import Foundation
import Combine

public enum STTEngineType: String, CaseIterable, Identifiable, Codable {
    case acousticMirror = "acousticMirror"
    case whisperKit = "whisperKit"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .acousticMirror:
            return "Acoustic Mirror (Wav2Vec2)"
        case .whisperKit:
            return "WhisperKit (Neural ASR)"
        }
    }
    
    public var description: String {
        switch self {
        case .acousticMirror:
            return "Raw acoustic subword beam search with lexicon trie constraints. Shows exact grammatical and phonetic stumbles."
        case .whisperKit:
            return "High-accuracy neural end-to-end ASR. Robust against non-native accents to establish the intended target words."
        }
    }
}

public enum WhisperModelVariant: String, CaseIterable, Identifiable, Codable {
    case base = "openai_whisper-base.en"
    case tiny = "openai_whisper-tiny.en"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .base:
            return "Base English (Recommended, ~140MB)"
        case .tiny:
            return "Tiny English (Fastest, ~75MB)"
        }
    }
    
    public var modelName: String {
        return rawValue
    }
}

public enum LLMProviderType: String, CaseIterable, Identifiable, Codable {
    case appleIntelligence = "appleIntelligence"
    case ollama = "ollama"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .appleIntelligence:
            return "Apple Intelligence (On-Device)"
        case .ollama:
            return "Ollama (Local Models)"
        }
    }

    public var description: String {
        switch self {
        case .appleIntelligence:
            return "Apple's native system foundation models with fast on-device inference and background prewarming."
        case .ollama:
            return "Local open-weight models running via Ollama (e.g. Gemma 4 MLX), offering deeper reasoning and offline flexibility."
        }
    }
}

public class STTSettings: ObservableObject {
    public static let shared = STTSettings()
    
    private let engineKey = "prosody_stt_engine_type"
    private let modelKey = "prosody_whisper_model_variant"
    private let scoringHeadKey = "prosody_use_learned_scoring_head"
    private let confidenceHeadKey = "prosody_use_learned_confidence_head"
    private let isChildKey = "prosody_is_child_mode"
    private let llmProviderKey = "prosody_llm_provider_type"
    private let ollamaModelKey = "prosody_ollama_model"
    private let ollamaEndpointKey = "prosody_ollama_endpoint"
    nonisolated public static let passingThresholdKey = "prosody_passing_threshold"
    nonisolated public static let defaultPassingThreshold = 65
    private let drillThresholdKey = "prosody_drill_threshold"
    private let targetDialectKey = "prosody_target_accent_dialect"

    nonisolated public static var currentPassingThreshold: Int {
        let val = UserDefaults.standard.integer(forKey: passingThresholdKey)
        return val > 0 ? val : defaultPassingThreshold
    }
    
    @Published public var engineType: STTEngineType {
        didSet {
            UserDefaults.standard.set(engineType.rawValue, forKey: engineKey)
        }
    }
    
    @Published public var whisperModel: WhisperModelVariant {
        didSet {
            UserDefaults.standard.set(whisperModel.rawValue, forKey: modelKey)
        }
    }

    @Published public var llmProvider: LLMProviderType {
        didSet {
            UserDefaults.standard.set(llmProvider.rawValue, forKey: llmProviderKey)
        }
    }

    @Published public var ollamaModel: String {
        didSet {
            UserDefaults.standard.set(ollamaModel, forKey: ollamaModelKey)
        }
    }

    @Published public var ollamaEndpoint: String {
        didSet {
            UserDefaults.standard.set(ollamaEndpoint, forKey: ollamaEndpointKey)
        }
    }

    /// Unified identifier for the selected base language model.
    /// Returns "apple-intelligence" for Apple Foundation Models, or the model name (e.g. "gemma4:e4b-mlx") for Ollama.
    public var selectedBaseModelID: String {
        get {
            llmProvider == .appleIntelligence ? "apple-intelligence" : ollamaModel
        }
        set {
            objectWillChange.send()
            if newValue == "apple-intelligence" {
                llmProvider = .appleIntelligence
            } else {
                llmProvider = .ollama
                ollamaModel = newValue
            }
        }
    }

