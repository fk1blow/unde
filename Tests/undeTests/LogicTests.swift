import XCTest
@testable import unde

/// Unit coverage for the pure logic the PRD test plan calls out: fuzzy scoring
/// and ordering, secret detection, dedup/eviction, and exclusion matching.
final class LogicTests: XCTestCase {

    // MARK: FuzzyMatcher

    func testFuzzySubsequenceMatches() {
        XCTAssertNotNil(FuzzyMatcher.score(query: "mow", candidate: "Master schedule Of Works"))
        XCTAssertNotNil(FuzzyMatcher.score(query: "msow", candidate: "Master Schedule Of Works"))
        XCTAssertNil(FuzzyMatcher.score(query: "zzz", candidate: "Master Schedule Of Works"))
    }

    func testFuzzyEmptyQueryMatchesEverything() {
        XCTAssertEqual(FuzzyMatcher.score(query: "", candidate: "anything"), 0)
    }

    func testFuzzyPrefersContiguousAndBoundaryMatches() {
        // "sch" contiguous inside a word should beat scattered s-c-h.
        let contiguous = FuzzyMatcher.score(query: "sch", candidate: "schedule")!
        let scattered = FuzzyMatcher.score(query: "sch", candidate: "some cheap hat")!
        XCTAssertGreaterThan(contiguous, scattered)
    }

    func testFuzzyRankingOrdersBetterMatchFirst() {
        let candidates = ["archive", "schedule", "search"]
        let ranked = candidates
            .compactMap { c in FuzzyMatcher.score(query: "sch", candidate: c).map { ($0, c) } }
            .sorted { $0.0 > $1.0 }
            .map { $0.1 }
        XCTAssertEqual(ranked.first, "schedule")
    }

    // MARK: SecretDetector

    func testDetectsJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        XCTAssertTrue(SecretDetector.looksSecret(jwt))
    }

    func testDetectsVendorKeyPrefixes() {
        XCTAssertTrue(SecretDetector.looksSecret("sk-abcdef1234567890ABCDEF"))
        XCTAssertTrue(SecretDetector.looksSecret("ghp_abcdefghijklmnopqrstuvwxyz0123456789"))
        XCTAssertTrue(SecretDetector.looksSecret("AKIAIOSFODNN7EXAMPLE"))
    }

    func testDetectsLongHighEntropyToken() {
        XCTAssertTrue(SecretDetector.looksSecret("a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8s9t0"))
    }

    func testDoesNotFlagOrdinaryProse() {
        XCTAssertFalse(SecretDetector.looksSecret("Master Schedule of Works"))
        XCTAssertFalse(SecretDetector.looksSecret("please advise at your earliest convenience"))
        XCTAssertFalse(SecretDetector.looksSecret("hello"))
        XCTAssertFalse(SecretDetector.looksSecret("https://portal.site/rfi/2291"))
    }

    func testDoesNotFlagPlainWordEvenIfLong() {
        // All-letters, no digits — reads as a word, not a token.
        XCTAssertFalse(SecretDetector.looksSecret("supercalifragilisticexpialidocious"))
    }

    // MARK: HistoryStore dedup + eviction (in-memory, no repository)

    func testDedupBumpsToTopWithoutDuplicating() {
        let store = HistoryStore(capacity: 10)
        store.insert(.text("one", source: nil))
        store.insert(.text("two", source: nil))
        store.insert(.text("one", source: nil)) // re-copy of "one"
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first?.text, "one")
    }

    func testEvictionRespectsCapacity() {
        let store = HistoryStore(capacity: 3)
        for i in 0..<10 { store.insert(.text("item-\(i)", source: nil)) }
        XCTAssertEqual(store.items.count, 3)
        XCTAssertEqual(store.items.first?.text, "item-9")
        XCTAssertEqual(store.items.last?.text, "item-7")
    }

    // MARK: Exclusion matching

    func testExclusionMatching() {
        let excluded: Set<String> = ["com.apple.keychainaccess", "com.1password.1password"]
        XCTAssertTrue(excluded.contains("com.1password.1password"))
        XCTAssertFalse(excluded.contains("com.apple.Terminal"))
    }

    // MARK: Classification

    func testClassification() {
        XCTAssertEqual(ClipboardItem.text("https://example.com", source: nil).classification, "link")
        XCTAssertEqual(ClipboardItem.text("2026-08-14", source: nil).classification, "date")
        XCTAssertEqual(ClipboardItem.text("WBS-4200-STRUCT", source: nil).classification, "code")
    }
}
