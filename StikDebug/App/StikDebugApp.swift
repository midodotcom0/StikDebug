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
    @StateObject private var coordinator = ConnectionCoordinator.shared
    @AppStorage(UserDefaults.Keys.autoConnectOnLaunch) private var autoConnectOnLaunch = true

    init() {
        AppBootstrapper.configure()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(coordinator)
                .task {
                    await downloadMissingDeveloperDiskImageFiles()
                    await connectOnLaunchIfEnabled()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    handleScenePhaseChange(newPhase)
                }
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        // The RSD session is sticky and survives backgrounding, so returning to the
        // foreground no longer tears it down and rebuilds it. Reconnecting here was
        // one of the two paths that raced to present an alert at launch.
        guard newPhase == .active else { return }
        MountingProgress.shared.checkforMounted()
    }

    @MainActor
    private func connectOnLaunchIfEnabled() async {
        guard autoConnectOnLaunch else { return }
        // Background attempt: failures land in the status banner and the log, never
        // in a dialog. Tools and Location Simulation stay reachable regardless.
        try? await coordinator.ensureReady(.tunnelOnly, userInitiated: false)
    }

    @MainActor
    private func downloadMissingDeveloperDiskImageFiles() async {
        do {
            try await DeveloperDiskImageService.shared.downloadMissingFiles()
        } catch {
            // Downloading is not mounting. Mounting happens only after a tunnel is up,
            // and only when something actually needs the image.
            coordinator.report(
                stage: .mount,
                title: "Developer Image Download Failed",
                message: error.localizedDescription,
                userInitiated: false
            )
        }
    }
}
