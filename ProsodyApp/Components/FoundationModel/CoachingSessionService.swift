import Foundation
import Combine
import FoundationModels

// MARK: - Chat Message Model

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: ChatRole
    var text: String
    var isStreaming: Bool = false
}

enum ChatRole {
    case coach
    case user
}

// MARK: - CoachingSessionService

/// Manages the post-session AI coaching interaction.
///
/// Lifecycle:
///   1. After the user finishes recording, call `startReport(record:)`.
///   2. The initial coach report streams into `reportText`.
///   3. The user can ask follow-up questions via `sendUserMessage(_:)`.
///   4. The same `LanguageModelSession` is reused for the chat, preserving
///      full conversation history and all tool access.
///
/// The session is discarded when the user leaves the coaching view.
@MainActor
final class CoachingSessionService: ObservableObject {

    // MARK: - Published State

    @Published var reportText: String = ""
    @Published var isGeneratingReport: Bool = false
    @Published var reportError: String? = nil

    @Published var chatHistory: [ChatMessage] = []
    @Published var isGeneratingReply: Bool = false
    @Published var sessionRecord: SessionRecord? = nil

    /// Interactive drill cards created dynamically by the coach.
    @Published var activeDrills: [InteractiveDrillCard] = []

    /// Interactive fluency & rhythm drill cards created dynamically by the coach.
    @Published var activeFluencyDrills: [FluencyDrillCard] = []

    /// Audio clips synthesized by the coach (keyed by target text).
    @Published var generatedClips: [String: URL] = [:]

    // MARK: - Private

    private var coachSession: LanguageModelSession? = nil
    private var ollamaChatMessages: [(role: String, content: String)] = []

    // MARK: - Report Generation

    /// Starts a new coaching session for the given `SessionRecord`.
    /// Routes between Apple Intelligence Foundation Models and local Ollama based on user settings.
    func startReport(record: SessionRecord) async {
        sessionRecord = record
        reportText = ""
        chatHistory = []
        activeDrills = []
        activeFluencyDrills = []
        generatedClips = [:]
        ollamaChatMessages = []
        reportError = nil
        isGeneratingReport = true

        let provider = STTSettings.shared.llmProvider

        switch provider {
        case .appleIntelligence:
            guard FoundationModelManager.shared.isAvailable else {
                reportError = "Apple Intelligence is not available on this device or region."
                isGeneratingReport = false
                return
            }

            let tools: [any Tool] = [
                GetSessionTranscriptTool(record: record),
                GetPronunciationSummaryTool(record: record),
                GetWordPhonemeDetailTool(record: record),
                FindWordsWithPhonemeTool(),
                GetFluencyMetricsTool(record: record),
                GetPauseDetailTool(record: record),
                GetWordTimingsTool(record: record),
                SynthesizeCorrectiveSpeechTool(record: record) { [weak self] word, url in
                    Task { @MainActor [weak self] in
                        self?.generatedClips[word.lowercased()] = url
                    }
                },
                CreatePracticeDrillTool(record: record) { [weak self] drill in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        if let idx = self.activeDrills.firstIndex(where: { $0.targetWord.lowercased() == drill.targetWord.lowercased() }) {
                            self.activeDrills[idx] = drill
                        } else {
                            self.activeDrills.append(drill)
                        }
                    }
                },
                CreateFluencyDrillTool(record: record) { [weak self] drill in
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        if let idx = self.activeFluencyDrills.firstIndex(where: { $0.targetPhrase == drill.targetPhrase }) {
                            self.activeFluencyDrills[idx] = drill
                        } else {
                            self.activeFluencyDrills.append(drill)
                        }
                    }
                },
                GetDisfluencyReportTool(record: record),
                AnalyzeGrammarAndSyntaxTool(record: record)
            ]

            let session = FoundationModelManager.shared.createSession(
                instructions: SystemPrompts.coachingEvaluationSystemInstructions,
                tools: tools
            )
            coachSession = session

            let initialPrompt = SystemPrompts.coachingInitialEvaluationInput(prompt: record.prompt)

