import Foundation
import NaturalLanguage
import Accelerate

/// Dedicated detection and syntactic analysis engine for speech disfluencies.
/// Detects vocalized filled pauses ("um", "uh"), exact word/phrase repetitions,
/// false starts, and classifies pause positions into grammatical boundaries vs. intra-phrase hesitations.
nonisolated struct DisfluencyDetector {

    // MARK: - Constants & Dictionaries

    /// Canonical vocalized filler tokens in English.
    static let lexicalFillers: Set<String> = [
        "um", "uh", "er", "ah", "erm", "mm", "mmm", "mhm", "uh-huh"
    ]

    /// Common coordinating and subordinating conjunctions and clause introducers.
    private static let clauseIntroducers: Set<String> = [
        "and", "but", "or", "so", "yet", "for", "nor",
        "because", "although", "though", "while", "when", "whenever",
        "where", "wherever", "if", "unless", "since", "after", "before",
        "that", "which", "who", "whom", "whose", "as", "until"
    ]

    /// Common English auxiliary and modal verbs.
    private static let auxiliaryVerbs: Set<String> = [
        "is", "am", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "having",
        "do", "does", "did",
        "can", "could", "will", "would", "shall", "should", "may", "might", "must"
    ]

    /// English determiners.
    private static let determiners: Set<String> = [
        "the", "a", "an", "this", "that", "these", "those",
        "my", "your", "his", "her", "its", "our", "their",
        "some", "any", "no", "every", "each", "either", "neither"
    ]

    /// Common English prepositions.
    private static let prepositions: Set<String> = [
        "to", "in", "at", "on", "for", "with", "by", "from", "about",
        "into", "through", "during", "before", "after", "above", "below",
        "under", "between", "among", "against", "without"
    ]

    // MARK: - Main Analysis Entry Point

    /// Analyzes speech segments, transcript, and optional audio to produce a comprehensive DisfluencyReport
    /// and decorate pause events with syntactic and acoustic classifications.
    static func analyze(
        segments: [WordTimestamp],
        transcript: String,
        sfSpeechTranscript: String? = nil,
        pauses: inout [PauseEvent],
        audioChunk: [Float]? = nil,
        sampleRate: Float = 16000.0,
        totalDuration: Float = 0.0
    ) -> DisfluencyReport {
        guard !segments.isEmpty else {
            return DisfluencyReport(
                fillerCount: 0,
                repetitionCount: 0,
                falseStartCount: 0,
                intraPhrasePauseCount: 0,
                grammaticalPauseCount: 0,
                totalDisfluencyCount: 0,
                disfluencyRatePerMinute: 0.0,
                intraPhrasePauseRatio: 0.0,
                events: [],
                annotatedTranscript: transcript
            )
        }

        var events: [DisfluencyEvent] = []

        // 1. Detect Word & Phrase Repetitions and False Starts
        let repetitionEvents = detectRepetitions(segments: segments)
        events.append(contentsOf: repetitionEvents)

        let falseStartEvents = detectFalseStarts(segments: segments)
        events.append(contentsOf: falseStartEvents)

        // 2. Classify Syntactic Pause Positions
        classifyPausePositions(pauses: &pauses, transcript: transcript)

        // 3. Detect Lexical and Acoustic Filled Pauses
        let fillerEvents = detectFilledPauses(
            segments: segments,
            transcript: transcript,
            sfSpeechTranscript: sfSpeechTranscript,
            pauses: &pauses,
            audioChunk: audioChunk,
            sampleRate: sampleRate
        )
        events.append(contentsOf: fillerEvents)

        // 4. Compute Counts & Ratios
        let fillerCount = events.filter { $0.type == .filledPause }.count
        let repetitionCount = events.filter { $0.type == .repetition || $0.type == .phraseRepetition }.count
        let falseStartCount = events.filter { $0.type == .falseStart }.count

        let intraPhrasePauseCount = pauses.filter { $0.positionType == .intraPhrase }.count
        let grammaticalPauseCount = pauses.filter { $0.positionType == .grammaticalClause || $0.positionType == .sentenceBoundary }.count
        let totalDisfluencyCount = fillerCount + repetitionCount + falseStartCount + intraPhrasePauseCount

        let durationMin = totalDuration > 0 ? (totalDuration / 60.0) : Float(segments.last!.endTime - segments.first!.startTime) / 60.0
        let disfluencyRate = durationMin > 0 ? Float(totalDisfluencyCount) / durationMin : 0.0
        let intraPhraseRatio = pauses.isEmpty ? 0.0 : Float(intraPhrasePauseCount) / Float(pauses.count)

        // 5. Generate Annotated Transcript
        let annotated = buildAnnotatedTranscript(
            segments: segments,
            pauses: pauses,
            events: events
        )

        return DisfluencyReport(
            fillerCount: fillerCount,
            repetitionCount: repetitionCount,
            falseStartCount: falseStartCount,
            intraPhrasePauseCount: intraPhrasePauseCount,
            grammaticalPauseCount: grammaticalPauseCount,
            totalDisfluencyCount: totalDisfluencyCount,
            disfluencyRatePerMinute: disfluencyRate,
            intraPhrasePauseRatio: intraPhraseRatio,
            events: events,
            annotatedTranscript: annotated
        )
    }

    // MARK: - Syntactic Pause Classification via NaturalLanguage

    /// Classifies each pause event as either a natural grammatical boundary or an intra-phrase hesitation.
    static func classifyPausePositions(pauses: inout [PauseEvent], transcript: String) {
        guard !pauses.isEmpty else { return }

        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = transcript

        // Cache POS tags for words in transcript
        var posMap: [String: String] = [:]
        let range = transcript.startIndex..<transcript.endIndex
        tagger.enumerateTags(in: range, unit: .word, scheme: .lexicalClass) { tag, tokenRange in
            let word = String(transcript[tokenRange]).lowercased()
            if let tagStr = tag?.rawValue {
                posMap[word] = tagStr
            }
            return true
        }

        for i in 0..<pauses.count {
            let beforeRaw = pauses[i].wordBefore
            let afterRaw = pauses[i].wordAfter
            let beforeClean = cleanWord(beforeRaw).lowercased()
            let afterClean = cleanWord(afterRaw).lowercased()

            let posBefore = posMap[beforeClean] ?? fallbackPOS(beforeClean)
            let posAfter = posMap[afterClean] ?? fallbackPOS(afterClean)

            pauses[i].precedingPartOfSpeech = posBefore
            pauses[i].succeedingPartOfSpeech = posAfter

            // Rule 1: Trailing punctuation on wordBefore
            if hasTerminalPunctuation(beforeRaw) {
                pauses[i].positionType = .sentenceBoundary
                continue
            }
            if hasClausePunctuation(beforeRaw) {
                pauses[i].positionType = .grammaticalClause
                continue
            }

            // Rule 2: Clause introducer or conjunction boundary (preceding or succeeding)
            if clauseIntroducers.contains(afterClean) || posAfter == "Conjunction" ||
               clauseIntroducers.contains(beforeClean) || posBefore == "Conjunction" {
                pauses[i].positionType = .grammaticalClause
                continue
            }

            // Rule 3: Tight intra-phrase constituents (inappropriate hesitation)
            // (a) Determiner -> Noun or Adjective
            if determiners.contains(beforeClean) || posBefore == "Determiner" {
                pauses[i].positionType = .intraPhrase
                continue
            }

            // (b) Preposition -> Determiner, Noun, Pronoun
            if prepositions.contains(beforeClean) || posBefore == "Preposition" {
                pauses[i].positionType = .intraPhrase
                continue
            }

            // (c) Auxiliary/Modal Verb -> Main Verb
            if auxiliaryVerbs.contains(beforeClean) && (posAfter == "Verb" || posAfter == "Particle") {
                pauses[i].positionType = .intraPhrase
                continue
            }

            // (d) Adjective -> Noun
            if posBefore == "Adjective" && posAfter == "Noun" {
                pauses[i].positionType = .intraPhrase
                continue
            }

            // Default: Grammatical phrase transition
            pauses[i].positionType = .grammaticalClause
        }
    }

    // MARK: - Repetition & False Start Detection

    private static func detectRepetitions(segments: [WordTimestamp]) -> [DisfluencyEvent] {
        guard segments.count >= 2 else { return [] }
        var events: [DisfluencyEvent] = []

        // Single-word repetitions: w[i] == w[i-1]
        var skipIndices = Set<Int>()
        for i in 1..<segments.count {
            let curr = cleanWord(segments[i].word).lowercased()
            let prev = cleanWord(segments[i - 1].word).lowercased()

            guard !curr.isEmpty && !prev.isEmpty else { continue }

            if curr == prev {
                events.append(DisfluencyEvent(
                    type: .repetition,
                    word: segments[i].word,
                    startTime: segments[i - 1].startTime,
                    duration: segments[i].endTime - segments[i - 1].startTime,
                    contextPhrase: "\(segments[i - 1].word) \(segments[i].word)"
                ))
                skipIndices.insert(i)
            }
        }

        // 2-word phrase repetitions: w[i] w[i+1] == w[i+2] w[i+3]
        if segments.count >= 4 {
            for i in 0...(segments.count - 4) {
                if skipIndices.contains(i) || skipIndices.contains(i + 1) { continue }
                let w0 = cleanWord(segments[i].word).lowercased()
                let w1 = cleanWord(segments[i + 1].word).lowercased()
                let w2 = cleanWord(segments[i + 2].word).lowercased()
                let w3 = cleanWord(segments[i + 3].word).lowercased()

                if w0 == w2 && w1 == w3 {
                    events.append(DisfluencyEvent(
                        type: .phraseRepetition,
                        word: "\(segments[i].word) \(segments[i + 1].word)",
                        startTime: segments[i].startTime,
                        duration: segments[i + 3].endTime - segments[i].startTime,
                        contextPhrase: "\(segments[i].word) \(segments[i + 1].word) \(segments[i + 2].word) \(segments[i + 3].word)"
                    ))
                }
            }
        }

        return events
    }

    private static func detectFalseStarts(segments: [WordTimestamp]) -> [DisfluencyEvent] {
        guard segments.count >= 2 else { return [] }
        var events: [DisfluencyEvent] = []

        for i in 1..<segments.count {
            let prev = cleanWord(segments[i - 1].word).lowercased()
            let curr = cleanWord(segments[i].word).lowercased()

            // Repetition already handles exact match
            guard prev != curr, prev.count >= 2, curr.count >= 3 else { continue }

            // Prefix false start: e.g. "pla-" before "play", "comput-" before "computer"
            if curr.hasPrefix(prev) && segments[i - 1].duration < 0.35 {
                events.append(DisfluencyEvent(
                    type: .falseStart,
                    word: segments[i - 1].word,
                    startTime: segments[i - 1].startTime,
                    duration: segments[i - 1].duration,
                    contextPhrase: "\(segments[i - 1].word) -> \(segments[i].word)"
                ))
            }
        }

        return events
    }

    // MARK: - Filled Pause Detection (Lexical + Acoustic)

    private static func detectFilledPauses(
        segments: [WordTimestamp],
        transcript: String,
        sfSpeechTranscript: String?,
        pauses: inout [PauseEvent],
        audioChunk: [Float]?,
        sampleRate: Float
    ) -> [DisfluencyEvent] {
        var events: [DisfluencyEvent] = []

        // A. Lexical tokens in segments
        for seg in segments {
            let clean = cleanWord(seg.word).lowercased()
            if lexicalFillers.contains(clean) {
                events.append(DisfluencyEvent(
                    type: .filledPause,
                    word: seg.word,
                    startTime: seg.startTime,
                    duration: seg.duration,
                    contextPhrase: seg.word
                ))
            }
        }

        // B. Lexical tokens in SFSpeech transcript not in aligned segments
        if let sfText = sfSpeechTranscript {
            let sfWords = sfText.components(separatedBy: .whitespacesAndNewlines).map { cleanWord($0).lowercased() }
            for filler in lexicalFillers {
                if sfWords.contains(filler) && !events.contains(where: { cleanWord($0.word).lowercased() == filler }) {
                    events.append(DisfluencyEvent(
                        type: .filledPause,
                        word: filler,
                        startTime: segments.first?.startTime ?? 0.0,
                        duration: 0.40,
                        contextPhrase: "Detected via speech recognizer: '\(filler)'"
                    ))
                }
            }
        }

        // C. Acoustic vocalized pauses during silence intervals
        if let audio = audioChunk, !audio.isEmpty && !pauses.isEmpty {
            for i in 0..<pauses.count {
                let p = pauses[i]
                guard p.duration >= 0.20 else { continue }

                let startSample = max(0, Int(p.startTime * Double(sampleRate)))
                let endSample = min(audio.count, Int((p.startTime + p.duration) * Double(sampleRate)))
                let sampleCount = endSample - startSample

                guard sampleCount > 160 else { continue } // >= 10ms

                var rms: Float = 0.0
                audio.withUnsafeBufferPointer { ptr in
                    if let base = ptr.baseAddress {
                        vDSP_rmsqv(base.advanced(by: startSample), 1, &rms, vDSP_Length(sampleCount))
                    }
                }

                // If gap has non-trivial energy (not silence) and voicing continuity
                if rms > 0.045 {
                    pauses[i].isFilled = true
                    pauses[i].fillerToken = "vocalized pause"

                    events.append(DisfluencyEvent(
                        type: .filledPause,
                        word: "uh/um (vocalized)",
                        startTime: p.startTime,
                        duration: p.duration,
                        contextPhrase: "after '\(p.wordBefore)' before '\(p.wordAfter)'"
                    ))
                }
            }
        }

        return events
    }

    // MARK: - Annotated Transcript Builder

    private static func buildAnnotatedTranscript(
        segments: [WordTimestamp],
        pauses: [PauseEvent],
        events: [DisfluencyEvent]
    ) -> String {
        var tokens: [String] = []

        for i in 0..<segments.count {
            let seg = segments[i]
            tokens.append(seg.word)

            // Check if a repetition or false start occurred here
            if let rep = events.first(where: { ($0.type == .repetition || $0.type == .falseStart) && abs($0.startTime - seg.startTime) < 0.05 }) {
                tokens.append("[\(rep.type.rawValue.uppercased())]")
            }

            // Check if pause follows this word
            if i < segments.count - 1 {
                if let pause = pauses.first(where: { abs($0.startTime - seg.endTime) < 0.15 }) {
                    let typeStr = pause.positionType == .intraPhrase ? "intra-phrase" : (pause.positionType == .sentenceBoundary ? "sentence" : "clause")
                    let fillStr = pause.isFilled ? " FILLED" : ""
                    tokens.append("[PAUSE: \(typeStr)\(fillStr) \(String(format: "%.2f", pause.duration))s]")
                }
            }
        }

        return tokens.joined(separator: " ")
    }

    // MARK: - Helpers

    static func cleanWord(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
    }

    private static func hasTerminalPunctuation(_ word: String) -> Bool {
        word.hasSuffix(".") || word.hasSuffix("?") || word.hasSuffix("!")
    }

    private static func hasClausePunctuation(_ word: String) -> Bool {
        word.hasSuffix(",") || word.hasSuffix(";") || word.hasSuffix(":") || word.hasSuffix("--") || word.hasSuffix("—")
    }

    private static func fallbackPOS(_ word: String) -> String {
        if determiners.contains(word) { return "Determiner" }
        if prepositions.contains(word) { return "Preposition" }
        if auxiliaryVerbs.contains(word) { return "Verb" }
        if clauseIntroducers.contains(word) { return "Conjunction" }
        return "Other"
    }
}
