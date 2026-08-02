//
//  LocalPairingRelay.swift
//  StikDebug
//
//  Keeps the native idevice tunnel on a loopback TCP endpoint while relaying
//  the byte stream to remotepairingdeviced on the Personal Hotspot interface.
//

import Darwin
import Foundation
import Network

/// Process-wide TCP relay used as a diagnostic transport for RemotePairing.
///
/// The idevice FFI connects to `127.0.0.1:<ephemeral>`. Every accepted stream
/// is forwarded to `172.20.10.1:<port>`. When LocalDevVPN exposes an IPv4
/// address on a utun interface, the upstream socket first tries to use that
/// address as its local endpoint so remotepairingdeviced sees a non-bridge100
/// source address. If iOS rejects the explicit source binding, the relay makes
/// one unbound fallback attempt so the failure mode remains observable.
final class LocalPairingRelay: @unchecked Sendable {
    private let targetHost: NWEndpoint.Host
    private let targetPort: NWEndpoint.Port
    private let preferredSourceHost: NWEndpoint.Host?
    private let queue = DispatchQueue(label: "com.stik.stikdebug.local-pairing-relay")
    private let startupSemaphore = DispatchSemaphore(value: 0)
    private let startupLock = NSLock()

    private var listener: NWListener?
    private var sessions: [UUID: LocalPairingRelaySession] = [:]
    private var startupResult: Result<NWEndpoint.Port, NSError>?
    private var startupCompleted = false

    private(set) var endpoint: RemotePairingEndpoint

    init(targetHost: String, targetPort: UInt16, preferredSourceHost: String?) throws {
        guard let networkPort = NWEndpoint.Port(rawValue: targetPort) else {
            throw Self.makeError("Invalid RemotePairing relay target port: \(targetPort)")
        }

        self.targetHost = NWEndpoint.Host(targetHost)
        self.targetPort = networkPort
        self.preferredSourceHost = preferredSourceHost.map { NWEndpoint.Host($0) }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: .any
        )

        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener

