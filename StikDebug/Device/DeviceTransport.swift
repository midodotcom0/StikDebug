//
//  DeviceTransport.swift
//  StikDebug
//
//  Owns the RSD session and how it is reached.
//
//  There are two ways to a Remote Service Discovery handshake on the device itself,
//  and they depend on completely different system daemons:
//
//    * `.remotePairing` — TCP 49152, `remotepairingdeviced`. iOS only creates this
//      listener while the device is associated to a Wi-Fi network as a client, so
//      it is unavailable on cellular and in Personal Hotspot (access point) mode.
//    * `.coreDeviceProxy` — TCP 62078, `lockdownd`, then the
//      `com.apple.internal.devicecompute.CoreDeviceProxy` service. lockdownd binds
//      at boot rather than on Wi-Fi association, so this path can survive where the
//      first one cannot.
//
//  Both produce the same `AdapterHandle` + `RsdHandshakeHandle` pair, so every
//  existing `*_connect_rsd` call site works unchanged regardless of which one won.
//
//  The session is deliberately sticky: once established it is kept alive across
//  scene changes and network handoffs. The whole path is device-local
//  (utun to utun through LocalDevVPN), so an established session needs no external
//  network and can outlive the Wi-Fi association that was required to create it.
//

import Darwin
import Foundation
import idevice

enum DeviceTransportKind: String, CaseIterable, Identifiable {
    case remotePairing
    case coreDeviceProxy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remotePairing: return "RemotePairing"
        case .coreDeviceProxy: return "CoreDeviceProxy"
        }
    }

    var port: UInt16 {
        switch self {
        case .remotePairing: return TransportProbe.remotePairingPort
        case .coreDeviceProxy: return TransportProbe.lockdownPort
        }
    }

    var detail: String {
        switch self {
        case .remotePairing: return "Port \(port) — needs the device to be a Wi-Fi client"
        case .coreDeviceProxy: return "Port \(port) — via lockdownd, works without Wi-Fi"
        }
    }
}

struct TunnelHandles {
    var adapter: OpaquePointer?
    var handshake: OpaquePointer?

    var isValid: Bool { adapter != nil && handshake != nil }

    mutating func free() {
        if let handshake {
            rsd_handshake_free(handshake)
            self.handshake = nil
        }
        if let adapter {
            adapter_free(adapter)
            self.adapter = nil
        }
    }
}

final class DeviceTransport {
    static let shared = DeviceTransport()

