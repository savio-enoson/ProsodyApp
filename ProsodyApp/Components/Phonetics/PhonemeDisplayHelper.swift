import Foundation

// MARK: - PhonemeDisplayHelper

/// Utility to translate raw phonetic data (IPA symbols, eSpeak tokens, aligned error pairs)
/// into friendly, human-readable explanations, anchor words, and articulatory tips.
nonisolated enum PhonemeDisplayHelper {

    // MARK: - Sound Name & Anchors

    /// Returns a learner-friendly label for an IPA symbol (e.g. "/θ/" → "\"th\" (soft / unvoiced)").
    static func friendlyName(for phoneme: String) -> String {
        if let info = PhonemeLexicon.shared.lookup(phoneme: phoneme) {
            return info.friendlyName
        }
        let clean = PhonemeLexicon.cleanToken(phoneme)
        return "/\(clean)/"
    }

    /// Returns a common everyday anchor word illustrating the target sound (e.g. "/θ/" → "think").
    static func anchorWord(for phoneme: String) -> String {
        if let info = PhonemeLexicon.shared.lookup(phoneme: phoneme) {
            return info.anchorWord
        }
        return ""
    }

    /// Returns a 1–2 sentence physical instruction on how to position the mouth, tongue, and voice.
    static func articulationTip(for phoneme: String) -> String {
        if let info = PhonemeLexicon.shared.lookup(phoneme: phoneme) {
            return info.articulationTip
        }
        return "Focus on clear, relaxed articulation."
    }

    /// Returns structured presentation details for a given phoneme symbol.
    static func soundGuide(for phoneme: String) -> (name: String, anchor: String, tip: String) {
        let name = friendlyName(for: phoneme)
        let anchor = anchorWord(for: phoneme)
        let tip = articulationTip(for: phoneme)
        return (name, anchor, tip)
    }

    // MARK: - Plain-English Error Descriptions

    /// Translates an `AlignedPhonemePair` into a clear, non-technical explanation of what occurred.
    static func errorDescription(for pair: AlignedPhonemePair, in word: String) -> String {
        switch pair.errorType {
        case .none:
            if let exp = pair.expected {
                let name = friendlyName(for: exp)
                if pair.score >= 70 {
                    return "Accurate pronunciation of the \(name) sound."
                } else {
                    return "The \(name) sound was understood, but could be clearer."
                }
            }
            return "Good pronunciation."

        case .substitution(let exp, let act):
            return contrastExplanation(expected: exp, heard: act, in: word)

        case .deletion(let exp):
            let expName = friendlyName(for: exp)
            let anchor = anchorWord(for: exp)
            let anchorHint = anchor.isEmpty ? "" : " (as in \"\(anchor)\")"
            return "The \(expName) sound\(anchorHint) was dropped from \"\(word)\"."

        case .insertion(let act):
            let actName = friendlyName(for: act)
            return "An extra \(actName) sound was inserted into \"\(word)\"."
        }
    }

    /// Translates a `PhonemeFeedback` item into a plain-English explanation.
    static func errorDescription(for feedback: PhonemeFeedback, in word: String) -> String {
        switch feedback.errorType {
        case .none:
            let name = friendlyName(for: feedback.symbol)
            if feedback.score >= 70 {
                return "Clear \(name) sound."
            } else if feedback.score >= 40 {
                return "The \(name) sound needs slight adjustment."
            } else {
                return "The \(name) sound was indistinct or unclear."
            }

        case .substitution(let exp, let act):
            return contrastExplanation(expected: exp, heard: act, in: word)

        case .deletion(let exp):
            let expName = friendlyName(for: exp)
            return "The \(expName) sound was omitted."

        case .insertion(let act):
            let actName = friendlyName(for: act)
            return "An extra \(actName) sound was spoken."
        }
    }

    /// Constructs a contrastive explanation between the intended sound and the heard sound.
    static func contrastExplanation(expected: String, heard: String, in word: String) -> String {
        let expName = friendlyName(for: expected)
        let heardName = friendlyName(for: heard)

        let expAnchor = anchorWord(for: expected)
        let heardAnchor = anchorWord(for: heard)

        var text = "Replaced \(expName)"
        if !expAnchor.isEmpty { text += " (as in \"\(expAnchor)\")" }
        text += " with \(heardName)"
        if !heardAnchor.isEmpty { text += " (as in \"\(heardAnchor)\")" }
        text += "."

        // Check if there is a known minimal pair to illustrate the contrast vividly
        let pairs = PhonemeLexicon.shared.findMinimalPairs(target: expected, contrast: heard)
        if let matchingPair = pairs.first(where: { $0.targetWord.lowercased() == word.lowercased() }) {
            text += " It sounded like \"\(matchingPair.contrastWord)\" instead of \"\(matchingPair.targetWord)\"."
        } else if let genericPair = pairs.first {
            text += " (Similar to saying \"\(genericPair.contrastWord)\" instead of \"\(genericPair.targetWord)\")."
        }

        return text
    }

    /// Formats a list of practice words into a clean display string.
    static func formatPracticeList(for phoneme: String, limit: Int = 4) -> [String] {
        PhonemeLexicon.shared.findWords(forPhoneme: phoneme, limit: limit)
    }
}
