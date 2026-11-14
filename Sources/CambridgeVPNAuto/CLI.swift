import Foundation
import CambridgeVPNAutoCore

@MainActor
enum CLI {
    static func run(arguments: [String]) -> Int32 {
        guard let command = arguments.first else {
            printHelp()
            return 2
        }

        if Bundle.main.object(forInfoDictionaryKey: "CambridgeUIPreview") as? Bool == true,
           ["--arm", "--ensure-connected", "--pause"].contains(command) {
            fputs("UI preview cannot change the VPN. Use the installed controller.\n", stderr)
            return 3
        }
        switch command {
        case "--arm", "--ensure-connected":
            return arm()
        case "--pause":
            return pause()
        case "--guard-status":
            print(ClaudeGuardController.signingProblem ?? "Signing present. Check the menu for activation state; live validation is required.")
            return ClaudeGuardController.signingProblem == nil ? 0 : 3
        case "--routing-status":
            print(RoutingController.signingProblem ?? "Signing present. Open Application Connections for running status; live validation is required.")
            return RoutingController.signingProblem == nil ? 0 : 3
        case "--rules":
            do {
                print(String(decoding: try AppRoutingStore().load().encoded(), as: UTF8.self))
                return 0
            } catch { fputs("Rules could not be read: \(error.localizedDescription)\n", stderr); return 1 }
        case "--inspect-app":
            guard arguments.count == 2 else { return 2 }
            do {
                let rule = try AppCatalog.inspect(URL(fileURLWithPath: arguments[1]), route: .direct)
                print(String(decoding: try AppRoutingPolicy(rules: [rule]).encoded(), as: UTF8.self))
                return 0
            } catch { fputs("Application could not be read: \(error.localizedDescription)\n", stderr); return 1 }
        case "--vpn-service":
            guard let id = VPNService.serviceID() else {
                fputs("A unique supported system VPN was not found. Configure one native IPSec profile in macOS VPN settings.\n", stderr)
                return 3
            }
            print(id)
            return 0
        case "--status":
            return showStatus()
        case "--help", "-h":
            printHelp()
            return 0
        default:
            fputs("Unknown command: \(command)\n", stderr)
            printHelp()
            return 2
        }
    }

    private static func arm() -> Int32 {
        let store = ControlStateStore()
        var state = loadState(from: store)
        state.mode = .armed
        state.manualStopPending = false
        state.updatedAt = Date()
        guard save(state, to: store) else {
            return 1
        }

        let vpnState = VPNService.connectionState()
        if vpnState == .disconnected || vpnState == .unknown {
            let result = VPNService.start()
            if result.exitCode != 0 {
                fputs("VPN start request failed: \(result.standardError)\n", stderr)
                return result.exitCode
            }
        }
        print("controller=armed vpn=\(VPNService.connectionState().rawValue)")
        return 0
    }

    private static func pause() -> Int32 {
        let store = ControlStateStore()
        let vpnState = VPNService.connectionState()
        var state = loadState(from: store)
        state.mode = .paused
        state.manualStopPending = vpnState != .disconnected
        state.updatedAt = Date()
        guard save(state, to: store) else {
            return 1
        }

        if state.manualStopPending {
            let result = VPNService.stop()
            if result.exitCode != 0 {
                fputs("VPN stop request failed: \(result.standardError)\n", stderr)
                return result.exitCode
            }
        }
        print("controller=paused vpn=\(VPNService.connectionState().rawValue)")
        return 0
    }

    private static func showStatus() -> Int32 {
        let state = loadState(from: ControlStateStore())
        print("controller=\(state.mode.rawValue)")
        print("manual_stop_pending=\(state.manualStopPending)")
        print("vpn=\(VPNService.connectionState().rawValue)")
        print("internet_reachable=\(VPNService.internetAvailable())")
        return 0
    }

    private static func loadState(from store: ControlStateStore) -> PersistentControlState {
        do {
            return try store.load()
        } catch {
            fputs("Control state could not be read; defaulting to armed: \(error)\n", stderr)
            return .armed()
        }
    }

    private static func save(_ state: PersistentControlState, to store: ControlStateStore) -> Bool {
        do {
            try store.save(state)
            return true
        } catch {
            fputs("Control state could not be saved: \(error)\n", stderr)
            return false
        }
    }

    private static func printHelp() {
        print("""
        \(connectionAppName) commands:
          --arm                 Turn the VPN on and keep auto-reconnect armed
          --pause               Turn the VPN off and persist the manual pause
          --status              Show controller, VPN, and reachability state
          --vpn-service         Show the discovered native IPSec VPN service identifier
          --guard-status        Report whether this build can activate Claude protection
          --routing-status      Report signing availability for per-app rules (exit 3 when unavailable)
          --rules               Print the desired saved rules; this is not enforcement status
          --inspect-app PATH    Inspect an app's signed identities without changing its rule
          --settings            Open Application Connections in the running controller
          --safari-test-mode    Open the locked, non-persisted Safari-only routing test window
          --preview-ui          Open an isolated UI preview; no VPN commands or saved changes
          --agent               Run the menu-bar controller
        """)
    }
}
