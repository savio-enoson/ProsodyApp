import Foundation
import SwiftUI
import Combine
import AVFoundation

/// Practice prompt mode options.
enum PracticePromptMode: Int, CaseIterable, Identifiable {
    case conversation = 0
    case artReflection = 1
    case voiceCloner = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .conversation: return "Conversation Prompt"
        case .artReflection: return "Art & Reflection"
        case .voiceCloner: return "Voice Cloner Sandbox"
        }
    }
}

/// Retains granular acoustic and timing metadata for an individual utterance turn (bit-by-bit chunk).
struct TurnEvaluationRecord: Identifiable {
    let id = UUID()
    let turnIndex: Int
    var audioChunk: [Float]
    var audioURL: URL?
    var transcript: String
    var literalTranscript: String
    var sfSpeechTranscript: String
    var whisperTranscript: String
    var wordTimestamps: [WordTimestamp]
    var logProbs: [[Float]]?
    var timeRange: (start: TimeInterval, end: TimeInterval)?
    var scoringResult: ScoringResult?
    var fluencyResult: FluencyResult?
    var words: [TranscriptWord]
}

/// ViewModel managing state and business logic for the main practice workflow.
@MainActor
final class ContentViewModel: ObservableObject {

    // MARK: - Subsystem Singletons
    let audioManager = AudioManager.shared
    let sttManager = STTManager.shared
    let fluencyManager = FluencyManager.shared
    let phonemeManager = PhonemeScoringManager.shared
    let sessionManager = SessionEvaluationManager.shared
    let ttsManager = TTSManager.shared
    let promptService = PromptGeneratorService.shared
    let artPromptService = ArtPromptService.shared

    // MARK: - Persistent Coaching Session
    @Published var coachingSessionService = CoachingSessionService()

    // MARK: - Presentation State
    @Published var selectedPromptMode: PracticePromptMode = .conversation
    @Published var committedTranscript: String = ""
    @Published var whisperTranscript: String = ""
    @Published var editableTranscriptText: String = ""
    @Published var isDirectEditing: Bool = false
    @Published var transcriptWords: [TranscriptWord] = []

    @Published var scoringResult: ScoringResult? = nil
    @Published var fluencyResult: FluencyResult? = nil
    @Published var isScoring: Bool = false

    @Published var showingSettings: Bool = false
    @Published var showingCoaching: Bool = false
    @Published var showingPermissionAlert: Bool = false
    @Published var isFinishingSession: Bool = false

    // MARK: - Granular Bit-by-Bit Turn Records
    @Published var turnRecords: [TurnEvaluationRecord] = []

    // MARK: - Test Sample Streaming State
    @Published var isTestStreaming: Bool = false
    @Published var testStreamingStatus: String = ""
    private var testStreamingTask: Task<Void, Never>? = nil

    // MARK: - Model Loading State
    @Published var isModelLoading: Bool = true

    // MARK: - Debounced Re-evaluation State
    @Published var reevaluationCountdown: Int = 0
    @Published var isReevaluating: Bool = false
    @Published var lastAudioChunk: [Float]? = nil
    @Published var lastLiteralTranscript: String = ""
    @Published var lastSFSpeechTranscript: String = ""
    @Published var lastWordTimings: [WordTimestamp] = []
    @Published var lastLogProbs: [[Float]]? = nil

    private var reevaluationTask: Task<Void, Never>? = nil
    private var cancellables = Set<AnyCancellable>()

    public init() {
        bindAudioObservations()
        bindModelLoadingObservations()
        updateModelLoadingState()
    }

    // MARK: - Engine Observation Bindings

    private func bindModelLoadingObservations() {
        sttManager.inference.$modelState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateModelLoadingState()
            }
            .store(in: &cancellables)

