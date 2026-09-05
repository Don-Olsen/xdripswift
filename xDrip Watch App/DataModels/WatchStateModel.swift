//
//  WatchStateModel.swift
//  xDrip Watch App
//
//  Created by Paul Plant on 11/2/24.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//

import Combine
import Foundation
import os
import SwiftUI
import WatchConnectivity
import WidgetKit

/// sensor noise states received from the paired iPhone
private enum WatchSensorNoiseState: Int {
    case collecting = 0
    case low = 1
    case elevated = 2
    case veryHigh = 3
    case extreme = 4
    case flatlineSuspected = 5

    var color: Color {
        switch self {
        case .collecting:
            return .gray
        case .low:
            return .green
        case .elevated:
            return .yellow
        case .veryHigh:
            return .orange
        case .extreme, .flatlineSuspected:
            return .red
        }
    }

    var localizedTitle: String {
        switch self {
        case .collecting:
            return Texts_HomeView.sensorManagementNoiseCollecting
        case .low:
            return Texts_HomeView.sensorManagementNoiseLow
        case .elevated:
            return Texts_HomeView.sensorManagementNoiseElevated
        case .veryHigh:
            return Texts_HomeView.sensorManagementNoiseVeryHigh
        case .extreme:
            return Texts_HomeView.sensorManagementNoiseExtreme
        case .flatlineSuspected:
            return Texts_HomeView.sensorNoiseWarningFlatlineTitle
        }
    }
}

// compact AGP point as received from the iOS app
// this stays as minute-of-day until the Watch maps it onto the visible chart range
private struct WatchAGPProfilePoint {
    let minuteOfDay: Int
    let p5MgDl: Double
    let p25MgDl: Double
    let medianMgDl: Double
    let p75MgDl: Double
    let p95MgDl: Double
}

/// holds, the watch state and allows updates and computed properties/variables to be generated for the different views that use it
/// also used to update the ComplicationSharedUserDefaultsModel in the app group so that the complication can access the data
final class WatchStateModel: NSObject, ObservableObject {
    private let log = Logger(subsystem: "xDrip", category: "WatchStateModel")

    /// the Watch Connectivity session
    var session: WCSession

    // set timer to automatically refresh the view
    // https://www.hackingwithswift.com/quick-start/swiftui/how-to-use-a-timer-with-swiftui
    let timer = Timer.publish(every: 2, tolerance: 0.5, on: .main, in: .common).autoconnect()
    @Published var timerControlDate = Date()

    var bgReadingValues: [Double] = []
    var bgReadingDates: [Date] = []
    var bgReadingDatesAsDouble: [Double] = []
    // AGP points are kept separate from BG readings so the normal main page can stay glucose-only
    // while the second main page renders the same chart with the AGP background enabled
    @Published var agpBackgroundPoints: [GlucoseChartAGPPoint] = []

    // store the compact minute-of-day AGP profile from the iOS app
    // this lets the Watch remap AGP instantly when the chart hours change
    private var agpProfilePoints: [WatchAGPProfilePoint] = []

    // make sure late AGP replies from older requests don't replace newer chart data
    private var latestAGPRequestID: Double = 0

    // keep the latest AGP request if WatchConnectivity is not ready yet
    // this fixes first-load cases where the AGP page appears before the session is reachable
    private var pendingAGPRequestRange: (startDate: Date, endDate: Date)?

    @Published var isMgDl: Bool = true
    @Published var slopeOrdinal: Int = 2
    @Published var deltaValueInUserUnit: Double = 0
    @Published var urgentLowLimitInMgDl: Double = 60
    @Published var lowLimitInMgDl: Double = 80
    @Published var highLimitInMgDl: Double = 170
    @Published var urgentHighLimitInMgDl: Double = 250
    @Published var updatedDate: Date = .now
    @Published var activeSensorDescription: String = ""
    @Published var sensorAgeInMinutes: Double = 0
    @Published var sensorMaxAgeInMinutes: Double = 14400
    @Published var preferSensorCountdown: Bool = false
    @Published var sensorNoiseStateRawValue: Int?
    @Published var timeStampOfLastFollowerConnection: Date = .now
    @Published var secondsUntilFollowerDisconnectWarning: Int = 60 * 6
    @Published var timeStampOfLastHeartBeat: Date = .now
    @Published var secondsUntilHeartBeatDisconnectWarning: Int = 90
    @Published var isMaster: Bool = true
    @Published var followerDataSourceType: FollowerDataSourceType = .nightscout
    @Published var followerBackgroundKeepAliveType: FollowerBackgroundKeepAliveType = .normal
    @Published var followerConnectionStatusRawValue: String?
    @Published var keepAliveIsDisabled: Bool = false

    @Published var lastUpdatedTextString: String = Texts_WatchApp.requestingData
    @Published var lastUpdatedTimeString: String = ""
    @Published var lastUpdatedTimeAgoString: String = ""
    @Published var requestingDataIconColor: Color = ConstantsAppleWatch.requestingDataIconColorInactive
    @Published var lastComplicationUpdateTimeStamp: Date = .distantPast

    /// NFC-authenticated direct Libre session and its persistent connection owner.
    @Published private(set) var libreWatchDirectSession: LibreWatchDirectSession?
    @Published private(set) var libreWatchOwnership: LibreWatchOwnership = .iphone
    @Published private(set) var libreWatchCalibrationSnapshot: LibreWatchCalibrationSnapshot?
    @Published private(set) var isShowingDirectLibreReading = false
    @Published private(set) var directLibreReadingIsStale = false

    /// Original direct values are retained in memory so a newer iPhone calibration can
    /// recompute the Watch-only presentation without altering values sent back to iPhone.
    private var directReadingHistory: [LibreWatchDirectReadingPayload] = []
    private var latestDirectSourceDelta: Double?
    private var directReadingAcceptance = LibreWatchReadingAcceptancePolicy()
    private var connectivityOutbox = LibreWatchSessionStore.loadOutbox()
    private var diagnosticJournal = LibreWatchSessionStore.loadDiagnosticJournal()
    private var outboxInFlightID: UUID?
    private var activationWasRequested = false

    @Published var aidStatus: AIDStatus?

    // we use the following to record when the user has manually requested a state update on each view so that we can trigger the animation on just this view
    // this is to prevent the UI animating "pending animations" when we switch view tabs
    @Published var updateBigNumberViewDate: Date = .now
    @Published var updateMainViewDate: Date = .now

    init(session: WCSession = .default) {
        self.session = session
        libreWatchDirectSession = LibreWatchSessionStore.loadSession()
        libreWatchOwnership = LibreWatchSessionStore.loadOwnership()
        libreWatchCalibrationSnapshot = LibreWatchSessionStore.loadCalibration()
        super.init()

        if let directSession = libreWatchDirectSession,
           libreWatchCalibrationSnapshot?.matches(session: directSession) != true {
            libreWatchCalibrationSnapshot = nil
            LibreWatchSessionStore.clearCalibration()
        }
        restorePersistedLibreWatchReadingIfPossible()
        restorePendingDiagnosticJournalToOutbox()

        session.delegate = self
        if session.activationState == .activated {
            flushWatchConnectivityOutbox()
        } else {
            requestSessionActivationIfNeeded()
        }
    }

    // MARK: - Functions to provide context data to populate the views

    /// the latest BG reading value in the array as a double
    /// - Returns: an optional double with the bg value in mg/dL if it exists
    func bgValueInMgDl() -> Double? {
        return bgReadingValues.isEmpty ? nil : bgReadingValues[0]
    }

    /// returns blood glucose value as a string in the user-defined measurement unit. Will check and display also high, low and error texts as required.
    /// - Returns: a String with the formatted value/unit or error text
    func bgValueStringInUserChosenUnit() -> String {
        if let bgReadingDate = bgReadingDate(),
           let bgValueInMgDl = bgValueInMgDl(),
           isShowingDirectLibreReading || bgReadingDate > Date().addingTimeInterval(-60 * 20) {
            var returnValue: String

            if bgValueInMgDl >= 400 {
                returnValue = Texts_Common.HIGH
            } else if bgValueInMgDl >= 40 {
                returnValue = bgValueInMgDl.mgDlToMmolAndToString(mgDl: isMgDl)
            } else if bgValueInMgDl > 12 {
                returnValue = Texts_Common.LOW
            } else {
                switch bgValueInMgDl {
                case 0:
                    returnValue = "??0"
                case 1:
                    returnValue = "?SN"
                case 2:
                    returnValue = "??2"
                case 3:
                    returnValue = "?NA"
                case 5:
                    returnValue = "?NC"
                case 6:
                    returnValue = "?CD"
                case 9:
                    returnValue = "?AD"
                case 12:
                    returnValue = "?RF"
                default:
                    returnValue = "???"
                }
            }
            return returnValue
        } else {
            return isMgDl ? "---" : "-.-"
        }
    }

