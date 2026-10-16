import Foundation
import CoreML
import Speech

class PhonemeScoringService {
    let inferenceEngine: InferenceEngine
    let scorer = AlignmentScorerEngine()
    
    init(inferenceEngine: InferenceEngine) {
        self.inferenceEngine = inferenceEngine
    }
    
    func scoreAudio(
        _ audioChunk: [Float],
        transcript: String,
        literalTranscript: String,
        sfSpeechTranscript: String,
        snappedTranscript: String = "",
        whisperTranscript: String = "",
        scoringReference: String? = nil,
        ttsAudio: [Float]? = nil,
        userSegments: [WordTimestamp] = [],
        ttsSegments: [WordTimestamp] = [],
        cachedTtsProbs: (probs: [Float], frames: Int, vocabSize: Int)? = nil,
        hiddenStates: MLMultiArray? = nil,
        isChild: Bool = false,
        userVerified: Bool = false,
        sttLogProbs: [[Float]]? = nil
    ) -> ScoringResult? {
        guard let phonemeEngine = inferenceEngine.phonemeEngine else {
            return nil
        }

        // Defensive normalization: Ensure userSegments are chunk-relative (offset = 0.0)
        let chunkDuration = Double(audioChunk.count) / 16000.0
        let effectiveUserSegments: [WordTimestamp]
        if let first = userSegments.first, first.startTime > 2.0 && first.startTime >= chunkDuration * 0.5 {
            let offset = first.startTime
            effectiveUserSegments = userSegments.map {
                WordTimestamp(
                    word: $0.word,
                    startTime: max(0.0, $0.startTime - offset),
                    duration: $0.duration,
                    alignmentScore: $0.alignmentScore
                )
            }
        } else {
            effectiveUserSegments = userSegments
        }
        
        guard let userLogits = inferenceEngine.extractPhonemeLogits(audioChunk: audioChunk) else {
            return nil
        }
        
        // Pitch / High-frequency Zero-Crossing Rate
        let pitchZcr: Float = {
            guard audioChunk.count > 1 else { return 0.0 }
            var crossings = 0
            for k in 1..<audioChunk.count {
                if (audioChunk[k] >= 0 && audioChunk[k - 1] < 0) || (audioChunk[k] < 0 && audioChunk[k - 1] >= 0) {
                    crossings += 1
                }
            }
            return Float(crossings) / Float(audioChunk.count)
        }()
        
        let heardPhonemesWithFrames = phonemeEngine.runGreedyDecodeWithFrames(logits: userLogits)
        
        let userProbs = phonemeEngine.getProbabilities(from: userLogits)
        var ttsProbs: (probs: [Float], frames: Int, vocabSize: Int)? = cachedTtsProbs
        
        if ttsProbs == nil, let ttsAudio = ttsAudio, let ttsLogits = inferenceEngine.extractPhonemeLogits(audioChunk: ttsAudio) {
            ttsProbs = phonemeEngine.getProbabilities(from: ttsLogits)
        }
        
        // Decoupled scoring reference (Strategy 1):
        // Use clean scoring reference (e.g. WhisperKit or ground truth) when provided for canonical target derivation,
        // while displaying the Acoustic Mirror verbatim transcript to the user.
        let effectiveReference = (scoringReference?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? scoringReference!.trimmingCharacters(in: .whitespacesAndNewlines)
            : transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Target 1: US English (Espeak US Dialect)
        let usWordPhonemes = EspeakManager.shared.getPhonemesDetailed(for: effectiveReference, dialect: .us)
        let usTargets = usWordPhonemes.flatMap { wp -> [String] in
            guard let sIdx = wp.primaryStressIndex, sIdx < wp.phonemes.count else {
                return wp.phonemes
            }
            var phones = wp.phonemes
            phones[sIdx] = "ˈ" + phones[sIdx]
            return phones
        }
        
        // Target 2: UK English (Espeak)
        let ukWordPhonemes = EspeakManager.shared.getPhonemesDetailed(for: effectiveReference, dialect: .generic)
        let ukTargets = ukWordPhonemes.flatMap { wp -> [String] in
            guard let sIdx = wp.primaryStressIndex, sIdx < wp.phonemes.count else {
                return wp.phonemes
            }
            var phones = wp.phonemes
            phones[sIdx] = "ˈ" + phones[sIdx]
            return phones
        }
        
        var sentenceUSPhoneScores: [PhoneScore]? = nil
        var sentenceUKPhoneScores: [PhoneScore]? = nil
        var hasComputedSentenceScores = false
        func getSentenceScores() -> ([PhoneScore], [PhoneScore]) {
            if hasComputedSentenceScores {
                return (sentenceUSPhoneScores ?? [], sentenceUKPhoneScores ?? [])
            }
            hasComputedSentenceScores = true
            let us = scorer.scorePronunciation(
                userLogits: userLogits,
                targetPhonemes: usTargets,
                vocabulary: phonemeEngine.vocabulary
            )
            let uk = scorer.scorePronunciation(
                userLogits: userLogits,
                targetPhonemes: ukTargets,
                vocabulary: phonemeEngine.vocabulary
            )
            sentenceUSPhoneScores = us
            sentenceUKPhoneScores = uk
            return (us, uk)
        }
        
        let parseWords: (String) -> [String] = { text in
            text.components(separatedBy: .whitespacesAndNewlines)
                .map { DiscrepancyEngine.cleanWord($0) }
                .filter { !$0.isEmpty }
        }
        
        let literalWords = parseWords(literalTranscript)
        let sfSpeechWords = parseWords(sfSpeechTranscript)
        let whisperWords = parseWords(whisperTranscript)
        let displayWords = parseWords(transcript)
        
        let refWordsList = usWordPhonemes.map { $0.word }
        let alignedDisplayMap = !displayWords.isEmpty ? DiscrepancyEngine.alignWords(targetWords: refWordsList, streamWords: displayWords) : [:]
        let alignedLiteralMap = DiscrepancyEngine.alignWords(targetWords: refWordsList, streamWords: literalWords)
        let alignedSFSpeechMap = !sfSpeechWords.isEmpty ? DiscrepancyEngine.alignWords(targetWords: refWordsList, streamWords: sfSpeechWords) : [:]
        let alignedWhisperMap = !whisperWords.isEmpty ? DiscrepancyEngine.alignWords(targetWords: refWordsList, streamWords: whisperWords) : [:]
        let allLiteralWordsSet = Set(literalWords.map { DiscrepancyEngine.cleanWord($0) })
        let allSFSpeechWordsSet = Set(sfSpeechWords.map { DiscrepancyEngine.cleanWord($0) })
        
        let usWordExpectedPhonemes = usWordPhonemes.map { $0.phonemes }
        let heardWordPhonemesMap = PhonemeWordAligner.partitionHeardPhonemes(
            words: usWordPhonemes.map { $0.word },
            wordTimings: effectiveUserSegments,
            heardPhonemes: heardPhonemesWithFrames,
            expectedWordPhonemes: usWordExpectedPhonemes
        )
            
        var usWordOffsets: [Int] = []
        var runningUS = 0
        for wp in usWordPhonemes {
            usWordOffsets.append(runningUS)
            runningUS += wp.phonemes.count
        }
        
        var ukWordOffsets: [Int] = []
        var runningUK = 0
        for wp in ukWordPhonemes {
            ukWordOffsets.append(runningUK)
            runningUK += wp.phonemes.count
        }
        
        var feedbackItems: [WordFeedbackItem] = []
        var scoredWords: [ScoredWord] = []
        var totalScore = 0
        var wordCount = 0
        var lastUserSegmentIdx = 0
        var lastTtsSegmentIdx = 0
        
        let ctcConfFeatures: [Int: CTCConfidenceFeatures.WordConfidenceFeatures]
        if let logProbs = sttLogProbs, !effectiveUserSegments.isEmpty {
            ctcConfFeatures = CTCConfidenceFeatures.computePerWord(
                logProbs: logProbs,
                wordTimestamps: effectiveUserSegments,
                topBeams: inferenceEngine.latestTopBeams
            )
        } else {
            ctcConfFeatures = [:]
        }
        
        for i in 0..<usWordPhonemes.count {
            let wpUS = usWordPhonemes[i]
            let displayWord = alignedDisplayMap[i] ?? wpUS.word
            let displayLower = displayWord.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let ukPhonemes = (i < ukWordPhonemes.count) ? ukWordPhonemes[i].phonemes : []
            let ukPhonemeCount = ukPhonemes.count
            let wordLower = wpUS.word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let isFunctionWord = Self.functionWords.contains(wordLower)
            let isClitic = Self.clitics.contains(wordLower)
            
            // Find matched alignment segment for user audio (matching target or displayed token)
            var matchedUserSegment: WordTimestamp? = nil
            var matchedUserSegmentIdx: Int? = nil
            for j in lastUserSegmentIdx..<effectiveUserSegments.count {
                let segWord = effectiveUserSegments[j].word.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if segWord == wordLower || segWord == displayLower {
                    matchedUserSegment = effectiveUserSegments[j]
                    matchedUserSegmentIdx = j
                    lastUserSegmentIdx = j + 1
                    break
                }
            }
            if matchedUserSegment == nil && i < effectiveUserSegments.count {
                matchedUserSegment = effectiveUserSegments[i]
                matchedUserSegmentIdx = i
            }
            
            // 1. Per-word audio slicing when alignment confidence is sufficient
            let (wordUSPhoneScores, wordUKPhoneScores) = sliceAndScoreWord(
                userSeg: matchedUserSegment,
                userProbs: userProbs,
                usPhonemes: wpUS.phonemes,
                ukPhonemes: ukPhonemes,
                phonemeEngine: phonemeEngine
            )
            
            // Fetch sentence-level baseline scores for this word
            let (sentenceUS, sentenceUK) = getSentenceScores()
            let uStart = usWordOffsets[i]
            let uEnd = min(sentenceUS.count, uStart + wpUS.phonemes.count)
            let sentUS: [PhoneScore] = (uStart < sentenceUS.count && uStart <= uEnd) ? Array(sentenceUS[uStart..<uEnd]) : []
            
            let sentUK: [PhoneScore]
            if i < ukWordOffsets.count {
                let kStart = ukWordOffsets[i]
                let kEnd = min(sentenceUK.count, kStart + ukPhonemeCount)
                sentUK = (kStart < sentenceUK.count && kStart <= kEnd) ? Array(sentenceUK[kStart..<kEnd]) : []
            } else {
                sentUK = []
            }
            
            // 2. Dual-resolution synthesis: Combine sentence-level global context with per-word local slicing
            let finalUS = combineDualResolution(sentenceScores: sentUS, slicedScores: wordUSPhoneScores)
            let finalUK = combineDualResolution(sentenceScores: sentUK, slicedScores: wordUKPhoneScores)
            
            // Score US vs UK with Nucleus Weighting
            let (usAvgScore, usPhoneFeedback, usVAvg, usCAvg) = computeWordBaseScore(phones: finalUS)
            let (ukAvgScore, ukPhoneFeedback, ukVAvg, ukCAvg) = computeWordBaseScore(phones: finalUK)
            
            let usedUS = usAvgScore >= ukAvgScore
            let baseAvgScore = max(usAvgScore, ukAvgScore)
            
            var wordPhoneScores: [PhonemeFeedback] = usedUS ? usPhoneFeedback : ukPhoneFeedback
            
            // Find matched TTS segment for DTW
            var matchedTtsSegment: WordTimestamp? = nil
            for j in lastTtsSegmentIdx..<ttsSegments.count {
                if ttsSegments[j].word.lowercased().trimmingCharacters(in: .punctuationCharacters) == wordLower {
                    matchedTtsSegment = ttsSegments[j]
                    lastTtsSegmentIdx = j + 1
                    break
                }
            }
            
            let wordDtwDistance = computeWordDTW(
                userSeg: matchedUserSegment,
                ttsSeg: matchedTtsSegment,
                userProbs: userProbs,
                ttsProbs: ttsProbs
            )
            
            // Aligner Missing / Omission Check
            let alignConfidence = matchedUserSegment?.alignmentScore ?? 0.0
            let isAcousticallyMissing = (matchedUserSegment == nil || alignConfidence < 0.20)
            
            // 3. Phonological Heuristic Checks
            let isVoicingHarmonyDefective = checkVoicingHarmony(wordPhoneScores: wordPhoneScores, isFunctionWord: isFunctionWord)
            
            let rawStressIdx = wpUS.primaryStressIndex ?? (i < ukWordPhonemes.count ? ukWordPhonemes[i].primaryStressIndex : nil)
            let isStressInverted = checkStressInversion(
                wordPhoneScores: wordPhoneScores,
                finalScores: usedUS ? finalUS : finalUK,
                baseAvgScore: baseAvgScore,
                primaryStressIndex: rawStressIdx,
                isFunctionWord: isFunctionWord
            )
            
            // 4. Multi-Stream Discrepancy Resolution
            let alignedLiteral = alignedLiteralMap[i]
            let alignedSFSpeech = alignedSFSpeechMap[i]
            let alignedWhisper = alignedWhisperMap[i]
            
            let targetPhones = usedUS ? wpUS.phonemes : ukPhonemes
            let heardPhonesForWord = heardWordPhonemesMap[i]?.map { $0.symbol } ?? []
            let alignedPairs = PhonemeWordAligner.alignExpectedVsHeard(
                expected: targetPhones,
                heard: heardPhonesForWord,
                gopScores: wordPhoneScores.map { $0.score }
            )
            
            for (pIdx, p) in wordPhoneScores.enumerated() {
                if let match = alignedPairs.first(where: { $0.expected == p.symbol && $0.heard != nil }) {
                    wordPhoneScores[pIdx].heardSymbol = match.heard
                }
            }
            
            let expectedIpa = "/" + targetPhones.joined() + "/"
            let heardIpa = heardPhonesForWord.isEmpty ? "[]" : "[" + heardPhonesForWord.joined() + "]"
            
            let discrepancy = DiscrepancyEngine.resolveWord(
                targetWord: wpUS.word,
                alignedLiteral: alignedLiteral,
                allLiteralWords: allLiteralWordsSet,
                alignedSFSpeech: alignedSFSpeech,
                allSFSpeechWords: allSFSpeechWordsSet,
                phoneScores: wordPhoneScores,
                baseAvgScore: baseAvgScore,
                isFunctionWord: isFunctionWord,
                isClitic: isClitic,
                isMissing: isAcousticallyMissing,
                dtwDistance: wordDtwDistance,
                isStressInverted: isStressInverted,
                isVoicingHarmonyDefective: isVoicingHarmonyDefective,
                alignedPhonemes: alignedPairs
            )
            
            // 5. 14-Dimensional Feature Extraction for Learned Scoring Head
            let cleanWordTarget = DiscrepancyEngine.cleanWord(wpUS.word)
            let hasExactLit: Bool = {
                if let al = alignedLiteral, DiscrepancyEngine.matchesWord(target: cleanWordTarget, candidate: al) { return true }
                return allLiteralWordsSet.contains { DiscrepancyEngine.matchesWord(target: cleanWordTarget, candidate: $0) }
            }()
            let hasExactSF: Bool = {
                if let asf = alignedSFSpeech, DiscrepancyEngine.matchesWord(target: cleanWordTarget, candidate: asf) { return true }
                return allSFSpeechWordsSet.contains { DiscrepancyEngine.matchesWord(target: cleanWordTarget, candidate: $0) }
            }()

            let baseGOP = Float(baseAvgScore) / 100.0
            let minPhone = Float(wordPhoneScores.map { $0.score }.min() ?? 100) / 100.0
            let vowelNucleus = (usedUS ? usVAvg : ukVAvg) / 100.0
            let consonantScore = (usedUS ? usCAvg : ukCAvg) / 100.0
            let phoneMarginMean = wordPhoneScores.isEmpty ? 0.0 : max(-5.0, min(5.0, wordPhoneScores.map { $0.phoneMargin }.reduce(0, +) / Float(wordPhoneScores.count)))
            let phoneCount = max(1, targetPhones.count)
            let expectedDur = max(0.08, Double(phoneCount) * 0.075)
            
            let alignConf = alignConfidence
            let durRatio: Float = matchedUserSegment != nil ? Float(min(5.0, max(0.1, matchedUserSegment!.duration / expectedDur))) : 0.0

            let finalScores = usedUS ? finalUS : finalUK
            var stressedVowelIdx: Int? = nil
            if let rawStressIdx = rawStressIdx, rawStressIdx < finalScores.count {
                for idx in rawStressIdx..<finalScores.count {
                    let clean = finalScores[idx].symbol
                        .replacingOccurrences(of: "ˈ", with: "")
                        .replacingOccurrences(of: "ˌ", with: "")
                        .replacingOccurrences(of: "\u{200D}", with: "")
                    if Self.vowels.contains(clean) {
                        stressedVowelIdx = idx
                        break
                    }
                }
            }

            let stressRatio: Float = {
                guard let sIdx = stressedVowelIdx, sIdx < finalScores.count else { return 1.0 }
                let unstressedVowels = finalScores.enumerated().filter { (idx, p) in
                    idx != sIdx && Self.vowels.contains(p.symbol.replacingOccurrences(of: "ˈ", with: "").replacingOccurrences(of: "ˌ", with: "").replacingOccurrences(of: "\u{200D}", with: ""))
                }
                guard !unstressedVowels.isEmpty else { return 1.0 }
                let stressedFrames = Float(finalScores[sIdx].frames)
                let avgUnstressedFrames = Float(unstressedVowels.map { $0.element.frames }.reduce(0, +)) / Float(unstressedVowels.count)
                guard avgUnstressedFrames > 0 else { return 1.0 }
                return min(5.0, max(0.2, stressedFrames / avgUnstressedFrames))
            }()

            let isContentWord: Float = isFunctionWord ? 0.0 : 1.0
            let isCliticVal: Float = isClitic ? 1.0 : 0.0
            let wordLenVal: Float = Float(targetPhones.count)
            let hasExactLitVal: Float = hasExactLit ? 1.0 : 0.0
            let hasExactSFVal: Float = hasExactSF ? 1.0 : 0.0

            let consensusCode: Float
            switch discrepancy.consensusState {
            case .dualRejection: consensusCode = 0.0
            case .sfSpeechOnly:  consensusCode = 1.0
            case .literalOnly:   consensusCode = 2.0
            case .dualMatch:     consensusCode = 3.0
            }

            let hs = hiddenStates ?? inferenceEngine.latestHiddenStates
            let wordStartFrame = matchedUserSegment != nil ? Int(matchedUserSegment!.startTime * 50) : 0
            let wordEndFrame = matchedUserSegment != nil ? Int((matchedUserSegment!.startTime + matchedUserSegment!.duration) * 50) : 0
            let embeddingStability = (matchedUserSegment != nil && hs != nil) ? computeEmbeddingStability(hiddenStates: hs, startFrame: wordStartFrame, endFrame: wordEndFrame) : 0.0

            let dtwVal = Float(max(0.0, min(5.0, wordDtwDistance)))
            let embStabVal = Float(max(0.0, min(1.0, embeddingStability)))
            let topCompetitorMassMax: Float = wordPhoneScores.map { $0.topCompetitorMass }.max() ?? 0.0

            // Unconstrained phonetic alignment metrics from raw acoustic greedy decode (bypasses ASR LM)
            var phoneticSubCount: Float = 0.0
            var phoneticDelCount: Float = 0.0
            var phoneticInsCount: Float = 0.0
            var phoneticMatchCount: Float = 0.0
            for pair in alignedPairs {
                if case .substitution = pair.errorType {
                    phoneticSubCount += 1.0
                } else if case .deletion = pair.errorType {
                    phoneticDelCount += 1.0
                } else if case .insertion = pair.errorType {
                    phoneticInsCount += 1.0
                } else if pair.errorType == .none || (pair.expected != nil && pair.heard != nil && pair.expected == pair.heard) {
                    phoneticMatchCount += 1.0
                }
            }
            let totalExpectedPhones = Float(max(1, targetPhones.count))
            let phoneticMatchRatio: Float = min(1.0, max(0.0, phoneticMatchCount / totalExpectedPhones))
            let isChildVal: Float = isChild ? 1.0 : 0.0

            let wordPitchZcr: Float = {
                guard let seg = matchedUserSegment, audioChunk.count > 1 else { return pitchZcr }
                let startSample = max(0, Int(seg.startTime * 16000))
                let endSample = min(audioChunk.count, Int((seg.startTime + seg.duration) * 16000))
                guard endSample > startSample + 1 else { return pitchZcr }
                var crossings = 0
                for k in (startSample + 1)..<endSample {
                    if (audioChunk[k] >= 0 && audioChunk[k - 1] < 0) || (audioChunk[k] < 0 && audioChunk[k - 1] >= 0) {
                        crossings += 1
                    }
                }
                return Float(crossings) / Float(endSample - startSample)
            }()

            let featureVector: [Float] = [
                baseGOP,
                minPhone,
                vowelNucleus,
                consonantScore,
                phoneMarginMean,
                alignConf,
                durRatio,
                stressRatio,
                isContentWord,
                isCliticVal,
                wordLenVal,
                hasExactLitVal,
                hasExactSFVal,
                consensusCode,
                dtwVal,
                embStabVal,
                topCompetitorMassMax,
                phoneticSubCount,
                phoneticDelCount,
                phoneticInsCount,
                phoneticMatchRatio,
                isChildVal,
                wordPitchZcr
            ]

            var finalAvgScore: Int
            var wordStatus: PronunciationStatus
            
            if LearnedScoringEngine.shared.isReady {
                if let seqPred = LearnedScoringEngine.shared.predictSequenceScore(phones: wordPhoneScores, wordFeatures: featureVector) {
                    finalAvgScore = Int(min(100.0, max(0.0, round(Double(seqPred.score) * 10.0))))
                    let passingCutoff = STTSettings.currentPassingThreshold
                    wordStatus = (!seqPred.isError && finalAvgScore >= passingCutoff) ? .good : (finalAvgScore >= 40 ? .needsWork : .incorrect)
                } else {
                    let pred = LearnedScoringEngine.shared.predictScore(features: featureVector)
                    finalAvgScore = Int(min(100.0, max(0.0, round(Double(pred) * 10.0))))
                    let passingCutoff = STTSettings.currentPassingThreshold
                    wordStatus = finalAvgScore >= passingCutoff ? .good : (finalAvgScore >= 40 ? .needsWork : .incorrect)
                }
            } else {
                finalAvgScore = discrepancy.score
                wordStatus = discrepancy.status
            }
            
            // STT Confidence Evaluation & Multi-Stream Pedagogical Categorization
            let wordCTCFeats = matchedUserSegmentIdx.flatMap { ctcConfFeatures[$0] }
            let sttEval = STTConfidenceEngine.evaluateWord(
                word: displayWord,
                segment: matchedUserSegment,
                literalWords: literalWords,
                whisperWords: whisperWords,
                sfSpeechWords: sfSpeechWords,
                alignedWhisperWord: alignedWhisper,
                alignedSFSpeechWord: alignedSFSpeech,
                alignedLiteralWord: alignedLiteral,
                phoneticMatchRatio: phoneticMatchRatio,
                frameEntropy: wordCTCFeats?.frameEntropy,
                meanBlankProb: wordCTCFeats?.meanBlankProb,
                maxNonBlankRun: wordCTCFeats?.maxNonBlankRun,
                blankStability: wordCTCFeats.map { Float($0.maxNonBlankRun) },
                blankOscillationRate: wordCTCFeats?.blankOscillationRate,
                beamConsensus: wordCTCFeats?.beamConsensus,
                useLearnedConfidenceHead: inferenceEngine.useLearnedConfidenceHead,
                acousticScore: finalAvgScore,
                scoringReferenceWord: wpUS.word
            )
            
            let isIntentSubstitution = !userVerified && (wpUS.word.lowercased() != displayWord.lowercased()) && (scoringReference != nil)
            let isWordUncertain = !userVerified && sttEval.isUncertain && !isIntentSubstitution
            if isWordUncertain {
                wordStatus = .uncertainTranscription
            } else if sttEval.category == .preservedGrammarVariation {
                // Preserved Non-Standard Grammar:
                // User uttered a valid grammatical variant (e.g. "he have"), confirmed by acoustic evidence.
                // Protect pronunciation score and mark .good so syntax coaching handles it without phonological penalty.
                wordStatus = .good
                finalAvgScore = max(finalAvgScore, 75)
            }
            
            let diagPhones = wordPhoneScores.map { "\($0.symbol):\($0.score)[\($0.frames)f,pM:\(String(format: "%.1f", $0.phoneMargin)),postM:\(String(format: "%.1f", $0.posteriorMargin))]" }.joined(separator: ",")
            let diagInfo = "Phones[\(diagPhones)] Exp:\(expectedIpa) Heard:\(heardIpa) Base:\(baseAvgScore) State:\(discrepancy.consensusState.rawValue) Reason:\(discrepancy.diagnosticReason) VMerge:\(discrepancy.isVowelMerge) Final:\(finalAvgScore) DTW:\(String(format: "%.3f", wordDtwDistance)) DurRatio:\(String(format: "%.2f", durRatio)) EmbStab:\(String(format: "%.2f", embeddingStability)) STTConf:\(String(format: "%.2f", sttEval.confidence)) STTUncertain:\(isWordUncertain) Cat:\(sttEval.category.rawValue) Ent:\(String(format: "%.2f", wordCTCFeats?.frameEntropy ?? 0.0)) Blank:\(String(format: "%.2f", wordCTCFeats?.meanBlankProb ?? 0.0))"
            
            feedbackItems.append(WordFeedbackItem(
                word: displayWord,
                status: wordStatus,
                overallScore: finalAvgScore,
                phonemes: wordPhoneScores,
                startTime: matchedUserSegment?.startTime,
                endTime: matchedUserSegment?.endTime,
                expectedIpa: expectedIpa,
                heardIpa: heardIpa,
                alignedPhonemes: alignedPairs
            ))
            
            scoredWords.append(ScoredWord(
                text: displayWord,
                status: wordStatus,
                score: finalAvgScore,
                diagnosticInfo: diagInfo,
                features: featureVector,
                sttConfidence: sttEval.confidence,
                isUncertainTranscription: isWordUncertain,
                candidateAlternatives: sttEval.candidates
            ))
            
            if wordStatus != .uncertainTranscription {
                totalScore += finalAvgScore
                wordCount += 1
            }
        }
        
        let overall = wordCount > 0 ? totalScore / wordCount : (scoredWords.isEmpty ? 0 : scoredWords.map(\.score).reduce(0, +) / scoredWords.count)
        
        return ScoringResult(
            overallScore: overall,
            scoredWords: scoredWords,
            feedbackItems: feedbackItems
        )
    }
}

// MARK: - Audio Slicing, Dual-Resolution Synthesis & Phonological Heuristics

extension PhonemeScoringService {
    