    /// Set by `SettingsView` to pin a single transport for testing. `nil` means try both.
    static var configuredOverride: DeviceTransportKind? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: UserDefaults.Keys.transportOverride) else {
                return nil
            }
            return DeviceTransportKind(rawValue: raw)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.rawValue, forKey: UserDefaults.Keys.transportOverride)
            } else {
                UserDefaults.standard.removeObject(forKey: UserDefaults.Keys.transportOverride)
            }
        }
    }

    /// Which local address the RemotePairing connection should originate from.
    ///
    /// `.system` is the historical behaviour: the kernel picks, which for a
    /// device-local destination means source == destination. The other policies
    /// route through `LocalPairingRelay` to force a different source.
    static var configuredSourcePolicy: RelaySourcePolicy {
        get {
            guard let raw = UserDefaults.standard.string(forKey: UserDefaults.Keys.pairingSourcePolicy),
                  let policy = RelaySourcePolicy(rawValue: raw) else {
                return .system
            }
            return policy
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: UserDefaults.Keys.pairingSourcePolicy)
        }
    }

    private let stateLock = NSLock()
    private let connectLock = NSLock()

    private var handles = TunnelHandles()
    private var connectedKind: DeviceTransportKind?

    /// The DVT location channel, cached so route playback does not rebuild it for
    /// every sample. It is layered on `handles.adapter`, so it lives and dies with the
    /// session and is guarded by the same lock — that is what keeps a stale channel
    /// from outliving the adapter it points into.
    private var locationChannel: OpaquePointer?

    private init() {}

    // MARK: - State

    var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return handles.isValid
    }

    var activeKind: DeviceTransportKind? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return handles.isValid ? connectedKind : nil
    }

    var adapterHandle: OpaquePointer? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return handles.adapter
    }

    var handshakeHandle: OpaquePointer? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return handles.handshake
    }

    /// Drops the cached session. The next `withRSD` rebuilds it.
    func invalidate() {
        stateLock.lock()
        var stale = handles
        let staleChannel = locationChannel
        handles = TunnelHandles()
        locationChannel = nil
        connectedKind = nil
        stateLock.unlock()

        // Order matters: the channel is layered on the adapter.
        if let staleChannel {
            location_simulation_free(staleChannel)
        }
        stale.free()
    }

    // MARK: - Connecting

    /// Establishes the session if it is not already up. Blocking — call off the main thread.
    ///
    /// `isCancelled` is consulted between transport attempts. The FFI connect itself
    /// cannot be interrupted, so a cancel takes effect at the next attempt boundary
    /// rather than instantly.
    @discardableResult
    func connectIfNeeded(isCancelled: () -> Bool = { false }) throws -> DeviceTransportKind {
        if let kind = activeKind {
            return kind
        }

        connectLock.lock()
        defer { connectLock.unlock() }

        // Another thread may have connected while we waited for the lock.
        if let kind = activeKind {
            return kind
        }

        guard FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path) else {
            throw TransportError.pairingFileMissing
        }

        var attempts: [(kind: DeviceTransportKind, error: NSError)] = []

        for kind in orderedKinds() {
            if isCancelled() {
                throw TransportError.cancelled
            }

            // Cancellation is deliberately raised outside the do/catch below. Inside
            // it, `catch let error as NSError` would swallow it — every Swift error
            // bridges to NSError — and quietly move on to the next transport.
            let newHandles: TunnelHandles
            do {
                newHandles = try createTunnel(kind: kind, hostname: "StikDebug")
            } catch let error as NSError {
                LogManager.shared.addWarningLog(
                    "\(kind.title) transport failed on port \(kind.port): \(error.localizedDescription)"
                )
                attempts.append((kind, error))
                continue
            }

            if isCancelled() {
                var discarded = newHandles
                discarded.free()
                throw TransportError.cancelled
            }

            stateLock.lock()
            var stale = handles
            let staleChannel = locationChannel
            handles = newHandles
            locationChannel = nil
            connectedKind = kind
            stateLock.unlock()

            // Replacing the adapter invalidates anything layered on the old one.
            if let staleChannel {
                location_simulation_free(staleChannel)
            }
            stale.free()

            UserDefaults.standard.set(kind.rawValue, forKey: UserDefaults.Keys.lastSuccessfulTransport)
            LogManager.shared.addInfoLog("Tunnel established via \(kind.title) (port \(kind.port))")
            return kind
        }

        throw TransportError.allTransportsFailed(attempts)
    }

    /// Runs `body` with the DVT location simulation channel, opening it if needed.
    ///
    /// `body` runs while `stateLock` is held. That is deliberate: it makes it
    /// impossible for `invalidate()` to free the adapter out from under an in-flight
    /// location update. The calls involved are short round-trips, and the connect
    /// path does not hold this lock, so nothing long-running is serialised behind it.
    func withLocationChannel<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try connectIfNeeded()

        stateLock.lock()
        defer { stateLock.unlock() }

        guard let adapter = handles.adapter, let handshake = handles.handshake else {
            throw TransportError.notConnected
        }

        if locationChannel == nil {
            var remoteServer: OpaquePointer?
            if let ffiError = remote_server_connect_rsd(adapter, handshake, &remoteServer) {
                throw TransportError.ffi(ffiError, fallback: "Failed to connect remote server")
            }
            guard let remoteServer else {
                throw TransportError.incompleteHandles
            }

            // `location_simulation_new` takes ownership of the remote server handle
            // on success; on failure it stays ours to free.
            var channel: OpaquePointer?
            if let ffiError = location_simulation_new(remoteServer, &channel) {
                remote_server_free(remoteServer)
                throw TransportError.ffi(ffiError, fallback: "Failed to open location simulation")
            }
            guard let channel else {
                remote_server_free(remoteServer)
                throw TransportError.incompleteHandles
            }
            locationChannel = channel
        }

        guard let channel = locationChannel else {
            throw TransportError.notConnected
        }

        do {
            return try body(channel)
        } catch {
            // The channel is unusable once a command fails on it; drop it so the next
            // attempt opens a fresh one rather than reusing a broken handle.
            location_simulation_free(channel)
            locationChannel = nil
            throw error
        }
    }

    /// True when a location channel is currently open.
    var hasLocationChannel: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return locationChannel != nil
    }

    /// Creates a session without adopting it as the shared one. Used where a
    /// dedicated tunnel is intentional, such as debug sessions and the heartbeat.
    func createDetachedTunnel(hostname: String) throws -> TunnelHandles {
        var attempts: [(kind: DeviceTransportKind, error: NSError)] = []

        // Prefer whatever the shared session already proved to work.
        var kinds = orderedKinds()
        if let active = activeKind, let index = kinds.firstIndex(of: active), index != 0 {
            kinds.remove(at: index)
            kinds.insert(active, at: 0)
        }

        for kind in kinds {
            do {
                return try createTunnel(kind: kind, hostname: hostname)
            } catch let error as NSError {
                attempts.append((kind, error))
            }
        }

        throw TransportError.allTransportsFailed(attempts)
    }

    // MARK: - Ordering

    private func orderedKinds() -> [DeviceTransportKind] {
        if let override = Self.configuredOverride {
            return [override]
        }

        var kinds: [DeviceTransportKind] = [.remotePairing, .coreDeviceProxy]

        // Without a Wi-Fi client association, `remotepairingdeviced` is guaranteed
        // not to be listening. Skip straight past it instead of burning a timeout.
        let interfaces = TransportProbe.activeInterfaceNames()
        let hasWiFiClient = interfaces.contains { $0 == "en0" || $0 == "en1" }
        if !hasWiFiClient {
            kinds = [.coreDeviceProxy, .remotePairing]
        }

        // Otherwise start with whatever worked last time.
        if hasWiFiClient,
           let raw = UserDefaults.standard.string(forKey: UserDefaults.Keys.lastSuccessfulTransport),
           let last = DeviceTransportKind(rawValue: raw),
           let index = kinds.firstIndex(of: last) {
            kinds.remove(at: index)
            kinds.insert(last, at: 0)
        }

        return kinds
    }

    // MARK: - Backends

    private func createTunnel(kind: DeviceTransportKind, hostname: String) throws -> TunnelHandles {
        // Check reachability first. The FFI has no connect timeout of its own, so
        // aiming it at an address that does not exist — a hotspot that is off, a
        // stale target IP — blocks for minutes instead of failing over to the other
        // transport. A 4-second probe turns that into an immediate, explainable skip.
        let target = DeviceConnectionContext.targetIPAddress
        let outcome = TransportProbe.probe(host: target, port: kind.port, timeout: 4)
        guard outcome == .connected else {
            LogManager.shared.addWarningLog(
                "Skipping \(kind.title): \(target):\(kind.port) is \(outcome.summary)"
            )
            throw TransportError.unreachable(kind: kind, host: target, outcome: outcome)
        }

        LogManager.shared.addInfoLog("Trying \(kind.title) at \(target):\(kind.port)")

        switch kind {
        case .remotePairing:
            return try createRemotePairingTunnel(hostname: hostname)
        case .coreDeviceProxy:
            return try createCoreDeviceProxyTunnel(hostname: hostname)
        }
    }

    /// The classic path: speak RemotePairing directly to `remotepairingdeviced`.
    ///
    /// When a source policy other than `.system` is configured, the connection is
    /// routed through `LocalPairingRelay` so the outbound socket can be bound to a
    /// different local address. `tunnel_create_rppairing` creates its own socket
    /// internally and offers no way to bind it, so the loopback hop is the only
    /// place we can influence the source address without rebuilding the Rust library.
    private func createRemotePairingTunnel(hostname: String) throws -> TunnelHandles {
        let policy = Self.configuredSourcePolicy
        guard policy == .system else {
            return try createRelayedRemotePairingTunnel(hostname: hostname, policy: policy)
        }
        return try createDirectRemotePairingTunnel(hostname: hostname)
    }

    private func createRelayedRemotePairingTunnel(
        hostname: String,
        policy: RelaySourcePolicy
    ) throws -> TunnelHandles {
        let relay = LocalPairingRelay(
            destinationHost: DeviceConnectionContext.targetIPAddress,
            destinationPort: DeviceTransportKind.remotePairing.port,
            policy: policy
        )
        let relayPort = try relay.start()
        defer { relay.stop() }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = relayPort.bigEndian
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        do {
            return try createRemotePairingTunnel(hostname: hostname, address: &address)
        } catch {
            if let source = relay.observedSourceAddress {
                LogManager.shared.addWarningLog(
                    "Relayed RemotePairing failed with source \(source). "
                    + (source == DeviceConnectionContext.targetIPAddress
                       ? "Source still equals the destination."
                       : "Source differed from the destination, so the source address is not the blocker.")
                )
            }
            throw error
        }
    }

    private func createDirectRemotePairingTunnel(hostname: String) throws -> TunnelHandles {
        var address = try socketAddress(port: DeviceTransportKind.remotePairing.port)
        return try createRemotePairingTunnel(hostname: hostname, address: &address)
    }

    private func createRemotePairingTunnel(
        hostname: String,
        address: inout sockaddr_in
    ) throws -> TunnelHandles {

        var pairingFile: OpaquePointer?
        let pairingPath = PairingFileStore.prepareURL().path
        if let ffiError = pairingPath.withCString({ rp_pairing_file_read($0, &pairingFile) }) {
            throw TransportError.ffi(ffiError, fallback: "Failed to read pairing file")
        }
        guard let pairingFile else {
            throw TransportError.pairingFileUnreadable
        }
        defer { rp_pairing_file_free(pairingFile) }

        var tunnel = TunnelHandles()
        let ffiError = hostname.withCString { hostname in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    tunnel_create_rppairing(
                        $0,
                        socklen_t(MemoryLayout<sockaddr_in>.stride),
                        hostname,
                        pairingFile,
                        nil,
                        nil,
                        &tunnel.adapter,
                        &tunnel.handshake
                    )
                }
            }
        }

        if let ffiError {
            throw TransportError.ffi(ffiError, fallback: "Failed to create RemotePairing tunnel")
        }
        guard tunnel.isValid else {
            var incomplete = tunnel
            incomplete.free()
            throw TransportError.incompleteHandles
        }
        return tunnel
    }

    /// The lockdownd path: build a lockdown provider over TCP, then let
    /// CoreDeviceProxy carry the tunnel. `tunnel_create_usb` is named for its
    /// usual transport, but it takes an arbitrary provider — feeding it a TCP
    /// provider reaches the same RSD without `remotepairingdeviced`.
    private func createCoreDeviceProxyTunnel(hostname: String) throws -> TunnelHandles {
        var address = try socketAddress(port: DeviceTransportKind.coreDeviceProxy.port)

        var pairingFile: OpaquePointer?
        let pairingPath = PairingFileStore.prepareURL().path
        if let ffiError = pairingPath.withCString({ idevice_pairing_file_read($0, &pairingFile) }) {
            throw TransportError.ffi(
                ffiError,
                fallback: "Pairing file is not a lockdown pair record"
            )
        }
        guard let pairingFile else {
            throw TransportError.pairingFileUnreadable
        }

        // `idevice_tcp_provider_new` consumes the pairing file — it must not be freed here.
        var provider: OpaquePointer?
        let providerError = hostname.withCString { label in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    idevice_tcp_provider_new($0, pairingFile, label, &provider)
                }
            }
        }

        if let providerError {
            throw TransportError.ffi(providerError, fallback: "Failed to create lockdown provider")
        }
        guard let provider else {
            throw TransportError.incompleteHandles
        }
        defer { idevice_provider_free(provider) }

        var tunnel = TunnelHandles()
        if let ffiError = tunnel_create_usb(provider, &tunnel.adapter, &tunnel.handshake) {
            throw TransportError.ffi(ffiError, fallback: "Failed to create CoreDeviceProxy tunnel")
        }
        guard tunnel.isValid else {
            var incomplete = tunnel
            incomplete.free()
            throw TransportError.incompleteHandles
        }
        return tunnel
    }

    private func socketAddress(port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian

        let target = DeviceConnectionContext.targetIPAddress
        guard target.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw TransportError.invalidTargetAddress(target)
        }
        return address
    }
}

