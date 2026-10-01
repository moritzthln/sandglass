import Foundation

/// Turns what someone types into a domain field into the value a `Target` can hold, or
/// refuses it.
///
/// People paste URLs. They type `https://www.youtube.com/feed/subscriptions`, `YouTube.com`,
/// `youtube.com/` and `www.youtube.com.`, and every one of those means the same site. A field
/// that stored them verbatim would produce four targets that block nothing, because matching
/// is on a host and none of those four is one.
///
/// **What it does not do is compute the registrable domain.** `m.youtube.com` stays
/// `m.youtube.com`: telling `co.uk` from `youtube.com` needs the public suffix list, and
/// guessing at it would silently widen or narrow a block. `www.` is the one prefix stripped,
/// because it is the one that never identifies a different site. Matching (Task 8) is
/// suffix-based, so a user who wants everything under a domain types the domain.
public enum DomainInput {

    /// The host in `text`, lowercased and stripped, or `nil` when there is no usable one.
    public static func normalize(_ text: String) -> String? {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Scheme, then everything a path can start with, then credentials — in that order.
        // Trimming the path first is what keeps an "@" inside a query string ("/watch?v=a@b")
        // from being read as credentials and eating the host in front of it.
        if let schemeEnd = host.range(of: "://") { host = String(host[schemeEnd.upperBound...]) }
        if let cut = host.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            host = String(host[..<cut])
        }
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        host = stripPort(host)
        // A trailing dot is the fully qualified form of the same name.
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www.") { host.removeFirst(4) }

        return isValidHost(host) ? host : nil
    }

    /// A name to show for a bare domain: the label in front of the public suffix, capitalised.
    ///
    /// `youtube.com` becomes "Youtube" and `twitch.tv` becomes "Twitch", which is both
    /// readable and — because groups are formed by matching names case-insensitively — what
    /// puts a typed `youtube.com` in the same group as an app called "YouTube".
    public static func displayName(for host: String) -> String {
        let labels = host.split(separator: ".")
        guard let label = labels.count > 1 ? labels[labels.count - 2] : labels.first else {
            return host
        }
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    /// Strips a `:port` suffix. A colon followed by anything else is left in place, so the
    /// host validation below can reject it rather than this quietly truncating it.
    private static func stripPort(_ host: String) -> String {
        guard let colon = host.lastIndex(of: ":") else { return host }
        let port = host[host.index(after: colon)...]
        guard !port.isEmpty, port.allSatisfy(\.isNumber) else { return host }
        return String(host[..<colon])
    }

    /// At least two labels, nothing but letters, digits and hyphens in them, and no label that
    /// is empty or hyphen-edged. Deliberately stricter than a resolver: this is a field
    /// someone types into, and a target that can never match is worse than a refusal.
    private static func isValidHost(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty
                && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
