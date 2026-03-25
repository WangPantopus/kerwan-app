import XCTest
@testable import Kerwan

final class StringSQLEscapingTests: XCTestCase {

    // MARK: - sqlEscaped

    func testSQLEscapeNoSpecialChars() {
        XCTAssertEqual("hello world".sqlEscaped, "hello world")
    }

    func testSQLEscapeSingleQuote() {
        XCTAssertEqual("O'Brien".sqlEscaped, "O''Brien")
    }

    func testSQLEscapeMultipleSingleQuotes() {
        XCTAssertEqual("it's Jane's".sqlEscaped, "it''s Jane''s")
    }

    func testSQLEscapeEmptyString() {
        XCTAssertEqual("".sqlEscaped, "")
    }

    func testSQLEscapeOnlySingleQuotes() {
        XCTAssertEqual("'''".sqlEscaped, "''''''")
    }

    // MARK: - fts5Escaped

    func testFTS5EscapeNormalText() {
        XCTAssertEqual("hello world".fts5Escaped, "\"hello world\"")
    }

    func testFTS5EscapeWithDoubleQuotes() {
        XCTAssertEqual("say \"hello\"".fts5Escaped, "\"say hello\"")
    }

    func testFTS5EscapeWithSpecialChars() {
        // FTS5 operators like AND, OR, NOT, *, - should be neutralized
        // by wrapping in double quotes
        XCTAssertEqual("hello AND world".fts5Escaped, "\"hello AND world\"")
    }

    func testFTS5EscapeEmptyString() {
        XCTAssertEqual("".fts5Escaped, "\"\"")
    }
}
