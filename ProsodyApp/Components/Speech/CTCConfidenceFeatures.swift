//
//  CTCConfidenceFeatures.swift
//  ProsodyApp
//
//  Created for Prosody STT Confidence & Discrepancy Detection.
//

import Foundation

/// Stateless utility extracting frame-level entropy and blank stability metrics
/// from the Wav2Vec2 CTC log-probability matrix and CTCSegmentation word boundaries.
enum CTCConfidenceFeatures {

    /// Extracted distributional uncertainty signals for a single word segment.
    struct WordConfidenceFeatures: Sendable, Equatable {
        /// Mean Shannon entropy \(-\sum p_i \ln p_i\) across frames aligned to the word span.
        /// Values range in \([0, \ln(V)]\) where \(V=32\) (max \(\approx 3.4657\)).
        let frameEntropy: Float

        /// Mean probability assigned to the CTC blank token across aligned frames.
        let meanBlankProb: Float

        /// Longest contiguous sequence of non-blank argmax frames within the word span.
        let maxNonBlankRun: Int

        /// Rate of transitions between blank and non-blank argmax frames across the span.
        let blankOscillationRate: Float

        /// Fraction of top-K beam hypotheses that contain this word (diversity / consensus).
        let beamConsensus: Float

        init(
            frameEntropy: Float = 0.0,
            meanBlankProb: Float = 0.0,
            maxNonBlankRun: Int = 0,
            blankOscillationRate: Float = 0.0,
            beamConsensus: Float = 1.0
        ) {
            self.frameEntropy = frameEntropy
            self.meanBlankProb = meanBlankProb
            self.maxNonBlankRun = maxNonBlankRun
            self.blankOscillationRate = blankOscillationRate
            self.beamConsensus = beamConsensus
        }
    }

    /// Computes features for a single word timestamp segment given the full log-probability matrix.
    static func compute(
        for segment: WordTimestamp,
        in logProbs: [[Float]],
        blankIndex: Int = 0,
        frameDuration: Double = 0.02,
        timeOffset: Double = 0.0
    ) -> WordConfidenceFeatures? {
        let totalFrames = logProbs.count
        guard totalFrames > 0 else { return nil }

        let startT = max(0.0, segment.startTime - timeOffset)
        let endT = max(startT, segment.endTime - timeOffset)

        let startFrame = max(0, min(totalFrames - 1, Int(round(startT / frameDuration))))
        let endFrame = max(startFrame, min(totalFrames - 1, Int(round(endT / frameDuration))))

        let frameCount = endFrame - startFrame + 1
        guard frameCount > 0 else { return nil }

        var totalEntropy: Float = 0.0
        var totalBlankProb: Float = 0.0
        var currentNonBlankRun = 0
        var maxNonBlankRun = 0
        var transitions = 0
        var prevIsBlank: Bool? = nil

        for t in startFrame...endFrame {
            let frameLogProbs = logProbs[t]
            let vocabSize = frameLogProbs.count

            var frameEntropy: Float = 0.0
            var argmaxIdx = 0
            var maxLogP: Float = -Float.infinity

            for i in 0..<vocabSize {
                let logP = frameLogProbs[i]
                if logP > maxLogP {
                    maxLogP = logP
                    argmaxIdx = i
                }
                // logP is ln(p_i) where p_i = exp(logP)
                // -p_i * ln(p_i) = -exp(logP) * logP
                if logP > -30.0 {
                    let p = exp(logP)
                    frameEntropy -= p * logP
                }
            }

            totalEntropy += max(0.0, frameEntropy)

            let blankLogP = blankIndex < vocabSize ? frameLogProbs[blankIndex] : -30.0
            let blankProb = exp(max(-30.0, blankLogP))
            totalBlankProb += blankProb

            let isBlank = (argmaxIdx == blankIndex)
            if let prev = prevIsBlank, prev != isBlank {
                transitions += 1
            }
            prevIsBlank = isBlank

            if !isBlank {
                currentNonBlankRun += 1
                if currentNonBlankRun > maxNonBlankRun {
                    maxNonBlankRun = currentNonBlankRun
                }
            } else {
                currentNonBlankRun = 0
            }
        }

        let meanEntropy = totalEntropy / Float(frameCount)
        let meanBlank = totalBlankProb / Float(frameCount)
        let oscillationRate = frameCount > 1 ? Float(transitions) / Float(frameCount - 1) : 0.0

        return WordConfidenceFeatures(
            frameEntropy: meanEntropy,
            meanBlankProb: meanBlank,
            maxNonBlankRun: maxNonBlankRun,
            blankOscillationRate: oscillationRate,
            beamConsensus: 1.0
        )
    }

