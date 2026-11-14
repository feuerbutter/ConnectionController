import Darwin
import Foundation
import SystemConfiguration
import CambridgeVPNAutoCore

enum VPNService {
    // Route only through one enabled, supported service in the active macOS
    // network location. Its user-chosen name is not part of the identity.
    static func serviceID() -> String? {
        guard let preferences = SCPreferencesCreate(nil, "\(connectionAppName)" as CFString, nil),
              let currentSet = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(currentSet) as? [SCNetworkService] else { return nil }
        let matches = services.filter { service in
            guard SCNetworkServiceGetEnabled(service), let interface = SCNetworkServiceGetInterface(service) else { return false }
            return SCNetworkInterfaceGetInterfaceType(interface) == kSCNetworkInterfaceTypeIPSec
        }
        return matches.count == 1 ? SCNetworkServiceGetServiceID(matches[0]) as String? : nil
    }

    static func connectionState() -> VPNConnectionState {
        guard let id = serviceID() else { return .unknown }
        let result = runScutil(["status", id])
        guard result.exitCode == 0 else {
            AgentLog.write("VPN status query failed exit=\(result.exitCode): \(result.standardError)")
            return .unknown
        }

        let firstLine = result.standardOutput
            .split(whereSeparator: { $0.isNewline })
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch firstLine {
        case "connected":
            return .connected
        case "connecting":
            return .connecting
        case "disconnecting":
            return .disconnecting
        case "disconnected":
            return .disconnected
        default:
            return .unknown
        }
    }

    static func start() -> CommandResult {
        guard let id = serviceID() else { return unavailableService() }
        return runScutil(["start", id])
    }

    static func stop() -> CommandResult {
        guard let id = serviceID() else { return unavailableService() }
        return runScutil(["stop", id])
    }

    static func internetAvailable() -> Bool {
        // Ask macOS about default-route reachability without depending on a
        // provider-specific hostname or performing a remote probe.
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        let reachability = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        }
        guard let reachability else { return false }
        var flags = SCNetworkReachabilityFlags()
        guard SCNetworkReachabilityGetFlags(reachability, &flags) else {
            return false
        }

        let reachable = flags.contains(.reachable)
        let connectionRequired = flags.contains(.connectionRequired)
        let canConnectAutomatically = flags.contains(.connectionOnTraffic)
            || flags.contains(.connectionOnDemand)
        return reachable && (!connectionRequired || canConnectAutomatically)
    }

    private static func unavailableService() -> CommandResult {
        CommandResult(exitCode: 3, standardOutput: "", standardError: "A unique supported system VPN was not found. Configure one native IPSec profile in macOS VPN settings.")
    }

    private static func runScutil(_ arguments: [String]) -> CommandResult {
        BoundedCommand.run(executable: "/usr/sbin/scutil", arguments: ["--nc"] + arguments)
    }
}
