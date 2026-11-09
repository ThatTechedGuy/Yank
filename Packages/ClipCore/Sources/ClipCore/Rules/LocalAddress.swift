import Foundation

// Decides whether a web address points at this Mac or the local network, where a link preview
// must never be fetched: a request there could reach a router's admin page, a development
// server, or a one-time link on the LAN, and would tell the local network that Yank exists.
// Pure function over the URL's host, so the tests can list the edge cases without a network.
//
// Blocked by name: anything with no dot in it (`localhost`, `router`, `nas`: a public site always
// has one) and names under the suffixes kept for private networks, such as `*.local` (Bonjour
// names, like `printer.local`), `*.localhost`, `*.home.arpa`, `*.internal` and `*.lan`. A name may
// end in one dot (`localhost.`), which means the same name. Blocked by number: the loopback,
// private, shared (Tailscale and carrier networks) and link-local ranges of IPv4 (127.x, 10.x,
// 172.16–31.x, 192.168.x, 100.64–127.x, 169.254.x) and IPv6 (::1, fc00::/7, fe80::/10), plus an
// IPv4 address written inside an IPv6 one (::ffff:10.0.0.1). An address with no host at all is
// local too, since there is nothing public to fetch.
//
// shortcut: a public name that secretly resolves to a local address, or a public page that
// redirects to one, still gets fetched, because the check sees only the address as written;
// resolve the name first (or check every redirect) if that risk ever matters for this app.
/// Whether a link points at this Mac or the local network.
public enum LocalAddress {
    /// True when the link must not be fetched: its host names this Mac or the local network,
    /// or it has no host.
    public static func isLocal(_ url: URL) -> Bool {
        guard var host = url.host(percentEncoded: false)?.lowercased() else { return true }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return true }
        if let bytes = ipv4Bytes(host) { return isLocalIPv4(bytes) }
        if let bytes = ipv6Bytes(host) { return isLocalIPv6(bytes) }
        if !host.contains(".") { return true }
        // The dot in front makes `home.arpa` itself match as well as names under it.
        return privateSuffixes.contains { ".\(host)".hasSuffix($0) }
    }

    /// The name endings set aside for private networks.
    private static let privateSuffixes = [".localhost", ".local", ".home.arpa", ".internal", ".lan"]

    /// The four bytes of an IPv4 address, or nil for anything else. `inet_aton` is the C
    /// library's forgiving parser, and it has to be: the system's URL loading also accepts the
    /// short and odd spellings ("127.1", "2130706433", "0x7f.0.0.1"), so each must be judged by
    /// the address it really means.
    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        var address = in_addr()
        guard inet_aton(host, &address) != 0 else { return nil }
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
    /// 172.31.x, 192.168.x, and 100.64.x to 100.127.x (shared address space: Tailscale, carriers).
    private static func isLocalIPv4(_ b: [UInt8]) -> Bool {
        b[0] == 0 || b[0] == 10 || b[0] == 127 || (b[0] == 169 && b[1] == 254)
            || (b[0] == 172 && (16...31).contains(b[1])) || (b[0] == 192 && b[1] == 168)
            || (b[0] == 100 && (64...127).contains(b[1]))
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
