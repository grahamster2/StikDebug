//
//  Planner.swift
//  Wander
//
//  Everything the user is setting up on the map before (or while) the engine
//  runs it: a pin to jump to, a walk destination, or a hand-drawn route.
//

import Foundation
import CoreLocation

enum PlanMode: String, CaseIterable, Identifiable {
    case pin
    case walk
    case draw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pin: return "Jump"
        case .walk: return "Route"
        case .draw: return "Draw"
        }
    }

    var systemImage: String {
        switch self {
        case .pin: return "mappin"
        case .walk: return "arrow.triangle.turn.up.right.diamond"
        case .draw: return "scribble.variable"
        }
    }
}

@MainActor
final class Planner: ObservableObject {
    @Published var mode: PlanMode = .walk {
        didSet { if mode != oldValue { modeChanged() } }
    }

    /// Jump mode target.
    @Published var pin: Place?
    /// Walk mode start, used only when nothing is being simulated yet.
    @Published var walkStart: Place?
    @Published var destination: Place?
    /// Draw mode points, in order.
    @Published var waypoints: [GeoPoint] = []

    @Published private(set) var preview: WalkRoute?
    @Published private(set) var isPlanning = false
    /// Road speeds are still loading for the previewed route. The route can
    /// already be started; the speeds switch on when they arrive.
    @Published private(set) var isLoadingRoadData = false
    /// What planning is doing right now, e.g. looking up speed limits.
    @Published private(set) var planningStatus = "Finding a route…"
    /// Non-fatal note about the plan, e.g. road data being unavailable.
    @Published var planNotice: String?
    @Published var planError: String?

    private var planTask: Task<Void, Never>?
    private var loadingRoadDataFor: [GeoPoint]?
    private let engine: SimulationEngine

    init() {
        engine = .shared
    }

    /// Where a new walk begins: the current simulated position if there is one.
    var effectiveStart: GeoPoint? {
        engine.currentPoint ?? walkStart?.point
    }

    var needsStartPoint: Bool {
        mode == .walk && engine.currentPoint == nil && walkStart == nil
    }

    var hint: String {
        switch mode {
        case .pin:
            return pin == nil ? "Tap the map or search to drop a pin." : "Tap Jump Here to move there instantly."
        case .walk:
            if engine.isMoving {
                return "Tap the map to change where you're going."
            }
            if needsStartPoint {
                return "Tap the map to choose where to start."
            }
            return destination == nil ? "Tap the map or search for a destination." : "Ready to go."
        case .draw:
            if waypoints.isEmpty {
                return engine.currentPoint == nil
                    ? "Tap the map to place the first point of your route."
                    : "Tap the map to add points. The route starts where you are."
            }
            return "Keep tapping to add points."
        }
    }

    // MARK: - Input

    func handleTap(_ point: GeoPoint) {
        planError = nil
        switch mode {
        case .pin:
            pin = Place(name: point.formatted, point: point)
        case .walk:
            if needsStartPoint {
                walkStart = Place(name: "Start", point: point)
            } else {
                setDestination(Place(name: point.formatted, point: point))
            }
        case .draw:
            guard !engine.isMoving else { return }
            if waypoints.isEmpty, let current = engine.currentPoint {
                waypoints = [current]
            }
            waypoints.append(point)
            rebuild()
        }
    }

    /// Search results and favourites go wherever makes sense for the mode.
    func handlePlace(_ place: Place) {
        planError = nil
        switch mode {
        case .pin:
            pin = place
        case .walk:
            setDestination(place)
        case .draw:
            handleTap(place.point)
        }
    }

    func setDestination(_ place: Place) {
        destination = place
        rebuild()
    }

    func undoWaypoint() {
        guard !waypoints.isEmpty else { return }
        waypoints.removeLast()
        if waypoints.count == 1, waypoints.first == engine.currentPoint {
            waypoints = []
        }
        rebuild()
    }

    func clear() {
        planTask?.cancel()
        pin = nil
        walkStart = nil
        destination = nil
        waypoints = []
        preview = nil
        isPlanning = false
        planError = nil
        planNotice = nil
    }

