import Darwin
import Foundation
import NetworkExtension
import CambridgeVPNAutoCore

/// A socket filter separate from the transparent router. No payload inspection.
@objc(InternetFilterProvider)
final class InternetFilterProvider: NEFilterDataProvider {
    private struct Tracked {
        let flow: NEFilterSocketFlow
        let source: FlowIdentity
        let route: AppRoute
        let tunnel: GuardTunnel?
    }
    private let lock = NSLock()
    private var flows: [UUID: Tracked] = [:]
    private var configuredIdentifiers = Set<String>()
    private var timer: DispatchSourceTimer?

    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        do {
            _ = try currentPolicy()
            let rule = NENetworkRule(remoteNetwork: nil, remotePrefix: 0, localNetwork: nil,
                                     localPrefix: 0, protocol: .any, direction: .outbound)
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.wjli.connection-filter"))
            timer.schedule(deadline: .now(), repeating: 1)
            timer.setEventHandler { [weak self] in self?.recheckFlows() }
            self.timer = timer; timer.resume()
            apply(NEFilterSettings(rules: [NEFilterRule(networkRule: rule, action: .filterData)],
                                   defaultAction: .allow), completionHandler: completionHandler)
        } catch { completionHandler(error) }
    }
    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        timer?.cancel(); timer = nil
        lock.lock(); flows.removeAll(); lock.unlock()
        completionHandler()
    }
    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard flow.direction == .outbound else { return .allow() }
        // Resolver lookups are shared system work even when attributed to
        // Safari. Do not drop/track them during Block or temporary transitions.
        if let socket = flow as? NEFilterSocketFlow,
           (socket.socketProtocol == IPPROTO_TCP || socket.socketProtocol == IPPROTO_UDP),
           preservesSystemDNS(socket.remoteEndpoint) { return .allow() }
        let source = FlowIdentity(auditToken: flow.sourceAppAuditToken)
        guard let policy = try? currentPolicy() else {
            lock.lock()
            let configured = configuredIdentifiers.contains(source.signingIdentifier)
            lock.unlock()
            return configured ? .drop() : .allow()
        }
        // The API installs a system-wide filter, but only explicit app rules
        // may be retained or rechecked. Other traffic stays on macOS/VPN.
        guard policy.admission(for: source.signingIdentifier, verify: source.verifies) != .bypassMacOS else {
            return .allow()
        }
        guard let route = policy.route(for: source.signingIdentifier, verify: source.verifies) else { return .allow() }
        let tunnel = currentTunnel()
        guard route != .blocked, route != .cambridgeVPN || tunnel != nil else { return .drop() }
        if let socket = flow as? NEFilterSocketFlow {
            lock.lock()
            flows[flow.identifier] = Tracked(flow: socket, source: source, route: route, tunnel: tunnel)
            lock.unlock()
        }
        let verdict = NEFilterNewFlowVerdict.allow()
        verdict.shouldReport = true // Receive closure events to release tracking.
        return verdict
    }
    override func handle(_ report: NEFilterReport) {
        guard report.event == .flowClosed, let flow = report.flow else { return }
        lock.lock(); flows[flow.identifier] = nil; lock.unlock()
    }
    private func recheckFlows() {
        let policy = try? currentPolicy()
        let tunnel = currentTunnel()
        lock.lock()
        let closing = flows.filter { _, item in
            guard let policy else { return true }
            let route = policy.route(for: item.source.signingIdentifier, verify: item.source.verifies)
            return route == .blocked || route != item.route || (route == .cambridgeVPN && (tunnel == nil || tunnel != item.tunnel))
        }
        for (id, _) in closing { flows[id] = nil }
        lock.unlock()
        for (_, item) in closing { update(item.flow, using: .drop(), for: .any) }
    }
    private func currentPolicy() throws -> AppRoutingPolicy {
        guard let data = filterConfiguration.vendorConfiguration?["policy"] as? Data else {
            throw RoutingError("Socket filter has no valid application policy")
        }
        let policy = try AppRoutingPolicy.decode(data)
        lock.lock()
        configuredIdentifiers = Set(policy.rules.flatMap(\.identities).map(\.signingIdentifier))
        lock.unlock()
        return policy
    }
    private func currentTunnel() -> GuardTunnel? {
        readCambridgeTunnel(serviceID: filterConfiguration.vendorConfiguration?["cambridgeServiceID"] as? String)
    }
}
