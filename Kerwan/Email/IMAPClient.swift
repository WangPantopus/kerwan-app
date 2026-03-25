// IMAPClient.swift
// Kerwan — Email capture layer
//
// Minimal IMAP4rev1 client built on Network.framework with TLS.
//
// Supported commands (exactly what EmailCaptureService needs)
// ──────────────────────────────────────────────────────────
//   AUTHENTICATE XOAUTH2  (initial-response form, RFC 4959)
//   SELECT <mailbox>
//   UID SEARCH SINCE <date>
//   UID FETCH <uid-set> (UID BODY.PEEK[HEADER.FIELDS (...)] BODY.PEEK[TEXT]<0.N>)
//   LOGOUT
//
// Response parsing
// ────────────────
// IMAP responses mix text lines (terminated by CRLF) with literal byte
// sequences announced as `{N}` at the end of a line, followed by exactly
// N octets.  `IMAPConnection.readSegments(untilTag:)` accumulates the full
// command response as an array of `IMAPResponseSegment` — each segment is
// one text line plus its optional trailing literal bytes.  Higher-level
// parsers inspect the text and literal fields to reconstruct messages.
//
// Thread safety
// ─────────────
// `IMAPConnection` is an actor that owns the `NWConnection` and its
// receive buffer.  `IMAPClient` is a separate actor that serialises
// command sequences on top of an `IMAPConnection`.  External callers only
// ever touch `IMAPClient` (or the injectable `IMAPClientProtocol`).

import Foundation
import Network
import os

// MARK: - IMAPAddress

/// A parsed RFC 5322 mailbox address.
public struct IMAPAddress: Sendable, Codable, Equatable {
    public let name: String?
    public let email: String

    public init(name: String?, email: String) {
        self.name  = name
        self.email = email
    }

    public var displayString: String {
        if let n = name, !n.isEmpty { return "\(n) <\(email)>" }
        return email
    }
}

// MARK: - IMAPMessage

/// One IMAP message as returned by `fetchMessages(uids:)`.
public struct IMAPMessage: Sendable {
    public let uid:             UInt32
    public let messageId:       String?
    public let from:            [IMAPAddress]
    public let to:              [IMAPAddress]
    public let cc:              [IMAPAddress]
    public let subject:         String?
    public let date:            Date?
    public let bodyText:        String?
    public let hasAttachments:  Bool
    public let isBodyCorrupted: Bool
}

// MARK: - IMAPError

public enum IMAPError: Error, Sendable, Equatable {
    case connectionFailed(String)
    case authenticationFailed(String)
    case commandFailed(String)
    case invalidResponse(String)
    case connectionClosed
    case timeout
}

// MARK: - IMAPClientProtocol

/// Injectable interface so `EmailCaptureService` is testable without
/// a live TCP connection.
public protocol IMAPClientProtocol: AnyActor {
    var isConnected: Bool { get async }
    func connect(host: String, port: UInt16) async throws
    func authenticate(email: String, accessToken: String) async throws
    func selectMailbox(_ mailbox: String) async throws
    func searchUIDs(since date: Date) async throws -> [UInt32]
    func fetchMessages(uids: [UInt32]) async throws -> [IMAPMessage]
    func logout() async
}

// MARK: - IMAPResponseSegment (internal)

/// One logical IMAP response unit: the text line plus any trailing literal.
struct IMAPResponseSegment {
    let text:    String
    let literal: Data?   // non-nil when the text line ended with `{N}`
}

// MARK: - IMAPConnection

