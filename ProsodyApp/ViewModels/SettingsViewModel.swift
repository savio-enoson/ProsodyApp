import Foundation
import SwiftUI
import Combine

/// ViewModel managing settings panel state and persistence.
@MainActor
final class SettingsViewModel: ObservableObject {
    let settings = STTSettings.shared
    let nemotronService = NemotronSTTService.shared
    let ollamaService = OllamaService.shared
    let interests = InterestsStore.shared

    @Published var newTopic: String = ""
    @Published var showingResetConfirm: Bool = false

    init() {}

    func addInterestTopic() {
        let trimmed = newTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        interests.add(trimmed)
        newTopic = ""
    }

    func removeInterestTopic(_ topic: String) {
        interests.remove(topic)
    }

    func resetInterestsToDefaults() {
        interests.resetToDefaults()
    }
}