// MARK: - Errors

enum TransportError {
    static let domain = "StikDebug.Transport"

    static let pairingFileMissing = NSError(
        domain: domain,
        code: -17,
        userInfo: [NSLocalizedDescriptionKey: "Pairing file not found."]
    )

    static let pairingFileUnreadable = NSError(
        domain: domain,
        code: -9,
        userInfo: [NSLocalizedDescriptionKey: "Pairing file could not be read."]
    )

    static let notConnected = NSError(
        domain: domain,
        code: -2,
        userInfo: [NSLocalizedDescriptionKey: "Tunnel is not connected."]
    )

    static let incompleteHandles = NSError(
        domain: domain,
        code: -3,
        userInfo: [NSLocalizedDescriptionKey: "Tunnel was created without valid handles."]
    )

    static let cancelled = NSError(
        domain: domain,
        code: -999,
        userInfo: [NSLocalizedDescriptionKey: "Connection cancelled."]
    )

    /// The target port did not accept a TCP connection, so there is no point
    /// handing the address to the FFI and waiting out its lack of a timeout.
    static func unreachable(
        kind: DeviceTransportKind,
        host: String,
        outcome: ProbeOutcome
    ) -> NSError {
        let explanation: String
        switch outcome {
        case .refused:
            explanation = "\(host) answered but nothing is listening on port \(kind.port)."
        case .timedOut:
            explanation = "No reply from \(host):\(kind.port) — the address does not exist on any active interface."
        case .invalidAddress:
            explanation = "\(host) is not a valid IPv4 address."
        default:
            explanation = "\(host):\(kind.port) is not reachable (\(outcome.summary))."
        }
        return NSError(
            domain: domain,
            code: outcome == .refused ? 61 : 60,
            userInfo: [NSLocalizedDescriptionKey: explanation]
        )
    }

