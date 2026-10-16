import Foundation
import SoundAnalysis
import AVFoundation

/// An on-device neural voice activity and non-speech distractor classifier powered by Apple's SoundAnalysis framework.
/// Runs asynchronously on Apple Neural Engine to verify human speech vs. non-speech acoustic transients.
public final class NeuralVADFilter: NSObject, SNResultsObserving, @unchecked Sendable {

    private var streamAnalyzer: SNAudioStreamAnalyzer?
    private var currentFramePosition: AVAudioFramePosition = 0
    private let stateLock = NSLock()

    // MARK: - Filter State
    private var _latestSpeechConfidence: Float = 0.0
    private var _latestDistractorConfidence: Float = 0.0
    private var _isSpeechDetected: Bool = false

    public var latestSpeechConfidence: Float {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _latestSpeechConfidence
    }

    public var latestDistractorConfidence: Float {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _latestDistractorConfidence
    }

    /// True if Apple SoundAnalysis actively detects speech or whispering with high confidence (>0.40).
    public var isSpeechDetected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isSpeechDetected
    }

    /// True if recent acoustic energy is dominated by non-speech transients (typing, coughing, laughter) rather than speech.
    public var isTransientDistractor: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _latestDistractorConfidence > 0.55 && _latestSpeechConfidence < 0.25
    }

    // MARK: - Initialization

    public override init() {
        super.init()
    }

    /// Configures the streaming sound analyzer for 16kHz mono audio.
    public func setup(format: AVAudioFormat) {
        stateLock.lock()
        defer { stateLock.unlock() }

        do {
            let analyzer = SNAudioStreamAnalyzer(format: format)
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            request.windowDuration = CMTime(seconds: 0.5, preferredTimescale: 16000)
            request.overlapFactor = 0.5
            try analyzer.add(request, withObserver: self)
            self.streamAnalyzer = analyzer
            self.currentFramePosition = 0
        } catch {
            print("NeuralVADFilter: Failed to initialize SNAudioStreamAnalyzer: \(error)")
        }
    }

    /// Ingests a live audio buffer into the neural analyzer.
    public func analyze(buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let analyzer = self.streamAnalyzer
        let framePos = self.currentFramePosition
        self.currentFramePosition += AVAudioFramePosition(buffer.frameLength)
        stateLock.unlock()

        analyzer?.analyze(buffer, atAudioFramePosition: framePos)
    }

    public func reset() {
        stateLock.lock()
        _latestSpeechConfidence = 0.0
        _latestDistractorConfidence = 0.0
        _isSpeechDetected = false
        currentFramePosition = 0
        stateLock.unlock()
    }

    // MARK: - SNResultsObserving

    public func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let classificationResult = result as? SNClassificationResult else { return }

        var speechScore: Float = 0.0
        var distractorScore: Float = 0.0

        for c in classificationResult.classifications {
            if c.identifier == "speech" || c.identifier == "whispering" {
                speechScore = max(speechScore, Float(c.confidence))
            } else if ["typing", "cough", "laughter", "applause", "sneeze", "sigh"].contains(c.identifier) {
                distractorScore = max(distractorScore, Float(c.confidence))
            }
        }

        stateLock.lock()
        self._latestSpeechConfidence = speechScore
        self._latestDistractorConfidence = distractorScore
        self._isSpeechDetected = speechScore >= 0.40
        stateLock.unlock()
    }

    public func request(_ request: SNRequest, didFailWithError error: Error) {
        // Non-fatal: continues relying on acoustic VAD fallback
    }

    public func requestDidComplete(_ request: SNRequest) {}
}
