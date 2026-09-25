import Foundation
import FoundationModels

/// FoundationModels Tool allowing the AI Coach to create interactive fluency and pacing
/// drill cards that the learner can review and play in the practice interface.
struct CreateFluencyDrillTool: Tool {
    let name = "createFluencyDrill"
    let description = """
    Creates an interactive fluency and pacing practice drill card in the user interface. \
    Use when the learner's speech is fragmented (mean length of run < 2.5), excessively slow \
    (speech rate < 1.0 wps), or heavily paused (phonation ratio < 45%). Generates a phrase-chunking \
    exercise with Golden Speaker audio at target pacing.
    """

    @Generable
    struct Arguments {
        @Guide(description: "A natural English phrase (4-10 words) for pacing and chunking practice, e.g. 'I decided to take a walk in the park'.")
        var targetPhrase: String

        @Guide(description: "Target speed multiplier for synthesis (0.8–1.3, default 1.0 for natural pace).")
        var speedMultiplier: Double?

        @Guide(description: "Actionable coaching tip about rhythm, word linking, or breath groups, e.g. 'Link 'decided to' as one continuous sound without stopping between words.'")
        var pacingTip: String

        init(
            targetPhrase: String = "",
            speedMultiplier: Double? = 1.0,
            pacingTip: String = ""
        ) {
            self.targetPhrase = targetPhrase
            self.speedMultiplier = speedMultiplier
            self.pacingTip = pacingTip
        }
    }

    let record: SessionRecord
    let onDrillCreated: (@Sendable (FluencyDrillCard) -> Void)?

    init(record: SessionRecord, onDrillCreated: (@Sendable (FluencyDrillCard) -> Void)? = nil) {
        self.record = record
        self.onDrillCreated = onDrillCreated
    }

    func call(arguments: Arguments) async throws -> String {
        let phrase = arguments.targetPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else {
            return "Cannot create a fluency drill with an empty phrase."
        }

        let speed = Float(arguments.speedMultiplier ?? 1.0)
        let tip = arguments.pacingTip.trimmingCharacters(in: .whitespacesAndNewlines)

        print(">>> [TOOL INVOKED] createFluencyDrill(phrase: \"\(phrase)\", speed: \(speed), tip: \"\(tip)\")")

        var drill = FluencyDrillCard(
            targetPhrase: phrase,
            targetSpeed: speed,
            pacingTip: tip,
            audioURL: nil,
            isSynthesizing: true
        )

        let sessionAudioURL = record.latestAudioURL
        Task {
            do {
                let result = try await TTSManager.shared.synthesize(
                    targetText: phrase,
                    learnerAudioURL: sessionAudioURL,
                    baseVoice: "auto",
                    speed: speed,
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

        return "Successfully created interactive fluency drill for phrase: '\(phrase)'. The drill card with target pacing guidance and Golden Speaker demonstration is now displayed in the learner's interface."
    }
}
