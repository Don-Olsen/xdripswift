import Foundation
import Combine

enum LibreWatchMessageKey {
    static let session = "libreWatchDirectSession"
    static let command = "libreWatchDirectCommand"
    static let sessionID = "libreWatchDirectSessionID"
    static let unlockCounter = "libreWatchDirectUnlockCounter"
    static let success = "libreWatchDirectSuccess"
    static let error = "libreWatchDirectError"
    static let ownership = "libreWatchDirectOwnership"
    static let reading = "libreWatchDirectReading"
    static let calibration = "libreWatchCalibrationSnapshot"
    static let diagnosticEvent = "libreWatchDiagnosticEvent"
    static let deliveryOutcome = "libreWatchDeliveryOutcome"
    static let releaseCutoff = "libreWatchReleaseCutoff"
    static let handoffSnapshot = "libreWatchHandoffSnapshot"
    static let persistedHandoffRevision = "libreWatchHandoffRevision.v1"
    static let deliveryItemID = "libreWatchDeliveryItemID"
    static let deliveryReceiptID = "libreWatchDeliveryReceiptID"
    static let durableReceipt = "libreWatchDurableReceipt"
    static let persistedInstallationID = "libreWatchInstallationID.v1"
    static let alarmSettings = "libreWatchAlarmSettings"
    static let alarmSettingsRevision = "libreWatchAlarmSettingsRevision"
    static let alarmsReady = "libreWatchAlarmsReady"
    static let alarmDelegation = "libreWatchAlarmDelegation"
    static let alarmState = "libreWatchAlarmState"

    static let persistedSession = "libreWatchDirectPersistedSession.v2"
    static let persistedOwnership = "libreWatchDirectPersistedOwnership.v2"
    static let persistedCalibration = "libreWatchCalibrationSnapshot.v1"
    static let persistedReading = "libreWatchDirectPersistedReading.v2"
    static let legacyPersistedReading = "libreWatchDirectPersistedReading.v1"
    static let persistedOutbox = "libreWatchConnectivityOutbox.v1"
    static let persistedDiagnosticReceipts = "libreWatchDiagnosticReceipts.v1"
    static let persistedDiagnosticJournal = "libreWatchDiagnosticJournal.v1"
    static let persistedRecoveryAttempt = "libreWatchRecoveryAttempt.v1"
    static let persistedReleaseReceipt = "libreWatchReleaseReceipt.v1"
}

enum LibreWatchCommand: String, Codable {
    case acknowledgeSession
    case requestOwnership
    case releaseOwnership
    case updateUnlockCounter
    case submitReading
    case reportDiagnostic
}

/// Exactly one device may own the Libre Bluetooth connection at a time.
enum LibreWatchOwnership: String, Codable, Equatable {
    case iphone
    case releasingToWatch
    case watch
    case releasingToPhone
    case recovery

    func canTransition(to next: LibreWatchOwnership) -> Bool {
        switch (self, next) {
        case (.iphone, .releasingToWatch),
             (.releasingToWatch, .watch),
             (.releasingToWatch, .iphone),
             (.watch, .releasingToPhone),
             (.releasingToPhone, .iphone),
             (.releasingToPhone, .watch),
             (_, .recovery),
             (.recovery, .iphone),
             (.recovery, .watch):
            return true
        default:
            return self == next
        }
    }
}

/// Resolves persisted ownership before the iPhone creates its Core Bluetooth central.
/// Interrupted transfers stay conservatively with Watch; only an explicit, completed
/// `.iphone` state or a proven sensor change permits the phone connection to start.
struct LibreWatchPhoneStartupDecision: Equatable {
    let session: LibreWatchDirectSession?
    let ownership: LibreWatchOwnership
    let phoneConnectionIsBlocked: Bool

    static func resolve(
        persistedOwnership: LibreWatchOwnership,
        persistedSession: LibreWatchDirectSession?,
        activeSensorUID: Data?,
        activePatchInfo: Data?
    ) -> LibreWatchPhoneStartupDecision {
        guard let persistedSession, persistedSession.isValid else {
            return LibreWatchPhoneStartupDecision(
                session: nil,
                ownership: .iphone,
                phoneConnectionIsBlocked: false
            )
        }

        let sensorIsKnownToDiffer = activeSensorUID.map { $0 != persistedSession.sensorUID } ?? false
            || activePatchInfo.map { $0 != persistedSession.patchInfo } ?? false
        guard !sensorIsKnownToDiffer else {
            return LibreWatchPhoneStartupDecision(
                session: persistedSession,
                ownership: .iphone,
                phoneConnectionIsBlocked: false
            )
        }

        guard persistedOwnership != .iphone else {
            return LibreWatchPhoneStartupDecision(
                session: persistedSession,
                ownership: .iphone,
                phoneConnectionIsBlocked: false
            )
        }

        return LibreWatchPhoneStartupDecision(
            session: persistedSession,
            ownership: .watch,
            phoneConnectionIsBlocked: true
        )
    }
}

enum LibreWatchDiagnosticEventKind: String, Codable, Equatable {
    case disconnected
    case recoveryStarted
    case recoverySucceeded
    case recoveryFailed
    case extendedRuntimeWillExpire
    case extendedRuntimeInvalidated
    case lifecycleChanged
    case bluetoothAction
    case coreBluetoothCallback
    case frameProgress
    case callbackRejected
    case journalRotated
}

enum LibreWatchApplicationState: String, Codable, Equatable {
    case active
    case inactive
    case background

    var applicationIsActive: Bool { self == .active }
}

enum LibreWatchRecoveryReconcileSource: String, Codable, Equatable {
    case initialPreparation
    case sceneActivation
    case sceneDeactivation
    case sceneInactive
    case sceneBackground
    case extendedRuntimeStarted
    case extendedRuntimeWillExpire
    case extendedRuntimeInvalidated
    case centralStateUpdate
    case stateRestoration
    case didConnect
    case didFailToConnect
    case didDisconnect
    case gattCallback
    case healthTimer
    case executionBudgetExpired
    case cancellationWatchdog
    case bleNotification

    var grantsEventDrivenBluetoothAction: Bool {
        switch self {
        case .centralStateUpdate, .stateRestoration, .didConnect, .didFailToConnect,
             .didDisconnect, .gattCallback, .bleNotification:
            return true
        default:
            return false
        }
    }
}

struct LibreWatchRecoveryAttemptContext: Codable, Equatable {
    let attemptID: UUID
    let originalTrigger: String
    let startedAt: Date
    let generation: UUID
    let sessionID: UUID
    let sensorIdentity: String

    init(
        attemptID: UUID = UUID(),
        originalTrigger: String,
        startedAt: Date,
        generation: UUID,
        sessionID: UUID,
        sensorIdentity: String
    ) {
        self.attemptID = attemptID
        self.originalTrigger = originalTrigger
        self.startedAt = startedAt
        self.generation = generation
        self.sessionID = sessionID
        self.sensorIdentity = sensorIdentity
    }
}

struct LibreWatchRecoveryAttemptState: Codable, Equatable {
    private(set) var context: LibreWatchRecoveryAttemptContext?
    private(set) var failureWasReported = false

    @discardableResult
    mutating func begin(_ candidate: LibreWatchRecoveryAttemptContext) -> LibreWatchRecoveryAttemptContext? {
        guard context == nil else { return nil }
        context = candidate
        failureWasReported = false
        return candidate
    }

    mutating func reportFailure() -> LibreWatchRecoveryAttemptContext? {
        guard let context, !failureWasReported else { return nil }
        failureWasReported = true
        return context
    }

    mutating func finishSuccess() -> LibreWatchRecoveryAttemptContext? {
        guard let context else { return nil }
        self.context = nil
        failureWasReported = false
        return context
    }

    mutating func invalidate() {
        context = nil
        failureWasReported = false
    }
}

/// A bounded, privacy-safe Watch diagnostic. Sensor identity is derived on iPhone from
/// the validated session and never crosses as a raw peripheral identifier.
struct LibreWatchDiagnosticEvent: Codable, Equatable {
    var eventID: UUID?
    let kind: LibreWatchDiagnosticEventKind
    let isReconnecting: Bool?
    let errorCode: Int?
    // Optional so already queued events from older Watch builds still decode.
    let watchTimestamp: Date?
    let trigger: String?
    let applicationIsActive: Bool?
    let extendedRuntimeIsRunning: Bool?
    let peripheralState: String?
    let connectionPhase: String?
    let deadlinePhase: String?
    let deadlineAt: Date?
    let generation: UUID?
    let attemptID: UUID?
    let attemptStartedAt: Date?
    let sessionID: UUID?
    let sensorIdentity: String?
    let reconcileSource: LibreWatchRecoveryReconcileSource?
    let remainingExecutionBudget: TimeInterval?
    let runtimeInvalidationReason: Int?
    let runtimeError: String?
    let applicationState: LibreWatchApplicationState?
    let appVersion: String?
    let appBuild: String?
    let watchOSVersion: String?
    var sequenceNumber: UInt64?
    let bluetoothAction: String?
    let actionReason: String?
    let errorDomain: String?
    let technicalFrameAt: Date?
    let measurementAt: Date?
    let receivingBudgetDeadline: Date?
    var journalDroppedCount: UInt64?
    let bluetoothErrorClassification: String?
    let extendedRuntimeState: String?
    let extendedRuntimeStartRequested: Bool?
    let appCommit: String?
    let installationID: UUID?
    let ownership: LibreWatchOwnership?
    let unlockCounter: UInt16?
    var journalUnacknowledgedDropCount: UInt64?
    var alarmSettingsRevision: UInt64?
    var alarmEnabledKinds: [Int]?
    var alarmSnoozeAllUntil: Date?
    var alarmSnoozes: [Int: Date]?
    var alarmNotificationsAuthorized: Bool?
    var alarmDelegatedToWatch: Bool?

