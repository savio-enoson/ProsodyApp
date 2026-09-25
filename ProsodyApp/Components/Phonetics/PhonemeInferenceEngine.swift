import CoreML

nonisolated struct PhonemeInferenceEngine: @unchecked Sendable {
    private let wav2vec2Model: MLModel
    let vocabulary: [String] = ["<pad>", "<s>", "</s>", "<unk>", "n", "s", "t", "ə", "l", "a", "i", "k", "d", "m", "ɛ", "ɾ", "e", "ɪ", "p", "o", "ɐ", "z", "ð", "f", "j", "v", "b", "ɹ", "ʁ", "ʊ", "iː", "r", "w", "ʌ", "u", "ɡ", "æ", "aɪ", "ʃ", "h", "ɔ", "ɑː", "ŋ", "ɚ", "eɪ", "β", "uː", "y", "ɑ̃", "oʊ", "ᵻ", "eː", "θ", "aʊ", "ts", "oː", "ɔ̃", "ɣ", "ɜ", "ɑ", "dʒ", "əl", "x", "ɜː", "ç", "ʒ", "tʃ", "ɔː", "ɑːɹ", "ɛ̃", "ʎ", "ɔːɹ", "ʋ", "aː", "ɕ", "œ", "ø", "oːɹ", "ɲ", "yː", "ʔ", "iə", "i5", "s.", "tɕ", "??", "nʲ", "ɛː", "œ̃", "ɭ", "ɔø", "ʑ", "tʲ", "ɨ", "ɛɹ", "ts.", "rʲ", "ɪɹ", "ɭʲ", "i.5", "ɔɪ", "q", "sʲ", "u5", "ʊɹ", "iɜ", "a5", "iɛ5", "øː", "ʕ", "ja", "əɜ", "th", "ɑ5", "oɪ", "dʲ", "ə5", "tɕh", "ts.h", "mʲ", "ɯ", "dʑ", "vʲ", "e̞", "tʃʲ", "ei5", "o5", "onɡ5", "ɑu5", "iɑ5", "ai5", "aɪɚ", "kh", "ə1", "ʐ", "i2", "ʉ", "ħ", "t[", "aɪə", "ʲ", "ju", "ə2", "u2", "oɜ", "pː", "iɛɜ", "ou5", "y5", "uɜ", "tː", "uo5", "d[", "uoɜ", "tsh", "ɑɜ", "ɵ", "i̪5", "uei5", "ɟ", "aɜ", "ɑɨ", "i.ɜ", "eʊ", "o2", "ɐ̃", "ä", "pʲ", "kʲ", "n̩", "ɒ", "ph", "ɑu2", "uɨ", "əɪ", "ɫ", "ɬ", "yɜ", "bʲ", "ɑ2", "s̪", "aiɜ", "χ", "ɐ̃ʊ̃", "1", "ə4", "yæɜ", "a2", "ɨː", "t̪", "iouɜ", "ũ", "onɡɜ", "aɨ", "iɛ2", "ɔɨ", "ɑuɜ", "o̞", "ei2", "iou2", "c", "kː", "y2", "ɖ", "oe", "dˤ", "yɛɜ", "əʊ", "S", "ɡʲ", "onɡ2", "u\"", "eiɜ", "ʈ", "ɯᵝ", "iou5", "dZ", "r̝̊", "i.2", "tS", "s^", "ʝ", "yə5", "iɑɜ", "uə5", "pf", "ɨu", "iɑ2", "ou2", "ər2", "fʲ", "ai2", "r̝", "uəɜ", "ɳ", "əɨ", "ua5", "uɪ", "ɽ", "bː", "yu5", "uo2", "yɛ5", "l̩", "ɻ", "ərɜ", "ʂ", "i̪2", "ouɜ", "uaɜ", "a.", "a.ː", "yæ5", "dː", "r̩", "ee", "ɪu", "ər5", "i̪ɜ", "æi", "u:", "i.ː", "t^", "o1", "ɪ^", "ai", "ueiɜ", "æː", "ɛɪ", "eə", "i.", "ɴ", "ie", "ua2", "ɑ1", "o4", "tʃː", "o:", "ɑ:", "u1", "N", "i̪1", "au", "yæ2", "u.", "qː", "yəɜ", "y:", "kʰ", "tʃʰ", "iʊ", "sx", "õ", "uo", "tʰ", "uai5", "bʰ", "u.ː", "uə2", "ʊə", "d^", "s̪ː", "yiɜ", "dʰ", "r.", "oe:", "i1", "ɟː", "yu2", "nʲʲ", "i̪4", "uei2", "tsʲ", "ɸ", "ĩ", "ɑ4", "t̪ː", "eɑ", "u4", "e:", "tsː", "ʈʰ", "ɡʰ", "ɯɯ", "dʒʲ", "ʂʲ", "X", "ɵː", "uaiɜ", "tɕʲ", "ã", "t^ː", "ẽː", "yɛ2", "cː", "i.1", "ɛʊ", "dˤdˤ", "dʒː", "i4", "ɡː", "yi", "ɕʲ", "ɟʰ", "pʰ", "dʑʲ", "yuɜ", "ua1", "ua4", "æiː", "ɐɐ", "ui", "iou1", "ʊː", "a1", "iou4", "cʰ", "iɛ1", "yə2", "ɖʰ", "ẽ", "ʒʲ", "ää", "ər4", "iːː", "ɪː", "iɑ1", "ər1", "œː", "øi", "ɪuː", "cʰcʰ", "əː1", "iː1", "ũ", "kʰː", "o̞o̞", "xʲ", "ou1", "iɛ4", "e̞e̞", "y1", "dzː", "dʲʲ", "dʰː", "ɯᵝɯᵝ", "lː", "uo1", "i.4", "i:", "yɛ5ʲ", "a4"]
    
    init(model: MLModel) {
        self.wav2vec2Model = model
    }
    
    static func load(modelURL: URL) async throws -> PhonemeInferenceEngine {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        let model = try await MLModel.load(contentsOf: modelURL, configuration: config)
        return PhonemeInferenceEngine(model: model)
    }

    
    func extractUserLogits(from userBuffer: MLMultiArray) throws -> MLMultiArray {
        let inputFeature = try MLDictionaryFeatureProvider(dictionary: ["audio": MLFeatureValue(multiArray: userBuffer)])
        let output = try wav2vec2Model.prediction(from: inputFeature)
        let featureName = output.featureNames.first!
        return output.featureValue(for: featureName)!.multiArrayValue!
    }
    
    /// The English IPA symbol set. Symbols outside this set that appear in the
    /// multilingual Wav2Vec2Phonetic vocabulary are artefacts of the model's
    /// multilingual training data (tone markers, retroflex consonants, etc.) and
    /// are excluded from the greedy decode sequence used for consonant-skeleton and
    /// vowel-substitution checks.
    ///
    /// This filter is NOT applied to raw logits — only to the greedy argmax sequence.
    static let englishPhonemeSet: Set<String> = [
        // Stops
        "p", "b", "t", "d", "k", "ɡ",
        // Affricates
        "tʃ", "dʒ",
        // Fricatives
        "f", "v", "θ", "ð", "s", "z", "ʃ", "ʒ", "h",
        // Nasals
        "m", "n", "ŋ",
        // Approximants
        "l", "ɹ", "j", "w",
        // Taps / Flaps (common in American English)
        "ɾ", "ʔ",
        // Short monophthong vowels
        "ɪ", "ɛ", "æ", "ʌ", "ɒ", "ʊ", "ə", "ɚ", "ɐ",
        // Long monophthong vowels
        "iː", "ɑː", "ɔː", "uː", "ɜː",
        // Diphthongs
        "eɪ", "aɪ", "ɔɪ", "aʊ", "oʊ", "əʊ",
        // Rhotic vowels / linking-r
        "ɪɹ", "ɛɹ", "ʊɹ", "ɑːɹ", "ɔːɹ",
        // Syllabic consonants
        "əl", "ən", "əm", "l̩", "n̩",
        // Vocabulary-internal shorthand forms used by this model
        "i", "u", "a", "e", "o", "ɑ", "ɔ",
        // Allophonic notation pairs already in `allophonicExpansions`
        "ᵻ", "ɨ", "ʉ", "ɝ", "ɜ", "ər"
    ]
    
    func runGreedyDecodeWithFrames(logits: MLMultiArray) -> [(symbol: String, frame: Int)] {
        let totalFrames = logits.shape[1].intValue
        let vocabSize = logits.shape[2].intValue
        let ptr = UnsafeMutablePointer<Float>(OpaquePointer(logits.dataPointer))
        
        var sequence: [(symbol: String, frame: Int)] = []
        var lastToken = -1
        
        for frame in 0..<totalFrames {
            let offset = frame * vocabSize
            var maxVal: Float = -Float.greatestFiniteMagnitude
            var maxIdx = 0
            
            for v in 0..<vocabSize {
                let val = ptr[offset + v]
                if val > maxVal {
                    maxVal = val
                    maxIdx = v
                }
            }
            
            if maxIdx != 0 && maxIdx != lastToken {
                let sym = vocabulary[maxIdx]
                if PhonemeInferenceEngine.englishPhonemeSet.contains(sym) {
                    sequence.append((symbol: sym, frame: frame))
                }
            }
            lastToken = maxIdx
        }
        return sequence
    }
    
    func getProbabilities(from logits: MLMultiArray) -> (probs: [Float], frames: Int, vocabSize: Int) {
        let totalFrames = logits.shape[1].intValue
        let vocabSize = logits.shape[2].intValue
        let ptr = UnsafeMutablePointer<Float>(OpaquePointer(logits.dataPointer))
        let probs = MathService.softmaxVectorized(logits: ptr, frameCount: totalFrames, vocabSize: vocabSize)
        return (probs, totalFrames, vocabSize)
    }
}

class Wav2Vec2Input: MLFeatureProvider {
    var featureNames: Set<String> { ["audio"] }
    let audio: MLMultiArray
    init(audio: MLMultiArray) { self.audio = audio }
    func featureValue(for featureName: String) -> MLFeatureValue? {
        return featureName == "audio" ? MLFeatureValue(multiArray: audio) : nil
    }
}
