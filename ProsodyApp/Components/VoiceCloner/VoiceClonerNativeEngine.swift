import Foundation
@preconcurrency import CoreML
import AVFoundation
import Accelerate

// MARK: - Error Types

/// Strongly-typed error domain for the voice cloning engine.
enum VoiceClonerError: LocalizedError {
    case modelNotFound(name: String)
    case engineNotReady
    case voiceStyleNotFound(voice: String)
    case emptyReferenceAudio
    case emptyTargetText
    case noValidPhonemes
    case audioFormatError(reason: String)
    case audioResampleFailed
    case inferenceReturnedEmpty(stage: String)
    case exportFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let name):
            return "Required model asset '\(name)' could not be located in the application bundle."
        case .engineNotReady:
            return "Native speech models are still initializing."
        case .voiceStyleNotFound(let voice):
            return "Voice style vector for '\(voice)' was not found."
        case .emptyReferenceAudio:
            return "Reference learner audio sample is empty or inaccessible."
        case .emptyTargetText:
            return "Target text to clone and synthesize cannot be empty."
        case .noValidPhonemes:
            return "The provided text produced no valid phonemes for synthesis."
        case .audioFormatError(let reason):
            return "Audio format error: \(reason)"
        case .audioResampleFailed:
            return "Audio resampling failed."
        case .inferenceReturnedEmpty(let stage):
            return "Inference failed: stage '\(stage)' returned no output data."
        case .exportFailed(let reason):
            return "Failed to export output WAV: \(reason)"
        }
    }
}

// MARK: - Native Engine

