import Foundation
import AVFoundation
import Combine
import Speech
import Accelerate

class AudioEngine: ObservableObject {
    private let audioEngine = AVAudioEngine()
    
    private let maxAudioSeconds: Float = 5.0
    private let overlapSeconds: Float = 1.5
    private var sampleBuffer = [Float]()
    
    @Published var isSpeaking = false
    @Published var currentAudioChunk: [Float]? = nil
    @Published var liveAudioChunk: [Float]? = nil
    @Published var liveTranscript: String = ""
    @Published var currentRMS: Float = 0.0
    @Published var lastChunkTimeRange: (start: TimeInterval, end: TimeInterval)? = nil
    
    // Adaptive VAD
    private var noiseFloor: Float = 0.001
    private var silenceFrames = 0
    private let maxSilenceFrames = 20 // 600ms
    private var lastLiveEmitIndex = 0
    private var sessionStartTime: CFAbsoluteTime? = nil
    private var currentTurnStartTime: CFAbsoluteTime? = nil
    private var lastRMSUpdateTime: CFAbsoluteTime = 0.0
    
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    @Published var isRecording = false
    private let dummyMixer = AVAudioMixerNode()
    private let silenceMixer = AVAudioMixerNode()
    
    private var audioConverter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    
    func start() {
        guard !isRecording else { return }
        
        sessionStartTime = CFAbsoluteTimeGetCurrent()
        currentTurnStartTime = nil
        lastChunkTimeRange = nil
        
        SFSpeechRecognizer.requestAuthorization { _ in }
        
        let inputNode = audioEngine.inputNode
        try? inputNode.setVoiceProcessingEnabled(true)
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            print("AudioEngine: Invalid input format: \(inputFormat)")
            return
        }
        
