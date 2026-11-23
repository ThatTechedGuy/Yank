import Foundation

// By pattern, not by the model, so it works with labelling off and a key is never shown to it.
/// Spots API keys, tokens and private keys in copied text.
public enum Credentials {
    /// Whether the text holds something shaped like a secret anywhere in it.
    public static func detect(_ text: String) -> Bool {
        // A plain substring test first: Swift's Regex is slow, and this runs on every copy and,
        // once, over the whole history (migration v6).
        let markers = [
            "sk-", "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_", "AKIA", "eyJ", "PRIVATE KEY-----",
        ]
        guard markers.contains(where: text.contains) else { return false }
        return text.contains(/\bsk-[A-Za-z0-9_\-]{20,}/)  // OpenAI, Anthropic, Stripe
            || text.contains(/\bgh[pousr]_[A-Za-z0-9]{36}\b/)
            || text.contains(/\bgithub_pat_[A-Za-z0-9_]{22,}/)
            || text.contains(/\bAKIA[0-9A-Z]{16}\b/)  // AWS access key id
            || text.contains(/\beyJ[A-Za-z0-9_\-]{5,}\.eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{10,}/)  // JWT
            || text.contains(/-----BEGIN [A-Z ]*PRIVATE KEY-----/)
    }
}
