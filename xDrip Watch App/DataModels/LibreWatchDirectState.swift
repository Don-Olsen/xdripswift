import Foundation

enum LibreWatchDirectStage: String, Codable, Equatable {
    case idle
    case sessionMissing
    case ready
    case releasingToWatch
    case scanning
    case candidateObserved
    case identityMatched
    case connecting
    case connected
    case discoveringServices
    case serviceFound
    case discoveringCharacteristics
    case characteristicsFound
    case enablingNotifications
    case notificationsEnabled
    case sendingUnlock
    case unlockSent
    case receivingFragments
    case frameComplete
    case decrypting
    case decrypted
    case parsing
    case directGlucose
    case failed
    case stopped

    var displayText: String {
        switch self {
        case .idle: return "IDLE"
        case .sessionMissing: return "NO TEST SESSION"
        case .ready: return "READY"
        case .releasingToWatch: return "RELEASING TO WATCH"
        case .scanning: return "SCANNING"
        case .candidateObserved: return "FDE3 CANDIDATE OBSERVED"
        case .identityMatched: return "IDENTITY MATCHED"
        case .connecting: return "CONNECTING"
        case .connected: return "CONNECTED"
        case .discoveringServices: return "DISCOVERING SERVICES"
        case .serviceFound: return "FDE3 FOUND"
        case .discoveringCharacteristics: return "DISCOVERING CHARACTERISTICS"
        case .characteristicsFound: return "F001 + F002 FOUND"
        case .enablingNotifications: return "ENABLING NOTIFICATIONS"
        case .notificationsEnabled: return "NOTIFICATIONS ACTIVE"
        case .sendingUnlock: return "SENDING UNLOCK"
        case .unlockSent: return "UNLOCK SENT"
        case .receivingFragments: return "PACKET RECEIVED"
        case .frameComplete: return "FRAME COMPLETE"
        case .decrypting: return "DECRYPTING"
        case .decrypted: return "DECRYPTED"
        case .parsing: return "PARSING"
        case .directGlucose: return "GLUCOSE DECODED"
        case .failed: return "FAILED"
        case .stopped: return "STOPPED"
        }
    }
}

enum LibreWatchDirectFailure: String, Equatable {
    case noTestSession = "NO TEST SESSION"
    case noMatchingTestSensor = "NO MATCHING TEST SENSOR"
    case identityMismatch = "TEST SENSOR IDENTITY NOT CONFIRMED"
    case ownershipFailed = "PHONE OWNERSHIP RELEASE FAILED"
    case connectionFailed = "CONNECTION FAILED"
    case serviceNotFound = "FDE3 NOT FOUND"
    case writeCharacteristicNotFound = "F001 NOT FOUND"
    case receiveCharacteristicNotFound = "F002 NOT FOUND"
    case notificationSetupFailed = "NOTIFICATION SETUP FAILED"
    case unlockWriteFailed = "UNLOCK WRITE FAILED"
    case noDataReceived = "NO DATA RECEIVED"
    case badFrameLength = "BAD FRAME LENGTH"
    case decryptionFailed = "DECRYPTION FAILED"
    case parsingFailed = "PARSING FAILED"
}

struct LibreWatchDirectState: Equatable {
    static let maximumTestDuration: TimeInterval = 5 * 60

    private(set) var stage: LibreWatchDirectStage = .idle
    private(set) var failure: LibreWatchDirectFailure?
    private(set) var detailText = "Prepare a Libre 2 Plus test session on iPhone"
    private(set) var elapsedSeconds = 0
    private(set) var lastRSSI: Int?
    private(set) var redactedSensorIdentity: String?
    private(set) var fragmentCount = 0
    private(set) var assembledByteCount = 0
    private(set) var completeFrameCount = 0
    private(set) var lastPacketLength = 0
    private(set) var lastPacketAt: Date?
    private(set) var lastCompleteFrameAt: Date?
    private(set) var unlockCounter: UInt16?
    private(set) var lastBluetoothError: String?
    private(set) var directReading: Libre2DirectReading?
    private var startedAt: Date?

    var isRunning: Bool {
        ![.idle, .sessionMissing, .ready, .failed, .stopped].contains(stage)
    }

    var elapsedText: String {
        String(format: "%d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    var canDisplayDirectFromSensor: Bool {
        stage == .directGlucose && directReading?.canDisplayDirectFromSensor == true
    }

    mutating func sessionAvailable(_ session: LibreWatchTestSession?) {
        guard let session, session.isValid else {
            stage = .sessionMissing
            failure = .noTestSession
            detailText = LibreWatchDirectFailure.noTestSession.rawValue
            redactedSensorIdentity = nil
            return
        }
        stage = .ready
        failure = nil
        detailText = "Prepared \(session.sensorTypeRawValue) test sensor"
        redactedSensorIdentity = session.redactedIdentity()
        unlockCounter = session.unlockCount
    }

    mutating func start(at date: Date) {
        stage = .releasingToWatch
        failure = nil
        detailText = "Requesting test-sensor ownership from iPhone"
        elapsedSeconds = 0
        fragmentCount = 0
        assembledByteCount = 0
        completeFrameCount = 0
        lastPacketLength = 0
        lastPacketAt = nil
        lastCompleteFrameAt = nil
        lastBluetoothError = nil
        directReading = nil
        startedAt = date
    }

    mutating func transition(to stage: LibreWatchDirectStage, detail: String? = nil) {
        self.stage = stage
        failure = nil
        if let detail { detailText = detail }
    }

    mutating func recordCandidate(rssi: Int, identityMatched: Bool) {
        lastRSSI = rssi
        stage = identityMatched ? .identityMatched : .candidateObserved
        detailText = identityMatched
            ? "Prepared test sensor matched"
            : LibreWatchDirectFailure.identityMismatch.rawValue
    }

    mutating func recordFragment(
        length: Int,
        fragmentCount: Int,
        assembledByteCount: Int,
        at date: Date
    ) {
        stage = .receivingFragments
        detailText = "Receiving F002 notification fragments"
        lastPacketLength = length
        self.fragmentCount = fragmentCount
        self.assembledByteCount = assembledByteCount
        lastPacketAt = date
    }

    mutating func recordCompleteFrame(count: Int, at date: Date) {
        stage = .frameComplete
        detailText = "46-byte encrypted frame assembled"
        completeFrameCount = count
        lastCompleteFrameAt = date
        assembledByteCount = 0
    }

    mutating func recordUnlockCounter(_ value: UInt16) {
        unlockCounter = value
    }

    mutating func recordDirectReading(_ reading: Libre2DirectReading) {
        guard reading.source == .watchSensorF002 else { return }
        directReading = reading
        stage = .directGlucose
        failure = nil
        detailText = "Watch received, decrypted and parsed F002 data"
    }

    mutating func updateElapsed(at date: Date) -> Bool {
        guard let startedAt else { return false }
        elapsedSeconds = min(
            Int(Self.maximumTestDuration),
            max(0, Int(date.timeIntervalSince(startedAt)))
        )
        return date.timeIntervalSince(startedAt) >= Self.maximumTestDuration
    }

    mutating func fail(_ failure: LibreWatchDirectFailure, error: String? = nil) {
        stage = .failed
        self.failure = failure
        detailText = failure.rawValue
        lastBluetoothError = error
        startedAt = nil
    }

    mutating func stop() {
        stage = .stopped
        failure = nil
        detailText = "Watch released the prepared test sensor"
        startedAt = nil
        directReading = nil
        assembledByteCount = 0
    }
}