    /// Computes per-word beam consensus: fraction of top-K beams containing this word within a position window.
    static func computeBeamConsensus(
        topBeams: [String],
        words: [String]
    ) -> [Float] {
        guard !words.isEmpty else { return [] }
        guard !topBeams.isEmpty else { return Array(repeating: 1.0, count: words.count) }
        
        let cleanedWords = words.map { DiscrepancyEngine.cleanWord($0) }
        let beamWordsList: [[String]] = topBeams.map { beam in
            beam.components(separatedBy: .whitespacesAndNewlines)
                .map { DiscrepancyEngine.cleanWord($0) }
                .filter { !$0.isEmpty }
        }
        
        var consensus = [Float]()
        consensus.reserveCapacity(words.count)
        
        let numBeams = Float(topBeams.count)
        
        for (idx, targetWord) in cleanedWords.enumerated() {
            if targetWord.isEmpty {
                consensus.append(1.0)
                continue
            }
            
            var matches = 0
            for bWords in beamWordsList {
                if bWords.isEmpty { continue }
                
                // Position-tolerant window: |j - idx| <= 2
                let minJ = max(0, idx - 2)
                let maxJ = min(bWords.count - 1, idx + 2)
                
                var found = false
                if minJ <= maxJ {
                    for j in minJ...maxJ {
                        let cand = bWords[j]
                        if DiscrepancyEngine.matchesWord(target: targetWord, candidate: cand) ||
                           DiscrepancyEngine.matchesWordMorphologically(target: targetWord, candidate: cand) {
                            found = true
                            break
                        }
                    }
                }
                
                // Secondary check across entire beam
                if !found && bWords.contains(where: { DiscrepancyEngine.matchesWord(target: targetWord, candidate: $0) }) {
                    found = true
                }
                
                if found {
                    matches += 1
                }
            }
            
            consensus.append(Float(matches) / numBeams)
        }
        
        return consensus
    }

    /// Computes per-word CTC confidence features for an array of word timestamps.
    /// Returns a dictionary mapping the index of each timestamp in `wordTimestamps` to its features.
    static func computePerWord(
        logProbs: [[Float]],
        wordTimestamps: [WordTimestamp],
        topBeams: [String]? = nil,
        blankIndex: Int = 0,
        frameDuration: Double = 0.02,
        timeOffset: Double = 0.0
    ) -> [Int: WordConfidenceFeatures] {
        var results = [Int: WordConfidenceFeatures]()
        results.reserveCapacity(wordTimestamps.count)

        let words = wordTimestamps.map { $0.word }
        let beamConsensusScores: [Float]? = topBeams.map { computeBeamConsensus(topBeams: $0, words: words) }

        for (idx, segment) in wordTimestamps.enumerated() {
            if let feats = compute(
                for: segment,
                in: logProbs,
                blankIndex: blankIndex,
                frameDuration: frameDuration,
                timeOffset: timeOffset
            ) {
                let bConsensus = (beamConsensusScores != nil && idx < beamConsensusScores!.count) ? beamConsensusScores![idx] : 1.0
                results[idx] = WordConfidenceFeatures(
                    frameEntropy: feats.frameEntropy,
                    meanBlankProb: feats.meanBlankProb,
                    maxNonBlankRun: feats.maxNonBlankRun,
                    blankOscillationRate: feats.blankOscillationRate,
                    beamConsensus: bConsensus
                )
            }
        }

        return results
    }
}
