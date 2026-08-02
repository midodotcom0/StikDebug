//
//  UserDefaults+Keys.swift
//  StikDebug
//

import Foundation

extension UserDefaults {
    enum Keys {
        /// Forces the app to treat the current device as TXM-capable so scripts always run.
        static let txmOverride = "overrideTXMForScripts"
        /// Requires confirmation before external links can enable JIT.
        static let confirmExternalJITRequests = "confirmExternalJITRequests"
        static let bundleScriptMap = "BundleScriptMap"
        static let defaultScriptName = "DefaultScriptName"
        static let defaultScriptNameValue = ""
        static let targetDeviceIP = "TunnelDeviceIP"
        /// Pins a single `DeviceTransportKind` instead of trying both. Absent means auto.
        static let transportOverride = "DeviceTransportOverride"
        /// Remembers which transport last worked so it is tried first next time.
        static let lastSuccessfulTransport = "LastSuccessfulDeviceTransport"
        /// Connects the tunnel on launch. Off means the connection is built the first
        /// time a feature actually needs it.
        static let autoConnectOnLaunch = "autoConnectOnLaunch"
        /// Which local address the RemotePairing connection originates from.
        /// Anything but the system default routes through the loopback relay.
        static let pairingSourcePolicy = "PairingSourcePolicy"
    }
}
