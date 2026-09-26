//
//  RoutePlanner.swift
//  Drift
//

import MapKit

enum RoutePlanner {
    enum PlanError: LocalizedError {
        case noRoute
        case tooFewPoints

        var errorDescription: String? {
            switch self {
            case .noRoute: return "Apple Maps couldn't find a route between those points."
            case .tooFewPoints: return "Add at least two points to make a route."
            }
        }
    }

    /// Directions between two points along paths (walk/bike) or roads (drive).
    static func directions(from start: GeoPoint, to end: GeoPoint, mode: TravelMode) async throws -> WalkRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end.coordinate))
        request.transportType = mode.transportType
        request.requestsAlternateRoutes = false

        let response = try await MKDirections(request: request).calculate()
        guard let mkRoute = response.routes.first else {
            throw PlanError.noRoute
        }
        // Directions start and end on the nearest path; bridge the gaps so the
        // route begins exactly where the user is and ends exactly on the pin.
        guard var route = WalkRoute(points: [start] + mkRoute.polyline.geoPoints + [end]) else {
            throw PlanError.noRoute
        }
        if mkRoute.expectedTravelTime > 0 {
            route.estimatedSpeed = mkRoute.distance / mkRoute.expectedTravelTime
        }
        return route
    }

    /// A route through every waypoint in order, either following paths or in
    /// straight lines.
    static func route(through waypoints: [GeoPoint], followPaths: Bool, mode: TravelMode) async throws -> WalkRoute {
        guard waypoints.count >= 2 else { throw PlanError.tooFewPoints }

        guard followPaths else {
            guard let route = WalkRoute(points: waypoints) else { throw PlanError.tooFewPoints }
            return route
        }

        var combined: WalkRoute?
        var totalTime: TimeInterval = 0
        for (start, end) in zip(waypoints, waypoints.dropFirst()) {
            try Task.checkCancellation()
            let leg = try await directions(from: start, to: end, mode: mode)
            if let speed = leg.estimatedSpeed, speed > 0 {
                totalTime += leg.totalDistance / speed
            }
            combined = combined.map { $0.appending(leg) } ?? leg
        }
        guard var combined else { throw PlanError.noRoute }
        if totalTime > 0 {
            combined.estimatedSpeed = combined.totalDistance / totalTime
        }
        return combined
    }
}
