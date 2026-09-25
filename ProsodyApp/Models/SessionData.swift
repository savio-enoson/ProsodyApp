import Foundation

// MARK: - Session Data Models

/// Accumulates all data produced during one practice session.
/// A session may contain one or more spoken utterances.
/// This value type is passed by value into each coaching tool.
nonisolated struct SessionRecord: Sendable {
    /// The speaking prompt shown to the user at the start of the session.
    let prompt: String

    /// Ordered list of spoken utterances captured during the session.
    var utterances: [UtteranceRecord] = []

    // MARK: - Computed Aggregates

    var overallPronunciationScore: Int {
        let scores = utterances.compactMap { $0.scoringResult?.overallScore }
        guard !scores.isEmpty else { return 0 }
        return scores.reduce(0, +) / scores.count
    }

    /// Unified session-level fluency evaluated across the continuous session timeline.
    var sessionFluency: FluencyResult? {
        FluencyManager.shared.evaluateSession(utterances: utterances)
    }

    var overallFluencyScore: Int {
        if let sf = sessionFluency {
            return sf.overallScore
        }
        let scores = utterances.compactMap { $0.fluencyResult?.overallScore }
        guard !scores.isEmpty else { return 0 }
        return scores.reduce(0, +) / scores.count
    }

    /// All word timestamps across the entire session, placed in chronological session time.
    var allWordTimestamps: [WordTimestamp] {
        utterances.flatMap { u in
            let needsOffset = (u.wordTimestamps.first?.startTime ?? 0) < u.startTime && u.startTime > 0
            let offset = needsOffset ? u.startTime : 0.0
            return u.wordTimestamps.map { w in
                if offset > 0 {
                    return WordTimestamp(
                        word: w.word,
                        startTime: w.startTime + offset,
                        duration: w.duration,
                        alignmentScore: w.alignmentScore
                    )
                }
                return w
            }
        }.sorted(by: { $0.startTime < $1.startTime })
    }

    /// All pause events across the entire session (including natural inter-turn sentence/clause pauses).
    var allPauses: [PauseEvent] {
        if let sf = sessionFluency {
            return sf.pauses
        }
        return utterances.compactMap { $0.fluencyResult?.pauses }.flatMap { $0 }
    }

    /// All disfluency events across the entire session.
    var allDisfluencies: [DisfluencyEvent] {
        if let sf = sessionFluency, let d = sf.disfluencyReport {
            return d.events
        }
        return utterances.compactMap { $0.fluencyResult?.disfluencyReport?.events }.flatMap { $0 }
    }

    /// Count of mid-phrase (inappropriate) pause events across the session.
    var intraPhrasePauseCount: Int {
        allPauses.filter { $0.positionType == .intraPhrase }.count
    }

    /// Count of vocalized filled pauses across the session.
    var totalFillerCount: Int {
        if let sf = sessionFluency {
            return sf.fillerCount
        }
        return utterances.compactMap { $0.fluencyResult?.fillerCount }.reduce(0, +)
    }

    /// Count of word and phrase repetitions across the session.
    var totalRepetitionCount: Int {
        if let sf = sessionFluency {
            return sf.repetitionCount
        }
        return utterances.compactMap { $0.fluencyResult?.repetitionCount }.reduce(0, +)
    }

    /// All word-level feedback items across the entire session.
    var allFeedbackItems: [WordFeedbackItem] {
        utterances.compactMap { $0.scoringResult?.feedbackItems }.flatMap { $0 }
    }

    /// Combined verbatim transcript of all utterances.
    var fullTranscript: String {
        utterances.map(\.transcript)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// URL of the most recent utterance audio file captured in this session.
    var latestAudioURL: URL? {
        utterances.reversed().compactMap(\.audioURL).first
    }
}

// MARK: -

/// One spoken utterance captured within a session.
nonisolated struct UtteranceRecord: Sendable {
    /// Acoustic Mirror verbatim output — preserves learner errors.
    let transcript: String

    /// Pronunciation scoring result; nil if scoring failed or audio was too short.
    let scoringResult: ScoringResult?

    /// Fluency evaluation result; nil if fewer than 3 words were spoken.
    let fluencyResult: FluencyResult?

    /// Word timestamps from CTCSegmentation forced alignment.
    let wordTimestamps: [WordTimestamp]

    /// Local file URL to recorded mono 16kHz WAV audio for this utterance, if available.
    let audioURL: URL?

    /// Start timestamp in seconds from session onset.
    let startTime: TimeInterval

    /// End timestamp in seconds from session onset.
    let endTime: TimeInterval

    init(
        transcript: String,
        scoringResult: ScoringResult?,
        fluencyResult: FluencyResult?,
        wordTimestamps: [WordTimestamp],
        audioURL: URL? = nil,
        startTime: TimeInterval = 0.0,
        endTime: TimeInterval? = nil
    ) {
        self.transcript = transcript
        self.scoringResult = scoringResult
        self.fluencyResult = fluencyResult
        self.wordTimestamps = wordTimestamps
        self.audioURL = audioURL
        self.startTime = startTime
        let computedEnd = wordTimestamps.last?.endTime ?? (startTime + wordTimestamps.reduce(0.0) { $0 + $1.duration })
        self.endTime = endTime ?? max(startTime, computedEnd)
    }
}

// MARK: -

/// Interactive practice drill item generated dynamically by the AI Coach.
nonisolated public struct InteractiveDrillCard: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let targetWord: String
    public let contrastWord: String?
    public let focusPhoneme: String?
    public let practiceSentence: String
    public let articulatoryTip: String?
    public var audioURL: URL?
    public var isSynthesizing: Bool

    public init(
        id: UUID = UUID(),
        targetWord: String,
        contrastWord: String? = nil,
        focusPhoneme: String? = nil,
        practiceSentence: String,
        articulatoryTip: String? = nil,
        audioURL: URL? = nil,
        isSynthesizing: Bool = false
    ) {
        self.id = id
        self.targetWord = targetWord
        self.contrastWord = contrastWord
        self.focusPhoneme = focusPhoneme
        self.practiceSentence = practiceSentence
        self.articulatoryTip = articulatoryTip
        self.audioURL = audioURL
        self.isSynthesizing = isSynthesizing
    }
}

/// Interactive fluency and pacing drill generated dynamically by the AI Coach.
nonisolated public struct FluencyDrillCard: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let targetPhrase: String
    public let targetSpeed: Float             // target words per second (e.g. 2.0)
    public let pacingTip: String              // rhythm, linking, or chunking guidance
    public var audioURL: URL?                 // Golden Speaker demo at target speed
    public var isSynthesizing: Bool

    public init(
        id: UUID = UUID(),
        targetPhrase: String,
        targetSpeed: Float = 2.0,
        pacingTip: String,
        audioURL: URL? = nil,
        isSynthesizing: Bool = false
    ) {
        self.id = id
        self.targetPhrase = targetPhrase
        self.targetSpeed = targetSpeed
        self.pacingTip = pacingTip
        self.audioURL = audioURL
        self.isSynthesizing = isSynthesizing
    }
}
