import Foundation
import AVFoundation
import Combine
import Speech
import Accelerate

class AudioEngine: ObservableObject {
    private let audioEngine = AVAudioEngine()
    
    // Unified Robust Turn Segmenter & Neural VAD
    private let turnSegmenter = TurnSegmenter(sampleRate: 16000)
    private let neuralVAD = NeuralVADFilter()
    private var liveAccumulator = [Float]()
    
    @Published var isSpeaking = false
    @Published var currentAudioChunk: [Float]? = nil
    @Published var liveAudioChunk: [Float]? = nil
    @Published var liveTranscript: String = ""
    @Published var currentRMS: Float = 0.0
    @Published var lastChunkTimeRange: (start: TimeInterval, end: TimeInterval)? = nil
    
    private var lastLiveEmitIndex = 0
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
        
        lastChunkTimeRange = nil
        turnSegmenter.reset()
        neuralVAD.reset()
        turnSegmenter.neuralFilter = neuralVAD
        
        SFSpeechRecognizer.requestAuthorization { _ in }
        
        let inputNode = audioEngine.inputNode
        try? inputNode.setVoiceProcessingEnabled(true)
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            print("AudioEngine: Invalid input format: \(inputFormat)")
            return
        }
        
        // Target format is 16kHz mono Float32 for Wav2Vec2 and Nemotron.
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            print("AudioEngine: Failed to create 16kHz mono target format")
            return
        }
        self.targetFormat = targetFormat
        neuralVAD.setup(format: targetFormat)
        
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
            
            // 1. Send native buffer to Apple's SFSpeechRecognizer
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
                self.neuralVAD.analyze(buffer: convertedBuffer)
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
        
        let flushedTurns = turnSegmenter.flush()
        
        DispatchQueue.main.async {
            if let last = flushedTurns.last {
                self.currentAudioChunk = last.samples
                self.lastChunkTimeRange = (start: last.startTime, end: last.endTime)
            }
            self.isSpeaking = false
            self.stopLiveTranscription()
            self.liveAccumulator.removeAll()
            self.lastLiveEmitIndex = 0
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
        
        // Extract floats to a Swift array before async dispatch
        let bufferPointer = UnsafeBufferPointer(start: channelData, count: frameLength)
        let floatArray = Array(bufferPointer)
        
        let completedTurns = turnSegmenter.append(samples: floatArray)
        let isSegmenterSpeaking = turnSegmenter.isSpeechActive
        
        let now = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async {
            // Throttle published RMS updates to ~12.5 Hz (every 80ms)
            if now - self.lastRMSUpdateTime >= 0.08 || self.isSpeaking {
                self.currentRMS = rms
                self.lastRMSUpdateTime = now
            }
            
            if isSegmenterSpeaking {
                if !self.isSpeaking {
                    self.isSpeaking = true
                    self.liveTranscript = ""
                    self.startLiveTranscription()
                    self.liveAccumulator.removeAll()
                }
                
                self.liveAccumulator.append(contentsOf: floatArray)
                // Emit live chunk every 0.5s (8000 frames) for UI visualization & Nemotron live stream
                if self.liveAccumulator.count - self.lastLiveEmitIndex >= 8000 {
                    self.liveAudioChunk = self.liveAccumulator
                    self.lastLiveEmitIndex = self.liveAccumulator.count
                }
            }
            
            for turn in completedTurns {
                self.currentAudioChunk = turn.samples
                self.lastChunkTimeRange = (start: turn.startTime, end: turn.endTime)
                self.isSpeaking = false
                self.stopLiveTranscription()
                self.liveAccumulator.removeAll()
                self.lastLiveEmitIndex = 0
            }
        }
    }
}
