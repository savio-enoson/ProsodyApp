import Foundation
import FoundationModels

/// Returns an aggregate pronunciation overview: overall score, per-status word counts,
/// and the 5 lowest-scoring content words with their IPA detail.
struct GetPronunciationSummaryTool: Tool {
    let name = "getPronunciationSummary"
    let description = "Returns a summary of the learner's pronunciation performance: overall score (0–100), word-level status counts (good / needs-work / incorrect), and the 5 lowest-scoring words with their expected IPA and heard IPA. Call this first to get the big picture of pronunciation quality."

    @Generable
    struct Arguments {}

    let record: SessionRecord

    func call(arguments: Arguments) async throws -> String {
        let allWords = record.allFeedbackItems

        guard !allWords.isEmpty else {
            return "No pronunciation data available for this session."
        }

        let good      = allWords.filter { $0.status == .good }.count
        let needsWork = allWords.filter { $0.status == .needsWork }.count
        let incorrect = allWords.filter { $0.status == .incorrect }.count

        // 5 worst words by overallScore, excluding clean words
        let worst = allWords
            .filter { $0.status != .good }
            .sorted { $0.overallScore < $1.overallScore }
            .prefix(5)

        var lines: [String] = []
        lines.append("Overall pronunciation score: \(record.overallPronunciationScore)%")
        lines.append("Words scored — Good: \(good) | Needs Work: \(needsWork) | Incorrect: \(incorrect)")
        lines.append("Total words evaluated: \(allWords.count)")
        lines.append("")
        lines.append("Lowest-scoring words:")

        for item in worst {
            var line = "• '\(item.word)' — score \(item.overallScore)%"
            if !item.expectedIpa.isEmpty { line += ", expected: \(item.expectedIpa)" }
            if !item.heardIpa.isEmpty    { line += ", heard: \(item.heardIpa)" }
            lines.append(line)
        }

        if worst.isEmpty {
            lines.append("Pronunciation status: All evaluated words scored in the good range (no words require remediation). Praise the learner's clear pronunciation.")
        }

        return lines.joined(separator: "\n")
    }
}
