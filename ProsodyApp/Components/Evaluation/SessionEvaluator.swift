import Foundation
import AVFoundation
import Speech
import FoundationModels

final class SessionEvaluator {
    let inferenceEngine: InferenceEngine
    private let sfSpeechLock = NSLock()
    
    init(inferenceEngine: InferenceEngine) {
        self.inferenceEngine = inferenceEngine
    }
    
    private func loadAudio(url: URL) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            return nil
        }
        try? file.read(into: buffer)
        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
    }
    
    private func getSFSpeechTranscriptSync(audioURL: URL) -> String {
        let auth = SFSpeechRecognizer.authorizationStatus()
        guard (auth == .authorized || auth == .notDetermined),
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            return ""
        }
        
        sfSpeechLock.lock()
        defer { sfSpeechLock.unlock() }
        
        let request = SFSpeechURLRecognitionRequest(url: audioURL)
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
        
        _ = sema.wait(timeout: .now() + 0.5)
        task.cancel()
        return finalTranscript
    }
    
    func runSessionEvaluation(datasetPath: String, sampleCount: Int = 15) {
        Task {
            await self.runSessionEvaluationAsync(datasetPath: datasetPath, sampleCount: sampleCount)
        }
    }
    
    private func runSessionEvaluationAsync(datasetPath: String, sampleCount: Int) async {
        print("\n=======================================================")
        print("   STARTING SESSION EVALUATION (15 Sequential Samples)")
        print("=======================================================\n")
        
        let manifestName = ProcessInfo.processInfo.environment["EVAL_MANIFEST_NAME"] ?? ProcessInfo.processInfo.environment["EVAL_MANIFEST"] ?? "manifest.json"
        var manifestURL = URL(fileURLWithPath: datasetPath).appendingPathComponent(manifestName)
        if !FileManager.default.fileExists(atPath: manifestURL.path) {
            let altURL = URL(fileURLWithPath: datasetPath).appendingPathComponent("speechocean").appendingPathComponent(manifestName)
            if FileManager.default.fileExists(atPath: altURL.path) {
                manifestURL = altURL
            }
        }
        guard let data = try? Data(contentsOf: manifestURL),
              let allSamples = try? JSONDecoder().decode([Evaluator.Sample].self, from: data) else {
            print("ERROR: Could not load manifest at \(manifestURL.path)")
            exit(1)
        }
        
        let selectedSamples = Array(allSamples.prefix(sampleCount))
        print("Loaded \(selectedSamples.count) samples from \(manifestURL.lastPathComponent)")
        
        let sessionPrompt = "Practice numbers, sentences and names"
        var session = SessionRecord(prompt: sessionPrompt, utterances: [])
        
        let scoringManager = PhonemeScoringManager(inferenceEngine: self.inferenceEngine)
        let baseAudioDir = manifestURL.deletingLastPathComponent()
        let ttsCacheDir = URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ProsodyApp/Dataset/speechocean_tts_cache")
        
        for (idx, sample) in selectedSamples.enumerated() {
            let audioURL = baseAudioDir.appendingPathComponent(sample.audio_path)
            guard let audioFloats = self.loadAudio(url: audioURL) else {
                print("[\(idx + 1)/\(sampleCount)] Failed to load audio at \(audioURL.path)")
                continue
            }
            
            let t0 = CFAbsoluteTimeGetCurrent()
            // 1. STT Acoustic Mirror Recognition
            let hypResult = self.inferenceEngine.processSynchronously(audioChunk: audioFloats, reference: nil)
            let snapped = hypResult?.snapped ?? ""
            let literal = hypResult?.literal ?? ""
            let transcript = snapped
            
            // 2. Align word timestamps
            var segments: [WordTimestamp] = []
            if let logProbs = hypResult?.logProbs {
                segments = CTCSegmentation.align(
                    transcript: sample.reference,
                    logProbs: logProbs,
                    vocab: self.inferenceEngine.decoder.vocab,
                    blankIndex: self.inferenceEngine.decoder.blankIndex
                )
            }
            
            // 3. Apple Speech Framework transcript
            let sfSpeechTranscript = self.getSFSpeechTranscriptSync(audioURL: audioURL)
            
            // 3b. Load TTS Cache for DTW
            let cacheFile = ttsCacheDir.appendingPathComponent("\(sample.id).bin")
            var ttsSegments: [WordTimestamp] = []
            var ttsProbs: (probs: [Float], frames: Int, vocabSize: Int)? = nil
            if let cached = Evaluator.loadTTSCache(fileURL: cacheFile) {
                ttsSegments = cached.segments
                ttsProbs = (probs: cached.probs, frames: cached.frames, vocabSize: cached.vocabSize)
            }
            
            // 4. Phoneme scoring
            let scoreResult = scoringManager.scoreAudio(
                audioFloats,
                transcript: sample.reference,
                literalTranscript: literal,
                sfSpeechTranscript: sfSpeechTranscript,
                snappedTranscript: transcript,
                userSegments: segments,
                ttsSegments: ttsSegments,
                cachedTtsProbs: ttsProbs,
                hiddenStates: hypResult?.hiddenStates,
                sttLogProbs: hypResult?.logProbs
            )
            
            // 5. Fluency evaluation
            let fluencyResult = FluencyManager.shared.evaluate(
                segments: segments,
                audioChunk: audioFloats
            )
            
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            
            let utterance = UtteranceRecord(
                transcript: transcript,
                scoringResult: scoreResult,
                fluencyResult: fluencyResult,
                wordTimestamps: segments,
                audioURL: audioURL
            )
            session.utterances.append(utterance)
            
            let pronScoreStr = scoreResult != nil ? "\(scoreResult!.overallScore)%" : "N/A"
            let fluencyScoreStr = fluencyResult != nil ? "\(fluencyResult!.overallScore)%" : "N/A"
            let rateStr = fluencyResult != nil ? String(format: "%.1fwps", fluencyResult!.speechRate) : "N/A"
            let pausesCount = fluencyResult?.pauseCount ?? 0
            
            print("[\(idx + 1)/\(sampleCount)] REF: \"\(sample.reference)\"")
            print("       HYP: \"\(transcript)\" | LIT: \"\(literal)\" | SF: \"\(sfSpeechTranscript)\"")
            if let refScores = sample.word_scores {
                let refWords = sample.reference.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
                let refChips = zip(refWords, refScores).map { "\($0): \($1)/10" }.joined(separator: ", ")
                print("       Manual GT: [\(refChips)]")
            }
            print("       Pron: \(pronScoreStr) | Fluency: \(fluencyScoreStr) (Rate: \(rateStr), Pauses: \(pausesCount)) | \(String(format: "%.2fs", elapsed))")
            if let sResult = scoreResult {
                let wordChips = sResult.scoredWords.map { "\($0.text):\($0.score)% (\($0.status == .good ? "Good" : "NeedsWork"))" }.joined(separator: ", ")
                print("       System Words: [\(wordChips)]")
                for w in sResult.scoredWords {
                    print("         -> \(w.text): \(w.diagnosticInfo)")
                }
            }
            print("-------------------------------------------------------")
        }
        
        print("\n=======================================================")
        print("               AGGREGATE SESSION RECORD                ")
        print("=======================================================")
        print("Total Utterances:           \(session.utterances.count)")
        print("Overall Pronunciation:      \(session.overallPronunciationScore)%")
        print("Overall Fluency:            \(session.overallFluencyScore)%")
        print("Total Words Evaluated:      \(session.allFeedbackItems.count)")
        print("Total Pauses Detected:      \(session.allPauses.count)")
        print("Full Session Transcript:    \"\(session.fullTranscript)\"")
        print("=======================================================\n")
        
        // MARK: - 1. Base Foundation Model Evaluation (Apple Intelligence)
        print("=======================================================")
        print("   [1/2] EVALUATING BASE FOUNDATION MODEL (APPLE INTELLIGENCE)")
        print("=======================================================\n")
        
        let isFMAvailable = await MainActor.run {
            FoundationModelManager.shared.isAvailable
        }
        let availability = await MainActor.run {
            FoundationModelManager.shared.availability
        }
        print("Apple Intelligence Availability: \(availability) (isAvailable: \(isFMAvailable))")
        
        if isFMAvailable {
            let coachServiceFM = await MainActor.run { CoachingSessionService() }
            await MainActor.run {
                STTSettings.shared.llmProvider = .appleIntelligence
            }
            
            let t0_fm = CFAbsoluteTimeGetCurrent()
            await coachServiceFM.startReport(record: session)
            let elapsed_fm = CFAbsoluteTimeGetCurrent() - t0_fm
            
            if let err = await MainActor.run(body: { coachServiceFM.reportError }) {
                print("[ERROR] Base FM Report Generation failed: \(err)")
            } else {
                let report = await MainActor.run { coachServiceFM.reportText }
                let drills = await MainActor.run { coachServiceFM.activeDrills }
                let clips = await MainActor.run { coachServiceFM.generatedClips }
                
                print("Base FM Diagnostic Report (elapsed: \(String(format: "%.2fs", elapsed_fm))):")
                print("-------------------------------------------------------")
                print(report)
                print("-------------------------------------------------------")
                print("Active Drills Created: \(drills.count)")
                for d in drills {
                    print("  - Target: '\(d.targetWord)' (contrast: \(d.contrastWord ?? "none"), phone: \(d.focusPhoneme ?? "none"))")
                    print("    Sentence: \"\(d.practiceSentence)\"")
                    print("    Tip: \(d.articulatoryTip ?? "none")")
                }
                print("Audio Clips Synthesized: \(clips.count)")
                for (word, url) in clips {
                    print("  - '\(word)' -> \(url.lastPathComponent)")
                }

                let followUpQuery = "Which sound was my biggest issue across these 15 sentences, and how should I position my tongue and mouth to fix it?"
                print("\n[Interactive Multi-Turn Chat] Asking Base FM:")
                print("\"\(followUpQuery)\"")
                let t_chat0 = CFAbsoluteTimeGetCurrent()
                await coachServiceFM.sendUserMessage(followUpQuery)
                let elapsed_chat = CFAbsoluteTimeGetCurrent() - t_chat0
                let chatHistory = await MainActor.run { coachServiceFM.chatHistory }
                if let lastReply = chatHistory.last(where: { $0.role == .coach }) {
                    print("\nBase FM Follow-up Response (\(String(format: "%.2fs", elapsed_chat))):")
                    print("-------------------------------------------------------")
                    print(lastReply.text)
                    print("-------------------------------------------------------")
                }
            }
        } else {
            print("[INFO] Apple Intelligence is not available on this device/configuration (\(availability)).")
        }
        
        // MARK: - 2. 4B Gemma Model Evaluation (Ollama / MLX)
        print("\n=======================================================")
        print("   [2/2] EVALUATING 4B GEMMA MODEL (OLLAMA / MLX)     ")
        print("=======================================================\n")
        
        let ollamaOnline = await MainActor.run {
            Task {
                await OllamaService.shared.checkConnection()
            }
        }
        _ = await ollamaOnline.value
        let isConnected = await MainActor.run { OllamaService.shared.isConnected }
        let statusDetail = await MainActor.run { OllamaService.shared.connectionDetail }
        let models = await MainActor.run { OllamaService.shared.availableModels }
        
        print("Ollama Connection: \(isConnected ? "ONLINE" : "OFFLINE") (\(statusDetail))")
        print("Available Models: \(models.map { "\($0.name) (\($0.sizeFormatted))" }.joined(separator: ", "))")
        
        if isConnected {
            let coachServiceGemma = await MainActor.run { CoachingSessionService() }
            await MainActor.run {
                STTSettings.shared.llmProvider = .ollama
                STTSettings.shared.ollamaModel = "gemma4:e4b-mlx"
            }
            print("Configured Ollama with model: gemma4:e4b-mlx")
            
            let t0_gemma = CFAbsoluteTimeGetCurrent()
            await coachServiceGemma.startReport(record: session)
            let elapsed_gemma = CFAbsoluteTimeGetCurrent() - t0_gemma
            
            if let err = await MainActor.run(body: { coachServiceGemma.reportError }) {
                print("[ERROR] Gemma 4B Report Generation failed: \(err)")
            } else {
                let report = await MainActor.run { coachServiceGemma.reportText }
                let drills = await MainActor.run { coachServiceGemma.activeDrills }
                let clips = await MainActor.run { coachServiceGemma.generatedClips }
                
                print("Gemma 4B Diagnostic Report (elapsed: \(String(format: "%.2fs", elapsed_gemma))):")
                print("-------------------------------------------------------")
                print(report)
                print("-------------------------------------------------------")
                print("Active Drills Created: \(drills.count)")
                for d in drills {
                    print("  - Target: '\(d.targetWord)' (contrast: \(d.contrastWord ?? "none"), phone: \(d.focusPhoneme ?? "none"))")
                    print("    Sentence: \"\(d.practiceSentence)\"")
                    print("    Tip: \(d.articulatoryTip ?? "none")")
                }
                print("Audio Clips Synthesized: \(clips.count)")
                for (word, url) in clips {
                    print("  - '\(word)' -> \(url.lastPathComponent)")
                }

                let followUpQuery = "Which sound was my biggest issue across these 15 sentences, and how should I position my tongue and mouth to fix it?"
                print("\n[Interactive Multi-Turn Chat] Asking Gemma 4B:")
                print("\"\(followUpQuery)\"")
                let t_chat0 = CFAbsoluteTimeGetCurrent()
                await coachServiceGemma.sendUserMessage(followUpQuery)
                let elapsed_chat = CFAbsoluteTimeGetCurrent() - t_chat0
                let chatHistory = await MainActor.run { coachServiceGemma.chatHistory }
                if let lastReply = chatHistory.last(where: { $0.role == .coach }) {
                    print("\nGemma 4B Follow-up Response (\(String(format: "%.2fs", elapsed_chat))):")
                    print("-------------------------------------------------------")
                    print(lastReply.text)
                    print("-------------------------------------------------------")
                }
            }
        } else {
            print("[ERROR] Ollama daemon is offline; cannot run Gemma 4B evaluation.")
        }
        
        print("\n=======================================================")
        print("          PIPELINE EVALUATION SUMMARY COMPLETE         ")
        print("=======================================================\n")
        exit(0)
    }
}
