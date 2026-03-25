/// SocketBridge.swift — Unix domain socket client for kerwan-nmh.
///
/// Connects to the Kerwan main app on the well-known socket path:
///   ~/Library/Application Support/Kerwan/chrome-bridge.sock
///
/// The same 4-byte LE length-prefix framing used by Chrome Native Messaging is
/// reused on the socket, so `MessageIO` can encode/decode both sides.

import Foundation

#if canImport(Darwin)
import Darwin
#endif

enum SocketBridgeError: Error {
    case socketCreateFailed(Int32)
    case connectFailed(Int32, String)
    case sendFailed(Int32)
    case recvFailed(Int32)
    case notConnected
}

final class SocketBridge {

    static var defaultSocketPath: String {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Kerwan")
            .appendingPathComponent("chrome-bridge.sock")
            .path
        return support ?? "/tmp/kerwan-chrome-bridge.sock"
    }

    private let socketPath: String
    private var fd: Int32 = -1

    init(socketPath: String = SocketBridge.defaultSocketPath) {
        self.socketPath = socketPath
    }

    // ─── Connect ─────────────────────────────────────────────────────────────

    func connect() throws {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { throw SocketBridgeError.socketCreateFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy path bytes into sun_path (fixed-size C char array).
        let pathBytes = socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard pathBytes.count <= maxLen else {
            throw SocketBridgeError.connectFailed(-1, "socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxLen + 1) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let addrLen = socklen_t(
            MemoryLayout<sa_family_t>.size + socketPath.utf8.count + 1
        )
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, addrLen)
            }
        }
        guard result == 0 else {
            Darwin.close(sock)
            let msg = String(cString: strerror(errno))
            throw SocketBridgeError.connectFailed(errno, msg)
        }

        fd = sock
    }

    var isConnected: Bool { fd >= 0 }

    // ─── Send ────────────────────────────────────────────────────────────────

    /// Sends one NM-framed message (4-byte LE length + body) over the socket.
    func sendMessage(_ data: Data) throws {
        guard fd >= 0 else { throw SocketBridgeError.notConnected }

        var length = UInt32(data.count).littleEndian
        var header = Data(bytes: &length, count: 4)
        header.append(data)

        try header.withUnsafeBytes { buf in
            var sent = 0
            while sent < header.count {
                let n = Darwin.write(fd, buf.baseAddress! + sent, header.count - sent)
                if n <= 0 { throw SocketBridgeError.sendFailed(errno) }
                sent += n
            }
        }
    }

    // ─── Receive ─────────────────────────────────────────────────────────────

    /// Reads one NM-framed message from the socket. Blocks until data arrives.
    func receiveMessage() throws -> Data {
        guard fd >= 0 else { throw SocketBridgeError.notConnected }

        // Read 4-byte length header.
        var lenBuf = [UInt8](repeating: 0, count: 4)
        try readExact(&lenBuf, count: 4)
        let length = Int(
            UInt32(lenBuf[0]) |
            (UInt32(lenBuf[1]) << 8) |
            (UInt32(lenBuf[2]) << 16) |
            (UInt32(lenBuf[3]) << 24)
        )

        var body = [UInt8](repeating: 0, count: length)
        try readExact(&body, count: length)
        return Data(body)
    }

    private func readExact(_ buf: inout [UInt8], count: Int) throws {
        var read = 0
        while read < count {
            let n = buf.withUnsafeMutableBytes { ptr in
                Darwin.read(fd, ptr.baseAddress! + read, count - read)
            }
            if n <= 0 { throw SocketBridgeError.recvFailed(errno) }
            read += n
        }
    }

    // ─── Close ───────────────────────────────────────────────────────────────

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit { close() }
}
