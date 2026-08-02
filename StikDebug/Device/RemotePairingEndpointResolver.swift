//
//  RemotePairingEndpointResolver.swift
//  StikDebug
//
//  Resolves the device's Bonjour-advertised RemotePairing endpoint and keeps
//  its peer-to-peer route alive while the native tunnel opens a second socket.
//

import Darwin
import Foundation
import Network

struct RemotePairingEndpoint: Equatable, Sendable {
    let host: String
    let port: UInt16
    let interfaceName: String?

    init(host: String, port: UInt16, interfaceName: String? = nil) {
        let trimmedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))

        if let percent = trimmedHost.lastIndex(of: "%") {
            self.host = String(trimmedHost[..<percent])
            let scope = String(trimmedHost[trimmedHost.index(after: percent)...])
            self.interfaceName = scope.isEmpty ? interfaceName : scope
        } else {
            self.host = trimmedHost
            self.interfaceName = interfaceName
        }
        self.port = port
    }

    var displayName: String {
        let scopedHost = interfaceName.map { "\(host)%\($0)" } ?? host
        return "\(scopedHost):\(port)"
    }
}

final class RemotePairingEndpointLease {
    let endpoint: RemotePairingEndpoint
    private let browser: NWBrowser?
    private let anchorConnection: NWConnection
    private let pathMonitor: NWPathMonitor
    private let pathQueue = DispatchQueue(label: "com.stik.stikdebug.remote-pairing-path")

    fileprivate init(
        endpoint: RemotePairingEndpoint,
        browser: NWBrowser?,
        anchorConnection: NWConnection,
        pathMonitor: NWPathMonitor
    ) {
        self.endpoint = endpoint
        self.browser = browser
        self.anchorConnection = anchorConnection
        self.pathMonitor = pathMonitor
        pathMonitor.start(queue: pathQueue)
    }

    deinit {
        browser?.cancel()
        anchorConnection.cancel()
        pathMonitor.cancel()
    }
}

enum RemotePairingEndpointResolver {
    private static let serviceType = "_remotepairing._tcp"

    /// Parameters used only for discovery/route anchoring.  The native FFI
    /// opens the actual tunnel socket, but keeping an NWConnection with
    /// handover enabled lets iOS migrate the route when Wi-Fi disappears.
    fileprivate static func handoverParameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        if #available(iOS 11.0, *) {
            parameters.multipathServiceType = .handover
        }
        return parameters
    }

    static func resolve(timeout: TimeInterval = 6) throws -> RemotePairingEndpointLease {
        let resolution = RemotePairingResolution(serviceType: serviceType)
        resolution.start()
        return try resolution.wait(timeout: timeout)
    }
}

private final class RemotePairingResolution: @unchecked Sendable {
    private let serviceType: String
    private let queue = DispatchQueue(label: "com.stik.stikdebug.remote-pairing-resolver")
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var result: Result<RemotePairingEndpoint, NSError>?
    private var completed = false

    init(serviceType: String) {
        self.serviceType = serviceType
    }

