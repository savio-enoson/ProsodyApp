import Foundation
import CoreAI
import Accelerate
import AVFoundation
import Combine

// MARK: - State & Errors

public enum NemotronState: Equatable, Sendable {
    case uninitialized
    case loading(String)
    case ready
    case failed(String)
}

public enum NemotronError: Error, LocalizedError {
    case unsupportedSampleRate(Int)
    case modelsMissing(String)
    case resourcesMissing(String)
    case sessionFinished
    case functionFailed(String)
    case missingOutput(String)
    case notReady

    public var errorDescription: String? {
        switch self {
        case .unsupportedSampleRate(let sr):
            return "Audio must be 16 kHz mono; received \(sr) Hz."
        case .modelsMissing(let path):
            return "Nemotron 3.5 Core AI models not found at \(path)."
        case .resourcesMissing(let res):
            return "Nemotron supporting resource missing: \(res)."
        case .sessionFinished:
            return "Nemotron streaming session has already finished."
        case .functionFailed(let msg):
            return "Core AI graph execution failed: \(msg)"
        case .missingOutput(let name):
            return "Core AI graph did not emit expected output '\(name)'."
        case .notReady:
            return "Nemotron STT Service is not ready."
        }
    }
}

// MARK: - Internal Tensor Value Wrapper

public struct NemotronTensorValue: Sendable {
    enum Storage {
        case float16([Float16])
        case float32([Float])
        case int32([Int32])
    }
    let storage: Storage
    public let shape: [Int]

    init(storage: Storage, shape: [Int]) {
        self.storage = storage
        self.shape = shape
    }

    public static func float16(_ scalars: [Float16], shape: [Int]) -> NemotronTensorValue {
        NemotronTensorValue(storage: .float16(scalars), shape: shape)
    }

    public static func float32(_ scalars: [Float], shape: [Int]) -> NemotronTensorValue {
        NemotronTensorValue(storage: .float32(scalars), shape: shape)
    }

    public static func int32(_ scalars: [Int32], shape: [Int]) -> NemotronTensorValue {
        NemotronTensorValue(storage: .int32(scalars), shape: shape)
    }

    public func floats() -> [Float] {
        switch storage {
        case .float16(let v): return v.map(Float.init)
        case .float32(let v): return v
        case .int32(let v): return v.map(Float.init)
        }
    }

    func makeNDArray(descriptor: NDArrayDescriptor, inputName: String) throws -> NDArray {
        var array = NDArray(descriptor: descriptor)
        switch (storage, descriptor.scalarType) {
        case (.float16(let v), .float16):
            var view = array.mutableView(as: Float16.self)
            view.copyElements(fromContentsOf: v)
        case (.float32(let v), .float16):
            var view = array.mutableView(as: Float16.self)
            view.copyElements(fromContentsOf: v.map(Float16.init))
        case (.float16(let v), .float32):
            var view = array.mutableView(as: Float.self)
            view.copyElements(fromContentsOf: v.map(Float.init))
        case (.float32(let v), .float32):
            var view = array.mutableView(as: Float.self)
            view.copyElements(fromContentsOf: v)
        case (.int32(let v), .int32):
            var view = array.mutableView(as: Int32.self)
            view.copyElements(fromContentsOf: v)
        default:
            throw NemotronError.functionFailed("Dtype mismatch for input \(inputName): expected \(descriptor.scalarType)")
        }
        return array
    }

    init(reading array: NDArray) {
        let shape = array.shape
        let count = shape.reduce(1, *)
        switch array.scalarType {
        case .float16:
            let values = array.view(as: Float16.self).withUnsafePointer { ptr, _, _ in
                Array(UnsafeBufferPointer(start: ptr, count: count))
            }
            self.init(storage: .float16(values), shape: shape)
        case .float32:
            let values = array.view(as: Float.self).withUnsafePointer { ptr, _, _ in
                Array(UnsafeBufferPointer(start: ptr, count: count))
            }
            self.init(storage: .float32(values), shape: shape)
        case .int32:
            let values = array.view(as: Int32.self).withUnsafePointer { ptr, _, _ in
                Array(UnsafeBufferPointer(start: ptr, count: count))
            }
            self.init(storage: .int32(values), shape: shape)
        default:
            fatalError("Unsupported NDArray scalarType: \(array.scalarType)")
        }
    }
}

// MARK: - Direct CoreAI Graph Wrapper

