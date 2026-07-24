import Foundation

/// Heuristic detector for strings that look like secrets — API keys, tokens,
/// JWTs, long base64 blobs. Used to optionally skip capturing them into history
/// (PRV-5). Off by default: it is a belt-and-braces measure on top of the
/// concealed-type filter and the app exclusion list, and false positives would
/// silently drop legitimate clipboard content.
enum SecretDetector {

    /// Whether `text` looks enough like a secret to skip capturing it.
    static func looksSecret(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only single-token, whitespace-free strings are candidates; a sentence
        // that happens to contain a key is left alone to avoid dropping prose.
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return false }

        if isJWT(trimmed) { return true }
        if hasKnownKeyPrefix(trimmed) { return true }
        if isLongHighEntropyToken(trimmed) { return true }
        return false
    }

    /// header.payload.signature — three base64url segments.
    private static func isJWT(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        let base64url = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return parts.allSatisfy { part in
            part.count >= 2 && CharacterSet(charactersIn: String(part)).isSubset(of: base64url)
        }
    }

    /// Vendor key prefixes that are unambiguous when followed by enough entropy.
    private static let keyPrefixes = [
        "sk-", "pk-", "sk_live_", "sk_test_", "rk_live_", "ghp_", "gho_",
        "github_pat_", "xoxb-", "xoxp-", "AKIA", "ASIA", "AIza", "ya29.",
    ]

    private static func hasKnownKeyPrefix(_ s: String) -> Bool {
        for prefix in keyPrefixes where s.hasPrefix(prefix) {
            return s.count >= prefix.count + 12
        }
        return false
    }

    /// A long token that is entirely key-ish characters and carries a mix of
    /// letters and digits — the shape of base64/hex secrets, not English words.
    private static func isLongHighEntropyToken(_ s: String) -> Bool {
        guard s.count >= 32 else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-")
        guard CharacterSet(charactersIn: s).isSubset(of: allowed) else { return false }
        let hasLetter = s.contains { $0.isLetter }
        let hasDigit = s.contains { $0.isNumber }
        return hasLetter && hasDigit
    }
}
