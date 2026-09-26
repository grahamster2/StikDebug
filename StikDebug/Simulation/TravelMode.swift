//
//  TravelMode.swift
//  Drift
//

import Foundation
import MapKit

enum TravelMode: String, CaseIterable, Identifiable {
    case walk
    case cycle
    case drive

    var id: String { rawValue }

    static var current: TravelMode {
        TravelMode(rawValue: UserDefaults.standard.string(forKey: UserDefaults.Keys.travelMode) ?? "") ?? .walk
    }

    var title: String {
        switch self {
        case .walk: return "Walk"
        case .cycle: return "Bike"
        case .drive: return "Drive"
        }
    }

    /// "Walking", "Cycling", "Driving".
    var activeTitle: String {
        switch self {
        case .walk: return "Walking"
        case .cycle: return "Cycling"
        case .drive: return "Driving"
        }
    }

    var systemImage: String {
        switch self {
        case .walk: return "figure.walk"
        case .cycle: return "bicycle"
        case .drive: return "car.fill"
        }
    }

    /// Apple Maps has no public cycling directions, so bikes follow walking paths.
    var transportType: MKDirectionsTransportType {
        self == .drive ? .automobile : .walking
    }

    /// Each mode remembers its own speed.
    var speedKey: String {
        switch self {
        case .walk: return UserDefaults.Keys.walkingSpeedKmh
        case .cycle: return UserDefaults.Keys.cyclingSpeedKmh
        case .drive: return UserDefaults.Keys.drivingSpeedKmh
        }
    }

    var defaultSpeedKmh: Double {
        switch self {
        case .walk: return 5
        case .cycle: return 18
        case .drive: return 50
        }
    }

    var speedRange: ClosedRange<Double> {
        switch self {
        case .walk: return 1...15
        case .cycle: return 5...45
        case .drive: return 10...160
        }
    }

    var speedStep: Double {
        self == .drive ? 1 : 0.5
    }

    var presets: [(title: String, kmh: Double)] {
        switch self {
        case .walk: return [("Stroll", 3.5), ("Walk", 5), ("Brisk", 6.5), ("Jog", 9), ("Run", 12)]
        case .cycle: return [("Easy", 12), ("Cruise", 18), ("Fast", 25), ("Race", 35)]
        case .drive: return [("Neighbourhood", 30), ("Town", 50), ("Main road", 70), ("Highway", 105), ("Fast highway", 120)]
        }
    }

    var speedKmh: Double {
        let stored = UserDefaults.standard.double(forKey: speedKey)
        let value = stored > 0 ? stored : defaultSpeedKmh
        return min(max(value, speedRange.lowerBound), speedRange.upperBound)
    }

    var speedMetersPerSecond: CLLocationSpeed {
        speedKmh / 3.6
    }
}
