import Foundation
import Combine

/// Standardized Manager singleton for session lifecycle, turn aggregation, and diagnostic evaluation.
@MainActor
final class SessionEvaluationManager: ObservableObject {
    static let shared = SessionEvaluationManager()

    // MARK: - Published State
    @Published private(set) var currentSession: SessionRecord? = nil
    @Published private(set) var isSessionActive: Bool = false
    @Published private(set) var isEvaluating: Bool = false

    private init() {}

    private var sessionStartTime: CFAbsoluteTime = 0.0

    // MARK: - Session Lifecycle

    /// Begins a new speaking session with an assigned practice prompt.
    func startSession(prompt: String = "") {
        currentSession = SessionRecord(prompt: prompt)
        isSessionActive = true
        sessionStartTime = CFAbsoluteTimeGetCurrent()
    }

    /// Appends an utterance result to the active practice session with optional timeline offsets.
    func recordUtterance(
        transcript: String,
        scoringResult: ScoringResult?,
        fluencyResult: FluencyResult?,
        wordTimestamps: [WordTimestamp] = [],
        audioURL: URL? = nil,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil
    ) {
        guard isSessionActive else { return }
        if currentSession == nil {
            currentSession = SessionRecord(prompt: "")
            sessionStartTime = CFAbsoluteTimeGetCurrent()
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - sessionStartTime
        let durationEstimate = wordTimestamps.last?.endTime ?? 3.0
        let actualStart = startTime ?? max(0.0, elapsed - durationEstimate)
        let actualEnd = endTime ?? max(actualStart, elapsed)

        let record = UtteranceRecord(
            transcript: transcript,
            scoringResult: scoringResult,
            fluencyResult: fluencyResult,
            wordTimestamps: wordTimestamps,
            audioURL: audioURL,
            startTime: actualStart,
            endTime: actualEnd
        )
        currentSession?.utterances.append(record)
    }

    /// Finalizes the active practice session and returns the aggregated record.
    @discardableResult
    func finishSession() -> SessionRecord? {
        isSessionActive = false
        return currentSession
    }

    /// Resets the current session state.
    func resetSession() {
        currentSession = nil
        isSessionActive = false
        isEvaluating = false
    }
}
