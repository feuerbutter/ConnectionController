import Darwin
import Foundation
import Network
import NetworkExtension
import OSLog
import ConnectionRouterObjC
import CambridgeVPNAutoCore

@objc(ConnectionRouterProvider)
final class ConnectionRouterProvider: NETransparentProxyProvider {
    private let queue = DispatchQueue(label: "com.wjli.connection-router.flows")
    private let policyLock = NSLock()
    private var pathMonitor: NWPathMonitor?
    private var interfaces: [NWInterface] = []
    private var policy: AppRoutingPolicy?
    private var configuredIdentifiers = Set<String>()
    private var serviceID: String?
    private var tunnel: GuardTunnel?
    private var direct: RouteInterface?
    private var timer: DispatchSourceTimer?
    private struct Session {
        let route: AppRoute
        let relay: FlowRelay
    }
    private var relays: [UUID: Session] = [:]

    private struct PolicySnapshot {
        let policy: AppRoutingPolicy?
        let configuredIdentifiers: Set<String>
    }

    private func installPolicy(_ policy: AppRoutingPolicy) {
        policyLock.lock()
        self.policy = policy
        configuredIdentifiers = Set(policy.rules.flatMap(\.identities).map(\.signingIdentifier))
        policyLock.unlock()
    }

    private func clearPolicy() {
        policyLock.lock()
        policy = nil
        policyLock.unlock()
    }

