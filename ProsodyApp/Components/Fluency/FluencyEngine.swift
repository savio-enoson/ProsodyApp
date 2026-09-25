import Foundation
import Accelerate

enum FluencyContext {
    case readingAloud
    case conversation
}

struct FluencyThresholds {
    let speechRateGood: Float
    let speechRateOkay: Float
    let speechRateTargetMax: Float
    
    let ptrGood: Float
    let ptrOkay: Float
    let ptrTargetMax: Float
    
    let mlrGood: Float
    let mlrOkay: Float
    let mlrTargetMax: Float
    
    let pauseFreqMax: Float
    
    static let readingAloud = FluencyThresholds(
        speechRateGood: 1.4,
        speechRateOkay: 0.8,
        speechRateTargetMax: 1.8,
        ptrGood: 0.55,
        ptrOkay: 0.35,
        ptrTargetMax: 0.60,
        mlrGood: 4.0,
        mlrOkay: 2.0,
        mlrTargetMax: 5.0,
        pauseFreqMax: 15.0
    )
    
    static let conversation = FluencyThresholds(
        speechRateGood: 2.0,
        speechRateOkay: 1.0,
        speechRateTargetMax: 2.5,
        ptrGood: 0.70,
        ptrOkay: 0.50,
        ptrTargetMax: 0.70,
        mlrGood: 5.0,
        mlrOkay: 3.0,
        mlrTargetMax: 6.0,
        pauseFreqMax: 20.0
    )
}

struct FluencyEngine {

    /// Minimum gap (seconds) to classify as a pause. 
    /// Research standard: 250ms filters out natural plosive closures.
    static let pauseThreshold: TimeInterval = 0.250
    
    /// Minimum words required for meaningful fluency metrics.
    static let minimumWords: Int = 3

    /// 22-dimensional feature representation for the learned FluencyScorer GBDT.
    static let featureNames: [String] = [
        "speech_rate",
        "articulation_rate",
        "phonation_time_ratio",
        "mean_length_of_run",
        "pause_count",
        "pause_freq_per_min",
        "mean_pause_duration",
        "max_pause_duration",
        "pause_duration_cv",
        "word_duration_cv",
        "long_pause_ratio",
        "max_length_of_run",
        "run_length_cv",
        "speech_rate_cv",
        "total_duration",
        "word_count",
        "mean_alignment_score",
        "pitch_zcr",
        "word_npvi",
        "energy_cv",
        "pitch_semitone_stddev",
        "voicing_ratio"
    ]

    /// Helper to compute coefficient of variation (stddev / mean). Returns 0.0 if count <= 1 or mean ~ 0.
    static func computeCV(_ values: [Float]) -> Float {
        guard values.count > 1 else { return 0.0 }
        let mean = values.reduce(0, +) / Float(values.count)
        guard mean > 1e-6 else { return 0.0 }
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Float(values.count)
        let stddev = sqrt(max(0, variance))
        return stddev / mean
    }

    /// Computes Normalized Pairwise Variability Index (nPVI) across word durations.
    /// Captures the degree of duration contrast between successive words (stress-timing).
    /// Typical values: < 40 indicates syllable-timed / monotone rhythm; > 50 indicates stress-timed rhythm.
    static func computeWordNPVI(_ segments: [WordTimestamp]) -> Float {
        guard segments.count >= 2 else { return 0.0 }
        var sumDiff: Float = 0.0
        let m = segments.count
        for k in 0..<(m - 1) {
            let d1 = Float(segments[k].duration)
            let d2 = Float(segments[k + 1].duration)
            let avg = (d1 + d2) / 2.0
            if avg > 1e-5 {
                sumDiff += abs(d1 - d2) / avg
            }
        }
        return (100.0 / Float(m - 1)) * sumDiff
    }

