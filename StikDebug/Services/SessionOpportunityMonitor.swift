//
//  SessionOpportunityMonitor.swift
//  StikDebug
//
//  Takes the Wi-Fi window automatically.
//
//  If the device's developer services really do require a Wi-Fi client association,
//  then the moment the device joins a network is the only moment a session can be
//  created. That window is often short and easy to miss — the user walks past their
//  home network, or joins one for a minute.
//
//  So rather than asking the user to notice it, this watches for the transition into
//  Wi-Fi and immediately builds the full session, image mount included. Because the
//  session is sticky and the whole path is device-local, it then keeps working after
//  the device drops back to cellular.
//
//  This is not a retry loop. Retrying on cellular cannot succeed and only burns
//  battery; this fires on the one edge that can.
//

import Foundation
import Network

final class SessionOpportunityMonitor {
    static let shared = SessionOpportunityMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.stik.session-opportunity")
    private let stateLock = NSLock()
    private var started = false
    private var hadWiFi = false

    private init() {}

    func start() {
        stateLock.lock()
        guard !started else {
            stateLock.unlock()
            return
        }
        started = true
        stateLock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path)
        }
        monitor.start(queue: queue)
    }

    private func handle(_ path: NWPath) {
        let hasWiFi = path.availableInterfaces.contains { $0.type == .wifi }

        stateLock.lock()
        let wasWiFi = hadWiFi
        hadWiFi = hasWiFi
        stateLock.unlock()

        // Only the rising edge matters. Losing Wi-Fi is not a reason to do anything:
        // an established session survives it.
        guard hasWiFi, !wasWiFi else { return }

        guard !DeviceTransport.shared.isConnected || !MountingProgress.shared.coolisMounted else {
            return
        }

        LogManager.shared.addInfoLog("Wi-Fi became available — claiming a device session while it lasts")
        ConnectionCoordinator.shared.ensureReadyInBackground(.tunnelAndDDI)
    }
}
