import Foundation

struct BeamState: Hashable {
    let text: String
    let lastToken: Int?
    let matchedWordsCount: Int
    
    init(text: String, lastToken: Int?, matchedWordsCount: Int = 0) {
        self.text = text
        self.lastToken = lastToken
        self.matchedWordsCount = matchedWordsCount
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(text)
        hasher.combine(lastToken)
        hasher.combine(matchedWordsCount)
    }
    
    static func == (lhs: BeamState, rhs: BeamState) -> Bool {
        return lhs.text == rhs.text && lhs.lastToken == rhs.lastToken && lhs.matchedWordsCount == rhs.matchedWordsCount
    }
}

public struct DecodeResult: Sendable {
    public let snapped: String
    public let literal: String
    public let topBeams: [String]
    
    public init(snapped: String, literal: String, topBeams: [String] = []) {
        self.snapped = snapped
        self.literal = literal
        self.topBeams = topBeams
    }
}

class CTCDecoder {
    let trie: LexiconTrie
    let vocab: [String] // Must match the Wav2Vec2 vocab list (~32 items)
    let blankIndex: Int
    let spaceChar: Character = " "
    
    let languageModel: LanguageModel?
    let alpha: Float
    let beta: Float
    
    init(trie: LexiconTrie, vocab: [String], blankIndex: Int, languageModel: LanguageModel? = nil, alpha: Float = 0.35, beta: Float = 0.0) {
        self.trie = trie
        self.vocab = vocab.map { $0.replacingOccurrences(of: "|", with: " ").lowercased() }
        self.blankIndex = blankIndex
        self.languageModel = languageModel
        self.alpha = alpha
        self.beta = beta
    }
    
