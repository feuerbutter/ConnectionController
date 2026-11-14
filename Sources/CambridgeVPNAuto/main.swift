import AppKit
import Foundation

MainActor.assumeIsolated {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let previewMode = Bundle.main.object(forInfoDictionaryKey: "CambridgeUIPreview") as? Bool == true || arguments == ["--preview-ui"]
    let showSettings = arguments == ["--settings"]
    let safariTestMode = arguments == ["--safari-test-mode"]
    let interactiveLaunch = arguments.isEmpty || showSettings
    if interactiveLaunch && !previewMode && NSRunningApplication.runningApplications(withBundleIdentifier: "com.wjli.cambridge-vpn-auto")
        .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
        DistributedNotificationCenter.default().postNotificationName(.init("com.wjli.cambridge-vpn-auto.show-settings"), object: nil, deliverImmediately: true)
        exit(0)
    }
    if arguments.isEmpty || arguments == ["--agent"] || arguments == ["--preview-ui"] || showSettings || safariTestMode {
        let application = NSApplication.shared
        let delegate = AppDelegate(preview: previewMode, safariTestMode: safariTestMode,
                                   openSettings: showSettings || arguments.isEmpty || safariTestMode)
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    } else {
        exit(CLI.run(arguments: arguments))
    }
}