public final class NemotronCoreAIGraph: @unchecked Sendable {
    private let function: InferenceFunction
    private let descriptor: InferenceFunctionDescriptor
    public let outputNames: [String]

    public init(url: URL) async throws {
        let model = try await AIModel(contentsOf: url, options: SpecializationOptions(preferredComputeUnitKind: .gpu))
        guard let desc = model.functionDescriptor(for: "main"),
              let fn = try model.loadFunction(named: "main") else {
            throw NemotronError.functionFailed("Failed to load main function from \(url.lastPathComponent)")
        }
        self.descriptor = desc
        self.function = fn
        self.outputNames = desc.outputNames
    }

    public func run(_ inputs: [String: NemotronTensorValue]) async throws -> [String: NemotronTensorValue] {
        var ndInputs: [String: NDArray] = [:]
        for (name, val) in inputs {
            guard case .ndArray(let d) = descriptor.inputDescriptor(of: name) else {
                throw NemotronError.functionFailed("Unknown input: \(name)")
            }
            let resolved = d.resolvingDynamicDimensions(val.shape)
            ndInputs[name] = try val.makeNDArray(descriptor: resolved, inputName: name)
        }
        var rawOutputs = try await function.run(inputs: ndInputs)
        var outputs: [String: NemotronTensorValue] = [:]
        for name in outputNames {
            guard let array = rawOutputs.remove(name)?.ndArray else {
                throw NemotronError.missingOutput(name)
            }
            outputs[name] = NemotronTensorValue(reading: array)
        }
        return outputs
    }
}

// MARK: - Streaming Log-Mel Frontend

final class NemotronMelStream {
    static let nFFT = 512
    static let winLength = 400
    static let hop = 160
    static let nMels = 128
    static let nFreq = nFFT / 2 + 1
    static let preemphasis: Float = 0.97
    static let logGuard = Float(exactly: pow(2.0, -24))!

    static let firstChunkFrames = 25
    static let chunkFrames = 32

    private let window: [Float]
    private let cosMat: [Float]
    private let sinMat: [Float]
    private let melFilters: [Float]

    private var buffer: [Float] = []
    private var bufferBase = 0
    private var prevSample: Float?
    private var nextFrame = 0
    private var pending: [[Float]] = []
    private(set) var chunksEmitted = 0

    init(melFilters: [Float]) {
        precondition(melFilters.count == Self.nMels * Self.nFreq, "melFilters must be [128, 257]")
        self.melFilters = melFilters

        var win = [Float](repeating: 0, count: Self.nFFT)
        let offset = (Self.nFFT - Self.winLength) / 2
        for n in 0..<Self.winLength {
            win[offset + n] = 0.5 - 0.5 * cos(2 * .pi * Float(n) / Float(Self.winLength - 1))
        }
        self.window = win

        var c = [Float](repeating: 0, count: Self.nFreq * Self.nFFT)
        var s = [Float](repeating: 0, count: Self.nFreq * Self.nFFT)
        for k in 0..<Self.nFreq {
            for n in 0..<Self.nFFT {
                let a = 2 * Float.pi * Float(k) * Float(n) / Float(Self.nFFT)
                c[k * Self.nFFT + n] = cos(a)
                s[k * Self.nFFT + n] = sin(a)
            }
        }
        self.cosMat = c
        self.sinMat = s
    }

    func push(_ samples: [Float]) -> [[Float]] {
        guard !samples.isEmpty else { return [] }
        var y = [Float](repeating: 0, count: samples.count)
        y[0] = prevSample.map { samples[0] - Self.preemphasis * $0 } ?? samples[0]
        for t in 1..<samples.count { y[t] = samples[t] - Self.preemphasis * samples[t - 1] }
        prevSample = samples[samples.count - 1]
        buffer.append(contentsOf: y)

        let total = bufferBase + buffer.count
        while Self.hop * nextFrame + Self.winLength / 2 <= total {
            pending.append(computeFrame(nextFrame))
            nextFrame += 1
        }

        let keepFrom = max(0, Self.hop * nextFrame - Self.nFFT / 2)
        if keepFrom > bufferBase {
            buffer.removeFirst(keepFrom - bufferBase)
            bufferBase = keepFrom
        }

        var out: [[Float]] = []
        while pending.count >= (chunksEmitted == 0 ? Self.firstChunkFrames : Self.chunkFrames) {
            let n = chunksEmitted == 0 ? Self.firstChunkFrames : Self.chunkFrames
            var chunk = [Float](repeating: 0, count: n * Self.nMels)
            for (i, f) in pending.prefix(n).enumerated() {
                chunk.replaceSubrange(i * Self.nMels ..< (i + 1) * Self.nMels, with: f)
            }
            pending.removeFirst(n)
            chunksEmitted += 1
            out.append(chunk)
        }
        return out
    }

