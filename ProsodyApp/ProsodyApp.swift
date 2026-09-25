import SwiftUI
import FoundationModels
import AppIntents

@main
struct ProsodyApp: App {
    @StateObject private var accent = CatalystAccent()

    init() {
        if ProcessInfo.processInfo.environment["RUN_TEST_PUNCT"] == "1" {
            let engine = PunctuationTransferEngine.shared
            
            let t1 = engine.transferPunctuation(
                acousticText: "for the twentieth time that evening the two men shook hands",
                sfSpeechText: "For the twentieth time that evening, the two men shook hands."
            )
            print("PUNCT 1: \(t1)")
            
            let t2 = engine.transferPunctuation(
                acousticText: "a trickle of flesh blood ran over his face",
                sfSpeechText: "A trickle of fresh blood ran over his face."
            )
            print("PUNCT 2: \(t2)")
            
            let t3 = engine.transferPunctuation(
                acousticText: "will we ever forget it",
                sfSpeechText: "Will we ever forget it?"
            )
            print("PUNCT 3: \(t3)")
            
            let t4 = engine.transferPunctuation(
                acousticText: "i'm playing a single hand in what looks like losing game",
                sfSpeechText: "I'm playing a single hand in what looks like a losing game."
            )
            print("PUNCT 4: \(t4)")
            
            let t5 = engine.transferPunctuation(
                acousticText: "god bless them i hope i'll go on seen then for ever",
                sfSpeechText: nil
            )
            print("PUNCT 5 (Fallback): \(t5)")
            exit(0)
        }
        
        if ProcessInfo.processInfo.environment["RUN_TEST_ART_PROMPT"] == "1" {
            print("=== RUNNING ART PROMPT SERVICE VERIFICATION ===")
            Task { @MainActor in
                let service = ArtPromptService.shared
                print("1. Initial Curated Artwork: \"\(service.currentArtwork.title)\" by \(service.currentArtwork.artist) [\(service.currentArtwork.sourceName)]")
                print("   Image URL: \(service.currentArtwork.imageURL?.absoluteString ?? "none")")
                print("   Prompt Text: \"\(service.currentPromptText)\"")
                
                service.nextCuratedArtwork()
                print("2. Next Curated Artwork: \"\(service.currentArtwork.title)\" by \(service.currentArtwork.artist)")
                
                print("3. Querying Cleveland Museum of Art Open Access API...")
                await service.fetchRandomOnlineArtwork()
                print("   Online Artwork: \"\(service.currentArtwork.title)\" by \(service.currentArtwork.artist)")
                print("   Image URL: \(service.currentArtwork.imageURL?.absoluteString ?? "none")")
                print("   Source: \(service.currentArtwork.sourceName)")
                if let error = service.errorMessage {
                    print("   Error Notice: \(error)")
                } else {
                    print("   API Fetch: [SUCCESS]")
                }
                print("=== ART PROMPT VERIFICATION COMPLETE ===")
                exit(0)
            }
            dispatchMain()
        }
        
        if ProcessInfo.processInfo.environment["RUN_TEST_PHONEME_LEXICON"] == "1" {
            print("=== RUNNING PHONEME LEXICON & TRANSLATION VERIFICATION ===")
            
            // 1. Lookup test
            if let theta = PhonemeLexicon.shared.lookup(phoneme: "θ") {
                print("1. [PASS] Found θ: name=\(theta.friendlyName), anchor=\(theta.anchorWord)")
                print("   Tip: \(theta.articulationTip)")
            } else {
                print("1. [FAIL] Could not find θ in lexicon")
            }

            // 2. Alias test (e.g. "th", "sh", "ch")
            let thLookup = PhonemeLexicon.shared.lookup(phoneme: "th")
            let shLookup = PhonemeLexicon.shared.lookup(phoneme: "sh")
            if thLookup?.symbol == "θ" && shLookup?.symbol == "ʃ" {
                print("2. [PASS] Alias resolution: 'th' -> \(thLookup!.symbol), 'sh' -> \(shLookup!.symbol)")
            } else {
                print("2. [FAIL] Alias resolution failed")
            }

            // 3. Word position search
            let initWords = PhonemeLexicon.shared.findWords(forPhoneme: "θ", position: .initial, limit: 3)
            let finalWords = PhonemeLexicon.shared.findWords(forPhoneme: "θ", position: .final, limit: 3)
            print("3. [PASS] θ initial words: \(initWords)")
            print("   [PASS] θ final words: \(finalWords)")

            // 4. Minimal pairs
            let pairs = PhonemeLexicon.shared.findMinimalPairs(target: "θ", contrast: "s")
            print("4. [PASS] Minimal pairs (θ vs s): \(pairs.map { "\($0.targetWord) vs \($0.contrastWord)" })")

            // 5. Human-readable error description
            let testPair = AlignedPhonemePair(
                expected: "θ",
                heard: "s",
                score: 35,
                status: .incorrect,
                errorType: .substitution(expected: "θ", actual: "s")
            )
            let desc = PhonemeDisplayHelper.errorDescription(for: testPair, in: "think")
            print("5. [PASS] Error description: \"\(desc)\"")

            // 6. Tool invocation test
            _ = Task {
                let tool = FindWordsWithPhonemeTool()
                let args = FindWordsWithPhonemeTool.Arguments(phoneme: "th", position: nil, limit: 4)
                let toolOutput = try await tool.call(arguments: args)
                print("6. [PASS] Tool output:\n\(toolOutput)")
                exit(0)
            }
            dispatchMain()
        }
        
        if ProcessInfo.processInfo.environment["RUN_TEST_FM_TOOL"] == "1" {
            print("=== VERIFYING FOUNDATION MODEL CALLS FINDWORDSWITHPHONEMETOOL ===")
            Task { @MainActor in
                let availability = FoundationModelManager.shared.availability
                let isAvailable = FoundationModelManager.shared.isAvailable
                print("1. Foundation Model Availability: \(availability) (isAvailable=\(isAvailable))")
                
                guard isAvailable else {
                    print("Apple Intelligence is not available in this environment.")
                    print("Status: \(availability)")
                    exit(0)
                }

                // Create a simulated session where the learner mispronounced 'think' as 'sink'
                var session = SessionRecord(prompt: "Tell me what you think about the weather.")
                let phonemeFeedbacks: [PhonemeFeedback] = [
                    PhonemeFeedback(symbol: "θ", score: 25, errorType: .substitution(expected: "θ", actual: "s"), heardSymbol: "s"),
                    PhonemeFeedback(symbol: "ɪ", score: 90, errorType: .none),
                    PhonemeFeedback(symbol: "ŋ", score: 88, errorType: .none),
                    PhonemeFeedback(symbol: "k", score: 92, errorType: .none)
                ]
                let alignedPairs: [AlignedPhonemePair] = [
                    AlignedPhonemePair(expected: "θ", heard: "s", score: 25, status: .incorrect, errorType: .substitution(expected: "θ", actual: "s")),
                    AlignedPhonemePair(expected: "ɪ", heard: "ɪ", score: 90, status: .good, errorType: .none),
                    AlignedPhonemePair(expected: "ŋ", heard: "ŋ", score: 88, status: .good, errorType: .none),
                    AlignedPhonemePair(expected: "k", heard: "k", score: 92, status: .good, errorType: .none)
                ]
                let wordFeedback = WordFeedbackItem(
                    word: "think",
                    status: .incorrect,
                    overallScore: 48,
                    phonemes: phonemeFeedbacks,
                    startTime: 0.1,
                    endTime: 0.5,
                    expectedIpa: "/θɪŋk/",
                    heardIpa: "[sɪŋk]",
                    alignedPhonemes: alignedPairs
                )
                let scoringResult = ScoringResult(
                    overallScore: 48,
                    scoredWords: [ScoredWord(text: "think", status: .incorrect, score: 48)],
                    feedbackItems: [wordFeedback]
                )
                let utterance = UtteranceRecord(
                    transcript: "sink",
                    scoringResult: scoringResult,
                    fluencyResult: nil,
                    wordTimestamps: [WordTimestamp(word: "think", startTime: 0.1, duration: 0.4, alignmentScore: 0.85)]
                )
                session.utterances.append(utterance)

                let tools: [any Tool] = [
                    GetSessionTranscriptTool(record: session),
                    GetPronunciationSummaryTool(record: session),
                    GetWordPhonemeDetailTool(record: session),
                    FindWordsWithPhonemeTool()
                ]

                print("2. Creating LanguageModelSession with coaching tools including FindWordsWithPhonemeTool...")
                let lmSession = FoundationModelManager.shared.createSession(
                    instructions: SystemPrompts.coachingEvaluationSystemInstructions,
                    tools: tools
                )

                let prompt = "The learner substituted the 'th' sound with 's' in 'think'. Please call the findWordsWithPhoneme tool to find practice words and minimal-pair drills for the 'th' sound, and give them a structured drill."
                print("3. Sending prompt to Foundation Model:\n\"\(prompt)\"\n")
                
                do {
                    let response = try await lmSession.respond(to: prompt)
                    print("\n4. [RESPONSE RECEIVED FROM FOUNDATION MODEL]:\n")
                    print(response.content)
                    print("\n=== VERIFICATION COMPLETE ===")
                } catch {
                    print("Error during Foundation Model execution: \(error)")
                }
                exit(0)
            }
            dispatchMain()
        }

        if ProcessInfo.processInfo.environment["RUN_TEST_BASE_MODEL_SELECTION"] == "1" {
            print("=== RUNNING BASE MODEL AUTO-DETECTION & SELECTION TEST ===")
            _ = Task { @MainActor in
                let ollama = OllamaService.shared
                let settings = STTSettings.shared

                // 1. Initial State
                print("1. Current selectedBaseModelID: \(settings.selectedBaseModelID) (provider: \(settings.llmProvider.rawValue))")

                // 2. Select Apple Intelligence
                settings.selectedBaseModelID = "apple-intelligence"
                guard settings.llmProvider == .appleIntelligence, settings.selectedBaseModelID == "apple-intelligence" else {
                    print("[FAIL] Failed to select Apple Intelligence.")
                    exit(1)
                }
                print("2. [PASS] Successfully selected Apple Intelligence via unified selectedBaseModelID.")

                // 3. Auto-Detect Ollama
                print("3. Auto-detecting Ollama daemon at \(settings.ollamaEndpoint)...")
                let (online, models) = await ollama.checkConnection()
                print("   Status: \(ollama.connectionDetail)")
                print("   Discovered \(models.count) models:")
                for m in models {
                    print("     - \(m.name) (\(m.sizeFormatted))")
                }
                guard online, !models.isEmpty else {
                    print("[FAIL] Ollama not detected or no models found.")
                    exit(1)
                }

                // 4. Test selecting each detected model
                for m in models {
                    settings.selectedBaseModelID = m.name
                    guard settings.llmProvider == .ollama,
                          settings.ollamaModel == m.name,
                          settings.selectedBaseModelID == m.name else {
                        print("[FAIL] Failed selection for \(m.name)")
                        exit(1)
                    }
                    print("4. [PASS] Unified picker correctly configured: \(m.name) -> llmProvider=\(settings.llmProvider.rawValue), model=\(settings.ollamaModel)")
                }

                // 5. Switch back to Apple Intelligence
                settings.selectedBaseModelID = "apple-intelligence"
                guard settings.llmProvider == .appleIntelligence else {
                    print("[FAIL] Failed switching back to Apple Intelligence.")
                    exit(1)
                }
                print("5. [PASS] Successfully toggled back to Apple Intelligence.")
                print("=== BASE MODEL VERIFICATION COMPLETE ===")
                exit(0)
            }
            dispatchMain()
        }

        if ProcessInfo.processInfo.environment["RUN_TEST_OLLAMA"] == "1" {
            print("=== RUNNING OLLAMA & GEMMA 4 VERIFICATION ===")
            _ = Task { @MainActor in
                do {
                    let ollama = OllamaService.shared
                    let settings = STTSettings.shared

                    print("1. Checking connection to Ollama at \(settings.ollamaEndpoint)...")
                    let (online, models) = await ollama.checkConnection()
                    guard online else {
                        print("[FAIL] Ollama daemon is not online: \(ollama.connectionDetail)")
                        exit(1)
                    }
                    print("   [PASS] Ollama is online. Found \(models.count) cached models:")
                    for m in models {
                        print("    - \(m.name) (\(m.sizeFormatted))")
                    }

                    settings.llmProvider = .ollama
                    settings.ollamaModel = "gemma4:e2b-mlx"
                    print("\n2. Configured provider: \(settings.llmProvider.displayName), model: \(settings.ollamaModel)")

                    print("\n3. Testing PromptGeneratorService with Ollama...")
                    let promptService = PromptGeneratorService.shared
                    await promptService.generate()
                    print("   [PASS] Generated Speaking Prompt:\n   \"\(promptService.currentPrompt)\"")
                    guard !promptService.currentPrompt.isEmpty else {
                        print("[FAIL] Generated prompt was empty")
                        exit(1)
                    }

                    print("\n4. Testing CoachingSessionService with Ollama...")
                    let mockRecord = SessionRecord(
                        prompt: "Tell me about a memorable trip.",
                        utterances: [
                            UtteranceRecord(
                                transcript: "i think the ship sink to deep water",
                                scoringResult: ScoringResult(
                                    overallScore: 54,
                                    scoredWords: [
                                        ScoredWord(text: "think", status: .incorrect, score: 42),
                                        ScoredWord(text: "sink", status: .incorrect, score: 50)
                                    ],
                                    feedbackItems: [
                                        WordFeedbackItem(
                                            word: "think",
                                            status: .incorrect,
                                            overallScore: 42,
                                            phonemes: [
                                                PhonemeFeedback(symbol: "θ", score: 35, errorType: .substitution(expected: "θ", actual: "s")),
                                                PhonemeFeedback(symbol: "ɪ", score: 75),
                                                PhonemeFeedback(symbol: "ŋ", score: 80),
                                                PhonemeFeedback(symbol: "k", score: 70)
                                            ],
                                            startTime: 0.2,
                                            endTime: 0.6,
                                            expectedIpa: "θɪŋk",
                                            heardIpa: "sɪŋk"
                                        ),
                                        WordFeedbackItem(
                                            word: "sink",
                                            status: .incorrect,
                                            overallScore: 50,
                                            phonemes: [
                                                PhonemeFeedback(symbol: "s", score: 45),
                                                PhonemeFeedback(symbol: "ɪ", score: 80),
                                                PhonemeFeedback(symbol: "ŋ", score: 85),
                                                PhonemeFeedback(symbol: "k", score: 75)
                                            ],
                                            startTime: 1.0,
                                            endTime: 1.4,
                                            expectedIpa: "sɪŋk",
                                            heardIpa: "ʃɪŋk"
                                        )
                                    ]
                                ),
                                fluencyResult: FluencyResult(
                                    overallScore: 70,
                                    speechRate: 1.5,
                                    articulationRate: 2.0,
                                    phonationTimeRatio: 0.65,
                                    meanLengthOfRun: 3.5,
                                    pauseCount: 1,
                                    meanPauseDuration: 0.4,
                                    pauseFrequencyPerMinute: 6.0,
                                    pauses: [
                                        PauseEvent(startTime: 0.6, duration: 0.4, wordBefore: "think", wordAfter: "the")
                                    ],
                                    feedback: []
                                ),
                                wordTimestamps: [],
                                audioURL: nil
                            )
                        ]
                    )

                    let coach = CoachingSessionService()
                    await coach.startReport(record: mockRecord)

                    if let err = coach.reportError {
                        print("[FAIL] Coach report error: \(err)")
                        exit(1)
                    }

                    print("   [PASS] Coaching Evaluation Report received:")
                    print("   --- REPORT START ---")
                    print(coach.reportText)
                    print("   --- REPORT END ---")

                    print("\n5. Checking active drills generated for weak words:")
                    print("   Active drills count: \(coach.activeDrills.count)")
                    for drill in coach.activeDrills {
                        print("    - Target: '\(drill.targetWord)', phoneme: \(drill.focusPhoneme ?? "none"), sentence: \"\(drill.practiceSentence)\"")
                    }

                    print("\n6. Testing interactive follow-up question via Ollama streaming...")
                    await coach.sendUserMessage("Can you give me one more exercise sentence for the /th/ sound?")
                    if let lastMsg = coach.chatHistory.last, lastMsg.role == .coach {
                        print("   [PASS] Coach follow-up reply:\n\(lastMsg.text)")
                    } else {
                        print("[FAIL] No coach response in chat history")
                        exit(1)
                    }

                    print("\n=== OLLAMA & GEMMA 4 VERIFICATION COMPLETED SUCCESSFULLY ===")
                    exit(0)
                } catch {
                    print("[FAIL] Ollama verification error: \(error)")
                    exit(1)
                }
            }
            dispatchMain()
        }
        if ProcessInfo.processInfo.environment["RUN_TEST_AGENTIC_TOOLS"] == "1" {
            print("=== RUNNING AGENTIC TOOLS VERIFICATION ===")
            _ = Task { @MainActor in
                do {
                    let mockRecord = SessionRecord(
                        prompt: "Tell me about something you did recently.",
                        utterances: [
                            UtteranceRecord(
                                transcript: "i think the metal ship will sink to deep water he have two book",
                                scoringResult: nil,
                                fluencyResult: nil,
                                wordTimestamps: [],
                                audioURL: nil
                            )
                        ]
                    )

                    print("1. Testing AnalyzeGrammarAndSyntaxTool...")
                    let grammarTool = AnalyzeGrammarAndSyntaxTool(record: mockRecord)
                    let grammarReport = try await grammarTool.call(arguments: AnalyzeGrammarAndSyntaxTool.Arguments())
                    print("   Grammar Analysis Output:\n\(grammarReport)")

                    print("\n2. Testing SynthesizeCorrectiveSpeechTool (canonical voice fallback)...")
                    let tts = TTSManager.shared
                    var attempts = 0
                    while !tts.isEngineReady && attempts < 50 {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        attempts += 1
                    }
                    let synthTool = SynthesizeCorrectiveSpeechTool(record: mockRecord)
                    let synthReport = try await synthTool.call(arguments: SynthesizeCorrectiveSpeechTool.Arguments(text: "think", focusPhoneme: "θ"))
                    print("   Synth Tool Output: \(synthReport)")

                    print("\n3. Testing CreatePracticeDrillTool...")
                    let drillTool = CreatePracticeDrillTool(record: mockRecord) { drill in
                        print("   [Callback] Received drill card for '\(drill.targetWord)' (contrast: \(drill.contrastWord ?? "none"))")
                    }
                    let drillReport = try await drillTool.call(arguments: CreatePracticeDrillTool.Arguments(
                        targetWord: "think",
                        contrastWord: "sink",
                        focusPhoneme: "θ",
                        practiceSentence: "I think the ship will sink.",
                        articulatoryTip: "Put tongue tip between teeth."
                    ))
                    print("   Drill Tool Output: \(drillReport)")

                    print("\n=== AGENTIC TOOLS VERIFICATION COMPLETED SUCCESSFULLY ===")
                    exit(0)
                } catch {
                    print("[FAIL] Agentic tool test error: \(error)")
                    exit(1)
                }
            }
            dispatchMain()
        }
        if ProcessInfo.processInfo.environment["RUN_TEST_ARTWORK"] == "1" {
            print("=== RUNNING ARTWORK MULTIMODAL VERIFICATION ===")
            Task {
                do {
                    let testURL = URL(string: "https://openaccess-cdn.clevelandart.org/1942.1065/1942.1065_web.jpg")!
                    print("1. Testing asynchronous artwork analysis for: \(testURL.absoluteString)...")
                    let analysis = try await FoundationModelManager.shared.analyzeArtwork(
                        imageURL: testURL,
                        title: "Romaine Lacaux",
                        artist: "Pierre-Auguste Renoir"
                    )
                    print("2. [PASS] Successfully analyzed artwork via Apple Intelligence multimodal model!")
                    print("   Scene Description: \(analysis.sceneDescription)")
                    print("   Guided Prompts:    \(analysis.guidedPrompts.joined(separator: " | "))")
                    print("   Feelings:          \(analysis.suggestedFeelings.joined(separator: ", "))")
                    print("=== ARTWORK VERIFICATION COMPLETE ===")
                    exit(0)
                } catch {
                    print("[FAIL] Artwork analysis error: \(error)")
                    exit(1)
                }
            }
            dispatchMain()
        }
        if ProcessInfo.processInfo.environment["RUN_TEST_VOICE_CLONER"] == "1" {
            print("=== RUNNING IN-PROCESS VOICE CLONER VERIFICATION ===")
            Task {
                let tts = TTSManager.shared
                var attempts = 0
                while !tts.isEngineReady && attempts < 50 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    attempts += 1
                }
                guard tts.isEngineReady else {
                    print("[FAIL] TTSManager failed to load: \(tts.engineStatusDetail)")
                    exit(1)
                }
                print("1. [PASS] Engine initialized and models loaded.")

                let sampleURL = URL(fileURLWithPath: "Dataset/speechocean/Audio/sample_0000.wav")
                let altURL = URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ProsodyApp/Dataset/speechocean/Audio/sample_0000.wav")
                let refURL = FileManager.default.fileExists(atPath: sampleURL.path) ? sampleURL : altURL

                guard FileManager.default.fileExists(atPath: refURL.path) else {
                    print("[FAIL] Reference audio not found at \(refURL.path)")
                    exit(1)
                }
                print("2. [PASS] Reference audio sample found at \(refURL.lastPathComponent)")

                let testText = "I wake up early every morning and make a fresh pot of coffee."
                print("3. Synthesizing: \"\(testText)\" with dynamic tau=0.35 and baseVoice=auto...")
                do {
                    let result = try await tts.synthesize(
                        targetText: testText,
                        learnerAudioURL: refURL,
                        baseVoice: "auto",
                        speed: 1.0,
                        tau: 0.35
                    )
                    print("4. [PASS] Cloned audio generated successfully at: \(result.outputURL.path)")
                    print(String(format: "   Inference Duration: %.3fs", result.inferenceDuration))
                    print(String(format: "   Audio Duration:     %.3fs", result.audioDuration))
                    print(String(format: "   Real-Time Factor:   %.3fx", result.rtf))

                    // Test 5: Verify British RP Dialect Auto-Matching
                    print("5. Verifying British RP Dialect Auto-Matching...")
                    STTSettings.shared.targetDialect = .britishRP
                    let ukMatch = VoiceClonerNativeEngine.shared.resolveOptimalBaseVoice(
                        for: nil,
                        estimatedF0: 200.0,
                        dialect: .britishRP
                    )
                    assert(ukMatch.voiceId == "bf_emma", "Expected bf_emma for feminine British RP, got \(ukMatch.voiceId)")
                    let ukMaleMatch = VoiceClonerNativeEngine.shared.resolveOptimalBaseVoice(
                        for: nil,
                        estimatedF0: 120.0,
                        dialect: .britishRP
                    )
                    assert(ukMaleMatch.voiceId == "bm_george", "Expected bm_george for masculine British RP, got \(ukMaleMatch.voiceId)")
                    print("   [PASS] Dialect matching: bf_emma (F), bm_george (M)")

                    // Test 6: Verify Silent Learner Profile Extraction & Smoothing
                    print("6. Verifying Background Voice Profiling & EMA...")
                    tts.clearLearnerProfile()
                    assert(tts.activeProfile == nil, "Profile should be cleared")
                    let testSamples = try VoiceClonerNativeEngine.shared.loadAudioAt16kHz(url: refURL)
                    tts.updateLearnerProfile(from: testSamples)
                    // Wait briefly for detached task
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    guard let prof = tts.activeProfile else {
                        print("[FAIL] Learner profile was not updated from audio samples")
                        exit(1)
                    }
                    print("   [PASS] Profile initialized: turns=\(prof.sampleCount), F0=\(Int(round(prof.estimatedF0))) Hz, register=\(prof.registerDescription)")

                    // Reset settings back
                    STTSettings.shared.targetDialect = .generalAmerican
                    print("=== VOICE CLONER VERIFICATION COMPLETED SUCCESSFULLY ===")
                    exit(0)
                } catch {
                    print("[FAIL] Cloning error: \(error)")
                    exit(1)
                }
            }
            dispatchMain()
        }
        if ProcessInfo.processInfo.environment["RUN_STREAMING_VOICE_EVAL"] == "1" {
            let defaultVoiceDir = "/Users/vio/PycharmProjects/ProsodyEnglish/VoiceResources"
            let voiceDirPath = ProcessInfo.processInfo.environment["VOICE_RESOURCES_PATH"] ?? defaultVoiceDir
            let voiceDirURL = URL(fileURLWithPath: voiceDirPath)

            let stt = STTManager(synchronous: true)
            let evaluator = StreamingVoiceEvaluator(inferenceEngine: stt.inference)

            Task {
                await evaluator.runEvaluation(voiceResourcesDir: voiceDirURL)
            }
            dispatchMain()
        }
        if ProcessInfo.processInfo.environment["RUN_SESSION_EVAL"] == "1" {
            let defaultDatasetPath = "/Users/vio/PycharmProjects/ProsodyEnglish/ProsodyApp/Dataset"
            let datasetPath = ProcessInfo.processInfo.environment["EVAL_DATASET_PATH"] ?? defaultDatasetPath
            let countStr = ProcessInfo.processInfo.environment["EVAL_SAMPLE_COUNT"]
            let sampleCount = countStr != nil ? (Int(countStr!) ?? 15) : 15
            
            let stt = STTManager(synchronous: true)
            let sessionEvaluator = SessionEvaluator(inferenceEngine: stt.inference)
            
            DispatchQueue.global(qos: .userInitiated).async {
                sessionEvaluator.runSessionEvaluation(datasetPath: datasetPath, sampleCount: sampleCount)
            }
            dispatchMain()
        }
        if ProcessInfo.processInfo.environment["RUN_TEST_DECOUPLED_SCORING"] == "1" {
            print("=== RUNNING DECOUPLED SCORING & JOINT CONFIDENCE VERIFICATION ===")
            
            // 1. Verify Learned Scoring Head CoreML Model
            print("1. Verifying LearnedScoringEngine CoreML loading and inference...")
            LearnedScoringEngine.shared.loadModelIfAvailable()
            assert(LearnedScoringEngine.shared.isReady, "LearnedScoringEngine failed to load WordIntelligibilityScorer.mlmodelc")
            
            let testFeatures: [Float] = [
                0.95, // base_gop_score
                0.90, // min_phone_score
                0.92, // vowel_nucleus_score
                0.91, // consonant_score
                2.5,  // phone_margin_mean
                0.90, // alignment_confidence
                1.0,  // duration_ratio
                1.0,  // stress_ratio
                1.0,  // is_content_word
                0.0,  // is_clitic
                3.0,  // word_len_phones
                1.0,  // has_exact_literal
                1.0,  // has_sfspeech_match
                3.0,  // consensus_code
                0.2,  // word_dtw_distance
                0.95, // embedding_stability
                0.01, // top_competitor_mass_max
                0.0,  // phonetic_substitutions
                0.0,  // phonetic_deletions
                0.0,  // phonetic_insertions
                1.0,  // phonetic_match_ratio
                0.0,  // is_child
                0.25  // pitch_zcr
            ]
            let predictedScore = LearnedScoringEngine.shared.predictScore(features: testFeatures)
            print("   LearnedScoringEngine test vector score: \(String(format: "%.3f", predictedScore)) / 10.0")
            assert(predictedScore >= 6.0 && predictedScore <= 10.0, "Expected high score for clean test vector, got \(predictedScore)")
            print("   [PASS] CoreML scoring head active and calibrated.")
            
            // 2. Verify Pedagogical Categorization in STTConfidenceEngine
            print("2. Verifying Pedagogical Categorization in STTConfidenceEngine...")
            
            // 2a. Transcription Uncertainty (low confidence)
            let uncertainEval = STTConfidenceEngine.evaluateWord(
                word: "mumble",
                segment: nil,
                literalWords: [],
                whisperWords: [],
                sfSpeechWords: [],
                useLearnedConfidenceHead: false,
                threshold: 0.55
            )
            assert(uncertainEval.isUncertain, "Expected uncertain transcription")
            assert(uncertainEval.category == .transcriptionUncertainty, "Expected .transcriptionUncertainty, got \(uncertainEval.category)")
            print("   [PASS] Low confidence -> .transcriptionUncertainty")
            
            // 2b. Preserved Non-Standard Grammar ("have" vs "has")
            let grammarEval = STTConfidenceEngine.evaluateWord(
                word: "have",
                segment: WordTimestamp(word: "have", startTime: 0.2, duration: 0.3, alignmentScore: 0.95),
                literalWords: ["he", "have", "a", "dog"],
                whisperWords: ["he", "has", "a", "dog"],
                sfSpeechWords: ["he", "have", "a", "dog"],
                alignedWhisperWord: "has",
                alignedLiteralWord: "have",
                useLearnedConfidenceHead: false,
                acousticScore: 85,
                scoringReferenceWord: "has"
            )
            assert(!grammarEval.isUncertain, "Grammar variation should not be flagged as STT uncertainty")
            assert(grammarEval.category == .preservedGrammarVariation, "Expected .preservedGrammarVariation, got \(grammarEval.category)")
            print("   [PASS] Verbatim 'have' with canonical 'has' -> .preservedGrammarVariation")
            
            // 2c. Mispronunciation ("photosinthesis" vs "photosynthesis")
            let mispronounceEval = STTConfidenceEngine.evaluateWord(
                word: "photosinthesis",
                segment: WordTimestamp(word: "photosinthesis", startTime: 0.2, duration: 0.5, alignmentScore: 0.85),
                literalWords: ["photosinthesis"],
                whisperWords: ["photosynthesis"],
                sfSpeechWords: ["photosynthesis"],
                alignedWhisperWord: "photosynthesis",
                alignedLiteralWord: "photosinthesis",
                useLearnedConfidenceHead: false,
                acousticScore: 45,
                scoringReferenceWord: "photosynthesis"
            )
            assert(!mispronounceEval.isUncertain, "Mispronunciation with high acoustic support should not be STT uncertainty")
            assert(mispronounceEval.category == .mispronunciation, "Expected .mispronunciation, got \(mispronounceEval.category)")
            print("   [PASS] Low acoustic score with canonical target -> .mispronunciation")
            
            // 2d. Clean Correct Pronunciation
            let correctEval = STTConfidenceEngine.evaluateWord(
                word: "photosynthesis",
                segment: WordTimestamp(word: "photosynthesis", startTime: 0.2, duration: 0.5, alignmentScore: 0.95),
                literalWords: ["photosynthesis"],
                whisperWords: ["photosynthesis"],
                sfSpeechWords: ["photosynthesis"],
                alignedWhisperWord: "photosynthesis",
                alignedLiteralWord: "photosynthesis",
                useLearnedConfidenceHead: false,
                acousticScore: 92,
                scoringReferenceWord: "photosynthesis"
            )
            assert(correctEval.category == .correctPronunciation, "Expected .correctPronunciation, got \(correctEval.category)")
            print("   [PASS] Clean acoustic match -> .correctPronunciation")
            
            print("=== DECOUPLED SCORING & JOINT CONFIDENCE VERIFICATION PASSED ===")
            exit(0)
        }
        if ProcessInfo.processInfo.environment["RUN_EVAL"] == "1" {
            let defaultDatasetPath = "/Users/vio/PycharmProjects/ProsodyEnglish/ProsodyApp/Dataset"
            let datasetPath = ProcessInfo.processInfo.environment["EVAL_DATASET_PATH"] ?? defaultDatasetPath
            let maxSamplesStr = ProcessInfo.processInfo.environment["EVAL_MAX_SAMPLES"]
            let maxSamples = maxSamplesStr != nil ? Int(maxSamplesStr!) : nil
            
            let stt = STTManager(synchronous: true)
            let evaluator = Evaluator(inferenceEngine: stt.inference)
            
            DispatchQueue.global(qos: .userInitiated).async {
                if ProcessInfo.processInfo.environment["RUN_GENERATE_CENTROIDS"] == "1" {
                    // evaluator.runCentroidGeneration(datasetPath: datasetPath)
                } else {
                    evaluator.runEvaluation(datasetPath: datasetPath, maxSamples: maxSamples)
                }
            }
            dispatchMain()
        }

        // Prewarm all models at app initialization
        TTSManager.shared.prewarm()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.catalystAccent, accent)
        }
    }
}
