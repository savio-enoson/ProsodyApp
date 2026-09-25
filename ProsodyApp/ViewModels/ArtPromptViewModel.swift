import Foundation
import SwiftUI
import Combine

/// ViewModel managing state and artwork prompt transitions.
@MainActor
final class ArtPromptViewModel: ObservableObject {
    let artService: ArtPromptService

    init(artService: ArtPromptService? = nil) {
        self.artService = artService ?? ArtPromptService.shared
    }

    func nextArtwork() {
        artService.nextCuratedArtwork()
    }

    func randomCuratedArtwork() {
        artService.randomCuratedArtwork()
    }

    func discoverArtwork() {
        Task {
            await artService.fetchRandomOnlineArtwork()
        }
    }
}
