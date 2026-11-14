import Foundation
import Network
import NetworkExtension

final class TCPRelay: FlowRelay {
    private let flow: NEAppProxyTCPFlow
    private let interface: NWInterface
    private let queue: DispatchQueue
    private let isCurrent: () -> Bool
    private let finished: () -> Void
    private var connection: NWConnection?
    private var stopped = false
    private var opened = false
    private var inputEnded = false
    private var outputEnded = false

    init(flow: NEAppProxyTCPFlow, interface: NWInterface, queue: DispatchQueue,
         isCurrent: @escaping () -> Bool, finished: @escaping () -> Void) {
        self.flow = flow
        self.interface = interface
        self.queue = queue
        self.isCurrent = isCurrent
        self.finished = finished
    }

    func start() {
        guard isCurrent(), let target = endpoint(flow.remoteEndpoint) else {
            stop(guardError("No VPN route for this TCP endpoint")); return
        }
        let connection = NWConnection(to: target, using: parameters(tcp: true, interface: interface))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                guard self.isCurrent() else { self.stop(guardError("VPN changed")); return }
                guard !self.opened else { return }
                self.opened = true
                self.flow.open(withLocalEndpoint: nil) { [weak self] error in
                    guard let self else { return }
                    self.queue.async { [self] in
                        guard !self.stopped else { return }
                        if let error { self.stop(error); return }
                        self.readApp()
                        self.readRemote()
                    }
                }
            case .failed(let error), .waiting(let error): self.stop(error)
            case .cancelled: self.stop(nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func readApp() {
        guard !stopped, isCurrent() else { stop(guardError("VPN unavailable")); return }
        flow.readData { [weak self] data, error in
            guard let self else { return }
            self.queue.async { [self] in
                guard !self.stopped else { return }
                guard self.isCurrent() else { self.stop(guardError("VPN changed")); return }
                if let error { self.stop(error); return }
                let eof = data?.isEmpty != false
                self.connection?.send(content: eof ? nil : data,
                                      contentContext: eof ? .finalMessage : .defaultMessage, isComplete: eof,
                                      completion: .contentProcessed { [weak self] error in
                    guard let self, !self.stopped else { return }
                    if let error { self.stop(error); return }
                    if eof {
                        self.inputEnded = true
                        self.flow.closeReadWithError(nil)
                        self.finishIfEnded()
                    } else { self.readApp() }
                })
            }
        }
    }

    private func readRemote() {
        guard !stopped, isCurrent() else { stop(guardError("VPN unavailable")); return }
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, eof, error in
            guard let self, !self.stopped else { return }
            if let error { self.stop(error); return }
            guard self.isCurrent() else { self.stop(guardError("VPN changed")); return }
            let next = {
                if eof {
                    self.outputEnded = true
                    self.flow.closeWriteWithError(nil)
                    self.finishIfEnded()
                } else { self.readRemote() }
            }
            if let data, !data.isEmpty {
                self.flow.write(data) { [weak self] error in
                    guard let self else { return }
                    self.queue.async { [self] in
                        guard !self.stopped else { return }
                        if let error { self.stop(error) } else { next() }
                    }
                }
            } else { next() }
        }
    }

    private func finishIfEnded() {
        if inputEnded && outputEnded { stop(nil) }
    }

    func stop(_ error: Error?) {
        guard !stopped else { return }
        stopped = true
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        closeFlow(flow, error: error)
        finished()
    }
}