    func start() {
        // Keep discovery on the plain Bonjour path. Multipath/handover is
        // applied only to the connected anchor below; applying it to the
        // browser can make the service disappear on iOS 27.
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: nil), using: parameters)
        self.browser = browser

        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let error) = state {
                self.complete(.failure(self.makeError("Remote Pairing discovery failed: \(error.localizedDescription)")))
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, let serviceEndpoint = results.first?.endpoint,
                  self.connection == nil else { return }

            let advertisedInterface: String?
            if case .service(_, _, _, let interface) = serviceEndpoint {
                advertisedInterface = interface?.name
            } else {
                advertisedInterface = nil
            }

            let parameters = RemotePairingEndpointResolver.handoverParameters()
            let connection = NWConnection(to: serviceEndpoint, using: parameters)
            self.connection = connection

            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }

                switch state {
                case .ready:
                    guard case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint else {
                        self.complete(.failure(self.makeError("Remote Pairing resolved without a numeric endpoint.")))
                        return
                    }
                    self.complete(.success(RemotePairingEndpoint(
                        host: String(describing: host),
                        port: port.rawValue,
                        interfaceName: advertisedInterface
                    )))
                case .failed(let error):
                    self.complete(.failure(self.makeError("Remote Pairing endpoint failed: \(error.localizedDescription)")))
                default:
                    break
                }
            }

            connection.start(queue: self.queue)
        }

        browser.start(queue: queue)
    }

    func wait(timeout: TimeInterval) throws -> RemotePairingEndpointLease {
        var waitResult = semaphore.wait(timeout: .now() + max(timeout, 0))
        guard waitResult == .success else {
            // Bonjour is commonly absent behind LocalDevVPN. Keep a real
            // NWConnection anchor on the configured synthetic peer and let
            // the FFI socket reuse that route for pair-verify.
            startConfiguredFallback()
            waitResult = semaphore.wait(timeout: .now() + 5)
            guard waitResult == .success else {
                queue.sync { cancelAllOnQueue() }
                throw makeError("No Remote Pairing service was found within \(Int(timeout)) seconds.")
            }
        }

        lock.lock()
        let finalResult = result
        lock.unlock()

        let resources: (browser: NWBrowser?, anchor: NWConnection?) = queue.sync {
            let resources = (browser, connection)
            browser = nil
            connection = nil
            return resources
        }

        guard let finalResult else {
            resources.browser?.cancel()
            resources.anchor?.cancel()
            throw makeError("Remote Pairing discovery ended without a result.")
        }

        switch finalResult {
        case .success(let endpoint):
            guard let browser = resources.browser, let anchor = resources.anchor else {
                throw makeError("Remote Pairing route was lost before tunnel setup.")
            }
            return RemotePairingEndpointLease(
                endpoint: endpoint,
                browser: browser,
                anchorConnection: anchor,
                pathMonitor: NWPathMonitor()
            )
        case .failure(let error):
            resources.browser?.cancel()
            resources.anchor?.cancel()
            throw error
        }
    }

    private func complete(_ newResult: Result<RemotePairingEndpoint, NSError>) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        result = newResult
        lock.unlock()
        semaphore.signal()
    }

    private func cancelAllOnQueue() {
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
    }

    private func startConfiguredFallback() {
        queue.sync {
            browser?.cancel()
            browser = nil
            guard connection == nil else { return }
            let host = DeviceConnectionContext.targetIPAddress
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: 49152)!
            )
            let parameters = RemotePairingEndpointResolver.handoverParameters()
            let connection = NWConnection(to: endpoint, using: parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                switch state {
                case .ready:
                    self.complete(.success(RemotePairingEndpoint(host: host, port: 49152)))
                case .failed(let error):
                    self.complete(.failure(self.makeError("Configured Remote Pairing endpoint failed: \(error.localizedDescription)")))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func makeError(_ message: String) -> NSError {
        NSError(
            domain: "StikDebug.RemotePairingDiscovery",
            code: -19,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

enum DeviceSocketAddress {
    static func withSockAddr<Result>(
        endpoint: RemotePairingEndpoint,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result
    ) throws -> Result {
        let effectiveEndpoint = try LocalPairingRelayRegistry.redirectedEndpointIfNeeded(for: endpoint)

        var ipv4 = sockaddr_in()
        let ipv4Result = effectiveEndpoint.host.withCString { inet_pton(AF_INET, $0, &ipv4.sin_addr) }
        if ipv4Result == 1 {
            ipv4.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
            ipv4.sin_family = sa_family_t(AF_INET)
            ipv4.sin_port = in_port_t(effectiveEndpoint.port).bigEndian
            return withUnsafePointer(to: &ipv4) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    body($0, socklen_t(MemoryLayout<sockaddr_in>.stride))
                }
            }
        }

        var ipv6 = sockaddr_in6()
        let ipv6Result = effectiveEndpoint.host.withCString { inet_pton(AF_INET6, $0, &ipv6.sin6_addr) }
        guard ipv6Result == 1 else {
            throw NSError(
                domain: "StikDebug.RemotePairingDiscovery",
                code: -18,
                userInfo: [NSLocalizedDescriptionKey: "Remote Pairing returned an invalid numeric address."]
            )
        }

        ipv6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.stride)
        ipv6.sin6_family = sa_family_t(AF_INET6)
        ipv6.sin6_port = in_port_t(effectiveEndpoint.port).bigEndian
        if let interfaceName = effectiveEndpoint.interfaceName {
            let interfaceIndex = if_nametoindex(interfaceName)
            guard interfaceIndex != 0 else {
                throw NSError(
                    domain: "StikDebug.RemotePairingDiscovery",
                    code: -18,
                    userInfo: [NSLocalizedDescriptionKey: "Remote Pairing returned an unknown network interface."]
                )
            }
            ipv6.sin6_scope_id = interfaceIndex
        }

        return withUnsafePointer(to: &ipv6) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_in6>.stride))
            }
        }
    }
}
