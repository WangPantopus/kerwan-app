import Foundation

extension String {
    /// Returns a copy of this string safe for use in SQL string literals.
    ///
    /// Escapes single quotes by doubling them (`'` → `''`), which is the
    /// standard SQL escaping mechanism. This does **not** add surrounding
    /// quotes — use parameterized queries (bind variables) whenever possible.
    ///
    /// This is a defense-in-depth measure for the rare cases where string
    /// interpolation into SQL is unavoidable (e.g., FTS5 MATCH expressions).
    /// For all normal queries, prefer SQLite.swift's parameterized binding API.
    ///
    /// - Returns: A string with single quotes escaped for safe SQL embedding.
    public var sqlEscaped: String {
        replacingOccurrences(of: "'", with: "''")
    }

    /// Returns a copy of this string safe for use in an FTS5 MATCH expression.
    ///
    /// FTS5 query syntax treats certain characters as operators. This method
    /// escapes them by wrapping each token in double quotes, making the
    /// search a literal phrase match.
    ///
    /// - Returns: A double-quoted string safe for FTS5 MATCH queries.
    public var fts5Escaped: String {
        // Remove any existing double quotes to prevent injection,
        // then wrap the entire string in double quotes for literal matching.
        let cleaned = replacingOccurrences(of: "\"", with: "")
        return "\"\(cleaned)\""
    }
}