    /// Computes coefficient of variation (stddev / mean) of word-level RMS energies using Accelerate vDSP.
    /// Distinguishes dynamic stress/emphasis contrast from robotic flat volume.
    static func computeWordEnergyCV(audio: [Float], sampleRate: Float = 16000.0, segments: [WordTimestamp]) -> Float {
        guard !audio.isEmpty, !segments.isEmpty else { return 0.35 }
        var wordRMS: [Float] = []
        wordRMS.reserveCapacity(segments.count)

        audio.withUnsafeBufferPointer { ptr in
            let basePtr = ptr.baseAddress!
            for seg in segments {
                let startSample = max(0, min(audio.count - 1, Int(seg.startTime * Double(sampleRate))))
                let endSample = max(startSample + 1, min(audio.count, Int(seg.endTime * Double(sampleRate))))
                let length = endSample - startSample
                guard length > 16 else { continue }

                var rms: Float = 0.0
                vDSP_rmsqv(basePtr.advanced(by: startSample), 1, &rms, vDSP_Length(length))
                if rms > 1e-6 {
                    wordRMS.append(rms)
                }
            }
        }

        return wordRMS.count > 1 ? computeCV(wordRMS) : 0.35
    }

    /// Extracts pitch (F0) dynamics across 25ms windowed frames (10ms hop) via time-domain autocorrelation using Accelerate.
    /// Returns semitone standard deviation (pitch modulation) and periodic voicing ratio.
    static func computePitchContour(audio: [Float], sampleRate: Float = 16000.0) -> (semitoneStdDev: Float, voicingRatio: Float) {
        guard audio.count >= 400 else { return (2.5, 0.65) }

        let frameLength = Int(0.025 * sampleRate) // 400 samples (25ms)
        let hopLength = Int(0.010 * sampleRate)   // 160 samples (10ms)
        let minLag = Int(sampleRate / 450.0)       // ~35 samples (450 Hz)
        let maxLag = Int(sampleRate / 65.0)        // ~246 samples (65 Hz)
        let searchLimit = min(maxLag, frameLength / 2)

        var voicedSemitones: [Float] = []
        var totalFrames = 0
        var voicedFrames = 0

        audio.withUnsafeBufferPointer { ptr in
            let basePtr = ptr.baseAddress!
            var frameStart = 0
            while frameStart + frameLength <= audio.count {
                totalFrames += 1
                let framePtr = basePtr.advanced(by: frameStart)

                var r0: Float = 0.0
                vDSP_svesq(framePtr, 1, &r0, vDSP_Length(frameLength))

                if r0 > 1e-4 {
                    var bestR: Float = 0.0
                    var bestLag = 0

                    for lag in minLag...searchLimit {
                        var rLag: Float = 0.0
                        vDSP_dotpr(framePtr, 1, framePtr.advanced(by: lag), 1, &rLag, vDSP_Length(frameLength - lag))
                        if rLag > bestR {
                            bestR = rLag
                            bestLag = lag
                        }
                    }

                    let normCorr = bestR / r0
                    if normCorr >= 0.30 && bestLag > 0 {
                        voicedFrames += 1
                        let f0 = sampleRate / Float(bestLag)
                        if f0 >= 65.0 && f0 <= 450.0 {
                            let semitones = 12.0 * log2(f0 / 100.0)
                            voicedSemitones.append(semitones)
                        }
                    }
                }

                frameStart += hopLength
            }
        }

        let voicingRatio = totalFrames > 0 ? Float(voicedFrames) / Float(totalFrames) : 0.65
        let semitoneStdDev: Float
        if voicedSemitones.count > 1 {
            let mean = voicedSemitones.reduce(0, +) / Float(voicedSemitones.count)
            let variance = voicedSemitones.reduce(0) { $0 + pow($1 - mean, 2) } / Float(voicedSemitones.count)
            semitoneStdDev = sqrt(max(0, variance))
        } else {
            semitoneStdDev = 2.5
        }

        return (semitoneStdDev, voicingRatio)
    }

    /// Assembles a 22-dimensional feature vector for training or inference.
    static func assembleFeatureVector(
        from result: FluencyResult,
        wordCount: Int,
        pitchZcr: Float = 0.0
    ) -> [Float] {
        [
            result.speechRate,
            result.articulationRate,
            result.phonationTimeRatio,
            result.meanLengthOfRun,
            Float(result.pauseCount),
            result.pauseFrequencyPerMinute,
            result.meanPauseDuration,
            result.maxPauseDuration,
            result.pauseDurationCV,
            result.wordDurationCV,
            result.longPauseRatio,
            Float(result.maxLengthOfRun),
            result.runLengthCV,
            result.speechRateCV,
            result.totalDuration,
            Float(wordCount),
            result.meanAlignmentScore,
            pitchZcr,
            result.wordNPVI,
            result.energyCV,
            result.pitchSemitoneStdDev,
            result.voicingRatio
        ]
    }