    init(
        eventID: UUID? = UUID(),
        kind: LibreWatchDiagnosticEventKind,
        isReconnecting: Bool? = nil,
        errorCode: Int? = nil,
        watchTimestamp: Date? = Date(),
        trigger: String? = nil,
        applicationIsActive: Bool? = nil,
        extendedRuntimeIsRunning: Bool? = nil,
        peripheralState: String? = nil,
        connectionPhase: String? = nil,
        deadlinePhase: String? = nil,
        deadlineAt: Date? = nil,
        generation: UUID? = nil,
        attemptID: UUID? = nil,
        attemptStartedAt: Date? = nil,
        sessionID: UUID? = nil,
        sensorIdentity: String? = nil,
        reconcileSource: LibreWatchRecoveryReconcileSource? = nil,
        remainingExecutionBudget: TimeInterval? = nil,
        runtimeInvalidationReason: Int? = nil,
        runtimeError: String? = nil,
        applicationState: LibreWatchApplicationState? = nil,
        appVersion: String? = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
        appBuild: String? = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
        watchOSVersion: String? = ProcessInfo.processInfo.operatingSystemVersionString,
        sequenceNumber: UInt64? = nil,
        bluetoothAction: String? = nil,
        actionReason: String? = nil,
        errorDomain: String? = nil,
        technicalFrameAt: Date? = nil,
        measurementAt: Date? = nil,
        receivingBudgetDeadline: Date? = nil,
        journalDroppedCount: UInt64? = nil,
        bluetoothErrorClassification: String? = nil,
        extendedRuntimeState: String? = nil,
        extendedRuntimeStartRequested: Bool? = nil,
        appCommit: String? = Bundle.main.infoDictionary?["XDripSourceCommit"] as? String,
        installationID: UUID? = LibreWatchSessionStore.installationID(),
        ownership: LibreWatchOwnership? = nil,
        unlockCounter: UInt16? = nil,
        journalUnacknowledgedDropCount: UInt64? = nil
    ) {
        self.eventID = eventID
        self.kind = kind
        self.isReconnecting = isReconnecting
        self.errorCode = errorCode
        self.watchTimestamp = watchTimestamp
        self.trigger = Self.bounded(trigger)
        self.applicationIsActive = applicationIsActive
        self.extendedRuntimeIsRunning = extendedRuntimeIsRunning
        self.peripheralState = Self.bounded(peripheralState)
        self.connectionPhase = Self.bounded(connectionPhase)
        self.deadlinePhase = Self.bounded(deadlinePhase)
        self.deadlineAt = deadlineAt
        self.generation = generation
        self.attemptID = attemptID
        self.attemptStartedAt = attemptStartedAt
        self.sessionID = sessionID
        self.sensorIdentity = Self.bounded(sensorIdentity)
        self.reconcileSource = reconcileSource
        self.remainingExecutionBudget = remainingExecutionBudget
        self.runtimeInvalidationReason = runtimeInvalidationReason
        self.runtimeError = Self.bounded(runtimeError)
        self.applicationState = applicationState
        self.appVersion = Self.bounded(appVersion)
        self.appBuild = Self.bounded(appBuild)
        self.watchOSVersion = Self.bounded(watchOSVersion)
        self.sequenceNumber = sequenceNumber
        self.bluetoothAction = Self.bounded(bluetoothAction)
        self.actionReason = Self.bounded(actionReason)
        self.errorDomain = Self.bounded(errorDomain)
        self.technicalFrameAt = technicalFrameAt
        self.measurementAt = measurementAt
        self.receivingBudgetDeadline = receivingBudgetDeadline
        self.journalDroppedCount = journalDroppedCount
        self.bluetoothErrorClassification = Self.bounded(bluetoothErrorClassification)
        self.extendedRuntimeState = Self.bounded(extendedRuntimeState)
        self.extendedRuntimeStartRequested = extendedRuntimeStartRequested
        self.appCommit = Self.bounded(appCommit)
        self.installationID = installationID
        self.ownership = ownership
        self.unlockCounter = unlockCounter
        self.journalUnacknowledgedDropCount = journalUnacknowledgedDropCount
    }

    private static func bounded(_ value: String?, maximumLength: Int = 512) -> String? {
        guard let value, value.count > maximumLength else { return value }
        return String(value.prefix(maximumLength)) + "…"
    }
}

enum LibreWatchReadingTransport: String, Codable, Equatable {
    case interactiveMessage
    case queuedUserInfo
}

enum LibreWatchDeliveryOutcome: String, Codable, Equatable {
    case liveAccepted
    case historicalInserted
    case duplicate
    case outOfOrder
    case invalidPayload
    case tooOld
    case wrongSession
    case wrongSensor
    case wrongCalibration
    case wrongOwnership
    case missingReceipt
    case afterCutoff
    case historyNotInserted
    case collectorUnavailable
    case receiptCreated
    case receiptCompleted
    case receiptCancelled
    case receiptExpired
}

enum LibreWatchGlucoseProcessingMode: Equatable {
    case live
    case historicalBackfill

    var routing: LibreWatchGlucoseProcessingRouting {
        switch self {
        case .live:
            return LibreWatchGlucoseProcessingRouting(
                updatesCurrentValue: true,
                resetsMissedReadingState: true,
                triggersAlerts: true,
                exportsToIntegrations: true
            )
        case .historicalBackfill:
            return LibreWatchGlucoseProcessingRouting(
                updatesCurrentValue: false,
                resetsMissedReadingState: false,
                triggersAlerts: false,
                exportsToIntegrations: false
            )
        }
    }

    var permitsCurrentValueAndLiveSideEffects: Bool {
        let routing = routing
        return routing.updatesCurrentValue && routing.resetsMissedReadingState &&
            routing.triggersAlerts && routing.exportsToIntegrations
    }
}

struct LibreWatchGlucoseProcessingRouting: Equatable {
    let updatesCurrentValue: Bool
    let resetsMissedReadingState: Bool
    let triggersAlerts: Bool
    let exportsToIntegrations: Bool
}

enum LibreWatchQueuedReadingRoute: Equatable {
    case attemptLiveAcceptance
    case historicalBackfill
}

struct LibreWatchQueuedReadingRoutingPolicy {
    static func route(
        transportAge: TimeInterval,
        ownership: LibreWatchOwnership
    ) -> LibreWatchQueuedReadingRoute {
        guard ownership == .watch,
              transportAge >= 0,
              transportAge <= LibreWatchReadingAcceptancePolicy.maximumTransportAge
        else { return .historicalBackfill }
        return .attemptLiveAcceptance
    }
}

/// Authorizes delayed delivery only for readings that Watch acquired before an explicit
/// return to iPhone. It never authorizes a Bluetooth connection or an interactive/live value.
struct LibreWatchReleaseReceipt: Codable, Equatable {
    enum State: String, Codable {
        case pending
        case completed
    }

    let sessionID: UUID
    let sensorUID: Data
    let patchInfo: Data
    let calibration: LibreWatchCalibrationSnapshot
    let cutoff: Date
    let expiresAt: Date
    private(set) var state: State = .pending

    init?(
        session: LibreWatchDirectSession,
        calibration: LibreWatchCalibrationSnapshot,
        cutoff: Date,
        now: Date = Date()
    ) {
        guard session.isValid,
              calibration.matches(session: session),
              cutoff.timeIntervalSince1970.isFinite,
              cutoff >= session.createdAt,
              cutoff <= now.addingTimeInterval(5 * 60),
              now.timeIntervalSince(cutoff) < LibreWatchHistoryPolicy.maximumAge
        else { return nil }

        sessionID = session.id
        sensorUID = session.sensorUID
        patchInfo = session.patchInfo
        self.calibration = calibration
        self.cutoff = cutoff
        expiresAt = min(cutoff, now).addingTimeInterval(LibreWatchHistoryPolicy.maximumAge)
    }

    func matches(
        session: LibreWatchDirectSession,
        calibration: LibreWatchCalibrationSnapshot
    ) -> Bool {
        sessionID == session.id &&
            sensorUID == session.sensorUID &&
            patchInfo == session.patchInfo &&
            self.calibration.hasSameCalibration(as: calibration) &&
            self.calibration.revision == calibration.revision
    }

    mutating func complete() {
        state = .completed
    }
}

struct LibreWatchHistoryPolicy {
    static let maximumAge: TimeInterval = 60 * 60

    static func rejection(
        reading: LibreWatchDirectReadingPayload,
        transport: LibreWatchReadingTransport,
        session: LibreWatchDirectSession,
        calibration: LibreWatchCalibrationSnapshot,
        ownership: LibreWatchOwnership,
        receipt: LibreWatchReleaseReceipt? = nil,
        now: Date = Date()
    ) -> LibreWatchDeliveryOutcome? {
        guard transport == .queuedUserInfo else { return .invalidPayload }
        guard reading.sessionID == session.id, session.isValid else { return .wrongSession }
        guard calibration.matches(session: session) else { return .wrongCalibration }
        guard reading.calibrationRevision == calibration.revision else { return .wrongCalibration }
        guard reading.isValid(for: calibration, at: now),
              reading.id != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              reading.sensorTimeInMinutes > 0,
              reading.receivedAt >= session.createdAt
        else { return .invalidPayload }
        let age = now.timeIntervalSince(reading.receivedAt)
        guard age >= 0, age <= maximumAge else { return .tooOld }

        if ownership == .watch {
            return nil
        }

        guard let receipt,
              receipt.expiresAt > now,
              receipt.matches(session: session, calibration: calibration)
        else { return .missingReceipt }
        guard reading.receivedAt <= receipt.cutoff else { return .afterCutoff }

        switch ownership {
        case .releasingToPhone:
            return nil
        case .iphone:
            return receipt.state == .completed ? nil : .missingReceipt
        case .watch:
            return nil
        case .releasingToWatch, .recovery:
            return .wrongOwnership
        }
    }

    static func collides(
        payloadID: String?,
        measuredAt: Date,
        sensorID: String,
        existingID: String,
        existingAt: Date,
        existingSensorID: String?,
        existingIsValid: Bool = true,
        tolerance: TimeInterval = 10
    ) -> Bool {
        guard existingSensorID == sensorID else { return false }
        if payloadID.map({ existingID == $0 }) ?? false { return true }
        return existingIsValid && abs(existingAt.timeIntervalSince(measuredAt)) <= tolerance
    }
}

enum LibreWatchOutboxKind: String, Codable, Equatable {
    case reading
    case command
}

struct LibreWatchOutboxItem: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: LibreWatchOutboxKind
    let createdAt: Date
    let sessionID: UUID
    let reading: LibreWatchDirectReadingPayload?
    let command: LibreWatchCommand?
    let unlockCounter: UInt16?
    let diagnosticEvent: Data?

    var isStructurallyValid: Bool {
        switch kind {
        case .reading:
            return command == .submitReading && reading?.id == id &&
                reading?.sessionID == sessionID && diagnosticEvent == nil
        case .command:
            guard reading == nil, let command else { return false }
            switch command {
            case .updateUnlockCounter:
                return unlockCounter != nil && diagnosticEvent == nil
            case .reportDiagnostic:
                return unlockCounter == nil && diagnosticEvent != nil
            case .acknowledgeSession, .requestOwnership, .releaseOwnership, .submitReading:
                return false
            }
        }
    }

    static func reading(_ reading: LibreWatchDirectReadingPayload) -> LibreWatchOutboxItem {
        LibreWatchOutboxItem(
            id: reading.id, kind: .reading, createdAt: reading.receivedAt,
            sessionID: reading.sessionID, reading: reading,
            command: .submitReading, unlockCounter: nil, diagnosticEvent: nil
        )
    }

    static func command(
        _ command: LibreWatchCommand,
        sessionID: UUID,
        unlockCounter: UInt16? = nil,
        diagnosticEvent: Data? = nil,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) -> LibreWatchOutboxItem {
        LibreWatchOutboxItem(
            id: id, kind: .command, createdAt: createdAt, sessionID: sessionID,
            reading: nil, command: command, unlockCounter: unlockCounter,
            diagnosticEvent: diagnosticEvent
        )
    }
}

struct LibreWatchConnectivityOutbox: Codable, Equatable {
    static let maximumItems = 256
    static let maximumAge: TimeInterval = 60 * 60
    private(set) var items: [LibreWatchOutboxItem] = []
    // Optional for decoding the persisted v1 queue after an upgrade. Submission is not
    // storage acknowledgement; retain payloads until a receiver reports a terminal result.
    private(set) var lastSubmittedAt: [UUID: Date]?
    static let retryInterval: TimeInterval = 60

