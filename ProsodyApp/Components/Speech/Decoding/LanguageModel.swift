import Foundation

public struct BigramEntry {
    public let key: UInt32
    public let prob: Float
    
    public init(key: UInt32, prob: Float) {
        self.key = key
        self.prob = prob
    }
}

public final class LanguageModel {
    private let wordToId: [String: UInt16]
    private let unigramProbs: [Float]
    private let unigramBackoffs: [Float]
    private let bigrams: [BigramEntry]
    
    private static let log10ToLn: Float = 2.302585092994046
    private static let oovPenalty: Float = -12.0 // ln scale penalty for out-of-vocabulary words
    
    public init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard data.count >= 12 else { return nil }
        
        var loadedW2id: [String: UInt16]?
        var loadedUProbs: [Float]?
        var loadedUBackoffs: [Float]?
        var loadedBigrams: [BigramEntry]?
        
        data.withUnsafeBytes { ptr in
            guard let baseAddr = ptr.baseAddress else { return }
            var offset = 0
            
            let magic = data.subdata(in: 0..<4)
            if String(data: magic, encoding: .ascii) != "TALK" { return }
            offset += 4
            
            let numU = Int(ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            offset += 4
            let numB = Int(ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            offset += 4
            
            var w2id = [String: UInt16](minimumCapacity: numU)
            var uProbs = [Float]()
            uProbs.reserveCapacity(numU)
            var uBackoffs = [Float]()
            uBackoffs.reserveCapacity(numU)
            
            for i in 0..<numU {
                let len = Int(ptr.loadUnaligned(fromByteOffset: offset, as: UInt8.self))
                offset += 1
                let strBytes = UnsafeRawBufferPointer(start: baseAddr.advanced(by: offset), count: len)
                if let word = String(bytes: strBytes, encoding: .utf8) {
                    w2id[word] = UInt16(i)
                }
                offset += len
                let p = ptr.loadUnaligned(fromByteOffset: offset, as: Float.self) * LanguageModel.log10ToLn
                offset += 4
                let b = ptr.loadUnaligned(fromByteOffset: offset, as: Float.self) * LanguageModel.log10ToLn
                offset += 4
                uProbs.append(p)
                uBackoffs.append(b)
            }
            
            let bigramByteCount = numB * 8
            guard data.count >= offset + bigramByteCount else { return }
            
            var entries = [BigramEntry](repeating: BigramEntry(key: 0, prob: 0), count: numB)
            entries.withUnsafeMutableBytes { destPtr in
                destPtr.copyMemory(from: UnsafeRawBufferPointer(start: baseAddr.advanced(by: offset), count: bigramByteCount))
            }
            
            // Convert bigram log10 probabilities to natural log in-place
            for i in 0..<numB {
                let raw = entries[i]
                entries[i] = BigramEntry(key: raw.key, prob: raw.prob * LanguageModel.log10ToLn)
            }
            
            loadedW2id = w2id
            loadedUProbs = uProbs
            loadedUBackoffs = uBackoffs
            loadedBigrams = entries
        }
        
        guard let w2id = loadedW2id,
              let uProbs = loadedUProbs,
              let uBackoffs = loadedUBackoffs,
              let bigrams = loadedBigrams else {
            return nil
        }
        
        self.wordToId = w2id
        self.unigramProbs = uProbs
        self.unigramBackoffs = uBackoffs
        self.bigrams = bigrams
    }
    
    public var vocabulary: [String] {
        return Array(wordToId.keys)
    }
    
    public func contains(word: String) -> Bool {
        return wordToId[word.lowercased()] != nil
    }
    
    /// Returns natural log probability ln P(word | prevWord)
    public func score(word: String, prevWord: String? = nil) -> Float {
        let cleanWord = word.lowercased()
        guard let wId = wordToId[cleanWord] else {
            return LanguageModel.oovPenalty
        }
        
        if let prev = prevWord {
            let cleanPrev = prev.lowercased()
            if let pId = wordToId[cleanPrev] {
                let targetKey = (UInt32(pId) << 16) | UInt32(wId)
                var low = 0
                var high = bigrams.count - 1
                while low <= high {
                    let mid = (low + high) &>> 1
                    let entry = bigrams[mid]
                    if entry.key == targetKey {
                        return entry.prob
                    } else if entry.key < targetKey {
                        low = mid + 1
                    } else {
                        high = mid - 1
                    }
                }
                // Backoff to unigram with backoff weight
                return unigramBackoffs[Int(pId)] + unigramProbs[Int(wId)]
            }
        }
        
        return unigramProbs[Int(wId)]
    }
}