    // MARK: - Phonological Sets
    
    static let consonants: Set<String> = [
        "p", "b", "t", "d", "k", "ɡ", "tʃ", "dʒ",
        "f", "v", "θ", "ð", "s", "z", "ʃ", "ʒ", "h",
        "m", "n", "ŋ", "l", "ɹ", "w", "j"
    ]
    
    static let vowels: Set<String> = [
        "iː", "ɪ", "eɪ", "ɛ", "æ", "ɑː", "ɒ", "ɔː", "oʊ",
        "ʊ", "uː", "ʌ", "ɜː", "ə", "aɪ", "aʊ", "ɔɪ", "ɪɹ",
        "ɛɹ", "ʊɹ", "i", "u", "a", "ɑːɹ", "ɔːɹ", "oːɹ", "ɚ",
        "ɔ", "o", "e", "ɑ", "əʊ", "iə", "eə", "ʊə", "ɐ", "ä",
        "ɨ", "ʉ", "ɯ", "ai", "au", "oi"
    ]
    
    static let laxVowels: Set<String> = [
        "ɛ", "ʊ", "ɔ", "ɒ", "ɪ", "ʌ", "ə", "ɚ", "ɐ", "æ", "a"
    ]
    
    static let unreleasedCodas: Set<String> = ["p", "b", "t", "d", "k", "ɡ", "m", "n", "ŋ"]
    static let terminalFricatives: Set<String> = ["v", "z", "f", "s", "ð", "θ", "ʃ", "ʒ"]
    static let voicedCodaFricatives: Set<String> = ["z", "v", "ð", "ʒ"]
    static let clitics: Set<String> = ["a", "an", "the"]
    
