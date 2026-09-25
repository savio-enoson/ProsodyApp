import Foundation

class TrieNode {
    var children: [Character: TrieNode] = [:]
    var isWord: Bool = false
}

class LexiconTrie {
    private let root = TrieNode()
    
    private static let allowedSingleLetters: Set<String> = ["a", "i"]
    private static let allowedTwoLetterWords: Set<String> = [
        "am", "an", "as", "at", "be", "by", "do", "go", "he", "hi",
        "if", "in", "is", "it", "me", "my", "no", "of", "oh", "ok",
        "on", "or", "so", "to", "up", "us", "we", "ah", "eh", "ha",
        "ma", "pa", "um", "uh"
    ]
    
    init(words: [String]) {
        for word in words {
            let lower = word.lowercased()
            if !lower.isEmpty {
                insert(lower)
            }
        }
    }
    
    private func insert(_ word: String) {
        var current = root
        for char in word {
            if current.children[char] == nil {
                current.children[char] = TrieNode()
            }
            current = current.children[char]!
        }
        
        // Enforce spoken English lexical constraints:
        // Only 'a' and 'i' can terminate as single-letter words.
        // Two-letter words are restricted to standard conversational vocabulary.
        if word.count == 1 {
            current.isWord = Self.allowedSingleLetters.contains(word)
        } else if word.count == 2 {
            current.isWord = Self.allowedTwoLetterWords.contains(word)
        } else {
            current.isWord = true
        }
    }
    
    func isValidPrefix(_ prefix: Substring) -> Bool {
        if prefix.isEmpty { return true }
        var current = root
        for char in prefix {
            guard let next = current.children[char] else { return false }
            current = next
        }
        return true
    }
    
    func isValidPrefix(_ prefix: String) -> Bool {
        return isValidPrefix(prefix[...])
    }
    
    func isExactWord(_ word: Substring) -> Bool {
        if word.isEmpty { return true }
        var current = root
        for char in word {
            guard let next = current.children[char] else { return false }
            current = next
        }
        return current.isWord
    }
    
    func isExactWord(_ word: String) -> Bool {
        return isExactWord(word[...])
    }
}
