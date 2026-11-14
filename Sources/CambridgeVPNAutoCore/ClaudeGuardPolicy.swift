import Foundation

public enum ClaudeGuardPolicy {
    public static let extensionIdentifier = "com.wjli.cambridge-vpn-auto.claude-guard"
    public static let profileName = "Claude VPN Guard"
    public static let signingIdentifiers = [
        "com.anthropic.claudefordesktop",
        "com.anthropic.claudefordesktop.helper",
        "com.anthropic.claude-code"
    ]

    public static func designatedRequirement(for identifier: String) -> String {
        // Stable across signed Claude updates. Rules omit matchPath and matchTools,
        // so versioned Code paths and tools spawned by these apps are covered.
        "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"Q6L2SF6YDW\""
    }
}

/// One connection generation, not simply the existence of an arbitrary utun.
public struct GuardTunnel: Equatable, Codable {
    public let interfaceName: String
    public let addresses: [String]
    public let connectTime: UInt64

    public init?(extendedStatus: [String: Any]) {
        guard (extendedStatus["Status"] as? NSNumber)?.intValue == 2,
              let ipv4 = extendedStatus["IPv4"] as? [String: Any],
              let name = ipv4["InterfaceName"] as? String,
              name.hasPrefix("utun"),
              !name.dropFirst(4).isEmpty,
              name.dropFirst(4).allSatisfy({ $0.isASCII && $0.isNumber }),
              let addresses = ipv4["Addresses"] as? [String],
              !addresses.isEmpty,
              let ipsec = extendedStatus["IPSec"] as? [String: Any],
              (ipsec["Status"] as? NSNumber)?.intValue == 6,
              let time = ipsec["ConnectTime"] as? NSNumber,
              time.doubleValue > 0 else { return nil }
        self.interfaceName = name
        self.addresses = addresses.sorted()
        self.connectTime = time.uint64Value
    }

    public func matches(interfaceName: String, observedIndex: Int, liveIndex: UInt32) -> Bool {
        self.interfaceName == interfaceName && liveIndex > 0 && observedIndex == Int(liveIndex)
    }
}
