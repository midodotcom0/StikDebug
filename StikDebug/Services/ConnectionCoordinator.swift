//
//  ConnectionCoordinator.swift
//  StikDebug
//
//  The single owner of tunnel setup and Developer Disk Image mounting.
//
//  Previously these ran as two independent code paths that each presented their own
//  global UIAlertController on failure. Both fired in the same runloop turn on a
//  failed launch, stacking "Connection Error" on top of "DDI Mount Failed" and making
//  the app look frozen until the user dismissed both.
//
//  Here the two steps are one ordered sequence. Mounting is not guarded against a
//  failed tunnel — it is unreachable after one, because the sequence returns first.
//  At most one failure exists at a time, and only user-initiated work is allowed to
//  raise an alert; background attempts stay silent in the status banner.
//

import Foundation
import SwiftUI

final class ConnectionCoordinator: ObservableObject {
    static let shared = ConnectionCoordinator()

    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case mounting
        case ready
        case failed

        var isBusy: Bool {
            self == .connecting || self == .mounting
        }
    }

    /// What a caller actually needs. Location simulation and JIT need the DDI;
    /// listing apps only needs the tunnel.
    enum Requirement {
        case tunnelOnly
        case tunnelAndDDI
    }

    struct Failure: Identifiable, Equatable {
        enum Stage: String {
            case pairing
            case tunnel
            case mount
        }

        let id = UUID()
        let stage: Stage
        let title: String
        let message: String

        static func == (lhs: Failure, rhs: Failure) -> Bool {
            lhs.stage == rhs.stage && lhs.title == rhs.title && lhs.message == rhs.message
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var activeTransport: DeviceTransportKind?
    /// The one current problem. Views bind this with `.alert(item:)`.
    @Published var failure: Failure?

    private let lock = NSLock()
    private var runningTask: Task<Void, Error>?
    /// Survives the end of an attempt so "Try Again" retries what the user actually
    /// wanted rather than a weaker default.
    private var lastRequirement: Requirement = .tunnelOnly
    private let cancellation = CancellationFlag()

    private init() {}

    var isConnected: Bool {
        DeviceTransport.shared.isConnected
    }

    var statusText: String {
        switch phase {
        case .idle:
            return DeviceTransport.shared.isConnected ? "Connected" : "Not connected"
        case .connecting:
            return "Connecting…"
        case .connected:
            return activeTransport.map { "Connected via \($0.title)" } ?? "Connected"
        case .mounting:
            let progress = MountingProgress.shared.mountProgress
            return progress > 0 ? "Mounting image \(Int(progress))%" : "Mounting image…"
        case .ready:
            return activeTransport.map { "Ready via \($0.title)" } ?? "Ready"
        case .failed:
            return failure?.title ?? "Connection failed"
        }
    }

    // MARK: - Entry point

    /// Brings the connection up to `requirement`, reusing any in-flight attempt.
    ///
    /// `userInitiated` decides how a failure surfaces: `true` raises the alert views
    /// are bound to, `false` only records it in the banner and the log. A failed
    /// launch must never interrupt navigation.
    func ensureReady(_ requirement: Requirement, userInitiated: Bool) async throws {
        if satisfies(requirement) {
            publishPhase(requirement == .tunnelAndDDI ? .ready : .connected)
            return
        }

        // Join an attempt that is already running rather than starting a second one.
        lock.lock()
        let existing = runningTask
        lock.unlock()

        if let existing {
            _ = try? await existing.value
            if satisfies(requirement) {
                publishPhase(requirement == .tunnelAndDDI ? .ready : .connected)
                return
            }
        }

        cancellation.reset()
        publishFailure(nil)

        lock.lock()
        lastRequirement = requirement
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.perform(requirement, userInitiated: userInitiated)
        }
        runningTask = task
        lock.unlock()

        defer {
            lock.lock()
            if runningTask == task {
                runningTask = nil
            }
            lock.unlock()
        }

        try await task.value
    }

    /// Fire-and-forget variant for launch and other background triggers.
    func ensureReadyInBackground(_ requirement: Requirement) {
        Task { try? await ensureReady(requirement, userInitiated: false) }
    }

    /// Aborts the current attempt. Takes effect at the next transport boundary —
    /// an in-flight FFI connect cannot be interrupted mid-handshake.
    func cancel() {
        cancellation.cancel()

        lock.lock()
        let task = runningTask
        runningTask = nil
        lock.unlock()

        task?.cancel()

        publish {
            if self.phase.isBusy {
                self.phase = DeviceTransport.shared.isConnected ? .connected : .idle
            }
        }
    }

    func retry() {
        lock.lock()
        let requirement = lastRequirement
        lock.unlock()

        publishFailure(nil)
        Task { try? await ensureReady(requirement, userInitiated: true) }
    }

    /// Drops the session so the next request rebuilds it. Used when the pairing file
    /// changes or the VPN goes away.
    func invalidate() {
        DeviceTransport.shared.invalidate()
        publish {
            self.activeTransport = nil
            self.phase = .idle
        }
    }

    /// Records a problem raised outside the connect/mount sequence, such as the DDI
    /// download failing. Never stacks on top of an existing failure.
    func report(stage: Failure.Stage, title: String, message: String, userInitiated: Bool) {
        LogManager.shared.addErrorLog("\(title): \(message)")
        guard userInitiated else { return }
        publish {
            guard self.failure == nil else { return }
            self.failure = Failure(stage: stage, title: title, message: message)
        }
    }

    // MARK: - Sequence

    private func satisfies(_ requirement: Requirement) -> Bool {
        guard DeviceTransport.shared.isConnected else { return false }
        switch requirement {
        case .tunnelOnly:
            return true
        case .tunnelAndDDI:
            return MountingProgress.shared.coolisMounted
        }
    }

    private func perform(_ requirement: Requirement, userInitiated: Bool) async throws {
        publishPhase(.connecting)

        do {
            let kind = try await connectTunnel()
            publish {
                self.activeTransport = kind
                self.phase = .connected
            }
        } catch {
            // Everything below is unreachable after a tunnel failure, so no mount can
            // follow one and no second dialog can appear.
            publishPhase(.failed)
            raise(tunnelFailure(from: error as NSError), userInitiated: userInitiated)
            throw error
        }

        guard requirement == .tunnelAndDDI else { return }

        do {
            publishPhase(.mounting)
            try await MountingProgress.shared.mountIfNeeded()
            publishPhase(.ready)
        } catch {
            publishPhase(.failed)
            raise(mountFailure(from: error), userInitiated: userInitiated)
            throw error
        }
    }

    private func connectTunnel() async throws -> DeviceTransportKind {
        let flag = cancellation
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let kind = try DeviceTransport.shared.connectIfNeeded(
                        isCancelled: { flag.isCancelled }
                    )
                    continuation.resume(returning: kind)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func raise(_ entry: Failure, userInitiated: Bool) {
        LogManager.shared.addErrorLog("\(entry.title): \(entry.message)")
        guard userInitiated else { return }
        publish {
            // One at a time. Queuing a second would recreate the stacked-dialog bug.
            guard self.failure == nil else { return }
            self.failure = entry
        }
    }

    // MARK: - Publishing

    private func publishPhase(_ newPhase: Phase) {
        publish { self.phase = newPhase }
    }

    private func publishFailure(_ newFailure: Failure?) {
        publish { self.failure = newFailure }
    }

    private func publish(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - Failure text

    private func tunnelFailure(from error: NSError) -> Failure {
        if error.domain == TransportError.domain, error.code == -999 {
            return Failure(
                stage: .tunnel,
                title: "Connection Cancelled",
                message: "The connection attempt was cancelled."
            )
        }

        if error.domain == TransportError.domain, error.code == -17 {
            return Failure(
                stage: .pairing,
                title: "Pairing File Required",
                message: "Import a pairing file before connecting to the device."
            )
        }

        return Failure(
            stage: .tunnel,
            title: "Connection Error",
            message: ConnectionDiagnostics.explain(error)
        )
    }

    private func mountFailure(from error: Error) -> Failure {
        Failure(
            stage: .mount,
            title: "Developer Image Not Mounted",
            message: """
            \(error.localizedDescription)

            The device is connected, but the Developer Disk Image could not be mounted. \
            Make sure the device is unlocked and Developer Mode is enabled, then try again.
            """
        )
    }
}

/// Minimal thread-safe box for handing a value back out of a `Task` to a caller that
/// is waiting on a semaphore rather than awaiting.
final class ResultBox {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

/// Thread-safe cancellation signal that a blocking FFI worker can poll.
/// `Task.isCancelled` is unavailable inside a plain `DispatchQueue` block, so the
/// coordinator carries this instead.
final class CancellationFlag {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }
}
