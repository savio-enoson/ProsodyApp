import Foundation
import FoundationModels

/// FoundationModels Tool enabling the AI Coach to synthesize corrective native audio
/// for words or phrases the learner mispronounced, utilizing Kokoro-82M on Apple Silicon
/// with learner vocal tract timbre conditioning (The Golden Speaker).
struct SynthesizeCorrectiveSpeechTool: Tool {
    let name = "synthesizeCorrectiveSpeech"
    let description = "Synthesizes canonical native English speech for a target word or short phrase that the learner mispronounced, conditioning the output on the learner's vocal timbre (the Golden Speaker). Call this tool when recommending a pronunciation correction so the learner can hear the word pronounced correctly in their own voice."

    @Generable
    struct Arguments {
        @Guide(description: "The word or short phrase to synthesize with canonical native pronunciation, e.g. 'photosynthesis' or 'think'.")
        var text: String

        @Guide(description: "Optional focus phoneme symbol (e.g. 'θ', 'æ', 'ʃ') or sound description.")
        var focusPhoneme: String?

        init(text: String = "", focusPhoneme: String? = nil) {
            self.text = text
            self.focusPhoneme = focusPhoneme
        }
    }

    let record: SessionRecord
    let onSynthesized: (@Sendable (String, URL) -> Void)?

    init(record: SessionRecord, onSynthesized: (@Sendable (String, URL) -> Void)? = nil) {
        self.record = record
        self.onSynthesized = onSynthesized
    }

    func call(arguments: Arguments) async throws -> String {
        let textToSynthesize = arguments.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !textToSynthesize.isEmpty else {
            return "Cannot synthesize speech for empty text."
        }

        print(">>> [TOOL INVOKED] synthesizeCorrectiveSpeech(text: \"\(textToSynthesize)\", focusPhoneme: \"\(arguments.focusPhoneme ?? "none")\")")

        do {
            let result = try await TTSManager.shared.synthesize(
                targetText: textToSynthesize,
                learnerAudioURL: record.latestAudioURL,
                baseVoice: "auto",
                speed: 1.0,
                tau: 0.35
            )

            onSynthesized?(textToSynthesize, result.outputURL)

            return "Successfully synthesized audio for '\(textToSynthesize)' with canonical pronunciation. Audio is ready for the learner to play in the interface. Real-time factor: \(String(format: "%.3f", result.rtf))x."
        } catch {
            print(">>> [TOOL ERROR] synthesizeCorrectiveSpeech failed: \(error)")
            return "Speech synthesis could not be completed: \(error.localizedDescription)"
        }
    }
}
