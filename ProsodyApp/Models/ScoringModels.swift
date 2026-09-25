//
//  ResultsModels.swift
//  tts_coach
//
//  Created by Shafa Tiara on 26/06/26.
//


import SwiftUI

/// Lightweight, UI-only data types for the Results screen.

nonisolated enum PronunciationStatus: Equatable, Sendable {
    case good
    case needsWork
    case incorrect
    case uncertainTranscription

    var color: Color {
        switch self {
        case .good:                   return .green
        case .needsWork:              return .orange
        case .incorrect:             return .red
        case .uncertainTranscription: return .yellow
        }
    }
}

nonisolated struct ScoredWord: Identifiable, Sendable {
    let id = UUID()
    let text: String
    let status: PronunciationStatus
    var score: Int = 0
    var diagnosticInfo: String = ""
    var features: [Float]? = nil
    var sttConfidence: Float? = nil
    var isUncertainTranscription: Bool = false
    var candidateAlternatives: [String] = []
}

extension Array where Element == ScoredWord {
    /// Builds a word list from real practice text with every word marked `.good` —
    /// used as a safe fallback when no real scoring data is available.
    nonisolated static func allGood(from text: String) -> [ScoredWord] {
        text.split(separator: " ").map { ScoredWord(text: String($0), status: .good, score: 100) }
    }
}

nonisolated enum ErrorType: Equatable, Sendable {
    case none
    case substitution(expected: String, actual: String)
    case insertion(actual: String)
    case deletion(expected: String)
}

nonisolated struct PhonemeFeedback: Identifiable, Sendable {
    let id = UUID()
    let symbol: String
    let score: Int
    var errorType: ErrorType = .none
    var frames: Int = 0
    var heardSymbol: String? = nil
    var phoneMargin: Float = 0.0
    var targetMass: Float = 0.0
    var topCompetitorMass: Float = 0.0
    var topCompetitorSymbol: String = ""
    var posteriorMargin: Float = 0.0
    
    var status: PronunciationStatus {
        if errorType != .none { return .incorrect }
        return score >= STTSettings.currentPassingThreshold ? .good : score > 40 ? .needsWork : .incorrect
    }
}

nonisolated struct AlignedPhonemePair: Identifiable, Equatable, Sendable {
    let id = UUID()
    let expected: String?
    let heard: String?
    let score: Int
    let status: PronunciationStatus
    let errorType: ErrorType
    var note: String? = nil
}

nonisolated struct WordFeedbackItem: Identifiable, Sendable {
    let id = UUID()
    let word: String
    let status: PronunciationStatus
    let overallScore: Int
    let phonemes: [PhonemeFeedback]
    let startTime: TimeInterval?
    let endTime: TimeInterval?
    var expectedIpa: String = ""
    var heardIpa: String = ""
    var alignedPhonemes: [AlignedPhonemePair] = []
}

// MARK: - ScoringResult

/// The fully-mapped output of one `PronunciationScoringService.score()` call.
/// Carries everything the results screen and history need to render real data.
nonisolated struct ScoringResult: Sendable {
    let overallScore: Int              // 0 – 100 (average GOP × 100)
    let scoredWords: [ScoredWord]      // word-level coloured chips
    let feedbackItems: [WordFeedbackItem]  // word-level carousel cards with phonemes

    /// Safe fallback when scoring isn't available (model missing, audio error, etc.).
    /// Produces a result that looks like the old placeholder behaviour so the
    /// rest of the flow is unaffected.
    static func placeholder(for text: String) -> ScoringResult {
        ScoringResult(
            overallScore: 0,
            scoredWords: .allGood(from: text),
            feedbackItems: []
        )
    }
}

// MARK: - Sample data (previews / dev only)

extension Array where Element == ScoredWord {
    static let sampleRecordingWords: [ScoredWord] = [
        .init(text: "Lorem",       status: .good),
        .init(text: "ipsum",       status: .good),
        .init(text: "dolor",       status: .good),
        .init(text: "sit",         status: .good),
        .init(text: "amet",        status: .good),
        .init(text: "consectetur", status: .incorrect),
        .init(text: "adipiscing",  status: .needsWork),
        .init(text: "elit",        status: .good),
        .init(text: "sed",         status: .good),
        .init(text: "do",          status: .good),
        .init(text: "eiusmod",     status: .incorrect),
        .init(text: "tempor",      status: .good),
        .init(text: "incididunt",  status: .needsWork),
        .init(text: "ut",          status: .good),
        .init(text: "labore",      status: .good),
        .init(text: "et.",         status: .good)
    ]
}

extension Array where Element == WordFeedbackItem {
    static let sampleFeedback: [WordFeedbackItem] = [
        .init(word: "consectetur", status: .incorrect, overallScore: 45, phonemes: [
            .init(symbol: "k", score: 80),
            .init(symbol: "ə", score: 75),
            .init(symbol: "n", score: 85),
            .init(symbol: "s", score: 30),
            .init(symbol: "ɛ", score: 40),
            .init(symbol: "k", score: 50),
            .init(symbol: "t", score: 20),
            .init(symbol: "ə", score: 45),
            .init(symbol: "t", score: 30),
            .init(symbol: "ʊ", score: 80),
            .init(symbol: "r", score: 85)
        ], startTime: 0.5, endTime: 1.2),
        .init(word: "adipiscing", status: .needsWork, overallScore: 65, phonemes: [
            .init(symbol: "ə", score: 55),
            .init(symbol: "d", score: 65),
            .init(symbol: "ɪ", score: 70),
            .init(symbol: "p", score: 80),
            .init(symbol: "ɪ", score: 45),
            .init(symbol: "s", score: 85),
            .init(symbol: "ɪ", score: 60),
            .init(symbol: "ŋ", score: 75)
        ], startTime: 1.3, endTime: 2.0),
        .init(word: "eiusmod", status: .incorrect, overallScore: 40, phonemes: [
            .init(symbol: "i", score: 30),
            .init(symbol: "j", score: 40),
            .init(symbol: "u", score: 50),
            .init(symbol: "s", score: 25),
            .init(symbol: "m", score: 80),
            .init(symbol: "ɒ", score: 75),
            .init(symbol: "d", score: 85)
        ], startTime: 2.1, endTime: 2.8)
    ]
}