    static func evaluate(
        segments: [WordTimestamp],
        context: FluencyContext = .readingAloud,
        isChild: Bool = false,
        pitchZcr: Float = 0.0,
        audioChunk: [Float]? = nil,
        transcript: String? = nil,
        sfSpeechTranscript: String? = nil
    ) -> FluencyResult? {
        guard segments.count >= minimumWords,
              let first = segments.first,
              let last = segments.last else { return nil }
        
        let thresholds: FluencyThresholds = (context == .readingAloud) ? .readingAloud : .conversation
        
        // 1. Total utterance duration (first word onset → last word offset)
        let totalDuration = last.endTime - first.startTime
        guard totalDuration > 0 else { return nil }
        
        // 2. Phonation time (sum of all word durations)
        let phonationTime = segments.reduce(0.0) { $0 + $1.duration }
        let articulationRate = phonationTime > 0 
            ? Float(segments.count) / Float(phonationTime) 
            : 0
            
        // Adaptive pause threshold based on speaker's articulation rate:
        // Clamped between 180ms (natural plosive closure floor) and 350ms (deliberate speech ceiling)
        let typicalGap = articulationRate > 0 ? (1.0 / articulationRate) * 0.3 : 0.1
        let adaptivePauseThreshold: TimeInterval = TimeInterval(max(0.18, min(0.35, typicalGap + 0.15)))
        
        // 3. Detect pauses (gaps between consecutive segments >= adaptivePauseThreshold)
        var pauses: [PauseEvent] = []
        for i in 1..<segments.count {
            let gap = segments[i].startTime - segments[i-1].endTime
            if gap >= adaptivePauseThreshold {
                pauses.append(PauseEvent(
                    startTime: segments[i-1].endTime,
                    duration: gap,
                    wordBefore: segments[i-1].word,
                    wordAfter: segments[i].word
                ))
            }
        }

        let sampleRate: Float = 16000.0

        // 4. Disfluency & Syntactic Pause Position Analysis
        let textForTagger = (transcript != nil && !transcript!.isEmpty) ? transcript! : segments.map(\.word).joined(separator: " ")
        let disfluencyReport = DisfluencyDetector.analyze(
            segments: segments,
            transcript: textForTagger,
            sfSpeechTranscript: sfSpeechTranscript,
            pauses: &pauses,
            audioChunk: audioChunk,
            sampleRate: sampleRate,
            totalDuration: Float(totalDuration)
        )
        
        // 5. Compute basic metrics
        let speechRate = Float(segments.count) / Float(totalDuration)
        let phonationTimeRatio = Float(phonationTime / totalDuration)
        let pauseFrequency = totalDuration > 0 
            ? Float(pauses.count) / Float(totalDuration / 60.0) 
            : 0
        let meanPauseDuration = pauses.isEmpty 
            ? 0 
            : Float(pauses.reduce(0.0) { $0 + $1.duration }) / Float(pauses.count)
        
        // 6. Mean Length of Run & run variability
        let runs = Self.computeRuns(segments: segments, pauseThreshold: adaptivePauseThreshold)
        let mlr = runs.isEmpty ? 0 : Float(runs.reduce(0, +)) / Float(runs.count)
        let maxLengthOfRun = runs.max() ?? 0
        let runLengthCV = Self.computeCV(runs.map { Float($0) })
        
        // 7. Extended pause & duration metrics
        let maxPauseDuration = pauses.map { Float($0.duration) }.max() ?? 0.0
        let pauseDurationCV = Self.computeCV(pauses.map { Float($0.duration) })
        let wordDurationCV = Self.computeCV(segments.map { Float($0.duration) })
        let longPauseCount = pauses.filter { $0.duration >= 0.5 }.count
        let longPauseRatio = pauses.isEmpty ? 0.0 : Float(longPauseCount) / Float(pauses.count)
        
        // Local speech rate CV over sliding 3-word windows
        var windowRates: [Float] = []
        if segments.count >= 3 {
            for i in 0...(segments.count - 3) {
                let span = segments[i + 2].endTime - segments[i].startTime
                if span > 1e-4 {
                    windowRates.append(Float(3.0 / span))
                }
            }
        }
        let speechRateCV = Self.computeCV(windowRates)
        let meanAlignmentScore = segments.map { $0.alignmentScore }.reduce(0, +) / Float(segments.count)
        
        // 8. Prosodic & Rhythmic Features
        let wordNPVI = computeWordNPVI(segments)
        
        let energyCV: Float
        let pitchSemitoneStdDev: Float
        let voicingRatio: Float
        let effectiveZcr: Float

        if let audio = audioChunk, !audio.isEmpty {
            energyCV = computeWordEnergyCV(audio: audio, sampleRate: sampleRate, segments: segments)
            let pitchStats = computePitchContour(audio: audio, sampleRate: sampleRate)
            pitchSemitoneStdDev = pitchStats.semitoneStdDev
            voicingRatio = pitchStats.voicingRatio
            
            if pitchZcr == 0.0 {
                var crossings = 0
                for k in 1..<audio.count {
                    if (audio[k] >= 0 && audio[k - 1] < 0) || (audio[k] < 0 && audio[k - 1] >= 0) {
                        crossings += 1
                    }
                }
                effectiveZcr = Float(crossings) / Float(audio.count)
            } else {
                effectiveZcr = pitchZcr
            }
        } else {
            energyCV = 0.35 // Neutral population prior
            pitchSemitoneStdDev = 2.5
            voicingRatio = 0.65
            effectiveZcr = pitchZcr
        }

        // 9. Generate feedback items
        let feedback = Self.generateFeedback(
            speechRate: speechRate,
            articulationRate: articulationRate,
            ptr: phonationTimeRatio,
            mlr: mlr,
            pauseFrequency: pauseFrequency,
            meanPauseDuration: meanPauseDuration,
            disfluencyReport: disfluencyReport,
            thresholds: thresholds
        )
        
        // 10. Compute overall score (Learned CoreML GBDT with heuristic fallback)
        let overallScore: Int
        if LearnedFluencyEngine.shared.isReady {
            let tempResult = FluencyResult(
                overallScore: 0,
                speechRate: speechRate,
                articulationRate: articulationRate,
                phonationTimeRatio: phonationTimeRatio,
                meanLengthOfRun: mlr,
                pauseCount: pauses.count,
                meanPauseDuration: meanPauseDuration,
                pauseFrequencyPerMinute: pauseFrequency,
                pauses: pauses,
                feedback: feedback,
                maxPauseDuration: maxPauseDuration,
                pauseDurationCV: pauseDurationCV,
                wordDurationCV: wordDurationCV,
                longPauseRatio: longPauseRatio,
                maxLengthOfRun: maxLengthOfRun,
                runLengthCV: runLengthCV,
                speechRateCV: speechRateCV,
                totalDuration: Float(totalDuration),
                meanAlignmentScore: meanAlignmentScore,
                wordNPVI: wordNPVI,
                energyCV: energyCV,
                pitchSemitoneStdDev: pitchSemitoneStdDev,
                voicingRatio: voicingRatio,
                disfluencyReport: disfluencyReport,
                fillerCount: disfluencyReport.fillerCount,
                repetitionCount: disfluencyReport.repetitionCount,
                intraPhrasePauseRatio: disfluencyReport.intraPhrasePauseRatio
            )
            let feats = assembleFeatureVector(from: tempResult, wordCount: segments.count, pitchZcr: effectiveZcr)
            let predRating = LearnedFluencyEngine.shared.predictScore(features: feats)
            overallScore = min(100, max(0, Int(round(predRating * 10.0))))
        } else {
            overallScore = 70
        }
        
        return FluencyResult(
            overallScore: overallScore,
            speechRate: speechRate,
            articulationRate: articulationRate,
            phonationTimeRatio: phonationTimeRatio,
            meanLengthOfRun: mlr,
            pauseCount: pauses.count,
            meanPauseDuration: meanPauseDuration,
            pauseFrequencyPerMinute: pauseFrequency,
            pauses: pauses,
            feedback: feedback,
            maxPauseDuration: maxPauseDuration,
            pauseDurationCV: pauseDurationCV,
            wordDurationCV: wordDurationCV,
            longPauseRatio: longPauseRatio,
            maxLengthOfRun: maxLengthOfRun,
            runLengthCV: runLengthCV,
            speechRateCV: speechRateCV,
            totalDuration: Float(totalDuration),
            meanAlignmentScore: meanAlignmentScore,
            wordNPVI: wordNPVI,
            energyCV: energyCV,
            pitchSemitoneStdDev: pitchSemitoneStdDev,
            voicingRatio: voicingRatio,
            disfluencyReport: disfluencyReport,
            fillerCount: disfluencyReport.fillerCount,
            repetitionCount: disfluencyReport.repetitionCount,
            intraPhrasePauseRatio: disfluencyReport.intraPhrasePauseRatio
        )
    }

