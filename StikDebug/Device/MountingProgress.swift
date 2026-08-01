//
//  MountingProgress.swift
//  StikDebug
//

import Foundation
import idevice

/// Tracks Developer Disk Image mount state and progress.
///
/// This type deliberately presents no UI of its own. Mount failures are thrown to
/// `ConnectionCoordinator`, which is the single owner of connection and mount state
/// and the only place that decides whether the user sees anything.
final class MountingProgress: ObservableObject {
    static let shared = MountingProgress()

    @Published private(set) var mountProgress: Double = 0.0
    @Published private(set) var isMounting: Bool = false
    @Published private(set) var coolisMounted: Bool = false

    private let stateLock = NSLock()
    private var mountInFlight = false

    private init() {}

    func checkforMounted() {
        DispatchQueue.global(qos: .utility).async {
            let mounted = isMounted()
            self.publish { self.coolisMounted = mounted }
        }
    }

    func progressCallback(progress: size_t, total: size_t, context: UnsafeMutableRawPointer?) {
        guard total > 0 else { return }
        let percentage = Double(progress) / Double(total) * 100.0
        publish { self.mountProgress = percentage }
    }

    /// Mounts the personalized DDI unless it is already mounted.
    ///
    /// Requires a live RSD session — callers must establish the tunnel first. Throws
    /// on failure so the caller can fold tunnel and mount problems into one report.
    func mountIfNeeded() async throws {
        stateLock.lock()
        if mountInFlight {
            stateLock.unlock()
            return
        }
        mountInFlight = true
        stateLock.unlock()

        defer {
            stateLock.lock()
            mountInFlight = false
            stateLock.unlock()
            publish { self.isMounting = false }
        }

        let alreadyMounted = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: isMounted())
            }
        }

        publish { self.coolisMounted = alreadyMounted }
        if alreadyMounted { return }

        guard isPairing() else {
            throw MountError.pairingFileUnreadable
        }

        let imagePath = URL.documentsDirectory.appendingPathComponent("DDI/Image.dmg").path
        let trustcachePath = URL.documentsDirectory.appendingPathComponent("DDI/Image.dmg.trustcache").path
        let manifestPath = URL.documentsDirectory.appendingPathComponent("DDI/BuildManifest.plist").path

        guard FileManager.default.fileExists(atPath: trustcachePath) else {
            throw MountError.imageMissing
        }

        publish {
            self.isMounting = true
            self.mountProgress = 0
        }

        let failureMessage: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = mountPersonalDDI(
                    imagePath: imagePath,
                    trustcachePath: trustcachePath,
                    manifestPath: manifestPath
                )
                continuation.resume(returning: result)
            }
        }

        if let failureMessage {
            throw MountError.mountFailed(failureMessage)
        }

        publish { self.coolisMounted = true }
        checkforMounted()
    }

    private func publish(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

enum MountError: LocalizedError {
    case pairingFileUnreadable
    case imageMissing
    case mountFailed(String)

    var errorDescription: String? {
        switch self {
        case .pairingFileUnreadable:
            return "The pairing file could not be read, so the Developer Disk Image cannot be mounted."
        case .imageMissing:
            return "The Developer Disk Image has not finished downloading yet."
        case .mountFailed(let message):
            return message
        }
    }
}

func isPairing() -> Bool {
    let pairingPath = PairingFileStore.prepareURL().path
    var pairingFile: RpPairingFileHandle?
    let error = rp_pairing_file_read(pairingPath, &pairingFile)
    if error != nil {
        return false
    }
    rp_pairing_file_free(pairingFile)
    return true
}
