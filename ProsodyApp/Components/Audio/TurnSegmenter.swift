import Foundation
import Accelerate

/// Represents a segmented utterance turn ready for speech recognition and acoustic evaluation.
public struct TurnSegment: Sendable {
    public let startSample: Int
    public let endSample: Int
    public let startTime: Double
    public let endTime: Double
    public let samples: [Float]
    public let isSlidingWindowContinuation: Bool

    public init(
        startSample: Int,
        endSample: Int,
        startTime: Double,
        endTime: Double,
        samples: [Float],
        isSlidingWindowContinuation: Bool = false
    ) {
        self.startSample = startSample
        self.endSample = endSample
        self.startTime = startTime
        self.endTime = endTime
        self.samples = samples
        self.isSlidingWindowContinuation = isSlidingWindowContinuation
    }
}

/// A unified, stateful turn segmenter and adaptive VAD engine designed for continuous 16kHz speech.
/// Provides identical behavior across real-time microphone capture and offline batch evaluation.
public final class TurnSegmenter: @unchecked Sendable {

    // MARK: - Configuration
    public let sampleRate: Int
    public let frameSize: Int
    public let preSpeechSamples: Int
    public let postSpeechSamples: Int
    public let minTurnSamples: Int
    public let maxTurnFrames: Int
    public let minNoiseFloor: Float
    public var neuralFilter: NeuralVADFilter? = nil

    // MARK: - State
    private var preRollBuffer = [Float]()
    private var turnBuffer = [Float]()
    private var isSpeaking = false
    private var silenceFrames = 0
    private var currentTurnFrames = 0
    private var totalSamplesProcessed = 0
    private var turnStartSampleIndex = 0
    private var isContinuationTurn = false

    /// Whether speech is currently detected and an utterance turn is actively accumulating.
    public var isSpeechActive: Bool {
        return isSpeaking
    }

    // Rolling energy tracking for dynamic 10th-percentile noise floor estimation
    private var rollingEnergies = [Float]()
    private let maxEnergyHistoryFrames = 64 // ~4.1 seconds history at 64ms/frame
    private var currentNoiseFloor: Float = 0.005

    // Leftover samples between append calls
    private var pendingSamples = [Float]()

    // MARK: - Initialization

    public init(
        sampleRate: Int = 16000,
        frameSize: Int = 1024, // 64ms at 16kHz
        preSpeechDuration: Double = 0.30, // 300ms onset buffer
        postSpeechHangover: Double = 0.25, // 250ms coda hangover
        minTurnDuration: Double = 0.70, // 700ms minimum turn to reject transient clicks and breathing
        maxTurnDuration: Double = 24.0, // 24.0s maximum turn before valley split
        minNoiseFloor: Float = 0.0005
    ) {
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        self.preSpeechSamples = Int(preSpeechDuration * Double(sampleRate))
        self.postSpeechSamples = Int(postSpeechHangover * Double(sampleRate))
        self.minTurnSamples = Int(minTurnDuration * Double(sampleRate))
        self.maxTurnFrames = Int(maxTurnDuration * Double(sampleRate) / Double(frameSize))
        self.minNoiseFloor = minNoiseFloor
    }

    public func reset() {
        preRollBuffer.removeAll()
        turnBuffer.removeAll()
        isSpeaking = false
        silenceFrames = 0
        currentTurnFrames = 0
        totalSamplesProcessed = 0
        turnStartSampleIndex = 0
        isContinuationTurn = false
        rollingEnergies.removeAll()
        currentNoiseFloor = 0.005
        pendingSamples.removeAll()
    }

    // MARK: - Streaming Ingestion

    /// Appends incoming audio samples and returns any finalized utterance turns.
    public func append(samples: [Float]) -> [TurnSegment] {
        guard !samples.isEmpty else { return [] }

        pendingSamples.append(contentsOf: samples)
        var completedTurns: [TurnSegment] = []

        while pendingSamples.count >= frameSize {
            let frame = Array(pendingSamples.prefix(frameSize))
            pendingSamples.removeFirst(frameSize)

            if let turn = processFrame(frame) {
                completedTurns.append(turn)
            }
        }

        return completedTurns
    }