    static func invalidTargetAddress(_ address: String) -> NSError {
        NSError(
            domain: domain,
            code: -18,
            userInfo: [NSLocalizedDescriptionKey: "Target address \(address) is not a valid IPv4 address."]
        )
    }

    static func ffi(_ error: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) -> NSError {
        guard let error else {
            return NSError(domain: domain, code: -1, userInfo: [NSLocalizedDescriptionKey: fallback])
        }
        let message = error.pointee.message.flatMap { String(validatingUTF8: $0) } ?? fallback
        let code = Int(error.pointee.code)
        idevice_error_free(error)
        return NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Every transport failed. Carries each attempt so the UI can show one combined
    /// message instead of a stack of alerts.
    static func allTransportsFailed(_ attempts: [(kind: DeviceTransportKind, error: NSError)]) -> NSError {
        guard !attempts.isEmpty else {
            return notConnected
        }

        let detail = attempts
            .map { "\($0.kind.title) (port \($0.kind.port)): \($0.error.localizedDescription)" }
            .joined(separator: "\n")

        // Surface the most specific code when only one transport was tried.
        let code = attempts.count == 1 ? attempts[0].error.code : -4

        return NSError(
            domain: domain,
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey: detail,
                transportAttemptsKey: attempts.map { $0.kind.rawValue }
            ]
        )
    }

    static let transportAttemptsKey = "StikDebugTransportAttempts"
}
