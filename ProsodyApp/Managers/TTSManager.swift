import Foundation
import AVFoundation
import Combine

/// Strongly-typed synthesis and voice cloning result.
struct VoiceClonerResult: Sendable {
    let outputURL: URL
    let inferenceDuration: Double
    let audioDuration: Double
    let rtf: Double

    init(outputURL: URL, inferenceDuration: Double, audioDuration: Double, rtf: Double) {
        self.outputURL = outputURL
        self.inferenceDuration = inferenceDuration
        self.audioDuration = audioDuration
        self.rtf = rtf
    }
}

/// Centralized manager and singleton entry point for Text-to-Speech (TTS) and Voice Cloning.
///
/// Coordinates on-device Kokoro-82M speech synthesis and OpenVoice V2 timbre conversion,
/// audio recording for learner reference samples, synchronized playback, and engine lifecycle.
/// Operates 100% in-process with zero external backend or network dependencies.
@MainActor
final class TTSManager: NSObject, ObservableObject, AVAudioRecorderDelegate, AVAudioPlayerDelegate {

    static let shared = TTSManager()

    // MARK: - Published State

    @Published var referenceAudioURL: URL? = nil
    @Published var clonedAudioURL: URL? = nil
    @Published var activeProfile: LearnerVoiceProfile? = nil

    @Published var isRecording: Bool = false
    @Published var recordingDuration: TimeInterval = 0.0
    @Published var recordingMeterLevel: Float = 0.0

    @Published var isGenerating: Bool = false
    @Published var generationProgressMessage: String = ""

    @Published var isEngineReady: Bool = false
    @Published var engineStatusDetail: String = "Loading Models..."
    @Published var loadFailed: Bool = false
    @Published var availableDevices: [String] = ["Apple Silicon (Neural Engine)", "CPU"]

    // Telemetry
    @Published var lastInferenceDuration: Double? = nil
    @Published var lastAudioDuration: Double? = nil
    @Published var lastRTF: Double? = nil
    @Published var lastDeviceUsed: String? = nil

    @Published var errorMessage: String? = nil

    // Playback state
    @Published var isPlayingReference: Bool = false
    @Published var isPlayingCloned: Bool = false

    // MARK: - Private Members

    private let profileKey = "prosody_learner_voice_profile"
    private var audioRecorder: AVAudioRecorder?
    private var referencePlayer: AVAudioPlayer?
    private var clonedPlayer: AVAudioPlayer?
    private var recordingTimer: Timer?

    override init() {
        super.init()
        loadPersistedProfile()
        setupEngineObservation()
    }

    private func loadPersistedProfile() {
        if let data = UserDefaults.standard.data(forKey: profileKey),
           let profile = try? JSONDecoder().decode(LearnerVoiceProfile.self, from: data) {
            self.activeProfile = profile
            print("TTSManager: Restored learner voice profile (\(profile.sampleCount) turns, F0: \(Int(round(profile.estimatedF0))) Hz, \(profile.registerDescription)).")
        }
    }

    deinit {
        recordingTimer?.invalidate()
    }

    // MARK: - Engine Lifecycle & Observation

    /// Prewarms the native engine on app launch so models are ready ahead of time.
    func prewarm() {
        VoiceClonerNativeEngine.shared.prewarm()
    }