    /// Flushes any pending speech in the buffer (e.g. when the user taps stop).
    public func flush() -> [TurnSegment] {
        var completedTurns: [TurnSegment] = []

        // Process leftover samples if they exceed half a frame
        if pendingSamples.count >= frameSize / 2 {
            let padded = pendingSamples + [Float](repeating: 0, count: frameSize - pendingSamples.count)
            pendingSamples.removeAll()
            if let turn = processFrame(padded) {
                completedTurns.append(turn)
            }
        } else {
            pendingSamples.removeAll()
        }

        if isSpeaking && turnBuffer.count >= minTurnSamples {
            let endSample = totalSamplesProcessed
            let startSample = max(0, turnStartSampleIndex)
            let turn = TurnSegment(
                startSample: startSample,
                endSample: endSample,
                startTime: Double(startSample) / Double(sampleRate),
                endTime: Double(endSample) / Double(sampleRate),
                samples: turnBuffer,
                isSlidingWindowContinuation: isContinuationTurn
            )
            completedTurns.append(turn)
        }

        reset()
        return completedTurns
    }

    // MARK: - Frame-Level VAD & Slicing

    private func processFrame(_ frame: [Float]) -> TurnSegment? {
        let frameRMS = computeRMS(frame)
        let frameZCR = computeZCR(frame)

        totalSamplesProcessed += frame.count

        // Update rolling energy history
        rollingEnergies.append(frameRMS)
        if rollingEnergies.count > maxEnergyHistoryFrames {
            rollingEnergies.removeFirst(rollingEnergies.count - maxEnergyHistoryFrames)
        }

        // Compute 10th percentile energy floor across rolling history
        let noiseFloor = estimate10thPercentileNoiseFloor()
        currentNoiseFloor = noiseFloor

        // Adaptive speech detection threshold
        // Unvoiced fricatives (/s/, /θ/, /f/) have high ZCR even when RMS is modest
        var isSpeechFrame: Bool
        let baseThreshold = max(minNoiseFloor * 3.0, noiseFloor * 2.2)

        if frameRMS > baseThreshold {
            isSpeechFrame = true
        } else if frameRMS > max(minNoiseFloor * 2.0, noiseFloor * 1.5) && frameZCR > 0.18 {
            isSpeechFrame = true
        } else {
            isSpeechFrame = false
        }

        // Stage 2: Non-speech transient suppression via Neural VAD
        if isSpeechFrame, let filter = neuralFilter, filter.isTransientDistractor {
            isSpeechFrame = false
        }

        if !isSpeaking {
            // Buffer into pre-roll while waiting for speech
            preRollBuffer.append(contentsOf: frame)
            if preRollBuffer.count > preSpeechSamples {
                preRollBuffer.removeFirst(preRollBuffer.count - preSpeechSamples)
            }

            if isSpeechFrame {
                isSpeaking = true
                currentTurnFrames = 0
                silenceFrames = 0
                turnStartSampleIndex = max(0, totalSamplesProcessed - frame.count - preRollBuffer.count)

                turnBuffer.removeAll()
                turnBuffer.append(contentsOf: preRollBuffer)
                preRollBuffer.removeAll()
            }
        } else {
            // Speech is active
            currentTurnFrames += 1
            turnBuffer.append(contentsOf: frame)

            if isSpeechFrame {
                silenceFrames = 0
            } else {
                silenceFrames += 1
            }

            // Calibrated silence timeout:
            // - Normal turns (<6s): 10 frames (~640ms) to accommodate non-native formulation pauses
            // - Extended turns (>=6s): 7 frames (~448ms) to readily capture sentence breath pauses
            let requiredSilenceFrames = (currentTurnFrames < Int(6.0 * Double(sampleRate) / Double(frameSize))) ? 10 : 7

            if silenceFrames >= requiredSilenceFrames {
                // Natural pause boundary reached
                return finalizeSilenceTurn(requiredSilenceFrames: requiredSilenceFrames)
            } else if currentTurnFrames >= maxTurnFrames {
                // Maximum turn length reached: perform energy-valley split
                return finalizeValleySplitTurn()
            }
        }

        return nil
    }

    // MARK: - Turn Finalization Helpers

