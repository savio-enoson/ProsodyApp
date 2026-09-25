import Foundation
import FoundationModels

/// FoundationModels Tool allowing the AI Coach to create interactive pronunciation and minimal-pair
/// drill cards that the learner can review and play in the practice interface.
struct CreatePracticeDrillTool: Tool {
    let name = "createPracticeDrill"
    let description = "Creates an interactive practice drill card in the user interface for a target word or minimal-pair sound contrast that the learner struggled with. Always provide a practice sentence and actionable mouth/tongue articulation tips."

    @Generable
    struct Arguments {
        @Guide(description: "The primary word that the learner needs to practice, e.g. 'think' or 'sheet'.")
        var targetWord: String

        @Guide(description: "Optional minimal-pair contrast word that represents the error or confusion sound, e.g. 'sink' or 'cheat'.")
        var contrastWord: String?

        @Guide(description: "Optional target phoneme symbol, e.g. 'θ', 'ð', 'æ', 'ʃ', or friendly label like 'th'.")
        var focusPhoneme: String?

        @Guide(description: "A natural practice sentence containing the target word, e.g. 'I think the heavy ship will sink to the bottom.'")
        var practiceSentence: String

        @Guide(description: "Concise physical articulatory guidance for the mouth and tongue, e.g. 'Touch tongue tip lightly to upper teeth and exhale softly without voicing.'")
        var articulatoryTip: String?

        init(
            targetWord: String = "",
            contrastWord: String? = nil,
            focusPhoneme: String? = nil,
            practiceSentence: String = "",
            articulatoryTip: String? = nil
        ) {
            self.targetWord = targetWord
            self.contrastWord = contrastWord
            self.focusPhoneme = focusPhoneme
            self.practiceSentence = practiceSentence
            self.articulatoryTip = articulatoryTip
        }
    }

    let record: SessionRecord
    let onDrillCreated: (@Sendable (InteractiveDrillCard) -> Void)?

    init(record: SessionRecord, onDrillCreated: (@Sendable (InteractiveDrillCard) -> Void)? = nil) {
        self.record = record
        self.onDrillCreated = onDrillCreated
    }

    func call(arguments: Arguments) async throws -> String {
        let target = arguments.targetWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            return "Cannot create a drill with an empty target word."
        }

        print(">>> [TOOL INVOKED] createPracticeDrill(target: \"\(target)\", contrast: \"\(arguments.contrastWord ?? "none")\", phoneme: \"\(arguments.focusPhoneme ?? "none")\")")

        var drill = InteractiveDrillCard(
            targetWord: target,
            contrastWord: arguments.contrastWord?.trimmingCharacters(in: .whitespacesAndNewlines),
            focusPhoneme: arguments.focusPhoneme?.trimmingCharacters(in: .whitespacesAndNewlines),
            practiceSentence: arguments.practiceSentence.trimmingCharacters(in: .whitespacesAndNewlines),
            articulatoryTip: arguments.articulatoryTip?.trimmingCharacters(in: .whitespacesAndNewlines),
            audioURL: nil,
            isSynthesizing: true
        )

        // Attempt on-device audio synthesis in background for instant playback readiness
        let sessionAudioURL = record.latestAudioURL
        Task {
            do {
                let result = try await TTSManager.shared.synthesize(
                    targetText: target,
                    learnerAudioURL: sessionAudioURL,
                    baseVoice: "auto",
                    speed: 1.0,
                    tau: 0.35
                )
                drill.audioURL = result.outputURL
                drill.isSynthesizing = false
                onDrillCreated?(drill)
            } catch {
                drill.isSynthesizing = false
                onDrillCreated?(drill)
            }
        }

        onDrillCreated?(drill)

        return "Successfully created interactive practice drill for '\(target)' (contrast: \(arguments.contrastWord ?? "none")). The drill card and Golden Speaker demo are now displayed in the learner's interface."
    }
}
