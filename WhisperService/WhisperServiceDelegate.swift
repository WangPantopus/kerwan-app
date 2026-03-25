// WhisperServiceDelegate.swift
// WhisperService — XPC service target
//
// NSXPCListenerDelegate implementation.
//
// One `WhisperTranscriptionEngine` instance is created per incoming
// connection.  This matches the "per-connection state" model: if two
// windows both connect to the service, each gets its own engine and its
// own loaded model copy.  In practice Kerwan has one connection from the
// main app; this separation is defensive isolation.

import Foundation
import os

// MARK: - WhisperServiceDelegate

final class WhisperServiceDelegate: NSObject, NSXPCListenerDelegate {

    private let log = Logger(
        subsystem: "com.kerwan.WhisperService",
        category:  "Listener"
    )

    // MARK: NSXPCListenerDelegate

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        log.info("New XPC connection from pid=\(connection.processIdentifier)")

        // Configure the exported interface.
        connection.exportedInterface = WhisperServiceProtocol.xpcInterface()

        // Each connection gets its own engine instance.
        let engine = WhisperTranscriptionEngine()
        connection.exportedObject = engine

        // Optional: log connection lifecycle for debugging.
        connection.invalidationHandler = { [weak self] in
            self?.log.info("Connection invalidated (pid=\(connection.processIdentifier))")
        }
        connection.interruptionHandler = { [weak self] in
            self?.log.warning("Connection interrupted (pid=\(connection.processIdentifier))")
        }

        connection.resume()
        return true
    }
}
