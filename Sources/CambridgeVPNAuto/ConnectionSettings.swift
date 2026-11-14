import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CambridgeVPNAutoCore

@MainActor
final class ConnectionSettingsModel: ObservableObject {
    @Published private(set) var policy = AppRoutingPolicy()
    @Published var message: String?
    @Published var importing = false
    @Published var snapshot: ControllerSnapshot?
    let routing = RoutingController()
    let preview: Bool
    let safariTestMode: Bool
    private let store: AppRoutingStore
    @Published private(set) var readable = true
    var controller: Controller?

    init(preview: Bool = false, safariTestMode: Bool = false, store: AppRoutingStore = AppRoutingStore()) {
        self.preview = preview; self.safariTestMode = safariTestMode; self.store = store
        guard !safariTestMode else { return }
        do { policy = try store.load() }
        catch { readable = false; message = "Saved rules could not be read. They have been preserved. \(error.localizedDescription)" }
    }
    func start() {
        routing.start()
        if safariTestMode {
            prepareSafariOnlyTest(route: .direct)
            return
        }

    }
    var hasUnappliedChanges: Bool {
        policy.revision != routing.runningRevision || policy.revision != routing.filterRevision
    }
    var safariTestReady: Bool {
        safariTestMode && policy.scope == .safariOnlyTest && policy.rules.count == 1
    }
    func prepareSafariOnlyTest(route: AppRoute) {
        guard safariTestMode, !importing else { return }
        importing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try AppCatalog.inspect(URL(fileURLWithPath: "/Applications/Safari.app"), route: route) }
            DispatchQueue.main.async {
                self.importing = false
                switch result {
                case .success(let rule):
                    guard rule.name == "Safari", rule.identities.contains(where: { $0.signingIdentifier == "com.apple.Safari" }) else {
                        self.message = "The selected Safari bundle did not provide the expected signed identity. No test policy was created."
                        return
                    }
                    self.policy = AppRoutingPolicy(rules: [rule], scope: .safariOnlyTest)
                    self.message = nil
                case .failure(let error): self.message = error.localizedDescription
                }
            }
        }
    }
    func setSafariTestRoute(_ route: AppRoute) {
        guard safariTestReady, var safari = policy.rules.first else { return }
        safari.route = route
        policy = AppRoutingPolicy(rules: [safari], scope: .safariOnlyTest)
    }
    func chooseApp() {
        guard !safariTestMode else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle, .executable]
        panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Add application"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        add(url, route: .direct)
    }
    func add(_ url: URL, route: AppRoute) {
        guard readable, !safariTestMode, !importing else { return }
        importing = true
        #if APP_STORE
        let rememberSelection = !preview
        #endif
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                #if APP_STORE
                return try StoreAppAccess.inspect(url, route: route, remember: rememberSelection)
                #else
                return try AppCatalog.inspect(url, route: route)
                #endif
            }
            DispatchQueue.main.async {
                self.importing = false
                switch result {
                case .success(let rule):
                    var next = self.policy
                    if let index = next.rules.firstIndex(where: { $0.bundlePath == rule.bundlePath }) {
                        var updated = rule
                        updated.id = next.rules[index].id
                        updated.route = next.rules[index].route
                        next.rules[index] = updated
                    } else { next.rules.append(rule) }
                    self.save(next)
                case .failure(let error): self.message = error.localizedDescription
                }
            }
        }
    }
    func setRoute(_ route: AppRoute, for id: UUID) {
        guard !safariTestMode else { return }
        var next = policy
        guard let index = next.rules.firstIndex(where: { $0.id == id }) else { return }
        next.rules[index].route = route
        save(next)
    }
    func remove(_ id: UUID) {
        guard !safariTestMode else { return }
        var next = policy
        next.rules.removeAll { $0.id == id }
        save(next)
    }
    private func save(_ nextPolicy: AppRoutingPolicy) {
        guard readable else { return }
        var next = nextPolicy
        next.revision = UUID()
        do {
            _ = try next.validated()
            if !preview { try store.save(next) }
            policy = next
            message = nil
        } catch { message = error.localizedDescription }
    }
}

private enum SettingsTypography {
    static let body = Font.system(size: 17)
    static let secondary = Font.system(size: 14)
    static let heading = Font.system(size: 18, weight: .semibold)
}

