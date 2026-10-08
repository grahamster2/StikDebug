//
//  CarModel.swift
//  Drift
//
//  Moves a car along a route with a drive profile. Cruises a little over each
//  road's limit, eases off through bends and back on along straights, drifts
//  around its cruise speed, occasionally gets held up by traffic, brakes for
//  lower limits, and waits at stop signs and red lights.
//

import Foundation
import CoreLocation

struct CarModel {
    struct Settings {
        /// How far over each road's posted limit this driver cruises, in m/s.
        /// Negative means habitually under the limit.
        var overspeed: CLLocationSpeed
        /// Cruise speed when road limits aren't known.
        var fallbackSpeed: CLLocationSpeed
        var stopAtSignsAndLights: Bool
        /// Occasional hold-ups: a slow car ahead, someone pulling out, parking.
        var trafficEvents: Bool
        var brakeForEnd: Bool
        /// Drift around the cruise speed instead of holding it exactly.
        var natural: Bool
    }

    enum Waiting: Equatable {
        case stopSign
        case redLight
    }

    private(set) var speed: CLLocationSpeed = 0
    private(set) var waiting: Waiting?
    private(set) var waitRemaining: TimeInterval = 0
    /// True while a traffic hold-up is slowing the car.
    private(set) var isHeldUp = false

    private var nextStopIndex = 0
    /// How long each light will be red when we reach it (0 = green), decided
    /// once when it comes into view.
    private var lightTimings: [Int: TimeInterval] = [:]
    /// Slow wander around the cruise speed, in m/s.
    private var cruiseOffset = 0.0
    private var trafficFactor = 1.0
    private var trafficRemaining: TimeInterval = 0

    private static let comfortableBraking = 2.4
    private static let hardBraking = 4.5
    private static let creepSpeed = 1.2
    private static let stopLineOffset: CLLocationDistance = 3
    private static let redLightChance = 0.4

    // Ornstein–Uhlenbeck wander: pulls back to zero with time constant 1/theta
    // (~7 s) and settles at a spread of sigma/sqrt(2*theta) ≈ 1.4 m/s (~3 mph).
    private static let wanderPull = 0.15
    private static let wanderNoise = 0.75
    private static let wanderLimit = 3.5

    /// Starts over from a standstill (new route, resume, turnaround).
    mutating func reset() {
        speed = 0
        waiting = nil
        waitRemaining = 0
        nextStopIndex = 0
        lightTimings = [:]
        cruiseOffset = 0
        clearTraffic()
    }

    /// Keeps the current speed but forgets per-route state (redirects).
    mutating func routeChanged() {
        waiting = nil
        waitRemaining = 0
        nextStopIndex = 0
        lightTimings = [:]
        clearTraffic()
    }

    private mutating func clearTraffic() {
        trafficFactor = 1
        trafficRemaining = 0
        isHeldUp = false
    }

    /// Moves the car forward by `elapsed` seconds and returns the new distance.
    mutating func advance(
        from startDistance: CLLocationDistance,
        by elapsed: TimeInterval,
        profile: DriveProfile,
        totalDistance total: CLLocationDistance,
        settings: Settings
    ) -> CLLocationDistance {
        var distance = startDistance
        var remaining = elapsed
        while remaining > 0.0001 {
            let dt = min(0.1, remaining)
            remaining -= dt

            if waitRemaining > 0 {
                waitRemaining -= dt
                speed = 0
                if waitRemaining <= 0 {
                    waiting = nil
                }
                continue
            }

            distance = step(from: distance, dt: dt, profile: profile, total: total, settings: settings)
        }
        return min(distance, total)
    }

