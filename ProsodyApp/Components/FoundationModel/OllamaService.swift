import Foundation
import Combine

// MARK: - Ollama Data Models

public struct OllamaModelInfo: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public let name: String
    public let sizeBytes: Int64
    public var sizeFormatted: String {
        let gb = Double(sizeBytes) / 1_073_741_824.0
        return String(format: "%.1f GB", gb)
    }
}

// MARK: - OllamaService

/// Centralized service coordinating communication with the local Ollama daemon.
/// Handles connection health checks, installed model discovery, non-streaming prompt generation,
/// and Server-Sent Events (SSE) streaming chat completions over native URLSession.
@MainActor
public final class OllamaService: ObservableObject {
    public static let shared = OllamaService()

    @Published public var isConnected: Bool = false
    @Published public var connectionDetail: String = "Not checked"
    @Published public var availableModels: [OllamaModelInfo] = []
    @Published public var isChecking: Bool = false

    private let urlSession: URLSession

    public init(session: URLSession = .shared) {
        self.urlSession = session
    }

    // MARK: - Health Check & Model Discovery

    /// Tests the Ollama daemon connection and retrieves all locally cached models.
    @discardableResult
    public func checkConnection(endpoint: String? = nil) async -> (isOnline: Bool, models: [OllamaModelInfo]) {
        let base = (endpoint ?? STTSettings.shared.ollamaEndpoint).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(base)/api/tags") else {
            self.isConnected = false
            self.connectionDetail = "Invalid endpoint URL"
            return (false, [])
        }

        self.isChecking = true

        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                self.isConnected = false
                self.connectionDetail = "Ollama returned HTTP error"
                self.isChecking = false
                return (false, [])
            }

            struct TagsResponse: Decodable {
                struct ModelItem: Decodable {
                    let name: String
                    let size: Int64?
                }
                let models: [ModelItem]?
            }

            let tags = try JSONDecoder().decode(TagsResponse.self, from: data)
            let models = (tags.models ?? []).map {
                OllamaModelInfo(name: $0.name, sizeBytes: $0.size ?? 0)
            }

            self.availableModels = models
            self.isConnected = true
            self.connectionDetail = "Connected (\(models.count) model\(models.count == 1 ? "" : "s") installed)"
            self.isChecking = false

            if STTSettings.shared.llmProvider == .ollama && !models.isEmpty {
                if !models.contains(where: { $0.name == STTSettings.shared.ollamaModel }) {
                    if let first = models.first {
                        STTSettings.shared.ollamaModel = first.name
                    }
                }
            }
            return (true, models)
        } catch {
            self.isConnected = false
            self.connectionDetail = "Ollama offline (\(error.localizedDescription))"
            self.isChecking = false
            return (false, [])
        }
    }

    // MARK: - Single-Turn Text Generation

    /// Generates a complete text response via Ollama's OpenAI-compatible endpoint.
    public func generate(
        prompt: String,
        instructions: String? = nil,
        model: String? = nil,
        maxTokens: Int? = nil,
        temperature: Float? = nil,
        endpoint: String? = nil
    ) async throws -> String {
        let base = (endpoint ?? STTSettings.shared.ollamaEndpoint).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: "\(base)/v1/chat/completions") else {
            throw URLError(.badURL)
        }

        let selectedModel = model ?? STTSettings.shared.ollamaModel

        var messages: [[String: String]] = []
        if let instr = instructions, !instr.isEmpty {
            messages.append(["role": "system", "content": instr])
        }
        messages.append(["role": "user", "content": prompt])

        var payload: [String: Any] = [
            "model": selectedModel,
            "messages": messages,
            "stream": false
        ]

        if let maxTokens = maxTokens {
            payload["max_tokens"] = maxTokens
            var options: [String: Any] = ["num_predict": maxTokens]
            if let temp = temperature { options["temperature"] = temp }
            payload["options"] = options
        } else if let temp = temperature {
            payload["temperature"] = temp
            payload["options"] = ["temperature": temp]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.timeoutInterval = 60.0

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP error"
            throw NSError(domain: "OllamaService", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        struct ChatResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                }
                let message: Message
            }
            let choices: [Choice]
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content else {
            throw NSError(domain: "OllamaService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Ollama returned empty response"])
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Streaming Chat Completion

    /// Streams response tokens chunk-by-chunk using Server-Sent Events (SSE) over native URLSession.
    public func streamChat(
        messages: [(role: String, content: String)],
        instructions: String? = nil,
        model: String? = nil,
        maxTokens: Int? = nil,
        temperature: Float? = nil,
        endpoint: String? = nil
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let base = (endpoint ?? STTSettings.shared.ollamaEndpoint).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let url = URL(string: "\(base)/v1/chat/completions") else {
                        continuation.finish(throwing: URLError(.badURL))
                        return
                    }

                    let selectedModel = model ?? STTSettings.shared.ollamaModel

                    var apiMessages: [[String: String]] = []
                    if let instr = instructions, !instr.isEmpty {
                        apiMessages.append(["role": "system", "content": instr])
                    }
                    for msg in messages {
                        apiMessages.append(["role": msg.role, "content": msg.content])
                    }

                    var payload: [String: Any] = [
                        "model": selectedModel,
                        "messages": apiMessages,
                        "stream": true
                    ]

                    if let maxTokens = maxTokens {
                        payload["max_tokens"] = maxTokens
                        var options: [String: Any] = ["num_predict": maxTokens]
                        if let temp = temperature { options["temperature"] = temp }
                        payload["options"] = options
                    } else if let temp = temperature {
                        payload["temperature"] = temp
                        payload["options"] = ["temperature": temp]
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                    request.timeoutInterval = 120.0

                    let (bytes, response) = try await urlSession.bytes(for: request)
                    guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                        continuation.finish(throwing: NSError(
                            domain: "OllamaService",
                            code: 3,
                            userInfo: [NSLocalizedDescriptionKey: "Ollama streaming returned HTTP error"]
                        ))
                        return
                    }

                    struct StreamChunk: Decodable {
                        struct Choice: Decodable {
                            struct Delta: Decodable {
                                let content: String?
                            }
                            let delta: Delta
                        }
                        let choices: [Choice]
                    }

                    for try await line in bytes.lines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard trimmed.hasPrefix("data:") else { continue }
                        let payloadStr = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)

                        if payloadStr == "[DONE]" {
                            break
                        }

                        guard let data = payloadStr.data(using: .utf8) else { continue }
                        if let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                           let contentDelta = chunk.choices.first?.delta.content,
                           !contentDelta.isEmpty {
                            continuation.yield(contentDelta)
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
