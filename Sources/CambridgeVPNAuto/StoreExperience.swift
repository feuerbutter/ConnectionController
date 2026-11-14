#if APP_STORE
import AppKit
import Foundation
import ServiceManagement
import CambridgeVPNAutoCore

@MainActor
enum StoreExperience {
    static var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func confirmFirstUse() -> Bool {
        guard !UserDefaults.standard.bool(forKey: "storePrivacyAcceptedV1") else { return true }
        let alert = NSAlert()
        alert.messageText = "Your connections stay on your Mac"
        alert.informativeText = "\(connectionAppName) uses local network extensions to apply your app rules and can reconnect one existing native IPSec VPN. It processes app identities, connection destinations and traffic locally to route or block connections. It does not send browsing history, traffic, credentials or analytics to the developer. No VPN service is included.\n\nStarting enables the reconnect controller. App routing requires a separate Apply action and macOS approval. Launch at Login is off until you enable it."
        alert.addButton(withTitle: "Start \(connectionAppName)")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        UserDefaults.standard.set(true, forKey: "storePrivacyAcceptedV1")
        return true
    }

    static func toggleLaunchAtLogin() {
        do {
            if launchesAtLogin || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch { NSAlert(error: error).runModal() }
    }

    static func showPrivacy() {
        guard let url = Bundle.main.url(forResource: "Privacy", withExtension: "html") else { return }
        NSWorkspace.shared.open(url)
    }
}

enum StoreAppAccess {
    static func inspect(_ selected: URL, route: AppRoute, remember: Bool) throws -> AppConnectionRule {
        let key = "applicationBookmark:" + selected.path
        var url = selected
        if let data = UserDefaults.standard.data(forKey: key) {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], bookmarkDataIsStale: &stale) {
                url = resolved
            }
        }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let rule = try AppCatalog.inspect(url, route: route)
        if remember {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: key)
        }
        return rule
    }
}
#endif
