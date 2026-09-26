//
//  WanderApp.swift
//  Wander
//

import SwiftUI

@main
struct WanderApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var shouldReconnect = false

    init() {
        AppBootstrapper.configure()
    }

    var body: some Scene {
        WindowGroup {
            MapScreen()
                .task {
                    startTunnelInBackground(showErrorUI: false)
                    await downloadMissingDeveloperDiskImageFiles()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    switch newPhase {
                    case .background:
                        shouldReconnect = true
                    case .active:
                        if shouldReconnect {
                            shouldReconnect = false
                            if !TunnelManager.shared.isConnected {
                                startTunnelInBackground(showErrorUI: false)
                            }
                        }
                    default:
                        break
                    }
                }
        }
    }

    private func downloadMissingDeveloperDiskImageFiles() async {
        do {
            try await DeveloperDiskImageService.shared.downloadMissingFiles()
            MountingProgress.shared.pubMount()
        } catch {
            showAlert(
                title: "Couldn't Download Developer Disk Image",
                message: "Wander needs this once to simulate location. Check your internet connection, then use Settings → Redownload Disk Image.\n\n\(error.localizedDescription)",
                showOk: true
            )
        }
    }
}
