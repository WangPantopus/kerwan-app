import Foundation

/// Pure, stateless helpers for preparing text before embedding.
///
/// All paths apply the same three-stage cleaning pipeline before adding the
/// nomic-embed-text prefix:
/// 1. Strip HTML tags (replaces each tag with a single space).
/// 2. Normalise whitespace (collapse runs of whitespace and newlines to a single space).
/// 3. Truncate to ``maxEmbedChars`` (≈ 512 tokens at 4 chars/token).
///
/// Two prefixes are used to improve retrieval quality with nomic-embed-text:
/// - `"search_document: "` — prepended to texts stored in the vector table.
/// - `"search_query: "` — prepended to texts used as search queries at runtime.
///
/// Transcript chunking uses a sliding window of ``chunkMaxChars`` with
/// ``chunkOverlapChars`` of overlap so long meetings are fully indexed without
/// any window losing important context at the boundary.
enum TextPreparation {

    // MARK: - Constants

    /// Maximum characters per stored embedding (≈ 512 tokens at 4 chars/token).
    static let maxEmbedChars = 2_000

    /// Maximum characters per transcript chunk (≈ 500 tokens).
    static let chunkMaxChars = 2_000

    /// Overlap between consecutive transcript chunks (≈ 50 tokens).
    static let chunkOverlapChars = 200

    /// Prefix applied to stored document embeddings.
    static let documentPrefix = "search_document: "

    /// Prefix applied to query embeddings at search time.
    static let queryPrefix = "search_query: "

    // MARK: - Public: Single-text preparation

    /// Returns a storage-ready embedding string: clean pipeline + `"search_document: "`.
    static func prepareForStorage(_ text: String) -> String {
        documentPrefix + clean(text)
    }

    /// Returns a query-ready embedding string: clean pipeline + `"search_query: "`.
    static func prepareForQuery(_ text: String) -> String {
        queryPrefix + clean(text)
    }

    // MARK: - Public: Email preparation

    /// Builds a single embedding text from an email's subject and body.
    ///
    /// Format: `"Subject: <subject>\n<first 500 chars of body>"`.
    /// Applies the full clean pipeline and prepends `"search_document: "`.
    ///
    /// - Parameters:
    ///   - subject: Email subject, if available.
    ///   - body: Raw email body text (HTML stripped if present).
    static func prepareEmail(subject: String?, body: String?) -> String {
        var parts: [String] = []
        if let s = subject, !s.isEmpty {
            parts.append("Subject: \(s)")
        }
        if let b = body, !b.isEmpty {
            parts.append(String(b.prefix(500)))
        }
        let combined = parts.joined(separator: "\n")
        return documentPrefix + clean(combined)
    }

    // MARK: - Public: Transcript chunking

    /// Splits a long text into overlapping chunks, each prepared with
    /// `"search_document: "` and ready for batch embedding.
    ///
    /// Uses a sliding window of ``chunkMaxChars`` advancing by
    /// `chunkMaxChars - chunkOverlapChars` per step.
    /// Chunk boundaries snap to the nearest word boundary (space character)
    /// within 100 chars of the target end position to avoid splitting mid-word.
    ///
    /// If the cleaned text is shorter than ``chunkMaxChars`` the function
    /// returns a single-element array.
    ///
    /// - Parameter text: Raw transcript text (may contain HTML or extra whitespace).
    /// - Returns: Array of embedding-ready strings, each with `"search_document: "` prefix.
    static func chunkForStorage(_ text: String) -> [String] {
        rawChunks(text).map { documentPrefix + $0 }
    }

    // MARK: - Public: Promise preparation

    /// Prepares a promise description for storage embedding.
    static func preparePromise(_ description: String) -> String {
        documentPrefix + clean(description)
    }

    // MARK: - Internal: raw pipeline helpers (accessible from tests)

    /// Applies the three-stage cleaning pipeline: HTML strip → whitespace norm → truncate.
    static func clean(_ text: String) -> String {
        var s = stripHTML(from: text)
        s = normalizeWhitespace(s)
        return truncate(s, maxChars: maxEmbedChars)
    }

    /// Removes HTML tags, replacing each `<...>` span with a single space.
    static func stripHTML(from text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        var inTag = false
        for ch in text {
            if ch == "<" {
                inTag = true
                output.append(" ")    // preserve word boundary
            } else if ch == ">" {
                inTag = false
            } else if !inTag {
                output.append(ch)
            }
        }
        return output
    }

    /// Collapses runs of whitespace characters (spaces, tabs, newlines) to a
    /// single ASCII space.
    static func normalizeWhitespace(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Private: helpers

    /// Truncates `text` to at most `maxChars` characters.
    private static func truncate(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        return String(text.prefix(maxChars))
    }

    /// Produces raw (un-prefixed) chunks for a transcript.
    ///
    /// Works on `[Character]` arrays for predictable index arithmetic.
    /// The sliding window advances by `chunkMaxChars - chunkOverlapChars` per
    /// step (default: 1800 chars), scanning back up to 100 chars from the
    /// window end to break at a space boundary.
    static func rawChunks(_ text: String) -> [String] {
        let cleaned = normalizeWhitespace(stripHTML(from: text))
        guard !cleaned.isEmpty else { return [] }
        guard cleaned.count > chunkMaxChars else { return [cleaned] }

        let chars = Array(cleaned)
        let stride = chunkMaxChars - chunkOverlapChars   // 1 800
        var chunks: [String] = []
        var start = 0

        while start < chars.count {
            var end = min(start + chunkMaxChars, chars.count)

            // Snap to word boundary (scan back up to 100 chars) when not at EOF.
            if end < chars.count {
                var scan = end
                let floor = max(start + 1, end - 100)
                while scan > floor {
                    scan -= 1
                    if chars[scan] == " " {
                        end = scan
                        break
                    }
                }
            }

            let chunk = String(chars[start..<end]).trimmingCharacters(in: .whitespaces)
            if !chunk.isEmpty { chunks.append(chunk) }

            if end >= chars.count { break }
            start += stride
        }

        return chunks
    }
}
