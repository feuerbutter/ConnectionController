import Foundation
import CambridgeVPNAutoCore

func runClaudeGuardChecks(_ runner: inout CheckRunner) {
    // Shape observed with unrestricted scutil on the real IPSec service.
    let connected: [String: Any] = [
        "Status": 2,
        "IPv4": ["InterfaceName": "utun5", "Addresses": ["172.16.32.157"]],
        "IPSec": ["Status": 6, "ConnectTime": 60771]
    ]
    let tunnel = GuardTunnel(extendedStatus: connected)
    runner.expect(tunnel?.interfaceName == "utun5", "guard accepts connected IPSec tunnel")
    runner.expect(tunnel?.matches(interfaceName: "utun5", observedIndex: 27, liveIndex: 27) == true,
                  "guard resolves the selected tunnel by name and index")
    runner.expect(tunnel?.matches(interfaceName: "en0", observedIndex: 19, liveIndex: 19) == false,
                  "physical interface is never a tunnel fallback")
    runner.expect(tunnel?.matches(interfaceName: "utun5", observedIndex: 27, liveIndex: 0) == false,
                  "removed tunnel interface is rejected")
    runner.expect(tunnel?.matches(interfaceName: "utun5", observedIndex: 27, liveIndex: 28) == false,
                  "stale interface index is rejected")
    for state in [0, 1, 3, 4] {
        var changed = connected
        changed["Status"] = state
        runner.expect(GuardTunnel(extendedStatus: changed) == nil,
                      "guard rejects non-connected service state \(state)")
    }
    var changed = connected
    changed["IPSec"] = ["Status": 0, "ConnectTime": 60771]
    runner.expect(GuardTunnel(extendedStatus: changed) == nil, "stale IPv4 data cannot override disconnected IPSec")
    changed["IPSec"] = ["Status": 6, "ConnectTime": 99999]
    runner.expect(GuardTunnel(extendedStatus: changed) != tunnel, "reconnect with reused interface starts a new generation")
    changed = connected
    changed["IPv4"] = ["InterfaceName": "en0", "Addresses": ["192.168.1.2"]]
    runner.expect(GuardTunnel(extendedStatus: changed) == nil, "guard rejects physical interface in service data")
    changed["IPv4"] = ["InterfaceName": "utun5", "Addresses": [String]()]
    runner.expect(GuardTunnel(extendedStatus: changed) == nil, "guard rejects tunnel without an assigned address")
    runner.expect(GuardTunnel(extendedStatus: [:]) == nil, "unknown status keeps guard closed")
}
