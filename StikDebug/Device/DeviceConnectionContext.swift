//
//  DeviceConnectionContext.swift
//  StikDebug
//
//  Created by Stephen.
//

import Foundation

enum DeviceConnectionContext {
    // LocalDevVPN exposes the phone's remote-pairing service through the
    // synthetic peer at .0; .1 is the Mac/tunnel interface and times out.
    static let defaultTargetIPAddress = "10.7.0.0"

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
