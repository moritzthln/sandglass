import Foundation

/// Canonical JSON coding for every Sandglass file on disk.
///
/// One coder pair for the whole app, used by `Store` and by every roundtrip test, so the
/// on-disk format is decided in exactly one place. The format is frozen: dates are
/// ISO-8601, keys are sorted, documents are pretty-printed. All three are chosen so that
/// the files stay readable — a user who wants to know what the app remembers about them can
/// open `state.json` in any editor, and that legibility is part of the product.
///
/// The trade-off of ISO-8601 is that it truncates sub-second precision. Nothing on disk
/// needs finer resolution than a second (budgets, sessions, cooldowns are minutes), but it
/// does mean a `Date` that goes through a file comes back rounded, so tests assert
/// roundtrip equality on whole-second dates only.
///
/// **Schema evolution:** `version` stays `1` for all of V1. Any field added later MUST be
/// optional with a default, so a file written by an older build keeps decoding. A decode
/// failure is therefore never "an old file" — it is corruption, and `Store` treats it as
/// such: the file is renamed to `.bad` and kept. It is never deleted; it is the user's only
/// path back to a streak that a bad write would otherwise erase.
public enum SandglassJSON {
    /// For whole documents: `config.json`, `state.json`.
    ///
    /// `.sortedKeys` is not cosmetic. Swift dictionaries iterate in a per-process random
    /// order, so without it every save would rewrite the same content as different bytes.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    /// For `events.jsonl`, where one event must occupy exactly one line. Same format as
    /// `encoder` minus the pretty-printing — a newline inside a record would split it into
    /// lines that no longer parse.
    public static let compactEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Reads anything either encoder wrote.
    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
