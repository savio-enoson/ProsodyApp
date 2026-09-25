import Foundation

nonisolated enum ConsensusState: String {
    case dualMatch
    case literalOnly
    case sfSpeechOnly
    case dualRejection
}

nonisolated struct DiscrepancyResult {
    let status: PronunciationStatus
    let score: Int
    let consensusState: ConsensusState
    let isVowelMerge: Bool
    let diagnosticReason: String
}

nonisolated class DiscrepancyEngine {
    
    /// Evaluates multi-stream agreement across literal CTC and secondary speech streams to classify consensus state.
    static func resolveConsensusState(
        targetWord: String,
        alignedLiteral: String?,
        allLiteralWords: Set<String>,
        alignedSFSpeech: String?,
        allSFSpeechWords: Set<String>,
        alignedPhonemes: [AlignedPhonemePair] = [],
        isStressInverted: Bool = false,
        isVoicingHarmonyDefective: Bool = false
    ) -> ConsensusState {
        let cleanTarget = cleanWord(targetWord)
        let cleanLit = alignedLiteral != nil ? cleanWord(alignedLiteral!) : ""
        let cleanSF = alignedSFSpeech != nil ? cleanWord(alignedSFSpeech!) : ""

        if (isStressInverted && (cleanTarget == "record" || cleanTarget == "present" || cleanLit != cleanTarget)) || isVoicingHarmonyDefective {
            return .sfSpeechOnly
        }

        let isClusterOnsetMatch = (!cleanLit.isEmpty && isClusterOnsetSubstitution(target: cleanTarget, candidate: cleanLit)) ||
            allLiteralWords.contains(where: { isClusterOnsetSubstitution(target: cleanTarget, candidate: $0) }) ||
            (!cleanSF.isEmpty && isClusterOnsetSubstitution(target: cleanTarget, candidate: cleanSF)) ||
            allSFSpeechWords.contains(where: { isClusterOnsetSubstitution(target: cleanTarget, candidate: $0) }) ||
            hasPhoneticClusterOnsetShift(alignedPhonemes: alignedPhonemes)

        let hasExactLiteral: Bool = {
            if !cleanLit.isEmpty {
                return matchesWord(target: cleanTarget, candidate: cleanLit)
            } else {
                return allLiteralWords.contains { matchesWord(target: cleanTarget, candidate: $0) }
            }
        }()
        let isCompoundGlued = !cleanLit.isEmpty && cleanTarget.count >= 4 && cleanLit.count > cleanTarget.count && cleanLit.hasSuffix(cleanTarget)
        let isEpentheticRelease = !cleanLit.isEmpty && cleanLit.hasPrefix(cleanTarget) && cleanLit.count == cleanTarget.count + 1 && extractConsonants(cleanLit) == extractConsonants(cleanTarget)
        let isClusterLiteralMatch = !cleanLit.isEmpty && isClusterOnsetSubstitution(target: cleanTarget, candidate: cleanLit)
        let hasFuzzyLiteral = hasExactLiteral || isCompoundGlued || isEpentheticRelease || isClusterLiteralMatch || (!cleanLit.isEmpty && (cleanLit.contains(cleanTarget) || cleanTarget.contains(cleanLit)) && abs(cleanLit.count - cleanTarget.count) <= 1 && cleanTarget.count >= 6)

        let hasExactSFSpeech: Bool = {
            if !cleanSF.isEmpty {
                return matchesWord(target: cleanTarget, candidate: cleanSF)
            } else {
                return allSFSpeechWords.contains { matchesWord(target: cleanTarget, candidate: $0) }
            }
        }()
        let hasFuzzySFSpeech = hasExactSFSpeech || (!cleanSF.isEmpty && (cleanSF.contains(cleanTarget) || cleanTarget.contains(cleanSF)) && abs(cleanSF.count - cleanTarget.count) <= 1 && cleanTarget.count >= 6)

        let literalMatched = hasFuzzyLiteral
        let sfSpeechMatched = hasFuzzySFSpeech

        if literalMatched && sfSpeechMatched {
            return .dualMatch
        } else if literalMatched && !sfSpeechMatched {
            return .literalOnly
        } else if !literalMatched && sfSpeechMatched {
            return .sfSpeechOnly
        } else {
            return .dualRejection
        }
    }

    /// Retained bridge method: resolves consensus state and provides structured fallback scoring.
    static func resolveWord(
        targetWord: String,
        alignedLiteral: String?,
        allLiteralWords: Set<String>,
        alignedSFSpeech: String?,
        allSFSpeechWords: Set<String>,
        phoneScores: [PhonemeFeedback] = [],
        baseAvgScore: Int,
        isFunctionWord: Bool = false,
        isClitic: Bool = false,
        isMissing: Bool = false,
        dtwDistance: Float = 0.0,
        isStressInverted: Bool = false,
        isVoicingHarmonyDefective: Bool = false,
        alignedPhonemes: [AlignedPhonemePair] = []
    ) -> DiscrepancyResult {
        let cleanTarget = cleanWord(targetWord)
        let cleanLit = alignedLiteral != nil ? cleanWord(alignedLiteral!) : ""
        let vMerge = !cleanLit.isEmpty && isBenignVowelMerge(target: cleanTarget, heard: cleanLit)

        let consensus = resolveConsensusState(
            targetWord: targetWord,
            alignedLiteral: alignedLiteral,
            allLiteralWords: allLiteralWords,
            alignedSFSpeech: alignedSFSpeech,
            allSFSpeechWords: allSFSpeechWords,
            alignedPhonemes: alignedPhonemes,
            isStressInverted: isStressInverted,
            isVoicingHarmonyDefective: isVoicingHarmonyDefective
        )

        let status: PronunciationStatus = consensus == .dualRejection ? (baseAvgScore >= 65 ? .needsWork : .incorrect) : (baseAvgScore >= 65 ? .good : .needsWork)
        let score: Int = consensus == .dualRejection ? min(baseAvgScore, 58) : max(baseAvgScore, 65)

        return DiscrepancyResult(
            status: status,
            score: score,
            consensusState: consensus,
            isVowelMerge: vMerge,
            diagnosticReason: "ConsensusResolved(\(consensus.rawValue))"
        )
    }
}

