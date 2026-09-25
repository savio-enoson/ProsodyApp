import Foundation
import FoundationModels

/// Searches the English pronunciation lexicon for common practice words and minimal-pair drills
/// containing a specific phoneme sound. The AI coach should call this tool when recommending
/// targeted drills for phonemes the learner mispronounced.
struct FindWordsWithPhonemeTool: Tool {
    let name = "findWordsWithPhoneme"
    let description = "Searches the English pronunciation lexicon for common everyday practice words and minimal-pair contrast drills containing a specific phoneme sound (e.g. 'θ', 'ð', 'æ', 'ʃ', 'tʃ', 'dʒ', 'l', 'r', or respellings like 'th', 'sh', 'ch', 'ng', 'short a'). Use this to provide grounded practice words and minimal pairs for sounds the learner struggled with."

    @Generable
    struct Arguments {
        @Guide(description: "The phoneme symbol (IPA like 'θ', 'ð', 'æ', 'ʃ', 'tʃ', or friendly respellings like 'th', 'sh', 'ch', 'ng', 'short a') to search for.")
        var phoneme: String

        @Guide(description: "Optional position in the word: 'initial' (start of word), 'medial' (middle of word), 'final' (end of word), or 'any'. Defaults to 'any'.")
        var position: String?

        @Guide(description: "Maximum number of practice words to return (1 to 10). Defaults to 5.")
        var limit: Int?

        init(phoneme: String = "", position: String? = nil, limit: Int? = nil) {
            self.phoneme = phoneme
            self.position = position
            self.limit = limit
        }
    }

    func call(arguments: Arguments) async throws -> String {
        print(">>> [TOOL INVOKED] findWordsWithPhoneme(phoneme: \"\(arguments.phoneme)\", position: \"\(arguments.position ?? "any")\", limit: \(arguments.limit ?? 5))")
        let phonemeQuery = arguments.phoneme
        guard let info = PhonemeLexicon.shared.lookup(phoneme: phonemeQuery) else {
            print(">>> [TOOL RESULT] No lexicon entry for '\(phonemeQuery)'")
            return "No lexicon entry found for sound '\(phonemeQuery)'. Try using an IPA symbol (e.g. 'θ', 'ð', 'æ', 'ʃ') or common respelling (e.g. 'th', 'sh', 'ch', 'ng')."
        }

        var lines: [String] = []
        lines.append("Sound: \(info.friendlyName) [IPA: /\(info.symbol)/]")
        lines.append("Anchor word: \"\(info.anchorWord)\"")
        lines.append("How to pronounce: \(info.articulationTip)")
        lines.append("")

        let posEnum: WordPosition
        if let p = arguments.position?.lowercased() {
            switch p {
            case "initial", "start", "beginning":
                posEnum = .initial
            case "medial", "middle":
                posEnum = .medial
            case "final", "end":
                posEnum = .final
            default:
                posEnum = .any
            }
        } else {
            posEnum = .any
        }

        let wordLimit = min(10, max(1, arguments.limit ?? 5))
        let words = PhonemeLexicon.shared.findWords(forPhoneme: info.symbol, position: posEnum, limit: wordLimit)

        if posEnum != .any {
            lines.append("Practice words (\(posEnum.rawValue) position): \(words.joined(separator: ", "))")
        } else {
            lines.append("Practice words: \(words.joined(separator: ", "))")
            if !info.initialWords.isEmpty {
                lines.append("  • Start of word: \(info.initialWords.prefix(4).joined(separator: ", "))")
            }
            if !info.medialWords.isEmpty {
                lines.append("  • Middle of word: \(info.medialWords.prefix(4).joined(separator: ", "))")
            }
            if !info.finalWords.isEmpty {
                lines.append("  • End of word: \(info.finalWords.prefix(4).joined(separator: ", "))")
            }
        }

        if !info.minimalPairs.isEmpty {
            lines.append("")
            lines.append("Recommended Minimal-Pair Drills:")
            for pair in info.minimalPairs.prefix(3) {
                let contrastName = PhonemeDisplayHelper.friendlyName(for: pair.contrastPhoneme)
                lines.append("  • \"\(pair.targetWord)\" (/\(pair.targetPhoneme)/) vs. \"\(pair.contrastWord)\" (/\(pair.contrastPhoneme)/ — \(contrastName))")
            }
        }

        return lines.joined(separator: "\n")
    }
}
