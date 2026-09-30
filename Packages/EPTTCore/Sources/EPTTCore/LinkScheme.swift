import Foundation

/// NXTPTT links: `nxtptt://contact/…`, `nxtptt://join/…`, `nxtptt://pushkey/…` (PROTOCOL.md §4).
/// Links shared before the rename used `eptt://`; they are still accepted.
public enum LinkScheme {
    public static let current = "nxtptt://"
    public static let legacy = "eptt://"

    /// The link with a legacy `eptt://` scheme rewritten to `nxtptt://`, trimmed of whitespace.
    public static func normalize(_ link: String) -> String {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix(legacy) else { return trimmed }
        return current + trimmed.dropFirst(legacy.count)
    }

    /// Whether this is an NXTPTT link, old or new.
    public static func isLink(_ link: String) -> Bool {
        let lower = link.lowercased()
        return lower.hasPrefix(current) || lower.hasPrefix(legacy)
    }
}
