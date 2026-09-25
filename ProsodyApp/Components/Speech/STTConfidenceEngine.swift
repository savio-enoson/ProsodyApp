//
//  STTConfidenceEngine.swift
//  ProsodyApp
//
//  Created for Prosody STT Confidence & Discrepancy Detection.
//

import Foundation

nonisolated enum PedagogicalCategory: String, Sendable, Equatable {
    case correctPronunciation = "correctPronunciation"
    case mispronunciation = "mispronunciation"
    case transcriptionUncertainty = "transcriptionUncertainty"
    case preservedGrammarVariation = "preservedGrammarVariation"
}

struct STTWordConfidence: Sendable, Equatable {
    let word: String
    let confidence: Float
    let isUncertain: Bool
    let category: PedagogicalCategory
    let candidates: [String]
    let alignScore: Float
    let ensembleScore: Float
    let literalScore: Float
    let frameEntropy: Float?
    let meanBlankProb: Float?
    let blankStability: Float?
    let blankOscillationRate: Float?
    let beamConsensus: Float?
    
    init(
        word: String,
        confidence: Float,
        isUncertain: Bool,
        category: PedagogicalCategory = .correctPronunciation,
        candidates: [String] = [],
        alignScore: Float = 0.0,
        ensembleScore: Float = 0.0,
        literalScore: Float = 0.0,
        frameEntropy: Float? = nil,
        meanBlankProb: Float? = nil,
        blankStability: Float? = nil,
        blankOscillationRate: Float? = nil,
        beamConsensus: Float? = nil
    ) {
        self.word = word
        self.confidence = confidence
        self.isUncertain = isUncertain
        self.category = category
        self.candidates = candidates
        self.alignScore = alignScore
        self.ensembleScore = ensembleScore
        self.literalScore = literalScore
        self.frameEntropy = frameEntropy
        self.meanBlankProb = meanBlankProb
        self.blankStability = blankStability
        self.blankOscillationRate = blankOscillationRate
        self.beamConsensus = beamConsensus
    }
}

enum STTConfidenceEngine {
    
    /// Default threshold under which an STT word is flagged as uncertain.
    /// Calibrated via SpeechOcean762 empirical sweep and conformal prediction (Phase 2).
    static let defaultThreshold: Float = 0.55
    
    static let functionAndSightWords: Set<String> = [
        "in", "on", "at", "to", "by", "up", "of", "for", "with", "from", "into", "out", "off", "down", "about",
        "a", "an", "the", "this", "that", "these", "those", "each", "every", "all", "some", "any", "no",
        "i", "me", "my", "we", "us", "our", "you", "your", "he", "him", "his", "she", "her", "it", "its", "they", "them", "their", "who", "what", "which",
        "and", "or", "but", "if", "so", "as", "than", "because", "while",
        "is", "am", "are", "was", "were", "be", "been", "being", "has", "have", "had", "do", "does", "did", "can", "could", "will", "would", "shall", "should", "may", "might", "must",
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "zero",
        "see", "go", "get", "come", "look", "make", "say", "said"
    ]
    
    static let grammarLemmaGroups: [Set<String>] = [
        ["have", "has", "had", "having"],
        ["do", "does", "did", "done", "doing"],
        ["go", "goes", "went", "gone", "going"],
        ["be", "is", "am", "are", "was", "were", "been", "being"],
        ["say", "says", "said"],
        ["make", "makes", "made"],
        ["get", "gets", "got", "gotten"],
        ["know", "knows", "knew", "known"],
        ["take", "takes", "took", "taken"],
        ["see", "sees", "saw", "seen"],
        ["come", "comes", "came"],
        ["think", "thinks", "thought"],
        ["look", "looks", "looked"],
        ["want", "wants", "wanted"],
        ["give", "gives", "gave", "given"],
        ["use", "uses", "used"],
        ["find", "finds", "found"],
        ["tell", "tells", "told"],
        ["ask", "asks", "asked"],
        ["work", "works", "worked"],
        ["seem", "seems", "seemed"],
        ["feel", "feels", "felt"],
        ["try", "tries", "tried"],
        ["leave", "leaves", "left"],
        ["call", "calls", "called"]
    ]
    
