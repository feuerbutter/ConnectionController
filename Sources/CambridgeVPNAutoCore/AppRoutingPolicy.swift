import Foundation

public enum AppRoute: String, Codable, CaseIterable, Identifiable, Sendable {
    case direct, cambridgeVPN, blocked
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .direct: return "Direct internet"
        case .cambridgeVPN: return "VPN only"
        case .blocked: return "Block internet"
        }
    }
}

/// Ordinary policies support arbitrary explicit app rules. The historical
/// Safari harness remains readable, but normal use does not depend on it.
/// Version 3 keeps unlisted traffic on macOS; old binaries reject this schema
/// instead of silently interpreting it as the version-1 Direct default.
public enum RoutingScope: String, Codable, Sendable {
    case ordinary
    case safariOnlyTest
}

/// The provider uses this result before accepting a transparent-proxy flow.
/// `bypassMacOS` must be returned synchronously from `handleNewFlow`, allowing
/// the system to retain its normal route for the flow.
public enum RoutingAdmission: Equatable, Sendable {
    case bypassMacOS
    case handle(AppRoute)
}

public struct AppCodeIdentity: Codable, Equatable, Hashable, Sendable {
    public var signingIdentifier: String
    public var designatedRequirement: String
    public init(signingIdentifier: String, designatedRequirement: String) {
        self.signingIdentifier = signingIdentifier
        self.designatedRequirement = designatedRequirement
    }
}

public struct AppConnectionRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var bundlePath: String
    public var identities: [AppCodeIdentity]
    public var route: AppRoute
    public init(id: UUID = UUID(), name: String, bundlePath: String,
                identities: [AppCodeIdentity], route: AppRoute) {
        self.id = id; self.name = name; self.bundlePath = bundlePath
        self.identities = identities; self.route = route
    }
}