// MARK: - Phonological Tables, Word Cleaning & Dynamic Sequence Alignment

nonisolated extension DiscrepancyEngine {
    
    static let vowels: Set<String> = [
        "iː", "ɪ", "eɪ", "ɛ", "æ", "ɑː", "ɒ", "ɔː", "ʊ", "uː", "ʌ", "ɜː", "ə",
        "aɪ", "aʊ", "ɔɪ", "ɪə", "eə", "ʊə", "ɚ", "ɝ", "ɐ", "a", "oʊ",
        "ɛɹ", "ɪɹ", "ʊɹ", "ɑːɹ", "ɔːɹ"
    ]
    
    static let digitToWord: [String: String] = [
        "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
        "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine",
        "10": "ten", "11": "eleven", "12": "twelve", "13": "thirteen",
        "14": "fourteen", "15": "fifteen", "16": "sixteen", "17": "seventeen",
        "18": "eighteen", "19": "nineteen", "20": "twenty"
    ]
    
    static let homophones: [String: Set<String>] = [
        "one": ["won", "1"], "two": ["to", "too", "2"], "four": ["for", "fore", "4"],
        "eight": ["ate", "8"], "nine": ["9"], "seven": ["7"], "six": ["6"],
        "three": ["3"], "zero": ["0"], "t": ["tee", "tea"], "b": ["bee", "be"],
        "c": ["see", "sea"], "see": ["c", "sea"], "sea": ["see", "c"],
        "scene": ["seen", "see"], "seen": ["scene", "see"],
        "i": ["eye"], "u": ["you"], "no": ["know"], "know": ["no"],
        "then": ["than"], "than": ["then"], "there": ["their", "theyre", "they're"],
        "their": ["there", "theyre", "they're"], "they're": ["there", "their", "theyre"],
        "here": ["hear"], "hear": ["here"], "by": ["buy", "bye"],
        "buy": ["by", "bye"], "bye": ["by", "buy"], "our": ["hour"],
        "hour": ["our"], "right": ["write"], "write": ["right"],
        "ladder": ["latter"], "latter": ["ladder"]
    ]
    
    static let orthographicVariants: [String: Set<String>] = [
        "gray": ["grey"], "grey": ["gray"],
        "color": ["colour"], "colour": ["color"],
        "flavor": ["flavour"], "flavour": ["flavor"],
        "theater": ["theatre"], "theatre": ["theater"],
        "center": ["centre"], "centre": ["center"],
        "defense": ["defence"], "defence": ["defense"],
        "license": ["licence"], "licence": ["license"],
        "traveling": ["travelling"], "travelling": ["traveling"],
        "traveled": ["travelled"], "travelled": ["traveled"],
        "debutante": ["debutant"], "debutant": ["debutante"],
        "disheveled": ["dishevelled"], "dishevelled": ["disheveled"],
        "program": ["programme"], "programme": ["program"],
        "catalog": ["catalogue"], "catalogue": ["catalog"],
        "judgment": ["judgement"], "judgement": ["judgment"],
        "fulfill": ["fulfil"], "fulfil": ["fulfill"],
        "dialog": ["dialogue"], "dialogue": ["dialog"],
        "whisky": ["whiskey"], "whiskey": ["whisky"]
    ]
    
    /// Map of compound words and their valid segmented components
    static let compoundEquivalents: [String: [String]] = [
        "forever": ["for", "ever"],
        "midstream": ["mid", "stream"],
        "cannot": ["can", "not"],
        "anyway": ["any", "way"],
        "someday": ["some", "day"],
        "everywhere": ["every", "where"],
        "into": ["in", "to"],
        "railroad": ["rail", "road"],
        "anyone": ["any", "one"],
        "someone": ["some", "one"],
        "everyone": ["every", "one"],
        "something": ["some", "thing"],
        "anything": ["any", "thing"],
        "everything": ["every", "thing"],
        "nobody": ["no", "body"],
        "somebody": ["some", "body"],
        "anybody": ["any", "body"],
        "everybody": ["every", "body"],
        "nowhere": ["no", "where"],
        "somewhere": ["some", "where"],
        "anywhere": ["any", "where"],
        "meanwhile": ["mean", "while"],
        "without": ["with", "out"],
        "within": ["with", "in"],
        "throughout": ["through", "out"],
        // Contraction expansions (1 word <-> 2 words)
        "shes": ["she", "is"],
        "hes": ["he", "is"],
        "its": ["it", "is"],
        "thats": ["that", "is"],
        "theres": ["there", "is"],
        "whats": ["what", "is"],
        "whos": ["who", "is"],
        "im": ["i", "am"],
        "youre": ["you", "are"],
        "theyre": ["they", "are"],
        "ive": ["i", "have"],
        "youve": ["you", "have"],
        "weve": ["we", "have"],
        "theyve": ["they", "have"],
        "ill": ["i", "will"],
        "youll": ["you", "will"],
        "theyll": ["they", "will"],
        "dont": ["do", "not"],
        "doesnt": ["does", "not"],
        "didnt": ["did", "not"],
        "cant": ["can", "not"],
        "wont": ["will", "not"],
        "isnt": ["is", "not"],
        "arent": ["are", "not"],
        "wasnt": ["was", "not"],
        "werent": ["were", "not"],
        "hasnt": ["has", "not"],
        "havent": ["have", "not"],
        "hadnt": ["had", "not"],
        "couldnt": ["could", "not"],
        "shouldnt": ["should", "not"],
        "wouldnt": ["would", "not"]
    ]
    
    /// Checks whether two cleaned words are equivalent in spelling, dialect, contraction, or homophone
    static func isWordEquivalent(_ w1: String, _ w2: String) -> Bool {
        if w1 == w2 { return true }
        let c1 = cleanWord(w1)
        let c2 = cleanWord(w2)
        if c1 == c2 { return true }
        if orthographicVariants[c1]?.contains(c2) == true { return true }
        if homophones[c1]?.contains(c2) == true { return true }
        return false
    }
    
    /// Checks whether a single word matches a 2-word compound segmentation (e.g. "forever" == "for" + "ever")
    static func isCompoundMatch(single: String, part1: String, part2: String) -> Bool {
        let cleanSingle = cleanWord(single)
        let c1 = cleanWord(part1)
        let c2 = cleanWord(part2)
        if cleanSingle == c1 + c2 { return true }
        if let expectedParts = compoundEquivalents[cleanSingle] {
            if expectedParts.count == 2 && expectedParts[0] == c1 && expectedParts[1] == c2 {
                return true
            }
        }
        return false
    }
    
    static func cleanWord(_ word: String) -> String {
        let lower = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        if let mapped = digitToWord[lower] {
            return mapped
        }
        let alphanum = lower.filter { $0.isLetter || $0.isNumber }
        if let mappedAlpha = digitToWord[alphanum] {
            return mappedAlpha
        }
        return alphanum.filter { $0.isLetter }
    }
    
    static func levenshtein(_ s1: String, _ s2: String) -> Int {
        if s1.count < s2.count { return levenshtein(s2, s1) }
        if s2.isEmpty { return s1.count }
        var prev = Array(0...s2.count)
        for (i, c1) in s1.enumerated() {
            var curr = [i + 1]
            for (j, c2) in s2.enumerated() {
                let ins = prev[j + 1] + 1
                let dels = curr[j] + 1
                let subs = prev[j] + (c1 == c2 ? 0 : 1)
                curr.append(min(ins, dels, subs))
            }
            prev = curr
        }
        return prev.last ?? 0
    }
    
    static func matchesWord(target: String, candidate: String) -> Bool {
        let ct = cleanWord(target)
        let cc = cleanWord(candidate)
        if ct.isEmpty || cc.isEmpty { return false }
        if ct == cc { return true }
        if let hSet = homophones[ct], hSet.contains(cc) { return true }
        if let hSet2 = homophones[cc], hSet2.contains(ct) { return true }
        if ct.count >= 6 && cc.count >= 6 && levenshtein(ct, cc) <= 1 {
            return extractConsonants(ct) == extractConsonants(cc)
        }
        return false
    }
    
    /// Matches words allowing common morphological variants, compound prefixes, and coda stop inflections
    static func matchesWordMorphologically(target: String, candidate: String) -> Bool {
        let ct = cleanWord(target)
        let cc = cleanWord(candidate)
        if ct.isEmpty || cc.isEmpty { return false }
        // 0. Clitic / Contraction / Inflection variations (e.g. "it" vs "its", "let" vs "lets", "he" vs "hes")
        if (cc == ct + "s" || ct == cc + "s" ||
            cc == ct + "d" || ct == cc + "d" ||
            cc == ct + "ll" || ct == cc + "ll" ||
            cc == ct + "re" || ct == cc + "re" ||
            cc == ct + "ve" || ct == cc + "ve") {
            return true
        }
        
        // 1. Compound noun / sub-token containment (e.g. "shirt" in "tshirt", "day" in "birthday")
        if ct.hasSuffix(cc) || cc.hasSuffix(ct) {
            let shortLen = min(ct.count, cc.count)
            let longLen = max(ct.count, cc.count)
            if shortLen >= 3 && Float(shortLen) / Float(longLen) >= 0.50 {
                return true
            }
        }
        
        // 2. Common grammatical and derivational inflection stripping
        func stripInflection(_ w: String) -> String {
            let suffixes = ["ian", "ing", "est", "ers", "er", "es", "ed", "al", "ly", "en", "s"]
            for s in suffixes {
                if w.count > s.count + 2 && w.hasSuffix(s) {
                    return String(w.dropLast(s.count))
                }
            }
            return w
        }
        
        let stemT = stripInflection(ct)
        let stemC = stripInflection(cc)
        if stemT == stemC && stemT.count >= 3 {
            return true
        }
        if (stemT.hasPrefix(stemC) || stemC.hasPrefix(stemT)) && min(stemT.count, stemC.count) >= 4 {
            return true
        }
        
        // 3. Trailing coda consonant expansion (e.g. "plan" vs "plant")
        if (ct.count >= 4 && cc.count == ct.count + 1 && cc.hasPrefix(ct)) ||
           (cc.count >= 4 && ct.count == cc.count + 1 && ct.hasPrefix(cc)) {
            return true
        }
        
        return false
    }
    
    static func extractConsonants(_ word: String) -> String {
        let clean = cleanWord(word)
        let vowelsChar: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        let rawCons = clean.filter { !vowelsChar.contains($0) }
            .replacingOccurrences(of: "ck", with: "k")
        var collapsed = ""
        for c in rawCons {
            if collapsed.last != c {
                collapsed.append(c)
            }
        }
        return collapsed
    }
    
    static func extractVowels(_ word: String) -> String {
        let clean = cleanWord(word)
        let vowelsChar: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        let rawVowels = clean.filter { vowelsChar.contains($0) }
        var collapsed = ""
        for c in rawVowels {
            if collapsed.last != c {
                collapsed.append(c)
            }
        }
        return collapsed
    }
    
    static func isVowelPhone(_ phone: String) -> Bool {
        let clean = phone.components(separatedBy: CharacterSet.decimalDigits).joined()
            .replacingOccurrences(of: "ˈ", with: "")
            .replacingOccurrences(of: "ˌ", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
        return vowels.contains(clean)
    }
    
    static func isBenignVowelMerge(target: String, heard: String) -> Bool {
        let tClean = cleanWord(target)
        let hClean = cleanWord(heard)
        if tClean.count <= 4 { return false }
        
        let tCons = extractConsonants(target)
        let hCons = extractConsonants(heard)
        guard !tCons.isEmpty, !hCons.isEmpty else { return false }
        
        let tV = extractVowels(tClean)
        let hV = extractVowels(hClean)
        
        // Exact consonant skeleton match
        if tCons == hCons {
            if tV == hV { return true }
            // Vowel shift is only benign if at most 1 vowel is substituted or reduced
            if levenshtein(tV, hV) <= 1 {
                return true
            }
            return false
        }
        
        // Single voicing difference (e.g. s <-> z)
        if tCons.count == hCons.count {
            var diffCount = 0
            var isVoicing = false
            for (tc, hc) in zip(tCons, hCons) {
                if tc != hc {
                    diffCount += 1
                    if (tc == "s" && hc == "z") || (tc == "z" && hc == "s") ||
                       (tc == "t" && hc == "d") || (tc == "d" && hc == "t") ||
                       (tc == "f" && hc == "v") || (tc == "v" && hc == "f") {
                        isVoicing = true
                    }
                }
            }
            if diffCount == 1 && isVoicing {
                return tV == hV || levenshtein(tV, hV) <= 1
            }
        }
        
        return false
    }
    
    /// Checks whether candidate represents an intelligible L2 onset cluster simplification of target (e.g. tr->ch, dr->j, thr->f/s)
    static func isClusterOnsetSubstitution(target: String, candidate: String) -> Bool {
        let ct = cleanWord(target)
        let cc = cleanWord(candidate)
        guard ct.count >= 3 && cc.count >= 2 else { return false }
        
        let tCons = extractConsonants(ct)
        let cCons = extractConsonants(cc)
        
        // tr- -> ch- (train -> chain, try -> chy)
        if ct.hasPrefix("tr") && (cc.hasPrefix("ch") || cc.hasPrefix("sh")) {
            let tailT = tCons.hasPrefix("tr") ? String(tCons.dropFirst(2)) : String(tCons.dropFirst(1))
            let tailC = cCons.hasPrefix("ch") || cCons.hasPrefix("sh") ? String(cCons.dropFirst(2)) : String(cCons.dropFirst(1))
            if tailT == tailC { return true }
            let tailRawT = String(ct.dropFirst(2))
            let tailRawC = String(cc.dropFirst(2))
            return tailRawT == tailRawC || levenshtein(tailRawT, tailRawC) <= 1
        }
        // dr- -> j- / dj- (draw -> jaw)
        if ct.hasPrefix("dr") && (cc.hasPrefix("j") || cc.hasPrefix("dj")) {
            let tailT = tCons.hasPrefix("dr") ? String(tCons.dropFirst(2)) : String(tCons.dropFirst(1))
            let tailC = cCons.hasPrefix("dj") ? String(cCons.dropFirst(2)) : String(cCons.dropFirst(1))
            if tailT == tailC { return true }
            let tailRawT = String(ct.dropFirst(2))
            let tailRawC = cc.hasPrefix("dj") ? String(cc.dropFirst(2)) : String(cc.dropFirst(1))
            return tailRawT == tailRawC || levenshtein(tailRawT, tailRawC) <= 1
        }
        // thr- -> f- / s- / t- (three -> free / tree)
        if ct.hasPrefix("thr") && (cc.hasPrefix("f") || cc.hasPrefix("s") || cc.hasPrefix("t")) {
            let tailT = tCons.hasPrefix("thr") ? String(tCons.dropFirst(3)) : (tCons.hasPrefix("th") ? String(tCons.dropFirst(2)) : String(tCons.dropFirst(1)))
            let tailC = String(cCons.dropFirst(1))
            if tailT == tailC { return true }
            let tailRawT = String(ct.dropFirst(3))
            let tailRawC = String(cc.dropFirst(1))
            return tailRawT == tailRawC || levenshtein(tailRawT, tailRawC) <= 1
        }
        // Liquid /r/ deletion in stop+r clusters: pr->p, br->b, gr->g, cr/kr->c/k, fr->f
        let onsetStopClusters = ["pr", "br", "gr", "cr", "kr", "fr"]
        for prefix in onsetStopClusters {
            if ct.hasPrefix(prefix) {
                let stopChar = prefix.first!
                if cc.first == stopChar && !cc.hasPrefix(prefix) {
                    let tailT = tCons.hasPrefix(prefix) ? String(tCons.dropFirst(2)) : String(tCons.dropFirst(1))
                    let tailC = String(cCons.dropFirst(1))
                    if tailT == tailC { return true }
                    let tailRawT = String(ct.dropFirst(2))
                    let tailRawC = String(cc.dropFirst(1))
                    if tailRawT == tailRawC || levenshtein(tailRawT, tailRawC) <= 1 { return true }
                }
            }
        }
        return false
    }
    
    /// Checks whether aligned phonemes reflect an intelligible L2 /ɹ/-cluster onset simplification
    static func hasPhoneticClusterOnsetShift(alignedPhonemes: [AlignedPhonemePair]) -> Bool {
        let pairsWithExpected = alignedPhonemes.filter { $0.expected != nil }
        guard pairsWithExpected.count >= 2 else { return false }
        
        let p0 = pairsWithExpected[0]
        let p1 = pairsWithExpected[1]
        guard let exp0 = p0.expected, let exp1 = p1.expected else { return false }
        let cExp0 = PhonemeWordAligner.cleanPhone(exp0)
        let cExp1 = PhonemeWordAligner.cleanPhone(exp1)
        
        if cExp1 == "ɹ" {
            let hrd0 = p0.heard != nil ? PhonemeWordAligner.cleanPhone(p0.heard!) : ""
            // t + ɹ -> tʃ
            if cExp0 == "t" && (hrd0 == "tʃ" || hrd0 == "tɕ" || hrd0 == "ʃ") {
                return true
            }
            // d + ɹ -> dʒ
            if cExp0 == "d" && (hrd0 == "dʒ" || hrd0 == "dʑ" || hrd0 == "ʒ") {
                return true
            }
            // θ + ɹ -> f / s / t
            if cExp0 == "θ" && (hrd0 == "f" || hrd0 == "s" || hrd0 == "t") {
                return true
            }
            // /ɹ/ replaced by glide /w/, /j/, /ʋ/, /l/, or tap /ɾ/
            if let hrd1 = p1.heard {
                let cHrd1 = PhonemeWordAligner.cleanPhone(hrd1)
                if cHrd1 == "w" || cHrd1 == "j" || cHrd1 == "ʋ" || cHrd1 == "l" || cHrd1 == "ɾ" {
                    return true
                }
            }
        }
        return false
    }
    
    static func alignWords(targetWords: [String], streamWords: [String]) -> [Int: String] {
        let n = targetWords.count
        let m = streamWords.count
        if n == 0 || m == 0 { return [:] }
        
        let tClean = targetWords.map { cleanWord($0) }
        let sClean = streamWords.map { cleanWord($0) }
        
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i * 2 }
        for j in 0...m { dp[0][j] = j * 2 }
        
        for i in 1...n {
            for j in 1...m {
                let tw = tClean[i - 1]
                let sw = sClean[j - 1]
                let cost: Int
                if tw == sw {
                    cost = 0
                } else if !tw.isEmpty && !sw.isEmpty && (tw.contains(sw) || sw.contains(tw)) {
                    cost = 1
                } else if isBenignVowelMerge(target: tw, heard: sw) {
                    cost = 1
                } else {
                    cost = 3
                }
                
                dp[i][j] = min(
                    dp[i - 1][j - 1] + cost,
                    dp[i - 1][j] + 2,
                    dp[i][j - 1] + 2
                )
            }
        }
        
        var i = n
        var j = m
        var aligned: [Int: String] = [:]
        
        while i > 0 && j > 0 {
            let tw = tClean[i - 1]
            let sw = sClean[j - 1]
            let cost: Int
            if tw == sw {
                cost = 0
            } else if !tw.isEmpty && !sw.isEmpty && (tw.contains(sw) || sw.contains(tw)) {
                cost = 1
            } else if isBenignVowelMerge(target: tw, heard: sw) {
                cost = 1
            } else {
                cost = 3
            }
            
            if dp[i][j] == dp[i - 1][j - 1] + cost {
                aligned[i - 1] = streamWords[j - 1]
                i -= 1
                j -= 1
            } else if dp[i][j] == dp[i - 1][j] + 2 {
                i -= 1
            } else {
                j -= 1
            }
        }
        
        return aligned
    }
}
