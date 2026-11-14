import Foundation
import Network
import NetworkExtension

final class UDPRelay: FlowRelay {
    private let flow: NEAppProxyUDPFlow
    private let interface: NWInterface
    private let queue: DispatchQueue
    private let isCurrent: () -> Bool
    private let finished: () -> Void
    private var connections: [Network.NWEndpoint: NWConnection] = [:]
    private var stopped = false

    init(flow: NEAppProxyUDPFlow, interface: NWInterface, queue: DispatchQueue,
         isCurrent: @escaping () -> Bool, finished: @escaping () -> Void) {
        self.flow = flow
        self.interface = interface
        self.queue = queue
        self.isCurrent = isCurrent
        self.finished = finished
    }

    func start() {
        guard isCurrent() else { stop(guardError("VPN unavailable")); return }
        flow.open(withLocalEndpoint: nil) { [weak self] error in
            guard let self else { return }
            self.queue.async { [self] in
                guard !self.stopped else { return }
                if let error { self.stop(error) } else { self.readApp() }
            }
        }
    }

    private func readApp() {
        guard !stopped, isCurrent() else { stop(guardError("VPN unavailable")); return }
        flow.readDatagrams { [weak self] datagrams, endpoints, error in
            guard let self else { return }
            self.queue.async { [self] in
                guard !self.stopped else { return }
                if let error { self.stop(error); return }
                guard let datagrams, let endpoints = endpoints as? [NWHostEndpoint], datagrams.count == endpoints.count else {
                    self.stop(guardError("Missing UDP endpoints")); return
                }
                if datagrams.isEmpty { self.stop(nil); return }
                self.sendBatch(Array(zip(datagrams, endpoints)), at: 0)
            }
        }
    }

    private func sendBatch(_ batch: [(Data, NWHostEndpoint)], at index: Int) {
        guard !stopped, isCurrent() else { stop(guardError("VPN unavailable")); return }
        guard index < batch.count else { readApp(); return }
        let (data, originalEndpoint) = batch[index]
        guard let target = endpoint(originalEndpoint) else {
            stop(guardError("Unsupported UDP endpoint")); return
        }
        let connection: NWConnection
        if let existing = connections[target] { connection = existing }
        else {
            connection = NWConnection(to: target, using: parameters(tcp: false, interface: interface))
            connections[target] = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready: self.receive(connection, from: originalEndpoint)
                case .failed(let error), .waiting(let error): self.stop(error)
                default: break
                }
            }
            connection.start(queue: queue)
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.stopped else { return }
            if let error { self.stop(error); return }
            self.sendBatch(batch, at: index + 1)
        })
    }

    private func receive(_ connection: NWConnection, from source: NWHostEndpoint) {
        guard !stopped, isCurrent() else { stop(guardError("VPN unavailable")); return }
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.stopped else { return }
            if let error { self.stop(error); return }
            guard self.isCurrent() else { self.stop(guardError("VPN changed")); return }
            guard let data else { self.receive(connection, from: source); return }
            self.flow.writeDatagrams([data], sentBy: [source]) { [weak self] error in
                guard let self else { return }
                self.queue.async { [self] in
                    guard !self.stopped else { return }
                    if let error { self.stop(error) } else { self.receive(connection, from: source) }
                }
            }
        }
    }

    func stop(_ error: Error?) {
        guard !stopped else { return }
        stopped = true
        for connection in connections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        connections.removeAll()
        closeFlow(flow, error: error)
        finished()
    }
}
