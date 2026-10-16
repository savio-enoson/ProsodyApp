import Foundation

// MARK: - Transcript Word Model

struct TranscriptWord: Identifiable, Equatable {
    let id: UUID
    var text: String
    var cleanWord: String
    var alternative: String?
    var confidence: Float
    var isUncertain: Bool
    var candidates: [String]
    var userVerified: Bool
    
    var hasDifference: Bool {
        guard let alt = alternative else { return false }
        return !alt.isEmpty && TranscriptWord.clean(alt) != cleanWord
    }
    
    init(
        id: UUID = UUID(),
        text: String,
        alternative: String? = nil,
        confidence: Float = 1.0,
        isUncertain: Bool = false,
        candidates: [String] = [],
        userVerified: Bool = false
    ) {
        self.id = id
        self.text = text
        self.cleanWord = TranscriptWord.clean(text)
        self.alternative = alternative
        self.confidence = confidence
        self.isUncertain = isUncertain
        self.candidates = candidates
        self.userVerified = userVerified
    }
    
    static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
            .lowercased()
    }
}

// MARK: - Sequence Alignment & Diff Engine

enum TranscriptDiffEngine {
    
    /// Compares primary (e.g. Wav2Vec2 / Acoustic Mirror) text with alternative (e.g. Whisper) text
    /// and returns an array of TranscriptWord objects with differences marked.
    static func align(primary: String, alternative: String) -> [TranscriptWord] {
        return align(
            primary: primary,
            alternative: alternative,
            sfSpeech: nil,
            literal: nil,
            timestamps: [],
            phoneticMatchRatio: nil,
            threshold: STTConfidenceEngine.defaultThreshold
        )
    }
    
    /// Enhanced multi-stream alignment and STT uncertainty evaluation
    static func align(
        primary: String,
        alternative: String,
        sfSpeech: String? = nil,
        literal: String? = nil,
        timestamps: [WordTimestamp] = [],
        phoneticMatchRatio: Float? = nil,
        threshold: Float = STTConfidenceEngine.defaultThreshold
    ) -> [TranscriptWord] {
        let rawWordsA = primary.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let rawWordsB = alternative.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        
        guard !rawWordsA.isEmpty else { return [] }
        guard !rawWordsB.isEmpty else {
            return rawWordsA.enumerated().map { (idx, w) in
                let seg = idx < timestamps.count ? timestamps[idx] : nil
                let conf = STTConfidenceEngine.evaluateWord(
                    word: w,
                    segment: seg,
                    literalWords: (literal ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty },
                    whisperWords: [],
                    sfSpeechWords: (sfSpeech ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty },
                    threshold: threshold
                )
                return TranscriptWord(
                    text: w,
                    alternative: nil,
                    confidence: conf.confidence,
                    isUncertain: conf.isUncertain,
                    candidates: conf.candidates
                )
            }
        }
        
        let cleanA = rawWordsA.map { TranscriptWord.clean($0) }
        let cleanB = rawWordsB.map { TranscriptWord.clean($0) }
        
        let m = cleanA.count
        let n = cleanB.count
        
        // DP table for edit distance alignment
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        
        for i in 1...m {
            for j in 1...n {
                if cleanA[i - 1] == cleanB[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    let costSub = dp[i - 1][j - 1] + 1
                    let costDel = dp[i - 1][j] + 1
                    let costIns = dp[i][j - 1] + 1
                    dp[i][j] = min(costSub, min(costDel, costIns))
                }
            }
        }
        
        // Backtrack to find alignment operations
        var i = m
        var j = n
        
        enum Op {
            case match(idxA: Int, idxB: Int)
            case substitute(idxA: Int, idxB: Int)
            case deleteA(idxA: Int)
            case insertB(idxB: Int)
        }
        
        var operations: [Op] = []
        
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && cleanA[i - 1] == cleanB[j - 1] {
                operations.append(.match(idxA: i - 1, idxB: j - 1))
                i -= 1
                j -= 1
            } else if i > 0 && j > 0 && dp[i][j] == dp[i - 1][j - 1] + 1 {
                operations.append(.substitute(idxA: i - 1, idxB: j - 1))
                i -= 1
                j -= 1
            } else if i > 0 && dp[i][j] == dp[i - 1][j] + 1 {
                operations.append(.deleteA(idxA: i - 1))
                i -= 1
            } else if j > 0 {
                operations.append(.insertB(idxB: j - 1))
                j -= 1
            } else {
                break
            }
        }
        
