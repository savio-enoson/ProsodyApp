import Foundation
import SwiftUI
import Combine

// MARK: - ArtPromptService

/// Coordinates curated and live open-access artwork prompts for speaking practice.
///
/// Combines an offline-capable collection of 12 curated public domain masterworks
/// with on-demand discovery from the Cleveland Museum of Art (CMA) Open Access API
/// and dynamic Apple Intelligence multimodal visual analysis.
@MainActor
public final class ArtPromptService: ObservableObject {
    public static let shared = ArtPromptService()

    @Published public private(set) var currentArtwork: ArtworkPromptItem
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var isAnalyzingVisuals: Bool = false
    @Published public var errorMessage: String? = nil

    private var curatedIndex: Int = 0

    // MARK: - Curated Masterworks Catalog (12 CC0 / Public Domain Masterworks)

    public static let curatedMasterworks: [ArtworkPromptItem] = [
        ArtworkPromptItem(
            id: "met-436535",
            title: "Wheat Field with Cypresses",
            artist: "Vincent van Gogh",
            date: "1889",
            medium: "Oil on canvas",
            department: "European Paintings",
            imageURL: URL(string: "https://images.metmuseum.org/CRDImages/ep/web-large/DP-42549-001.jpg"),
            webURL: URL(string: "https://www.metmuseum.org/art/collection/search/436535"),
            sourceName: "The Met • CC0",
            guidedPrompts: [
                "Describe the swirling clouds, golden wheat, and the tall dark green cypress tree.",
                "How does the dynamic brushwork make the landscape feel alive?",
                "What emotions does this vibrant countryside scene stir in you?"
            ],
            suggestedFeelings: ["Vibrant", "Restless", "Expansive", "Sun-drenched", "Yearning"],
            localResourceName: "van_gogh_cypresses"
        ),
        ArtworkPromptItem(
            id: "cma-1927.1984",
            title: "The Champion Single Sculls (Max Schmitt in a Single Scull)",
            artist: "Thomas Eakins",
            date: "1873",
            medium: "Oil on canvas",
            department: "American Painting and Sculpture",
            imageURL: URL(string: "https://openaccess-cdn.clevelandart.org/1927.1984/1927.1984_web.jpg"),
            webURL: URL(string: "https://clevelandart.org/art/1927.1984"),
            sourceName: "Cleveland Museum of Art • CC0",
            guidedPrompts: [
                "Notice the calm reflection on the river, the rower resting his oars, and the distant bridges.",
                "How does the artist balance athletic concentration with peaceful silence?",
                "Does this setting remind you of any outdoor places you have visited?"
            ],
            suggestedFeelings: ["Tranquil", "Focused", "Solitary", "Reflective", "Crisp"],
            localResourceName: "eakins_sculls"
        ),
        ArtworkPromptItem(
            id: "met-438008",
            title: "Bridge over a Pond of Water Lilies",
            artist: "Claude Monet",
            date: "1899",
            medium: "Oil on canvas",
            department: "European Paintings",
            imageURL: URL(string: "https://images.metmuseum.org/CRDImages/ep/web-large/DP-25466-001.jpg"),
            webURL: URL(string: "https://www.metmuseum.org/art/collection/search/438008"),
            sourceName: "The Met • CC0",
            guidedPrompts: [
                "Describe the wooden footbridge spanning the pond filled with blooming water lilies.",
                "How do the lush greens and filtered sunlight create a sense of harmony?",
                "What sounds would you expect to hear if you were standing on this bridge?"
            ],
            suggestedFeelings: ["Peaceful", "Dreamy", "Lush", "Harmonious", "Calming"],
            localResourceName: "monet_water_lilies"
        ),
        ArtworkPromptItem(
            id: "cma-1951.454",
            title: "The Repentant St. Peter",
            artist: "Georges de La Tour",
            date: "1645",
            medium: "Oil on canvas",
            department: "European Painting and Sculpture",
            imageURL: URL(string: "https://openaccess-cdn.clevelandart.org/1951.454/1951.454_web.jpg"),
            webURL: URL(string: "https://clevelandart.org/art/1951.454"),
            sourceName: "Cleveland Museum of Art • CC0",
            guidedPrompts: [
                "Examine the dramatic candle illumination (chiaroscuro) highlighting the subject's face and hands.",
                "What story or internal conflict do the man's expression and clasped hands tell?",
                "How does the deep darkness surrounding the lantern heighten the drama?"
            ],
            suggestedFeelings: ["Solemn", "Intimate", "Contemplative", "Dramatic", "Penitent"],
            localResourceName: "latour_st_peter"
        ),
        ArtworkPromptItem(
            id: "met-45434",
            title: "Under the Wave off Kanagawa (The Great Wave)",
            artist: "Katsushika Hokusai",
            date: "c. 1830–32",
            medium: "Woodblock print; ink and color on paper",
            department: "Asian Art",
            imageURL: URL(string: "https://images.metmuseum.org/CRDImages/as/web-large/DP130155.jpg"),
            webURL: URL(string: "https://www.metmuseum.org/art/collection/search/45434"),
            sourceName: "The Met • CC0",
            guidedPrompts: [
                "Describe the towering claw-like crest of the wave framing Mount Fuji in the distance.",
                "How do the small wooden boats and rowers emphasize human vulnerability against nature?",
                "What sensation of movement or sound does this famous woodblock print convey?"
            ],
            suggestedFeelings: ["Awe-inspiring", "Dramatic", "Vulnerable", "Majestic", "Electrifying"],
            localResourceName: "hokusai_great_wave"
        ),
        ArtworkPromptItem(
            id: "cma-1922.1133",
            title: "Stag at Sharkey's",
            artist: "George Bellows",
            date: "1909",
            medium: "Oil on canvas",
            department: "American Painting and Sculpture",
            imageURL: URL(string: "https://openaccess-cdn.clevelandart.org/1922.1133/1922.1133_web.jpg"),
            webURL: URL(string: "https://clevelandart.org/art/1922.1133"),
            sourceName: "Cleveland Museum of Art • CC0",
            guidedPrompts: [
                "Describe the raw athletic collision of the two boxers under the harsh overhead ring lights.",
                "Notice the animated crowd in the shadows around the ring. What is the atmosphere?",
                "How does the painter capture intense physical energy and grit?"
            ],
            suggestedFeelings: ["Energetic", "Raw", "Intense", "Chaotic", "Gritty"],
            localResourceName: "bellows_sharkeys"
        ),
        ArtworkPromptItem(
            id: "cma-1942.1065",
            title: "Romaine Lacaux",
            artist: "Pierre-Auguste Renoir",
            date: "1864",
            medium: "Oil on canvas",
            department: "European Painting and Sculpture",
            imageURL: URL(string: "https://openaccess-cdn.clevelandart.org/1942.1065/1942.1065_web.jpg"),
            webURL: URL(string: "https://clevelandart.org/art/1942.1065"),
            sourceName: "Cleveland Museum of Art • CC0",
            guidedPrompts: [
                "Notice the young girl's gentle expression and the delicate flowers she holds in her lap.",
                "How do the soft textures and bright red touches bring warmth to the portrait?",
                "What personality or thoughts does her calm gaze suggest?"
            ],
            suggestedFeelings: ["Gentle", "Innocent", "Warm", "Delicate", "Serene"],
            localResourceName: "renoir_romaine"
        ),
        ArtworkPromptItem(
            id: "met-436105",
            title: "The Dance Class",
            artist: "Edgar Degas",
            date: "1874",
            medium: "Oil on canvas",
            department: "European Paintings",
            imageURL: URL(string: "https://images.metmuseum.org/CRDImages/ep/web-large/DP-20101-001.jpg"),
            webURL: URL(string: "https://www.metmuseum.org/art/collection/search/436105"),
            sourceName: "The Met • CC0",
            guidedPrompts: [
                "Describe the young ballerinas gathered around the ballet master in the spacious studio.",
                "Notice the candid poses—some stretching, some resting, some adjusting their costumes.",
                "How does this behind-the-scenes view differ from a polished stage performance?"
            ],
            suggestedFeelings: ["Graceful", "Candid", "Disciplined", "Lively", "Atmospheric"],
            localResourceName: "degas_dance_class"
        ),
        ArtworkPromptItem(
            id: "met-437397",
            title: "Self-Portrait",
            artist: "Rembrandt van Rijn",
            date: "1660",
            medium: "Oil on canvas",
            department: "European Paintings",
            imageURL: URL(string: "https://images.metmuseum.org/CRDImages/ep/web-large/DP145924.jpg"),
            webURL: URL(string: "https://www.metmuseum.org/art/collection/search/437397"),
            sourceName: "The Met • CC0",
            guidedPrompts: [
                "Observe the artist's weathered, introspective expression illuminated against a shadowy background.",
                "How does the thick impasto paint texture convey experience, dignity, and age?",
                "What thoughts or feelings do you imagine were on the artist's mind as he painted himself?"
            ],
            suggestedFeelings: ["Introspective", "Dignified", "Weathered", "Resolute", "Profound"],
            localResourceName: "rembrandt_self_portrait"
        ),
        ArtworkPromptItem(
            id: "cma-1958.20",
            title: "The Brook",
            artist: "Paul Cézanne",
            date: "c. 1895–1900",
            medium: "Oil on canvas",
            department: "European Painting and Sculpture",
            imageURL: URL(string: "https://openaccess-cdn.clevelandart.org/1958.20/1958.20_web.jpg"),
            webURL: URL(string: "https://clevelandart.org/art/1958.20"),
            sourceName: "Cleveland Museum of Art • CC0",
            guidedPrompts: [
                "Examine how Cézanne structures the trees, rocks, and stream with geometric brush strokes.",
                "How does the interplay of earthy ochre, green, and blue capture nature's underlying architecture?",
                "What sense of quiet solitude does this forest stream evoke?"
            ],
            suggestedFeelings: ["Earthy", "Architectural", "Secluded", "Quiet", "Timeless"],
            localResourceName: "cezanne_brook"
        ),
        ArtworkPromptItem(
            id: "cma-1942.647",
            title: "The Burning of the Houses of Lords and Commons",
            artist: "Joseph Mallord William Turner",
            date: "1835",
            medium: "Oil on canvas",
            department: "European Painting and Sculpture",
            imageURL: URL(string: "https://openaccess-cdn.clevelandart.org/1942.647/1942.647_web.jpg"),
            webURL: URL(string: "https://clevelandart.org/art/1942.647"),
            sourceName: "Cleveland Museum of Art • CC0",
            guidedPrompts: [
                "Describe the towering blaze of fiery orange and yellow lighting up the nighttime Thames river.",
                "Notice the spectators crowded along the riverbank watching the historic catastrophe.",
                "How does Turner convey the sublime and overwhelming power of elemental fire?"
            ],
            suggestedFeelings: ["Sublime", "Cataclysmic", "Mesmerizing", "Ominous", "Fiery"],
            localResourceName: "turner_parliament"
        ),
        ArtworkPromptItem(
            id: "cma-1965.233",
            title: "Twilight in the Wilderness",
            artist: "Frederic Edwin Church",
            date: "1860",
            medium: "Oil on canvas",
            department: "American Painting and Sculpture",
            imageURL: URL(string: "https://openaccess-cdn.clevelandart.org/1965.233/1965.233_web.jpg"),
            webURL: URL(string: "https://clevelandart.org/art/1965.233"),
            sourceName: "Cleveland Museum of Art • CC0",
            guidedPrompts: [
                "Describe the spectacular sunset burning across the sky in vivid shades of crimson, violet, and gold.",
                "Notice the stillness of the wilderness lake mirroring the evening glow.",
                "What sense of wonder or reverence does this dramatic American frontier landscape stir?"
            ],
            suggestedFeelings: ["Majestic", "Awe-inspiring", "Luminescent", "Still", "Vibrant"],
            localResourceName: "church_twilight"
        )
    ]

