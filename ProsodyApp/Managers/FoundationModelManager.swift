import Foundation
import Combine
import CoreGraphics
import ImageIO
import FoundationModels

// MARK: - FoundationModelManager

/// Centralized manager and entry point for Apple Intelligence Foundation Models.
///
/// Manages system language model availability checks, background prewarming,
/// session initialization, and prompt execution across the Prosody app.
@MainActor
final class FoundationModelManager: ObservableObject {
    static let shared = FoundationModelManager()

    /// The default system language model instance.
    var defaultModel: SystemLanguageModel {
        SystemLanguageModel.default
    }

    /// Whether Apple Intelligence Foundation Models are ready and available on this device.
    var isAvailable: Bool {
        if case .available = defaultModel.availability { return true }
        return false
    }

    /// The current availability status of the system language model.
    var availability: SystemLanguageModel.Availability {
        defaultModel.availability
    }

    // MARK: - Session Factory

    /// Creates and configures a new `LanguageModelSession` with specified instructions and tools.
    func createSession(
        instructions: String? = nil,
        tools: [any Tool] = []
    ) -> LanguageModelSession {
        LanguageModelSession(
            model: defaultModel,
            tools: tools,
            instructions: instructions
        )
    }

    // MARK: - Direct Prompt Execution

    /// Generates a single-turn completion for a given input prompt.
    func respond(
        to prompt: String,
        instructions: String? = nil,
        tools: [any Tool] = []
    ) async throws -> String {
        let session = createSession(instructions: instructions, tools: tools)
        let response = try await session.respond(to: prompt)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Multimodal Artwork Analysis

    /// Resolves a remote image URL to a locally cached file URL asynchronously via URLSession.
    /// If the URL is already a local file URL, it is returned directly.
    private func resolveLocalImageURL(for url: URL) async throws -> URL {
        if url.isFileURL {
            return url
        }

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ProsodyArtworkCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: cacheDir.path) {
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }

        let hash = String(format: "%016llx", UInt64(bitPattern: Int64(url.absoluteString.hashValue)))
        let fileExtension = url.pathExtension.isEmpty ? "jpg" : url.pathExtension
        let localFile = cacheDir.appendingPathComponent("\(hash).\(fileExtension)")

        if FileManager.default.fileExists(atPath: localFile.path) {
            return localFile
        }

        // Asynchronously download using URLSession (CFNetwork asynchronous API)
        var request = URLRequest(url: url)
        request.timeoutInterval = 15.0
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        try data.write(to: localFile, options: .atomic)
        return localFile
    }

    /// Analyzes an artwork image using Apple Intelligence multimodal Foundation Models,
    /// generating structured visual descriptions, guided prompts, and mood vocabulary.
    func analyzeArtwork(
        imageURL: URL,
        title: String,
        artist: String
    ) async throws -> ArtworkAnalysis {
        guard isAvailable else {
            throw NSError(
                domain: "FoundationModelManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is not available on this device."]
            )
        }

        // Asynchronously resolve image via URLSession to eliminate synchronous CFNetwork main thread loading
        let localImageURL = try await resolveLocalImageURL(for: imageURL)
        let attachment: Attachment<ImageAttachmentContent>
        if let source = CGImageSourceCreateWithURL(localImageURL as CFURL, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            attachment = Attachment(cgImage)
        } else {
            attachment = Attachment(imageURL: localImageURL)
        }

        let prompt = Prompt {
            attachment
            SystemPrompts.artworkAnalysisInput(title: title, artist: artist)
        }

        let session = createSession(instructions: SystemPrompts.artworkAnalysisSystemInstructions)
        let response = try await session.respond(to: prompt, generating: ArtworkAnalysis.self)
        return response.content
    }

    // MARK: - Prewarming

    /// Preloads model assets in the background to minimize first-turn latency.
    nonisolated func prewarm(
        instructions: String? = nil,
        tools: [any Tool] = []
    ) {
        guard case .available = SystemLanguageModel.default.availability else { return }
        Task.detached(priority: .background) {
            let session = LanguageModelSession(
                model: SystemLanguageModel.default,
                tools: tools,
                instructions: instructions
            )
            session.prewarm()
        }
    }
}

// MARK: - SystemLanguageModel Availability Helper

extension SystemLanguageModel {
    /// Convenience property indicating whether the model is available.
    static var isReady: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }
}

// MARK: - ArtworkAnalysis Schema

/// Structured output schema for multimodal visual analysis of artworks via Apple Intelligence.
@Generable
public struct ArtworkAnalysis: Equatable, Sendable {
    @Guide(description: "A vivid 1-2 sentence description of the visual scene in the artwork (colors, lighting, focal subjects).")
    public var sceneDescription: String

    @Guide(description: "Three pedagogical guided speaking questions for an English learner: 1 for visual scene, 1 for narrative interpretation, 1 for emotional impact.")
    public var guidedPrompts: [String]

    @Guide(description: "4-6 evocative mood or atmosphere adjectives.")
    public var suggestedFeelings: [String]

    public init(
        sceneDescription: String,
        guidedPrompts: [String],
        suggestedFeelings: [String]
    ) {
        self.sceneDescription = sceneDescription
        self.guidedPrompts = guidedPrompts
        self.suggestedFeelings = suggestedFeelings
    }
}

