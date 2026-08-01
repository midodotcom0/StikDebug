//
//  ConnectionDiagnosticsView.swift
//  StikDebug
//
//  Measures which transport is actually reachable on the current network.
//
//  The interesting question this answers is whether lockdownd on port 62078 responds
//  when the device is on cellular only. If it does, the CoreDeviceProxy transport
//  reaches RSD without Wi-Fi. If it does not, no app-side change can help, because
//  iOS starts those services only for a Wi-Fi client association.
//

import SwiftUI
import UIKit

struct ConnectionDiagnosticsView: View {
    @State private var report: TransportProbeReport?
    @State private var isRunning = false
    @State private var didCopy = false

    var body: some View {
        List {
            Section {
                Button {
                    runProbe()
                } label: {
                    HStack {
                        Text(isRunning ? "Running…" : "Run Diagnostics")
                        Spacer()
                        if isRunning {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(isRunning)
            } footer: {
                Text("Checks which device services are reachable through the VPN tunnel right now. Nothing leaves the device.")
            }

            if let report {
                Section("Verdict") {
                    Text(report.verdict)
                        .font(.callout)
                }

                Section("Ports") {
                    ForEach(report.ports, id: \.port) { result in
                        LabeledContent {
                            Text(result.outcome.summary)
                                .foregroundStyle(result.outcome.isReachable ? .green : .secondary)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(result.port)")
                                Text(result.service)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Network") {
                    LabeledContent("Wi-Fi client", value: report.hasWiFiClientInterface ? "yes" : "no")
                    LabeledContent("Cellular", value: report.hasCellularInterface ? "yes" : "no")
                    LabeledContent("Access point mode", value: report.hasAccessPointInterface ? "yes" : "no")
                    LabeledContent("VPN tunnel", value: report.hasTunnelInterface ? "yes" : "no")
                    LabeledContent("Interfaces", value: report.interfaces.joined(separator: ", "))
                        .font(.caption)
                }

                Section("Pairing record") {
                    if report.pairingFilePresent {
                        LabeledContent("RemotePairing reader", value: report.remotePairingRecordReadable ? "ok" : "failed")
                        LabeledContent("Lockdown reader", value: report.lockdownRecordReadable ? "ok" : "failed")
                    } else {
                        Text("No pairing file imported")
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button {
                        UIPasteboard.general.string = report.text
                        didCopy = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { didCopy = false }
                    } label: {
                        Label(didCopy ? "Copied" : "Copy Report", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                } footer: {
                    Text("The report contains port results and interface names only — no pairing data, identifiers, or addresses.")
                }
            }
        }
        .navigationTitle("Connection Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func runProbe() {
        isRunning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = TransportProbe.run()
            DispatchQueue.main.async {
                report = result
                isRunning = false
                LogManager.shared.addInfoLog("Transport probe: \(result.verdict)")
            }
        }
    }
}
