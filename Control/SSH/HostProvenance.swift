import Foundation

/// How a saved connection identifies its Mac, derived from the hostname's
/// shape. The three forms fail differently when a host-key mismatch occurs,
/// so the review flow tailors its conclusions: an IP is a DHCP lease that can
/// move to another device, a .local name can collide and auto-rename, and a
/// remote hostname can simply stop pointing at the Mac.
enum HostProvenance {
    case ipAddress
    case localHostname
    case remoteHostname

    init(host: String) {
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1 {
            self = .ipAddress
        } else if host.lowercased().hasSuffix(".local") || host.lowercased().hasSuffix(".local.") {
            self = .localHostname
        } else {
            self = .remoteHostname
        }
    }
}

enum HostIdentityHeuristics {
    /// Strips the trailing DNS root dot, so a hand-typed FQDN matches the
    /// dot-free form Bonjour discovery produces. The dot is meaningless for
    /// every DNS name, not only `.local` ones: gating it would let
    /// `example.com.` fork a second, untrusted row beside `example.com`.
    static func normalizedHostname(_ host: String) -> String {
        host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    /// Normalizes a Mac's display name or .local hostname so renamed
    /// duplicates match the row they diverged from: "Mac mini (2)" and
    /// "Mac-mini-2.local" both stem to "macmini". Used only to pick probe
    /// candidates; identity is decided by the pinned key, never by the name.
    static func nameStem(_ name: String) -> String {
        var stem = normalizedHostname(name.lowercased())
        if stem.hasSuffix(".local") { stem = String(stem.dropLast(6)) }
        // The separator is required: a rename suffix is always set off by one
        // ("Mac mini (2)"), while a fused model number ("Mac Studio M1") is
        // part of the name and must survive.
        stem = stem.replacingOccurrences(
            of: #"[\s\-]+\(?\d+\)?$"#,
            with: "",
            options: .regularExpression
        )
        stem = stem.replacingOccurrences(
            of: #"[\s\-_'’]+"#,
            with: "",
            options: .regularExpression
        )
        return stem
    }
}
