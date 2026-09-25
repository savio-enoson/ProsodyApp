import Foundation
import FoundationModels

/// Returns the user's saved list of personal topics and interests.
struct GetUserInterestsTool: Tool {
    let name = "getUserInterests"
    let description = "Returns the user's saved list of personal topics and interests as a comma-separated string. Call this first to choose an appropriate speaking topic."

    @Generable
    struct Arguments {}

    // Captured at tool creation time from the @MainActor store
    let interests: [String]

    init() {
        // Must be called from MainActor context; captures the current interests list
        self.interests = InterestsStore.shared.interests
    }

    func call(arguments: Arguments) async throws -> String {
        return interests.isEmpty
            ? "general topics, everyday life, hobbies"
            : interests.joined(separator: ", ")
    }
}
