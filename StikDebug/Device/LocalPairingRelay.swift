//
//  LocalPairingRelay.swift
//  StikDebug
//
//  Relays the native RemotePairing TCP stream through a loopback listener.
//  The outbound side is explicitly bound to LocalDevVPN's tunnel address so
//  remotepairingdeviced sees a source address different from bridge100.
//

import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class LocalPairingRelayLease: @unchecked Sendable {
    let endpoint: RemotePairingEndpoint

    private let relay: LocalPairingRelay

    fileprivate init(endpoint: RemotePairingEndpoint, relay: LocalPairingRelay) {
        self.endpoint = endpoint
        self.relay = relay
    }

    deinit {
        relay.stop()
    }
}

enum LocalPairingRelayFactory {
    static let hotspotEndpoint = RemotePairingEndpoint(host: "172.20.10.1", port: 49152)
    static let localDevVPNSourceAddress = "10.7.0.2"

    static func start(
        target: RemotePairingEndpoint = hotspotEndpoint,
        sourceAddress: String = localDevVPNSourceAddress
    ) throws -> LocalPairingRelayLease {
        let relay = LocalPairingRelay(target: target, sourceAddress: sourceAddress)
        let endpoint = try relay.start()
        return LocalPairingRelayLease(endpoint: endpoint, relay: relay)
    }
}

private final class LocalPairingRelay: @unchecked Sendable {
    private let target: RemotePairingEndpoint
    private let sourceAddress: String
    private let workerQueue = DispatchQueue(label: "com.stikdebug.local-pairing-relay", qos: .userInitiated)
    private let pumpQueue = DispatchQueue(label: "com.stikdebug.local-pairing-relay.pump", qos: .userInitiated, attributes: .concurrent)
    private let stateLock = NSLock()

    private var listenerFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var upstreamFD: Int32 = -1
    private var stopped = false

    init(target: RemotePairingEndpoint, sourceAddress: String) {
        self.target = target
        self.sourceAddress = sourceAddress
    }

