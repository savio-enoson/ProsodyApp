import Foundation
import CoreML

/// Standardized Manager singleton for phonetic GOP scoring, 1:1 alignment, and pronunciation evaluation.
final class PhonemeScoringManager {
    static let shared = PhonemeScoringManager()
    
    let scoringService: PhonemeScoringService
    let espeak = EspeakManager.shared
    
    private init() {
        let sttEngine = MainActor.assumeIsolated {
            STTManager.shared.inference
        }
        self.scoringService = PhonemeScoringService(inferenceEngine: sttEngine)
    }
    
    /// Synchronous initialization for CLI and multi-worker batch evaluation harnesses
    init(inferenceEngine: InferenceEngine) {
        self.scoringService = PhonemeScoringService(inferenceEngine: inferenceEngine)
    }
    
    /// Score audio against expected target and acoustic mirror transcripts
    func scoreAudio(
        _ audioChunk: [Float],
        transcript: String,
        literalTranscript: String,
        sfSpeechTranscript: String,
        snappedTranscript: String = "",
        whisperTranscript: String = "",
        scoringReference: String? = nil,
        ttsAudio: [Float]? = nil,
        userSegments: [WordTimestamp] = [],
        ttsSegments: [WordTimestamp] = [],
        cachedTtsProbs: (probs: [Float], frames: Int, vocabSize: Int)? = nil,
        hiddenStates: MLMultiArray? = nil,
        isChild: Bool = false,
        userVerified: Bool = false,
        sttLogProbs: [[Float]]? = nil
    ) -> ScoringResult? {
        return scoringService.scoreAudio(
            audioChunk,
            transcript: transcript,
            literalTranscript: literalTranscript,
            sfSpeechTranscript: sfSpeechTranscript,
            snappedTranscript: snappedTranscript,
            whisperTranscript: whisperTranscript,
            scoringReference: scoringReference,
            ttsAudio: ttsAudio,
            userSegments: userSegments,
            ttsSegments: ttsSegments,
            cachedTtsProbs: cachedTtsProbs,
            hiddenStates: hiddenStates,
            isChild: isChild,
            userVerified: userVerified,
            sttLogProbs: sttLogProbs
        )
    }
}
