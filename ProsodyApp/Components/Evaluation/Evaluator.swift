import Foundation
import AVFoundation
import Speech

class Evaluator {
    let inferenceEngine: InferenceEngine
    private let sfSpeechLock = NSLock()
    private let nemotronLock = NSLock()
    private let logLock = NSLock()
    
    struct Sample: Codable {
        let id: String
        let audio_path: String
        let reference: String
        let word_scores: [Int]?
        let speaker: String?
        let age: Int?
        let gender: String?
        let is_child: Bool?
        let sentence_accuracy: Int?
        let sentence_fluency: Int?
        let sentence_total: Int?
        let speaker_avg_total: Double?
        let skill_level: String?
    }
    
    struct EvaluationMetricsTracker {
        var tp: Int = 0
        var fp: Int = 0
        var tn: Int = 0
        var fn: Int = 0
        var totalAbsError: Double = 0.0
        var totalSquaredError: Double = 0.0
        var totalRefScore: Double = 0.0
        var totalPredScore: Double = 0.0
        var totalEvaluatedWords: Int = 0
        var allPredScores: [Double] = []
        var allRefScores: [Double] = []
        
        mutating func add(rVal: Double, pVal: Double) {
            let isTrueError = rVal < 6.0
            let isPredError = pVal < 6.0
            if isTrueError && isPredError { tp += 1 }
            else if !isTrueError && isPredError { fp += 1 }
            else if isTrueError && !isPredError { fn += 1 }
            else { tn += 1 }
            
            totalAbsError += abs(pVal - rVal)
            totalSquaredError += (pVal - rVal) * (pVal - rVal)
            totalPredScore += pVal
            totalRefScore += rVal
            totalEvaluatedWords += 1
            allPredScores.append(pVal)
            allRefScores.append(rVal)
        }
        
        var precision: Float { tp + fp > 0 ? Float(tp) / Float(tp + fp) * 100.0 : 0.0 }
        var recall: Float { tp + fn > 0 ? Float(tp) / Float(tp + fn) * 100.0 : 0.0 }
        var fpr: Float { fp + tn > 0 ? Float(fp) / Float(fp + tn) * 100.0 : 0.0 }
        var f1: Float { precision + recall > 0 ? (2.0 * precision * recall) / (precision + recall) : 0.0 }
        var mae: Double { totalEvaluatedWords > 0 ? totalAbsError / Double(totalEvaluatedWords) : 0.0 }
        var rmse: Double { totalEvaluatedWords > 0 ? sqrt(totalSquaredError / Double(totalEvaluatedWords)) : 0.0 }
        var pearsonR: Double {
            guard totalEvaluatedWords > 1 else { return 0.0 }
            let meanPred = totalPredScore / Double(totalEvaluatedWords)
            let meanRef = totalRefScore / Double(totalEvaluatedWords)
            var num = 0.0
            var denPred = 0.0
            var denRef = 0.0
            for i in 0..<totalEvaluatedWords {
                let dP = allPredScores[i] - meanPred
                let dR = allRefScores[i] - meanRef
                num += dP * dR
                denPred += dP * dP
                denRef += dR * dR
            }
            return (denPred > 0 && denRef > 0) ? num / sqrt(denPred * denRef) : 0.0
        }
    }
    
    struct STTDiagnosticCase {
        let sampleId: String
        let speaker: String
        let age: Int
        let hypWord: String
        let refWord: String?
        let confidence: Float
        let alignScore: Float
        let ensembleScore: Float
        let literalScore: Float
        let whisperWord: String?
        let sfSpeechWord: String?
        let literalWord: String?
    }
    
    struct STTThresholdMetrics {
        var tp: Int = 0
        var fp: Int = 0
        var tn: Int = 0
        var fn: Int = 0
        
        var precision: Float { tp + fp > 0 ? Float(tp) / Float(tp + fp) * 100.0 : 0.0 }
        var recall: Float { tp + fn > 0 ? Float(tp) / Float(tp + fn) * 100.0 : 0.0 }
        var fpr: Float { fp + tn > 0 ? Float(fp) / Float(fp + tn) * 100.0 : 0.0 }
        var f1: Float { precision + recall > 0 ? (2.0 * precision * recall) / (precision + recall) : 0.0 }
    }
    
    struct STTUncertaintyTracker {
        let thresholds: [Float] = [0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70]
        var metricsByThreshold: [Float: STTThresholdMetrics] = [:]
        var totalWords: Int = 0
        var totalErrors: Int = 0
        var interceptedPronunciationFPs: Int = 0
        
        var falseNegativeCases: [STTDiagnosticCase] = []
        var falsePositiveCases: [STTDiagnosticCase] = []
        
        init() {
            for t in [Float(0.40), 0.45, 0.50, 0.55, 0.60, 0.65, 0.70] {
                metricsByThreshold[t] = STTThresholdMetrics()
            }
        }
        
        var defaultMetrics: STTThresholdMetrics {
            metricsByThreshold[STTConfidenceEngine.defaultThreshold] ?? STTThresholdMetrics()
        }
        
        var tp: Int { defaultMetrics.tp }
        var fp: Int { defaultMetrics.fp }
        var tn: Int { defaultMetrics.tn }
        var fn: Int { defaultMetrics.fn }
        var precision: Float { defaultMetrics.precision }
        var recall: Float { defaultMetrics.recall }
        var fpr: Float { defaultMetrics.fpr }
        var f1: Float { defaultMetrics.f1 }
        var errorRate: Float { totalWords > 0 ? Float(totalErrors) / Float(totalWords) * 100.0 : 0.0 }
        
        mutating func record(
            hypWord: String,
            refWord: String?,
            isActualError: Bool,
            conf: STTWordConfidence,
            sampleId: String,
            speaker: String,
            age: Int,
            whisperWord: String?,
            sfSpeechWord: String?,
            literalWord: String?
        ) {
            totalWords += 1
            if isActualError { totalErrors += 1 }
            
            for t in thresholds {
                var m = metricsByThreshold[t] ?? STTThresholdMetrics()
                let isFlagged = conf.confidence < t
                if isActualError && isFlagged {
                    m.tp += 1
                } else if !isActualError && isFlagged {
                    m.fp += 1
                } else if !isActualError && !isFlagged {
                    m.tn += 1
                } else {
                    m.fn += 1
                }
                metricsByThreshold[t] = m
            }
            
            let flaggedAtDefault = conf.confidence < STTConfidenceEngine.defaultThreshold
            if isActualError && !flaggedAtDefault && falseNegativeCases.count < 100 {
                falseNegativeCases.append(STTDiagnosticCase(
                    sampleId: sampleId,
                    speaker: speaker,
                    age: age,
                    hypWord: hypWord,
                    refWord: refWord,
                    confidence: conf.confidence,
                    alignScore: conf.alignScore,
                    ensembleScore: conf.ensembleScore,
                    literalScore: conf.literalScore,
                    whisperWord: whisperWord,
                    sfSpeechWord: sfSpeechWord,
                    literalWord: literalWord
                ))
            } else if !isActualError && conf.confidence < 0.70 && falsePositiveCases.count < 50 {
                falsePositiveCases.append(STTDiagnosticCase(
                    sampleId: sampleId,
                    speaker: speaker,
                    age: age,
                    hypWord: hypWord,
                    refWord: refWord,
                    confidence: conf.confidence,
                    alignScore: conf.alignScore,
                    ensembleScore: conf.ensembleScore,
                    literalScore: conf.literalScore,
                    whisperWord: whisperWord,
                    sfSpeechWord: sfSpeechWord,
                    literalWord: literalWord
                ))
            }
        }
    }
    
