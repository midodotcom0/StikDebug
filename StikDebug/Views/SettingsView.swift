//  SettingsView.swift
//  StikDebug
//
//  Created by Stephen on 3/27/25.

import SwiftUI
import UIKit

private enum SettingsLinks {
    static let githubStars = URL(string: "https://github.com/StephenDev0/StikDebug/stargazers")!
    static let pairingFileGuide = URL(string: "https://github.com/StephenDev0/StikDebug-Guide/blob/main/pairing_file.md")!
    static let localDevVPN = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
    static let discord = URL(string: "https://discord.gg/qahjXNTDwS")!
}

struct SettingsView: View {
    @AppStorage(UserDefaults.Keys.txmOverride) private var overrideTXMDetection = false
    @AppStorage(UserDefaults.Keys.confirmExternalJITRequests) private var confirmExternalJITRequests = true
    @AppStorage("keepAliveAudio") private var keepAliveAudio = true
    @AppStorage("keepAliveLocation") private var keepAliveLocation = true
    @AppStorage(UserDefaults.Keys.targetDeviceIP) private var targetDeviceIP = DeviceConnectionContext.defaultTargetIPAddress

    @State private var isShowingPairingFilePicker = false
    @State private var isImportingFile = false
    @State private var pairingImportMessage: (text: String, isError: Bool)?
    @State private var showDDIConfirmation = false
    @State private var isRedownloadingDDI = false
    @State private var ddiDownloadProgress: Double = 0.0
    @State private var ddiStatusMessage: String = ""
    @State private var ddiResultMessage: (text: String, isError: Bool)?
    @StateObject private var lockdownProbe = LockdownReachabilityProbe()
    @StateObject private var remotePairingDiscovery = RemotePairingDiscoveryProbe()