    static let functionWords: Set<String> = [
        // Articles
        "a", "an", "the",
        // Core pronouns (unstressed forms dominate)
        "i", "you", "he", "she", "it", "we", "they",
        "me", "him", "her", "us", "them",
        "my", "your", "his", "its", "our", "their",
        // Auxiliaries (heavily reduced in natural speech)
        "do", "does", "did", "have", "has", "had",
        "can", "could", "will", "would", "shall", "should",
        "may", "might", "must", "is", "am", "are",
        "was", "were", "be", "been", "being",
        // Short prepositions and particles (typically unstressed)
        "in", "on", "at", "to", "for", "of", "by", "as",
        "with", "up", "from", "into", "out", "off", "down",
        // Conjunctions & discourse markers
        "and", "but", "or", "if", "so", "than", "then", "that", "there", "it's", "all",
        // Common contractions & clitics in connected speech
        "that's", "it's", "i'm", "we're", "they're", "you're", "don't", "can't", "won't", "i've", "you've", "we've", "they've",
        // Demonstratives
        "this", "these", "those",
        // Question words / relative pronouns
        "who", "what", "where", "when", "why", "how"
    ]
    
    // MARK: - Audio Slicing
    
    /// Slices probability matrix around the word boundary and scores US and UK phoneme targets locally
    func sliceAndScoreWord(
        userSeg: WordTimestamp?,
        userProbs: (probs: [Float], frames: Int, vocabSize: Int),
        usPhonemes: [String],
        ukPhonemes: [String],
        phonemeEngine: PhonemeInferenceEngine
    ) -> (usScores: [PhoneScore]?, ukScores: [PhoneScore]?) {
        guard let userSeg = userSeg, userSeg.alignmentScore >= 0.2 else {
            return (nil, nil)
        }
        
        let wordStartFrame = Int(userSeg.startTime * 50)
        let wordEndFrame = Int((userSeg.startTime + userSeg.duration) * 50)
        // Add 3 frames buffer (60ms) on each side for coarticulation transitions
        let startFrame = max(0, wordStartFrame - 3)
        let endFrame = min(userProbs.frames, wordEndFrame + 3)
        let sliceFrames = endFrame - startFrame
        
        let targetPhoneCount = max(usPhonemes.count, ukPhonemes.count)
        let minFrames = targetPhoneCount * 2 + 2
        guard sliceFrames >= minFrames,
              let sliced = MathService.sliceMatrix(
                  probs: userProbs.probs,
                  frames: userProbs.frames,
                  vocabSize: userProbs.vocabSize,
                  startFrame: startFrame,
                  endFrame: endFrame
              ) else {
            return (nil, nil)
        }
        
        let us = scorer.scorePronunciation(
            probs: sliced.0,
            totalFrames: sliced.1,
            vocabSize: userProbs.vocabSize,
            targetPhonemes: usPhonemes,
            vocabulary: phonemeEngine.vocabulary
        )
        let uk = scorer.scorePronunciation(
            probs: sliced.0,
            totalFrames: sliced.1,
            vocabSize: userProbs.vocabSize,
            targetPhonemes: ukPhonemes,
            vocabulary: phonemeEngine.vocabulary
        )
        return (!us.isEmpty ? us : nil, !uk.isEmpty ? uk : nil)
    }
    
