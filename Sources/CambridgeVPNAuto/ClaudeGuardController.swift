import AppKit
import Foundation
import NetworkExtension
import Security
import SystemConfiguration
import SystemExtensions
import CambridgeVPNAutoCore

final class ClaudeGuardController: NSObject, OSSystemExtensionRequestDelegate {
    var onChange: ((String) -> Void)?
    private(set) var status = "Claude protection: Not active"
    private var manager: NETunnelProviderManager?
    private var pendingRequest: OSSystemExtensionRequest?
    private var statusObserver: NSObjectProtocol?

    static var signingProblem: String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let data = info as? [String: Any],
              data[kSecCodeInfoTeamIdentifier as String] as? String != nil,
              let entitlements = data[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements["com.apple.developer.system-extension.install"] as? Bool == true,
              let network = entitlements["com.apple.developer.networking.networkextension"] as? [String],
              network.contains("app-proxy-provider-systemextension") else {
            return "This build does not have Apple Developer signing and the Network Extension entitlements. Claude is NOT protected. An Apple Developer Program membership and signed provisioning profiles are required to activate the standalone guard."
        }
        let extensionURL = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/SystemExtensions/\(ClaudeGuardPolicy.extensionIdentifier).systemextension")
        guard FileManager.default.fileExists(atPath: extensionURL.path) else {
            return "The signed Claude VPN Guard system extension is missing from this app. Claude is NOT protected."
        }
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
            return "Install the signed app in /Applications before activating its system extension. This preview is not active."
        }
        return nil
    }

    func start() {
        guard Self.signingProblem == nil else {
            setStatus("Claude protection: Unavailable — signing required")
            return
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.renderStatus() }
        loadManager { [weak self] error in
            if let error { self?.setStatus("Claude protection: Unavailable (\(error.localizedDescription))") }
            else { self?.renderStatus() }
        }
    }

    func showControls() {
        if let problem = Self.signingProblem {
            let alert = NSAlert()
            alert.messageText = "Claude VPN Guard is not active"
            alert.informativeText = problem + "\n\nThe standalone source and build instructions are in the project’s docs/claude-vpn-guard.md. The current VPN reconnect controller continues to work normally."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        guard pendingRequest == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Claude VPN Guard (experimental)"
        alert.informativeText = "The guard routes Claude Desktop, Claude Code and their child tools through the system VPN. Other apps retain their normal access.\n\nThis build still requires live validation. Restart Claude after first activation to replace existing sockets. macOS will ask you to approve the system extension and per-app VPN configuration."
        alert.addButton(withTitle: "Enable Guard")
        alert.addButton(withTitle: "Cancel")
        if manager?.isEnabled == true { alert.addButton(withTitle: "Disable Guard…") }
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn { activate() }
        else if response == .alertThirdButtonReturn { confirmDisable() }
    }

    private func activate() {
        setStatus("Claude protection: Waiting for macOS approval")
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: ClaudeGuardPolicy.extensionIdentifier, queue: .main)
        request.delegate = self
        pendingRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func loadManager(completion: @escaping (Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            DispatchQueue.main.async {
                self.manager = managers?.first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == ClaudeGuardPolicy.extensionIdentifier
                }
                completion(error)
            }
        }
    }

    private func configure() {
        loadManager { error in
            if let error { self.report(error); return }
            guard let serviceID = self.cambridgeServiceID() else {
                self.report(NSError(domain: "ClaudeVPNGuard", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "A unique supported system VPN was not found"]))
                return
            }
            let manager = self.manager ?? NETunnelProviderManager.forPerAppVPN()
            let configuration = NETunnelProviderProtocol()
            configuration.providerBundleIdentifier = ClaudeGuardPolicy.extensionIdentifier
            configuration.serverAddress = "VPN only (local per-app guard)"
            configuration.providerConfiguration = ["cambridgeServiceID": serviceID]
            configuration.disconnectOnSleep = false
            manager.protocolConfiguration = configuration
            manager.localizedDescription = ClaudeGuardPolicy.profileName
            manager.appRules = ClaudeGuardPolicy.signingIdentifiers.map {
                NEAppRule(signingIdentifier: $0,
                          designatedRequirement: ClaudeGuardPolicy.designatedRequirement(for: $0))
            }
            manager.excludedDomains = []
            manager.onDemandRules = [NEOnDemandRuleConnect()]
            manager.isOnDemandEnabled = true
            manager.isEnabled = true
            self.manager = manager
            manager.saveToPreferences { error in
                if let error { DispatchQueue.main.async { self.report(error) }; return }
                manager.loadFromPreferences { error in
                    DispatchQueue.main.async {
                        if let error { self.report(error); return }
                        do { try manager.connection.startVPNTunnel(); self.renderStatus() }
                        catch { self.report(error) }
                    }
                }
            }
        }
    }

    private func cambridgeServiceID() -> String? {
        VPNService.serviceID()
    }

    private func confirmDisable() {
        let alert = NSAlert()
        alert.messageText = "Remove Claude's VPN-only restriction?"
        alert.informativeText = "Disabling the guard permits Claude to use the normal internet connection, including when the VPN is off."
        alert.addButton(withTitle: "Keep Guard")
        alert.addButton(withTitle: "Disable Guard")
        guard alert.runModal() == .alertSecondButtonReturn, let manager else { return }
        manager.isOnDemandEnabled = false
        manager.isEnabled = false
        manager.saveToPreferences { error in
            DispatchQueue.main.async {
                if let error { self.report(error) }
                else { manager.connection.stopVPNTunnel(); self.renderStatus() }
            }
        }
    }

    private func renderStatus() {
        guard let manager, manager.isEnabled else {
            setStatus("Claude protection: Not active"); return
        }
        switch manager.connection.status {
        case .connected: setStatus("Claude guard: Running — live validation required")
        case .connecting, .reasserting: setStatus("Claude guard: Starting")
        case .disconnected, .disconnecting: setStatus("Claude guard: Disconnected — check setup")
        default: setStatus("Claude protection: Unavailable")
        }
    }

    private func setStatus(_ value: String) {
        status = value
        onChange?(value)
    }

    private func report(_ error: Error) {
        setStatus("Claude protection: Setup failed")
        AgentLog.write("Claude guard setup failed: \(error.localizedDescription)")
        let alert = NSAlert(error: error)
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        setStatus("Claude protection: Waiting for macOS approval")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        pendingRequest = nil
        if result == .completed { configure() }
        else { setStatus("Claude protection: Restart required; not verified") }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        pendingRequest = nil
        report(error)
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }
}