public struct AppRoutingPolicy: Codable, Equatable, Sendable {
    public static let extensionIdentifier = "com.wjli.cambridge-vpn-auto.connection-router"
    public static let profileName = "ConnectionManager"
    public var schemaVersion: Int = 3
    public var scope: RoutingScope = .ordinary
    public var revision: UUID = UUID()
    public var rules: [AppConnectionRule] = []
    private enum CodingKeys: String, CodingKey { case schemaVersion, scope, revision, rules }
    public init(rules: [AppConnectionRule] = [], scope: RoutingScope = .ordinary) {
        self.rules = rules
        self.scope = scope
        self.schemaVersion = scope == .ordinary ? 3 : 2
    }
    /// Read existing app choices without changing their identities or routes.
    /// Upgrade only ordinary version-1 policies to the explicit-app contract;
    /// subsequent saves and provider messages use version 3.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        scope = try values.decodeIfPresent(RoutingScope.self, forKey: .scope) ?? .ordinary
        revision = try values.decode(UUID.self, forKey: .revision)
        rules = try values.decode([AppConnectionRule].self, forKey: .rules)
        if schemaVersion == 1 && scope == .ordinary { schemaVersion = 3 }
    }

    /// A nil route leaves an unlisted app on macOS routing, including its VPN.
    /// A known identity that fails verification remains explicitly blocked.
    public func route(for signingIdentifier: String,
                      verify: (AppCodeIdentity) -> Bool) -> AppRoute? {
        var candidates: [AppRoute] = []
        var knownIdentifier = false
        for rule in rules {
            for identity in rule.identities where identity.signingIdentifier == signingIdentifier {
                knownIdentifier = true
                if verify(identity) { candidates.append(rule.route) }
            }
        }
        guard let route = candidates.first else { return knownIdentifier ? .blocked : nil }
        return candidates.allSatisfy { $0 == route } ? route : .blocked
    }

    /// Only explicit app rules own flows, in both ordinary and historical test
    /// scopes. This also keeps OS networking and VPN transport outside relays.
    public func admission(for signingIdentifier: String,
                          verify: (AppCodeIdentity) -> Bool) -> RoutingAdmission {
        guard let route = route(for: signingIdentifier, verify: verify) else { return .bypassMacOS }
        return .handle(route)
    }

    public func validated() throws -> Self {
        switch (schemaVersion, scope) {
        case (3, .ordinary): break
        case (2, .safariOnlyTest):
            guard rules.count == 1, rules[0].name == "Safari",
                  rules[0].identities.contains(where: { $0.signingIdentifier == "com.apple.Safari" }) else {
                throw RoutingError("Safari-only test policy must contain exactly the verified Safari rule")
            }
        default:
            throw RoutingError("Unsupported routing policy version or scope")
        }
        var seen = Set<AppCodeIdentity>()
        var ids = Set<UUID>()
        let reserved = [Self.extensionIdentifier, "com.wjli.cambridge-vpn-auto",
                        ClaudeGuardPolicy.extensionIdentifier]
        for rule in rules {
            guard ids.insert(rule.id).inserted, !rule.name.isEmpty, !rule.identities.isEmpty else {
                throw RoutingError("Each application must have a unique rule and a signed identity")
            }
            for identity in rule.identities {
                guard !identity.signingIdentifier.isEmpty, !identity.designatedRequirement.isEmpty,
                      !reserved.contains(identity.signingIdentifier) else {
                    throw RoutingError("This application cannot be assigned a connection rule")
                }
                guard seen.insert(identity).inserted else {
                    throw RoutingError("Overlapping application identity: \(identity.signingIdentifier). Remove the existing rule first.")
                }
            }
        }
        return self
    }

    /// Temporary blocks prevent a VPN-only app from using the old direct rule
    /// while the router and filter receive an update. No change to unlisted apps.
    public func blockingTransition(from previous: AppRoutingPolicy) -> AppRoutingPolicy {
        var identities = Set<AppCodeIdentity>()
        // A scope switch must still start with a block for the newly selected
        // identities. Never borrow identities from a broader previous scope.
        let transitionRules = scope == previous.scope ? previous.rules + rules : rules
        for rule in transitionRules {
            for identity in rule.identities { identities.insert(identity) }
        }
        guard !identities.isEmpty else { return AppRoutingPolicy(scope: scope) }
        let transitionName = scope == .safariOnlyTest ? "Safari" : "Applying app rules"
        return AppRoutingPolicy(rules: [AppConnectionRule(name: transitionName, bundlePath: "",
            identities: identities.sorted { ($0.signingIdentifier, $0.designatedRequirement) < ($1.signingIdentifier, $1.designatedRequirement) }, route: .blocked)], scope: scope)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(validated())
    }

    public static func decode(_ data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data).validated()
    }
}

public struct RoutingError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct AppRoutingStore {
    public let fileURL: URL
    public init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CambridgeVPNAuto/app-routing.json")) {
        self.fileURL = fileURL
    }
    public func load() throws -> AppRoutingPolicy {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AppRoutingPolicy() }
        return try AppRoutingPolicy.decode(Data(contentsOf: fileURL))
    }
    public func save(_ policy: AppRoutingPolicy) throws {
        let data = try policy.encoded()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

public struct RouteInterface: Equatable {
    public enum Kind { case wifi, ethernet, cellular, tunnel, other }
    public let name: String
    public let index: Int
    public let kind: Kind
    public init(name: String, index: Int, kind: Kind) {
        self.name = name; self.index = index; self.kind = kind
    }
    public var isPhysical: Bool {
        index > 0 && !name.hasPrefix("utun") && !name.hasPrefix("tun") &&
        !name.hasPrefix("ppp") && !name.hasPrefix("ipsec") &&
        (kind == .wifi || kind == .ethernet || kind == .cellular)
    }
}

public enum RouteSelection {
    /// Prefer macOS network-service order. Refuse an ambiguous default rather
    /// than silently selecting a VPN or a different connection.
    public static func direct(interfaces: [RouteInterface], serviceOrder: [String]) -> RouteInterface? {
        let physical = interfaces.filter(\.isPhysical)
        for name in serviceOrder {
            if let item = physical.first(where: { $0.name == name }) { return item }
        }
        return physical.count == 1 ? physical.first : nil
    }
}
