import Foundation

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
    static let releaseCutoff = "libreWatchReleaseCutoff"
    static let historySensorID = "libreWatchHistorySensorID"

    static let persistedSession = "libreWatchDirectPersistedSession.v2"
    static let persistedOwnership = "libreWatchDirectPersistedOwnership.v2"
    static let persistedCalibration = "libreWatchCalibrationSnapshot.v1"
    static let persistedReading = "libreWatchDirectPersistedReading.v2"
    static let legacyPersistedReading = "libreWatchDirectPersistedReading.v1"
    static let persistedReleaseReceipt = "libreWatchReleaseReceipt.v1"
    static let persistedHistory = "libreWatchDirectHistory.v2"
    static let recoveryProgress = "libreWatchRecoveryProgress.v1"
    static let diagnosticReceipts = "libreWatchDiagnosticReceipts.v1"
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
    case recoveryDecision
}

enum LibreWatchScene: String, Codable { case active, inactive, background, unknown }
enum LibreWatchRuntimeState: String, Codable { case none, starting, running }
enum LibreWatchCentralState: String, Codable { case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn }
enum LibreWatchPeripheralState: String, Codable { case absent, disconnected, connecting, connected, disconnecting }
enum LibreWatchDiagnosticStage: String, Codable {
    case unavailable, ready, handingOff, scanning, connecting, reconnecting, receiving, failed, returningToPhone
}
enum LibreWatchRecoveryTrigger: String, Codable {
    case prepare, ownership, scene, runtime, bluetooth, restoration, disconnected, connectionFailed
    case connected, setup, setupFailed, packet, timer
}
enum LibreWatchRecoveryAction: String, Codable {
    case stopped, waitForExecution, waitForBluetooth, waitForCancellation, waitForSystemReconnect
    case waitForConnection, waitForNotifications, scanConfirmedSensor, connectConfirmedSensor
    case discoverServices, restartConfirmedSensorScan
}

struct LibreWatchDiagnosticContext: Codable, Equatable {
    let scene: LibreWatchScene
    let runtime: LibreWatchRuntimeState
    let central: LibreWatchCentralState
    let peripheral: LibreWatchPeripheralState
    let stage: LibreWatchDiagnosticStage
    let trigger: LibreWatchRecoveryTrigger
    let action: LibreWatchRecoveryAction
    let recoveryStartedAt: Date?
}

/// A bounded, privacy-safe Watch diagnostic. Sensor identity is derived on iPhone from
/// the validated session and never crosses as a raw peripheral identifier.
struct LibreWatchDiagnosticEvent: Codable, Equatable {
    // Optional for already queued events from build 4245. Do not invent their event time/ID.
    let id: UUID?
    let occurredAt: Date?
    let kind: LibreWatchDiagnosticEventKind
    let isReconnecting: Bool?
    let errorCode: Int?
    let context: LibreWatchDiagnosticContext?

    init(
        kind: LibreWatchDiagnosticEventKind,
        isReconnecting: Bool? = nil,
        errorCode: Int? = nil,
        id: UUID? = UUID(),
        occurredAt: Date? = Date(),
        context: LibreWatchDiagnosticContext? = nil
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.kind = kind
        self.isReconnecting = isReconnecting
        self.errorCode = errorCode
        self.context = context
    }
}

/// The same encoded event (and UUID) is queued if interactive delivery fails.
enum LibreWatchDiagnosticDelivery {
    static func send(_ message: [String: Any], interactively: Bool,
                     send: ([String: Any], @escaping (Error) -> Void) -> Void,
                     queue: @escaping ([String: Any]) -> Void) {
        if interactively { send(message) { _ in queue(message) } }
        else { queue(message) }
    }
}

struct LibreWatchDiagnosticReceipts: Codable {
    private var received: [UUID: Date] = [:]

    mutating func accept(_ event: LibreWatchDiagnosticEvent, now: Date) -> Bool {
        received = received.filter { now.timeIntervalSince($0.value) <= 24 * 60 * 60 }
        guard let id = event.id else { return true } // legacy event, identity was not recorded
        guard received[id] == nil else { return false }
        if received.count >= 1_024, let oldest = received.min(by: { $0.value < $1.value })?.key {
            received.removeValue(forKey: oldest)
        }
        received[id] = now
        return true
    }
}

/// Episode time survives suspension/restoration. Only a new actual connection attempt changes
/// its deadline; lifecycle callbacks and repeated failures never postpone an existing deadline.
struct LibreWatchRecoveryProgress: Codable, Equatable {
    let sessionID: UUID
    private(set) var startedAt: Date?
    private(set) var attemptStartedAt: Date?
    private(set) var lastPacketAt: Date?