    mutating func enqueue(_ item: LibreWatchOutboxItem, now: Date = Date()) {
        prune(at: now)
        guard item.isStructurallyValid,
              !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        items.sort {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        if items.count > Self.maximumItems {
            items.removeFirst(items.count - Self.maximumItems)
        }
    }

    mutating func remove(id: UUID) {
        items.removeAll { $0.id == id }
        lastSubmittedAt?.removeValue(forKey: id)
    }

    mutating func retain(sessionID: UUID?) {
        guard let sessionID else {
            items.removeAll()
            return
        }
        items.removeAll { $0.sessionID != sessionID && $0.command != .reportDiagnostic }
    }

    mutating func prune(at date: Date = Date()) {
        items.removeAll {
            !$0.isStructurallyValid || date.timeIntervalSince($0.createdAt) > Self.maximumAge
        }
        let retained = Set(items.map(\.id))
        lastSubmittedAt = lastSubmittedAt?.filter { retained.contains($0.key) }
    }

    var next: LibreWatchOutboxItem? { items.first }

    func nextEligible(at date: Date = Date()) -> LibreWatchOutboxItem? {
        items.first { item in
            guard let last = lastSubmittedAt?[item.id] else { return true }
            return date.timeIntervalSince(last) >= Self.retryInterval
        }
    }

    /// Reuse an existing execution opportunity; never create a background polling loop.
    /// Ownership is deliberately not an input: pre-cutoff readings can finish after return.
    func retryIsDue(at date: Date, executionIsAvailable: Bool, hasInFlightItem: Bool) -> Bool {
        executionIsAvailable && !hasInFlightItem && nextEligible(at: date) != nil
    }

    mutating func markSubmitted(id: UUID, at date: Date = Date()) {
        guard items.contains(where: { $0.id == id }) else { return }
        if lastSubmittedAt == nil { lastSubmittedAt = [:] }
        lastSubmittedAt?[id] = date
    }

    mutating func retry(id: UUID) {
        lastSubmittedAt?.removeValue(forKey: id)
    }
}

enum LibreWatchConnectivityDeliveryAction: Equatable {
    case activateAndQueue
    case sendMessage
    case transferUserInfo
}

struct LibreWatchConnectivityDeliveryPolicy {
    static func action(sessionIsActivated: Bool, phoneIsReachable: Bool) -> LibreWatchConnectivityDeliveryAction {
        guard sessionIsActivated else { return .activateAndQueue }
        return phoneIsReachable ? .sendMessage : .transferUserInfo
    }

    static func actionAfterSendError(
        sessionIsActivated: Bool
    ) -> LibreWatchConnectivityDeliveryAction {
        sessionIsActivated ? .transferUserInfo : .activateAndQueue
    }

    static func shouldRetryReadingAsQueued(
        after outcome: LibreWatchDeliveryOutcome?
    ) -> Bool {
        outcome == .tooOld || outcome == .wrongOwnership || outcome == .outOfOrder
    }

    static func isTerminal(_ outcome: LibreWatchDeliveryOutcome?) -> Bool {
        guard let outcome else { return false }
        switch outcome {
        case .liveAccepted, .historicalInserted, .duplicate, .invalidPayload, .tooOld,
             .wrongSession, .wrongSensor, .wrongCalibration, .missingReceipt, .afterCutoff:
            return true
        case .outOfOrder, .wrongOwnership, .historyNotInserted, .collectorUnavailable,
             .receiptCreated, .receiptCompleted, .receiptCancelled, .receiptExpired:
            return false
        }
    }

    static func shouldFinish(_ item: LibreWatchOutboxItem, success: Bool,
                             outcome: LibreWatchDeliveryOutcome?, durableReceipt: Bool = false) -> Bool {
        if success {
            // Older phones acknowledged transport/void callbacks without confirming storage.
            // Keep readings and diagnostics until a storage-aware receiver explicitly confirms.
            if item.kind == .reading || item.command == .reportDiagnostic {
                guard durableReceipt else { return false }
            }
            return item.kind == .command || outcome == .liveAccepted ||
                outcome == .historicalInserted || outcome == .duplicate
        }
        return isTerminal(outcome)
    }
}

struct LibreWatchDiagnosticReceiptLedger: Codable, Equatable {
    // Retain dedupe evidence longer than the bounded 24-hour Watch journal so a delayed
    // WatchConnectivity retry cannot recreate an already exported diagnostic event.
    static let maximumItems = 512
    static let maximumAge: TimeInterval = 48 * 60 * 60
    private(set) var receipts: [UUID: Date] = [:]

    mutating func accept(_ eventID: UUID?, at date: Date = Date()) -> Bool {
        prune(at: date)
        guard let eventID else { return true }
        guard receipts[eventID] == nil else { return false }
        receipts[eventID] = date
        if receipts.count > Self.maximumItems {
            let oldest = receipts.sorted { $0.value < $1.value }.prefix(receipts.count - Self.maximumItems)
            oldest.forEach { receipts.removeValue(forKey: $0.key) }
        }
        return true
    }

    mutating func prune(at date: Date = Date()) {
        receipts = receipts.filter { date.timeIntervalSince($0.value) <= Self.maximumAge }
    }
}

/// A small local Watch record independent of current WatchConnectivity reachability.
/// Entries remain after delivery so a physical test can be reconstructed from original
/// Watch timestamps; only redacted session context is stored.
struct LibreWatchDiagnosticJournal: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var event: LibreWatchDiagnosticEvent
        /// Local insertion time is independent of an absent or skewed event timestamp.
        let recordedAt: Date?
        var handedToWatchConnectivityAt: Date?
        var acknowledgedByPhoneAt: Date?
        var terminalDeliveryOutcome: String?
    }

    struct AppendResult: Equatable {
        let event: LibreWatchDiagnosticEvent
        let rotated: Bool
        let inserted: Bool
    }

    static let maximumEntries = 128
    static let maximumAge: TimeInterval = 24 * 60 * 60
    static let maximumEncodedBytes = 64 * 1024

    private(set) var entries: [Entry] = []
    private(set) var nextSequenceNumber: UInt64 = 1
    private(set) var droppedCount: UInt64 = 0
    private(set) var unacknowledgedDropCount: UInt64?

    mutating func append(
        _ sourceEvent: LibreWatchDiagnosticEvent,
        at date: Date = Date()
    ) -> AppendResult {
        let droppedBeforeAppend = droppedCount
        prune(at: date)

        if let eventID = sourceEvent.eventID,
           let existing = entries.first(where: { $0.event.eventID == eventID }) {
            return AppendResult(event: existing.event, rotated: false, inserted: false)
        }

        var event = sourceEvent
        if event.eventID == nil { event.eventID = UUID() }
        event.sequenceNumber = nextSequenceNumber
        nextSequenceNumber &+= 1

        if entries.count >= Self.maximumEntries {
            let removalCount = entries.count - Self.maximumEntries + 1
            recordDropped(entries.prefix(removalCount))
            entries.removeFirst(removalCount)
            droppedCount &+= UInt64(removalCount)
        }
        event.journalDroppedCount = droppedCount
        event.journalUnacknowledgedDropCount = unacknowledgedDropCount ?? 0
        entries.append(Entry(
            event: event,
            recordedAt: date,
            handedToWatchConnectivityAt: nil
        ))
        trimToEncodedSize()
        let inserted = entries.last?.event.eventID == event.eventID
        if inserted, var appended = entries.last {
            appended.event.journalDroppedCount = droppedCount
            appended.event.journalUnacknowledgedDropCount = unacknowledgedDropCount ?? 0
            entries[entries.count - 1] = appended
            event = appended.event
        }
        return AppendResult(
            event: event,
            rotated: droppedCount != droppedBeforeAppend,
            inserted: inserted
        )
    }

    mutating func markHandedToWatchConnectivity(eventID: UUID?, at date: Date = Date()) {
        guard let eventID,
              let index = entries.firstIndex(where: { $0.event.eventID == eventID })
        else { return }
        entries[index].handedToWatchConnectivityAt = date
        trimToEncodedSize()
    }

    mutating func markAcknowledgedByPhone(eventID: UUID?, outcome: String = "received", at date: Date = Date()) {
        guard let eventID,
              let index = entries.firstIndex(where: { $0.event.eventID == eventID })
        else { return }
        entries[index].acknowledgedByPhoneAt = date
        entries[index].terminalDeliveryOutcome = String(outcome.prefix(64))
        trimToEncodedSize()
    }

    func pendingEvents(for sessionID: UUID? = nil) -> [LibreWatchDiagnosticEvent] {
        entries
            .filter {
                $0.acknowledgedByPhoneAt == nil &&
                    (sessionID == nil || $0.event.sessionID == sessionID)
            }
            .map(\.event)
    }

    mutating func prune(at date: Date = Date()) {
        let retained = entries.filter {
            let timestamp = $0.recordedAt ?? $0.event.watchTimestamp ?? date
            return date.timeIntervalSince(timestamp) <= Self.maximumAge
        }
        let removed = entries.count - retained.count
        let retainedIDs = Set(retained.compactMap { $0.event.eventID })
        recordDropped(entries.filter { !($0.event.eventID.map(retainedIDs.contains) ?? false) })
        entries = retained
        if removed > 0 { droppedCount &+= UInt64(removed) }
        if let highest = entries.compactMap({ $0.event.sequenceNumber }).max() {
            nextSequenceNumber = max(nextSequenceNumber, highest &+ 1)
        }
        trimToEncodedSize()
    }

    private mutating func trimToEncodedSize() {
        while !entries.isEmpty,
              (try? JSONEncoder().encode(self).count).map({ $0 > Self.maximumEncodedBytes }) == true {
            recordDropped(entries.prefix(1))
            entries.removeFirst()
            droppedCount &+= 1
        }
    }

    private mutating func recordDropped<S: Sequence>(_ removed: S) where S.Element == Entry {
        let unconfirmed = removed.filter { $0.acknowledgedByPhoneAt == nil }.count
        unacknowledgedDropCount = (unacknowledgedDropCount ?? 0) &+ UInt64(unconfirmed)
    }
}

enum LibreWatchNotificationErrorAction: Equatable {
    case preserveConnectionNearBackgroundLimit
    case preserveConnectionExceededBackgroundLimit
    case recoverBluetoothLink

    var diagnosticName: String {
        switch self {
        case .preserveConnectionNearBackgroundLimit: return "backgroundBudgetNear"
        case .preserveConnectionExceededBackgroundLimit: return "backgroundBudgetExceeded"
        case .recoverBluetoothLink: return "recoverBluetoothLink"
        }
    }
}

/// The quota callbacks describe watchOS background delivery, not corrupt Libre bytes.
/// CoreBluetooth-to-semantic mapping remains at the delegate boundary.
struct LibreWatchNotificationErrorPolicy {
    static func action(
        isNearBackgroundNotificationLimit: Bool,
        isExceededBackgroundNotificationLimit: Bool
    ) -> LibreWatchNotificationErrorAction {
        if isNearBackgroundNotificationLimit {
            return .preserveConnectionNearBackgroundLimit
        }
        if isExceededBackgroundNotificationLimit {
            return .preserveConnectionExceededBackgroundLimit
        }
        return .recoverBluetoothLink
    }
}

