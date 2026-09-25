import Foundation

class CTCSegmentation {
    
    static func align(transcript: String, logProbs: [[Float]], vocab: [String], blankIndex: Int, timeOffset: TimeInterval = 0.0) -> [WordTimestamp] {
        if transcript.isEmpty || logProbs.isEmpty { return [] }
        
        let pipeIdx = vocab.firstIndex(of: "|") ?? blankIndex
        var E_indices: [Int] = []
        for char in transcript {
            if char.isWhitespace {
                E_indices.append(pipeIdx)
            } else {
                let s = String(char).uppercased()
                if let idx = vocab.firstIndex(of: s) {
                    E_indices.append(idx)
                } else {
                    E_indices.append(blankIndex)
                }
            }
        }
        
        let M = E_indices.count
        let L = 2 * M + 1
        var E = [Int](repeating: blankIndex, count: L)
        for k in 0..<M {
            E[2 * k + 1] = E_indices[k]
        }
        
        let totalFrames = logProbs.count
        var alpha = [[Float]](repeating: [Float](repeating: -Float.infinity, count: L), count: totalFrames)
        var backpointer = [[Int]](repeating: [Int](repeating: 0, count: L), count: totalFrames)
        
        alpha[0][0] = logProbs[0][E[0]]
        alpha[0][1] = logProbs[0][E[1]]
        
        for t in 1..<totalFrames {
            for s in 0..<L {
                let logP = logProbs[t][E[s]]
                
                var maxPrev = -Float.infinity
                var bestPrevS = s
                
                if alpha[t-1][s] > maxPrev {
                    maxPrev = alpha[t-1][s]
                    bestPrevS = s
                }
                if s > 0 && alpha[t-1][s-1] > maxPrev {
                    maxPrev = alpha[t-1][s-1]
                    bestPrevS = s - 1
                }
                if s > 1 && E[s] != blankIndex && E[s] != E[s-2] && alpha[t-1][s-2] > maxPrev {
                    maxPrev = alpha[t-1][s-2]
                    bestPrevS = s - 2
                }
                
                if maxPrev != -Float.infinity {
                    alpha[t][s] = maxPrev + logP
                    backpointer[t][s] = bestPrevS
                }
            }
        }
        
        var bestFinalS = L - 1
        if alpha[totalFrames-1][L-2] > alpha[totalFrames-1][L-1] {
            bestFinalS = L - 2
        }
        
        var path = [Int]()
        var currentS = bestFinalS
        for t in (0..<totalFrames).reversed() {
            path.append(currentS)
            currentS = backpointer[t][currentS]
        }
        path.reverse()
        
        // Find word boundaries in the transcript
        var words = [String]()
        var wordRanges = [Range<Int>]()
        var currentWord = ""
        var startIdx = -1
        
        let chars = Array(transcript)
        for i in 0..<chars.count {
            if chars[i] == " " {
                if !currentWord.isEmpty {
                    words.append(currentWord)
                    wordRanges.append(startIdx..<i)
                    currentWord = ""
                }
            } else {
                if currentWord.isEmpty {
                    startIdx = i
                }
                currentWord.append(chars[i])
            }
        }
        if !currentWord.isEmpty {
            words.append(currentWord)
            wordRanges.append(startIdx..<chars.count)
        }
        
        var wordStartFrames = [Int](repeating: -1, count: words.count)
        var wordEndFrames = [Int](repeating: -1, count: words.count)
        
        for t in 0..<totalFrames {
            let s = path[t]
            if s % 2 != 0 {
                let charIdx = (s - 1) / 2
                // Find which word this character belongs to
                for w in 0..<words.count {
                    if wordRanges[w].contains(charIdx) {
                        if wordStartFrames[w] == -1 {
                            wordStartFrames[w] = t
                        }
                        wordEndFrames[w] = t
                        break
                    }
                }
            }
        }
        
        let frameDuration = 0.02
        var timestamps = [WordTimestamp]()
        for w in 0..<words.count {
            if wordStartFrames[w] != -1 && wordEndFrames[w] != -1 {
                // Compute alignment score over the core character frames
                var logProbSum: Float = 0
                var frameCount = 0
                for t in wordStartFrames[w]...wordEndFrames[w] {
                    let s = path[t]
                    logProbSum += logProbs[t][E[s]]
                    frameCount += 1
                }
                let rawMean = frameCount > 0 ? logProbSum / Float(frameCount) : -10.0
                let normalizedScore = min(1.0, max(0.0, (rawMean + 5.0) / 5.0))
                
                // Expand boundaries to include onset and coda acoustics (up to half the gap to neighbouring words, capped at 8 frames = 160ms)
                let leadGap: Int
                if w > 0 && wordEndFrames[w - 1] != -1 {
                    leadGap = max(0, wordStartFrames[w] - wordEndFrames[w - 1] - 1)
                } else {
                    leadGap = wordStartFrames[w]
                }
                let leadPad = min(8, leadGap / 2)
                let actualStartFrame = max(0, wordStartFrames[w] - leadPad)
                
                let trailGap: Int
                if w < words.count - 1 && wordStartFrames[w + 1] != -1 {
                    trailGap = max(0, wordStartFrames[w + 1] - wordEndFrames[w] - 1)
                } else {
                    trailGap = max(0, totalFrames - 1 - wordEndFrames[w])
                }
                let trailPad = min(8, trailGap / 2)
                let actualEndFrame = min(totalFrames - 1, wordEndFrames[w] + trailPad)
                
                let startT = (Double(actualStartFrame) * frameDuration) + timeOffset
                let endT = (Double(actualEndFrame + 1) * frameDuration) + timeOffset
                
                timestamps.append(WordTimestamp(
                    word: words[w],
                    startTime: startT,
                    duration: max(0.02, endT - startT),
                    alignmentScore: normalizedScore
                ))
            }
        }
        
        return timestamps
    }
}