    /// the timestamp of the latest BG reading value in the array
    /// - Returns: an optional date
    func bgReadingDate() -> Date? {
        return bgReadingDates.isEmpty ? nil : bgReadingDates.first
    }

    /// returns the localized string of mg/dL or mmol/L
    /// - Returns: string representation of mg/dL or mmol/L
    func bgUnitString() -> String {
        return isMgDl ? Texts_Common.mgdl : Texts_Common.mmol
    }

    /// Blood glucose color dependant on the user defined limit values and also on if it is a recent value
    /// - Returns: a Color object either red, yellow or green
    func bgTextColor() -> Color {
        if let bgReadingDate = bgReadingDate(), bgReadingDate > Date().addingTimeInterval(-60 * 7), let bgValueInMgDl = bgValueInMgDl() {
            if bgValueInMgDl >= urgentHighLimitInMgDl || bgValueInMgDl <= urgentLowLimitInMgDl {
                return .red
            } else if bgValueInMgDl >= highLimitInMgDl || bgValueInMgDl <= lowLimitInMgDl {
                return .yellow
            } else {
                return .green
            }
        } else {
            return .gray
        }
    }

    /// returns the minutes ago string of the last updated time
    /// check if more than 1 hour has passed. If so, then the amount of text to show would be too much so return the shorter version
    /// - Returns: string representation of last reading time as "x mins ago"
    func lastUpdatedMinsAgoString(at date: Date = Date()) -> String {
        if let bgReadingDate = bgReadingDate() {
            let diffComponents = Calendar.current.dateComponents([.hour], from: bgReadingDate, to: date)

            if let hours = diffComponents.hour, hours >= 1 {
                return bgReadingDate.daysAndHoursAgo(appendAgo: true)
            } else {
                return bgReadingDate.daysAndHoursAgoFull(appendAgo: true)
            }
        } else {
            return "Waiting..."
        }
    }

    /// Color dependant on how long ago the last BG reading was
    /// - Returns: a Color either normal (gray) or yellow/red if the reading was several minutes ago and hasn't been updated
    func lastUpdatedTimeColor() -> Color {
        if let bgReadingDate = bgReadingDate(), bgReadingDate > Date().addingTimeInterval(-60 * 7) {
            return .colorSecondary
        } else if let bgReadingDate = bgReadingDate(), bgReadingDate > Date().addingTimeInterval(-60 * 12) {
            return .yellow
        } else if let bgReadingDate = bgReadingDate(), bgReadingDate > Date().addingTimeInterval(-60 * 22) {
            return .red
        } else {
            return .colorTertiary
        }
    }

    ///  returns a string holding the trend arrow
    /// - Returns: trend arrow string (i.e.  "↑")
    func trendArrow() -> String {
        if let bgReadingDate = bgReadingDate(),
           (!isShowingDirectLibreReading || !directLibreReadingIsStale),
           isShowingDirectLibreReading || bgReadingDate > Date().addingTimeInterval(-60 * 20) {
            switch slopeOrdinal {
            case 7:
                return "\u{2193}\u{2193}" // ↓↓
            case 6:
                return "\u{2193}" // ↓
            case 5:
                return "\u{2198}" // ↘
            case 4:
                return "\u{2192}" // →
            case 3:
                return "\u{2197}" // ↗
            case 2:
                return "\u{2191}" // ↑
            case 1:
                return "\u{2191}\u{2191}" // ↑↑
            default:
                return ""
            }
        } else {
            return ""
        }
    }

    /// convert the optional delta change int (in mg/dL) to a formatted change value in the user chosen unit making sure all zero values are shown as a positive change to follow Nightscout convention
    /// - Returns: a string holding the formatted delta change value (i.e. +0.4 or -6)
    func deltaChangeStringInUserChosenUnit() -> String {
        if let bgReadingDate = bgReadingDate(),
           (!isShowingDirectLibreReading || !directLibreReadingIsStale),
           isShowingDirectLibreReading || bgReadingDate > Date().addingTimeInterval(-60 * 20) {
            let deltaValueAsString = isMgDl ? deltaValueInUserUnit.mgDlToMmolAndToString(mgDl: isMgDl) : deltaValueInUserUnit.mmolToString()

            var deltaSign = ""

            if deltaValueInUserUnit > 0 {
                deltaSign = "+"
            }

            // quickly check "value" and prevent "-0mg/dl" or "-0.0mmol/l" being displayed
            // show unitized zero deltas as +0 or +0.0 as per Nightscout format
            return deltaValueInUserUnit == 0.0 ? (isMgDl ? "+0" : "+0.0") : (deltaSign + deltaValueAsString)
        } else {
            return "-"
        }
    }

    /// function to calculate the sensor progress value and return a text color to be used by the view
    /// - Returns: progress: the % progress between 0 and 1, textColor:
    func activeSensorProgress() -> (progress: Float, textColor: Color) {
        if sensorAgeInMinutes > 0, sensorMaxAgeInMinutes > 0 {
            let sensorTimeLeftInMinutes = sensorMaxAgeInMinutes - sensorAgeInMinutes
            let progress = Float(min(max(preferSensorCountdown ? sensorTimeLeftInMinutes / sensorMaxAgeInMinutes : sensorAgeInMinutes / sensorMaxAgeInMinutes, 0), 1))

            // irrespective of all the above, if the current sensor age is over the max age, then just set everything to the expired colour to make it clear
            if sensorTimeLeftInMinutes < 0 {
                return (preferSensorCountdown ? 0 : 1, ConstantsHomeView.sensorProgressExpiredSwiftUI)
            } else if sensorTimeLeftInMinutes <= ConstantsHomeView.sensorProgressViewUrgentInMinutes {
                return (progress, ConstantsHomeView.sensorProgressViewProgressColorUrgentSwiftUI)
            } else if sensorTimeLeftInMinutes <= ConstantsHomeView.sensorProgressViewWarningInMinutes {
                return (progress, ConstantsHomeView.sensorProgressViewProgressColorWarningSwiftUI)
            } else {
                return (progress, ConstantsHomeView.sensorProgressNormalTextColorSwiftUI)
            }
        } else {
            return (0, ConstantsHomeView.sensorProgressNormalTextColorSwiftUI)
        }
    }

    /// returns either the elapsed or remaining sensor lifetime based upon the user's preference
    /// - Returns: string representation of the sensor lifetime as days and hours
    func activeSensorLifetimeText() -> String {
        let lifetimeInMinutes = preferSensorCountdown ? max(sensorMaxAgeInMinutes - sensorAgeInMinutes, 0) : sensorAgeInMinutes
        return lifetimeInMinutes.minutesToDaysAndHours()
    }

    /// returns the sensor noise indicator color supplied by the paired iPhone
    func sensorNoiseIndicatorColor() -> Color? {
        sensorNoiseState()?.color
    }

    /// returns an accessible description of the current sensor noise state
    func sensorNoiseIndicatorAccessibilityLabel() -> String {
        guard let sensorNoiseState = sensorNoiseState() else { return "" }

        return Texts_HomeView.sensorManagementNoiseTitle + ": " + sensorNoiseState.localizedTitle
    }

    private func sensorNoiseState() -> WatchSensorNoiseState? {
        guard isMaster, let sensorNoiseStateRawValue else { return nil }

        return WatchSensorNoiseState(rawValue: sensorNoiseStateRawValue)
    }

    /// check when the last follower connection was and compare that to the actual time
    /// - Returns: color of the follower connection status indicator
    func followerConnectionIndicatorColor() -> Color {
        if followerDataSourceType == .careLink, let followerConnectionStatusRawValue {
            switch followerConnectionStatusRawValue {
            case "loginRequired", "selectPatient": return .gray
            case "connecting", "noData": return .yellow
            case "active": return .green
            case "stale", "rateLimited": return .orange
            case "error": return .red
            default: break
            }
        }

        if timeStampOfLastFollowerConnection > Date().addingTimeInterval(-Double(secondsUntilFollowerDisconnectWarning)) {
            return .green
        } else {
            if followerBackgroundKeepAliveType != .disabled {
                return .red
            } else {
                // if keep-alive is disabled, then this will never show a constant server connection so just "disable"
                // the indicator when not recent. It would be incorrect to show a red error.
                return .gray
            }
        }
    }

