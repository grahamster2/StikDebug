//
//  SimulationEngine.swift
//  Wander
//
//  Owns the device's simulated location: holding a fixed point, or walking a
//  route at a chosen speed with optional natural GPS drift.
//

import Foundation
import CoreLocation

enum LoopMode: String, CaseIterable, Identifiable {
    case off
    case backAndForth
    case loop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Stop at end"
        case .backAndForth: return "Back and forth"
        case .loop: return "Loop to start"
        }
    }

    var systemImage: String {
        switch self {
        case .off: return "arrow.right.to.line"
        case .backAndForth: return "arrow.left.arrow.right"
        case .loop: return "repeat"
        }
    }

    static var current: LoopMode {
        LoopMode(rawValue: UserDefaults.standard.string(forKey: UserDefaults.Keys.loopMode) ?? "") ?? .off
    }
}

/// What gets written to disk so an interrupted session can be resumed.
struct SavedSession: Codable {
    enum Kind: String, Codable {
        case holding
        case walking
    }

    var kind: Kind
    var point: GeoPoint
    var route: WalkRoute?
    var distanceWalked: Double
    var savedAt: Date
}

@MainActor
final class SimulationEngine: ObservableObject {
    static let shared = SimulationEngine()

    enum Phase: Equatable {
        case idle
        case holding
        case walking
        case paused
    }

    @Published private(set) var phase: Phase = .idle
    /// The position currently reported to the device (without GPS drift).
    @Published private(set) var currentPoint: GeoPoint?
    @Published private(set) var route: WalkRoute?
    @Published private(set) var distanceWalked: CLLocationDistance = 0
    @Published private(set) var isBusy = false
    @Published private(set) var recoverableSession: SavedSession?
    @Published var errorMessage: String?

    private var walkTask: Task<Void, Never>?
    private var holdTask: Task<Void, Never>?
    private var sendInFlight = false
    private var consecutiveFailures = 0
    private var keepAliveHeld = false
    private var lastPersist = Date.distantPast

    private var driftEast = 0.0
    private var driftNorth = 0.0
    private var speedFactor = 1.0

