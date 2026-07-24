import Foundation

/// A kind filter typed as a leading `#token` in the picker query (FLT-1). Narrows
/// the list to one class of item; the rest of the query fuzzy-filters within it.
enum QueryScope: String, CaseIterable {
    case text, image, file, link, pinned

    /// The token the user types, e.g. `#image`.
    var token: String { "#\(rawValue)" }

    /// Parse a single word like `#image` into a scope, or nil if it isn't a known
    /// token. Case-insensitive; the leading `#` is required.
    init?(token word: String) {
        let lower = word.lowercased()
        guard lower.hasPrefix("#") else { return nil }
        self.init(rawValue: String(lower.dropFirst()))
    }

    /// Human label + hint shown on the autocomplete suggestion row (FLT-5).
    var suggestionLabel: String { token }
    var suggestionHint: String {
        switch self {
        case .text:   return "Text items"
        case .image:  return "Images"
        case .file:   return "Files"
        case .link:   return "Links"
        case .pinned: return "Pinned snippets"
        }
    }

    /// The noun for the result-count / empty-state labels, pluralised for `n`
    /// (FLT-7). e.g. "3 images", "No files".
    func countNoun(_ n: Int) -> String {
        switch self {
        case .text:   return n == 1 ? "text item" : "text items"
        case .image:  return n == 1 ? "image" : "images"
        case .file:   return n == 1 ? "file" : "files"
        case .link:   return n == 1 ? "link" : "links"
        case .pinned: return n == 1 ? "pinned snippet" : "pinned snippets"
        }
    }
    var pluralNoun: String { countNoun(2) }
}

/// The result of parsing the raw query field into a scope + residual text, or a
/// pending token completion. Kept a plain value so it's trivially testable and so
/// future scopes (`app:`, `before:`) slot in here rather than in the controller.
struct ParsedQuery: Equatable {
    /// The active kind scope, or nil when the query is unscoped.
    var scope: QueryScope?
    /// The fuzzy query that remains after stripping any scope token.
    var text: String
    /// Non-nil while the first word is a partial, unfinished token (`#`, `#im`),
    /// which drives the autocomplete list instead of results (FLT-5).
    var completing: String?
    /// The tokens matching `completing`, in declaration order.
    var suggestions: [QueryScope]

    static let empty = ParsedQuery(scope: nil, text: "", completing: nil, suggestions: [])
}

enum QueryParser {
    /// Parse the raw picker query. Precedence, in order (FLT-1, FLT-4, FLT-5):
    ///   1. exact known token as the first word            → active scope
    ///   2. a partial that prefixes ≥1 token, no space yet → completing (suggest)
    ///   3. anything else beginning with `#` (e.g. #ff0000)→ literal text search
    static func parse(_ raw: String) -> ParsedQuery {
        // Tolerate leading spaces, but keep the literal fallback faithful to input.
        let trimmedLeading = raw.drop(while: { $0 == " " })
        let literal = raw.trimmingCharacters(in: .whitespaces)

        guard trimmedLeading.first == "#" else {
            return ParsedQuery(scope: nil, text: literal, completing: nil, suggestions: [])
        }

        if let spaceIdx = trimmedLeading.firstIndex(of: " ") {
            // First word is complete (a space follows it).
            let word = String(trimmedLeading[trimmedLeading.startIndex..<spaceIdx])
            let rest = trimmedLeading[trimmedLeading.index(after: spaceIdx)...]
                .trimmingCharacters(in: .whitespaces)
            if let scope = QueryScope(token: word) {
                return ParsedQuery(scope: scope, text: rest, completing: nil, suggestions: [])
            }
            // Unknown token + space → literal (FLT-4).
            return ParsedQuery(scope: nil, text: literal, completing: nil, suggestions: [])
        }

        // No space yet — still typing the first word.
        let word = String(trimmedLeading)
        if let scope = QueryScope(token: word) {
            // Exact token, no trailing space: activate the scope immediately.
            return ParsedQuery(scope: scope, text: "", completing: nil, suggestions: [])
        }
        let matches = QueryScope.allCases.filter { $0.token.hasPrefix(word.lowercased()) }
        guard !matches.isEmpty else {
            // Not a prefix of any token (e.g. #ff0000) → literal search (FLT-4).
            return ParsedQuery(scope: nil, text: literal, completing: nil, suggestions: [])
        }
        return ParsedQuery(scope: nil, text: "", completing: word, suggestions: matches)
    }
}
