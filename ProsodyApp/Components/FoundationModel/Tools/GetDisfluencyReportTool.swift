import Foundation
import FoundationModels

/// Returns a comprehensive disfluency report for the session, detailing filled pauses ("um"/"uh"),
/// word and phrase repetitions, false starts, and syntactic pause placement (intra-phrase vs. clause boundary).
struct GetDisfluencyReportTool: Tool {
    let name = "getDisfluencyReport"
    let description = "Returns the session's disfluency analysis: count and timing of filled pauses ('um', 'uh', 'er'), exact word/phrase repetitions, false starts, and syntactic pause placement (intra-phrase hesitation vs. natural clause boundary). Call this to assess speech continuity, self-repair frequency, and formulation difficulties."

    @Generable
    struct Arguments {}

    let record: SessionRecord

    func call(arguments: Arguments) async throws -> String {
        let reports = record.utterances.compactMap { $0.fluencyResult?.disfluencyReport }

        guard !reports.isEmpty else {
            return "No disfluency data available. The session may have been too short (fewer than 3 words)."
        }

        let totalFillers = reports.map(\.fillerCount).reduce(0, +)
        let totalRepetitions = reports.map(\.repetitionCount).reduce(0, +)
        let totalFalseStarts = reports.map(\.falseStartCount).reduce(0, +)
        let totalIntraPhrase = reports.map(\.intraPhrasePauseCount).reduce(0, +)
        let totalGrammatical = reports.map(\.grammaticalPauseCount).reduce(0, +)
        let totalDisfluencies = reports.map(\.totalDisfluencyCount).reduce(0, +)

        let allEvents = reports.flatMap(\.events)
        let totalPauses = totalIntraPhrase + totalGrammatical
        let overallIntraPhraseRatio = totalPauses > 0 ? Float(totalIntraPhrase) / Float(totalPauses) : 0.0

        var lines: [String] = [
            "Session Disfluency & Speech Continuity Report:",
            "  Total disfluency events:       \(totalDisfluencies)",
            "  Vocalized filled pauses:       \(totalFillers) ('um', 'uh', vocalized hesitations)",
            "  Word & phrase repetitions:     \(totalRepetitions)",
            "  False starts / self-repairs:   \(totalFalseStarts)",
            "  Intra-phrase pauses (awkward): \(totalIntraPhrase) (pauses between closely connected words)",
            "  Grammatical clause pauses:     \(totalGrammatical) (pauses at punctuation or clause boundaries)",
            "  Intra-phrase pause ratio:      \(Int(overallIntraPhraseRatio * 100))% of all pauses",
            "",
            "Pedagogical Assessment & Reference Norms:",
            "  - Intra-phrase pause ratio: <20% is typical; >40% indicates lexical access or formulation difficulty.",
            "  - Vocalized fillers: <2 per minute is natural; excessive fillers indicate search for vocabulary.",
            "  - Repetitions: indicate real-time self-monitoring and difficulty completing syntactic constituents."
        ]

        if !allEvents.isEmpty {
            lines.append("")
            lines.append("Detailed Disfluency Events:")
            for (idx, event) in allEvents.prefix(10).enumerated() {
                let typeLabel: String
                switch event.type {
                case .filledPause: typeLabel = "FILLED PAUSE"
                case .repetition: typeLabel = "REPETITION"
                case .phraseRepetition: typeLabel = "PHRASE REPETITION"
                case .falseStart: typeLabel = "FALSE START"
                case .prolongation: typeLabel = "PROLONGATION"
                }
                lines.append("  \(idx + 1). [\(typeLabel)] '\(event.word)' at \(String(format: "%.2f", event.startTime))s (\(String(format: "%.2f", event.duration))s) — Context: \"\(event.contextPhrase)\"")
            }
        }

        // Annotated transcript
        let annotatedSnippets = reports.map(\.annotatedTranscript).filter { !$0.isEmpty }
        if !annotatedSnippets.isEmpty {
            lines.append("")
            lines.append("Annotated Verbatim Transcript (with disfluency markers):")
            for (idx, snippet) in annotatedSnippets.enumerated() {
                lines.append("  Turn \(idx + 1): \"\(snippet)\"")
            }
        }

        return lines.joined(separator: "\n")
    }
}
