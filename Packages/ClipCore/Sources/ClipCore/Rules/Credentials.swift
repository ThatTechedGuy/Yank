import Foundation

// By pattern, not by the model, so it works with labelling off and a key is never shown to it.
/// Spots API keys, tokens and private keys in copied text.
public enum Credentials {
    /// Each pattern's fixed start, as bytes.
    private static let markers = [
        "sk-", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "AKIA", "eyJ", "PRIVATE KEY-----",
    ].map { Array($0.utf8) }

    /// Whether the text holds something shaped like a secret anywhere in it.
    public static func detect(_ text: String) -> Bool {
        // Swift's Regex and String.contains are slow (0.3 ms for 2,000 characters), and this runs
        // on every copy and over the whole history in migration v6, so a byte search for each
        // pattern's fixed start rules most texts out first: 23 times faster.
        var text = text  // `withUTF8` wants a mutable string; a native one is not copied
        let hasMarker = text.withUTF8 { bytes in
            markers.contains { memmem(bytes.baseAddress, bytes.count, $0, $0.count) != nil }
        }
        guard hasMarker else { return false }
        return text.contains(/\bsk-[A-Za-z0-9_\-]{20,}/)  // OpenAI, Anthropic, Stripe
            || text.contains(/\bgh[pousr]_[A-Za-z0-9]{36}\b/)
            || text.contains(/\bgithub_pat_[A-Za-z0-9_]{22,}/)
            || text.contains(/\bAKIA[0-9A-Z]{16}\b/)  // AWS access key id
            || text.contains(/\beyJ[A-Za-z0-9_\-]{5,}\.eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{10,}/)  // JWT
            || text.contains(/-----BEGIN [A-Z ]*PRIVATE KEY-----/)
    }
}
