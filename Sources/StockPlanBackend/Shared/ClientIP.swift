#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif
import Vapor

/// The address of the client behind our own proxies.
///
/// Every request reaches the API through Traefik (and, in-cluster, through
/// other pods), so `remoteAddress` is a proxy and one rate-limit bucket would
/// cover everyone. `X-Forwarded-For` names the real client, but only its
/// right-hand end is trustworthy: each proxy appends the address it saw, and
/// anything to the left of the last untrusted hop is whatever the client sent.
/// So walk the header right to left, skip hops inside `TRUSTED_PROXY_CIDRS`,
/// and take the first one outside it.
///
/// The header is only consulted when the direct peer is itself a trusted
/// proxy; otherwise anyone could pick their own bucket.
enum ClientIP {
    static let defaultTrustedProxyCIDRs = "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,127.0.0.0/8,100.64.0.0/10"

    static func trustedProxies() -> [IPNetwork] {
        let raw = Environment.get("TRUSTED_PROXY_CIDRS")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let configured = (raw?.isEmpty == false ? raw : nil) ?? defaultTrustedProxyCIDRs
        return configured.split(separator: ",").compactMap { IPNetwork(String($0)) }
    }

    static func resolve(_ request: Request) -> String? {
        resolve(
            remoteAddress: request.remoteAddress?.ipAddress,
            forwardedFor: request.headers[.xForwardedFor],
            trusted: trustedProxies()
        )
    }

    static func resolve(remoteAddress: String?, forwardedFor: [String], trusted: [IPNetwork]) -> String? {
        guard let remoteAddress else { return nil }
        guard let peer = IPAddressBytes(remoteAddress), trusted.contains(where: { $0.contains(peer) }) else {
            return remoteAddress
        }

        let hops = forwardedFor
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for hop in hops.reversed() {
            guard let address = IPAddressBytes(hop) else {
                // Not an address: the proxy to its right was trusted, so this
                // is what it was handed. Key on it rather than skip past it.
                return hop
            }
            if !trusted.contains(where: { $0.contains(address) }) {
                return hop
            }
        }
        // Every hop is internal (or there is no header): nothing in the chain
        // is both untrusted and beyond spoofing, so stay on the peer.
        return remoteAddress
    }
}

/// An IPv4 or IPv6 address as raw bytes. IPv4-mapped IPv6 (`::ffff:a.b.c.d`)
/// folds to IPv4 so one CIDR list covers both spellings.
struct IPAddressBytes: Equatable {
    let bytes: [UInt8]

    init?(_ string: String) {
        let text = string.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, text, &v6) == 1 else { return nil }
        let raw = withUnsafeBytes(of: &v6) { Array($0) }
        if raw[0 ..< 10].allSatisfy({ $0 == 0 }), raw[10] == 0xFF, raw[11] == 0xFF {
            bytes = Array(raw[12 ..< 16])
        } else {
            bytes = raw
        }
    }
}

struct IPNetwork {
    let base: IPAddressBytes
    let prefixLength: Int

    init?(_ cidr: String) {
        let parts = cidr.trimmingCharacters(in: .whitespaces).split(separator: "/", maxSplits: 1)
        guard let first = parts.first, let base = IPAddressBytes(String(first)) else { return nil }
        let maxBits = base.bytes.count * 8
        let prefix = parts.count == 2 ? Int(parts[1]) : maxBits
        guard let prefix, (0 ... maxBits).contains(prefix) else { return nil }
        self.base = base
        prefixLength = prefix
    }

    func contains(_ address: IPAddressBytes) -> Bool {
        guard address.bytes.count == base.bytes.count else { return false }
        var remaining = prefixLength
        for (lhs, rhs) in zip(address.bytes, base.bytes) where remaining > 0 {
            let bits = min(8, remaining)
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - bits))
            if lhs & mask != rhs & mask {
                return false
            }
            remaining -= bits
        }
        return true
    }
}
