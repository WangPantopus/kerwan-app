import Foundation

extension Date {
    /// Thread-safe ISO 8601 formatter with fractional seconds.
    ///
    /// Produces strings like `"2024-03-15T14:30:00.123Z"`. Uses UTC timezone
    /// and fractional seconds for sub-second precision in database storage
    /// and log output.
    private static let iso8601FractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter
    }()

    /// Thread-safe ISO 8601 formatter without fractional seconds (fallback).
    private static let iso8601BasicFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Formats this date as an ISO 8601 string with fractional seconds in UTC.
    ///
    /// Example output: `"2024-03-15T14:30:00.123Z"`
    ///
    /// - Returns: An ISO 8601 formatted string.
    public var iso8601String: String {
        Self.iso8601FractionalFormatter.string(from: self)
    }

    /// Parses an ISO 8601 date string, with or without fractional seconds.
    ///
    /// Accepts both `"2024-03-15T14:30:00.123Z"` and `"2024-03-15T14:30:00Z"`.
    ///
    /// - Parameter string: An ISO 8601 formatted date string.
    /// - Returns: The parsed `Date`, or `nil` if the string is malformed.
    public static func fromISO8601(_ string: String) -> Date? {
        iso8601FractionalFormatter.date(from: string)
            ?? iso8601BasicFormatter.date(from: string)
    }
}