    // MARK: - Fast PropertyList TTS Caching
    struct CachedTTS: Codable {
        let segments: [WordTimestamp]
        let probs: [Float]
        let frames: Int
        let vocabSize: Int
    }
    
    static func saveTTSCache(fileURL: URL, segments: [WordTimestamp], probs: [Float], frames: Int, vocabSize: Int) {
        let item = CachedTTS(segments: segments, probs: probs, frames: frames, vocabSize: vocabSize)
        if let data = try? PropertyListEncoder().encode(item) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
    
    static func loadTTSCache(fileURL: URL) -> (segments: [WordTimestamp], probs: [Float], frames: Int, vocabSize: Int)? {
        guard let data = try? Data(contentsOf: fileURL),
              let item = try? PropertyListDecoder().decode(CachedTTS.self, from: data) else {
            return nil
        }
        return (segments: item.segments, probs: item.probs, frames: item.frames, vocabSize: item.vocabSize)
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
    
    init(inferenceEngine: InferenceEngine) {
        self.inferenceEngine = inferenceEngine
    }
    
    func runEvaluation(datasetPath: String, maxSamples: Int? = nil) {
        let manifestName = ProcessInfo.processInfo.environment["EVAL_MANIFEST_NAME"] ?? ProcessInfo.processInfo.environment["EVAL_MANIFEST"] ?? "manifest.json"
        var manifestURL = URL(fileURLWithPath: datasetPath).appendingPathComponent(manifestName)
        if !FileManager.default.fileExists(atPath: manifestURL.path) {
            let altURL = URL(fileURLWithPath: datasetPath).appendingPathComponent("speechocean").appendingPathComponent(manifestName)
            if FileManager.default.fileExists(atPath: altURL.path) {
                manifestURL = altURL
            }
        }
        guard let data = try? Data(contentsOf: manifestURL),
              var samples = try? JSONDecoder().decode([Sample].self, from: data) else {
            print("Failed to load \(manifestName) at \(manifestURL.path)")
            return
        }
        
        if let filterIndicesStr = ProcessInfo.processInfo.environment["EVAL_SAMPLE_INDICES"] {
            let indices = Set(filterIndicesStr.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
            samples = samples.enumerated().filter { indices.contains($0.offset + 1) }.map { $0.element }
        } else {
            if let startIdxStr = ProcessInfo.processInfo.environment["EVAL_START_INDEX"], let startIdx = Int(startIdxStr), startIdx < samples.count {
                samples = Array(samples.dropFirst(startIdx))
            }
            if let maxSamples = maxSamples, samples.count > maxSamples {
                samples = Array(samples.prefix(maxSamples))
            }
        }
        
        var totalErrors = 0
        var totalWords = 0
        var totalGOPScore = 0
        var evaluatedSamples = 0
        var totalFluencyScore = 0
        var evaluatedFluencySamples = 0
        
        var tp = 0
        var fp = 0
        var tn = 0
        var fn = 0
        
        var totalAbsError: Double = 0.0
        var totalSquaredError: Double = 0.0
        var totalRefScore: Double = 0.0
        var totalPredScore: Double = 0.0
        var totalEvaluatedWords = 0
        var allPredScores: [Double] = []
        var allRefScores: [Double] = []
        
        var ageTrackers: [Int: EvaluationMetricsTracker] = [:]
        var childTracker = EvaluationMetricsTracker()
        var adultTracker = EvaluationMetricsTracker()
        var bracketEarlyElementary = EvaluationMetricsTracker() // 6-8
        var bracketMiddleChildhood = EvaluationMetricsTracker() // 9-12
        var bracketAdolescents = EvaluationMetricsTracker()     // 13-15
        var bracketYoungAdults = EvaluationMetricsTracker()     // 18-25
        var bracketMatureAdults = EvaluationMetricsTracker()    // 26+
        var sttTracker = STTUncertaintyTracker()
        
        var overallFluencyTracker = EvaluationMetricsTracker()
        var childFluencyTracker = EvaluationMetricsTracker()
        var adultFluencyTracker = EvaluationMetricsTracker()
        var skillLevelTrackers: [String: EvaluationMetricsTracker] = [:]
        
        let sttEngine = ProcessInfo.processInfo.environment["EVAL_STT_ENGINE"] ?? "nemotron"
        let useNemotron = (sttEngine.lowercased() == "nemotron" || sttEngine.lowercased() == "whisperkit" || sttEngine.lowercased() == "whisper")
        
        let enableWhisperEnsemble = ProcessInfo.processInfo.environment["EVAL_WHISPER_ENSEMBLE"] == "1"
        let enableDecoupledScoring = ProcessInfo.processInfo.environment["EVAL_DECOUPLED_SCORING"] == "1"
        
        print("=== Starting Swift Native Evaluation (\(samples.count) samples) ===")
        print("STT Engine: \(useNemotron ? "Nemotron 3.5 Streaming (Core AI)" : "Acoustic Mirror (Wav2Vec2)")\(enableWhisperEnsemble ? " + Neural Ensemble" : "")\(enableDecoupledScoring ? " [Decoupled Scoring Mode]" : "")")
        
        if useNemotron || enableWhisperEnsemble {
            print("=== Initializing Nemotron Core AI ===")
            let sema = DispatchSemaphore(value: 0)
            Task {
                await NemotronSTTService.shared.initializeIfNeeded()
                sema.signal()
            }
            sema.wait()
            print("=== Nemotron Core AI Initialization Complete ===")
        }
        
        if ProcessInfo.processInfo.environment["USE_LEARNED_SCORER"] == "1" {
            self.inferenceEngine.useLearnedScoringHead = true
            LearnedScoringEngine.shared.loadModelIfAvailable()
            print("=== Using Learned Scoring Head (WordIntelligibilityScorer) ===")
        }
        
        let isExportFeatures = ProcessInfo.processInfo.environment["EXPORT_SCORING_FEATURES"] == "1"
        let exportFeaturesPath = ProcessInfo.processInfo.environment["EXPORT_FEATURES_PATH"] ?? "/Users/vio/PycharmProjects/ProsodyEnglish/ScoringHead/data/speechocean_features.csv"
        let exportFileHandle: FileHandle? = isExportFeatures ? {
            let exportURL = URL(fileURLWithPath: exportFeaturesPath)
            try? FileManager.default.createDirectory(at: exportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let header = "sample_id,speaker_id,word_index,word_text,base_gop_score,min_phone_score,vowel_nucleus_score,consonant_score,phone_margin_mean,alignment_confidence,duration_ratio,stress_ratio,is_content_word,is_clitic,word_len_phones,has_exact_literal,has_sfspeech_match,consensus_code,word_dtw_distance,embedding_stability,top_competitor_mass_max,phonetic_substitutions,phonetic_deletions,phonetic_insertions,phonetic_match_ratio,is_child,pitch_zcr,ref_score\n"
            let shouldAppend = ProcessInfo.processInfo.environment["EXPORT_APPEND"] == "1" && FileManager.default.fileExists(atPath: exportURL.path)
            if !shouldAppend {
                FileManager.default.createFile(atPath: exportURL.path, contents: header.data(using: .utf8), attributes: nil)
            }
            let handle = try? FileHandle(forWritingTo: exportURL)
            handle?.seekToEndOfFile()
            print("=== Exporting Scoring Features to: \(exportFeaturesPath) (append=\(shouldAppend)) ===")
            return handle
        }() : nil

        let isExportFluencyFeatures = ProcessInfo.processInfo.environment["EXPORT_FLUENCY_FEATURES"] == "1"
        let exportFluencyPath = ProcessInfo.processInfo.environment["EXPORT_FLUENCY_PATH"] ?? "/Users/vio/PycharmProjects/ProsodyEnglish/ScoringHead/data/speechocean_fluency_features.csv"
        let exportFluencyFileHandle: FileHandle? = isExportFluencyFeatures ? {
            let exportURL = URL(fileURLWithPath: exportFluencyPath)
            try? FileManager.default.createDirectory(at: exportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let header = "sample_id,speaker_id," + FluencyEngine.featureNames.joined(separator: ",") + ",ref_fluency_score\n"
            let shouldAppend = ProcessInfo.processInfo.environment["EXPORT_APPEND"] == "1" && FileManager.default.fileExists(atPath: exportURL.path)
            if !shouldAppend {
                FileManager.default.createFile(atPath: exportURL.path, contents: header.data(using: .utf8), attributes: nil)
            }
            let handle = try? FileHandle(forWritingTo: exportURL)
            handle?.seekToEndOfFile()
            print("=== Exporting Fluency Features to: \(exportFluencyPath) (append=\(shouldAppend)) ===")
            return handle
        }() : nil
        
        let isExportConfidence = ProcessInfo.processInfo.environment["EXPORT_CONFIDENCE"] == "1"
        let exportConfidencePath = ProcessInfo.processInfo.environment["EXPORT_CONFIDENCE_PATH"] ?? "/Users/vio/PycharmProjects/ProsodyEnglish/ScoringHead/data/speechocean_confidence_features.csv"
        let exportConfidenceFileHandle: FileHandle? = isExportConfidence ? {
            let exportURL = URL(fileURLWithPath: exportConfidencePath)
            try? FileManager.default.createDirectory(at: exportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let header = "sample_id,speaker,word_idx,word,stt_correct,align_score,ensemble_score,literal_score,composite_confidence,frame_entropy,mean_blank_prob,max_nonblank_run,blank_oscillation_rate,phonetic_match_ratio,word_length,is_function_word,is_content_word,word_duration_ms,has_whisper_match,has_sfspeech_match,consensus_veto,beam_consensus,ref_word\n"
            let shouldAppend = ProcessInfo.processInfo.environment["EXPORT_APPEND"] == "1" && FileManager.default.fileExists(atPath: exportURL.path)
            if !shouldAppend {
                FileManager.default.createFile(atPath: exportURL.path, contents: header.data(using: .utf8), attributes: nil)
            }
            let handle = try? FileHandle(forWritingTo: exportURL)
            handle?.seekToEndOfFile()
            print("=== Exporting STT Confidence Features to: \(exportConfidencePath) (append=\(shouldAppend)) ===")
            return handle
        }() : nil

        let isExportPhoneSequences = ProcessInfo.processInfo.environment["EXPORT_PHONE_SEQUENCES"] == "1"
        let exportPhoneSequencesPath = ProcessInfo.processInfo.environment["EXPORT_PHONE_SEQUENCES_PATH"] ?? "/Users/vio/PycharmProjects/ProsodyEnglish/ScoringHead/data/speechocean_phone_sequences.jsonl"
        let exportPhoneSequencesFileHandle: FileHandle? = isExportPhoneSequences ? {
            let exportURL = URL(fileURLWithPath: exportPhoneSequencesPath)
            try? FileManager.default.createDirectory(at: exportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let shouldAppend = ProcessInfo.processInfo.environment["EXPORT_APPEND"] == "1" && FileManager.default.fileExists(atPath: exportURL.path)
            if !shouldAppend {
                FileManager.default.createFile(atPath: exportURL.path, contents: Data(), attributes: nil)
            }
            let handle = try? FileHandle(forWritingTo: exportURL)
            handle?.seekToEndOfFile()
            print("=== Exporting Phone Sequences to: \(exportPhoneSequencesPath) (append=\(shouldAppend)) ===")
            return handle
        }() : nil
        
        let ttsCacheDir = URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ProsodyApp/Dataset/speechocean_tts_cache")
        try? FileManager.default.createDirectory(at: ttsCacheDir, withIntermediateDirectories: true)
        
        // Multi-worker concurrent pool with thread-safe model synchronization
        let queue = OperationQueue()
        let numWorkers = ProcessInfo.processInfo.environment["EVAL_NUM_WORKERS"].flatMap(Int.init) ?? 8
        queue.maxConcurrentOperationCount = numWorkers
        
        let baseAudioDir = manifestURL.deletingLastPathComponent()
        for (index, sample) in samples.enumerated() {
            queue.addOperation { [self] in
                autoreleasepool {
                    let scoringManager = PhonemeScoringManager(inferenceEngine: self.inferenceEngine)
                var audioURL = baseAudioDir.appendingPathComponent(sample.audio_path)
                if !FileManager.default.fileExists(atPath: audioURL.path) {
                    audioURL = URL(fileURLWithPath: datasetPath).appendingPathComponent(sample.audio_path)
                }
                guard let audioFloats = self.loadAudio(url: audioURL) else { return }
                
                let startTime = CFAbsoluteTimeGetCurrent()
                let t0 = CFAbsoluteTimeGetCurrent()
                
                // 1. Raw Acoustic Processing (Wav2Vec2) for acoustic logits and alignment
                let hypResult = self.inferenceEngine.processSynchronously(audioChunk: audioFloats, reference: nil)
                let mirrorSnapped = hypResult?.snapped ?? ""
                let literal = hypResult?.literal ?? ""
                let hypTimestamps = hypResult?.wordTimestamps ?? []
                
                var segments: [WordTimestamp] = []
                if let logProbs = hypResult?.logProbs {
                    segments = CTCSegmentation.align(
                        transcript: sample.reference,
                        logProbs: logProbs,
                        vocab: self.inferenceEngine.decoder.vocab,
                        blankIndex: self.inferenceEngine.decoder.blankIndex
                    )
                }
                
                var whisperText = ""
                if useNemotron || enableWhisperEnsemble {
                    self.nemotronLock.lock()
                    let sema = DispatchSemaphore(value: 0)
                    Task {
                        do {
                            let res = try await NemotronSTTService.shared.transcribe(audioFloats: audioFloats)
                            whisperText = res.transcript
                        } catch {
                            print("Nemotron Core AI transcribe error: \(error)")
                        }
                        sema.signal()
                    }
                    sema.wait()
                    self.nemotronLock.unlock()
                }
                
                let transcript: String
                let sfSpeechTranscript: String
                
                if useNemotron {
                    transcript = !whisperText.isEmpty ? whisperText : mirrorSnapped
                    sfSpeechTranscript = mirrorSnapped
                } else {
                    transcript = mirrorSnapped
                    sfSpeechTranscript = self.getSFSpeechTranscriptSync(audioURL: audioURL)
                }
                let t1 = CFAbsoluteTimeGetCurrent()
                let sttTime = t1 - t0
                
                let pStartTime = CFAbsoluteTimeGetCurrent()
                var scoreOutput = ""
                var wordScoresOutput = ""
                
                let sampleId = sample.id
                var ttsSegments: [WordTimestamp] = []
                var ttsProbs: (probs: [Float], frames: Int, vocabSize: Int)? = nil
                var ttsAudioFloats: [Float]? = nil
                
                let isSpeechOcean = datasetPath.lowercased().contains("speechocean")
                if isSpeechOcean {
                    let cacheFile = ttsCacheDir.appendingPathComponent("\(sampleId).bin")
                    if let cached = Evaluator.loadTTSCache(fileURL: cacheFile) {
                        ttsSegments = cached.segments
                        ttsProbs = (probs: cached.probs, frames: cached.frames, vocabSize: cached.vocabSize)
                    } else {
                        let ttsAudioURL = URL(fileURLWithPath: "/Users/vio/PycharmProjects/ProsodyEnglish/ProsodyApp/Dataset/speechocean_tts").appendingPathComponent("\(sampleId).wav")
                        ttsAudioFloats = self.loadAudio(url: ttsAudioURL)
                        let ttsHypResult = ttsAudioFloats != nil ? self.inferenceEngine.processSynchronously(audioChunk: ttsAudioFloats!, reference: sample.reference) : nil
                        if let ttsLogProbs = ttsHypResult?.logProbs {
                            ttsSegments = CTCSegmentation.align(
                                transcript: sample.reference,
                                logProbs: ttsLogProbs,
                                vocab: self.inferenceEngine.decoder.vocab,
                                blankIndex: self.inferenceEngine.decoder.blankIndex
                            )
                        }
                        if let ttsAudio = ttsAudioFloats,
                           let phonemeEngine = self.inferenceEngine.phonemeEngine,
                           let ttsLogits = self.inferenceEngine.extractPhonemeLogits(audioChunk: ttsAudio) {
                            ttsProbs = phonemeEngine.getProbabilities(from: ttsLogits)
                        }
                        if let ttsP = ttsProbs {
                            Evaluator.saveTTSCache(fileURL: cacheFile, segments: ttsSegments, probs: ttsP.probs, frames: ttsP.frames, vocabSize: ttsP.vocabSize)
                        }
                    }
                }
                
                var sampleTP = 0
                var sampleFP = 0
                var sampleTN = 0
                var sampleFN = 0
                var sampleInterceptedFP = 0
                var sampleAbsError: Double = 0.0
                var sampleSqError: Double = 0.0
                var samplePredScores: [Double] = []
                var sampleRefScores: [Double] = []
                var sampleGOP = 0
                var hasGOP = false
                var exportLines = ""
                var phoneSequenceExportLines = ""
                
                let sampleAge = sample.age ?? 25
                let sampleIsChild = sample.is_child ?? (sampleAge < 18)
                var scoringResult: ScoringResult? = nil
                
                let transcriptForEval = enableDecoupledScoring ? (!mirrorSnapped.isEmpty ? mirrorSnapped : sample.reference) : sample.reference
                let scoringReferenceForEval: String? = enableDecoupledScoring ? sample.reference : nil

                if let result = scoringManager.scoreAudio(
                    audioFloats, 
                    transcript: transcriptForEval,
                    literalTranscript: literal,
                    sfSpeechTranscript: sfSpeechTranscript,
                    snappedTranscript: transcript,
                    scoringReference: scoringReferenceForEval,
                    ttsAudio: ttsAudioFloats,
                    userSegments: segments,
                    ttsSegments: ttsSegments,
                    cachedTtsProbs: ttsProbs,
                    hiddenStates: hypResult?.hiddenStates,
                    isChild: sampleIsChild,
                    sttLogProbs: hypResult?.logProbs
                ) {
                    scoringResult = result
                    sampleGOP = result.overallScore
                    hasGOP = true
                    scoreOutput = " | Pronunciation Score: \(result.overallScore)%"
                    
                    let wordsStr = result.scoredWords.map { "\($0.text):\($0.status == .good ? "G" : "E")(\($0.score))" }.joined(separator: " ")
                    wordScoresOutput = "WORDS: \(wordsStr)\n"
                    wordScoresOutput += result.scoredWords.map { "DIAG: \($0.text) -> \($0.diagnosticInfo)" }.joined(separator: "\n")
                    
                    if let refScores = sample.word_scores, refScores.count == result.scoredWords.count {
                        for i in 0..<refScores.count {
                            let isTrueError = refScores[i] < 6
                            let isPredError = result.scoredWords[i].score < 60
                            
                            if isTrueError && isPredError { sampleTP += 1 }
                            else if !isTrueError && isPredError {
                                sampleFP += 1
                                if result.scoredWords[i].isUncertainTranscription || (result.scoredWords[i].sttConfidence ?? 1.0) < STTConfidenceEngine.defaultThreshold {
                                    sampleInterceptedFP += 1
                                }
                            }
                            else if isTrueError && !isPredError { sampleFN += 1 }
                            else { sampleTN += 1 }
                            
                            let rVal = Double(refScores[i])
                            let pVal = Double(result.scoredWords[i].score) / 10.0
                            sampleAbsError += abs(pVal - rVal)
                            sampleSqError += (pVal - rVal) * (pVal - rVal)
                            samplePredScores.append(pVal)
                            sampleRefScores.append(rVal)

                            if isExportFeatures, let feats = result.scoredWords[i].features {
                                let featStr = feats.map { String(format: "%.5f", $0) }.joined(separator: ",")
                                exportLines += "\(sample.id),\(sample.speaker ?? ""),\(i),\"\(result.scoredWords[i].text)\",\(featStr),\(refScores[i])\n"
                            }

                            if isExportPhoneSequences, i < result.feedbackItems.count {
                                let fb = result.feedbackItems[i]
                                let wordPhones: [[String: Any]] = fb.phonemes.map { p in
                                    return [
                                        "sym": p.symbol,
                                        "score": Double(p.score) / 100.0,
                                        "frames": p.frames,
                                        "p_margin": Double(p.phoneMargin),
                                        "post_margin": Double(p.posteriorMargin),
                                        "t_mass": Double(p.targetMass),
                                        "c_mass": Double(p.topCompetitorMass),
                                        "c_sym": p.topCompetitorSymbol
                                    ]
                                }
                                let record: [String: Any] = [
                                    "sample_id": sample.id,
                                    "speaker_id": sample.speaker ?? "unknown",
                                    "word_idx": i,
                                    "word": result.scoredWords[i].text,
                                    "ref_score": refScores[i],
                                    "is_child": sampleIsChild,
                                    "pitch_zcr": Double(result.scoredWords[i].features?.last ?? 0.0),
                                    "features_19": (result.scoredWords[i].features ?? []).map { Double($0) },
                                    "phones": wordPhones
                                ]
                                if let jsonData = try? JSONSerialization.data(withJSONObject: record),
                                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                                    phoneSequenceExportLines += jsonStr + "\n"
                                }
                            }
                        }
                    }
                }
                let pTime = CFAbsoluteTimeGetCurrent() - pStartTime
                let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
                
                let refWords = sample.reference.components(separatedBy: .whitespacesAndNewlines).map { DiscrepancyEngine.cleanWord($0) }.filter { !$0.isEmpty }
                let hypWords = transcript.components(separatedBy: .whitespacesAndNewlines).map { DiscrepancyEngine.cleanWord($0) }.filter { !$0.isEmpty }
                let dist = self.levenshtein(a: refWords, b: hypWords)
                
                var fluencyOutput = ""
                var sampleFluency = 0
                var hasFluency = false
                var fluencyExportLine: String? = nil
                let pitchZcr: Float = {
                    guard audioFloats.count > 1 else { return 0.0 }
                    var crossings = 0
                    for k in 1..<audioFloats.count {
                        if (audioFloats[k] >= 0 && audioFloats[k - 1] < 0) || (audioFloats[k] < 0 && audioFloats[k - 1] >= 0) {
                            crossings += 1
                        }
                    }
                    return Float(crossings) / Float(audioFloats.count)
                }()
                if let fResult = FluencyManager.shared.evaluate(segments: segments, pitchZcr: pitchZcr, audioChunk: audioFloats) {
                    sampleFluency = fResult.overallScore
                    hasFluency = true
                    fluencyOutput = " | Fluency: \(fResult.overallScore)% (Rate: \(String(format: "%.1f", fResult.speechRate)), PTR: \(String(format: "%.0f%%", fResult.phonationTimeRatio * 100)))"
                    
                    if isExportFluencyFeatures, let refFluency = sample.sentence_fluency {
                        let feats = FluencyEngine.assembleFeatureVector(
                            from: fResult,
                            wordCount: segments.count,
                            pitchZcr: pitchZcr
                        )
                        let featStr = feats.map { String(format: "%.5f", $0) }.joined(separator: ",")
                        fluencyExportLine = "\(sample.id),\(sample.speaker ?? ""),\(featStr),\(refFluency)\n"
                    }
                } else {
                    fluencyOutput = " | Fluency: N/A"
                }
                
                let literalWords = literal.components(separatedBy: .whitespacesAndNewlines).map { DiscrepancyEngine.cleanWord($0) }.filter { !$0.isEmpty }
                let sfSpeechWords = sfSpeechTranscript.components(separatedBy: .whitespacesAndNewlines).map { DiscrepancyEngine.cleanWord($0) }.filter { !$0.isEmpty }
                let whisperWords = whisperText.components(separatedBy: .whitespacesAndNewlines).map { DiscrepancyEngine.cleanWord($0) }.filter { !$0.isEmpty }
                let alignedWhisperMap = whisperWords.isEmpty ? [:] : DiscrepancyEngine.alignWords(targetWords: hypWords, streamWords: whisperWords)
                let alignedRefMap = DiscrepancyEngine.alignWords(targetWords: hypWords, streamWords: refWords)
                let alignedLitMap = DiscrepancyEngine.alignWords(targetWords: hypWords, streamWords: literalWords)
                let alignedSFMap = DiscrepancyEngine.alignWords(targetWords: hypWords, streamWords: sfSpeechWords)
                
                struct WordEvalRecord {
                    let hypWord: String
                    let refWord: String?
                    let isActualError: Bool
                    let conf: STTWordConfidence
                    let whisperWord: String?
                    let sfSpeechWord: String?
                    let literalWord: String?
                }
                var sampleWordRecords: [WordEvalRecord] = []
                var confidenceExportLines = ""
                let hypCTCFeats: [Int: CTCConfidenceFeatures.WordConfidenceFeatures]
                if let logProbs = hypResult?.logProbs, !hypTimestamps.isEmpty {
                    hypCTCFeats = CTCConfidenceFeatures.computePerWord(
                        logProbs: logProbs,
                        wordTimestamps: hypTimestamps,
                        topBeams: hypResult?.topBeams
                    )
                } else {
                    hypCTCFeats = [:]
                }
                
                for i in 0..<hypWords.count {
                    let hypWord = hypWords[i]
                    let alignedRef = alignedRefMap[i]
                    let isActualError = alignedRef == nil || !DiscrepancyEngine.matchesWord(target: hypWord, candidate: alignedRef!)
                    
                    let (matchedSeg, matchedSegIdx): (WordTimestamp?, Int?) = {
                        if i < hypTimestamps.count { return (hypTimestamps[i], i) }
                        if let idx = hypTimestamps.firstIndex(where: { DiscrepancyEngine.matchesWord(target: hypWord, candidate: $0.word) }) {
                            return (hypTimestamps[idx], idx)
                        }
                        return (nil, nil)
                    }()
                    
                    let cleanHyp = DiscrepancyEngine.cleanWord(hypWord)
                    let phoneticMatchRatio: Float = {
                        if let feats = scoringResult?.scoredWords.first(where: { DiscrepancyEngine.matchesWord(target: cleanHyp, candidate: DiscrepancyEngine.cleanWord($0.text)) })?.features, feats.count > 20 {
                            return feats[20]
                        }
                        return 0.0
                    }()
                    
                    let wordCTCFeats = matchedSegIdx.flatMap { hypCTCFeats[$0] }
                    let conf = STTConfidenceEngine.evaluateWord(
                        word: hypWord,
                        segment: matchedSeg,
                        literalWords: literalWords,
                        whisperWords: whisperWords,
                        sfSpeechWords: sfSpeechWords,
                        alignedWhisperWord: alignedWhisperMap[i],
                        alignedSFSpeechWord: alignedSFMap[i],
                        alignedLiteralWord: alignedLitMap[i],
                        phoneticMatchRatio: phoneticMatchRatio,
                        frameEntropy: wordCTCFeats?.frameEntropy,
                        meanBlankProb: wordCTCFeats?.meanBlankProb,
                        blankStability: wordCTCFeats.map { Float($0.maxNonBlankRun) },
                        blankOscillationRate: wordCTCFeats?.blankOscillationRate,
                        beamConsensus: wordCTCFeats?.beamConsensus,
                        useLearnedConfidenceHead: self.inferenceEngine.useLearnedConfidenceHead
                    )
                    
                    if isExportConfidence {
                        let isFuncWord = STTConfidenceEngine.functionAndSightWords.contains(cleanHyp)
                        let hasWhisperMatch = alignedWhisperMap[i] != nil && DiscrepancyEngine.matchesWord(target: cleanHyp, candidate: DiscrepancyEngine.cleanWord(alignedWhisperMap[i]!))
                        let hasSFMatch = alignedSFMap[i] != nil && DiscrepancyEngine.matchesWord(target: cleanHyp, candidate: DiscrepancyEngine.cleanWord(alignedSFMap[i]!))
                        
                        let alternativeConsensusAgrees: Bool = {
                            guard let w = alignedWhisperMap[i], let s = alignedSFMap[i] else { return false }
                            let cW = DiscrepancyEngine.cleanWord(w)
                            let cS = DiscrepancyEngine.cleanWord(s)
                            guard !cW.isEmpty && !cS.isEmpty else { return false }
                            return (DiscrepancyEngine.matchesWord(target: cW, candidate: cS) || DiscrepancyEngine.matchesWordMorphologically(target: cW, candidate: cS)) &&
                                   !DiscrepancyEngine.matchesWord(target: cleanHyp, candidate: cW)
                        }()
                        
                        let durMs = (matchedSeg?.duration ?? 0.0) * 1000.0
                        let safeRef = (alignedRef ?? "").replacingOccurrences(of: "\"", with: "'")
                        let bConsensus = conf.beamConsensus ?? 1.0
                        
                        confidenceExportLines += "\(sample.id),\(sample.speaker ?? "unknown"),\(i),\"\(hypWord)\",\(isActualError ? 0 : 1),\(String(format: "%.4f", conf.alignScore)),\(String(format: "%.4f", conf.ensembleScore)),\(String(format: "%.4f", conf.literalScore)),\(String(format: "%.4f", conf.confidence)),\(String(format: "%.4f", conf.frameEntropy ?? 0.0)),\(String(format: "%.4f", conf.meanBlankProb ?? 0.0)),\(Int(conf.blankStability ?? 0.0)),\(String(format: "%.4f", conf.blankOscillationRate ?? 0.0)),\(String(format: "%.4f", phoneticMatchRatio)),\(cleanHyp.count),\(isFuncWord ? 1 : 0),\(isFuncWord ? 0 : 1),\(String(format: "%.1f", durMs)),\(hasWhisperMatch ? 1 : 0),\(hasSFMatch ? 1 : 0),\(alternativeConsensusAgrees ? 1 : 0),\(String(format: "%.4f", bConsensus)),\"\(safeRef)\"\n"
                    }
                    
                    sampleWordRecords.append(WordEvalRecord(
                        hypWord: hypWord,
                        refWord: alignedRef,
                        isActualError: isActualError,
                        conf: conf,
                        whisperWord: alignedWhisperMap[i],
                        sfSpeechWord: alignedSFMap[i],
                        literalWord: alignedLitMap[i]
                    ))
                }
                
                // Synchronized output and metric accumulation
                self.logLock.lock()
                defer { self.logLock.unlock() }
                
                for r in sampleWordRecords {
                    sttTracker.record(
                        hypWord: r.hypWord,
                        refWord: r.refWord,
                        isActualError: r.isActualError,
                        conf: r.conf,
                        sampleId: sample.id,
                        speaker: sample.speaker ?? "unknown",
                        age: sampleAge,
                        whisperWord: r.whisperWord,
                        sfSpeechWord: r.sfSpeechWord,
                        literalWord: r.literalWord
                    )
                }
                sttTracker.interceptedPronunciationFPs += sampleInterceptedFP
                
                if !exportLines.isEmpty, let handle = exportFileHandle {
                    if let data = exportLines.data(using: .utf8) {
                        handle.write(data)
                    }
                }
                
                if let fLine = fluencyExportLine, let fHandle = exportFluencyFileHandle {
                    if let data = fLine.data(using: .utf8) {
                        fHandle.write(data)
                    }
                }
                
                if !confidenceExportLines.isEmpty, let cHandle = exportConfidenceFileHandle {
                    if let data = confidenceExportLines.data(using: .utf8) {
                        cHandle.write(data)
                    }
                }

                if !phoneSequenceExportLines.isEmpty, let psHandle = exportPhoneSequencesFileHandle {
                    if let data = phoneSequenceExportLines.data(using: .utf8) {
                        psHandle.write(data)
                    }
                }
                
                totalErrors += dist
                totalWords += refWords.count
                if hasGOP {
                    totalGOPScore += sampleGOP
                    evaluatedSamples += 1
                }
                if hasFluency {
                    totalFluencyScore += sampleFluency
                    evaluatedFluencySamples += 1
                    
                    if let refF = sample.sentence_fluency {
                        let pF = Double(sampleFluency) / 10.0
                        let rF = Double(refF)
                        overallFluencyTracker.add(rVal: rF, pVal: pF)
                        if sampleIsChild {
                            childFluencyTracker.add(rVal: rF, pVal: pF)
                        } else {
                            adultFluencyTracker.add(rVal: rF, pVal: pF)
                        }
                    }
                }

                tp += sampleTP
                fp += sampleFP
                tn += sampleTN
                fn += sampleFN
                totalAbsError += sampleAbsError
                totalSquaredError += sampleSqError
                totalEvaluatedWords += samplePredScores.count
                for p in samplePredScores { totalPredScore += p }
                for r in sampleRefScores { totalRefScore += r }
                allPredScores.append(contentsOf: samplePredScores)
                allRefScores.append(contentsOf: sampleRefScores)
                
                for (rVal, pVal) in zip(sampleRefScores, samplePredScores) {
                    var aTracker = ageTrackers[sampleAge] ?? EvaluationMetricsTracker()
                    aTracker.add(rVal: rVal, pVal: pVal)
                    ageTrackers[sampleAge] = aTracker
                    
                    if sampleIsChild {
                        childTracker.add(rVal: rVal, pVal: pVal)
                    } else {
                        adultTracker.add(rVal: rVal, pVal: pVal)
                    }
                    
                    if sampleAge >= 6 && sampleAge <= 8 {
                        bracketEarlyElementary.add(rVal: rVal, pVal: pVal)
                    } else if sampleAge >= 9 && sampleAge <= 12 {
                        bracketMiddleChildhood.add(rVal: rVal, pVal: pVal)
                    } else if sampleAge >= 13 && sampleAge <= 15 {
                        bracketAdolescents.add(rVal: rVal, pVal: pVal)
                    } else if sampleAge >= 18 && sampleAge <= 25 {
                        bracketYoungAdults.add(rVal: rVal, pVal: pVal)
                    } else if sampleAge >= 26 {
                        bracketMatureAdults.add(rVal: rVal, pVal: pVal)
                    }
                    
                    if let tier = sample.skill_level, !tier.isEmpty {
                        var sTracker = skillLevelTrackers[tier] ?? EvaluationMetricsTracker()
                        sTracker.add(rVal: rVal, pVal: pVal)
                        skillLevelTrackers[tier] = sTracker
                    }
                }
                
                var logChunk = "Sample \(index + 1)/\(samples.count) | Total: \(String(format: "%.2fs", timeElapsed)) | STT: \(String(format: "%.2fs", sttTime)) | Score: \(String(format: "%.2fs", pTime))\n"
                if let spk = sample.speaker {
                    logChunk += "SPK: \(spk) | Age: \(sample.age ?? 0) | Tier: \(sample.skill_level ?? "-") (Avg: \(String(format: "%.2f", sample.speaker_avg_total ?? 0.0)))\n"
                }
                logChunk += "REF: \(sample.reference)\n"
                logChunk += "HYP: \(transcript)\n"
                logChunk += "LIT: \(literal)\n"
                logChunk += "ERR: \(dist) | WER: \(String(format: "%.2f", Float(totalErrors) / Float(max(totalWords, 1)) * 100))%\(scoreOutput)\(fluencyOutput)\n"
                if !wordScoresOutput.isEmpty {
                    logChunk += wordScoresOutput + "\n"
                }
                logChunk += "--------------------------------------------------"
                print(logChunk)
                fflush(stdout)
                }
            }
        }
        
        queue.waitUntilAllOperationsAreFinished()
        
        if let handle = exportFileHandle {
            try? handle.close()
            print("=== Finished writing features to \(exportFeaturesPath) ===")
        }
        
        if let fHandle = exportFluencyFileHandle {
            try? fHandle.close()
            print("=== Finished writing fluency features to \(exportFluencyPath) ===")
        }
        
        let finalWER = Float(totalErrors) / Float(max(totalWords, 1)) * 100
        let avgGOP = evaluatedSamples > 0 ? Float(totalGOPScore) / Float(evaluatedSamples) : 0
        let avgFluency = evaluatedFluencySamples > 0 ? Float(totalFluencyScore) / Float(evaluatedFluencySamples) : 0
        print("=== EVALUATION COMPLETE ===")
        print("STT Engine: \(useNemotron ? "Nemotron 3.5 Streaming (Core AI)" : "Acoustic Mirror (Wav2Vec2)")")
        print("Total Errors: \(totalErrors)")
        print("Total Words: \(totalWords)")
        print("Final V-WER: \(String(format: "%.2f", finalWER))%")
        print("Average Pronunciation Score: \(String(format: "%.1f", avgGOP))% (over \(evaluatedSamples) samples)")
        print("Average Fluency Score: \(String(format: "%.1f", avgFluency))% (over \(evaluatedFluencySamples) samples)")
        
        if overallFluencyTracker.totalEvaluatedWords > 0 {
            print("\n=== FLUENCY BASELINE EVALUATION (Ground Truth: sentence_fluency 0-10) ===")
            print("Samples Evaluated with Fluency Label: \(overallFluencyTracker.totalEvaluatedWords)")
            print(String(format: "Overall Pearson r: %.3f", overallFluencyTracker.pearsonR))
            print(String(format: "Overall MAE:       %.3f", overallFluencyTracker.mae))
            print(String(format: "Overall RMSE:      %.3f", overallFluencyTracker.rmse))
            print(String(format: "Adults Pearson r:  %.3f (MAE: %.3f, N: %d)", adultFluencyTracker.pearsonR, adultFluencyTracker.mae, adultFluencyTracker.totalEvaluatedWords))
            print(String(format: "Children Pearson r: %.3f (MAE: %.3f, N: %d)", childFluencyTracker.pearsonR, childFluencyTracker.mae, childFluencyTracker.totalEvaluatedWords))
        }
        
        print("\n=== STT UNCERTAINTY DETECTION BENCHMARK (Default Threshold: \(String(format: "%.2f", STTConfidenceEngine.defaultThreshold))) ===")
        print("Total Words Evaluated: \(sttTracker.totalWords)")
        print("Actual STT Error Words: \(sttTracker.tp + sttTracker.fn) (\(String(format: "%.2f", sttTracker.errorRate))%)")
        print("STT Errors Correctly Flagged (TP): \(sttTracker.tp)")
        print("Clean Words Correctly Passed (TN): \(sttTracker.tn)")
        print("Clean Words Falsely Flagged (FP): \(sttTracker.fp)")
        print("STT Errors Missed (FN): \(sttTracker.fn)")
        print("Detection Precision: \(String(format: "%.2f", sttTracker.precision))%")
        print("Detection Recall: \(String(format: "%.2f", sttTracker.recall))%")
        print("Detection FPR (False Alarm on Clean): \(String(format: "%.2f", sttTracker.fpr))%")
        print("Detection F1-Score: \(String(format: "%.2f", sttTracker.f1))%")
        print("Downstream Pronunciation FPs Intercepted: \(sttTracker.interceptedPronunciationFPs)")
        
        print("\n--- THRESHOLD SWEEP ANALYSIS ---")
        print("Threshold | Precision | Recall  | FPR     | F1-Score | TP  | FP  | FN  | TN  ")
        print("--------------------------------------------------------------------------------")
        for t in sttTracker.thresholds.sorted() {
            if let m = sttTracker.metricsByThreshold[t] {
                let pStr = String(format: "%6.2f%%", m.precision)
                let rStr = String(format: "%6.2f%%", m.recall)
                let fprStr = String(format: "%6.2f%%", m.fpr)
                let f1Str = String(format: "%6.2f%%", m.f1)
                let tStr = String(format: "  %.2f   ", t)
                let counts = String(format: "| %3d | %3d | %3d | %3d", m.tp, m.fp, m.fn, m.tn)
                print("\(tStr) | \(pStr) | \(rStr) | \(fprStr) | \(f1Str) \(counts)")
            }
        }
        print("--------------------------------------------------------------------------------")
        
        if !sttTracker.falseNegativeCases.isEmpty {
            print("\n--- DIAGNOSTIC: MISSED STT ERRORS (Sorted by Conf Ascending) [Showing up to 25 of \(sttTracker.falseNegativeCases.count)] ---")
            for (idx, c) in sttTracker.falseNegativeCases.sorted(by: { $0.confidence < $1.confidence }).prefix(25).enumerated() {
                let ref = c.refWord ?? "<none>"
                let whis = c.whisperWord ?? "<none>"
                let sf = c.sfSpeechWord ?? "<none>"
                let lit = c.literalWord ?? "<none>"
                print("[\(idx + 1)] Spk:\(c.speaker)(Age \(c.age)) | Hyp:\"\(c.hypWord)\" != Ref:\"\(ref)\" | Conf:\(String(format: "%.2f", c.confidence)) [Align:\(String(format: "%.2f", c.alignScore)), Ens:\(String(format: "%.2f", c.ensembleScore)), Lit:\(String(format: "%.2f", c.literalScore))] | Whis:\"\(whis)\", SF:\"\(sf)\", Lit:\"\(lit)\"")
            }
        }
        
        if !sttTracker.falsePositiveCases.isEmpty {
            print("\n--- DIAGNOSTIC: ALL CLEAN WORDS FALSELY FLAGGED (< 0.70) [Count: \(sttTracker.falsePositiveCases.count)] ---")
            for (idx, c) in sttTracker.falsePositiveCases.sorted(by: { $0.confidence < $1.confidence }).enumerated() {
                let whis = c.whisperWord ?? "<none>"
                let sf = c.sfSpeechWord ?? "<none>"
                let lit = c.literalWord ?? "<none>"
                let status = c.confidence < 0.50 ? "FP@0.50" : (c.confidence < 0.65 ? "FP@0.65" : "FP@0.70")
                print("[\(idx + 1)] [\(status)] Spk:\(c.speaker)(Age \(c.age)) | Word:\"\(c.hypWord)\" (Clean) | Conf:\(String(format: "%.2f", c.confidence)) [Align:\(String(format: "%.2f", c.alignScore)), Ens:\(String(format: "%.2f", c.ensembleScore)), Lit:\(String(format: "%.2f", c.literalScore))] | Whis:\"\(whis)\", SF:\"\(sf)\", Lit:\"\(lit)\"")
            }
        }
        
        let precision = tp + fp > 0 ? Float(tp) / Float(tp + fp) * 100 : 0
        let recall = tp + fn > 0 ? Float(tp) / Float(tp + fn) * 100 : 0
        let fpr = fp + tn > 0 ? Float(fp) / Float(fp + tn) * 100 : 0
        
        print("\n=== PRONUNCIATION SCORING METRICS ===")
        print("True Positives: \(tp) (Errors correctly caught)")
        print("False Positives: \(fp) (Valid words wrongly flagged)")
        print("False Negatives: \(fn) (Errors missed)")
        print("True Negatives: \(tn) (Valid words passed)")
        print("Precision: \(String(format: "%.2f", precision))%")
        print("Recall: \(String(format: "%.2f", recall))%")
        print("False Positive Rate (FPR): \(String(format: "%.2f", fpr))%")
        let f1 = precision + recall > 0 ? (2 * precision * recall) / (precision + recall) : 0
        print("F1-Score: \(String(format: "%.2f", f1))%")
        
        let mae = totalEvaluatedWords > 0 ? totalAbsError / Double(totalEvaluatedWords) : 0.0
        let rmse = totalEvaluatedWords > 0 ? sqrt(totalSquaredError / Double(totalEvaluatedWords)) : 0.0
        var pearsonR = 0.0
        if totalEvaluatedWords > 1 {
            let meanPred = totalPredScore / Double(totalEvaluatedWords)
            let meanRef = totalRefScore / Double(totalEvaluatedWords)
            var num = 0.0
            var denPred = 0.0
            var denRef = 0.0
            for i in 0..<totalEvaluatedWords {
                let dP = allPredScores[i] - meanPred
                let dR = allRefScores[i] - meanRef
                num += dP * dR
                denPred += dP * dP
                denRef += dR * dR
            }
            if denPred > 0 && denRef > 0 {
                pearsonR = num / sqrt(denPred * denRef)
            }
        }
        print("=== CONTINUOUS CALIBRATION METRICS (0-10 Scale) ===")
        print("Total Evaluated Words: \(totalEvaluatedWords)")
        print("Mean Absolute Error (MAE): \(String(format: "%.3f", mae))")
        print("Root Mean Squared Error (RMSE): \(String(format: "%.3f", rmse))")
        print("Pearson Correlation (r): \(String(format: "%.3f", pearsonR))")
        
        func printCohortRow(name: String, tracker: EvaluationMetricsTracker) {
            print("\n--- \(name) (Words: \(tracker.totalEvaluatedWords)) ---")
            print("  MAE: \(String(format: "%.3f", tracker.mae)) | RMSE: \(String(format: "%.3f", tracker.rmse)) | Pearson r: \(String(format: "%.3f", tracker.pearsonR))")
            print("  Precision: \(String(format: "%.2f%%", tracker.precision)) | Recall: \(String(format: "%.2f%%", tracker.recall)) | FPR: \(String(format: "%.2f%%", tracker.fpr)) | F1: \(String(format: "%.2f%%", tracker.f1))")
            print("  Confusion: TP=\(tracker.tp), FP=\(tracker.fp), FN=\(tracker.fn), TN=\(tracker.tn)")
        }
        
        print("\n=== HIGH-LEVEL COHORT BREAKDOWN ===")
        printCohortRow(name: "Children Cohort (Ages 6-15)", tracker: childTracker)
        printCohortRow(name: "Adult Cohort (Ages 18+)", tracker: adultTracker)
        
        print("\n=== DEVELOPMENTAL AGE BRACKET BREAKDOWN ===")
        printCohortRow(name: "Early Elementary (Ages 6-8)", tracker: bracketEarlyElementary)
        printCohortRow(name: "Middle Childhood (Ages 9-12)", tracker: bracketMiddleChildhood)
        printCohortRow(name: "Adolescents (Ages 13-15)", tracker: bracketAdolescents)
        printCohortRow(name: "Young Adults (Ages 18-25)", tracker: bracketYoungAdults)
        printCohortRow(name: "Mature Adults (Ages 26+)", tracker: bracketMatureAdults)
        
        func pad(_ s: String, _ width: Int) -> String {
            s.padding(toLength: width, withPad: " ", startingAt: 0)
        }
        
        print("\n=== DETAILED PER-AGE BREAKDOWN ===")
        let sep = String(repeating: "-", count: 105)
        print(sep)
        print("\(pad("Age", 5)) | \(pad("Words", 6)) | \(pad("MAE", 6)) | \(pad("RMSE", 6)) | \(pad("Pearson r", 9)) | \(pad("Precision", 9)) | \(pad("Recall", 7)) | \(pad("FPR", 6)) | \(pad("F1", 8)) | \(pad("TP/FP/FN/TN", 15))")
        print(sep)
        for age in ageTrackers.keys.sorted() {
            if let t = ageTrackers[age] {
                let confStr = "\(t.tp)/\(t.fp)/\(t.fn)/\(t.tn)"
                let row = "\(pad("\(age)", 5)) | \(pad("\(t.totalEvaluatedWords)", 6)) | \(pad(String(format: "%.3f", t.mae), 6)) | \(pad(String(format: "%.3f", t.rmse), 6)) | \(pad(String(format: "%.3f", t.pearsonR), 9)) | \(pad(String(format: "%.2f%%", t.precision), 9)) | \(pad(String(format: "%.2f%%", t.recall), 7)) | \(pad(String(format: "%.2f%%", t.fpr), 6)) | \(pad(String(format: "%.2f%%", t.f1), 8)) | \(pad(confStr, 15))"
                print(row)
            }
        }
        print(sep)
        
        if !skillLevelTrackers.isEmpty {
            print("\n=== SKILL LEVEL / L1 LANGUAGE BREAKDOWN ===")
            print(sep)
            print("\(pad("Tier/L1", 16)) | \(pad("Words", 6)) | \(pad("MAE", 6)) | \(pad("RMSE", 6)) | \(pad("Pearson r", 9)) | \(pad("Precision", 9)) | \(pad("Recall", 7)) | \(pad("FPR", 6)) | \(pad("F1", 8)) | \(pad("TP/FP/FN/TN", 15))")
            print(sep)
            for tier in skillLevelTrackers.keys.sorted() {
                if let t = skillLevelTrackers[tier] {
                    let confStr = "\(t.tp)/\(t.fp)/\(t.fn)/\(t.tn)"
                    let row = "\(pad(tier, 16)) | \(pad("\(t.totalEvaluatedWords)", 6)) | \(pad(String(format: "%.3f", t.mae), 6)) | \(pad(String(format: "%.3f", t.rmse), 6)) | \(pad(String(format: "%.3f", t.pearsonR), 9)) | \(pad(String(format: "%.2f%%", t.precision), 9)) | \(pad(String(format: "%.2f%%", t.recall), 7)) | \(pad(String(format: "%.2f%%", t.fpr), 6)) | \(pad(String(format: "%.2f%%", t.f1), 8)) | \(pad(confStr, 15))"
                    print(row)
                }
            }
            print(sep)
        }
        
        exit(0)
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
    
    private func levenshtein(a: [String], b: [String]) -> Int {
        let aLen = a.count
        let bLen = b.count
        if aLen == 0 { return bLen }
        if bLen == 0 { return aLen }
        
        var dist = Array(repeating: Array(repeating: 0, count: bLen + 1), count: aLen + 1)
        
        for i in 0...aLen { dist[i][0] = i }
        for j in 0...bLen { dist[0][j] = j }
        
        for i in 1...aLen {
            for j in 1...bLen {
                let w1 = a[i - 1]
                let w2 = b[j - 1]
                let isEquiv = DiscrepancyEngine.isWordEquivalent(w1, w2)
                let cost = isEquiv ? 0 : 1
                
                var best = min(
                    dist[i - 1][j] + 1,      // deletion
                    dist[i][j - 1] + 1,      // insertion
                    dist[i - 1][j - 1] + cost // substitution
                )
                
                // 1-to-2 match: a has single compound (e.g. "forever"), b has 2 parts ("for", "ever")
                if j >= 2 && DiscrepancyEngine.isCompoundMatch(single: w1, part1: b[j - 2], part2: w2) {
                    best = min(best, dist[i - 1][j - 2])
                }
                
                // 2-to-1 match: a has 2 parts ("for", "ever"), b has single compound ("forever")
                if i >= 2 && DiscrepancyEngine.isCompoundMatch(single: w2, part1: a[i - 2], part2: w1) {
                    best = min(best, dist[i - 2][j - 1])
                }
                
                dist[i][j] = best
            }
        }
        return dist[aLen][bLen]
    }
    
}