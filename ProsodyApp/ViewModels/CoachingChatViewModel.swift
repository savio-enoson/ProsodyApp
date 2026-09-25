import Foundation
import SwiftUI
import Combine

/// ViewModel managing state and chat operations for the AI Coaching Review interface.
@MainActor
final class CoachingChatViewModel: ObservableObject {
    let coach: CoachingSessionService
    let record: SessionRecord
    let tts = TTSManager.shared

    @Published var userInput: String = ""

    init(record: SessionRecord, coach: CoachingSessionService? = nil) {
        self.record = record
        self.coach = coach ?? CoachingSessionService()
    }

    func sendMessage() {
        let text = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        userInput = ""
        Task {
            await coach.sendUserMessage(text)
        }
    }

    func endSession() {
        coach.endSession()
    }
}
