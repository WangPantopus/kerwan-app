/// MessageIO.swift — Chrome Native Messaging length-prefixed frame codec.
///
/// Chrome Native Messaging wraps every JSON message in a 4-byte **little-endian
/// unsigned 32-bit integer** that encodes the byte length of the JSON payload,
/// followed immediately by the UTF-8-encoded JSON body.
///
/// ```
/// ┌──────────────┬───────────────────────────────┐
/// │  length (4B) │  JSON body (length bytes, UTF-8) │
/// └──────────────┴───────────────────────────────┘
/// ```
///
/// This module provides:
/// - `readMessage(from:)` — read one frame from a `FileHandle`
/// - `writeMessage(_:to:)` — write one frame to a `FileHandle`
///
/// Both functions throw on I/O error or if the payload exceeds 1 MiB
/// (Chrome's own limit).

import Foundation

enum MessageIOError: Error {
    case eof
    case payloadTooLarge(Int)
    case readFailed(Int)
}

private let maxPayload = 1 * 1024 * 1024  // 1 MiB — Chrome's hard cap

/// Reads one length-prefixed message frame from `handle`.
///
/// - Returns: The raw UTF-8 JSON data for the message body.
/// - Throws: `MessageIOError.eof` if stdin is closed; other errors on failure.
func readMessage(from handle: FileHandle) throws -> Data {
    // Read 4-byte little-endian length.
    let lengthData = handle.readData(ofLength: 4)
    guard lengthData.count == 4 else { throw MessageIOError.eof }

    let length = Int(
        UInt32(lengthData[0]) |
        (UInt32(lengthData[1]) << 8) |
        (UInt32(lengthData[2]) << 16) |
        (UInt32(lengthData[3]) << 24)
    )

    guard length <= maxPayload else { throw MessageIOError.payloadTooLarge(length) }
    guard length > 0 else { throw MessageIOError.eof }

    let body = handle.readData(ofLength: length)
    guard body.count == length else { throw MessageIOError.readFailed(body.count) }
    return body
}

/// Writes one length-prefixed message frame to `handle`.
///
/// - Parameter data: UTF-8 JSON bytes to send.
func writeMessage(_ data: Data, to handle: FileHandle) throws {
    guard data.count <= maxPayload else {
        throw MessageIOError.payloadTooLarge(data.count)
    }
    let length = UInt32(data.count)
    var lengthLE = length.littleEndian
    let lengthData = Data(bytes: &lengthLE, count: 4)
    handle.write(lengthData)
    handle.write(data)
}