    private mutating func step(
        from distance: CLLocationDistance,
        dt: TimeInterval,
        profile: DriveProfile,
        total: CLLocationDistance,
        settings: Settings
    ) -> CLLocationDistance {
        let stops = profile.stops
        while nextStopIndex < stops.count, stops[nextStopIndex].distance < distance - 1 {
            nextStopIndex += 1
        }

        let braking = Self.comfortableBraking
        /// Fastest speed now that still lets us slow to `speed` over `gap` metres.
        func approach(_ speed: CLLocationSpeed, in gap: CLLocationDistance) -> CLLocationSpeed {
            (speed * speed + 2 * braking * max(gap, 0)).squareRoot()
        }

        let roadLimit = profile.segment(at: distance)?.limit
        var target = roadLimit.map { $0 + Self.overspeed(for: $0, settings: settings) }
            ?? settings.fallbackSpeed

        if settings.natural {
            cruiseOffset += -cruiseOffset * Self.wanderPull * dt
                + Self.wanderNoise * dt.squareRoot() * Self.gaussian()
            cruiseOffset = min(max(cruiseOffset, -Self.wanderLimit), Self.wanderLimit)
            target += cruiseOffset
        } else {
            cruiseOffset = 0
        }

        if settings.trafficEvents {
            updateTraffic(dt: dt, roadLimit: roadLimit ?? settings.fallbackSpeed)
            target *= trafficFactor
        } else if trafficFactor != 1 {
            clearTraffic()
        }

        let horizon = speed * speed / (2 * braking) + 80
        // A keener driver carries more speed through bends.
        let cornering = Self.corneringFactor(settings: settings)

        for cap in profile.caps {
            let gap = cap.distance - distance
            if gap > horizon { break }
            if gap > -8 {
                let capSpeed = cap.speed * cornering
                // Ahead, or still in the middle of the corner.
                target = min(target, gap > 0 ? approach(capSpeed, in: gap) : capSpeed)
            }
        }

        if profile.hasRoadSpeeds {
            for segment in profile.segments where segment.start > distance {
                let gap = segment.start - distance
                if gap > horizon { break }
                let cruise = segment.limit + Self.overspeed(for: segment.limit, settings: settings)
                target = min(target, approach(cruise, in: gap))
            }
        }

        var stopLine: (distance: CLLocationDistance, index: Int)?
        if settings.stopAtSignsAndLights {
            var index = nextStopIndex
            while index < stops.count, stops[index].distance - distance <= horizon {
                let stop = stops[index]
                var mustStop = false
                switch stop.kind {
                case .yield:
                    target = min(target, approach(4, in: stop.distance - distance))
                case .stopSign:
                    mustStop = true
                case .trafficSignal:
                    if lightTimings[index] == nil {
                        lightTimings[index] = Double.random(in: 0..<1) < Self.redLightChance ? Double.random(in: 8...35) : 0
                    }
                    mustStop = (lightTimings[index] ?? 0) > 0
                }
                if mustStop {
                    let line = stop.distance - Self.stopLineOffset
                    stopLine = (line, index)
                    target = min(target, approach(0, in: line - distance))
                    break
                }
                index += 1
            }
        }

        if settings.brakeForEnd {
            target = min(target, approach(0, in: total - distance))
        }

        // Keep rolling slowly so we actually reach stop lines and the end.
        target = max(target, Self.creepSpeed)

        if speed < target {
            // Pull away briskly, with less acceleration at higher speeds.
            let acceleration = max(0.7, 3.0 - speed * 0.075)
            speed = min(target, speed + acceleration * dt)
        } else {
            speed = max(target, speed - Self.hardBraking * dt)
        }

        var next = distance + speed * dt
        if let stopLine, next >= stopLine.distance {
            next = max(distance, stopLine.distance)
            speed = 0
            if stops[stopLine.index].kind == .stopSign {
                waiting = .stopSign
                waitRemaining = Double.random(in: 1.5...3.5)
            } else {
                waiting = .redLight
                waitRemaining = lightTimings[stopLine.index] ?? 0
            }
            nextStopIndex = stopLine.index + 1
        }
        return next
    }

    // MARK: - Driver character

    /// How far over this particular limit the driver actually goes. The offset
    /// is held back on slow roads, where +10 mph on a 25 would be absurd.
    private static func overspeed(for limit: CLLocationSpeed, settings: Settings) -> CLLocationSpeed {
        settings.overspeed >= 0
            ? min(settings.overspeed, limit * 0.5)
            : max(settings.overspeed, -limit * 0.35)
    }

    /// Scales the geometric corner ceiling: someone happy to speed also takes
    /// bends harder. Caps are built at a neutral sideways acceleration.
    private static func corneringFactor(settings: Settings) -> Double {
        min(max(1 + settings.overspeed * 0.035, 0.88), 1.14)
    }

    // MARK: - Traffic

    /// Chance per second of being held up, by how built-up the road is.
    private static func holdUpChance(roadLimit: CLLocationSpeed) -> Double {
        switch roadLimit {
        case ..<13.5: return 0.011   // residential / town streets
        case ..<22: return 0.005     // main roads
        default: return 0.0018       // highway
        }
    }

    private mutating func updateTraffic(dt: TimeInterval, roadLimit: CLLocationSpeed) {
        if trafficRemaining > 0 {
            trafficRemaining -= dt
            if trafficRemaining <= 0 {
                clearTraffic()
            }
            return
        }

        guard waiting == nil else { return }
        guard Double.random(in: 0..<1) < Self.holdUpChance(roadLimit: roadLimit) * dt else { return }

        if roadLimit < 22 {
            // Someone turning, parking, or a pedestrian: a real drop.
            trafficFactor = Double.random(in: 0.40...0.72)
            trafficRemaining = Double.random(in: 5...18)
        } else {
            // Highway bunching: lift off rather than brake hard.
            trafficFactor = Double.random(in: 0.62...0.86)
            trafficRemaining = Double.random(in: 10...30)
        }
        isHeldUp = true
    }

    // MARK: - Noise

    /// Standard normal sample (Box–Muller).
    private static func gaussian() -> Double {
        let u1 = max(Double.random(in: 0..<1), 1e-9)
        let u2 = Double.random(in: 0..<1)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