        // Assigned after the listener reports its ephemeral port.
        endpoint = RemotePairingEndpoint(host: "127.0.0.1", port: 0)

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }

            switch state {
            case .ready:
                guard let port = listener.port else {
                    self.completeStartup(.failure(Self.makeError("Loopback relay started without a port.")))
                    return
                }
                self.completeStartup(.success(port))
                self.log(
                    "Local pairing relay ready on 127.0.0.1:\(port.rawValue) " +
                    "→ \(targetHost):\(targetPort), preferred source: \(preferredSourceHost ?? "automatic")"
                )
            case .failed(let error):
                self.completeStartup(.failure(Self.makeError("Loopback relay failed: \(error.localizedDescription)")))
            case .cancelled:
                self.completeStartup(.failure(Self.makeError("Loopback relay was cancelled during startup.")))
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        guard startupSemaphore.wait(timeout: .now() + 3) == .success else {
            listener.cancel()
            throw Self.makeError("Timed out while starting the loopback pairing relay.")
        }

        startupLock.lock()
        let result = startupResult
        startupLock.unlock()

        switch result {
        case .success(let port):
            endpoint = RemotePairingEndpoint(host: "127.0.0.1", port: port.rawValue)
        case .failure(let error):
            listener.cancel()
            throw error
        case .none:
            listener.cancel()
            throw Self.makeError("Loopback pairing relay ended without a startup result.")
        }
    }

    deinit {
        listener?.cancel()
        sessions.values.forEach { $0.cancel() }
        sessions.removeAll()
    }

    private func completeStartup(_ result: Result<NWEndpoint.Port, NSError>) {
        startupLock.lock()
        guard !startupCompleted else {
            startupLock.unlock()
            return
        }
        startupCompleted = true
        startupResult = result
        startupLock.unlock()
        startupSemaphore.signal()
    }

    private func accept(_ client: NWConnection) {
        let id = UUID()
        let session = LocalPairingRelaySession(
            id: id,
            client: client,
            targetHost: targetHost,
            targetPort: targetPort,
            preferredSourceHost: preferredSourceHost,
            queue: queue,
            logger: { [weak self] message in self?.log(message) },
            completion: { [weak self] id in
                self?.sessions.removeValue(forKey: id)
            }
        )
        sessions[id] = session
        session.start()
    }

    private func log(_ message: String) {
        let line = "LocalPairingRelay: \(message)"
        NSLog("%@", line)
        LogManager.shared.addInfoLog(line)
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(
            domain: "StikDebug.LocalPairingRelay",
            code: -20,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private final class LocalPairingRelaySession: @unchecked Sendable {
    private let id: UUID
    private let client: NWConnection
    private let targetHost: NWEndpoint.Host
    private let targetPort: NWEndpoint.Port
    private let preferredSourceHost: NWEndpoint.Host?
    private let queue: DispatchQueue
    private let logger: (String) -> Void
    private let completion: (UUID) -> Void

    private var upstream: NWConnection?
    private var fallbackTask: DispatchWorkItem?
    private var usedUnboundFallback = false
    private var startedPumping = false
    private var completedDirections = 0
    private var finished = false

    init(
        id: UUID,
        client: NWConnection,
        targetHost: NWEndpoint.Host,
        targetPort: NWEndpoint.Port,
        preferredSourceHost: NWEndpoint.Host?,
        queue: DispatchQueue,
        logger: @escaping (String) -> Void,
        completion: @escaping (UUID) -> Void
    ) {
        self.id = id
        self.client = client
        self.targetHost = targetHost
        self.targetPort = targetPort
        self.preferredSourceHost = preferredSourceHost
        self.queue = queue
        self.logger = logger
        self.completion = completion
    }

    func start() {
        client.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let error):
                self.finish(reason: "loopback client failed: \(error.localizedDescription)")
            case .cancelled:
                self.finish(reason: nil)
            default:
                break
            }
        }
        client.start(queue: queue)
        connectUpstream(boundToPreferredSource: preferredSourceHost != nil)
    }

    func cancel() {
        finish(reason: nil)
    }

    private func connectUpstream(boundToPreferredSource: Bool) {
        fallbackTask?.cancel()
        upstream?.stateUpdateHandler = nil
        upstream?.cancel()

        let parameters = NWParameters.tcp
        if boundToPreferredSource, let preferredSourceHost {
            parameters.requiredLocalEndpoint = .hostPort(host: preferredSourceHost, port: .any)
        }

        let connection = NWConnection(host: targetHost, port: targetPort, using: parameters)
        upstream = connection

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.upstream === connection, !self.finished else { return }

            switch state {
            case .ready:
                self.fallbackTask?.cancel()
                self.fallbackTask = nil
                self.logger(
                    "upstream ready to \(self.targetHost):\(self.targetPort.rawValue)" +
                    (boundToPreferredSource ? " with preferred source" : " with automatic source")
                )
                self.beginPumpingIfNeeded()
            case .failed(let error):
                if boundToPreferredSource, !self.usedUnboundFallback {
                    self.retryWithoutSourceBinding(reason: error.localizedDescription)
                } else {
                    self.finish(reason: "upstream failed: \(error.localizedDescription)")
                }
            case .waiting(let error):
                self.logger("upstream waiting: \(error.localizedDescription)")
            case .cancelled:
                if !self.finished, !boundToPreferredSource || self.usedUnboundFallback {
                    self.finish(reason: nil)
                }
            default:
                break
            }
        }

        connection.start(queue: queue)

        if boundToPreferredSource {
            let fallbackTask = DispatchWorkItem { [weak self, weak connection] in
                guard let self, let connection, self.upstream === connection,
                      !self.startedPumping, !self.finished, !self.usedUnboundFallback else { return }
                self.retryWithoutSourceBinding(reason: "preferred-source attempt did not become ready")
            }
            self.fallbackTask = fallbackTask
            queue.asyncAfter(deadline: .now() + 2, execute: fallbackTask)
        }
    }

    private func retryWithoutSourceBinding(reason: String) {
        guard !usedUnboundFallback, !finished else { return }
        usedUnboundFallback = true
        logger("preferred source unavailable (\(reason)); retrying with automatic source")
        connectUpstream(boundToPreferredSource: false)
    }

    private func beginPumpingIfNeeded() {
        guard !startedPumping, let upstream, !finished else { return }
        startedPumping = true
        pump(from: client, to: upstream, direction: "client→device")
        pump(from: upstream, to: client, direction: "device→client")
    }

    private func pump(from source: NWConnection, to destination: NWConnection, direction: String) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }

            if let error {
                self.finish(reason: "\(direction) receive failed: \(error.localizedDescription)")
                return
            }

            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self, !self.finished else { return }
                    if let sendError {
                        self.finish(reason: "\(direction) send failed: \(sendError.localizedDescription)")
                    } else if isComplete {
                        self.finishDirection(destination: destination)
                    } else {
                        self.pump(from: source, to: destination, direction: direction)
                    }
                })
                return
            }

            if isComplete {
                self.finishDirection(destination: destination)
            } else {
                self.pump(from: source, to: destination, direction: direction)
            }
        }
    }

    private func finishDirection(destination: NWConnection) {
        destination.send(
            content: nil,
            contentContext: .defaultMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self] error in
                guard let self, !self.finished else { return }
                if let error {
                    self.finish(reason: "half-close failed: \(error.localizedDescription)")
                    return
                }

                self.completedDirections += 1
                if self.completedDirections >= 2 {
                    self.finish(reason: nil)
                }
            }
        )
    }

    private func finish(reason: String?) {
        guard !finished else { return }
        finished = true
        fallbackTask?.cancel()
        fallbackTask = nil
        client.stateUpdateHandler = nil
        upstream?.stateUpdateHandler = nil
        client.cancel()
        upstream?.cancel()
        upstream = nil
        if let reason {
            logger(reason)
        }
        completion(id)
    }
}