    // MARK: - Initialization

    public init() {
        self.currentArtwork = Self.curatedMasterworks[0]
        Task { [weak self] in
            await self?.analyzeCurrentArtwork()
        }
    }

    // MARK: - Public Actions

    /// Selects the next curated artwork from the local collection.
    public func nextCuratedArtwork() {
        errorMessage = nil
        curatedIndex = (curatedIndex + 1) % Self.curatedMasterworks.count
        currentArtwork = Self.curatedMasterworks[curatedIndex]
        Task { [weak self] in
            await self?.analyzeCurrentArtwork()
        }
    }

    /// Selects a random curated artwork different from the current one.
    public func randomCuratedArtwork() {
        errorMessage = nil
        guard Self.curatedMasterworks.count > 1 else { return }
        var nextIdx = Int.random(in: 0..<Self.curatedMasterworks.count)
        if nextIdx == curatedIndex {
            nextIdx = (nextIdx + 1) % Self.curatedMasterworks.count
        }
        curatedIndex = nextIdx
        currentArtwork = Self.curatedMasterworks[curatedIndex]
        Task { [weak self] in
            await self?.analyzeCurrentArtwork()
        }
    }

    /// Queries the Cleveland Museum of Art Open Access API for a random CC0 painting.
    /// Falls back to a curated artwork if offline or if the request times out.
    public func fetchRandomOnlineArtwork() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil

        let randomSkip = Int.random(in: 0..<400)
        let urlString = "https://openaccess-api.clevelandart.org/api/artworks/?cc0=1&has_image=1&type=Painting&limit=1&skip=\(randomSkip)"

        guard let url = URL(string: urlString) else {
            isLoading = false
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 6.0

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                throw URLError(.badServerResponse)
            }

            let decoded = try JSONDecoder().decode(CMASearchResponse.self, from: data)
            guard let item = decoded.data.first,
                  let imageWebUrlStr = item.images?.web?.url,
                  let imageURL = URL(string: imageWebUrlStr) else {
                throw URLError(.cannotParseResponse)
            }

            let title = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Untitled Artwork"
            let artist = item.creators?.first?.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown Artist"
            let date = item.dateText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let medium = item.technique
            let department = item.department
            let webURL = item.url != nil ? URL(string: item.url!) : nil

            self.currentArtwork = ArtworkPromptItem(
                id: "cma-\(item.id)",
                title: title,
                artist: artist,
                date: date,
                medium: medium,
                department: department,
                imageURL: imageURL,
                webURL: webURL,
                sourceName: "Cleveland Museum of Art • CC0"
            )

            // Asynchronously analyze newly discovered online artwork
            await self.analyzeCurrentArtwork()
        } catch {
            // Non-blocking error notice; keep current or switch to curated
            self.errorMessage = "Could not fetch online artwork (\(error.localizedDescription)). Showing curated masterwork instead."
            self.randomCuratedArtwork()
        }

        isLoading = false
    }

    /// Asynchronously runs Apple Intelligence multimodal analysis on the current artwork's image
    /// to dynamically generate scene descriptions, guided questions, and atmosphere vocabulary.
    public func analyzeCurrentArtwork() async {
        guard FoundationModelManager.shared.isAvailable else { return }
        guard let targetURL = currentArtwork.effectiveImageURL else { return }

        let targetId = currentArtwork.id
        let targetTitle = currentArtwork.title
        let targetArtist = currentArtwork.artist

        isAnalyzingVisuals = true

        do {
            let analysis = try await FoundationModelManager.shared.analyzeArtwork(
                imageURL: targetURL,
                title: targetTitle,
                artist: targetArtist
            )

            // Confirm that the user hasn't switched to another artwork during inference
            if currentArtwork.id == targetId {
                currentArtwork.visualSceneDescription = analysis.sceneDescription
                if !analysis.guidedPrompts.isEmpty {
                    currentArtwork.guidedPrompts = analysis.guidedPrompts
                }
                if !analysis.suggestedFeelings.isEmpty {
                    currentArtwork.suggestedFeelings = analysis.suggestedFeelings
                }
                currentArtwork.isAIGenerated = true
            }
        } catch {
            print("Multimodal visual analysis fallback to curated prompts: \(error)")
        }

        if currentArtwork.id == targetId {
            isAnalyzingVisuals = false
        }
    }

    /// The speaking prompt string to pass into `SessionRecord`.
    public var currentPromptText: String {
        currentArtwork.promptText
    }
}