    // MARK: - Dual Resolution Synthesis
    
    /// Combines sentence-level global acoustic context with per-word local sliced acoustic context
    func combineDualResolution(sentenceScores: [PhoneScore], slicedScores: [PhoneScore]?) -> [PhoneScore] {
        guard let sliced = slicedScores, !sliced.isEmpty else {
            return sentenceScores
        }
        guard sliced.count == sentenceScores.count else {
            return sliced
        }
        
        return zip(sentenceScores, sliced).map { sent, sl in
            let combinedScore = 0.60 * sl.gopScore + 0.40 * sent.gopScore
            let resolvedError: ErrorType
            if combinedScore >= 0.70 {
                if case .substitution = sl.errorType, sl.topCompetitorMass > sl.targetMass * 2.0 {
                    resolvedError = sl.errorType
                } else if case .substitution = sent.errorType, sent.topCompetitorMass > sent.targetMass * 2.0 {
                    resolvedError = sent.errorType
                } else {
                    resolvedError = .none
                }
            } else if combinedScore < 0.50 {
                if sl.errorType != .none {
                    resolvedError = sl.errorType
                } else {
                    resolvedError = sent.errorType
                }
            } else {
                if sl.errorType != .none {
                    resolvedError = sl.errorType
                } else {
                    resolvedError = sent.errorType
                }
            }
            let bestTargetMass = max(sent.targetMass, sl.targetMass)
            let minCompMass = min(sent.topCompetitorMass, sl.topCompetitorMass)
            let bestMargin = max(sent.posteriorMargin, sl.posteriorMargin)
            let compSym = sent.topCompetitorMass >= sl.topCompetitorMass ? sent.topCompetitorSymbol : sl.topCompetitorSymbol
            return PhoneScore(
                symbol: sent.symbol,
                gopScore: combinedScore,
                frames: max(sent.frames, sl.frames),
                errorType: resolvedError,
                phoneMargin: max(sent.phoneMargin, sl.phoneMargin),
                targetMass: bestTargetMass,
                topCompetitorMass: minCompMass,
                topCompetitorSymbol: compSym,
                posteriorMargin: bestMargin
            )
        }
    }
    
