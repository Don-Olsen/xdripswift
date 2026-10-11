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


final class WatchTreatmentQueueRecoveryTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_800_000_000)

    private func queueURL() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchTreatmentQueueRecovery-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("queue.json")
    }

    private func bolus(id: UUID = UUID(), amount: Double = 2) -> WatchBolusOperation {
        WatchBolusOperation(operationID: id, insulinID: UUID(), carbsID: UUID(),
            recordedAt: when, insulinUnits: amount, carbohydrateGrams: 30,
            mealKindRaw: "slow", pizzaReminderRequested: false,
            manualWithoutCurrentSuggestion: true, penStepUnits: 0.5,
            maximumUnits: 25, profileSignature: "synthetic-profile")
    }

    func testReceiptWriteFailureRecoversSameDurableOperationWithoutDuplicates() throws {
        let url = try queueURL()
        let operation = bolus()
        try WatchManualTreatmentQueue.persistBolusOperations([operation], to: url)
        let root = url.deletingLastPathComponent()
        let temporarilyUnavailable = root.appendingPathExtension("unavailable")
        try FileManager.default.moveItem(at: root, to: temporarilyUnavailable)
        defer {
            if FileManager.default.fileExists(atPath: temporarilyUnavailable.path) {
                try? FileManager.default.moveItem(at: temporarilyUnavailable, to: root)
            }
        }
        // Acknowledged on iPhone, but the Watch cannot commit removal from its queue.
        XCTAssertThrowsError(try WatchManualTreatmentQueue.persistBolusOperations([], to: url))
        XCTAssertThrowsError(try WatchManualTreatmentQueue.recover(
            manualTreatments: [], bolusOperations: [operation], from: url))
        try FileManager.default.moveItem(at: temporarilyUnavailable, to: root)
        let recovered = try WatchManualTreatmentQueue.recover(
            manualTreatments: [], bolusOperations: [operation], from: url)
        XCTAssertEqual(recovered.bolusOperations, [operation])
        XCTAssertEqual(try WatchManualTreatmentQueue.loadBolusOperations(from: url), [operation])
        // A repeated durable receipt can now remove precisely the same operation.
        try WatchManualTreatmentQueue.persistBolusOperations([], to: url)
        XCTAssertTrue(try WatchManualTreatmentQueue.loadBolusOperations(from: url).isEmpty)
    }

    func testFailedNewLogDoesNotReplaceEarlierDurableQueue() throws {
        let url = try queueURL()
        let prior = bolus()
        let new = bolus()
        try WatchManualTreatmentQueue.persistBolusOperations([prior], to: url)
        let root = url.deletingLastPathComponent()
        let temporarilyUnavailable = root.appendingPathExtension("unavailable")
        try FileManager.default.moveItem(at: root, to: temporarilyUnavailable)
        defer {
            if FileManager.default.fileExists(atPath: temporarilyUnavailable.path) {
                try? FileManager.default.moveItem(at: temporarilyUnavailable, to: root)
            }
        }
        XCTAssertThrowsError(try WatchManualTreatmentQueue.persistBolusOperations([prior, new], to: url))
        try FileManager.default.moveItem(at: temporarilyUnavailable, to: root)
        // The user-confirmed candidate retains its identity even if the first write
        // failed before reaching disk. Recovery must preserve the earlier entry too.
        let recovered = try WatchManualTreatmentQueue.recover(
            manualTreatments: [], bolusOperations: [prior, new], from: url)
        XCTAssertEqual(recovered.bolusOperations, [prior, new])
        XCTAssertEqual(try WatchManualTreatmentQueue.loadBolusOperations(from: url), [prior, new])
    }

    func testUncertainNewWriteIsRecoveredFromDiskWithFrozenIdentityAndContent() throws {
        let url = try queueURL()
        let prior = bolus()
        let new = bolus()
        // An atomic write may have landed before its final file-handle check failed.
        try WatchManualTreatmentQueue.persistBolusOperations([prior, new], to: url)
        let recovered = try WatchManualTreatmentQueue.recover(
            manualTreatments: [], bolusOperations: [prior], from: url)
        XCTAssertEqual(recovered.bolusOperations, [prior, new])
        XCTAssertEqual(recovered.bolusOperations.last?.recordedAt, when)
        XCTAssertEqual(recovered.bolusOperations.last?.mealKindRaw, "slow")
        XCTAssertEqual(recovered.bolusOperations.last?.pizzaReminderRequested, false)
        XCTAssertEqual(try WatchManualTreatmentQueue.recover(manualTreatments: [],
            bolusOperations: recovered.bolusOperations, from: url).bolusOperations, [prior, new])
    }

    func testUncertainAppendAndOlderReceiptKeepTheFrozenOperationExactlyOnce() throws {
        let url = try queueURL()
        let prior = bolus()
        let frozen = bolus()
        // Atomic write landed, but its final check and immediate recovery failed.
        // The frozen candidate must participate in recovery before an older receipt writes.
        try WatchManualTreatmentQueue.persistBolusOperations([prior, frozen], to: url)
        let recovered = try WatchManualTreatmentQueue.recover(
            manualTreatments: [], bolusOperations: [prior, frozen], from: url)
        XCTAssertEqual(recovered.bolusOperations, [prior, frozen])
        let remaining = recovered.bolusOperations.filter { $0.id != prior.id }
        try WatchManualTreatmentQueue.persistBolusOperations(remaining, to: url)
        XCTAssertEqual(try WatchManualTreatmentQueue.loadBolusOperations(from: url), [frozen])
        let retry = try WatchManualTreatmentQueue.recover(
            manualTreatments: [], bolusOperations: remaining, from: url)
        XCTAssertEqual(retry.bolusOperations, [frozen])
        XCTAssertEqual(retry.bolusOperations.first?.insulinID, frozen.insulinID)
        XCTAssertEqual(retry.bolusOperations.first?.carbsID, frozen.carbsID)
        XCTAssertEqual(retry.bolusOperations.first?.recordedAt, frozen.recordedAt)
    }

    func testLegacyUncertainAppendSurvivesOlderManualReceipt() throws {
        let url = try queueURL()
        let prior = WatchManualTreatment(id: UUID(), recordedAt: when,
            kind: .insulin, amount: 1.5)
        let frozen = WatchManualTreatment(id: UUID(), recordedAt: when,
            kind: .basalInjection, amount: 20)
        try WatchManualTreatmentQueue.persist([prior, frozen], to: url)
        let recovered = try WatchManualTreatmentQueue.recover(
            manualTreatments: [prior, frozen], bolusOperations: [], from: url)
        let receipt = try XCTUnwrap(WatchManualTreatmentReceipt([
            WatchManualTreatmentMessageKey.treatmentID: prior.id.uuidString,
            WatchManualTreatmentMessageKey.stored: true]))
        try WatchManualTreatmentQueue.persist(WatchManualTreatmentQueue.applying(receipt,
            to: recovered.manualTreatments), to: url)
        XCTAssertEqual(try WatchManualTreatmentQueue.load(from: url), [frozen])
    }

    func testInterruptedReceiptWriteRetainsKnownPendingOperationUntilReceiptCanRepeat() throws {
        let url = try queueURL()
        let prior = bolus()
        // File has the new empty contents, while a final write check left memory pending.
        try WatchManualTreatmentQueue.persistBolusOperations([], to: url)
        let recovered = try WatchManualTreatmentQueue.recover(
            manualTreatments: [], bolusOperations: [prior], from: url)
        XCTAssertEqual(recovered.bolusOperations, [prior])
        XCTAssertEqual(try WatchManualTreatmentQueue.loadBolusOperations(from: url), [prior])
    }

    func testLegacyBasalAndCombinedOperationsRecoverTogetherAndKeepSeparateReceipts() throws {
        let url = try queueURL()
        let basal = WatchManualTreatment(id: UUID(), recordedAt: when,
            kind: .basalInjection, amount: 20)
        let legacyInsulin = WatchManualTreatment(id: UUID(), recordedAt: when,
            kind: .insulin, amount: 1.5)
        let operation = bolus()
        try WatchManualTreatmentQueue.persist([basal, legacyInsulin], to: url)
        try WatchManualTreatmentQueue.persistBolusOperations([operation], to: url)
        let recovered = try WatchManualTreatmentQueue.recover(
            manualTreatments: [basal, legacyInsulin], bolusOperations: [operation], from: url)
        XCTAssertEqual(recovered.manualTreatments, [basal, legacyInsulin])
        XCTAssertEqual(recovered.bolusOperations, [operation])
        let receipt = try XCTUnwrap(WatchManualTreatmentReceipt([
            WatchManualTreatmentMessageKey.treatmentID: basal.id.uuidString,
            WatchManualTreatmentMessageKey.stored: true]))
        try WatchManualTreatmentQueue.persist(WatchManualTreatmentQueue.applying(receipt,
            to: recovered.manualTreatments), to: url)
        XCTAssertEqual(try WatchManualTreatmentQueue.load(from: url), [legacyInsulin])
        XCTAssertEqual(try WatchManualTreatmentQueue.loadBolusOperations(from: url), [operation])
    }

    func testUnknownCorruptOrFutureQueueRemainsBlockedAndByteIdentical() throws {
        let url = try queueURL()
        let operation = bolus()
        let unknownLegacy = Data("[{\"id\":\"\(UUID())\",\"recordedAt\":0,\"kind\":\"futureKind\",\"amount\":1}]".utf8)
        let future = Data("{\"version\":99,\"manualTreatments\":[],\"bolusOperations\":[]}".utf8)
        for data in [unknownLegacy, future, Data("interrupted json".utf8)] {
            try data.write(to: url)
            XCTAssertThrowsError(try WatchManualTreatmentQueue.recover(
                manualTreatments: [], bolusOperations: [operation], from: url))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testConflictingUUIDInMemoryOrOnDiskCannotBeReconciled() throws {
        let url = try queueURL()
        let id = UUID()
        let prior = bolus(id: id)
        let conflict = bolus(id: id, amount: 3)
        try WatchManualTreatmentQueue.persistBolusOperations([prior], to: url)
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try WatchManualTreatmentQueue.recover(
            manualTreatments: [], bolusOperations: [conflict], from: url))
        XCTAssertEqual(try Data(contentsOf: url), original)
        try WatchManualTreatmentQueue.persistBolusOperations([prior, conflict], to: url)
        let conflictingFile = try Data(contentsOf: url)
        XCTAssertThrowsError(try WatchManualTreatmentQueue.recover(
            manualTreatments: [], bolusOperations: [], from: url))
        XCTAssertEqual(try Data(contentsOf: url), conflictingFile)
    }
}