    private func computeFrame(_ t: Int) -> [Float] {
        let nFFT = Self.nFFT, nFreq = Self.nFreq, nMels = Self.nMels
        let lo = Self.hop * t - nFFT / 2
        var seg = [Float](repeating: 0, count: nFFT)
        let srcLo = max(lo, 0)
        let start = srcLo - bufferBase
        let count = min(lo + nFFT, bufferBase + buffer.count) - srcLo
        if count > 0 {
            seg.replaceSubrange(srcLo - lo ..< srcLo - lo + count, with: buffer[start ..< start + count])
        }
        var w = [Float](repeating: 0, count: nFFT)
        vDSP_vmul(seg, 1, window, 1, &w, 1, vDSP_Length(nFFT))

        var re = [Float](repeating: 0, count: nFreq)
        var im = [Float](repeating: 0, count: nFreq)
        vDSP_mmul(cosMat, 1, w, 1, &re, 1, vDSP_Length(nFreq), 1, vDSP_Length(nFFT))
        vDSP_mmul(sinMat, 1, w, 1, &im, 1, vDSP_Length(nFreq), 1, vDSP_Length(nFFT))
        var power = [Float](repeating: 0, count: nFreq)
        vDSP_vsq(re, 1, &re, 1, vDSP_Length(nFreq))
        vDSP_vsq(im, 1, &im, 1, vDSP_Length(nFreq))
        vDSP_vadd(re, 1, im, 1, &power, 1, vDSP_Length(nFreq))

        var mel = [Float](repeating: 0, count: nMels)
        vDSP_mmul(melFilters, 1, power, 1, &mel, 1, vDSP_Length(nMels), 1, vDSP_Length(nFreq))
        var guardV = Self.logGuard
        vDSP_vsadd(mel, 1, &guardV, &mel, 1, vDSP_Length(nMels))
        var n32 = Int32(nMels)
        vvlogf(&mel, mel, &n32)
        return mel
    }
}

// MARK: - Streaming Session

public final class NemotronStreamingSession: @unchecked Sendable {
    private let preFirst: NemotronCoreAIGraph
    private let pre: NemotronCoreAIGraph
    private let conformerA: NemotronCoreAIGraph
    private let conformerB: NemotronCoreAIGraph
    private let predict: NemotronCoreAIGraph
    private let joint: NemotronCoreAIGraph
    private let vocab: [String]
    private let melStream: NemotronMelStream
    private let oneHotTensor: NemotronTensorValue

    // Conformer state caches
    private var kCacheA: NemotronTensorValue
    private var vCacheA: NemotronTensorValue
    private var convCacheA: NemotronTensorValue
    private var kCacheB: NemotronTensorValue
    private var vCacheB: NemotronTensorValue
    private var convCacheB: NemotronTensorValue

    // Pre-encoder state caches
    private var cache0: NemotronTensorValue?
    private var cache1: NemotronTensorValue?
    private var cache2: NemotronTensorValue?

    // Predictor / Decoder state
    private var h: [Float]
    private var c: [Float]
    private var dec: [Float] = []
    private var encFrames: [Float] = []
    private var emitted: [(token: Int, frame: Int)] = []

    private var chunkIndex = 0
    private var frame = 0
    private var symbolsOnFrame = 0
    private var primed = false
    private var isFinished = false
    private var totalSamplesSeen = 0

    public private(set) var transcript: String = ""

