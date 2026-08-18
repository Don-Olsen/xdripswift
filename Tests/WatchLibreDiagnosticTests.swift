import Foundation

private enum TestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure.failed(message)
    }
}

@main
struct WatchLibreDiagnosticTests {
    static func main() throws {
        try testServiceUUIDFiltering()
        try testIdentifierRedaction()
        try testCandidateObservationAggregation()
        try testScanStateTransitions()
        try testFiveMinuteTimeout()
        try testStopOnViewDisappearance()
        try testNoCandidateResult()
        try testCandidateObservedResult()

        print("Watch Libre Phase 1A model tests passed")
    }

    private static func testServiceUUIDFiltering() throws {
        try expect(LibreWatchDiagnosticState.isRelevantServiceUUID("FDE3"), "FDE3 must be relevant")
        try expect(
            LibreWatchDiagnosticState.isRelevantServiceUUID("0000fde3-0000-1000-8000-00805f9b34fb"),
            "The Bluetooth-base expansion of FDE3 must be relevant"
        )
        try expect(!LibreWatchDiagnosticState.isRelevantServiceUUID("180D"), "Unrelated services must be rejected")
    }

    private static func testIdentifierRedaction() throws {
        let rawIdentifier = "12345678-1234-1234-1234-123456789ABC"
        let first = LibreWatchDiagnosticState.redact(rawIdentifier, salt: 42)
        let repeated = LibreWatchDiagnosticState.redact(rawIdentifier, salt: 42)
        let anotherSession = LibreWatchDiagnosticState.redact(rawIdentifier, salt: 43)

        try expect(first == repeated, "A candidate label must be stable during one scan")
        try expect(first != anotherSession, "A candidate label must change between scan sessions")
        try expect(first.hasPrefix("Candidate-"), "A candidate label must be visibly redacted")
        try expect(first.count == 16, "A candidate label must contain only a short digest")
        try expect(!first.contains("12345678"), "A candidate label must not expose the raw identifier")
    }

    private static func testCandidateObservationAggregation() throws {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let lastSeen = startedAt.addingTimeInterval(10)
        var state = LibreWatchDiagnosticState()

        state.start(at: startedAt, sessionSalt: 7)
        state.recordCandidate(rawIdentifier: "candidate-a", rssi: -72, seenAt: startedAt.addingTimeInterval(2))
        state.recordCandidate(rawIdentifier: "candidate-a", rssi: -65, seenAt: lastSeen)

        try expect(state.observationCount == 2, "Each relevant advertisement must be counted")
        try expect(state.lastRSSI == -65, "The latest RSSI must replace the prior value")
        try expect(state.lastSeen == lastSeen, "The latest observation time must be retained")
        try expect(state.redactedCandidateIdentifier != nil, "A redacted candidate label must be shown")
    }

    private static func testScanStateTransitions() throws {
        let startedAt = Date(timeIntervalSince1970: 2_000)
        var state = LibreWatchDiagnosticState()

        try expect(!state.isScanning, "The diagnostic must initially be stopped")
        state.start(at: startedAt, sessionSalt: 1)
        try expect(state.isScanning, "Start must enter scanning state")
        state.stop(at: startedAt.addingTimeInterval(3), reason: .user)
        try expect(!state.isScanning, "Stop must leave scanning state")
        try expect(state.lastStopReason == .user, "A manual stop reason must be recorded")
    }

    private static func testFiveMinuteTimeout() throws {
        let startedAt = Date(timeIntervalSince1970: 3_000)
        var state = LibreWatchDiagnosticState()

        state.start(at: startedAt, sessionSalt: 1)
        try expect(!state.updateElapsed(at: startedAt.addingTimeInterval(299)), "The scan must continue before five minutes")
        try expect(state.updateElapsed(at: startedAt.addingTimeInterval(300)), "The scan must time out at five minutes")
        state.stop(at: startedAt.addingTimeInterval(300), reason: .timeout)

        try expect(state.elapsedSeconds == 300, "Elapsed time must stop at five minutes")
        try expect(state.lastStopReason == .timeout, "The timeout reason must be recorded")
        try expect(!state.isScanning, "A timed-out scan must be stopped")
    }

    private static func testStopOnViewDisappearance() throws {
        let startedAt = Date(timeIntervalSince1970: 4_000)
        var state = LibreWatchDiagnosticState()

        state.start(at: startedAt, sessionSalt: 1)
        state.stop(at: startedAt.addingTimeInterval(5), reason: .viewDisappeared)

        try expect(!state.isScanning, "Leaving the view must stop the scan")
        try expect(state.lastStopReason == .viewDisappeared, "The view-disappearance reason must be recorded")
    }

    private static func testNoCandidateResult() throws {
        let startedAt = Date(timeIntervalSince1970: 5_000)
        var state = LibreWatchDiagnosticState()

        state.start(at: startedAt, sessionSalt: 1)
        state.stop(at: startedAt.addingTimeInterval(12), reason: .user)

        try expect(
            state.resultText == "No candidate observed during this scan",
            "A scan without observations must use the non-conclusive no-candidate wording"
        )
    }

    private static func testCandidateObservedResult() throws {
        let startedAt = Date(timeIntervalSince1970: 6_000)
        var state = LibreWatchDiagnosticState()

        state.start(at: startedAt, sessionSalt: 1)
        state.recordCandidate(rawIdentifier: "candidate-b", rssi: -80, seenAt: startedAt.addingTimeInterval(1))
        state.stop(at: startedAt.addingTimeInterval(2), reason: .user)

        try expect(state.resultText == "FDE3 candidate observed", "A relevant observation must use candidate wording")
    }
}
