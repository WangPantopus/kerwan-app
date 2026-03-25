// EmailCaptureMetadata.swift
// Kerwan — Email capture layer
//
// JSON payload for RawEvents with source == .email.
// Embedded in RawEvent.metadataJSON alongside a `rawText` field that
// combines subject/from/to/body for downstream search and classification.

import Foundation

// MARK: - EmailCaptureMetadata

/// Metadata embedded in an `.email` RawEvent's `metadataJSON` field.
///
/// Keys use snake_case to match the ClassificationActor's expectations
/// and the eventual SQLite schema.
public struct EmailCaptureMetadata: Codable, Sendable, Equatable {

    // MARK: Fields

    /// The IMAP Message-ID header (without angle brackets), used for deduplication.
    public let messageId: String?

    /// Parsed sender address(es).
    public let from: [IMAPAddress]

    /// Parsed recipient address(es).
    public let to: [IMAPAddress]

    /// Parsed CC address(es).
    public let cc: [IMAPAddress]

    /// Decoded email subject.
    public let subject: String?

    /// The email's RFC 2822 date.
    public let date: Date?

    /// First 2 000 characters of plain-text body (HTML stripped).
    public let bodyPreview: String?

    /// `true` when the body was truncated to `bodyPreview`.
    public let isBodyTruncated: Bool

    /// `true` when the body could not be decoded correctly.
    public let isBodyCorrupted: Bool

    /// `true` when the message has at least one attachment.
    public let hasAttachments: Bool

    /// Formatted raw text intended for the AI classification pipeline:
    /// `"Subject: …\nFrom: …\nTo: …\n\n<bodyPreview>"`.
    public let rawText: String?

    // MARK: CodingKeys

    enum CodingKeys: String, CodingKey {
        case messageId        = "message_id"
        case from
        case to
        case cc
        case subject
        case date
        case bodyPreview      = "body_preview"
        case isBodyTruncated  = "is_body_truncated"
        case isBodyCorrupted  = "is_body_corrupted"
        case hasAttachments   = "has_attachments"
        case rawText          = "raw_text"
    }

    // MARK: Init

    public init(
        messageId:       String?,
        from:            [IMAPAddress],
        to:              [IMAPAddress],
        cc:              [IMAPAddress],
        subject:         String?,
        date:            Date?,
        bodyPreview:     String?,
        isBodyTruncated: Bool,
        isBodyCorrupted: Bool,
        hasAttachments:  Bool,
        rawText:         String?
    ) {
        self.messageId       = messageId
        self.from            = from
        self.to              = to
        self.cc              = cc
        self.subject         = subject
        self.date            = date
        self.bodyPreview     = bodyPreview
        self.isBodyTruncated = isBodyTruncated
        self.isBodyCorrupted = isBodyCorrupted
        self.hasAttachments  = hasAttachments
        self.rawText         = rawText
    }

    // MARK: JSON helpers

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Encodes to a compact JSON string; returns `nil` on failure.
    public var jsonString: String? {
        guard let data = try? Self.encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Decodes from a JSON string; returns `nil` on failure.
    public static func decode(from json: String) -> EmailCaptureMetadata? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(EmailCaptureMetadata.self, from: data)
    }
}

// MARK: - Builder

extension EmailCaptureMetadata {

    /// Builds an `EmailCaptureMetadata` from a raw `IMAPMessage`.
    static func from(_ message: IMAPMessage) -> EmailCaptureMetadata {
        let fullBody    = message.bodyText ?? ""
        let preview     = String(fullBody.prefix(2000))
        let isTruncated = fullBody.count > 2000

        let rawText = buildRawText(
            subject: message.subject,
            from:    message.from,
            to:      message.to,
            body:    preview
        )

        return EmailCaptureMetadata(
            messageId:       message.messageId,
            from:            message.from,
            to:              message.to,
            cc:              message.cc,
            subject:         message.subject,
            date:            message.date,
            bodyPreview:     preview.isEmpty ? nil : preview,
            isBodyTruncated: isTruncated,
            isBodyCorrupted: message.isBodyCorrupted,
            hasAttachments:  message.hasAttachments,
            rawText:         rawText.isEmpty ? nil : rawText
        )
    }

    private static func buildRawText(
        subject: String?,
        from:    [IMAPAddress],
        to:      [IMAPAddress],
        body:    String
    ) -> String {
        var lines: [String] = []
        if let s = subject, !s.isEmpty { lines.append("Subject: \(s)") }
        if let f = from.first { lines.append("From: \(f.displayString)") }
        if !to.isEmpty { lines.append("To: \(to.map(\.displayString).joined(separator: ", "))") }
        lines.append("")
        if !body.isEmpty { lines.append(body) }
        return lines.joined(separator: "\n")
    }
}