    init(
        preFirst: NemotronCoreAIGraph,
        pre: NemotronCoreAIGraph,
        conformerA: NemotronCoreAIGraph,
        conformerB: NemotronCoreAIGraph,
        predict: NemotronCoreAIGraph,
        joint: NemotronCoreAIGraph,
        melFilters: [Float],
        vocab: [String],
        promptIndex: Int
    ) {
        self.preFirst = preFirst
        self.pre = pre
        self.conformerA = conformerA
        self.conformerB = conformerB
        self.predict = predict
        self.joint = joint
        self.vocab = vocab
        self.melStream = NemotronMelStream(melFilters: melFilters)

        var oh = [Float16](repeating: 0, count: 128)
        if promptIndex >= 0 && promptIndex < 128 {
            oh[promptIndex] = 1.0
        } else {
            oh[0] = 1.0 // fallback en-US
        }
        self.oneHotTensor = NemotronTensorValue.float16(oh, shape: [1, 128])

        let kvShape = [12, 8, 56, 128]
        let convShape = [12, 1024, 8]
        self.kCacheA = NemotronTensorValue.float16([Float16](repeating: 0, count: 12 * 8 * 56 * 128), shape: kvShape)
        self.vCacheA = NemotronTensorValue.float16([Float16](repeating: 0, count: 12 * 8 * 56 * 128), shape: kvShape)
        self.convCacheA = NemotronTensorValue.float16([Float16](repeating: 0, count: 12 * 1024 * 8), shape: convShape)
        self.kCacheB = NemotronTensorValue.float16([Float16](repeating: 0, count: 12 * 8 * 56 * 128), shape: kvShape)
        self.vCacheB = NemotronTensorValue.float16([Float16](repeating: 0, count: 12 * 8 * 56 * 128), shape: kvShape)
        self.convCacheB = NemotronTensorValue.float16([Float16](repeating: 0, count: 12 * 1024 * 8), shape: convShape)

        self.h = [Float](repeating: 0, count: 2 * 1 * 640)
        self.c = [Float](repeating: 0, count: 2 * 1 * 640)
    }

    private func primeIfNeeded() async throws {
        guard !primed else { return }
        let primeOut = try await predict.run([
            "token": NemotronTensorValue.int32([13087], shape: [1, 1]),
            "h": NemotronTensorValue.float32(h, shape: [2, 1, 640]),
            "c": NemotronTensorValue.float32(c, shape: [2, 1, 640])
        ])
        h = primeOut["h_out"]!.floats()
        c = primeOut["c_out"]!.floats()
        dec = primeOut["dec_out"]!.floats()
        primed = true
    }

    private func negMask(chunkIdx: Int) -> NemotronTensorValue {
        let q = 4, kv = 60
        let valid = min(56, q * chunkIdx)
        var mask = [Float16](repeating: 0, count: q * kv)
        let maskedCols = 56 - valid
        if maskedCols > 0 {
            for row in 0..<q {
                for col in 0..<maskedCols { mask[row * kv + col] = -Float16.infinity }
            }
        }
        return NemotronTensorValue.float16(mask, shape: [1, 1, q, kv])
    }

    private func processChunk(_ chunk: [Float]) async throws {
        try await primeIfNeeded()
        let frames = chunk.count / 128

        let embeds: NemotronTensorValue
        if chunkIndex == 0 {
            let out = try await preFirst.run([
                "mel": NemotronTensorValue.float32(chunk, shape: [1, frames, 128])
            ])
            embeds = out["embeds"]!
            cache0 = out["cache0"]!
            cache1 = out["cache1"]!
            cache2 = out["cache2"]!
        } else {
            let out = try await pre.run([
                "mel": NemotronTensorValue.float32(chunk, shape: [1, frames, 128]),
                "cache0": cache0!, "cache1": cache1!, "cache2": cache2!
            ])
            embeds = out["embeds"]!
            cache0 = out["cache0_out"]!
            cache1 = out["cache1_out"]!
            cache2 = out["cache2_out"]!
        }

        let neg = negMask(chunkIdx: chunkIndex)
        let outA = try await conformerA.run([
            "embeds": embeds,
            "neg_mask": neg,
            "k_cache": kCacheA, "v_cache": vCacheA, "conv_cache": convCacheA
        ])
        kCacheA = outA["k_out"]!
        vCacheA = outA["v_out"]!
        convCacheA = outA["conv_out"]!

        let outB = try await conformerB.run([
            "embeds": outA["embeds_out"]!,
            "one_hot": oneHotTensor,
            "neg_mask": neg,
            "k_cache": kCacheB, "v_cache": vCacheB, "conv_cache": convCacheB
        ])
        kCacheB = outB["k_out"]!
        vCacheB = outB["v_out"]!
        convCacheB = outB["conv_out"]!

        let encChunk = outB["enc_proj"]!.floats()
        encFrames.append(contentsOf: encChunk)
        chunkIndex += 1

        // Greedy RNN-T decode
        let totalEncFrames = encFrames.count / 640
        var newTokensEmitted = false
        while frame < totalEncFrames {
            let encFrame = Array(encFrames[frame * 640 ..< (frame + 1) * 640])
            let jout = try await joint.run([
                "dec_out": NemotronTensorValue.float32(dec, shape: [1, 640]),
                "enc_frame": NemotronTensorValue.float32(encFrame, shape: [1, 640])
            ])
            let logits = jout["token_logits"]!.floats()
            var best = 0
            var bestVal = -Float.greatestFiniteMagnitude
            for i in 0..<13088 where logits[i] > bestVal {
                bestVal = logits[i]
                best = i
            }

            if best == 13087 {
                frame += 1
                symbolsOnFrame = 0
            } else {
                emitted.append((token: best, frame: frame))
                newTokensEmitted = true
                let predOut = try await predict.run([
                    "token": NemotronTensorValue.int32([Int32(best)], shape: [1, 1]),
                    "h": NemotronTensorValue.float32(h, shape: [2, 1, 640]),
                    "c": NemotronTensorValue.float32(c, shape: [2, 1, 640])
                ])
                h = predOut["h_out"]!.floats()
                c = predOut["c_out"]!.floats()
                dec = predOut["dec_out"]!.floats()
                symbolsOnFrame += 1
                if symbolsOnFrame >= 10 {
                    frame += 1
                    symbolsOnFrame = 0
                }
            }
        }

        if newTokensEmitted {
            updateTranscript()
        }
    }

