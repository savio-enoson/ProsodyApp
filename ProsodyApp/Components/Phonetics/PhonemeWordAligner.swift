import Foundation

nonisolated class PhonemeWordAligner {
    
    static let vowels: Set<String> = [
        "iː", "ɪ", "eɪ", "ɛ", "æ", "ɑː", "ɒ", "ɔː", "ʊ", "uː", "ʌ", "ɜː", "ə",
        "aɪ", "aʊ", "ɔɪ", "ɪə", "eə", "ʊə", "ɚ", "ɝ", "ɐ", "a", "oʊ",
        "ɛɹ", "ɪɹ", "ʊɹ", "ɑːɹ", "ɔːɹ", "oːɹ", "i", "u", "e", "o", "ɑ", "ɔ"
    ]
    
    static func cleanPhone(_ s: String) -> String {
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "ˈ", with: "")
            .replacingOccurrences(of: "ˌ", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
            .replacingOccurrences(of: "ː", with: "")
    }
    
    static func isVowel(_ s: String) -> Bool {
        let c = cleanPhone(s)
        return vowels.contains(s) || vowels.contains(c) || "aeiouyəɛɪɐʊʌæɔɑɚɜɒ".contains(where: { c.contains($0) })
    }
    
    private static let labials: Set<String> = ["p", "b", "f", "v", "m", "w", "ʋ", "β", "ɸ"]
    private static let alveolars: Set<String> = ["t", "d", "s", "z", "n", "l", "ɹ", "r", "θ", "ð", "ɾ", "ts", "dz"]
    private static let velars: Set<String> = ["k", "ɡ", "g", "ŋ", "q", "x", "ɣ"]
    private static let palatals: Set<String> = ["ʃ", "ʒ", "tʃ", "dʒ", "j", "tɕ", "dʑ", "ɕ", "ɲ", "ʎ", "c", "ɟ"]
    
    private static func getConsonantClass(_ s: String) -> Int {
        let c = cleanPhone(s)
        if labials.contains(c) { return 1 }
        if alveolars.contains(c) { return 2 }
        if velars.contains(c) { return 3 }
        if palatals.contains(c) { return 4 }
        return 0
    }
    
    static func comparePhonemes(expected: String, heard: String) -> (score: Float, status: PronunciationStatus, errorType: ErrorType) {
        let expClean = cleanPhone(expected)
        let hrdClean = cleanPhone(heard)
        
        if expClean == hrdClean || expected == heard {
            return (2.0, .good, .none)
        }
        
        // Tier 0: Allowable Allophones
        if let allos = AlignmentScorerEngine.allophonicExpansions[expClean], allos.contains(hrdClean) {
            return (1.8, .good, .none)
        }
        if let allos2 = AlignmentScorerEngine.allophonicExpansions[expected], allos2.contains(heard) {
            return (1.8, .good, .none)
        }
        
        // Tier 1: Connected Speech Reductions & Neutralizations
        if let reds = AlignmentScorerEngine.tier1Reductions[expClean], reds.contains(hrdClean) {
            return (1.2, .good, .none)
        }
        
        // Tier 2: Intelligible Non-Native Accent Shifts
        if let shifts = AlignmentScorerEngine.tier2AccentShifts[expClean], shifts.contains(hrdClean) {
            return (0.8, .needsWork, .none)
        }
        
        let expVow = isVowel(expected)
        let hrdVow = isVowel(heard)
        
        if expVow && hrdVow {
            // Vowel substitution
            return (-0.6, .incorrect, .substitution(expected: expected, actual: heard))
        } else if !expVow && !hrdVow {
            // Consonant substitution
            let c1 = getConsonantClass(expected)
            let c2 = getConsonantClass(heard)
            if c1 != 0 && c1 == c2 {
                // Same manner/place class (e.g. voicing or near fricative)
                return (-0.4, .needsWork, .substitution(expected: expected, actual: heard))
            } else {
                return (-1.2, .incorrect, .substitution(expected: expected, actual: heard))
            }
        } else {
            // Vowel vs Consonant mismatch
            return (-2.0, .incorrect, .substitution(expected: expected, actual: heard))
        }
    }
    
    /// Needleman-Wunsch 1:1 pairwise sequence alignment between expected and heard phonemes of a word.
    static func alignExpectedVsHeard(
        expected: [String],
        heard: [String],
        gopScores: [Int]
    ) -> [AlignedPhonemePair] {
        let n = expected.count
        let m = heard.count
        
        if n == 0 && m == 0 { return [] }
        if n == 0 {
            return heard.map { h in
                AlignedPhonemePair(expected: nil, heard: h, score: 0, status: .incorrect, errorType: .insertion(actual: h), note: "Inserted sound [\(h)]")
            }
        }
        if m == 0 {
            return expected.enumerated().map { idx, e in
                let gop = idx < gopScores.count ? gopScores[idx] : 0
                return AlignedPhonemePair(expected: e, heard: nil, score: min(gop, 30), status: .incorrect, errorType: .deletion(expected: e), note: "Omitted /\(e)/")
            }
        }
        
        let gapScore: Float = -1.2
        
        // DP table
        var dp = [[Float]](repeating: [Float](repeating: 0.0, count: m + 1), count: n + 1)
        enum Step { case match, delete, insert }
        var backtrace = [[Step]](repeating: [Step](repeating: .match, count: m + 1), count: n + 1)
        
        for i in 1...n {
            dp[i][0] = Float(i) * gapScore
            backtrace[i][0] = .delete
        }
        for j in 1...m {
            dp[0][j] = Float(j) * gapScore
            backtrace[0][j] = .insert
        }
        
        for i in 1...n {
            for j in 1...m {
                let sim = comparePhonemes(expected: expected[i - 1], heard: heard[j - 1]).score
                let match = dp[i - 1][j - 1] + sim
                let delete = dp[i - 1][j] + gapScore
                let insert = dp[i][j - 1] + gapScore
                
                if match >= delete && match >= insert {
                    dp[i][j] = match
                    backtrace[i][j] = .match
                } else if delete >= insert {
                    dp[i][j] = delete
                    backtrace[i][j] = .delete
                } else {
                    dp[i][j] = insert
                    backtrace[i][j] = .insert
                }
            }
        }
        
        var i = n
        var j = m
        var pairsRev = [AlignedPhonemePair]()
        
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && backtrace[i][j] == .match {
                let exp = expected[i - 1]
                let hrd = heard[j - 1]
                let comp = comparePhonemes(expected: exp, heard: hrd)
                let gop = (i - 1 < gopScores.count) ? gopScores[i - 1] : 0
                let status: PronunciationStatus = (comp.status == .incorrect || gop < 40) ? .incorrect : (comp.status == .needsWork || gop < 70) ? .needsWork : .good
                
                var note: String? = nil
                if case let .substitution(e, a) = comp.errorType {
                    note = "Substituted /\(e)/ with [\(a)]"
                }
                
                pairsRev.append(AlignedPhonemePair(
                    expected: exp,
                    heard: hrd,
                    score: gop,
                    status: status,
                    errorType: comp.errorType,
                    note: note
                ))
                i -= 1
                j -= 1
            } else if i > 0 && (j == 0 || backtrace[i][j] == .delete) {
                // Deletion (expected was omitted in heard speech)
                let exp = expected[i - 1]
                let gop = (i - 1 < gopScores.count) ? gopScores[i - 1] : 0
                pairsRev.append(AlignedPhonemePair(
                    expected: exp,
                    heard: nil,
                    score: min(gop, 30),
                    status: .incorrect,
                    errorType: .deletion(expected: exp),
                    note: "Omitted /\(exp)/"
                ))
                i -= 1
            } else {
                // Insertion (speaker added extra sound)
                let hrd = heard[j - 1]
                pairsRev.append(AlignedPhonemePair(
                    expected: nil,
                    heard: hrd,
                    score: 0,
                    status: .incorrect,
                    errorType: .insertion(actual: hrd),
                    note: "Inserted sound [\(hrd)]"
                ))
                j -= 1
            }
        }
        
        return pairsRev.reversed()
    }
    
    /// Partitions continuous greedy heard phonemes to individual words using timestamps and sequence alignment.
    static func partitionHeardPhonemes(
        words: [String],
        wordTimings: [WordTimestamp],
        heardPhonemes: [(symbol: String, frame: Int)],
        expectedWordPhonemes: [[String]]
    ) -> [Int: [(symbol: String, frame: Int)]] {
        var wordHeardMap = [Int: [(symbol: String, frame: Int)]]()
        for idx in 0..<words.count {
            wordHeardMap[idx] = []
        }
        
        if heardPhonemes.isEmpty { return wordHeardMap }
        
        // Dynamic Programming global assignment across all words
        // Map each heard phoneme to a word index monotonically
        let flatExpected = expectedWordPhonemes.enumerated().flatMap { wIdx, phones in
            phones.map { (wordIndex: wIdx, symbol: $0) }
        }
        
        let n = flatExpected.count
        let m = heardPhonemes.count
        if n == 0 || m == 0 { return wordHeardMap }
        
        var dp = [[Float]](repeating: [Float](repeating: 0.0, count: m + 1), count: n + 1)
        struct State { let i: Int; let j: Int }
        var backtrace = [[State?]](repeating: [State?](repeating: nil, count: m + 1), count: n + 1)
        
        for i in 1...n {
            dp[i][0] = Float(i) * -1.5
            backtrace[i][0] = State(i: i - 1, j: 0)
        }
        for j in 1...m {
            dp[0][j] = Float(j) * -1.5
            backtrace[0][j] = State(i: 0, j: j - 1)
        }
        
        for i in 1...n {
            for j in 1...m {
                let sim = comparePhonemes(expected: flatExpected[i - 1].symbol, heard: heardPhonemes[j - 1].symbol).score
                let match = dp[i - 1][j - 1] + sim
                let del = dp[i - 1][j] - 1.5
                let ins = dp[i][j - 1] - 1.5
                
                let best = max(match, max(del, ins))
                dp[i][j] = best
                if best == match {
                    backtrace[i][j] = State(i: i - 1, j: j - 1)
                } else if best == del {
                    backtrace[i][j] = State(i: i - 1, j: j)
                } else {
                    backtrace[i][j] = State(i: i, j: j - 1)
                }
            }
        }
        
        var currI = n
        var currJ = m
        var assignments = [Int: Int]() // heard index -> word index
        
        while currI > 0 || currJ > 0 {
            guard let prev = backtrace[currI][currJ] else { break }
            if prev.j < currJ {
                let pIdx = currJ - 1
                if prev.i < currI {
                    assignments[pIdx] = flatExpected[currI - 1].wordIndex
                } else if currI > 0 {
                    assignments[pIdx] = flatExpected[currI - 1].wordIndex
                } else {
                    assignments[pIdx] = 0
                }
            }
            currI = prev.i
            currJ = prev.j
        }
        
        for (j, phone) in heardPhonemes.enumerated() {
            let wIdx = assignments[j] ?? 0
            wordHeardMap[wIdx, default: []].append(phone)
        }
        
        // Degemination Recovery:
        // If word k ends with consonant C and word k+1 starts with identical consonant C,
        // share the boundary consonant if only one acoustic realization exists.
        for k in 0..<(words.count - 1) {
            let currExp = expectedWordPhonemes[k]
            let nextExp = expectedWordPhonemes[k + 1]
            guard let lastPhone = currExp.last, let firstPhone = nextExp.first else { continue }
            
            let c1 = cleanPhone(lastPhone)
            let c2 = cleanPhone(firstPhone)
            if c1 == c2 && !isVowel(lastPhone) {
                let currHeard = wordHeardMap[k] ?? []
                let nextHeard = wordHeardMap[k + 1] ?? []
                
                let currHasC = currHeard.contains { cleanPhone($0.symbol) == c1 }
                let nextHasC = nextHeard.contains { cleanPhone($0.symbol) == c1 }
                
                if currHasC && !nextHasC, let matching = currHeard.last(where: { cleanPhone($0.symbol) == c1 }) {
                    wordHeardMap[k + 1]?.insert(matching, at: 0)
                } else if !currHasC && nextHasC, let matching = nextHeard.first(where: { cleanPhone($0.symbol) == c1 }) {
                    wordHeardMap[k]?.append(matching)
                }
            }
        }
        
        return wordHeardMap
    }
}
