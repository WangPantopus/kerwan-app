import Foundation
import os

/// Unix domain socket server that accepts connections from `kerwan-nmh`.
///
/// Chrome spawns `kerwan-nmh` when the extension connects. The NMH binary
/// connects to this socket and relays NM-framed JSON messages in both
/// directions.
///
/// Each inbound message is decoded into a ``RawEvent`` (source `.browser`) and
/// posted on `NotificationCenter` as `.kerwanBrowserRawEvent`. Downstream
/// consumers — typically `AppLifecycle` once wired to storage — persist events
/// from there.
///
/// ## Socket path
/// `~/Library/Application Support/Kerwan/chrome-bridge.sock`
///
/// ## Inbound message schema
/// ```json
/// {
///   "type": "linkedin_profile" | "gmail_thread",
///   "url": "https://...",
///   "timestamp": 1711363200.0,
///   "data": { ... }
/// }
/// ```
actor NativeMessagingBridge {

    private static let logger = Logger(
        subsystem: "com.kerwan.app",
        category: "NativeMessagingBridge"
    )

    // ─── State ────────────────────────────────────────────────────────────────

    private var serverFD: Int32 = -1
    private var listenerTask: Task<Void, Never>?
    private var connectedClientFD: Int32 = -1

    /// Set to `true` while a client is connected.
    private(set) var isClientConnected: Bool = false

    // ─── Init ─────────────────────────────────────────────────────────────────

    init() {}

    // ─── Start / Stop ─────────────────────────────────────────────────────────

    func start() {
        guard listenerTask == nil else { return }
        listenerTask = Task { await runAcceptLoop() }
        Self.logger.info("NativeMessagingBridge started on \(Self.socketPath, privacy: .public)")
    }

    func stop() {
        listenerTask?.cancel()
        listenerTask = nil
        closeClient()
        if serverFD >= 0 {
            Darwin.close(serverFD)
            serverFD = -1
        }
        try? FileManager.default.removeItem(atPath: Self.socketPath)
        Self.logger.info("NativeMessagingBridge stopped")
    }

    // ─── Socket path ──────────────────────────────────────────────────────────

    static var socketPath: String {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Kerwan")
            .appendingPathComponent("chrome-bridge.sock")
            .path
            ?? "/tmp/kerwan-chrome-bridge.sock"
    }

    // ─── Accept loop ──────────────────────────────────────────────────────────

    private func runAcceptLoop() async {
        do {
            try createServerSocket()
        } catch {
            Self.logger.error("Failed to create server socket: \(error, privacy: .public)")
            return
        }

        while !Task.isCancelled {
            let clientFD = Darwin.accept(serverFD, nil, nil)
            if Task.isCancelled { break }
            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                Self.logger.error("accept() failed errno=\(errno, privacy: .public)")
                try? await Task.sleep(for: .seconds(1))
                continue
            }

            Self.logger.info("NMH client connected (fd=\(clientFD, privacy: .public))")
            connectedClientFD = clientFD
            isClientConnected = true
            await notifyConnectionChange(connected: true)

            await serveClient(fd: clientFD)

            Darwin.close(clientFD)
            if connectedClientFD == clientFD {
                connectedClientFD = -1
                isClientConnected = false
            }
            Self.logger.info("NMH client disconnected")
            await notifyConnectionChange(connected: false)
        }
    }

    private func createServerSocket() throws {
        try? FileManager.default.removeItem(atPath: Self.socketPath)

        let dir = (Self.socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw BridgeError.socketFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Self.socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, b) in pathBytes.enumerated() { dest[i] = b }
            }
        }
        let addrLen = socklen_t(
            MemoryLayout<sa_family_t>.size + Self.socketPath.utf8.count + 1
        )
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, addrLen)
            }
        }
        guard bindResult == 0 else {
            Darwin.close(sock)
            throw BridgeError.bindFailed(errno)
        }
        guard Darwin.listen(sock, 1) == 0 else {
            Darwin.close(sock)
            throw BridgeError.listenFailed(errno)
        }
        serverFD = sock
    }

    // ─── Per-client serving ───────────────────────────────────────────────────

    private func serveClient(fd: Int32) async {
        while !Task.isCancelled {
            var lenBuf = [UInt8](repeating: 0, count: 4)
            guard readExact(fd: fd, buf: &lenBuf, count: 4) else { break }

            let length = Int(
                UInt32(lenBuf[0]) |
                (UInt32(lenBuf[1]) << 8) |
                (UInt32(lenBuf[2]) << 16) |
                (UInt32(lenBuf[3]) << 24)
            )
            guard length > 0, length <= 1_048_576 else { break }

            var body = [UInt8](repeating: 0, count: length)
            guard readExact(fd: fd, buf: &body, count: length) else { break }

            handleMessage(Data(body))
            await Task.yield()
        }
    }

    private func readExact(fd: Int32, buf: inout [UInt8], count: Int) -> Bool {
        var total = 0
        while total < count {
            let n = buf.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress! + total, count - total)
            }
            if n <= 0 { return false }
            total += n
        }
        return true
    }

    // ─── Message handling ─────────────────────────────────────────────────────

    private func handleMessage(_ data: Data) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String,
            let url  = json["url"]  as? String
        else {
            Self.logger.debug("NMH: malformed message, ignoring")
            return
        }

        let timestamp = (json["timestamp"] as? Double)
            .map { Date(timeIntervalSince1970: $0) } ?? Date()

        // Store the full message as metadataJSON for downstream classification.
        let metadataJSON: String?
        if let encoded = try? JSONSerialization.data(withJSONObject: json),
           let str = String(data: encoded, encoding: .utf8) {
            metadataJSON = str
        } else {
            metadataJSON = nil
        }

        // Build a human-readable rawText from the data payload.
        let payloadData = json["data"] as? [String: Any] ?? [:]
        let rawText = buildRawText(type: type, url: url, payload: payloadData)

        let event = RawEvent(
            source: .browser,
            sourceApp: "Chrome",
            startedAt: timestamp,
            rawText: rawText,
            metadataJSON: metadataJSON
        )

        Self.logger.debug("NMH: created \(type, privacy: .public) event for \(url, privacy: .private)")

        // Publish for downstream consumers (storage, classification).
        let eventCopy = event
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .kerwanBrowserRawEvent,
                object: nil,
                userInfo: [BrowserEventKey.rawEvent: eventCopy]
            )
        }
    }

    private func buildRawText(
        type: String,
        url: String,
        payload: [String: Any]
    ) -> String {
        var parts: [String] = []
        switch type {
        case "linkedin_profile":
            if let name     = payload["name"]     as? String { parts.append(name) }
            if let headline = payload["headline"] as? String { parts.append(headline) }
            if let company  = payload["company"]  as? String { parts.append(company) }
            if let title    = payload["title"]    as? String { parts.append(title) }
            parts.append(url)
        case "gmail_thread":
            if let subject = payload["subject"] as? String { parts.append(subject) }
            if let snippet = payload["snippet"] as? String { parts.append(snippet) }
            if let participants = payload["participants"] as? [[String: Any]] {
                let names = participants.compactMap { $0["name"] as? String }
                if !names.isEmpty { parts.append("Participants: " + names.joined(separator: ", ")) }
            }
        default:
            parts.append(url)
        }
        return parts.joined(separator: "\n")
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private func closeClient() {
        if connectedClientFD >= 0 {
            Darwin.close(connectedClientFD)
            connectedClientFD = -1
        }
        isClientConnected = false
    }

    private func notifyConnectionChange(connected: Bool) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .kerwanBrowserExtensionConnectionChanged,
                object: nil,
                userInfo: ["connected": connected]
            )
        }
    }
}

// MARK: - Notifications & Keys

enum BrowserEventKey {
    static let rawEvent = "rawEvent"
}

extension Notification.Name {
    /// Posted when the Chrome extension's NMH connects or disconnects.
    static let kerwanBrowserExtensionConnectionChanged =
        Notification.Name("com.kerwan.app.browserExtensionConnectionChanged")

    /// Posted for every browser `RawEvent` received from the Chrome extension.
    /// `userInfo[BrowserEventKey.rawEvent]` holds the `RawEvent` value.
    static let kerwanBrowserRawEvent =
        Notification.Name("com.kerwan.app.browserRawEvent")
}

// MARK: - Errors

private enum BridgeError: Error {
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}
