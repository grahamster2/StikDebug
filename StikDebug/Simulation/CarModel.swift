//
//  CarModel.swift
//  Wander
//
//  Moves a car along a route with a drive profile: cruises near each road's
//  limit, brakes ahead of corners, lower limits and stops, pulls away
//  gradually, and waits at stop signs and red lights.
//

import Foundation
import CoreLocation

struct CarModel {
    struct Settings {
        /// Multiplier on each road's limit (0.85 relaxed … 1.15 aggressive).
        var style: Double
        /// Cruise speed when road limits aren't known.
        var fallbackSpeed: CLLocationSpeed
        var stopAtSignsAndLights: Bool
        var brakeForEnd: Bool
        var natural: Bool
    }

    enum Waiting: Equatable {
        case stopSign
        case redLight
    }

    private(set) var speed: CLLocationSpeed = 0
    private(set) var waiting: Waiting?
    private(set) var waitRemaining: TimeInterval = 0

    private var nextStopIndex = 0
    /// How long each light will be red when we reach it (0 = green), decided
    /// once when it comes into view.
    private var lightTimings: [Int: TimeInterval] = [:]
    private var cruiseFactor = 1.0

    private static let comfortableBraking = 2.4
    private static let hardBraking = 4.5
    private static let creepSpeed = 1.2
    private static let stopLineOffset: CLLocationDistance = 3
    private static let redLightChance = 0.4

    /// Starts over from a standstill (new route, resume, turnaround).
    mutating func reset() {
        speed = 0
        waiting = nil
        waitRemaining = 0
        nextStopIndex = 0
        lightTimings = [:]
    }

    /// Keeps the current speed but forgets per-route state (redirects).
    mutating func routeChanged() {
        waiting = nil
        waitRemaining = 0
        nextStopIndex = 0
        lightTimings = [:]
    }

    /// Moves the car forward by `elapsed` seconds and returns the new distance.
    mutating func advance(
        from startDistance: CLLocationDistance,
        by elapsed: TimeInterval,
        profile: DriveProfile,
        totalDistance total: CLLocationDistance,
        settings: Settings
    ) -> CLLocationDistance {
        if settings.natural {
            cruiseFactor = min(max(cruiseFactor + Double.random(in: -0.015...0.015), 0.95), 1.05)
        } else {
            cruiseFactor = 1
        }

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

        var target = (profile.segment(at: distance).map { $0.limit * settings.style } ?? settings.fallbackSpeed) * cruiseFactor
        let horizon = speed * speed / (2 * braking) + 80

        for cap in profile.caps {
            let gap = cap.distance - distance
            if gap > horizon { break }
            if gap > -8 {
                // Ahead, or still in the middle of the corner.
                target = min(target, gap > 0 ? approach(cap.speed, in: gap) : cap.speed)
            }
        }

        if profile.hasRoadSpeeds {
            for segment in profile.segments where segment.start > distance {
                let gap = segment.start - distance
                if gap > horizon { break }
                target = min(target, approach(segment.limit * settings.style * cruiseFactor, in: gap))
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
}
