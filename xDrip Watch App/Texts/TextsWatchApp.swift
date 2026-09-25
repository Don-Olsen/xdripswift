//
//  TextsWatchApp.swift
//  xDrip Watch App
//
//  Created by Paul Plant on 27/4/24.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//

import Foundation

/// all Nightscout related texts
class Texts_WatchApp {
    static private let filename = "WatchApp"
    
    static let requestingData: String = {
        return NSLocalizedString("requestingData", tableName: filename, bundle: Bundle.main, value: "Requesting data...", comment: "watch app - text for requesting data")
    }()
    
    static let lastReading: String = {
        return NSLocalizedString("lastReading", tableName: filename, bundle: Bundle.main, value: "Last reading", comment: "watch app - text for last reading")
    }()
    
    static let noSensorData: String = {
        return NSLocalizedString("noSensorData", tableName: filename, bundle: Bundle.main, value: "No sensor data", comment: "watch app - text for no sensor data")
    }()

    static func directConnectionTitle(_ presentation: LibreWatchConnectionPresentation) -> String {
        let key: String
        let fallback: String
        switch presentation.connection {
        case .phone: (key, fallback) = ("librePhoneOwnsSensor", "Sensor on iPhone")
        case .takingOver: (key, fallback) = ("libreTakingOver", "Taking over sensor")
        case .searching: (key, fallback) = ("libreSearching", "Searching for sensor")
        case .connecting: (key, fallback) = ("libreConnecting", "Connecting to sensor")
        case .reconnecting: (key, fallback) = ("libreReconnecting", "Reconnecting to sensor")
        case .returningToPhone: (key, fallback) = ("libreReturning", "Returning sensor to iPhone")
        case .unavailable: (key, fallback) = ("libreUnavailable", "Set up sensor on iPhone")
        case .failed: (key, fallback) = ("libreConnectionFailed", "Sensor connection needs attention")
        case .connected:
            switch presentation.reading {
            case .current: (key, fallback) = ("libreConnected", "Sensor connected")
            case .stale: (key, fallback) = ("libreConnectedStale", "Connected · no new readings")
            case .waiting, .notDirect: (key, fallback) = ("libreConnectedWaiting", "Connected · waiting for reading")
            }
        }
        return NSLocalizedString(key, tableName: filename, bundle: .main, value: fallback,
            comment: "Watch direct sensor connection; distinct from measurement freshness")
    }

    static func directReadingAge(_ presentation: LibreWatchConnectionPresentation) -> String {
        guard let age = presentation.readingAge else {
            return NSLocalizedString("libreWaitingForFirstReading", tableName: filename, bundle: .main,
                value: "Waiting for first Watch reading", comment: "No final direct Watch reading yet")
        }
        let ageText: String
        if age < 60 {
            ageText = NSLocalizedString("libreReadingLessThanMinute", tableName: filename, bundle: .main,
                value: "<1 min", comment: "Age of latest Watch reading, less than one minute")
        } else {
            let format = NSLocalizedString("libreReadingMinutes", tableName: filename, bundle: .main,
                value: "%ld min", comment: "Age of latest Watch reading in whole minutes")
            ageText = String(format: format, Int(age / 60))
        }
        let format = NSLocalizedString("libreLastReadingAge", tableName: filename, bundle: .main,
            value: "Last reading: %@", comment: "Label and age of latest direct Watch measurement")
        return String(format: format, ageText)
    }

}
