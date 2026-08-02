//
//  StikDebugApp.swift
//  StikDebug
//
//  Created by Stephen on 3/26/25.
//

import SwiftUI

@main
struct StikDebugApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var shouldAttemptTunnelReconnect = false

    init() {
        AppBootstrapper.configure()
        // The on-device VPN uses the isolated synthetic peer address. Older
        // builds stored the physical hotspot gateway, which always resets or
        // times out; migrate those values automatically.
        let key = UserDefaults.Keys.targetDeviceIP
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        if stored.isEmpty || stored.hasPrefix("172.") || stored == "10.7.0.0" {
            UserDefaults.standard.set(DeviceConnectionContext.defaultTargetIPAddress, forKey: key)
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .task {
                    await downloadMissingDeveloperDiskImageFiles()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    handleScenePhaseChange(newPhase)
                }
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            shouldAttemptTunnelReconnect = true
        case .active:
            if shouldAttemptTunnelReconnect {
                shouldAttemptTunnelReconnect = false
                startTunnelInBackground(showErrorUI: false)
            }
        default:
            break
        }
    }

    private func downloadMissingDeveloperDiskImageFiles() async {
        do {
            try await DeveloperDiskImageService.shared.downloadMissingFiles()
            // Mounting requires a live tunnel. Trying it unconditionally at
            // launch produces a second alert on top of the connection failure.
            if TunnelManager.shared.isConnected {
                MountingProgress.shared.pubMount()
            }
        } catch {
            await MainActor.run {
                showAlert(
                    title: "An Error has Occurred",
                    message: "[Download DDI Error]: \(error.localizedDescription)",
                    showOk: true
                )
            }
        }
    }
}
