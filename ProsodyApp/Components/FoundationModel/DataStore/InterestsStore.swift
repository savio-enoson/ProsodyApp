import Foundation
import SwiftUI
import Combine

// MARK: - InterestsStore

/// Persists the user's list of personal topics and interests to UserDefaults.
/// Used by the Prompt Generator to personalise the speaking prompt.
final class InterestsStore: ObservableObject {
    static let shared = InterestsStore()

    @Published var interests: [String]

    private let key = "prosody.user.interests"

    static let defaults: [String] = [
        "travel", "food and cooking", "technology", "daily life",
        "work and career", "family", "hobbies", "learning new things",
        "current events", "music", "sports", "movies and TV"
    ]

    init() {
        interests = UserDefaults.standard.stringArray(forKey: key) ?? InterestsStore.defaults
    }

    func save() {
        UserDefaults.standard.set(interests, forKey: key)
    }

    func add(_ topic: String) {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !interests.contains(trimmed) else { return }
        interests.append(trimmed)
        save()
    }

    func remove(at offsets: IndexSet) {
        interests.remove(atOffsets: offsets)
        save()
    }

    func remove(_ topic: String) {
        interests.removeAll { $0 == topic }
        save()
    }

    func resetToDefaults() {
        interests = InterestsStore.defaults
        save()
    }
}