enum LibreWatchDisconnectRecoveryAction: Equatable {
    case finishDeliberateDisconnect
    case waitForSystemReconnect
    case reconnectManually
    case noAdditionalWork
}

enum LibreWatchReconnectFallbackAction: Equatable {
    case wait(TimeInterval)
    case restartConfirmedSensorScan
    case noAdditionalWork
}

/// One disconnect per connection, with a cancellable legacy fallback on every OS version.
struct LibreWatchLegacyDisconnectGate {
    private(set) var pendingToken: UUID?
    private(set) var handled = false

    mutating func scheduleLegacy() -> UUID? {
        guard !handled else { return nil }
        if pendingToken == nil { pendingToken = UUID() }
        return pendingToken
    }

    mutating func accept(legacyToken: UUID? = nil) -> Bool {
        if let legacyToken, legacyToken != pendingToken { return false }
        pendingToken = nil
        guard !handled else { return false }
        handled = true
        return true
    }

    mutating func reset() {
        pendingToken = nil
        handled = false
    }

    func legacyIsCurrent(_ token: UUID, scheduledGeneration: UUID, currentGeneration: UUID,
                         peripheralIsDisconnectedOrDisconnecting: Bool,
                         peripheralIsConnecting: Bool = false) -> Bool {
        !handled && pendingToken == token && scheduledGeneration == currentGeneration &&
            (peripheralIsDisconnectedOrDisconnecting || peripheralIsConnecting)
    }

    mutating func cancelLegacy() {
        pendingToken = nil
    }
}

/// Connection/setup/technical-liveness timing; Bluetooth operations remain in the collector.
struct LibreWatchConnectionTiming {
    enum Phase: String, Equatable {
        case connection, services, characteristics, notifications, unlock, receiving, cancelling
    }

    enum CancellationResult: Equatable {
        case confirmedDisconnected, retireForScan, awaitConfirmedDisconnection
    }

    enum FailedConnectionAction: Equatable {
        case retryConfirmedPeripheral, scanConfirmedSensor, waitForBluetooth
    }

    struct Deadline: Equatable {
        let phase: Phase
        let token: UUID
        let expiresAt: Date
        let monotonicExpiresAt: TimeInterval?
    }

    struct ExecutionBudget: Equatable {
        let phase: Phase
        let token: UUID
        private(set) var armToken: UUID
        private(set) var remaining: TimeInterval
        private(set) var armedAt: Date?
        private(set) var armedAtMonotonic: TimeInterval?
        private(set) var expiresAt: Date?
        private(set) var monotonicExpiresAt: TimeInterval?

        init(
            phase: Phase,
            duration: TimeInterval,
            at date: Date,
            executionIsAvailable: Bool,
            monotonicTime: TimeInterval? = nil
        ) {
            self.phase = phase
            token = UUID()
            armToken = UUID()
            remaining = duration
            armedAt = executionIsAvailable ? date : nil
            let instant = monotonicTime ?? date.timeIntervalSinceReferenceDate
            armedAtMonotonic = executionIsAvailable ? instant : nil
            expiresAt = executionIsAvailable ? date.addingTimeInterval(duration) : nil
            monotonicExpiresAt = executionIsAvailable ? instant + duration : nil
        }

        mutating func setExecutionAvailable(
            _ available: Bool,
            at date: Date,
            monotonicTime: TimeInterval? = nil
        ) {
            let instant = monotonicTime ?? date.timeIntervalSinceReferenceDate
            if available {
                guard armedAt == nil else { return }
                armToken = UUID()
                armedAt = date
                armedAtMonotonic = instant
                expiresAt = date.addingTimeInterval(remaining)
                monotonicExpiresAt = instant + remaining
            } else {
                guard armedAt != nil, let armedAtMonotonic else { return }
                remaining = max(0, remaining - max(0, instant - armedAtMonotonic))
                self.armedAt = nil
                self.armedAtMonotonic = nil
                expiresAt = nil
                monotonicExpiresAt = nil
            }
        }

        func remainingExecutionTime(
            at date: Date,
            monotonicTime: TimeInterval? = nil
        ) -> TimeInterval {
            guard let armedAtMonotonic else { return remaining }
            let instant = monotonicTime ?? date.timeIntervalSinceReferenceDate
            return max(0, remaining - max(0, instant - armedAtMonotonic))
        }

        var activeDeadline: Deadline? {
            guard let expiresAt, let monotonicExpiresAt else { return nil }
            return Deadline(
                phase: phase,
                token: armToken,
                expiresAt: expiresAt,
                monotonicExpiresAt: monotonicExpiresAt
            )
        }
    }

    private(set) var phase: Phase?
    private(set) var executionBudget: ExecutionBudget?
    private(set) var cancellationDeadline: Deadline?
    private(set) var dataExpectedSince: Date?
    private(set) var generation = UUID()
    private(set) var cancellationWatchdogDidFire = false

    var deadline: Deadline? {
        phase == .cancelling ? cancellationDeadline : executionBudget?.activeDeadline
    }

    func remainingExecutionTime(
        at date: Date,
        monotonicTime: TimeInterval? = nil
    ) -> TimeInterval? {
        executionBudget?.remainingExecutionTime(at: date, monotonicTime: monotonicTime)
    }

    // One bounded cancellation observation, using the collector's existing one-shot work item.
    static let cancellationTimeout: TimeInterval = 5

    var setupInProgress: Bool {
        switch phase {
        case .services, .characteristics, .notifications, .unlock: return true
        default: return false
        }
    }

    var canStartBluetoothOperation: Bool { phase == nil }

    mutating func beginConnection(
        at date: Date,
        applicationIsActive: Bool,
        executionIsAvailable: Bool = true,
        monotonicTime: TimeInterval? = nil
    ) {
        // Retries belong to the same logical generation until it is explicitly retired.
        guard phase == nil else { return }
        generation = UUID()
        dataExpectedSince = nil
        cancellationDeadline = nil
        cancellationWatchdogDidFire = false
        phase = .connection
        executionBudget = ExecutionBudget(
            phase: .connection,
            duration: applicationIsActive ? 60 : 90,
            at: date,
            executionIsAvailable: executionIsAvailable,
            monotonicTime: monotonicTime
        )
    }

    mutating func beginSetup(
        at date: Date,
        startingAt setupPhase: Phase = .services,
        executionIsAvailable: Bool = true,
        monotonicTime: TimeInterval? = nil
    ) {
        guard phase != .cancelling else { return }
        switch setupPhase {
        case .services, .characteristics, .notifications, .unlock:
            break
        case .connection, .receiving, .cancelling:
            return
        }
        executionBudget = nil
        cancellationDeadline = nil
        dataExpectedSince = nil
        phase = setupPhase
        refreshSetupBudget(
            at: date,
            executionIsAvailable: executionIsAvailable,
            monotonicTime: monotonicTime
        )
    }

    func acceptsSetup(_ expected: Phase) -> Bool {
        setupInProgress && phase == expected
    }

    @discardableResult
    mutating func setupProgress(
        _ completed: Phase,
        at date: Date,
        executionIsAvailable: Bool = true,
        monotonicTime: TimeInterval? = nil
    ) -> Bool {
        guard acceptsSetup(completed) else { return false }
        switch completed {
        case .services: phase = .characteristics
        case .characteristics: phase = .notifications
        case .notifications: phase = .unlock
        case .unlock:
            receivedPacketOrEnabledNotifications(at: date)
            return true
        default: return false
        }
        refreshSetupBudget(
            at: date,
            executionIsAvailable: executionIsAvailable,
            monotonicTime: monotonicTime
        )
        return true
    }

    mutating func receivedPacketOrEnabledNotifications(at date: Date) {
        guard phase != .cancelling else { return }
        executionBudget = nil
        cancellationDeadline = nil
        phase = .receiving
        dataExpectedSince = date
    }

    /// Starts or refreshes the technical BLE liveness budget without changing the timestamp
    /// of the most recently accepted clinical reading. Suspension never consumes this budget.
    mutating func recordReceivingProgress(
        at date: Date,
        timeout: TimeInterval,
        executionIsAvailable: Bool,
        monotonicTime: TimeInterval? = nil
    ) {
        guard phase == .receiving else { return }
        dataExpectedSince = date
        executionBudget = ExecutionBudget(
            phase: .receiving,
            duration: timeout,
            at: date,
            executionIsAvailable: executionIsAvailable,
            monotonicTime: monotonicTime
        )
    }

    /// Migration/safety path for a healthy notification state created before a liveness budget.
    /// It is deliberately one-shot and therefore cannot be refilled by lifecycle churn.
    mutating func ensureReceivingBudget(
        at date: Date,
        timeout: TimeInterval,
        executionIsAvailable: Bool,
        monotonicTime: TimeInterval? = nil
    ) {
        guard phase == .receiving, executionBudget == nil else { return }
        recordReceivingProgress(
            at: date,
            timeout: timeout,
            executionIsAvailable: executionIsAvailable,
            monotonicTime: monotonicTime
        )
    }

    /// Execution budgets consume only foreground or valid extended-runtime time.
    /// Pausing and resuming preserve phase, token, generation and the exact remainder.
    @discardableResult
    mutating func setExecutionAvailable(
        _ available: Bool,
        at date: Date,
        monotonicTime: TimeInterval? = nil
    ) -> Bool {
        guard phase != .cancelling, var budget = executionBudget else { return false }
        let previous = budget
        budget.setExecutionAvailable(available, at: date, monotonicTime: monotonicTime)
        executionBudget = budget
        return budget != previous
    }

    /// Observing .connecting must not fabricate a *new* attempt on every lifecycle event.
    /// The true receiving-without-deadline case enters here with its timing still absent.
    @discardableResult
    mutating func observeLink(
        connected: Bool, connecting: Bool, hasReceptionState: Bool,
        at date: Date, applicationIsActive: Bool, executionIsAvailable: Bool = true,
        monotonicTime: TimeInterval? = nil
    ) -> Bool {
        guard !connected, phase != .cancelling else { return false }
        let staleReception = hasReceptionState || setupInProgress || phase == .receiving
        let missingConnection = connecting && phase != .connection
        guard staleReception || missingConnection else { return false }
        if phase != .connection {
            invalidate()
            if connecting {
                beginConnection(
                    at: date,
                    applicationIsActive: applicationIsActive,
                    executionIsAvailable: executionIsAvailable,
                    monotonicTime: monotonicTime
                )
            }
        }
        return true
    }

    func timeoutIsCurrent(_ captured: Deadline, ownership: LibreWatchOwnership,
                          cancelling: Bool, at date: Date,
                          monotonicTime: TimeInterval? = nil) -> Bool {
        let instant = monotonicTime ?? date.timeIntervalSinceReferenceDate
        return ownership == .watch && !cancelling && deadline == captured &&
            phase == captured.phase &&
            captured.monotonicExpiresAt.map { instant >= $0 } == true
    }

    func noDataIsOverdue(lastPacketAt: Date?, at date: Date, timeout: TimeInterval) -> Bool {
        guard phase == .receiving, let dataExpectedSince else { return false }
        let lastActivity = max(dataExpectedSince, lastPacketAt ?? dataExpectedSince)
        return date.timeIntervalSince(lastActivity) >= timeout
    }