// MARK: - Fluency Evaluation

nonisolated struct WordTimestamp: Codable, Sendable {
    let word: String
    let startTime: TimeInterval
    let duration: TimeInterval
    var alignmentScore: Float = 1.0
    var endTime: TimeInterval { startTime + duration }
}

enum DisfluencyType: String, Codable, Sendable {
    case filledPause        // Vocalized hesitations ("um", "uh", "er", "ah", "mm")
    case repetition         // Exact single-word repetitions ("the the", "I I")
    case phraseRepetition   // Multi-word phrase repetitions ("in the in the")
    case falseStart         // Self-repair or restart ("he go- he went")
    case prolongation       // Prolonged sound / abnormal syllable stretching
}

enum PausePositionType: String, Codable, Sendable {
    case grammaticalClause  // Natural boundary: after punctuation, before conjunctions/relative pronouns
    case intraPhrase        // Hesitation: within tight constituents (det-noun, prep-noun, aux-verb, adj-noun)
    case sentenceBoundary   // Between complete sentences / terminal punctuation
    case unspecified        // Default / indeterminate
}

nonisolated struct PauseEvent: Identifiable, Sendable {
    let id = UUID()
    let startTime: TimeInterval
    let duration: TimeInterval
    let wordBefore: String
    let wordAfter: String
    var positionType: PausePositionType = .unspecified
    var isFilled: Bool = false
    var fillerToken: String? = nil
    var precedingPartOfSpeech: String? = nil
    var succeedingPartOfSpeech: String? = nil
}

nonisolated struct DisfluencyEvent: Identifiable, Sendable {
    let id = UUID()
    let type: DisfluencyType
    let word: String
    let startTime: TimeInterval
    let duration: TimeInterval
    let contextPhrase: String
}

nonisolated struct DisfluencyReport: Sendable {
    let fillerCount: Int
    let repetitionCount: Int
    let falseStartCount: Int
    let intraPhrasePauseCount: Int
    let grammaticalPauseCount: Int
    let totalDisfluencyCount: Int
    let disfluencyRatePerMinute: Float
    let intraPhrasePauseRatio: Float
    let events: [DisfluencyEvent]
    let annotatedTranscript: String
}

nonisolated struct FluencyFeedbackItem: Identifiable, Sendable {
    let id = UUID()
    let metric: String          // "Phonation", "Speech Rate", "Flow"
    let value: String           // "62%", "1.8 wps", "3.2 words/run"
    let message: String         // Human-readable feedback
    let status: PronunciationStatus  // Reuses existing enum
}

nonisolated struct FluencyResult: Sendable {
    let overallScore: Int                  // 0-100
    let speechRate: Float                  // words per second (total)
    let articulationRate: Float            // words per second (phonation only)
    let phonationTimeRatio: Float          // 0.0-1.0
    let meanLengthOfRun: Float             // avg words per run
    let pauseCount: Int
    let meanPauseDuration: Float           // seconds
    let pauseFrequencyPerMinute: Float     // pauses per minute
    let pauses: [PauseEvent]
    let feedback: [FluencyFeedbackItem]

    // Extended diagnostic metrics
    var maxPauseDuration: Float = 0.0         // longest single pause (seconds)
    var pauseDurationCV: Float = 0.0          // coefficient of variation of pause durations (stddev / mean)
    var wordDurationCV: Float = 0.0           // coefficient of variation of word durations (stddev / mean)
    var longPauseRatio: Float = 0.0           // fraction of pauses >= 500ms
    var maxLengthOfRun: Int = 0               // longest uninterrupted word run
    var runLengthCV: Float = 0.0              // coefficient of variation of run lengths
    var speechRateCV: Float = 0.0             // local rate variability (sliding 3-word window CV)
    var totalDuration: Float = 0.0            // total utterance duration (seconds)
    var meanAlignmentScore: Float = 1.0       // average CTC alignment confidence across words

    // Prosodic & acoustic dynamics
    var wordNPVI: Float = 0.0                 // Normalized Pairwise Variability Index across word durations
    var energyCV: Float = 0.0                 // Coefficient of variation of word-level RMS energy
    var pitchSemitoneStdDev: Float = 0.0      // Fundamental frequency (F0) variability in semitones
    var voicingRatio: Float = 0.0             // Fraction of periodic voiced frames in speech

    // Disfluency & syntactic structure
    var disfluencyReport: DisfluencyReport? = nil
    var fillerCount: Int = 0
    var repetitionCount: Int = 0
    var intraPhrasePauseRatio: Float = 0.0

    // Session-level temporal continuity
    var isSessionLevel: Bool = false
    var sessionSpeechRate: Float? = nil       // words per second across full elapsed session time (including inter-turn pauses)
    var sessionDuration: Float = 0.0          // total wall-clock duration including inter-turn pauses
    var phonationDuration: Float = 0.0        // cumulative vocalized phonation time across all utterances
    var interTurnPauseCount: Int = 0          // count of natural pauses occurring between turns
    var intraTurnPauseCount: Int = 0          // count of hesitation pauses occurring within turns
}

