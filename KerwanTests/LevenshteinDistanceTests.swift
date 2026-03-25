import XCTest
@testable import Kerwan

/// Unit tests for ``LevenshteinDistance/similarity(_:_:)`` covering edge cases
/// that are not already tested by the embedded Levenshtein assertions in
/// ``IdentityResolverTests``.
///
/// Existing coverage (not duplicated here): identical strings, completely
/// dissimilar strings, both-empty, one-empty, case-insensitive, diacritic-
/// insensitive (café/cafe), one-character substitution difference, length-
/// optimisation early exit, Chinese identical, Arabic identical, accented
/// Latin, and symmetry.
final class LevenshteinDistanceTests: XCTestCase {

    // MARK: - Single-edit operations

    /// One character is deleted from the longer string.
    func test_levenshtein_singleInsertion_highSimilarity() {
        // "hello" vs "helo": edit distance 1, max length 5 → 1 − 1/5 = 0.8
        let result = LevenshteinDistance.similarity("hello", "helo")
        XCTAssertEqual(result, 0.8, accuracy: 0.001)
    }

    /// Deletion and insertion are symmetric; both directions must agree.
    func test_levenshtein_deletionAndInsertion_symmetric() {
        let forward  = LevenshteinDistance.similarity("helo", "hello")
        let backward = LevenshteinDistance.similarity("hello", "helo")
        XCTAssertEqual(forward, backward, accuracy: 0.001)
        XCTAssertGreaterThan(forward, 0.75)
    }

    /// "kitten" → "sitting" is the canonical Levenshtein example.
    /// Edit distance = 3, max length = 7 → similarity = 1 − 3/7 ≈ 0.571.
    func test_levenshtein_kittenSitting_knownEditDistance() {
        let result = LevenshteinDistance.similarity("kitten", "sitting")
        XCTAssertEqual(result, 1.0 - 3.0 / 7.0, accuracy: 0.001)
    }

    // MARK: - Transposition

    /// A transposition (swap of two adjacent characters) is counted as two
    /// substitutions under standard Levenshtein.
    func test_levenshtein_transposition_twoEdits() {
        // "abc" vs "bac": two substitutions, max length 3 → 1 − 2/3 ≈ 0.333
        let result = LevenshteinDistance.similarity("abc", "bac")
        XCTAssertEqual(result, 1.0 - 2.0 / 3.0, accuracy: 0.001)
    }

    // MARK: - 40 % length threshold boundary

    /// When shorter/longer == exactly 0.4 the guard passes (`>=`) and the DP
    /// table is computed — the result must be > 0.
    func test_levenshtein_at40PercentBoundary_computesSimilarity() {
        // "ab" (2) vs "abcde" (5): 2/5 = 0.4 → threshold met.
        // Edit distance = 3, max = 5, similarity = 1 − 3/5 = 0.4
        let result = LevenshteinDistance.similarity("ab", "abcde")
        XCTAssertGreaterThan(result, 0.0, "Ratio = 0.4 must NOT trigger early-exit")
        XCTAssertEqual(result, 0.4, accuracy: 0.001)
    }

    /// When shorter/longer < 0.4 the function must return 0.0 immediately.
    func test_levenshtein_strictlyBelow40Percent_returnsZero() {
        // "a" (1) vs "aaaaa" (5): 1/5 = 0.2 < 0.4
        XCTAssertEqual(LevenshteinDistance.similarity("a", "aaaaa"), 0.0)
    }

    /// Another below-threshold case with non-repeated characters.
    func test_levenshtein_below40Percent_differentContent_returnsZero() {
        // "hi" (2) vs "abcdefgh" (8): 2/8 = 0.25 < 0.4
        XCTAssertEqual(LevenshteinDistance.similarity("hi", "abcdefgh"), 0.0)
    }

    // MARK: - Single-character strings

    func test_levenshtein_singleChar_identical_returns1() {
        XCTAssertEqual(LevenshteinDistance.similarity("x", "x"), 1.0)
    }

    /// Distance 1, max 1 → 1 − 1/1 = 0.0.
    func test_levenshtein_singleChar_different_returnsZero() {
        XCTAssertEqual(LevenshteinDistance.similarity("a", "b"), 0.0)
    }

    // MARK: - Number strings

    func test_levenshtein_numericStrings_identical_returns1() {
        XCTAssertEqual(LevenshteinDistance.similarity("12345", "12345"), 1.0)
    }

    func test_levenshtein_numericStrings_oneDigitOff_highSimilarity() {
        // "12345" vs "12346": 1 substitution, max 5 → 0.8
        let result = LevenshteinDistance.similarity("12345", "12346")
        XCTAssertEqual(result, 0.8, accuracy: 0.001)
    }

    // MARK: - German umlaut (distinct from café/cafe in existing tests)

    /// "Müller" normalised with diacritic-insensitive folding produces "Muller",
    /// which is identical to the second argument → similarity must be 1.0.
    func test_levenshtein_germanUmlaut_foldsToIdentical() {
        let result = LevenshteinDistance.similarity("Müller", "Muller")
        XCTAssertEqual(result, 1.0, accuracy: 0.001,
                       "ü should fold to u → identical after normalisation")
    }

    // MARK: - Emoji (multi-scalar Unicode)

    func test_levenshtein_identicalEmoji_returns1() {
        XCTAssertEqual(LevenshteinDistance.similarity("👋", "👋"), 1.0)
    }

    /// Two different single-scalar emoji: 1 substitution, max 1 → 0.0.
    func test_levenshtein_differentEmoji_returnsZero() {
        XCTAssertEqual(LevenshteinDistance.similarity("👍", "🎉"), 0.0)
    }

    // MARK: - Whitespace sensitivity

    /// Removing an internal space counts as one edit.
    func test_levenshtein_internalSpaceVsNoSpace_almostIdentical() {
        // "hello world" (11) vs "helloworld" (10): 1 deletion, max 11 → 10/11 ≈ 0.909
        let result = LevenshteinDistance.similarity("hello world", "helloworld")
        XCTAssertGreaterThan(result, 0.85)
    }

    // MARK: - Very long strings

    /// Performance guard: identical 500-character strings must return 1.0
    /// without excessive runtime.
    func test_levenshtein_longIdenticalStrings_returns1() {
        let s = String(repeating: "abcde", count: 100) // 500 chars
        XCTAssertEqual(LevenshteinDistance.similarity(s, s), 1.0)
    }

    /// A single edit in a long string produces a score very close to 1.
    func test_levenshtein_longStringsSingleEdit_nearlyIdentical() {
        let base    = String(repeating: "a", count: 99)
        let variant = base + "b"          // 100 chars, last char differs
        // The 40 % guard does not fire (same length), dist = 1, max = 100 → 0.99
        let result = LevenshteinDistance.similarity(base + "a", variant)
        XCTAssertEqual(result, 0.99, accuracy: 0.001)
    }
}
