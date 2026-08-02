//
//  LocalPairingRelay.swift
//  StikDebug
//
//  A loopback TCP relay that lets the app choose the source address of the
//  RemotePairing connection.
//
//  The problem it works around: `tunnel_create_rppairing` takes a destination
//  `sockaddr` and creates the socket itself, inside the vendored Rust library.
//  There is no way to bind that socket first. On cellular the only address with a
//  live listener is the device's own hotspot address, so the connection ends up
//  with source == destination and the daemon never answers pair-verify.
//
//  The relay splits that into two sockets:
//
//      idevice ──► 127.0.0.1:<relayPort> ──► [this relay] ──► 172.20.10.1:49152
//                                                             bound to a chosen
//                                                             local source address
//
//  The library only ever talks to loopback; we own the outbound socket and can
//  bind() it before connecting. Bytes are copied through unchanged — the relay
//  never parses, decrypts, or modifies the RemotePairing stream.
//
//  This is primarily a measurement: `observedSourceAddress` reports what
//  `getsockname()` actually returned, so a successful handshake proves the source
//  address was the blocker, and a continued timeout proves it was not.
//

import Darwin
import Foundation

/// Which local address the outbound leg should be bound to.
enum RelaySourcePolicy: String, CaseIterable, Identifiable {
    /// Let the kernel pick. For a local destination this yields source == destination.
    case system
    /// The LocalDevVPN tunnel address.
    case tunnel
    /// The cellular interface address.
    case cellular

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System default"
        case .tunnel: return "VPN tunnel address"
        case .cellular: return "Cellular address"
        }
    }

    var detail: String {
        switch self {
        case .system:
            return "Kernel chooses. For a device-local target this ends up equal to the destination."
        case .tunnel:
            return "Binds to the utun address, so source and destination differ."
        case .cellular:
            return "Binds to pdp_ip0, so source and destination differ."
        }
    }
}

final class LocalPairingRelay {
    enum RelayError: LocalizedError {
        case listenFailed(Int32)
        case noSourceAddress(RelaySourcePolicy)
        case bindSourceFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .listenFailed(let code):
                return "Relay could not listen on loopback: \(String(cString: strerror(code)))"
            case .noSourceAddress(let policy):
                return "No local address available for \(policy.title)."
            case .bindSourceFailed(let code):
                return "Relay could not bind the chosen source address: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Loopback port the idevice library should be pointed at.
    private(set) var port: UInt16 = 0

    /// What `getsockname()` reported for the outbound socket. This is the whole
    /// point of the relay — it turns a guess about source addresses into a fact.
    private(set) var observedSourceAddress: String?

    private let destinationHost: String
    private let destinationPort: UInt16
    private let policy: RelaySourcePolicy

    private var listenDescriptor: Int32 = -1
    private let queue = DispatchQueue(label: "com.stik.pairing-relay", qos: .userInitiated)
    private let stateLock = NSLock()
    private var running = false
    private var openDescriptors: Set<Int32> = []

    init(destinationHost: String, destinationPort: UInt16, policy: RelaySourcePolicy) {
        self.destinationHost = destinationHost
        self.destinationPort = destinationPort
        self.policy = policy
    }

    deinit {
        stop()
    }