    /// check when the last heartbeat connection was and compare that to the actual time
    /// if no heartbeat, just return the standard gray colour for the keep alive type icon
    func getFollowerBackgroundKeepAliveColor() -> Color {
        if followerBackgroundKeepAliveType == .heartbeat {
            if let timeDifferenceInSeconds = Calendar.current.dateComponents([.second], from: timeStampOfLastHeartBeat, to: Date()).second, timeDifferenceInSeconds > secondsUntilHeartBeatDisconnectWarning {
                return .red
            } else {
                return .green
            }
        } else {
            return .gray
        }
    }

    /// used to return values and colors used by a SwiftUI gauge view
    /// - Returns: minValue/maxValue - used to define the limits of the gauge. nilValue - used if there is currently no data present (basically puts the gauge at the 50% mark). gaugeGradient - the color ranges used
    func gaugeModel() -> (minValue: Double, maxValue: Double, nilValue: Double, gaugeGradient: Gradient) {
        // if no readings are available yet, return a gray gradient
        if bgValueInMgDl() == nil {
            return (0, 1, 0.5, Gradient(colors: [.gray]))
        }

        // now we've got the values, if there is no recent reading, return a gray gradient
        if let bgReadingDate = bgReadingDate(), bgReadingDate < Date().addingTimeInterval(-60 * 7) {
            return (0, 1, 0.5, Gradient(colors: [.gray]))
        }

        var minValue: Double = lowLimitInMgDl
        var maxValue: Double = highLimitInMgDl
        var colorArray = [Color]()

        // let's put the min and max values into values/context that makes sense for the UI we show to the user
        if let bgValueInMgDl = bgValueInMgDl() {
            if bgValueInMgDl >= urgentHighLimitInMgDl {
                maxValue = ConstantsCalibrationAlgorithms.maximumBgReadingCalculatedValue
            } else if bgValueInMgDl >= highLimitInMgDl {
                maxValue = urgentHighLimitInMgDl
            }

            if bgValueInMgDl <= urgentLowLimitInMgDl {
                minValue = ConstantsCalibrationAlgorithms.minimumBgReadingCalculatedValue
            } else if bgValueInMgDl <= lowLimitInMgDl {
                minValue = urgentLowLimitInMgDl
            }
        }

        // calculate a nil value to show on the gauge (as it can't display nil). This should basically just peg the gauge indicator in the middle of the current range
        let nilValue = minValue + ((maxValue - minValue) / 2)

        // this means that there is a recent reading so we can show a colored gauge
        // let's round the min value down to nearest 10 and the max up to nearest 10
        // this is to start creating the gradient ranges
        let minValueRoundedDown = Double(10 * Int(minValue / 10))
        let maxValueRoundedUp = Double(10 * Int(maxValue / 10)) + 10

        // the prevent the gradient changes from being too sharp, we'll reduce the granularity if trying to show a bigger range (such as >200mg/dL)
        let reducedGranularity = (maxValueRoundedUp - minValueRoundedDown) > 200

        // step through the range and append the colors as necessary
        for currentValue in stride(from: minValueRoundedDown, through: maxValueRoundedUp, by: reducedGranularity ? 20 : 10) {
            if currentValue > urgentHighLimitInMgDl || currentValue <= urgentLowLimitInMgDl {
                colorArray.append(.red)
            } else if currentValue > highLimitInMgDl || currentValue <= lowLimitInMgDl {
                colorArray.append(.yellow)
            } else {
                colorArray.append(.green)
            }
        }

        return (minValue, maxValue, nilValue, Gradient(colors: colorArray))
    }

    func aidStatusColor() -> Color? {
        aidStatus?.presentation().color
    }

    func aidStatusIconImage() -> Image? {
        guard let systemImage = aidStatus?.presentation().systemImage else { return nil }
        return Image(systemName: systemImage)
    }

    func aidStatusIOBString() -> String {
        guard let aidStatus, aidStatus.presentation().hasFreshData, let iob = aidStatus.iob else { return "-U" }
        return "\(iob.round(toDecimalPlaces: 2).stringWithoutTrailingZeroes)U"
    }

    func aidStatusCOBString() -> String {
        guard let aidStatus, aidStatus.presentation().hasFreshData, let cob = aidStatus.cob else { return "-g" }
        return "\(cob.round(toDecimalPlaces: 0).stringWithoutTrailingZeroes)g"
    }

    func aidStatusActivityAgeString() -> String {
        guard let aidStatus, aidStatus.presentation().showsActivityAge else { return "" }
        guard let lastActivityAt = aidStatus.lastActivityAt else { return "-m" }

        let diffComponents = Calendar.current.dateComponents([.hour], from: lastActivityAt, to: Date())

        if let hours = diffComponents.hour, hours < 1 {
            return "\(lastActivityAt.daysAndHoursAgo(appendAgo: false))"
        } else {
            return "-m"
        }
    }

    // MARK: - helper functions not related with the class structure

    /// request a state update from the iOS companion app
    func requestWatchStateUpdate() {
        guard session.activationState == .activated else {
            requestSessionActivationIfNeeded()
            return
        }
        // change the text, this must be done in the main thread but only do it if the watch app is reachable
        if session.isReachable {
            DispatchQueue.main.async {
                self.requestingDataIconColor = ConstantsAppleWatch.requestingDataIconColorPending
            }

            requestWatchUpdate(updateType: "status")
            requestWatchUpdate(updateType: "bgReadings")
        }
    }

    var phoneIsReachable: Bool {
        session.activationState == .activated && session.isReachable
    }

    func requestLibreWatchOwnership(completion: @escaping (Bool, String?) -> Void) {
        guard let preparedSession = libreWatchDirectSession, preparedSession.isValid else {
            completion(false, LibreWatchDirectFailure.noSession.rawValue)
            return
        }
        guard phoneIsReachable else {
            completion(false, LibreWatchDirectFailure.phoneUnavailable.rawValue)
            return
        }

        setLibreWatchOwnership(.releasingToWatch)
        sendLibreWatchCommand(.requestOwnership, sessionID: preparedSession.id) { [weak self] success, error in
            self?.setLibreWatchOwnership(success ? .watch : .iphone)
            completion(success, error)
        }
    }

    func releaseLibreWatchOwnership(
        unlockCounter: UInt16?,
        completion: @escaping (Bool, String?) -> Void
    ) {
        guard let preparedSession = libreWatchDirectSession else {
            completion(false, LibreWatchDirectFailure.noSession.rawValue)
            return
        }
        guard phoneIsReachable else {
            completion(false, LibreWatchDirectFailure.phoneUnavailable.rawValue)
            return
        }

        let releaseCutoff = Date()
        setLibreWatchOwnership(.releasingToPhone)
        sendLibreWatchCommand(
            .releaseOwnership,
            sessionID: preparedSession.id,
            unlockCounter: unlockCounter,
            releaseCutoff: releaseCutoff
        ) { [weak self] success, error in
            self?.setLibreWatchOwnership(success ? .iphone : .watch)
            completion(success, error)
        }
    }

    func updateLibreWatchUnlockCounter(_ counter: UInt16) {
        guard var preparedSession = libreWatchDirectSession,
              counter >= preparedSession.unlockCount
        else { return }

        preparedSession.unlockCount = counter
        libreWatchDirectSession = preparedSession
        LibreWatchSessionStore.saveSession(preparedSession)
        connectivityOutbox.retain(sessionID: preparedSession.id)
        LibreWatchSessionStore.saveOutbox(connectivityOutbox)
        sendLibreWatchCommand(
            .updateUnlockCounter,
            sessionID: preparedSession.id,
            unlockCounter: counter,
            queueIfUnreachable: true,
            completion: nil
        )
    }

    @discardableResult
    func submitLibreWatchReading(_ directReading: Libre2WatchDirectReading) -> Bool {
        guard let directSession = libreWatchDirectSession,
              let snapshot = libreWatchCalibrationSnapshot,
              snapshot.matches(session: directSession),
              libreWatchOwnership == .watch
        else { return false }

        let reading = directReading.payload(
            sessionID: directSession.id,
            valueDomain: snapshot.requiredValueDomain,
            calibrationRevision: snapshot.revision
        )
        guard reading.isValid(for: snapshot),
              snapshot.displayedGlucose(for: reading) != nil
        else { return false }

        guard directReadingAcceptance.accept(
            reading,
            for: directSession.id,
            now: Date()
        ) else { return false }

        applyLibreWatchReadingLocally(reading)

        enqueueForWatchConnectivity(.reading(reading))
        return true
    }

