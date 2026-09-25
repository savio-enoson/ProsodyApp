import Foundation
import FoundationModels

/// Returns the phoneme-level breakdown for a specific word spoken in the session.
/// The model should call this when it needs to discuss a particular word in detail.
struct GetWordPhonemeDetailTool: Tool {
    let name = "getWordPhonemeDetail"
    let description = "Returns the phoneme-level breakdown for a specific word spoken during the session. For each phoneme: the IPA symbol, the GOP score (0–100), the error type (none/substitution/deletion), and the expected vs. heard phoneme. Use this to explain exactly which sounds were wrong in a word."

    @Generable
    struct Arguments {
        @Guide(description: "The exact word to look up, in lowercase with no punctuation.")
        var word: String
    }

    let record: SessionRecord

    func call(arguments: Arguments) async throws -> String {
        let target = arguments.word.lowercased()
            .filter { $0.isLetter || $0.isNumber }

        // Find the lowest-scoring occurrence of this word (most pedagogically relevant)
        let matches = record.allFeedbackItems.filter {
            $0.word.lowercased().filter { $0.isLetter || $0.isNumber } == target
        }

        guard let item = matches.min(by: { $0.overallScore < $1.overallScore }) else {
            return "'\(arguments.word)' was not found in the session data."
        }

        var lines: [String] = []
        lines.append("Word: '\(item.word)' — overall score \(item.overallScore)% (\(item.status.label))")
        if !item.expectedIpa.isEmpty { lines.append("Expected IPA: \(item.expectedIpa)") }
        if !item.heardIpa.isEmpty    { lines.append("Heard IPA:    \(item.heardIpa)") }
        lines.append("")
        lines.append("Phoneme breakdown:")

        var lowScoringPhonemes: [String] = []
        var accuratePhonemes: [String] = []

        for phoneme in item.phonemes {
            let isVowel = DiscrepancyEngine.isVowelPhone(phoneme.symbol)
            let typeStr = isVowel ? "vowel" : "consonant"
            var line = "  /\(phoneme.symbol)/: \(phoneme.score)% (\(typeStr))"
            switch phoneme.errorType {
            case .substitution(let exp, let act):
                line += " [substitution: expected '\(exp)', heard '\(act)']"
            case .deletion(let exp):
                line += " [deletion: '\(exp)' omitted]"
            case .insertion(let act):
                line += " [insertion: '\(act)' extra]"
            case .none:
                break
            }
            lines.append(line)

            if phoneme.score < 60 || phoneme.errorType != .none {
                lowScoringPhonemes.append("/\(phoneme.symbol)/ (\(typeStr), \(phoneme.score)%)")
            } else if phoneme.score >= 65 {
                accuratePhonemes.append("/\(phoneme.symbol)/ (\(typeStr))")
            }
        }

        lines.append("")
        if !lowScoringPhonemes.isEmpty {
            lines.append("Needs attention: " + lowScoringPhonemes.joined(separator: ", "))
            if !accuratePhonemes.isEmpty {
                lines.append("Accurate sounds: " + accuratePhonemes.joined(separator: ", "))
            }
        } else {
            lines.append("All phonemes for this word scored in the clean/acceptable range.")
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - PronunciationStatus label helper

private extension PronunciationStatus {
    nonisolated var label: String {
        switch self {
        case .good:                   return "good"
        case .needsWork:              return "needs work"
        case .incorrect:             return "incorrect"
        case .uncertainTranscription: return "uncertain transcription"
        }
    }
}
