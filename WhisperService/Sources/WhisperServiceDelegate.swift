import Foundation
import os
import KerwanXPCProtocol

/// Entry point for the WhisperService XPC service process.
///
/// This class sets up the NSXPCListener and handles incoming connections
/// from the main Kerwan app. Each connection gets its own instance of
/// ``WhisperServiceHandler`` to process transcription requests.
final class WhisperServiceDelegate: NSObject, NSXPCListenerDelegate {
    private static let logger = Logger(
        subsystem: "com.kerwan.app.whisper-service",
        category: "ServiceDelegate"
    )

    /// Accepts or rejects incoming XPC connections.
    ///
    /// Configures the connection's exported interface and object, then resumes it.
    /// - Parameters:
    ///   - listener: The XPC listener receiving the connection.
    ///   - newConnection: The incoming connection from the main app.
    /// - Returns: `true` to accept the connection, `false` to reject it.
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        Self.logger.info("Accepting new XPC connection")

        let exportedInterface = NSXPCInterface(with: WhisperServiceProtocol.self)
        newConnection.exportedInterface = exportedInterface
        newConnection.exportedObject = WhisperServiceHandler()

        newConnection.invalidationHandler = {
            Self.logger.info("XPC connection invalidated")
        }

        newConnection.interruptionHandler = {
            Self.logger.warning("XPC connection interrupted")
        }

        newConnection.resume()
        return true
    }
}