        // Target format is 16kHz mono Float32 for Wav2Vec2 and Whisper.
        // AVAudioFormat(commonFormat:sampleRate:channels:interleaved:) returns nil if channels > 2,
        // so targetFormat must always be 1-channel mono.
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            print("AudioEngine: Failed to create 16kHz mono target format")
            return
        }
        self.targetFormat = targetFormat
        
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            print("AudioEngine: Failed to create AVAudioConverter from \(inputFormat) to \(targetFormat)")
            return
        }
        // Map input channel 0 to output channel 0 to avoid silent conversion on multichannel mics
        converter.channelMap = [0]
        self.audioConverter = converter
        
        inputNode.removeTap(onBus: 0)
        let tapBlock: AVAudioNodeTapBlock = { [weak self] buffer, time in
            guard let self = self, let targetFormat = self.targetFormat, let converter = self.audioConverter else { return }
            
            // 1. Send native buffer to Apple's SFSpeechRecognizer (works flawlessly)
            if self.isSpeaking {
                self.recognitionRequest?.append(buffer)
            }
            
            // 2. Resample to 16kHz mono
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / inputFormat.sampleRate) + 1024
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            
            var error: NSError?
            var allSamplesReceived = false
            converter.convert(to: convertedBuffer, error: &error) { inNumPackets, outStatus in
                if allSamplesReceived {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                allSamplesReceived = true
                outStatus.pointee = .haveData
                return buffer
            }
            
            if error == nil {
                self.processBuffer(convertedBuffer)
            }
        }
        
        if #available(macOS 27.0, *) {
            try? inputNode.__installTap(onBus: 0, bufferSize: 1024, format: inputFormat, error: (), block: tapBlock)
        } else {
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat, block: tapBlock)
        }
        
        audioEngine.prepare()
        do {
            try audioEngine.start()
            isRecording = true
        } catch {
            print("AudioEngine: Failed to start audioEngine: \(error)")
            inputNode.removeTap(onBus: 0)
            isRecording = false
        }
    }
    
    func stop() {
        guard isRecording else { return }
        isRecording = false
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        DispatchQueue.main.async {
            self.flushBuffer(isSilence: true)
        }
    }
    
    private func startLiveTranscription() {
        recognitionTask?.cancel()
        recognitionTask = nil
        
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest, let speechRecognizer = speechRecognizer else { return }
        
        recognitionRequest.shouldReportPartialResults = true
        if #available(macOS 13.0, iOS 16.0, *) {
            recognitionRequest.addsPunctuation = true
        }
        
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                DispatchQueue.main.async {
                    self.liveTranscript = result.bestTranscription.formattedString
                }
            }
            
            if error != nil {
                self.stopLiveTranscription()
            }
        }
    }
    
    private func stopLiveTranscription() {
        recognitionRequest?.endAudio()
        recognitionRequest = nil
    }
    
    func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }
        
        // Accelerated SIMD vector calculation for Root Mean Square (RMS) energy
        var meanSquare: Float = 0.0
        vDSP_measqv(channelData, 1, &meanSquare, vDSP_Length(frameLength))
        let rms = sqrt(meanSquare)
        
        // CRITICAL: Extract floats to a Swift array BEFORE async dispatch.
        // If we don't do this, the AVAudioPCMBuffer is deallocated by the time
        // the async block runs, and the channelData pointer becomes a dangling pointer!
        let bufferPointer = UnsafeBufferPointer(start: channelData, count: frameLength)
        let floatArray = Array(bufferPointer)
        
        let now = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async {
            // Throttle published RMS updates to ~12.5 Hz (every 80ms) to avoid SwiftUI view thrashing
            if now - self.lastRMSUpdateTime >= 0.08 || self.isSpeaking {
                self.currentRMS = rms
                self.lastRMSUpdateTime = now
            }
            
            if !self.isSpeaking {
                if rms < self.noiseFloor {
                    self.noiseFloor = rms
                } else {
                    self.noiseFloor = self.noiseFloor * 0.95 + rms * 0.05
                }
            }
            
            let dynamicThreshold = max(0.01, self.noiseFloor * 2.0)
            
            if rms > dynamicThreshold {
                if !self.isSpeaking {
                    self.isSpeaking = true
                    self.currentTurnStartTime = CFAbsoluteTimeGetCurrent()
                    self.liveTranscript = ""
                    self.startLiveTranscription()
                }
                self.silenceFrames = 0
            } else {
                if self.isSpeaking {
                    self.silenceFrames += 1
                }
            }
            
            if self.isSpeaking {
                if !self.audioEngine.isRunning {
                    self.recognitionRequest?.append(buffer)
                }
                self.sampleBuffer.append(contentsOf: floatArray)
                
                // Emit live chunk every 0.5s (8000 frames)
                if self.sampleBuffer.count - self.lastLiveEmitIndex >= 8000 {
                    self.liveAudioChunk = self.sampleBuffer
                    self.lastLiveEmitIndex = self.sampleBuffer.count
                }
                
                if self.silenceFrames >= self.maxSilenceFrames {
                    self.flushBuffer(isSilence: true)
                } else if self.sampleBuffer.count >= 16000 * 15 {
                    // Safety check: if continuous speech exceeds 15 seconds without a silence pause,
                    // flush via sliding window to retain context and prevent excessive buffer accumulation
                    self.flushBuffer(isSilence: false)
                }
            }
        }
    }
    
    private func flushBuffer(isSilence: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        let sess0 = self.sessionStartTime ?? now
        let fallbackStart = now - (Double(self.sampleBuffer.count) / 16000.0)
        let tStart = max(0.0, (self.currentTurnStartTime ?? fallbackStart) - sess0)
        let tEnd = max(tStart, now - sess0)
        self.lastChunkTimeRange = (start: tStart, end: tEnd)
        self.currentTurnStartTime = nil

        if isSilence {
            // Trim trailing silence frames accumulated during silence detection
            let trailingSilenceSamples = min(self.silenceFrames * 1024, self.sampleBuffer.count)
            let speechSampleCount = self.sampleBuffer.count - trailingSilenceSamples
            if speechSampleCount > 4000 { 
                self.currentAudioChunk = Array(self.sampleBuffer.prefix(speechSampleCount))
            } else if self.sampleBuffer.count > 4000 {
                self.currentAudioChunk = self.sampleBuffer
            }
            
            self.sampleBuffer.removeAll()
            self.isSpeaking = false
            self.stopLiveTranscription()
            self.silenceFrames = 0
            self.lastLiveEmitIndex = 0
        } else {
            if self.sampleBuffer.count > 4000 { 
                self.currentAudioChunk = self.sampleBuffer
            }
            // Sliding Window: Retain the last 1.5 seconds as prefix context for the next chunk
            let retainSamples = Int(self.overlapSeconds * 16000.0)
            if self.sampleBuffer.count > retainSamples {
                self.sampleBuffer = Array(self.sampleBuffer.suffix(retainSamples))
            }
            self.lastLiveEmitIndex = 0
            
            // Note: During sliding window, we DO NOT stop live transcription so it continues seamlessly!
        }
    }
}