    private func updateTranscript() {
        var raw = emitted.map { vocab[$0.token] }.joined()
        while let r = raw.range(of: #"<[A-Za-z]{2,4}(-[A-Za-z]{2,4})?>"#, options: .regularExpression) {
            raw.removeSubrange(r)
        }
        transcript = raw.replacingOccurrences(of: "\u{2581}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Feeds live audio samples (16kHz mono). Returns running partial transcript.
    @discardableResult
    public func feed(samples: [Float]) async throws -> String {
        guard !isFinished else { throw NemotronError.sessionFinished }
        totalSamplesSeen += samples.count
        let chunks = melStream.push(samples)
        for chunk in chunks {
            try await processChunk(chunk)
        }
        return transcript
    }

    /// Flushes end of stream and returns final transcript and word-level timestamps.
    func finish() async throws -> (transcript: String, wordTimings: [WordTimestamp]) {
        guard !isFinished else { throw NemotronError.sessionFinished }

        // Flush tail with silence until the last real sample's frame has decoded plus right-context lookahead
        let lastFrame = (totalSamplesSeen + NemotronMelStream.winLength / 2 - 1) / NemotronMelStream.hop
        let targetFrame = lastFrame + NemotronMelStream.chunkFrames
        let silence = [Float](repeating: 0, count: NemotronMelStream.hop * 8)
        var guardIters = 0
        while (melStream.chunksEmitted == 0 ? 0 : (NemotronMelStream.firstChunkFrames + (melStream.chunksEmitted - 1) * NemotronMelStream.chunkFrames)) <= targetFrame && guardIters < 64 {
            for chunk in melStream.push(silence) {
                try await processChunk(chunk)
            }
            guardIters += 1
        }
        isFinished = true
        updateTranscript()

        // Extract Word Timestamps from emitted token frames
        var wordTimings: [WordTimestamp] = []
        var curWord = ""
        var curStartFrame: Int?
        var lastTokenFrame = 0

        for item in emitted {
            let piece = vocab[item.token]
            if piece.hasPrefix("<") && piece.hasSuffix(">") { continue }
            let isNew = piece.hasPrefix("\u{2581}")
            let clean = piece.replacingOccurrences(of: "\u{2581}", with: "")

            if isNew && !curWord.isEmpty {
                let s = Double(curStartFrame ?? lastTokenFrame) * 0.080
                let e = Double(lastTokenFrame + 1) * 0.080
                let duration = max(0.040, e - s)
                wordTimings.append(WordTimestamp(word: curWord, startTime: s, duration: duration, alignmentScore: 1.0))
                curWord = ""
                curStartFrame = item.frame
            } else if curStartFrame == nil {
                curStartFrame = item.frame
            }
            curWord += clean
            lastTokenFrame = item.frame
        }
        if !curWord.isEmpty {
            let s = Double(curStartFrame ?? lastTokenFrame) * 0.080
            let e = Double(lastTokenFrame + 1) * 0.080
            let duration = max(0.040, e - s)
            wordTimings.append(WordTimestamp(word: curWord, startTime: s, duration: duration, alignmentScore: 1.0))
        }

        return (transcript: transcript, wordTimings: wordTimings)
    }
}

// MARK: - Nemotron STT Service Singleton

@MainActor
public final class NemotronSTTService: ObservableObject {
    public static let shared = NemotronSTTService()

    @Published public private(set) var state: NemotronState = .uninitialized
    @Published public private(set) var liveTranscript: String = ""
    @Published public private(set) var isStreaming: Bool = false

    private var preFirstGraph: NemotronCoreAIGraph?
    private var preGraph: NemotronCoreAIGraph?
    private var conformerAGraph: NemotronCoreAIGraph?
    private var conformerBGraph: NemotronCoreAIGraph?
    private var predictGraph: NemotronCoreAIGraph?
    private var jointGraph: NemotronCoreAIGraph?

    private var melFilters: [Float]?
    private var vocab: [String]?

    private var currentSession: NemotronStreamingSession?
    private var isInitializing = false

    public static let promptDictionary: [String: Int] = [
        "en-US": 0, "en-GB": 1, "es-ES": 2, "es-US": 3, "zh-CN": 4, "zh-TW": 5, "hi-IN": 6,
        "ar": 7, "fr-FR": 8, "de": 9, "ja-JP": 10, "ru": 11, "pt-BR": 12, "pt-PT": 13,
        "ko-KR": 14, "it": 15, "nl": 16, "pl": 17, "tr": 18, "uk": 19, "ro": 20, "el": 21,
        "cs": 22, "hu": 23, "sv": 24, "da": 25, "fi": 26, "no": 27, "sk": 28, "hr": 29,
        "bg": 30, "lt": 31, "th-TH": 32, "vi-VN": 33, "id-ID": 34, "ms-MY": 35, "bn-IN": 36,
        "ur-PK": 37, "fa-IR": 38, "ta-IN": 39, "te-IN": 40, "mr-IN": 41, "gu-IN": 42,
        "kn-IN": 43, "ml-IN": 44, "si-LK": 45, "ne-NP": 46, "km-KH": 47, "sw-KE": 48,
        "am-ET": 49, "ha-NG": 50, "zu-ZA": 51, "yo-NG": 52, "ig-NG": 53, "af-ZA": 54,
        "auto": 101
    ]

    private init() {}

    // MARK: - Resource & Model Resolution

    private func resolveModelDirectory() -> URL? {
        let fm = FileManager.default

        // 1. Environment variable override
        if let env = ProcessInfo.processInfo.environment["PROSODY_NEMOTRON_DIR"] {
            let u = URL(fileURLWithPath: env)
            if fm.fileExists(atPath: u.path) { return u }
        }

        // 2. Application Support location
        let appSupport = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Prosody/Nemotron-3.5-ASR-Streaming/macos")
        if fm.fileExists(atPath: appSupport.path) {
            return appSupport
        }

        // 3. App Bundle location
        if let bundleDir = Bundle.main.url(forResource: "Nemotron", withExtension: nil)?.appendingPathComponent("macos"),
           fm.fileExists(atPath: bundleDir.path) {
            return bundleDir
        }

        return nil
    }

    private func resolveResourceURL(name: String, ext: String) -> URL? {
        let fm = FileManager.default
        // Check bundle first
        if let u = Bundle.main.url(forResource: name, withExtension: ext) {
            return u
        }
        // Fallback to project AI/Resources
        let fallback = URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ProsodyApp/ProsodyApp/AI/Resources/\(name).\(ext)")
        if fm.fileExists(atPath: fallback.path) {
            return fallback
        }
        return nil
    }

    // MARK: - Initialization

    public func initializeIfNeeded() async {
        if state == .ready, preFirstGraph != nil { return }
        if isInitializing { return }
        isInitializing = true
        state = .loading("Loading Nemotron 3.5 Core AI models...")

        do {
            guard let modelDir = resolveModelDirectory() else {
                let expected = "~/Library/Application Support/Prosody/Nemotron-3.5-ASR-Streaming/macos"
                throw NemotronError.modelsMissing(expected)
            }

            guard let melURL = resolveResourceURL(name: "mel_filters_128x257_f32", ext: "bin") else {
                throw NemotronError.resourcesMissing("mel_filters_128x257_f32.bin")
            }
            guard let tokURL = resolveResourceURL(name: "nemotron_tokenizer", ext: "json") else {
                throw NemotronError.resourcesMissing("nemotron_tokenizer.json")
            }

            // Load Mel filterbank
            let melData = try Data(contentsOf: melURL)
            self.melFilters = melData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

            // Load Vocab table
            let tokData = try Data(contentsOf: tokURL)
            guard let tokJson = try JSONSerialization.jsonObject(with: tokData) as? [String: Any],
                  let modelObj = tokJson["model"] as? [String: Any],
                  let vocabDict = modelObj["vocab"] as? [String: Int] else {
                throw NemotronError.resourcesMissing("Could not parse vocab from nemotron_tokenizer.json")
            }
            var vTable = [String](repeating: "", count: 13088)
            for (k, v) in vocabDict {
                if v < vTable.count { vTable[v] = k }
            }
            self.vocab = vTable

            // Load 6 Core AI graphs
            let pf = try await NemotronCoreAIGraph(url: modelDir.appendingPathComponent("nemotron_asr_stream_pre_first_float16.aimodel"))
            let p = try await NemotronCoreAIGraph(url: modelDir.appendingPathComponent("nemotron_asr_stream_pre_float16.aimodel"))
            let ca = try await NemotronCoreAIGraph(url: modelDir.appendingPathComponent("nemotron_asr_stream_conformer_a_float16.aimodel"))
            let cb = try await NemotronCoreAIGraph(url: modelDir.appendingPathComponent("nemotron_asr_stream_conformer_b_float16.aimodel"))
            let pr = try await NemotronCoreAIGraph(url: modelDir.appendingPathComponent("nemotron_asr_predict_float32.aimodel"))
            let jt = try await NemotronCoreAIGraph(url: modelDir.appendingPathComponent("nemotron_asr_joint_float32.aimodel"))

            self.preFirstGraph = pf
            self.preGraph = p
            self.conformerAGraph = ca
            self.conformerBGraph = cb
            self.predictGraph = pr
            self.jointGraph = jt

            self.state = .ready
            print("NemotronSTTService: initialized successfully on Apple Core AI.")
        } catch {
            self.state = .failed(error.localizedDescription)
            print("NemotronSTTService: initialization failed with error: \(error)")
        }
        isInitializing = false
    }

    // MARK: - Live Streaming API

    public func startStreaming(language: String = "en-US") throws {
        guard state == .ready,
              let pf = preFirstGraph, let p = preGraph,
              let ca = conformerAGraph, let cb = conformerBGraph,
              let pr = predictGraph, let jt = jointGraph,
              let filters = melFilters, let v = vocab else {
            throw NemotronError.notReady
        }

        let promptIdx = Self.promptDictionary[language] ?? 0
        currentSession = NemotronStreamingSession(
            preFirst: pf, pre: p,
            conformerA: ca, conformerB: cb,
            predict: pr, joint: jt,
            melFilters: filters, vocab: v,
            promptIndex: promptIdx
        )
        liveTranscript = ""
        isStreaming = true
    }

    @discardableResult
    public func feedLiveAudio(chunk: [Float]) async throws -> String {
        guard let session = currentSession, isStreaming else {
            throw NemotronError.sessionFinished
        }
        let updated = try await session.feed(samples: chunk)
        self.liveTranscript = updated
        return updated
    }

    func finishStreaming() async throws -> (transcript: String, wordTimings: [WordTimestamp]) {
        guard let session = currentSession, isStreaming else {
            throw NemotronError.sessionFinished
        }
        let result = try await session.finish()
        self.liveTranscript = result.transcript
        self.isStreaming = false
        self.currentSession = nil
        return result
    }

    // MARK: - Batch / Utterance Convenience API

    func transcribe(
        audioFloats: [Float],
        language: String = "en-US"
    ) async throws -> (transcript: String, wordTimings: [WordTimestamp]) {
        if state != .ready {
            await initializeIfNeeded()
        }
        try startStreaming(language: language)

        let step = 1600 // 100ms chunks for smooth incremental feed
        var offset = 0
        while offset < audioFloats.count {
            let end = min(offset + step, audioFloats.count)
            let slice = Array(audioFloats[offset..<end])
            try await feedLiveAudio(chunk: slice)
            offset = end
        }
        return try await finishStreaming()
    }
}