    static func isGrammarLemmaVariant(_ w1: String, _ w2: String) -> Bool {
        let c1 = DiscrepancyEngine.cleanWord(w1)
        let c2 = DiscrepancyEngine.cleanWord(w2)
        guard !c1.isEmpty && !c2.isEmpty else { return false }
        if c1 == c2 { return true }
        for group in grammarLemmaGroups {
            if group.contains(c1) && group.contains(c2) {
                return true
            }
        }
        return false
    }
    
    static func isGrammarOrMorphologicalVariant(target: String, candidate: String) -> Bool {
        let cT = DiscrepancyEngine.cleanWord(target)
        let cC = DiscrepancyEngine.cleanWord(candidate)
        guard !cT.isEmpty && !cC.isEmpty else { return false }
        if cT == cC { return true }
        if isGrammarLemmaVariant(cT, cC) { return true }
        return DiscrepancyEngine.matchesWordMorphologically(target: cT, candidate: cC)
    }

    /// Evaluates word-level confidence using multiple acoustic and semantic data streams.
    static func evaluateWord(
        word: String,
        segment: WordTimestamp?,
        literalWords: [String],
        whisperWords: [String],
        sfSpeechWords: [String],
        alignedWhisperWord: String? = nil,
        alignedSFSpeechWord: String? = nil,
        alignedLiteralWord: String? = nil,
        phoneticMatchRatio: Float? = nil,
        frameEntropy: Float? = nil,
        meanBlankProb: Float? = nil,
        maxNonBlankRun: Int? = nil,
        blankStability: Float? = nil,
        blankOscillationRate: Float? = nil,
        beamConsensus: Float? = nil,
        useLearnedConfidenceHead: Bool = true,
        threshold: Float = defaultThreshold,
        acousticScore: Int? = nil,
        scoringReferenceWord: String? = nil
    ) -> STTWordConfidence {
        let clean = DiscrepancyEngine.cleanWord(word)
        guard !clean.isEmpty else {
            return STTWordConfidence(word: word, confidence: 1.0, isUncertain: false, category: .correctPronunciation)
        }
        
        // 1. Acoustic Alignment Confidence (from CTCSegmentation Viterbi path)
        let rawAlign: Float = segment?.alignmentScore ?? 0.25
        
        // 2. Cross-Engine Ensemble Consensus
        let hasWhisperEngine = !whisperWords.isEmpty || alignedWhisperWord != nil
        let hasSFEngine = !sfSpeechWords.isEmpty || alignedSFSpeechWord != nil
        
        let hasWhisperMatch: Bool = {
            guard hasWhisperEngine else { return false }
            if let alt = alignedWhisperWord {
                let cleanAlt = DiscrepancyEngine.cleanWord(alt)
                if DiscrepancyEngine.matchesWord(target: clean, candidate: cleanAlt) { return true }
                if DiscrepancyEngine.matchesWordMorphologically(target: clean, candidate: cleanAlt) { return true }
                return false
            }
            return whisperWords.contains {
                let cW = DiscrepancyEngine.cleanWord($0)
                return DiscrepancyEngine.matchesWord(target: clean, candidate: cW) ||
                       DiscrepancyEngine.matchesWordMorphologically(target: clean, candidate: cW)
            }
        }()
        
        let hasSFMatch: Bool = {
            guard hasSFEngine else { return false }
            if let alt = alignedSFSpeechWord {
                let cleanAlt = DiscrepancyEngine.cleanWord(alt)
                if DiscrepancyEngine.matchesWord(target: clean, candidate: cleanAlt) { return true }
                if DiscrepancyEngine.matchesWordMorphologically(target: clean, candidate: cleanAlt) { return true }
                return false
            }
            return sfSpeechWords.contains {
                let cS = DiscrepancyEngine.cleanWord($0)
                return DiscrepancyEngine.matchesWord(target: clean, candidate: cS) ||
                       DiscrepancyEngine.matchesWordMorphologically(target: clean, candidate: cS)
            }
        }()
        
        // Check for Alternative Engine Consensus Veto:
        // When both alternative engines disagree with target but agree with each other
        let alternativeConsensusAgrees: Bool = {
            guard hasWhisperEngine && hasSFEngine && !hasWhisperMatch && !hasSFMatch else { return false }
            guard let w = alignedWhisperWord, let s = alignedSFSpeechWord else { return false }
            let cleanW = DiscrepancyEngine.cleanWord(w)
            let cleanS = DiscrepancyEngine.cleanWord(s)
            guard !cleanW.isEmpty && !cleanS.isEmpty else { return false }
            return DiscrepancyEngine.matchesWordMorphologically(target: cleanW, candidate: cleanS)
        }()
        
        // 3. Greedy Literal Acoustic Match
        let cLiteralRaw: Float = {
            if let lit = alignedLiteralWord {
                let cleanLit = DiscrepancyEngine.cleanWord(lit)
                if DiscrepancyEngine.matchesWord(target: clean, candidate: cleanLit) { return 1.0 }
                if levenshteinDistance(clean, cleanLit) <= 1 && clean.count >= 3 { return 0.70 }
            }
            if literalWords.contains(where: { DiscrepancyEngine.matchesWord(target: clean, candidate: DiscrepancyEngine.cleanWord($0)) }) {
                return 0.90
            }
            if literalWords.contains(where: { levenshteinDistance(clean, DiscrepancyEngine.cleanWord($0)) <= 1 && clean.count >= 3 }) {
                return 0.60
            }
            return 0.10
        }()
        
        let isDropoutStream = hasWhisperEngine && hasSFEngine &&
            alignedWhisperWord == nil && alignedSFSpeechWord == nil &&
            cLiteralRaw >= 0.95 && rawAlign >= 0.80

        let cEnsemble: Float
        if alternativeConsensusAgrees {
            // Strong veto: both independent engines agree on a distinct competing word
            cEnsemble = 0.05
        } else if hasWhisperEngine && hasSFEngine {
            if hasWhisperMatch && hasSFMatch {
                cEnsemble = 1.0
            } else if hasWhisperMatch {
                cEnsemble = 0.85
            } else if hasSFMatch {
                cEnsemble = 0.65
            } else if isDropoutStream {
                // Secondary stream omission/dropout (neither engine produced a token), high acoustic confidence
                cEnsemble = 0.40
            } else {
                cEnsemble = 0.15
            }
        } else if hasWhisperEngine {
            cEnsemble = hasWhisperMatch ? 0.95 : (alignedWhisperWord == nil && cLiteralRaw >= 0.95 && rawAlign >= 0.80 ? 0.40 : 0.20)
        } else if hasSFEngine {
            cEnsemble = hasSFMatch ? 0.90 : (alignedSFSpeechWord == nil && cLiteralRaw >= 0.95 && rawAlign >= 0.80 ? 0.40 : 0.20)
        } else {
            // Neither alternative engine was active or provided
            cEnsemble = 0.50
        }
        
        let lengthDampener: Float = {
            if cLiteralRaw >= 0.95 { return 1.0 }
            if clean.count <= 2 { return 0.60 }
            if clean.count == 3 { return 0.85 }
            return 1.0
        }()
        
        let hasAlternativeLexicalExpansion: Bool = {
            if let w = alignedWhisperWord {
                let cW = DiscrepancyEngine.cleanWord(w)
                if cW.count - clean.count >= 3 && !DiscrepancyEngine.matchesWordMorphologically(target: clean, candidate: cW) {
                    return true
                }
            }
            if let s = alignedSFSpeechWord {
                let cS = DiscrepancyEngine.cleanWord(s)
                if cS.count - clean.count >= 3 && !DiscrepancyEngine.matchesWordMorphologically(target: clean, candidate: cS) {
                    return true
                }
            }
            return false
        }()
        
        let isFunctionOrSight = functionAndSightWords.contains(clean)

        // Literal self-confirmation discounting:
        // When alternative engines agree on a competing candidate, heavily discount literal.
        // When an alternative engine confirms the word, floor literal at 0.70 so raw CTC spelling noise doesn't hurt.
        // When an alternative engine hears a full lexical word while target is a fragment, discount literal.
        // When alternative engines reject the word:
        //   - For short function/sight words with exact literal & strong alignment, preserve credit (child speech dropouts).
        //   - For content words, discount self-confirmation to break the Wav2Vec2 self-validation loop.
        let effectiveLiteral: Float
        if alternativeConsensusAgrees {
            effectiveLiteral = cLiteralRaw * 0.30
        } else if hasWhisperMatch || hasSFMatch {
            effectiveLiteral = max(cLiteralRaw, 0.70)
        } else if hasAlternativeLexicalExpansion {
            effectiveLiteral = cLiteralRaw * 0.35
        } else if hasWhisperEngine && hasSFEngine && !hasWhisperMatch && !hasSFMatch {
            if isFunctionOrSight && cLiteralRaw >= 0.95 && rawAlign >= 0.65 {
                effectiveLiteral = cLiteralRaw
            } else {
                effectiveLiteral = cLiteralRaw * 0.40
            }
        } else if (hasWhisperEngine || hasSFEngine) && !hasWhisperMatch && !hasSFMatch {
            if isFunctionOrSight && cLiteralRaw >= 0.95 && rawAlign >= 0.65 {
                effectiveLiteral = cLiteralRaw
            } else {
                effectiveLiteral = cLiteralRaw * 0.50
            }
        } else {
            effectiveLiteral = cLiteralRaw
        }
        
        // Alignment floor when confirmed by both an alternative engine and literal
        var effectiveAlign: Float
        if (hasWhisperMatch || hasSFMatch) && cLiteralRaw >= 0.90 {
            effectiveAlign = max(0.60, rawAlign)
        } else if hasWhisperMatch || hasSFMatch {
            effectiveAlign = rawAlign
        } else {
            effectiveAlign = rawAlign * lengthDampener
        }
        
        // CTC distributional uncertainty multipliers:
        // Entropy penalty: high Shannon entropy (normalized by ln(32) ≈ 3.4657) indicates acoustic ambiguity
        let entropyPenalty: Float = {
            guard let entropy = frameEntropy else { return 1.0 }
            let normalized = min(1.0, max(0.0, entropy / 3.4657))
            return max(0.35, 1.0 - max(0.0, normalized - 0.35) * 1.4)
        }()

        // Blank dominance penalty: model assigned substantial mass to silence/blank across the word span
        let blankPenalty: Float = {
            guard let blankP = meanBlankProb else { return 1.0 }
            return max(0.40, 1.0 - max(0.0, blankP - 0.50) * 2.0)
        }()

        // Blank oscillation penalty: erratic toggling between blank and non-blank frames
        let oscillationPenalty: Float = {
            guard let osc = blankOscillationRate else { return 1.0 }
            return max(0.70, 1.0 - max(0.0, osc - 0.40) * 0.75)
        }()

        effectiveAlign *= (entropyPenalty * blankPenalty * oscillationPenalty)
        
        // 4. Learned Confidence Estimation Module (CoreML CEM)
        var finalConfidence: Float
        if useLearnedConfidenceHead && LearnedConfidenceEngine.shared.isReady {
            let cemFeatures: [Float] = [
                effectiveAlign,
                cEnsemble,
                effectiveLiteral,
                frameEntropy ?? 0.0,
                meanBlankProb ?? 0.0,
                maxNonBlankRun.map { Float($0) } ?? blankStability ?? 0.0,
                blankOscillationRate ?? 0.0,
                phoneticMatchRatio ?? 0.0,
                Float(clean.count),
                isFunctionOrSight ? 1.0 : 0.0,
                isFunctionOrSight ? 0.0 : 1.0,
                Float((segment?.duration ?? 0.0) * 1000.0),
                hasWhisperMatch ? 1.0 : 0.0,
                hasSFMatch ? 1.0 : 0.0,
                alternativeConsensusAgrees ? 1.0 : 0.0,
                beamConsensus ?? 1.0
            ]
            let learned = LearnedConfidenceEngine.shared.predictConfidence(features: cemFeatures)
            finalConfidence = min(1.0, max(0.0, learned))
        } else {
            finalConfidence = min(1.0, max(0.0, effectiveAlign))
            if alternativeConsensusAgrees {
                finalConfidence = min(finalConfidence, 0.35)
            }
        }
        
        let isUncertain = finalConfidence < threshold
        
        let pedagogicalCategory: PedagogicalCategory
        if isUncertain {
            pedagogicalCategory = .transcriptionUncertainty
        } else if let ref = scoringReferenceWord,
                  !DiscrepancyEngine.matchesWord(target: clean, candidate: DiscrepancyEngine.cleanWord(ref)),
                  isGrammarOrMorphologicalVariant(target: ref, candidate: clean),
                  (acousticScore ?? 70) >= 55 && effectiveLiteral >= 0.50 {
            pedagogicalCategory = .preservedGrammarVariation
        } else if (acousticScore != nil && acousticScore! < STTSettings.currentPassingThreshold) ||
                  (phoneticMatchRatio != nil && phoneticMatchRatio! < 0.65) {
            pedagogicalCategory = .mispronunciation
        } else {
            pedagogicalCategory = .correctPronunciation
        }

        // Collect candidate alternative words
        var rawCandidates = [String]()
        if pedagogicalCategory == .preservedGrammarVariation, let ref = scoringReferenceWord {
            rawCandidates.append(ref)
        }
        if alternativeConsensusAgrees, let w = alignedWhisperWord {
            rawCandidates.append(w)
        }
        if let w = alignedWhisperWord { rawCandidates.append(w) }
        if let s = alignedSFSpeechWord { rawCandidates.append(s) }
        if let l = alignedLiteralWord { rawCandidates.append(l) }
        
        var seen = Set<String>()
        seen.insert(clean)
        var filteredCandidates = [String]()
        for cand in rawCandidates {
            let cleanCand = DiscrepancyEngine.cleanWord(cand)
            if !cleanCand.isEmpty && !seen.contains(cleanCand) {
                seen.insert(cleanCand)
                filteredCandidates.append(cand.trimmingCharacters(in: .punctuationCharacters))
            }
        }
        
        return STTWordConfidence(
            word: word,
            confidence: finalConfidence,
            isUncertain: isUncertain,
            category: pedagogicalCategory,
            candidates: filteredCandidates,
            alignScore: effectiveAlign,
            ensembleScore: cEnsemble,
            literalScore: effectiveLiteral,
            frameEntropy: frameEntropy,
            meanBlankProb: meanBlankProb,
            blankStability: blankStability,
            blankOscillationRate: blankOscillationRate,
            beamConsensus: beamConsensus
        )
    }
    
    private static func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let m = aChars.count
        let n = bChars.count
        guard m > 0 else { return n }
        guard n > 0 else { return m }
        
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        
        for i in 1...m {
            for j in 1...n {
                if aChars[i - 1] == bChars[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + min(dp[i - 1][j - 1], min(dp[i - 1][j], dp[i][j - 1]))
                }
            }
        }
        return dp[m][n]
    }
}
