import XCTest
@testable import xdrip

final class WatchSnapshotSemanticsTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)
    private func fixtures() -> (LibreWatchDirectSession, LibreWatchCalibrationSnapshot, LibreWatchAlarmSettings) {
        let session = LibreWatchDirectSession(createdAt: date, sensorUID: Data([1,2,3,4,5,6,7,8]),
            patchInfo: Data([0,1,2,3,4,5]), sensorSerialNumber: "TEST-SENSOR", sensorTypeRawValue: "7F",
            expectedPeripheralName: "AABBCCDDEEFF", unlockCode: 1000, unlockCount: 4,
            algorithmParameters: LibreWatchAlgorithmParameters(slopeSlope: 0, slopeOffset: 0,
                offsetSlope: 0.1, offsetOffset: 0, extraSlope: 1, extraOffset: 0, sensorSerialNumber: "TEST-SENSOR"))
        let calibration = LibreWatchCalibrationSnapshot(activeSensorID: "test", sensorUID: session.sensorUID,
            sensorSerialNumber: session.sensorSerialNumber, watchSessionID: session.id,
            calibrationType: .factoryCalibrated, slope: 1, intercept: 0, rawValueDivider: 1, calibratedAt: date, revision: 1)
        let settings = LibreWatchAlarmSettings(sessionID: session.id, sensorIdentity: session.redactedIdentity(),
            revision: 1, generatedAt: date, isMgDl: true,
            rules: [LibreWatchAlarmRule(kind: .missed, startMinute: 0, value: 5, enabled: true,
                snoozeMinutes: 15, allowsSnooze: true, soundEnabled: true, vibrate: true, title: "Test")],
            snoozes: [], snoozeAllUntil: nil)
        return (session, calibration, settings)
    }

    func testOrdinaryRefreshAndRestartReuseHandoffRevision() throws {
        let name = "WatchSnapshotSemanticsTests.\(UUID())"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let (session, calibration, settings) = fixtures()
        let cache = LibreWatchHandoffSnapshotCache(defaults: defaults)
        let first = try XCTUnwrap(cache.resolve(session: session, calibration: calibration, ownership: .watch,
            settings: settings, delegation: .confirmed(for: settings), at: date))
        var later = settings; later.generatedAt = date.addingTimeInterval(60)
        for _ in 0..<100 {
            XCTAssertEqual(cache.resolve(session: session, calibration: calibration, ownership: .watch,
                settings: later, delegation: .confirmed(for: settings), at: date.addingTimeInterval(60)), first)
        }
        let restored = LibreWatchHandoffSnapshotCache(defaults: defaults)
        XCTAssertEqual(restored.resolve(session: session, calibration: calibration, ownership: .watch,
            settings: later, delegation: .confirmed(for: settings), at: date.addingTimeInterval(60)), first)
        XCTAssertEqual(LibreWatchSessionStore.loadHandoffRevision(defaults: defaults), first.revision)
    }

    func testRealOwnerUnlockCalibrationAndAlarmChangesAdvanceAuthority() throws {
        let name = "WatchSnapshotSemanticsTests.\(UUID())"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var (session, calibration, settings) = fixtures()
        let cache = LibreWatchHandoffSnapshotCache(defaults: defaults)
        let initial = try XCTUnwrap(cache.resolve(session: session, calibration: calibration, ownership: .iphone,
            settings: settings, delegation: nil, at: date))
        let owner = try XCTUnwrap(cache.resolve(session: session, calibration: calibration, ownership: .watch,
            settings: settings, delegation: .confirmed(for: settings), at: date))
        XCTAssertGreaterThan(owner.revision, initial.revision)
        session.unlockCount += 1
        let unlock = try XCTUnwrap(cache.resolve(session: session, calibration: calibration, ownership: .watch,
            settings: settings, delegation: .confirmed(for: settings), at: date))
        XCTAssertGreaterThan(unlock.revision, owner.revision)
        calibration = LibreWatchCalibrationSnapshot(activeSensorID: calibration.activeSensorID,
            sensorUID: calibration.sensorUID, sensorSerialNumber: calibration.sensorSerialNumber,
            watchSessionID: session.id, calibrationType: .factoryCalibrated, slope: 1,
            intercept: 0, rawValueDivider: 1, calibratedAt: date, revision: 2)
        let calibrated = try XCTUnwrap(cache.resolve(session: session, calibration: calibration, ownership: .watch,
            settings: settings, delegation: .confirmed(for: settings), at: date))
        XCTAssertGreaterThan(calibrated.revision, unlock.revision)
        settings.revision += 1
        let alarm = try XCTUnwrap(cache.resolve(session: session, calibration: calibration, ownership: .watch,
            settings: settings, delegation: .confirmed(for: settings), at: date))
        XCTAssertGreaterThan(alarm.revision, calibrated.revision)
        XCTAssertNil(cache.current(session: session, calibration: calibration, ownership: .iphone,
            delegation: .confirmed(for: settings)))
    }

    func testInvalidControlSnapshotDoesNotConsumeRevision() {
        let name = "WatchSnapshotSemanticsTests.\(UUID())"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let (session, _, settings) = fixtures()
        let cache = LibreWatchHandoffSnapshotCache(defaults: defaults)
        XCTAssertNil(cache.resolve(session: session, calibration: nil, ownership: .watch,
            settings: settings, delegation: nil, at: date))
        XCTAssertEqual(LibreWatchSessionStore.loadHandoffRevision(defaults: defaults), 0)
    }

    func testContentIdentityIgnoresTransportTimeButDetectsSensorAndClinicalChanges() {
        var payload: [String: Any] = ["generatedAt": 1.0, "sensorAgeInMinutes": 2.0,
            "sensorStartedAt": 100.0, "bgReadingDatesAsDouble": [200.0], "bgReadingValues": [110.0]]
        let first = WatchPhoneRefreshService.contentID(payload, scope: "test")
        payload["generatedAt"] = 999.0; payload["sensorAgeInMinutes"] = 999.0
        XCTAssertEqual(WatchPhoneRefreshService.contentID(payload, scope: "test"), first)
        payload["bgReadingValues"] = [111.0]
        XCTAssertNotEqual(WatchPhoneRefreshService.contentID(payload, scope: "test"), first)
        XCTAssertNotEqual(WatchPhoneRefreshService.contentID(payload, scope: "new-session"), first)
    }

    func testRevalidationKeepsMeasurementTimeAndRejectsSameRevisionChangedContent() throws {
        let name = "WatchSnapshotSemanticsTests.\(UUID())"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let measured = date.addingTimeInterval(-120).timeIntervalSince1970
        let generation = WatchPhoneSnapshotStore.nextGeneration(sessionID: nil, at: date, defaults: defaults)
        var payload = WatchPhoneSnapshotStore.attaching(generation, to: ["generatedAt": date.timeIntervalSince1970,
            "snapshotValidatedAt": date.timeIntervalSince1970, "snapshotContentID": "test-content",
            "bgReadingDatesAsDouble": [measured], "bgReadingValues": [110.0], "slopeOrdinal": 1,
            "deltaValueInUserUnit": 0.0])
        XCTAssertTrue(WatchPhoneSnapshotStore.accept(payload, stream: .bgReadings, sessionID: nil, at: date, defaults: defaults))
        payload["snapshotValidatedAt"] = date.addingTimeInterval(60).timeIntervalSince1970
        XCTAssertTrue(WatchPhoneSnapshotStore.accept(payload, stream: .bgReadings, sessionID: nil,
            at: date.addingTimeInterval(60), defaults: defaults))
        XCTAssertEqual(WatchPhoneSnapshotStore.stored(.bgReadings, defaults: defaults)?["bgReadingDatesAsDouble"] as? [Double], [measured])
        payload["snapshotValidatedAt"] = date.addingTimeInterval(120).timeIntervalSince1970
        payload["bgReadingValues"] = [200.0]
        XCTAssertFalse(WatchPhoneSnapshotStore.accept(payload, stream: .bgReadings, sessionID: nil,
            at: date.addingTimeInterval(120), defaults: defaults))
        payload["bgReadingValues"] = [110.0]
        payload["snapshotValidatedAt"] = date.addingTimeInterval(4000).timeIntervalSince1970
        XCTAssertFalse(WatchPhoneSnapshotStore.isValid(payload, stream: .bgReadings, sessionID: nil, at: date.addingTimeInterval(4000)))
    }

    func testPartialContextMergePreservesControlAndOtherStreamContentIDs() {
        let original: [String: Any] = ["session": Data([1]), "calibration": Data([2]),
            "alarm": Data([3]), "bgReadings": ["value": 100], "contentIDs": ["bgReadings": "graph1"]]
        let merged = WatchPhoneRefreshService.merging(["status": ["value": 1], "contentIDs": ["status": "status1"]], into: original)
        XCTAssertEqual(merged["session"] as? Data, Data([1]))
        XCTAssertEqual(merged["calibration"] as? Data, Data([2]))
        XCTAssertEqual(merged["alarm"] as? Data, Data([3]))
        XCTAssertEqual(merged["contentIDs"] as? [String: String], ["bgReadings": "graph1", "status": "status1"])
    }
}