    private func finalizeSilenceTurn(requiredSilenceFrames: Int) -> TurnSegment? {
        let trailingSilenceSamples = min(silenceFrames * frameSize, turnBuffer.count)
        let trailingCut = max(0, trailingSilenceSamples - postSpeechSamples)
        let speechSampleCount = turnBuffer.count - trailingCut

        var result: TurnSegment? = nil
        if speechSampleCount >= minTurnSamples {
            let finalSamples = Array(turnBuffer.prefix(speechSampleCount))
            let endSample = turnStartSampleIndex + finalSamples.count
            result = TurnSegment(
                startSample: turnStartSampleIndex,
                endSample: endSample,
                startTime: Double(turnStartSampleIndex) / Double(sampleRate),
                endTime: Double(endSample) / Double(sampleRate),
                samples: finalSamples,
                isSlidingWindowContinuation: isContinuationTurn
            )
        }

        // Reset turn state
        turnBuffer.removeAll()
        preRollBuffer.removeAll()
        isSpeaking = false
        silenceFrames = 0
        currentTurnFrames = 0
        isContinuationTurn = false

        return result
    }

    private func finalizeValleySplitTurn() -> TurnSegment? {
        // Look back over the last 2.0 seconds (~32 frames) for the local RMS energy minimum
        let lookbackFrames = min(currentTurnFrames - 16, Int(2.0 * Double(sampleRate) / Double(frameSize)))
        var splitSampleOffset = turnBuffer.count

        if lookbackFrames > 4 {
            let searchStart = turnBuffer.count - (lookbackFrames * frameSize)
            var minRMS: Float = .infinity
            var bestOffset = turnBuffer.count

            for f in 0..<lookbackFrames {
                let sIdx = searchStart + (f * frameSize)
                let eIdx = min(sIdx + frameSize, turnBuffer.count)
                guard eIdx > sIdx else { continue }
                let sub = Array(turnBuffer[sIdx..<eIdx])
                let rms = computeRMS(sub)
                if rms < minRMS {
                    minRMS = rms
                    bestOffset = eIdx
                }
            }
            // Split exactly at the energy minimum valley without adding post-speech hangover
            // to avoid cutting into the beginning of the next word.
            splitSampleOffset = min(turnBuffer.count, bestOffset)
        }

        var result: TurnSegment? = nil
        if splitSampleOffset >= minTurnSamples {
            let finalSamples = Array(turnBuffer.prefix(splitSampleOffset))
            let endSample = turnStartSampleIndex + finalSamples.count
            result = TurnSegment(
                startSample: turnStartSampleIndex,
                endSample: endSample,
                startTime: Double(turnStartSampleIndex) / Double(sampleRate),
                endTime: Double(endSample) / Double(sampleRate),
                samples: finalSamples,
                isSlidingWindowContinuation: isContinuationTurn
            )
        }

        // Sliding window continuation: retain up to 1.5 seconds (24,000 samples) prior to the split
        // as an overlap prefix so boundary words remain intact and are deduplicated downstream.
        let overlapSamples = Int(1.5 * Double(sampleRate))
        let continuationStart = max(0, splitSampleOffset - overlapSamples)
        turnBuffer = Array(turnBuffer[continuationStart..<turnBuffer.count])

        turnStartSampleIndex = turnStartSampleIndex + continuationStart
        currentTurnFrames = turnBuffer.count / frameSize
        silenceFrames = 0
        isContinuationTurn = true // Flag that this turn continues the previous one

        return result
    }

    // MARK: - DSP Feature Extraction

    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0.0 }
        var meanSquare: Float = 0.0
        vDSP_measqv(samples, 1, &meanSquare, vDSP_Length(samples.count))
        return sqrt(meanSquare)
    }

    private func computeZCR(_ samples: [Float]) -> Float {
        guard samples.count > 1 else { return 0.0 }
        var crossings = 0
        var prevSign = samples[0] >= 0
        for i in 1..<samples.count {
            let currSign = samples[i] >= 0
            if currSign != prevSign {
                crossings += 1
                prevSign = currSign
            }
        }
        return Float(crossings) / Float(samples.count - 1)
    }

    private func estimate10thPercentileNoiseFloor() -> Float {
        guard !rollingEnergies.isEmpty else { return minNoiseFloor }
        let sorted = rollingEnergies.sorted()
        let p10Index = max(0, min(sorted.count - 1, Int(Float(sorted.count) * 0.10)))
        return max(minNoiseFloor, sorted[p10Index])
    }

    // MARK: - Batch Slicing API (Evaluation & Offline Parity)

    /// Slices an entire audio buffer into turns with 100% parity to real-time streaming segmentation.
    public static func segment(audio: [Float], sampleRate: Int = 16000) -> [TurnSegment] {
        let segmenter = TurnSegmenter(sampleRate: sampleRate)
        var turns = segmenter.append(samples: audio)
        turns.append(contentsOf: segmenter.flush())
        return turns
    }
}
