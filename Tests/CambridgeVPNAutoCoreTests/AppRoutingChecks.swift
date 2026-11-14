import Foundation
import CambridgeVPNAutoCore

func runAppRoutingChecks(_ runner: inout CheckRunner) {
    let resolvers = ["131.111.12.20", "240a:4282:3000:38e::33", "fe80::1%en0"]
    runner.expect(SystemDNSPolicy.preservesSystemRoute(host: "131.111.12.20", port: 53, servers: resolvers),
                  "configured VPN DNS keeps macOS routing rather than physical Direct")
    runner.expect(SystemDNSPolicy.preservesSystemRoute(host: "240a:4282:3000:038e:0:0:0:33", port: 53, servers: resolvers),
                  "equivalent IPv6 resolver addresses preserve the system route")
    runner.expect(SystemDNSPolicy.preservesSystemRoute(host: "fe80::1%en0", port: 53, servers: resolvers),
                  "scoped IPv6 DNS preserves macOS resolver transport")
    runner.expect(!SystemDNSPolicy.preservesSystemRoute(host: "8.8.8.8", port: 53, servers: resolvers),
                  "custom DNS destinations remain subject to the application rule")
    runner.expect([443, 853, 5353].allSatisfy { !SystemDNSPolicy.preservesSystemRoute(host: "131.111.12.20", port: UInt16($0), servers: resolvers) },
                  "resolver exception does not bypass web, encrypted DNS, or mDNS ports")
    runner.expect(!SystemDNSPolicy.preservesSystemRoute(host: "131.111.12.20", port: 53, servers: []),
                  "removed DNS server does not retain a route exception")
    runner.expect(["", "resolver.example", "131.111.12.20.example"].allSatisfy {
        !SystemDNSPolicy.preservesSystemRoute(host: $0, port: 53, servers: resolvers + [$0])
    }, "DNS admission accepts only literal configured IP addresses without recursive lookup")

    let claude = AppCodeIdentity(signingIdentifier: "com.example.claude", designatedRequirement: "claude requirement")
    let helper = AppCodeIdentity(signingIdentifier: "com.example.claude.helper", designatedRequirement: "helper requirement")
    let vpnRule = AppConnectionRule(name: "Claude", bundlePath: "/Applications/Claude.app", identities: [claude, helper], route: .cambridgeVPN)
    var policy = AppRoutingPolicy(rules: [vpnRule])
    runner.expect(policy.admission(for: "com.example.other", verify: { _ in false }) == .bypassMacOS,
                  "ordinary mode preserves the macOS/VPN route for unlisted apps")
    runner.expect(policy.route(for: claude.signingIdentifier, verify: { $0 == claude }) == .cambridgeVPN,
                  "verified app selects Cambridge only")
    runner.expect(policy.route(for: helper.signingIdentifier, verify: { $0 == helper }) == .cambridgeVPN,
                  "embedded helper uses its parent app rule")
    runner.expect(policy.route(for: claude.signingIdentifier, verify: { _ in false }) == .blocked,
                  "missing or mismatched signature cannot bypass a configured rule")
    runner.expect(policy.route(for: "com.example.claude.unrelated", verify: { _ in true }) == nil,
                  "identifier prefix alone does not capture another app")
    policy.rules[0].route = .blocked
    runner.expect(policy.route(for: helper.signingIdentifier, verify: { _ in true }) == .blocked,
                  "blocked app includes its discovered helper")
    let otherVendor = AppCodeIdentity(signingIdentifier: claude.signingIdentifier, designatedRequirement: "another vendor")
    let otherRule = AppConnectionRule(name: "Another vendor", bundlePath: "/Applications/Other.app", identities: [otherVendor], route: .direct)
    let collision = AppRoutingPolicy(rules: [vpnRule, otherRule])
    runner.expect((try? collision.validated()) != nil, "different vendors may reuse a generic signing identifier")
    runner.expect(collision.route(for: claude.signingIdentifier, verify: { $0 == otherVendor }) == .direct,
                  "matching uses the signature as well as the identifier")
    runner.expect(collision.route(for: claude.signingIdentifier, verify: { _ in true }) == .blocked,
                  "ambiguous conflicting matching requirements fail closed")
    let old = AppRoutingPolicy(rules: [vpnRule])
    let transition = AppRoutingPolicy().blockingTransition(from: old)
    runner.expect(transition.route(for: helper.signingIdentifier, verify: { _ in true }) == .blocked,
                  "removing a rule remains blocked during the router/filter transition")
    runner.expect(transition.admission(for: "unlisted", verify: { _ in true }) == .bypassMacOS,
                  "temporary apply blocks preserve unrelated macOS/VPN traffic")
    let newTransition = policy.blockingTransition(from: AppRoutingPolicy())
    runner.expect(newTransition.route(for: claude.signingIdentifier, verify: { _ in true }) == .blocked,
                  "first activation holds selected apps until the router acknowledges")
    let safari = AppCodeIdentity(signingIdentifier: "com.apple.Safari", designatedRequirement: "identifier com.apple.Safari and anchor apple")
    let safariHelper = AppCodeIdentity(signingIdentifier: "com.apple.Safari.SandboxBroker", designatedRequirement: "identifier com.apple.Safari.SandboxBroker and anchor apple")
    let safariRule = AppConnectionRule(name: "Safari", bundlePath: "/Applications/Safari.app", identities: [safari, safariHelper], route: .cambridgeVPN)
    let safariTest = AppRoutingPolicy(rules: [safariRule], scope: .safariOnlyTest)
    runner.expect((try? safariTest.validated()) != nil, "Safari-only test policy validates with a verified Safari identity")
    runner.expect(safariTest.admission(for: safari.signingIdentifier, verify: { $0 == safari }) == .handle(.cambridgeVPN),
                  "Safari test admits the verified Safari process")
    runner.expect(safariTest.admission(for: safariHelper.signingIdentifier, verify: { $0 == safariHelper }) == .handle(.cambridgeVPN),
                  "Safari test admits its verified helper")
    runner.expect(safariTest.admission(for: "com.example.unrelated", verify: { _ in false }) == .bypassMacOS,
                  "Safari test leaves unrelated attributed traffic on macOS routing")
    runner.expect(safariTest.admission(for: "", verify: { _ in false }) == .bypassMacOS,
                  "Safari test leaves unattributable traffic on macOS routing")
    runner.expect(safariTest.admission(for: safari.signingIdentifier, verify: { _ in false }) == .handle(.blocked),
                  "Safari signature mismatch remains handled and blocked")
    let safariTransition = safariTest.blockingTransition(from: AppRoutingPolicy(rules: [vpnRule]))
    runner.expect(safariTransition.scope == .safariOnlyTest && safariTransition.rules.count == 1 &&
                  safariTransition.route(for: safari.signingIdentifier, verify: { _ in true }) == .blocked,
                  "Safari transition blocks only the selected Safari identities")
    runner.expect(safariTransition.admission(for: claude.signingIdentifier, verify: { _ in true }) == .bypassMacOS,
                  "Safari transition does not admit the previous ordinary-policy identity")
    var malformedScope = safariTest
    malformedScope.scope = .ordinary
    runner.expect((try? malformedScope.validated()) == nil,
                  "schema-version-two test policy is rejected when interpreted as an ordinary policy")
    let malformedSafari = AppRoutingPolicy(rules: [vpnRule], scope: .safariOnlyTest)
    runner.expect((try? malformedSafari.validated()) == nil,
                  "Safari-only scope rejects a non-Safari policy")
    let legacyPolicy = Data("""
    {"schemaVersion":1,"revision":"00000000-0000-0000-0000-000000000001","rules":[]}
    """.utf8)
    runner.expect((try? AppRoutingPolicy.decode(legacyPolicy))?.scope == .ordinary,
                  "version-one saved policy without a scope remains an ordinary policy")
    let migrated = try? AppRoutingPolicy.decode(legacyPolicy)
    runner.expect(migrated?.schemaVersion == 3 && migrated?.admission(for: "com.apple.racoon", verify: { _ in false }) == .bypassMacOS,
                  "legacy ordinary preferences migrate without relaying system VPN traffic")
    runner.expect((try? migrated?.encoded()).flatMap { try? AppRoutingPolicy.decode($0) }?.schemaVersion == 3,
                  "migrated ordinary policies serialize the new contract for old-binary rejection")
    let ordinary = AppRoutingPolicy(rules: [vpnRule, safariRule])
    runner.expect(["", "com.apple.racoon", "com.apple.mDNSResponder", "com.example.unlisted"].allSatisfy {
        ordinary.admission(for: $0, verify: { _ in false }) == .bypassMacOS
    }, "ordinary multi-app rules leave OS, unattributed and unrelated traffic outside relays")
    runner.expect(ordinary.admission(for: claude.signingIdentifier, verify: { $0 == claude }) == .handle(.cambridgeVPN) &&
                  ordinary.admission(for: safari.signingIdentifier, verify: { $0 == safari }) == .handle(.cambridgeVPN),
                  "ordinary mode enforces multiple explicit applications without a Safari test scope")
    runner.expect(ordinary.admission(for: safari.signingIdentifier, verify: { _ in false }) == .handle(.blocked),
                  "ordinary known identity verification failure stays blocked")
    let incompleteLegacyPolicy = Data("""
    {"schemaVersion":1,"revision":"00000000-0000-0000-0000-000000000001"}
    """.utf8)
    runner.expect((try? AppRoutingPolicy.decode(incompleteLegacyPolicy)) == nil,
                  "legacy policy missing its required rules field is rejected")
    let en0 = RouteInterface(name: "en0", index: 14, kind: .wifi)
    let en1 = RouteInterface(name: "en1", index: 15, kind: .ethernet)
    let utun = RouteInterface(name: "utun4", index: 26, kind: .tunnel)
    runner.expect(RouteSelection.direct(interfaces: [utun, en0], serviceOrder: ["utun4", "en0"]) == en0,
                  "VPN default cannot become Direct egress")
    runner.expect(RouteSelection.direct(interfaces: [en0, en1], serviceOrder: ["en1", "en0"]) == en1,
                  "direct selection respects physical service order")
    runner.expect(RouteSelection.direct(interfaces: [utun], serviceOrder: ["utun4"]) == nil,
                  "no physical route means no direct fallback to a tunnel")
    runner.expect(RouteSelection.direct(interfaces: [en0, en1], serviceOrder: []) == nil,
                  "ambiguous physical routes without service order are unavailable")
    runner.expect(!RouteInterface(name: "utun4", index: 26, kind: .ethernet).isPhysical,
                  "tunnel names cannot masquerade as physical interfaces")
    let store = AppRoutingStore(fileURL: FileManager.default.temporaryDirectory
        .appendingPathComponent("CambridgeAppRulesChecks-\(UUID().uuidString)/rules.json"))
    do {
        try store.save(policy)
        let reloaded = try store.load()
        runner.expect(reloaded == policy, "app rule choices survive a restart")
        var duplicate = policy
        duplicate.rules.append(vpnRule)
        do { try store.save(duplicate); runner.expect(false, "overlapping rules are rejected") }
        catch { runner.expect(true, "overlapping rules are rejected") }
        let retained = try store.load()
        runner.expect(retained == policy, "invalid edits preserve the last saved rules")
        var future = policy
        future.schemaVersion = 99
        do { _ = try future.validated(); runner.expect(false, "future schema is rejected") }
        catch { runner.expect(true, "future schema is rejected") }
        try Data("{truncated".utf8).write(to: store.fileURL)
        do { _ = try store.load(); runner.expect(false, "corrupt rules never silently become Direct") }
        catch { runner.expect(true, "corrupt rules never silently become Direct") }
    } catch { runner.expect(false, "routing persistence checks: \(error)") }
}

