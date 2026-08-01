//
//  TunnelManager.swift
//  StikDebug
//

import Foundation

/// Compatibility facade over `DeviceTransport` and `ConnectionCoordinator`.
///
/// Connection state now lives in `DeviceTransport` and the connect/mount sequence in
/// `ConnectionCoordinator`. This type stays because several call sites read
/// `isConnected` or ask for a background reconnect; it no longer presents any UI and
/// no longer triggers the DDI mount, which is what used to produce a second alert on
/// top of the first.
final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    private init() {}

    var isConnected: Bool {
        DeviceTransport.shared.isConnected
    }

    var activeTransport: DeviceTransportKind? {
        DeviceTransport.shared.activeKind
    }

    func markDisconnected() {
        ConnectionCoordinator.shared.invalidate()
    }

    func start(showErrorUI: Bool = true) {
        Task {
            try? await ConnectionCoordinator.shared.ensureReady(.tunnelOnly, userInitiated: showErrorUI)
        }
    }
}

func startTunnelInBackground(showErrorUI: Bool = true) {
    TunnelManager.shared.start(showErrorUI: showErrorUI)
}

func markTunnelDisconnected() {
    TunnelManager.shared.markDisconnected()
}

/// Turns a transport error into something a person can act on.
///
/// The transport layer reports one combined error when every path failed, so this
/// produces a single message covering all of them instead of one alert per attempt.
enum ConnectionDiagnostics {
    static func explain(_ error: NSError) -> String {
        let targetIP = DeviceConnectionContext.targetIPAddress
        let rawMessage = error.localizedDescription
        let lowercased = rawMessage.lowercased()

        let likelyCause: String
        var recoverySteps: [String]

        if lowercased.contains("connection refused") || error.code == 61 {
            likelyCause = """
            The device answered but nothing is listening on the developer port.

            iOS only starts its developer network services while the device is joined \
            to a Wi-Fi network as a client. Cellular alone does not start them, and \
            neither does Personal Hotspot — in hotspot mode the Wi-Fi chip runs as an \
            access point, which is not the same thing.
            """
            recoverySteps = [
                "Join any Wi-Fi network — it does not need internet access.",
                "Once connected, the session stays alive if you switch back to cellular.",
                "If you are already on Wi-Fi, unlock the device and try again."
            ]
        } else if lowercased.contains("timed out") || lowercased.contains("timeout") || error.code == 60 {
            likelyCause = "No reply from \(targetIP). The route to the device is missing."
            recoverySteps = [
                "Open LocalDevVPN and confirm the VPN is connected.",
                "Confirm LocalDevVPN exposes the device at \(DeviceConnectionContext.defaultTargetIPAddress).",
                "Reconnect the VPN, then try again."
            ]
        } else if lowercased.contains("network is unreachable") || lowercased.contains("no route") {
            likelyCause = "The VPN route to the device is not available."
            recoverySteps = [
                "Disconnect and reconnect LocalDevVPN.",
                "Confirm iOS shows the VPN indicator.",
                "Try switching Wi-Fi off and on."
            ]
        } else if error.code == 48 || lowercased.contains("address already in use") {
            likelyCause = "A port needed for the tunnel is already in use."
            recoverySteps = [
                "Close other JIT, debugging, proxy, or VPN apps.",
                "Disconnect and reconnect LocalDevVPN.",
                "Reboot the device if it keeps happening."
            ]
        } else if error.code == 54 || lowercased.contains("connection reset") {
            likelyCause = "The device closed the connection before setup finished."
            recoverySteps = [
                "Unlock the device and try again.",
                "Reconnect LocalDevVPN.",
                "If this keeps happening, import a fresh pairing file."
            ]
        } else if error.code == -18 || lowercased.contains("valid ipv4") {
            likelyCause = "The configured target IP address is not valid."
            recoverySteps = [
                "Open Settings and check the target IP address.",
                "Use the default \(DeviceConnectionContext.defaultTargetIPAddress)."
            ]
        } else if lowercased.contains("lockdown pair record") {
            likelyCause = """
            The pairing file works for the Wi-Fi transport but is not a lockdown pair \
            record, so the cellular-capable transport cannot use it.
            """
            recoverySteps = [
                "Re-create the pairing file with the device connected over USB.",
                "Import it again under Settings."
            ]
        } else {
            likelyCause = "The tunnel could not be created."
            recoverySteps = [
                "Confirm LocalDevVPN is connected.",
                "Unlock the device.",
                "Try again."
            ]
        }

        let steps = recoverySteps.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        return """
        \(likelyCause)

        Try this:
        \(steps)

        Technical details
        Target: \(targetIP)
        \(rawMessage)
        """
    }
}