    init(sessionID: UUID) { self.sessionID = sessionID }
    mutating func begin(at date: Date) {
        startedAt = startedAt ?? date
        attemptStartedAt = attemptStartedAt ?? date
    }
    mutating func beginAttempt(at date: Date) {
        startedAt = startedAt ?? date
        attemptStartedAt = date
    }
    mutating func receivedPacket(at date: Date) {
        startedAt = nil
        attemptStartedAt = nil
        lastPacketAt = date
    }
}

/// Modern callbacks carry the actual disconnect time. Old events cannot tear down a newer
/// connection, and a callback for an unrelated peripheral never consumes this gate.
struct LibreWatchDisconnectGate {
    private var handledAt: Date?

    mutating func accept(disconnectedAt date: Date) -> Bool {
        // Compare event times, not the time a delayed didConnect callback reached our process.
        // Do not reset on didConnect: a late duplicate still belongs to its old disconnect.
        guard handledAt.map({ date > $0 }) ?? true else { return false }
        handledAt = date
        return true
    }
    static func useLegacyCallback(modernCallbackAvailable: Bool) -> Bool { !modernCallbackAvailable }
}

/// One decision per execution opportunity, not a background retry loop. The collector executes
/// this action and then waits for Core Bluetooth (or an eligible foreground/runtime deadline).
enum LibreWatchRecoveryPolicy {
    static func action(ownership: LibreWatchOwnership, validSession: Bool,
                       poweredOn: Bool, peripheral: LibreWatchPeripheralState,
                       scanning: Bool, systemReconnecting: Bool, manualConnecting: Bool, cancelling: Bool,
                       setupInProgress: Bool, notificationsReady: Bool, receivingFrame: Bool = false,
                       attemptStartedAt: Date?, lastActivityAt: Date?, now: Date,
                       applicationIsActive: Bool, extendedRuntimeIsRunning: Bool,
                       trigger: LibreWatchRecoveryTrigger) -> LibreWatchRecoveryAction {
        guard ownership == .watch, validSession else { return .stopped }
        if trigger == .timer && !LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: applicationIsActive, extendedRuntimeIsRunning: extendedRuntimeIsRunning,
            ownership: ownership
        ) { return .waitForExecution }
        guard poweredOn else { return .waitForBluetooth }
        if cancelling {
            return peripheral == .disconnected || peripheral == .absent ? .scanConfirmedSensor : .waitForCancellation
        }
        let reconnectDelay = applicationIsActive
            ? LibreWatchLifecyclePolicy.foregroundReconnectFallbackDelay
            : LibreWatchLifecyclePolicy.extendedRuntimeReconnectFallbackDelay
        let overdue = attemptStartedAt.map { now.timeIntervalSince($0) >= reconnectDelay } ?? false
        if peripheral == .connected, notificationsReady {
            // Let a newly arriving frame finish within the existing fragment-gap limit.
            // Its first fragment is not a reason to cancel a now-working connection.
            if receivingFrame { return .waitForNotifications }
            let noDataDelay = applicationIsActive
                ? LibreWatchLifecyclePolicy.foregroundNoDataRecoveryDelay
                : LibreWatchLifecyclePolicy.extendedRuntimeNoDataRecoveryDelay
            return lastActivityAt.map { now.timeIntervalSince($0) >= noDataDelay } == true
                ? .restartConfirmedSensorScan : .waitForNotifications
        }
        if overdue && peripheral != .absent { return .restartConfirmedSensorScan }
        if systemReconnecting { return .waitForSystemReconnect }
        if manualConnecting { return .waitForConnection }
        if scanning && (peripheral == .absent || peripheral == .disconnected) {
            return .scanConfirmedSensor // keep the one existing filtered scan
        }
        switch peripheral {
        case .absent: return .scanConfirmedSensor
        case .disconnected: return trigger == .connectionFailed || trigger == .setupFailed
            ? .scanConfirmedSensor : .connectConfirmedSensor
        case .connecting: return .waitForConnection
        case .disconnecting: return .waitForCancellation
        case .connected: return setupInProgress ? .waitForConnection : .discoverServices
        }
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

/// Pure lifecycle policy shared by the Watch collector and deterministic iPhone tests.
/// Timed recovery requires foreground/runtime execution, while Core Bluetooth delegate events
/// may finish one already-established operation whenever Watch still owns the sensor.
struct LibreWatchLifecyclePolicy {
    static let foregroundReconnectFallbackDelay: TimeInterval = 12
    static let extendedRuntimeReconnectFallbackDelay: TimeInterval = 90
    static let foregroundNoDataRecoveryDelay: TimeInterval = 2 * 60
    static let extendedRuntimeNoDataRecoveryDelay: TimeInterval = 3 * 60

