import Darwin
import Foundation
import Network
import NetworkExtension
import SystemConfiguration
import CambridgeVPNAutoCore

func readCambridgeTunnel(serviceID: String?) -> GuardTunnel? {
    guard let serviceID,
          let connection = SCNetworkConnectionCreateWithServiceID(nil, serviceID as CFString, nil, nil),
          let status = SCNetworkConnectionCopyExtendedStatus(connection) as? [String: Any] else { return nil }
    return GuardTunnel(extendedStatus: status)
}

func physicalServiceOrder() -> [String] {
    guard let preferences = SCPreferencesCreate(nil, "ConnectionRouter" as CFString, nil),
          let set = SCNetworkSetCopyCurrent(preferences),
          let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else { return [] }
    let order = SCNetworkSetGetServiceOrder(set) as? [String] ?? []
    let byID = Dictionary(uniqueKeysWithValues: services.compactMap { service -> (String, SCNetworkService)? in
        guard let id = SCNetworkServiceGetServiceID(service) as String? else { return nil }
        return (id, service)
    })
    let store = SCDynamicStoreCreate(nil, "ConnectionRouter" as CFString, nil, nil)
    return order.compactMap { id in
        guard let service = byID[id], SCNetworkServiceGetEnabled(service),
              let interface = SCNetworkServiceGetInterface(service),
              let device = SCNetworkInterfaceGetBSDName(interface) as String?,
              let store else { return nil }
        // Configured, enabled and actually assigned an address. A disconnected
        // Ethernet adapter must not win over a working Wi-Fi connection.
        let hasAddress = ["IPv4", "IPv6"].contains { family in
            let key = "State:/Network/Service/\(id)/\(family)" as CFString
            let state = SCDynamicStoreCopyValue(store, key) as? [String: Any]
            return !(state?["Addresses"] as? [String] ?? []).isEmpty
        }
        return hasAddress ? device : nil
    }
}

func routeInterface(_ value: NWInterface) -> RouteInterface {
    let kind: RouteInterface.Kind
    switch value.type {
    case .wifi: kind = .wifi
    case .wiredEthernet: kind = .ethernet
    case .cellular: kind = .cellular
    default: kind = value.name.hasPrefix("utun") ? .tunnel : .other
    }
    return RouteInterface(name: value.name, index: value.index, kind: kind)
}

func guardError(_ message: String) -> NSError {
    NSError(domain: NEAppProxyErrorDomain, code: NEAppProxyFlowError.refused.rawValue,
            userInfo: [NSLocalizedDescriptionKey: message])
}
func closeFlow(_ flow: NEAppProxyFlow, error: Error?) {
    flow.closeReadWithError(error); flow.closeWriteWithError(error)
}
protocol FlowRelay: AnyObject {
    func start()
    func stop(_ error: Error?)
}
func endpoint(_ value: AnyObject, hostname: String? = nil) -> Network.NWEndpoint? {
    guard let host = value as? NWHostEndpoint, let port = Network.NWEndpoint.Port(host.port) else { return nil }
    // Preserve the OS-supplied connect-by-name destination. NWConnection
    // resolves it on requiredInterface, avoiding VPN-region CDN answers on a
    // Direct socket. Literal-address flows retain their exact destination.
    let name = hostname.flatMap { $0.isEmpty ? nil : $0 } ?? host.hostname
    return .hostPort(host: .init(name), port: port)
}
func parameters(tcp: Bool, interface: NWInterface) -> NWParameters {
    let result = tcp ? NWParameters.tcp : NWParameters.udp
    result.requiredInterface = interface
    result.multipathServiceType = .disabled
    return result
}

// Read only active Dynamic Store DNS, not saved Setup preferences. Include
// scoped physical and VPN resolvers, since either can be selected by macOS.
func preservesSystemDNS(_ host: String, port: UInt16) -> Bool {
    guard port == 53,
          let store = SCDynamicStoreCreate(nil, "ConnectionRouterDNS" as CFString, nil, nil),
          let values = SCDynamicStoreCopyMultiple(store,
              ["State:/Network/Global/DNS"] as CFArray,
              ["State:/Network/Service/.*/DNS"] as CFArray) as? [String: Any] else { return false }
    let servers = values.flatMap { key, value -> [String] in
        if key.hasPrefix("State:/Network/Service/") {
            let serviceKey = String(key.dropLast("DNS".count))
            let live = ["IPv4", "IPv6"].contains { family in
                let state = SCDynamicStoreCopyValue(store, (serviceKey + family) as CFString) as? [String: Any]
                return !(state?["Addresses"] as? [String] ?? []).isEmpty
            }
            guard live else { return [] }
        }
        return (value as? [String: Any])?["ServerAddresses"] as? [String] ?? []
    }
    return SystemDNSPolicy.preservesSystemRoute(host: host, port: port, servers: servers)
}

func preservesSystemDNS(_ value: AnyObject?) -> Bool {
    guard let host = value as? NWHostEndpoint, let port = UInt16(host.port) else { return false }
    return preservesSystemDNS(host.hostname, port: port)
}
