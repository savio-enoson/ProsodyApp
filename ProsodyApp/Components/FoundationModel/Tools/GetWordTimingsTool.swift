import Foundation
import FoundationModels

/// Returns per-word start time and duration for every word in the session,
/// derived from CTCSegmentation forced alignment.
struct GetWordTimingsTool: Tool {
    let name = "getWordTimings"
    let description = "Returns the start time (seconds from utterance start) and duration (seconds) for every word in the session, as computed by CTCSegmentation forced alignment. Use this to discuss pacing, syllable stretching, or to identify which parts of the utterance were rushed or drawn out."

    @Generable
    struct Arguments {}

    let record: SessionRecord

    func call(arguments: Arguments) async throws -> String {
        let timestamps = record.allWordTimestamps

        guard !timestamps.isEmpty else {
            return "No word timing data available for this session."
        }

        var lines: [String] = ["Word timings (\(timestamps.count) words):"]

        for ts in timestamps {
            let wordPad = "'\(ts.word)'".padding(toLength: 22, withPad: " ", startingAt: 0)
            let line = "  \(wordPad)  start: \(String(format: "%5.2f", ts.startTime))s  duration: \(String(format: "%.2f", ts.duration))s"
            lines.append(line)
        }

        let durations = timestamps.map { $0.duration }
        let avgDuration = durations.reduce(0, +) / Double(durations.count)
        let maxWord = timestamps.max(by: { $0.duration < $1.duration })
        let minWord = timestamps.min(by: { $0.duration < $1.duration })

        lines.append("")
        lines.append("Average word duration: \(String(format: "%.2f", avgDuration))s")
        if let maxWord {
            lines.append("Longest word: '\(maxWord.word)' at \(String(format: "%.2f", maxWord.duration))s")
        }
        if let minWord {
            lines.append("Shortest word: '\(minWord.word)' at \(String(format: "%.2f", minWord.duration))s")
        }

        return lines.joined(separator: "\n")
    }
}
