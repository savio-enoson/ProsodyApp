import Foundation

/// Standardized Manager singleton for speech fluency and temporal prosodic analysis.
final class FluencyManager {
    static let shared = FluencyManager()
    
    private init() {}
    
    /// Evaluates temporal and prosodic properties of speech (speaking rate, phonation ratio, pause frequency, pitch variability, rhythm, disfluencies)
    func evaluate(
        segments: [WordTimestamp],
        context: FluencyContext = .readingAloud,
        isChild: Bool = false,
        pitchZcr: Float = 0.0,
        audioChunk: [Float]? = nil,
        transcript: String? = nil,
        sfSpeechTranscript: String? = nil
    ) -> FluencyResult? {
        guard !segments.isEmpty else { return nil }
        return FluencyEngine.evaluate(
            segments: segments,
            context: context,
            isChild: isChild,
            pitchZcr: pitchZcr,
            audioChunk: audioChunk,
            transcript: transcript,
            sfSpeechTranscript: sfSpeechTranscript
        )
    }

    /// Evaluates temporal and prosodic properties of speech across an entire multi-turn practice session.
    func evaluateSession(
        utterances: [UtteranceRecord],
        sessionDuration: TimeInterval? = nil,
        context: FluencyContext = .readingAloud,
        isChild: Bool = false
    ) -> FluencyResult? {
        guard !utterances.isEmpty else { return nil }
        return FluencyEngine.evaluateSession(
            utterances: utterances,
            sessionDuration: sessionDuration,
            context: context,
            isChild: isChild
        )
    }
}
