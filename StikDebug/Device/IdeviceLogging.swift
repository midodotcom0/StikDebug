//
//  IdeviceLogging.swift
//  StikDebug
//
//  Turns on the idevice library's own logging.
//
//  This used to live in `JITEnableContext.init`, which worked only because every
//  path into the FFI went through that class. `DeviceTransport` now calls the
//  library directly, so a connection could be attempted without the logger ever
//  being installed — leaving `idevice_log.txt` empty exactly when something went
//  wrong and the log was needed. Installing it from `AppBootstrapper` instead
//  makes it independent of which code path runs first.
//

import Foundation
import idevice

enum IdeviceLogging {
    private static let lock = NSLock()
    private static var started = false

    /// Safe to call repeatedly and from anywhere; only the first call takes effect.
    static func startIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true

        let logURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("idevice_log.txt")

        var path = Array(logURL.path.utf8CString)
        path.withUnsafeMutableBufferPointer { buffer in
            _ = idevice_init_logger(Info, Debug, buffer.baseAddress)
        }
    }
}
