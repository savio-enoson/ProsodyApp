import Foundation

// MARK: - ArtworkPromptItem

/// Represents a public domain artwork presented to the learner as a creative speaking prompt.
public struct ArtworkPromptItem: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let artist: String
    public let date: String
    public let medium: String?
    public let department: String?
    public let imageURL: URL?
    public let webURL: URL?
    public let sourceName: String
    public var guidedPrompts: [String]
    public var suggestedFeelings: [String]
    public var visualSceneDescription: String?
    public var isAIGenerated: Bool
    public let localResourceName: String?

    public init(
        id: String,
        title: String,
        artist: String,
        date: String,
        medium: String? = nil,
        department: String? = nil,
        imageURL: URL?,
        webURL: URL? = nil,
        sourceName: String = "Cleveland Museum of Art • CC0",
        guidedPrompts: [String] = SystemPrompts.defaultArtworkGuidedPrompts,
        suggestedFeelings: [String] = SystemPrompts.defaultArtworkSuggestedFeelings,
        visualSceneDescription: String? = nil,
        isAIGenerated: Bool = false,
        localResourceName: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.date = date
        self.medium = medium
        self.department = department
        self.imageURL = imageURL
        self.webURL = webURL
        self.sourceName = sourceName
        self.guidedPrompts = guidedPrompts
        self.suggestedFeelings = suggestedFeelings
        self.visualSceneDescription = visualSceneDescription
        self.isAIGenerated = isAIGenerated
        self.localResourceName = localResourceName
    }

    /// Resolves local image file URL from the app bundle if available.
    public var localImageURL: URL? {
        guard let name = localResourceName else { return nil }
        return Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "Artworks")
            ?? Bundle.main.url(forResource: name, withExtension: "jpg")
    }

    /// Returns the best available image URL (local bundled image if available, else remote URL).
    public var effectiveImageURL: URL? {
        localImageURL ?? imageURL
    }

    /// Formats a complete speaking prompt string suitable for passing to `SessionRecord`
    /// and the Foundation Model coaching evaluator.
    public var promptText: String {
        let artistPart = artist.isEmpty ? "an unknown artist" : artist
        let datePart = date.isEmpty ? "" : " (\(date))"
        if let scene = visualSceneDescription, !scene.isEmpty {
            return "Describe the artwork \"\(title)\" by \(artistPart)\(datePart). Visual scene: \(scene). Describe the visual details—the colors, lighting, and subjects—and express what mood or emotions it evokes for you."
        }
        return "Describe the artwork \"\(title)\" by \(artistPart)\(datePart). Describe the visual scene in detail—the colors, lighting, and subjects—and express what mood or emotions it evokes for you."
    }
}

// MARK: - Cleveland Museum of Art API Decodable Models

struct CMASearchResponse: Decodable {
    let info: CMAInfo?
    let data: [CMAArtworkData]
}

struct CMAInfo: Decodable {
    let total: Int?
}

struct CMAArtworkData: Decodable {
    let id: Int
    let title: String?
    let dateText: String?
    let department: String?
    let technique: String?
    let url: String?
    let creators: [CMACreator]?
    let images: CMAImages?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case dateText = "date_text"
        case department
        case technique
        case url
        case creators
        case images
    }
}

struct CMACreator: Decodable {
    let description: String?
    let role: String?
}

struct CMAImages: Decodable {
    let web: CMAWebImage?
}

struct CMAWebImage: Decodable {
    let url: String?
    let width: String?
    let height: String?
}
