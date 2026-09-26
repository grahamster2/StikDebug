//
//  SettingsView.swift
//  Drift
//

import SwiftUI

private enum SettingsLinks {
    static let source = URL(string: "https://github.com/grahamster2/StikDebug")!
    static let stikDebug = URL(string: "https://github.com/StephenDev0/StikDebug")!
    static let localDevVPN = URL(string: "https://apps.apple.com/us/app/localdevvpn/id6755608044")!
}

struct SettingsView: View {
    @ObservedObject var monitor: ConnectionMonitor
    @ObservedObject var engine: SimulationEngine
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var mounting = MountingProgress.shared

    @AppStorage(UserDefaults.Keys.naturalMovement) private var naturalMovement = true
    @AppStorage(UserDefaults.Keys.realisticDriving) private var realisticDriving = true
    @AppStorage(UserDefaults.Keys.stopAtSignsAndLights) private var stopAtSignsAndLights = true
    @AppStorage(UserDefaults.Keys.keepAliveAudio) private var keepAliveAudio = true
    @AppStorage(UserDefaults.Keys.keepAliveLocation) private var keepAliveLocation = true
    @AppStorage(UserDefaults.Keys.targetDeviceIP) private var targetDeviceIP = DeviceConnectionContext.defaultTargetIPAddress

    @Binding var showPairingImporter: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var isRedownloading = false
    @State private var redownloadStatus: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    statusRow("Pairing file", ok: monitor.hasPairingFile, detail: monitor.hasPairingFile ? "Imported" : "Missing")
                    statusRow("LocalDevVPN link", ok: tunnel.isConnected, detail: tunnel.isStarting ? "Connecting…" : (tunnel.isConnected ? "Connected" : "Not connected"))
                    statusRow("Developer disk image", ok: mounting.coolisMounted, detail: mounting.mountingThread != nil ? "Mounting…" : (mounting.coolisMounted ? "Mounted" : "Not mounted"))

                    Button {
                        monitor.reconnect(showErrors: true)
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .disabled(tunnel.isStarting || !monitor.hasPairingFile)

                    if let message = tunnel.lastErrorMessage, !tunnel.isConnected {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Drift needs LocalDevVPN connected to talk to your iPhone's developer services.")
                }

                Section("Pairing File") {
                    Button {
                        dismiss()
                        // Give the sheet time to close before presenting the picker.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            showPairingImporter = true
                        }
                    } label: {
                        Label(monitor.hasPairingFile ? "Replace Pairing File" : "Import Pairing File", systemImage: "doc.badge.plus")
                    }
                }

                Section {
                    Toggle(isOn: $naturalMovement) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Natural Movement")
                            Text("Adds a few metres of GPS drift and small speed changes so movement doesn't look robotic.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Movement")
                }

                Section {
                    Toggle(isOn: $realisticDriving) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Realistic Driving")
                            Text("Looks up each road's speed limit and drives near it, slowing for corners and pulling away gradually.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $stopAtSignsAndLights) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stop at Signs and Lights")
                            Text("Stops briefly at stop signs and sometimes waits at red lights.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!realisticDriving)
                } header: {
                    Text("Driving")
                } footer: {
                    Text("Road data comes from OpenStreetMap. Where a road has no posted limit, a typical speed for that kind of road is used. Changes apply to the next route you plan.")
                }

                Section {
                    Toggle(isOn: $keepAliveAudio) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Silent Audio")
                            Text("Plays inaudible audio during a simulation so iOS keeps Drift running in the background.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $keepAliveLocation) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Background Location")
                            Text("Keeps a low-accuracy location session open during a simulation for the same reason.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: keepAliveLocation) { _, enabled in
                        if !enabled { BackgroundLocationManager.shared.stop() }
                    }
                } header: {
                    Text("Keep Running in Background")
                } footer: {
                    Text("Walks only continue while Drift is running. Leave both on unless they cause problems.")
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

                    Button {
                        redownloadDiskImage()
                    } label: {
                        Label("Redownload Disk Image", systemImage: "arrow.down.circle")
                    }
                    .disabled(isRedownloading)

                    if let redownloadStatus {
                        Text(redownloadStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        Task { await engine.restoreRealLocation() }
                    } label: {
                        Label("Force Restore Real Location", systemImage: "location.slash")
                    }
                    .disabled(engine.isBusy)
                }

                Section("About") {
                    LabeledContent("Version", value: appVersion)
                    Link(destination: SettingsLinks.localDevVPN) {
                        Label("Get LocalDevVPN", systemImage: "arrow.down.app")
                    }
                    Link(destination: SettingsLinks.source) {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    Link(destination: SettingsLinks.stikDebug) {
                        Label("Built on StikDebug (AGPL-3.0)", systemImage: "heart")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        return "\(version) • iOS \(UIDevice.current.systemVersion)"
    }

    private func statusRow(_ title: String, ok: Bool, detail: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(title)
            Spacer()
            Text(detail)
                .foregroundStyle(.secondary)
        }
    }

    private func redownloadDiskImage() {
        isRedownloading = true
        redownloadStatus = "Starting download…"
        Task {
            do {
                try await redownloadDDI { _, status in
                    Task { @MainActor in redownloadStatus = status }
                }
                redownloadStatus = "Disk image downloaded."
                MountingProgress.shared.pubMount()
            } catch {
                redownloadStatus = "Download failed: \(error.localizedDescription)"
            }
            isRedownloading = false
        }
    }
}