    // MARK: - Word Scoring Synthesis
    
    /// Computes base score using 45% vowel / 55% consonant weighting
    func computeWordBaseScore(phones: [PhoneScore]) -> (avgScore: Int, phoneFeedbacks: [PhonemeFeedback], vAvg: Float, cAvg: Float) {
        guard !phones.isEmpty else { return (0, [], 0, 0) }
        var phoneFeedbacks: [PhonemeFeedback] = []
        var vowelScores: [Float] = []
        var consonantScores: [Float] = []
        var total: Float = 0.0
        
        for ps in phones {
            let gop = Int(ps.gopScore * 100)
            phoneFeedbacks.append(PhonemeFeedback(
                symbol: ps.symbol,
                score: gop,
                errorType: ps.errorType,
                frames: ps.frames,
                phoneMargin: ps.phoneMargin,
                targetMass: ps.targetMass,
                topCompetitorMass: ps.topCompetitorMass,
                topCompetitorSymbol: ps.topCompetitorSymbol,
                posteriorMargin: ps.posteriorMargin
            ))
            total += Float(gop)
            
            let clean = ps.symbol.replacingOccurrences(of: "ˈ", with: "")
                .replacingOccurrences(of: "ˌ", with: "")
                .replacingOccurrences(of: "\u{200D}", with: "")
            if Self.vowels.contains(clean) {
                vowelScores.append(Float(gop))
            } else {
                consonantScores.append(Float(gop))
            }
        }
        
        let vAvg = vowelScores.isEmpty ? total / Float(phones.count) : vowelScores.reduce(0, +) / Float(vowelScores.count)
        let cAvg = consonantScores.isEmpty ? total / Float(phones.count) : consonantScores.reduce(0, +) / Float(consonantScores.count)
        
        let score: Int
        if !vowelScores.isEmpty && !consonantScores.isEmpty {
            score = Int(round(0.45 * vAvg + 0.55 * cAvg))
        } else {
            score = Int(round(total / Float(phones.count)))
        }
        return (score, phoneFeedbacks, vAvg, cAvg)
    }
    