        ttsManager.$isEngineReady
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateModelLoadingState()
            }
            .store(in: &cancellables)

        ttsManager.$loadFailed
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateModelLoadingState()
            }
            .store(in: &cancellables)

        ttsManager.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateModelLoadingState()
            }
            .store(in: &cancellables)

        promptService.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        NemotronSTTService.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateModelLoadingState()
            }
            .store(in: &cancellables)
    }

    private func bindAudioObservations() {
        // When speech activity ceases, process accumulated audio chunk
        audioManager.$isSpeaking
            .dropFirst()
            .sink { [weak self] speaking in
                guard let self = self else { return }
                if !speaking {
                    if let chunk = self.audioManager.currentAudioChunk {
                        if self.sttManager.settings.engineType == .nemotron {
                            Task {
                                if let res = try? await NemotronSTTService.shared.finishStreaming() {
                                    self.executeScoringPipeline(
                                        chunk: chunk,
                                        overrideTranscript: res.transcript,
                                        overrideTimestamps: res.wordTimings
                                    )
                                } else {
                                    self.sttManager.inference.process(audioChunk: chunk, sfSpeechHint: self.audioManager.liveTranscript)
                                }
                            }
                        } else {
                            self.sttManager.inference.process(audioChunk: chunk, sfSpeechHint: self.audioManager.liveTranscript)
                        }
                    }
                } else {
                    self.scoringResult = nil
                    self.fluencyResult = nil
                    self.sttManager.inference.latestTranscript = ""
                    self.sttManager.inference.latestFormattedTranscript = ""
                    if self.sttManager.settings.engineType == .nemotron {
                        try? NemotronSTTService.shared.startStreaming(language: "en-US")
                    }
                }
            }
            .store(in: &cancellables)

        // Stream partial audio for live preview
        audioManager.$liveAudioChunk
            .compactMap { $0 }
            .sink { [weak self] chunk in
                guard let self = self else { return }
                if self.sttManager.settings.engineType == .nemotron {
                    Task {
                        _ = try? await NemotronSTTService.shared.feedLiveAudio(chunk: chunk)
                    }
                }
                self.sttManager.inference.processLive(audioChunk: chunk)
            }
            .store(in: &cancellables)

        // Forward live transcript updates from Nemotron
        NemotronSTTService.shared.$liveTranscript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // When inference finishes, execute scoring pipeline
        sttManager.inference.$isProcessing
            .dropFirst()
            .sink { [weak self] processing in
                guard let self = self else { return }
                if !processing && !self.sttManager.inference.latestTranscript.isEmpty {
                    if let chunk = self.audioManager.currentAudioChunk {
                        self.executeScoringPipeline(chunk: chunk)
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Pipeline Execution

    func processUtteranceTurn(
        chunk: [Float],
        transcriptToScore: String,
        literalToScore: String,
        formattedToCommit: String,
        wordTimestampsToUse: [WordTimestamp],
        logProbsToUse: [[Float]]?,
        sfSpeechToScore: String = "",
        timeRange: (start: TimeInterval, end: TimeInterval)? = nil
    ) async {
        isScoring = true
        lastAudioChunk = chunk

        // Silently update learner voice profile in background from natural practice turn
        ttsManager.updateLearnerProfile(from: chunk)

        self.lastLiteralTranscript = literalToScore
        self.lastSFSpeechTranscript = sfSpeechToScore
        self.lastWordTimings = wordTimestampsToUse
        self.lastLogProbs = logProbsToUse

        // Extract active prompt context for prompt-conditioned decoding (Strategy 7)
        let activePromptContext: String? = {
            switch self.selectedPromptMode {
            case .conversation:
                let p = self.promptService.currentPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
                return p.isEmpty ? nil : p
            case .artReflection:
                let t = self.artPromptService.currentArtwork.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            case .voiceCloner:
                return nil
            }
        }()

        var effectiveTranscript = transcriptToScore
        var effectiveTimestamps = wordTimestampsToUse

        // Run Nemotron model on Core AI for dual ASR cross-check and accurate neural transcription
        var nemotronResultText = ""
        do {
            let nemotronResult = try await NemotronSTTService.shared.transcribe(
                audioFloats: chunk,
                language: "en-US"
            )
            nemotronResultText = nemotronResult.transcript
            if STTSettings.shared.engineType == .nemotron && !nemotronResult.transcript.isEmpty {
                effectiveTranscript = nemotronResult.transcript
                if !nemotronResult.wordTimings.isEmpty {
                    effectiveTimestamps = nemotronResult.wordTimings
                    self.lastWordTimings = effectiveTimestamps
                }
            }
        } catch {
            print("Nemotron Core AI transcription failed: \(error)")
        }

        let fluency = fluencyManager.evaluate(
            segments: effectiveTimestamps,
            isChild: STTSettings.shared.isChildLearnerMode,
            audioChunk: chunk,
            transcript: effectiveTranscript,
            sfSpeechTranscript: sfSpeechToScore
        )

        // Intent vs. Realization Reconciliation (Dual-Stream Acoustic Mirror):
        // Reconciles intended semantic words with verbatim acoustic realizations.
        let intentSource = !nemotronResultText.isEmpty ? nemotronResultText : (activePromptContext ?? effectiveTranscript)
        let reconciled = IntentRealizationReconciler.reconcile(
            intent: intentSource,
            literal: literalToScore,
            fallbackTranscript: effectiveTranscript
        )

        let scoringRef: String? = (reconciled.scoringReference != reconciled.displayTranscript) ? reconciled.scoringReference : nil
        let displayTranscriptToUse = reconciled.displayTranscript.isEmpty ? effectiveTranscript : reconciled.displayTranscript

        let secondaryNeuralTranscript = (STTSettings.shared.engineType == .nemotron && !nemotronResultText.isEmpty)
            ? transcriptToScore
            : nemotronResultText

        let result = phonemeManager.scoreAudio(
            chunk,
            transcript: displayTranscriptToUse,
            literalTranscript: literalToScore,
            sfSpeechTranscript: sfSpeechToScore,
            whisperTranscript: secondaryNeuralTranscript,
            scoringReference: scoringRef,
            userSegments: effectiveTimestamps,
            isChild: STTSettings.shared.isChildLearnerMode,
            sttLogProbs: logProbsToUse
        )

        let newTurnFormatted = formattedToCommit.isEmpty ? displayTranscriptToUse : formattedToCommit

        // Align and score words for this specific utterance turn with its acoustic metadata
        let turnWords = TranscriptDiffEngine.align(
            primary: newTurnFormatted,
            alternative: secondaryNeuralTranscript,
            sfSpeech: sfSpeechToScore,
            literal: literalToScore,
            timestamps: effectiveTimestamps
        )

        // Drop overlapping words from previous turn if any using WordOverlapDeduplicator
        let uniqueTurnWords: [TranscriptWord]
        var finalResult = result
        var finalTimestamps = effectiveTimestamps
        if let lastRecord = self.turnRecords.last, !turnWords.isEmpty {
            let tailText = lastRecord.transcript
            let headText = turnWords.map(\.cleanWord).joined(separator: " ")
            let (_, droppedCount) = WordOverlapDeduplicator.deduplicateText(tailTranscript: tailText, headTranscript: headText)
            if droppedCount > 0 && droppedCount < turnWords.count {
                uniqueTurnWords = Array(turnWords.dropFirst(droppedCount))
                if droppedCount < finalTimestamps.count {
                    finalTimestamps = Array(finalTimestamps.dropFirst(droppedCount))
                }
                if let r = result {
                    let dedupedScored = Array(r.scoredWords.dropFirst(min(droppedCount, r.scoredWords.count)))
                    let dedupedFeedback = Array(r.feedbackItems.dropFirst(min(droppedCount, r.feedbackItems.count)))
                    let overall = dedupedScored.isEmpty ? r.overallScore : (dedupedScored.map(\.score).reduce(0, +) / dedupedScored.count)
                    finalResult = ScoringResult(
                        overallScore: overall,
                        scoredWords: dedupedScored,
                        feedbackItems: dedupedFeedback
                    )
                }
            } else {
                uniqueTurnWords = turnWords
            }
        } else {
            uniqueTurnWords = turnWords
        }

        let audioURL = self.saveTemporaryWAV(samples: chunk)
        let record = TurnEvaluationRecord(
            turnIndex: self.turnRecords.count,
            audioChunk: chunk,
            audioURL: audioURL,
            transcript: uniqueTurnWords.map(\.text).joined(separator: " "),
            literalTranscript: literalToScore,
            sfSpeechTranscript: sfSpeechToScore,
            whisperTranscript: secondaryNeuralTranscript,
            wordTimestamps: finalTimestamps,
            logProbs: logProbsToUse,
            timeRange: timeRange,
            scoringResult: finalResult,
            fluencyResult: fluency,
            words: uniqueTurnWords
        )
        self.turnRecords.append(record)

        self.transcriptWords = self.turnRecords.flatMap(\.words)
        self.committedTranscript = self.transcriptWords.map(\.text).joined(separator: " ")
        self.editableTranscriptText = self.committedTranscript

        if self.whisperTranscript.isEmpty {
            self.whisperTranscript = nemotronResultText
        } else if !nemotronResultText.isEmpty {
            self.whisperTranscript = self.mergeOverlappingStrings(self.whisperTranscript, nemotronResultText)
        }

        self.updateCompositeResults()
        self.isScoring = false

        // Accumulate turn into active session
        if sessionManager.isSessionActive {
            sessionManager.recordUtterance(
                transcript: newTurnFormatted,
                scoringResult: result,
                fluencyResult: fluency,
                wordTimestamps: effectiveTimestamps,
                audioURL: audioURL,
                startTime: timeRange?.start,
                endTime: timeRange?.end
            )
        }

        if self.isFinishingSession {
            self.isFinishingSession = false
            self.sessionManager.finishSession()
            self.showingCoaching = true
        }
    }

    private func executeScoringPipeline(
        chunk: [Float],
        overrideTranscript: String? = nil,
        overrideTimestamps: [WordTimestamp]? = nil
    ) {
        let transcript = overrideTranscript ?? sttManager.inference.latestTranscript
        let literal = sttManager.inference.latestLiteralTranscript
        let formatted = overrideTranscript ?? sttManager.inference.latestFormattedTranscript
        let timestamps = overrideTimestamps ?? sttManager.inference.wordTimestamps ?? []
        let logProbs = sttManager.inference.latestLogProbs
        let sfSpeech = audioManager.liveTranscript
        let timeRange = audioManager.lastChunkTimeRange

        sttManager.inference.latestTranscript = ""
        sttManager.inference.latestLiteralTranscript = ""
        sttManager.inference.latestFormattedTranscript = ""

        Task {
            await self.processUtteranceTurn(
                chunk: chunk,
                transcriptToScore: transcript,
                literalToScore: literal,
                formattedToCommit: formatted,
                wordTimestampsToUse: timestamps,
                logProbsToUse: logProbs,
                sfSpeechToScore: sfSpeech,
                timeRange: timeRange
            )
        }
    }

    // MARK: - Test Sample Streaming

    func cancelTestSample() {
        testStreamingTask?.cancel()
        testStreamingTask = nil
        isTestStreaming = false
        testStreamingStatus = ""
    }

    func runTestSample() {
        guard !isTestStreaming, !audioManager.isRecording, !isModelLoading else { return }

        guard let sampleURL = findTestSampleURL() else {
            print("[TestSample] 'savio.wav' not found.")
            return
        }

        let targetPrompt = "Read the rainbow passage aloud in a clear and calm voice"

        // 1. Configure mode & session
        selectedPromptMode = .conversation
        promptService.currentPrompt = targetPrompt
        sessionManager.resetSession()
        coachingSessionService.endSession()
        sessionManager.startSession(prompt: targetPrompt)

        turnRecords = []
        committedTranscript = ""
        whisperTranscript = ""
        editableTranscriptText = ""
        transcriptWords = []
        scoringResult = nil
        fluencyResult = nil
        isTestStreaming = true
        testStreamingStatus = "Loading savio.wav..."

        testStreamingTask = Task {
            do {
                let audio = try VoiceClonerNativeEngine.shared.loadAudioAt16kHz(url: sampleURL)
                guard !audio.isEmpty else {
                    await MainActor.run {
                        self.isTestStreaming = false
                        self.testStreamingStatus = ""
                    }
                    return
                }

                let turns = StreamingVoiceEvaluator.segmentStreamingTurns(audio: audio, sampleRate: 16000)
                guard !turns.isEmpty else {
                    await MainActor.run {
                        self.isTestStreaming = false
                        self.testStreamingStatus = ""
                    }
                    return
                }

                for (idx, turn) in turns.enumerated() {
                    if Task.isCancelled { break }

                    await MainActor.run {
                        self.testStreamingStatus = "Streaming turn \(idx + 1) of \(turns.count)..."
                    }

                    guard let decoded = self.sttManager.inference.processSynchronously(
                        audioChunk: turn.samples,
                        reference: nil
                    ) else {
                        continue
                    }

                    if Task.isCancelled { break }

                    let formatted = PunctuationTransferEngine.shared.transferPunctuation(
                        acousticText: decoded.snapped,
                        sfSpeechText: nil
                    )

                    await self.processUtteranceTurn(
                        chunk: turn.samples,
                        transcriptToScore: decoded.snapped,
                        literalToScore: decoded.literal,
                        formattedToCommit: formatted,
                        wordTimestampsToUse: decoded.wordTimestamps,
                        logProbsToUse: decoded.logProbs,
                        sfSpeechToScore: "",
                        timeRange: (start: turn.startTime, end: turn.endTime)
                    )

                    // Short progressive pause for UI reactivity
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }

                if Task.isCancelled {
                    await MainActor.run {
                        self.isTestStreaming = false
                        self.testStreamingStatus = ""
                    }
                    return
                }

                // Finalize session and open AI Coaching Review sheet
                await MainActor.run {
                    self.testStreamingStatus = "Finalizing session & AI Coach..."
                    self.sessionManager.finishSession()
                    self.isTestStreaming = false
                    self.testStreamingStatus = ""
                    self.showingCoaching = true
                }
            } catch {
                print("[TestSample] Failed to stream: \(error)")
                await MainActor.run {
                    self.isTestStreaming = false
                    self.testStreamingStatus = ""
                }
            }
        }
    }

    private func findTestSampleURL() -> URL? {
        if let bundleURL = Bundle.main.url(forResource: "savio", withExtension: "wav") {
            return bundleURL
        }
        if let bundleSubURL = Bundle.main.url(forResource: "savio", withExtension: "wav", subdirectory: "VoiceResources") {
            return bundleSubURL
        }
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent("VoiceResources/savio.wav"),
           FileManager.default.fileExists(atPath: resURL.path) {
            return resURL
        }
        let relativePaths = [
            "VoiceResources/savio.wav",
            "../VoiceResources/savio.wav",
            "../../VoiceResources/savio.wav"
        ]
        for rel in relativePaths {
            let url = URL(fileURLWithPath: rel)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        let absolutePath = "/Users/vio/PycharmProjects/ProsodyEnglish/VoiceResources/savio.wav"
        if FileManager.default.fileExists(atPath: absolutePath) {
            return URL(fileURLWithPath: absolutePath)
        }
        return nil
    }

    // MARK: - User Intent Actions

    func onToggleListening() {
        if audioManager.isRecording {
            audioManager.stopListening()
        } else {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        if !self.sessionManager.isSessionActive {
                            self.turnRecords = []
                            self.sessionManager.resetSession()
                            self.coachingSessionService.endSession()
                            let assignedPrompt = self.selectedPromptMode == .conversation
                                ? self.promptService.currentPrompt
                                : self.artPromptService.currentArtwork.title
                            self.sessionManager.startSession(prompt: assignedPrompt)
                        }
                        self.audioManager.startListening()
                    } else {
                        self.showingPermissionAlert = true
                    }
                }
            }
        }
    }

    func onFinishSession() {
        if audioManager.isRecording {
            isFinishingSession = true
            audioManager.stopListening()
        } else if isScoring {
            isFinishingSession = true
        } else {
            sessionManager.finishSession()
            showingCoaching = true
        }
    }

    func prewarm() {
        sttManager.prewarm()
        ttsManager.prewarm()
        Task {
            await NemotronSTTService.shared.initializeIfNeeded()
            promptService.prewarm()
            await promptService.generate()
        }
    }

    // MARK: - Word Swap & Debounced Re-evaluation

    func swapWord(id: UUID, with newWord: String) {
        guard let index = transcriptWords.firstIndex(where: { $0.id == id }) else { return }
        swapWord(at: index, with: newWord)
    }

    func swapWord(at index: Int, with newWord: String) {
        guard index >= 0 && index < transcriptWords.count else { return }

        var targetTurnIdx: Int? = nil
        var localWordIdx: Int? = nil

        if !turnRecords.isEmpty {
            var running = 0
            for tIdx in 0..<turnRecords.count {
                let count = turnRecords[tIdx].words.count
                if index < running + count {
                    targetTurnIdx = tIdx
                    localWordIdx = index - running
                    break
                }
                running += count
            }
        }

        if let tIdx = targetTurnIdx, let lIdx = localWordIdx {
            let origWord = turnRecords[tIdx].words[lIdx].text
            var replacement = newWord
            if let lastPunct = origWord.last, CharacterSet.punctuationCharacters.contains(lastPunct.unicodeScalars.first!), !newWord.hasSuffix(String(lastPunct)) {
                replacement += String(lastPunct)
            }
            turnRecords[tIdx].words[lIdx].text = replacement
            turnRecords[tIdx].words[lIdx].cleanWord = TranscriptWord.clean(replacement)
            turnRecords[tIdx].words[lIdx].userVerified = true
            turnRecords[tIdx].words[lIdx].isUncertain = false
            turnRecords[tIdx].words[lIdx].alternative = nil
            turnRecords[tIdx].transcript = turnRecords[tIdx].words.map(\.text).joined(separator: " ")

            transcriptWords[index] = turnRecords[tIdx].words[lIdx]
        } else {
            transcriptWords[index].text = newWord
            transcriptWords[index].cleanWord = TranscriptWord.clean(newWord)
            transcriptWords[index].userVerified = true
            transcriptWords[index].isUncertain = false
            transcriptWords[index].alternative = nil
        }

        let updatedFullText = transcriptWords.map(\.text).joined(separator: " ")
        committedTranscript = updatedFullText
        editableTranscriptText = updatedFullText
        reevaluationTask?.cancel()
        reevaluationCountdown = 0
        performReevaluation()
    }

    func onEditableTextChanged(to newText: String) {
        committedTranscript = newText
        scheduleReevaluation()
    }

    func commitDirectEdit() {
        reevaluationTask?.cancel()
        reevaluationCountdown = 0
        isDirectEditing = false
        committedTranscript = editableTranscriptText

        // Synchronously update transcriptWords and turnRecords so UI changes instantly
        applyEditedTextImmediately(editableTranscriptText)

        // Trigger background re-evaluation for phonetic and fluency recalculation
        performReevaluation()
    }

    /// Synchronously applies direct edit modifications to in-memory word structures.
    private func applyEditedTextImmediately(_ newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            transcriptWords = []
            return
        }

        let editedRawWords = trimmed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        if turnRecords.isEmpty {
            let oldWordsMap = Dictionary(transcriptWords.map { ($0.cleanWord, $0) }, uniquingKeysWith: { first, _ in first })
            self.transcriptWords = editedRawWords.map { raw in
                let clean = TranscriptWord.clean(raw)
                if let existing = oldWordsMap[clean] {
                    var w = existing
                    w.text = raw
                    return w
                } else {
                    return TranscriptWord(
                        text: raw,
                        alternative: nil,
                        confidence: 1.0,
                        isUncertain: false,
                        candidates: [],
                        userVerified: true
                    )
                }
            }
            return
        }

        let partitioned = partitionEditedWords(
            editedWords: editedRawWords,
            turnRecords: turnRecords
        )

        for tIdx in 0..<turnRecords.count {
            let turnWordStrings = partitioned[tIdx]
            let oldTurnWords = turnRecords[tIdx].words
            let oldWordsMap = Dictionary(oldTurnWords.map { ($0.cleanWord, $0) }, uniquingKeysWith: { first, _ in first })

            let updatedTurnWords: [TranscriptWord] = turnWordStrings.map { raw in
                let clean = TranscriptWord.clean(raw)
                if let existing = oldWordsMap[clean] {
                    var w = existing
                    w.text = raw
                    return w
                } else {
                    return TranscriptWord(
                        text: raw,
                        alternative: nil,
                        confidence: 1.0,
                        isUncertain: false,
                        candidates: [],
                        userVerified: true
                    )
                }
            }

            turnRecords[tIdx].words = updatedTurnWords
            turnRecords[tIdx].transcript = updatedTurnWords.map(\.text).joined(separator: " ")
        }

        self.transcriptWords = turnRecords.flatMap(\.words)
    }

    func scheduleReevaluation() {
        guard lastAudioChunk != nil || !turnRecords.isEmpty else { return }
        reevaluationTask?.cancel()
        reevaluationCountdown = 5

        reevaluationTask = Task {
            for second in stride(from: 5, through: 1, by: -1) {
                if Task.isCancelled { return }
                self.reevaluationCountdown = second
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if Task.isCancelled { return }
            self.reevaluationCountdown = 0
            self.performReevaluation()
        }
    }

    func performReevaluation() {
        guard !committedTranscript.isEmpty else { return }
        isReevaluating = true
        reevaluationCountdown = 0

        Task {
            let editedText = self.committedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            let editedWords = editedText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

            if self.turnRecords.isEmpty {
                // Single-chunk fallback (e.g. if turnRecords was not populated)
                if let chunk = self.lastAudioChunk {
                    let userSegmentsToUse = self.lastWordTimings
                    let fluency = self.fluencyManager.evaluate(
                        segments: userSegmentsToUse,
                        isChild: STTSettings.shared.isChildLearnerMode,
                        audioChunk: chunk,
                        transcript: editedText,
                        sfSpeechTranscript: self.lastSFSpeechTranscript
                    )

                    let result = self.phonemeManager.scoreAudio(
                        chunk,
                        transcript: editedText,
                        literalTranscript: self.lastLiteralTranscript,
                        sfSpeechTranscript: self.lastSFSpeechTranscript,
                        whisperTranscript: self.whisperTranscript,
                        scoringReference: editedText,
                        userSegments: userSegmentsToUse,
                        isChild: STTSettings.shared.isChildLearnerMode,
                        userVerified: true,
                        sttLogProbs: self.lastLogProbs
                    )

                    let reParsedWords = TranscriptDiffEngine.align(
                        primary: editedText,
                        alternative: self.whisperTranscript,
                        sfSpeech: self.lastSFSpeechTranscript,
                        literal: self.lastLiteralTranscript,
                        timestamps: userSegmentsToUse
                    )

                    self.transcriptWords = reParsedWords
                    self.fluencyResult = fluency
                    self.scoringResult = result
                }
                self.isReevaluating = false
                return
            }

            // Proper chunk-by-chunk, bit-by-bit parsing & re-evaluation for modified turns
            let partitioned = self.partitionEditedWords(
                editedWords: editedWords,
                turnRecords: self.turnRecords
            )

            for tIdx in 0..<self.turnRecords.count {
                let turn = self.turnRecords[tIdx]
                let newTurnWords = partitioned[tIdx]
                let newTurnText = newTurnWords.joined(separator: " ")
                let lastScoredWords = turn.scoringResult?.scoredWords.map(\.text).joined(separator: " ") ?? ""

                let cleanCurrent = TranscriptWord.clean(newTurnText)
                let cleanScored = TranscriptWord.clean(lastScoredWords)

                if cleanCurrent != cleanScored {
                    var turnWords = TranscriptDiffEngine.align(
                        primary: newTurnText,
                        alternative: turn.whisperTranscript,
                        sfSpeech: turn.sfSpeechTranscript,
                        literal: turn.literalTranscript,
                        timestamps: turn.wordTimestamps
                    )

                    let oldVerifiedClean = Set(turn.words.filter(\.userVerified).map(\.cleanWord))
                    for wIdx in 0..<turnWords.count {
                        if oldVerifiedClean.contains(turnWords[wIdx].cleanWord) {
                            turnWords[wIdx].userVerified = true
                            turnWords[wIdx].isUncertain = false
                        }
                    }

                    let fluency = self.fluencyManager.evaluate(
                        segments: turn.wordTimestamps,
                        isChild: STTSettings.shared.isChildLearnerMode,
                        audioChunk: turn.audioChunk,
                        transcript: newTurnText,
                        sfSpeechTranscript: turn.sfSpeechTranscript
                    )

                    let scoreResult = self.phonemeManager.scoreAudio(
                        turn.audioChunk,
                        transcript: newTurnText,
                        literalTranscript: turn.literalTranscript,
                        sfSpeechTranscript: turn.sfSpeechTranscript,
                        whisperTranscript: turn.whisperTranscript,
                        scoringReference: newTurnText,
                        userSegments: turn.wordTimestamps,
                        isChild: STTSettings.shared.isChildLearnerMode,
                        userVerified: true,
                        sttLogProbs: turn.logProbs
                    )

                    self.turnRecords[tIdx].transcript = newTurnText
                    self.turnRecords[tIdx].words = turnWords
                    self.turnRecords[tIdx].scoringResult = scoreResult
                    self.turnRecords[tIdx].fluencyResult = fluency

                    self.sessionManager.updateUtterance(
                        at: tIdx,
                        transcript: newTurnText,
                        scoringResult: scoreResult,
                        fluencyResult: fluency
                    )
                }
            }

            // Reconstruct full transcript words
            self.transcriptWords = self.turnRecords.flatMap(\.words)
            self.committedTranscript = self.transcriptWords.map(\.text).joined(separator: " ")
            self.editableTranscriptText = self.committedTranscript
            self.updateCompositeResults()
            self.isReevaluating = false
        }
    }

    /// Partitions an edited word stream across multiple turn records using sequence alignment.
    private func partitionEditedWords(
        editedWords: [String],
        turnRecords: [TurnEvaluationRecord]
    ) -> [[String]] {
        guard !turnRecords.isEmpty else { return [] }
        if turnRecords.count == 1 {
            return [editedWords]
        }

        var origWords: [String] = []
        var wordToTurn: [Int] = []
        for (tIdx, turn) in turnRecords.enumerated() {
            for w in turn.words {
                origWords.append(TranscriptWord.clean(w.text))
                wordToTurn.append(tIdx)
            }
        }

        let cleanEdited = editedWords.map { TranscriptWord.clean($0) }
        let m = origWords.count
        let n = cleanEdited.count

        guard m > 0 else {
            var buckets = Array(repeating: [String](), count: turnRecords.count)
            buckets[0] = editedWords
            return buckets
        }

        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = (origWords[i - 1] == cleanEdited[j - 1]) ? 0 : 1
                dp[i][j] = min(dp[i - 1][j] + 1, min(dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost))
            }
        }

        var i = m
        var j = n
        enum AlignOp {
            case match(orig: Int, edit: Int)
            case insert(edit: Int)
            case delete(orig: Int)
        }
        var ops: [AlignOp] = []

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && dp[i][j] == dp[i - 1][j - 1] + ((origWords[i - 1] == cleanEdited[j - 1]) ? 0 : 1) {
                ops.append(.match(orig: i - 1, edit: j - 1))
                i -= 1
                j -= 1
            } else if j > 0 && dp[i][j] == dp[i][j - 1] + 1 {
                ops.append(.insert(edit: j - 1))
                j -= 1
            } else if i > 0 {
                ops.append(.delete(orig: i - 1))
                i -= 1
            } else {
                break
            }
        }
        ops.reverse()

        var assignedTurns = Array(repeating: 0, count: n)
        var lastTurn = 0
        for op in ops {
            switch op {
            case .match(let origIdx, let editIdx):
                let t = wordToTurn[origIdx]
                assignedTurns[editIdx] = t
                lastTurn = t
            case .insert(let editIdx):
                assignedTurns[editIdx] = lastTurn
            case .delete(let origIdx):
                lastTurn = wordToTurn[origIdx]
            }
        }

        var turnBuckets = Array(repeating: [String](), count: turnRecords.count)
        for (editIdx, word) in editedWords.enumerated() {
            let t = max(0, min(turnRecords.count - 1, assignedTurns[editIdx]))
            turnBuckets[t].append(word)
        }

        return turnBuckets
    }

    /// Aggregates turn-level evaluation results into unified presentation properties.
    func updateCompositeResults() {
        let allScoredWords = turnRecords.compactMap { $0.scoringResult?.scoredWords }.flatMap { $0 }
        let allFeedbackItems = turnRecords.compactMap { $0.scoringResult?.feedbackItems }.flatMap { $0 }
        let scores = turnRecords.compactMap { $0.scoringResult?.overallScore }
        let overall = scores.isEmpty ? 0 : (scores.reduce(0, +) / scores.count)

        if !allScoredWords.isEmpty || !allFeedbackItems.isEmpty {
            self.scoringResult = ScoringResult(
                overallScore: overall,
                scoredWords: allScoredWords,
                feedbackItems: allFeedbackItems
            )
        }

        if let sessionRec = sessionManager.currentSession, let sf = sessionRec.sessionFluency {
            self.fluencyResult = sf
        } else if let lastFluency = turnRecords.last?.fluencyResult {
            self.fluencyResult = lastFluency
        }
    }

    // MARK: - Helpers

    func updateModelLoadingState() {
        if case .failed = sttManager.inference.modelState {
            self.isModelLoading = false
            return
        }
        if ttsManager.loadFailed || ttsManager.errorMessage != nil {
            self.isModelLoading = (sttManager.inference.modelState == .loading)
            return
        }
        let nemotronLoading: Bool
        if case .loading = NemotronSTTService.shared.state {
            nemotronLoading = true
        } else {
            nemotronLoading = false
        }
        self.isModelLoading = (sttManager.inference.modelState == .loading || !ttsManager.isEngineReady || nemotronLoading)
    }

    var activeLiveTranscript: String {
        if audioManager.isSpeaking {
            if sttManager.settings.engineType == .nemotron {
                let nLive = NemotronSTTService.shared.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !nLive.isEmpty { return nLive }
            }
            if !audioManager.liveTranscript.isEmpty {
                return audioManager.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return sttManager.inference.latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if sttManager.inference.isProcessing || isScoring || NemotronSTTService.shared.isStreaming {
            if sttManager.settings.engineType == .nemotron {
                let nLive = NemotronSTTService.shared.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !nLive.isEmpty { return nLive }
            }
            let formatted = sttManager.inference.latestFormattedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !formatted.isEmpty { return formatted }
            let latest = sttManager.inference.latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !latest.isEmpty { return latest }
            return audioManager.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    private func mergeOverlappingStrings(_ a: String, _ b: String) -> String {
        let wordsA = a.split(separator: " ")
        let wordsB = b.split(separator: " ")
        for i in 0..<wordsA.count {
            let sliceA = wordsA[i...]
            if wordsB.starts(with: sliceA) {
                let uniqueB = wordsB.dropFirst(sliceA.count)
                return (wordsA + uniqueB).joined(separator: " ")
            }
        }
        return "\(a) \(b)".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveTemporaryWAV(samples: [Float], sampleRate: Double = 16000.0) -> URL? {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn_\(UUID().uuidString)")
            .appendingPathExtension("wav")

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let file = try? AVAudioFile(forWriting: tempURL, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData?[0] {
            channelData.initialize(from: samples, count: samples.count)
        }
        try? file.write(from: buffer)
        return tempURL
    }
}
