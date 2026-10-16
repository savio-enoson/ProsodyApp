import Foundation

/// Reconciles consecutive utterance transcripts and word timestamps when an emergency
/// sliding-window turn split occurs, removing duplicate prefix words emitted across the boundary.
final class WordOverlapDeduplicator: Sendable {

    /// Deduplicates head transcript by identifying matching suffix tokens from the previous turn's tail.
    ///
    /// - Parameters:
    ///   - tailTranscript: The transcript of the preceding turn (Chunk N).
    ///   - headTranscript: The raw transcript of the continuation turn (Chunk N+1).
    ///   - maxOverlapWords: Maximum token lookback window (default 14 words, covering ~2.5s of speech).
    /// - Returns: The deduplicated continuation transcript and number of dropped duplicate tokens.
    static func deduplicateText(
        tailTranscript: String,
        headTranscript: String,
        maxOverlapWords: Int = 14
    ) -> (dedupedHead: String, droppedWordCount: Int) {
        let tailTokens = tailTranscript.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let headTokens = headTranscript.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        let maxCheck = min(maxOverlapWords, tailTokens.count, headTokens.count)
        guard maxCheck > 0 else { return (headTranscript, 0) }

        func clean(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        let cleanTail = tailTokens.map(clean)
        let cleanHead = headTokens.map(clean)

        for l in stride(from: maxCheck, through: 1, by: -1) {
            let tailSub = Array(cleanTail.suffix(l))
            let headSub = Array(cleanHead.prefix(l))

            // Exact token match
            if tailSub == headSub {
                let remaining = headTokens.dropFirst(l)
                return (remaining.joined(separator: " "), l)
            }

            // Approximate match for sequences of 3+ words: allow at most 1 minor ASR deviation
            if l >= 3 {
                var diffCount = 0
                for i in 0..<l {
                    if tailSub[i] != headSub[i] {
                        diffCount += 1
                    }
                }
                if diffCount <= 1 {
                    let remaining = headTokens.dropFirst(l)
                    return (remaining.joined(separator: " "), l)
                }
            }
        }

        return (headTranscript, 0)
    }

    /// Deduplicates word timestamp arrays across sliding-window continuation boundaries.
    static func deduplicateTimestamps(
        tailTimestamps: [WordTimestamp],
        headTimestamps: [WordTimestamp],
        maxOverlapWords: Int = 14
    ) -> [WordTimestamp] {
        guard !tailTimestamps.isEmpty, !headTimestamps.isEmpty else { return headTimestamps }

        let tailWords = tailTimestamps.map { $0.word }
        let headWords = headTimestamps.map { $0.word }

        let (_, droppedCount) = deduplicateText(
            tailTranscript: tailWords.joined(separator: " "),
            headTranscript: headWords.joined(separator: " "),
            maxOverlapWords: maxOverlapWords
        )

        if droppedCount > 0 && droppedCount < headTimestamps.count {
            return Array(headTimestamps.dropFirst(droppedCount))
        }

        return headTimestamps
    }
}