    // MARK: - Dynamic Time Warping Alignment
    
    /// Computes DTW distance between user audio slice and TTS reference slice for a word
    func computeWordDTW(
        userSeg: WordTimestamp?,
        ttsSeg: WordTimestamp?,
        userProbs: (probs: [Float], frames: Int, vocabSize: Int),
        ttsProbs: (probs: [Float], frames: Int, vocabSize: Int)?
    ) -> Float {
        guard let userSeg = userSeg, let ttsSeg = ttsSeg, let ttsP = ttsProbs else {
            return 0.0
        }
        
        let userStartFrame = Int(userSeg.startTime * 50)
        let userEndFrame = Int((userSeg.startTime + userSeg.duration) * 50)
        let ttsStartFrame = Int(ttsSeg.startTime * 50)
        let ttsEndFrame = Int((ttsSeg.startTime + ttsSeg.duration) * 50)
        
        if let uSlice = MathService.sliceMatrix(probs: userProbs.probs, frames: userProbs.frames, vocabSize: userProbs.vocabSize, startFrame: userStartFrame, endFrame: userEndFrame),
           let tSlice = MathService.sliceMatrix(probs: ttsP.probs, frames: ttsP.frames, vocabSize: ttsP.vocabSize, startFrame: ttsStartFrame, endFrame: ttsEndFrame) {
            return MathService.computeDTW(
                seqA: uSlice.0, framesA: uSlice.1,
                seqB: tSlice.0, framesB: tSlice.1,
                vocabSize: userProbs.vocabSize
            )
        }
        return 0.0
    }
    
