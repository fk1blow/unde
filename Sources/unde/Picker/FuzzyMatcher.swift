import Foundation

/// Fuzzy subsequence matcher with a small scoring function: every query
/// character must appear in order, and matches score higher for consecutive
/// runs, word-boundary hits, and earlier positions. Fast enough to run over a
/// few thousand short strings inside a single frame.
enum FuzzyMatcher {

    /// Returns a score if `query` is a subsequence of `candidate`, else nil.
    /// Higher is better. Case-insensitive.
    static func score(query: String, candidate: String) -> Int? {
        if query.isEmpty { return 0 }

        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        guard q.count <= c.count else { return nil }

        var qi = 0
        var score = 0
        var lastMatch = -1
        var prevWasBoundary = true

        for (ci, char) in c.enumerated() {
            guard qi < q.count else { break }
            let isBoundary = prevWasBoundary
            prevWasBoundary = !char.isLetter && !char.isNumber

            if char == q[qi] {
                // Base point for a match.
                score += 1
                // Consecutive-run bonus — weighted above the boundary bonus so a
                // contiguous substring ("sch"→"schedule") beats scattered word
                // initials ("sch"→"some cheap hat"). Predictability matters more
                // than cleverness when muscle memory is the goal.
                if lastMatch == ci - 1 { score += 8 }
                // Word-boundary bonus (start of word).
                if isBoundary { score += 6 }
                // Earlier matches are slightly better.
                score += max(0, 4 - ci / 8)
                lastMatch = ci
                qi += 1
            }
        }

        return qi == q.count ? score : nil
    }

    /// Whether `query` matches `candidate` at all.
    static func matches(query: String, candidate: String) -> Bool {
        score(query: query, candidate: candidate) != nil
    }
}
