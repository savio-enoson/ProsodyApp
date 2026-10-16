import Foundation
import AVFoundation
import Speech
import FoundationModels

/// End-to-end streaming simulation evaluator for testing real speech recordings against the Rainbow Passage ground truth.
final class StreamingVoiceEvaluator {
    let inferenceEngine: InferenceEngine
    private let sfSpeechLock = NSLock()

    static let rainbowPassageGT = """
    When the sunlight strikes raindrops in the air, they act as a prism and form a rainbow. The rainbow is a division of white light into many beautiful colors. These take the shape of a long round arch, with its path high above, and its two ends apparently beyond the horizon. There is, according to legend, a boiling pot of gold at one end. People look, but no one ever finds it. When a man looks for something beyond his reach, his friends say he is looking for the pot of gold at the end of the rainbow. Throughout history the rainbow has been a symbol of hope and a sign of things to come. The vibrant bands of red, orange, yellow, green, blue, and violet curve gracefully across the sky, reminding us of the calm that follows a storm. Scientists observe these wavelengths to understand the physics of light, while artists simply try to capture the fleeting brilliance on canvas.
    """

    struct SpeakerSubject {
        let name: String
        let proficiencyGroup: String // "High-Proficiency" or "Medium-Proficiency"
        let filename: String
    }

    init(inferenceEngine: InferenceEngine) {
        self.inferenceEngine = inferenceEngine
    }

    private func getSFSpeechTranscriptSync(audioFloats: [Float]) -> String {
        // Create temporary wav file for SFSpeechURLRecognitionRequest
        let tempDir = FileManager.default.temporaryDirectory
        let tempWav = tempDir.appendingPathComponent("sfspeech_chunk_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempWav) }

        do {
            let file = try AVAudioFile(
                forWriting: tempWav,
                settings: [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: 16000.0,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false
                ]
            )
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(audioFloats.count))!
            buffer.frameLength = AVAudioFrameCount(audioFloats.count)
            let channelData = buffer.floatChannelData![0]
            for i in 0..<audioFloats.count {
                channelData[i] = audioFloats[i]
            }
            try file.write(from: buffer)
        } catch {
            return ""
        }

        let auth = SFSpeechRecognizer.authorizationStatus()
        guard (auth == .authorized || auth == .notDetermined),
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            return ""
        }

        sfSpeechLock.lock()
        defer { sfSpeechLock.unlock() }

