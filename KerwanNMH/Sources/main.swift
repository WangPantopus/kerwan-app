/// main.swift — kerwan-nmh Native Messaging Host
///
/// Chrome Native Messaging Host binary. Chrome spawns this process and
/// communicates via stdin/stdout using the 4-byte LE length-prefix framing
/// defined in `MessageIO.swift`.
///
/// Architecture:
///
/// ```
///  Chrome Extension  ──stdin──▶  kerwan-nmh  ──socket──▶  Kerwan.app
///                    ◀─stdout──              ◀─socket──
/// ```
///
/// The NMH is a pure relay:
///   1. Read a JSON message from stdin (Chrome → NMH).
///   2. Forward it verbatim to the Kerwan Unix domain socket.
///   3. If the socket sends a reply, write it back to stdout (NMH → Chrome).
///
/// The NMH reconnects to the socket on every message if the connection is lost.
/// Chrome will kill this process when the extension disconnects; the app side
/// treats a closed socket connection as a normal disconnect.

import Foundation

let stdin  = FileHandle.standardInput
let stdout = FileHandle.standardOutput
let stderr = FileHandle.standardError

func log(_ msg: String) {
    var data = (msg + "\n").data(using: .utf8)!
    stderr.write(data)
}

// ─── Main relay loop ──────────────────────────────────────────────────────────

let bridge = SocketBridge()

func ensureConnected() -> Bool {
    if bridge.isConnected { return true }
    do {
        try bridge.connect()
        log("[kerwan-nmh] Connected to Kerwan socket")
        return true
    } catch {
        log("[kerwan-nmh] Socket connect failed: \(error)")
        return false
    }
}

// Spawn a background thread to relay socket → stdout.
Thread.detachNewThread {
    while true {
        guard bridge.isConnected else {
            Thread.sleep(forTimeInterval: 0.5)
            continue
        }
        do {
            let data = try bridge.receiveMessage()
            try writeMessage(data, to: stdout)
        } catch {
            log("[kerwan-nmh] Socket read error: \(error) — disconnected")
            bridge.close()
        }
    }
}

// Main thread: stdin → socket relay.
while true {
    do {
        let data = try readMessage(from: stdin)
        if ensureConnected() {
            do {
                try bridge.sendMessage(data)
            } catch {
                log("[kerwan-nmh] Socket send failed: \(error)")
                bridge.close()
                // Try once more immediately.
                if ensureConnected() {
                    try? bridge.sendMessage(data)
                }
            }
        }
    } catch MessageIOError.eof {
        log("[kerwan-nmh] stdin closed — exiting")
        bridge.close()
        exit(0)
    } catch {
        log("[kerwan-nmh] stdin read error: \(error)")
        bridge.close()
        exit(1)
    }
}