    /// Evaluates temporal, prosodic, and disfluency properties across an entire multi-turn practice session.
    /// Bridges inter-turn pause gaps, computes true session speech rate (words / total elapsed time)
    /// alongside burst articulation rate (words / active phonation time), and evaluates rhythm & disfluency session-wide.
    static func evaluateSession(
        utterances: [UtteranceRecord],
        sessionDuration: TimeInterval? = nil,
        context: FluencyContext = .readingAloud,
        isChild: Bool = false
    ) -> FluencyResult? {
        guard !utterances.isEmpty else { return nil }

        // 1. Shift and collect all word timestamps onto a unified chronological timeline
        var allWords: [WordTimestamp] = []
        for u in utterances {
            let needsOffset = (u.wordTimestamps.first?.startTime ?? 0) < u.startTime && u.startTime > 0
            let offset = needsOffset ? u.startTime : 0.0
            for w in u.wordTimestamps {
                allWords.append(WordTimestamp(
                    word: w.word,
                    startTime: w.startTime + offset,
                    duration: w.duration,
                    alignmentScore: w.alignmentScore
                ))
            }
        }
        allWords.sort(by: { $0.startTime < $1.startTime })

        guard allWords.count >= minimumWords,
              let firstWord = allWords.first,
              let lastWord = allWords.last else {
            return utterances.compactMap({ $0.fluencyResult }).first
        }

        let thresholds: FluencyThresholds = (context == .readingAloud) ? .readingAloud : .conversation

        // 2. Compute true total session wall-clock duration & phonation time
        let measuredSpan = lastWord.endTime - firstWord.startTime
        let totalSessionDuration: TimeInterval = max(measuredSpan, sessionDuration ?? measuredSpan)
        guard totalSessionDuration > 0 else { return nil }

        let phonationTime = allWords.reduce(0.0) { $0 + $1.duration }
        let articulationRate = phonationTime > 0
            ? Float(allWords.count) / Float(phonationTime)
            : 0

        // Adaptive pause threshold based on speaker's articulation rate:
        let typicalGap = articulationRate > 0 ? (1.0 / articulationRate) * 0.3 : 0.1
        let adaptivePauseThreshold: TimeInterval = TimeInterval(max(0.18, min(0.35, typicalGap + 0.15)))

        // 3. Collect both intra-turn and inter-turn pauses across the unified timeline
        var pauses: [PauseEvent] = []
        var interTurnCount = 0
        var intraTurnCount = 0

        for i in 1..<allWords.count {
            let gap = allWords[i].startTime - allWords[i-1].endTime
            if gap >= adaptivePauseThreshold {
                let prevWord = allWords[i-1].word.trimmingCharacters(in: .whitespacesAndNewlines)
                let isSentenceBoundary = prevWord.hasSuffix(".") || prevWord.hasSuffix("!") || prevWord.hasSuffix("?") || gap >= 0.8
                let isGrammatical = prevWord.hasSuffix(",") || prevWord.hasSuffix(";") || prevWord.hasSuffix(":") || prevWord.hasSuffix("—")

                let posType: PausePositionType = isSentenceBoundary ? .sentenceBoundary : (isGrammatical ? .grammaticalClause : .intraPhrase)
                if posType == .sentenceBoundary || posType == .grammaticalClause {
                    interTurnCount += 1
                } else {
                    intraTurnCount += 1
                }

                pauses.append(PauseEvent(
                    startTime: allWords[i-1].endTime,
                    duration: gap,
                    wordBefore: allWords[i-1].word,
                    wordAfter: allWords[i].word,
                    positionType: posType
                ))
            }
        }

        // 4. Session-level rates and ratios
        let sessionSpeechRate = Float(allWords.count) / Float(totalSessionDuration)
        let phonationTimeRatio = Float(phonationTime / totalSessionDuration)
        let pauseFrequency = totalSessionDuration > 0
            ? Float(pauses.count) / Float(totalSessionDuration / 60.0)
            : 0
        let meanPauseDuration = pauses.isEmpty
            ? 0
            : Float(pauses.reduce(0.0) { $0 + $1.duration }) / Float(pauses.count)

        // 5. Mean Length of Run across the continuous session
        let runs = Self.computeRuns(segments: allWords, pauseThreshold: adaptivePauseThreshold)
        let mlr = runs.isEmpty ? 0 : Float(runs.reduce(0, +)) / Float(runs.count)
        let maxLengthOfRun = runs.max() ?? 0
        let runLengthCV = Self.computeCV(runs.map { Float($0) })

        // 6. Extended pause & duration metrics
        let maxPauseDuration = pauses.map { Float($0.duration) }.max() ?? 0.0
        let pauseDurationCV = Self.computeCV(pauses.map { Float($0.duration) })
        let wordDurationCV = Self.computeCV(allWords.map { Float($0.duration) })
        let longPauseCount = pauses.filter { $0.duration >= 0.5 }.count
        let longPauseRatio = pauses.isEmpty ? 0.0 : Float(longPauseCount) / Float(pauses.count)

        // 7. Local speech rate CV over sliding 3-word windows
        var windowRates: [Float] = []
        if allWords.count >= 3 {
            for i in 0...(allWords.count - 3) {
                let span = allWords[i + 2].endTime - allWords[i].startTime
                if span > 1e-4 {
                    windowRates.append(Float(3.0 / span))
                }
            }
        }
        let speechRateCV = Self.computeCV(windowRates)
        let meanAlignmentScore = allWords.map { $0.alignmentScore }.reduce(0, +) / Float(allWords.count)

        // 8. Prosodic & Rhythmic Features
        let wordNPVI = computeWordNPVI(allWords)

        let validResults = utterances.compactMap { $0.fluencyResult }
        let count = Float(max(1, validResults.count))
        let energyCV = validResults.isEmpty ? 0.35 : (validResults.map { $0.energyCV }.reduce(0, +) / count)
        let pitchSemitoneStdDev = validResults.isEmpty ? 2.5 : (validResults.map { $0.pitchSemitoneStdDev }.reduce(0, +) / count)
        let voicingRatio = validResults.isEmpty ? 0.65 : (validResults.map { $0.voicingRatio }.reduce(0, +) / count)

        // 9. Disfluency Report across full transcript
        let fullText = utterances.map(\.transcript).filter { !$0.isEmpty }.joined(separator: " ")
        var mutablePauses = pauses
        let disfluencyReport = DisfluencyDetector.analyze(
            segments: allWords,
            transcript: fullText,
            sfSpeechTranscript: nil,
            pauses: &mutablePauses,
            audioChunk: nil,
            sampleRate: 16000.0,
            totalDuration: Float(totalSessionDuration)
        )

        // 10. Generate session-calibrated feedback
        let feedback = Self.generateFeedback(
            speechRate: sessionSpeechRate,
            articulationRate: articulationRate,
            ptr: phonationTimeRatio,
            mlr: mlr,
            pauseFrequency: pauseFrequency,
            meanPauseDuration: meanPauseDuration,
            disfluencyReport: disfluencyReport,
            thresholds: thresholds
        )

        // 11. Score calculation via CoreML GBDT
        var sessionResult = FluencyResult(
            overallScore: 0,
            speechRate: sessionSpeechRate,
            articulationRate: articulationRate,
            phonationTimeRatio: phonationTimeRatio,
            meanLengthOfRun: mlr,
            pauseCount: pauses.count,
            meanPauseDuration: meanPauseDuration,
            pauseFrequencyPerMinute: pauseFrequency,
            pauses: pauses,
            feedback: feedback,
            maxPauseDuration: maxPauseDuration,
            pauseDurationCV: pauseDurationCV,
            wordDurationCV: wordDurationCV,
            longPauseRatio: longPauseRatio,
            maxLengthOfRun: maxLengthOfRun,
            runLengthCV: runLengthCV,
            speechRateCV: speechRateCV,
            totalDuration: Float(totalSessionDuration),
            meanAlignmentScore: meanAlignmentScore,
            wordNPVI: wordNPVI,
            energyCV: energyCV,
            pitchSemitoneStdDev: pitchSemitoneStdDev,
            voicingRatio: voicingRatio,
            disfluencyReport: disfluencyReport,
            fillerCount: disfluencyReport.fillerCount,
            repetitionCount: disfluencyReport.repetitionCount,
            intraPhrasePauseRatio: disfluencyReport.intraPhrasePauseRatio,
            isSessionLevel: true,
            sessionSpeechRate: sessionSpeechRate,
            sessionDuration: Float(totalSessionDuration),
            phonationDuration: Float(phonationTime),
            interTurnPauseCount: interTurnCount,
            intraTurnPauseCount: intraTurnCount
        )

        let overallScore: Int
        if LearnedFluencyEngine.shared.isReady {
            let feats = assembleFeatureVector(from: sessionResult, wordCount: allWords.count, pitchZcr: 0.0)
            let predRating = LearnedFluencyEngine.shared.predictScore(features: feats)
            overallScore = min(100, max(0, Int(round(predRating * 10.0))))
        } else {
            overallScore = 70
        }

        return FluencyResult(
            overallScore: overallScore,
            speechRate: sessionSpeechRate,
            articulationRate: articulationRate,
            phonationTimeRatio: phonationTimeRatio,
            meanLengthOfRun: mlr,
            pauseCount: pauses.count,
            meanPauseDuration: meanPauseDuration,
            pauseFrequencyPerMinute: pauseFrequency,
            pauses: pauses,
            feedback: feedback,
            maxPauseDuration: maxPauseDuration,
            pauseDurationCV: pauseDurationCV,
            wordDurationCV: wordDurationCV,
            longPauseRatio: longPauseRatio,
            maxLengthOfRun: maxLengthOfRun,
            runLengthCV: runLengthCV,
            speechRateCV: speechRateCV,
            totalDuration: Float(totalSessionDuration),
            meanAlignmentScore: meanAlignmentScore,
            wordNPVI: wordNPVI,
            energyCV: energyCV,
            pitchSemitoneStdDev: pitchSemitoneStdDev,
            voicingRatio: voicingRatio,
            disfluencyReport: disfluencyReport,
            fillerCount: disfluencyReport.fillerCount,
            repetitionCount: disfluencyReport.repetitionCount,
            intraPhrasePauseRatio: disfluencyReport.intraPhrasePauseRatio,
            isSessionLevel: true,
            sessionSpeechRate: sessionSpeechRate,
            sessionDuration: Float(totalSessionDuration),
            phonationDuration: Float(phonationTime),
            interTurnPauseCount: interTurnCount,
            intraTurnPauseCount: intraTurnCount
        )
    }

