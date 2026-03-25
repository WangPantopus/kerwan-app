import Foundation

/// Pure, stateless helpers for computing string similarity using the
/// Levenshtein edit-distance algorithm.
///
/// All operations work on `[Unicode.Scalar]` arrays so that multi-scalar
/// characters (e.g., emoji, composite glyphs) are handled correctly without
/// silent truncation.
///
/// Before comparison, strings are normalised with `.caseInsensitive` and
/// `.diacriticInsensitive` folding so that "Café" and "cafe" are considered
/// equivalent.
enum LevenshteinDistance {

    // MARK: - Public API

    /// Returns the normalised similarity in `[0.0, 1.0]` between `a` and `b`.
    ///
    /// Similarity is computed as `1 - editDistance / max(len(a), len(b))`.
    /// Identical strings return `1.0`; completely dissimilar strings approach `0.0`.
    ///
    /// **40 % length optimisation:** if one string is more than 2.5× longer than
    /// the other (`shorter / longer < 0.4`), the function returns `0.0` immediately
    /// without constructing the DP table. This prevents false positives between
    /// strings of very different lengths and avoids allocating large matrices.
    ///
    /// - Parameters:
    ///   - a: First string. May be any language or script.
    ///   - b: Second string.
    /// - Returns: Similarity score in `[0.0, 1.0]`.
    static func similarity(_ a: String, _ b: String) -> Double {
        let na = normalise(a)
        let nb = normalise(b)

        // Both empty → identical.
        guard !na.isEmpty || !nb.isEmpty else { return 1.0 }
        // One empty → completely dissimilar.
        guard !na.isEmpty, !nb.isEmpty   else { return 0.0 }

        // 40 % length optimisation: skip DP when lengths differ by more than 2.5×.
        let longer  = Double(max(na.count, nb.count))
        let shorter = Double(min(na.count, nb.count))
        guard shorter / longer >= 0.4 else { return 0.0 }

        let dist = editDistance(na, nb)
        return 1.0 - Double(dist) / longer
    }

    // MARK: - Private: Normalisation

    /// Folds a string to case- and diacritic-insensitive unicode scalars.
    private static func normalise(_ string: String) -> [Unicode.Scalar] {
        let folded = string.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return Array(folded.unicodeScalars)
    }

    // MARK: - Private: DP edit distance

    /// Standard Levenshtein edit-distance computed with two alternating rows,
    /// avoiding an O(m × n) allocation.
    ///
    /// Swaps `a` and `b` internally so the outer loop always iterates over the
    /// longer string and the inner loop (and array allocation) over the shorter.
    private static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        // Ensure `a` is the longer sequence so `b` (inner) allocates fewer cells.
        if a.count < b.count { return editDistance(b, a) }

        let m = a.count
        let n = b.count

        // prev[j] = edit distance between a[0..<i] and b[0..<j]
        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    curr[j] = prev[j - 1]              // no operation needed
                } else {
                    curr[j] = 1 + min(
                        prev[j],      // deletion  (remove a[i-1])
                        curr[j - 1],  // insertion (insert b[j-1])
                        prev[j - 1]   // substitution
                    )
                }
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }
}
