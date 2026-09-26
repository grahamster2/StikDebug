//
//  ControlPanel.swift
//  Drift
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
    @AppStorage(UserDefaults.Keys.travelMode) private var travelRaw = TravelMode.walk.rawValue
    @AppStorage(UserDefaults.Keys.realisticDriving) private var realisticDriving = true

    private var travel: TravelMode { TravelMode(rawValue: travelRaw) ?? .walk }
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
            } else if let notice = planner.planNotice {
                noticeRow(notice)
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

        primaryButton("Start \(travel.activeTitle)", systemImage: travel.systemImage, disabled: !canStartWalk) {
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
            Label(travel == .drive ? "Follow roads" : "Follow streets and paths", systemImage: "road.lanes")
                .font(.subheadline)
        }
        .onChange(of: followPaths) { _, _ in planner.rebuild() }

        routeSettings

        primaryButton("Start \(travel.activeTitle)", systemImage: travel.systemImage, disabled: !canStartWalk) {
            startPreviewWalk()
        }
    }

    private var routeSettings: some View {
        VStack(spacing: 10) {
            TravelModePicker { planner.rebuild() }
            if planner.isPlanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(planner.planningStatus)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else if let preview = planner.preview {
                RouteSummary(route: preview)
                if planner.isLoadingRoadData {
                    roadDataLoadingRow
                }
            }
            if travel == .drive && realisticDriving && (planner.isLoadingRoadData || planner.preview?.driveProfile?.hasRoadSpeeds != false) {
                DriveStyleControl()
            } else {
                SpeedControl()
            }
            LoopPicker { planner.rebuild() }
        }
    }

    // MARK: - Active walk

    private var activeWalk: some View {
        VStack(spacing: 12) {
            HStack {
                Label(engine.phase == .paused ? "Paused" : travel.activeTitle, systemImage: engine.phase == .paused ? "pause.circle.fill" : travel.systemImage)
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

            if let readout = engine.driveReadout {
                DriveReadoutView(readout: readout)
            }
            if engine.isDrivingRealistically, engine.route?.driveProfile?.hasRoadSpeeds == false, planner.isLoadingRoadData {
                roadDataLoadingRow
            }

            HStack {
                statColumn("Travelled", Self.format(distance: engine.distanceWalked))
                Spacer()
                statColumn("Left", Self.format(distance: engine.remainingDistance))
                Spacer()
                statColumn("Time left", Self.format(duration: engine.remainingTime))
            }

            TravelModePicker(onChange: nil)
            if engine.isDrivingRealistically && (engine.route?.driveProfile?.hasRoadSpeeds == true || planner.isLoadingRoadData) {
                DriveStyleControl()
            } else {
                SpeedControl()
            }
            LoopPicker(onChange: nil)

            if planner.mode == .walk, planner.destination != nil, planner.isPlanning || planner.preview != nil {
                redirectRow
            } else {
                Text("Tap the map to change where you're going.")
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

    private var roadDataLoadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text("Loading speed limits and stop signs… you can start now.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var redirectRow: some View {
        HStack {
            if planner.isPlanning {
                ProgressView().controlSize(.small)
                Text(planner.planningStatus)
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

    private func noticeRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
            Text(message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                planner.planNotice = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
    let route: WalkRoute
    // Observed so the time updates when the speed, mode or style changes.
    @AppStorage(UserDefaults.Keys.travelMode) private var travelRaw = TravelMode.walk.rawValue
    @AppStorage(UserDefaults.Keys.walkingSpeedKmh) private var walkingSpeed = TravelMode.walk.defaultSpeedKmh
    @AppStorage(UserDefaults.Keys.cyclingSpeedKmh) private var cyclingSpeed = TravelMode.cycle.defaultSpeedKmh
    @AppStorage(UserDefaults.Keys.drivingSpeedKmh) private var drivingSpeed = TravelMode.drive.defaultSpeedKmh
    @AppStorage(UserDefaults.Keys.drivingStyle) private var drivingStyle = 1.0
    @AppStorage(UserDefaults.Keys.realisticDriving) private var realisticDriving = true

    var body: some View {
        let travel = TravelMode(rawValue: travelRaw) ?? .walk
        let profile = travel == .drive && realisticDriving ? route.driveProfile : nil
        let time = profile?.estimatedTime(
            from: 0,
            totalDistance: route.totalDistance,
            style: drivingStyle,
            fallbackSpeed: travel.speedMetersPerSecond
        ) ?? route.totalDistance / travel.speedMetersPerSecond

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
                    .foregroundStyle(.purple)
                Text(ControlPanel.format(distance: route.totalDistance))
                    .font(.subheadline.weight(.semibold))
                Text("·")
                    .foregroundStyle(.secondary)
                Text(ControlPanel.format(duration: time))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            if let profile, profile.hasRoadSpeeds {
                Text(Self.describe(profile))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    static func describe(_ profile: DriveProfile) -> String {
        let signs = profile.stops.filter { $0.kind == .stopSign }.count
        let lights = profile.stops.filter { $0.kind == .trafficSignal }.count
        let limits = profile.segments.map(\.limit)
        var parts: [String] = []
        if let low = limits.min(), let high = limits.max() {
            let lowLabel = SpeedControl.limitLabel(low)
            let highLabel = SpeedControl.limitLabel(high)
            parts.append(lowLabel == highLabel ? "\(lowLabel) roads" : "\(lowLabel)–\(highLabel) roads")
        }
        parts.append("\(signs) stop sign\(signs == 1 ? "" : "s")")
        parts.append("\(lights) traffic light\(lights == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }
}

struct DriveStyleControl: View {
    @AppStorage(UserDefaults.Keys.drivingStyle) private var style = 1.0

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "car.fill")
                    .frame(width: 28, height: 28)
                Slider(value: $style, in: 0.85...1.15, step: 0.01)
                Text(Self.label(style))
                    .font(.subheadline.monospacedDigit())
                    .frame(width: 76, alignment: .trailing)
            }
            HStack {
                Text("Relaxed")
                Spacer()
                Text("Follows each road's limit")
                Spacer()
                Text("Aggressive")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    static func label(_ style: Double) -> String {
        let percent = Int(((style - 1) * 100).rounded())
        if percent == 0 { return "At limit" }
        return percent > 0 ? "+\(percent)%" : "\(percent)%"
    }
}

struct DriveReadoutView: View {
    let readout: DriveReadout

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 0) {
                Text(SpeedControl.speedNumber(readout.speed))
                    .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                Text(SpeedControl.speedUnit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 64, alignment: .leading)

            if let limit = readout.limit {
                SpeedLimitSign(limit: limit, isPosted: readout.limitIsPosted)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(readout.road ?? "Unnamed road")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let waiting = readout.waiting {
                    Label(
                        waiting == .stopSign ? "Stop sign" : "Red light · \(Int(readout.waitRemaining.rounded(.up)))s",
                        systemImage: waiting == .stopSign ? "octagon.fill" : "light.beacon.max.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                } else if readout.limit != nil {
                    Text(readout.limitIsPosted ? "Posted limit" : "Typical speed for this road")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct SpeedLimitSign: View {
    let limit: CLLocationSpeed
    let isPosted: Bool

    private var isUS: Bool { Locale.current.measurementSystem == .us }

    var body: some View {
        VStack(spacing: 0) {
            if isUS {
                Text("LIMIT")
                    .font(.system(size: 7, weight: .heavy))
            }
            Text(SpeedControl.speedNumber(limit, roundTo: 5))
                .font(.system(size: 18, weight: .heavy, design: .rounded))
        }
        .foregroundStyle(.black)
        .frame(width: 44, height: 44)
        .background {
            if isUS {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.black, lineWidth: 2))
            } else {
                Circle()
                    .fill(.white)
                    .overlay(Circle().stroke(.red, lineWidth: 4))
            }
        }
        // Guessed limits are shown faded.
        .opacity(isPosted ? 1 : 0.6)
        .accessibilityLabel("Speed limit \(SpeedControl.limitLabel(limit))")
    }
}

struct TravelModePicker: View {
    @AppStorage(UserDefaults.Keys.travelMode) private var travelRaw = TravelMode.walk.rawValue
    let onChange: (() -> Void)?

    var body: some View {
        Picker("Travel by", selection: $travelRaw) {
            ForEach(TravelMode.allCases) { mode in
                Label(mode.title, systemImage: mode.systemImage).tag(mode.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: travelRaw) { _, _ in onChange?() }
    }
}

struct SpeedControl: View {
    @AppStorage(UserDefaults.Keys.travelMode) private var travelRaw = TravelMode.walk.rawValue
    @AppStorage(UserDefaults.Keys.walkingSpeedKmh) private var walkingSpeed = TravelMode.walk.defaultSpeedKmh
    @AppStorage(UserDefaults.Keys.cyclingSpeedKmh) private var cyclingSpeed = TravelMode.cycle.defaultSpeedKmh
    @AppStorage(UserDefaults.Keys.drivingSpeedKmh) private var drivingSpeed = TravelMode.drive.defaultSpeedKmh

    private var travel: TravelMode { TravelMode(rawValue: travelRaw) ?? .walk }

    private var speed: Binding<Double> {
        switch travel {
        case .walk: return $walkingSpeed
        case .cycle: return $cyclingSpeed
        case .drive: return $drivingSpeed
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(travel.presets, id: \.kmh) { preset in
                    Button("\(preset.title) · \(Self.label(preset.kmh))") {
                        speed.wrappedValue = preset.kmh
                    }
                }
            } label: {
                Image(systemName: travel.systemImage)
                    .frame(width: 28, height: 28)
            }
            .accessibilityLabel("Speed presets")

            Slider(
                value: Binding(
                    get: { min(max(speed.wrappedValue, travel.speedRange.lowerBound), travel.speedRange.upperBound) },
                    set: { speed.wrappedValue = $0 }
                ),
                in: travel.speedRange,
                step: travel.speedStep
            )

            Text(Self.label(travel.speedKmh))
                .font(.subheadline.monospacedDigit())
                .frame(width: 76, alignment: .trailing)
        }
    }

    static var speedUnit: String {
        Locale.current.measurementSystem == .us ? "mph" : "km/h"
    }

    /// Speed in the user's units as a bare number, e.g. "34".
    static func speedNumber(_ metersPerSecond: CLLocationSpeed, roundTo step: Double = 1) -> String {
        let value = Locale.current.measurementSystem == .us ? metersPerSecond * 2.236936 : metersPerSecond * 3.6
        return String(Int((value / step).rounded() * step))
    }

    static func limitLabel(_ metersPerSecond: CLLocationSpeed) -> String {
        "\(speedNumber(metersPerSecond, roundTo: 5)) \(speedUnit)"
    }

    static func label(_ kmh: Double) -> String {
        if Locale.current.measurementSystem == .us {
            let mph = kmh / 1.609344
            return mph >= 20 ? String(format: "%.0f mph", mph) : String(format: "%.1f mph", mph)
        }
        return kmh >= 20 ? String(format: "%.0f km/h", kmh) : String(format: "%.1f km/h", kmh)
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