func runReconnectLifecycleChecks(_ runner: inout CheckRunner) {
    // A complete decision sequence, with no live VPN disruption.
    var state = PersistentControlState.armed()
    func action(_ vpn: VPNConnectionState, online: Bool = true, ready: Bool = true) -> ControllerAction {
        DecisionEngine.action(controlState: state, vpnState: vpn, internetAvailable: online, retryReady: ready)
    }
    runner.expect(action(.connected) == .none, "reconnect lifecycle begins stable")
    runner.expect(action(.disconnected) == .connect, "unexpected drop requests recovery")
    runner.expect(action(.disconnected, ready: false) == .none, "failed attempt waits for backoff")
    runner.expect(action(.connecting) == .none, "pending connection is not duplicated")
    runner.expect(action(.unknown) == .none, "failed status query cannot trigger an unsafe retry")
    runner.expect(action(.disconnected, online: false) == .none, "offline recovery waits for network")
    runner.expect(action(.disconnected) == .connect, "network restoration resumes recovery")
    state = PersistentControlState(mode: .paused, manualStopPending: true)
    runner.expect(action(.connected) == .disconnect, "manual off persists intent before stop")
    runner.expect(action(.disconnected) == .completePause, "pause settles after stop")
    state.manualStopPending = false
    runner.expect(action(.disconnected) == .none, "settled pause survives a network-change observation")
    state.mode = .armed
    runner.expect(action(.disconnected) == .connect, "manual on re-arms recovery")
    runner.expect((0..<7).map { RetryPolicy.delay(afterAttempt: $0) } == [5, 15, 30, 60, 120, 300, 300],
                  "full reconnect delay schedule remains bounded")
}
