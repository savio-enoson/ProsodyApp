import Foundation
import FoundationModels

/// Returns all fluency metrics for the session.
struct GetFluencyMetricsTool: Tool {
    let name = "getFluencyMetrics"
    let description = "Returns all fluency metrics for the session: overall score (0–100), speech rate, articulation rate, phonation-time ratio, mean length of run, pause metrics (count, mean/max duration, long pause ratio), rhythmic stability (word duration CV, speech rate CV, run length CV), per-utterance breakdown, and rule-based feedback. Always call this before making any fluency-related statements."

    @Generable
    struct Arguments {}

    let record: SessionRecord

    func call(arguments: Arguments) async throws -> String {
        guard !record.utterances.isEmpty else {
            return "No fluency data available. The session may have been too short (fewer than 3 words)."
        }

        let sf = record.sessionFluency
        let perUtteranceResults = record.utterances.compactMap { $0.fluencyResult }

        guard sf != nil || !perUtteranceResults.isEmpty else {
            return "No fluency data available. The session may have been too short (fewer than 3 words)."
        }

        let overallScore     = sf?.overallScore ?? record.overallFluencyScore
        let speechRate       = sf?.sessionSpeechRate ?? sf?.speechRate ?? (perUtteranceResults.map { $0.speechRate }.reduce(0, +) / Float(max(1, perUtteranceResults.count)))
        let articRate        = sf?.articulationRate ?? (perUtteranceResults.map { $0.articulationRate }.reduce(0, +) / Float(max(1, perUtteranceResults.count)))
        let ptr              = sf?.phonationTimeRatio ?? (perUtteranceResults.map { $0.phonationTimeRatio }.reduce(0, +) / Float(max(1, perUtteranceResults.count)))
        let mlr              = sf?.meanLengthOfRun ?? (perUtteranceResults.map { $0.meanLengthOfRun }.reduce(0, +) / Float(max(1, perUtteranceResults.count)))
        let pauses           = sf?.pauses ?? record.allPauses
        let totalPauses      = pauses.count
        let meanPauseDur     = sf?.meanPauseDuration ?? (pauses.isEmpty ? 0.0 : Float(pauses.reduce(0.0) { $0 + $1.duration }) / Float(pauses.count))
        let maxPauseDur      = sf?.maxPauseDuration ?? (pauses.map { Float($0.duration) }.max() ?? 0.0)
        let pauseFreq        = sf?.pauseFrequencyPerMinute ?? (sf != nil && sf!.totalDuration > 0 ? Float(totalPauses) / Float(sf!.totalDuration / 60.0) : 0.0)
        let longPauseRat     = sf?.longPauseRatio ?? (pauses.isEmpty ? 0.0 : Float(pauses.filter { $0.duration >= 0.5 }.count) / Float(pauses.count))
        let wordDurCV        = sf?.wordDurationCV ?? 0.35
        let rateCV           = sf?.speechRateCV ?? 0.25
        let runLengthCV      = sf?.runLengthCV ?? 0.40
        let wordNPVI         = sf?.wordNPVI ?? 58.0
        let energyCV         = sf?.energyCV ?? 0.35
        let pitchStdDev      = sf?.pitchSemitoneStdDev ?? 2.5
        let voicingRatio     = sf?.voicingRatio ?? 0.65

        let interTurnCount   = sf?.interTurnPauseCount ?? pauses.filter { $0.positionType == .sentenceBoundary || $0.positionType == .grammaticalClause }.count
        let intraPhraseCount = sf?.intraTurnPauseCount ?? pauses.filter { $0.positionType == .intraPhrase }.count

        var lines: [String] = [
            "Session Fluency & Temporal Metrics (computed across continuous session timeline):",
            "  Overall Fluency Score:         \(overallScore)%",
            "  Session Speech Rate:           \(String(format: "%.2f", speechRate)) words/sec (overall pace including natural pauses; reference: 1.4–2.5 wps)",
            "  Burst Articulation Rate:       \(String(format: "%.2f", articRate)) words/sec (pure phonation time without pauses; reference: 3.5–5.5 wps)",
            "  Phonation-Time Ratio:          \(Int(ptr * 100))% of session spent speaking (reference: 50%–70% natural flow)",
            "  Mean Length of Run:            \(String(format: "%.1f", mlr)) words per run (reference: >4.0 fluent, <2.0 fragmented)",
            "  Total Pauses Detected:         \(totalPauses) (\(interTurnCount) natural sentence/clause breaks, \(intraPhraseCount) intra-phrase hesitations)",
            "  Mean Pause Duration:           \(String(format: "%.2f", meanPauseDur)) seconds",
            "  Max Pause Duration:            \(String(format: "%.2f", maxPauseDur)) seconds",
            "  Pause Frequency:               \(String(format: "%.1f", pauseFreq)) pauses/minute",
            "  Long Pause Ratio (>=0.5s):     \(Int(longPauseRat * 100))%",
            "  Rhythm Variability (Word CV):  \(String(format: "%.2f", wordDurCV)) (natural stress variability)",
            "  Local Rate CV:                 \(String(format: "%.2f", rateCV)) (tempo consistency)",
            "  Run Length CV:                 \(String(format: "%.2f", runLengthCV)) (chunking uniformity)",
            "  Word nPVI (rhythm):            \(String(format: "%.1f", wordNPVI)) (stress rhythm contrast; English native ~55–70)",
            "  Energy Variability (CV):       \(String(format: "%.2f", energyCV)) (dynamic vocal volume contrast)",
            "  Pitch Variability (F0 ST):     \(String(format: "%.2f", pitchStdDev)) semitones (intonation expressiveness; native ~2.5–4.5)",
            "  Voicing Ratio:                 \(Int(voicingRatio * 100))% (voiced speech proportion)",
            "",
            "Reference ranges (L2 speech evaluation):",
            "  Session Speech Rate: 1.4–2.5 wps (natural pace), <1.0 wps (hesitant/slow), >3.0 wps (rushed)",
            "  Burst Articulation Rate: 3.5–5.5 wps (active speech velocity during phrases)",
            "  Phonation-Time Ratio: 50%–70% (natural conversational flow with breath pauses), <35% (excessive hesitation)",
            "  Mean Length of Run: >4.0 words (fluent phrasing), <2.0 (severely fragmented)",
            "  Max Pause Duration: <1.5s (natural transition), >2.5s (severe breakdown)"
        ]

        if perUtteranceResults.count > 1 {
            lines.append("")
            lines.append("Per-utterance burst breakdown:")
            for (idx, u) in record.utterances.enumerated() {
                if let f = u.fluencyResult {
                    lines.append("  Utterance \(idx + 1) [\(String(format: "%.1f", u.startTime))s - \(String(format: "%.1f", u.endTime))s]: score=\(f.overallScore)%, burstRate=\(String(format: "%.2f", f.speechRate)) wps, words=\(u.wordTimestamps.count), intraPauses=\(f.pauseCount)")
                }
            }
        }

        // Rule-based feedback items
        let feedbackItems = sf?.feedback ?? perUtteranceResults.flatMap { $0.feedback }
        if !feedbackItems.isEmpty {
            lines.append("")
            lines.append("Automated diagnostic observations:")
            for item in feedbackItems {
                let statusLabel = item.status == .good ? "GOOD" : (item.status == .needsWork ? "NEEDS_WORK" : "INCORRECT")
                lines.append("  [\(statusLabel)] \(item.metric): \(item.value) — \(item.message)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