    /// Binds a loopback listener and starts accepting. Returns the chosen port.
    @discardableResult
    func start() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw RelayError.listenFailed(errno) }

        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0 // kernel picks a free port
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(descriptor)
            throw RelayError.listenFailed(code)
        }

        guard Darwin.listen(descriptor, 4) == 0 else {
            let code = errno
            close(descriptor)
            throw RelayError.listenFailed(code)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }

        listenDescriptor = descriptor
        port = UInt16(bigEndian: boundAddress.sin_port)

        stateLock.lock()
        running = true
        stateLock.unlock()

        queue.async { [weak self] in
            self?.acceptLoop()
        }

        LogManager.shared.addInfoLog(
            "Pairing relay listening on 127.0.0.1:\(port) → \(destinationHost):\(destinationPort) "
            + "(source: \(policy.title))"
        )
        return port
    }

    func stop() {
        stateLock.lock()
        guard running else {
            stateLock.unlock()
            return
        }
        running = false
        let descriptors = openDescriptors
        openDescriptors.removeAll()
        let listener = listenDescriptor
        listenDescriptor = -1
        stateLock.unlock()

        if listener >= 0 {
            close(listener)
        }
        for descriptor in descriptors {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
    }

    private var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    // MARK: - Accepting

    private func acceptLoop() {
        while isRunning {
            let inbound = accept(listenDescriptor, nil, nil)
            guard inbound >= 0 else {
                if isRunning && errno == EINTR { continue }
                break
            }

            track(inbound)

            queue.async { [weak self] in
                self?.handle(inbound: inbound)
            }
        }
    }

    private func handle(inbound: Int32) {
        let outbound: Int32
        do {
            outbound = try connectOutbound()
        } catch {
            LogManager.shared.addErrorLog("Pairing relay: \(error.localizedDescription)")
            untrack(inbound)
            close(inbound)
            return
        }

        track(outbound)

        // Two directions, each on its own thread. Both close their peer when the
        // stream ends so a half-open connection cannot wedge the handshake.
        let group = DispatchGroup()
        for (from, to) in [(inbound, outbound), (outbound, inbound)] {
            queue.async(group: group) { [weak self] in
                self?.pump(from: from, to: to)
            }
        }

        group.notify(queue: queue) { [weak self] in
            self?.untrack(inbound)
            self?.untrack(outbound)
            close(inbound)
            close(outbound)
        }
    }

    private func pump(from source: Int32, to destination: Int32) {
        let capacity = 32 * 1024
        var buffer = [UInt8](repeating: 0, count: capacity)
        while isRunning {
            // `capacity` is read up front: passing `buffer.count` alongside `&buffer`
            // in the same call is an overlapping access.
            let read = recv(source, &buffer, capacity, 0)
            if read <= 0 {
                shutdown(destination, SHUT_WR)
                return
            }

            var written = 0
            while written < read {
                let sent = buffer.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return send(destination, base.advanced(by: written), read - written, 0)
                }
                if sent <= 0 {
                    shutdown(source, SHUT_RD)
                    return
                }
                written += sent
            }
        }
    }

    // MARK: - Outbound leg

    private func connectOutbound() throws -> Int32 {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw RelayError.listenFailed(errno) }

        if policy != .system {
            guard let sourceIP = Self.localAddress(for: policy) else {
                close(descriptor)
                throw RelayError.noSourceAddress(policy)
            }

            var source = sockaddr_in()
            source.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            source.sin_family = sa_family_t(AF_INET)
            source.sin_port = 0
            guard sourceIP.withCString({ inet_pton(AF_INET, $0, &source.sin_addr) }) == 1 else {
                close(descriptor)
                throw RelayError.noSourceAddress(policy)
            }

            let bindResult = withUnsafePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                let code = errno
                close(descriptor)
                throw RelayError.bindSourceFailed(code)
            }
        }

        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = destinationPort.bigEndian
        guard destinationHost.withCString({ inet_pton(AF_INET, $0, &destination.sin_addr) }) == 1 else {
            close(descriptor)
            throw RelayError.noSourceAddress(policy)
        }

        let connectResult = withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            let code = errno
            close(descriptor)
            throw RelayError.bindSourceFailed(code)
        }

        recordSourceAddress(of: descriptor)
        return descriptor
    }

    /// Records what the kernel actually chose, which is the measurement this whole
    /// relay exists to produce.
    private func recordSourceAddress(of descriptor: Int32) {
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0 else { return }

        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var addr = local.sin_addr
        guard inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return }

        let source = String(cString: text)
        observedSourceAddress = source
        LogManager.shared.addInfoLog(
            "Pairing relay outbound source is \(source) → \(destinationHost) "
            + (source == destinationHost ? "(SAME — still a self-connection)" : "(differs — not a self-connection)")
        )
    }

    // MARK: - Interface addresses

    /// First IPv4 address of the interface class the policy names.
    static func localAddress(for policy: RelaySourcePolicy) -> String? {
        let prefixes: [String]
        switch policy {
        case .system: return nil
        case .tunnel: prefixes = ["utun"]
        case .cellular: prefixes = ["pdp_ip"]
        }

        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else { return nil }
        defer { freeifaddrs(addressList) }

        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addressPointer = entry.pointee.ifa_addr,
                  addressPointer.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            let name = String(cString: entry.pointee.ifa_name)
            guard prefixes.contains(where: { name.hasPrefix($0) }) else { continue }

            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = addressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }

            let address = String(cString: text)
            // Skip the reflector's own fake address; it is not a usable source.
            if address == DeviceConnectionContext.targetIPAddress { continue }
            return address
        }
        return nil
    }

    // MARK: - Descriptor bookkeeping

    private func track(_ descriptor: Int32) {
        stateLock.lock()
        openDescriptors.insert(descriptor)
        stateLock.unlock()
    }

    private func untrack(_ descriptor: Int32) {
        stateLock.lock()
        openDescriptors.remove(descriptor)
        stateLock.unlock()
    }
}