    private static func computeRuns(segments: [WordTimestamp], pauseThreshold: TimeInterval) -> [Int] {
        guard !segments.isEmpty else { return [] }
        var runs: [Int] = []
        var currentRunLength = 1
        for i in 1..<segments.count {
            let gap = segments[i].startTime - segments[i-1].endTime
            if gap >= pauseThreshold {
                runs.append(currentRunLength)
                currentRunLength = 1
            } else {
                currentRunLength += 1
            }
        }
        runs.append(currentRunLength)
        return runs
    }

    private static func computeMLR(segments: [WordTimestamp], pauseThreshold: TimeInterval) -> Float {
        let runs = computeRuns(segments: segments, pauseThreshold: pauseThreshold)
        guard !runs.isEmpty else { return 0 }
        return Float(runs.reduce(0, +)) / Float(runs.count)
    }



    private static func generateFeedback(
        speechRate: Float,
        articulationRate: Float,
        ptr: Float,
        mlr: Float,
        pauseFrequency: Float,
        meanPauseDuration: Float,
        disfluencyReport: DisfluencyReport? = nil,
        thresholds: FluencyThresholds
    ) -> [FluencyFeedbackItem] {
        var items: [FluencyFeedbackItem] = []
        
        // PTR feedback
        if ptr < thresholds.ptrOkay {
            items.append(FluencyFeedbackItem(
                metric: "Phonation",
                value: String(format: "%.0f%%", ptr * 100),
                message: "You spent more time pausing than speaking. Try to maintain a steadier flow.",
                status: .incorrect
            ))
        } else if ptr < thresholds.ptrGood {
            items.append(FluencyFeedbackItem(
                metric: "Phonation",
                value: String(format: "%.0f%%", ptr * 100),
                message: "Some hesitation detected. Try reading ahead to reduce mid-sentence pauses.",
                status: .needsWork
            ))
        } else {
            items.append(FluencyFeedbackItem(
                metric: "Phonation",
                value: String(format: "%.0f%%", ptr * 100),
                message: "Good speech flow with minimal pausing.",
                status: .good
            ))
        }
        
        // Speech rate feedback
        if speechRate < thresholds.speechRateOkay {
            items.append(FluencyFeedbackItem(
                metric: "Speech Rate",
                value: String(format: "%.1f wps", speechRate),
                message: "Very slow pace. Try to speak a bit faster to sound more natural.",
                status: .incorrect
            ))
        } else if speechRate < thresholds.speechRateGood {
            items.append(FluencyFeedbackItem(
                metric: "Speech Rate",
                value: String(format: "%.1f wps", speechRate),
                message: "Slightly slow pace. You can improve by speaking with more confidence.",
                status: .needsWork
            ))
        } else if speechRate > (thresholds.speechRateTargetMax + 0.8) {
            items.append(FluencyFeedbackItem(
                metric: "Speech Rate",
                value: String(format: "%.1f wps", speechRate),
                message: "Pace is unusually rapid. Practice deliberate enunciation to ensure listeners can absorb every word.",
                status: .needsWork
            ))
        } else {
            items.append(FluencyFeedbackItem(
                metric: "Speech Rate",
                value: String(format: "%.1f wps", speechRate),
                message: "Natural speaking pace.",
                status: .good
            ))
        }
        
        // MLR feedback
        if mlr < thresholds.mlrOkay {
            items.append(FluencyFeedbackItem(
                metric: "Flow",
                value: String(format: "%.1f w/run", mlr),
                message: "Speech is highly fragmented. Try linking your words together.",
                status: .incorrect
            ))
        } else if mlr < thresholds.mlrGood {
            items.append(FluencyFeedbackItem(
                metric: "Flow",
                value: String(format: "%.1f w/run", mlr),
                message: "Some fragmentation detected. Practice longer phrases.",
                status: .needsWork
            ))
        } else {
            items.append(FluencyFeedbackItem(
                metric: "Flow",
                value: String(format: "%.1f w/run", mlr),
                message: "Words flow together smoothly.",
                status: .good
            ))
        }

        // Disfluency feedback
        if let report = disfluencyReport {
            if report.intraPhrasePauseCount >= 2 && report.intraPhrasePauseRatio > 0.40 {
                items.append(FluencyFeedbackItem(
                    metric: "Phrase Linking",
                    value: "\(report.intraPhrasePauseCount) mid-phrase",
                    message: "Pauses occurred within phrases rather than at natural clause breaks. Practice grouping connected words into single breath units.",
                    status: .needsWork
                ))
            }

            if report.repetitionCount > 0 {
                items.append(FluencyFeedbackItem(
                    metric: "Repetitions",
                    value: "\(report.repetitionCount) repeated",
                    message: "Consecutive word repetitions detected. Try steadying your pacing to reduce self-corrections.",
                    status: .needsWork
                ))
            }

            if report.fillerCount > 0 {
                items.append(FluencyFeedbackItem(
                    metric: "Vocal Hesitations",
                    value: "\(report.fillerCount) fillers",
                    message: "Vocalized fillers ('um'/'uh') were detected. Aim for quiet pauses when formulating thoughts.",
                    status: .needsWork
                ))
            }
        }
        
        return items
    }
}