    func canConnect(at date: Date, peripheralIsDisconnected: Bool,
                    retiredPeripheralIsReleased: Bool,
                    monotonicTime: TimeInterval? = nil) -> Bool {
        phase == .connection && executionBudget.map {
            $0.remainingExecutionTime(at: date, monotonicTime: monotonicTime) > 0
        } == true &&
            peripheralIsDisconnected && retiredPeripheralIsReleased
    }

    func failedConnectionAction(
        at date: Date,
        bluetoothIsPoweredOn: Bool,
        monotonicTime: TimeInterval? = nil
    ) -> FailedConnectionAction {
        guard bluetoothIsPoweredOn else { return .waitForBluetooth }
        guard phase == .connection,
              executionBudget.map({
                  $0.remainingExecutionTime(at: date, monotonicTime: monotonicTime) > 0
              }) == true
        else { return .scanConfirmedSensor }
        return .retryConfirmedPeripheral
    }

    mutating func beginCancellation(at date: Date) {
        guard phase != .cancelling else { return }
        dataExpectedSince = nil
        executionBudget = nil
        phase = .cancelling
        cancellationWatchdogDidFire = false
        cancellationDeadline = Deadline(
            phase: .cancelling,
            token: UUID(),
            expiresAt: date.addingTimeInterval(Self.cancellationTimeout),
            monotonicExpiresAt: nil
        )
    }

    /// Timeout may retire a cancelled attempt for scanning, never grant iPhone ownership.
    mutating func finishCancellation(_ captured: Deadline, ownership: LibreWatchOwnership,
                                     returningToPhone: Bool, peripheralIsDisconnected: Bool,
                                     at date: Date) -> CancellationResult? {
        guard phase == .cancelling, cancellationDeadline == captured else { return nil }
        if peripheralIsDisconnected {
            invalidate()
            return .confirmedDisconnected
        }
        guard date >= captured.expiresAt, !cancellationWatchdogDidFire else { return nil }
        cancellationWatchdogDidFire = true
        guard ownership == .watch, !returningToPhone else { return .awaitConfirmedDisconnection }
        invalidate()
        return .retireForScan
    }

    mutating func invalidate() {
        phase = nil
        executionBudget = nil
        cancellationDeadline = nil
        dataExpectedSince = nil
        generation = UUID()
        cancellationWatchdogDidFire = false
    }

    private mutating func refreshSetupBudget(
        at date: Date,
        executionIsAvailable: Bool,
        monotonicTime: TimeInterval? = nil
    ) {
        guard let phase else { return }
        executionBudget = ExecutionBudget(
            phase: phase,
            duration: 60,
            at: date,
            executionIsAvailable: executionIsAvailable,
            monotonicTime: monotonicTime
        )
    }
}

/// Tracks one restored Core Bluetooth object graph without weakening the normal identity gates.
/// The collector executes these actions against the exact restored peripheral/service/characteristics.
struct LibreWatchRestorationState: Equatable {
    enum Action: Equatable {
        case stop
        case waitForBluetooth
        case waitForConnection
        case waitForCurrentOperation
        case discoverServices
        case discoverCharacteristics
        case enableNotifications
        case awaitExistingStream
        case preserveActiveStream
    }

    let token: UUID
    let sessionID: UUID
    let sensorIdentity: String
    private(set) var generation: UUID
    private(set) var awaitingStreamEvidence = false
    private(set) var unlockWasRequested = false
    private(set) var streamEvidenceWasReceived = false

    init(
        token: UUID = UUID(),
        sessionID: UUID,
        sensorIdentity: String,
        generation: UUID
    ) {
        self.token = token
        self.sessionID = sessionID
        self.sensorIdentity = sensorIdentity
        self.generation = generation
    }

    mutating func bind(to generation: UUID) {
        self.generation = generation
    }

    mutating func beginConnectionGeneration(_ generation: UUID) {
        self.generation = generation
        awaitingStreamEvidence = false
        unlockWasRequested = false
        streamEvidenceWasReceived = false
    }

    func belongsTo(
        sessionID: UUID?,
        sensorIdentity: String?,
        ownership: LibreWatchOwnership
    ) -> Bool {
        ownership == .watch && self.sessionID == sessionID &&
            self.sensorIdentity == sensorIdentity
    }

    mutating func nextAction(
        centralIsPoweredOn: Bool,
        peripheralState: LibreWatchObservedPeripheralState,
        hasService: Bool,
        hasWriteCharacteristic: Bool,
        hasReceiveCharacteristic: Bool,
        receiveIsNotifying: Bool,
        connectionPhase: LibreWatchConnectionTiming.Phase?,
        currentGeneration: UUID,
        sessionID: UUID?,
        sensorIdentity: String?,
        ownership: LibreWatchOwnership,
        cancellationIsActive: Bool
    ) -> Action {
        guard belongsTo(
            sessionID: sessionID,
            sensorIdentity: sensorIdentity,
            ownership: ownership
        ), generation == currentGeneration, !cancellationIsActive else {
            return .stop
        }
        guard centralIsPoweredOn else { return .waitForBluetooth }
        guard peripheralState == .connected else { return .waitForConnection }

        if streamEvidenceWasReceived || connectionPhase == .receiving {
            return .preserveActiveStream
        }
        switch connectionPhase {
        case .some(.services), .some(.characteristics), .some(.notifications), .some(.unlock):
            return .waitForCurrentOperation
        case .some(.cancelling):
            return .stop
        case .some(.connection), .none:
            break
        case .some(.receiving):
            return .preserveActiveStream
        }

        guard hasService else { return .discoverServices }
        guard hasWriteCharacteristic, hasReceiveCharacteristic else {
            return .discoverCharacteristics
        }
        guard receiveIsNotifying else { return .enableNotifications }

        awaitingStreamEvidence = true
        return .awaitExistingStream
    }

    mutating func recordStreamEvidence() {
        streamEvidenceWasReceived = true
        awaitingStreamEvidence = false
    }

    mutating func beginAwaitingStreamEvidence() {
        guard !streamEvidenceWasReceived, !unlockWasRequested else { return }
        awaitingStreamEvidence = true
    }

    mutating func markUnlockRequested() {
        unlockWasRequested = true
        awaitingStreamEvidence = false
    }

    mutating func claimUnknownUnlockRecovery(
        capturedToken: UUID?,
        currentGeneration: UUID,
        phase: LibreWatchConnectionTiming.Phase?,
        sessionID: UUID?,
        sensorIdentity: String?,
        ownership: LibreWatchOwnership,
        cancellationIsActive: Bool
    ) -> Bool {
        guard capturedToken == token,
              belongsTo(
                  sessionID: sessionID,
                  sensorIdentity: sensorIdentity,
                  ownership: ownership
              ),
              generation == currentGeneration,
              phase == .notifications,
              awaitingStreamEvidence,
              !streamEvidenceWasReceived,
              !unlockWasRequested,
              !cancellationIsActive
        else { return false }
        markUnlockRequested()
        return true
    }
}

/// Object identity, rather than a matching characteristic UUID, defines the current GATT graph.
struct LibreWatchRestoredObjectIdentity {
    static func isCurrent(_ candidate: AnyObject, expected: AnyObject?) -> Bool {
        candidate === expected
    }
}

/// Per notification stream: tolerate a corrupt frame, recover once after three in a row.
struct LibreWatchFrameLiveness {
    static let invalidFrameLimit = 3
    private(set) var consecutiveInvalidFrames = 0
    private(set) var recoveryRequested = false
    private(set) var lastValidBLEFrameAt: Date?

    mutating func invalidFrame() -> Bool {
        guard !recoveryRequested else { return false }
        consecutiveInvalidFrames += 1
        guard consecutiveInvalidFrames >= Self.invalidFrameLimit else { return false }
        recoveryRequested = true
        return true
    }

    mutating func validFrame(at date: Date = Date()) {
        consecutiveInvalidFrames = 0
        recoveryRequested = false
        lastValidBLEFrameAt = date
    }
}

/// Pure lifecycle policy shared by the Watch collector and deterministic iPhone tests.
/// Timed recovery requires foreground/runtime execution, while Core Bluetooth delegate events
/// may finish one already-established operation whenever Watch still owns the sensor.
struct LibreWatchLifecyclePolicy {
    static let foregroundNoDataRecoveryDelay: TimeInterval = 2 * 60
    static let extendedRuntimeNoDataRecoveryDelay: TimeInterval = 3 * 60

    /// @Published sends in willSet. Apply only the still-current value after the complete
    /// session/ownership transaction has returned on main, including delayed handoff replies.
    static func observeCommittedOwnership(
        _ publisher: Published<LibreWatchOwnership>.Publisher,
        current: @escaping () -> LibreWatchOwnership?,
        receive: @escaping (LibreWatchOwnership) -> Void
    ) -> AnyCancellable {
        publisher.dropFirst().receive(on: DispatchQueue.main).sink { ownership in
            guard current() == ownership else { return }
            receive(ownership)
        }
    }

    static func recoveryIsAllowed(
        applicationIsActive: Bool,
        extendedRuntimeIsRunning: Bool,
        ownership: LibreWatchOwnership
    ) -> Bool {
        recoveryIsAllowed(
            applicationState: applicationIsActive ? .active : .background,
            extendedRuntimeIsRunning: extendedRuntimeIsRunning,
            ownership: ownership
        )
    }

    static func recoveryIsAllowed(
        applicationState: LibreWatchApplicationState,
        extendedRuntimeIsRunning: Bool,
        ownership: LibreWatchOwnership
    ) -> Bool {
        ownership == .watch &&
            (applicationState == .active || extendedRuntimeIsRunning)
    }

    static func eventDrivenRecoveryIsAllowed(ownership: LibreWatchOwnership) -> Bool {
        ownership == .watch
    }

    static func shouldHandleDisconnect(alreadyHandled: Bool) -> Bool {
        !alreadyHandled
    }

    static func shouldStartExtendedRuntime(
        userInitiatedTakeover: Bool,
        applicationIsActive: Bool,
        ownership: LibreWatchOwnership,
        alreadyHasSession: Bool
    ) -> Bool {
        userInitiatedTakeover &&
            applicationIsActive &&
            ownership == .watch &&
            !alreadyHasSession
    }

    static func shouldStopExtendedRuntime(
        ownership: LibreWatchOwnership,
        sensorChanged: Bool = false,
        watchSessionEnded: Bool = false
    ) -> Bool {
        ownership != .watch || sensorChanged || watchSessionEnded
    }

    static func disconnectRecoveryAction(
        isDeliberate: Bool,
        systemIsReconnecting: Bool,
        ownership: LibreWatchOwnership
    ) -> LibreWatchDisconnectRecoveryAction {
        if isDeliberate {
            return .finishDeliberateDisconnect
        }
        guard eventDrivenRecoveryIsAllowed(ownership: ownership) else {
            return .noAdditionalWork
        }
        return systemIsReconnecting ? .waitForSystemReconnect : .reconnectManually
    }

