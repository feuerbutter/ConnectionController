import AppKit
import Foundation
import CambridgeVPNAutoCore

#if APP_STORE
let connectionAppName = "ConnectionController"
#else
let connectionAppName = "ConnectionManager"
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let connectionItem = NSMenuItem(title: "VPN: Checking…", action: nil, keyEquivalent: "")
    private let modeItem = NSMenuItem(title: "Automatic reconnect: Checking…", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggleMode), keyEquivalent: "")
    private let retryItem = NSMenuItem(title: "Reconnect Now", action: #selector(retryNow), keyEquivalent: "r")
    private let settingsItem = NSMenuItem(title: "Application Connections…", action: #selector(showConnections), keyEquivalent: ",")
    private var settingsModel: ConnectionSettingsModel!
    private var settingsWindow: ConnectionSettingsWindow?
    private let preview: Bool
    private let safariTestMode: Bool
    private let openSettings: Bool

    init(preview: Bool = false, safariTestMode: Bool = false, openSettings: Bool = false) {
        self.preview = preview
        self.safariTestMode = safariTestMode
        self.openSettings = openSettings
        super.init()
    }
    private var controller: Controller!
    private var snapshot: ControllerSnapshot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if APP_STORE
        if !preview && !StoreExperience.confirmFirstUse() { NSApp.terminate(nil); return }
        #endif
        NSApplication.shared.setActivationPolicy(preview ? .regular : .accessory)
        configureMenu()
        configureApplicationMenu()
        settingsModel = ConnectionSettingsModel(preview: preview, safariTestMode: safariTestMode)
        settingsModel.start()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showConnections), name: .init("com.wjli.cambridge-vpn-auto.show-settings"), object: nil)
        if preview {
            showConnections()
            return
        }
        controller = Controller()
        settingsModel.controller = controller
        controller.onSnapshot = { [weak self] snapshot in
            self?.settingsModel.snapshot = snapshot
            self?.render(snapshot)
        }
        controller.start()
        if openSettings { showConnections() }
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "\(connectionAppName)")
        applicationMenu.addItem(withTitle: "About \(connectionAppName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        let settings = applicationMenu.addItem(withTitle: "Application Connections…", action: #selector(showConnections), keyEquivalent: ",")
        settings.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Hide \(connectionAppName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = applicationMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        #if APP_STORE
        let close = applicationMenu.addItem(withTitle: preview ? "Quit Preview" : "Quit \(connectionAppName)…", action: #selector(quitStoreApp), keyEquivalent: "q")
        #else
        // Direct distribution retains its launch-agent-owned controller.
        let close = applicationMenu.addItem(withTitle: preview ? "Quit Preview" : "Keep Running in Menu Bar", action: #selector(closeInterface), keyEquivalent: "q")
        #endif
        close.target = self
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    #if APP_STORE
    @objc private func toggleLogin(_ sender: NSMenuItem) {
        guard !preview else { return }
        StoreExperience.toggleLaunchAtLogin()
        sender.state = StoreExperience.launchesAtLogin ? .on : .off
    }
    @objc private func showPrivacy() { StoreExperience.showPrivacy() }
    @objc private func quitStoreApp() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !preview, controller != nil else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit \(connectionAppName)?"
        alert.informativeText = "Automatic reconnect will stop. Your system VPN stays connected. Applied app rules can keep running in the network extension after you quit. To stop those rules, cancel and choose Disable rules in the application window."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Keep App Rules and Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    #endif

    @objc private func closeInterface() {
        if preview { NSApp.terminate(nil) }
        else { settingsWindow?.close() }
    }

    func windowWillClose(_ notification: Notification) {
        guard !preview else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.font = NSFont.systemFont(ofSize: 16)
        connectionItem.isEnabled = false
        modeItem.isEnabled = false
        toggleItem.target = self
        retryItem.target = self

        let vpnSettingsItem = NSMenuItem(
            title: "Open VPN Settings…",
            action: #selector(openVPNSettings),
            keyEquivalent: ""
        )
        vpnSettingsItem.target = self

        #if !APP_STORE
        let logItem = NSMenuItem(
            title: "Show Controller Log…",
            action: #selector(showControllerLog),
            keyEquivalent: "l"
        )
        logItem.target = self
        #endif

        menu.addItem(connectionItem)
        menu.addItem(modeItem)
        menu.addItem(.separator())
        menu.addItem(toggleItem)
        menu.addItem(retryItem)
        menu.addItem(.separator())
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(vpnSettingsItem)
        #if !APP_STORE
        menu.addItem(logItem)
        #endif
        #if APP_STORE
        menu.addItem(.separator())
        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = StoreExperience.launchesAtLogin ? .on : .off
        login.isEnabled = !preview
        let privacy = menu.addItem(withTitle: "Privacy & Support…", action: #selector(showPrivacy), keyEquivalent: "")
        privacy.target = self
        let quit = menu.addItem(withTitle: "Quit \(connectionAppName)…", action: #selector(quitStoreApp), keyEquivalent: "q")
        quit.target = self
        #endif
        statusItem.menu = menu
        setStatusImage(symbolName: "shield", toolTip: "\(connectionAppName): checking")
    }

    private func render(_ snapshot: ControllerSnapshot) {
        self.snapshot = snapshot
        let vpnText = snapshot.vpnState.rawValue.capitalized
        connectionItem.title = "VPN: \(vpnText)"
        modeItem.title = snapshot.controlState.mode == .armed
            ? "Automatic reconnect: Armed"
            : "Automatic reconnect: Manually paused"

        if snapshot.controlState.mode == .armed {
            toggleItem.title = "Turn VPN Off Until I Turn It On"
            retryItem.isEnabled = snapshot.vpnState != .connected
        } else {
            toggleItem.title = "Turn VPN On and Keep It Connected"
            retryItem.isEnabled = false
        }

        if snapshot.controlState.mode == .paused {
            setStatusImage(
                symbolName: "shield.slash",
                toolTip: "\(connectionAppName): manually paused"
            )
        } else if snapshot.vpnState == .connected {
            setStatusImage(
                symbolName: "checkmark.shield.fill",
                toolTip: "\(connectionAppName): VPN connected; automatic recovery armed"
            )
        } else {
            setStatusImage(
                symbolName: "arrow.triangle.2.circlepath.circle",
                toolTip: "\(connectionAppName): VPN reconnecting automatically"
            )
        }
    }

    private func setStatusImage(symbolName: String, toolTip: String) {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = toolTip
    }

    @objc private func toggleMode() {
        guard let snapshot else {
            return
        }
        if snapshot.controlState.mode == .armed {
            controller.pause()
        } else {
            controller.arm()
        }
    }

    @objc private func retryNow() {
        controller?.retryNow()
    }

    @objc private func showConnections() {
        guard settingsModel != nil else { return }
        if settingsWindow == nil {
            settingsWindow = ConnectionSettingsWindow(model: settingsModel)
            settingsWindow?.window?.delegate = self
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.present()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showConnections()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { preview }

    @objc private func openVPNSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Network-Settings.extension?VPN",
            "x-apple.systempreferences:com.apple.preference.network"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    @objc private func showControllerLog() {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CambridgeVPNAuto/agent.log")
        if FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.open(logURL)
        } else {
            NSWorkspace.shared.open(logURL.deletingLastPathComponent())
        }
    }
}