/// Actor that owns one `NWConnection` and its read buffer.
///
/// `readSegments(untilTag:)` reads until the tagged completion line, handling
/// all literal strings inline.
actor IMAPConnection {

    // MARK: State

    private let connection: NWConnection
    private var buffer = Data()
    private let log = Logger(subsystem: "com.kerwan.app", category: "IMAPConnection")

    // MARK: Init

    init(host: String, port: UInt16) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw IMAPError.connectionFailed("Invalid port \(port)")
        }
        let params = NWParameters.tls
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            using: params
        )
    }

    // MARK: Lifecycle

    /// Starts the TLS connection and waits for `.ready`.
    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume()
                case .failed(let err):
                    resumed = true
                    cont.resume(throwing: IMAPError.connectionFailed(err.localizedDescription))
                case .cancelled:
                    resumed = true
                    cont.resume(throwing: IMAPError.connectionClosed)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .background))
        }
    }

    func cancel() { connection.cancel() }

    // MARK: Read primitives

    private func receiveChunk() async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, error in
                if let error = error {
                    cont.resume(throwing: IMAPError.connectionFailed(error.localizedDescription))
                } else if let data = data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete {
                    cont.resume(throwing: IMAPError.connectionClosed)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    /// Reads until `\r\n`, filling the internal buffer as needed.
    /// Returns the line without the trailing CRLF.
    func readLine() async throws -> String {
        let crlf = Data([0x0D, 0x0A])
        while true {
            if let range = buffer.range(of: crlf) {
                let lineData = buffer[..<range.lowerBound]
                buffer.removeSubrange(..<range.upperBound)
                return String(data: lineData, encoding: .utf8)
                    ?? String(data: lineData, encoding: .isoLatin1)
                    ?? ""
            }
            let chunk = try await receiveChunk()
            if !chunk.isEmpty { buffer.append(chunk) }
        }
    }

    /// Reads exactly `count` bytes, filling the buffer as needed.
    func readBytes(_ count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        while buffer.count < count {
            let chunk = try await receiveChunk()
            if !chunk.isEmpty { buffer.append(chunk) }
        }
        let result = Data(buffer[..<count])
        buffer.removeSubrange(..<count)
        return result
    }

    // MARK: Write

    func write(_ text: String) async throws {
        guard let data = text.data(using: .utf8) else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err = err { cont.resume(throwing: err) }
                else { cont.resume() }
            })
        }
    }

    // MARK: Segment reader

    /// Accumulates all response lines (handling literals) until the tagged
    /// completion response (OK / NO / BAD) is seen.
    /// Throws `IMAPError.commandFailed` on NO or BAD.
    func readSegments(untilTag tag: String) async throws -> [IMAPResponseSegment] {
        var segments: [IMAPResponseSegment] = []
        while true {
            var line = try await readLine()

            // Check for literal {N} at end of line.
            if let literalSize = extractLiteralSize(from: &line) {
                let literal = try await readBytes(literalSize)
                segments.append(IMAPResponseSegment(text: line, literal: literal))
                continue   // more response data follows
            }

            segments.append(IMAPResponseSegment(text: line, literal: nil))

            // Check for tagged completion.
            if line.hasPrefix("\(tag) ") {
                if line.hasPrefix("\(tag) NO") || line.hasPrefix("\(tag) BAD") {
                    throw IMAPError.commandFailed(line)
                }
                break
            }
        }
        return segments
    }

    // MARK: Private helpers

    /// If `line` ends with `{N}`, removes the `{N}` suffix and returns N.
    private func extractLiteralSize(from line: inout String) -> Int? {
        guard line.hasSuffix("}"),
              let openBrace = line.lastIndex(of: "{")
        else { return nil }

        let sizeStr = line[line.index(after: openBrace)...].dropLast()  // remove "}"
        guard let size = Int(sizeStr) else { return nil }

        line = String(line[..<openBrace])
        return size
    }
}

// MARK: - IMAPClient

