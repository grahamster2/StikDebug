//
//  WalkRoute.swift
//  Wander
//

import CoreLocation
import MapKit

struct GeoPoint: Codable, Hashable {
    var latitude: Double
    var longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isValid: Bool {
        CLLocationCoordinate2DIsValid(coordinate)
    }

    func distance(to other: GeoPoint) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }

    func interpolated(to other: GeoPoint, fraction: Double) -> GeoPoint {
        GeoPoint(
            latitude: latitude + (other.latitude - latitude) * fraction,
            longitude: longitude + (other.longitude - longitude) * fraction
        )
    }

    /// Moves the point by a small offset in metres (east, north).
    func offset(east: Double, north: Double) -> GeoPoint {
        let metersPerDegreeLatitude = 111_320.0
        let metersPerDegreeLongitude = max(metersPerDegreeLatitude * cos(latitude * .pi / 180), 1)
        return GeoPoint(
            latitude: latitude + north / metersPerDegreeLatitude,
            longitude: longitude + east / metersPerDegreeLongitude
        )
    }

    var formatted: String {
        String(format: "%.6f, %.6f", latitude, longitude)
    }
}

/// A polyline with cumulative distances, so a position can be looked up by
/// "metres walked so far".
struct WalkRoute: Codable, Equatable {
    let points: [GeoPoint]
    let cumulative: [CLLocationDistance]
    /// Apple Maps' average speed for driving routes, if known.
    var estimatedSpeed: CLLocationSpeed?

    init?(points rawPoints: [GeoPoint]) {
        var points: [GeoPoint] = []
        for point in rawPoints where point.isValid {
            if let last = points.last, last.distance(to: point) < 0.05 { continue }
            points.append(point)
        }
        guard points.count >= 2 else { return nil }

        var cumulative = [0.0]
        for (start, end) in zip(points, points.dropFirst()) {
            cumulative.append(cumulative[cumulative.count - 1] + start.distance(to: end))
        }
        self.points = points
        self.cumulative = cumulative
    }

    var totalDistance: CLLocationDistance { cumulative.last ?? 0 }
    var start: GeoPoint { points[0] }
    var end: GeoPoint { points[points.count - 1] }

    func point(atDistance distance: CLLocationDistance) -> GeoPoint {
        if distance <= 0 { return start }
        if distance >= totalDistance { return end }

        // First index whose cumulative distance is >= distance.
        var low = 1
        var high = cumulative.count - 1
        while low < high {
            let mid = (low + high) / 2
            if cumulative[mid] < distance {
                low = mid + 1
            } else {
                high = mid
            }
        }
        let segmentStart = cumulative[low - 1]
        let segmentLength = cumulative[low] - segmentStart
        let fraction = segmentLength > 0 ? (distance - segmentStart) / segmentLength : 0
        return points[low - 1].interpolated(to: points[low], fraction: fraction)
    }

    /// The part of the route already walked, ending exactly at `distance`.
    func walkedPortion(upTo distance: CLLocationDistance) -> [GeoPoint] {
        guard distance > 0 else { return [] }
        var result = [start]
        for index in 1..<points.count where cumulative[index] < distance {
            result.append(points[index])
        }
        result.append(point(atDistance: distance))
        return result
    }

    /// The part still to walk, starting exactly at `distance`.
    func remainingPortion(from distance: CLLocationDistance) -> [GeoPoint] {
        var result = [point(atDistance: distance)]
        for index in 1..<points.count where cumulative[index] > distance {
            result.append(points[index])
        }
        return result
    }

    func reversed() -> WalkRoute {
        var route = WalkRoute(points: points.reversed())!
        route.estimatedSpeed = estimatedSpeed
        return route
    }

    /// Joins routes end to end (used for multi-waypoint and round-trip routes).
    func appending(_ other: WalkRoute) -> WalkRoute {
        var route = WalkRoute(points: points + other.points)!
        route.estimatedSpeed = estimatedSpeed ?? other.estimatedSpeed
        return route
    }
}

extension Array where Element == GeoPoint {
    var coordinates: [CLLocationCoordinate2D] { map(\.coordinate) }
}

extension MKPolyline {
    var geoPoints: [GeoPoint] {
        var coordinates = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            count: pointCount
        )
        getCoordinates(&coordinates, range: NSRange(location: 0, length: pointCount))
        return coordinates.map(GeoPoint.init)
    }
}
