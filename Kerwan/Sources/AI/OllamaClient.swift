import Foundation
import os

/// A lightweight, `Sendable` HTTP client for communicating with a local Ollama server.
///
/// `OllamaClient` covers the subset of the Ollama REST API used by Kerwan:
/// token-streaming text generation, JSON-constrained generation, single and batch
/// embedding, model listing, and model pulling with progress reporting.
///
/// All requests time out after 120 seconds to accommodate slow LLM inference. The
/// client is a plain `struct` — stateless, value-typed, and safe to copy across
/// task and actor boundaries.
///
/// Usage:
/// ```swift
/// let client = OllamaClient()
/// let reply = try await client.complete(
///     prompt: "Summarise this meeting transcript: ...",
///     system: "You are a concise assistant.",
///     model: "llama3:8b-instruct-q4_K_M"
/// )
/// ```
public struct OllamaClient: Sendable {

    // MARK: - Properties

    /// The base URL of the Ollama server. Default: `http://127.0.0.1:11434`.
    public let baseURL: URL

    private let session: URLSession
    private static let logger = Logger(subsystem: "com.kerwan.app", category: "OllamaClient")

    /// Timeout for all requests. 120 s to cover slow first-token latency on large models.
    private static let requestTimeout: TimeInterval = 120

    // MARK: - Init

    /// Creates a client pointed at `baseURL` and using `session` for all requests.
    ///
    /// - Parameters:
    ///   - baseURL: Ollama server base URL. Defaults to `http://127.0.0.1:11434`.
    ///   - session: `URLSession` to use. Override in tests to inject a mock protocol.
    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Text Generation