    private static let tickInterval: TimeInterval = 1
    private static let holdResendInterval: TimeInterval = 4
    private static let closedLoopTolerance: CLLocationDistance = 25
    private static let sessionKey = "savedSession"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.sessionKey),
           let session = try? JSONDecoder().decode(SavedSession.self, from: data) {
            recoverableSession = session
        }
    }

    // MARK: - Derived values

    var isActive: Bool { phase != .idle }
    var isMoving: Bool { phase == .walking || phase == .paused }

    var remainingDistance: CLLocationDistance {
        guard let route else { return 0 }
        return max(route.totalDistance - distanceWalked, 0)
    }

    var progress: Double {
        guard let route, route.totalDistance > 0 else { return 0 }
        return min(distanceWalked / route.totalDistance, 1)
    }

    static var speedMetersPerSecond: CLLocationSpeed {
        TravelMode.current.speedMetersPerSecond
    }

    static func travelTime(for distance: CLLocationDistance) -> TimeInterval {
        distance / speedMetersPerSecond
    }

    // MARK: - Commands

    /// Jumps straight to a point and holds it there.
    func teleport(to point: GeoPoint) async {
        cancelTasks()
        guard await sendNow(point) else { return }
        route = nil
        distanceWalked = 0
        currentPoint = point
        phase = .holding
        startHolding()
        persist(force: true)
    }

    /// Starts walking a route from its first point.
    func startWalk(_ newRoute: WalkRoute) async {
        cancelTasks()
        guard await sendNow(newRoute.start) else { return }
        route = newRoute
        distanceWalked = 0
        currentPoint = newRoute.start
        phase = .walking
        startWalking()
        persist(force: true)
    }

    /// Swaps in a new route that starts at the current position, keeping the
    /// walk (or pause) going.
    func redirect(_ newRoute: WalkRoute) {
        guard isMoving else { return }
        route = newRoute
        distanceWalked = 0
        persist(force: true)
    }

    func pause() {
        guard phase == .walking else { return }
        walkTask?.cancel()
        walkTask = nil
        phase = .paused
        startHolding()
        persist(force: true)
    }

    func resume() {
        guard phase == .paused else { return }
        holdTask?.cancel()
        holdTask = nil
        phase = .walking
        startWalking()
    }

    /// Turns around and walks back the way you came.
    func reverse() {
        guard isMoving, let route else { return }
        let walked = distanceWalked
        self.route = route.reversed()
        distanceWalked = route.totalDistance - walked
        persist(force: true)
    }

    /// Stops simulating and gives the device its real location back.
    func restoreRealLocation() async {
        cancelTasks()
        isBusy = true
        let code = await Self.run { LocationSimulator.clear() }
        isBusy = false

        phase = .idle
        route = nil
        currentPoint = nil
        distanceWalked = 0
        releaseKeepAlive()
        clearPersistedSession()

        if code != LocationSimulator.Status.ok {
            errorMessage = "Couldn't restore your real location. \(LocationSimulator.describe(code)) (error \(code))"
        }
    }

    // MARK: - Recovery

    func resumeSavedSession() async {
        guard let session = recoverableSession else { return }
        recoverableSession = nil

        switch session.kind {
        case .holding:
            await teleport(to: session.point)
        case .walking:
            guard let savedRoute = session.route else {
                await teleport(to: session.point)
                return
            }
            let walked = min(session.distanceWalked, savedRoute.totalDistance)
            let point = savedRoute.point(atDistance: walked)
            cancelTasks()
            guard await sendNow(point) else { return }
            route = savedRoute
            distanceWalked = walked
            currentPoint = point
            // Come back paused so the user can get ready before moving again.
            phase = .paused
            startHolding()
            persist(force: true)
        }
    }

    func discardSavedSession() async {
        recoverableSession = nil
        await restoreRealLocation()
    }

    // MARK: - Loops

    private func startWalking() {
        acquireKeepAlive()
        consecutiveFailures = 0
        walkTask = Task { [weak self] in
            var lastTick = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.tickInterval))
                guard !Task.isCancelled, let self else { return }
                let now = Date()
                // Cap the step so a long suspension doesn't teleport the walker.
                let elapsed = min(now.timeIntervalSince(lastTick), 5)
                lastTick = now
                self.advance(by: elapsed)
            }
        }
    }

    private func startHolding() {
        acquireKeepAlive()
        holdTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.holdResendInterval))
                guard !Task.isCancelled, let self, let point = self.currentPoint else { return }
                self.sendInBackground(self.drifted(point))
            }
        }
    }

    private func advance(by elapsed: TimeInterval) {
        guard phase == .walking, let route else { return }

        let natural = UserDefaults.standard.bool(forKey: UserDefaults.Keys.naturalMovement)
        if natural {
            speedFactor = min(max(speedFactor + Double.random(in: -0.04...0.04), 0.85), 1.15)
        } else {
            speedFactor = 1
        }

        distanceWalked += Self.speedMetersPerSecond * speedFactor * elapsed

        if distanceWalked >= route.totalDistance {
            handleRouteEnd(route)
            guard phase == .walking else { return }
        }

        guard let activeRoute = self.route else { return }
        let point = activeRoute.point(atDistance: distanceWalked)
        currentPoint = point
        sendInBackground(drifted(point))
        persist(force: false)
    }

    private func handleRouteEnd(_ finished: WalkRoute) {
        let overshoot = distanceWalked - finished.totalDistance
        let closed = finished.start.distance(to: finished.end) <= Self.closedLoopTolerance

        switch LoopMode.current {
        case .off:
            distanceWalked = finished.totalDistance
            currentPoint = finished.end
            sendInBackground(finished.end)
            walkTask?.cancel()
            walkTask = nil
            phase = .holding
            startHolding()
            persist(force: true)
            Haptics.medium()
        case .loop where closed:
            distanceWalked = overshoot
        case .loop, .backAndForth:
            route = finished.reversed()
            distanceWalked = overshoot
        }
    }

    /// Adds a slowly wandering offset of a few metres, like real GPS.
    private func drifted(_ point: GeoPoint) -> GeoPoint {
        guard UserDefaults.standard.bool(forKey: UserDefaults.Keys.naturalMovement) else {
            return point
        }
        driftEast = min(max(driftEast * 0.85 + Double.random(in: -0.6...0.6), -3), 3)
        driftNorth = min(max(driftNorth * 0.85 + Double.random(in: -0.6...0.6), -3), 3)
        return point.offset(east: driftEast, north: driftNorth)
    }

    // MARK: - Device I/O

    private static func run(_ work: @escaping () -> Int32) async -> Int32 {
        await withCheckedContinuation { continuation in
            LocationSimulator.queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    /// Sends a point and waits for the result, reporting any failure.
    private func sendNow(_ point: GeoPoint) async -> Bool {
        isBusy = true
        let code = await Self.run { LocationSimulator.set(latitude: point.latitude, longitude: point.longitude) }
        isBusy = false
        guard code == LocationSimulator.Status.ok else {
            errorMessage = "\(LocationSimulator.describe(code)) (error \(code))"
            return false
        }
        errorMessage = nil
        return true
    }

    /// Fire-and-forget update used by the walk and hold loops. Skips the update
    /// if the previous one hasn't finished, so slow links never build a backlog.
    private func sendInBackground(_ point: GeoPoint) {
        guard !sendInFlight else { return }
        sendInFlight = true
        Task { [weak self] in
            let code = await Self.run { LocationSimulator.set(latitude: point.latitude, longitude: point.longitude) }
            guard let self else { return }
            self.sendInFlight = false
            if code == LocationSimulator.Status.ok {
                self.consecutiveFailures = 0
                return
            }
            self.consecutiveFailures += 1
            if self.consecutiveFailures >= 5 {
                self.consecutiveFailures = 0
                self.pause()
                self.errorMessage = "Lost connection to the device, so the walk was paused. \(LocationSimulator.describe(code)) (error \(code))"
            }
        }
    }

    private func cancelTasks() {
        walkTask?.cancel()
        walkTask = nil
        holdTask?.cancel()
        holdTask = nil
    }

    // MARK: - Keep alive

    private func acquireKeepAlive() {
        guard !keepAliveHeld else { return }
        keepAliveHeld = true
        BackgroundLocationManager.shared.requestStart()
        BackgroundAudioManager.shared.requestStart()
    }

    private func releaseKeepAlive() {
        guard keepAliveHeld else { return }
        keepAliveHeld = false
        BackgroundLocationManager.shared.requestStop()
        BackgroundAudioManager.shared.requestStop()
    }

    // MARK: - Persistence

    private func persist(force: Bool) {
        let now = Date()
        guard force || now.timeIntervalSince(lastPersist) >= 5 else { return }
        lastPersist = now

        guard let currentPoint else { return }
        let session = SavedSession(
            kind: isMoving ? .walking : .holding,
            point: currentPoint,
            route: route,
            distanceWalked: distanceWalked,
            savedAt: now
        )
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: Self.sessionKey)
        }
    }

    private func clearPersistedSession() {
        UserDefaults.standard.removeObject(forKey: Self.sessionKey)
    }
}
