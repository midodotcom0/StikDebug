//
//  DeviceConnectionContext.swift
//  StikDebug
//
//  Created by Stephen.
//

import Foundation

enum DeviceConnectionContext {
    // LocalDevVPN exposes the synthetic peer at .1 and rewrites it to the
    // device-side .0 inside the packet tunnel.
    static let defaultTargetIPAddress = "10.7.0.1"

    static var targetIPAddress: String {
        let stored = UserDefaults.standard
            .string(forKey: UserDefaults.Keys.targetDeviceIP)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let stored, !stored.isEmpty else {
            return defaultTargetIPAddress
        }
        return stored
    }
}
