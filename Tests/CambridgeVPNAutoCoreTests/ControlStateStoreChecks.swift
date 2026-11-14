import Foundation
import CambridgeVPNAutoCore

func runControlStateStoreChecks(_ runner: inout CheckRunner) {
    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ControlStateStore(fileURL: directory.appendingPathComponent("state.json"))
        let expected = PersistentControlState(
            mode: .paused,
            manualStopPending: false,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try store.save(expected)
        let loaded = try store.load()
        runner.expect(loaded == expected, "state store preserves a manual pause")
    } catch {
        runner.expect(false, "state store preserves a manual pause: \(error)")
    }

    do {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("state.json")
        let state = try ControlStateStore(fileURL: fileURL).load()
        runner.expect(state.mode == .armed, "missing state defaults to armed")
        runner.expect(state.manualStopPending == false, "default armed state has no stop pending")
    } catch {
        runner.expect(false, "missing state defaults to armed: \(error)")
    }
}
