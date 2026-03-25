import XCTest
@testable import Kerwan

final class DateISO8601Tests: XCTestCase {

    func testISO8601StringFormat() {
        // Create a known date: 2024-03-15 14:30:00 UTC
        let components = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: TimeZone(identifier: "UTC"),
            year: 2024, month: 3, day: 15,
            hour: 14, minute: 30, second: 0
        )
        let date = components.date!

        let result = date.iso8601String
        XCTAssertTrue(result.hasPrefix("2024-03-15T14:30:00"))
        XCTAssertTrue(result.hasSuffix("Z"))
    }

    func testFromISO8601WithFractionalSeconds() {
        let date = Date.fromISO8601("2024-03-15T14:30:00.123Z")
        XCTAssertNotNil(date)

        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: date!)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 15)
        XCTAssertEqual(components.hour, 14)
        XCTAssertEqual(components.minute, 30)
    }

    func testFromISO8601WithoutFractionalSeconds() {
        let date = Date.fromISO8601("2024-03-15T14:30:00Z")
        XCTAssertNotNil(date)
    }

    func testFromISO8601InvalidString() {
        XCTAssertNil(Date.fromISO8601("not a date"))
        XCTAssertNil(Date.fromISO8601(""))
        XCTAssertNil(Date.fromISO8601("2024-13-45"))
    }

    func testRoundTrip() {
        let original = Date()
        let string = original.iso8601String
        let parsed = Date.fromISO8601(string)
        XCTAssertNotNil(parsed)

        // Allow up to 1ms difference due to fractional second precision
        let difference = abs(original.timeIntervalSince(parsed!))
        XCTAssertLessThan(difference, 0.001)
    }
}
