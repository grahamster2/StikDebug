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
        static let walkingSpeedKmh = "walkingSpeedKmh"
        static let naturalMovement = "naturalMovement"
        static let loopMode = "loopMode"
        static let followPaths = "followPaths"
    }
}
