import AppKit
import NetworkExtension
import Security
import SystemConfiguration
import SystemExtensions
import CambridgeVPNAutoCore

@MainActor
final class RoutingController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published private(set) var status = "Rules are not active"
    @Published private(set) var detail = "Save app rules, then enable the signed extension."
    @Published private(set) var busy = false
    @Published private(set) var hasConfiguration = false
    @Published private(set) var runningRevision: UUID?
    @Published private(set) var filterRevision: UUID?
    @Published private(set) var activeScope: RoutingScope?
    private var manager: NETransparentProxyManager?
    private var request: OSSystemExtensionRequest?
    private var pendingPolicy: AppRoutingPolicy?
    private var timer: Timer?

    private static var requiredNetworkCapabilities: [String] {
        #if APP_STORE
        ["app-proxy-provider", "content-filter-provider"]
        #else
        ["app-proxy-provider-systemextension", "content-filter-provider-systemextension"]
        #endif
    }

    static var signingProblem: String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let values = info as? [String: Any], values[kSecCodeInfoTeamIdentifier as String] as? String != nil,
              let entitlements = values[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements["com.apple.developer.system-extension.install"] as? Bool == true,
              let network = entitlements["com.apple.developer.networking.networkextension"] as? [String],
              requiredNetworkCapabilities.allSatisfy(network.contains) else {
            return "Apple Developer signing is required. App rules are saved only; VPN-only routing and internet blocking are NOT enforced. Until activation, macOS controls all app routes. Auto-reconnect works independently."
        }
        let extensionURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/SystemExtensions/\(AppRoutingPolicy.extensionIdentifier).systemextension")
        guard FileManager.default.fileExists(atPath: extensionURL.path) else { return "The connection extension is missing. App rules are NOT enforced." }
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return "Install the signed app in /Applications before enabling app rules." }
        return nil
    }

    func start() {
        if let problem = Self.signingProblem {
            status = "Saved only · signing required"
            detail = problem
            return
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }
    func apply(_ policy: AppRoutingPolicy) {
        guard !busy else { return }
        if let problem = Self.signingProblem { detail = problem; return }
        pendingPolicy = policy
        busy = true
        status = "Waiting for macOS approval"
        detail = "Approve the system extension and network configurations when macOS asks."
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: AppRoutingPolicy.extensionIdentifier, queue: .main)
        self.request = request
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }
    func applySafariOnlyTest(_ policy: AppRoutingPolicy) {
        guard policy.scope == .safariOnlyTest else {
            status = "Safari test was not applied"
            detail = "The test window supplied a non-Safari policy. Saved application rules were left untouched."
            return
        }
        apply(policy)
    }
    func endSafariOnlyTest() {
        guard !busy, Self.signingProblem == nil else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await loadManager()
                let filter = NEFilterManager.shared()
                try await filter.loadFromPreferences()
                let routerEnabled = manager?.isEnabled == true
                let filterEnabled = filter.isEnabled && filter.providerConfiguration?.filterDataProviderBundleIdentifier == AppRoutingPolicy.extensionIdentifier
                guard routerEnabled || filterEnabled else {
                    throw RoutingError("No active Safari-only test configuration was found. No app rules were changed.")
                }
                if routerEnabled {
                    guard let manager,
                          let routerData = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["policy"] as? Data,
                          try AppRoutingPolicy.decode(routerData).scope == .safariOnlyTest else {
                        throw RoutingError("The active router is not a Safari-only test. No app rules were changed.")
                    }
                    manager.isOnDemandEnabled = false
                    manager.isEnabled = false
                    try await manager.saveToPreferences()
                    manager.connection.stopVPNTunnel()
                }
                if filterEnabled {
                    guard let filterData = filter.providerConfiguration?.vendorConfiguration?["policy"] as? Data,
                          try AppRoutingPolicy.decode(filterData).scope == .safariOnlyTest else {
                        throw RoutingError("The active socket filter is not a Safari-only test. No app rules were changed.")
                    }
                    filter.isEnabled = false
                    try await filter.saveToPreferences()
                }
                runningRevision = nil; filterRevision = nil; activeScope = nil
                hasConfiguration = false
                status = "Safari-only test ended"
                detail = "Safari now follows macOS routing. Saved application rules were not changed."
            } catch { fail(error) }
        }
    }
    func refresh() {
        guard Self.signingProblem == nil, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await loadManager()
                let filter = NEFilterManager.shared()
                try await filter.loadFromPreferences()
                hasConfiguration = manager?.isEnabled == true || (filter.isEnabled && filter.providerConfiguration?.filterDataProviderBundleIdentifier == AppRoutingPolicy.extensionIdentifier)
                filterRevision = filter.isEnabled && filter.providerConfiguration?.filterDataProviderBundleIdentifier == AppRoutingPolicy.extensionIdentifier
                    ? (filter.providerConfiguration?.vendorConfiguration?["policy"] as? Data).flatMap { try? AppRoutingPolicy.decode($0).revision } : nil
                let filterScope = filter.isEnabled && filter.providerConfiguration?.filterDataProviderBundleIdentifier == AppRoutingPolicy.extensionIdentifier
                    ? (filter.providerConfiguration?.vendorConfiguration?["policy"] as? Data).flatMap { try? AppRoutingPolicy.decode($0).scope } : nil
                let routerScope = manager?.isEnabled == true
                    ? ((manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["policy"] as? Data).flatMap { try? AppRoutingPolicy.decode($0).scope } : nil
                activeScope = filterScope ?? routerScope
                guard let manager, manager.isEnabled, manager.connection.status == .connected else {
                    runningRevision = nil
                    status = "Rules are not running"
                    detail = "The connection router is inactive. A separately enabled block filter may still apply."
                    return
                }
                let reply = try await providerMessage(Data("status".utf8), manager: manager)
                guard reply["schemaVersion"] as? Int == (activeScope == .ordinary ? 3 : 2),
                      reply["scope"] as? String == activeScope?.rawValue else {
                    runningRevision = nil
                    status = "Router update required"
                    detail = "Apply app rules to activate the matching extension and preserve unlisted apps on macOS routing."
                    return
                }
                runningRevision = (reply["revision"] as? String).flatMap(UUID.init(uuidString:))
                status = filterRevision == runningRevision && runningRevision != nil
                    ? "App rules running" : "Configuration mismatch · check setup"
                detail = "Direct: \(reply["directInterface"] as? String ?? "unknown")   •   VPN: \(reply["vpnInterface"] as? String ?? "unknown"). Restart affected apps after first activation."
            } catch { fail(error) }
        }
    }
    func disable() {
        guard !busy, Self.signingProblem == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Disable app connection rules?"
        alert.informativeText = "This removes internet blocking and VPN-only restrictions. Apps will follow macOS routing. Auto-reconnect remains available."
        alert.addButton(withTitle: "Keep rules enabled")
        alert.addButton(withTitle: "Disable rules")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await loadManager()
                if let manager {
                    manager.isOnDemandEnabled = false
                    manager.isEnabled = false
                    try await manager.saveToPreferences()
                    manager.connection.stopVPNTunnel()
                }
                let filter = NEFilterManager.shared()
                try await filter.loadFromPreferences()
                if filter.providerConfiguration?.filterDataProviderBundleIdentifier == AppRoutingPolicy.extensionIdentifier {
                    filter.isEnabled = false
                    try await filter.saveToPreferences()
                }
                runningRevision = nil; filterRevision = nil; activeScope = nil
                hasConfiguration = false
                status = "Rules disabled"
                detail = "Apps now follow macOS routing. Saved choices are retained."
            } catch { fail(error) }
        }
    }
    private func loadManager() async throws {
        let managers = try await NETransparentProxyManager.loadAllFromPreferences()
        let ours = managers.filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppRoutingPolicy.extensionIdentifier }
        guard ours.count <= 1 else { throw RoutingError("More than one connection-router profile exists; resolve duplicate profiles before applying.") }
        manager = ours.first
    }
    private func configure(_ policy: AppRoutingPolicy) async throws {
        let data = try policy.encoded()
        guard let serviceID = VPNService.serviceID() else { throw RoutingError("A unique supported system VPN was not found. Configure one native IPSec profile in macOS VPN settings.") }
        let oldProfiles = try await NETunnelProviderManager.loadAllFromPreferences()
        guard !oldProfiles.contains(where: { $0.isEnabled && ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == ClaudeGuardPolicy.extensionIdentifier }) else {
            throw RoutingError("Disable the older Claude-only guard before enabling the connection manager")
        }
        try await loadManager()
        let filter = NEFilterManager.shared()
        try await filter.loadFromPreferences()
        if let existing = filter.providerConfiguration,
           existing.filterDataProviderBundleIdentifier != AppRoutingPolicy.extensionIdentifier {
            throw RoutingError("An existing content-filter configuration is present. It will not be overwritten.")
        }
        let filterConfig = NEFilterProviderConfiguration()
        filterConfig.filterSockets = true
        filterConfig.filterDataProviderBundleIdentifier = AppRoutingPolicy.extensionIdentifier
        let previousData = filter.providerConfiguration?.vendorConfiguration?["policy"] as? Data
        let previous = try previousData.map(AppRoutingPolicy.decode) ?? AppRoutingPolicy()
        if policy.scope == .safariOnlyTest,
           previous.scope != .safariOnlyTest,
           !previous.rules.isEmpty {
            throw RoutingError("Disable the existing app-rule configuration before starting a Safari-only test. This protects unrelated app rules from a scope switch.")
        }
        let transition = policy.blockingTransition(from: previous)
        filterConfig.vendorConfiguration = ["policy": try transition.encoded(), "cambridgeServiceID": serviceID]
        filter.providerConfiguration = filterConfig
        filter.localizedDescription = "\(connectionAppName) App Rules"
        filter.isEnabled = true
        try await filter.saveToPreferences()
        try await filter.loadFromPreferences()
        hasConfiguration = true
        filterRevision = transition.revision
        activeScope = policy.scope

        let manager = self.manager ?? NETransparentProxyManager()
        let protocolConfig = NETunnelProviderProtocol()
        protocolConfig.providerBundleIdentifier = AppRoutingPolicy.extensionIdentifier
        protocolConfig.serverAddress = "Local application connection router"
        protocolConfig.providerConfiguration = ["policy": data, "cambridgeServiceID": serviceID]
        protocolConfig.disconnectOnSleep = false
        manager.localizedDescription = AppRoutingPolicy.profileName
        manager.protocolConfiguration = protocolConfig
        manager.isEnabled = true
        manager.onDemandRules = [NEOnDemandRuleConnect()]
        manager.isOnDemandEnabled = true
        self.manager = manager
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        if manager.connection.status == .connected {
            let reply = try await providerMessage(data, manager: manager)
            guard reply["revision"] as? String == policy.revision.uuidString,
                  reply["schemaVersion"] as? Int == policy.schemaVersion,
                  reply["scope"] as? String == policy.scope.rawValue else { throw RoutingError("The router did not acknowledge the saved rules") }
            runningRevision = policy.revision
        } else {
            try manager.connection.startVPNTunnel()
            runningRevision = nil
            for _ in 0..<30 {
                if manager.connection.status == .connected { break }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            guard manager.connection.status == .connected else {
                throw RoutingError("Router did not start. Temporary blocks remain for configured apps; retry Apply after resolving setup.")
            }
            let reply = try await providerMessage(Data("status".utf8), manager: manager)
            guard reply["revision"] as? String == policy.revision.uuidString,
                  reply["schemaVersion"] as? Int == policy.schemaVersion,
                  reply["scope"] as? String == policy.scope.rawValue else {
                throw RoutingError("Router revision mismatch. Temporary application blocks remain.")
            }
            runningRevision = policy.revision
        }
        // Release temporary blocks only after the router acknowledges the final policy.
        filterConfig.vendorConfiguration = ["policy": data, "cambridgeServiceID": serviceID]
        filter.providerConfiguration = filterConfig
        try await filter.saveToPreferences()
        try await filter.loadFromPreferences()
        filterRevision = policy.revision
        status = "App rules running"
        detail = "Router acknowledged the saved rules. Restart affected apps after first activation."
    }
    private func providerMessage(_ data: Data, manager: NETransparentProxyManager) async throws -> [String: Any] {
        guard let session = manager.connection as? NETunnelProviderSession else { throw RoutingError("No router session") }
        // An extension that stops responding must not freeze settings forever.
        return try await withCheckedThrowingContinuation { continuation in
            var completed = false // All accesses serialized on the main queue.
            let finish: (Result<[String: Any], Error>) -> Void = { result in
                DispatchQueue.main.async {
                    guard !completed else { return }; completed = true
                    continuation.resume(with: result)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish(.failure(RoutingError("Router status timed out; rules are not verified"))) }
            do {
                try session.sendProviderMessage(data) { reply in
                    guard let reply, let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any], object["error"] == nil else {
                        finish(.failure(RoutingError("Router rejected the request"))); return
                    }
                    finish(.success(object))
                }
            } catch { finish(.failure(error)) }
        }
    }
    private func fail(_ error: Error) {
        runningRevision = nil
        status = "Setup / status needs attention"
        detail = error.localizedDescription + " Existing or temporary app blocks may remain; use Apply to retry or Disable rules to remove them."
        AgentLog.write("connection manager: \(error.localizedDescription)")
    }
    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.status = "Waiting for macOS approval" }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            self.request = nil
            defer { self.busy = false }
            guard result == .completed, let policy = self.pendingPolicy else {
                self.status = "Restart required · rules not verified"; return
            }
            self.pendingPolicy = nil
            do { try await self.configure(policy) } catch { self.fail(error) }
        }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in self.request = nil; self.busy = false; self.fail(error) }
    }
    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                            withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
}