            do {
                let stream = session.streamResponse(to: initialPrompt)
                for try await snapshot in stream {
                    reportText = snapshot.content
                }
                chatHistory.append(ChatMessage(role: .coach, text: reportText))
            } catch {
                reportError = error.localizedDescription
            }

        case .ollama:
            // 1. Automatically generate Interactive Practice Drills & Golden Speaker synthesis for words scoring below remediation threshold
            let drillCutoff = STTSettings.shared.drillThreshold
            let weakItems = record.allFeedbackItems.filter { $0.overallScore < drillCutoff }
            var seenWords = Set<String>()
            var uniqueWeakItems: [WordFeedbackItem] = []
            for item in weakItems {
                let lower = item.word.lowercased()
                if !seenWords.contains(lower) {
                    seenWords.insert(lower)
                    uniqueWeakItems.append(item)
                }
            }
            let targetItems = Array(uniqueWeakItems.sorted(by: { $0.overallScore < $1.overallScore }).prefix(2))

            for item in targetItems {
                let worstPhoneme = item.phonemes.sorted(by: { $0.score < $1.score }).first
                let focusPhone = worstPhoneme?.symbol ?? ""
                let drill = InteractiveDrillCard(
                    targetWord: item.word,
                    contrastWord: nil,
                    focusPhoneme: focusPhone.isEmpty ? nil : focusPhone,
                    practiceSentence: "Practice repeating '\(item.word)' with clear articulation.",
                    articulatoryTip: "Focus on articulating the target sound clearly: [\(item.expectedIpa)] vs heard [\(item.heardIpa)].",
                    audioURL: nil,
                    isSynthesizing: true
                )
                activeDrills.append(drill)

                let sessionAudioURL = record.latestAudioURL
                let wordText = item.word
                Task { @MainActor [weak self] in
                    do {
                        let result = try await TTSManager.shared.synthesize(
                            targetText: wordText,
                            learnerAudioURL: sessionAudioURL,
                            baseVoice: "auto",
                            speed: 1.0,
                            tau: 0.35
                        )
                        guard let self = self else { return }
                        self.generatedClips[wordText.lowercased()] = result.outputURL
                        if let idx = self.activeDrills.firstIndex(where: { $0.targetWord.lowercased() == wordText.lowercased() }) {
                            self.activeDrills[idx].audioURL = result.outputURL
                            self.activeDrills[idx].isSynthesizing = false
                        }
                    } catch {
                        guard let self = self else { return }
                        if let idx = self.activeDrills.firstIndex(where: { $0.targetWord.lowercased() == wordText.lowercased() }) {
                            self.activeDrills[idx].isSynthesizing = false
                        }
                    }
                }
            }

            // 2. Fluency remediation & Golden Speaker pacing synthesis
            let sessionFluency = record.sessionFluency ?? record.utterances.compactMap({ $0.fluencyResult }).first
            if let f = sessionFluency, f.overallScore < 60 || f.meanLengthOfRun < 2.5 || f.longPauseRatio > 0.4 {
                let text = record.fullTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                let words = text.split(separator: " ")
                let practicePhrase: String
                if words.count >= 4 {
                    practicePhrase = words.prefix(min(words.count, 7)).joined(separator: " ")
                } else if !record.prompt.isEmpty {
                    practicePhrase = record.prompt
                } else {
                    practicePhrase = text
                }

                if !practicePhrase.isEmpty {
                    let drill = FluencyDrillCard(
                        targetPhrase: practicePhrase,
                        targetSpeed: 1.0,
                        pacingTip: "Focus on linking words together smoothly without pausing mid-clause.",
                        audioURL: nil,
                        isSynthesizing: true
                    )
                    activeFluencyDrills.append(drill)

                    let sessionAudioURL = record.latestAudioURL
                    Task { @MainActor [weak self] in
                        do {
                            let result = try await TTSManager.shared.synthesize(
                                targetText: practicePhrase,
                                learnerAudioURL: sessionAudioURL,
                                baseVoice: "auto",
                                speed: 1.0,
                                tau: 0.35
                            )
                            guard let self = self else { return }
                            if let idx = self.activeFluencyDrills.firstIndex(where: { $0.targetPhrase == practicePhrase }) {
                                self.activeFluencyDrills[idx].audioURL = result.outputURL
                                self.activeFluencyDrills[idx].isSynthesizing = false
                            }
                        } catch {
                            guard let self = self else { return }
                            if let idx = self.activeFluencyDrills.firstIndex(where: { $0.targetPhrase == practicePhrase }) {
                                self.activeFluencyDrills[idx].isSynthesizing = false
                            }
                        }
                    }
                }
            }

