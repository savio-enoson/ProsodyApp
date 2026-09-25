import Foundation
import FoundationModels

/// FoundationModels Tool allowing the AI Coach to analyze the Acoustic Mirror's verbatim transcript
/// for grammatical structure, phrasing naturalness, and distinguishing acoustic coda elisions
/// from syntactic habits.
struct AnalyzeGrammarAndSyntaxTool: Tool {
    let name = "analyzeGrammarAndSyntax"
    let description = "Analyzes the session's verbatim transcript to evaluate grammatical accuracy, natural phrasing, and structural differences. Use this to separate acoustic elisions (e.g. dropping a final 's' or 'ed' sound) from underlying grammatical patterns (e.g. subject-verb agreement or missing articles), providing constructive native reformulations."

    @Generable
    struct Arguments {
        @Guide(description: "Optional specific sentence or phrase from the session transcript to analyze. If omitted, analyzes the full session transcript.")
        var phrase: String?

        init(phrase: String? = nil) {
            self.phrase = phrase
        }
    }

    let record: SessionRecord

    init(record: SessionRecord) {
        self.record = record
    }

    func call(arguments: Arguments) async throws -> String {
        let transcript = record.fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return "No transcript is available in the session record to analyze."
        }

        let targetText = arguments.phrase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? transcript
        print(">>> [TOOL INVOKED] analyzeGrammarAndSyntax(phrase: \"\(targetText)\")")

        var lines: [String] = []
        lines.append("Acoustic Mirror Verbatim Text: \"\(targetText)\"")
        lines.append("")
        lines.append("Analysis Guidelines for the Coach:")
        lines.append("1. The Acoustic Mirror preserves learner speech verbatim — it never autocorrects.")
        lines.append("2. Distinguish between:")
        lines.append("   - Acoustic/Phonetic Elision: The learner knows the grammar, but dropped word-final consonants (e.g. '-s' on plural nouns or '-ed' on past verbs) due to pronunciation habits.")
        lines.append("   - Syntactic/Grammatical Usage: Subject-verb agreement (e.g. 'he have' vs 'he has'), auxiliary verb omissions ('she going' vs 'she is going'), or article omission ('in city' vs 'in the city').")
        lines.append("3. Affirm the learner's spoken effort while providing a natural, native English reformulation in your response.")

        return lines.joined(separator: "\n")
    }
}
