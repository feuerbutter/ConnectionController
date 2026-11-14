import Darwin
import Foundation
import Network
import NetworkExtension
import SystemConfiguration
import CambridgeVPNAutoCore

@objc(GuardProvider)
final class GuardProvider: NEAppProxyProvider {
    private let queue = DispatchQueue(label: "com.wjli.claude-guard.flows")
    private let pathMonitor = NWPathMonitor()
    private var interfaces: [NWInterface] = []
    private var serviceID: String?
    private var tunnel: GuardTunnel?
    private var timer: DispatchSourceTimer?
    private var relays: [UUID: FlowRelay] = [:]

    override func startProxy(options: [String: Any]? = nil, completionHandler: @escaping (Error?) -> Void) {
        guard let settings = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration,
              let id = settings["cambridgeServiceID"] as? String, !id.isEmpty else {
            completionHandler(guardError("A system VPN service is not configured"))
            return
        }
        queue.async { [self] in
            self.serviceID = id
            self.pathMonitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                self.interfaces = path.availableInterfaces
                self.refreshTunnel()
            }
            self.pathMonitor.start(queue: self.queue)
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1)
            timer.setEventHandler { [weak self] in self?.refreshTunnel() }
            self.timer = timer
            timer.resume()
            // Stay active when the system VPN is off: delivered flows are rejected.
            // The timer closes stale sessions; requiredInterface prevents fallback.
            completionHandler(nil)
        }
    }

    override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        queue.async { [self] in
            self.timer?.cancel()
            self.timer = nil
            self.pathMonitor.cancel()
            self.closeRelays()
            self.serviceID = nil
            self.tunnel = nil
            completionHandler()
        }
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        // The OS applies signed per-app rules before dispatch. Do not reclassify
        // here: children such as tools launched by Claude must remain protected.
        queue.async { [self] in
            self.refreshTunnel()
            guard let tunnel = self.tunnel,
                  let interface = self.interfaces.first(where: {
                      tunnel.matches(interfaceName: $0.name, observedIndex: $0.index,
                                     liveIndex: if_nametoindex(tunnel.interfaceName))
                  }) else {
                closeFlow(flow, error: guardError("The system VPN is unavailable"))
                return
            }
            let id = UUID()
            let finished: () -> Void = { [weak self] in self?.relays[id] = nil }
            let isCurrent: () -> Bool = { [weak self] in
                self?.readTunnel() == tunnel &&
                if_nametoindex(tunnel.interfaceName) == UInt32(interface.index)
            }
            let relay: FlowRelay
            if let tcp = flow as? NEAppProxyTCPFlow {
                relay = TCPRelay(flow: tcp, interface: interface, queue: self.queue,
                                 isCurrent: isCurrent, finished: finished)
            } else if let udp = flow as? NEAppProxyUDPFlow {
                relay = UDPRelay(flow: udp, interface: interface, queue: self.queue,
                                 isCurrent: isCurrent, finished: finished)
            } else {
                closeFlow(flow, error: guardError("Unsupported protected flow"))
                return
            }
            self.relays[id] = relay
            relay.start()
        }
        return true
    }

    private func readTunnel() -> GuardTunnel? {
        // Legacy IPSec returns disconnected from SCNetworkConnectionGetStatus
        // on this Mac even while ExtendedStatus and scutil correctly say connected.
        // Require both connected fields and the interface in ExtendedStatus instead.
        guard let serviceID,
              let connection = SCNetworkConnectionCreateWithServiceID(nil, serviceID as CFString, nil, nil),
              let status = SCNetworkConnectionCopyExtendedStatus(connection) as? [String: Any]
        else { return nil }
        return GuardTunnel(extendedStatus: status)
    }

    private func refreshTunnel() {
        let next = readTunnel()
        if next != tunnel {
            closeRelays()
            tunnel = next
        }
    }

    private func closeRelays() {
        let current = Array(relays.values)
        relays.removeAll()
        for relay in current { relay.stop(guardError("VPN connection changed")) }
    }
}

func guardError(_ message: String) -> NSError {
    NSError(domain: NEAppProxyErrorDomain, code: NEAppProxyFlowError.refused.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message])
}

func closeFlow(_ flow: NEAppProxyFlow, error: Error?) {
    flow.closeReadWithError(error)
    flow.closeWriteWithError(error)
}

protocol FlowRelay: AnyObject {
    func start()
    func stop(_ error: Error?)
}

func endpoint(_ value: AnyObject) -> Network.NWEndpoint? {
    guard let host = value as? NWHostEndpoint,
          let port = Network.NWEndpoint.Port(host.port) else { return nil }
    return .hostPort(host: .init(host.hostname), port: port)
}

func parameters(tcp: Bool, interface: NWInterface) -> NWParameters {
    let parameters = tcp ? NWParameters.tcp : NWParameters.udp
    parameters.requiredInterface = interface
    parameters.multipathServiceType = .disabled
    return parameters
}