enum LocalPairingRelayRegistry {
    private static let lock = NSLock()
    private static var relay: LocalPairingRelay?

    static func redirectedEndpointIfNeeded(for endpoint: RemotePairingEndpoint) throws -> RemotePairingEndpoint {
        guard shouldRedirect(endpoint) else { return endpoint }

        lock.lock()
        defer { lock.unlock() }

        if let relay {
            return relay.endpoint
        }

        let sourceHost = preferredTunnelIPv4Address()
        let relay = try LocalPairingRelay(
            targetHost: "172.20.10.1",
            targetPort: endpoint.port,
            preferredSourceHost: sourceHost
        )
        self.relay = relay
        return relay.endpoint
    }

    private static func shouldRedirect(_ endpoint: RemotePairingEndpoint) -> Bool {
        guard endpoint.port == 49152 else { return false }
        return endpoint.host == "172.20.10.1" || endpoint.host.hasPrefix("10.7.")
    }

    private static func preferredTunnelIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }

        var fallback: String?
        var current: UnsafeMutablePointer<ifaddrs>? = first

        while let interface = current {
            defer { current = interface.pointee.ifa_next }

            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET),
                  let namePointer = interface.pointee.ifa_name else { continue }

            let name = String(cString: namePointer)
            guard name.hasPrefix("utun") else { continue }

            var addressStorage = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr
            }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let converted = buffer.withUnsafeMutableBufferPointer { bufferPointer in
                inet_ntop(
                    AF_INET,
                    &addressStorage,
                    bufferPointer.baseAddress,
                    socklen_t(INET_ADDRSTRLEN)
                )
            }
            guard converted != nil else { continue }

            let host = String(cString: buffer)
            if host.hasPrefix("10.7.") {
                return host
            }
            fallback = fallback ?? host
        }

        return fallback
    }
}
