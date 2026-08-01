//
//  TransportProbe.swift
//  StikDebug
//
//  Read-only diagnostics for the on-device transport paths.
//
//  StikDebug reaches the device's own RSD endpoint through the LocalDevVPN
//  loopback reflector. There are two possible entry points:
//
//    * TCP 49152 — `remotepairingdeviced`, the RemotePairing listener Xcode uses
//      for "Connect via Network". iOS only brings this listener up while the
//      device is associated to a Wi-Fi network as a *client*.
//    * TCP 62078 — `lockdownd`, which historically binds at boot on the wildcard
//      address. If it answers without Wi-Fi, the CoreDeviceProxy transport can
//      reach RSD over cellular alone.
//
//  This probe answers which of those is actually reachable right now. It never
//  reports pairing file contents, paths, or device identifiers.
//

import Darwin
import Foundation
import idevice

enum ProbeOutcome: Equatable {
    case connected
    case refused
    case timedOut
    case invalidAddress
    case failed(Int32)

    var summary: String {
        switch self {
        case .connected: return "connected"
        case .refused: return "refused (61)"
        case .timedOut: return "timeout (60)"
        case .invalidAddress: return "invalid target address"
        case .failed(let code): return "errno \(code) (\(String(cString: strerror(code))))"
        }
    }

    /// A listener exists and completed the TCP handshake.
    var isReachable: Bool { self == .connected }
}

struct TransportProbeReport {
    struct PortResult {
        let port: UInt16
        let service: String
        let outcome: ProbeOutcome
    }

    let targetIP: String
    let ports: [PortResult]
    let interfaces: [String]
    let remotePairingRecordReadable: Bool
    let lockdownRecordReadable: Bool
    let pairingFilePresent: Bool

    /// True when a utun interface exists, i.e. LocalDevVPN (or another tunnel) is up.
    var hasTunnelInterface: Bool {
        interfaces.contains { $0.hasPrefix("utun") }
    }

    /// True when the device is associated to a Wi-Fi network as a client.
    /// Access-point mode (Personal Hotspot) surfaces as `ap1`/`bridge100` instead
    /// and deliberately does not count.
    var hasWiFiClientInterface: Bool {
        interfaces.contains { $0 == "en0" || $0 == "en1" }
    }

    var hasCellularInterface: Bool {
        interfaces.contains { $0.hasPrefix("pdp_ip") }
    }

    var hasAccessPointInterface: Bool {
        interfaces.contains { $0 == "ap1" || $0.hasPrefix("bridge") }
    }

    func outcome(forPort port: UInt16) -> ProbeOutcome? {
        ports.first { $0.port == port }?.outcome
    }

    var verdict: String {
        guard hasTunnelInterface else {
            return "No utun interface. LocalDevVPN is not connected — connect it before "
                + "interpreting anything below."
        }

        let remotePairing = outcome(forPort: TransportProbe.remotePairingPort)
        let lockdown = outcome(forPort: TransportProbe.lockdownPort)

        if remotePairing?.isReachable == true {
            return "RemotePairing (49152) is reachable. The classic transport works here."
        }
        if lockdown?.isReachable == true {
            return "RemotePairing (49152) is down, but lockdownd (62078) answers. "
                + "The CoreDeviceProxy transport can reach RSD on this network."
        }
        if hasCellularInterface && !hasWiFiClientInterface {
            return "Cellular only, and neither port answers. iOS starts developer network "
                + "services only while the device is a Wi-Fi client — join any Wi-Fi network "
                + "once to bring the tunnel up, then switch back."
        }
        return "Neither port answers. Check that LocalDevVPN targets \(targetIP) and that the "
            + "device is unlocked."
    }

