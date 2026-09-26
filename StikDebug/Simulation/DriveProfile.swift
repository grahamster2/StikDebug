//
//  DriveProfile.swift
//  Wander
//
//  What a realistic drive needs to know about a route, keyed by distance
//  along it: each road's speed limit, how fast each corner can be taken,
//  and where the stop signs and traffic lights are.
//

import Foundation
import CoreLocation

struct DriveProfile: Codable, Equatable {
    struct Segment: Codable, Equatable {
        var start: CLLocationDistance
        var end: CLLocationDistance
        /// Speed limit (or a typical speed for the road type) in m/s.
        var limit: CLLocationSpeed
        var name: String?
        /// True when the limit came from a posted speed limit, not a guess.
        var isPosted: Bool
    }

    /// The fastest a corner at `distance` can be driven.
    struct Cap: Codable, Equatable {
        var distance: CLLocationDistance
        var speed: CLLocationSpeed
    }

    enum StopKind: String, Codable {
        case stopSign
        case trafficSignal
        case yield
    }

    struct Stop: Codable, Equatable {
        var distance: CLLocationDistance
        var kind: StopKind
    }

    var segments: [Segment] = []
    var caps: [Cap] = []
    var stops: [Stop] = []

    /// Whether road speeds were looked up. Without them only corners are known.
    var hasRoadSpeeds: Bool { !segments.isEmpty }

    func segment(at distance: CLLocationDistance) -> Segment? {
        guard !segments.isEmpty else { return nil }
        var low = 0
        var high = segments.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if segments[mid].start <= distance {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return segments[low]
    }

    func reversed(totalDistance total: CLLocationDistance) -> DriveProfile {
        DriveProfile(
            segments: segments.reversed().map {
                Segment(start: total - $0.end, end: total - $0.start, limit: $0.limit, name: $0.name, isPosted: $0.isPosted)
            },
            caps: caps.reversed().map { Cap(distance: total - $0.distance, speed: $0.speed) },
            // Stop signs usually only face one way; drop them when turning around
            // rather than stopping at signs meant for the other direction.
            stops: stops.reversed().filter { $0.kind == .trafficSignal }.map {
                Stop(distance: total - $0.distance, kind: $0.kind)
            }
        )
    }

    /// Rough driving time for the rest of the route (without stops).
    func estimatedTime(
        from distance: CLLocationDistance,
        totalDistance total: CLLocationDistance,
        style: Double,
        fallbackSpeed: CLLocationSpeed
    ) -> TimeInterval {
        guard hasRoadSpeeds else {
            return max(total - distance, 0) / fallbackSpeed * 1.1
        }
        var time: TimeInterval = 0
        for segment in segments where segment.end > distance {
            let length = segment.end - max(segment.start, distance)
            time += length / max(segment.limit * style, 2)
        }
        let upcomingStops = stops.filter { $0.distance > distance && $0.kind != .yield }.count
        // Corners, acceleration and the odd red light add up.
        return time * 1.12 + Double(upcomingStops) * 6
    }

    // MARK: - Corners

    /// Finds corners from the route's shape and how fast each can be taken,
    /// using the turn radius and a comfortable sideways acceleration.
    static func cornerCaps(for route: WalkRoute) -> [Cap] {
        let window: CLLocationDistance = 10
        let lateralAcceleration = 2.8
        let total = route.totalDistance
        guard total > window * 2 else { return [] }

        var raw: [Cap] = []
        var distance = window
        while distance < total - window {
            let before = route.point(atDistance: distance - window)
            let here = route.point(atDistance: distance)
            let after = route.point(atDistance: distance + window)
            let turn = abs(angleBetween(bearing(from: before, to: here), bearing(from: here, to: after)))
            if turn > 12 {
                let radians = turn * .pi / 180
                let radius = (window * 2) / radians
                let speed = max(sqrt(lateralAcceleration * radius), 3)
                if speed < 30 {
                    raw.append(Cap(distance: distance, speed: speed))
                }
            }
            distance += 4
        }

        // Keep only the slowest point of each corner.
        var caps: [Cap] = []
        for cap in raw {
            if let last = caps.last, cap.distance - last.distance < 25 {
                if cap.speed < last.speed {
                    caps[caps.count - 1] = cap
                }
            } else {
                caps.append(cap)
            }
        }
        return caps
    }

    static func bearing(from a: GeoPoint, to b: GeoPoint) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        return atan2(y, x) * 180 / .pi
    }

    /// Signed difference between two bearings, in -180...180.
    static func angleBetween(_ a: Double, _ b: Double) -> Double {
        var difference = (b - a).truncatingRemainder(dividingBy: 360)
        if difference > 180 { difference -= 360 }
        if difference < -180 { difference += 360 }
        return difference
    }
}