/// Production `IMAPClientProtocol` implementation.
///
/// One `IMAPClient` per account session.  Create a new one when reconnecting.
public actor IMAPClient: IMAPClientProtocol {

    // MARK: State

    private var conn:        IMAPConnection?
    private var tagCounter:  Int = 0

    public var isConnected: Bool { conn != nil }

    private let log = Logger(subsystem: "com.kerwan.app", category: "IMAPClient")

    public init() {}

    // MARK: - IMAPClientProtocol

    public func connect(host: String, port: UInt16) async throws {
        let c = try IMAPConnection(host: host, port: port)
        try await c.start()
        _ = try await c.readLine()   // consume server greeting
        conn = c
        log.info("IMAP connected to \(host, privacy: .public):\(port)")
    }

    public func authenticate(email: String, accessToken: String) async throws {
        guard let c = conn else { throw IMAPError.connectionFailed("Not connected") }

        // Build XOAUTH2 initial response: user=<email>\x01auth=Bearer <token>\x01\x01
        let authPayload = "user=\(email)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        let base64 = Data(authPayload.utf8).base64EncodedString()

        let tag = nextTag()
        try await c.write("\(tag) AUTHENTICATE XOAUTH2 \(base64)\r\n")

        do {
            _ = try await c.readSegments(untilTag: tag)
        } catch IMAPError.commandFailed(let msg) {
            throw IMAPError.authenticationFailed(msg)
        }
        log.info("IMAP authenticated as \(email, privacy: .private)")
    }

    public func selectMailbox(_ mailbox: String) async throws {
        guard let c = conn else { throw IMAPError.connectionFailed("Not connected") }
        let tag = nextTag()
        try await c.write("\(tag) SELECT \"\(mailbox)\"\r\n")
        _ = try await c.readSegments(untilTag: tag)
        log.info("IMAP selected mailbox: \(mailbox, privacy: .public)")
    }

    public func searchUIDs(since date: Date) async throws -> [UInt32] {
        guard let c = conn else { throw IMAPError.connectionFailed("Not connected") }
        let dateStr = IMAPClient.imapDateFormatter.string(from: date)
        let tag = nextTag()
        try await c.write("\(tag) UID SEARCH SINCE \(dateStr)\r\n")
        let segs = try await c.readSegments(untilTag: tag)
        let uids = parseSearchResponse(segs)
        log.info("IMAP UID SEARCH SINCE \(dateStr, privacy: .public) → \(uids.count) UIDs")
        return uids
    }

    public func fetchMessages(uids: [UInt32]) async throws -> [IMAPMessage] {
        guard !uids.isEmpty else { return [] }
        guard let c = conn else { throw IMAPError.connectionFailed("Not connected") }

        let uidSet = uids.map(String.init).joined(separator: ",")
        let fields = "BODY.PEEK[HEADER.FIELDS (MESSAGE-ID FROM TO CC SUBJECT DATE CONTENT-TYPE CONTENT-TRANSFER-ENCODING)]"
        let body   = "BODY.PEEK[TEXT]<0.5000>"
        let tag    = nextTag()

        try await c.write("\(tag) UID FETCH \(uidSet) (UID \(fields) \(body))\r\n")
        let segs     = try await c.readSegments(untilTag: tag)
        let messages = parseFetchResponses(segs)
        log.debug("IMAP fetched \(messages.count)/\(uids.count) messages")
        return messages
    }

    public func logout() async {
        guard let c = conn else { return }
        conn = nil
        let tag = nextTag()
        try? await c.write("\(tag) LOGOUT\r\n")
        // Don't bother reading the response — just cancel.
        await c.cancel()
        log.info("IMAP logged out")
    }

    // MARK: - Private: tag generation

    private func nextTag() -> String {
        tagCounter += 1
        return String(format: "K%04d", tagCounter)
    }

    // MARK: - Private: SEARCH response parsing

    private func parseSearchResponse(_ segments: [IMAPResponseSegment]) -> [UInt32] {
        for seg in segments {
            let t = seg.text
            guard t.hasPrefix("* SEARCH") else { continue }
            // "* SEARCH 1 2 3 ..." or "* SEARCH" (no results)
            let parts = t.split(separator: " ").dropFirst(2)
            return parts.compactMap { UInt32($0) }
        }
        return []
    }

    // MARK: - Private: FETCH response parsing

    private func parseFetchResponses(_ segments: [IMAPResponseSegment]) -> [IMAPMessage] {
        var messages:      [IMAPMessage] = []
        var uid:           UInt32?
        var headerLiteral: Data?
        var bodyLiteral:   Data?
        var inFetch = false

        for seg in segments {
            let t = seg.text

            // New FETCH item: "* N FETCH (...)"
            if t.hasPrefix("* "), t.contains(" FETCH ") {
                // Finalize the previous item if we got its headers
                if inFetch, let msg = buildMessage(uid: uid, headerData: headerLiteral, bodyData: bodyLiteral) {
                    messages.append(msg)
                }
                inFetch        = true
                uid            = extractUID(from: t)
                headerLiteral  = nil
                bodyLiteral    = nil
            }

            guard inFetch else { continue }

            if t.contains("BODY[HEADER"), let lit = seg.literal {
                headerLiteral = lit
                if uid == nil { uid = extractUID(from: t) }
            }

            if t.contains("BODY[TEXT"), let lit = seg.literal {
                bodyLiteral = lit
            }

            // Closing ")" ends the current FETCH item.
            if t.trimmingCharacters(in: .whitespaces) == ")" {
                if let msg = buildMessage(uid: uid, headerData: headerLiteral, bodyData: bodyLiteral) {
                    messages.append(msg)
                }
                inFetch        = false
                uid            = nil
                headerLiteral  = nil
                bodyLiteral    = nil
            }
        }

        // Handle the (unlikely) case where the last item had no closing ")"
        if inFetch, let msg = buildMessage(uid: uid, headerData: headerLiteral, bodyData: bodyLiteral) {
            messages.append(msg)
        }

        return messages
    }

    // MARK: - Private: message construction

    private func buildMessage(uid: UInt32?, headerData: Data?, bodyData: Data?) -> IMAPMessage? {
        guard let uid = uid, let headerData = headerData else { return nil }

        let headers = parseHeaders(headerData)
        let cte     = headers["content-transfer-encoding"]
        let ct      = headers["content-type"] ?? ""

        let (bodyText, isCorrupted) = decodeBody(bodyData, transferEncoding: cte)
        let finalText = bodyText.map { ct.lowercased().contains("text/html") ? stripHTML($0) : $0 }

        return IMAPMessage(
            uid:             uid,
            messageId:       normaliseMessageId(headers["message-id"]),
            from:            parseAddresses(headers["from"]),
            to:              parseAddresses(headers["to"]),
            cc:              parseAddresses(headers["cc"]),
            subject:         headers["subject"].map { decodeEncodedWords($0) },
            date:            headers["date"].flatMap { parseEmailDate($0) },
            bodyText:        finalText.map { String($0.prefix(5000)) },
            hasAttachments:  ct.lowercased().contains("multipart/mixed"),
            isBodyCorrupted: isCorrupted
        )
    }

    // MARK: - Private: header parsing

    private func parseHeaders(_ data: Data) -> [String: String] {
        let text   = String(data: data, encoding: .utf8)
                  ?? String(data: data, encoding: .isoLatin1)
                  ?? ""
        let lines  = text.components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        var key:     String?
        var value    = ""

        for line in lines {
            if line.isEmpty { break }
            if let first = line.first, first == " " || first == "\t" {
                // Folded continuation
                value += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                if let k = key {
                    headers[k.lowercased()] = value.trimmingCharacters(in: .whitespaces)
                }
                key   = String(line[..<colon])
                value = String(line[line.index(after: colon)...])
            }
        }
        if let k = key {
            headers[k.lowercased()] = value.trimmingCharacters(in: .whitespaces)
        }
        return headers
    }

    // MARK: - Private: address parsing

    private func parseAddresses(_ raw: String?) -> [IMAPAddress] {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return [] }
        return splitAddresses(raw).compactMap { parseOneAddress($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func splitAddresses(_ s: String) -> [String] {
        var parts:   [String] = []
        var current  = ""
        var depth    = 0
        var inQuote  = false

        for ch in s {
            switch ch {
            case "\"" where !inQuote: inQuote = true;  current.append(ch)
            case "\"" where inQuote:  inQuote = false; current.append(ch)
            case "<"  where !inQuote: depth += 1; current.append(ch)
            case ">"  where !inQuote: depth -= 1; current.append(ch)
            case ","  where depth == 0 && !inQuote:
                parts.append(current); current = ""
            default: current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private func parseOneAddress(_ s: String) -> IMAPAddress? {
        if let lt = s.lastIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let email = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            let name  = String(s[..<lt])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !email.isEmpty else { return nil }
            return IMAPAddress(name: name.isEmpty ? nil : name, email: email)
        }
        if s.contains("@") {
            return IMAPAddress(name: nil, email: s)
        }
        return nil
    }

    // MARK: - Private: body decoding

    private func decodeBody(_ data: Data?, transferEncoding: String?) -> (String?, Bool) {
        guard let data = data, !data.isEmpty else { return (nil, false) }
        let enc = (transferEncoding ?? "").lowercased().trimmingCharacters(in: .whitespaces)

        switch enc {
        case "base64":
            let cleaned = (String(data: data, encoding: .ascii) ?? "")
                .filter { !$0.isWhitespace }
            if let decoded = Data(base64Encoded: cleaned) {
                let text = String(data: decoded, encoding: .utf8)
                        ?? String(data: decoded, encoding: .isoLatin1)
                return (text, text == nil)
            }
            return (nil, true)

        case "quoted-printable":
            let text = decodeQuotedPrintable(data)
            return (text, text == nil)

        default:
            let text = String(data: data, encoding: .utf8)
                    ?? String(data: data, encoding: .isoLatin1)
            return (text, text == nil)
        }
    }

    private func decodeQuotedPrintable(_ data: Data) -> String? {
        var result = Data()
        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == 0x3D, data.index(after: i) < data.endIndex {  // '='
                let i1 = data.index(after: i)
                let i2 = data.index(after: i1)
                if i2 < data.endIndex {
                    let h = String(format: "%c%c", data[i1], data[i2])
                    if let byte = UInt8(h, radix: 16) {
                        result.append(byte); i = data.index(after: i2); continue
                    }
                }
                // Soft line break (=\r\n or =\n)
                if data[i1] == 0x0D || data[i1] == 0x0A {
                    i = i2 < data.endIndex && data[i1] == 0x0D ? data.index(after: i2) : i2
                    continue
                }
            }
            result.append(data[i]); i = data.index(after: i)
        }
        return String(data: result, encoding: .utf8) ?? String(data: result, encoding: .isoLatin1)
    }

    // MARK: - Private: HTML stripping

    private func stripHTML(_ html: String) -> String {
        var s = html
        let opts: String.CompareOptions = [.regularExpression, .caseInsensitive]
        s = s.replacingOccurrences(of: "(?s)<style[^>]*>.*?</style>", with: " ", options: opts)
        s = s.replacingOccurrences(of: "(?s)<script[^>]*>.*?</script>", with: " ", options: opts)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&amp;",  with: "&")
        s = s.replacingOccurrences(of: "&lt;",   with: "<")
        s = s.replacingOccurrences(of: "&gt;",   with: ">")
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;",  with: "'")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private: RFC 2047 encoded-word decoding

    /// Decodes RFC 2047 encoded words like `=?UTF-8?B?<base64>?=` or `=?UTF-8?Q?<qp>?=`.
    private func decodeEncodedWords(_ s: String) -> String {
        var result = s
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        while let range = result.range(of: pattern, options: .regularExpression) {
            let match = String(result[range])
            let parts = match.dropFirst(2).dropLast(2).components(separatedBy: "?")
            guard parts.count >= 3 else { break }
            let charset  = parts[0]
            let encoding = parts[1].uppercased()
            let encoded  = parts[2]
            let enc      = String.Encoding(ianaCharsetName: charset)

            var decoded: String?
            if encoding == "B", let data = Data(base64Encoded: encoded) {
                decoded = String(data: data, encoding: enc ?? .utf8)
            } else if encoding == "Q" {
                let qpData = Data((encoded.replacingOccurrences(of: "_", with: " ")).utf8)
                decoded = decodeQuotedPrintable(qpData)
            }

            result = result.replacingCharacters(in: range, with: decoded ?? match)
        }
        return result
    }

    // MARK: - Private: date parsing

    private func parseEmailDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        for fmt in IMAPClient.emailDateFormatters {
            if let date = fmt.date(from: trimmed) { return date }
        }
        return nil
    }

    // MARK: - Private: Message-ID normalisation

    private func normaliseMessageId(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Private: UID extraction

    private func extractUID(from text: String) -> UInt32? {
        guard let range = text.range(of: #"\bUID\s+(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let match = text[range]
        let parts = match.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return UInt32(parts[1])
    }

    // MARK: - Static formatters

    static let imapDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd-MMM-yyyy"
        return f
    }()

    private static let emailDateFormatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss z",
            "dd MMM yyyy HH:mm:ss z",
            "EEE, dd MMM yyyy HH:mm:ss +0000"
        ]
        return formats.map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            return f
        }
    }()
}

// MARK: - String.Encoding IANA helper

private extension String.Encoding {
    /// Converts an IANA charset name to `String.Encoding`.  Falls back to
    /// `nil` for unrecognised charsets.
    init?(ianaCharsetName: String) {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(ianaCharsetName as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        self.init(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}