            // 3. Prepare comprehensive session diagnostic prompt for Ollama
            var sessionSummary = """
            The learner has completed an English speaking practice session.
            - Assigned Speaking Prompt: "\(record.prompt.isEmpty ? "Free speech" : record.prompt)"
            - Verbatim Spoken Transcript (Acoustic Mirror): "\(record.fullTranscript)"
            - Pronunciation Score: \(record.overallPronunciationScore)/100
            - Fluency Score: \(record.overallFluencyScore)/100
            """

            if let f = sessionFluency {
                sessionSummary += """

                - Detailed Fluency & Rhythm Metrics (Session-Wide):
                  * Session Speech Rate: \(String(format: "%.2f", f.sessionSpeechRate ?? f.speechRate)) words/sec (overall pace including natural pauses; reference: 1.4–2.5 wps natural reading pace)
                  * Burst Articulation Rate: \(String(format: "%.2f", f.articulationRate)) words/sec (active speaking speed during runs without pauses; reference: 3.5–5.5 wps)
                  * Phonation-Time Ratio: \(Int(f.phonationTimeRatio * 100))% of session spent speaking (reference: 50%–70% natural flow)
                  * Mean Length of Run: \(String(format: "%.1f", f.meanLengthOfRun)) words/run (reference: >4.0 fluent chunking, <2.0 fragmented)
                  * Pauses: \(f.pauseCount) pauses detected (\(f.interTurnPauseCount) natural sentence/clause breaks, \(f.intraTurnPauseCount) intra-phrase hesitations), mean duration \(String(format: "%.2f", f.meanPauseDuration))s, max duration \(String(format: "%.2f", f.maxPauseDuration))s
                  * Long Pause Ratio (>=0.5s): \(Int(f.longPauseRatio * 100))%
                  * Rhythm Variability (Word Duration CV): \(String(format: "%.2f", f.wordDurationCV))
                  * Local Tempo Consistency (Speech Rate CV): \(String(format: "%.2f", f.speechRateCV))
                """
            } else {
                sessionSummary += "\n- Pauses: \(record.allPauses.count) pauses detected"
            }

            let pauses = record.allPauses
            let longPauses = pauses.filter { $0.duration >= 0.8 }
            if !longPauses.isEmpty {
                let pauseList = longPauses.prefix(3).map { "after '\($0.wordBefore)' before '\($0.wordAfter)' (\(String(format: "%.2f", $0.duration))s)" }.joined(separator: ", ")
                sessionSummary += "\n- Noticeable Hesitation Pauses: \(pauseList)"
            }

            let allDisfluencies = record.allDisfluencies
            let intraPhrasePauses = record.intraPhrasePauseCount
            let totalPausesCount = record.allPauses.count
            if !allDisfluencies.isEmpty || intraPhrasePauses > 0 {
                sessionSummary += """

                - Speech Disfluencies & Syntactic Pausing:
                  * Vocalized Filled Pauses: \(record.totalFillerCount) ('um', 'uh', etc.)
                  * Repetitions & False Starts: \(record.totalRepetitionCount) repeated tokens
                  * Intra-Phrase Hesitations: \(intraPhrasePauses) of \(totalPausesCount) pauses occurred awkwardly inside phrases (e.g. between articles/prepositions and nouns)
                """
            }

            if !targetItems.isEmpty {
                let errorDetails = targetItems.map { "- \($0.word) (score: \($0.overallScore)/100, target IPA: [\($0.expectedIpa)], heard IPA: [\($0.heardIpa)])" }.joined(separator: "\n")
                sessionSummary += "\n- Words flagged for pronunciation remediation (score < \(drillCutoff)%):\n\(errorDetails)"
                sessionSummary += "\nNote: Interactive practice drill cards and Golden Speaker audio models have already been created for these words."
            } else {
                sessionSummary += "\n- All words were pronounced with high clarity."
            }