    static func recoveryIsAllowed(
        applicationIsActive: Bool,
        extendedRuntimeIsRunning: Bool,
        ownership: LibreWatchOwnership
    ) -> Bool {
        ownership == .watch && (applicationIsActive || extendedRuntimeIsRunning)
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
        reconnectStartedAt: Date,
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

        let timeout = applicationIsActive
            ? foregroundReconnectFallbackDelay
            : extendedRuntimeReconnectFallbackDelay
        let remaining = timeout - max(0, now.timeIntervalSince(reconnectStartedAt))
        return remaining <= 0 ? .restartConfirmedSensorScan : .wait(remaining)
    }

    static func noDataRecoveryDelay(
        applicationIsActive: Bool,
        extendedRuntimeIsRunning: Bool,
        ownership: LibreWatchOwnership
    ) -> TimeInterval? {
        guard recoveryIsAllowed(
            applicationIsActive: applicationIsActive,
            extendedRuntimeIsRunning: extendedRuntimeIsRunning,
            ownership: ownership
        ) else { return nil }

        return applicationIsActive
            ? foregroundNoDataRecoveryDelay
            : extendedRuntimeNoDataRecoveryDelay
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
            receivedAt <= Date().addingTimeInterval(5 * 60)
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
        isValid &&
            snapshot.isValid &&
            sessionID == snapshot.watchSessionID &&
            valueDomain == snapshot.requiredValueDomain &&
            calibrationRevision <= snapshot.revision
    }

