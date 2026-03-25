// OAuthCallbackServer.swift
// Kerwan — Email capture layer
//
// Lightweight localhost HTTP server that receives the single OAuth 2.0
// authorization-code callback from the system browser and then shuts down.
//
// Lifecycle
// ─────────
//   1. `GmailOAuthManager` creates the server and calls `waitForCallback(timeout:)`.
//   2. `waitForCallback` starts an `NWListener` on port 8089, stores a
//      `CheckedContinuation`, and suspends.
//   3. When the browser hits GET /callback?code=…&state=…, the listener
//      handler parses the query, resumes the continuation, and sends a
//      one-shot HTML "You may close this tab" response before stopping.
//   4. If `timeout` elapses first, a `Task` resumes the continuation with
//      `.flowTimeout` and stops the listener.
//
// Only one callback is ever accepted.  A `hasFired` flag (actor-isolated)
// prevents double-resumption if the browser retries the request.
//
// The server deliberately does NOT support persistent connections, TLS, or
// any method other than GET; it is a one-shot local loopback helper.

import Foundation
import Network

// MARK: - OAuthCallbackResult

/// The parsed query parameters from the browser redirect.
public struct OAuthCallbackResult: Sendable, Equatable {
    public let code:  String
    public let state: String
}

// MARK: - OAuthCallbackServing

/// Injectable protocol for `OAuthCallbackServer`; lets tests inject a mock.
public protocol OAuthCallbackServing: AnyActor {
    /// Starts the listener and suspends until the browser delivers the callback.
    /// - Parameter timeout: Maximum wait (default 5 min).
    /// - Returns: Parsed `OAuthCallbackResult` on success.
    /// - Throws: `GmailOAuthError.serverStartFailed` if the port is busy,
    ///           `GmailOAuthError.flowTimeout` on expiry, or
    ///           `GmailOAuthError.authorizationDenied` if the query has `error=`.
    func waitForCallback(timeout: TimeInterval) async throws -> OAuthCallbackResult

    /// Cancels the server immediately (safe to call multiple times).
    func stop() async
}

// MARK: - OAuthCallbackServer

/// Production NWListener-based implementation of `OAuthCallbackServing`.
public actor OAuthCallbackServer: OAuthCallbackServing {

    // MARK: - Constants

    static let port: NWEndpoint.Port = 8089
    static let callbackPath = "/callback"

    // MARK: - State

    private var listener:     NWListener?
    private var continuation: CheckedContinuation<OAuthCallbackResult, Error>?
    private var timeoutTask:  Task<Void, Never>?
    private var hasFired:     Bool = false

    // MARK: - Init

    public init() {}

    // MARK: - OAuthCallbackServing

    public func waitForCallback(timeout: TimeInterval = 300) async throws -> OAuthCallbackResult {
        precondition(continuation == nil, "waitForCallback called twice")

        return try await withCheckedThrowingContinuation { cont in
            self.continuation = cont

            do {
                try self.startListener()
            } catch {
                self.continuation = nil
                cont.resume(throwing: error)
                return
            }

            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.handleTimeout()
            }
        }
    }

    public func stop() async {
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil
    }

    // MARK: - Private: listener setup

    private func startListener() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let l: NWListener
        do {
            l = try NWListener(using: params, on: Self.port)
        } catch {
            throw GmailOAuthError.serverStartFailed(error.localizedDescription)
        }

        l.newConnectionHandler = { [weak self] connection in
            Task { await self?.handleConnection(connection) }
        }

        l.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state {
                Task { await self?.resumeWithError(GmailOAuthError.serverStartFailed(err.localizedDescription)) }
            }
        }

        l.start(queue: .global(qos: .userInitiated))
        listener = l
    }

    // MARK: - Private: connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))

        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else { return }
            let request = String(data: data, encoding: .utf8) ?? ""
            Task { await self.handleRequest(request, on: connection) }
        }
    }

    private func handleRequest(_ rawRequest: String, on connection: NWConnection) async {
        guard !hasFired else {
            connection.cancel()
            return
        }

        // Parse the request line: "GET /callback?code=…&state=… HTTP/1.1"
        let firstLine = rawRequest.components(separatedBy: "\r\n").first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else { connection.cancel(); return }

        let path = parts[1]    // e.g. "/callback?code=…&state=…"
        let result = parseCallback(from: path)

        // Send HTML response before stopping, so the browser gets a reply.
        let html = htmlResponse(isSuccess: result != nil)
        sendHTTPResponse(html, on: connection) {
            connection.cancel()
        }

        switch result {
        case .success(let cbResult):
            await resumeWithSuccess(cbResult)
        case .failure(let error):
            await resumeWithError(error)
        case .none:
            await resumeWithError(GmailOAuthError.authorizationDenied("Unrecognized callback path"))
        }
    }

    // MARK: - Private: query parsing

    private func parseCallback(from path: String) -> Result<OAuthCallbackResult, Error>? {
        guard let urlComponents = URLComponents(string: "http://localhost\(path)"),
              urlComponents.path == Self.callbackPath
        else { return nil }

        let items = urlComponents.queryItems ?? []
        let params = Dictionary(uniqueKeysWithValues: items.compactMap { i -> (String, String)? in
            guard let v = i.value else { return nil }
            return (i.name, v)
        })

        // Error response from Google
        if let error = params["error"] {
            return .failure(GmailOAuthError.authorizationDenied(error))
        }

        guard let code  = params["code"],
              let state = params["state"]
        else { return nil }

        return .success(OAuthCallbackResult(code: code, state: state))
    }

    // MARK: - Private: HTTP response

    private func sendHTTPResponse(_ body: String, on connection: NWConnection, completion: @escaping () -> Void) {
        let bodyData  = body.data(using: .utf8) ?? Data()
        let header    = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        let response  = (header.data(using: .utf8) ?? Data()) + bodyData

        connection.send(content: response, completion: .contentProcessed { _ in completion() })
    }

    private func htmlResponse(isSuccess: Bool) -> String {
        if isSuccess {
            return """
            <!DOCTYPE html><html><head><title>Kerwan</title></head><body>
            <h2>✓ Kerwan connected to Gmail</h2>
            <p>You may close this tab and return to Kerwan.</p>
            </body></html>
            """
        } else {
            return """
            <!DOCTYPE html><html><head><title>Kerwan</title></head><body>
            <h2>Authorization failed</h2>
            <p>Return to Kerwan and try again.</p>
            </body></html>
            """
        }
    }

    // MARK: - Private: continuation management

    private func resumeWithSuccess(_ result: OAuthCallbackResult) async {
        guard !hasFired, let cont = continuation else { return }
        hasFired = true
        continuation = nil
        await stop()
        cont.resume(returning: result)
    }

    private func resumeWithError(_ error: Error) async {
        guard !hasFired, let cont = continuation else { return }
        hasFired = true
        continuation = nil
        await stop()
        cont.resume(throwing: error)
    }

    private func handleTimeout() async {
        await resumeWithError(GmailOAuthError.flowTimeout)
    }
}