/// In-process native inference engine for single-stage zero-shot voice cloning.
/// Executes Kokoro-82M FP16 TTS and StyleTTS2/WeSpeaker StyleEncoder purely on-device
/// with 100% CoreML acceleration on Apple Silicon Neural Engine.
nonisolated final class VoiceClonerNativeEngine: @unchecked Sendable {

    static let shared = VoiceClonerNativeEngine()

    // MARK: - Thread-Safe State
    private let stateLock = NSLock()
    private var _isLoaded: Bool = false
    private var _statusMessage: String = "Loading Models..."

    var isLoaded: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isLoaded
    }

    var statusMessage: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _statusMessage
    }

    /// Callback invoked whenever the engine status changes.
    var onStatusChanged: (@Sendable (Bool, String) -> Void)?

    // MARK: - Model Constants
    private static let sampleRateKokoro: Double = 24000.0
    private static let sampleRateStyleEncoder: Double = 16000.0
    private static let speakerEmbeddingDim: Int = 256
    private static let maxTokensPerPass: Int = 128

    // CoreML Models
    private var kokoroModel: MLModel?
    private var styleEncoderModel: MLModel?

    // Kokoro vocabulary, pronunciation dictionary, and cached voice vectors
    private var vocab: [String: Int] = [:]
    private var pronunciationDict: [String: String] = [:]
    private var voiceVectors: [String: [Float]] = [:]

    private let executionQueue = DispatchQueue(label: "com.prosody.voicecloner.engine", qos: .userInitiated)

    private init() {
        executionQueue.async { [weak self] in
            self?.loadModels()
        }
    }

    /// Prewarms the native engine on app launch so models are ready ahead of time.
    func prewarm() {
        // Accessing shared triggers init and executionQueue loading.
    }

    private func updateStatus(isLoaded: Bool, message: String) {
        stateLock.lock()
        self._isLoaded = isLoaded
        self._statusMessage = message
        let callback = self.onStatusChanged
        stateLock.unlock()

        callback?(isLoaded, message)
    }

    // MARK: - Asset Resolution

    private func findAssetURL(name: String, ext: String) -> URL? {
        // 1. Direct bundle root lookup
        if let bundleURL = Bundle.main.url(forResource: name, withExtension: ext) {
            return bundleURL
        }
        // 2. Subdirectory lookups
        let subdirectories = ["AI/VoiceCloner", "VoiceCloner", "AI/Models", "AI/Resources"]
        for sub in subdirectories {
            if let bundleURL = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: sub) {
                return bundleURL
            }
        }
        // 3. Class bundle lookup (for unit tests / frameworks)
        let frameworkBundle = Bundle(for: VoiceClonerNativeEngine.self)
        if let bundleURL = frameworkBundle.url(forResource: name, withExtension: ext) {
            return bundleURL
        }
        // 4. Resource directory fallback
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent("\(name).\(ext)"),
           FileManager.default.fileExists(atPath: resURL.path) {
            return resURL
        }
        // 5. Source tree fallback (for sandbox / debug execution)
        let sourceDir = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AI/VoiceCloner")
        let directSourceURL = sourceDir.appendingPathComponent("\(name).\(ext)")
        if FileManager.default.fileExists(atPath: directSourceURL.path) {
            return directSourceURL
        }
        return nil
    }

    private func findVoiceURL(voiceName: String) -> URL? {
        if let bundleURL = Bundle.main.url(forResource: voiceName, withExtension: "json") {
            return bundleURL
        }
        let subdirectories = ["AI/VoiceCloner/voices", "VoiceCloner/voices", "voices"]
        for sub in subdirectories {
            if let bundleURL = Bundle.main.url(forResource: voiceName, withExtension: "json", subdirectory: sub) {
                return bundleURL
            }
        }
        if let resURL = Bundle.main.resourceURL?.appendingPathComponent("voices/\(voiceName).json"),
           FileManager.default.fileExists(atPath: resURL.path) {
            return resURL
        }
        // Source tree fallback
        let sourceDir = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("AI/VoiceCloner/voices")
        let directSourceURL = sourceDir.appendingPathComponent("\(voiceName).json")
        if FileManager.default.fileExists(atPath: directSourceURL.path) {
            return directSourceURL
        }
        return nil
    }

    // MARK: - Model Loading

    nonisolated func loadModels() {
        do {
            updateStatus(isLoaded: false, message: "Loading Models...")

            // CoreML Neural Engine & CPU Configuration
            let modelConfig = MLModelConfiguration()
            modelConfig.computeUnits = .cpuAndNeuralEngine

            // 1. Load Vocab Index
            guard let vocabURL = findAssetURL(name: "vocab_index", ext: "json") ?? findAssetURL(name: "kokoro_vocab", ext: "json") else {
                throw VoiceClonerError.modelNotFound(name: "vocab_index.json")
            }
            let vocabData = try Data(contentsOf: vocabURL)
            if let json = try JSONSerialization.jsonObject(with: vocabData) as? [String: Any] {
                if let v = json["vocab"] as? [String: Int] {
                    self.vocab = v
                } else if let v = json as? [String: Int] {
                    self.vocab = v
                }
            }

            // 2. Load Pronunciation Dictionary (us_gold.json)
            if let goldURL = findAssetURL(name: "us_gold", ext: "json"),
               let goldData = try? Data(contentsOf: goldURL),
               let goldJson = try? JSONSerialization.jsonObject(with: goldData) as? [String: String] {
                self.pronunciationDict = goldJson
                print("VoiceClonerNativeEngine: Loaded \(goldJson.count) gold pronunciation entries.")
            }

            // 3. Load Kokoro-82M CoreML Generator
            guard let kokoroURL = findAssetURL(name: "kokoro_5s", ext: "mlmodelc") else {
                throw VoiceClonerError.modelNotFound(name: "kokoro_5s.mlmodelc")
            }
            updateStatus(isLoaded: false, message: "Loading Kokoro-82M Neural Engine generator…")
            let tKokoro = CFAbsoluteTimeGetCurrent()
            self.kokoroModel = try MLModel(contentsOf: kokoroURL, configuration: modelConfig)
            print("VoiceClonerNativeEngine: Kokoro-82M CoreML loaded in \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - tKokoro) * 1000)) ms.")

            // 4. Load StyleEncoder CoreML Model
            guard let styleURL = findAssetURL(name: "StyleEncoder", ext: "mlmodelc") else {
                throw VoiceClonerError.modelNotFound(name: "StyleEncoder.mlmodelc")
            }
            updateStatus(isLoaded: false, message: "Loading StyleEncoder Neural Engine model…")
            let tStyle = CFAbsoluteTimeGetCurrent()
            self.styleEncoderModel = try MLModel(contentsOf: styleURL, configuration: modelConfig)
            print("VoiceClonerNativeEngine: StyleEncoder CoreML loaded in \(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - tStyle) * 1000)) ms.")

            // 5. Pre-load Stock Voices
            let stockVoices = ["af_heart", "am_adam", "bf_emma", "bm_george", "af_bella", "am_michael"]
            for voiceName in stockVoices {
                if let voiceURL = findVoiceURL(voiceName: voiceName),
                   let data = try? Data(contentsOf: voiceURL),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let emb = json["embedding"] as? [Double] {
                    self.voiceVectors[voiceName] = emb.map { Float($0) }
                }
            }
            print("VoiceClonerNativeEngine: Pre-loaded \(self.voiceVectors.count) stock voices.")

            updateStatus(isLoaded: true, message: "Native Speech Engine Ready")
            print("VoiceClonerNativeEngine: All in-process CoreML models loaded successfully.")

        } catch {
            updateStatus(isLoaded: false, message: "Failed to load native models: \(error.localizedDescription)")
            print("VoiceClonerNativeEngine Error: \(error)")
        }
    }

    // MARK: - Phoneme Tokenization

    private func textToInputIds(text: String, isBritish: Bool) -> (inputIds: [Int32], mask: [Int32], tokenCount: Int) {
        let maxLen = Self.maxTokensPerPass
        var tokens: [Int32] = [0] // BOS token
        let spaceId = Int32(vocab[" "] ?? 16)

        // Clean and tokenize into words / punctuation
        let pattern = "[\\w']+|[.,!?;—]"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return ([0, 0], [1, 1], 2)
        }

        let nsString = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            let word = nsString.substring(with: match.range)
            let lowerWord = word.lowercased()

            // Lookup in dictionary or fallback to eSpeak
            var phonemes: String? = pronunciationDict[lowerWord]
            if phonemes == nil {
                let dialect: EspeakManager.Dialect = isBritish ? .generic : .us
                let espeakDetails = EspeakManager.shared.getPhonemesDetailed(for: word, dialect: dialect)
                phonemes = espeakDetails.map { $0.phonemes.joined() }.joined()
            }

            if let ph = phonemes, !ph.isEmpty {
                for char in ph {
                    if let id = vocab[String(char)] {
                        tokens.append(Int32(id))
                    }
                }
            } else {
                for char in word {
                    if let id = vocab[String(char)] {
                        tokens.append(Int32(id))
                    }
                }
            }
            tokens.append(spaceId)
        }

        tokens.append(0) // EOS token

        let tokenCount = tokens.count
        if tokens.count > maxLen {
            tokens = Array(tokens.prefix(maxLen))
        }

        var inputIds = [Int32](repeating: 0, count: maxLen)
        var mask = [Int32](repeating: 0, count: maxLen)

        for i in 0..<tokens.count {
            inputIds[i] = tokens[i]
            mask[i] = 1
        }

        return (inputIds, mask, min(tokenCount, maxLen))
    }

    // MARK: - Audio Loading & Resampling

    /// Loads an audio file and converts it to mono float samples at 16,000 Hz for the StyleEncoder.
    func loadAudioAt16kHz(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw VoiceClonerError.audioFormatError(reason: "Could not allocate audio buffer")
        }
        try file.read(into: buffer)

        guard let channelData = buffer.floatChannelData else {
            throw VoiceClonerError.audioFormatError(reason: "No float channel data present")
        }

        let rawSamples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))

        // Resample to 16 kHz if necessary
        if abs(format.sampleRate - Self.sampleRateStyleEncoder) > 1.0 {
            let ratio = Self.sampleRateStyleEncoder / format.sampleRate
            let dstCount = Int(Double(rawSamples.count) * ratio)
            var dstAudio = [Float](repeating: 0, count: dstCount)
            for i in 0..<dstCount {
                let srcIdx = Double(i) / ratio
                let i0 = Int(srcIdx)
                let i1 = min(i0 + 1, rawSamples.count - 1)
                let frac = Float(srcIdx - Double(i0))
                dstAudio[i] = rawSamples[i0] * (1.0 - frac) + rawSamples[i1] * frac
            }
            return dstAudio
        }
        return rawSamples
    }

    /// Writes mono float PCM samples to a 16-bit 24,000 Hz WAV file.
    private func writeWav(samples: [Float], sampleRate: Double, outputURL: URL) throws {
        try autoreleasepool {
            let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]

            let audioFile = try AVAudioFile(forWriting: outputURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
                throw VoiceClonerError.exportFailed(reason: "Could not allocate PCM buffer")
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            if let channelData = buffer.floatChannelData {
                samples.withUnsafeBufferPointer { ptr in
                    channelData[0].initialize(from: ptr.baseAddress!, count: samples.count)
                }
            }
            try audioFile.write(from: buffer)
        }
    }

    // MARK: - Style Extraction

    private func extractLearnerStyle(audio: [Float]) throws -> [Float] {
        guard let model = styleEncoderModel else {
            throw VoiceClonerError.engineNotReady
        }

        var samples = audio
        let minSamples = 16000  // 1.0s
        let maxSamples = 160000 // 10.0s
        if samples.count < minSamples {
            samples.append(contentsOf: [Float](repeating: 0, count: minSamples - samples.count))
        } else if samples.count > maxSamples {
            samples = Array(samples.prefix(maxSamples))
        }

        let shape: [NSNumber] = [1, 1, NSNumber(value: samples.count)]
        let multiArray = try MLMultiArray(shape: shape, dataType: .float32)

        samples.withUnsafeBufferPointer { ptr in
            let destPtr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: samples.count)
            destPtr.initialize(from: ptr.baseAddress!, count: samples.count)
        }

        let inputProvider = try MLDictionaryFeatureProvider(dictionary: ["raw_audio": multiArray])
        let output = try model.prediction(from: inputProvider)

        guard let styleFeature = output.featureValue(for: "acoustic_style")?.multiArrayValue else {
            throw VoiceClonerError.inferenceReturnedEmpty(stage: "StyleEncoder")
        }

        var result = [Float](repeating: 0, count: 128)
        let ptr = styleFeature.dataPointer.bindMemory(to: Float.self, capacity: 128)
        for i in 0..<128 {
            result[i] = ptr[i]
        }
        return result
    }

    // MARK: - Voice Profiling & F0 Estimation

    /// Estimates median fundamental frequency (F0 in Hz) across voiced frames using time-domain autocorrelation.
    func estimateMedianF0(audio: [Float], sampleRate: Float = 16000.0) -> Float {
        guard audio.count >= 400 else { return 0.0 }

        let frameLength = Int(0.025 * sampleRate) // 400 samples (25ms)
        let hopLength = Int(0.010 * sampleRate)   // 160 samples (10ms)
        let minLag = Int(sampleRate / 450.0)       // ~35 samples (450 Hz)
        let maxLag = Int(sampleRate / 65.0)        // ~246 samples (65 Hz)
        let searchLimit = min(maxLag, frameLength / 2)

        var voicedF0s: [Float] = []

        audio.withUnsafeBufferPointer { ptr in
            let basePtr = ptr.baseAddress!
            var frameStart = 0
            while frameStart + frameLength <= audio.count {
                let framePtr = basePtr.advanced(by: frameStart)

                var r0: Float = 0.0
                vDSP_svesq(framePtr, 1, &r0, vDSP_Length(frameLength))

                if r0 > 1e-4 {
                    var bestR: Float = 0.0
                    var bestLag = 0

                    for lag in minLag...searchLimit {
                        var rLag: Float = 0.0
                        vDSP_dotpr(framePtr, 1, framePtr.advanced(by: lag), 1, &rLag, vDSP_Length(frameLength - lag))
                        if rLag > bestR {
                            bestR = rLag
                            bestLag = lag
                        }
                    }

                    let normCorr = bestR / r0
                    if normCorr >= 0.30 && bestLag > 0 {
                        let f0 = sampleRate / Float(bestLag)
                        if f0 >= 65.0 && f0 <= 450.0 {
                            voicedF0s.append(f0)
                        }
                    }
                }

                frameStart += hopLength
            }
        }

        guard voicedF0s.count >= 5 else { return 0.0 }
        voicedF0s.sort()
        return voicedF0s[voicedF0s.count / 2]
    }

    /// Extracts a 128-dimensional timbre embedding and fundamental frequency from audio.
    /// Returns nil if audio is too short (< 1.5s) or has insufficient energy.
    func extractProfile(audio: [Float]) throws -> (embedding: [Float], f0: Float)? {
        guard audio.count >= 24000 else { return nil } // Minimum 1.5s at 16kHz

        // Energy gate: check RMS to ensure audio is not pure room silence
        var rms: Float = 0.0
        audio.withUnsafeBufferPointer { ptr in
            vDSP_rmsqv(ptr.baseAddress!, 1, &rms, vDSP_Length(audio.count))
        }
        guard rms >= 0.020 else { return nil }

        let embedding = try extractLearnerStyle(audio: audio)
        let f0 = estimateMedianF0(audio: audio)
        return (embedding, f0)
    }

    // MARK: - Voice Metadata & Intelligent Matching

    static let stockVoiceMetadata: [String: (name: String, gender: String, dialect: TargetAccentDialect)] = [
        "af_heart": ("American Heart (F)", "Feminine", .generalAmerican),
        "am_adam": ("American Adam (M)", "Masculine", .generalAmerican),
        "bf_emma": ("British Emma (F)", "Feminine", .britishRP),
        "bm_george": ("British George (M)", "Masculine", .britishRP),
        "af_bella": ("American Bella (F)", "Feminine", .generalAmerican),
        "am_michael": ("American Michael (M)", "Masculine", .generalAmerican)
    ]

    private func computeCosineSimilarity(a: [Float], b: [Float]) -> Float {
        guard a.count >= 128, b.count >= 128 else { return 0.0 }
        return a.withUnsafeBufferPointer { ptrA in
            b.withUnsafeBufferPointer { ptrB in
                let dist = MathService.cosineDistance(ptrA.baseAddress!, ptrB.baseAddress!, length: 128)
                return max(-1.0, min(1.0, 1.0 - dist))
            }
        }
    }

    /// Selects the optimal Kokoro base template based on target dialect, estimated fundamental pitch, and timbre cosine similarity.
    func resolveOptimalBaseVoice(
        for learnerStyle: [Float]?,
        estimatedF0: Float?,
        dialect: TargetAccentDialect = .generalAmerican,
        isChild: Bool = false
    ) -> VoiceTemplateMatch {
        // 1. Filter candidates by dialect
        let dialectCandidates = Self.stockVoiceMetadata.filter { $0.value.dialect == dialect }

        // 2. Classify vocal register
        let matchedRegister: String
        let registerFiltered: [String: (name: String, gender: String, dialect: TargetAccentDialect)]

        if isChild {
            matchedRegister = "Child / High Pitch"
            let feminine = dialectCandidates.filter { $0.value.gender == "Feminine" }
            registerFiltered = feminine.isEmpty ? dialectCandidates : feminine
        } else if let f0 = estimatedF0, f0 > 165.0 {
            matchedRegister = "Feminine / High Pitch (\(Int(round(f0))) Hz)"
            let feminine = dialectCandidates.filter { $0.value.gender == "Feminine" }
            registerFiltered = feminine.isEmpty ? dialectCandidates : feminine
        } else if let f0 = estimatedF0, f0 > 0.0, f0 < 155.0 {
            matchedRegister = "Masculine / Low Pitch (\(Int(round(f0))) Hz)"
            let masculine = dialectCandidates.filter { $0.value.gender == "Masculine" }
            registerFiltered = masculine.isEmpty ? dialectCandidates : masculine
        } else {
            matchedRegister = "Neutral / Default"
            registerFiltered = dialectCandidates
        }

        // 3. Compute cosine similarity if learner style vector is provided
        if let style = learnerStyle, style.count >= 128 {
            var bestVoiceId = registerFiltered.keys.first ?? (dialect == .britishRP ? "bf_emma" : "af_heart")
            var bestScore: Float = -Float.greatestFiniteMagnitude

            for (voiceId, _) in registerFiltered {
                if let baseEmb = self.voiceVectors[voiceId] {
                    let sim = computeCosineSimilarity(a: style, b: baseEmb)
                    if sim > bestScore {
                        bestScore = sim
                        bestVoiceId = voiceId
                    }
                }
            }

            let meta = Self.stockVoiceMetadata[bestVoiceId] ?? ("Default", "Feminine", dialect)
            return VoiceTemplateMatch(
                voiceId: bestVoiceId,
                displayName: meta.name,
                cosineSimilarity: max(0.0, bestScore),
                matchedRegister: matchedRegister,
                accentDialect: dialect
            )
        }

        // Fallback without style vector: choose the default for that register and dialect
        let defaultVoiceId: String
        if isChild || (estimatedF0 != nil && estimatedF0! > 165.0) {
            defaultVoiceId = dialect == .britishRP ? "bf_emma" : "af_heart"
        } else if let f0 = estimatedF0, f0 > 0.0, f0 < 155.0 {
            defaultVoiceId = dialect == .britishRP ? "bm_george" : "am_adam"
        } else {
            defaultVoiceId = dialect == .britishRP ? "bf_emma" : "af_heart"
        }

        let meta = Self.stockVoiceMetadata[defaultVoiceId] ?? ("Default", "Feminine", dialect)
        return VoiceTemplateMatch(
            voiceId: defaultVoiceId,
            displayName: meta.name,
            cosineSimilarity: 0.0,
            matchedRegister: matchedRegister,
            accentDialect: dialect
        )
    }

    // MARK: - Sentence Splitting for Natural Multi-Pass Synthesis

    private func splitIntoSentences(text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.bySentences, .localized]) { substring, _, _, _ in
            if let s = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                sentences.append(s)
            }
        }
        return sentences.isEmpty ? [text] : sentences
    }

    // MARK: - Pipeline Execution

    /// End-to-end voice cloning pipeline executed 100% in-process via CoreML on Apple Neural Engine.
    func clone(
        learnerAudioURL: URL? = nil,
        learnerStyle: [Float]? = nil,
        targetText: String,
        baseVoice: String = "auto",
        speed: Float = 1.0,
        tau: Float = 0.35,
        targetDialect: TargetAccentDialect = .generalAmerican,
        isChild: Bool = false
    ) async throws -> (outputURL: URL, inferenceDuration: Double, audioDuration: Double, rtf: Double) {

        guard isLoaded,
              let kokoro = kokoroModel,
              let _ = styleEncoderModel else {
            throw VoiceClonerError.engineNotReady
        }

        let startTime = CFAbsoluteTimeGetCurrent()

        return try await withCheckedThrowingContinuation { continuation in
            executionQueue.async {
                do {
                    // 1. Extract or Apply Learner Vocal Timbre
                    var learnerAcoustic: [Float]? = nil
                    var detectedF0: Float? = nil

                    if let style = learnerStyle, style.count >= 128 {
                        learnerAcoustic = Array(style.prefix(128))
                        print("VoiceCloner Pipeline: [1/4] Using pre-extracted learner profile timbre vector.")
                    } else if let url = learnerAudioURL, FileManager.default.fileExists(atPath: url.path) {
                        print("VoiceCloner Pipeline: [1/4] Extracting learner acoustic style on Neural Engine...")
                        let rawLearnerAudio = try self.loadAudioAt16kHz(url: url)
                        let tStyle = CFAbsoluteTimeGetCurrent()
                        learnerAcoustic = try self.extractLearnerStyle(audio: rawLearnerAudio)
                        detectedF0 = self.estimateMedianF0(audio: rawLearnerAudio)
                        let styleDurationMs = (CFAbsoluteTimeGetCurrent() - tStyle) * 1000.0
                        print("VoiceCloner Pipeline: [1/4] Extracted learner style in \(String(format: "%.1f", styleDurationMs)) ms (F0: \(Int(round(detectedF0 ?? 0))) Hz).")
                    } else {
                        print("VoiceCloner Pipeline: [1/4] No learner audio provided or file missing; synthesizing using canonical base voice.")
                    }

                    // 2. Resolve Base Voice (Intelligent Template Matching if "auto")
                    let effectiveBaseVoice: String
                    if baseVoice == "auto" || self.voiceVectors[baseVoice] == nil {
                        let match = self.resolveOptimalBaseVoice(
                            for: learnerAcoustic,
                            estimatedF0: detectedF0,
                            dialect: targetDialect,
                            isChild: isChild
                        )
                        effectiveBaseVoice = match.voiceId
                        print("VoiceCloner Pipeline: [2/4] Auto-matched base voice: '\(effectiveBaseVoice)' [\(match.displayName), register: \(match.matchedRegister), sim: \(String(format: "%.3f", match.cosineSimilarity))]")
                    } else {
                        effectiveBaseVoice = baseVoice
                    }

                    print("VoiceCloner Pipeline: [2/4] Blending style vector for voice '\(effectiveBaseVoice)' (tau=\(tau))...")
                    guard let baseEmb = self.voiceVectors[effectiveBaseVoice] ?? self.voiceVectors["af_heart"] else {
                        throw VoiceClonerError.voiceStyleNotFound(voice: effectiveBaseVoice)
                    }

                    var targetStyle = baseEmb
                    if let learner = learnerAcoustic {
                        // Dims 0..127: acoustic/timbre blend
                        for i in 0..<128 {
                            targetStyle[i] = tau * learner[i] + (1.0 - tau) * baseEmb[i]
                        }
                    }
                    // Dims 128..255: strictly preserved from base voice (native English prosody & cadence)

                    // 3. Sentence Chunking & Kokoro Inference
                    print("VoiceCloner Pipeline: [3/4] Synthesizing speech via Kokoro-82M FP16 CoreML...")
                    let isBritish = baseVoice.hasPrefix("b")
                    let sentences = self.splitIntoSentences(text: targetText)

                    var allAudioSamples: [Float] = []
                    let silenceSamples = [Float](repeating: 0, count: 1800) // ~75ms natural pause between sentences

                    for (idx, sentence) in sentences.enumerated() {
                        let (inputIds, mask, _) = self.textToInputIds(text: sentence, isBritish: isBritish)

                        let maxPhonemes = Self.maxTokensPerPass
                        let inputIdsArr = try MLMultiArray(shape: [1, NSNumber(value: maxPhonemes)], dataType: .int32)
                        let maskArr = try MLMultiArray(shape: [1, NSNumber(value: maxPhonemes)], dataType: .int32)
                        let styleArr = try MLMultiArray(shape: [1, NSNumber(value: Self.speakerEmbeddingDim)], dataType: .float32)
                        let speedArr = try MLMultiArray(shape: [1], dataType: .float32)
                        let phaseArr = try MLMultiArray(shape: [1, 9], dataType: .float32)

                        inputIds.withUnsafeBufferPointer { ptr in
                            let dest = inputIdsArr.dataPointer.bindMemory(to: Int32.self, capacity: maxPhonemes)
                            dest.initialize(from: ptr.baseAddress!, count: maxPhonemes)
                        }

                        mask.withUnsafeBufferPointer { ptr in
                            let dest = maskArr.dataPointer.bindMemory(to: Int32.self, capacity: maxPhonemes)
                            dest.initialize(from: ptr.baseAddress!, count: maxPhonemes)
                        }

                        targetStyle.withUnsafeBufferPointer { ptr in
                            let dest = styleArr.dataPointer.bindMemory(to: Float.self, capacity: Self.speakerEmbeddingDim)
                            dest.initialize(from: ptr.baseAddress!, count: Self.speakerEmbeddingDim)
                        }

                        speedArr[0] = NSNumber(value: speed)

                        for p in 0..<9 {
                            phaseArr[p] = NSNumber(value: Float.random(in: -Float.pi...Float.pi))
                        }

                        let kokoroInputs = try MLDictionaryFeatureProvider(dictionary: [
                            "input_ids": inputIdsArr,
                            "attention_mask": maskArr,
                            "ref_s": styleArr,
                            "speed": speedArr,
                            "random_phases": phaseArr
                        ])

                        let kokoroOut = try kokoro.prediction(from: kokoroInputs)

                        guard let audioFeature = kokoroOut.featureValue(for: "audio")?.multiArrayValue else {
                            throw VoiceClonerError.inferenceReturnedEmpty(stage: "Kokoro CoreML")
                        }

                        var lengthSamples = audioFeature.count
                        if let lengthFeature = kokoroOut.featureValue(for: "audio_length_samples")?.multiArrayValue {
                            lengthSamples = Int(lengthFeature[0].int32Value)
                        }

                        let audioPtr = audioFeature.dataPointer.bindMemory(to: Float.self, capacity: lengthSamples)
                        let chunkAudio = Array(UnsafeBufferPointer(start: audioPtr, count: lengthSamples))

                        allAudioSamples.append(contentsOf: chunkAudio)
                        if idx < sentences.count - 1 {
                            allAudioSamples.append(contentsOf: silenceSamples)
                        }
                    }

                    guard !allAudioSamples.isEmpty else {
                        throw VoiceClonerError.inferenceReturnedEmpty(stage: "Speech Synthesis")
                    }

                    // 4. Export Final Audio
                    print("VoiceCloner Pipeline: [4/4] Exporting high-fidelity 24kHz WAV...")
                    let tempDir = FileManager.default.temporaryDirectory
                    let outputFileName = "cloned_speech_\(Int(Date().timeIntervalSince1970)).wav"
                    let outputURL = tempDir.appendingPathComponent(outputFileName)

                    try self.writeWav(samples: allAudioSamples, sampleRate: Self.sampleRateKokoro, outputURL: outputURL)

                    let totalDuration = CFAbsoluteTimeGetCurrent() - startTime
                    let audioDuration = Double(allAudioSamples.count) / Self.sampleRateKokoro
                    let rtf = audioDuration > 0 ? (totalDuration / audioDuration) : 0.0

                    print(String(format: "VoiceCloner Pipeline: Finished! Audio: %.2fs | Latency: %.1fms | RTF: %.3fx",
                                 audioDuration, totalDuration * 1000.0, rtf))

                    continuation.resume(returning: (
                        outputURL: outputURL,
                        inferenceDuration: totalDuration,
                        audioDuration: audioDuration,
                        rtf: rtf
                    ))

                } catch {
                    print("VoiceCloner Pipeline Failed: \(error)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