    /// Generates a completion for `prompt` and streams the response tokens back as a single string.
    ///
    /// Uses `POST /api/generate` with `stream: true`. Tokens are accumulated from the
    /// newline-delimited JSON stream and returned as a single concatenated string once
    /// the server signals `"done": true`.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt.
    ///   - system: Optional system message prepended to the context window.
    ///   - model: Ollama model name, e.g. `"llama3:8b-instruct-q4_K_M"`.
    /// - Returns: The full generated text.
    /// - Throws: ``OllamaError`` on network failure, bad status, or a server-side error.
    public func complete(prompt: String, system: String?, model: String) async throws -> String {
        var body: [String: Any] = [
            "model":  model,
            "prompt": prompt,
            "stream": true
        ]
        if let system { body["system"] = system }

        let request = try makeRequest(path: "api/generate", jsonObject: body)
        let (bytes, response) = try await session.bytes(for: request)

        try checkHTTPResponse(response, path: "api/generate")

        var result = ""
        for try await line in bytes.lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let err = json["error"] as? String {
                throw OllamaError.serverError(err)
            }
            if let token = json["response"] as? String {
                result += token
            }
            if let done = json["done"] as? Bool, done {
                break
            }
        }
        return result
    }

    /// Generates a JSON-constrained completion, returning the parsed object.
    ///
    /// Passes `"format": "json"` to Ollama so the model output is valid JSON.
    /// The accumulated response string is parsed with `JSONSerialization` before returning.
    ///
    /// - Note: The returned `Any` is one of the standard `JSONSerialization` types
    ///   (`[String: Any]`, `[Any]`, `String`, `NSNumber`, `NSNull`). Decode it into a
    ///   concrete `Codable` type before crossing actor or task boundaries to avoid
    ///   strict-concurrency warnings at call sites.
    ///
    /// - Parameters:
    ///   - prompt: The user prompt.
    ///   - system: Optional system message.
    ///   - model: Ollama model name.
    /// - Returns: The parsed JSON object.
    /// - Throws: ``OllamaError`` on failure, or if the accumulated text is not valid JSON.
    public func completeJSON(prompt: String, system: String?, model: String) async throws -> Any {
        var body: [String: Any] = [
            "model":  model,
            "prompt": prompt,
            "stream": true,
            "format": "json"
        ]
        if let system { body["system"] = system }

        let request = try makeRequest(path: "api/generate", jsonObject: body)
        let (bytes, response) = try await session.bytes(for: request)

        try checkHTTPResponse(response, path: "api/generate")

        var accumulated = ""
        for try await line in bytes.lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let err = json["error"] as? String {
                throw OllamaError.serverError(err)
            }
            if let token = json["response"] as? String {
                accumulated += token
            }
            if let done = json["done"] as? Bool, done {
                break
            }
        }

        guard
            let jsonData = accumulated.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: jsonData)
        else {
            throw OllamaError.invalidResponse(
                "Response is not valid JSON. First 200 chars: \(accumulated.prefix(200))"
            )
        }
        return parsed
    }

    // MARK: - Embeddings

    /// Generates a single embedding vector for `text`.
    ///
    /// Uses `POST /api/embeddings` (Ollama's single-prompt endpoint) and returns
    /// a `[Float]` representation of the 768-dimensional vector produced by
    /// `nomic-embed-text`.
    ///
    /// - Parameters:
    ///   - text: The text to embed.
    ///   - model: Embedding model name, e.g. `"nomic-embed-text"`.
    /// - Returns: Embedding vector as `[Float]`.
    /// - Throws: ``OllamaError`` on failure.
    public func embed(text: String, model: String) async throws -> [Float] {
        let body: [String: Any] = ["model": model, "prompt": text]
        let request = try makeRequest(path: "api/embeddings", jsonObject: body)
        let (data, response) = try await session.data(for: request)

        try checkHTTPResponse(response, path: "api/embeddings")
        try checkServerError(in: data, path: "api/embeddings")

        struct EmbeddingsResponse: Decodable {
            let embedding: [Double]
        }
        let decoded = try decode(EmbeddingsResponse.self, from: data, path: "api/embeddings")
        return decoded.embedding.map(Float.init)
    }

    /// Generates embedding vectors for multiple texts in a single request.
    ///
    /// Uses `POST /api/embed` (Ollama ≥ 0.1.26), which accepts an array of inputs
    /// and returns a corresponding array of embeddings. More efficient than calling
    /// ``embed(text:model:)`` in a loop for large batches.
    ///
    /// - Parameters:
    ///   - texts: Array of texts to embed. Must not be empty.
    ///   - model: Embedding model name, e.g. `"nomic-embed-text"`.
    /// - Returns: Array of embedding vectors, one per input text, in the same order.
    /// - Throws: ``OllamaError`` on failure.
    public func embedBatch(texts: [String], model: String) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        let body: [String: Any] = ["model": model, "input": texts]
        let request = try makeRequest(path: "api/embed", jsonObject: body)
        let (data, response) = try await session.data(for: request)

        try checkHTTPResponse(response, path: "api/embed")
        try checkServerError(in: data, path: "api/embed")

        struct EmbedResponse: Decodable {
            let embeddings: [[Double]]
        }
        let decoded = try decode(EmbedResponse.self, from: data, path: "api/embed")
        return decoded.embeddings.map { $0.map(Float.init) }
    }

    // MARK: - Model Management

    /// Returns `true` if the Ollama server is running and accepting requests.
    ///
    /// A HEAD request to `/api/tags` is used as the health probe. Any network
    /// error or non-2xx response returns `false`.
    public func isHealthy() async -> Bool {
        guard let url = URL(string: "api/tags", relativeTo: baseURL) else { return false }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// Lists all models currently available in the local Ollama registry.
    ///
    /// - Returns: Array of ``OllamaModel`` values.
    /// - Throws: ``OllamaError`` on network failure or unexpected response shape.
    public func listModels() async throws -> [OllamaModel] {
        guard let url = URL(string: "api/tags", relativeTo: baseURL) else {
            throw OllamaError.invalidResponse("Could not construct URL for api/tags")
        }
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        try checkHTTPResponse(response, path: "api/tags")
        try checkServerError(in: data, path: "api/tags")

        struct TagsResponse: Decodable {
            let models: [OllamaModel]
        }
        let decoded = try decode(TagsResponse.self, from: data, path: "api/tags")
        return decoded.models
    }

    /// Pulls a model from the Ollama registry, streaming download progress.
    ///
    /// Calls `POST /api/pull` with `stream: true` and reports fractional progress
    /// (0.0 – 1.0) via the `progress` callback as each NDJSON chunk arrives.
    /// The callback receives `1.0` on completion. If the pull fails, the error
    /// message from Ollama is surfaced through ``OllamaError/modelPullFailed(model:message:)``.
    ///
    /// - Parameters:
    ///   - name: Fully-qualified model name, e.g. `"llama3:8b-instruct-q4_K_M"`.
    ///   - progress: Called on every streamed progress update with a value in `[0, 1]`.
    /// - Throws: ``OllamaError`` on failure.
    public func pullModel(
        name: String,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let body: [String: Any] = ["name": name, "stream": true]
        let request = try makeRequest(path: "api/pull", jsonObject: body)
        let (bytes, response) = try await session.bytes(for: request)

        try checkHTTPResponse(response, path: "api/pull")

        struct PullChunk: Decodable {
            let status: String
            let completed: Int64?
            let total: Int64?
            let error: String?
        }

        for try await line in bytes.lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8)
            else { continue }

            let chunk: PullChunk
            do {
                chunk = try JSONDecoder().decode(PullChunk.self, from: data)
            } catch {
                Self.logger.warning("Unparseable pull chunk: \(line, privacy: .public)")
                continue
            }

            if let err = chunk.error {
                throw OllamaError.modelPullFailed(model: name, message: err)
            }

            if chunk.status == "success" {
                progress(1.0)
                return
            }

            if let completed = chunk.completed, let total = chunk.total, total > 0 {
                progress(Double(completed) / Double(total))
            }
        }
    }

    // MARK: - Private Helpers

    /// Builds a `URLRequest` for a JSON POST to `path` with the given JSON-serialisable body.
    private func makeRequest(path: String, jsonObject: Any) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw OllamaError.invalidResponse("Could not construct URL for path: \(path)")
        }
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonObject)
        return request
    }

    /// Validates that `response` is an HTTP 2xx response, otherwise throws ``OllamaError``.
    private func checkHTTPResponse(_ response: URLResponse, path: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse("Non-HTTP response from \(path)")
        }
        guard (200...299).contains(http.statusCode) else {
            throw OllamaError.requestFailed(statusCode: http.statusCode, body: "")
        }
    }

    /// Inspects `data` for an Ollama `{"error": "..."}` envelope and throws if found.
    private func checkServerError(in data: Data, path: String) throws {
        struct ErrorEnvelope: Decodable { let error: String }
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            throw OllamaError.serverError(envelope.error)
        }
    }

    /// Decodes `data` as `T`, wrapping any decoding error in ``OllamaError/invalidResponse(_:)``.
    private func decode<T: Decodable>(_ type: T.Type, from data: Data, path: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            let preview = String(data: data, encoding: .utf8)?.prefix(200) ?? "<binary>"
            throw OllamaError.invalidResponse(
                "Failed to decode \(T.self) from \(path). Body: \(preview). Error: \(error)"
            )
        }
    }
}