            if !activeFluencyDrills.isEmpty {
                sessionSummary += "\nNote: A pacing & rhythm practice drill card and Golden Speaker pacing demonstration have been created for the learner."
            }

            sessionSummary += "\n\nPlease deliver your initial diagnostic evaluation following your system instructions. Be concise and punchy: keep each section to 2–3 focused sentences."

            ollamaChatMessages.append((role: "user", content: sessionSummary))

            do {
                let stream = OllamaService.shared.streamChat(
                    messages: ollamaChatMessages,
                    instructions: SystemPrompts.coachingEvaluationSystemInstructions,
                    maxTokens: 850
                )
                for try await token in stream {
                    reportText += token
                }
                chatHistory.append(ChatMessage(role: .coach, text: reportText))
                ollamaChatMessages.append((role: "assistant", content: reportText))
            } catch {
                reportError = "Ollama coaching evaluation failed: \(error.localizedDescription)"
            }
        }

        isGeneratingReport = false
    }

    // MARK: - Interactive Chat

    /// Sends a user message to the coach and streams the reply.
    /// Preserves full conversation history across either Apple Intelligence or Ollama.
    func sendUserMessage(_ text: String) async {
        let provider = STTSettings.shared.llmProvider

        switch provider {
        case .appleIntelligence:
            guard let session = coachSession else { return }
            let promptInput = SystemPrompts.coachingFollowUpInput(userMessage: text)
            guard !promptInput.isEmpty else { return }

            chatHistory.append(ChatMessage(role: .user, text: promptInput))
            chatHistory.append(ChatMessage(role: .coach, text: "", isStreaming: true))
            let replyIndex = chatHistory.count - 1

            isGeneratingReply = true

            do {
                let stream = session.streamResponse(to: promptInput)
                for try await snapshot in stream {
                    chatHistory[replyIndex].text = snapshot.content
                }
                chatHistory[replyIndex].isStreaming = false
            } catch {
                chatHistory[replyIndex].text = "An error occurred: \(error.localizedDescription)"
                chatHistory[replyIndex].isStreaming = false
            }

            isGeneratingReply = false

        case .ollama:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            chatHistory.append(ChatMessage(role: .user, text: trimmed))
            ollamaChatMessages.append((role: "user", content: trimmed))

            chatHistory.append(ChatMessage(role: .coach, text: "", isStreaming: true))
            let replyIndex = chatHistory.count - 1

            isGeneratingReply = true

            do {
                let stream = OllamaService.shared.streamChat(
                    messages: ollamaChatMessages,
                    instructions: SystemPrompts.coachingEvaluationSystemInstructions,
                    maxTokens: 500
                )
                for try await token in stream {
                    chatHistory[replyIndex].text += token
                }
                chatHistory[replyIndex].isStreaming = false
                ollamaChatMessages.append((role: "assistant", content: chatHistory[replyIndex].text))
            } catch {
                chatHistory[replyIndex].text = "Ollama error: \(error.localizedDescription)"
                chatHistory[replyIndex].isStreaming = false
            }

            isGeneratingReply = false
        }
    }

    // MARK: - Audio Playback

    func playDrillAudio(_ drill: InteractiveDrillCard) {
        if let url = drill.audioURL ?? generatedClips[drill.targetWord.lowercased()] {
            TTSManager.shared.playAudio(from: url)
        }
    }

    func playFluencyDrillAudio(_ drill: FluencyDrillCard) {
        if let url = drill.audioURL {
            TTSManager.shared.playAudio(from: url)
        }
    }

    func playClip(for text: String) {
        if let url = generatedClips[text.lowercased()] {
            TTSManager.shared.playAudio(from: url)
        }
    }

    // MARK: - Session Teardown

    /// Discards the current session. Call when the coaching view is dismissed.
    func endSession() {
        coachSession = nil
        ollamaChatMessages = []
        reportText = ""
        chatHistory = []
        activeDrills = []
        activeFluencyDrills = []
        generatedClips = [:]
        sessionRecord = nil
        reportError = nil
        TTSManager.shared.stopAllPlayback()
    }
}
