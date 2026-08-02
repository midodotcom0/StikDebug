import Darwin
import Foundation
import Network

/// Experimental localhost relay for RemotePairing self-connections.
/// The native library connects to `endpoint`; the relay connects onward to the
/// configured target while forcing a non-target local IPv4 source address.
final class LocalPairingRelay: @unchecked Sendable {
    let endpoint: RemotePairingEndpoint

    private struct Source: Equatable {
        let name: String
        let address: String

        var priority: Int {
            if name.hasPrefix("utun") { return 0 }
            if name.hasPrefix("ipsec") { return 10 }
            if name.hasPrefix("pdp_ip") { return 20 }
            if name == "en0" { return 30 }
            return 100
        }
    }

    private final class Holder: @unchecked Sendable {
        weak var relay: LocalPairingRelay?
    }

    private final class Startup: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: Result<UInt16, NSError>?

        func complete(_ value: Result<UInt16, NSError>) {
            lock.lock()
            guard result == nil else { lock.unlock(); return }
            result = value
            lock.unlock()
            semaphore.signal()
        }

        func wait() -> Result<UInt16, NSError>? {
            guard semaphore.wait(timeout: .now() + 3) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    private final class Session: @unchecked Sendable {
        private let client: NWConnection
        private let target: RemotePairingEndpoint
        private let sources: [Source]
        private let queue: DispatchQueue
        private let log: (String) -> Void
        private let finished: () -> Void

        private var server: NWConnection?
        private var sourceIndex = 0
        private var generation = 0
        private var clientReady = false
        private var serverReady = false
        private var pumpsStarted = false
        private var stopped = false

        init(
            client: NWConnection,
            target: RemotePairingEndpoint,
            sources: [Source],
            queue: DispatchQueue,
            log: @escaping (String) -> Void,
            finished: @escaping () -> Void
        ) {
            self.client = client
            self.target = target
            self.sources = sources
            self.queue = queue
            self.log = log
            self.finished = finished
        }

        func start() {
            queue.async { [self] in
                client.stateUpdateHandler = { [weak self] state in
                    guard let self, !stopped else { return }
                    switch state {
                    case .ready:
                        clientReady = true
                        startPumps()
                    case .failed(let error):
                        log("Relay client failed: \(error.localizedDescription)")
                        stopNow()
                    case .cancelled:
                        stopNow()
                    default:
                        break
                    }
                }
                client.start(queue: queue)
                tryNextSource()
            }
        }

        func stop() {
            queue.async { [self] in stopNow() }
        }

        private func tryNextSource() {
            guard !stopped else { return }
            guard sourceIndex < sources.count else {
                log("Relay could not reach \(target.displayName) from any alternate source address.")
                stopNow()
                return
            }

            let source = sources[sourceIndex]
            sourceIndex += 1
            generation += 1
            let attempt = generation

            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(
                host: NWEndpoint.Host(source.address),
                port: .any
            )

            guard let port = NWEndpoint.Port(rawValue: target.port) else {
                stopNow()
                return
            }

            let connection = NWConnection(
                host: NWEndpoint.Host(target.host),
                port: port,
                using: parameters
            )
            server = connection
            serverReady = false

            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection, !stopped,
                      generation == attempt, server === connection else { return }

                switch state {
                case .ready:
                    serverReady = true
                    let actual = connection.currentPath?.localEndpoint.map { String(describing: $0) }
                        ?? source.address
                    log("Relay connected from \(actual) via \(source.name) to \(target.displayName).")
                    startPumps()
                case .failed(let error):
                    log("Relay failed from \(source.address) on \(source.name): \(error.localizedDescription)")
                    connection.cancel()
                    server = nil
                    tryNextSource()
                default:
                    break
                }
            }
            connection.start(queue: queue)

            queue.asyncAfter(deadline: .now() + 3) { [weak self, weak connection] in
                guard let self, let connection, !stopped,
                      generation == attempt, server === connection, !serverReady else { return }
                log("Relay timed out from \(source.address) on \(source.name).")
                connection.cancel()
                server = nil
                tryNextSource()
            }
        }

        private func startPumps() {
            guard clientReady, serverReady, !pumpsStarted, let server else { return }
            pumpsStarted = true
            pump(from: client, to: server)
            pump(from: server, to: client)
        }

        private func pump(from source: NWConnection, to destination: NWConnection) {
            guard !stopped else { return }
            source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
                [weak self] data, _, complete, error in
                guard let self else { return }
                queue.async {
                    guard !stopped else { return }
                    if let error {
                        log("Relay receive failed: \(error.localizedDescription)")
                        stopNow()
                    } else if let data, !data.isEmpty {
                        destination.send(content: data, completion: .contentProcessed { [weak self] error in
                            guard let self else { return }
                            queue.async {
                                if let error {
                                    log("Relay send failed: \(error.localizedDescription)")
                                    stopNow()
                                } else if complete {
                                    stopNow()
                                } else {
                                    pump(from: source, to: destination)
                                }
                            }
                        })
                    } else if complete {
                        stopNow()
                    } else {
                        pump(from: source, to: destination)
                    }
                }
            }
        }

