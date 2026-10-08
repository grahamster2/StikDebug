//
//  AppBootstrapper.swift
//  StikDebug
//

import Foundation
import ObjectiveC.runtime
import UIKit

enum AppBootstrapper {
    static func configure() {
        registerDefaultSettings()
        applyDocumentPickerCopyWorkaround()
    }

    private static func registerDefaultSettings() {
        UserDefaults.standard.register(defaults: [
            UserDefaults.Keys.keepAliveAudio: true,
            UserDefaults.Keys.keepAliveLocation: true,
            UserDefaults.Keys.walkingSpeedKmh: TravelMode.walk.defaultSpeedKmh,
            UserDefaults.Keys.cyclingSpeedKmh: TravelMode.cycle.defaultSpeedKmh,
            UserDefaults.Keys.drivingSpeedKmh: TravelMode.drive.defaultSpeedKmh,
            UserDefaults.Keys.useRouteSpeedEstimate: true,
            UserDefaults.Keys.realisticDriving: true,
            UserDefaults.Keys.stopAtSignsAndLights: true,
            UserDefaults.Keys.drivingOverspeedKmh: 8.0,
            UserDefaults.Keys.trafficEvents: true,
            UserDefaults.Keys.naturalMovement: true,
            UserDefaults.Keys.followPaths: true
        ])
    }

    private static func applyDocumentPickerCopyWorkaround() {
        let fixedSelector = NSSelectorFromString("fix_initForOpeningContentTypes:asCopy:")
        let originalSelector = #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:))

        guard let fixedMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, fixedSelector),
              let originalMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, originalSelector) else {
            return
        }

        method_exchangeImplementations(originalMethod, fixedMethod)
    }
}