    private func policySnapshot() -> PolicySnapshot {
        policyLock.lock()
        let snapshot = PolicySnapshot(policy: policy, configuredIdentifiers: configuredIdentifiers)
        policyLock.unlock()
        return snapshot
    }

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        do {
            guard let config = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
                  let data = config["policy"] as? Data,
                  let serviceID = config["cambridgeServiceID"] as? String, !serviceID.isEmpty else {
                throw RoutingError("Missing connection policy or system VPN service")
            }
            let policy = try AppRoutingPolicy.decode(data)
            // Install the immutable policy before accepting flows. The monitor
            // itself is initialized on the provider queue below.
            installPolicy(policy)
            queue.async { [self] in
                self.serviceID = serviceID
                let monitor = NWPathMonitor()
                self.pathMonitor = monitor
                monitor.pathUpdateHandler = { [weak self] path in
                    self?.interfaces = path.availableInterfaces
                    self?.refreshRoutes()
                }
                monitor.start(queue: self.queue)
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: 1)
                timer.setEventHandler { [weak self] in self?.refreshRoutes() }
                self.timer = timer
                timer.resume()
                let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
                settings.includedNetworkRules = [NENetworkRule(remoteNetwork: nil, remotePrefix: 0,
                    localNetwork: nil, localPrefix: 0, protocol: .any, direction: .outbound)]
                settings.excludedNetworkRules = []
                self.setTunnelNetworkSettings(settings, completionHandler: completionHandler)
            }
        } catch { completionHandler(error) }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async { [self] in
            self.timer?.cancel(); self.timer = nil
            self.pathMonitor?.cancel(); self.pathMonitor = nil
            self.closeSessions { _ in true }
            self.clearPolicy(); self.interfaces = []; self.tunnel = nil; self.direct = nil
            completionHandler()
        }
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        if let tcp = flow as? NEAppProxyTCPFlow, preservesSystemDNS(tcp.remoteEndpoint) {
            return releaseSystemDNS()
        }
        return accept(flow)
    }

    override func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteEndpoint remoteEndpoint: CMLegacyEndpoint) -> Bool {
        if preservesSystemDNS(remoteEndpoint) { return releaseSystemDNS() }
        return accept(flow, initialUDPEndpoint: endpoint(remoteEndpoint))
    }

    fileprivate func releaseSystemDNS() -> Bool {
        Logger(subsystem: AppRoutingPolicy.extensionIdentifier, category: "resolver")
            .info("Preserving configured system DNS on its macOS route")
        return false
    }

    fileprivate func accept(_ flow: NEAppProxyFlow, initialUDPEndpoint: Network.NWEndpoint? = nil) -> Bool {
        // A relay's own socket is already bound to its selected interface.
        // Never re-proxy it. No user-editable rule can target this provider.
        if flow.metaData.sourceAppSigningIdentifier == AppRoutingPolicy.extensionIdentifier { return false }
        let source = FlowIdentity(auditToken: flow.metaData.sourceAppAuditToken,
                                  fallbackIdentifier: flow.metaData.sourceAppSigningIdentifier)
        let snapshot = policySnapshot()
        guard let policy = snapshot.policy else {
            // Only previously configured apps fail closed during shutdown.
            // Never interrupt unrelated networking or the VPN transport.
            if !snapshot.configuredIdentifiers.contains(source.signingIdentifier) {
                return false
            }
            queue.async { closeFlow(flow, error: guardError("Connection policy unavailable")) }
            return true
        }
        // Decide synchronously, before dispatching to the relay queue.
        // Unlisted apps, system services and VPN transport retain macOS routing.
        guard policy.admission(for: source.signingIdentifier, verify: source.verifies) != .bypassMacOS else {
            return false
        }
        queue.async { [self] in
            self.refreshRoutes()
            // A policy update may have happened after the synchronous
            // admission decision. Do not let a now-unlisted app flow become
            // a relay simply because this block was already queued.
            let current = self.policySnapshot()
            guard let policy = current.policy else {
                closeFlow(flow, error: guardError("Connection policy unavailable")); return
            }
            guard policy.admission(for: source.signingIdentifier, verify: source.verifies) != .bypassMacOS else {
                closeFlow(flow, error: guardError("Application no longer has an explicit rule")); return
            }
            guard let route = policy.route(for: source.signingIdentifier, verify: source.verifies), route != .blocked else {
                closeFlow(flow, error: guardError("Internet access is blocked for this application")); return
            }
            let selected: NWInterface?
            switch route {
            case .cambridgeVPN:
                selected = self.interfaces.first { value in
                    self.tunnel?.matches(interfaceName: value.name, observedIndex: value.index,
                                         liveIndex: if_nametoindex(value.name)) == true
                }
            case .direct:
                selected = self.interfaces.first { routeInterface($0) == self.direct }
            case .blocked: selected = nil
            }
            guard let interface = selected else {
                closeFlow(flow, error: guardError("Selected connection unavailable; no fallback permitted")); return
            }
            let tunnel = self.tunnel
            let revision = policy.revision
            let id = UUID()
            let isCurrent: () -> Bool = { [weak self] in
                guard let self, self.policySnapshot().policy?.revision == revision,
                      if_nametoindex(interface.name) == UInt32(interface.index) else { return false }
                if route == .cambridgeVPN { return tunnel != nil && readCambridgeTunnel(serviceID: self.serviceID) == tunnel }
                return self.direct == routeInterface(interface)
            }
            let finished: () -> Void = { [weak self] in self?.relays[id] = nil }
            let relay: FlowRelay
            if let tcp = flow as? NEAppProxyTCPFlow {
                relay = TCPRelay(flow: tcp, interface: interface, queue: self.queue, isCurrent: isCurrent, finished: finished)
            } else if let udp = flow as? NEAppProxyUDPFlow {
                relay = UDPRelay(flow: udp, initialRemoteEndpoint: initialUDPEndpoint, interface: interface, queue: self.queue, isCurrent: isCurrent, finished: finished)
            } else {
                closeFlow(flow, error: guardError("Unsupported connection type")); return
            }
            self.relays[id] = Session(route: route, relay: relay)
            relay.start()
        }
        // Returning false would let this flow use the system's route, including
        // a physical connection when a VPN-only rule cannot be satisfied.
        return true
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        queue.async { [self] in
            do {
                if messageData != Data("status".utf8) {
                    let next = try AppRoutingPolicy.decode(messageData)
                    self.closeSessions { _ in true }
                    self.installPolicy(next)
                }
                self.refreshRoutes()
                let reply: [String: Any] = [
                    "revision": self.policySnapshot().policy?.revision.uuidString ?? "",
                    "schemaVersion": self.policySnapshot().policy?.schemaVersion ?? 0,
                    "scope": self.policySnapshot().policy?.scope.rawValue ?? "unavailable",
                    "vpnInterface": self.tunnel?.interfaceName ?? "unavailable",
                    "directInterface": self.direct?.name ?? "unavailable",
                    "activeFlows": self.relays.count
                ]
                completionHandler?(try JSONSerialization.data(withJSONObject: reply))
            } catch {
                // A malformed update leaves the last valid policy in force.
                completionHandler?(try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription]))
            }
        }
    }

    private func selectDirect() -> RouteInterface? {
        let order = physicalServiceOrder()
        return RouteSelection.direct(interfaces: interfaces.map(routeInterface).filter { order.contains($0.name) },
                                     serviceOrder: order)
    }
    private func refreshRoutes() {
        let nextTunnel = readCambridgeTunnel(serviceID: serviceID)
        let nextDirect = selectDirect()
        if tunnel != nextTunnel { closeSessions { $0 == .cambridgeVPN }; tunnel = nextTunnel }
        if direct != nextDirect { closeSessions { $0 == .direct }; direct = nextDirect }
    }
    private func closeSessions(matching predicate: (AppRoute) -> Bool) {
        let closing = relays.filter { predicate($0.value.route) }
        for (id, session) in closing {
            relays[id] = nil
            session.relay.stop(guardError("Connection or application rule changed"))
        }
    }
}

// macOS 15+ delivers Network.NWEndpoint via this Swift overlay protocol.
// Handle it explicitly so DNS is classified before opening a UDP relay.
@available(macOS 15.0, *)
extension ConnectionRouterProvider: NEAppProxyUDPFlowHandling {
    func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteFlowEndpoint remoteEndpoint: Network.NWEndpoint) -> Bool {
        if case let .hostPort(host, port) = remoteEndpoint,
           preservesSystemDNS("\(host)", port: port.rawValue) {
            return releaseSystemDNS()
        }
        return accept(flow, initialUDPEndpoint: remoteEndpoint)
    }
}