    private func applyLibreWatchReadingLocally(
        _ reading: LibreWatchDirectReadingPayload,
        displayedOverride: (glucose: Double, trend: Double?, revision: UInt64?)? = nil,
        sourceDeltaOverride: Double? = nil,
        displayedDeltaOverride: Double? = nil
    ) {
        guard let directSession = libreWatchDirectSession,
              let snapshot = libreWatchCalibrationSnapshot,
              snapshot.matches(session: directSession),
              reading.sessionID == directSession.id,
              reading.isValid(for: snapshot),
              let displayed = displayedOverride ?? displayedLibreValues(for: reading)
        else { return }

        if let existingIndex = directReadingHistory.firstIndex(where: { $0.id == reading.id }) {
            directReadingHistory.remove(at: existingIndex)
        }
        directReadingHistory.append(reading)
        directReadingHistory.sort { $0.receivedAt > $1.receivedAt }
        directReadingHistory.removeAll { $0.receivedAt < Date().addingTimeInterval(-12 * 60 * 60) }

        upsertDirectReading(reading, displayedGlucose: displayed.glucose)

        guard directReadingHistory.first?.id == reading.id else { return }
        let sourceDelta = sourceDeltaOverride ?? directSourceDelta(for: reading)
        let displayedDelta = displayedDeltaOverride ?? displayedLibreDelta(sourceDelta)
        latestDirectSourceDelta = sourceDelta
        updateDirectDerivedValues(
            for: reading,
            displayedGlucose: displayed.glucose,
            displayedTrend: displayed.trend,
            displayedDelta: displayedDelta
        )
        isShowingDirectLibreReading = libreWatchOwnership == .watch

        let stored = LibreWatchPersistedDirectReading(
            sessionID: reading.sessionID,
            sensorIdentity: directSession.redactedIdentity(),
            sourceReading: reading,
            sourceDelta: sourceDelta,
            displayedGlucoseMGDL: displayed.glucose,
            displayedTrendMGDLPerMinute: displayed.trend,
            displayedDeltaMGDL: displayedDelta,
            calibrationRevision: displayed.revision
        )
        LibreWatchSessionStore.saveReading(stored)
        updateComplicationData()
    }

    private func displayedLibreValues(
        for reading: LibreWatchDirectReadingPayload
    ) -> (glucose: Double, trend: Double?, revision: UInt64?)? {
        guard let directSession = libreWatchDirectSession,
              let snapshot = libreWatchCalibrationSnapshot,
              snapshot.matches(session: directSession),
              let glucose = snapshot.displayedGlucose(for: reading)
        else { return nil }

        return (glucose, snapshot.displayedTrend(for: reading), snapshot.revision)
    }

    private func directSourceDelta(for reading: LibreWatchDirectReadingPayload) -> Double? {
        guard let index = directReadingHistory.firstIndex(where: { $0.id == reading.id }),
              directReadingHistory.indices.contains(index + 1),
              let snapshot = libreWatchCalibrationSnapshot,
              reading.isValid(for: snapshot),
              directReadingHistory[index + 1].isValid(for: snapshot)
        else { return nil }
        return LibreWatchDirectDeltaPolicy.sourceDelta(
            current: reading,
            previous: directReadingHistory[index + 1],
            calibration: snapshot
        )
    }

    private func displayedLibreDelta(_ sourceDelta: Double?) -> Double? {
        guard let directSession = libreWatchDirectSession,
              let snapshot = libreWatchCalibrationSnapshot,
              snapshot.matches(session: directSession)
        else { return nil }
        return snapshot.displayedDelta(sourceDelta: sourceDelta)
    }

    private func upsertDirectReading(
        _ reading: LibreWatchDirectReadingPayload,
        displayedGlucose: Double
    ) {
        if let existingIndex = bgReadingDates.firstIndex(of: reading.receivedAt) {
            if existingIndex < bgReadingValues.count {
                bgReadingValues[existingIndex] = displayedGlucose
            }
            return
        }

        let insertionIndex = bgReadingDates.firstIndex(where: { $0 < reading.receivedAt }) ?? bgReadingDates.count
        bgReadingDates.insert(reading.receivedAt, at: insertionIndex)
        bgReadingValues.insert(displayedGlucose, at: min(insertionIndex, bgReadingValues.count))
        bgReadingDatesAsDouble.insert(
            reading.receivedAt.timeIntervalSince1970,
            at: min(insertionIndex, bgReadingDatesAsDouble.count)
        )

        let oldestAllowed = Date().addingTimeInterval(-12 * 60 * 60)
        while let lastDate = bgReadingDates.last, lastDate < oldestAllowed {
            bgReadingDates.removeLast()
            if !bgReadingValues.isEmpty { bgReadingValues.removeLast() }
            if !bgReadingDatesAsDouble.isEmpty { bgReadingDatesAsDouble.removeLast() }
        }
    }

    func directLibreStatus(connectionIsRecovering: Bool, at date: Date = Date()) -> String? {
        guard libreWatchOwnership == .watch else { return nil }
        return connectionIsRecovering || !isShowingDirectLibreReading || !directLibreReadingIsCurrent(at: date)
            ? "Forbinder igen"
            : "Direkte fra Libre"
    }

    func directLibreReadingIsCurrent(at date: Date = Date()) -> Bool {
        guard isShowingDirectLibreReading,
              let latest = directReadingHistory.first
        else { return false }
        return latest.isCurrent(at: date)
    }

    func refreshDirectLibreReadingFreshness(at date: Date = Date()) {
        guard libreWatchOwnership == .watch, isShowingDirectLibreReading else {
            directLibreReadingIsStale = false
            return
        }

        let isStale = !directLibreReadingIsCurrent(at: date)
        guard isStale != directLibreReadingIsStale else { return }
        directLibreReadingIsStale = isStale
        if isStale {
            slopeOrdinal = 0
            deltaValueInUserUnit = 0
        } else if let latest = directReadingHistory.first,
                  let displayed = displayedLibreValues(for: latest) {
            updateDirectDerivedValues(
                for: latest,
                displayedGlucose: displayed.glucose,
                displayedTrend: displayed.trend,
                displayedDelta: displayedLibreDelta(latestDirectSourceDelta)
            )
        }
        updateMainViewDate = .now
        updateBigNumberViewDate = .now
        updateComplicationData()
    }

    private func updateDirectDerivedValues(
        for reading: LibreWatchDirectReadingPayload,
        displayedGlucose: Double,
        displayedTrend: Double?,
        displayedDelta: Double?
    ) {
        directLibreReadingIsStale = !reading.isCurrent(at: Date())
        if let trend = displayedTrend {
            if trend >= 3 { slopeOrdinal = 2 }
            else if trend >= 1 { slopeOrdinal = 3 }
            else if trend < -3 { slopeOrdinal = 6 }
            else if trend < -1 { slopeOrdinal = 5 }
            else { slopeOrdinal = 4 }
        } else {
            slopeOrdinal = 0
        }

        if let deltaMGDL = displayedDelta {
            deltaValueInUserUnit = isMgDl ? deltaMGDL : deltaMGDL / 18.0182
        } else {
            deltaValueInUserUnit = 0
        }

        updatedDate = reading.receivedAt
        sensorAgeInMinutes = Double(reading.sensorTimeInMinutes)
        lastUpdatedTextString = Texts_WatchApp.lastReading + " "
        lastUpdatedTimeString = reading.receivedAt.formatted(date: .omitted, time: .shortened)
        lastUpdatedTimeAgoString = reading.receivedAt.daysAndHoursAgo(appendAgo: true)
        updateMainViewDate = .now
        updateBigNumberViewDate = .now
    }