    /// Greedy best-path decoding for literal acoustic mirror output
    func greedyDecode(logProbs: [[Float]]) -> String {
        var result = ""
        var lastIndex = -1
        
        for frame in logProbs {
            var maxIdx = 0
            var maxVal: Float = -Float.infinity
            for i in 0..<frame.count {
                if frame[i] > maxVal {
                    maxVal = frame[i]
                    maxIdx = i
                }
            }
            if maxIdx != blankIndex && maxIdx != lastIndex {
                result += vocab[maxIdx]
            }
            lastIndex = maxIdx
        }
        return result.replacingOccurrences(of: " ", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Prefix Beam Search with Trie Constraints and N-gram LM

extension CTCDecoder {
    
    /// Log-add function to prevent underflow
    func logAdd(_ a: Float, _ b: Float) -> Float {
        if a == -Float.infinity { return b }
        if b == -Float.infinity { return a }
        let maxVal = max(a, b)
        return maxVal + log(1.0 + exp(min(a, b) - maxVal))
    }
    
    func normalizeContraction(_ str: String) -> String {
        return str.replacingOccurrences(of: "'", with: "").lowercased()
    }
    
    func getAliases(for word: String) -> [String] {
        let w = normalizeContraction(word)
        var aliases: Set<String> = [w]
        
        // Orthographic & Phonetic onset rules
        if w.hasPrefix("ph") {
            aliases.insert("f" + w.dropFirst(2))
        }
        if w.hasPrefix("wr") {
            aliases.insert("r" + w.dropFirst(2))
        }
        if w.hasPrefix("kn") {
            aliases.insert("n" + w.dropFirst(2))
        }
        if w.hasPrefix("one") {
            aliases.insert("won" + w.dropFirst(3))
        }
        if w == "once" {
            aliases.insert("wonce")
        }
        if w == "eight" {
            aliases.insert("ate")
        }
        
        // High-frequency homophones and identical sound pairs
        switch w {
        case "see", "sea":
            aliases.insert("see"); aliases.insert("sea")
        case "two", "to", "too":
            aliases.insert("two"); aliases.insert("to"); aliases.insert("too")
        case "for", "four":
            aliases.insert("for"); aliases.insert("four")
        case "here", "hear":
            aliases.insert("here"); aliases.insert("hear")
        case "there", "their", "theyre":
            aliases.insert("there"); aliases.insert("their"); aliases.insert("theyre")
        case "no", "know":
            aliases.insert("no"); aliases.insert("know")
        case "right", "write":
            aliases.insert("right"); aliases.insert("write")
        case "buy", "by", "bye":
            aliases.insert("buy"); aliases.insert("by"); aliases.insert("bye")
        case "son", "sun":
            aliases.insert("son"); aliases.insert("sun")
        case "meat", "meet":
            aliases.insert("meat"); aliases.insert("meet")
        case "week", "weak":
            aliases.insert("week"); aliases.insert("weak")
        case "hour", "our":
            aliases.insert("hour"); aliases.insert("our")
        default:
            break
        }
        return Array(aliases)
    }
    
    func isWordMatch(_ candidate: String, _ ref: String) -> Bool {
        let c = candidate.lowercased()
        let r = ref.lowercased()
        if c == r || normalizeContraction(c) == normalizeContraction(r) {
            return true
        }
        let cAliases = getAliases(for: c)
        let rAliases = getAliases(for: r)
        for ra in rAliases {
            if cAliases.contains(ra) { return true }
        }
        return false
    }
    
    func isPrefixMatch(_ candidatePrefix: String, _ ref: String) -> Bool {
        let cp = candidatePrefix.lowercased()
        let r = ref.lowercased()
        if r.hasPrefix(cp) || normalizeContraction(r).hasPrefix(normalizeContraction(cp)) {
            return true
        }
        let rAliases = getAliases(for: r)
        let normCP = normalizeContraction(cp)
        for ra in rAliases {
            if ra.hasPrefix(normCP) { return true }
        }
        return false
    }
    
    func levenshteinDistance(_ s1: [Character], _ s2: [Character]) -> Int {
        let m = s1.count
        let n = s2.count
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = s1[i - 1] == s2[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = curr
        }
        return prev[n]
    }
    
    func isNearMatch(_ candidate: String, _ ref: String) -> Bool {
        let c = normalizeContraction(candidate)
        let r = normalizeContraction(ref)
        if c == r { return true }
        if c.count < 3 || r.count < 3 { return false }
        
        let cAliases = getAliases(for: c)
        let rAliases = getAliases(for: r)
        for ra in rAliases {
            let raChars = Array(ra)
            for ca in cAliases {
                if ca == ra { return true }
                let caChars = Array(ca)
                if caChars.first == raChars.first {
                    let d = levenshteinDistance(caChars, raChars)
                    if d <= 1 { return true }
                    if d <= 2 && raChars.count >= 4 && caChars.count >= 3 { return true }
                }
            }
        }
        return false
    }
    
    /// Extract the current active word from the end of the text
    func currentWord(of text: String) -> Substring {
        guard let lastSpaceIndex = text.lastIndex(of: spaceChar) else {
            return text[...]
        }
        let nextIndex = text.index(after: lastSpaceIndex)
        return text[nextIndex...]
    }
    
    /// Extract the current active word and the preceding word from text
    func lastTwoWords(of text: String) -> (current: Substring, previous: Substring?) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let lastSpace = trimmed.lastIndex(of: spaceChar) else {
            return (trimmed[...], nil)
        }
        let current = trimmed[trimmed.index(after: lastSpace)...]
        let remaining = trimmed[..<lastSpace].trimmingCharacters(in: .whitespaces)
        if let prevSpace = remaining.lastIndex(of: spaceChar) {
            let prev = remaining[remaining.index(after: prevSpace)...]
            return (current, prev)
        } else {
            return (current, remaining.isEmpty ? nil : remaining[...])
        }
    }
    
    /// Decode a sequence of log-probabilities
    /// logProbs shape: [frames][vocab_size]
    func decode(logProbs: [[Float]], referenceText: String? = nil, beamWidth: Int = 80) -> DecodeResult {
        let literalText = greedyDecode(logProbs: logProbs)
        
        let refWords: [String]
        let refWordSet: Set<String>
        if let ref = referenceText, !ref.isEmpty {
            let allowedChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'"))
            refWords = ref.lowercased()
                .components(separatedBy: allowedChars.inverted)
                .filter { !$0.isEmpty }
            refWordSet = Set(refWords)
        } else {
            refWords = []
            refWordSet = []
        }
        let hasReference = !refWords.isEmpty
        
        var beams: [BeamState: (Float, Float)] = [BeamState(text: "", lastToken: nil, matchedWordsCount: 0): (0.0, -Float.infinity)]
        
        for frame in logProbs {
            var nextBeams: [BeamState: (Float, Float)] = [:]
            
            let maxFrameVal = frame.max() ?? 0
            let framePruneThreshold = max(maxFrameVal - 8.0, -18.0)
            let blankProb = frame[blankIndex]
            let isBlankDominant = blankProb > -0.35
            
            for (beam, probs) in beams {
                let (p_b, p_nb) = probs
                let text = beam.text
                let matchedCount = beam.matchedWordsCount
                
                // 1. Extend with blank token
                if blankProb > -50.0 {
                    let p_total = logAdd(p_b, p_nb)
                    let new_p_b = p_total + blankProb
                    
                    if let existing = nextBeams[beam] {
                        nextBeams[beam] = (logAdd(existing.0, new_p_b), existing.1)
                    } else {
                        nextBeams[beam] = (new_p_b, -Float.infinity)
                    }
                }
                
                // 2. Extend with non-blank characters
                if !isBlankDominant || blankProb < -0.05 {
                    for c in 0..<vocab.count {
                        if c == blankIndex { continue }
                        let p = frame[c]
                        if p < framePruneThreshold { continue }
                        
                        let char = vocab[c]
                        guard let charVal = char.first else { continue }
                        let isSpace = (charVal == spaceChar)
                        
                        if c == beam.lastToken {
                            // Subcase A: Sustained character without intervening blank (collapses)
                            if p_nb > -Float.infinity {
                                let new_p_nb = p_nb + p
                                let state = BeamState(text: text, lastToken: c, matchedWordsCount: matchedCount)
                                if let existing = nextBeams[state] {
                                    nextBeams[state] = (existing.0, logAdd(existing.1, new_p_nb))
                                } else {
                                    nextBeams[state] = (-Float.infinity, new_p_nb)
                                }
                            }
                            
                            // Subcase B: Repeated character separated by an intervening blank (extends prefix)
                            if p_b > -Float.infinity {
                                var newText = text
                                var newMatchedCount = matchedCount
                                var isValid = false
                                var scoreBonus: Float = 0.0
                                
                                if isSpace {
                                    let curr = currentWord(of: text)
                                    if !curr.isEmpty {
                                        let currStr = String(curr).lowercased()
                                        if currStr.count == 1 && currStr != "a" && currStr != "i" {
                                            isValid = false
                                        } else if hasReference {
                                            if matchedCount < refWords.count && isWordMatch(currStr, refWords[matchedCount]) {
                                                isValid = true
                                                scoreBonus += 6.0
                                                newMatchedCount += 1
                                            } else if refWordSet.contains(currStr) {
                                                isValid = true
                                                scoreBonus += 3.0
                                            } else if matchedCount < refWords.count && isNearMatch(currStr, refWords[matchedCount]) {
                                                isValid = true
                                                scoreBonus += 2.0
                                                newMatchedCount += 1
                                            } else {
                                                isValid = trie.isExactWord(curr)
                                            }
                                        } else {
                                            isValid = trie.isExactWord(curr)
                                        }
                                        
                                        if isValid {
                                            if let lm = languageModel {
                                                let words = lastTwoWords(of: text)
                                                let currWord = String(words.current)
                                                if let prevWord = words.previous {
                                                    let bigramProb = lm.score(word: currWord, prevWord: String(prevWord))
                                                    scoreBonus += alpha * bigramProb + beta
                                                } else {
                                                    let unigramProb = lm.score(word: currWord)
                                                    scoreBonus += alpha * unigramProb + beta
                                                }
                                                if !lm.contains(word: currWord) {
                                                    scoreBonus -= 2.5
                                                }
                                            }
                                            newText.append(spaceChar)
                                        }
                                    }
                                } else {
                                    newText.append(charVal)
                                    let curr = currentWord(of: newText)
                                    let currStr = String(curr).lowercased()
                                    if hasReference {
                                        if matchedCount < refWords.count && isPrefixMatch(currStr, refWords[matchedCount]) {
                                            isValid = true
                                        } else if refWords.contains(where: { isPrefixMatch(currStr, $0) }) {
                                            isValid = true
                                        } else {
                                            isValid = trie.isValidPrefix(curr)
                                        }
                                    } else {
                                        isValid = trie.isValidPrefix(curr)
                                    }
                                }
                                
                                if isValid {
                                    let new_p_nb = p_b + p + scoreBonus
                                    let state = BeamState(text: newText, lastToken: c, matchedWordsCount: newMatchedCount)
                                    if let existing = nextBeams[state] {
                                        nextBeams[state] = (existing.0, logAdd(existing.1, new_p_nb))
                                    } else {
                                        nextBeams[state] = (-Float.infinity, new_p_nb)
                                    }
                                }
                            }
                        } else {
                            // Subcase C: Different character from last token (always extends prefix)
                            let p_total = logAdd(p_b, p_nb)
                            if p_total > -Float.infinity {
                                var newText = text
                                var newMatchedCount = matchedCount
                                var isValid = false
                                var scoreBonus: Float = 0.0
                                
                                if isSpace {
                                    let curr = currentWord(of: text)
                                    if !curr.isEmpty {
                                        let currStr = String(curr).lowercased()
                                        if currStr.count == 1 && currStr != "a" && currStr != "i" {
                                            isValid = false
                                        } else if hasReference {
                                            if matchedCount < refWords.count && isWordMatch(currStr, refWords[matchedCount]) {
                                                isValid = true
                                                scoreBonus += 6.0
                                                newMatchedCount += 1
                                            } else if refWordSet.contains(currStr) {
                                                isValid = true
                                                scoreBonus += 3.0
                                            } else if matchedCount < refWords.count && isNearMatch(currStr, refWords[matchedCount]) {
                                                isValid = true
                                                scoreBonus += 2.0
                                                newMatchedCount += 1
                                            } else {
                                                isValid = trie.isExactWord(curr)
                                            }
                                        } else {
                                            isValid = trie.isExactWord(curr)
                                        }
                                        
                                        if isValid {
                                            if let lm = languageModel {
                                                let words = lastTwoWords(of: text)
                                                let currWord = String(words.current)
                                                if let prevWord = words.previous {
                                                    let bigramProb = lm.score(word: currWord, prevWord: String(prevWord))
                                                    scoreBonus += alpha * bigramProb + beta
                                                } else {
                                                    let unigramProb = lm.score(word: currWord)
                                                    scoreBonus += alpha * unigramProb + beta
                                                }
                                                if !lm.contains(word: currWord) {
                                                    scoreBonus -= 2.5
                                                }
                                            }
                                            newText.append(spaceChar)
                                        }
                                    }
                                } else {
                                    newText.append(charVal)
                                    let curr = currentWord(of: newText)
                                    let currStr = String(curr).lowercased()
                                    if hasReference {
                                        if matchedCount < refWords.count && isPrefixMatch(currStr, refWords[matchedCount]) {
                                            isValid = true
                                        } else if refWords.contains(where: { isPrefixMatch(currStr, $0) }) {
                                            isValid = true
                                        } else {
                                            isValid = trie.isValidPrefix(curr)
                                        }
                                    } else {
                                        isValid = trie.isValidPrefix(curr)
                                    }
                                }
                                
                                if isValid {
                                    let new_p_nb = p_total + p + scoreBonus
                                    let state = BeamState(text: newText, lastToken: c, matchedWordsCount: newMatchedCount)
                                    if let existing = nextBeams[state] {
                                        nextBeams[state] = (existing.0, logAdd(existing.1, new_p_nb))
                                    } else {
                                        nextBeams[state] = (-Float.infinity, new_p_nb)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            // Beam pruning
            let scoredBeams = nextBeams.map { (state: $0.key, prob: logAdd($0.value.0, $0.value.1)) }
            var sortedBeams = scoredBeams.sorted { $0.prob > $1.prob }
            if sortedBeams.count > beamWidth {
                sortedBeams = Array(sortedBeams.prefix(beamWidth))
            }
            
            var prunedNextBeams: [BeamState: (Float, Float)] = [:]
            for sb in sortedBeams {
                prunedNextBeams[sb.state] = nextBeams[sb.state]
            }
            beams = prunedNextBeams
        }
        
        // Finalize beams
        var bestScore: Float = -Float.infinity
        var bestText = ""
        var maxMatchedWords = -1
        var scoredFinalBeams: [(text: String, score: Float, matchedCount: Int)] = []
        
        for (beam, probs) in beams {
            var totalProb = logAdd(probs.0, probs.1)
            let curr = currentWord(of: beam.text)
            
            if !curr.isEmpty {
                let currStr = String(curr).lowercased()
                var isValid = false
                if currStr.count == 1 && currStr != "a" && currStr != "i" {
                    isValid = false
                } else if hasReference {
                    if beam.matchedWordsCount < refWords.count && isWordMatch(currStr, refWords[beam.matchedWordsCount]) {
                        isValid = true
                    } else if refWordSet.contains(currStr) {
                        isValid = true
                    } else if beam.matchedWordsCount < refWords.count && isNearMatch(currStr, refWords[beam.matchedWordsCount]) {
                        isValid = true
                    } else {
                        isValid = trie.isExactWord(curr)
                    }
                } else {
                    isValid = trie.isExactWord(curr)
                }
                
                if !isValid { continue }
                
                if let lm = languageModel {
                    let words = lastTwoWords(of: beam.text)
                    let currWord = String(words.current)
                    if let prevWord = words.previous {
                        let bigramProb = lm.score(word: currWord, prevWord: String(prevWord))
                        totalProb += alpha * bigramProb + beta
                    } else {
                        let unigramProb = lm.score(word: currWord)
                        totalProb += alpha * unigramProb + beta
                    }
                    if !lm.contains(word: currWord) {
                        totalProb -= 2.5
                    }
                }
            }
            
            scoredFinalBeams.append((text: beam.text, score: totalProb, matchedCount: beam.matchedWordsCount))
            
            if hasReference {
                if beam.matchedWordsCount > maxMatchedWords {
                    maxMatchedWords = beam.matchedWordsCount
                    bestScore = totalProb
                    bestText = beam.text
                } else if beam.matchedWordsCount == maxMatchedWords && totalProb > bestScore {
                    bestScore = totalProb
                    bestText = beam.text
                }
            } else {
                if totalProb > bestScore {
                    bestScore = totalProb
                    bestText = beam.text
                }
            }
        }
        
        if bestText.isEmpty {
            var fallbackScore: Float = -Float.infinity
            var fallbackText = ""
            for (beam, probs) in beams {
                let prob = logAdd(probs.0, probs.1)
                if prob > fallbackScore && !beam.text.isEmpty {
                    fallbackScore = prob
                    fallbackText = beam.text
                }
            }
            bestText = fallbackText.isEmpty ? literalText : fallbackText
        }
        
        let finalSnapped = bestText.trimmingCharacters(in: .whitespaces)
        
        // Extract top-K beam hypotheses (up to 5 unique strings) for downstream consensus / diversity
        var topBeams: [String] = []
        var seenBeams = Set<String>()
        if !finalSnapped.isEmpty {
            topBeams.append(finalSnapped)
            seenBeams.insert(finalSnapped.lowercased())
        }
        let sortedCandidates = scoredFinalBeams.sorted {
            if hasReference && $0.matchedCount != $1.matchedCount {
                return $0.matchedCount > $1.matchedCount
            }
            return $0.score > $1.score
        }
        for cand in sortedCandidates {
            let trimmed = cand.text.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if !trimmed.isEmpty && !seenBeams.contains(lower) {
                seenBeams.insert(lower)
                topBeams.append(trimmed)
                if topBeams.count >= 5 { break }
            }
        }
        if topBeams.isEmpty && !literalText.isEmpty {
            topBeams.append(literalText)
        }
        
        return DecodeResult(snapped: finalSnapped, literal: literalText, topBeams: topBeams)
    }
}