    private func setupEngineObservation() {
        updateEngineStatus()

        let engine = VoiceClonerNativeEngine.shared

        // Register reactive callback to eliminate periodic polling
        engine.onStatusChanged = { [weak self] isLoaded, message in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.isEngineReady = isLoaded
                self.engineStatusDetail = message
                if !isLoaded && message.contains("Failed") {
                    self.loadFailed = true
                    self.errorMessage = message
                }
            }
        }
    }

    func updateEngineStatus() {
        let engine = VoiceClonerNativeEngine.shared
        self.isEngineReady = engine.isLoaded
        self.engineStatusDetail = engine.statusMessage
        if !engine.isLoaded && engine.statusMessage.contains("Failed") {
            self.loadFailed = true
            self.errorMessage = engine.statusMessage
        }
    }

    // MARK: - Learner Voice Profiling

    /// Updates the learner's voice profile using raw audio samples captured during a speech turn.
    /// Runs silently on a background utility queue without blocking audio playback or speech scoring.
    func updateLearnerProfile(from samples: [Float]) {
        guard samples.count >= 24000 else { return } // Minimum 1.5s at 16kHz
        let engine = VoiceClonerNativeEngine.shared

        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            do {
                guard let result = try engine.extractProfile(audio: samples) else { return }

                await MainActor.run {
                    let current = self.activeProfile
                    let newEmbedding: [Float]
                    let newF0: Float
                    let newCount: Int

                    if let existing = current, existing.timbreEmbedding.count == 128 {
                        // Exponential moving average: 0.75 existing, 0.25 new sample
                        var smoothed = [Float](repeating: 0, count: 128)
                        for i in 0..<128 {
                            smoothed[i] = 0.75 * existing.timbreEmbedding[i] + 0.25 * result.embedding[i]
                        }
                        newEmbedding = smoothed
                        newF0 = (result.f0 > 0 && existing.estimatedF0 > 0)
                            ? (0.75 * existing.estimatedF0 + 0.25 * result.f0)
                            : (result.f0 > 0 ? result.f0 : existing.estimatedF0)
                        newCount = existing.sampleCount + 1
                    } else {
                        newEmbedding = result.embedding
                        newF0 = result.f0
                        newCount = 1
                    }

                    let updated = LearnerVoiceProfile(
                        timbreEmbedding: newEmbedding,
                        estimatedF0: newF0,
                        sampleCount: newCount,
                        lastUpdated: Date()
                    )
                    self.saveProfile(updated)
                    print("TTSManager: Updated learner voice profile (Turn \(newCount), F0: \(Int(round(newF0))) Hz, Register: \(updated.registerDescription)).")
                }
            } catch {
                print("TTSManager: Background profiling error: \(error)")
            }
        }
    }

    /// Persists a voice profile to UserDefaults.
    private func saveProfile(_ profile: LearnerVoiceProfile) {
        self.activeProfile = profile
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: profileKey)
        }
    }

    /// Clears the cached learner voice profile and reference sample.
    func clearLearnerProfile() {
        self.activeProfile = nil
        self.referenceAudioURL = nil
        UserDefaults.standard.removeObject(forKey: profileKey)
        print("TTSManager: Cleared learner voice profile.")
    }

    // MARK: - Programmatic Synthesis API

    /// Synthesizes speech with canonical pronunciation and transfers the learner's vocal timbre.
    ///
    /// - Parameters:
    ///   - targetText: The script or sentence to synthesize with canonical phonemes.
    ///   - learnerAudioURL: Optional local URL to learner reference WAV file (falls back to activeProfile or base voice).
    ///   - baseVoice: Pre-cached Kokoro voice style or "auto" for intelligent automatic selection.
    ///   - speed: Speech rate multiplier (1.0 = normal).
    ///   - tau: Timbre transfer balance (0.0 = pure base voice, 1.0 = maximum learner timbre).
    /// - Returns: A `VoiceClonerResult` with the output audio URL and telemetry metrics.
    @discardableResult
    func synthesize(
        targetText: String,
        learnerAudioURL: URL? = nil,
        baseVoice: String = "auto",
        speed: Float = 1.0,
        tau: Float = 0.35
    ) async throws -> VoiceClonerResult {
        let trimmedText = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            let error = VoiceClonerError.emptyTargetText
            self.errorMessage = error.localizedDescription
            throw error
        }

        // Determine effective learner reference URL or cached timbre vector
        var effectiveLearnerURL: URL? = nil
        if let explicitURL = learnerAudioURL, FileManager.default.fileExists(atPath: explicitURL.path) {
            effectiveLearnerURL = explicitURL
        } else if let refURL = referenceAudioURL, FileManager.default.fileExists(atPath: refURL.path) {
            effectiveLearnerURL = refURL
        }

        let learnerStyle = activeProfile?.timbreEmbedding
        let hasLearnerIdentity = (effectiveLearnerURL != nil) || (learnerStyle != nil && learnerStyle!.count >= 128)

        stopAllPlayback()
        isGenerating = true
        errorMessage = nil
        generationProgressMessage = hasLearnerIdentity
            ? "Synthesizing native speech & transferring timbre on-device…"
            : "Synthesizing native speech with canonical base voice…"

        let settings = STTSettings.shared
        let targetDialect = settings.targetDialect
        let isChild = settings.isChildLearnerMode

        do {
            let rawResult = try await VoiceClonerNativeEngine.shared.clone(
                learnerAudioURL: effectiveLearnerURL,
                learnerStyle: learnerStyle,
                targetText: trimmedText,
                baseVoice: baseVoice,
                speed: speed,
                tau: hasLearnerIdentity ? tau : 0.0,
                targetDialect: targetDialect,
                isChild: isChild
            )

            let result = VoiceClonerResult(
                outputURL: rawResult.outputURL,
                inferenceDuration: rawResult.inferenceDuration,
                audioDuration: rawResult.audioDuration,
                rtf: rawResult.rtf
            )

            self.clonedAudioURL = result.outputURL
            self.lastInferenceDuration = result.inferenceDuration
            self.lastAudioDuration = result.audioDuration
            self.lastRTF = result.rtf
            self.lastDeviceUsed = "Apple Silicon (Neural Engine)"

            self.isGenerating = false
            self.generationProgressMessage = ""

            return result
        } catch {
            self.isGenerating = false
            self.generationProgressMessage = ""
            self.errorMessage = "Generation failed: \(error.localizedDescription)"
            throw error
        }
    }

    // MARK: - Audio Recording

    func startRecording() {
        stopAllPlayback()
        errorMessage = nil

        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if authStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor [weak self] in
                    if granted {
                        self?.beginRecordingSession()
                    } else {
                        self?.errorMessage = "Microphone permission is required to record a voice sample."
                    }
                }
            }
        } else if authStatus == .authorized {
            beginRecordingSession()
        } else {
            errorMessage = "Microphone access is disabled. Please enable it in System Settings > Privacy & Security > Microphone."
        }
    }

    private func beginRecordingSession() {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("learner_reference_sample.wav")
        try? FileManager.default.removeItem(at: fileURL)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 24000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            recorder.record()

            self.audioRecorder = recorder
            self.isRecording = true
            self.recordingDuration = 0.0

            recordingTimer?.invalidate()
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self = self, let rec = self.audioRecorder, rec.isRecording else { return }
                    rec.updateMeters()
                    self.recordingDuration = rec.currentTime
                    let p = rec.averagePower(forChannel: 0)
                    let norm = max(0.0, min(1.0, (p + 50.0) / 50.0))
                    self.recordingMeterLevel = norm
                }
            }
        } catch {
            self.errorMessage = "Failed to start recording: \(error.localizedDescription)"
            self.isRecording = false
        }
    }

    func stopRecording() {
        guard let recorder = audioRecorder, recorder.isRecording else { return }
        recorder.stop()
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false
        recordingMeterLevel = 0.0

        if FileManager.default.fileExists(atPath: recorder.url.path) {
            self.referenceAudioURL = recorder.url
            let recordedURL = recorder.url
            Task.detached(priority: .utility) { [weak self] in
                if let samples = try? VoiceClonerNativeEngine.shared.loadAudioAt16kHz(url: recordedURL) {
                    await self?.updateLearnerProfile(from: samples)
                }
            }
        }
    }

    // MARK: - Playback

    func playReference() {
        guard let url = referenceAudioURL else { return }
        stopAllPlayback()
        do {
            referencePlayer = try AVAudioPlayer(contentsOf: url)
            referencePlayer?.delegate = self
            referencePlayer?.play()
            isPlayingReference = true
        } catch {
            errorMessage = "Playback error: \(error.localizedDescription)"
        }
    }

    func stopReference() {
        referencePlayer?.stop()
        isPlayingReference = false
    }

    func playCloned() {
        guard let url = clonedAudioURL else { return }
        stopAllPlayback()
        do {
            clonedPlayer = try AVAudioPlayer(contentsOf: url)
            clonedPlayer?.delegate = self
            clonedPlayer?.play()
            isPlayingCloned = true
        } catch {
            errorMessage = "Playback error: \(error.localizedDescription)"
        }
    }

    func stopCloned() {
        clonedPlayer?.stop()
        isPlayingCloned = false
    }

    private var customPlayer: AVAudioPlayer?
    @Published var isPlayingCustom: Bool = false
    @Published var activeCustomURL: URL? = nil

    func playAudio(from url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Audio file does not exist."
            return
        }
        stopAllPlayback()
        do {
            customPlayer = try AVAudioPlayer(contentsOf: url)
            customPlayer?.delegate = self
            customPlayer?.play()
            isPlayingCustom = true
            activeCustomURL = url
        } catch {
            errorMessage = "Playback error: \(error.localizedDescription)"
        }
    }

    func stopCustomAudio() {
        customPlayer?.stop()
        isPlayingCustom = false
        activeCustomURL = nil
    }

    func stopAllPlayback() {
        referencePlayer?.stop()
        clonedPlayer?.stop()
        customPlayer?.stop()
        isPlayingReference = false
        isPlayingCloned = false
        isPlayingCustom = false
        activeCustomURL = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if player == self.referencePlayer {
                self.isPlayingReference = false
            }
            if player == self.clonedPlayer {
                self.isPlayingCloned = false
            }
            if player == self.customPlayer {
                self.isPlayingCustom = false
                self.activeCustomURL = nil
            }
        }
    }

    // MARK: - Generation (Native On-Device Synthesis)

    func generateGoldenSpeaker(
        text: String,
        baseVoice: String = "auto",
        speed: Float = 1.0,
        tau: Float = 0.35
    ) async {
        let hasRefAudio = referenceAudioURL != nil && FileManager.default.fileExists(atPath: referenceAudioURL!.path)
        let hasProfile = activeProfile != nil && !(activeProfile!.timbreEmbedding.isEmpty)
        guard hasRefAudio || hasProfile else {
            errorMessage = "No voice profile available yet. Speak during practice or record a voice sample first."
            return
        }

        do {
            _ = try await synthesize(
                targetText: text,
                learnerAudioURL: hasRefAudio ? referenceAudioURL : nil,
                baseVoice: baseVoice,
                speed: speed,
                tau: tau
            )
            // Auto-play the synthesized audio
            self.playCloned()
        } catch {
            // Error handling already performed in synthesize()
        }
    }
}

// MARK: - Backwards Compatibility
typealias VoiceClonerService = TTSManager
