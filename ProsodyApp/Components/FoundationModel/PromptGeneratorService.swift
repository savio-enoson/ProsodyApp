import Foundation
import Combine
import FoundationModels

// MARK: - PromptGeneratorService

/// Generates a personalised English speaking prompt using the on-device
/// Foundation Models framework via `FoundationModelManager`.
///
/// Prompts and system instructions are loaded from `SystemPrompts`.
/// Call `prewarm()` on app launch to load model assets in the background
/// and reduce first-use latency.
@MainActor
final class PromptGeneratorService: ObservableObject {
    static let shared = PromptGeneratorService()

    @Published var currentPrompt: String = ""
    @Published var isGenerating: Bool = false
    @Published var error: String? = nil

    // MARK: - Public API

    /// Generates a new speaking prompt and updates `currentPrompt`.
    func generate() async {
        isGenerating = true
        error = nil

        let provider = STTSettings.shared.llmProvider

        switch provider {
        case .appleIntelligence:
            guard FoundationModelManager.shared.isAvailable else {
                error = "Apple Intelligence is not available on this device."
                if currentPrompt.isEmpty {
                    currentPrompt = SystemPrompts.defaultSpeakingPrompt()
                }
                isGenerating = false
                return
            }

            do {
                let promptText = try await FoundationModelManager.shared.respond(
                    to: SystemPrompts.generateSpeakingPromptInput(),
                    instructions: SystemPrompts.speakingPromptSystemInstructions,
                    tools: [
                        GetUserInterestsTool()
                    ]
                )
                currentPrompt = promptText
            } catch {
                self.error = error.localizedDescription
                if currentPrompt.isEmpty {
                    currentPrompt = SystemPrompts.defaultSpeakingPrompt()
                }
            }

        case .ollama:
            do {
                let promptInput = SystemPrompts.generateSpeakingPromptInput(interests: InterestsStore.shared.interests)
                let promptText = try await OllamaService.shared.generate(
                    prompt: promptInput,
                    instructions: SystemPrompts.speakingPromptSystemInstructions,
                    maxTokens: 150
                )
                if !promptText.isEmpty {
                    currentPrompt = promptText
                } else {
                    currentPrompt = SystemPrompts.defaultSpeakingPrompt()
                }
            } catch {
                self.error = "Ollama generation failed: \(error.localizedDescription)"
                if currentPrompt.isEmpty {
                    currentPrompt = SystemPrompts.defaultSpeakingPrompt()
                }
            }
        }

        isGenerating = false
    }

    /// Preloads model assets in the background to reduce first-call latency.
    func prewarm() {
        switch STTSettings.shared.llmProvider {
        case .appleIntelligence:
            FoundationModelManager.shared.prewarm(
                instructions: SystemPrompts.speakingPromptSystemInstructions,
                tools: [
                    GetUserInterestsTool()
                ]
            )
        case .ollama:
            Task {
                await OllamaService.shared.checkConnection()
            }
        }
    }
}

