//
//  RemotePairingDiscoveryProbe.swift
//  StikDebug
//
//  Discovers Apple's RemotePairing service, including peer-to-peer/AWDL results.
//

import Combine
import Foundation
import Network

enum RemotePairingDiscoveryStatus: Equatable {
    case idle
    case browsing
    case connecting(service: String)
    case reachable(endpoint: String)
    case notFound
    case failed(reason: String)

    var isRunning: Bool {
        switch self {
        case .browsing, .connecting:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class RemotePairingDiscoveryProbe: ObservableObject {
    @Published private(set) var status: RemotePairingDiscoveryStatus = .idle

    private let networkQueue = DispatchQueue(label: "com.stik.stikdebug.remote-pairing-discovery")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var timeoutTask: Task<Void, Never>?

    func start(timeout: TimeInterval = 7) {
        cancel()

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: "_remotepairing._tcp", domain: nil),
            using: parameters
        )

        self.browser = browser
        status = .browsing

        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let browser else { return }
            Task { @MainActor [weak self] in
                guard let self, self.browser === browser else { return }
                if case .failed(let error) = state {
                    self.finish(with: .failed(reason: error.localizedDescription))
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let browser, let endpoint = results.first?.endpoint else { return }
            Task { @MainActor [weak self] in
                guard let self, self.browser === browser else { return }
                self.connect(to: endpoint)
            }
        }

        timeoutTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }

            switch self.status {
            case .browsing:
                // LocalDevVPN carries TCP but does not proxy Bonjour. Fall
                // back to the configured synthetic peer instead of reporting
                // a false "no service" result after the browse window.
                self.connectToConfiguredTarget()
            case .connecting(let service):
                self.finish(with: .failed(reason: "Found \(service), but its endpoint timed out."))
            default:
                break
            }
        }

        browser.start(queue: networkQueue)
    }

    private func connectToConfiguredTarget() {
        let host = DeviceConnectionContext.targetIPAddress
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: 49152)!
        )
        connect(to: endpoint)
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if case .connecting(let service) = self.status {
                self.finish(with: .failed(reason: "Configured VPN target (service) did not respond."))
            }
        }
    }

    private func connect(to endpoint: NWEndpoint) {
        browser?.cancel()
        browser = nil

        let service = Self.describe(endpoint)
        status = .connecting(service: service)

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }

                switch state {
                case .ready:
                    let resolved = connection.currentPath?.remoteEndpoint ?? connection.endpoint
                    self.finish(with: .reachable(endpoint: Self.describe(resolved)))
                case .failed(let error):
                    self.finish(with: .failed(reason: "Found \(service), but connect failed: \(error.localizedDescription)"))
                default:
                    break
                }
            }
        }

        connection.start(queue: networkQueue)
    }

    private func finish(with result: RemotePairingDiscoveryStatus) {
        timeoutTask?.cancel()
        timeoutTask = nil
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        status = result
    }

    private func cancel() {
        finish(with: .idle)
    }

    private static func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        case .service(let name, let type, let domain, _):
            return "\(name).\(type).\(domain)"
        default:
            return String(describing: endpoint)
        }
    }
}
