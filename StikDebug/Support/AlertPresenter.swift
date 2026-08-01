//
//  AlertPresenter.swift
//  StikDebug
//

import UIKit

/// Serialised presenter for the few places that still raise a global alert.
///
/// The previous implementation dispatched to the main queue, looked up the top view
/// controller and presented immediately. Two failures arriving in the same runloop
/// turn — the classic case being a failed tunnel plus a failed DDI mount at launch —
/// both resolved the same top controller and both called `present`, stacking two
/// dialogs and requiring two dismissals before the UI responded again.
///
/// Now only one alert is on screen at a time. Anything that arrives while one is up
/// is folded into a single follow-up alert rather than queued as another dialog, and
/// repeats of the same message are dropped outright.
///
/// New code should prefer a SwiftUI `.alert` bound to view state. This stays as the
/// safety net for call sites that have no view context.
enum AlertPresenter {
    private struct Request {
        let title: String
        let message: String
        let showOk: Bool
        let showTryAgain: Bool
        let primaryButtonText: String?
        let completion: ((Bool) -> Void)?
    }

    /// All state is touched on the main queue only.
    private static var isPresenting = false
    private static var pending: [Request] = []
    private static var recentSignatures: [String: Date] = [:]

    private static let duplicateWindow: TimeInterval = 5
    private static let retryDelay: TimeInterval = 0.3

    static func show(
        title: String,
        message: String,
        showOk: Bool,
        showTryAgain: Bool = false,
        primaryButtonText: String? = nil,
        completion: ((Bool) -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            let signature = "\(title)\u{1}\(message)"
            let now = Date()
            recentSignatures = recentSignatures.filter { now.timeIntervalSince($0.value) < duplicateWindow }

            if recentSignatures[signature] != nil {
                LogManager.shared.addDebugLog("Suppressed duplicate alert: \(title)")
                completion?(false)
                return
            }
            recentSignatures[signature] = now

            pending.append(
                Request(
                    title: title,
                    message: message,
                    showOk: showOk,
                    showTryAgain: showTryAgain,
                    primaryButtonText: primaryButtonText,
                    completion: completion
                )
            )
            presentNextIfIdle()
        }
    }

    static func dismissPresentedAlert() {
        DispatchQueue.main.async {
            pending.removeAll()
            recentSignatures.removeAll()

            guard let rootViewController = UIApplication.shared.activeRootViewController,
                  let topController = UIApplication.shared.topViewController(from: rootViewController),
                  topController is UIAlertController else {
                return
            }
            topController.dismiss(animated: true) {
                isPresenting = false
            }
        }
    }

    private static func presentNextIfIdle() {
        guard !isPresenting, !pending.isEmpty else { return }

        guard let rootViewController = UIApplication.shared.activeRootViewController,
              let topController = UIApplication.shared.topViewController(from: rootViewController) else {
            // The scene is not ready yet — try again shortly rather than dropping it.
            scheduleRetry()
            return
        }

        // Never present on top of an alert, including one we did not create.
        if topController is UIAlertController {
            scheduleRetry()
            return
        }

        let batch = pending
        pending.removeAll()
        isPresenting = true

        let alert = batch.count == 1
            ? makeAlert(for: batch[0])
            : makeCombinedAlert(for: batch)

        topController.present(alert, animated: true)
    }

    private static func scheduleRetry() {
        DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) {
            presentNextIfIdle()
        }
    }

    private static func finish(_ completion: ((Bool) -> Void)?, _ value: Bool) {
        isPresenting = false
        completion?(value)
        presentNextIfIdle()
    }

    private static func makeAlert(for request: Request) -> UIAlertController {
        let alert = UIAlertController(
            title: request.title,
            message: request.message,
            preferredStyle: .alert
        )

        if request.showTryAgain {
            alert.addAction(
                UIAlertAction(title: request.primaryButtonText ?? "Try Again", style: .default) { _ in
                    finish(request.completion, true)
                }
            )
            alert.addAction(
                UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    finish(request.completion, false)
                }
            )
        } else {
            alert.addAction(
                UIAlertAction(title: request.showOk ? (request.primaryButtonText ?? "OK") : "OK", style: .default) { _ in
                    finish(request.completion, true)
                }
            )
        }

        return alert
    }

    /// Folds everything that piled up into one dialog. The user dismisses once and
    /// sees every problem, instead of dismissing a stack one layer at a time.
    private static func makeCombinedAlert(for batch: [Request]) -> UIAlertController {
        let body = batch
            .map { "• \($0.title)\n\($0.message)" }
            .joined(separator: "\n\n")

        let alert = UIAlertController(
            title: "\(batch.count) Issues",
            message: body,
            preferredStyle: .alert
        )

        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            isPresenting = false
            for request in batch {
                request.completion?(false)
            }
            presentNextIfIdle()
        })

        return alert
    }
}

public func showAlert(
    title: String,
    message: String,
    showOk: Bool,
    showTryAgain: Bool = false,
    primaryButtonText: String? = nil,
    completion: ((Bool) -> Void)? = nil
) {
    AlertPresenter.show(
        title: title,
        message: message,
        showOk: showOk,
        showTryAgain: showTryAgain,
        primaryButtonText: primaryButtonText,
        completion: completion
    )
}

private extension UIApplication {
    var activeRootViewController: UIViewController? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    }

    func topViewController(from rootViewController: UIViewController) -> UIViewController? {
        var topController: UIViewController? = rootViewController
        while let presented = topController?.presentedViewController {
            topController = presented
        }
        return topController
    }
}
