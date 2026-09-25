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

    // Local rendering only. This timer never polls WatchConnectivity or wakes watchOS.
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

    @Published private(set) var lastPhoneStatusReceivedAt: Date?
    @Published private(set) var lastPhoneGraphReceivedAt: Date?
    private var phoneSensorStartedAt: Date?
    private var sensorAgeReferenceDate: Date?
    private var mappedAGPRange: (start: Date, end: Date)?
    private var mappedAGPPoints: [GlucoseChartAGPPoint] = []
    private lazy var phoneRefresh = WatchRefreshCoordinator(
        schedule: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
        isReachable: { [weak self] in self?.phoneIsReachable == true },
        send: { [weak self] message, reply, failure in
            guard let self else { return }
            self.requestingDataIconColor = ConstantsAppleWatch.requestingDataIconColorPending
            let replyHandler: (([String: Any]) -> Void)? = reply.map { callback in
                { payload in DispatchQueue.main.async { callback(payload) } }
            }
            self.session.sendMessage(message, replyHandler: replyHandler) { error in
                DispatchQueue.main.async { failure(error) }
            }
        },
        consume: { [weak self] payload in
            guard let self else { return [] }
            self.processLibreWatchPayload(payload)
            return self.processWatchPayloadFromDictionary(dictionary: payload)
        },
        event: { [weak self] stream, action, outcome in
            let evidenceStream: WatchDeliveryEvidenceStream
            switch stream {
            case .status: evidenceStream = .status
            case .bgReadings: evidenceStream = .graph
            case .agp: evidenceStream = .agp
            }
            WatchDeliveryEvidenceStore.shared.recordTransport(stream: evidenceStream, action: action, outcome: outcome)
            if action == "failed" {
                self?.log.error("Watch refresh \(stream.rawValue, privacy: .public) failed: \(outcome ?? "unknown", privacy: .public)")
                self?.requestingDataIconColor = ConstantsAppleWatch.requestingDataIconColorInactive
            } else if action == "received" {
                self?.requestingDataIconColor = ConstantsAppleWatch.requestingDataIconColorInactive
                if stream == .status { self?.lastPhoneStatusReceivedAt = Date() }
                if stream == .bgReadings { self?.lastPhoneGraphReceivedAt = Date() }
            }
        })

    @Published var isMgDl: Bool = true
    @Published var slopeOrdinal: Int = 2
    @Published var deltaValueInUserUnit: Double = 0
    @Published var urgentLowLimitInMgDl: Double = 60
    @Published var lowLimitInMgDl: Double = 80
    @Published var highLimitInMgDl: Double = 170
    @Published var urgentHighLimitInMgDl: Double = 250
    @Published var updatedDate: Date = .distantPast
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
    /// Source of the displayed measurement; Bluetooth ownership is tracked independently.
    @Published private(set) var isShowingDirectLibreReading = false
    @Published private(set) var directLibreReadingIsStale = false
    @Published private(set) var libreWatchStorageIssue: String?
    @Published private(set) var localAlarmStatus = "Watch-alarmer: venter på iPhone-indstillinger"
    private let localAlarms = LibreWatchAlarmController()

    /// Original direct values are retained in memory so a newer iPhone calibration can
    /// recompute the Watch-only presentation without altering values sent back to iPhone.
    private var directReadingHistory: [LibreWatchDirectReadingPayload] = []
    private var latestDirectSourceDelta: Double?
    private var latestReadingQueuePersistenceConfirmed: Bool?
    private var directReadingAcceptance = LibreWatchReadingAcceptancePolicy()
    private var connectivityOutbox = LibreWatchSessionStore.loadOutbox()
    private var evidenceConfirmedOutboxIDs = Set<UUID>()
    private var diagnosticJournal = LibreWatchSessionStore.loadDiagnosticJournal()
    private let diagnosticDelivery = LibreWatchDiagnosticDeliveryScheduler(schedule: {
        DispatchQueue.main.async(execute: $0)
    })
    private var outboxSendGate = LibreWatchConnectivitySendAttemptGate()
    private var pendingPhoneReturn = LibreWatchSessionStore.loadPhoneReturn()
    private var phoneReturnSendToken: UUID?
    private var lastPhoneReturnSendAt: Date?
    private var phoneReturnCompletion: ((Bool, String?) -> Void)?
    private var phoneReturnDiagnostic: ((LibreWatchReturnDiagnostic.Stage, LibreWatchReturnDiagnostic.Reason?, NSError?) -> Void)?
    private var lastDiagnosticReplayAt: Date?
    private var activationWasRequested = false
    private var lastAlarmAcknowledgementAttemptAt: Date?
    private var acceptedHandoffRevision = LibreWatchSessionStore.loadHandoffRevision()
    private let acceptedHandoffSnapshotKey = "libreWatchAcceptedHandoffContent.v1"
    private var acceptedHandoffSnapshot = UserDefaults.standard.data(forKey: "libreWatchAcceptedHandoffContent.v1")
        .flatMap { try? JSONDecoder().decode(LibreWatchHandoffSnapshot.self, from: $0) }

    @Published var therapyMetrics: TherapyMetricsSnapshot?
    var resolvedTherapyMetrics: TherapyMetricsSnapshot { therapyMetrics ?? .external(aidStatus) }
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

        if let pending = pendingPhoneReturn {
            if !pending.matches(libreWatchDirectSession) ||
                (libreWatchOwnership == .iphone && acceptedHandoffRevision > pending.startingRevision) {
                pendingPhoneReturn = nil
                LibreWatchSessionStore.savePhoneReturn(nil)
            } else {
                // A process restart cannot turn an unconfirmed release into Watch ownership.
                libreWatchOwnership = .releasingToPhone
                LibreWatchSessionStore.saveOwnership(.releasingToPhone)
            }
        }

        if let directSession = libreWatchDirectSession,
           libreWatchCalibrationSnapshot?.matches(session: directSession) != true {
            libreWatchCalibrationSnapshot = nil
            LibreWatchSessionStore.clearCalibration()
        }
        restorePersistedLibreWatchReadingIfPossible()
        if let status = WatchPhoneSnapshotStore.stored(.status) {
            _ = processStatusFromDictionary(dictionary: status, restoring: true)
        }
        if let readings = WatchPhoneSnapshotStore.stored(.bgReadings) {
            _ = processBgReadingsFromDictionary(dictionary: readings, restoring: true)
        }
        updateComplicationData()
        restorePendingDiagnosticJournalToOutbox()
        localAlarms.onStatusChange = { [weak self] status in self?.localAlarmStatus = status }
        localAlarms.onReadinessChange = { [weak self] in self?.synchronizeLocalAlarmState() }
        localAlarms.onSnooze = { [weak self] in self?.synchronizeLocalAlarmState() }
        localAlarms.validate(session: libreWatchDirectSession)
        localAlarms.ownershipDidChange(libreWatchOwnership)
        localAlarms.refreshPermission()

        session.delegate = self
        if session.activationState == .activated {
            retryPendingPhoneReturn()
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
           (isShowingDirectLibreReading && libreWatchOwnership == .watch) ||
           (isShowingDirectLibreReading ? directLibreReadingIsCurrent() : bgReadingDate > Date().addingTimeInterval(-60 * 20)) {
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
           (!isShowingDirectLibreReading || directLibreReadingIsCurrent()),
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
           (!isShowingDirectLibreReading || directLibreReadingIsCurrent()),
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
        let sensorAgeInMinutes = currentSensorAgeInMinutes()
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
        let sensorAgeInMinutes = currentSensorAgeInMinutes()
        let lifetimeInMinutes = preferSensorCountdown ? max(sensorMaxAgeInMinutes - sensorAgeInMinutes, 0) : sensorAgeInMinutes
        return lifetimeInMinutes.minutesToDaysAndHours()
    }

    private func currentSensorAgeInMinutes(at now: Date = Date()) -> Double {
        if isShowingDirectLibreReading, let measured = bgReadingDate() {
            return sensorAgeInMinutes + max(0, now.timeIntervalSince(measured)) / 60
        }
        if let started = phoneSensorStartedAt { return max(0, now.timeIntervalSince(started)) / 60 }
        return sensorAgeInMinutes + max(0, now.timeIntervalSince(sensorAgeReferenceDate ?? now)) / 60
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

    /// Use the common AID renderer so this surface inherits the same symbol weight as the app.
    /// Keep a missing symbol absent so checking states do not imply an active loop.
    func aidStatusIconImage() -> AIDStatusSymbolImage? {
        guard let symbol = aidStatus?.presentation().symbol else { return nil }
        return AIDStatusSymbolImage(symbol: symbol)
    }

    func aidStatusIOBString() -> String {
        resolvedTherapyMetrics.iob.formatted(isIOB: true)
    }

    func aidStatusCOBString() -> String {
        resolvedTherapyMetrics.cob.formatted(isIOB: false)
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
        if session.activationState != .activated { requestSessionActivationIfNeeded() }
        phoneRefresh.request(force: true)
    }

    /// RootView owns execution/selection. Hidden TabView pages cannot start pollers.
    func phoneRefreshVisibilityDidChange(active: Bool, showsAGP: Bool, hours: Double) {
        let end = Date().addingTimeInterval(5 * 60)
        phoneRefresh.setAGPRange(start: end.addingTimeInterval(-(hours * 60 * 60 + 5 * 60)), end: end)
        phoneRefresh.setVisibleStreams(showsAGP ? [.status, .bgReadings, .agp] : [.status, .bgReadings])
        phoneRefresh.setExecutionAvailable(active)
        if active, session.activationState != .activated { requestSessionActivationIfNeeded() }
    }

    var phoneIsReachable: Bool {
        session.activationState == .activated && session.isReachable
    }

    var libreWatchConnectivityIsActivated: Bool { session.activationState == .activated }
    var libreWatchConnectivityActivationState: Int { session.activationState.rawValue }
    var libreWatchConnectivityIsReachable: Bool { session.isReachable }
    var hasPendingLibrePhoneReturn: Bool { pendingPhoneReturn != nil }

    func requestLibreWatchOwnership(completion: @escaping (Bool, String?) -> Void) {
        guard pendingPhoneReturn == nil else {
            retryPendingPhoneReturn()
            completion(false, "Awaiting iPhone confirmation of the previous return")
            return
        }
        guard let preparedSession = libreWatchDirectSession, preparedSession.isValid else {
            completion(false, LibreWatchDirectFailure.noSession.rawValue)
            return
        }
        guard phoneIsReachable else {
            completion(false, LibreWatchDirectFailure.phoneUnavailable.rawValue)
            return
        }

        let startingRevision = acceptedHandoffRevision
        setLibreWatchOwnership(.releasingToWatch)
        sendLibreWatchCommand(.requestOwnership, sessionID: preparedSession.id) { [weak self] success, error in
            guard let self else { return }
            let snapshotConfirmed = self.acceptedHandoffRevision > startingRevision &&
                self.libreWatchDirectSession?.id == preparedSession.id && self.libreWatchOwnership == .watch
            if !success, !snapshotConfirmed, self.libreWatchOwnership == .releasingToWatch {
                self.setLibreWatchOwnership(.iphone)
            }
            completion((success || snapshotConfirmed) && self.libreWatchOwnership == .watch,
                       snapshotConfirmed ? nil : error)
        }
    }

    func releaseLibreWatchOwnership(
        unlockCounter: UInt16?,
        diagnostic: ((LibreWatchReturnDiagnostic.Stage, LibreWatchReturnDiagnostic.Reason?, NSError?) -> Void)? = nil,
        completion: @escaping (Bool, String?) -> Void
    ) {
        diagnostic?(.releasePreparing, nil, nil)
        guard let preparedSession = libreWatchDirectSession, preparedSession.isValid else {
            diagnostic?(.failed, .noSession, nil)
            completion(false, LibreWatchDirectFailure.noSession.rawValue)
            return
        }
        guard phoneIsReachable else {
            diagnostic?(.failed, session.activationState == .activated ? .phoneUnreachable : .notActivated, nil)
            completion(false, LibreWatchDirectFailure.phoneUnavailable.rawValue)
            return
        }

        if pendingPhoneReturn == nil {
            var releaseSession = preparedSession
            releaseSession.unlockCount = max(preparedSession.unlockCount, unlockCounter ?? 0)
            pendingPhoneReturn = LibreWatchPhoneReturnTransaction(session: releaseSession,
                cutoff: Date(), startingRevision: acceptedHandoffRevision)
            LibreWatchSessionStore.savePhoneReturn(pendingPhoneReturn)
        }
        setLibreWatchOwnership(.releasingToPhone)
        phoneReturnCompletion = completion
        phoneReturnDiagnostic = diagnostic
        retryPendingPhoneReturn(force: true, diagnostic: diagnostic, completion: completion)
    }

    /// Reuses existing lifecycle/transport execution opportunities, never a polling timer.
    /// The transaction was persisted only after the collector confirmed native disconnection.
    func retryPendingPhoneReturn(at date: Date = Date(), force: Bool = false,
        diagnostic: ((LibreWatchReturnDiagnostic.Stage, LibreWatchReturnDiagnostic.Reason?, NSError?) -> Void)? = nil,
        completion: ((Bool, String?) -> Void)? = nil) {
        guard var pending = pendingPhoneReturn, pending.matches(libreWatchDirectSession),
              libreWatchOwnership == .releasingToPhone, phoneReturnSendToken == nil,
              phoneIsReachable,
              force || date.timeIntervalSince(lastPhoneReturnSendAt ?? .distantPast) >= LibreWatchConnectivityOutbox.retryInterval
        else { return }
        let sendToken = UUID()
        phoneReturnSendToken = sendToken
        lastPhoneReturnSendAt = date
        let effectiveDiagnostic = diagnostic ?? phoneReturnDiagnostic
        sendLibreWatchCommand(
            .releaseOwnership,
            sessionID: pending.session.id,
            unlockCounter: max(pending.session.unlockCount, libreWatchDirectSession?.unlockCount ?? 0),
            releaseCutoff: pending.cutoff,
            returnDiagnostic: effectiveDiagnostic,
            returnReplyIsCurrent: { [weak self] in
                self?.phoneReturnSendToken == sendToken && self?.pendingPhoneReturn?.id == pending.id
            },
            returnWillSend: { [weak self] in
                pending.wasSubmitted = true
                self?.pendingPhoneReturn = pending
                LibreWatchSessionStore.savePhoneReturn(pending)
            },
            returnResponse: { [weak self] response, error in
                guard let self, self.phoneReturnSendToken == sendToken,
                      self.pendingPhoneReturn?.id == pending.id else { return }
                self.phoneReturnSendToken = nil
                let resolution = pending.resolution(for: response, currentSession: self.libreWatchDirectSession,
                    ownership: self.libreWatchOwnership, acceptedRevision: self.acceptedHandoffRevision)
                switch resolution {
                case .phone, .watch:
                    self.finishPhoneReturn(pending, owner: resolution == .phone ? .iphone : .watch, error: error)
                case .pending:
                    // Unknown is not rejection. Keep the persisted cutoff and remain disconnected.
                    self.log.info("Libre return is awaiting iPhone confirmation; Watch remains disconnected")
                    completion?(false, "Awaiting iPhone confirmation; Watch remains disconnected")
                case .obsolete:
                    break
                }
            }, completion: nil)
    }

    private func finishPhoneReturn(_ pending: LibreWatchPhoneReturnTransaction,
                                   owner: LibreWatchOwnership, error: String? = nil,
                                   reason: LibreWatchReturnDiagnostic.Reason? = nil) {
        guard pendingPhoneReturn?.id == pending.id, pending.matches(libreWatchDirectSession) else { return }
        let completion = phoneReturnCompletion
        let diagnostic = phoneReturnDiagnostic
        phoneReturnCompletion = nil
        phoneReturnDiagnostic = nil
        // Persist the resolved owner first. An interrupted cleanup may safely retry the
        // remaining transaction; a missing transaction with .releasingToPhone cannot.
        setLibreWatchOwnership(owner)
        pendingPhoneReturn = nil
        phoneReturnSendToken = nil
        LibreWatchSessionStore.savePhoneReturn(nil)
        diagnostic?(owner == .iphone ? .completed : .failed, reason, nil)
        completion?(owner == .iphone, error)
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
    func submitLibreWatchReading(_ directReading: Libre2WatchDirectReading, payloadID: UUID = UUID()) -> Bool {
        guard let directSession = libreWatchDirectSession,
              let snapshot = libreWatchCalibrationSnapshot,
              snapshot.matches(session: directSession),
              libreWatchOwnership == .watch
        else {
            let reason = libreWatchDirectSession == nil ? "missingSession" :
                libreWatchCalibrationSnapshot == nil ? "missingCalibration" :
                libreWatchOwnership != .watch ? "notWatchOwner" : "calibrationSessionMismatch"
            WatchDeliveryEvidenceStore.shared.record(stage: .rejected, payloadID: payloadID,
                sessionID: libreWatchDirectSession?.id, measuredAt: directReading.receivedAt,
                sensorElapsedMinutes: directReading.sensorTimeInMinutes, outcome: reason)
            return false
        }

        let reading = directReading.payload(
            id: payloadID,
            sessionID: directSession.id,
            valueDomain: snapshot.requiredValueDomain,
            calibrationRevision: snapshot.revision
        )
        guard reading.isValid(for: snapshot),
              snapshot.displayedGlucose(for: reading) != nil
        else {
            WatchDeliveryEvidenceStore.shared.recordReading(.rejected, reading: reading, outcome: "invalidValueOrCalibration")
            return false
        }

        let now = Date()
        let priorAcceptance = directReadingAcceptance
        let accepted = LibreWatchReadingSubmission.receive(
            reading,
            sessionID: directSession.id,
            acceptance: directReadingAcceptance,
            outbox: connectivityOutbox,
            at: now,
            persist: { pending in
                LibreWatchSessionStore.prepareOutboxForDelivery(&pending, sessionID: directSession.id, at: now)
            },
            publishLocally: { commit in
                // Storage is attempted before publication, without holding any inout
                // access during the existing display and local alarm paths.
                connectivityOutbox = commit.outbox
                directReadingAcceptance = commit.acceptance
                latestReadingQueuePersistenceConfirmed = commit.persistence == .durable
                libreWatchStorageIssue = commit.persistence.issue
                WatchDeliveryEvidenceStore.shared.recordReading(.accepted, reading: reading)
                let durable = commit.persistence == .durable
                WatchDeliveryEvidencePipeline.localWrite(
                    durable,
                    item: .reading(reading),
                    failureReason: commit.persistence == .notRetained
                        ? "notRetainedByOutbox" : "atomicOutboxWriteFailed"
                )
                if durable { evidenceConfirmedOutboxIDs.insert(reading.id) }
                applyLibreWatchReadingLocally(reading)
                if let glucose = snapshot.displayedGlucose(for: reading) {
                    localAlarms.acceptedDirectReading(reading, glucose: glucose)
                }
            }
        )
        guard accepted else {
            WatchDeliveryEvidenceStore.shared.recordReading(.rejected, reading: reading,
                outcome: WatchDeliveryEvidencePipeline.rejection(of: reading, policy: priorAcceptance, at: now))
            return false
        }
        flushWatchConnectivityOutbox()
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

        guard directReadingHistory.first?.id == reading.id,
              bgReadingDate() == reading.receivedAt else { return }
        let sourceDelta = sourceDeltaOverride ?? directSourceDelta(for: reading)
        let displayedDelta = displayedDeltaOverride ?? displayedLibreDelta(sourceDelta)
        latestDirectSourceDelta = sourceDelta
        updateDirectDerivedValues(
            for: reading,
            displayedGlucose: displayed.glucose,
            displayedTrend: displayed.trend,
            displayedDelta: displayedDelta
        )
        isShowingDirectLibreReading = true

        let stored = LibreWatchPersistedDirectReading(
            sessionID: reading.sessionID,
            sensorIdentity: directSession.redactedIdentity(),
            sourceReading: reading,
            sourceDelta: sourceDelta,
            displayedGlucoseMGDL: displayed.glucose,
            displayedTrendMGDLPerMinute: displayed.trend,
            displayedDeltaMGDL: displayedDelta,
            calibrationRevision: displayed.revision,
            queuePersistenceConfirmed: latestReadingQueuePersistenceConfirmed
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
              let measuredAt = bgReadingDate()
        else { return false }
        return ComplicationReadingSource.directLibre.isCurrent(measuredAt: measuredAt, at: date)
    }

    func refreshDirectLibreReadingFreshness(at date: Date = Date()) {
        guard isShowingDirectLibreReading else {
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
        guard let directSession = libreWatchDirectSession,
              let snapshot = libreWatchCalibrationSnapshot
        else { return }
        let stored = LibreWatchSessionStore.loadReading()
        let now = Date()
        guard let restored = LibreWatchReadingSubmission.restore(
            cached: stored, outbox: connectivityOutbox, session: directSession, calibration: snapshot, at: now,
            persist: { pending in
                LibreWatchSessionStore.prepareOutboxForDelivery(&pending, sessionID: directSession.id, at: now)
            }
        ) else { return }
        connectivityOutbox = restored.outbox
        latestReadingQueuePersistenceConfirmed = restored.persistence == .durable
        libreWatchStorageIssue = restored.persistence.issue
        directReadingAcceptance.reset(
            for: directSession.id,
            seeding: restored.reading
        )
        let displayOverride = stored.flatMap { cached -> (Double, Double?, UInt64?)? in
            guard cached.sourceReading.id == restored.reading.id,
                  cached.calibrationRevision == snapshot.revision,
                  cached.isValid(for: directSession, calibration: snapshot) else { return nil }
            return (cached.displayedGlucoseMGDL, cached.displayedTrendMGDLPerMinute, cached.calibrationRevision)
        }
        applyLibreWatchReadingLocally(
            restored.reading,
            displayedOverride: displayOverride,
            sourceDeltaOverride: nil,
            displayedDeltaOverride: nil
        )
    }

    func reportLibreWatchDiagnostic(_ event: LibreWatchDiagnosticEvent) {
        reportLibreWatchDiagnostics([event])
    }

    /// Persists one Core Bluetooth callback's immutable snapshots with one journal write and
    /// one outbox write. The journal remains first so a process exit between the two stores is
    /// repaired by `restorePendingDiagnosticJournalToOutbox` on the next execution opportunity.
    /// Only transport is deferred: suspension before that work runs leaves the local snapshots
    /// available for replay. Reading acceptance and its immediate delivery path are unchanged.
    func reportLibreWatchDiagnostics(_ events: [LibreWatchDiagnosticEvent]) {
        for event in events { WatchDeliveryEvidenceStore.shared.recordCollectorDiagnostic(event) }
        guard !events.isEmpty else { return }
        var preparedEvents: [LibreWatchDiagnosticEvent] = []

        for sourceEvent in events {
            var event = sourceEvent
            let eventSessionID = event.sessionID ?? libreWatchDirectSession?.id
            if let settings = localAlarms.settings, settings.sessionID == eventSessionID {
                let at = event.watchTimestamp ?? Date()
                event.alarmSettingsRevision = settings.revision
                event.alarmEnabledKinds = LibreWatchAlarmKind.allCases.filter {
                    settings.rule(for: $0, at: at)?.enabled == true
                }.map(\.rawValue)
                event.alarmSnoozeAllUntil = settings.snoozeAllUntil
                event.alarmSnoozes = Dictionary(uniqueKeysWithValues: LibreWatchAlarmKind.allCases.compactMap { kind in
                    let until = localAlarms.state.snoozedUntil(kind, settings: settings)
                    return until > at ? (kind.rawValue, until) : nil
                })
                event.alarmNotificationsAuthorized = localAlarms.notificationsAreAuthorized
                event.alarmDelegatedToWatch = localAlarms.alarmsAreDelegatedToWatch
            }

            preparedEvents.append(event)
        }

        _ = LibreWatchDiagnosticBatch.stage(
            preparedEvents,
            fallbackSessionID: libreWatchDirectSession?.id,
            journal: &diagnosticJournal,
            outbox: &connectivityOutbox
        )
        LibreWatchSessionStore.saveDiagnosticJournal(diagnosticJournal)
        LibreWatchSessionStore.saveOutbox(connectivityOutbox)
        diagnosticDelivery.request { [weak self] in self?.flushWatchConnectivityOutbox() }
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
        guard isShowingDirectLibreReading,
              let directSession = libreWatchDirectSession,
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
            calibrationRevision: displayed.revision,
            queuePersistenceConfirmed: latestReadingQueuePersistenceConfirmed
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
        latestReadingQueuePersistenceConfirmed = nil
        libreWatchStorageIssue = nil
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
        phoneRefresh.setAGPRange(start: startDate, end: endDate)
    }

    /// Maps the stored daily AGP profile onto the dates currently visible on the Watch chart.
    func agpBackgroundPointsMatching(startDate: Date, endDate: Date) -> [GlucoseChartAGPPoint] {
        if mappedAGPRange?.start != startDate || mappedAGPRange?.end != endDate {
            mappedAGPPoints = mapAGPProfileToVisibleRange(startDate: startDate, endDate: endDate)
            mappedAGPRange = (startDate, endDate)
        }
        return mappedAGPPoints
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


    private func setLibreWatchOwnership(_ ownership: LibreWatchOwnership) {
        let ownershipChanged = ownership != libreWatchOwnership
        libreWatchOwnership = ownership
        LibreWatchSessionStore.saveOwnership(ownership)
        localAlarms.ownershipDidChange(ownership)
        if ownershipChanged {
            directReadingAcceptance.reset(
                for: ownership == .watch ? libreWatchDirectSession?.id : nil
            )
        }
        if ownership == .watch {
            if directReadingHistory.isEmpty {
                restorePersistedLibreWatchReadingIfPossible()
            } else {
                refreshDirectLibreReadingFreshness()
            }
        } else if ownership == .iphone {
            refreshDirectLibreReadingFreshness()
        }
    }

    @discardableResult
    private func processLibreWatchPayload(_ incomingPayload: [String: Any]) -> Bool {
        var payload = incomingPayload
        var handoffRevision: UInt64?
        var applyingSnapshot: LibreWatchHandoffSnapshot?
        if let snapshotData = payload[LibreWatchMessageKey.handoffSnapshot] as? Data {
            guard let snapshot = try? JSONDecoder().decode(LibreWatchHandoffSnapshot.self, from: snapshotData),
                  snapshot.isValid
            else { return false }
            if snapshot.revision == acceptedHandoffRevision {
                // An unchanged authoritative snapshot is idempotent. Matching only ID
                // and owner would also accept conflicting calibration/alarm/unlock data.
                // A pre-upgrade installation has no such evidence and waits for the
                // next real authoritative revision rather than inventing acceptance.
                return acceptedHandoffSnapshot == snapshot
            }
            guard snapshot.canApply(after: acceptedHandoffRevision) else { return false }
            payload[LibreWatchMessageKey.session] = try? JSONEncoder().encode(snapshot.session)
            payload[LibreWatchMessageKey.calibration] = snapshot.calibration.flatMap { try? JSONEncoder().encode($0) }
            payload[LibreWatchMessageKey.ownership] = snapshot.ownership.rawValue
            payload[LibreWatchMessageKey.alarmSettings] = snapshot.alarmSettings.flatMap { try? JSONEncoder().encode($0) }
            payload[LibreWatchMessageKey.alarmDelegation] = snapshot.alarmDelegation.flatMap { try? JSONEncoder().encode($0) }
            payload[LibreWatchMessageKey.alarmsReady] = snapshot.alarmDelegation != nil
            handoffRevision = snapshot.revision
            applyingSnapshot = snapshot
        } else if acceptedHandoffRevision > 0 {
            // Already-queued contexts from before the atomic snapshot must not roll back
            // a completed takeover or return. Updated phones always include the snapshot.
            return false
        }
        guard let data = payload[LibreWatchMessageKey.session] as? Data,
              var preparedSession = try? JSONDecoder().decode(LibreWatchDirectSession.self, from: data),
              preparedSession.isValid
        else { return false }

        let sessionChanged = libreWatchDirectSession?.id != preparedSession.id ||
            libreWatchDirectSession?.representsSameSensor(as: preparedSession) == false
        if sessionChanged {
            pendingPhoneReturn = nil
            phoneReturnSendToken = nil
            phoneReturnCompletion = nil
            phoneReturnDiagnostic = nil
            clearStoredDirectStateForSessionChange()
        }

        if let currentSession = libreWatchDirectSession,
           currentSession.id == preparedSession.id,
           currentSession.representsSameSensor(as: preparedSession),
           currentSession.unlockCount > preparedSession.unlockCount {
            preparedSession.unlockCount = currentSession.unlockCount
        }

        libreWatchDirectSession = preparedSession
        LibreWatchSessionStore.saveSession(preparedSession)
        if sessionChanged {
            localAlarms.validate(session: preparedSession)
            connectivityOutbox.retain(sessionID: preparedSession.id)
            if let attempt = outboxSendGate.activeAttempt,
               !connectivityOutbox.items.contains(where: { $0.id == attempt.payloadID }) {
                outboxSendGate.invalidate()
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
        processLibreWatchAlarmResponse(payload)

        if let rawOwnership = payload[LibreWatchMessageKey.ownership] as? String,
           let ownership = LibreWatchOwnership(rawValue: rawOwnership) {
            if let handoffRevision {
                acceptedHandoffRevision = handoffRevision
                LibreWatchSessionStore.saveHandoffRevision(handoffRevision)
            }
            if let pending = pendingPhoneReturn, pending.matches(preparedSession) {
                if ownership == .iphone, let handoffRevision, handoffRevision > pending.startingRevision {
                    finishPhoneReturn(pending, owner: .iphone, reason: .authoritativeSnapshot)
                } else {
                    // A delayed pre-release .watch snapshot is not a release rejection.
                    setLibreWatchOwnership(.releasingToPhone)
                }
            } else {
                setLibreWatchOwnership(ownership)
            }
        }

        // Keep an interrupted old return recoverable until the replacement session and
        // its authoritative owner have both been persisted.
        if sessionChanged { LibreWatchSessionStore.savePhoneReturn(nil) }
        if let applyingSnapshot, let data = try? JSONEncoder().encode(applyingSnapshot) {
            acceptedHandoffSnapshot = applyingSnapshot
            UserDefaults.standard.set(data, forKey: acceptedHandoffSnapshotKey)
        }
        sendLibreWatchCommand(
            .acknowledgeSession,
            sessionID: preparedSession.id,
            completion: nil
        )
        return true
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
            LibreWatchMessageKey.sessionID: item.sessionID.uuidString,
            LibreWatchMessageKey.deliveryItemID: item.id.uuidString
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
        let admitted = connectivityOutbox.enqueue(item)
        let saved = LibreWatchSessionStore.saveOutbox(connectivityOutbox)
        if item.reading != nil {
            let retained = admitted && connectivityOutbox.items.contains(where: { $0.id == item.id })
            WatchDeliveryEvidencePipeline.localWrite(saved && retained, item: item,
                failureReason: retained ? "atomicOutboxWriteFailed" : "notRetainedByOutbox")
            if saved && retained { evidenceConfirmedOutboxIDs.insert(item.id) }
        }
        flushWatchConnectivityOutbox()
    }

    /// Called only after the production atomic file store confirms the current outbox.
    /// Captures restart/retry confirmation once per retained payload, not at every BLE fragment.
    private func recordConfirmedOutboxWrites() {
        let queuedIDs = Set(connectivityOutbox.items.map(\.id))
        evidenceConfirmedOutboxIDs.formIntersection(queuedIDs)
        for item in connectivityOutbox.items where item.reading != nil && !evidenceConfirmedOutboxIDs.contains(item.id) {
            WatchDeliveryEvidencePipeline.localWrite(true, item: item)
            evidenceConfirmedOutboxIDs.insert(item.id)
        }
    }

    /// Called by the collector's existing health/activation opportunity, even after return.
    /// A final transient failure must not need another sensor frame to become eligible.
    func retryPendingLibreDeliveries(at date: Date, executionIsAvailable: Bool) {
        if executionIsAvailable { retryPendingPhoneReturn(at: date) }
        if executionIsAvailable, session.activationState == .activated, outboxSendGate.isIdle,
           date.timeIntervalSince(lastDiagnosticReplayAt ?? .distantPast) >= LibreWatchConnectivityOutbox.retryInterval {
            restorePendingDiagnosticJournalToOutbox(at: date)
        }
        if executionIsAvailable, phoneIsReachable, localAlarms.hasPendingConfiguration,
           date.timeIntervalSince(lastAlarmAcknowledgementAttemptAt ?? .distantPast) >= LibreWatchConnectivityOutbox.retryInterval {
            synchronizeLocalAlarmState()
        }
        retryWatchConnectivityOutbox(at: date, opportunity: .existingExecution(isAvailable: executionIsAvailable))
    }

    /// Reuse only this validated delegate call, including partial/duplicate frames. Do not
    /// grant timer execution, retry a handoff, or synchronize alarm settings from here.
    func retryPendingLibreReadingsAfterBLENotification(at date: Date) {
        retryWatchConnectivityOutbox(at: date,
            opportunity: .validatedBLENotification(ownership: libreWatchOwnership))
    }

    private func retryWatchConnectivityOutbox(at date: Date, opportunity: LibreWatchOutboxDeliveryOpportunity) {
        guard opportunity.allowsDelivery,
              LibreWatchSessionStore.prepareOutboxForDelivery(&connectivityOutbox,
                  sessionID: libreWatchDirectSession?.id, at: date) else { return }
        confirmLatestReadingQueuePersistenceIfPossible()
        recordConfirmedOutboxWrites()
        LibreWatchConnectivityDeliveryPolicy.retryPendingDelivery(
            outbox: connectivityOutbox, at: date, opportunity: opportunity,
            sessionIsActivated: session.activationState == .activated,
            hasInFlightItem: !outboxSendGate.isIdle
        ) {
            flushWatchConnectivityOutbox()
        }
    }

    /// Update the display cache only after the full current queue is on disk.
    private func confirmLatestReadingQueuePersistenceIfPossible() {
        guard latestReadingQueuePersistenceConfirmed != true,
              var cached = LibreWatchSessionStore.loadReading(),
              cached.sessionID == libreWatchDirectSession?.id,
              connectivityOutbox.items.contains(where: { $0.id == cached.sourceReading.id }) else { return }
        cached.queuePersistenceConfirmed = true
        LibreWatchSessionStore.saveReading(cached)
        latestReadingQueuePersistenceConfirmed = true
        libreWatchStorageIssue = nil
    }

    /// Recovers the narrow crash window between journal persistence and outbox persistence.
    /// Existing IDs make this idempotent; normal delivery remains the per-event outbox path.
    private func restorePendingDiagnosticJournalToOutbox(at date: Date = Date()) {
        lastDiagnosticReplayAt = date
        _ = LibreWatchDiagnosticBatch.replayPending(
            journal: diagnosticJournal,
            outbox: &connectivityOutbox,
            at: date
        )
        LibreWatchSessionStore.saveOutbox(connectivityOutbox)
    }

    private func finishOutboxItem(_ id: UUID, outcome: String = "received") {
        if let item = connectivityOutbox.items.first(where: { $0.id == id }),
           item.command == .reportDiagnostic {
            diagnosticJournal.markAcknowledgedByPhone(eventID: id, outcome: outcome)
            LibreWatchSessionStore.saveDiagnosticJournal(diagnosticJournal)
        }
        connectivityOutbox.remove(id: id)
        LibreWatchSessionStore.saveOutbox(connectivityOutbox)
        if let attempt = outboxSendGate.activeAttempt, attempt.payloadID == id {
            outboxSendGate.finish(attempt)
        }
        DispatchQueue.main.async { [weak self] in self?.flushWatchConnectivityOutbox() }
    }

    private func transferOutboxItemIfActivated(_ item: LibreWatchOutboxItem, message: [String: Any],
                                              attempt: LibreWatchConnectivitySendAttemptGate.Attempt) {
        guard attempt.payloadID == item.id, outboxSendGate.matches(attempt) else { return }
        guard session.activationState == .activated else {
            outboxSendGate.finish(attempt)
            requestSessionActivationIfNeeded()
            return
        }
        session.transferUserInfo(message)
        if let reading = item.reading {
            WatchDeliveryEvidenceStore.shared.recordReading(.sendAttempt, reading: reading, outcome: "transferUserInfo")
        }
        WatchDeliveryEvidenceStore.shared.recordTransport(stream: WatchDeliveryEvidencePipeline.stream(for: item),
            action: "attempt", outcome: "transferUserInfo")
        connectivityOutbox.markSubmitted(id: item.id)
        if item.command == .reportDiagnostic {
            diagnosticJournal.markHandedToWatchConnectivity(eventID: item.id)
            LibreWatchSessionStore.saveDiagnosticJournal(diagnosticJournal)
        }
        LibreWatchSessionStore.saveOutbox(connectivityOutbox)
        outboxSendGate.finish(attempt)
        // OS queue acceptance is transport progress only. The app-level receipt removes it.
        DispatchQueue.main.async { [weak self] in self?.flushWatchConnectivityOutbox() }
    }

    private func beginOutboxAttempt(for item: LibreWatchOutboxItem) -> LibreWatchConnectivitySendAttemptGate.Attempt? {
        guard let attempt = outboxSendGate.begin(payloadID: item.id) else { return nil }
        connectivityOutbox.markSelected(id: item.id)
        guard LibreWatchSessionStore.saveOutbox(connectivityOutbox),
              connectivityOutbox.items.contains(where: { $0.id == item.id }) else {
            outboxSendGate.finish(attempt)
            return nil
        }
        recordConfirmedOutboxWrites()
        return attempt
    }

    private func flushWatchConnectivityOutbox() {
        guard outboxSendGate.isIdle else { return }
        // A journal entry is persisted before its outbox item. Reconcile that crash/eviction
        // window on every activation/reachability opportunity, not only at process launch.
        connectivityOutbox.prune()
        restorePendingDiagnosticJournalToOutbox()
        // A failed write leaves the in-memory queue intact for the next existing execution
        // opportunity; do not send/reload an older snapshot or create a retry timer.
        guard LibreWatchSessionStore.prepareOutboxForDelivery(&connectivityOutbox,
            sessionID: libreWatchDirectSession?.id) else { return }
        confirmLatestReadingQueuePersistenceIfPossible()
        recordConfirmedOutboxWrites()
        guard let item = connectivityOutbox.nextEligible() else { return }
        if session.activationState == .activated,
           session.outstandingUserInfoTransfers.contains(where: {
               $0.userInfo[LibreWatchMessageKey.deliveryItemID] as? String == item.id.uuidString
           }) {
            connectivityOutbox.markSubmitted(id: item.id)
            LibreWatchSessionStore.saveOutbox(connectivityOutbox)
            DispatchQueue.main.async { [weak self] in self?.flushWatchConnectivityOutbox() }
            return
        }
        guard let message = message(for: item) else {
            finishOutboxItem(item.id)
            return
        }

        if session.activationState == .activated,
           let reading = item.reading,
           Date().timeIntervalSince(reading.receivedAt) > LibreWatchReadingAcceptancePolicy.maximumTransportAge {
            guard let attempt = beginOutboxAttempt(for: item) else { return }
            transferOutboxItemIfActivated(item, message: message, attempt: attempt)
            return
        }

        switch LibreWatchConnectivityDeliveryPolicy.action(
            sessionIsActivated: session.activationState == .activated,
            phoneIsReachable: session.isReachable
        ) {
        case .activateAndQueue:
            requestSessionActivationIfNeeded()
        case .transferUserInfo:
            guard let attempt = beginOutboxAttempt(for: item) else { return }
            transferOutboxItemIfActivated(item, message: message, attempt: attempt)
        case .sendMessage:
            guard let attempt = beginOutboxAttempt(for: item) else { return }
            if let reading = item.reading {
                WatchDeliveryEvidenceStore.shared.recordReading(.sendAttempt, reading: reading, outcome: "sendMessage")
            }
            WatchDeliveryEvidenceStore.shared.recordTransport(stream: WatchDeliveryEvidencePipeline.stream(for: item),
                action: "attempt", outcome: "sendMessage")
            if item.command == .reportDiagnostic {
                diagnosticJournal.markHandedToWatchConnectivity(eventID: item.id)
                LibreWatchSessionStore.saveDiagnosticJournal(diagnosticJournal)
            }
            session.sendMessage(message, replyHandler: { [weak self] reply in
                DispatchQueue.main.async {
                    let success = reply[LibreWatchMessageKey.success] as? Bool ?? false
                    let outcome = (reply[LibreWatchMessageKey.deliveryOutcome] as? String)
                        .flatMap { LibreWatchDeliveryOutcome(rawValue: $0) }
                    let durableReceipt = reply[LibreWatchMessageKey.durableReceipt] as? Bool == true
                    if let reading = item.reading {
                        WatchDeliveryEvidencePipeline.acknowledgement(reading: reading, success: success,
                            durable: durableReceipt, outcome: outcome?.rawValue)
                    }
                    guard let self, self.outboxSendGate.matches(attempt) else { return }
                    if success, LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: success, outcome: outcome, durableReceipt: durableReceipt) {
                        self.finishOutboxItem(item.id)
                    } else if !success, item.kind == .reading,
                              LibreWatchConnectivityDeliveryPolicy.shouldRetryReadingAsQueued(
                                after: outcome
                              ) {
                        // The interactive delivery either crossed the live-age boundary or
                        // raced an explicit phone return. The queued path independently checks
                        // the persisted cutoff receipt before accepting historical data.
                        self.transferOutboxItemIfActivated(item, message: message, attempt: attempt)
                    } else {
                        if !success, LibreWatchConnectivityDeliveryPolicy.isTerminal(outcome) {
                            self.log.error("Libre delivery permanently rejected: \(outcome?.rawValue ?? "unknown", privacy: .public)")
                            self.finishOutboxItem(item.id, outcome: "rejected:\(outcome?.rawValue ?? "unknown")")
                        } else {
                            self.connectivityOutbox.markSubmitted(id: item.id)
                            LibreWatchSessionStore.saveOutbox(self.connectivityOutbox)
                            self.outboxSendGate.finish(attempt)
                            self.flushWatchConnectivityOutbox()
                        }
                    }
                }
            }, errorHandler: { [weak self] error in
                DispatchQueue.main.async {
                    let errorClass = WatchDeliveryEvidenceStore.errorClass(error)
                    WatchDeliveryEvidenceStore.shared.recordTransport(stream: WatchDeliveryEvidencePipeline.stream(for: item),
                        action: "failed", outcome: errorClass)
                    if let reading = item.reading {
                        WatchDeliveryEvidenceStore.shared.recordReading(.transportFailed, reading: reading, outcome: errorClass)
                    }
                    guard let self, self.outboxSendGate.matches(attempt) else { return }
                    switch LibreWatchConnectivityDeliveryPolicy.actionAfterSendError(
                        sessionIsActivated: self.session.activationState == .activated
                    ) {
                    case .transferUserInfo:
                        self.transferOutboxItemIfActivated(item, message: message, attempt: attempt)
                    case .activateAndQueue:
                        self.outboxSendGate.finish(attempt)
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
        returnDiagnostic: ((LibreWatchReturnDiagnostic.Stage, LibreWatchReturnDiagnostic.Reason?, NSError?) -> Void)? = nil,
        returnReplyIsCurrent: (() -> Bool)? = nil,
        returnWillSend: (() -> Void)? = nil,
        returnResponse: ((LibreWatchPhoneReturnTransaction.Response, String?) -> Void)? = nil,
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
        if [.requestOwnership, .releaseOwnership, .acknowledgeSession].contains(command),
           let settings = localAlarms.offeredSettings, settings.sessionID == sessionID {
            message[LibreWatchMessageKey.alarmSettingsRevision] = String(settings.revision)
            message[LibreWatchMessageKey.alarmsReady] = localAlarms.readinessRevision == settings.revision
            message[LibreWatchMessageKey.alarmState] = try? JSONEncoder().encode(localAlarms.state)
        }

        guard session.activationState == .activated else {
            returnDiagnostic?(.transportFailed, .notActivated, nil)
            requestSessionActivationIfNeeded()
            returnResponse?(.notSent, "WatchConnectivity is not activated")
            completion?(false, "WatchConnectivity is not activated")
            return
        }

        guard session.isReachable else {
            returnDiagnostic?(.transportFailed, .phoneUnreachable, nil)
            returnResponse?(.notSent, LibreWatchDirectFailure.phoneUnavailable.rawValue)
            completion?(false, LibreWatchDirectFailure.phoneUnavailable.rawValue)
            return
        }

        returnDiagnostic?(.releaseSent, nil, nil)
        returnWillSend?()
        let evidenceStream: WatchDeliveryEvidenceStream = command == .reportDiagnostic ? .diagnostic : .session
        WatchDeliveryEvidenceStore.shared.recordTransport(stream: evidenceStream,
            action: "commandAttempt", outcome: command.rawValue)
        session.sendMessage(message, replyHandler: { reply in
            DispatchQueue.main.async {
                WatchDeliveryEvidenceStore.shared.recordTransport(stream: evidenceStream,
                    action: "commandReply", outcome: reply[LibreWatchMessageKey.success] as? Bool == true ? "accepted" : "rejected")
                guard returnReplyIsCurrent?() != false else { return }
                let success = reply[LibreWatchMessageKey.success] as? Bool ?? false
                let error = reply[LibreWatchMessageKey.error] as? String
                self.processLibreWatchAlarmResponse(reply)
                if reply[LibreWatchMessageKey.handoffSnapshot] is Data {
                    guard self.processLibreWatchPayload(reply) else {
                        returnDiagnostic?(.snapshotRejected, .staleSnapshot, nil)
                        returnResponse?(.unknown, "Stale or invalid Libre handoff snapshot")
                        completion?(false, "Stale or invalid Libre handoff snapshot")
                        return
                    }
                } else if success, command == .requestOwnership {
                    completion?(false, "iPhone did not confirm a current Libre handoff snapshot")
                    return
                }
                // A raw owner in an acknowledgement is not an ownership transaction.
                // Only the validated snapshot or this current return response may change it.
                returnDiagnostic?(success ? .replyAccepted : .replyRejected,
                                  success ? nil : .phoneRejected, nil)
                let repliedOwner = (reply[LibreWatchMessageKey.ownership] as? String).flatMap(LibreWatchOwnership.init(rawValue:))
                let repliedOutcome = (reply[LibreWatchMessageKey.deliveryOutcome] as? String).flatMap(LibreWatchDeliveryOutcome.init(rawValue:))
                returnResponse?(LibreWatchPhoneReturnTransaction.response(success: success,
                    owner: repliedOwner, outcome: repliedOutcome), error)
                completion?(success, error)
            }
        }, errorHandler: { error in
            DispatchQueue.main.async {
                WatchDeliveryEvidenceStore.shared.recordTransport(stream: evidenceStream,
                    action: "commandFailed", outcome: WatchDeliveryEvidenceStore.errorClass(error))
                guard returnReplyIsCurrent?() != false else { return }
                returnDiagnostic?(.transportFailed, .transportError, error as NSError)
                returnResponse?(.unknown, error.localizedDescription)
                completion?(false, error.localizedDescription)
            }
        })
    }

    // MARK: - Private functions used to interact with the WCSession and prepare internal data

    func requestLocalAlarmPermission() { localAlarms.requestPermission() }

    func refreshLocalAlarmPermission() { localAlarms.refreshPermission() }

    private func synchronizeLocalAlarmState() {
        guard let sessionID = libreWatchDirectSession?.id else { return }
        lastAlarmAcknowledgementAttemptAt = Date()
        // The latest snooze state is persisted independently of transport, attached again on
        // reconnection and included in release before the phone resumes its own alarm role.
        sendLibreWatchCommand(.acknowledgeSession, sessionID: sessionID, completion: nil)
    }

    private func processLibreWatchAlarmResponse(_ payload: [String: Any]) {
        guard let data = payload[LibreWatchMessageKey.alarmSettings] as? Data,
              let settings = try? JSONDecoder().decode(LibreWatchAlarmSettings.self, from: data),
              let session = libreWatchDirectSession, settings.matches(session)
        else { return }
        localAlarms.apply(settings: settings, session: session)
        if let data = payload[LibreWatchMessageKey.alarmDelegation] as? Data,
           let delegation = try? JSONDecoder().decode(LibreWatchAlarmDelegation.self, from: data) {
            // alarmsReady describes the offered revision, not revocation of an older
            // explicit delegation that the phone still holds while waiting for our reply.
            localAlarms.apply(delegation: delegation, session: session)
        } else if payload[LibreWatchMessageKey.alarmsReady] as? Bool == false,
                  payload[LibreWatchMessageKey.alarmDelegation] == nil,
                  settings.revision >= (localAlarms.offeredSettings?.revision ?? 0) {
            localAlarms.apply(delegation: nil, session: session)
        }
    }

    @discardableResult
    private func processLibreWatchDeliveryReceipt(_ message: [String: Any]) -> Bool {
        guard let value = message[LibreWatchMessageKey.deliveryReceiptID] as? String,
              let id = UUID(uuidString: value)
        else { return false }
        WatchDeliveryEvidenceStore.shared.recordTransport(stream: .receipt, action: "receivedEnvelope",
            outcome: message[LibreWatchMessageKey.deliveryOutcome] as? String)
        guard let item = connectivityOutbox.items.first(where: { $0.id == id }),
              message[LibreWatchMessageKey.sessionID] as? String == item.sessionID.uuidString
        else {
            WatchDeliveryEvidenceStore.shared.record(stage: .acknowledgement, payloadID: id,
                sessionID: (message[LibreWatchMessageKey.sessionID] as? String).flatMap(UUID.init(uuidString:)),
                outcome: "unmatchedOrDuplicateReceipt:\(message[LibreWatchMessageKey.deliveryOutcome] as? String ?? "unknown")", stream: .receipt)
            return true
        }
        let success = message[LibreWatchMessageKey.success] as? Bool ?? false
        let outcome = (message[LibreWatchMessageKey.deliveryOutcome] as? String)
            .flatMap(LibreWatchDeliveryOutcome.init(rawValue:))
        let durableReceipt = message[LibreWatchMessageKey.durableReceipt] as? Bool == true
        if let reading = item.reading {
            WatchDeliveryEvidencePipeline.acknowledgement(reading: reading, success: success,
                durable: durableReceipt, outcome: outcome?.rawValue)
        }
        if LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: success, outcome: outcome, durableReceipt: durableReceipt) {
            if !success {
                log.error("Queued Libre delivery permanently rejected: \(outcome?.rawValue ?? "unknown", privacy: .public)")
            }
            finishOutboxItem(id, outcome: success ? "received" : "rejected:\(outcome?.rawValue ?? "unknown")")
        } else {
            connectivityOutbox.markSubmitted(id: id)
            LibreWatchSessionStore.saveOutbox(connectivityOutbox)
        }
        return true
    }

    @discardableResult
    private func processWatchPayloadFromDictionary(dictionary: [String: Any]) -> Set<WatchRefreshCoordinator.Stream> {
        var processedUpdate = false
        var received: Set<WatchRefreshCoordinator.Stream> = []

        if let statusDictionary = dictionary["status"] as? [String: Any] {
            processedUpdate = processStatusFromDictionary(dictionary: statusDictionary)
            if processedUpdate || WatchPhoneSnapshotStore.isCurrent(statusDictionary, stream: .status,
                sessionID: libreWatchDirectSession?.id, allowUnscopedPhoneSession: libreWatchOwnership == .iphone) {
                received.insert(.status)
            }
        }

        if let bgReadingsDictionary = dictionary["bgReadings"] as? [String: Any] {
            let applied = processBgReadingsFromDictionary(dictionary: bgReadingsDictionary)
            if applied || (libreWatchOwnership == .watch && isShowingDirectLibreReading &&
                WatchPhoneSnapshotStore.accept(bgReadingsDictionary, stream: .bgReadings, sessionID: libreWatchDirectSession?.id)) ||
                WatchPhoneSnapshotStore.isCurrent(bgReadingsDictionary, stream: .bgReadings, sessionID: libreWatchDirectSession?.id,
                    allowUnscopedPhoneSession: libreWatchOwnership == .iphone) {
                received.insert(.bgReadings)
                lastPhoneGraphReceivedAt = Date()
            }
            processedUpdate = applied || processedUpdate
        }

        if let agpDictionary = dictionary["agp"] as? [String: Any] {
            if processAGPFromDictionary(dictionary: agpDictionary) { received.insert(.agp) }
        }

        if processedUpdate {
            // now process the shared user defaults to get data for the WidgetKit complications
            updateComplicationData()
        }
        return received
    }

    private func processBgReadingsFromDictionary(dictionary: [String: Any], restoring: Bool = false) -> Bool {
        // While Watch owns Libre, its locally calibrated direct history remains authoritative.
        // iPhone still receives the original direct value for its own normal processing.
        guard libreWatchOwnership != .watch || !isShowingDirectLibreReading else { return false }

        guard WatchPhoneSnapshotStore.isValid(dictionary, stream: .bgReadings, sessionID: libreWatchDirectSession?.id,
                  allowUnscopedPhoneSession: libreWatchOwnership == .iphone),
              let dates = dictionary["bgReadingDatesAsDouble"] as? [Double],
              let values = dictionary["bgReadingValues"] as? [Double],
              let latest = dates.first,
              latest >= (bgReadingDate()?.timeIntervalSince1970 ?? 0),
              let slope = dictionary["slopeOrdinal"] as? Int,
              let delta = dictionary["deltaValueInUserUnit"] as? Double,
              restoring || WatchPhoneSnapshotStore.accept(dictionary, stream: .bgReadings,
                  sessionID: libreWatchDirectSession?.id, displayedReadingDate: bgReadingDate(),
                  allowUnscopedPhoneSession: libreWatchOwnership == .iphone)
        else { return false }

        bgReadingDatesAsDouble = dates
        bgReadingDates = dates.map(Date.init(timeIntervalSince1970:))
        bgReadingValues = values
        slopeOrdinal = slope
        deltaValueInUserUnit = delta
        // This is measurement freshness. A regenerated status envelope cannot update it.
        updatedDate = Date(timeIntervalSince1970: latest)
        if !restoring { lastPhoneGraphReceivedAt = Date() }
        // Only a validated replacement changes measurement provenance, never an ownership reply.
        isShowingDirectLibreReading = false
        directLibreReadingIsStale = false
        let readingDate = Date(timeIntervalSince1970: latest)
        lastUpdatedTextString = Texts_WatchApp.lastReading + " "
        lastUpdatedTimeString = readingDate.formatted(date: .omitted, time: .shortened)
        lastUpdatedTimeAgoString = readingDate.daysAndHoursAgo(appendAgo: true)
        return true
    }

    private func processStatusFromDictionary(dictionary: [String: Any], restoring: Bool = false) -> Bool {
        // transferUserInfo queues every payload while the Watch app is inactive. Ignore old status
        // updates so reopening the app does not replay days of state changes one by one.
        guard WatchPhoneSnapshotStore.isValid(dictionary, stream: .status, sessionID: libreWatchDirectSession?.id,
                  allowUnscopedPhoneSession: libreWatchOwnership == .iphone),
              restoring || WatchPhoneSnapshotStore.accept(dictionary, stream: .status,
                  sessionID: libreWatchDirectSession?.id,
                  allowUnscopedPhoneSession: libreWatchOwnership == .iphone) else {
            return false
        }

        isMgDl = dictionary["isMgDl"] as? Bool ?? true
        urgentLowLimitInMgDl = dictionary["urgentLowLimitInMgDl"] as? Double ?? 60
        lowLimitInMgDl = dictionary["lowLimitInMgDl"] as? Double ?? 70
        highLimitInMgDl = dictionary["highLimitInMgDl"] as? Double ?? 180
        urgentHighLimitInMgDl = dictionary["urgentHighLimitInMgDl"] as? Double ?? 250
        if !restoring { lastPhoneStatusReceivedAt = Date() }
        activeSensorDescription = dictionary["activeSensorDescription"] as? String ?? ""
        if !isShowingDirectLibreReading || libreWatchOwnership != .watch {
            sensorAgeInMinutes = dictionary["sensorAgeInMinutes"] as? Double ?? 0
        }
        if let started = dictionary["sensorStartedAt"] as? Double, started.isFinite, started > 0 {
            phoneSensorStartedAt = Date(timeIntervalSince1970: started)
        } else { phoneSensorStartedAt = nil }
        sensorAgeReferenceDate = (dictionary["generatedAt"] as? Double).map(Date.init(timeIntervalSince1970:))
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
        if let alarmDictionary = dictionary["libreAlarmSettings"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: alarmDictionary),
           let settings = try? JSONDecoder().decode(LibreWatchAlarmSettings.self, from: data),
           let session = libreWatchDirectSession {
            localAlarms.apply(settings: settings, session: session)
        }

        therapyMetrics = (dictionary["therapyMetrics"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }.flatMap { try? JSONDecoder().decode(TherapyMetricsSnapshot.self, from: $0) }
        if let aidStatusDictionary = dictionary["aidStatus"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: aidStatusDictionary),
           let decodedStatus = try? JSONDecoder().decode(AIDStatus.self, from: data) {
            aidStatus = decodedStatus
        } else {
            aidStatus = nil
        }

        return true
    }

    @discardableResult
    private func processAGPFromDictionary(dictionary: [String: Any]) -> Bool {
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
        guard requestID == phoneRefresh.latestAGPRequestID else {
            return false
        }

        mappedAGPRange = nil

        guard pointCount > 0 else {
            agpProfilePoints = []
            agpBackgroundPoints = []
            return true
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
        return true
    }

    /// once we've process the state update, then save this data to the shared app group so that the complication can read it
    private func updateComplicationData() {
        guard let sharedUserDefaults = UserDefaults(suiteName: Bundle.main.appGroupSuiteName) else { return }

        // Do not leave stale glucose behind the warning when disabled. Complications may remain
        // visible long after watchOS stops receiving updates from the phone.
        let complicationBgReadingValues = keepAliveIsDisabled ? [] : bgReadingValues
        let complicationBgReadingDates = keepAliveIsDisabled ? [] : bgReadingDates
        let hidesDirectDerivedValues = isShowingDirectLibreReading &&
            !directLibreReadingIsCurrent()
        let complicationSlopeOrdinal = keepAliveIsDisabled || hidesDirectDerivedValues ? 0 : slopeOrdinal
        let complicationDeltaValueInUserUnit: Double? = keepAliveIsDisabled || hidesDirectDerivedValues
            ? nil
            : deltaValueInUserUnit

        let bgReadingDatesAsDouble = complicationBgReadingDates.map { date in
            date.timeIntervalSince1970
        }

        let complicationSharedUserDefaultsModel = ComplicationSharedUserDefaultsModel(bgReadingValues: complicationBgReadingValues, bgReadingDatesAsDouble: bgReadingDatesAsDouble, isMgDl: isMgDl, slopeOrdinal: complicationSlopeOrdinal, deltaValueInUserUnit: complicationDeltaValueInUserUnit, urgentLowLimitInMgDl: urgentLowLimitInMgDl, lowLimitInMgDl: lowLimitInMgDl, highLimitInMgDl: highLimitInMgDl, urgentHighLimitInMgDl: urgentHighLimitInMgDl, keepAliveIsDisabled: keepAliveIsDisabled, readingSource: isShowingDirectLibreReading ? .directLibre : .phone)

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
            // Activation can already be visible before this queued main hop runs. Never
            // invalidate a newer send started in that interval; callbacks have attempt tokens.
            guard activationState == .activated, self.session.activationState == .activated else {
                if self.session.activationState != .activated {
                    self.outboxSendGate.invalidate()
                    self.phoneReturnSendToken = nil
                }
                if let error {
                    self.log.error("WatchConnectivity activation failed; queued Libre data retained: \(error.localizedDescription, privacy: .public)")
                }
                return
            }

            self.phoneRefresh.reachabilityDidChange()
            self.retryPendingPhoneReturn()
            self.synchronizeLocalAlarmState()
            self.flushWatchConnectivityOutbox()
        }
    }

    func sessionReachabilityDidChange(_: WCSession) {
        DispatchQueue.main.async {
            self.retryPendingPhoneReturn()
            self.synchronizeLocalAlarmState()
            self.phoneRefresh.reachabilityDidChange()
            self.flushWatchConnectivityOutbox()
        }
    }

    func session(_: WCSession, didReceiveMessageData _: Data) {}

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        DispatchQueue.main.async {
            if WatchDeliveryEvidenceTransfer.shared.handleRequest(message, session: session, reply: nil) { return }
            if self.processLibreWatchDeliveryReceipt(message) { return }
            self.phoneRefresh.receivePush(message)
            self.requestingDataIconColor = ConstantsAppleWatch.requestingDataIconColorActive

            // change the requesting icon color back after a small delay to prevent it
            // flashing on/off too quickly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.requestingDataIconColor = ConstantsAppleWatch.requestingDataIconColorInactive
            }
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async {
            if WatchDeliveryEvidenceTransfer.shared.handleRequest(message, session: session, reply: replyHandler) { return }
            // Reply after the synchronous main-queue validation/persistence, rather than
            // treating the dispatch itself as completion. Measurement receipts are separate.
            replyHandler(WatchSnapshotPushContract.reply(to: message) { self.phoneRefresh.receivePush($0) })
        }
    }

    func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        DispatchQueue.main.async {
            if self.processLibreWatchDeliveryReceipt(userInfo) { return }
            self.phoneRefresh.receivePush(userInfo)
        }
    }

    func session(
        _: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        DispatchQueue.main.async {
            self.phoneRefresh.receivePush(applicationContext)
        }
    }

    func session(_: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        DispatchQueue.main.async {
            let command = userInfoTransfer.userInfo[LibreWatchMessageKey.command] as? String
            let stream: WatchDeliveryEvidenceStream = command == LibreWatchCommand.submitReading.rawValue ? .reading :
                command == LibreWatchCommand.reportDiagnostic.rawValue ? .diagnostic : .session
            WatchDeliveryEvidenceStore.shared.recordTransport(stream: stream,
                action: error == nil ? "OStransferCompleted" : "OStransferFailed",
                outcome: error.map(WatchDeliveryEvidenceStore.errorClass))
            guard let value = userInfoTransfer.userInfo[LibreWatchMessageKey.deliveryItemID] as? String,
                  let id = UUID(uuidString: value),
                  self.connectivityOutbox.items.contains(where: { $0.id == id })
            else { return }
            if let error {
                self.log.error("Libre queued transport failed; payload retained: \(error.localizedDescription, privacy: .public)")
            }
            // didFinish proves WC transfer only, never receiver storage. Retain until receipt
            // and retry on a later activation/reachability/frame opportunity if it is absent.
            self.connectivityOutbox.markSubmitted(id: id)
            LibreWatchSessionStore.saveOutbox(self.connectivityOutbox)
        }
    }

    func session(_: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        WatchDeliveryEvidenceTransfer.shared.finished(fileTransfer, error: error)
    }

    #if os(iOS)
    func sessionDidBecomeInactive(_: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
