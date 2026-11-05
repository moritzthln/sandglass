import Foundation
import SandglassCore

/// A video a search engine plays inside its own results page, read back out as the address it
/// really comes from.
///
/// Google's video results open the clip in an overlay on `google.com/search`, and DuckDuckGo's do
/// the same on `duckduckgo.com/`. The tab never leaves the search engine, so the address the
/// browser reports names Google — and a YouTube group that blocks `youtube.com` would let the
/// whole video play. The only trace of YouTube is in the part of the address that
/// `RuleMatcher.normalize` throws away: the fragment on Google, the query on DuckDuckGo.
///
/// So this runs **before** normalizing, on the address exactly as the browser said it, and hands
/// back the video's own address for the rules to judge. Nothing is invented: when the overlay
/// does not say where the video is from, the page stays the search page it is.
///
/// Bing is not covered: its overlay carries an id of Bing's own, not the source's address.
public enum EmbeddedVideo {

    /// The address of the video playing on a search results page, or `nil` when there is none.
    public static func source(of address: String) -> String? {
        guard let components = URLComponents(string: address.trimmingCharacters(in: .whitespaces)),
              let host = components.host.map(RuleMatcher.normalize(url:))
        else { return nil }
        if isGoogle(host), components.path == "/search" {
            return googleVideo(fragment: components.fragment)
        }
        if host == "duckduckgo.com" {
            return duckDuckGoVideo(query: components.queryItems)
        }
        return nil
    }

    /// The address the rules should judge: the embedded video's when there is one, else the
    /// address itself.
    public static func unwrapped(_ address: String) -> String {
        source(of: address) ?? address
    }

    // MARK: - Google

    /// `google.com`, `google.de`, `google.co.uk` — every country Google answers searches from.
    private static func isGoogle(_ host: String) -> Bool {
        host.hasPrefix("google.") && !host.dropFirst("google.".count).isEmpty
    }

    /// The overlay writes its state into the fragment, as in
    /// `#fpstate=ive&vld=cid:666d58b5,vid:oweLRy_EvmM,st:0`. `vid:` is a YouTube video id, and
    /// only an id of YouTube's exact shape is trusted — eleven characters of its alphabet — so a
    /// clip from anywhere else is not mistaken for one.
    private static func googleVideo(fragment: String?) -> String? {
        guard let fragment, let start = fragment.range(of: "vid:") else { return nil }
        let id = fragment[start.upperBound...].prefix { $0 != "," && $0 != "&" }
        guard isYouTubeID(id) else { return nil }
        return "https://www.youtube.com/watch?v=" + id
    }

    private static func isYouTubeID(_ id: Substring) -> Bool {
        id.count == 11 && id.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    // MARK: - DuckDuckGo

    /// The overlay names the video's own address in `iai`, already a whole URL —
    /// `&ia=videos&iai=https://www.youtube.com/watch?v=…`. `URLComponents` has decoded it.
    private static func duckDuckGoVideo(query: [URLQueryItem]?) -> String? {
        guard let value = query?.first(where: { $0.name == "iai" })?.value else { return nil }
        let lower = value.lowercased()
        guard lower.hasPrefix("https://") || lower.hasPrefix("http://") else { return nil }
        return value
    }
}