    /// Threshold (50-85%) where scores at or above are considered .good (green). Default is 65%.
    @Published public var passingThreshold: Int {
        didSet {
            UserDefaults.standard.set(passingThreshold, forKey: Self.passingThresholdKey)
            if drillThreshold > passingThreshold {
                drillThreshold = passingThreshold
            }
        }
    }

    /// Threshold (40-75%) below which words trigger AI Coach practice drills and Golden Speaker synthesis. Default is 60%.
    @Published public var drillThreshold: Int {
        didSet {
            UserDefaults.standard.set(drillThreshold, forKey: drillThresholdKey)
            if drillThreshold > passingThreshold {
                passingThreshold = drillThreshold
            }
        }
    }
    
    @Published public var useLearnedScoringHead: Bool {
        didSet {
            UserDefaults.standard.set(useLearnedScoringHead, forKey: scoringHeadKey)
            DispatchQueue.main.async {
                STTManager.shared.inference.useLearnedScoringHead = self.useLearnedScoringHead
            }
        }
    }
    
    @Published public var useLearnedConfidenceHead: Bool {
        didSet {
            UserDefaults.standard.set(useLearnedConfidenceHead, forKey: confidenceHeadKey)
            DispatchQueue.main.async {
                STTManager.shared.inference.useLearnedConfidenceHead = self.useLearnedConfidenceHead
            }
        }
    }
    
    @Published public var isChildLearnerMode: Bool {
        didSet {
            UserDefaults.standard.set(isChildLearnerMode, forKey: isChildKey)
        }
    }

    @Published public var targetDialect: TargetAccentDialect {
        didSet {
            UserDefaults.standard.set(targetDialect.rawValue, forKey: targetDialectKey)
        }
    }
    
    public init() {
        if let savedEngine = UserDefaults.standard.string(forKey: engineKey),
           let engine = STTEngineType(rawValue: savedEngine) {
            self.engineType = engine
        } else {
            self.engineType = .acousticMirror
        }
        
        if let savedModel = UserDefaults.standard.string(forKey: modelKey),
           let model = WhisperModelVariant(rawValue: savedModel) {
            self.whisperModel = model
        } else {
            self.whisperModel = .base
        }
        
        self.useLearnedScoringHead = true
        self.useLearnedConfidenceHead = true
        
        if UserDefaults.standard.object(forKey: isChildKey) != nil {
            self.isChildLearnerMode = UserDefaults.standard.bool(forKey: isChildKey)
        } else {
            self.isChildLearnerMode = false
        }

        if let savedDialect = UserDefaults.standard.string(forKey: targetDialectKey),
           let dialect = TargetAccentDialect(rawValue: savedDialect) {
            self.targetDialect = dialect
        } else {
            self.targetDialect = .generalAmerican
        }

        if let savedProvider = UserDefaults.standard.string(forKey: llmProviderKey),
           let provider = LLMProviderType(rawValue: savedProvider) {
            self.llmProvider = provider
        } else {
            self.llmProvider = .appleIntelligence
        }

        if let savedOllamaModel = UserDefaults.standard.string(forKey: ollamaModelKey),
           !savedOllamaModel.isEmpty {
            self.ollamaModel = savedOllamaModel
        } else {
            self.ollamaModel = "gemma4:e2b-mlx"
        }

        if let savedOllamaEndpoint = UserDefaults.standard.string(forKey: ollamaEndpointKey),
           !savedOllamaEndpoint.isEmpty {
            self.ollamaEndpoint = savedOllamaEndpoint
        } else {
            self.ollamaEndpoint = "http://localhost:11434"
        }

        if UserDefaults.standard.object(forKey: Self.passingThresholdKey) != nil {
            self.passingThreshold = UserDefaults.standard.integer(forKey: Self.passingThresholdKey)
        } else {
            self.passingThreshold = 65
        }

        if UserDefaults.standard.object(forKey: drillThresholdKey) != nil {
            self.drillThreshold = UserDefaults.standard.integer(forKey: drillThresholdKey)
        } else {
            self.drillThreshold = 60
        }
    }

    /// Resets passing and drill remediation thresholds to canonical recommended defaults (65% and 60%).
    public func resetThresholds() {
        self.passingThreshold = 65
        self.drillThreshold = 60
    }
}
