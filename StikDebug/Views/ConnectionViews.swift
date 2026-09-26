//
//  ConnectionViews.swift
//  Wander
//

import SwiftUI
import Combine

enum ConnectionState: Equatable {
    case needsPairingFile
    case connecting
    case disconnected
    case mountingImage
    case ready

    var title: String {
        switch self {
        case .needsPairingFile: return "Setup needed"
        case .connecting: return "Connecting…"
        case .disconnected: return "Not connected"
        case .mountingImage: return "Preparing…"
        case .ready: return "Ready"
        }
    }

    var color: Color {
        switch self {
        case .ready: return .green
        case .connecting, .mountingImage: return .orange
        case .needsPairingFile, .disconnected: return .red
        }
    }
}

/// Watches the tunnel and disk image and summarises them as one state.
@MainActor
final class ConnectionMonitor: ObservableObject {
    static let shared = ConnectionMonitor()

    @Published private(set) var state: ConnectionState = .connecting

    private let tunnel = TunnelManager.shared
    private let mounting = MountingProgress.shared
    private var retryTask: Task<Void, Never>?

    private init() {
        tunnel.$isConnected.combineLatest(tunnel.$isStarting, mounting.$coolisMounted, mounting.$mountingThread.map { $0 != nil })
            .receive(on: DispatchQueue.main)
            .map { _ in () }
            .sink { [weak self] in self?.refresh() }
            .store(in: &cancellables)
        refresh()
        startRetrying()
    }

    private var cancellables = Set<AnyCancellable>()

    var hasPairingFile: Bool {
        FileManager.default.fileExists(atPath: PairingFileStore.prepareURL().path)
    }

    func refresh() {
        let newState: ConnectionState
        if !hasPairingFile {
            newState = .needsPairingFile
        } else if tunnel.isConnected {
            newState = mounting.coolisMounted ? .ready : .mountingImage
        } else {
            newState = tunnel.isStarting ? .connecting : .disconnected
        }
        if newState != state {
            state = newState
        }
    }

    func reconnect(showErrors: Bool) {
        markTunnelDisconnected()
        startTunnelInBackground(showErrorUI: showErrors)
    }

    /// Quietly keeps trying while disconnected, so turning on LocalDevVPN
    /// after opening the app just works.
    private func startRetrying() {
        retryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(8))
                guard let self else { return }
                self.refresh()
                switch self.state {
                case .disconnected:
                    startTunnelInBackground(showErrorUI: false)
                case .mountingImage:
                    if self.mounting.mountingThread == nil {
                        self.mounting.checkforMounted()
                    }
                default:
                    break
                }
            }
        }
    }
}

struct ConnectionBadge: View {
    @ObservedObject var monitor: ConnectionMonitor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if monitor.state == .connecting || monitor.state == .mountingImage {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Circle()
                        .fill(monitor.state.color)
                        .frame(width: 8, height: 8)
                }
                Text(monitor.state.title)
                    .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Connection: \(monitor.state.title)")
    }
}

/// Shown in the bottom panel until the app can actually talk to the device.
struct SetupCard: View {
    let state: ConnectionState
    let importPairingFile: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(state.color)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if state == .needsPairingFile {
                    Button("Import Pairing File", action: importPairingFile)
                        .buttonStyle(.borderedProminent)
                }
                Button("Details", action: openSettings)
                    .buttonStyle(.bordered)
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        switch state {
        case .needsPairingFile: return "Import your pairing file"
        case .disconnected: return "Can't reach your iPhone"
        default: return state.title
        }
    }

    private var message: String {
        switch state {
        case .needsPairingFile:
            return "Pick the same pairing file SideStore uses (On My iPhone → SideStore → ALTPairingFile.mobiledevicepairing)."
        case .disconnected:
            return "Open LocalDevVPN and connect it. Wander will reconnect automatically."
        default:
            return ""
        }
    }
}