        private func stopNow() {
            guard !stopped else { return }
            stopped = true
            client.cancel()
            server?.cancel()
            server = nil
            finished()
        }
    }

    private let listener: NWListener
    private let target: RemotePairingEndpoint
    private let sources: [Source]
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "com.stik.stikdebug.local-pairing-relay")
    private let lock = NSLock()
    private var sessions: [UUID: Session] = [:]
    private var stopped = false

    static func shouldAttempt(target: RemotePairingEndpoint) -> Bool {
        guard target.interfaceName == nil, isIPv4(target.host) else { return false }
        let addresses = interfaceSources(includeBridges: true)
        return addresses.contains { $0.address == target.host }
            && !sources(excluding: target.host).isEmpty
    }

    static func start(
        target: RemotePairingEndpoint,
        logger: @escaping (String) -> Void
    ) throws -> LocalPairingRelay {
        guard shouldAttempt(target: target) else {
            throw relayError("Target is not a local IPv4 self-address, or no alternate source exists.")
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

        let listener = try NWListener(using: parameters)
        let holder = Holder()
        let startup = Startup()

        listener.newConnectionHandler = { [holder] connection in
            holder.relay?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak listener, startup] state in
            switch state {
            case .ready:
                if let port = listener?.port?.rawValue {
                    startup.complete(.success(port))
                } else {
                    startup.complete(.failure(relayError("Relay listener has no port.")))
                }
            case .failed(let error):
                startup.complete(.failure(relayError("Relay listener failed: \(error.localizedDescription)")))
            default:
                break
            }
        }
        listener.start(queue: DispatchQueue(label: "com.stik.stikdebug.local-pairing-relay.start"))

        guard let result = startup.wait() else {
            listener.cancel()
            throw relayError("Timed out starting relay listener.")
        }

        switch result {
        case .failure(let error):
            listener.cancel()
            throw error
        case .success(let port):
            let relay = LocalPairingRelay(
                endpoint: RemotePairingEndpoint(host: "127.0.0.1", port: port),
                listener: listener,
                target: target,
                sources: sources(excluding: target.host),
                log: logger
            )
            holder.relay = relay
            return relay
        }
    }

    private init(
        endpoint: RemotePairingEndpoint,
        listener: NWListener,
        target: RemotePairingEndpoint,
        sources: [Source],
        log: @escaping (String) -> Void
    ) {
        self.endpoint = endpoint
        self.listener = listener
        self.target = target
        self.sources = sources
        self.log = log
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let active = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()
        listener.cancel()
        active.forEach { $0.stop() }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let session = Session(
            client: connection,
            target: target,
            sources: sources,
            queue: queue,
            log: log,
            finished: { [weak self] in self?.remove(id) }
        )

        lock.lock()
        guard !stopped else { lock.unlock(); session.stop(); return }
        sessions[id] = session
        lock.unlock()
        session.start()
    }

    private func remove(_ id: UUID) {
        lock.lock()
        sessions.removeValue(forKey: id)
        lock.unlock()
    }

    private static func relayError(_ message: String) -> NSError {
        NSError(
            domain: "StikDebug.LocalPairingRelay",
            code: -20,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private static func isIPv4(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) } == 1
    }

    private static func sources(excluding address: String) -> [Source] {
        interfaceSources(includeBridges: false)
            .filter { $0.address != address && !$0.address.hasPrefix("127.") }
            .sorted {
                ($0.priority, $0.name, $0.address) < ($1.priority, $1.name, $1.address)
            }
    }

    private static func interfaceSources(includeBridges: Bool) -> [Source] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }

        var result: [Source] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            guard let raw = item.pointee.ifa_addr,
                  raw.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(item.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            let name = String(cString: item.pointee.ifa_name)
            guard !name.hasPrefix("awdl"), !name.hasPrefix("llw"),
                  includeBridges || !name.hasPrefix("bridge") else { continue }

            var address = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr
            }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { continue }

            let source = Source(name: name, address: String(cString: buffer))
            if !result.contains(source) { result.append(source) }
        }
        return result
    }
}
