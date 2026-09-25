import Foundation
import AVFoundation
import Combine

/// Centralized manager and singleton entry point for audio capture, VAD, and playback.
///
/// Orchestrates microphone hardware acquisition via `AudioEngine`, resampling to 16kHz mono Float32,
/// real-time energy calculation (RMS), live speech recognition preview, and audio playback.
@MainActor
final class AudioManager: ObservableObject {
    static let shared = AudioManager()

    // MARK: - Subordinate Audio Engine Component
    let engine: AudioEngine

    // MARK: - Forwarded Published State
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var isSpeaking: Bool = false
    @Published private(set) var currentAudioChunk: [Float]? = nil
    @Published private(set) var liveAudioChunk: [Float]? = nil
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var currentRMS: Float = 0.0
    @Published private(set) var lastChunkTimeRange: (start: TimeInterval, end: TimeInterval)? = nil

    private var cancellables = Set<AnyCancellable>()

    init(engine: AudioEngine? = nil) {
        let eng = engine ?? AudioEngine()
        self.engine = eng
        bindEngine()
    }

    private func bindEngine() {
        engine.$isRecording
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRecording)

        engine.$isSpeaking
            .receive(on: DispatchQueue.main)
            .assign(to: &$isSpeaking)

        engine.$currentAudioChunk
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentAudioChunk)

        engine.$liveAudioChunk
            .receive(on: DispatchQueue.main)
            .assign(to: &$liveAudioChunk)

        engine.$liveTranscript
            .receive(on: DispatchQueue.main)
            .assign(to: &$liveTranscript)

        engine.$currentRMS
            .receive(on: DispatchQueue.main)
            .assign(to: &$currentRMS)

        engine.$lastChunkTimeRange
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastChunkTimeRange)
    }

    // MARK: - Public Audio Control API

    /// Starts audio recording, VAD monitoring, and live transcription preview.
    func startListening() {
        engine.start()
    }

    /// Stops audio capture and finalizes speech chunk buffers.
    func stopListening() {
        engine.stop()
    }
}