    static func reconnectFallbackAction(
        deadline: Date,
        now: Date,
        applicationIsActive: Bool,
        extendedRuntimeIsRunning: Bool,
        ownership: LibreWatchOwnership
    ) -> LibreWatchReconnectFallbackAction {
        guard recoveryIsAllowed(
            applicationIsActive: applicationIsActive,
            extendedRuntimeIsRunning: extendedRuntimeIsRunning,
            ownership: ownership
        ) else {
            return .noAdditionalWork
        }

        let remaining = deadline.timeIntervalSince(now)
        return remaining <= 0 ? .restartConfirmedSensorScan : .wait(remaining)
    }

    static func noDataRecoveryDelay(
        applicationIsActive: Bool,
        extendedRuntimeIsRunning: Bool,
        ownership: LibreWatchOwnership
    ) -> TimeInterval? {
        noDataRecoveryDelay(
            applicationState: applicationIsActive ? .active : .background,
            extendedRuntimeIsRunning: extendedRuntimeIsRunning,
            ownership: ownership
        )
    }

    static func noDataRecoveryDelay(
        applicationState: LibreWatchApplicationState,
        extendedRuntimeIsRunning: Bool,
        ownership: LibreWatchOwnership
    ) -> TimeInterval? {
        guard recoveryIsAllowed(
            applicationState: applicationState,
            extendedRuntimeIsRunning: extendedRuntimeIsRunning,
            ownership: ownership
        ) else { return nil }

        return applicationState == .active
            ? foregroundNoDataRecoveryDelay
            : extendedRuntimeNoDataRecoveryDelay
    }

    /// Chooses one finite liveness budget when notification reception begins. If no continuous
    /// timer execution is currently available, the background-sized budget is created paused.
    static func receivingExecutionBudget(
        applicationState: LibreWatchApplicationState,
        extendedRuntimeIsRunning: Bool
    ) -> TimeInterval {
        applicationState == .active
            ? foregroundNoDataRecoveryDelay
            : extendedRuntimeNoDataRecoveryDelay
    }
}

enum LibreWatchExpiredPhaseAction: Equatable {
    case beginGATTSetup
    case reconcileObservedLink
    case beginControlledRecovery
    case noAdditionalWork
}

enum LibreWatchObservedPeripheralState: String, Codable, Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case unknown
}

/// A receiving/setup deadline cancels only a still-connected phase that made no newer progress.
/// Native link transitions are reconciled first; once the current connection phase itself has
/// exhausted its immutable budget, every non-connected state is retired through one controlled
/// recovery instead of rescheduling the same expired deadline.
struct LibreWatchExpiredPhasePolicy {
    static func action(
        phase: LibreWatchConnectionTiming.Phase?,
        peripheralState: LibreWatchObservedPeripheralState,
        ownership: LibreWatchOwnership,
        cancellationIsActive: Bool
    ) -> LibreWatchExpiredPhaseAction {
        guard ownership == .watch, !cancellationIsActive, let phase else {
            return .noAdditionalWork
        }
        if phase == .connection {
            switch peripheralState {
            case .connected: return .beginGATTSetup
            case .disconnected, .connecting, .disconnecting, .unknown:
                // This connection generation has consumed its immutable execution budget.
                // Retire it once before returning to the exact-sensor scan; merely reconciling
                // a disconnected auto-reconnect would reschedule the same expired deadline.
                return .beginControlledRecovery
            }
        }
        return peripheralState == .connected
            ? .beginControlledRecovery
            : .reconcileObservedLink
    }
}

struct LibreWatchAlgorithmParameters: Codable, Equatable {
    let slopeSlope: Double
    let slopeOffset: Double
    let offsetSlope: Double
    let offsetOffset: Double
    let extraSlope: Double
    let extraOffset: Double
    let sensorSerialNumber: String

    var isFinite: Bool {
        [slopeSlope, slopeOffset, offsetSlope, offsetOffset, extraSlope, extraOffset]
            .allSatisfy(\.isFinite)
    }
}

enum LibreWatchSessionValidationError: String, Equatable {
    case unsupportedVersion = "Unsupported Watch-session version"
    case invalidSensorUID = "Sensor UID must contain exactly 8 bytes"
    case invalidPatchInfo = "Patch info must contain at least 6 bytes"
    case unsupportedSensorType = "Direct Watch reception supports Libre 2 Plus C6/7F only"
    case missingSensorSerialNumber = "Sensor serial number is missing"
    case invalidExpectedPeripheralName = "Expected Bluetooth identity is invalid"
    case invalidAlgorithmParameters = "Libre algorithm parameters are invalid"
    case algorithmSerialMismatch = "Algorithm parameters belong to another sensor"
}

/// Everything the Watch needs to reconnect to one NFC-authenticated sensor.
struct LibreWatchDirectSession: Codable, Equatable, Identifiable {
    static let currentVersion = 2
    static let supportedSensorTypes: Set<String> = ["C6", "7F"]

    let version: Int
    let id: UUID
    let createdAt: Date
    let sensorUID: Data
    let patchInfo: Data
    let sensorSerialNumber: String
    let sensorTypeRawValue: String
    let expectedPeripheralName: String
    let unlockCode: UInt32
    var unlockCount: UInt16
    let algorithmParameters: LibreWatchAlgorithmParameters

    init(
        version: Int = Self.currentVersion,
        id: UUID = UUID(),
        createdAt: Date = Date(),
        sensorUID: Data,
        patchInfo: Data,
        sensorSerialNumber: String,
        sensorTypeRawValue: String,
        expectedPeripheralName: String,
        unlockCode: UInt32,
        unlockCount: UInt16,
        algorithmParameters: LibreWatchAlgorithmParameters
    ) {
        self.version = version
        self.id = id
        self.createdAt = createdAt
        self.sensorUID = sensorUID
        self.patchInfo = patchInfo
        self.sensorSerialNumber = sensorSerialNumber
        self.sensorTypeRawValue = sensorTypeRawValue.uppercased()
        self.expectedPeripheralName = expectedPeripheralName.uppercased()
        self.unlockCode = unlockCode
        self.unlockCount = unlockCount
        self.algorithmParameters = algorithmParameters
    }

    var validationError: LibreWatchSessionValidationError? {
        guard version == Self.currentVersion else { return .unsupportedVersion }
        guard sensorUID.count == 8 else { return .invalidSensorUID }
        guard patchInfo.count >= 6 else { return .invalidPatchInfo }
        guard Self.supportedSensorTypes.contains(sensorTypeRawValue) else {
            return .unsupportedSensorType
        }
        guard !sensorSerialNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .missingSensorSerialNumber
        }
        guard expectedIdentityIsValid else { return .invalidExpectedPeripheralName }
        guard algorithmParameters.isFinite else { return .invalidAlgorithmParameters }
        guard algorithmParameters.sensorSerialNumber.caseInsensitiveCompare(sensorSerialNumber) == .orderedSame else {
            return .algorithmSerialMismatch
        }
        return nil
    }

    var isValid: Bool { validationError == nil }

    func matches(candidateName: String?) -> Bool {
        guard isValid,
              let candidateName,
              !candidateName.isEmpty
        else { return false }

        return candidateName.uppercased() == expectedPeripheralName
    }

    func representsSameSensor(as other: LibreWatchDirectSession) -> Bool {
        sensorUID == other.sensorUID &&
            patchInfo == other.patchInfo &&
            sensorSerialNumber.caseInsensitiveCompare(other.sensorSerialNumber) == .orderedSame &&
            expectedPeripheralName.caseInsensitiveCompare(other.expectedPeripheralName) == .orderedSame
    }

    func redactedIdentity(salt: UInt64 = 0x4C_32_50_57) -> String {
        var digest = UInt64(14_695_981_039_346_656_037) ^ salt
        for byte in sensorUID {
            digest ^= UInt64(byte)
            digest &*= 1_099_511_628_211
        }
        return String(format: "Libre-%06X", digest & 0xFF_FFFF)
    }

    private var expectedIdentityIsValid: Bool {
        if sensorTypeRawValue == "C6" {
            return expectedPeripheralName == "ABBOTT" + sensorSerialNumber.uppercased()
        }

        guard sensorTypeRawValue == "7F", expectedPeripheralName.count == 12 else {
            return false
        }

        let hexadecimal = CharacterSet(charactersIn: "0123456789ABCDEF")
        return expectedPeripheralName.unicodeScalars.allSatisfy { hexadecimal.contains($0) }
    }
}

enum LibreWatchValueDomain: String, Codable, Equatable {
    case factoryNativeMGDL
    case xDripRawGlucose
}

/// A versioned Watch reading keeps both Libre value domains. `valueDomain` records which
/// one was selected by the matching iPhone calibration snapshot when the frame arrived.
struct LibreWatchDirectReadingPayload: Codable, Equatable, Identifiable {
    static let currentVersion = 2

    let version: Int
    let id: UUID
    let sessionID: UUID
    let valueDomain: LibreWatchValueDomain
    let nativeGlucoseMGDL: Double
    let previousNativeGlucoseMGDL: Double
    let rawGlucose: UInt16
    let previousRawGlucose: UInt16
    let sensorTimeInMinutes: UInt16
    let receivedAt: Date
    let calibrationRevision: UInt64

    init(
        version: Int = Self.currentVersion,
        id: UUID = UUID(),
        sessionID: UUID,
        valueDomain: LibreWatchValueDomain,
        nativeGlucoseMGDL: Double,
        previousNativeGlucoseMGDL: Double,
        rawGlucose: UInt16,
        previousRawGlucose: UInt16,
        sensorTimeInMinutes: UInt16,
        receivedAt: Date,
        calibrationRevision: UInt64
    ) {
        self.version = version
        self.id = id
        self.sessionID = sessionID
        self.valueDomain = valueDomain
        self.nativeGlucoseMGDL = nativeGlucoseMGDL
        self.previousNativeGlucoseMGDL = previousNativeGlucoseMGDL
        self.rawGlucose = rawGlucose
        self.previousRawGlucose = previousRawGlucose
        self.sensorTimeInMinutes = sensorTimeInMinutes
        self.receivedAt = receivedAt
        self.calibrationRevision = calibrationRevision
    }

    var isValid: Bool {
        isValid(at: Date())
    }

    func isValid(at date: Date) -> Bool {
        version == Self.currentVersion &&
            nativeGlucoseMGDL.isFinite &&
            nativeGlucoseMGDL > 0 &&
            nativeGlucoseMGDL <= 3_000 &&
            previousNativeGlucoseMGDL.isFinite &&
            previousNativeGlucoseMGDL > 0 &&
            previousNativeGlucoseMGDL <= 3_000 &&
            rawGlucose > 0 &&
            rawGlucose <= 0x3FFF &&
            previousRawGlucose > 0 &&
            previousRawGlucose <= 0x3FFF &&
            calibrationRevision > 0 &&
            receivedAt <= date.addingTimeInterval(5 * 60)
    }

    var xDripCalibrationInput: Double {
        Double(rawGlucose) * ConstantsBloodGlucose.libreMultiplier
    }

    var previousXDripCalibrationInput: Double {
        Double(previousRawGlucose) * ConstantsBloodGlucose.libreMultiplier
    }

    func sourceValue(for domain: LibreWatchValueDomain) -> Double {
        switch domain {
        case .factoryNativeMGDL:
            return nativeGlucoseMGDL
        case .xDripRawGlucose:
            return xDripCalibrationInput
        }
    }

