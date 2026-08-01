//
//  LockdownReachabilityProbe.swift
//  StikDebug
//
//  Read-only TCP reachability check for Apple device-service ports.
//

import Combine
import Foundation
import Network

enum LockdownReachabilityStatus: Equatable {
    case idle
    case running(host: String)
    case reachable(host: String)
    case refused(host: String)
    case timedOut(host: String)
    case invalidAddress
    case failed(host: String, reason: String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

@MainActor
final class LockdownReachabilityProbe: ObservableObject {
    @Published private(set) var status: LockdownReachabilityStatus = .idle
    @Published private(set) var testedPort: UInt16 = 62078

    private let connectionQueue = DispatchQueue(label: "com.stik.stikdebug.lockdown-reachability")
    private var connection: NWConnection?
    private var timeoutTask: Task<Void, Never>?

    func start(host rawHost: String, port rawPort: UInt16 = 62078, timeout: TimeInterval = 5) {
        cancelCurrentConnection()

        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IPv4Address(host) != nil || IPv6Address(host) != nil else {
            status = .invalidAddress
            return
        }

        guard let port = NWEndpoint.Port(rawValue: rawPort) else {
            status = .failed(host: host, reason: "Invalid TCP port")
            return
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: port,
            using: .tcp
        )

        testedPort = rawPort
        self.connection = connection
        status = .running(host: host)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }

                switch state {
                case .ready:
                    self.finish(with: .reachable(host: host), connection: connection)
                case .failed(let error):
                    self.finish(with: self.status(for: error, host: host), connection: connection)
                case .waiting(let error):
                    if let terminalStatus = self.terminalWaitingStatus(for: error, host: host) {
                        self.finish(with: terminalStatus, connection: connection)
                    }
                default:
                    break
                }
            }
        }

        timeoutTask = Task { @MainActor [weak self, weak connection] in
            let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self, let connection,
                  self.connection === connection else { return }
            self.finish(with: .timedOut(host: host), connection: connection)
        }

        connection.start(queue: connectionQueue)
    }

    private func terminalWaitingStatus(
        for error: NWError,
        host: String
    ) -> LockdownReachabilityStatus? {
        guard case .posix(let code) = error else { return nil }

        switch code {
        case .ECONNREFUSED:
            return .refused(host: host)
        case .ETIMEDOUT:
            return .timedOut(host: host)
        default:
            return nil
        }
    }

    private func status(for error: NWError, host: String) -> LockdownReachabilityStatus {
        if case .posix(let code) = error {
            switch code {
            case .ECONNREFUSED:
                return .refused(host: host)
            case .ETIMEDOUT:
                return .timedOut(host: host)
            default:
                break
            }
        }

        return .failed(host: host, reason: error.localizedDescription)
    }

    private func finish(with status: LockdownReachabilityStatus, connection: NWConnection) {
        guard self.connection === connection else { return }

        self.connection = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        self.status = status
    }

    private func cancelCurrentConnection() {
        timeoutTask?.cancel()
        timeoutTask = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }
}
