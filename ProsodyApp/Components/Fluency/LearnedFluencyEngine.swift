import Foundation
import CoreML

/// On-device CoreML runtime engine executing the trained FluencyScorer GBDT.
/// Thread-safe singleton providing sub-millisecond continuous fluency prediction.
nonisolated final class LearnedFluencyEngine: @unchecked Sendable {
    static let shared = LearnedFluencyEngine()
    
    private var model: MLModel? = nil
    private let lock = NSLock()
    
    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return model != nil
    }
    
    static var featureNames: [String] {
        FluencyEngine.featureNames
    }
    
    private let loaderQueue = DispatchQueue(label: "com.prosody.learnedfluency.loader", qos: .userInitiated)
    
    init() {
        loaderQueue.async { [weak self] in
            self?.loadModelIfAvailable()
        }
    }
    
    func loadModelIfAvailable() {
        lock.lock()
        defer { lock.unlock() }
        
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "FluencyScorer", withExtension: "mlmodelc"),
            Bundle.main.resourceURL?.appendingPathComponent("FluencyScorer.mlmodelc"),
            Bundle(for: LearnedFluencyEngine.self).url(forResource: "FluencyScorer", withExtension: "mlmodelc"),
            URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ProsodyApp/ProsodyApp/AI/Models/FluencyScorer.mlmodelc"),
            URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ScoringHead/FluencyScorer.mlmodelc")
        ]
        
        let config = MLModelConfiguration()
        config.computeUnits = .all
        
        for candidate in candidates {
            guard let url = candidate, FileManager.default.fileExists(atPath: url.path) else { continue }
            if let loaded = try? MLModel(contentsOf: url, configuration: config) {
                self.model = loaded
                print("LearnedFluencyEngine loaded FluencyScorer successfully from: \(url.path)")
                return
            }
        }
    }
    
    func loadModel(from compiledURL: URL) {
        lock.lock()
        defer { lock.unlock() }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        self.model = try? MLModel(contentsOf: compiledURL, configuration: config)
        if self.model != nil {
            print("LearnedFluencyEngine loaded model from: \(compiledURL.path)")
        }
    }
    
    /// Predicts continuous human rating (0.0 - 10.0) from the feature vector.
    func predictScore(features: [Float]) -> Float {
        lock.lock()
        guard let model = model else {
            lock.unlock()
            return 8.0
        }
        let inputDescriptions = model.modelDescription.inputDescriptionsByName
        lock.unlock()
        
        let activeNames = FluencyEngine.featureNames
        guard features.count >= activeNames.count else { return 8.0 }
        
        var featureDict: [String: MLFeatureValue] = [:]
        for (idx, name) in activeNames.enumerated() {
            if inputDescriptions[name] != nil || inputDescriptions.isEmpty {
                let val: Double = Double(features[idx])
                featureDict[name] = MLFeatureValue(double: val)
            }
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
            print("LearnedFluencyEngine prediction error: \(error)")
        }
        
        return 8.0
    }
}