    func previousSourceValue(for domain: LibreWatchValueDomain) -> Double {
        switch domain {
        case .factoryNativeMGDL:
            return previousNativeGlucoseMGDL
        case .xDripRawGlucose:
            return previousXDripCalibrationInput
        }
    }

    func sourceTrendPerMinute(for domain: LibreWatchValueDomain) -> Double {
        (sourceValue(for: domain) - previousSourceValue(for: domain)) / 2
    }

    func isValid(for snapshot: LibreWatchCalibrationSnapshot) -> Bool {
        isValid(for: snapshot, at: Date())
    }

    func isValid(for snapshot: LibreWatchCalibrationSnapshot, at date: Date) -> Bool {
        isValid(at: date) &&
            snapshot.isValid &&
            sessionID == snapshot.watchSessionID &&
            valueDomain == snapshot.requiredValueDomain &&
            calibrationRevision <= snapshot.revision
    }

    func isCurrent(
        at date: Date,
        freshnessInterval: TimeInterval = 3 * 60
    ) -> Bool {
        isValid(at: date) && date.timeIntervalSince(receivedAt) <= freshnessInterval
    }
}

/// Shared ordering and freshness gate for direct Watch readings. It deliberately does not
/// inspect glucose values, so a fresh physiological LOW is treated exactly like any other value.
struct LibreWatchReadingAcceptancePolicy {
    static let maximumTransportAge: TimeInterval = 3 * 60

    private(set) var sessionID: UUID?
    private(set) var acceptedPayloadIDs = Set<UUID>()
    private(set) var lastSensorTimeInMinutes: UInt16?
    private(set) var lastReceivedAt: Date?

    mutating func reset(
        for sessionID: UUID? = nil,
        seeding reading: LibreWatchDirectReadingPayload? = nil
    ) {
        self.sessionID = sessionID
        acceptedPayloadIDs.removeAll(keepingCapacity: true)
        lastSensorTimeInMinutes = nil
        lastReceivedAt = nil

        guard let sessionID,
              let reading,
              reading.isValid,
              reading.sessionID == sessionID
        else { return }

        acceptedPayloadIDs.insert(reading.id)
        lastSensorTimeInMinutes = reading.sensorTimeInMinutes
        lastReceivedAt = reading.receivedAt
    }

    mutating func accept(
        _ reading: LibreWatchDirectReadingPayload,
        for expectedSessionID: UUID,
        now: Date = Date(),
        maximumAge: TimeInterval = LibreWatchReadingAcceptancePolicy.maximumTransportAge
    ) -> Bool {
        guard reading.isValid(at: now),
              reading.sessionID == expectedSessionID,
              now.timeIntervalSince(reading.receivedAt) <= maximumAge
        else { return false }

        if sessionID != expectedSessionID {
            reset(for: expectedSessionID)
        }

        guard !acceptedPayloadIDs.contains(reading.id),
              lastSensorTimeInMinutes.map({ reading.sensorTimeInMinutes > $0 }) ?? true,
              lastReceivedAt.map({ reading.receivedAt > $0 }) ?? true
        else { return false }

        acceptedPayloadIDs.insert(reading.id)
        lastSensorTimeInMinutes = reading.sensorTimeInMinutes
        lastReceivedAt = reading.receivedAt
        return true
    }
}

struct LibreWatchDirectDeltaPolicy {
    static let maximumGap: TimeInterval = 3 * 60

    static func sourceDelta(
        current: LibreWatchDirectReadingPayload,
        previous: LibreWatchDirectReadingPayload,
        calibration: LibreWatchCalibrationSnapshot
    ) -> Double? {
        guard current.sessionID == previous.sessionID,
              current.valueDomain == previous.valueDomain,
              current.calibrationRevision == previous.calibrationRevision,
              current.isValid(for: calibration),
              previous.isValid(for: calibration),
              previous.sensorTimeInMinutes < current.sensorTimeInMinutes,
              previous.receivedAt < current.receivedAt,
              current.receivedAt.timeIntervalSince(previous.receivedAt) <= maximumGap
        else { return nil }
        return current.sourceValue(for: calibration.requiredValueDomain) -
            previous.sourceValue(for: calibration.requiredValueDomain)
    }
}

enum LibreWatchCalibrationType: String, Codable, Equatable {
    case factoryCalibrated
    case fixedSlope
    case nonFixedSlope

    var usesXDripCalibration: Bool {
        self != .factoryCalibrated
    }

    var requiredValueDomain: LibreWatchValueDomain {
        usesXDripCalibration ? .xDripRawGlucose : .factoryNativeMGDL
    }
}

struct LibreWatchDirectPresentation: Equatable {
    let glucoseMGDL: Double
    let trendMGDLPerMinute: Double?
    let deltaMGDL: Double?
    let isStale: Bool
}

/// Versioned snapshot of the iPhone calibration needed to render direct readings on Watch.
/// The original direct value is still sent to iPhone and calibrated there exactly once.
struct LibreWatchCalibrationSnapshot: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let activeSensorID: String
    let sensorUID: Data
    let sensorSerialNumber: String
    let watchSessionID: UUID
    let calibrationType: LibreWatchCalibrationType
    let slope: Double
    let intercept: Double
    let rawValueDivider: Double
    let calibratedAt: Date
    let revision: UInt64

    init(
        version: Int = Self.currentVersion,
        activeSensorID: String,
        sensorUID: Data,
        sensorSerialNumber: String,
        watchSessionID: UUID,
        calibrationType: LibreWatchCalibrationType,
        slope: Double,
        intercept: Double,
        rawValueDivider: Double,
        calibratedAt: Date,
        revision: UInt64
    ) {
        self.version = version
        self.activeSensorID = activeSensorID
        self.sensorUID = sensorUID
        self.sensorSerialNumber = sensorSerialNumber
        self.watchSessionID = watchSessionID
        self.calibrationType = calibrationType
        self.slope = slope
        self.intercept = intercept
        self.rawValueDivider = rawValueDivider
        self.calibratedAt = calibratedAt
        self.revision = revision
    }

    var isValid: Bool {
        let dividerIsValid = calibrationType.usesXDripCalibration
            ? rawValueDivider == 1_000
            : rawValueDivider == 1

        return version == Self.currentVersion &&
            !activeSensorID.isEmpty &&
            sensorUID.count == 8 &&
            !sensorSerialNumber.isEmpty &&
            slope.isFinite &&
            intercept.isFinite &&
            rawValueDivider.isFinite &&
            dividerIsValid &&
            revision > 0
    }

    var requiredValueDomain: LibreWatchValueDomain {
        calibrationType.requiredValueDomain
    }

    func matches(session: LibreWatchDirectSession) -> Bool {
        isValid &&
            watchSessionID == session.id &&
            sensorUID == session.sensorUID &&
            sensorSerialNumber.caseInsensitiveCompare(session.sensorSerialNumber) == .orderedSame
    }

    func hasSameCalibration(as other: LibreWatchCalibrationSnapshot) -> Bool {
        activeSensorID == other.activeSensorID &&
            sensorUID == other.sensorUID &&
            sensorSerialNumber.caseInsensitiveCompare(other.sensorSerialNumber) == .orderedSame &&
            watchSessionID == other.watchSessionID &&
            calibrationType == other.calibrationType &&
            slope == other.slope &&
            intercept == other.intercept &&
            rawValueDivider == other.rawValueDivider &&
            calibratedAt == other.calibratedAt
    }

    func displayedGlucose(for reading: LibreWatchDirectReadingPayload) -> Double? {
        guard reading.isValid(for: self), reading.sessionID == watchSessionID else { return nil }

        if calibrationType == .factoryCalibrated {
            // Mirrors NoCalibrator: factory values are already mg/dL and are only capped.
            return min(600, reading.nativeGlucoseMGDL)
        }

        // Mirrors Libre2BLEUtilities + Libre1Calibrator exactly: the 14-bit Libre value is
        // multiplied first, then Calibrator divides that input by 1000 before applying slope.
        let calibrated = slope * (reading.xDripCalibrationInput / rawValueDivider) + intercept
        guard calibrated.isFinite else { return nil }

        // Calibrator uses 38 as an internal failure sentinel when the calculation never
        // produced a usable value. It must not become a physiological LOW on Watch or be
        // forwarded to iPhone. A completed low calculation is clamped to 39 below.
        guard calibrated >= 10 else { return nil }
        return min(400, max(39, calibrated))
    }

    func displayedTrend(for reading: LibreWatchDirectReadingPayload) -> Double? {
        guard reading.isValid(for: self), reading.sessionID == watchSessionID else { return nil }

        let sourceTrend = reading.sourceTrendPerMinute(for: requiredValueDomain)
        let displayedTrend = calibrationType.usesXDripCalibration
            ? slope * sourceTrend / rawValueDivider
            : sourceTrend
        return displayedTrend.isFinite ? displayedTrend : nil
    }

    func displayedDelta(sourceDelta: Double?) -> Double? {
        guard let sourceDelta, sourceDelta.isFinite else { return nil }
        if calibrationType == .factoryCalibrated {
            return sourceDelta
        }
        let calibratedDelta = slope * sourceDelta / rawValueDivider
        return calibratedDelta.isFinite ? calibratedDelta : nil
    }

    func presentation(
        for reading: LibreWatchDirectReadingPayload,
        sourceDelta: Double?,
        at date: Date
    ) -> LibreWatchDirectPresentation? {
        guard let glucose = displayedGlucose(for: reading) else { return nil }
        let isStale = !reading.isCurrent(at: date)
        return LibreWatchDirectPresentation(
            glucoseMGDL: glucose,
            trendMGDLPerMinute: isStale ? nil : displayedTrend(for: reading),
            deltaMGDL: isStale ? nil : displayedDelta(sourceDelta: sourceDelta),
            isStale: isStale
        )
    }
}

/// Last direct reading as rendered on Watch. Source values are retained so a newer
/// calibration snapshot can immediately recompute the display without waiting for Libre.
struct LibreWatchPersistedDirectReading: Codable, Equatable {
    static let currentVersion = 2

    let version: Int
    let sessionID: UUID
    let sensorIdentity: String
    let sourceReading: LibreWatchDirectReadingPayload
    let sourceDelta: Double?
    let displayedGlucoseMGDL: Double
    let displayedTrendMGDLPerMinute: Double?
    let displayedDeltaMGDL: Double?
    let calibrationRevision: UInt64?

    init(
        version: Int = Self.currentVersion,
        sessionID: UUID,
        sensorIdentity: String,
        sourceReading: LibreWatchDirectReadingPayload,
        sourceDelta: Double? = nil,
        displayedGlucoseMGDL: Double,
        displayedTrendMGDLPerMinute: Double?,
        displayedDeltaMGDL: Double? = nil,
        calibrationRevision: UInt64?
    ) {
        self.version = version
        self.sessionID = sessionID
        self.sensorIdentity = sensorIdentity
        self.sourceReading = sourceReading
        self.sourceDelta = sourceDelta
        self.displayedGlucoseMGDL = displayedGlucoseMGDL
        self.displayedTrendMGDLPerMinute = displayedTrendMGDLPerMinute
        self.displayedDeltaMGDL = displayedDeltaMGDL
        self.calibrationRevision = calibrationRevision
    }