struct ConnectionSettingsView: View {
    @ObservedObject var model: ConnectionSettingsModel
    @ObservedObject var routing: RoutingController
    @State private var search = ""
    private let teal = Color(red: 0.04, green: 0.45, blue: 0.45)
    private var visibleRules: [AppConnectionRule] {
        model.policy.rules.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                Image(systemName: "network.badge.shield.half.filled").font(.system(size: 40)).foregroundStyle(teal)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your apps. Your connections.").font(.system(size: 30, weight: .semibold))
                    Text("\(connectionAppName)").font(SettingsTypography.body).foregroundStyle(.secondary)
                }
                Spacer()
                if model.preview { Text("UI PREVIEW").font(SettingsTypography.secondary.bold()).padding(8).background(.quaternary, in: Capsule()) }
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("VPN", systemImage: "shield.lefthalf.filled").font(SettingsTypography.heading)
                    Text(model.snapshot?.vpnState.rawValue.capitalized ?? (model.preview ? "Read-only preview" : "Checking…"))
                        .font(.system(size: 22, weight: .semibold)).foregroundStyle(teal)
                    Text(model.snapshot?.controlState.mode == .paused ? "Auto-reconnect is manually paused" : "Auto-reconnect keeps this connection available")
                        .font(SettingsTypography.secondary).foregroundStyle(.secondary)
                    HStack {
                        Button(model.snapshot?.controlState.mode == .armed ? "Turn off & pause" : "Turn on & reconnect") {
                            if model.snapshot?.controlState.mode == .armed { model.controller?.pause() }
                            else { model.controller?.arm() }
                        }.disabled(model.preview || model.snapshot == nil)
                        Button("Retry now") { model.controller?.retryNow() }
                            .disabled(model.preview || model.snapshot?.controlState.mode != .armed || model.snapshot?.vpnState == .connected)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Label(model.safariTestMode ? "Safari-only test" : "App rules", systemImage: "slider.horizontal.3").font(SettingsTypography.heading)
                    Text(routing.status).font(SettingsTypography.heading).foregroundStyle(.orange)
                    Text(routing.detail).font(SettingsTypography.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(18).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(model.safariTestMode ? "Safari-only live test" : "Application connections").font(SettingsTypography.heading)
                    Spacer()
                    if !model.safariTestMode {
                        TextField("Find an app", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
                        Button { model.chooseApp() } label: { Label("Add application", systemImage: "plus") }
                            .disabled(model.importing)
                    }
                }
                HStack {
                    Image(systemName: "globe").foregroundStyle(teal)
                    Text(model.safariTestMode ? "Every app except Safari" : "All other apps").fontWeight(.medium)
                    Spacer()
                    Text("Existing macOS / VPN routing").foregroundStyle(.secondary)
                }.padding(12).background(teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(visibleRules) { rule in
                            HStack(spacing: 12) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: rule.bundlePath)).resizable().frame(width: 42, height: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(rule.name).fontWeight(.medium)
                                    Text("\(rule.identities.count) signed identities · embedded helpers included")
                                        .font(SettingsTypography.secondary).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 12)
                                Picker("Connection for \(rule.name)", selection: Binding(get: { rule.route }, set: {
                                    if model.safariTestMode { model.setSafariTestRoute($0) }
                                    else { model.setRoute($0, for: rule.id) }
                                })) {
                                    ForEach(AppRoute.allCases) { route in Text(route.title).font(SettingsTypography.body).tag(route) }
                                }.font(SettingsTypography.body).labelsHidden().frame(width: 240).accessibilityLabel("Connection for \(rule.name)")
                                if !model.safariTestMode {
                                    Menu {
                                        Button("Refresh signed identities") { model.add(URL(fileURLWithPath: rule.bundlePath), route: rule.route) }
                                        Button("Remove rule (use macOS routing)") { model.remove(rule.id) }
                                    } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 30)
                                }
                            }.padding(.vertical, 14).padding(.horizontal, 10)
                            Divider()
                        }
                        if visibleRules.isEmpty {
                            Text(model.safariTestMode ? "Reading Safari’s signed identities…" : (search.isEmpty ? "Add an application to choose its connection." : "No matching applications"))
                                .foregroundStyle(.secondary).padding(25)
                        }
                    }
                }.frame(minHeight: 130)
                if model.importing { ProgressView("Reading application signatures…").controlSize(.small) }
            }
            VStack(alignment: .leading, spacing: 5) {
                if model.safariTestMode {
                    Text("This signed test applies only to a newly verified Safari identity set. The saved app policy is not read or changed.")
                    Text("Safari web connections and their destination lookups use the selected interface. DNS to configured system resolvers stays on macOS routing, including while Safari is blocked. Other apps keep their macOS route; starting the router may reset existing connections.")
                } else {
                    Text("Direct uses Wi-Fi or Ethernet. VPN only waits for the system VPN and never falls back. Block denies the app’s internet sockets. Unlisted apps keep their macOS / VPN connection.")
                    Text("Rules need a signed, approved extension. DNS to configured system resolvers follows macOS routing, even for blocked apps. Localhost forwarding and independently launched tools may need separate rules.")
                }
            }.font(SettingsTypography.secondary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = model.message { Text(message).font(SettingsTypography.secondary).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Text(model.preview ? "Preview changes are not saved" : (model.safariTestMode ? "Safari-only test policy · not saved" : (model.hasUnappliedChanges ? "Choices saved · not applied" : "Saved configuration is running")))
                    .font(SettingsTypography.secondary).foregroundStyle(.secondary)
                Spacer()
                if routing.hasConfiguration && !model.safariTestMode { Button("Disable rules…") { routing.disable() }.disabled(routing.busy) }
                if model.safariTestMode && routing.activeScope == .safariOnlyTest {
                    Button("End Safari-only test") { routing.endSafariOnlyTest() }.disabled(routing.busy)
                }
                Button(model.safariTestMode ? "Apply Safari-only test" : "Apply app rules") {
                    if model.safariTestMode { routing.applySafariOnlyTest(model.policy) }
                    else { routing.apply(model.policy) }
                }
                    .buttonStyle(.borderedProminent).tint(teal)
                    .disabled(model.preview || !model.readable || routing.busy || RoutingController.signingProblem != nil || model.importing || (model.safariTestMode && !model.safariTestReady))
            }
        }.font(SettingsTypography.body)
        .controlSize(.large)
        .padding(26).frame(minWidth: 980, minHeight: 740)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
final class ConnectionSettingsWindow: NSWindowController {
    init(model: ConnectionSettingsModel) {
        let view = ConnectionSettingsView(model: model, routing: model.routing)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(connectionAppName)"
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func present() { showWindow(nil); NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil) }
}
