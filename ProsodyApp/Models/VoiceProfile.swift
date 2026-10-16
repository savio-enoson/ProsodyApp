import Foundation

/// Target dialect/accent for English pronunciation practice.
public enum TargetAccentDialect: String, CaseIterable, Identifiable, Codable, Sendable {
    case generalAmerican = "us"
    case britishRP = "uk"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .generalAmerican:
            return "General American (US)"
        case .britishRP:
            return "British English (UK)"
        }
    }

    public var voicePrefix: String {
        switch self {
        case .generalAmerican:
            return "a"
        case .britishRP:
            return "b"
        }
    }
}

/// Learner voice profile tracking on-device acoustic vocal timbre and fundamental pitch.
nonisolated public struct LearnerVoiceProfile: Codable, Sendable, Equatable {
    /// 128-dimensional acoustic style vector extracted by StyleEncoder.
    public var timbreEmbedding: [Float]

    /// Estimated median fundamental frequency in Hertz.
    public var estimatedF0: Float

    /// Total count of valid spoken turns integrated into this profile.
    public var sampleCount: Int

    /// Timestamp when this profile was last refreshed.
    public var lastUpdated: Date

    public init(
        timbreEmbedding: [Float],
        estimatedF0: Float,
        sampleCount: Int = 1,
        lastUpdated: Date = Date()
    ) {
        self.timbreEmbedding = timbreEmbedding
        self.estimatedF0 = estimatedF0
        self.sampleCount = sampleCount
        self.lastUpdated = lastUpdated
    }

    /// Descriptive vocal register based on fundamental pitch.
    public var registerDescription: String {
        if estimatedF0 <= 0 {
            return "Unknown"
        } else if estimatedF0 < 155.0 {
            return "Low / Masculine (\(Int(round(estimatedF0))) Hz)"
        } else if estimatedF0 > 165.0 {
            return "High / Feminine (\(Int(round(estimatedF0))) Hz)"
        } else {
            return "Intermediate (\(Int(round(estimatedF0))) Hz)"
        }
    }
}

/// Outcome of intelligent base template voice matching.
nonisolated public struct VoiceTemplateMatch: Sendable, Equatable {
    public let voiceId: String
    public let displayName: String
    public let cosineSimilarity: Float
    public let matchedRegister: String
    public let accentDialect: TargetAccentDialect

    public init(
        voiceId: String,
        displayName: String,
        cosineSimilarity: Float,
        matchedRegister: String,
        accentDialect: TargetAccentDialect
    ) {
        self.voiceId = voiceId
        self.displayName = displayName
        self.cosineSimilarity = cosineSimilarity
        self.matchedRegister = matchedRegister
        self.accentDialect = accentDialect
    }
}
