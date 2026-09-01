import Foundation

enum LibreWatchDirectStage: String, Equatable {
    case unavailable
    case ready
    case handingOff
    case scanning
    case connecting
    case receiving
    case failed
    case returningToPhone

    var displayText: String {
        switch self {
        case .unavailable: return "Set up Libre on iPhone"
        case .ready: return "Ready for Watch takeover"
        case .handingOff: return "iPhone is releasing Libre"
        case .scanning: return "Looking for your Libre"
        case .connecting: return "Connecting to your Libre"
        case .receiving: return "Watch receives directly"
        case .failed: return "Direct reception needs attention"
        case .returningToPhone: return "Returning Libre to iPhone"
        }
    }
}

enum LibreWatchDirectFailure: String, Equatable {
    case noSession = "No prepared Libre session"
    case phoneUnavailable = "Keep iPhone nearby for takeover"
    case ownershipFailed = "iPhone could not release Libre"
    case bluetoothUnavailable = "Bluetooth is unavailable"
    case connectionFailed = "Could not connect to Libre"
    case serviceNotFound = "Libre Bluetooth service was not found"
    case characteristicNotFound = "Libre Bluetooth channel was not found"
    case notificationSetupFailed = "Libre notifications could not start"
    case unlockWriteFailed = "Libre unlock failed"
    case invalidFrame = "Libre data could not be decoded"
}

struct LibreWatchDirectState: Equatable {
    private(set) var stage: LibreWatchDirectStage = .unavailable
    private(set) var failure: LibreWatchDirectFailure?
    private(set) var detailText = "A compatible Libre 2 Plus must first be set up on iPhone"
    private(set) var redactedSensorIdentity: String?
    private(set) var lastRSSI: Int?
    private(set) var lastPacketAt: Date?
    private(set) var unlockCounter: UInt16?
    private(set) var directReading: Libre2WatchDirectReading?
    private(set) var lastBluetoothError: String?

    var isReceiving: Bool {
        [.scanning, .connecting, .receiving].contains(stage)
    }

    mutating func sessionAvailable(_ session: LibreWatchDirectSession?) {
        guard let session, session.isValid else {
            stage = .unavailable
            failure = .noSession
            detailText = LibreWatchDirectFailure.noSession.rawValue
            redactedSensorIdentity = nil
            return
        }
        if !isReceiving {
            stage = .ready
            failure = nil
            detailText = "Prepared for \(session.sensorTypeRawValue) sensor"
        }
        redactedSensorIdentity = session.redactedIdentity()
        unlockCounter = session.unlockCount
    }

    mutating func beginHandoff() {
        stage = .handingOff
        failure = nil
        detailText = "Waiting for the iPhone to disconnect"
        lastBluetoothError = nil
    }

    mutating func scanning() {
        stage = .scanning
        failure = nil
        detailText = "Scanning for the exact NFC-confirmed sensor"
    }

    mutating func candidate(rssi: Int) {
        lastRSSI = rssi
    }

    mutating func connecting() {
        stage = .connecting
        failure = nil
        detailText = "Exact sensor matched; establishing direct connection"
    }

    mutating func notificationsActive() {
        stage = .receiving
        failure = nil
        detailText = "Connected; waiting for the next Libre reading"
    }

    mutating func recordUnlockCounter(_ value: UInt16) {
        unlockCounter = value
    }

    mutating func recordDirectReading(_ reading: Libre2WatchDirectReading) {
        directReading = reading
        lastPacketAt = reading.receivedAt
        stage = .receiving
        failure = nil
        detailText = "Direct reading received by Apple Watch"
    }

    mutating func beginReturn() {
        stage = .returningToPhone
        failure = nil
        detailText = "Disconnecting Watch and restoring iPhone"
    }

    mutating func returnedToPhone(session: LibreWatchDirectSession?) {
        directReading = nil
        lastPacketAt = nil
        sessionAvailable(session)
    }

    mutating func fail(_ failure: LibreWatchDirectFailure, error: String? = nil) {
        stage = .failed
        self.failure = failure
        detailText = failure.rawValue
        lastBluetoothError = error
    }
}
