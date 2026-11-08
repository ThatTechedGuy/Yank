import Foundation

// Decides whether a web address points at this Mac or the local network, where a link preview
// must never be fetched: a request there could reach a router's admin page, a development
// server, or a one-time link on the LAN, and would tell the local network that Yank exists.
// Pure function over the URL's host, so the tests can list the edge cases without a network.
//
// Blocked by name: `localhost` (and anything under it) and `*.local` (Bonjour names, like
// `printer.local`). Blocked by number: the loopback, private and link-local ranges of IPv4
// (127.x, 10.x, 172.16–31.x, 192.168.x, 169.254.x) and IPv6 (::1, fc00::/7, fe80::/10), plus
// an IPv4 address written inside an IPv6 one (::ffff:10.0.0.1). An address with no host at
// all is local too, since there is nothing public to fetch.
//
// shortcut: a public name that secretly resolves to a local address, or a public page that
// redirects to one, still gets fetched, because the check sees only the address as written;
// resolve the name first (or check every redirect) if that risk ever matters for this app.
/// Whether a link points at this Mac or the local network.
public enum LocalAddress {
    /// True when the link must not be fetched: its host names this Mac or the local network,
    /// or it has no host.
    public static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return true }
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        if let bytes = ipv4Bytes(host) { return isLocalIPv4(bytes) }
        if let bytes = ipv6Bytes(host) { return isLocalIPv6(bytes) }
        return false
    }

    /// The four bytes of an IPv4 address written as digits and dots, or nil for anything
    /// else. `inet_pton` is the C library's parser, strict about the four-part form, so
    /// "172.16.0" or "10" are not addresses to it (and not to a browser either).
    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    /// The sixteen bytes of an IPv6 address, or nil. The URL parser has already removed the
    /// square brackets; a zone such as "%en0" (which interface to use) is dropped, because it
    /// says nothing about where the address points and `inet_pton` refuses it.
    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        let plain = host.prefix { $0 != "%" }
        var address = in6_addr()
        guard inet_pton(AF_INET6, String(plain), &address) == 1 else { return nil }
        return withUnsafeBytes(of: &address) { Array($0) }
    }

    /// 0.x (this network), 10.x, 127.x (loopback), 169.254.x (link-local), 172.16.x to
    /// 172.31.x, 192.168.x.
    private static func isLocalIPv4(_ b: [UInt8]) -> Bool {
        b[0] == 0 || b[0] == 10 || b[0] == 127 || (b[0] == 169 && b[1] == 254)
            || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
    }

    /// `::` and `::1` (unspecified and loopback), fc00::/7 (unique local, the IPv6 "private"
    /// range), fe80::/10 (link-local), and an IPv4 address carried as ::ffff:a.b.c.d, judged by
    /// its IPv4 rules.
    private static func isLocalIPv6(_ b: [UInt8]) -> Bool {
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] <= 1 { return true }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xFF && b[11] == 0xFF {
            return isLocalIPv4(Array(b[12...]))
        }
        return b[0] & 0xFE == 0xFC || (b[0] == 0xFE && b[1] & 0xC0 == 0x80)
    }
}
