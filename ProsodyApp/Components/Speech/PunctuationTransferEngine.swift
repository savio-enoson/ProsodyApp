import Foundation

/// Engine that transfers punctuation, capitalization, and apostrophes from a secondary
/// punctuated stream (e.g. Apple SFSpeechRecognizer) onto the Wav2Vec2 Acoustic Mirror output,
/// while strictly preserving learner phonetic words 1:1 (immutable phonetic tokens).
public final class PunctuationTransferEngine {
    
    public static let shared = PunctuationTransferEngine()
    
    private let interrogativeStarters: Set<String> = [
        "who", "what", "when", "where", "why", "which", "how",
        "is", "are", "was", "were", "do", "does", "did",
        "can", "could", "will", "would", "should", "shall",
        "have", "has", "had", "am", "may", "might"
    ]
    
    public init() {}
    
    /// Clean a token to alphanumeric lowercase for robust alignment
    private func cleanToken(_ token: String) -> String {
        return token.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    
    /// Extract leading punctuation, core word, and trailing punctuation from a token
    private func decomposeToken(_ token: String) -> (leading: String, core: String, trailing: String) {
        var raw = token
        var leading = ""
        while let first = raw.first, !first.isLetter && !first.isNumber && first != "'" {
            leading.append(first)
            raw.removeFirst()
        }
        var trailing = ""
        while let last = raw.last, !last.isLetter && !last.isNumber && last != "'" {
            trailing = String(last) + trailing
            raw.removeLast()
        }
        return (leading, raw, trailing)
    }
    
    /// Transfer casing and punctuation from sfSpeechText onto acousticText
    public func transferPunctuation(acousticText: String, sfSpeechText: String?) -> String {
        let trimmedAcoustic = acousticText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAcoustic.isEmpty else { return "" }
        
        let acousticWords = trimmedAcoustic.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        guard !acousticWords.isEmpty else { return "" }
        
        // If no SFSpeech text is available, apply deterministic truecasing & punctuation fallback
        guard let sfText = sfSpeechText?.trimmingCharacters(in: .whitespacesAndNewlines), !sfText.isEmpty else {
            return applyRuleBasedFormatting(acousticWords: acousticWords)
        }
        
        let sfTokens = sfText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        if sfTokens.isEmpty {
            return applyRuleBasedFormatting(acousticWords: acousticWords)
        }
        
        let acClean = acousticWords.map { cleanToken($0) }
        let sfClean = sfTokens.map { cleanToken($0) }
        
        let n = acClean.count
        let m = sfClean.count
        
        // Dynamic programming sequence alignment (Levenshtein on word tokens)
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }
        
        for i in 1...n {
            for j in 1...m {
                let match = (acClean[i - 1] == sfClean[j - 1] ||
                             acClean[i - 1].contains(sfClean[j - 1]) ||
                             sfClean[j - 1].contains(acClean[i - 1]))
                let cost = match ? 0 : 1
                dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost)
            }
        }
        
        // Backtrack to find optimal alignment pairs
        var i = n
        var j = m
        var pairs: [(acIdx: Int, sfIdx: Int?)] = []
        
        while i > 0 || j > 0 {
            if i > 0 && j > 0 {
                let match = (acClean[i - 1] == sfClean[j - 1] ||
                             acClean[i - 1].contains(sfClean[j - 1]) ||
                             sfClean[j - 1].contains(acClean[i - 1]))
                let cost = match ? 0 : 1
                if dp[i][j] == dp[i - 1][j - 1] + cost {
                    pairs.append((i - 1, j - 1))
                    i -= 1
                    j -= 1
                    continue
                }
            }
            if i > 0 && dp[i][j] == dp[i - 1][j] + 1 {
                pairs.append((i - 1, nil))
                i -= 1
            } else {
                j -= 1
            }
        }
        pairs.reverse()
        
        var formattedWords: [String] = []
        
        for (idx, pair) in pairs.enumerated() {
            let acWord = acousticWords[pair.acIdx]
            
            if let sfIdx = pair.sfIdx {
                let sfRaw = sfTokens[sfIdx]
                let (leadPunct, sfCore, trailPunct) = decomposeToken(sfRaw)
                
                var transferredWord = acWord
                
                // 1. Transfer casing
                if sfCore.count > 1 && sfCore == sfCore.uppercased() {
                    transferredWord = acWord.uppercased()
                } else if let firstChar = sfCore.first, firstChar.isUppercase {
                    transferredWord = acWord.prefix(1).uppercased() + acWord.dropFirst()
                } else if acWord == "i" {
                    transferredWord = "I"
                } else if idx == 0 {
                    transferredWord = acWord.prefix(1).uppercased() + acWord.dropFirst()
                }
                
                // 2. Transfer apostrophe if acoustic dropped it (e.g. "im" -> "I'm", "promoters" -> "promoter's")
                if sfCore.contains("'") && !transferredWord.contains("'") {
                    if cleanToken(sfCore) == cleanToken(transferredWord) {
                        if let firstChar = sfCore.first, firstChar.isUppercase {
                            transferredWord = sfCore.prefix(1).uppercased() + sfCore.dropFirst().lowercased()
                        } else {
                            transferredWord = sfCore.lowercased()
                        }
                    }
                }
                
                formattedWords.append(leadPunct + transferredWord + trailPunct)
            } else {
                // No alignment: retain acoustic word and apply rule-based casing
                var fallbackWord = acWord
                if idx == 0 {
                    fallbackWord = acWord.prefix(1).uppercased() + acWord.dropFirst()
                } else if acWord == "i" {
                    fallbackWord = "I"
                }
                formattedWords.append(fallbackWord)
            }
        }
        
        // Ensure final word has terminal punctuation
        if let lastWord = formattedWords.last {
            let (_, _, trail) = decomposeToken(lastWord)
            if trail.isEmpty {
                let firstWordClean = cleanToken(acousticWords[0])
                let terminator = interrogativeStarters.contains(firstWordClean) ? "?" : "."
                formattedWords[formattedWords.count - 1] = lastWord + terminator
            }
        }
        
        let result = formattedWords.joined(separator: " ")
        return result
    }
    
    /// Rule-based deterministic truecasing and punctuation when no SFSpeech text exists
    public func applyRuleBasedFormatting(acousticWords: [String]) -> String {
        guard !acousticWords.isEmpty else { return "" }
        
        var formatted = acousticWords.enumerated().map { (idx, word) -> String in
            var w = word
            if idx == 0 {
                w = w.prefix(1).uppercased() + w.dropFirst()
            } else if w == "i" {
                w = "I"
            } else if w == "im" || w == "i'm" {
                w = "I'm"
            } else if w == "ill" || w == "i'll" {
                w = "I'll"
            }
            return w
        }
        
        let firstWordClean = cleanToken(acousticWords[0])
        let terminator = interrogativeStarters.contains(firstWordClean) ? "?" : "."
        if let last = formatted.last, !last.hasSuffix(".") && !last.hasSuffix("?") && !last.hasSuffix("!") {
            formatted[formatted.count - 1] = last + terminator
        }
        
        return formatted.joined(separator: " ")
    }
    
    /// Asserts that the formatting pass did not alter, drop, or substitute any phonetic words
    public func assertWordFidelity(raw: String, formatted: String) -> Bool {
        let rawClean = raw.components(separatedBy: .whitespacesAndNewlines)
            .map { cleanToken($0) }
            .filter { !$0.isEmpty }
        let formattedClean = formatted.components(separatedBy: .whitespacesAndNewlines)
            .map { cleanToken($0) }
            .filter { !$0.isEmpty }
        return rawClean == formattedClean
    }
}
