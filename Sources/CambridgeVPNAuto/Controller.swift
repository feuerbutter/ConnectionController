import AppKit
import Foundation
import CambridgeVPNAutoCore

struct ControllerSnapshot {
    let controlState: PersistentControlState
    let vpnState: VPNConnectionState
    let internetAvailable: Bool
    let reconnectAttempt: Int
}

final class Controller: NSObject {
    var onSnapshot: ((ControllerSnapshot) -> Void)?

    private let store: ControlStateStore
    private let worker = DispatchQueue(label: "com.wjli.cambridge-vpn-auto.worker")
    private var timer: Timer?
    private var pollInFlight = false
    private var startInFlight = false
    private var stopInFlight = false
    private var reconnectAttempt = 0
    private var nextConnectAttempt = Date.distantPast
    private var nextStopAttempt = Date.distantPast
    private var controlState: PersistentControlState
    private var vpnState: VPNConnectionState = .unknown
    private var internetAvailable = false

    init(store: ControlStateStore = ControlStateStore()) {
        self.store = store
        do {
            self.controlState = try store.load()
        } catch {
            self.controlState = .armed()
            AgentLog.write("state load failed at startup; defaulting to armed: \(error.localizedDescription)")
        }
        super.init()
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.pollNow()
        }
        AgentLog.write("controller started mode=\(controlState.mode.rawValue)")
        pollNow()
    }

    func arm() {
        controlState.mode = .armed
        controlState.manualStopPending = false
        persistControlState(reason: "manual turn-on")
        reconnectAttempt = 0
        nextConnectAttempt = .distantPast
        publishSnapshot()
        pollNow()
    }

    func pause() {
        controlState.mode = .paused
        controlState.manualStopPending = true
        persistControlState(reason: "manual turn-off")
        publishSnapshot()
        attemptDisconnection(force: true)
    }

    func retryNow() {
        guard controlState.mode == .armed else {
            return
        }
        nextConnectAttempt = .distantPast
        pollNow()
    }

    func pollNow() {
        guard !pollInFlight else {
            return
        }
        reloadExternalControlState()
        pollInFlight = true
        worker.async { [weak self] in
            let observedVPNState = VPNService.connectionState()
            let observedInternet = VPNService.internetAvailable()
            DispatchQueue.main.async {
                guard let self else { return }
                self.pollInFlight = false
                self.processObservation(
                    vpnState: observedVPNState,
                    internetAvailable: observedInternet
                )
            }
        }
    }

    @objc private func systemDidWake() {
        AgentLog.write("system wake observed; checking VPN")
        nextConnectAttempt = .distantPast
        pollNow()
    }

    private func processObservation(
        vpnState observedVPNState: VPNConnectionState,
        internetAvailable observedInternet: Bool
    ) {
        reloadExternalControlState()
        if vpnState != observedVPNState {
            AgentLog.write("VPN observation changed \(vpnState.rawValue) -> \(observedVPNState.rawValue)")
        }
        vpnState = observedVPNState
        internetAvailable = observedInternet

        if controlState.mode == .armed && vpnState == .connected {
            reconnectAttempt = 0
            nextConnectAttempt = .distantPast
        }

        let action = DecisionEngine.action(
            controlState: controlState,
            vpnState: vpnState,
            internetAvailable: internetAvailable,
            retryReady: Date() >= nextConnectAttempt
        )

        switch action {
        case .none:
            break
        case .connect:
            attemptConnection()
        case .disconnect:
            attemptDisconnection(force: false)
        case .completePause:
            controlState.manualStopPending = false
            persistControlState(reason: "manual turn-off completed")
        case .rearm:
            controlState.mode = .armed
            controlState.manualStopPending = false
            reconnectAttempt = 0
            nextConnectAttempt = .distantPast
            persistControlState(reason: "external manual turn-on observed")
        }

        publishSnapshot()
    }

    private func attemptConnection() {
        guard !startInFlight else {
            return
        }
        startInFlight = true
        let attemptNumber = reconnectAttempt + 1
        let delay = RetryPolicy.delay(afterAttempt: reconnectAttempt)
        reconnectAttempt += 1
        nextConnectAttempt = Date().addingTimeInterval(delay)
        AgentLog.write("requesting VPN start attempt=\(attemptNumber) next_retry_seconds=\(Int(delay))")

        worker.async { [weak self] in
            let result = VPNService.start()
            DispatchQueue.main.async {
                guard let self else { return }
                self.startInFlight = false
                if result.exitCode == 0 {
                    AgentLog.write("VPN start request accepted attempt=\(attemptNumber)")
                } else {
                    AgentLog.write(
                        "VPN start request failed attempt=\(attemptNumber) exit=\(result.exitCode) error=\(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))"
                    )
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.pollNow()
                }
            }
        }
    }

    private func attemptDisconnection(force: Bool) {
        guard !stopInFlight else {
            return
        }
        if !force && Date() < nextStopAttempt {
            return
        }
        stopInFlight = true
        nextStopAttempt = Date().addingTimeInterval(5)
        AgentLog.write("requesting VPN stop for persistent manual pause")

        worker.async { [weak self] in
            let result = VPNService.stop()
            DispatchQueue.main.async {
                guard let self else { return }
                self.stopInFlight = false
                if result.exitCode == 0 {
                    AgentLog.write("VPN stop request accepted")
                } else {
                    AgentLog.write(
                        "VPN stop request failed exit=\(result.exitCode) error=\(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines))"
                    )
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    self.pollNow()
                }
            }
        }
    }

    private func reloadExternalControlState() {
        do {
            let loaded = try store.load()
            guard loaded != controlState else {
                return
            }
            controlState = loaded
            if controlState.mode == .armed {
                nextConnectAttempt = .distantPast
            }
            AgentLog.write(
                "external control-state update mode=\(controlState.mode.rawValue) stop_pending=\(controlState.manualStopPending)"
            )
        } catch {
            AgentLog.write("state reload failed; retaining last valid state: \(error.localizedDescription)")
        }
    }

    private func persistControlState(reason: String) {
        controlState.updatedAt = Date()
        do {
            try store.save(controlState)
            AgentLog.write(
                "control state saved mode=\(controlState.mode.rawValue) stop_pending=\(controlState.manualStopPending) reason=\(reason)"
            )
        } catch {
            AgentLog.write("control-state save failed: \(error.localizedDescription)")
        }
    }

    private func publishSnapshot() {
        onSnapshot?(
            ControllerSnapshot(
                controlState: controlState,
                vpnState: vpnState,
                internetAvailable: internetAvailable,
                reconnectAttempt: reconnectAttempt
            )
        )
    }
}
