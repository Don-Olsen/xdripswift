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

    static let persistedSession = "libreWatchDirectPersistedSession.v2"
    static let persistedOwnership = "libreWatchDirectPersistedOwnership.v2"
    static let persistedCalibration = "libreWatchCalibrationSnapshot.v1"
    static let persistedReading = "libreWatchDirectPersistedReading.v2"
    static let legacyPersistedReading = "libreWatchDirectPersistedReading.v1"
}

enum LibreWatchCommand: String, Codable {
    case acknowledgeSession
    case requestOwnership
    case releaseOwnership
    case updateUnlockCounter
    case submitReading
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

        // Mirrors Calibrator.updateCalculatedValue(for:).
        if calibrated < 10 { return 38 }
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

    static func clear(defaults: UserDefaults = .standard) {
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