        let request = SFSpeechURLRecognitionRequest(url: tempWav)
        request.shouldReportPartialResults = false
        if #available(macOS 13, iOS 16, *) {
            request.requiresOnDeviceRecognition = true
        }

        var finalTranscript = ""
        let sema = DispatchSemaphore(value: 0)

        let task = recognizer.recognitionTask(with: request) { result, error in
            if let result = result {
                finalTranscript = result.bestTranscription.formattedString
                if result.isFinal {
                    sema.signal()
                }
            } else if error != nil {
                sema.signal()
            }
        }

        _ = sema.wait(timeout: .now() + 0.6)
        task.cancel()
        return finalTranscript
    }

    /// Segments audio into streaming turns using the unified TurnSegmenter.
    static func segmentStreamingTurns(audio: [Float], sampleRate: Int = 16000) -> [TurnSegment] {
        return TurnSegmenter.segment(audio: audio, sampleRate: sampleRate)
    }

    /// Evaluates Levenshtein alignment between hypothesis and ground truth words.
    private func computeWordAlignment(hyp: [String], ref: [String]) -> (correct: Int, substitutions: Int, deletions: Int, insertions: Int, alignment: [(type: String, ref: String, hyp: String)]) {
        let m = ref.count
        let n = hyp.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = ref[i - 1].lowercased() == hyp[j - 1].lowercased() ? 0 : 1
                dp[i][j] = min(
                    dp[i - 1][j] + 1,       // Deletion
                    dp[i][j - 1] + 1,       // Insertion
                    dp[i - 1][j - 1] + cost // Match or Substitution
                )
            }
        }

        // Backtrack
        var i = m
        var j = n
        var correct = 0
        var subs = 0
        var dels = 0
        var inss = 0
        var ops: [(type: String, ref: String, hyp: String)] = []

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && ref[i - 1].lowercased() == hyp[j - 1].lowercased() && dp[i][j] == dp[i - 1][j - 1] {
                correct += 1
                ops.append(("C", ref[i - 1], hyp[j - 1]))
                i -= 1
                j -= 1
            } else if i > 0 && j > 0 && dp[i][j] == dp[i - 1][j - 1] + 1 {
                subs += 1
                ops.append(("S", ref[i - 1], hyp[j - 1]))
                i -= 1
                j -= 1
            } else if i > 0 && dp[i][j] == dp[i - 1][j] + 1 {
                dels += 1
                ops.append(("D", ref[i - 1], ""))
                i -= 1
            } else {
                inss += 1
                ops.append(("I", "", hyp[j - 1]))
                j -= 1
            }
        }

        ops.reverse()
        return (correct, subs, dels, inss, ops)
    }

    /// Executes the full streaming simulation for all 4 voice resource subjects.
    func runEvaluation(voiceResourcesDir: URL) async {
        print("\n================================================================================")
        print("          END-TO-END STREAMING VOICE EVALUATION: RAINBOW PASSAGE                ")
        print("================================================================================\n")

        // 1. Initialize Nemotron Core AI & prewarm models
        print("[SETUP] Prewarming models (Kokoro, StyleEncoder, Nemotron Core AI, ScoringHead)...")
        await NemotronSTTService.shared.initializeIfNeeded()
        TTSManager.shared.prewarm()

        // Configure STTSettings
        await MainActor.run {
            STTSettings.shared.engineType = .acousticMirror
            STTSettings.shared.useLearnedScoringHead = true
            STTSettings.shared.useLearnedConfidenceHead = true
            STTSettings.shared.llmProvider = .ollama
            STTSettings.shared.ollamaModel = "gemma4:e4b-mlx"
        }
        self.inferenceEngine.useLearnedScoringHead = true
        LearnedScoringEngine.shared.loadModelIfAvailable()

        var subjects: [SpeakerSubject] = [
            SpeakerSubject(name: "Savio", proficiencyGroup: "High-Proficiency", filename: "savio.wav"),
            SpeakerSubject(name: "Gagaz", proficiencyGroup: "High-Proficiency", filename: "gagaz.wav"),
            SpeakerSubject(name: "Nicholas", proficiencyGroup: "High-Proficiency", filename: "nicholas.wav"),
            SpeakerSubject(name: "Kak Anggi", proficiencyGroup: "Medium-Proficiency", filename: "kak_anggi.wav"),
            SpeakerSubject(name: "Ko Davin", proficiencyGroup: "Medium-Proficiency", filename: "ko_davin.wav"),
            SpeakerSubject(name: "Kak Gemala", proficiencyGroup: "Medium-Proficiency", filename: "kak_gemala.wav"),
            SpeakerSubject(name: "Kak Tere", proficiencyGroup: "Medium-Proficiency", filename: "kak_tere.wav"),
            SpeakerSubject(name: "Dewa", proficiencyGroup: "Medium-Proficiency", filename: "dewa.wav"),
            SpeakerSubject(name: "Tiara", proficiencyGroup: "Medium-Proficiency", filename: "tiara.wav")
        ]

        if let filterStr = ProcessInfo.processInfo.environment["EVAL_STREAMING_SUBJECTS"] {
            let allowed = Set(filterStr.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            subjects = subjects.filter { allowed.contains($0.filename.lowercased()) || allowed.contains($0.name.lowercased()) }
        }

        let refWords = Self.rainbowPassageGT
            .replacingOccurrences(of: "[.,!?;:\"']", with: "", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        print("Ground Truth Words (\(refWords.count) words):")
        print("   \"\(Self.rainbowPassageGT.trimmingCharacters(in: .whitespacesAndNewlines))\"\n")

        var allSubjectResults: [[String: Any]] = []

        for (subjIdx, subj) in subjects.enumerated() {
            let fileURL = voiceResourcesDir.appendingPathComponent(subj.filename)
            print("================================================================================")
            print("[\(subjIdx + 1)/\(subjects.count)] EVALUATING: \(subj.name) (\(subj.proficiencyGroup)) - \(subj.filename)")
            print("================================================================================")

            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                print("[ERROR] Audio file not found at: \(fileURL.path)")
                continue
            }

            guard let audioSamples = try? VoiceClonerNativeEngine.shared.loadAudioAt16kHz(url: fileURL) else {
                print("[ERROR] Failed to load & resample audio at: \(fileURL.path)")
                continue
            }

            let audioDuration = Double(audioSamples.count) / 16000.0
            print("Loaded Audio: \(String(format: "%.2f", audioDuration))s (16,000 Hz Float32 PCM)")

            // Clear previous profile to measure genuine progressive learning
            await MainActor.run {
                TTSManager.shared.clearLearnerProfile()
            }

            // Segment into streaming turns
            let turns = Self.segmentStreamingTurns(audio: audioSamples, sampleRate: 16000)
            print("VAD Segmenter Extracted: \(turns.count) streaming utterance turns.\n")

            let scoringManager = PhonemeScoringManager(inferenceEngine: self.inferenceEngine)
            let sessionPrompt = "The Rainbow Passage - Practice reading aloud"
            var session = SessionRecord(prompt: sessionPrompt, utterances: [])

            var turnRecords: [[String: Any]] = []
            var allHypWords: [String] = []
            var allFlaggedWords: Set<String> = []
            var scoredWordItems: [ScoredWord] = []
            var lastTurnHyp: String? = nil

            for (turnIdx, turn) in turns.enumerated() {
                let tTurn0 = CFAbsoluteTimeGetCurrent()

                // A. STT (Wav2Vec2 Conformer Acoustic Mirror)
                let sttResult = self.inferenceEngine.processSynchronously(audioChunk: turn.samples, reference: nil)
                var snapped = sttResult?.snapped ?? ""
                var literal = sttResult?.literal ?? ""
                let logProbs = sttResult?.logProbs

                // B. Dual-ASR Nemotron Core AI cross-check
                var whisperTranscript = ""
                do {
                    let nRes = try await NemotronSTTService.shared.transcribe(audioFloats: turn.samples, language: "en-US")
                    whisperTranscript = nRes.transcript
                } catch {
                    whisperTranscript = ""
                }

                // C. CTCSegmentation alignment (chunk-relative: timeOffset = 0.0)
                var segments: [WordTimestamp] = []
                if let lp = logProbs, !snapped.isEmpty {
                    segments = CTCSegmentation.align(
                        transcript: snapped,
                        logProbs: lp,
                        vocab: self.inferenceEngine.decoder.vocab,
                        blankIndex: self.inferenceEngine.decoder.blankIndex,
                        timeOffset: 0.0
                    )
                }

                // D. Sliding-window overlap deduplication across all streams before scoring
                var droppedOverlapCount = 0
                if turn.isSlidingWindowContinuation, let prevHyp = lastTurnHyp {
                    let (dedupedHead, droppedCount) = WordOverlapDeduplicator.deduplicateText(tailTranscript: prevHyp, headTranscript: snapped)
                    droppedOverlapCount = droppedCount
                    if droppedCount > 0 {
                        print("     [DEDUP] Dropped \(droppedCount) duplicate overlap prefix tokens across sliding boundary")
                        snapped = dedupedHead
                        if droppedCount < segments.count {
                            segments = Array(segments.dropFirst(droppedCount))
                        }
                        let litWords = literal.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                        if droppedCount < litWords.count {
                            literal = litWords.dropFirst(droppedCount).joined(separator: " ")
                        }
                    }
                }
                lastTurnHyp = sttResult?.snapped ?? snapped

                // E. Apple SFSpeech transcript
                let sfSpeech = getSFSpeechTranscriptSync(audioFloats: turn.samples)

                // F. Fluency Evaluation
                let fluency = FluencyManager.shared.evaluate(
                    segments: segments,
                    isChild: false,
                    audioChunk: turn.samples,
                    transcript: snapped,
                    sfSpeechTranscript: sfSpeech
                )

                // G. Intent vs. Realization Reconciliation & Learned Sequence Scoring
                let intentSource = !whisperTranscript.isEmpty ? whisperTranscript : snapped
                let reconciled = IntentRealizationReconciler.reconcile(
                    intent: intentSource,
                    literal: literal,
                    fallbackTranscript: snapped
                )
                let scoringRef: String? = (reconciled.scoringReference != reconciled.displayTranscript) ? reconciled.scoringReference : nil
                let displayTranscriptToUse = reconciled.displayTranscript.isEmpty ? snapped : reconciled.displayTranscript

                let scoreResult = scoringManager.scoreAudio(
                    turn.samples,
                    transcript: displayTranscriptToUse,
                    literalTranscript: literal,
                    sfSpeechTranscript: sfSpeech,
                    whisperTranscript: whisperTranscript,
                    scoringReference: scoringRef,
                    userSegments: segments,
                    isChild: false,
                    sttLogProbs: logProbs
                )

                // H. Silent Background Learner Voice Profiling
                await MainActor.run {
                    TTSManager.shared.updateLearnerProfile(from: turn.samples)
                }

                let elapsedTurn = CFAbsoluteTimeGetCurrent() - tTurn0
                let turnDur = Double(turn.samples.count) / 16000.0
                let rtf = elapsedTurn / turnDur

                // Store utterance
                let utterance = UtteranceRecord(
                    transcript: snapped,
                    scoringResult: scoreResult,
                    fluencyResult: fluency,
                    wordTimestamps: segments,
                    audioURL: fileURL,
                    startTime: turn.startTime,
                    endTime: turn.endTime
                )
                session.utterances.append(utterance)

                let turnWords = snapped.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                allHypWords.append(contentsOf: turnWords)

                var turnScoresSummary: [String] = []
                if let sr = scoreResult {
                    for w in sr.scoredWords {
                        scoredWordItems.append(w)
                        let statusTag = w.isUncertainTranscription ? "[UNCERTAIN]" : (w.status == .good ? "Good" : "NeedsWork")
                        if w.isUncertainTranscription {
                            allFlaggedWords.insert(w.text.lowercased())
                        }
                        turnScoresSummary.append("\(w.text):\(w.score)%(\(statusTag))")
                    }
                }

                print("  [Turn \(turnIdx + 1)/\(turns.count)] (\(String(format: "%.2f", turn.startTime))s - \(String(format: "%.2f", turn.endTime))s, dur: \(String(format: "%.2f", turnDur))s, RTF: \(String(format: "%.3f", rtf))x)")
                print("     HYP (Acoustic Mirror): \"\(snapped)\"")
                print("     LIT (Raw CTC Greedy):  \"\(literal)\"")
                print("     WHISPER (Dual ASR):    \"\(whisperTranscript)\"")
                print("     Scores: [\(turnScoresSummary.joined(separator: ", "))]")
                if let f = fluency {
                    print(String(format: "     Fluency: %d%% | Rate: %.2f wps | MLR: %.1f | Pauses: %d", f.overallScore, f.speechRate, f.meanLengthOfRun, f.pauseCount))
                }
                print("")

                turnRecords.append([
                    "turnIndex": turnIdx + 1,
                    "startTime": turn.startTime,
                    "endTime": turn.endTime,
                    "duration": turnDur,
                    "rtf": rtf,
                    "transcript": snapped,
                    "literal": literal,
                    "whisper": whisperTranscript,
                    "scores": turnScoresSummary
                ])
            }

            // Wait for profile tasks to settle
            try? await Task.sleep(nanoseconds: 600_000_000)

            // MARK: - Full Session Telemetry
            print("--------------------------------------------------------------------------------")
            print("[\(subj.name)] FULL-SESSION AGGREGATE RESULTS & ACCURACY AUDIT")
            print("--------------------------------------------------------------------------------")

            let fullHypText = session.fullTranscript
            print("Full Hypothesis Transcript: \"\(fullHypText)\"")

            // 1. Levenshtein Alignment against Ground Truth
            let hypCleanWords = allHypWords.map { $0.replacingOccurrences(of: "[.,!?;:\"']", with: "", options: .regularExpression) }.filter { !$0.isEmpty }
            let alignment = computeWordAlignment(hyp: hypCleanWords, ref: refWords)

            let totalRefWords = refWords.count
            let vwer = Double(alignment.substitutions + alignment.deletions + alignment.insertions) / Double(totalRefWords) * 100.0
            let wordAccuracy = Double(alignment.correct) / Double(totalRefWords) * 100.0

            print("\n1. STT Speech Recognition Performance:")
            print("   - Ground Truth Words:   \(totalRefWords)")
            print("   - Transcribed Words:    \(hypCleanWords.count)")
            print("   - Correct Matches (C):  \(alignment.correct)")
            print("   - Substitutions (S):    \(alignment.substitutions)")
            print("   - Deletions (D):        \(alignment.deletions)")
            print("   - Insertions (I):       \(alignment.insertions)")
            print(String(format: "   - Verbatim WER (V-WER): %.2f%%", vwer))
            print(String(format: "   - Word Accuracy:        %.2f%%", wordAccuracy))

            // 2. STT Uncertainty & Flagging Metrics
            // Substituted and Inserted words should ideally be flagged as uncertain (.uncertainTranscription)
            var errorWordsSet = Set<String>()
            for op in alignment.alignment {
                if op.type == "S" || op.type == "I" {
                    if !op.hyp.isEmpty {
                        errorWordsSet.insert(op.hyp.lowercased())
                    }
                }
            }

            var tp = 0 // Error word flagged uncertain
            var fp = 0 // Correct word flagged uncertain
            var fn = 0 // Error word NOT flagged
            var tn = 0 // Correct word NOT flagged

            for w in scoredWordItems {
                let lower = w.text.lowercased().replacingOccurrences(of: "[.,!?;:\"']", with: "", options: .regularExpression)
                let isError = errorWordsSet.contains(lower)
                let isFlagged = w.isUncertainTranscription || (w.sttConfidence ?? 1.0) < 0.55

                if isError && isFlagged { tp += 1 }
                if !isError && isFlagged { fp += 1 }
                if isError && !isFlagged { fn += 1 }
                if !isError && !isFlagged { tn += 1 }
            }

            let flagPrecision = (tp + fp) > 0 ? (Double(tp) / Double(tp + fp) * 100.0) : 0.0
            let flagRecall = (tp + fn) > 0 ? (Double(tp) / Double(tp + fn) * 100.0) : 0.0
            let flagF1 = (flagPrecision + flagRecall) > 0 ? (2.0 * flagPrecision * flagRecall / (flagPrecision + flagRecall)) : 0.0

            print("\n2. STT Confidence & Discrepancy Flagging:")
            print("   - True Positives (Errors Flagged):     \(tp)")
            print("   - False Positives (Clean Flagged):     \(fp)")
            print("   - False Negatives (Errors Missed):     \(fn)")
            print("   - True Negatives (Clean Pass):         \(tn)")
            print(String(format: "   - Flagging Precision:                  %.2f%%", flagPrecision))
            print(String(format: "   - Flagging Recall:                     %.2f%%", flagRecall))
            print(String(format: "   - Flagging F1 Score:                   %.2f%%", flagF1))

            // 3. Pronunciation Scoring Breakdown
            let totalScored = scoredWordItems.count
            let goodWords = scoredWordItems.filter { $0.status == PronunciationStatus.good && !$0.isUncertainTranscription }
            let needsWorkWords = scoredWordItems.filter { ($0.status == PronunciationStatus.needsWork || $0.status == PronunciationStatus.incorrect) && !$0.isUncertainTranscription }
            let uncertainWords = scoredWordItems.filter { $0.isUncertainTranscription }

            let avgPronScore = session.overallPronunciationScore

            print("\n3. Pronunciation Scoring (HiPAMA-Lite Sequence Scorer + 19-Feature GBDT):")
            print("   - Overall Pronunciation Score:         \(avgPronScore)%")
            print("   - Total Words Evaluated:               \(totalScored)")
            print("   - Good Words (Score >= 65%):           \(goodWords.count) (\(String(format: "%.1f", Double(goodWords.count)/Double(max(1, totalScored))*100))%)")
            print("   - Needs Work Words (Score < 65%):      \(needsWorkWords.count) (\(String(format: "%.1f", Double(needsWorkWords.count)/Double(max(1, totalScored))*100))%)")
            print("   - Uncertain Words (Neutral Yellow):    \(uncertainWords.count)")
            
            let feedbackNeedsWork = session.allFeedbackItems.filter { $0.status == PronunciationStatus.needsWork || $0.status == PronunciationStatus.incorrect }
            if !feedbackNeedsWork.isEmpty {
                print("   - Words Flagged for Remediation:")
                for item in feedbackNeedsWork {
                    let worstPhones = item.phonemes.sorted(by: { $0.score < $1.score }).prefix(2).map { "\($0.symbol):\($0.score)" }.joined(separator: ", ")
                    print("       * '\(item.word)' (\(item.overallScore)%) -> Worst Phones: [\(worstPhones)]")
                }
            }

            // 4. Fluency Metrics (Session-Wide Continuous Timeline)
            let fluencyScore = session.overallFluencyScore
            let sessionFluency = session.sessionFluency
            let allPauses = session.allPauses
            let longPauses = allPauses.filter { $0.duration >= 0.75 }
            let sessionRate = Double(sessionFluency?.sessionSpeechRate ?? sessionFluency?.speechRate ?? 0.0)
            let articRate = Double(sessionFluency?.articulationRate ?? 0.0)
            let ptr = Double(sessionFluency?.phonationTimeRatio ?? 0.0) * 100.0
            let meanRun = Double(sessionFluency?.meanLengthOfRun ?? 0.0)
            let interPauses = sessionFluency?.interTurnPauseCount ?? 0
            let intraPauses = sessionFluency?.intraTurnPauseCount ?? 0

            print("\n4. Fluency & Temporal Metrics (Unified Continuous Session):")
            print("   - Overall Fluency Score:               \(fluencyScore)%")
            print(String(format: "   - Session Speech Rate (Overall Pace):  %.2f words/sec (target: 1.4-2.5 wps)", sessionRate))
            print(String(format: "   - Burst Articulation Rate (Phonation): %.2f words/sec (target: 3.5-5.5 wps)", articRate))
            print(String(format: "   - Phonation-Time Ratio (PTR):          %.1f%% (target: 50-70%%)", ptr))
            print(String(format: "   - Mean Length of Run:                  %.1f words/run (target: >4.0)", meanRun))
            print("   - Total Pauses Detected:               \(allPauses.count) (\(interPauses) sentence/clause breaks, \(intraPauses) intra-phrase hesitations)")
            print("   - Long Pauses (>= 0.75s):              \(longPauses.count)")

            // 5. Silent Voice Profile & Base Template Matching
            let activeProf = await MainActor.run { TTSManager.shared.activeProfile }
            var profileSummary = "No Profile"
            if let prof = activeProf {
                let match = VoiceClonerNativeEngine.shared.resolveOptimalBaseVoice(
                    for: prof.timbreEmbedding,
                    estimatedF0: prof.estimatedF0,
                    dialect: .generalAmerican
                )
                profileSummary = "\(prof.sampleCount) turns | F0: \(Int(round(prof.estimatedF0))) Hz (\(prof.registerDescription)) | Auto Template: \(match.displayName) [\(match.voiceId)] (Cosine: \(String(format: "%.3f", match.cosineSimilarity)))"
            }
            print("\n5. Silent Background Learner Voice Profile:")
            print("   - \(profileSummary)")

            var drillsCount = 0
            var clipsCount = 0

            if ProcessInfo.processInfo.environment["EVAL_SKIP_COACH"] != "1" {
                // 6. Foundation Model Evaluation (AI Coach with Local Gemma 4B / Ollama)
                print("\n6. Foundation Model AI Coaching Evaluation:")
                let coachService = await MainActor.run { CoachingSessionService() }
                let tCoach0 = CFAbsoluteTimeGetCurrent()
                await coachService.startReport(record: session)
                let elapsedCoach = CFAbsoluteTimeGetCurrent() - tCoach0

                let report = await MainActor.run { coachService.reportText }
                let drills = await MainActor.run { coachService.activeDrills }
                let fluencyDrills = await MainActor.run { coachService.activeFluencyDrills }
                let clips = await MainActor.run { coachService.generatedClips }
                let coachError = await MainActor.run { coachService.reportError }

                drillsCount = drills.count
                clipsCount = clips.count

                if let err = coachError {
                    print("   [ERROR] Coach Report Failed: \(err)")
                } else {
                    print("   [COACH DIAGNOSTIC REPORT] (Generated in \(String(format: "%.2fs", elapsedCoach))):")
                    print("   -------------------------------------------------------------------------")
                    let reportLines = report.components(separatedBy: .newlines)
                    for line in reportLines.prefix(25) {
                        print("   \(line)")
                    }
                    if reportLines.count > 25 {
                        print("   ... [truncated \(reportLines.count - 25) lines] ...")
                    }
                    print("   -------------------------------------------------------------------------")

                    print("   Active Pronunciation Drills Created: \(drills.count)")
                    for d in drills {
                        print("     - Target: '\(d.targetWord)' (phone: [\(d.focusPhoneme ?? "none")]) | Sentence: \"\(d.practiceSentence)\"")
                        print("       Tip: \(d.articulatoryTip ?? "none")")
                    }

                    print("   Active Fluency Drills Created: \(fluencyDrills.count)")
                    for fd in fluencyDrills {
                        print("     - Target Phrase: \"\(fd.targetPhrase)\" | Pacing Tip: \(fd.pacingTip)")
                    }

                    print("   Corrective Golden Speaker Clips Synthesized: \(clips.count)")
                    for (word, clipURL) in clips {
                        print("     - '\(word)' -> \(clipURL.lastPathComponent)")
                    }

                    // Interactive Multi-turn Follow-up
                    let userQuery = "Which specific consonant or vowel sound was my most frequent pronunciation error in this passage, and how should I position my tongue and mouth to fix it?"
                    print("\n   [INTERACTIVE FOLLOW-UP QUERY]")
                    print("   Learner: \"\(userQuery)\"")
                    let tChat0 = CFAbsoluteTimeGetCurrent()
                    await coachService.sendUserMessage(userQuery)
                    let elapsedChat = CFAbsoluteTimeGetCurrent() - tChat0
                    let chatHistory = await MainActor.run { coachService.chatHistory }
                    if let lastReply = chatHistory.last(where: { $0.role == .coach }) {
                        print("   Coach (\(String(format: "%.2fs", elapsedChat))):")
                        print("   \"\(lastReply.text)\"")
                    }
                }
            }

            print("================================================================================\n")

            allSubjectResults.append([
                "speaker": subj.name,
                "proficiency": subj.proficiencyGroup,
                "audioDuration": audioDuration,
                "turnCount": turns.count,
                "vwer": vwer,
                "wordAccuracy": wordAccuracy,
                "flaggingPrecision": flagPrecision,
                "flaggingRecall": flagRecall,
                "flaggingF1": flagF1,
                "pronunciationScore": avgPronScore,
                "fluencyScore": fluencyScore,
                "speechRate": sessionRate,
                "articulationRate": articRate,
                "profile": profileSummary,
                "drillsCreated": drillsCount,
                "clipsSynthesized": clipsCount,
                "turns": turnRecords
            ])
        }

        print("\n================================================================================")
        print("                 EXECUTIVE MULTI-SPEAKER AUDIT REPORT                           ")
        print("================================================================================")
        print("Speaker      | Dur(s) | Turns | V-WER    | STT Acc  | Pron Score  | Fluency | F0 / Auto Template")
        print("------------------------------------------------------------------------------------------------------------------------")
        for r in allSubjectResults {
            let spk = (r["speaker"] as? String ?? "").padding(toLength: 12, withPad: " ", startingAt: 0)
            let dur = r["audioDuration"] as? Double ?? 0.0
            let turns = r["turnCount"] as? Int ?? 0
            let vwer = r["vwer"] as? Double ?? 0.0
            let acc = r["wordAccuracy"] as? Double ?? 0.0
            let pron = r["pronunciationScore"] as? Int ?? 0
            let flu = r["fluencyScore"] as? Int ?? 0
            let prof = r["profile"] as? String ?? ""
            let templatePart = prof.components(separatedBy: "Auto Template: ").last ?? prof
            let line = String(format: "%@ | %5.1fs | %5d | %7.2f%% | %7.2f%% | %10d%% | %6d%% | %@", spk, dur, turns, vwer, acc, pron, flu, templatePart)
            print(line)
        }
        print("================================================================================\n")
        exit(0)
    }
}
