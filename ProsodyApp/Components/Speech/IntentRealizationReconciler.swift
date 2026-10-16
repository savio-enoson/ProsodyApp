import Foundation

/// IntentRealizationReconciler
/// Resolves the Acoustic Mirror Paradox for unprompted conversational practice:
/// Decouples "What word did the learner intend to say?" (Semantic Target)
/// from "What sound/morpheme did the learner actually articulate?" (Verbatim Realization).
nonisolated struct ReconciledWord: Equatable {
    let displayWord: String
    let scoringWord: String
    let isMorphologicalOmission: Bool
    let isMinimalPairSubstitution: Bool
    let diagnosticNote: String?
}

nonisolated struct ReconciledTurn: Equatable {
    let displayTranscript: String
    let scoringReference: String
    let words: [ReconciledWord]
}

nonisolated enum IntentRealizationReconciler {
    
    // Known high-frequency L2 minimal pair confusions: (intended, spokenVariant)
    private static let knownMinimalPairs: [String: Set<String>] = [
        // Dental fricative unvoiced /θ/ -> [s], [t], [f]
        "think": ["sink", "tink", "fink"],
        "thought": ["sought", "taught"],
        "thin": ["sin", "tin", "fin"],
        "thick": ["sick", "tick"],
        "thank": ["sank", "tank"],
        "three": ["tree", "free"],
        "theme": ["seem", "team"],
        "thumb": ["some", "tumb"],
        "mouth": ["mouse"],
        "path": ["pass", "pat"],
        "faith": ["face", "fate"],
        
        // Dental fricative voiced /ð/ -> [d], [z], [v]
        "they": ["day", "dey"],
        "there": ["dare", "dere"],
        "their": ["dare", "dere"],
        "then": ["den"],
        "than": ["dan"],
        "that": ["dat"],
        "this": ["dis"],
        "these": ["dees"],
        "those": ["dose"],
        "breathe": ["breeze"],
        "clothe": ["close"],
        
        // Liquid / Glide /r/ -> [w], [l]
        "red": ["wed", "led"],
        "right": ["white", "light"],
        "ring": ["wing"],
        "read": ["lead"],
        "rake": ["lake"],
        "road": ["load"],
        "rock": ["lock"],
        
        // Labiodental /v/ -> [b], [w]
        "very": ["berry", "wary"],
        "vest": ["best", "west"],
        "van": ["ban"],
        "vine": ["wine"],
        "voice": ["boys"],
        
        // Final Obstruent Devoicing
        "leave": ["leaf"],
        "live": ["lif"],
        "prize": ["price"],
        "buzz": ["bus"],
        "bad": ["bat"],
        "bed": ["bet"],
        "hard": ["heart"],
        "card": ["cart"],
        "cab": ["cap"],
        "pig": ["pick"],
        "dog": ["dock"],
        
        // Tense vs Lax Vowels
        "sheep": ["ship"],
        "seat": ["sit"],
        "beat": ["bit"],
        "heat": ["hit"],
        "feet": ["fit"],
        "reach": ["rich"],
        "pull": ["pool"],
        "fool": ["full"]
    ]
    
    /// Reconciles the contextual intent transcript (e.g. from Nemotron or Language Model)
    /// with the literal unconstrained acoustic transcript (e.g. from Wav2Vec2 greedy decode).
    static func reconcile(
        intent: String,
        literal: String,
        fallbackTranscript: String
    ) -> ReconciledTurn {
        let cleanWords: (String) -> [String] = { text in
            text.components(separatedBy: .whitespacesAndNewlines)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty }
        }
        
        let intentWords = cleanWords(intent)
        let literalWords = cleanWords(literal)
        let fallbackWords = cleanWords(fallbackTranscript)
        
        let primaryWords = !fallbackWords.isEmpty ? fallbackWords : intentWords
        guard !primaryWords.isEmpty else {
            return ReconciledTurn(
                displayTranscript: "",
                scoringReference: "",
                words: []
            )
        }

        // Align primary stream with intent and literal streams
        var reconciledWords: [ReconciledWord] = []
        var intentIdx = 0
        var litIdx = 0

        for primWord in primaryWords {
            let primLower = primWord.lowercased()

            // 1. Search in intent window of size 3 around current index
            var matchedIntentIdx: Int? = nil
            let searchStartI = max(0, intentIdx - 1)
            let searchEndI = min(intentWords.count, intentIdx + 3)

            for j in searchStartI..<searchEndI {
                let iLower = intentWords[j].lowercased()
                if iLower == primLower || isMorphologicalPair(intent: iLower, literal: primLower) || isMinimalPair(intent: iLower, literal: primLower) {
                    matchedIntentIdx = j
                    break
                }
            }

            // 2. Search in literal window of size 3 around current index
            var matchedLitIdx: Int? = nil
            let searchStartL = max(0, litIdx - 1)
            let searchEndL = min(literalWords.count, litIdx + 3)

            for j in searchStartL..<searchEndL {
                let lLower = literalWords[j].lowercased()
                if lLower == primLower || isMorphologicalPair(intent: primLower, literal: lLower) || isMinimalPair(intent: primLower, literal: lLower) {
                    matchedLitIdx = j
                    break
                }
            }
            if let fL = matchedLitIdx { litIdx = fL + 1 }

            if let fI = matchedIntentIdx {
                let iWord = intentWords[fI]
                let iLower = iWord.lowercased()
                intentIdx = fI + 1

                if iLower == primLower {
                    // Exact agreement between primary and intent
                    reconciledWords.append(ReconciledWord(
                        displayWord: primWord,
                        scoringWord: primWord,
                        isMorphologicalOmission: false,
                        isMinimalPairSubstitution: false,
                        diagnosticNote: nil
                    ))
                } else if isMorphologicalPair(intent: iLower, literal: primLower) {
                    // Case 1: Morphological omission (e.g. intent "walked", spoken "walk")
                    reconciledWords.append(ReconciledWord(
                        displayWord: primWord,
                        scoringWord: primWord,
                        isMorphologicalOmission: true,
                        isMinimalPairSubstitution: false,
                        diagnosticNote: "Omitted inflection: intended '\(iWord)', pronounced '\(primWord)'"
                    ))
                } else if isMinimalPair(intent: iLower, literal: primLower) {
                    // Case 2: Minimal pair substitution (e.g. intent "think", spoken "sink")
                    // Display spoken "sink" for the Acoustic Mirror, but score against target "think"!
                    reconciledWords.append(ReconciledWord(
                        displayWord: primWord,
                        scoringWord: iWord,
                        isMorphologicalOmission: false,
                        isMinimalPairSubstitution: true,
                        diagnosticNote: "Phonemic substitution: intended '\(iWord)', pronounced '\(primWord)'"
                    ))
                } else {
                    reconciledWords.append(ReconciledWord(
                        displayWord: primWord,
                        scoringWord: primWord,
                        isMorphologicalOmission: false,
                        isMinimalPairSubstitution: false,
                        diagnosticNote: nil
                    ))
                }
            } else {
                // No intent counterpart found, preserve primary acoustic word
                reconciledWords.append(ReconciledWord(
                    displayWord: primWord,
                    scoringWord: primWord,
                    isMorphologicalOmission: false,
                    isMinimalPairSubstitution: false,
                    diagnosticNote: nil
                ))
            }
        }
        
        let displayStr = reconciledWords.map(\.displayWord).joined(separator: " ")
        let scoringStr = reconciledWords.map(\.scoringWord).joined(separator: " ")
        
        return ReconciledTurn(
            displayTranscript: displayStr,
            scoringReference: scoringStr,
            words: reconciledWords
        )
    }
    
    private static func isMorphologicalPair(intent: String, literal: String) -> Bool {
        // -ed past tense omission (walked -> walk)
        if intent.hasSuffix("ed") && (intent.dropLast(2) == literal || intent.dropLast(1) == literal) {
            return true
        }
        // -s / -es plural / 3rd-person omission (books -> book, watches -> watch, has -> have)
        if intent.hasSuffix("s") && (intent.dropLast(1) == literal || intent.dropLast(2) == literal) {
            return true
        }
        if (intent == "has" && literal == "have") || (intent == "is" && literal == "are") || (intent == "was" && literal == "were") {
            return true
        }
        // -ing omission (walking -> walk)
        if intent.hasSuffix("ing") && (intent.dropLast(3) == literal || intent.dropLast(1) == literal) {
            return true
        }
        return false
    }
    
    private static func isMinimalPair(intent: String, literal: String) -> Bool {
        if let variants = knownMinimalPairs[intent], variants.contains(literal) {
            return true
        }
        return false
    }
}