    private var appVersion: String {
        let marketingVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return marketingVersion
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 12) {
                            Image("StikDebug")
                                .resizable().aspectRatio(contentMode: .fit)
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            Text("StikDebug").font(.title2.weight(.semibold))
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 8)
                }

                Section {
                    Link(destination: SettingsLinks.githubStars) {
                        Label("Star on GitHub", systemImage: "star")
                    }
                }

                Section("Pairing File") {
                    Button {
                        isShowingPairingFilePicker = true
                    } label: {
                        Label("Import Pairing File", systemImage: "doc.badge.plus")
                    }
                    .disabled(isImportingFile)

                    if isImportingFile {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Importing pairing file…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if let pairingImportMessage {
                        Label(
                            pairingImportMessage.text,
                            systemImage: pairingImportMessage.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(pairingImportMessage.isError ? .red : .green)
                    }
                }

                Section {
                    Toggle(isOn: $keepAliveAudio) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Silent Audio")
                            Text("Plays inaudible audio so iOS keeps the app running.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveAudio) { _, enabled in
                        if enabled { BackgroundAudioManager.shared.start() }
                        else { BackgroundAudioManager.shared.stop() }
                    }

                    Toggle(isOn: $keepAliveLocation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Background Location")
                            Text("Uses low-accuracy location to stay alive when an activity needs it.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveLocation) { _, enabled in
                        if !enabled { BackgroundLocationManager.shared.stop() }
                    }

                } header: {
                    Text("Background Keep-Alive")
                }

                Section("Behavior") {
                    Toggle(isOn: $confirmExternalJITRequests) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Confirm JIT Links")
                            Text("Ask before external links enable JIT or run scripts.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: $overrideTXMDetection) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Always Run Scripts")
                            Text("Treats device as TXM-capable to bypass hardware checks.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Advanced") {
                    HStack {
                        Text("Target Device IP")
                        Spacer()
                        TextField(DeviceConnectionContext.defaultTargetIPAddress, text: $targetDeviceIP)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .keyboardType(.numbersAndPunctuation)
                            .frame(maxWidth: 160)
                    }
                    ForEach([UInt16(49152), 58783, 62078], id: \.self) { port in
                        Button {
                            lockdownProbe.start(host: targetDeviceIP, port: port)
                        } label: {
                            HStack {
                                Label(portProbeLabel(port), systemImage: "network")
                                Spacer()
                                if lockdownProbe.status.isRunning && lockdownProbe.testedPort == port {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                        .disabled(lockdownProbe.status.isRunning || remotePairingDiscovery.status.isRunning)
                    }

                    if lockdownProbe.status != .idle {
                        Label(lockdownProbeMessage, systemImage: lockdownProbeSymbol)
                            .font(.caption)
                            .foregroundStyle(lockdownProbeColor)
                    }

                    Text("Reachability only. This test does not read or transmit pairing data.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        remotePairingDiscovery.start()
                    } label: {
                        HStack {
                            Label("Discover Remote Pairing", systemImage: "dot.radiowaves.left.and.right")
                            Spacer()
                            if remotePairingDiscovery.status.isRunning {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    .disabled(remotePairingDiscovery.status.isRunning || lockdownProbe.status.isRunning)

                    if remotePairingDiscovery.status != .idle {
                        Label(remotePairingMessage, systemImage: remotePairingSymbol)
                            .font(.caption)
                            .foregroundStyle(remotePairingColor)
                    }

                    Button { openAppFolder() } label: {
                        Label("App Folder", systemImage: "folder")
                    }.foregroundStyle(.primary)
                    Button { showDDIConfirmation = true } label: {
                        Label("Redownload DDI", systemImage: "arrow.down.circle")
                    }.foregroundStyle(.primary).disabled(isRedownloadingDDI)
                    if isRedownloadingDDI {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: ddiDownloadProgress, total: 1.0)
                            Text(ddiStatusMessage).font(.caption).foregroundStyle(.secondary)
                        }
                    } else if let result = ddiResultMessage {
                        Text(result.text).font(.caption).foregroundStyle(result.isError ? .red : .green)
                    }
                }

                Section("Help") {
                    Link(destination: SettingsLinks.pairingFileGuide) {
                        Label("Pairing File Guide", systemImage: "questionmark.circle")
                    }
                    Link(destination: SettingsLinks.localDevVPN) {
                        Label("Download LocalDevVPN", systemImage: "arrow.down.circle")
                    }
                    Link(destination: SettingsLinks.discord) {
                        Label("Discord Support", systemImage: "bubble.left.and.bubble.right")
                    }
                }

                Section {
                    Text(versionFooter)
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Settings")
        }
        .fileImporter(
            isPresented: $isShowingPairingFilePicker,
            allowedContentTypes: PairingFileStore.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }

                let fileManager = FileManager.default
                isImportingFile = true
                pairingImportMessage = nil

                do {
                    try PairingFileStore.importFromPicker(url, fileManager: fileManager)
                    isImportingFile = false
                    pairingImportMessage = ("Imported successfully", false)
                    startTunnelInBackground()
                    schedulePairingStatusDismiss()
                } catch {
                    isImportingFile = false
                    pairingImportMessage = ("Import failed: \(error.localizedDescription)", true)
                    schedulePairingStatusDismiss()
                }
            case .failure(let error):
                isImportingFile = false
                pairingImportMessage = ("Import failed: \(error.localizedDescription)", true)
                schedulePairingStatusDismiss()
            }
        }
        .confirmationDialog("Redownload DDI Files?", isPresented: $showDDIConfirmation, titleVisibility: .visible) {
            Button("Redownload", role: .destructive) {
                redownloadDDIPressed()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Existing DDI files will be removed before downloading fresh copies.")
        }
    }

    private var versionFooter: String {
        let processInfo = ProcessInfo.processInfo
        let txmLabel: String
        if processInfo.isTXMOverridden {
            txmLabel = "TXM (Override)"
        } else {
            txmLabel = processInfo.hasTXM ? "TXM" : "Non TXM"
        }
        return "Version \(appVersion) • iOS \(UIDevice.current.systemVersion) • \(txmLabel)"
    }

    private var lockdownProbeMessage: String {
        let port = lockdownProbe.testedPort
        switch lockdownProbe.status {
        case .idle:
            return ""
        case .running(let host):
            return "Connecting to \(host):\(port)…"
        case .reachable(let host):
            return "Success: \(host):\(port) accepts TCP connections."
        case .refused(let host):
            return "Refused: \(host) responded, but nothing accepts TCP connections on port \(port)."
        case .timedOut(let host):
            return "Timeout: no TCP response from \(host):\(port) within 5 seconds."
        case .invalidAddress:
            return "Enter a numeric IPv4 or IPv6 target address first."
        case .failed(let host, let reason):
            return "Failed to reach \(host):\(port): \(reason)"
        }
    }

    private func portProbeLabel(_ port: UInt16) -> String {
        switch port {
        case 49152:
            return "Test Remote Pairing Port 49152"
        case 58783:
            return "Test RemoteXPC Port 58783"
        case 62078:
            return "Test Lockdown Port 62078"
        default:
            return "Test TCP Port \(port)"
        }
    }

    private var remotePairingMessage: String {
        switch remotePairingDiscovery.status {
        case .idle:
            return ""
        case .browsing:
            return "Searching for Apple's Remote Pairing service, including peer-to-peer…"
        case .connecting(let service):
            return "Found \(service); testing the advertised endpoint…"
        case .reachable(let endpoint):
            return "Success: Remote Pairing is reachable at \(endpoint)."
        case .notFound:
            return "No Remote Pairing service was advertised within 7 seconds."
        case .failed(let reason):
            return "Remote Pairing discovery failed: \(reason)"
        }
    }

    private var remotePairingSymbol: String {
        switch remotePairingDiscovery.status {
        case .idle, .browsing, .connecting:
            return "dot.radiowaves.left.and.right"
        case .reachable:
            return "checkmark.circle.fill"
        case .notFound, .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var remotePairingColor: Color {
        switch remotePairingDiscovery.status {
        case .idle, .browsing, .connecting:
            return .secondary
        case .reachable:
            return .green
        case .notFound, .failed:
            return .orange
        }
    }

    private var lockdownProbeSymbol: String {
        switch lockdownProbe.status {
        case .idle, .running:
            return "network"
        case .reachable:
            return "checkmark.circle.fill"
        case .refused, .timedOut, .invalidAddress, .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var lockdownProbeColor: Color {
        switch lockdownProbe.status {
        case .idle, .running:
            return .secondary
        case .reachable:
            return .green
        case .refused, .timedOut, .invalidAddress, .failed:
            return .orange
        }
    }

    // MARK: - Business Logic

    private func openAppFolder() {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let path = documentsURL.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
        if let url = URL(string: path) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }

    private func redownloadDDIPressed() {
        guard !isRedownloadingDDI else { return }
        Task {
            await MainActor.run {
                isRedownloadingDDI = true
                ddiDownloadProgress = 0
                ddiStatusMessage = "Preparing download…"
                ddiResultMessage = nil
            }
            do {
                try await redownloadDDI { progress, status in
                    Task { @MainActor in
                        self.ddiDownloadProgress = progress
                        self.ddiStatusMessage = status
                    }
                }
                await MainActor.run {
                    isRedownloadingDDI = false
                    ddiResultMessage = ("DDI files refreshed successfully.", false)
                }
            } catch {
                await MainActor.run {
                    isRedownloadingDDI = false
                    ddiResultMessage = ("Failed to redownload DDI files: \(error.localizedDescription)", true)
                }
            }
        }
        scheduleDDIStatusDismiss()
    }

    private func schedulePairingStatusDismiss() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                if !isImportingFile {
                    pairingImportMessage = nil
                }
            }
        }
    }

    private func scheduleDDIStatusDismiss() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await MainActor.run {
                if !isRedownloadingDDI {
                    ddiResultMessage = nil
                }
            }
        }
    }
}