    var text: String {
        var lines: [String] = []
        lines.append("Target: \(targetIP)")
        lines.append("")
        lines.append("Ports")
        for result in ports {
            lines.append("  \(result.port) (\(result.service)): \(result.outcome.summary)")
        }
        lines.append("")
        lines.append("Interfaces")
        lines.append("  \(interfaces.isEmpty ? "none" : interfaces.joined(separator: ", "))")
        lines.append("  Wi-Fi client: \(hasWiFiClientInterface ? "yes" : "no")")
        lines.append("  Cellular: \(hasCellularInterface ? "yes" : "no")")
        lines.append("  Access point mode: \(hasAccessPointInterface ? "yes" : "no")")
        lines.append("  Tunnel (utun): \(hasTunnelInterface ? "yes" : "no")")
        lines.append("")
        lines.append("Pairing record")
        if pairingFilePresent {
            lines.append("  RemotePairing reader: \(remotePairingRecordReadable ? "ok" : "failed")")
            lines.append("  Lockdown reader: \(lockdownRecordReadable ? "ok" : "failed")")
        } else {
            lines.append("  No pairing file imported")
        }
        lines.append("")
        lines.append("Verdict")
        lines.append("  \(verdict)")
        return lines.joined(separator: "\n")
    }
}

enum TransportProbe {
    static let remotePairingPort: UInt16 = 49152
    static let lockdownPort: UInt16 = 62078

    /// Runs the full probe. Blocking — call off the main thread.
    static func run(timeout: TimeInterval = 3) -> TransportProbeReport {
        let targetIP = DeviceConnectionContext.targetIPAddress

        let ports: [TransportProbeReport.PortResult] = [
            .init(
                port: remotePairingPort,
                service: "remotepairingdeviced",
                outcome: probe(host: targetIP, port: remotePairingPort, timeout: timeout)
            ),
            .init(
                port: lockdownPort,
                service: "lockdownd",
                outcome: probe(host: targetIP, port: lockdownPort, timeout: timeout)
            )
        ]

        let pairingURL = PairingFileStore.prepareURL()
        let pairingFilePresent = FileManager.default.fileExists(atPath: pairingURL.path)

        return TransportProbeReport(
            targetIP: targetIP,
            ports: ports,
            interfaces: activeInterfaceNames(),
            remotePairingRecordReadable: pairingFilePresent && canReadRemotePairingRecord(at: pairingURL.path),
            lockdownRecordReadable: pairingFilePresent && canReadLockdownRecord(at: pairingURL.path),
            pairingFilePresent: pairingFilePresent
        )
    }

    /// Non-blocking `connect()` plus `poll()`, so a black-holed SYN cannot hang the caller
    /// for the kernel's default TCP timeout.
    static func probe(host: String, port: UInt16, timeout: TimeInterval) -> ProbeOutcome {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian

        guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            return .invalidAddress
        }

        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            return classify(errno)
        }
        defer { close(descriptor) }

        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            return classify(errno)
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if connectResult == 0 {
            return .connected
        }

        let connectErrno = errno
        guard connectErrno == EINPROGRESS else {
            return classify(connectErrno)
        }

        var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&descriptorSet, 1, Int32(timeout * 1000))

        if pollResult == 0 {
            return .timedOut
        }
        if pollResult < 0 {
            return classify(errno)
        }

        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
            return classify(errno)
        }

        return socketError == 0 ? .connected : classify(socketError)
    }

    private static func classify(_ code: Int32) -> ProbeOutcome {
        switch code {
        case ECONNREFUSED: return .refused
        case ETIMEDOUT: return .timedOut
        default: return .failed(code)
        }
    }

    /// Interface names that currently carry an IPv4 or IPv6 address. Names only —
    /// no addresses, so nothing identifying leaves the device.
    static func activeInterfaceNames() -> [String] {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let first = addressList else {
            return []
        }
        defer { freeifaddrs(addressList) }

        var names: Set<String> = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addressPointer = entry.pointee.ifa_addr else { continue }
            let family = addressPointer.pointee.sa_family
            guard family == sa_family_t(AF_INET) || family == sa_family_t(AF_INET6) else { continue }
            names.insert(String(cString: entry.pointee.ifa_name))
        }
        return names.sorted()
    }

    private static func canReadRemotePairingRecord(at path: String) -> Bool {
        var handle: OpaquePointer?
        let ffiError = path.withCString { rp_pairing_file_read($0, &handle) }
        if let ffiError {
            idevice_error_free(ffiError)
            return false
        }
        rp_pairing_file_free(handle)
        return true
    }

    private static func canReadLockdownRecord(at path: String) -> Bool {
        var handle: OpaquePointer?
        let ffiError = path.withCString { idevice_pairing_file_read($0, &handle) }
        if let ffiError {
            idevice_error_free(ffiError)
            return false
        }
        idevice_pairing_file_free(handle)
        return true
    }
}
