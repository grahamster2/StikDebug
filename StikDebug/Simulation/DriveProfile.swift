//
//  DriveProfile.swift
//  Drift
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

    /// Rough driving time for the rest of the route.
    func estimatedTime(
        from distance: CLLocationDistance,
        totalDistance total: CLLocationDistance,
        overspeed: CLLocationSpeed,
        fallbackSpeed: CLLocationSpeed
    ) -> TimeInterval {
        guard hasRoadSpeeds else {
            return max(total - distance, 0) / fallbackSpeed * 1.1
        }
        var time: TimeInterval = 0
        for segment in segments where segment.end > distance {
            let length = segment.end - max(segment.start, distance)
            let cruise = overspeed >= 0
                ? segment.limit + min(overspeed, segment.limit * 0.5)
                : segment.limit + max(overspeed, -segment.limit * 0.35)
            time += length / max(cruise, 2)
        }
        let upcomingStops = stops.filter { $0.distance > distance && $0.kind != .yield }.count
        let upcomingCorners = caps.filter { $0.distance > distance }.count
        // Pulling away, traffic and the odd red light all add up.
        return time * 1.06 + Double(upcomingStops) * 6 + Double(upcomingCorners) * 0.7
    }

    // MARK: - Corners

    /// Sideways acceleration a cap is built for. The car scales these at
    /// runtime, so a keener driver carries more speed through the same bend.
    static let referenceLateralAcceleration = 2.6
    /// Bends that allow more than this are left out, so true straights carry
    /// no entries at all and the car is free to run at the road's limit.
    static let cornerSpeedCeiling: CLLocationSpeed = 36

    /// A geometric speed ceiling along the route, from how tightly it bends.
    /// Picks up long gentle curves as well as junction turns, which is what
    /// keeps the car from holding one speed through a whole winding road.
    static func cornerCaps(for route: WalkRoute) -> [Cap] {
        let window: CLLocationDistance = 12
        let total = route.totalDistance
        guard total > window * 2 else { return [] }

        var raw: [Cap] = []
        var distance = window
        while distance < total - window {
            let before = route.point(atDistance: distance - window)
            let here = route.point(atDistance: distance)
            let after = route.point(atDistance: distance + window)
            let turn = abs(angleBetween(bearing(from: before, to: here), bearing(from: here, to: after)))
            if turn > 3 {
                let radius = (window * 2) / (turn * .pi / 180)
                let speed = max((referenceLateralAcceleration * radius).squareRoot(), 3)
                if speed < cornerSpeedCeiling {
                    raw.append(Cap(distance: distance, speed: speed))
                }
            }
            distance += 5
        }

        // Thin out to the slowest point every 18 m, so a long sweeping bend
        // keeps a sustained ceiling instead of collapsing to one point.
        var caps: [Cap] = []
        for cap in raw {
            if let last = caps.last, cap.distance - last.distance < 18 {
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