    /// Loads an imported GPX (or similar) track as a drawn route.
    func loadImportedTrack(_ points: [GeoPoint]) {
        mode = .draw
        waypoints = points
        guard let route = WalkRoute(points: points) else {
            planError = "That file didn't contain a usable route."
            return
        }
        planTask?.cancel()
        preview = route
    }

    /// Recomputes the preview route after anything that affects it changes.
    func rebuild() {
        planTask?.cancel()
        preview = nil
        if !SimulationEngine.shared.isMoving {
            loadingRoadDataFor = nil
            isLoadingRoadData = false
        }

        let loop = LoopMode.current
        let travel = TravelMode.current
        let followPaths = UserDefaults.standard.bool(forKey: UserDefaults.Keys.followPaths)

        let request: (() async throws -> WalkRoute)?
        switch mode {
        case .pin:
            request = nil
        case .walk:
            if let start = effectiveStart, let end = destination?.point {
                request = { try await RoutePlanner.directions(from: start, to: end, mode: travel) }
            } else {
                request = nil
            }
        case .draw:
            if waypoints.count >= 2 {
                let points = waypoints
                request = { try await RoutePlanner.route(through: points, followPaths: followPaths, mode: travel) }
            } else {
                request = nil
            }
        }

        guard let request else {
            isPlanning = false
            return
        }

        isPlanning = true
        planningStatus = "Finding a route…"
        planNotice = nil
        let realistic = travel == .drive && UserDefaults.standard.bool(forKey: UserDefaults.Keys.realisticDriving)
        planTask = Task { [weak self] in
            do {
                var route = try await request()
                // "Loop to start" needs a way back; plan it now so the walker
                // doesn't teleport when it wraps around.
                if loop == .loop, route.start.distance(to: route.end) > 25 {
                    let back: WalkRoute
                    if followPaths || self?.mode == .walk {
                        back = try await RoutePlanner.directions(from: route.end, to: route.start, mode: travel)
                    } else {
                        back = WalkRoute(points: [route.end, route.start])!
                    }
                    route = route.appending(back)
                }
                if realistic {
                    // Corners are instant; road speeds come from the network.
                    route.driveProfile = DriveProfile(caps: DriveProfile.cornerCaps(for: route))
                }
                guard !Task.isCancelled, let self else { return }
                self.preview = route
                self.isPlanning = false
                if realistic {
                    self.loadRoadData(for: route)
                }
                self.applySpeedEstimate(route, travel: travel)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isPlanning = false
                self.planError = error.localizedDescription
            }
        }
    }

    /// Driving routes start at Apple Maps' average speed for that route
    /// (slower in town, faster on highways). The slider can still override it.
    private func applySpeedEstimate(_ route: WalkRoute, travel: TravelMode) {
        guard travel == .drive,
              route.driveProfile?.hasRoadSpeeds != true,
              UserDefaults.standard.bool(forKey: UserDefaults.Keys.useRouteSpeedEstimate),
              let speed = route.estimatedSpeed, speed > 0 else { return }
        let kmh = (speed * 3.6).rounded()
        let clamped = min(max(kmh, travel.speedRange.lowerBound), travel.speedRange.upperBound)
        UserDefaults.standard.set(clamped, forKey: travel.speedKey)
    }

    /// Fetches road speeds in the background and applies them to the preview
    /// and, if it has already been started, to the running route. Not tied to
    /// the planning task, so starting the drive doesn't cancel it.
    private func loadRoadData(for route: WalkRoute) {
        let points = route.points
        loadingRoadDataFor = points
        isLoadingRoadData = true
        Task { [weak self] in
            let result = await RoadSpeedService.profile(for: route)
            guard let self else { return }
            SimulationEngine.shared.applyDriveProfile(result.profile, toRouteWith: points)
            if self.preview?.points == points {
                self.preview?.driveProfile = result.profile
            }
            // Only the most recently planned route drives the loading indicator.
            guard self.loadingRoadDataFor == points else { return }
            self.loadingRoadDataFor = nil
            self.isLoadingRoadData = false
            if let problem = result.problem {
                self.planNotice = "\(problem) Using a fixed speed with slowing for corners instead."
            }
        }
    }

    private func modeChanged() {
        planTask?.cancel()
        preview = nil
        isPlanning = false
        planError = nil
        planNotice = nil
        rebuild()
    }
}
