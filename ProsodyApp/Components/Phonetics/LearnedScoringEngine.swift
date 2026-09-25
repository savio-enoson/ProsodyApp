import Foundation
import CoreML

final class LearnedScoringEngine: @unchecked Sendable {
    static let shared = LearnedScoringEngine()
    
    private var model: MLModel? = nil
    private let lock = NSLock()
    
    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return model != nil
    }
    
    static let featureNames23: [String] = [
        "base_gop_score",
        "min_phone_score",
        "vowel_nucleus_score",
        "consonant_score",
        "phone_margin_mean",
        "alignment_confidence",
        "duration_ratio",
        "stress_ratio",
        "is_content_word",
        "is_clitic",
        "word_len_phones",
        "has_exact_literal",
        "has_sfspeech_match",
        "consensus_code",
        "word_dtw_distance",
        "embedding_stability",
        "top_competitor_mass_max",
        "phonetic_substitutions",
        "phonetic_deletions",
        "phonetic_insertions",
        "phonetic_match_ratio",
        "is_child",
        "pitch_zcr"
    ]

    static let featureNames30: [String] = [
        "base_gop_score",
        "min_phone_score",
        "vowel_nucleus_score",
        "consonant_score",
        "phone_margin_mean",
        "alignment_confidence",
        "duration_ratio",
        "stress_ratio",
        "is_content_word",
        "is_clitic",
        "word_len_phones",
        "has_exact_literal",
        "has_sfspeech_match",
        "consensus_code",
        "word_dtw_distance",
        "embedding_stability",
        "top_competitor_mass_max",
        "phonetic_substitutions",
        "phonetic_deletions",
        "phonetic_insertions",
        "phonetic_match_ratio",
        "is_child",
        "pitch_zcr",
        "initial_phone_score",
        "final_phone_score",
        "stressed_vowel_score",
        "coda_is_deleted",
        "max_deletion_run",
        "has_consonant_cluster",
        "n_syllables"
    ]

    static var featureNames: [String] {
        return featureNames23
    }
    
    private let loaderQueue = DispatchQueue(label: "com.prosody.learnedscoring.loader", qos: .userInitiated)
    
    init() {
        loaderQueue.async { [weak self] in
            self?.loadModelIfAvailable()
        }
    }
    
    func loadModelIfAvailable() {
        lock.lock()
        defer { lock.unlock() }
        
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "WordIntelligibilityScorer", withExtension: "mlmodelc"),
            Bundle.main.resourceURL?.appendingPathComponent("WordIntelligibilityScorer.mlmodelc"),
            Bundle(for: LearnedScoringEngine.self).url(forResource: "WordIntelligibilityScorer", withExtension: "mlmodelc"),
            URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ProsodyApp/ProsodyApp/AI/Models/WordIntelligibilityScorer.mlmodelc"),
            URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ScoringHead/WordIntelligibilityScorer.mlmodelc")
        ]
        
        let config = MLModelConfiguration()
        config.computeUnits = .all
        
        for candidate in candidates {
            guard let url = candidate, FileManager.default.fileExists(atPath: url.path) else { continue }
            if let loaded = try? MLModel(contentsOf: url, configuration: config) {
                self.model = loaded
                print("LearnedScoringEngine loaded WordIntelligibilityScorer successfully from: \(url.path)")
                return
            }
        }
        print("LearnedScoringEngine: Warning - WordIntelligibilityScorer.mlmodelc could not be loaded from any candidate path.")
    }
    
    func loadModel(from compiledURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        self.model = try? MLModel(contentsOf: compiledURL, configuration: config)
        if self.model != nil {
            print("LearnedScoringEngine loaded model from: \(compiledURL.path)")
        }
    }
    
    func predictScore(features: [Float]) -> Float {
        lock.lock()
        guard let model = model else {
            lock.unlock()
            return 5.0
        }
        let expectedCount = model.modelDescription.inputDescriptionsByName.count
        lock.unlock()
        
        let activeNames: [String]
        if expectedCount == 30 {
            activeNames = LearnedScoringEngine.featureNames30
        } else if expectedCount == 23 {
            activeNames = LearnedScoringEngine.featureNames23
        } else {
            activeNames = features.count >= 30 ? LearnedScoringEngine.featureNames30 : LearnedScoringEngine.featureNames23
        }
        
        guard features.count >= activeNames.count else { return 5.0 }
        
        // Dictionary feature provider with exact named features expected by CoreML model schema
        var featureDict: [String: MLFeatureValue] = [:]
        for (idx, name) in activeNames.enumerated() {
            let val: Double = idx < features.count ? Double(features[idx]) : 0.0
            featureDict[name] = MLFeatureValue(double: val)
        }
        
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: featureDict)
            let output = try model.prediction(from: provider)
            if let scoreVal = output.featureValue(for: "score")?.doubleValue {
                return Float(scoreVal)
            }
            if let targetVal = output.featureValue(for: "target")?.doubleValue {
                return Float(targetVal)
            }
        } catch {
            print("LearnedScoringEngine prediction error: \(error)")
        }
        
        return 5.0
    }
}