    private func restorePersistedLibreWatchReadingIfPossible() {
        guard libreWatchOwnership == .watch,
              let directSession = libreWatchDirectSession,
              let snapshot = libreWatchCalibrationSnapshot,
              let stored = LibreWatchSessionStore.loadReading(),
              stored.isValid(for: directSession, calibration: snapshot)
        else { return }

        directReadingAcceptance.reset(
            for: directSession.id,
            seeding: stored.sourceReading
        )
        let storedCalibrationIsCurrent = stored.calibrationRevision == libreWatchCalibrationSnapshot?.revision
        applyLibreWatchReadingLocally(
            stored.sourceReading,
            displayedOverride: storedCalibrationIsCurrent ? (
                stored.displayedGlucoseMGDL,
                stored.displayedTrendMGDLPerMinute,
                stored.calibrationRevision
            ) : nil,
            sourceDeltaOverride: nil,
            displayedDeltaOverride: nil
        )
    }

    func reportLibreWatchDiagnostic(_ event: LibreWatchDiagnosticEvent) {
        guard let preparedSession = libreWatchDirectSession else { return }

        let result = diagnosticJournal.append(event)
        LibreWatchSessionStore.saveDiagnosticJournal(diagnosticJournal)
        guard result.inserted,
              let encoded = try? JSONEncoder().encode(result.event)
        else { return }

        sendLibreWatchCommand(
            .reportDiagnostic,
            sessionID: preparedSession.id,
            diagnosticEvent: encoded,
            queueIfUnreachable: true,
            completion: nil
        )
    }

    private func acceptLibreWatchCalibration(_ snapshot: LibreWatchCalibrationSnapshot) {
        guard let directSession = libreWatchDirectSession,
              snapshot.matches(session: directSession)
        else { return }

        if let current = libreWatchCalibrationSnapshot,
           current.matches(session: directSession),
           snapshot.revision <= current.revision {
            return
        }

        if let current = libreWatchCalibrationSnapshot,
           current.matches(session: directSession),
           current.requiredValueDomain != snapshot.requiredValueDomain {
            clearDirectReadingPresentation()
        }

        libreWatchCalibrationSnapshot = snapshot
        LibreWatchSessionStore.saveCalibration(snapshot)
        recalculateDirectPresentation()
    }

    private func recalculateDirectPresentation() {
        guard let directSession = libreWatchDirectSession,
              let snapshot = libreWatchCalibrationSnapshot,
              snapshot.matches(session: directSession)
        else { return }

        directReadingHistory.removeAll { !$0.isValid(for: snapshot) }
        for reading in directReadingHistory {
            guard let displayed = displayedLibreValues(for: reading) else { continue }
            upsertDirectReading(reading, displayedGlucose: displayed.glucose)
        }

        guard let latest = directReadingHistory.first,
              let displayed = displayedLibreValues(for: latest)
        else {
            isShowingDirectLibreReading = false
            LibreWatchSessionStore.clearReading()
            return
        }
        let displayedDelta = displayedLibreDelta(latestDirectSourceDelta)
        updateDirectDerivedValues(
            for: latest,
            displayedGlucose: displayed.glucose,
            displayedTrend: displayed.trend,
            displayedDelta: displayedDelta
        )

        LibreWatchSessionStore.saveReading(LibreWatchPersistedDirectReading(
            sessionID: latest.sessionID,
            sensorIdentity: directSession.redactedIdentity(),
            sourceReading: latest,
            sourceDelta: latestDirectSourceDelta,
            displayedGlucoseMGDL: displayed.glucose,
            displayedTrendMGDLPerMinute: displayed.trend,
            displayedDeltaMGDL: displayedDelta,
            calibrationRevision: displayed.revision
        ))
        updateMainViewDate = .now
        updateBigNumberViewDate = .now
        updateComplicationData()
    }

    private func clearDirectReadingPresentation() {
        let directDates = Set(directReadingHistory.map(\.receivedAt))
        let retained = zip(bgReadingDates, bgReadingValues).filter { !directDates.contains($0.0) }
        bgReadingDates = retained.map { $0.0 }
        bgReadingValues = retained.map { $0.1 }
        bgReadingDatesAsDouble = bgReadingDates.map { $0.timeIntervalSince1970 }
        directReadingHistory.removeAll()
        latestDirectSourceDelta = nil
        isShowingDirectLibreReading = false
        directLibreReadingIsStale = false
        LibreWatchSessionStore.clearReading()
    }

    private func clearStoredDirectStateForSessionChange() {
        directReadingAcceptance.reset()
        clearDirectReadingPresentation()
        libreWatchCalibrationSnapshot = nil
        LibreWatchSessionStore.clearCalibration()
    }

    /// request the compact AGP profile used by the Watch main chart background
    func requestAGPBackground(startDate: Date, endDate: Date) {
        // always save the latest requested range first
        // if the session isn't ready, we'll retry when activation/reachability changes
        pendingAGPRequestRange = (startDate: startDate, endDate: endDate)

        sendPendingAGPRequestIfPossible()
    }