    func isCurrent(
        at date: Date,
        freshnessInterval: TimeInterval = 3 * 60
    ) -> Bool {
        isValid && date.timeIntervalSince(receivedAt) <= freshnessInterval
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
        guard reading.isValid,
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

/// Local delivery metadata, never a sender-controlled permission in the reading payload.
enum LibreWatchReadingTransport: String, Codable {
    case interactiveMessage
    case queuedUserInfo
}

enum LibreWatchDeliveryOutcome: String, Codable {
    case liveAccepted, historicalInserted, duplicate
    case invalidPayload, wrongSession, wrongSensor, wrongCalibration, invalidValue
    case invalidTime, tooOld, notOwner, missingReceipt, afterCutoff, collectorUnavailable
    case liveOrderingRejected, historyNotInserted
    case receiptCreated, receiptCompleted, receiptCancelled, receiptExpired
}

/// A receipt only authorizes late delivery of readings already acquired before Watch released
/// the sensor. It never authorizes a BLE connection or relaxes the interactive/live policy.
struct LibreWatchReleaseReceipt: Codable, Equatable {
    enum State: String, Codable { case pending, completed }

    let sessionID: UUID
    let sensorUID: Data
    let patchInfo: Data
    let calibration: LibreWatchCalibrationSnapshot?
    let cutoff: Date
    let expiresAt: Date
    private(set) var state: State = .pending

    init?(session: LibreWatchDirectSession, calibration: LibreWatchCalibrationSnapshot?,
          cutoff: Date, now: Date = Date()) {
        guard session.isValid, calibration.map({ $0.matches(session: session) }) ?? true,
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

    func matches(session: LibreWatchDirectSession, calibration: LibreWatchCalibrationSnapshot) -> Bool {
        sessionID == session.id && sensorUID == session.sensorUID && patchInfo == session.patchInfo &&
            self.calibration?.hasSameCalibration(as: calibration) == true &&
            self.calibration?.revision == calibration.revision
    }

    mutating func complete() { state = .completed }
}

enum LibreWatchHistoryPolicy {
    static let maximumAge: TimeInterval = 12 * 60 * 60
    // Same tolerance as the normal newest-reading path, not its 2.5-minute backfill slot.
    // This preserves actual one-minute Watch samples and the phone's existing collision winner.
    static let collisionTolerance: TimeInterval = 10

    static func rejection(
        for reading: LibreWatchDirectReadingPayload,
        transport: LibreWatchReadingTransport,
        session: LibreWatchDirectSession,
        calibration: LibreWatchCalibrationSnapshot,
        ownership: LibreWatchOwnership,
        receipt: LibreWatchReleaseReceipt?,
        now: Date = Date()
    ) -> LibreWatchDeliveryOutcome? {
        guard transport == .queuedUserInfo else { return .invalidPayload }
        guard session.isValid, reading.sessionID == session.id else { return .wrongSession }
        guard calibration.matches(session: session) else { return .wrongSensor }
        guard reading.calibrationRevision == calibration.revision,
              reading.valueDomain == calibration.requiredValueDomain else { return .wrongCalibration }
        guard reading.isValid(for: calibration),
              reading.id != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
              calibration.displayedGlucose(for: reading) != nil else { return .invalidValue }
        guard reading.receivedAt.timeIntervalSince1970.isFinite,
              reading.receivedAt >= session.createdAt,
              reading.receivedAt <= now,
              reading.sensorTimeInMinutes > 0 else { return .invalidTime }
        guard now.timeIntervalSince(reading.receivedAt) <= maximumAge else { return .tooOld }

        if let receipt {
            guard receipt.expiresAt > now,
                  receipt.matches(session: session, calibration: calibration) else { return .missingReceipt }
            guard reading.receivedAt <= receipt.cutoff else { return .afterCutoff }
            switch ownership {
            case .watch, .releasingToPhone: return nil
            case .iphone: return receipt.state == .completed ? nil : .missingReceipt
            default: return .notOwner
            }
        }
        return ownership == .watch ? nil : .missingReceipt
    }

    static func collides(payloadID: String?, measuredAt: Date, sensorID: String,
                         existingID: String, existingAt: Date, existingSensorID: String?) -> Bool {
        existingSensorID == sensorID &&
            (payloadID == existingID || abs(existingAt.timeIntervalSince(measuredAt)) <= collisionTolerance)
    }
}

/// Chart-only union of real points. The caller supplies only the matching direct session.
/// There is deliberately no interpolation or timestamp rounding.
enum LibreWatchHistoryMerge {
    struct Point: Equatable {
        let date: Date
        let glucose: Double
    }

    static func merge(phone: [Point], watch: [Point], now: Date = Date()) -> [Point] {
        let oldest = now.addingTimeInterval(-LibreWatchHistoryPolicy.maximumAge)
        let valid: (Point) -> Bool = {
            $0.date >= oldest && $0.date <= now && $0.glucose.isFinite && $0.glucose > 0
        }
        let phone = phone.filter(valid)
        var points = [Date: Point]()
        for point in watch.filter(valid) where !phone.contains(where: {
            abs($0.date.timeIntervalSince(point.date)) <= LibreWatchHistoryPolicy.collisionTolerance
        }) {
            points[point.date] = point
        }
        for point in phone { points[point.date] = point }
        return points.values.sorted { $0.date > $1.date }
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
            defaults.removeObject(forKey: LibreWatchMessageKey.persistedHistory)
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

    /// Chart cache only, never an outbox or resend source. WCSession owns delivery.
    static func loadHistory(defaults: UserDefaults = .standard) -> [LibreWatchDirectReadingPayload] {
        guard let data = defaults.data(forKey: LibreWatchMessageKey.persistedHistory),
              let history = try? JSONDecoder().decode([LibreWatchDirectReadingPayload].self, from: data)
        else { return [] }
        return history
    }

    static func saveHistory(_ history: [LibreWatchDirectReadingPayload], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: LibreWatchMessageKey.persistedHistory)
    }

    static func loadReleaseReceipt(defaults: UserDefaults = .standard) -> LibreWatchReleaseReceipt? {
        guard let data = defaults.data(forKey: LibreWatchMessageKey.persistedReleaseReceipt) else { return nil }
        return try? JSONDecoder().decode(LibreWatchReleaseReceipt.self, from: data)
    }

    static func saveReleaseReceipt(_ receipt: LibreWatchReleaseReceipt, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(receipt) else { return }
        defaults.set(data, forKey: LibreWatchMessageKey.persistedReleaseReceipt)
    }

    static func clearReleaseReceipt(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: LibreWatchMessageKey.persistedReleaseReceipt)
    }

    static func clear(defaults: UserDefaults = .standard) {
        clearReleaseReceipt(defaults: defaults)
        defaults.removeObject(forKey: LibreWatchMessageKey.persistedHistory)
        defaults.removeObject(forKey: LibreWatchMessageKey.persistedSession)
        defaults.removeObject(forKey: LibreWatchMessageKey.persistedOwnership)
        defaults.removeObject(forKey: LibreWatchMessageKey.persistedCalibration)
        defaults.removeObject(forKey: LibreWatchMessageKey.persistedReading)
        defaults.removeObject(forKey: LibreWatchMessageKey.legacyPersistedReading)
    }
}

extension Notification.Name {
    static let libreWatchDirectSessionPrepared = Notification.Name("libreWatchDirectSessionPrepared")
    static let libreWatchDirectOwnershipForcedToPhone = Notification.Name("libreWatchDirectOwnershipForcedToPhone")
}
