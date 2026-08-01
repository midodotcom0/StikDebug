//
//  LocalLinkActivator.swift
//  StikDebug
//
//  Brings up a peer-to-peer local link without joining any network.
//
//  Reasoning behind this:
//
//  The observed rule is "developer network services only start while the device is a
//  Wi-Fi client". But that is an inference from two data points — Wi-Fi works,
//  cellular does not. The condition iOS actually needs is more likely "a local link
//  that carries mDNS peer discovery exists". Wi-Fi infrastructure is one such link.
//  It is not the only one.
//
//  AWDL (`awdl0`) is the peer-to-peer Wi-Fi link behind AirDrop, AirPlay and Handoff.
//  It is a real link-local interface, it carries mDNS, and crucially it needs no
//  router, no SSID and no internet — only that the Wi-Fi radio is powered on. iOS
//  brings it up on demand for any app that opens a peer-to-peer Bonjour listener or
//  browser.
//
//  So if the gate is "local link present" rather than specifically "en0 associated to
//  an access point", an app can satisfy it by itself, on cellular, with no second
//  device and no private API. That is a hypothesis, not a fact — which is why this is
//  wired into the diagnostics screen as a toggle you can measure rather than as
//  silent behaviour.
//
//  Note that this needs `NSLocalNetworkUsageDescription` in Info.plist. Without it
//  iOS denies local network access outright and none of the above can happen.
//

import Foundation
import Network

final class LocalLinkActivator: ObservableObject {
    static let shared = LocalLinkActivator()

    /// Reuses the service type already declared under `NSBonjourServices`.
    private static let serviceType = "_stikdebug._tcp"

    @Published private(set) var isActive = false
    @Published private(set) var lastError: String?

    private let queue = DispatchQueue(label: "com.stik.local-link")
    private var listener: NWListener?
    private var browser: NWBrowser?

    private init() {}

    /// True once a peer-to-peer capable interface is visible.
    var hasPeerToPeerInterface: Bool {
        TransportProbe.activeInterfaceNames().contains { $0.hasPrefix("awdl") || $0.hasPrefix("llw") }
    }

    func start() {
        guard !isActive else { return }

        publish {
            self.lastError = nil
            self.isActive = true
        }

        startListener()
        startBrowser()

        LogManager.shared.addInfoLog("Local link activation requested (peer-to-peer Bonjour)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil

        publish { self.isActive = false }
        LogManager.shared.addInfoLog("Local link activation stopped")
    }

    // MARK: - Private

    /// Advertising alone tends to be lazy, so this pairs with a browser. Together they
    /// are what actually forces the radio to bring the peer-to-peer link up.
    private func startListener() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true

        do {
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: "StikDebug", type: Self.serviceType)

            // Nothing is meant to connect. The link is the point, not the traffic.
            listener.newConnectionHandler = { connection in
                connection.cancel()
            }

            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.handle(error, source: "listener")
                }
            }

            listener.start(queue: queue)
            self.listener = listener
        } catch {
            handle(error, source: "listener")
        }
    }

    private func startBrowser() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: nil),
            using: parameters
        )

        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.handle(error, source: "browser")
            }
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    private func handle(_ error: Error, source: String) {
        let message = "Local link \(source) failed: \(error.localizedDescription)"
        LogManager.shared.addWarningLog(message)
        publish {
            self.lastError = message
            self.isActive = false
        }
    }

    private func publish(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
