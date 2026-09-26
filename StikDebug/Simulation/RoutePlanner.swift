//
//  RoutePlanner.swift
//  Wander
//

import MapKit

enum RoutePlanner {
    enum PlanError: LocalizedError {
        case noRoute
        case tooFewPoints

        var errorDescription: String? {
            switch self {
            case .noRoute: return "Apple Maps couldn't find a walking route between those points."
            case .tooFewPoints: return "Add at least two points to make a route."
            }
        }
    }

    /// Walking directions between two points, following footpaths and streets.
    static func walkingRoute(from start: GeoPoint, to end: GeoPoint) async throws -> WalkRoute {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: end.coordinate))
        request.transportType = .walking
        request.requestsAlternateRoutes = false

        let response = try await MKDirections(request: request).calculate()
        guard let polyline = response.routes.first?.polyline else {
            throw PlanError.noRoute
        }
        // Directions start and end on the nearest path; bridge the gaps so the
        // walk begins exactly where the user is and ends exactly on the pin.
        guard let route = WalkRoute(points: [start] + polyline.geoPoints + [end]) else {
            throw PlanError.noRoute
        }
        return route
    }

    /// A route through every waypoint in order, either following paths or in
    /// straight lines.
    static func route(through waypoints: [GeoPoint], followPaths: Bool) async throws -> WalkRoute {
        guard waypoints.count >= 2 else { throw PlanError.tooFewPoints }

        guard followPaths else {
            guard let route = WalkRoute(points: waypoints) else { throw PlanError.tooFewPoints }
            return route
        }

        var combined: WalkRoute?
        for (start, end) in zip(waypoints, waypoints.dropFirst()) {
            try Task.checkCancellation()
            let leg = try await walkingRoute(from: start, to: end)
            combined = combined.map { $0.appending(leg) } ?? leg
        }
        guard let combined else { throw PlanError.noRoute }
        return combined
    }
}
