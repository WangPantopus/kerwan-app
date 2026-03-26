import Foundation
import os
import KerwanXPCProtocol

/// NSXPCListenerDelegate for the WhisperService XPC process.
///
/// Accepts incoming connections from the main Kerwan app and vends a
/// ``WhisperServiceHandler`` instance for each connection.
///
/// The exported interface is configured with ``makeWhisperXPCInterface()``
/// so that the `[Data]` array in the `transcribe` reply is allowlisted by
/// the XPC sandbox on both sides of the connection.
final class WhisperServiceDelegate: NSObject, NSXPCListenerDelegate {
    private static let logger = Logger(
        subsystem: "com.kerwan.app.whisper-service",
        category: "ServiceDelegate"
    )

    /// Accepts or rejects incoming XPC connections.
    ///
    /// Configures the exported interface and object, then resumes the
    /// connection. Each connection receives its own ``WhisperServiceHandler``
    /// instance so model state is not shared across callers.
    ///
    /// - Parameters:
    ///   - listener: The XPC listener receiving the connection.
    ///   - newConnection: The incoming connection from the main app.
    /// - Returns: `true` to accept the connection.
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        Self.logger.info("Accepting new XPC connection from pid \(newConnection.processIdentifier)")

        // Use the shared factory so the sandbox allows [NSData] in transcribe reply.
        newConnection.exportedInterface = makeWhisperXPCInterface()
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
