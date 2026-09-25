import Foundation
import FoundationModels

/// Returns the list of all detected pauses in the session with their duration,
/// severity classification, and the words immediately surrounding each pause.
struct GetPauseDetailTool: Tool {
    let name = "getPauseDetail"
    let description = "Returns the list of all detected pauses in the session with severity classifications ([NORMAL] <0.4s, [MODERATE] 0.4-0.8s, [LONG] >=0.8s). For each pause: its duration in seconds, the word spoken immediately before it, and the word spoken immediately after. Use this to identify where the learner hesitates and to coach on specific pause patterns."

    @Generable
    struct Arguments {}

    let record: SessionRecord

    func call(arguments: Arguments) async throws -> String {
        let pauses = record.allPauses

        guard !pauses.isEmpty else {
            return "No pauses detected in this session (or session was too short to evaluate)."
        }

        var lines: [String] = ["Detected pauses (\(pauses.count) total):"]

        for (i, pause) in pauses.enumerated() {
            let severity: String
            if pause.duration >= 0.8 {
                severity = "LONG (>=0.8s)"
            } else if pause.duration >= 0.4 {
                severity = "MODERATE (0.4-0.8s)"
            } else {
                severity = "NORMAL (<0.4s)"
            }

            let positionDesc: String
            switch pause.positionType {
            case .intraPhrase:
                let beforePos = pause.precedingPartOfSpeech ?? "Word"
                let afterPos = pause.succeedingPartOfSpeech ?? "Word"
                positionDesc = "[INTRA-PHRASE HESITATION — \(beforePos) → \(afterPos)]"
            case .sentenceBoundary:
                positionDesc = "[SENTENCE BOUNDARY]"
            case .grammaticalClause:
                positionDesc = "[GRAMMATICAL CLAUSE BOUNDARY]"
            case .unspecified:
                positionDesc = "[PHRASE BOUNDARY]"
            }

            let fillDesc = pause.isFilled ? " [VOCALIZED FILLER: '\(pause.fillerToken ?? "vocalized")']" : ""

            let line = "  \(i + 1). \(String(format: "%.2f", pause.duration))s — after '\(pause.wordBefore)' before '\(pause.wordAfter)' [\(severity)] \(positionDesc)\(fillDesc)"
            lines.append(line)
        }

        let totalDuration = pauses.map { $0.duration }.reduce(0, +)
        let longest = pauses.max(by: { $0.duration < $1.duration })
        let longCount = pauses.filter { $0.duration >= 0.8 }.count
        let moderateCount = pauses.filter { $0.duration >= 0.4 && $0.duration < 0.8 }.count
        let normalCount = pauses.filter { $0.duration < 0.4 }.count
        let intraPhraseCount = pauses.filter { $0.positionType == .intraPhrase }.count
        let grammaticalCount = pauses.filter { $0.positionType == .grammaticalClause || $0.positionType == .sentenceBoundary }.count
        let filledCount = pauses.filter { $0.isFilled }.count

        lines.append("")
        lines.append("Summary:")
        lines.append("  Total pause time: \(String(format: "%.2f", totalDuration)) seconds")
        lines.append("  Duration profile: \(longCount) long, \(moderateCount) moderate, \(normalCount) normal")
        lines.append("  Syntactic placement: \(intraPhraseCount) intra-phrase hesitations (awkward gaps inside word groups), \(grammaticalCount) grammatical boundaries")
        if filledCount > 0 {
            lines.append("  Vocalized filled pauses: \(filledCount) pause(s) had vocalized hesitation/groan")
        }
        if let longest {
            lines.append("  Longest pause: \(String(format: "%.2f", longest.duration))s after '\(longest.wordBefore)' before '\(longest.wordAfter)'")
        }

        return lines.joined(separator: "\n")
    }
}