    func start() throws -> RemotePairingEndpoint {
        guard target.interfaceName == nil else {
            throw makeError("The local relay currently supports numeric IPv4 targets only.", code: EAFNOSUPPORT)
        }

        let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), Int32(IPPROTO_TCP))
        guard listener >= 0 else {
            throw systemError("socket(listener)")
        }

        do {
            try configureSocket(listener)

            var loopback = try ipv4Address(host: "127.0.0.1", port: 0)
            let bindResult = withUnsafePointer(to: &loopback) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
                }
            }
            guard bindResult == 0 else {
                throw systemError("bind(loopback)")
            }

            guard listen(listener, 1) == 0 else {
                throw systemError("listen(loopback)")
            }

            var assigned = sockaddr_in()
            var assignedLength = socklen_t(MemoryLayout<sockaddr_in>.stride)
            let nameResult = withUnsafeMutablePointer(to: &assigned) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(listener, $0, &assignedLength)
                }
            }
            guard nameResult == 0 else {
                throw systemError("getsockname(loopback)")
            }

            let port = UInt16(bigEndian: assigned.sin_port)

            stateLock.lock()
            listenerFD = listener
            stateLock.unlock()

            LocalPairingRelayDiagnostics.log(
                "Listening on 127.0.0.1:\(port); outbound source \(sourceAddress), target \(target.displayName)"
            )

            workerQueue.async { [self] in
                acceptAndRelay()
            }

            return RemotePairingEndpoint(host: "127.0.0.1", port: port)
        } catch {
            close(listener)
            throw error
        }
    }

    func stop() {
        let descriptors: [Int32]

        stateLock.lock()
        if stopped {
            stateLock.unlock()
            return
        }
        stopped = true
        descriptors = [listenerFD, clientFD, upstreamFD]
        listenerFD = -1
        clientFD = -1
        upstreamFD = -1
        stateLock.unlock()

        for descriptor in descriptors where descriptor >= 0 {
            _ = shutdown(descriptor, Int32(SHUT_RDWR))
            close(descriptor)
        }
    }

    private func acceptAndRelay() {
        let listener = descriptor(\.listenerFD)
        guard listener >= 0 else { return }

        var peerAddress = sockaddr_storage()
        var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.stride)
        let accepted = withUnsafeMutablePointer(to: &peerAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(listener, $0, &peerLength)
            }
        }

        guard accepted >= 0 else {
            if !isStopped {
                LocalPairingRelayDiagnostics.log(systemError("accept(loopback)").localizedDescription)
            }
            return
        }

        guard register(descriptor: accepted, as: \.clientFD) else {
            close(accepted)
            return
        }
        closeListener()

        do {
            try configureSocket(accepted)
            let upstream = try makeUpstreamSocket()
            guard register(descriptor: upstream, as: \.upstreamFD) else {
                close(upstream)
                return
            }

            LocalPairingRelayDiagnostics.log(
                "Transport established: \(localEndpoint(of: upstream)) -> \(target.displayName)"
            )

            let group = DispatchGroup()
            group.enter()
            pumpQueue.async { [self] in
                pump(from: accepted, to: upstream, direction: "client→device")
                group.leave()
            }
            group.enter()
            pumpQueue.async { [self] in
                pump(from: upstream, to: accepted, direction: "device→client")
                group.leave()
            }
            group.notify(queue: workerQueue) { [weak self] in
                LocalPairingRelayDiagnostics.log("Relay transport finished")
                self?.stop()
            }
        } catch {
            LocalPairingRelayDiagnostics.log("Relay setup failed: \(error.localizedDescription)")
            stop()
        }
    }

    private func makeUpstreamSocket() throws -> Int32 {
        let upstream = socket(AF_INET, Int32(SOCK_STREAM.rawValue), Int32(IPPROTO_TCP))
        guard upstream >= 0 else {
            throw systemError("socket(upstream)")
        }

        do {
            try configureSocket(upstream)

            var source = try ipv4Address(host: sourceAddress, port: 0)
            let sourceBindResult = withUnsafePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
                }
            }
            guard sourceBindResult == 0 else {
                throw systemError("bind(source \(sourceAddress))")
            }
            LocalPairingRelayDiagnostics.log("Bound outbound socket to \(sourceAddress)")

            var targetAddress = try ipv4Address(host: target.host, port: target.port)
            let connectResult = withUnsafePointer(to: &targetAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.stride))
                }
            }
            guard connectResult == 0 else {
                throw systemError("connect(\(target.displayName))")
            }

            return upstream
        } catch {
            close(upstream)
            throw error
        }
    }

    private func configureSocket(_ descriptor: Int32) throws {
        var enabled: Int32 = 1
        let reuseResult = withUnsafePointer(to: &enabled) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                $0,
                socklen_t(MemoryLayout<Int32>.stride)
            )
        }
        guard reuseResult == 0 else {
            throw systemError("setsockopt(SO_REUSEADDR)")
        }

        #if canImport(Darwin)
        let noSigPipeResult = withUnsafePointer(to: &enabled) {
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.stride)
            )
        }
        guard noSigPipeResult == 0 else {
            throw systemError("setsockopt(SO_NOSIGPIPE)")
        }
        #endif
    }

    private func pump(from source: Int32, to destination: Int32, direction: String) {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        var totalBytes = 0
        var loggedFirstPayload = false

        while !isStopped {
            let received = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return recv(source, baseAddress, rawBuffer.count, 0)
            }

            if received > 0 {
                if !loggedFirstPayload {
                    loggedFirstPayload = true
                    LocalPairingRelayDiagnostics.log("First \(direction) payload: \(received) bytes")
                }

                do {
                    try sendAll(buffer, count: received, to: destination)
                    totalBytes += received
                } catch {
                    LocalPairingRelayDiagnostics.log("\(direction) send failed: \(error.localizedDescription)")
                    stop()
                    return
                }
                continue
            }

            if received == 0 {
                _ = shutdown(destination, Int32(SHUT_WR))
                LocalPairingRelayDiagnostics.log("\(direction) closed after \(totalBytes) bytes")
                return
            }

            let code = errno
            if code == EINTR {
                continue
            }
            if isStopped {
                return
            }

            LocalPairingRelayDiagnostics.log(
                "\(direction) receive failed: \(errorDescription(code: code)) (\(code))"
            )
            stop()
            return
        }
    }

    private func sendAll(_ bytes: [UInt8], count: Int, to descriptor: Int32) throws {
        var offset = 0
        while offset < count {
            let sent = bytes.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                return send(descriptor, baseAddress.advanced(by: offset), count - offset, 0)
            }

            if sent > 0 {
                offset += sent
                continue
            }

            let code = errno
            if sent < 0, code == EINTR {
                continue
            }
            throw makeError("send failed: \(errorDescription(code: code))", code: code)
        }
    }

    private func ipv4Address(host: String, port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian

        let parseResult = host.withCString {
            inet_pton(AF_INET, $0, &address.sin_addr)
        }
        guard parseResult == 1 else {
            throw makeError("Invalid IPv4 address: \(host)", code: EINVAL)
        }
        return address
    }

    private func localEndpoint(of descriptor: Int32) -> String {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.stride)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0 else { return sourceAddress }

        var rawAddress = address.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let host = buffer.withUnsafeMutableBufferPointer { bufferPointer -> String? in
            guard let baseAddress = bufferPointer.baseAddress,
                  let result = inet_ntop(AF_INET, &rawAddress, baseAddress, socklen_t(INET_ADDRSTRLEN)) else {
                return nil
            }
            return String(cString: result)
        } ?? sourceAddress

        return "\(host):\(UInt16(bigEndian: address.sin_port))"
    }

    private func register(
        descriptor: Int32,
        as keyPath: ReferenceWritableKeyPath<LocalPairingRelay, Int32>
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !stopped else { return false }
        self[keyPath: keyPath] = descriptor
        return true
    }

    private func descriptor(_ keyPath: KeyPath<LocalPairingRelay, Int32>) -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return self[keyPath: keyPath]
    }

    private func closeListener() {
        let listener: Int32
        stateLock.lock()
        listener = listenerFD
        listenerFD = -1
        stateLock.unlock()

        if listener >= 0 {
            _ = shutdown(listener, Int32(SHUT_RDWR))
            close(listener)
        }
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func systemError(_ operation: String) -> NSError {
        let code = errno
        return makeError("\(operation) failed: \(errorDescription(code: code))", code: code)
    }

    private func makeError(_ message: String, code: Int32) -> NSError {
        NSError(
            domain: "StikDebug.LocalPairingRelay",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func errorDescription(code: Int32) -> String {
        guard let description = strerror(code) else { return "errno \(code)" }
        return String(cString: description)
    }
}

private enum LocalPairingRelayDiagnostics {
    private static let queue = DispatchQueue(label: "com.stikdebug.local-pairing-relay.log", qos: .utility)
    private static let formatter = ISO8601DateFormatter()

    static func log(_ message: String) {
        queue.async {
            let line = "[\(formatter.string(from: Date()))] \(message)\n"
            NSLog("[LocalPairingRelay] %@", message)

            guard let data = line.data(using: .utf8),
                  let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return
            }

            let logURL = documents.appendingPathComponent("local_pairing_relay.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }

            guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }
}
