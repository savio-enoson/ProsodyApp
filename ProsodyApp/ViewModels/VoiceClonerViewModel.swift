import Foundation
import SwiftUI
import Combine

/// ViewModel managing state and synthesis parameters for the Voice Cloner Sandbox.
@MainActor
final class VoiceClonerViewModel: ObservableObject {
    let tts: TTSManager = TTSManager.shared

    @Published var targetText: String = "I wake up early every morning and make a fresh pot of coffee. I like to sit by the window, check my messages, and listen to the birds outside before starting my busy day."
    @Published var selectedBaseVoice: String = "auto"
    @Published var speed: Float = 1.0
    @Published var tau: Float = 0.35

    init() {}

    func generateGoldenSpeaker() async {
        await tts.generateGoldenSpeaker(
            text: targetText,
            baseVoice: selectedBaseVoice,
            speed: speed,
            tau: tau
        )
    }

    @discardableResult
    func synthesize() async throws -> VoiceClonerResult {
        try await tts.synthesize(
            targetText: targetText,
            baseVoice: selectedBaseVoice,
            speed: speed,
            tau: tau
        )
    }
}
