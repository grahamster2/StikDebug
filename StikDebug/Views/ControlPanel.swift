//
//  ControlPanel.swift
//  Wander
//

import SwiftUI
import CoreLocation

struct ControlPanel: View {
    @ObservedObject var engine: SimulationEngine
    @ObservedObject var planner: Planner
    @ObservedObject var monitor: ConnectionMonitor

    let importPairingFile: () -> Void
    let importRoute: () -> Void
    let openSettings: () -> Void
    let saveFavourite: (GeoPoint) -> Void

    @AppStorage(UserDefaults.Keys.followPaths) private var followPaths = true
    @State private var showEndOptions = false

    var body: some View {
        VStack(spacing: 14) {
            if let session = engine.recoverableSession, !engine.isActive {
                RecoveryBanner(session: session, engine: engine)
                Divider()
            }

            if monitor.state == .needsPairingFile || monitor.state == .disconnected {
                SetupCard(state: monitor.state, importPairingFile: importPairingFile, openSettings: openSettings)
                Divider()
            }

            if engine.isMoving {
                activeWalk
            } else {
                planning
            }

            if let message = engine.errorMessage ?? planner.planError {
                errorRow(message)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .animation(.snappy, value: engine.phase)
        .animation(.snappy, value: planner.mode)
        .confirmationDialog("End this walk?", isPresented: $showEndOptions, titleVisibility: .visible) {
            Button("Stay Here") {
                if let point = engine.currentPoint {
                    Task { await engine.teleport(to: point) }
                }
            }
            Button("Restore Real Location", role: .destructive) {
                Task { await engine.restoreRealLocation() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can keep your simulated position where you are now, or go back to your real location.")
        }
    }

    // MARK: - Planning

    private var planning: some View {
        VStack(spacing: 12) {
            Picker("Mode", selection: $planner.mode) {
                ForEach(PlanMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if engine.phase == .holding, let point = engine.currentPoint {
                holdingRow(point)
            }

            Text(planner.hint)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            switch planner.mode {
            case .pin: pinPlanning
            case .walk: walkPlanning
            case .draw: drawPlanning
            }
        }
    }

    private func holdingRow(_ point: GeoPoint) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "location.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(engine.route == nil ? "Location set" : "Arrived")
                    .font(.subheadline.weight(.semibold))
                Text(point.formatted)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                saveFavourite(point)
            } label: {
                Image(systemName: "star")
            }
            .buttonStyle(.bordered)
            Button("Restore", role: .destructive) {
                Task { await engine.restoreRealLocation() }
            }
            .buttonStyle(.bordered)
            .disabled(engine.isBusy)
        }
        .controlSize(.small)
        .padding(10)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var pinPlanning: some View {
        if let pin = planner.pin {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pin.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(pin.point.formatted)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    saveFavourite(pin.point)
                } label: {
                    Image(systemName: "star")
                }
                .buttonStyle(.bordered)
            }

            primaryButton("Jump Here", systemImage: "location.fill", disabled: !canSimulate) {
                PlaceStore.shared.recordRecent(name: pin.name, point: pin.point)
                Task { await engine.teleport(to: pin.point) }
            }
        }
    }

    @ViewBuilder
    private var walkPlanning: some View {
        VStack(spacing: 8) {
            endpointRow(
                icon: "circle.fill",
                tint: .green,
                label: "From",
                value: engine.currentPoint != nil ? "Current simulated location" : (planner.walkStart?.point.formatted ?? "Tap the map")
            ) {
                if engine.currentPoint == nil, planner.walkStart != nil {
                    planner.walkStart = nil
                    planner.rebuild()
                }
            }
            endpointRow(
                icon: "flag.fill",
                tint: .red,
                label: "To",
                value: planner.destination?.name ?? "Tap the map or search"
            ) {
                planner.destination = nil
                planner.rebuild()
            }
        }

        routeSettings

        primaryButton("Start Walk", systemImage: "figure.walk", disabled: !canStartWalk) {
            startPreviewWalk()
        }
    }

    @ViewBuilder
    private var drawPlanning: some View {
        HStack {
            Label("\(planner.waypoints.count) points", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.subheadline)
            Spacer()
            Button {
                planner.undoWaypoint()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(planner.waypoints.isEmpty)
            Button(role: .destructive) {
                planner.clear()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(planner.waypoints.isEmpty)
            Button(action: importRoute) {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("Import GPX")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)

        Toggle(isOn: $followPaths) {
            Label("Follow streets and paths", systemImage: "road.lanes")
                .font(.subheadline)
        }
        .onChange(of: followPaths) { _, _ in planner.rebuild() }

        routeSettings

        primaryButton("Start Walk", systemImage: "figure.walk", disabled: !canStartWalk) {
            startPreviewWalk()
        }
    }

    private var routeSettings: some View {
        VStack(spacing: 10) {
            if planner.isPlanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding a route…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if let preview = planner.preview {
                RouteSummary(distance: preview.totalDistance)
            }
            SpeedControl()
            LoopPicker { planner.rebuild() }
        }
    }

    // MARK: - Active walk

    private var activeWalk: some View {
        VStack(spacing: 12) {
            HStack {
                Label(engine.phase == .paused ? "Paused" : "Walking", systemImage: engine.phase == .paused ? "pause.circle.fill" : "figure.walk.motion")
                    .font(.headline)
                    .foregroundStyle(engine.phase == .paused ? .orange : .blue)
                Spacer()
                if let point = engine.currentPoint {
                    Button {
                        saveFavourite(point)
                    } label: {
                        Image(systemName: "star")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            ProgressView(value: engine.progress)
                .tint(engine.phase == .paused ? .orange : .blue)

            HStack {
                statColumn("Walked", Self.format(distance: engine.distanceWalked))
                Spacer()
                statColumn("Left", Self.format(distance: engine.remainingDistance))
                Spacer()
                statColumn("Time left", Self.format(duration: SimulationEngine.travelTime(for: engine.remainingDistance)))
            }

            SpeedControl()
            LoopPicker(onChange: nil)

            if planner.mode == .walk, planner.destination != nil, planner.isPlanning || planner.preview != nil {
                redirectRow
            } else {
                Text("Tap the map to change where you're walking.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                if engine.phase == .paused {
                    wideButton("Resume", systemImage: "play.fill", prominent: true) { engine.resume() }
                } else {
                    wideButton("Pause", systemImage: "pause.fill", prominent: true) { engine.pause() }
                }
                wideButton("Reverse", systemImage: "arrow.uturn.backward", prominent: false) { engine.reverse() }
                wideButton("End", systemImage: "stop.fill", prominent: false, role: .destructive) { showEndOptions = true }
            }
        }
        .onAppear {
            // While walking, taps on the map pick a new destination.
            planner.mode = .walk
        }
    }

    private var redirectRow: some View {
        HStack {
            if planner.isPlanning {
                ProgressView().controlSize(.small)
                Text("Finding a new route…")
                    .font(.footnote)
            } else if let preview = planner.preview {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New destination")
                        .font(.subheadline.weight(.semibold))
                    Text(Self.format(distance: preview.totalDistance))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    planner.destination = nil
                    planner.rebuild()
                }
                .buttonStyle(.bordered)
                Button("Walk There") {
                    engine.redirect(preview)
                    planner.destination = nil
                    planner.rebuild()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.small)
        .padding(10)
        .background(Color.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Pieces

    private var canSimulate: Bool {
        monitor.state != .needsPairingFile && !engine.isBusy
    }

    private var canStartWalk: Bool {
        canSimulate && planner.preview != nil && !planner.isPlanning
    }

    private func startPreviewWalk() {
        guard let route = planner.preview else { return }
        if let destination = planner.destination {
            PlaceStore.shared.recordRecent(name: destination.name, point: destination.point)
        }
        Task {
            await engine.startWalk(route)
            if engine.isMoving {
                planner.clear()
            }
        }
    }

    private func endpointRow(icon: String, tint: Color, label: String, value: String, clear: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .lineLimit(1)
            Spacer()
            Button(action: clear) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear \(label)")
        }
    }

    private func statColumn(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    private func primaryButton(_ title: String, systemImage: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if engine.isBusy {
                    ProgressView()
                } else {
                    Label(title, systemImage: systemImage)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .disabled(disabled)
    }

    private func wideButton(_ title: String, systemImage: String, prominent: Bool, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .modifier(ProminenceModifier(prominent: prominent))
        .disabled(engine.isBusy)
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                engine.errorMessage = nil
                planner.planError = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Formatting

    static func format(distance: CLLocationDistance) -> String {
        Measurement(value: distance, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road))
    }

    static func format(duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(duration, 0)) ?? "–"
    }
}

private struct ProminenceModifier: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

// MARK: - Shared controls

struct RouteSummary: View {
    let distance: CLLocationDistance
    @AppStorage(UserDefaults.Keys.walkingSpeedKmh) private var speedKmh = 5.0

    var body: some View {
        HStack {
            Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
                .foregroundStyle(.purple)
            Text(ControlPanel.format(distance: distance))
                .font(.subheadline.weight(.semibold))
            Text("·")
                .foregroundStyle(.secondary)
            Text(ControlPanel.format(duration: distance / (max(speedKmh, 0.5) / 3.6)))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct SpeedControl: View {
    @AppStorage(UserDefaults.Keys.walkingSpeedKmh) private var speedKmh = 5.0

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(SpeedPreset.allCases) { preset in
                    Button {
                        speedKmh = preset.rawValue
                    } label: {
                        Label("\(preset.title) · \(Self.label(preset.rawValue))", systemImage: preset.systemImage)
                    }
                }
            } label: {
                Image(systemName: icon)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Speed presets")

            Slider(value: $speedKmh, in: 1...25, step: 0.5)

            Text(Self.label(speedKmh))
                .font(.subheadline.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
        }
    }

    private var icon: String {
        switch speedKmh {
        case ..<7.5: return "figure.walk"
        case ..<13: return "figure.run"
        default: return "bicycle"
        }
    }

    static func label(_ kmh: Double) -> String {
        if Locale.current.measurementSystem == .us {
            return String(format: "%.1f mph", kmh / 1.609344)
        }
        return String(format: "%.1f km/h", kmh)
    }
}

struct LoopPicker: View {
    @AppStorage(UserDefaults.Keys.loopMode) private var loopRaw = LoopMode.off.rawValue
    let onChange: (() -> Void)?

    var body: some View {
        HStack {
            Text("At the end")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Picker("At the end", selection: $loopRaw) {
                ForEach(LoopMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode.rawValue)
                }
            }
            .pickerStyle(.menu)
        }
        .onChange(of: loopRaw) { _, _ in onChange?() }
    }
}

struct RecoveryBanner: View {
    let session: SavedSession
    @ObservedObject var engine: SimulationEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                session.kind == .walking ? "Your last walk was interrupted" : "Your last location was interrupted",
                systemImage: "clock.arrow.circlepath"
            )
            .font(.subheadline.weight(.semibold))
            Text("Saved \(session.savedAt.formatted(.relative(presentation: .named))).")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(session.kind == .walking ? "Resume Walk" : "Go Back There") {
                    Task { await engine.resumeSavedSession() }
                }
                .buttonStyle(.borderedProminent)
                Button("Restore Real Location") {
                    Task { await engine.discardSavedSession() }
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)
            .disabled(engine.isBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