    // MARK: - Phonological Error Verification
    
    /// Checks voicing duration harmony for coda fricatives
    func checkVoicingHarmony(wordPhoneScores: [PhonemeFeedback], isFunctionWord: Bool) -> Bool {
        if isFunctionWord || wordPhoneScores.count < 2 { return false }
        
        let lastPhone = wordPhoneScores[wordPhoneScores.count - 1]
        let penultPhone = wordPhoneScores[wordPhoneScores.count - 2]
        let lastSym = lastPhone.symbol
            .replacingOccurrences(of: "ˈ", with: "")
            .replacingOccurrences(of: "ˌ", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
        let penultSym = penultPhone.symbol
            .replacingOccurrences(of: "ˈ", with: "")
            .replacingOccurrences(of: "ˌ", with: "")
            .replacingOccurrences(of: "\u{200D}", with: "")
        
        if Self.voicedCodaFricatives.contains(lastSym) && lastPhone.frames <= 1 && Self.vowels.contains(penultSym) {
            if penultPhone.score < 50 {
                return true
            }
        }
        return false
    }
    
    /// Checks multisyllabic stress inversion
    func checkStressInversion(
        wordPhoneScores: [PhonemeFeedback],
        finalScores: [PhoneScore],
        baseAvgScore: Int,
        primaryStressIndex: Int?,
        isFunctionWord: Bool
    ) -> Bool {
        if isFunctionWord { return false }
        
        let allVowels = wordPhoneScores.filter { p in
            let clean = p.symbol.replacingOccurrences(of: "ˈ", with: "")
                .replacingOccurrences(of: "ˌ", with: "")
                .replacingOccurrences(of: "\u{200D}", with: "")
            return Self.vowels.contains(clean)
        }
        guard allVowels.count >= 2, let rawStressIdx = primaryStressIndex else { return false }
        
        guard rawStressIdx < wordPhoneScores.count else { return false }
        var stressedVowelIdx: Int? = nil
        for idx in rawStressIdx..<wordPhoneScores.count {
            let clean = wordPhoneScores[idx].symbol
                .replacingOccurrences(of: "ˈ", with: "")
                .replacingOccurrences(of: "ˌ", with: "")
                .replacingOccurrences(of: "\u{200D}", with: "")
            if Self.vowels.contains(clean) {
                stressedVowelIdx = idx
                break
            }
        }
        
        guard let sIdx = stressedVowelIdx, sIdx < finalScores.count else { return false }
        
        let unstressedVowels = wordPhoneScores.enumerated().filter { (idx, p) in
            idx != sIdx && Self.vowels.contains(p.symbol.replacingOccurrences(of: "ˈ", with: "").replacingOccurrences(of: "ˌ", with: "").replacingOccurrences(of: "\u{200D}", with: ""))
        }
        
        let stressedFrames = finalScores[sIdx].frames
        let stressedPhoneScore = finalScores[sIdx].gopScore * 100.0
        let maxUnstressedFrames = unstressedVowels.compactMap { (idx, _) -> Int? in
            idx < finalScores.count ? finalScores[idx].frames : nil
        }.max() ?? 0
        
        let maxUnstressedScore = unstressedVowels.compactMap { (idx, _) -> Float? in
            idx < finalScores.count ? Float(finalScores[idx].gopScore * 100.0) : nil
        }.max() ?? 0
        
        return baseAvgScore < 85 && (
            (stressedPhoneScore < 70 && ((stressedFrames <= 2 && maxUnstressedFrames >= 6 && Float(maxUnstressedFrames) > Float(stressedFrames) * 2.0)
            || (stressedFrames <= 3 && maxUnstressedFrames >= 8 && Float(maxUnstressedFrames) > Float(stressedFrames) * 2.5)))
            || (stressedPhoneScore < 35 && maxUnstressedScore >= 80 && maxUnstressedFrames >= stressedFrames)
        )
    }
    
    // MARK: - Continuous Acoustic Embedding Stability (Wav2Vec2 Transformer Hidden States)
    
    /// Computes frame-to-frame cosine similarity of the 1024-dimensional hidden states over a word interval.
    /// Natural phonated vocalization yields high continuity (> 0.70), whereas acoustic noise, dropouts, or mumbling show low continuity (< 0.40).
    func computeEmbeddingStability(hiddenStates: MLMultiArray?, startFrame: Int, endFrame: Int) -> Float {
        guard let hs = hiddenStates, hs.shape.count >= 3 else { return 0.0 }
        let totalFrames = hs.shape[1].intValue
        let hiddenDim = hs.shape[2].intValue
        guard hiddenDim > 0, totalFrames > 1 else { return 0.0 }
        
        let sFrame = max(0, min(startFrame, totalFrames - 2))
        let eFrame = max(sFrame + 1, min(endFrame, totalFrames - 1))
        guard eFrame > sFrame else { return 0.0 }
        
        let isFloat16 = hs.dataType == .float16
        let ptr16 = isFloat16 ? hs.dataPointer.bindMemory(to: Float16.self, capacity: hs.count) : nil
        let ptr32 = !isFloat16 ? hs.dataPointer.bindMemory(to: Float.self, capacity: hs.count) : nil
        let frameStride = hs.strides[1].intValue
        let dimStride = hs.strides[2].intValue
        
        var totalCosine: Float = 0.0
        var pairCount = 0
        
        for t in sFrame..<eFrame {
            let offset1 = t * frameStride
            let offset2 = (t + 1) * frameStride
            
            var dot: Float = 0.0
            var norm1: Float = 0.0
            var norm2: Float = 0.0
            
            for d in 0..<hiddenDim {
                let v1 = isFloat16 ? Float(ptr16![offset1 + d * dimStride]) : ptr32![offset1 + d * dimStride]
                let v2 = isFloat16 ? Float(ptr16![offset2 + d * dimStride]) : ptr32![offset2 + d * dimStride]
                dot += v1 * v2
                norm1 += v1 * v1
                norm2 += v2 * v2
            }
            
            let denom = sqrt(norm1) * sqrt(norm2)
            if denom > 1e-6 {
                let cosSim = max(-1.0, min(1.0, dot / denom))
                totalCosine += cosSim
                pairCount += 1
            }
        }
        
        return pairCount > 0 ? (totalCosine / Float(pairCount)) : 0.0
    }
}
