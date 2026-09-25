import Foundation

/// Centralized app-wide configuration constants.
public enum AppConstants {

    // MARK: - Audio Configuration

    public enum Audio {
        /// Canonical sample rate for Wav2Vec2, Whisper, and phonetic inference (16 kHz).
        public static let standardSampleRate: Double = 16000.0
        /// Mono audio channel count.
        public static let monoChannelCount: UInt32 = 1
        /// Default VAD max silence frames before flush (~600ms at standard buffer cadence).
        public static let maxSilenceFrames: Int = 20
        /// Sliding window duration for speech chunks.
        public static let chunkSeconds: Float = 5.0
        /// Sliding window overlap duration.
        public static let overlapSeconds: Float = 1.5
    }

    // MARK: - Scoring & Remediation Thresholds

    public enum Scoring {
        /// Baseline score threshold for passing (good) pronunciation.
        public static let defaultPassingThreshold: Int = 65
        /// High proficiency threshold.
        public static let masteryThreshold: Int = 80
        /// Needs work lower threshold.
        public static let remediationThreshold: Int = 40
    }

    // MARK: - Fluency Reference Norms

    public enum Fluency {
        /// Adaptive pause duration floor (plosive closure margin).
        public static let minPauseThreshold: TimeInterval = 0.18
        /// Adaptive pause duration ceiling.
        public static let maxPauseThreshold: TimeInterval = 0.35
        /// Long pause threshold indicating significant formulation breakdown.
        public static let longPauseThreshold: TimeInterval = 0.50
        /// Typical L2 speech rate lower bound in words per second.
        public static let minSpeechRate: Float = 1.0
        /// Normal conversational speech rate upper bound in words per second.
        public static let maxSpeechRate: Float = 2.5
    }
}
