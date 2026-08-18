//
//  LibreWatchDiagnosticState.swift
//  xDrip Watch App
//
//  Phase 1A keeps all observations in memory and contains no sensor I/O.
//

import Foundation

enum LibreWatchScanStopReason: Equatable {
    case user
    case timeout
    case viewDisappeared
    case bluetoothUnavailable
}

struct LibreWatchDiagnosticState: Equatable {
    static let serviceUUIDString = "FDE3"
    static let maximumScanDuration: TimeInterval = 5 * 60

    private(set) var isScanning = false
    private(set) var elapsedSeconds = 0
    private(set) var observationCount = 0
    private(set) var lastRSSI: Int?
    private(set) var lastSeen: Date?
    private(set) var redactedCandidateIdentifier: String?
    private(set) var resultText = "Ready for a passive FDE3 scan"
    private(set) var lastStopReason: LibreWatchScanStopReason?

    private var startedAt: Date?
    private var sessionSalt: UInt64 = 0

    var scanStatusText: String {
        isScanning ? "Scanning" : "Not scanning"
    }

    var elapsedText: String {
        String(format: "%d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    mutating func start(at date: Date, sessionSalt: UInt64) {
        isScanning = true
        elapsedSeconds = 0
        observationCount = 0
        lastRSSI = nil
        lastSeen = nil
        redactedCandidateIdentifier = nil
        resultText = "Scanning for FDE3 advertisements…"
        lastStopReason = nil
        startedAt = date
        self.sessionSalt = sessionSalt
    }

    mutating func recordCandidate(rawIdentifier: String, rssi: Int, seenAt date: Date) {
        guard isScanning else { return }

        observationCount += 1
        lastRSSI = rssi
        lastSeen = date
        redactedCandidateIdentifier = Self.redact(rawIdentifier, salt: sessionSalt)
        resultText = "FDE3 candidate observed"
    }

    @discardableResult
    mutating func updateElapsed(at date: Date) -> Bool {
        guard isScanning, let startedAt else { return false }

        elapsedSeconds = min(
            Int(Self.maximumScanDuration),
            max(0, Int(date.timeIntervalSince(startedAt)))
        )

        return date.timeIntervalSince(startedAt) >= Self.maximumScanDuration
    }

    mutating func stop(at date: Date, reason: LibreWatchScanStopReason) {
        guard isScanning else { return }

        _ = updateElapsed(at: date)
        isScanning = false
        lastStopReason = reason
        startedAt = nil
        sessionSalt = 0
        resultText = observationCount > 0
            ? "FDE3 candidate observed"
            : "No candidate observed during this scan"
    }

    static func isRelevantServiceUUID(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        return normalized == serviceUUIDString
            || normalized == "0000FDE3-0000-1000-8000-00805F9B34FB"
    }

    static func redact(_ rawIdentifier: String, salt: UInt64) -> String {
        // A session-scoped FNV-1a digest gives the user a stable label during one
        // scan without retaining or revealing the peripheral identifier.
        var digest = UInt64(14_695_981_039_346_656_037) ^ salt

        for byte in rawIdentifier.utf8 {
            digest ^= UInt64(byte)
            digest &*= 1_099_511_628_211
        }

        return String(format: "Candidate-%06X", digest & 0xFF_FFFF)
    }
}
