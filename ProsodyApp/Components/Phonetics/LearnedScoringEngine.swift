import Foundation
import CoreML

final class LearnedScoringEngine: @unchecked Sendable {
    static let shared = LearnedScoringEngine()
    
    private var model: MLModel? = nil
    private var sequenceModel: MLModel? = nil
    private let lock = NSLock()
    
    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return model != nil || sequenceModel != nil
    }

    var isSequenceReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sequenceModel != nil
    }

    static let canonicalPhonemes: [String] = [
        "<pad>", "<unk>",
        "p", "b", "t", "d", "k", "ɡ", "tʃ", "dʒ",
        "f", "v", "θ", "ð", "s", "z", "ʃ", "ʒ", "h",
        "m", "n", "ŋ", "l", "ɹ", "j", "w", "ɾ", "ʔ",
        "ɪ", "ɛ", "æ", "ʌ", "ɒ", "ʊ", "ə", "ɚ", "ɐ",
        "iː", "ɑː", "ɔː", "uː", "ɜː",
        "eɪ", "aɪ", "ɔɪ", "aʊ", "oʊ", "əʊ",
        "ɪɹ", "ɛɹ", "ʊɹ", "ɑːɹ", "ɔːɹ",
        "i", "u", "a", "e", "o", "ɑ", "ɔ",
        "ᵻ", "ɨ", "ʉ", "ɝ", "ɜ", "ər", "əl", "ən", "əm", "l̩", "n̩"
    ]
    static let phoneToId: [String: Int32] = {
        var map: [String: Int32] = [:]
        for (idx, sym) in canonicalPhonemes.enumerated() {
            map[sym] = Int32(idx)
        }
        return map
    }()
    static let vowelSet: Set<String> = [
        "i", "u", "a", "e", "o", "ɑ", "ɔ", "ɪ", "ɛ", "æ", "ʌ", "ɒ", "ʊ", "ə",
        "ɚ", "ɐ", "iː", "ɑː", "ɔː", "uː", "ɜː", "eɪ", "aɪ", "ɔɪ", "aʊ", "oʊ",
        "əʊ", "ɪɹ", "ɛɹ", "ʊɹ", "ɑːɹ", "ɔːɹ", "ᵻ", "ɨ", "ʉ", "ɝ", "ɜ", "ər"
    ]
    static func cleanPhoneSymbol(_ sym: String) -> String {
        return sym
            .replacingOccurrences(of: "ˈ", with: "")
            .replacingOccurrences(of: "ˌ", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .trimmingCharacters(in: .decimalDigits)
            .trimmingCharacters(in: .whitespaces)
    }
    
    static let featureNames19: [String] = [
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
        "embedding_stability",
        "top_competitor_mass_max",
        "phonetic_substitutions",
        "phonetic_deletions",
        "phonetic_insertions",
        "phonetic_match_ratio",
        "is_child",
        "pitch_zcr"
    ]

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
                break
            }
        }
        if self.model == nil {
            print("LearnedScoringEngine: Warning - WordIntelligibilityScorer.mlmodelc could not be loaded from any candidate path.")
        }

        let seqCandidates: [URL?] = [
            Bundle.main.url(forResource: "HiPAMALiteScorer", withExtension: "mlmodelc"),
            Bundle.main.resourceURL?.appendingPathComponent("HiPAMALiteScorer.mlmodelc"),
            Bundle(for: LearnedScoringEngine.self).url(forResource: "HiPAMALiteScorer", withExtension: "mlmodelc"),
            URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ProsodyApp/ProsodyApp/AI/Models/HiPAMALiteScorer.mlmodelc"),
            URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ScoringHead/models/HiPAMALiteScorer.mlmodelc")
        ]
        for candidate in seqCandidates {
            guard let url = candidate, FileManager.default.fileExists(atPath: url.path) else { continue }
            if let loaded = try? MLModel(contentsOf: url, configuration: config) {
                self.sequenceModel = loaded
                print("LearnedScoringEngine loaded HiPAMALiteScorer successfully from: \(url.path)")
                break
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
            print("LearnedScoringEngine loaded model from: \(compiledURL.path)")
        }
    }
    
    func predictSequenceScore(phones: [PhonemeFeedback], wordFeatures: [Float]) -> (score: Float, isError: Bool)? {
        lock.lock()
        guard let model = sequenceModel else {
            lock.unlock()
            return nil
        }
        lock.unlock()

        guard let targetIdsArray = try? MLMultiArray(shape: [1, 16], dataType: .int32),
              let compIdsArray = try? MLMultiArray(shape: [1, 16], dataType: .int32),
              let phoneFeatsArray = try? MLMultiArray(shape: [1, 16, 8], dataType: .float32),
              let phoneMaskArray = try? MLMultiArray(shape: [1, 16], dataType: .float32),
              let wordFeatsArray = try? MLMultiArray(shape: [1, 19], dataType: .float32) else {
            return nil
        }

        let targetPtr = targetIdsArray.dataPointer.bindMemory(to: Int32.self, capacity: 16)
        let compPtr = compIdsArray.dataPointer.bindMemory(to: Int32.self, capacity: 16)
        let featsPtr = phoneFeatsArray.dataPointer.bindMemory(to: Float.self, capacity: 16 * 8)
        let maskPtr = phoneMaskArray.dataPointer.bindMemory(to: Float.self, capacity: 16)
        let wordPtr = wordFeatsArray.dataPointer.bindMemory(to: Float.self, capacity: 19)

        targetPtr.initialize(repeating: 0, count: 16)
        compPtr.initialize(repeating: 0, count: 16)
        featsPtr.initialize(repeating: 0.0, count: 16 * 8)
        maskPtr.initialize(repeating: 0.0, count: 16)
        wordPtr.initialize(repeating: 0.0, count: 19)

        let phoneCount = min(phones.count, 16)
        for i in 0..<phoneCount {
            let p = phones[i]
            let cleanSym = Self.cleanPhoneSymbol(p.symbol)
            let cleanComp = Self.cleanPhoneSymbol(p.topCompetitorSymbol)
            
            targetPtr[i] = Self.phoneToId[cleanSym] ?? (Self.phoneToId["<unk>"] ?? 1)
            compPtr[i] = Self.phoneToId[cleanComp] ?? (Self.phoneToId["<unk>"] ?? 1)
            maskPtr[i] = 1.0

            let offset = i * 8
            featsPtr[offset + 0] = Float(p.score) / 100.0
            featsPtr[offset + 1] = log1p(max(0.0, Float(p.frames))) / 3.0
            featsPtr[offset + 2] = min(1.0, max(-1.0, p.phoneMargin / 5.0))
            featsPtr[offset + 3] = min(1.0, max(-1.0, p.posteriorMargin / 5.0))
            featsPtr[offset + 4] = min(1.0, max(0.0, p.targetMass / 10.0))
            featsPtr[offset + 5] = min(1.0, max(0.0, p.topCompetitorMass / 10.0))
            featsPtr[offset + 6] = Self.vowelSet.contains(cleanSym) ? 1.0 : 0.0
            featsPtr[offset + 7] = p.symbol.contains("ˈ") ? 1.0 : (p.symbol.contains("ˌ") ? 0.5 : 0.0)
        }

        let validIndices = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 15, 16, 17, 18, 19, 20, 21, 22]
        if wordFeatures.count >= 23 {
            for (outIdx, inIdx) in validIndices.enumerated() {
                wordPtr[outIdx] = wordFeatures[inIdx]
            }
        } else {
            let featCount = min(wordFeatures.count, 19)
            for i in 0..<featCount {
                wordPtr[i] = wordFeatures[i]
            }
        }

        do {
            let inputs: [String: MLFeatureValue] = [
                "target_ids": MLFeatureValue(multiArray: targetIdsArray),
                "comp_ids": MLFeatureValue(multiArray: compIdsArray),
                "phone_feats": MLFeatureValue(multiArray: phoneFeatsArray),
                "phone_mask": MLFeatureValue(multiArray: phoneMaskArray),
                "word_feats": MLFeatureValue(multiArray: wordFeatsArray)
            ]
            let provider = try MLDictionaryFeatureProvider(dictionary: inputs)
            let out = try model.prediction(from: provider)

            if let scoreVal = out.featureValue(for: "word_score")?.multiArrayValue {
                let score = scoreVal.dataPointer.bindMemory(to: Float.self, capacity: 1)[0]
                var isErr = false
                if let errVal = out.featureValue(for: "error_logit")?.multiArrayValue {
                    let logit = errVal.dataPointer.bindMemory(to: Float.self, capacity: 1)[0]
                    isErr = logit > 0.0
                }
                return (score, isErr)
            }
        } catch {
            print("HiPAMALite prediction failed: \(error)")
        }
        return nil
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
        } else if expectedCount == 19 {
            activeNames = LearnedScoringEngine.featureNames19
        } else if expectedCount == 23 {
            activeNames = LearnedScoringEngine.featureNames23
        } else {
            activeNames = features.count >= 30 ? LearnedScoringEngine.featureNames30 : (features.count >= 23 ? LearnedScoringEngine.featureNames23 : LearnedScoringEngine.featureNames19)
        }
        
        guard features.count >= activeNames.count else { return 5.0 }
        
        // Dictionary feature provider with exact named features expected by CoreML model schema
        var featureDict: [String: MLFeatureValue] = [:]
        
        // Map input vector into named lookup using the canonical 23/30 feature order
        var namedValues: [String: Double] = [:]
        let sourceNames = features.count >= 30 ? LearnedScoringEngine.featureNames30 : (features.count >= 23 ? LearnedScoringEngine.featureNames23 : LearnedScoringEngine.featureNames19)
        for (idx, name) in sourceNames.enumerated() {
            if idx < features.count {
                namedValues[name] = Double(features[idx])
            }
        }
        
        for name in activeNames {
            let val = namedValues[name] ?? 0.0
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