    func isValid(
        for session: LibreWatchDirectSession,
        calibration: LibreWatchCalibrationSnapshot
    ) -> Bool {
        version == Self.currentVersion &&
            sessionID == session.id &&
            sourceReading.sessionID == session.id &&
            sensorIdentity == session.redactedIdentity() &&
            calibration.matches(session: session) &&
            sourceReading.isValid(for: calibration) &&
            displayedGlucoseMGDL.isFinite &&
            displayedGlucoseMGDL > 0 &&
            displayedGlucoseMGDL <= 600 &&
            (sourceDelta?.isFinite ?? true) &&
            (displayedTrendMGDLPerMinute?.isFinite ?? true) &&
            (displayedDeltaMGDL?.isFinite ?? true)
    }
}

enum LibreWatchSessionStore {
    static func loadSession(defaults: UserDefaults = .standard) -> LibreWatchDirectSession? {
        guard let data = defaults.data(forKey: LibreWatchMessageKey.persistedSession),
              let session = try? JSONDecoder().decode(LibreWatchDirectSession.self, from: data),
              session.isValid
        else { return nil }
        return session
    }

    static func saveSession(_ session: LibreWatchDirectSession, defaults: UserDefaults = .standard) {
        guard session.isValid, let data = try? JSONEncoder().encode(session) else { return }
        if let previous = loadSession(defaults: defaults),
           previous.id != session.id || !previous.representsSameSensor(as: session) {
            clearReleaseReceipt(defaults: defaults)
        }
        defaults.set(data, forKey: LibreWatchMessageKey.persistedSession)
    }

    static func loadOwnership(defaults: UserDefaults = .standard) -> LibreWatchOwnership {
        guard let rawValue = defaults.string(forKey: LibreWatchMessageKey.persistedOwnership),
              let ownership = LibreWatchOwnership(rawValue: rawValue)
        else { return .iphone }
        return ownership
    }

    static func saveOwnership(_ ownership: LibreWatchOwnership, defaults: UserDefaults = .standard) {
        defaults.set(ownership.rawValue, forKey: LibreWatchMessageKey.persistedOwnership)
    }

    static func loadCalibration(defaults: UserDefaults = .standard) -> LibreWatchCalibrationSnapshot? {
        guard let data = defaults.data(forKey: LibreWatchMessageKey.persistedCalibration),
              let snapshot = try? JSONDecoder().decode(LibreWatchCalibrationSnapshot.self, from: data),
              snapshot.isValid
        else { return nil }
        return snapshot
    }

    static func saveCalibration(
        _ snapshot: LibreWatchCalibrationSnapshot,
        defaults: UserDefaults = .standard
    ) {
        guard snapshot.isValid, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: LibreWatchMessageKey.persistedCalibration)
    }

    static func clearCalibration(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: LibreWatchMessageKey.persistedCalibration)
    }

    static func loadReading(defaults: UserDefaults = .standard) -> LibreWatchPersistedDirectReading? {
        defaults.removeObject(forKey: LibreWatchMessageKey.legacyPersistedReading)
        guard let data = defaults.data(forKey: LibreWatchMessageKey.persistedReading),
              let reading = try? JSONDecoder().decode(LibreWatchPersistedDirectReading.self, from: data),
              reading.version == LibreWatchPersistedDirectReading.currentVersion
        else {
            defaults.removeObject(forKey: LibreWatchMessageKey.persistedReading)
            return nil
        }
        return reading
    }

    static func saveReading(
        _ reading: LibreWatchPersistedDirectReading,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(reading) else { return }
        defaults.set(data, forKey: LibreWatchMessageKey.persistedReading)
    }

    static func clearReading(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: LibreWatchMessageKey.persistedReading)
        defaults.removeObject(forKey: LibreWatchMessageKey.legacyPersistedReading)
    }

    static func loadOutbox(defaults: UserDefaults = .standard) -> LibreWatchConnectivityOutbox {
        guard let data = defaults.data(forKey: LibreWatchMessageKey.persistedOutbox),
              var outbox = try? JSONDecoder().decode(LibreWatchConnectivityOutbox.self, from: data)
        else { return LibreWatchConnectivityOutbox() }
        outbox.prune()
        return outbox
    }

    static func saveOutbox(
        _ outbox: LibreWatchConnectivityOutbox,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(outbox) else { return }
        defaults.set(data, forKey: LibreWatchMessageKey.persistedOutbox)
    }

    static func loadDiagnosticReceipts(
        defaults: UserDefaults = .standard
    ) -> LibreWatchDiagnosticReceiptLedger {
        guard let data = defaults.data(forKey: LibreWatchMessageKey.persistedDiagnosticReceipts),
              var ledger = try? JSONDecoder().decode(LibreWatchDiagnosticReceiptLedger.self, from: data)
        else { return LibreWatchDiagnosticReceiptLedger() }
        ledger.prune()
        return ledger
    }

    static func saveDiagnosticReceipts(
        _ ledger: LibreWatchDiagnosticReceiptLedger,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        defaults.set(data, forKey: LibreWatchMessageKey.persistedDiagnosticReceipts)
    }

    static func loadDiagnosticJournal(
        defaults: UserDefaults = .standard,
        at date: Date = Date()
    ) -> LibreWatchDiagnosticJournal {
        guard let data = defaults.data(forKey: LibreWatchMessageKey.persistedDiagnosticJournal),
              var journal = try? JSONDecoder().decode(LibreWatchDiagnosticJournal.self, from: data)
        else { return LibreWatchDiagnosticJournal() }
        journal.prune(at: date)
        return journal
    }

    static func saveDiagnosticJournal(
        _ journal: LibreWatchDiagnosticJournal,
        defaults: UserDefaults = .standard,
        at date: Date = Date()
    ) {
        var boundedJournal = journal
        boundedJournal.prune(at: date)
        guard let data = try? JSONEncoder().encode(boundedJournal) else { return }
        defaults.set(data, forKey: LibreWatchMessageKey.persistedDiagnosticJournal)
    }

    static func loadRecoveryAttempt(
        defaults: UserDefaults = .standard
    ) -> LibreWatchRecoveryAttemptState {
        guard let data = defaults.data(forKey: LibreWatchMessageKey.persistedRecoveryAttempt),
              let state = try? JSONDecoder().decode(LibreWatchRecoveryAttemptState.self, from: data)
        else { return LibreWatchRecoveryAttemptState() }
        return state
    }

    static func saveRecoveryAttempt(
        _ state: LibreWatchRecoveryAttemptState,
        defaults: UserDefaults = .standard
    ) {
        guard state.context != nil else {
            defaults.removeObject(forKey: LibreWatchMessageKey.persistedRecoveryAttempt)
            return
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: LibreWatchMessageKey.persistedRecoveryAttempt)
    }

    static func loadReleaseReceipt(
        defaults: UserDefaults = .standard
    ) -> LibreWatchReleaseReceipt? {
        guard let data = defaults.data(forKey: LibreWatchMessageKey.persistedReleaseReceipt) else {
            return nil
        }
        return try? JSONDecoder().decode(LibreWatchReleaseReceipt.self, from: data)
    }

    static func saveReleaseReceipt(
        _ receipt: LibreWatchReleaseReceipt,
        defaults: UserDefaults = .standard
    ) {
        guard let data = try? JSONEncoder().encode(receipt) else { return }
        defaults.set(data, forKey: LibreWatchMessageKey.persistedReleaseReceipt)
    }

    static func clearReleaseReceipt(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: LibreWatchMessageKey.persistedReleaseReceipt)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: LibreWatchMessageKey.persistedSession)
        defaults.removeObject(forKey: LibreWatchMessageKey.persistedOwnership)
        defaults.removeObject(forKey: LibreWatchMessageKey.persistedCalibration)
        defaults.removeObject(forKey: LibreWatchMessageKey.persistedReading)
        defaults.removeObject(forKey: LibreWatchMessageKey.legacyPersistedReading)
        defaults.removeObject(forKey: LibreWatchMessageKey.persistedOutbox)
        defaults.removeObject(forKey: LibreWatchMessageKey.persistedDiagnosticReceipts)
        defaults.removeObject(forKey: LibreWatchMessageKey.persistedRecoveryAttempt)
        defaults.removeObject(forKey: LibreWatchMessageKey.persistedReleaseReceipt)
    }
}

extension Notification.Name {
    static let libreWatchDirectSessionPrepared = Notification.Name("libreWatchDirectSessionPrepared")
    static let libreWatchDirectOwnershipForcedToPhone = Notification.Name("libreWatchDirectOwnershipForcedToPhone")
}

/// One phone-authored transaction: connection ownership is applied only after its exact
/// sensor session, highest used unlock counter and calibration have been installed on Watch.
struct LibreWatchHandoffSnapshot: Codable, Equatable {
    let session: LibreWatchDirectSession
    let calibration: LibreWatchCalibrationSnapshot?
    let ownership: LibreWatchOwnership
    let revision: UInt64
    var alarmSettings: LibreWatchAlarmSettings? = nil
    var alarmDelegation: LibreWatchAlarmDelegation? = nil

    var isValid: Bool {
        session.isValid && revision > 0 &&
            (alarmSettings == nil || alarmSettings?.matches(session) == true) &&
            (calibration == nil || calibration?.matches(session: session) == true) &&
            (ownership != .watch || calibration?.matches(session: session) == true)
    }

    func canApply(after acceptedRevision: UInt64) -> Bool {
        isValid && revision > acceptedRevision
    }
}

enum LibreWatchUnlockCounterPolicy {
    static func highest(
        incoming: UInt16,
        session: LibreWatchDirectSession,
        storedSession: LibreWatchDirectSession?,
        activeSensorUID: Data?,
        activePatchInfo: Data?,
        activeCounter: UInt16
    ) -> UInt16 {
        var value = max(incoming, session.unlockCount)
        if let storedSession, storedSession.id == session.id,
           storedSession.representsSameSensor(as: session) {
            value = max(value, storedSession.unlockCount)
        }
        if activeSensorUID == session.sensorUID, activePatchInfo == session.patchInfo {
            value = max(value, activeCounter)
        }
        return value
    }
}

extension LibreWatchSessionStore {
    static func installationID(defaults: UserDefaults = .standard) -> UUID {
        if let stored = defaults.string(forKey: LibreWatchMessageKey.persistedInstallationID),
           let id = UUID(uuidString: stored) { return id }
        let id = UUID()
        defaults.set(id.uuidString, forKey: LibreWatchMessageKey.persistedInstallationID)
        return id
    }

    static func loadHandoffRevision(defaults: UserDefaults = .standard) -> UInt64 {
        defaults.string(forKey: LibreWatchMessageKey.persistedHandoffRevision).flatMap(UInt64.init) ?? 0
    }

    static func saveHandoffRevision(_ revision: UInt64, defaults: UserDefaults = .standard) {
        defaults.set(String(revision), forKey: LibreWatchMessageKey.persistedHandoffRevision)
    }

    static func nextHandoffRevision(at date: Date = Date(), defaults: UserDefaults = .standard) -> UInt64 {
        let previous = loadHandoffRevision(defaults: defaults)
        let revision = max(UInt64(max(1, date.timeIntervalSince1970 * 1_000)),
                           previous == UInt64.max ? previous : previous + 1)
        saveHandoffRevision(revision, defaults: defaults)
        return revision
    }
}
