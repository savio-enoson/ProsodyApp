//
//  LearnedConfidenceEngine.swift
//  ProsodyApp
//
//  Created for Prosody STT Confidence & Discrepancy Detection (Phase 3).
//

import Foundation
import CoreML

final class LearnedConfidenceEngine: @unchecked Sendable {
    static let shared = LearnedConfidenceEngine()
    
    private var model: MLModel? = nil
    private let lock = NSLock()
    
    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return model != nil
    }
    
    static let featureNames15: [String] = [
        "align_score",
        "ensemble_score",
        "literal_score",
        "frame_entropy",
        "mean_blank_prob",
        "max_nonblank_run",
        "blank_oscillation_rate",
        "phonetic_match_ratio",
        "word_length",
        "is_function_word",
        "is_content_word",
        "word_duration_ms",
        "has_whisper_match",
        "has_sfspeech_match",
        "consensus_veto"
    ]
    
    static let featureNames16: [String] = featureNames15 + [
        "beam_consensus"
    ]
    
    static var featureNames: [String] {
        return featureNames16
    }
    
    private let loaderQueue = DispatchQueue(label: "com.prosody.learnedconfidence.loader", qos: .userInitiated)
    
    init() {
        loaderQueue.async { [weak self] in
            self?.loadModelIfAvailable()
        }
    }
    
    func loadModelIfAvailable() {
        lock.lock()
        defer { lock.unlock() }
        
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "STTConfidenceScorer", withExtension: "mlmodelc"),
            Bundle.main.resourceURL?.appendingPathComponent("STTConfidenceScorer.mlmodelc"),
            Bundle(for: LearnedConfidenceEngine.self).url(forResource: "STTConfidenceScorer", withExtension: "mlmodelc"),
            URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ProsodyApp/ProsodyApp/AI/Models/STTConfidenceScorer.mlmodelc"),
            URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ScoringHead/STTConfidenceScorer.mlmodelc")
        ]
        
        let config = MLModelConfiguration()
        config.computeUnits = .all
        
        for candidate in candidates {
            guard let url = candidate, FileManager.default.fileExists(atPath: url.path) else { continue }
            if let loaded = try? MLModel(contentsOf: url, configuration: config) {
                self.model = loaded
                print("LearnedConfidenceEngine loaded STTConfidenceScorer successfully from: \(url.path)")
                return
            }
        }
        print("LearnedConfidenceEngine: Warning - STTConfidenceScorer.mlmodelc could not be loaded from any candidate path.")
    }
    
    func loadModel(from compiledURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        self.model = try? MLModel(contentsOf: compiledURL, configuration: config)
        if self.model != nil {
            print("LearnedConfidenceEngine loaded model from: \(compiledURL.path)")
        }
    }
    
    /// Predicts P(stt_correct == 1) ∈ [0.0, 1.0] given the 15-dimensional confidence feature vector.
    func predictConfidence(features: [Float]) -> Float {
        lock.lock()
        guard let model = model else {
            lock.unlock()
            return 0.5
        }
        let expectedCount = model.modelDescription.inputDescriptionsByName.count
        lock.unlock()
        
        let activeNames: [String] = expectedCount == 16 ? LearnedConfidenceEngine.featureNames16 : LearnedConfidenceEngine.featureNames15
        guard features.count >= activeNames.count else { return 0.5 }
        
        var featureDict: [String: MLFeatureValue] = [:]
        for (idx, name) in activeNames.enumerated() {
            let val: Double = idx < features.count ? Double(features[idx]) : 0.0
            featureDict[name] = MLFeatureValue(double: val)
        }
        
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: featureDict)
            let output = try model.prediction(from: provider)
            
            // CoreML TreeEnsembleClassifier returns dictionary of class probabilities
            if let probDict = output.featureValue(for: "classProbability")?.dictionaryValue {
                // Key 1 represents P(stt_correct == 1)
                if let p1 = probDict[1 as NSNumber]?.doubleValue {
                    return Float(p1)
                }
            }
            
            // Fallback to discrete prediction
            if let predictedClass = output.featureValue(for: "stt_correct")?.int64Value {
                return predictedClass == 1 ? 1.0 : 0.0
            }
        } catch {
            print("LearnedConfidenceEngine prediction error: \(error)")
        }
        
        return 0.5
    }
}
