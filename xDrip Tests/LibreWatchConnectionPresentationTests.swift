import XCTest
@testable import xdrip

final class LibreWatchConnectionPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func presentation(ownership: LibreWatchOwnership = .watch,
                              stage: LibreWatchDirectStage = .receiving,
                              age: TimeInterval? = 60,
                              isCurrent: Bool = true) -> LibreWatchConnectionPresentation {
        LibreWatchConnectionPresentation(ownership: ownership, stage: stage,
            directReadingAt: age.map { now.addingTimeInterval(-$0) },
            directReadingIsCurrent: isCurrent, at: now)
    }

    func testNormalMinuteOldReadingRemainsConnectedAndHealthy() {
        let value = presentation(age: 61)
        XCTAssertEqual(value.connection, .connected)
        XCTAssertEqual(value.reading, .current)
        XCTAssertEqual(value.readingAge, 61)
        XCTAssertEqual(value.emphasis, .healthy)
    }

    func testStaleMeasurementDoesNotInventBluetoothReconnection() {
        let value = presentation(age: 8 * 60, isCurrent: false)
        XCTAssertEqual(value.connection, .connected)
        XCTAssertEqual(value.reading, .stale)
        XCTAssertEqual(value.readingAge, 8 * 60)
        XCTAssertEqual(value.emphasis, .attention)
    }

    func testPendingReconnectionIsVisibleEvenWhenLastReadingIsStillCurrent() {
        let value = presentation(stage: .reconnecting, age: 30)
        XCTAssertEqual(value.connection, .reconnecting)
        XCTAssertEqual(value.reading, .current)
        XCTAssertEqual(value.emphasis, .attention)
    }

    func testSevenMinuteReconnectionKeepsLastMeasurementAge() {
        let first = presentation(stage: .reconnecting, age: 60)
        let later = LibreWatchConnectionPresentation(ownership: .watch, stage: .reconnecting,
            directReadingAt: now.addingTimeInterval(-60), directReadingIsCurrent: false,
            at: now.addingTimeInterval(7 * 60))
        XCTAssertEqual(first.connection, later.connection)
        XCTAssertEqual(later.readingAge, 8 * 60)
        XCTAssertEqual(later.reading, .stale)
        XCTAssertEqual(later.emphasis, .attention)
    }

    func testConnectedWithoutFinalReadingIsWaitingAndNeverHealthy() {
        // A phone reading or uncalibrated native frame is not a final direct Watch reading.
        let value = presentation(age: nil)
        XCTAssertEqual(value.connection, .connected)
        XCTAssertEqual(value.reading, .waiting)
        XCTAssertNil(value.readingAge)
        XCTAssertEqual(value.emphasis, .attention)
    }

    func testFreshReadingCannotHideFailedOrReturningConnection() {
        XCTAssertEqual(presentation(stage: .failed).connection, .failed)
        XCTAssertEqual(presentation(stage: .failed).emphasis, .failure)
        XCTAssertEqual(presentation(stage: .returningToPhone).connection, .returningToPhone)
        XCTAssertEqual(presentation(stage: .returningToPhone).emphasis, .attention)
    }

    func testPhoneOwnershipDiscardsRetainedCollectorAndDirectReadingState() {
        for stage in [LibreWatchDirectStage.receiving, .reconnecting, .failed] {
            let value = presentation(ownership: .iphone, stage: stage, age: 8 * 60, isCurrent: false)
            XCTAssertEqual(value.connection, .phone)
            XCTAssertEqual(value.reading, .notDirect)
            XCTAssertNil(value.readingAge)
            XCTAssertEqual(value.emphasis, .neutral)
        }
    }

    func testOwnershipTransitionsOverrideCollectorState() {
        for (ownership, expected) in [
            (LibreWatchOwnership.releasingToWatch, LibreWatchConnectionPresentation.Connection.takingOver),
            (.releasingToPhone, .returningToPhone), (.recovery, .failed)
        ] {
            let value = presentation(ownership: ownership)
            XCTAssertEqual(value.connection, expected)
            XCTAssertEqual(value.reading, .notDirect)
            XCTAssertNil(value.readingAge)
        }
    }

    func testUnconfiguredSessionDoesNotClaimPhoneHasSensor() {
        let value = presentation(ownership: .iphone, stage: .unavailable, age: nil)
        XCTAssertEqual(value.connection, .unavailable)
        XCTAssertEqual(value.reading, .notDirect)
        XCTAssertNil(value.readingAge)
    }

    func testNewTakeoverDistinguishesFirstConnectionFromRecovery() {
        XCTAssertEqual(presentation(stage: .scanning, age: nil).connection, .searching)
        XCTAssertEqual(presentation(stage: .connecting, age: nil).connection, .connecting)
        XCTAssertEqual(presentation(stage: .scanning, age: 120).connection, .reconnecting)
        XCTAssertEqual(presentation(stage: .connecting, age: 120).connection, .reconnecting)
        XCTAssertEqual(presentation(stage: .unavailable, age: nil).connection, .unavailable)
    }
}
