import Foundation
import Network

/// macOS shares resolver requests/cache across applications. Preserve transport
/// to its currently configured DNS servers instead of binding VPN DNS to Direct
/// or dropping shared lookups during an application's Block transition.
public enum SystemDNSPolicy {
    public static func preservesSystemRoute(host: String, port: UInt16, servers: [String]) -> Bool {
        guard port == 53, let address = literalAddress(host) else { return false }
        return servers.contains { literalAddress($0) == address }
    }

    private static func literalAddress(_ host: String) -> Data? {
        if let address = IPv4Address(host) { return Data([4]) + address.rawValue }
        // A link-local resolver can carry an interface scope suffix. Scope is
        // retained by macOS; here we only compare the configured IP address.
        let unscoped = String(host.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)[0])
        if let address = IPv6Address(unscoped) { return Data([6]) + address.rawValue }
        return nil // Never resolve a hostname while deciding DNS admission.
    }
}