        operations.reverse()
        
        // Map operations onto TranscriptWord array
        var resultWords: [TranscriptWord] = rawWordsA.map { TranscriptWord(text: $0, alternative: nil) }
        
        for op in operations {
            switch op {
            case .match:
                break // No difference
            case .substitute(let idxA, let idxB):
                if idxA < resultWords.count && idxB < rawWordsB.count {
                    resultWords[idxA].alternative = rawWordsB[idxB]
                }
            case .deleteA:
                break
            case .insertB(let idxB):
                if idxB < rawWordsB.count {
                    let insertText = rawWordsB[idxB]
                    let precedingIndex = operations.last(where: {
                        switch $0 {
                        case .match(_, let b) where b < idxB: return true
                        case .substitute(_, let b) where b < idxB: return true
                        default: return false
                        }
                    })
                    if let p = precedingIndex {
                        switch p {
                        case .match(let a, _), .substitute(let a, _):
                            if a < resultWords.count {
                                if let existing = resultWords[a].alternative {
                                    resultWords[a].alternative = existing + " " + insertText
                                } else {
                                    resultWords[a].alternative = resultWords[a].text + " " + insertText
                                }
                            }
                        default: break
                        }
                    }
                }
            }
        }
        
        // Enrich with multi-stream confidence evaluation
        let whisperWords = rawWordsB
        let sfSpeechWords = (sfSpeech ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let literalWords = (literal ?? "").components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        
        let alignedSFMap = DiscrepancyEngine.alignWords(targetWords: rawWordsA, streamWords: sfSpeechWords)
        let alignedLitMap = DiscrepancyEngine.alignWords(targetWords: rawWordsA, streamWords: literalWords)
        
        var lastSegIdx = 0
        for idx in 0..<resultWords.count {
            let wordText = resultWords[idx].text
            let wordClean = TranscriptWord.clean(wordText)
            
            // Match segment sequentially
            var matchedSegment: WordTimestamp? = nil
            for sIdx in lastSegIdx..<timestamps.count {
                if TranscriptWord.clean(timestamps[sIdx].word) == wordClean {
                    matchedSegment = timestamps[sIdx]
                    lastSegIdx = sIdx + 1
                    break
                }
            }
            if matchedSegment == nil && idx < timestamps.count {
                matchedSegment = timestamps[idx]
            }
            
            let alignedWhisper = resultWords[idx].alternative
            let alignedSF = alignedSFMap[idx]
            let alignedLit = alignedLitMap[idx]
            
            let evalResult = STTConfidenceEngine.evaluateWord(
                word: wordText,
                segment: matchedSegment,
                literalWords: literalWords,
                whisperWords: whisperWords,
                sfSpeechWords: sfSpeechWords,
                alignedWhisperWord: alignedWhisper,
                alignedSFSpeechWord: alignedSF,
                alignedLiteralWord: alignedLit,
                phoneticMatchRatio: phoneticMatchRatio,
                threshold: threshold
            )
            
            resultWords[idx].confidence = evalResult.confidence
            resultWords[idx].isUncertain = !resultWords[idx].userVerified && evalResult.isUncertain
            
            var allCandidates = evalResult.candidates
            if let alt = resultWords[idx].alternative, !alt.isEmpty {
                let cleanAlt = TranscriptWord.clean(alt)
                if !allCandidates.contains(where: { TranscriptWord.clean($0) == cleanAlt }) && cleanAlt != wordClean {
                    allCandidates.insert(alt, at: 0)
                }
            }
            resultWords[idx].candidates = allCandidates
        }
        
        return resultWords
    }
    
    /// Replaces a specific word in the transcript by ID, keeping other words intact.
    static func replaceWord(in words: [TranscriptWord], id: UUID, with newText: String) -> (words: [TranscriptWord], fullString: String) {
        var updated = words
        if let idx = updated.firstIndex(where: { $0.id == id }) {
            let orig = updated[idx].text
            var replacement = newText
            if let lastPunct = orig.last, CharacterSet.punctuationCharacters.contains(lastPunct.unicodeScalars.first!), !newText.hasSuffix(String(lastPunct)) {
                replacement += String(lastPunct)
            }
            updated[idx] = TranscriptWord(
                id: id,
                text: replacement,
                alternative: nil,
                confidence: 1.0,
                isUncertain: false,
                candidates: [],
                userVerified: true
            )
        }
        let fullString = updated.map(\.text).joined(separator: " ")
        return (updated, fullString)
    }
}
