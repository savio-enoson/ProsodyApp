import Foundation
import AVFoundation
import Combine
#if canImport(WhisperKit)
import WhisperKit
#endif

enum WhisperState: Equatable {
    case uninitialized
    case loading(String)
    case ready(String)
    case failed(String)
}

@MainActor
class WhisperSTTService: ObservableObject {
    static let shared = WhisperSTTService()
    
    @Published var state: WhisperState = .uninitialized
    @Published var currentModelName: String = ""
    
    #if canImport(WhisperKit)
    private var pipe: WhisperKit?
    #endif
    
    private var isInitializing = false
    
    init() {}
    
    func initializeIfNeeded(modelVariant: WhisperModelVariant = .base) async {
        #if canImport(WhisperKit)
        if case .ready(let model) = state, model == modelVariant.modelName, pipe != nil {
            return
        }
        if isInitializing { return }
        isInitializing = true
        
        state = .loading("Loading \(modelVariant.displayName)...")
        currentModelName = modelVariant.modelName
        
        do {
            let config = WhisperKitConfig(
                model: modelVariant.modelName,
                verbose: false,
                logLevel: .error
            )
            let whisper = try await WhisperKit(config)
            self.pipe = whisper
            self.state = .ready(modelVariant.modelName)
            print("WhisperKit initialized successfully with model: \(modelVariant.modelName)")
        } catch {
            self.state = .failed(error.localizedDescription)
            print("Failed to initialize WhisperKit: \(error)")
        }
        isInitializing = false
        #else
        self.state = .failed("WhisperKit module not available")
        #endif
    }
    
    func transcribe(
        audioFloats: [Float],
        prompt: String? = nil,
        modelVariant: WhisperModelVariant? = nil
    ) async throws -> (transcript: String, wordTimings: [WordTimestamp]) {
        #if canImport(WhisperKit)
        let targetVariant = modelVariant ?? STTSettings.shared.whisperModel
        if pipe == nil || currentModelName != targetVariant.modelName {
            await initializeIfNeeded(modelVariant: targetVariant)
        }
        guard let pipe = self.pipe else {
            throw NSError(domain: "WhisperSTTService", code: -1, userInfo: [NSLocalizedDescriptionKey: "WhisperKit model is not initialized"])
        }
        
        var options = DecodingOptions(wordTimestamps: true)
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            if let tokens = pipe.tokenizer?.encode(text: prompt), !tokens.isEmpty {
                options.promptTokens = tokens
            }
        }
        
        let results = try await pipe.transcribe(audioArray: audioFloats, decodeOptions: options)
        let fullText = results.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .replacingOccurrences(of: "[APPLAUSE]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Extract word-level timestamps
        var wordTimings: [WordTimestamp] = []
        for result in results {
            let words = result.allWords
            for w in words {
                let clean = w.word.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
                if !clean.isEmpty {
                    let startT = Double(w.start)
                    let endT = Double(w.end)
                    let duration = max(0.04, endT - startT)
                    wordTimings.append(WordTimestamp(word: clean, startTime: startT, duration: duration, alignmentScore: 1.0))
                }
            }
        }
        
        // Fallback to proportional segmentation if word-level timestamps are not emitted
        if wordTimings.isEmpty && !fullText.isEmpty {
            let words = fullText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            let totalDuration = Double(audioFloats.count) / 16000.0
            let durPerWord = max(0.04, totalDuration / Double(max(1, words.count)))
            for (idx, word) in words.enumerated() {
                let clean = word.trimmingCharacters(in: CharacterSet.punctuationCharacters)
                let startT = Double(idx) * durPerWord
                wordTimings.append(WordTimestamp(word: clean, startTime: startT, duration: durPerWord, alignmentScore: 1.0))
            }
        }
        
        return (fullText, wordTimings)
        #else
        throw NSError(domain: "WhisperSTTService", code: -2, userInfo: [NSLocalizedDescriptionKey: "WhisperKit module not available"])
        #endif
    }
}
