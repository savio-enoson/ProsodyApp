import Foundation
import AVFoundation
import Combine
import CoreML

/// Standardized Manager singleton for speech recognition, decoding, and language modeling.
@MainActor
final class STTManager: ObservableObject {
    static let shared = STTManager()
    
    // Internal engines
    let inference: InferenceEngine
    let whisperService = WhisperSTTService.shared
    let settings = STTSettings.shared
    
    // Decoding components
    let trie: LexiconTrie
    let decoder: CTCDecoder
    let languageModel: LanguageModel?
    let vocab: [String]
    
    public static let standardContractions: [String] = [
        "i'm", "i'll", "i've", "i'd",
        "you're", "you'll", "you've", "you'd",
        "he's", "he'll", "he'd",
        "she's", "she'll", "she'd",
        "it's", "it'll",
        "we're", "we'll", "we've", "we'd",
        "they're", "they'll", "they've", "they'd",
        "that's", "what's", "who's", "where's", "when's", "why's", "how's",
        "there's", "here's", "let's",
        "can't", "cannot", "couldn't", "won't", "wouldn't",
        "don't", "doesn't", "didn't",
        "isn't", "aren't", "wasn't", "weren't",
        "haven't", "hasn't", "hadn't",
        "shouldn't", "mustn't", "'em"
    ]
    
    private init() {
        // 1. Load Wav2Vec2 Vocabulary
        let vocabURL = Bundle.main.url(forResource: "wav2vec2_vocab", withExtension: "json") ??
            URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ProsodyApp/ProsodyApp/AI/Resources/wav2vec2_vocab.json")
        if let vdata = try? Data(contentsOf: vocabURL),
           let loadedVocab = try? JSONDecoder().decode([String].self, from: vdata) {
            self.vocab = loadedVocab
        } else {
            print("WARNING: Could not load wav2vec2_vocab.json.")
            self.vocab = [String](repeating: "a", count: 32)
        }
        
        // 2. Load Compact Language Model
        let lmURL = Bundle.main.url(forResource: "lm_compact", withExtension: "bin") ??
            URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ProsodyApp/ProsodyApp/AI/Resources/lm_compact.bin")
        if let lm = LanguageModel(contentsOf: lmURL) {
            self.languageModel = lm
        } else {
            self.languageModel = nil
        }
        
        // 3. Load Lexicon Trie with LM vocabulary and contractions
        var wordList: [String] = []
        let wordsURL = Bundle.main.url(forResource: "words_alpha", withExtension: "txt") ??
            URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ProsodyApp/ProsodyApp/AI/Resources/words_alpha.txt")
        if let wordsStr = try? String(contentsOf: wordsURL, encoding: .utf8) {
            wordList = wordsStr.replacingOccurrences(of: "\r", with: "")
                .components(separatedBy: .newlines)
                .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else if let dictStr = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) {
            wordList = dictStr.components(separatedBy: .newlines).map { $0.lowercased() }
        }
        if let lm = self.languageModel {
            wordList.append(contentsOf: lm.vocabulary)
        }
        wordList.append(contentsOf: STTManager.standardContractions)
        self.trie = LexiconTrie(words: wordList)
        
        // 4. Initialize CTC Decoder & Conformer Engine
        self.decoder = CTCDecoder(trie: self.trie, vocab: self.vocab, blankIndex: 0, languageModel: self.languageModel)
        self.inference = InferenceEngine(decoder: self.decoder)
    }
    
    /// Synchronous initialization constructor for CLI evaluation environments
    init(synchronous: Bool) {
        let vocabURL = Bundle.main.url(forResource: "wav2vec2_vocab", withExtension: "json") ??
            URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ProsodyApp/ProsodyApp/AI/Resources/wav2vec2_vocab.json")
        let loadedVocab: [String]
        if let vdata = try? Data(contentsOf: vocabURL),
           let v = try? JSONDecoder().decode([String].self, from: vdata) {
            loadedVocab = v
        } else {
            loadedVocab = [String](repeating: "a", count: 32)
        }
        self.vocab = loadedVocab
        
        let lmURL = Bundle.main.url(forResource: "lm_compact", withExtension: "bin") ??
            URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ProsodyApp/ProsodyApp/AI/Resources/lm_compact.bin")
        let lm = LanguageModel(contentsOf: lmURL)
        self.languageModel = lm
        
        var wordList: [String] = []
        let wordsURL = Bundle.main.url(forResource: "words_alpha", withExtension: "txt") ??
            URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ProsodyApp/ProsodyApp/AI/Resources/words_alpha.txt")
        if let wordsStr = try? String(contentsOf: wordsURL, encoding: .utf8) {
            wordList = wordsStr.replacingOccurrences(of: "\r", with: "")
                .components(separatedBy: .newlines)
                .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else if let dictStr = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) {
            wordList = dictStr.components(separatedBy: .newlines).map { $0.lowercased() }
        }
        if let loadedLm = lm {
            wordList.append(contentsOf: loadedLm.vocabulary)
        }
        wordList.append(contentsOf: STTManager.standardContractions)
        let trie = LexiconTrie(words: wordList)
        self.trie = trie
        
        let decoder = CTCDecoder(trie: trie, vocab: self.vocab, blankIndex: 0, languageModel: self.languageModel)
        self.decoder = decoder
        let engine = InferenceEngine(decoder: decoder, synchronousLoad: synchronous)
        engine.useLearnedScoringHead = self.settings.useLearnedScoringHead
        self.inference = engine
    }
    
    /// Asynchronous pipeline processing based on active engine setting
    func transcribe(audioFloats: [Float]) async throws -> (transcript: String, literal: String, wordTimings: [WordTimestamp]) {
        switch settings.engineType {
        case .whisperKit:
            let whisper = try await whisperService.transcribe(audioFloats: audioFloats)
            let literal = inference.latestLiteralTranscript
            return (transcript: whisper.transcript, literal: literal, wordTimings: whisper.wordTimings)
            
        case .acousticMirror:
            inference.process(audioChunk: audioFloats)
            return (transcript: inference.latestTranscript, literal: inference.latestLiteralTranscript, wordTimings: inference.wordTimestamps ?? [])
        }
    }
    
    /// Forward audio processing to Wav2Vec2 Conformer
    func process(audioChunk: [Float]) {
        inference.process(audioChunk: audioChunk)
    }
    
    /// Forward live streaming chunks for partial decoding
    func processLive(audioChunk: [Float]) {
        inference.processLive(audioChunk: audioChunk)
    }
    
    /// Synchronous transcription entry point for CLI and batch evaluations
    func processSynchronously(audioChunk: [Float], reference: String? = nil) -> (snapped: String, literal: String, wordTimestamps: [WordTimestamp], logProbs: [[Float]], hiddenStates: MLMultiArray?, topBeams: [String])? {
        return inference.processSynchronously(audioChunk: audioChunk, reference: reference)
    }

    /// Prewarms the speech inference engine and underlying models.
    func prewarm() {
        _ = inference
    }
}