    private func sendPendingAGPRequestIfPossible() {
        guard let pendingAGPRequestRange else { return }

        // the Watch app can appear before WCSession has finished activating
        // keep the pending range and try again when activation completes
        guard session.activationState == .activated else {
            requestSessionActivationIfNeeded()
            return
        }

        // if the phone isn't reachable yet, keep the pending range and retry on reachability change
        guard session.isReachable else { return }

        // tag each request so old phone replies can be ignored
        latestAGPRequestID += 1

        session.sendMessage([
            "requestWatchUpdate": "agp",
            "requestID": latestAGPRequestID,
            "visibleStartDate": pendingAGPRequestRange.startDate.timeIntervalSince1970,
            "visibleEndDate": pendingAGPRequestRange.endDate.timeIntervalSince1970
        ], replyHandler: nil) { [log] error in
            log.error("Error requesting agp: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Maps the stored daily AGP profile onto the dates currently visible on the Watch chart.
    func agpBackgroundPointsMatching(startDate: Date, endDate: Date) -> [GlucoseChartAGPPoint] {
        // convert the stored minute-of-day profile into real chart dates for this render pass
        mapAGPProfileToVisibleRange(startDate: startDate, endDate: endDate)
    }

    private func mapAGPProfileToVisibleRange(startDate: Date, endDate: Date) -> [GlucoseChartAGPPoint] {
        guard startDate < endDate, !agpProfilePoints.isEmpty else { return [] }

        let calendar = Calendar.current
        let sortedProfile = agpProfilePoints.sorted { $0.minuteOfDay < $1.minuteOfDay }
        var day = calendar.startOfDay(for: startDate)
        let finalDay = calendar.startOfDay(for: endDate)
        var mappedPoints: [GlucoseChartAGPPoint] = []

        // add interpolated edge points so the AGP bands reach the exact chart start
        if let startBoundaryPoint = agpBoundaryPoint(for: startDate, from: sortedProfile, calendar: calendar) {
            mappedPoints.append(startBoundaryPoint)
        }

        // add every AGP bucket that lands inside the visible chart range
        while day <= finalDay {
            for point in sortedProfile {
                guard let date = calendar.date(byAdding: .minute, value: point.minuteOfDay, to: day),
                      date > startDate,
                      date < endDate else {
                    continue
                }

                mappedPoints.append(GlucoseChartAGPPoint(
                    date: date,
                    p5MgDl: point.p5MgDl,
                    p25MgDl: point.p25MgDl,
                    medianMgDl: point.medianMgDl,
                    p75MgDl: point.p75MgDl,
                    p95MgDl: point.p95MgDl
                ))
            }

            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day), nextDay > day else {
                break
            }

            day = nextDay
        }

        // add an interpolated edge point so the AGP bands reach the exact chart end
        if let endBoundaryPoint = agpBoundaryPoint(for: endDate, from: sortedProfile, calendar: calendar) {
            mappedPoints.append(endBoundaryPoint)
        }

        return mappedPoints.sorted { $0.date < $1.date }
    }

    private func agpBoundaryPoint(for date: Date, from sortedProfile: [WatchAGPProfilePoint], calendar: Calendar) -> GlucoseChartAGPPoint? {
        guard let firstPoint = sortedProfile.first else { return nil }

        // find where this exact date sits between the surrounding AGP minute-of-day buckets
        // this prevents small gaps at the left and right edges of the chart
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        let minuteOfDay = Double((components.hour ?? 0) * 60 + (components.minute ?? 0)) + Double(components.second ?? 0) / 60
        let lowerPoint = sortedProfile.last { Double($0.minuteOfDay) <= minuteOfDay } ?? sortedProfile.last ?? firstPoint
        let upperPoint = sortedProfile.first { Double($0.minuteOfDay) >= minuteOfDay && $0.minuteOfDay != lowerPoint.minuteOfDay } ?? firstPoint
        let lowerMinute = Double(lowerPoint.minuteOfDay)
        let upperMinute = upperPoint.minuteOfDay <= lowerPoint.minuteOfDay ? Double(upperPoint.minuteOfDay + 1440) : Double(upperPoint.minuteOfDay)
        let normalizedMinute = minuteOfDay < lowerMinute ? minuteOfDay + 1440 : minuteOfDay
        let interpolationRange = max(upperMinute - lowerMinute, 1)
        let progress = min(max((normalizedMinute - lowerMinute) / interpolationRange, 0), 1)

        return GlucoseChartAGPPoint(
            date: date,
            p5MgDl: interpolatedAGPValue(from: lowerPoint.p5MgDl, to: upperPoint.p5MgDl, progress: progress),
            p25MgDl: interpolatedAGPValue(from: lowerPoint.p25MgDl, to: upperPoint.p25MgDl, progress: progress),
            medianMgDl: interpolatedAGPValue(from: lowerPoint.medianMgDl, to: upperPoint.medianMgDl, progress: progress),
            p75MgDl: interpolatedAGPValue(from: lowerPoint.p75MgDl, to: upperPoint.p75MgDl, progress: progress),
            p95MgDl: interpolatedAGPValue(from: lowerPoint.p95MgDl, to: upperPoint.p95MgDl, progress: progress)
        )
    }

    private func interpolatedAGPValue(from lowerValue: Double, to upperValue: Double, progress: Double) -> Double {
        lowerValue + (upperValue - lowerValue) * progress
    }

    private func requestWatchUpdate(updateType: String) {
        session.sendMessage(["requestWatchUpdate": updateType], replyHandler: nil) { [log] error in
            log.error("Error requesting \(updateType, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func setLibreWatchOwnership(_ ownership: LibreWatchOwnership) {
        let ownershipChanged = ownership != libreWatchOwnership
        libreWatchOwnership = ownership
        LibreWatchSessionStore.saveOwnership(ownership)
        if ownershipChanged {
            directReadingAcceptance.reset(
                for: ownership == .watch ? libreWatchDirectSession?.id : nil
            )
        }
        if ownership == .watch {
            if directReadingHistory.isEmpty {
                restorePersistedLibreWatchReadingIfPossible()
            } else {
                isShowingDirectLibreReading = true
                refreshDirectLibreReadingFreshness()
            }
        } else if ownership == .iphone {
            isShowingDirectLibreReading = false
            directLibreReadingIsStale = false
        }
    }

    private func processLibreWatchPayload(_ payload: [String: Any]) {
        guard let data = payload[LibreWatchMessageKey.session] as? Data,
              var preparedSession = try? JSONDecoder().decode(LibreWatchDirectSession.self, from: data),
              preparedSession.isValid
        else { return }

        let sessionChanged = libreWatchDirectSession?.id != preparedSession.id ||
            libreWatchDirectSession?.representsSameSensor(as: preparedSession) == false
        if sessionChanged {
            clearStoredDirectStateForSessionChange()
        }

        if let currentSession = libreWatchDirectSession,
           currentSession.representsSameSensor(as: preparedSession),
           currentSession.unlockCount > preparedSession.unlockCount {
            preparedSession.unlockCount = currentSession.unlockCount
        }

        libreWatchDirectSession = preparedSession
        LibreWatchSessionStore.saveSession(preparedSession)
        if sessionChanged {
            connectivityOutbox.retain(sessionID: preparedSession.id)
            if let inFlightID = outboxInFlightID,
               !connectivityOutbox.items.contains(where: { $0.id == inFlightID }) {
                outboxInFlightID = nil
            }
            LibreWatchSessionStore.saveOutbox(connectivityOutbox)
        }
        if sessionChanged, libreWatchOwnership == .watch {
            directReadingAcceptance.reset(for: preparedSession.id)
        }

        if let calibrationData = payload[LibreWatchMessageKey.calibration] as? Data,
           let calibration = try? JSONDecoder().decode(LibreWatchCalibrationSnapshot.self, from: calibrationData) {
            acceptLibreWatchCalibration(calibration)
        }

        if let rawOwnership = payload[LibreWatchMessageKey.ownership] as? String,
           let ownership = LibreWatchOwnership(rawValue: rawOwnership) {
            setLibreWatchOwnership(ownership)
        }

        sendLibreWatchCommand(
            .acknowledgeSession,
            sessionID: preparedSession.id,
            completion: nil
        )
    }

    private func requestSessionActivationIfNeeded() {
        guard session.activationState != .activated, !activationWasRequested else { return }
        activationWasRequested = true
        session.activate()
    }

    private func message(for item: LibreWatchOutboxItem) -> [String: Any]? {
        guard let command = item.command else { return nil }
        var message: [String: Any] = [
            LibreWatchMessageKey.command: command.rawValue,
            LibreWatchMessageKey.sessionID: item.sessionID.uuidString
        ]
        if let reading = item.reading,
           let data = try? JSONEncoder().encode(reading) {
            message[LibreWatchMessageKey.reading] = data
        } else if item.kind == .reading {
            return nil
        }
        if let unlockCounter = item.unlockCounter {
            message[LibreWatchMessageKey.unlockCounter] = Int(unlockCounter)
        }
        if let diagnosticEvent = item.diagnosticEvent {
            message[LibreWatchMessageKey.diagnosticEvent] = diagnosticEvent
        }
        return message
    }

    private func enqueueForWatchConnectivity(_ item: LibreWatchOutboxItem) {
        connectivityOutbox.enqueue(item)
        LibreWatchSessionStore.saveOutbox(connectivityOutbox)
        flushWatchConnectivityOutbox()
    }

    /// Recovers the narrow crash window between journal persistence and outbox persistence.
    /// Existing IDs make this idempotent; normal delivery remains the per-event outbox path.
    private func restorePendingDiagnosticJournalToOutbox(at date: Date = Date()) {
        guard let sessionID = libreWatchDirectSession?.id else { return }
        let pending = diagnosticJournal.pendingEvents(for: sessionID)
        guard !pending.isEmpty else { return }

        for (index, event) in pending.enumerated() {
            guard let eventID = event.eventID,
                  let sessionID = event.sessionID,
                  let encoded = try? JSONEncoder().encode(event)
            else { continue }
            connectivityOutbox.enqueue(.command(
                .reportDiagnostic,
                sessionID: sessionID,
                diagnosticEvent: encoded,
                id: eventID,
                createdAt: date.addingTimeInterval(-1 + Double(index) / 1_000)
            ), now: date)
        }
        LibreWatchSessionStore.saveOutbox(connectivityOutbox)
    }

    private func finishOutboxItem(_ id: UUID) {
        if let item = connectivityOutbox.items.first(where: { $0.id == id }),
           item.command == .reportDiagnostic {
            diagnosticJournal.markHandedToWatchConnectivity(eventID: id)
            LibreWatchSessionStore.saveDiagnosticJournal(diagnosticJournal)
        }
        connectivityOutbox.remove(id: id)
        LibreWatchSessionStore.saveOutbox(connectivityOutbox)
        outboxInFlightID = nil
        DispatchQueue.main.async { [weak self] in self?.flushWatchConnectivityOutbox() }
    }

    private func transferOutboxItemIfActivated(_ item: LibreWatchOutboxItem, message: [String: Any]) {
        guard session.activationState == .activated else {
            outboxInFlightID = nil
            requestSessionActivationIfNeeded()
            return
        }
        session.transferUserInfo(message)
        finishOutboxItem(item.id)
    }

    private func flushWatchConnectivityOutbox() {
        guard outboxInFlightID == nil else { return }
        // A journal entry is persisted before its outbox item. Reconcile that crash/eviction
        // window on every activation/reachability opportunity, not only at process launch.
        restorePendingDiagnosticJournalToOutbox()
        connectivityOutbox.prune()
        LibreWatchSessionStore.saveOutbox(connectivityOutbox)
        guard let item = connectivityOutbox.next else { return }
        guard let message = message(for: item) else {
            finishOutboxItem(item.id)
            return
        }

        if session.activationState == .activated,
           let reading = item.reading,
           Date().timeIntervalSince(reading.receivedAt) > LibreWatchReadingAcceptancePolicy.maximumTransportAge {
            outboxInFlightID = item.id
            transferOutboxItemIfActivated(item, message: message)
            return
        }

        switch LibreWatchConnectivityDeliveryPolicy.action(
            sessionIsActivated: session.activationState == .activated,
            phoneIsReachable: session.isReachable
        ) {
        case .activateAndQueue:
            requestSessionActivationIfNeeded()
        case .transferUserInfo:
            outboxInFlightID = item.id
            transferOutboxItemIfActivated(item, message: message)
        case .sendMessage:
            outboxInFlightID = item.id
            session.sendMessage(message, replyHandler: { [weak self] reply in
                DispatchQueue.main.async {
                    guard let self, self.outboxInFlightID == item.id else { return }
                    let success = reply[LibreWatchMessageKey.success] as? Bool ?? false
                    let outcome = (reply[LibreWatchMessageKey.deliveryOutcome] as? String)
                        .flatMap { LibreWatchDeliveryOutcome(rawValue: $0) }
                    if success {
                        self.finishOutboxItem(item.id)
                    } else if item.kind == .reading,
                              LibreWatchConnectivityDeliveryPolicy.shouldRetryReadingAsQueued(
                                after: outcome
                              ) {
                        // The interactive delivery either crossed the live-age boundary or
                        // raced an explicit phone return. The queued path independently checks
                        // the persisted cutoff receipt before accepting historical data.
                        self.transferOutboxItemIfActivated(item, message: message)
                    } else {
                        self.finishOutboxItem(item.id)
                    }
                }
            }, errorHandler: { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.outboxInFlightID == item.id else { return }
                    switch LibreWatchConnectivityDeliveryPolicy.actionAfterSendError(
                        sessionIsActivated: self.session.activationState == .activated
                    ) {
                    case .transferUserInfo:
                        self.transferOutboxItemIfActivated(item, message: message)
                    case .activateAndQueue:
                        self.outboxInFlightID = nil
                        self.requestSessionActivationIfNeeded()
                    case .sendMessage:
                        break
                    }
                }
            })
        }
    }

    private func sendLibreWatchCommand(
        _ command: LibreWatchCommand,
        sessionID: UUID,
        unlockCounter: UInt16? = nil,
        releaseCutoff: Date? = nil,
        diagnosticEvent: Data? = nil,
        queueIfUnreachable: Bool = false,
        completion: ((Bool, String?) -> Void)?
    ) {
        if queueIfUnreachable {
            let eventID: UUID?
            if let diagnosticEvent,
               let event = try? JSONDecoder().decode(LibreWatchDiagnosticEvent.self, from: diagnosticEvent) {
                eventID = event.eventID
            } else {
                eventID = nil
            }
            enqueueForWatchConnectivity(.command(
                command,
                sessionID: sessionID,
                unlockCounter: unlockCounter,
                diagnosticEvent: diagnosticEvent,
                id: eventID ?? UUID()
            ))
            completion?(true, nil)
            return
        }

        var message: [String: Any] = [
            LibreWatchMessageKey.command: command.rawValue,
            LibreWatchMessageKey.sessionID: sessionID.uuidString
        ]
        if let unlockCounter {
            message[LibreWatchMessageKey.unlockCounter] = Int(unlockCounter)
        }
        if let releaseCutoff {
            message[LibreWatchMessageKey.releaseCutoff] = releaseCutoff.timeIntervalSince1970
        }
        if let diagnosticEvent {
            message[LibreWatchMessageKey.diagnosticEvent] = diagnosticEvent
        }

        guard session.activationState == .activated else {
            requestSessionActivationIfNeeded()
            completion?(false, "WatchConnectivity is not activated")
            return
        }

        guard session.isReachable else {
            completion?(false, LibreWatchDirectFailure.phoneUnavailable.rawValue)
            return
        }

        session.sendMessage(message, replyHandler: { reply in
            DispatchQueue.main.async {
                let success = reply[LibreWatchMessageKey.success] as? Bool ?? false
                let error = reply[LibreWatchMessageKey.error] as? String
                if let rawOwnership = reply[LibreWatchMessageKey.ownership] as? String,
                   let ownership = LibreWatchOwnership(rawValue: rawOwnership) {
                    self.setLibreWatchOwnership(ownership)
                }
                completion?(success, error)
            }
        }, errorHandler: { error in
            DispatchQueue.main.async {
                completion?(false, error.localizedDescription)
            }
        })
    }

    // MARK: - Private functions used to interact with the WCSession and prepare internal data

    private func processWatchPayloadFromDictionary(dictionary: [String: Any]) {
        var processedUpdate = false

        if let statusDictionary = dictionary["status"] as? [String: Any] {
            processedUpdate = processStatusFromDictionary(dictionary: statusDictionary)
        }

        if let bgReadingsDictionary = dictionary["bgReadings"] as? [String: Any] {
            processedUpdate = processBgReadingsFromDictionary(dictionary: bgReadingsDictionary) || processedUpdate
        }

        if let agpDictionary = dictionary["agp"] as? [String: Any] {
            processAGPFromDictionary(dictionary: agpDictionary)
            processedUpdate = true
        }

        if processedUpdate {
            // now process the shared user defaults to get data for the WidgetKit complications
            updateComplicationData()
        }
    }

    private func processBgReadingsFromDictionary(dictionary: [String: Any]) -> Bool {
        // While Watch owns Libre, its locally calibrated direct history remains authoritative.
        // iPhone still receives the original direct value for its own normal processing.
        guard libreWatchOwnership != .watch || !isShowingDirectLibreReading else { return false }

        let bgReadingDatesFromDictionary: [Double] = dictionary["bgReadingDatesAsDouble"] as? [Double] ?? [0]

        // let's make a quick check to see if the data about to be processed is from within the last hour
        // this is to avoid long delays when re-opening a Watch app for the first time in days and waiting
        // whilst the whole queue of userInfo messages are processed
        if let lastBgReadingDateFromDictionaryReceived = bgReadingDatesFromDictionary.first, Date(timeIntervalSince1970: lastBgReadingDateFromDictionaryReceived) > Date(timeIntervalSinceNow: -60 * 60 * 1) {
            bgReadingDates = bgReadingDatesFromDictionary.map { bgReadingDateAsDouble -> Date in
                return Date(timeIntervalSince1970: bgReadingDateAsDouble)
            }

            bgReadingValues = dictionary["bgReadingValues"] as? [Double] ?? [100]

            slopeOrdinal = dictionary["slopeOrdinal"] as? Int ?? 0
            deltaValueInUserUnit = dictionary["deltaValueInUserUnit"] as? Double ?? 0
            updatedDate = Date(timeIntervalSince1970: dictionary["generatedAt"] as? Double ?? Date().timeIntervalSince1970)

            // check if there is any BG data available before updating the data source info strings accordingly
            if let bgReadingDate = bgReadingDate() {
                lastUpdatedTextString = Texts_WatchApp.lastReading + " "
                lastUpdatedTimeString = bgReadingDate.formatted(date: .omitted, time: .shortened)
                lastUpdatedTimeAgoString = bgReadingDate.daysAndHoursAgo(appendAgo: true)
            } else {
                lastUpdatedTextString = Texts_WatchApp.noSensorData
                lastUpdatedTimeString = ""
                lastUpdatedTimeAgoString = ""
            }

            return true
        }

        return false
    }

    private func processStatusFromDictionary(dictionary: [String: Any]) -> Bool {
        // transferUserInfo queues every payload while the Watch app is inactive. Ignore old status
        // updates so reopening the app does not replay days of state changes one by one.
        guard let generatedAt = dictionary["generatedAt"] as? Double,
              Date(timeIntervalSince1970: generatedAt) > Date(timeIntervalSinceNow: -60 * 60) else {
            return false
        }

        isMgDl = dictionary["isMgDl"] as? Bool ?? true
        urgentLowLimitInMgDl = dictionary["urgentLowLimitInMgDl"] as? Double ?? 60
        lowLimitInMgDl = dictionary["lowLimitInMgDl"] as? Double ?? 70
        highLimitInMgDl = dictionary["highLimitInMgDl"] as? Double ?? 180
        urgentHighLimitInMgDl = dictionary["urgentHighLimitInMgDl"] as? Double ?? 250
        updatedDate = Date(timeIntervalSince1970: generatedAt)
        activeSensorDescription = dictionary["activeSensorDescription"] as? String ?? ""
        sensorAgeInMinutes = dictionary["sensorAgeInMinutes"] as? Double ?? 0
        sensorMaxAgeInMinutes = dictionary["sensorMaxAgeInMinutes"] as? Double ?? 0
        preferSensorCountdown = dictionary["preferSensorCountdown"] as? Bool ?? false
        sensorNoiseStateRawValue = dictionary["sensorNoiseStateRawValue"] as? Int
        isMaster = dictionary["isMaster"] as? Bool ?? true
        followerDataSourceType = FollowerDataSourceType(rawValue: dictionary["followerDataSourceTypeRawValue"] as? Int ?? 0) ?? .nightscout
        followerBackgroundKeepAliveType = FollowerBackgroundKeepAliveType(rawValue: dictionary["followerBackgroundKeepAliveTypeRawValue"] as? Int ?? 0) ?? .normal
        followerConnectionStatusRawValue = dictionary["followerConnectionStatusRawValue"] as? String
        timeStampOfLastFollowerConnection = Date(timeIntervalSince1970: dictionary["timeStampOfLastFollowerConnection"] as? Double ?? 0)
        secondsUntilFollowerDisconnectWarning = dictionary["secondsUntilFollowerDisconnectWarning"] as? Int ?? 0
        timeStampOfLastHeartBeat = Date(timeIntervalSince1970: dictionary["timeStampOfLastHeartBeat"] as? Double ?? 0)
        secondsUntilHeartBeatDisconnectWarning = dictionary["secondsUntilHeartBeatDisconnectWarning"] as? Int ?? 0
        keepAliveIsDisabled = dictionary["keepAliveIsDisabled"] as? Bool ?? false

        if let aidStatusDictionary = dictionary["aidStatus"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: aidStatusDictionary),
           let decodedStatus = try? JSONDecoder().decode(AIDStatus.self, from: data) {
            aidStatus = decodedStatus
        } else {
            aidStatus = nil
        }

        return true
    }

    private func processAGPFromDictionary(dictionary: [String: Any]) {
        // the payload is column-based because it's smaller and cheaper to decode on watchOS
        // than sending raw glucose history or nested report objects
        let requestID = dictionary["requestID"] as? Double ?? 0
        let minuteOfDayValues = dictionary["minuteOfDayValues"] as? [Int] ?? []
        let p5Values = dictionary["p5Values"] as? [Double] ?? []
        let p25Values = dictionary["p25Values"] as? [Double] ?? []
        let medianValues = dictionary["medianValues"] as? [Double] ?? []
        let p75Values = dictionary["p75Values"] as? [Double] ?? []
        let p95Values = dictionary["p95Values"] as? [Double] ?? []
        let pointCount = [
            minuteOfDayValues.count,
            p5Values.count,
            p25Values.count,
            medianValues.count,
            p75Values.count,
            p95Values.count
        ].min() ?? 0

        // ignore stale replies if the user has already requested a newer AGP profile
        guard requestID == latestAGPRequestID else {
            return
        }

        // this request has now been answered, even if the profile itself is empty
        pendingAGPRequestRange = nil

        guard pointCount > 0 else {
            agpProfilePoints = []
            agpBackgroundPoints = []
            return
        }

        // validate the percentile ordering before storing the profile
        // bad ordering can make Swift Charts draw crossing AGP bands
        agpProfilePoints = (0..<pointCount).compactMap { index in
            let p5 = p5Values[index]
            let p25 = p25Values[index]
            let median = medianValues[index]
            let p75 = p75Values[index]
            let p95 = p95Values[index]
            let minuteOfDay = minuteOfDayValues[index]

            guard (0..<1440).contains(minuteOfDay), p5 <= p25, p25 <= median, median <= p75, p75 <= p95 else {
                return nil
            }

            return WatchAGPProfilePoint(
                minuteOfDay: minuteOfDay,
                p5MgDl: p5,
                p25MgDl: p25,
                medianMgDl: median,
                p75MgDl: p75,
                p95MgDl: p95
            )
        }

        let fallbackEndDate = Date()
        let fallbackStartDate = fallbackEndDate.addingTimeInterval(-12 * 60 * 60)

        // create an initial mapped set immediately so the AGP page can render as soon as the data arrives
        // later chart renders will remap from agpProfilePoints for their own visible range
        agpBackgroundPoints = mapAGPProfileToVisibleRange(
            startDate: bgReadingDates.last ?? fallbackStartDate,
            endDate: bgReadingDates.first ?? fallbackEndDate
        )
    }

    /// once we've process the state update, then save this data to the shared app group so that the complication can read it
    private func updateComplicationData() {
        guard let sharedUserDefaults = UserDefaults(suiteName: Bundle.main.appGroupSuiteName) else { return }

        // Do not leave stale glucose behind the warning when disabled; complications may remain
        // visible long after watchOS stops receiving updates from the phone.
        let complicationBgReadingValues = keepAliveIsDisabled ? [] : bgReadingValues
        let complicationBgReadingDates = keepAliveIsDisabled ? [] : bgReadingDates
        let hidesDirectDerivedValues = libreWatchOwnership == .watch &&
            isShowingDirectLibreReading &&
            !directLibreReadingIsCurrent()
        let complicationSlopeOrdinal = keepAliveIsDisabled || hidesDirectDerivedValues ? 0 : slopeOrdinal
        let complicationDeltaValueInUserUnit: Double? = keepAliveIsDisabled || hidesDirectDerivedValues
            ? nil
            : deltaValueInUserUnit

        let bgReadingDatesAsDouble = complicationBgReadingDates.map { date in
            date.timeIntervalSince1970
        }

        let complicationSharedUserDefaultsModel = ComplicationSharedUserDefaultsModel(bgReadingValues: complicationBgReadingValues, bgReadingDatesAsDouble: bgReadingDatesAsDouble, isMgDl: isMgDl, slopeOrdinal: complicationSlopeOrdinal, deltaValueInUserUnit: complicationDeltaValueInUserUnit, urgentLowLimitInMgDl: urgentLowLimitInMgDl, lowLimitInMgDl: lowLimitInMgDl, highLimitInMgDl: highLimitInMgDl, urgentHighLimitInMgDl: urgentHighLimitInMgDl, keepAliveIsDisabled: keepAliveIsDisabled)

        // store the model in the shared user defaults using a name that is uniquely specific to this copy of the app as installed on
        // the user's device - this allows several copies of the app to be installed without cross-contamination of widget/complication data
        if let stateData = try? JSONEncoder().encode(complicationSharedUserDefaultsModel) {
            sharedUserDefaults.set(stateData, forKey: "complicationSharedUserDefaults.\(Bundle.main.mainAppBundleIdentifier)")
        }

        // now that the new data is stored in the app group, try to force the complications to reload
        WidgetCenter.shared.reloadAllTimelines()

        lastComplicationUpdateTimeStamp = .now
    }
}

// MARK: - WCSession delegate to handle communications

extension WatchStateModel: WCSessionDelegate {
    func session(_: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        // keep Watch state changes on the main queue because WCSession delivers delegate callbacks on a non-main queue
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activationWasRequested = false
            // The payload remains persisted until a transport accepts it. Reclaim any send that
            // was interrupted by session reactivation; stable payload IDs make retry idempotent.
            self.outboxInFlightID = nil
            guard activationState == .activated else {
                if let error {
                    self.log.error("WatchConnectivity activation failed; queued Libre data retained: \(error.localizedDescription, privacy: .public)")
                }
                return
            }

            self.requestWatchStateUpdate()
            // if the AGP tab requested data while activation was pending, send it now
            self.sendPendingAGPRequestIfPossible()
            self.flushWatchConnectivityOutbox()
        }
    }

    func sessionReachabilityDidChange(_: WCSession) {
        DispatchQueue.main.async {
            // retry AGP requests that were made before the phone became reachable
            self.sendPendingAGPRequestIfPossible()
            self.flushWatchConnectivityOutbox()
        }
    }

    func session(_: WCSession, didReceiveMessageData _: Data) {}

    func session(_: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            self.processLibreWatchPayload(message)
            self.processWatchPayloadFromDictionary(dictionary: message)
            self.requestingDataIconColor = ConstantsAppleWatch.requestingDataIconColorActive

            // change the requesting icon color back after a small delay to prevent it
            // flashing on/off too quickly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.requestingDataIconColor = ConstantsAppleWatch.requestingDataIconColorInactive
            }
        }
    }

    func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        DispatchQueue.main.async {
            self.processLibreWatchPayload(userInfo)
            self.processWatchPayloadFromDictionary(dictionary: userInfo)
        }
    }

    func session(
        _: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        DispatchQueue.main.async {
            self.processLibreWatchPayload(applicationContext)
        }
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
