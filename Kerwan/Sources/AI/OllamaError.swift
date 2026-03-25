import Foundation

/// Errors that can occur during Ollama subprocess management or HTTP communication.
///
/// These errors map to the two layers of the Ollama integration: the subprocess lifecycle
/// managed by ``OllamaManager``, and the HTTP protocol handled by ``OllamaClient``.
public enum OllamaError: Error, LocalizedError, Sendable {

    // MARK: - Lifecycle Errors

    /// The Ollama binary could not be located on this machine.
    case notInstalled

    /// The ``Process`` failed to launch (e.g., permissions, missing binary).
    case launchFailed(underlying: any Error & Sendable)

    /// Ollama did not respond to health checks within the 30-second timeout.
    case healthCheckTimeout

    /// The subprocess crashed and the maximum number of restart attempts was reached.
    case maxRestartsExceeded

    // MARK: - Model Errors

    /// A required model could not be pulled from the registry.
    case modelPullFailed(model: String, message: String)

    /// The requested model is not available locally or was not found.
    case modelNotFound(String)

    // MARK: - HTTP / Protocol Errors

    /// The server returned a non-2xx HTTP status code.
    case requestFailed(statusCode: Int, body: String)

    /// The server response body could not be decoded as expected.
    case invalidResponse(String)

    /// Ollama returned a structured `{"error": "..."}` object in the response body.
    case serverError(String)

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Ollama is not installed. Visit https://ollama.com/download to install."
        case .launchFailed(let err):
            return "Failed to launch Ollama: \(err.localizedDescription)"
        case .healthCheckTimeout:
            return "Ollama did not start within the timeout period (30 seconds)."
        case .maxRestartsExceeded:
            return "Ollama crashed repeatedly and could not be restarted. AI features are unavailable."
        case .modelPullFailed(let model, let message):
            return "Failed to pull model '\(model)': \(message)"
        case .modelNotFound(let name):
            return "Model '\(name)' is not available. Run `ollama pull \(name)` to install it."
        case .requestFailed(let code, let body):
            let preview = body.prefix(200)
            return "HTTP request failed with status \(code): \(preview)"
        case .invalidResponse(let detail):
            return "Invalid response from Ollama: \(detail)"
        case .serverError(let message):
            return "Ollama server error: \(message)"
        }
    }
}
