import Foundation
import CoreML

nonisolated struct PhoneScore: Identifiable {
    let id = UUID()
    let symbol: String
    let gopScore: Float
    let frames: Int
    var errorType: ErrorType = .none
    var phoneMargin: Float = 0.0
    var targetMass: Float = 0.0
    var topCompetitorMass: Float = 0.0
    var topCompetitorSymbol: String = ""
    var posteriorMargin: Float = 0.0
}

nonisolated struct WordScore: Identifiable {
    let id = UUID()
    let word: String
    let phoneScores: [PhoneScore]
    let averageScore: Float
}

nonisolated class AlignmentScorerEngine {
    private let blankIndex = 0
    
    private func logSumExp(_ a: Float, _ b: Float) -> Float {
        if a == -Float.greatestFiniteMagnitude { return b }
        if b == -Float.greatestFiniteMagnitude { return a }
        let maxVal = max(a, b)
        return maxVal + log(exp(a - maxVal) + exp(b - maxVal))
    }
    
    private func logSumExp(_ a: Float, _ b: Float, _ c: Float) -> Float {
        return logSumExp(logSumExp(a, b), c)
    }
    
    func scorePronunciation(userLogits: MLMultiArray, targetPhonemes: [String], vocabulary: [String]) -> [PhoneScore] {
        let totalFrames = userLogits.shape[1].intValue
        let vocabSize = userLogits.shape[2].intValue
        let ptr = UnsafeMutablePointer<Float>(OpaquePointer(userLogits.dataPointer))
        
        let probs = MathService.softmaxVectorized(logits: ptr, frameCount: totalFrames, vocabSize: vocabSize)
        
        return runCTCForwardBackward(probs: probs, targets: targetPhonemes, vocab: vocabulary, totalFrames: totalFrames, vocabSize: vocabSize)
    }
    
    func scorePronunciation(probs: [Float], totalFrames: Int, vocabSize: Int, targetPhonemes: [String], vocabulary: [String]) -> [PhoneScore] {
        return runCTCForwardBackward(probs: probs, targets: targetPhonemes, vocab: vocabulary, totalFrames: totalFrames, vocabSize: vocabSize)
    }
    
    static let nativeCalibration: [String: (mean: Float, std: Float)] = [
        "a": (mean: 0.72, std: 0.22),
        "aɪ": (mean: 0.74, std: 0.22),
        "aʊ": (mean: 0.72, std: 0.22),
        "b": (mean: 0.853, std: 0.233),
        "d": (mean: 0.8662, std: 0.2413),
        "dʒ": (mean: 0.8367, std: 0.2032),
        "eɪ": (mean: 0.74, std: 0.22),
        "f": (mean: 0.8783, std: 0.2156),
        "h": (mean: 0.8818, std: 0.2212),
        "iː": (mean: 0.74, std: 0.22),
        "j": (mean: 0.8957, std: 0.1832),
        "k": (mean: 0.872, std: 0.2263),
        "l": (mean: 0.8512, std: 0.2309),
        "m": (mean: 0.8707, std: 0.2261),
        "n": (mean: 0.8743, std: 0.2499),
        "oʊ": (mean: 0.68, std: 0.25),
        "p": (mean: 0.8742, std: 0.2161),
        "s": (mean: 0.8611, std: 0.2397),
        "t": (mean: 0.8617, std: 0.231),
        "tʃ": (mean: 0.8909, std: 0.1646),
        "uː": (mean: 0.74, std: 0.22),
        "v": (mean: 0.76, std: 0.22),
        "w": (mean: 0.824, std: 0.2481),
        "z": (mean: 0.74, std: 0.24),
        "æ": (mean: 0.68, std: 0.26),
        "ð": (mean: 0.72, std: 0.24),
        "ŋ": (mean: 0.8872, std: 0.2331),
        "ɑː": (mean: 0.74, std: 0.22),
        "ɔɪ": (mean: 0.72, std: 0.22),
        "ɔː": (mean: 0.72, std: 0.22),
        "ɒ": (mean: 0.72, std: 0.22),
        "ə": (mean: 0.72, std: 0.24),
        "ɚ": (mean: 0.70, std: 0.28),
        "ɛ": (mean: 0.75, std: 0.20),
        "ɡ": (mean: 0.8655, std: 0.2318),
        "ɪ": (mean: 0.76, std: 0.20),
        "ɹ": (mean: 0.74, std: 0.25),
        "ʃ": (mean: 0.85, std: 0.2308),
        "ʊ": (mean: 0.75, std: 0.20),
        "ʌ": (mean: 0.75, std: 0.20),
        "θ": (mean: 0.70, std: 0.24),
        "ɜː": (mean: 0.58, std: 0.28),
        "ɝ": (mean: 0.60, std: 0.26),
    ]

    // Pre-computed allowable allophones for common English phonemes in connected speech
    // NOTE: Only true connected-speech allophones (flaps, glottals) and Allosaurus notation pairs are permitted.
    // Phonemic vowel contrasts (minimal pairs like /iː/ vs /ɪ/, /uː/ vs /ʊ/, /eɪ/ vs /ɛ/) are NEVER conflated.
    static let allophonicExpansions: [String: [String]] = [
        "t": ["t", "tʰ", "ɾ", "ʔ", "t̪", "tː"],
        "d": ["d", "dʰ", "ɾ", "d̪", "dː", "t", "ʔ"],
        "k": ["k", "kʰ", "kʲ", "kː", "c"],
        "ɡ": ["ɡ", "ɡʰ", "ɡʲ", "ɡː", "k", "ɡ̊", "ʔ"],
        "p": ["p", "pʰ", "pʲ", "pː"],
        "b": ["b", "bʰ", "bʲ", "bː", "p"],
        "iː": ["iː", "i"],
        "i": ["i", "iː", "ɪ", "ɨ", "ᵻ", "ə"],
        "ɪ": ["ɪ", "ᵻ", "ɨ", "i", "ɛ̃"],
        "eɪ": ["eɪ", "e", "eː", "ɛ"],
        "ɛ": ["ɛ", "ɛː", "e", "ɛ̃"],
        "æ": ["æ", "a", "ɑ", "ɛ̃", "ɑ̃"],
        "ɑː": ["ɑː", "ɑ", "a", "ɑ̃", "ɒ", "ɔ"],
        "ɔː": ["ɔː", "ɔ", "oː", "ɒ", "ɔ̃", "ɑː", "ɑ"],
        "ɔ": ["ɔ", "ɔː", "ɒ", "ɔ̃", "ɑː"],
        "ɒ": ["ɒ", "ɔ", "ɔː", "ɑː", "ɑ", "ʌ"],
        "oʊ": ["oʊ", "əʊ", "o", "oː", "ɔ"],
        "əʊ": ["əʊ", "oʊ", "o"],
        "ʊ": ["ʊ", "u", "o"],
        "uː": ["uː", "u", "ʉ"],
        "u": ["u", "uː", "ʊ", "ʉ"],
        "ʌ": ["ʌ", "ɐ", "ə", "a", "ɑ̃"],
        "ə": ["ə", "ʌ", "ɐ"],
        "ɜː": ["ɜː", "ɝ", "ɜ", "ə", "ɚ", "ər", "ɛ", "ɐ"],
        "aɪ": ["aɪ", "ai", "a", "ɑː", "ɑ"],
        "aʊ": ["aʊ", "au", "a", "ɑː", "ɑ"],
        "ɔɪ": ["ɔɪ", "oɪ", "ɔ"],
        "iə": ["iə", "ɪɹ", "iː", "ɪ"],
        "eə": ["eə", "ɛɹ", "ɛ", "eɪ"],
        "ʊə": ["ʊə", "ʊɹ", "ʊ", "uː"],
        "ər": ["ər", "ɚ"],
        "ɚ": ["ɚ", "ər"],
        "ɛɹ": ["ɛɹ", "eə", "ɛ", "eɪ", "ɚ"],
        "ɪɹ": ["ɪɹ", "iə", "ɪ", "iː"],
        "ʊɹ": ["ʊɹ", "ʊə", "ʊ", "uː"],
        "l": ["l", "əl", "l̩"],
        "əl": ["əl", "l", "l̩", "ə"],
        "ən": ["ən", "n", "n̩", "ə"],
        "əm": ["əm", "m", "ə"],
        "ɹ": ["ɹ", "ɚ", "ɻ", "ɾ", "w"],
        "θ": ["θ", "t̪", "t"],
        "ð": ["ð", "d̪", "d", "ɾ"],
        "z": ["z", "s"],
        "s": ["s"],
        "v": ["v", "vʲ", "ʋ", "f"],
        "f": ["f"],
        "w": ["w", "u"],
        "j": ["j", "i"],
        "ŋ": ["ŋ", "n", "n̩"],
        "m": ["m"],
        "n": ["n"],
        "ʃ": ["ʃ", "ɕ", "ʂ"],
        "ʒ": ["ʒ", "ʑ", "ʐ"],
        "tʃ": ["tʃ", "tɕ", "tʃʰ", "tʃʲ", "tʃː"],
        "dʒ": ["dʒ", "dʑ", "dʒʲ", "dʒː"]
    ]

    // Tier 1: Connected Speech Reductions & Neutralizations (mild penalty: * 0.90, no errorType flagged)
    static let tier1Reductions: [String: Set<String>] = [
        "ɪ": ["iː", "i", "ᵻ", "ɨ", "ə"],
        "i": ["ɪ", "iː", "ə"],
        "ɛ": ["e", "eɪ", "ə"],
        "æ": ["a", "ɛ", "ə", "ʌ"],
        "ʊ": ["uː", "u", "ə", "o"],
        "ʌ": ["ə", "ɐ"],
        "ə": ["ʌ", "ɐ", "ɪ"],
        "z": ["s"],
        "s": ["z"],
        "v": ["f", "ʋ"],
        "n": ["ŋ", "m"],
        "ŋ": ["n"],
        "iə": ["iː", "ɪ", "ɪɹ", "ə"],
        "eə": ["eɪ", "ɛ", "ɛɹ", "ə"],
        "ʊə": ["uː", "ʊ", "ʊɹ", "ə"]
    ]

    // Tier 2: Intelligible Non-Native L2 Accent Shifts (moderate penalty: min(score * 0.75, 0.75), no errorType flagged)
    static let tier2AccentShifts: [String: Set<String>] = [
        "θ": ["t", "t̪", "f", "s"],
        "ð": ["d", "d̪", "v", "z", "ɾ"],
        "w": ["v", "ʋ", "uː", "u"],
        "v": ["w", "b"],
        "ɹ": ["l", "w", "r", "j", "ʋ"],
        "l": ["ɹ", "w", "oʊ", "əl", "l̩"],
        "h": ["ʔ"],
        "b": ["p", "v"],
        "d": ["t", "ɾ", "dʒ"],
        "ɡ": ["k"],
        "p": ["b"],
        "k": ["ɡ"],
        "t": ["d", "tʃ"],
        "ɜː": ["ɛ", "ɐ", "ɝ", "ə", "ɚ"],
        "iː": ["ɪ", "i"],
        "ɪ": ["iː", "e", "ɛ", "ᵻ", "ɨ"],
        "ɛ": ["æ", "e", "eɪ"],
        "æ": ["ɛ", "a", "ɑː", "ɑ"],
        "ʌ": ["ə", "ɑː", "ʊ", "ɒ"],
        "ʊ": ["uː", "oʊ", "ʌ", "u"],
        "uː": ["ʊ", "u", "oʊ", "ʉ"],
        "aɪ": ["ɑː", "æ", "eɪ"],
        "aʊ": ["ɑː", "æ", "ɔː"],
        "ɔɪ": ["ɔː", "oʊ", "ɪ"],
        "ɑː": ["a", "æ", "ʌ", "ɒ"],
        "ɔː": ["ɒ", "oʊ", "ɑː"],
        "oʊ": ["ɔː", "ɒ", "uː", "əʊ"]
    ]

    struct FunctionalLoadMatrix {
        /// Returns communicative penalty factor in [0.0, 1.0].
        /// 0.15 - 0.35: Intelligible dialectal / connected-speech variant (mild penalty, high score floor)
        /// 0.70: Standard phonemic substitution
        /// 0.85 - 0.95: Critical minimal pair distinction (severe penalty, capped <= 0.45)
        static func penaltyFactor(expected: String, competitor: String) -> Float {
            let expClean = expected
                .replacingOccurrences(of: "ˈ", with: "")
                .replacingOccurrences(of: "ˌ", with: "")
                .replacingOccurrences(of: "\u{200D}", with: "")
                .trimmingCharacters(in: .decimalDigits)
            let compClean = competitor
                .replacingOccurrences(of: "ˈ", with: "")
                .replacingOccurrences(of: "ˌ", with: "")
                .replacingOccurrences(of: "\u{200D}", with: "")
                .trimmingCharacters(in: .decimalDigits)
            
            if expClean == compClean || compClean.isEmpty { return 0.0 }
            
            // 1. Very Low Functional Load (dialectal / connected speech variants): 0.15 - 0.35
            // Dental fricatives
            if (expClean == "θ" && (compClean == "f" || compClean == "s" || compClean == "t" || compClean == "t̪")) ||
               (expClean == "ð" && (compClean == "d" || compClean == "d̪" || compClean == "v" || compClean == "z" || compClean == "ɾ")) {
                return 0.20
            }
            // Rhotic centralizations
            if (expClean == "ɜː" || expClean == "ɝ") && (compClean == "ɛ" || compClean == "ə" || compClean == "ɚ" || compClean == "ɐ" || compClean == "ər") {
                return 0.25
            }
            // Flaps / Glottal stops
            if (expClean == "t" || expClean == "d") && (compClean == "ɾ" || compClean == "ʔ") {
                return 0.15
            }
            // Liquid shifts (r/l/w)
            if expClean == "ɹ" && (compClean == "w" || compClean == "ʋ" || compClean == "l" || compClean == "r" || compClean == "ɾ") {
                return 0.30
            }
            if expClean == "w" && (compClean == "v" || compClean == "ʋ" || compClean == "u") {
                return 0.30
            }
            if expClean == "v" && (compClean == "w" || compClean == "b" || compClean == "f") {
                return 0.30
            }
            // Coda -ing reduction
            if expClean == "ŋ" && compClean == "n" {
                return 0.20
            }
            // Dark l vocalization
            if expClean == "l" && (compClean == "w" || compClean == "oʊ" || compClean == "əl" || compClean == "l̩") {
                return 0.25
            }
            
            // 2. High Functional Load (Critical phonemic minimal pairs): 0.85 - 0.95
            let highVowelPairs: Set<String> = [
                "iː-ɪ", "ɪ-iː",
                "uː-ʊ", "ʊ-uː",
                "ɛ-æ", "æ-ɛ",
                "ɑː-ʌ", "ʌ-ɑː"
            ]
            if highVowelPairs.contains("\(expClean)-\(compClean)") {
                return 0.90
            }
            
            return 0.70
        }
    }

    private func runCTCForwardBackward(probs: [Float], targets: [String], vocab: [String], totalFrames: Int, vocabSize: Int) -> [PhoneScore] {
        if targets.isEmpty || totalFrames == 0 { return [] }
        
        let M = targets.count
        let L = 2 * M + 1
        var E = [Int](repeating: blankIndex, count: L)
        var E_candidates = [[Int]](repeating: [blankIndex], count: L)
        
        // Map target symbols to vocabulary indices and allophonic expansion sets.
        for k in 0..<M {
            let symbolWithStress = targets[k]
            let symbol = symbolWithStress
                .replacingOccurrences(of: "ˈ", with: "")
                .replacingOccurrences(of: "ˌ", with: "")
                .replacingOccurrences(of: "\u{200D}", with: "")
            let primaryIdx = vocab.firstIndex(of: symbol) ?? vocab.firstIndex(of: symbol.replacingOccurrences(of: "ː", with: "")) ?? blankIndex
            E[2*k+1] = primaryIdx
            
            var candidates = [primaryIdx]
            if let allophones = AlignmentScorerEngine.allophonicExpansions[symbol] {
                for allo in allophones {
                    if let idx = vocab.firstIndex(of: allo), idx != blankIndex, !candidates.contains(idx) {
                        candidates.append(idx)
                    }
                }
            }
            E_candidates[2*k+1] = candidates
        }
        
        let candidateSets = E_candidates.map { Set($0) }
        
        var alpha = [[Float]](repeating: [Float](repeating: -Float.greatestFiniteMagnitude, count: L), count: totalFrames)
        alpha[0][0] = log(max(probs[E[0]], 1e-8))
        
        var initCandidateP: Float = probs[E_candidates[1][0]]
        for idx in E_candidates[1].dropFirst() {
            let p = probs[idx]
            if p > initCandidateP { initCandidateP = p }
        }
        alpha[0][1] = log(max(initCandidateP, 1e-8))
        
        for t in 1..<totalFrames {
            let offset = t * vocabSize
            for s in 0..<L {
                var maxCandidateP: Float = probs[offset + E_candidates[s][0]]
                if E_candidates[s].count > 1 {
                    for idx in E_candidates[s].dropFirst() {
                        let p = probs[offset + idx]
                        if p > maxCandidateP { maxCandidateP = p }
                    }
                }
                let logProb = log(max(maxCandidateP, 1e-8))
                
                let a1 = alpha[t-1][s]
                var a2: Float = -Float.greatestFiniteMagnitude
                var a3: Float = -Float.greatestFiniteMagnitude
                
                if s > 0 { a2 = alpha[t-1][s-1] }
                if s > 1 && E[s] != blankIndex && E[s] != E[s-2] { a3 = alpha[t-1][s-2] }
                
                let sumPrev = logSumExp(a1, a2, a3)
                if sumPrev != -Float.greatestFiniteMagnitude {
                    alpha[t][s] = logProb + sumPrev
                }
            }
        }
        
        var beta = [[Float]](repeating: [Float](repeating: -Float.greatestFiniteMagnitude, count: L), count: totalFrames)
        beta[totalFrames-1][L-1] = 0.0
        beta[totalFrames-1][L-2] = 0.0
        
        for t in (0..<totalFrames-1).reversed() {
            let offset = (t + 1) * vocabSize
            for s in 0..<L {
                var b1: Float = -Float.greatestFiniteMagnitude
                var b2: Float = -Float.greatestFiniteMagnitude
                var b3: Float = -Float.greatestFiniteMagnitude
                
                var p1_max: Float = probs[offset + E_candidates[s][0]]
                if E_candidates[s].count > 1 {
                    for idx in E_candidates[s].dropFirst() {
                        let p = probs[offset + idx]
                        if p > p1_max { p1_max = p }
                    }
                }
                let p1 = log(max(p1_max, 1e-8))
                b1 = beta[t+1][s] + p1
                
                if s + 1 < L {
                    var p2_max: Float = probs[offset + E_candidates[s+1][0]]
                    if E_candidates[s+1].count > 1 {
                        for idx in E_candidates[s+1].dropFirst() {
                            let p = probs[offset + idx]
                            if p > p2_max { p2_max = p }
                        }
                    }
                    let p2 = log(max(p2_max, 1e-8))
                    b2 = beta[t+1][s+1] + p2
                }
                if s + 2 < L && E[s+2] != blankIndex && E[s+2] != E[s] {
                    var p3_max: Float = probs[offset + E_candidates[s+2][0]]
                    if E_candidates[s+2].count > 1 {
                        for idx in E_candidates[s+2].dropFirst() {
                            let p = probs[offset + idx]
                            if p > p3_max { p3_max = p }
                        }
                    }
                    let p3 = log(max(p3_max, 1e-8))
                    b3 = beta[t+1][s+2] + p3
                }
                beta[t][s] = logSumExp(b1, b2, b3)
            }
        }
        
        let pTotal = logSumExp(alpha[totalFrames-1][L-1], alpha[totalFrames-1][L-2])
        
        var metrics: [PhoneScore] = []
        for k in 0..<M {
            let s = 2 * k + 1
            let symbolWithStress = targets[k]
            let stress = symbolWithStress.last?.wholeNumberValue ?? 1
            let symbol = symbolWithStress.trimmingCharacters(in: .decimalDigits)
                .replacingOccurrences(of: "ˈ", with: "")
                .replacingOccurrences(of: "ˌ", with: "")
                .replacingOccurrences(of: "\u{200D}", with: "")
            
            var sumGammaLin: Float = 0.0
            var sumLogP: Float = 0.0
            
            var substitutionCandidates = [Int: Float]()
            let activeCandidateSet = candidateSets[s]
            
            for t in 0..<totalFrames {
                if alpha[t][s] == -Float.greatestFiniteMagnitude || beta[t][s] == -Float.greatestFiniteMagnitude || pTotal == -Float.greatestFiniteMagnitude {
                    continue
                }
                
                let gamma = alpha[t][s] + beta[t][s] - pTotal
                if gamma > -30.0 {
                    let gammaLin = exp(gamma)
                    let offset = t * vocabSize
                    
                    var targetP: Float = probs[offset + E_candidates[s][0]]
                    if E_candidates[s].count > 1 {
                        for idx in E_candidates[s].dropFirst() {
                            let p = probs[offset + idx]
                            if p > targetP { targetP = p }
                        }
                    }
                    let logP = log(max(targetP, 1e-8))
                    
                    var maxCompetingLogP: Float = -Float.greatestFiniteMagnitude
                    
                    for v in 1..<vocabSize {
                        // Allowable allophones do NOT compete against the target phoneme
                        if !activeCandidateSet.contains(v) {
                            let vp = log(max(probs[offset + v], 1e-8))
                            if vp > maxCompetingLogP {
                                maxCompetingLogP = vp
                            }
                        }
                        
                        // Accumulate probability mass for unconstrained divergence analysis
                        substitutionCandidates[v, default: 0.0] += gammaLin * probs[offset + v]
                    }
                    
                    sumGammaLin += gammaLin
                    sumLogP += gammaLin * (logP - maxCompetingLogP)
                }
            }
            
            let rawMargin = sumGammaLin > 0.001 ? (sumLogP / sumGammaLin) : -5.0
            let rawScore = sumGammaLin > 0.001 ? exp(sumLogP / sumGammaLin) : 0.0
            var calibratedScore = rawScore
            let stats = AlignmentScorerEngine.nativeCalibration[symbol] ?? (mean: 0.72, std: 0.22)
            let ratio = max(0.0, min(1.0, rawScore / stats.mean))
            if ratio >= 1.0 {
                calibratedScore = 1.0
            } else {
                let exponent: Float = (stress == 0) ? 0.50 : 0.65
                calibratedScore = pow(ratio, exponent)
            }
            
            // Proportional penalty for deleted / truncated phonemes with < 1 frame duration
            if sumGammaLin < 1.0 {
                calibratedScore *= Float(max(0.0, sumGammaLin))
            }
            
            // --- Probabilistic Divergence Analysis ---
            var errorType: ErrorType = .none
            let expectedVocabIdx = E[s]
            var expectedMass: Float = 0.0
            var maxActualMass: Float = 0.0
            var topCompetitorSymbol = ""
            var posteriorMargin: Float = -5.0
            
            // 1. Deletion Detection
            if sumGammaLin < 0.8 {
                errorType = .deletion(expected: symbolWithStress)
            } else {
                // 2. Continuous Posterior Mass & Divergence Analysis
                var maxActualIdx = -1
                for (v, mass) in substitutionCandidates {
                    if v != expectedVocabIdx && !activeCandidateSet.contains(v) {
                        if mass > maxActualMass {
                            maxActualMass = mass
                            maxActualIdx = v
                        }
                    }
                }
                
                expectedMass = substitutionCandidates[expectedVocabIdx] ?? 0.0
                topCompetitorSymbol = (maxActualIdx != -1 && maxActualIdx < vocab.count) ? vocab[maxActualIdx] : ""
                posteriorMargin = log(max(expectedMass, 1e-6) / max(maxActualMass, 1e-6))
                
                let expectedBase = symbolWithStress
                    .replacingOccurrences(of: "ˈ", with: "")
                    .replacingOccurrences(of: "ˌ", with: "")
                    .replacingOccurrences(of: "\u{200D}", with: "")
                
                // Functional Load & Continuous Posterior Mass Gating
                if maxActualIdx != -1 && maxActualIdx != blankIndex && maxActualMass >= 1.0 {
                    let actualSymbol = vocab[maxActualIdx]
                    let actualBase = actualSymbol
                        .replacingOccurrences(of: "ˈ", with: "")
                        .replacingOccurrences(of: "ˌ", with: "")
                        .replacingOccurrences(of: "\u{200D}", with: "")
                    
                    let isTier0 = AlignmentScorerEngine.allophonicExpansions[expectedBase]?.contains(actualBase) ?? false
                    if isTier0 {
                        // Tier 0: Allophonic variant - fully allowed, no penalty
                    } else if AlignmentScorerEngine.tier1Reductions[expectedBase]?.contains(actualBase) == true {
                        // Tier 1: Connected speech reduction / neutralization - mild penalty (target ~9.0)
                        calibratedScore *= 0.92
                    } else if AlignmentScorerEngine.tier2AccentShifts[expectedBase]?.contains(actualBase) == true {
                        // Tier 2: Intelligible non-native accent shift - scaled by functional load
                        let flPenalty = FunctionalLoadMatrix.penaltyFactor(expected: expectedBase, competitor: actualBase)
                        calibratedScore = max(0.65, calibratedScore * (1.0 - 0.30 * flPenalty))
                    } else {
                        // Tier 3: Unlisted phonetic candidate
                        // Decouple string mismatch from fatal substitution:
                        // Only flag fatal phonemic substitution if competitor strongly dominates (> 2.5x) AND target mass is depleted (< 0.8)
                        if expectedMass < 0.8 && maxActualMass > (expectedMass * 2.5) {
                            errorType = .substitution(expected: symbolWithStress, actual: actualSymbol)
                            let flPenalty = FunctionalLoadMatrix.penaltyFactor(expected: expectedBase, competitor: actualBase)
                            let maxAllowed: Float = flPenalty >= 0.85 ? 0.45 : 0.60
                            calibratedScore = min(calibratedScore * (1.0 - 0.55 * flPenalty), maxAllowed)
                        } else if maxActualMass > (expectedMass * 2.5) {
                            // Target mass was articulated (>= 0.8), but competitor also had strong energy: moderate penalty scaled by functional load
                            let flPenalty = FunctionalLoadMatrix.penaltyFactor(expected: expectedBase, competitor: actualBase)
                            calibratedScore = max(0.55, calibratedScore * (1.0 - 0.35 * flPenalty))
                        }
                    }
                }
            }
            
            // 3. Insertion Detection & Blank Duration (Look at the blank state following this phoneme)
            var blankGammaSum: Float = 0.0
            var insertionPhoneScore: PhoneScore? = nil
            if k < M - 1 {
                let blankState = s + 1
                var insertedCandidates = [Int: Float]()
                for t in 0..<totalFrames {
                    if alpha[t][blankState] != -Float.greatestFiniteMagnitude && beta[t][blankState] != -Float.greatestFiniteMagnitude {
                        let gamma = alpha[t][blankState] + beta[t][blankState] - pTotal
                        if gamma > -30.0 {
                            let gammaLin = exp(gamma)
                            blankGammaSum += gammaLin
                            let offset = t * vocabSize
                            for v in 1..<vocabSize {
                                insertedCandidates[v, default: 0.0] += gammaLin * probs[offset + v]
                            }
                        }
                    }
                }
                
                if blankGammaSum > 2.0 {
                    var maxInsertMass: Float = 0.0
                    var maxInsertIdx = -1
                    for (v, mass) in insertedCandidates {
                        if mass > maxInsertMass {
                            maxInsertMass = mass
                            maxInsertIdx = v
                        }
                    }
                    // If an unconstrained phoneme dominated the blank space
                    if maxInsertIdx != blankIndex && maxInsertMass > (blankGammaSum * 0.5) && maxInsertMass > 1.5 {
                        let actualSymbol = vocab[maxInsertIdx]
                        insertionPhoneScore = PhoneScore(
                            symbol: actualSymbol,
                            gopScore: 0.0,
                            frames: Int(round(maxInsertMass)),
                            errorType: .insertion(actual: actualSymbol),
                            phoneMargin: -5.0,
                            targetMass: 0.0,
                            topCompetitorMass: maxInsertMass,
                            topCompetitorSymbol: actualSymbol,
                            posteriorMargin: -5.0
                        )
                    }
                }
            }
            
            let totalFramesForPhone = Int(round(sumGammaLin + blankGammaSum))
            let postMarginFinal = (sumGammaLin < 0.8) ? -5.0 : posteriorMargin
            metrics.append(PhoneScore(
                symbol: symbolWithStress,
                gopScore: calibratedScore,
                frames: max(1, totalFramesForPhone),
                errorType: errorType,
                phoneMargin: rawMargin,
                targetMass: expectedMass,
                topCompetitorMass: maxActualMass,
                topCompetitorSymbol: topCompetitorSymbol,
                posteriorMargin: postMarginFinal
            ))
            if let ins = insertionPhoneScore {
                metrics.append(ins)
            }
        }
        // Post-processing to fix geminates (consecutive identical phonemes)
        var i = 0
        while i < metrics.count {
            var j = i + 1
            while j < metrics.count && metrics[j].symbol == metrics[i].symbol {
                j += 1
            }
            if j > i + 1 {
                let maxScore = metrics[i..<j].map { $0.gopScore }.max() ?? 0.0
                for k in i..<j {
                    metrics[k] = PhoneScore(
                        symbol: metrics[k].symbol,
                        gopScore: maxScore,
                        frames: metrics[k].frames,
                        errorType: metrics[k].errorType,
                        phoneMargin: metrics[k].phoneMargin,
                        targetMass: metrics[k].targetMass,
                        topCompetitorMass: metrics[k].topCompetitorMass,
                        topCompetitorSymbol: metrics[k].topCompetitorSymbol,
                        posteriorMargin: metrics[k].posteriorMargin
                    )
                }
            }
            i = j
        }
        
        return metrics
    }
}

