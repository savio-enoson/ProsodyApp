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
    }

    // MARK: - Engine Observation Bindings

    private func bindAudioObservations() {
        // When speech activity ceases, process accumulated audio chunk
        audioManager.$isSpeaking
            .dropFirst()
            .sink { [weak self] speaking in
                guard let self = self else { return }
                if !speaking {
                    if let chunk = self.audioManager.currentAudioChunk {
                        self.sttManager.inference.process(audioChunk: chunk, sfSpeechHint: self.audioManager.liveTranscript)
                    }
                } else {
                    self.scoringResult = nil
                    self.fluencyResult = nil
                    self.sttManager.inference.latestTranscript = ""
                    self.sttManager.inference.latestFormattedTranscript = ""
                }
            }
            .store(in: &cancellables)

        // Stream partial audio for live preview
        audioManager.$liveAudioChunk
            .compactMap { $0 }
            .sink { [weak self] chunk in
                self?.sttManager.inference.processLive(audioChunk: chunk)
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

    private func executeScoringPipeline(chunk: [Float]) {
        isScoring = true
        lastAudioChunk = chunk

        // Silently update learner voice profile in background from natural practice turn
        ttsManager.updateLearnerProfile(from: chunk)

        Task {
            var transcriptToScore = sttManager.inference.latestTranscript
            var wordTimestampsToUse = sttManager.inference.wordTimestamps ?? []

            let literalToScore = [sttManager.inference.latestLiteralTranscript, sttManager.inference.latestTranscript]
                .filter { !$0.isEmpty }.joined(separator: " ")
            let sfSpeechToScore = audioManager.liveTranscript

            self.lastLiteralTranscript = literalToScore
            self.lastSFSpeechTranscript = sfSpeechToScore
            self.lastWordTimings = wordTimestampsToUse
            self.lastLogProbs = sttManager.inference.latestLogProbs

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

            // Run lightweight Whisper model with prompt conditioning for dual ASR cross-check (Strategy 7)
            var whisperResultText = ""
            do {
                let whisperResult = try await WhisperSTTService.shared.transcribe(
                    audioFloats: chunk,
                    prompt: activePromptContext,
                    modelVariant: .tiny
                )
                whisperResultText = whisperResult.transcript
                self.whisperTranscript = whisperResultText
                if STTSettings.shared.engineType == .whisperKit && !whisperResult.transcript.isEmpty {
                    transcriptToScore = whisperResult.transcript
                    if !whisperResult.wordTimings.isEmpty {
                        wordTimestampsToUse = whisperResult.wordTimings
                        self.lastWordTimings = wordTimestampsToUse
                    }
                }
            } catch {
                print("WhisperKit transcription failed: \(error)")
            }

            let fluency = fluencyManager.evaluate(
                segments: wordTimestampsToUse,
                isChild: STTSettings.shared.isChildLearnerMode,
                audioChunk: chunk,
                transcript: transcriptToScore,
                sfSpeechTranscript: sfSpeechToScore
            )

            // Decoupled scoring reference (Strategy 1):
            // Use WhisperKit's clean hypothesis as scoringReference to eliminate
            // upstream Acoustic Mirror recognition errors from corrupting canonical phoneme targets,
            // while preserving the Acoustic Mirror verbatim transcript for display.
            let scoringRef: String? = whisperResultText.isEmpty ? nil : whisperResultText

            let result = phonemeManager.scoreAudio(
                chunk,
                transcript: transcriptToScore,
                literalTranscript: literalToScore,
                sfSpeechTranscript: sfSpeechToScore,
                whisperTranscript: whisperResultText,
                scoringReference: scoringRef,
                userSegments: wordTimestampsToUse,
                isChild: STTSettings.shared.isChildLearnerMode,
                sttLogProbs: sttManager.inference.latestLogProbs
            )

            let formattedToCommit = sttManager.inference.latestFormattedTranscript.isEmpty
                ? transcriptToScore
                : sttManager.inference.latestFormattedTranscript

            let newFullTranscript: String
            if self.committedTranscript.isEmpty {
                newFullTranscript = formattedToCommit
            } else {
                newFullTranscript = self.mergeOverlappingStrings(self.committedTranscript, formattedToCommit)
            }
            self.committedTranscript = newFullTranscript
            self.editableTranscriptText = newFullTranscript

            if self.whisperTranscript.isEmpty {
                self.whisperTranscript = whisperResultText
            } else if !whisperResultText.isEmpty {
                self.whisperTranscript = self.mergeOverlappingStrings(self.whisperTranscript, whisperResultText)
            }

            self.transcriptWords = TranscriptDiffEngine.align(
                primary: newFullTranscript,
                alternative: self.whisperTranscript,
                sfSpeech: sfSpeechToScore,
                literal: literalToScore,
                timestamps: wordTimestampsToUse
            )

            self.fluencyResult = fluency
            self.scoringResult = result
            self.isScoring = false
            self.sttManager.inference.latestTranscript = ""
            self.sttManager.inference.latestFormattedTranscript = ""

            // Accumulate turn into active session
            if sessionManager.isSessionActive {
                let audioURL = self.saveTemporaryWAV(samples: chunk)
                let timeRange = self.audioManager.lastChunkTimeRange
                sessionManager.recordUtterance(
                    transcript: newFullTranscript,
                    scoringResult: result,
                    fluencyResult: fluency,
                    wordTimestamps: wordTimestampsToUse,
                    audioURL: audioURL,
                    startTime: timeRange?.start,
                    endTime: timeRange?.end
                )
            }

            if self.isFinishingSession {
                self.isFinishingSession = false
                self.showingCoaching = true
            }
        }
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
            showingCoaching = true
        }
    }

    func prewarm() {
        sttManager.prewarm()
        ttsManager.prewarm()
        Task {
            await WhisperSTTService.shared.initializeIfNeeded(modelVariant: .tiny)
            promptService.prewarm()
            await promptService.generate()
        }
    }

    // MARK: - Word Swap & Debounced Re-evaluation

    func swapWord(at index: Int, with newWord: String) {
        guard index >= 0 && index < transcriptWords.count else { return }
        transcriptWords[index].text = newWord
        transcriptWords[index].cleanWord = TranscriptWord.clean(newWord)
        let updatedFullText = transcriptWords.map(\.text).joined(separator: " ")
        committedTranscript = updatedFullText
        editableTranscriptText = updatedFullText
        scheduleReevaluation()
    }

    func onEditableTextChanged(to newText: String) {
        committedTranscript = newText
        scheduleReevaluation()
    }

    func scheduleReevaluation() {
        guard lastAudioChunk != nil else { return }
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
        guard let chunk = lastAudioChunk, !committedTranscript.isEmpty else { return }
        isReevaluating = true
        reevaluationCountdown = 0

        Task {
            let userSegmentsToUse = self.lastWordTimings
            let fluency = self.fluencyManager.evaluate(
                segments: userSegmentsToUse,
                isChild: STTSettings.shared.isChildLearnerMode,
                audioChunk: chunk,
                transcript: self.committedTranscript,
                sfSpeechTranscript: self.lastSFSpeechTranscript
            )

            let result = self.phonemeManager.scoreAudio(
                chunk,
                transcript: self.committedTranscript,
                literalTranscript: self.lastLiteralTranscript,
                sfSpeechTranscript: self.lastSFSpeechTranscript,
                whisperTranscript: self.whisperTranscript,
                scoringReference: self.committedTranscript,
                userSegments: userSegmentsToUse,
                isChild: STTSettings.shared.isChildLearnerMode,
                userVerified: true,
                sttLogProbs: self.lastLogProbs
            )

            self.fluencyResult = fluency
            self.scoringResult = result
            self.isReevaluating = false
        }
    }

    // MARK: - Helpers

    var isModelLoading: Bool {
        if case .failed = sttManager.inference.modelState {
            return false
        }
        if ttsManager.loadFailed || ttsManager.errorMessage != nil {
            return sttManager.inference.modelState == .loading
        }
        return sttManager.inference.modelState == .loading || !ttsManager.isEngineReady
    }

    var activeLiveTranscript: String {
        if audioManager.isSpeaking {
            if !audioManager.liveTranscript.isEmpty {
                return audioManager.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return sttManager.inference.latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if sttManager.inference.isProcessing || isScoring {
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
