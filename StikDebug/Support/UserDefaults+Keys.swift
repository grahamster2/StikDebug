//
//  UserDefaults+Keys.swift
//  Wander
//

import Foundation

extension UserDefaults {
    enum Keys {
        static let targetDeviceIP = "TunnelDeviceIP"
        static let keepAliveAudio = "keepAliveAudio"
        static let keepAliveLocation = "keepAliveLocation"
        static let travelMode = "travelMode"
        static let walkingSpeedKmh = "walkingSpeedKmh"
        static let cyclingSpeedKmh = "cyclingSpeedKmh"
        static let drivingSpeedKmh = "drivingSpeedKmh"
        static let useRouteSpeedEstimate = "useRouteSpeedEstimate"
        static let realisticDriving = "realisticDriving"
        static let stopAtSignsAndLights = "stopAtSignsAndLights"
        static let drivingStyle = "drivingStyle"
        static let naturalMovement = "naturalMovement"
        static let loopMode = "loopMode"
        static let followPaths = "followPaths"
    }
}
