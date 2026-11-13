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

    @MainActor func testPhoneUsesOnlyExplicitWatchHighSnoozeAndKeepsOriginalDeadline() throws {
        let suite = "WatchHighSnooze." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let manager = AlertManager(coreDataManager: core, soundPlayer: nil, silenceDefaults: defaults)
        let (session, _, _) = fixtures()
        var state = LibreWatchAlarmState(sessionID: session.id, sensorIdentity: session.redactedIdentity())
        let expiry = date.addingTimeInterval(1800)
        state.recordAutomaticThrottle(.high, readingID: UUID(), until: expiry)
        AlertManager.applyLibreWatchAlarmState(state, session: session, coreDataManager: core,
            silenceDefaults: defaults, now: date)
        XCTAssertNil(SelectiveAlarmSilence.until(defaults: defaults), "An alarm ringing is not a user snooze")
        state.snoozeFromUser(.high, until: expiry, at: date)
        let transported = try JSONDecoder().decode(LibreWatchAlarmState.self, from: JSONEncoder().encode(state))
        AlertManager.applyLibreWatchAlarmState(transported, session: session, coreDataManager: core,
            silenceDefaults: defaults, now: date.addingTimeInterval(120))
        XCTAssertEqual(SelectiveAlarmSilence.until(defaults: defaults), expiry, "Receipt time cannot extend the pause")
        XCTAssertTrue(SelectiveAlarmSilence.suppresses(.veryhigh, at: date, defaults: defaults))
        for kind in [AlertKind.low, .verylow, .lowSoon, .missedreading, .sensorTransmitterFailure] {
            XCTAssertFalse(SelectiveAlarmSilence.suppresses(kind, at: date, defaults: defaults))
            XCTAssertEqual(manager.getSnoozeParameters(alertKind: kind).snoozePeriodInMinutes, 0)
        }
        let revision = SelectiveAlarmSilence.revision(defaults: defaults)
        AlertManager.applyLibreWatchAlarmState(transported, session: session, coreDataManager: core,
            silenceDefaults: defaults, now: date.addingTimeInterval(180))
        XCTAssertEqual(SelectiveAlarmSilence.revision(defaults: defaults), revision)
        XCTAssertFalse(SelectiveAlarmSilence.isActive(at: expiry, defaults: defaults))
    }

    @MainActor func testPhoneEndAndRestartRejectReplayedAndOlderUnseenWatchHighSnoozes() throws {
        let suite = "WatchHighSnoozeReplay." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = LibreWatchUserHighSnooze(id: UUID(), requestedAt: date,
            until: date.addingTimeInterval(1800))
        SelectiveAlarmSilence.applyWatchSnooze(original, at: date, defaults: defaults)
        SelectiveAlarmSilence.end(at: date.addingTimeInterval(120), defaults: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        let endedRevision = SelectiveAlarmSilence.revision(defaults: reopened)
        let unseenOlder = LibreWatchUserHighSnooze(id: UUID(), requestedAt: date.addingTimeInterval(60),
            until: date.addingTimeInterval(3600))
        for request in [original, unseenOlder] {
            SelectiveAlarmSilence.applyWatchSnooze(request, at: date.addingTimeInterval(180), defaults: reopened)
            XCTAssertNil(SelectiveAlarmSilence.until(defaults: reopened))
            XCTAssertEqual(SelectiveAlarmSilence.revision(defaults: reopened), endedRevision)
        }
        let fresh = LibreWatchUserHighSnooze(id: UUID(), requestedAt: date.addingTimeInterval(181),
            until: date.addingTimeInterval(1200))
        SelectiveAlarmSilence.applyWatchSnooze(fresh, at: fresh.requestedAt, defaults: reopened)
        XCTAssertEqual(SelectiveAlarmSilence.until(defaults: reopened), fresh.until)
        SelectiveAlarmSilence.applyWatchSnooze(original, at: fresh.requestedAt, defaults: reopened)
        XCTAssertEqual(SelectiveAlarmSilence.until(defaults: reopened), fresh.until)
    }

    @MainActor func testPhoneRejectsInvalidExpiredAndFutureWatchHighSnoozeRequests() throws {
        let suite = "WatchHighSnoozeInvalid." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let intervals: [(Date, Date)] = [
            (date.addingTimeInterval(-1800), date),
            (date.addingTimeInterval(1), date.addingTimeInterval(601)),
            (date, date), (date, date.addingTimeInterval(-1)),
            (date, date.addingTimeInterval(7 * 24 * 3600 + 1)),
            (Date(timeIntervalSince1970: .nan), date.addingTimeInterval(60)),
            (date, Date(timeIntervalSince1970: .infinity))
        ]
        for (start, end) in intervals {
            let request = LibreWatchUserHighSnooze(id: UUID(), requestedAt: start, until: end)
            SelectiveAlarmSilence.applyWatchSnooze(request, at: date, defaults: defaults)
            XCTAssertNil(defaults.object(forKey: SelectiveAlarmSilence.stateKey))
        }
    }

    @MainActor func testWatchReceiptRequiresMatchingSessionAndDoesNotShortenExistingSilence() throws {
        let suite = "WatchHighSnoozeSession." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let (session, _, _) = fixtures()
        var state = LibreWatchAlarmState(sessionID: UUID(), sensorIdentity: session.redactedIdentity())
        state.snoozeFromUser(.veryHigh, until: date.addingTimeInterval(900), at: date)
        AlertManager.applyLibreWatchAlarmState(state, session: session, coreDataManager: core,
            silenceDefaults: defaults, now: date)
        XCTAssertNil(SelectiveAlarmSilence.until(defaults: defaults))
        state.sessionID = session.id; state.sensorIdentity = "other-sensor"
        AlertManager.applyLibreWatchAlarmState(state, session: session, coreDataManager: core,
            silenceDefaults: defaults, now: date)
        XCTAssertNil(SelectiveAlarmSilence.until(defaults: defaults))
        state.sensorIdentity = session.redactedIdentity()
        let longer = date.addingTimeInterval(3600)
        SelectiveAlarmSilence.start(until: longer, at: date.addingTimeInterval(-1), defaults: defaults)
        AlertManager.applyLibreWatchAlarmState(state, session: session, coreDataManager: core,
            silenceDefaults: defaults, now: date)
        XCTAssertEqual(SelectiveAlarmSilence.until(defaults: defaults), longer)
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


final class WatchBolusLogCompletionTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_800_000_000)

    private func operation(carbs: Double = 30, insulin: Double = 2.5,
                           at date: Date? = nil) -> WatchBolusOperation {
        WatchBolusOperation(operationID: UUID(), insulinID: UUID(), carbsID: UUID(),
            recordedAt: date ?? when, insulinUnits: insulin, carbohydrateGrams: carbs,
            mealKindRaw: "normal", pizzaReminderRequested: false,
            manualWithoutCurrentSuggestion: true, penStepUnits: 0.5,
            maximumUnits: 25, profileSignature: "synthetic-profile")
    }

    func testDurableSuccessFinishesExactCombinedDraftAndRetainsReceipt() throws {
        let prior = operation()
        let submitted = operation()
        var carbs = 30.0, insulin = 2.5
        let receipt = try XCTUnwrap(WatchBolusLogCompletion.finish(didStore: true, at: when,
            previouslyPendingIDs: [prior.id], pending: [prior, submitted],
            submitted: (30, 2.5, "normal"), carbohydrateGrams: &carbs, insulinUnits: &insulin, mealKindRaw: "normal"))
        XCTAssertEqual(carbs, 0)
        XCTAssertEqual(insulin, 0)
        XCTAssertEqual(receipt.operation, submitted)
        XCTAssertEqual(receipt.operation.recordedAt, when)
        XCTAssertFalse(receipt.isStoredOnPhone, "Durable Watch storage is not an iPhone receipt")
        XCTAssertTrue(receipt.amountText.contains("30 g"))
        XCTAssertTrue(receipt.amountText.contains(" E"))
    }

    func testCarbohydrateOnlyAndInsulinOnlyDraftsFinishWithoutInventingOtherQuantity() throws {
        for (carbsValue, insulinValue) in [(30.0, 0.0), (0.0, 2.5)] {
            let submitted = operation(carbs: carbsValue, insulin: insulinValue)
            var carbs = carbsValue, insulin = insulinValue
            let receipt = try XCTUnwrap(WatchBolusLogCompletion.finish(didStore: true, at: when,
                previouslyPendingIDs: [], pending: [submitted],
                submitted: (carbsValue, insulinValue, "normal"),
                carbohydrateGrams: &carbs, insulinUnits: &insulin, mealKindRaw: "normal"))
            XCTAssertEqual(carbs, 0)
            XCTAssertEqual(insulin, 0)
            XCTAssertFalse(receipt.amountText.contains(" og "))
            XCTAssertEqual(receipt.operation.carbohydrateGrams, carbsValue)
            XCTAssertEqual(receipt.operation.insulinUnits, insulinValue)
        }
    }

    func testFailedOrUncertainWritePreservesDraftEvenIfOperationAppearsInRecoveredQueue() {
        for pending in [[], [operation()]] {
            var carbs = 30.0, insulin = 2.5
            XCTAssertNil(WatchBolusLogCompletion.finish(didStore: false, at: when,
                previouslyPendingIDs: [], pending: pending,
                submitted: (30, 2.5, "normal"), carbohydrateGrams: &carbs, insulinUnits: &insulin, mealKindRaw: "normal"))
            XCTAssertEqual(carbs, 30)
            XCTAssertEqual(insulin, 2.5)
        }
    }

    func testSynchronousVerifiedRecoveryUsesActualFrozenOperation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchBolusCompletion-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("queue.json")
        let prior = operation(at: when.addingTimeInterval(-60))
        let submitted = operation()
        // Atomic append landed before a final write check failed. The production queue
        // recovers the same IDs and content, and the UI receives a verified true result.
        try WatchManualTreatmentQueue.persistBolusOperations([prior, submitted], to: url)
        let recovered = try WatchManualTreatmentQueue.recover(manualTreatments: [],
            bolusOperations: [prior, submitted], from: url)
        var carbs = 30.0, insulin = 2.5
        let receipt = try XCTUnwrap(WatchBolusLogCompletion.finish(didStore: true, at: when,
            previouslyPendingIDs: [prior.id], pending: recovered.bolusOperations,
            submitted: (30, 2.5, "normal"), carbohydrateGrams: &carbs, insulinUnits: &insulin, mealKindRaw: "normal"))
        XCTAssertEqual(receipt.operation, submitted)
        XCTAssertEqual(carbs, 0)
        XCTAssertEqual(insulin, 0)
        XCTAssertEqual(try WatchManualTreatmentQueue.loadBolusOperations(from: url), [prior, submitted])
    }

    func testOldSameAmountsWrongTimeAndAmbiguousOperationsNeverFinishDraft() {
        let prior = operation()
        let differentTime = operation(at: when.addingTimeInterval(-60))
        for (ids, pending) in [(Set([prior.id]), [prior]), (Set<UUID>(), [differentTime]),
                               (Set<UUID>(), [operation(), operation()]), (Set<UUID>(), [])] {
            var carbs = 30.0, insulin = 2.5
            XCTAssertNil(WatchBolusLogCompletion.finish(didStore: true, at: when,
                previouslyPendingIDs: ids, pending: pending,
                submitted: (30, 2.5, "normal"), carbohydrateGrams: &carbs, insulinUnits: &insulin, mealKindRaw: "normal"))
            XCTAssertEqual(carbs, 30)
            XCTAssertEqual(insulin, 2.5)
        }
    }

    func testChangedDraftKeepsItsInputsButGetsTheExactStoredConfirmation() throws {
        let submitted = operation()
        var carbs = 40.0, insulin = 3.0
        let receipt = try XCTUnwrap(WatchBolusLogCompletion.finish(didStore: true, at: when,
            previouslyPendingIDs: [], pending: [submitted],
            submitted: (30, 2.5, "normal"), carbohydrateGrams: &carbs, insulinUnits: &insulin, mealKindRaw: "slow"))
        XCTAssertEqual(receipt.operation, submitted)
        XCTAssertEqual(carbs, 40)
        XCTAssertEqual(insulin, 3)
    }

    func testDelayedReceiptOnlyConfirmsExactOperationAndLeavesNewDraftAlone() throws {
        let submitted = operation()
        var carbs = 30.0, insulin = 2.5
        var receipt = try XCTUnwrap(WatchBolusLogCompletion.finish(didStore: true, at: when,
            previouslyPendingIDs: [], pending: [submitted],
            submitted: (30, 2.5, "normal"), carbohydrateGrams: &carbs, insulinUnits: &insulin, mealKindRaw: "normal"))
        carbs = 45; insulin = 4
        receipt.acceptPhoneConfirmation(operation()) // same amounts, different identity
        XCTAssertFalse(receipt.isStoredOnPhone)
        receipt.acceptPhoneConfirmation(submitted)
        XCTAssertTrue(receipt.isStoredOnPhone)
        receipt.acceptPhoneConfirmation(operation()) // a later receipt does not undo this one
        XCTAssertTrue(receipt.isStoredOnPhone)
        XCTAssertEqual(receipt.operation, submitted)
        XCTAssertEqual(carbs, 45)
        XCTAssertEqual(insulin, 4)
    }
}

final class WatchMealQuietTests: XCTestCase {
    private let when = Date(timeIntervalSince1970: 1_800_000_000)

    private func period(_ id: String = "meal-a", duration: TimeInterval = 1800) -> MealQuietPeriod {
        MealQuietPeriod(mealID: id, startedAt: when, until: when.addingTimeInterval(duration))
    }

    private func started() -> WatchMealQuietState {
        var value = WatchMealQuietState()
        value.apply(.init(revision: 1, period: period()), at: when)
        return value
    }

    private func settings(low: Double = 75, urgent: Double = 250, urgentEnabled: Bool = true) -> LibreWatchAlarmSettings {
        let rules: [(LibreWatchAlarmKind, Double)] = [(.veryLow, 55), (.low, low), (.high, 180), (.veryHigh, urgent), (.missed, 5)]
        return LibreWatchAlarmSettings(sessionID: UUID(), sensorIdentity: "synthetic-sensor",
            revision: 1, generatedAt: when, isMgDl: true,
            rules: rules.map { LibreWatchAlarmRule(kind: $0.0, startMinute: 0, value: $0.1,
                enabled: $0.0 == .veryHigh ? urgentEnabled : true, snoozeMinutes: 15, allowsSnooze: true,
                soundEnabled: true, vibrate: true, title: "Synthetic") },
            snoozes: [], snoozeAllUntil: nil)
    }

    func testPeriodRejectsMalformedDatesAndExpiresAtOriginalDeadline() {
        XCTAssertTrue(period().isActive(at: when))
        XCTAssertFalse(period().isActive(at: when.addingTimeInterval(-1)))
        XCTAssertFalse(period().isActive(at: when.addingTimeInterval(1800)))
        XCTAssertFalse(period(duration: 0).isActive(at: when))
        XCTAssertFalse(period(duration: 5401).isActive(at: when))
        XCTAssertTrue(period(duration: 3600).isActive(at: when))
        XCTAssertTrue(period(duration: 3601).isActive(at: when))
        XCTAssertTrue(period(duration: 5400).isActive(at: when))
        XCTAssertFalse(period("").isActive(at: when))
        XCTAssertFalse(MealQuietPeriod(mealID: "bad", startedAt: when,
            until: Date(timeIntervalSince1970: .infinity)).isActive(at: when))
    }

    func testNinetyMinutePeriodSurvivesSyncAndRestartWithExactOriginalExpiry() throws {
        let original = period(duration: 90 * 60)
        let payload = MealQuietSyncState(revision: 1, period: original)
        let received = try JSONDecoder().decode(MealQuietSyncState.self, from: JSONEncoder().encode(payload))
        var value = WatchMealQuietState()
        value.apply(received, at: when.addingTimeInterval(30))
        value = try JSONDecoder().decode(WatchMealQuietState.self, from: JSONEncoder().encode(value))
        let settings = settings()
        for seconds in [3600.0, 4200, 5399] {
            let now = when.addingTimeInterval(seconds)
            value.refreshLocalBasis(glucose: 200, measuredAt: now, settings: settings, at: now)
            XCTAssertEqual(value.activePeriod(at: now), original)
            XCTAssertTrue(value.suppresses(.high, at: now))
            for kind: LibreWatchAlarmKind in [.veryHigh, .veryLow, .low, .missed] {
                XCTAssertFalse(value.suppresses(kind, at: now))
            }
        }
        value.apply(.init(revision: 2, period: original), at: original.until.addingTimeInterval(-1))
        XCTAssertEqual(value.activePeriod(at: original.until.addingTimeInterval(-1)), original)
        value.apply(.init(revision: 3, period: original), at: original.until)
        XCTAssertNil(value.activePeriod(at: original.until))
        XCTAssertFalse(value.suppresses(.high, at: original.until))
        value = try JSONDecoder().decode(WatchMealQuietState.self, from: JSONEncoder().encode(value))
        XCTAssertNil(value.activePeriod(at: original.until.addingTimeInterval(1)))
        XCTAssertTrue(settings.snoozes.isEmpty)
    }

    func testNinetyMinuteLocalStopSurvivesRestartAndNewerPhoneReplay() throws {
        let original = period(duration: 90 * 60)
        let stoppedAt = when.addingTimeInterval(70 * 60)
        var value = WatchMealQuietState()
        value.apply(.init(revision: 1, period: original), at: when)
        XCTAssertEqual(value.activePeriod(at: stoppedAt), original)
        value.stop(at: stoppedAt)
        value = try JSONDecoder().decode(WatchMealQuietState.self, from: JSONEncoder().encode(value))
        let later = stoppedAt.addingTimeInterval(60)
        value.apply(.init(revision: 2, period: original), at: later)
        value.refreshLocalBasis(glucose: 200, measuredAt: later, settings: settings(), at: later)
        XCTAssertNil(value.activePeriod(at: later))
        XCTAssertFalse(value.suppresses(.high, at: later))
        XCTAssertEqual(value.stoppedUntil[original.mealID], original.until)
        XCTAssertEqual(value.pendingEndIDs, [original.mealID])
        value.apply(.init(revision: 3, period: nil), at: later)
        XCTAssertTrue(value.pendingEndIDs.isEmpty)
        value.apply(.init(revision: 2, period: original), at: later.addingTimeInterval(1))
        XCTAssertNil(value.activePeriod(at: later.addingTimeInterval(1)))
    }

    func testNinetyMinuteHighSuppressionPreservesUrgentHighAndLowDelivery() throws {
        let settings = settings()
        let now = when.addingTimeInterval(70 * 60)
        let unsafeReadings: [(Double, LibreWatchAlarmKind)] = [(50, .veryLow), (60, .low), (260, .veryHigh)]
        for (glucose, expected) in unsafeReadings {
            var alarms = LibreWatchAlarmState()
            alarms.use(settings)
            alarms.beginWatchOwnership(at: when)
            var quiet = WatchMealQuietState()
            quiet.apply(.init(revision: 1, period: period(duration: 90 * 60)), at: when)
            quiet.refreshLocalBasis(glucose: 200, measuredAt: now, settings: settings, at: now)
            let high = try XCTUnwrap(alarms.accept(id: UUID(), measuredAt: now, glucose: 200,
                settings: settings, delegation: .confirmed(for: settings), watchOwnsSensor: true, now: now))
            XCTAssertEqual(high.kind, .high)
            XCTAssertTrue(quiet.suppresses(high.kind, at: now))
            XCTAssertEqual(alarms.snoozedUntil(.high, settings: settings), .distantPast)
            XCTAssertNotNil(alarms.nextMissedAlarm(settings: settings, delegation: .confirmed(for: settings),
                watchOwnsSensor: true, now: now))
            let later = now.addingTimeInterval(60)
            quiet.refreshLocalBasis(glucose: glucose, measuredAt: later, settings: settings, at: later)
            let alarm = try XCTUnwrap(alarms.accept(id: UUID(), measuredAt: later, glucose: glucose,
                settings: settings, delegation: .confirmed(for: settings), watchOwnsSensor: true, now: later))
            XCTAssertEqual(alarm.kind, expected)
            XCTAssertFalse(quiet.suppresses(alarm.kind, at: later))
            XCTAssertNil(quiet.activePeriod(at: later))
            quiet.refreshLocalBasis(glucose: 200, measuredAt: later, settings: settings, at: later)
            XCTAssertNil(quiet.activePeriod(at: later), "A later safe reading cannot restart the stopped meal")
            XCTAssertEqual(quiet.pendingEndIDs, ["meal-a"])
        }
    }

    func testNinetyMinuteReadingGapStillEndsQuietAfterFirstHour() throws {
        let now = when.addingTimeInterval(70 * 60)
        var value = WatchMealQuietState()
        value.apply(.init(revision: 1, period: period(duration: 90 * 60)), at: when)
        value.observeReadingGap(previouslyMeasuredAt: now.addingTimeInterval(-180), at: now)
        XCTAssertNotNil(value.activePeriod(at: now))
        value.observeReadingGap(previouslyMeasuredAt: now.addingTimeInterval(-181), at: now)
        value = try JSONDecoder().decode(WatchMealQuietState.self, from: JSONEncoder().encode(value))
        value.refreshLocalBasis(glucose: 200, measuredAt: now, settings: settings(), at: now)
        XCTAssertNil(value.activePeriod(at: now))
        XCTAssertEqual(value.pendingEndIDs, ["meal-a"])
    }

    func testPhoneStopRejectsReorderedStartsAndSameRevisionConflicts() throws {
        var value = started()
        value.apply(.init(revision: 2, period: nil), at: when.addingTimeInterval(10))
        value = try JSONDecoder().decode(WatchMealQuietState.self, from: JSONEncoder().encode(value))
        value.apply(.init(revision: 1, period: period()), at: when.addingTimeInterval(20))
        value.apply(.init(revision: 2, period: period("conflict")), at: when.addingTimeInterval(20))
        XCTAssertNil(value.activePeriod(at: when.addingTimeInterval(20)))
        XCTAssertEqual(value.received?.revision, 2)
    }

    func testLocalStopSurvivesRestartAndNewerReplayButAllowsDifferentMeal() throws {
        var value = started()
        value.stop(at: when.addingTimeInterval(10))
        value = try JSONDecoder().decode(WatchMealQuietState.self, from: JSONEncoder().encode(value))
        value.apply(.init(revision: 2, period: period()), at: when.addingTimeInterval(20))
        XCTAssertNil(value.activePeriod(at: when.addingTimeInterval(20)))
        XCTAssertEqual(value.pendingEndIDs, ["meal-a"])
        value.apply(.init(revision: 3, period: period("meal-b")), at: when.addingTimeInterval(30))
        XCTAssertEqual(value.activePeriod(at: when.addingTimeInterval(30))?.mealID, "meal-b")
        XCTAssertTrue(value.pendingEndIDs.isEmpty, "Phone replaced the stopped meal; its stop receipt cannot end meal-b")
    }

    func testNewRevisionCannotExtendSameMealAfterOriginalExpiry() {
        var value = started()
        value.apply(.init(revision: 2, period: period(duration: 3600)), at: when.addingTimeInterval(1801))
        XCTAssertNil(value.activePeriod(at: when.addingTimeInterval(1801)))
        XCTAssertEqual(value.pendingEndIDs, ["meal-a"])
    }

    func testOfflineFreshReadingsKeepFixedExpiryAndNeverChangeSnooze() {
        var value = started()
        let settings = settings()
        for seconds in [60.0, 600, 1799] {
            let now = when.addingTimeInterval(seconds)
            value.refreshLocalBasis(glucose: 200, measuredAt: now, settings: settings, at: now)
            XCTAssertEqual(value.activePeriod(at: now), period())
        }
        XCTAssertTrue(settings.snoozes.isEmpty)
        XCTAssertNil(value.activePeriod(at: when.addingTimeInterval(1800)))
        XCTAssertFalse(value.suppresses(.high, at: when.addingTimeInterval(1800)))
    }

    func testLocalLowUrgentAndUnknownBasisAreTerminalEvenWithFreshLaterGlucose() {
        let settings = settings()
        let unsafe: [(Double?, Date?)] = [(60, when), (75, when), (250, when), (300, when),
            (nil, nil), (.nan, when), (100, when.addingTimeInterval(-181)),
            (100, when.addingTimeInterval(21))]
        for (glucose, measuredAt) in unsafe {
            var value = started()
            value.refreshLocalBasis(glucose: glucose, measuredAt: measuredAt, settings: settings, at: when)
            value.refreshLocalBasis(glucose: 100, measuredAt: when, settings: settings, at: when)
            XCTAssertNil(value.activePeriod(at: when), "Unsafe basis must not resume the same meal")
            XCTAssertEqual(value.pendingEndIDs, ["meal-a"])
        }
    }

    func testFreshReadingAfterSuspendedGapCannotRestartQuiet() {
        var value = started()
        let now = when.addingTimeInterval(181)
        value.observeReadingGap(previouslyMeasuredAt: when, at: now)
        value.refreshLocalBasis(glucose: 200, measuredAt: now, settings: settings(), at: now)
        XCTAssertNil(value.activePeriod(at: now))
        XCTAssertEqual(value.pendingEndIDs, ["meal-a"])
        var uninterrupted = started()
        uninterrupted.observeReadingGap(previouslyMeasuredAt: when, at: when.addingTimeInterval(180))
        XCTAssertNotNil(uninterrupted.activePeriod(at: when.addingTimeInterval(180)))
    }

    func testExistingCurrentLowFloorAppliesEvenWithLowerUserLowThreshold() {
        let settings = settings(low: 50)
        XCTAssertFalse(WatchMealQuietState.localBasisIsSafe(glucose: 65, measuredAt: when,
            settings: settings, at: when))
        XCTAssertTrue(WatchMealQuietState.localBasisIsSafe(glucose: 100, measuredAt: when,
            settings: settings, at: when))
    }

    func testDisabledOrInvalidUrgentRuleEndsQuietRegardlessOfSnooze() {
        for disabled in [true, false] {
            let settings = settings(urgent: disabled ? 250 : 180, urgentEnabled: !disabled)
            var value = started()
            value.refreshLocalBasis(glucose: 200, measuredAt: when, settings: settings, at: when)
            XCTAssertNil(value.activePeriod(at: when))
        }
    }

    func testOnlyOrdinaryHighIsFilteredBeforeThrottleAndMissedDeadlineStillExists() throws {
        let settings = settings()
        var alarms = LibreWatchAlarmState()
        alarms.use(settings)
        alarms.beginWatchOwnership(at: when)
        var quiet = started()
        quiet.refreshLocalBasis(glucose: 200, measuredAt: when, settings: settings, at: when)
        let high = try XCTUnwrap(alarms.accept(id: UUID(), measuredAt: when, glucose: 200,
            settings: settings, delegation: .confirmed(for: settings), watchOwnsSensor: true, now: when))
        XCTAssertEqual(high.kind, .high)
        XCTAssertTrue(quiet.suppresses(high.kind, at: when))
        XCTAssertEqual(alarms.snoozedUntil(.high, settings: settings), .distantPast)
        XCTAssertNotNil(alarms.nextMissedAlarm(settings: settings, delegation: .confirmed(for: settings),
            watchOwnsSensor: true, now: when))
        for kind: LibreWatchAlarmKind in [.veryHigh, .veryLow, .low, .missed] {
            XCTAssertFalse(quiet.suppresses(kind, at: when))
        }
        let later = when.addingTimeInterval(60)
        quiet.refreshLocalBasis(glucose: 260, measuredAt: later, settings: settings, at: later)
        let urgent = try XCTUnwrap(alarms.accept(id: UUID(), measuredAt: later, glucose: 260,
            settings: settings, delegation: .confirmed(for: settings), watchOwnsSensor: true, now: later))
        XCTAssertEqual(urgent.kind, .veryHigh)
        XCTAssertFalse(quiet.suppresses(urgent.kind, at: later))
        XCTAssertNil(quiet.activePeriod(at: later))
    }

    func testStorageFailureDisablesRestorationAndRetainsEndedMealIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WatchMealQuiet-\(UUID())")
        let name = "WatchMealQuiet-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: name)
        }
        let url = directory.appendingPathComponent("state.json")
        let value = started()
        try WatchMealQuietStore.save(value, to: url, defaults: defaults)
        XCTAssertEqual(WatchMealQuietStore.load(from: url, defaults: defaults), value)
        // Writing a file over its existing nonempty directory deterministically fails.
        XCTAssertThrowsError(try WatchMealQuietStore.save(value, to: directory, defaults: defaults))
        XCTAssertFalse(WatchMealQuietStore.storageIsHealthy(defaults: defaults))
        let restored = WatchMealQuietStore.load(from: url, defaults: defaults)
        XCTAssertNil(restored.activePeriod(at: when))
        XCTAssertEqual(restored.pendingEndIDs, ["meal-a"])
        try WatchMealQuietStore.save(restored, to: url, defaults: defaults)
        XCTAssertTrue(WatchMealQuietStore.storageIsHealthy(defaults: defaults))
        XCTAssertNil(WatchMealQuietStore.load(from: url, defaults: defaults).activePeriod(at: when))
        try Data("corrupt".utf8).write(to: url)
        XCTAssertNil(WatchMealQuietStore.load(from: url, defaults: defaults).received)
        XCTAssertFalse(WatchMealQuietStore.storageIsHealthy(defaults: defaults))
    }

    func testRejectedWatchReadingWithOlderPhoneBasisCannotStartQuiet() throws {
        var operation = WatchBolusOperation(operationID: UUID(), insulinID: UUID(), carbsID: UUID(),
            recordedAt: when, insulinUnits: 2, carbohydrateGrams: 30,
            mealKindRaw: "normal", pizzaReminderRequested: false,
            manualWithoutCurrentSuggestion: true, penStepUnits: 0.5,
            maximumUnits: 25, profileSignature: "synthetic",
            allowsMealQuietStart: true, latestWatchReadingAt: when)
        operation = try JSONDecoder().decode(WatchBolusOperation.self, from: JSONEncoder().encode(operation))
        XCTAssertEqual(operation.latestWatchReadingAt, when)
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.isTerminal(.wrongCalibration),
            "A rejected reading can leave an empty outbox without updating phone glucose")
        XCTAssertFalse(operation.mayStartMealQuiet(at: when,
            latestPhoneReadingAt: when.addingTimeInterval(-60), phoneOwnsSensor: true))
        XCTAssertFalse(operation.mayStartMealQuiet(at: when, latestPhoneReadingAt: nil))
        XCTAssertTrue(operation.mayStartMealQuiet(at: when, latestPhoneReadingAt: when))
        XCTAssertTrue(operation.mayStartMealQuiet(at: when.addingTimeInterval(10),
            latestPhoneReadingAt: when.addingTimeInterval(5)))
        XCTAssertTrue(operation.isValid(at: when), "Only quiet eligibility changes; the treatment remains loggable")
        operation.latestWatchReadingAt = nil
        XCTAssertFalse(operation.mayStartMealQuiet(at: when, latestPhoneReadingAt: when))
        XCTAssertTrue(operation.mayStartMealQuiet(at: when, phoneOwnsSensor: true))
    }

    func testFrozenConnectedOriginAndOriginalTimestampAreRequiredAfterQueueRoundTrip() throws {
        var operation = WatchBolusOperation(operationID: UUID(), insulinID: UUID(), carbsID: UUID(),
            recordedAt: when, insulinUnits: 2, carbohydrateGrams: 30,
            mealKindRaw: "normal", pizzaReminderRequested: false,
            manualWithoutCurrentSuggestion: true, penStepUnits: 0.5,
            maximumUnits: 25, profileSignature: "synthetic")
        XCTAssertFalse(operation.mayStartMealQuiet(at: when, phoneOwnsSensor: true), "Legacy queue entries have no online-origin evidence")
        operation.allowsMealQuietStart = false
        XCTAssertFalse(operation.mayStartMealQuiet(at: when, phoneOwnsSensor: true))
        operation.allowsMealQuietStart = true
        operation = try JSONDecoder().decode(WatchBolusOperation.self, from: JSONEncoder().encode(operation))
        XCTAssertTrue(operation.mayStartMealQuiet(at: when.addingTimeInterval(30), phoneOwnsSensor: true))
        XCTAssertFalse(operation.mayStartMealQuiet(at: when.addingTimeInterval(31), phoneOwnsSensor: true))
        XCTAssertFalse(operation.mayStartMealQuiet(at: when.addingTimeInterval(-1), phoneOwnsSensor: true))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(operation)) as? [String: Any])
        legacy.removeValue(forKey: "allowsMealQuietStart")
        let restored = try JSONDecoder().decode(WatchBolusOperation.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.allowsMealQuietStart)
        XCTAssertFalse(restored.mayStartMealQuiet(at: when, phoneOwnsSensor: true))
    }
}

extension WatchSnapshotSemanticsTests {
    func testOfflinePhoneReleaseCoalescesDuplicatesUntilNativeCompletion() {
        let coordinator = LibreWatchOfflinePhoneReleaseCoordinator()
        let request = UUID()
        var responses: [Bool] = []
        XCTAssertEqual(coordinator.begin(requestID: request) {
            responses.append($0[LibreWatchMessageKey.success] as? Bool == true)
        }, .started)
        XCTAssertEqual(coordinator.begin(requestID: request) {
            responses.append($0[LibreWatchMessageKey.success] as? Bool == true)
        }, .joined)
        XCTAssertEqual(coordinator.begin(requestID: UUID()) { _ in XCTFail("Unrelated claim joined") }, .conflict)
        XCTAssertTrue(responses.isEmpty, "Submitting/repeating a claim cannot acknowledge Bluetooth release")
        coordinator.complete(requestID: UUID(), response: [LibreWatchMessageKey.success: true])
        XCTAssertTrue(responses.isEmpty)
        coordinator.complete(requestID: request, response: [LibreWatchMessageKey.success: true])
        XCTAssertEqual(responses, [true, true])
        XCTAssertNil(coordinator.requestID)
        coordinator.complete(requestID: request, response: [LibreWatchMessageKey.success: false])
        XCTAssertEqual(responses, [true, true], "A late duplicate callback cannot deliver a second result")
    }

    func testOfflinePhoneNativeCompletionRevalidatesOwnershipSessionCalibrationAndAlarms() {
        let (original, calibration, settings) = fixtures()
        let transaction = LibreWatchOfflineTakeoverTransaction(originInstallationID: UUID(), offerID: UUID(),
            session: original, calibration: calibration, alarmSettings: settings,
            startingRevision: 10, createdAt: date)
        var session: LibreWatchDirectSession? = original
        var currentCalibration: LibreWatchCalibrationSnapshot? = calibration
        var currentSettings: LibreWatchAlarmSettings? = settings
        var ownership: LibreWatchOwnership = .releasingToWatch
        var ownershipRevision: UInt64 = 1
        var receipt = LibreWatchOfflineTakeoverReceipt(transaction: transaction, acceptedRevision: 0, state: .releasing)
        // This closure represents the delayed native completion; it reads live state at
        // invocation, using the same production policy that the real callback calls.
        let completionIsCurrent = {
            LibreWatchOfflinePhoneReleaseCoordinator.canComplete(transaction: transaction,
                session: session, calibration: currentCalibration, settings: currentSettings,
                ownership: ownership, ownershipRevision: ownershipRevision, receipt: receipt, at: self.date)
        }
        XCTAssertTrue(completionIsCurrent())
        session?.unlockCount += 1
        XCTAssertTrue(completionIsCurrent(), "A real intervening phone unlock is merged after release")
        session = fixtures().0
        XCTAssertFalse(completionIsCurrent(), "A sensor/session change invalidates the pending callback")
        session = original
        currentCalibration = nil
        XCTAssertFalse(completionIsCurrent())
        currentCalibration = LibreWatchCalibrationSnapshot(activeSensorID: calibration.activeSensorID,
            sensorUID: calibration.sensorUID, sensorSerialNumber: calibration.sensorSerialNumber,
            watchSessionID: calibration.watchSessionID, calibrationType: calibration.calibrationType,
            slope: calibration.slope, intercept: calibration.intercept, rawValueDivider: calibration.rawValueDivider,
            calibratedAt: calibration.calibratedAt, revision: calibration.revision + 1)
        XCTAssertFalse(completionIsCurrent(), "A new calibration needs a new validated preparation")
        currentCalibration = calibration
        currentSettings?.revision += 1
        XCTAssertFalse(completionIsCurrent(), "A changed alarm offer cannot be silently acknowledged")
        currentSettings = settings
        ownership = .iphone
        ownershipRevision = 11
        receipt.acceptedRevision = 11
        receipt.state = .retired
        XCTAssertFalse(completionIsCurrent(), "Explicit phone return wins over a delayed callback")
        ownership = .releasingToWatch
        XCTAssertFalse(completionIsCurrent(), "A retired receipt alone is sufficient to reject the callback")
    }

    func testOfflinePreparationCounterUpdatePreservesOfferAndExplicitOwnershipEpoch() throws {
        let name = "WatchSnapshotSemanticsTests.\(UUID())"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var (session, calibration, settings) = fixtures()
        let cache = LibreWatchHandoffSnapshotCache(defaults: defaults)
        let offer = UUID()
        let ownershipRevision = LibreWatchSessionStore.nextHandoffRevision(at: date, defaults: defaults)
        let first = try XCTUnwrap(cache.resolve(session: session, calibration: calibration, ownership: .iphone,
            settings: settings, delegation: nil, offlineTakeoverOfferID: offer,
            ownershipRevision: ownershipRevision, at: date))
        session.unlockCount += 1
        let refreshed = try XCTUnwrap(cache.resolve(session: session, calibration: calibration, ownership: .iphone,
            settings: settings, delegation: nil, offlineTakeoverOfferID: offer,
            ownershipRevision: ownershipRevision, at: date))
        XCTAssertGreaterThan(refreshed.revision, first.revision)
        XCTAssertEqual(refreshed.session.unlockCount, first.session.unlockCount + 1)
        XCTAssertEqual(refreshed.offlineTakeoverOfferID, first.offlineTakeoverOfferID)
        XCTAssertEqual(refreshed.ownershipRevision, first.ownershipRevision)
        XCTAssertEqual(LibreWatchHandoffSnapshotCache(defaults: defaults).snapshot, refreshed)
        XCTAssertTrue(LibreWatchOfflineTakeoverPolicy.canBegin(snapshot: refreshed, session: session,
            calibration: calibration, alarmSettings: settings, notificationsAuthorized: true))
        let revokedRevision = LibreWatchSessionStore.nextHandoffRevision(at: date, defaults: defaults)
        let replaced = try XCTUnwrap(cache.resolve(session: session, calibration: calibration, ownership: .iphone,
            settings: settings, delegation: nil, offlineTakeoverOfferID: UUID(),
            ownershipRevision: revokedRevision, at: date))
        XCTAssertGreaterThan(replaced.revision, refreshed.revision)
        XCTAssertNotEqual(replaced.offlineTakeoverOfferID, refreshed.offlineTakeoverOfferID)
        XCTAssertGreaterThan(try XCTUnwrap(replaced.ownershipRevision), first.revision)
    }

    func testOfflineAcceptedReceiptIsAtomicWithFreshCounterAndAuthorityPayload() throws {
        let name = "WatchSnapshotSemanticsTests.\(UUID())"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var (session, calibration, settings) = fixtures()
        let transaction = LibreWatchOfflineTakeoverTransaction(originInstallationID: UUID(), offerID: UUID(),
            session: session, calibration: calibration, alarmSettings: settings, startingRevision: 10, createdAt: date)
        let accepted = LibreWatchOfflineTakeoverReceipt(transaction: transaction, acceptedRevision: 11, state: .accepted)
        session.unlockCount = 7
        let cache = LibreWatchHandoffSnapshotCache(defaults: defaults)
        let snapshot = try XCTUnwrap(cache.resolve(session: session, calibration: calibration, ownership: .watch,
            settings: settings, delegation: .confirmed(for: settings), ownershipRevision: 1,
            offlineTakeoverReceipt: accepted, at: date))
        let payload = try XCTUnwrap(LibreWatchHandoffSnapshotCache.payload(snapshot))
        let restored = try JSONDecoder().decode(LibreWatchHandoffSnapshot.self,
            from: XCTUnwrap(payload[LibreWatchMessageKey.handoffSnapshot] as? Data))
        XCTAssertEqual(restored.session.unlockCount, 7)
        XCTAssertEqual(restored.ownership, .watch)
        XCTAssertEqual(restored.offlineTakeoverReceipt, accepted)
        XCTAssertGreaterThanOrEqual(restored.revision, accepted.acceptedRevision)
        XCTAssertNil(restored.offlineTakeoverOfferID)
        XCTAssertEqual(try JSONDecoder().decode(LibreWatchOfflineTakeoverReceipt.self,
            from: XCTUnwrap(payload[LibreWatchMessageKey.offlineTakeoverReceipt] as? Data)), accepted)
        XCTAssertNil(cache.current(session: session, calibration: calibration, ownership: .watch,
            delegation: .confirmed(for: settings), ownershipRevision: 1,
            offlineTakeoverReceipt: nil), "A pending/retired receipt must not reuse an accepted envelope")
    }
}

extension WatchSnapshotSemanticsTests {
    func testTerminalOfflinePreparationRejectionRevokesOnlyItsExactAuthority() {
        let (session, calibration, settings) = fixtures()
        let transaction = LibreWatchOfflineTakeoverTransaction(originInstallationID: UUID(), offerID: UUID(),
            session: session, calibration: calibration, alarmSettings: settings, startingRevision: 10, createdAt: date)
        func canRetire(_ decision: LibreWatchOfflineTakeoverPolicy.PhoneDecision = .wrongCalibration,
                       current: LibreWatchDirectSession? = nil, offer: UUID? = nil,
                       owner: LibreWatchOwnership = .iphone, epoch: UInt64 = 1,
                       receipt: LibreWatchOfflineTakeoverReceipt? = nil) -> Bool {
            LibreWatchOfflinePhoneReleaseCoordinator.canRetireRejectedPreparation(decision: decision,
                transaction: transaction, session: current ?? session, activeOfferID: offer ?? transaction.offerID,
                ownership: owner, ownershipRevision: epoch, receipt: receipt)
        }
        XCTAssertTrue(canRetire())
        XCTAssertTrue(canRetire(.wrongAlarmSettings))
        XCTAssertFalse(canRetire(.invalid))
        XCTAssertFalse(canRetire(.conflictingRequest))
        XCTAssertFalse(canRetire(.duplicate))
        XCTAssertFalse(canRetire(.accept))
        XCTAssertFalse(canRetire(offer: UUID()))
        XCTAssertFalse(canRetire(current: fixtures().0))
        XCTAssertFalse(canRetire(owner: .watch))
        XCTAssertFalse(canRetire(epoch: 11), "An explicit later return cannot be revoked by rejection")
        let pending = LibreWatchOfflineTakeoverReceipt(transaction: transaction, acceptedRevision: 0, state: .releasing)
        XCTAssertTrue(canRetire(owner: .releasingToWatch, receipt: pending))
        XCTAssertTrue(canRetire(owner: .watch, receipt: pending), "A restarted pending native release can be unwound")
        let accepted = LibreWatchOfflineTakeoverReceipt(transaction: transaction, acceptedRevision: 11, state: .accepted)
        XCTAssertFalse(canRetire(owner: .watch, receipt: accepted), "A completed claim is not a rejected preparation")
        let other = LibreWatchOfflineTakeoverTransaction(originInstallationID: transaction.originInstallationID,
            offerID: transaction.offerID, session: session, calibration: calibration, alarmSettings: settings,
            startingRevision: 10, createdAt: date)
        XCTAssertFalse(canRetire(receipt: LibreWatchOfflineTakeoverReceipt(transaction: other,
            acceptedRevision: 0, state: .releasing)), "A conflicting claim cannot revoke the persisted first intent")
    }

    func testTerminalOfflineConfigurationRejectionPublishesARecoverablePhonePreparation() throws {
        let name = "WatchSnapshotSemanticsTests.\(UUID())"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let (session, calibration, originalSettings) = fixtures()
        let cache = LibreWatchHandoffSnapshotCache(defaults: defaults)
        let epoch = LibreWatchSessionStore.nextHandoffRevision(at: date, defaults: defaults)
        let offer = UUID()
        let offered = try XCTUnwrap(cache.resolve(session: session, calibration: calibration, ownership: .iphone,
            settings: originalSettings, delegation: nil, offlineTakeoverOfferID: offer, ownershipRevision: epoch, at: date))
        let transaction = LibreWatchOfflineTakeoverTransaction(originInstallationID: UUID(), offerID: offer,
            session: session, calibration: calibration, alarmSettings: originalSettings,
            startingRevision: offered.revision, createdAt: date)
        var settings = originalSettings
        settings.revision += 1
        let rejection = LibreWatchOfflineTakeoverPolicy.phoneDecision(transaction: transaction,
            currentSession: session, currentCalibration: calibration, currentAlarmSettings: settings,
            activeOfferID: offer, ownership: .iphone, ownershipRevision: epoch, receipt: nil, at: date)
        XCTAssertEqual(rejection, .wrongAlarmSettings)
        XCTAssertTrue(LibreWatchOfflinePhoneReleaseCoordinator.canRetireRejectedPreparation(decision: rejection,
            transaction: transaction, session: session, activeOfferID: offer, ownership: .iphone,
            ownershipRevision: epoch, receipt: nil))
        let replacementEpoch = LibreWatchSessionStore.nextHandoffRevision(at: date, defaults: defaults)
        let replacementOffer = UUID()
        let replacement = try XCTUnwrap(cache.resolve(session: session, calibration: calibration, ownership: .iphone,
            settings: settings, delegation: nil, offlineTakeoverOfferID: replacementOffer,
            ownershipRevision: replacementEpoch, at: date))
        let payload = try XCTUnwrap(LibreWatchHandoffSnapshotCache.payload(replacement))
        let received = try JSONDecoder().decode(LibreWatchHandoffSnapshot.self,
            from: XCTUnwrap(payload[LibreWatchMessageKey.handoffSnapshot] as? Data))
        XCTAssertEqual(received.ownership, .iphone)
        XCTAssertGreaterThan(try XCTUnwrap(received.ownershipRevision), transaction.startingRevision,
            "The Watch can stop its pending claim and quarantine the unaccepted readings")
        XCTAssertTrue(LibreWatchOfflineTakeoverPolicy.canBegin(snapshot: received, session: session,
            calibration: calibration, alarmSettings: settings, notificationsAuthorized: true))
        XCTAssertEqual(LibreWatchOfflineTakeoverPolicy.phoneDecision(transaction: transaction,
            currentSession: session, currentCalibration: calibration, currentAlarmSettings: settings,
            activeOfferID: replacementOffer, ownership: .iphone, ownershipRevision: replacementEpoch,
            receipt: nil, at: date), .staleOwnership, "Repeating the rejected claim cannot restore its old offer")
    }
}

extension WatchSnapshotSemanticsTests {
    func testPhoneRestartCompletesInterruptedOfflineRevocationBeforePublishingGrant() throws {
        let name = "WatchSnapshotSemanticsTests.\(UUID())"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let (session, calibration, settings) = fixtures()
        let transaction = LibreWatchOfflineTakeoverTransaction(originInstallationID: UUID(), offerID: UUID(),
            session: session, calibration: calibration, alarmSettings: settings, startingRevision: 10, createdAt: date)
        let accepted = LibreWatchOfflineTakeoverReceipt(transaction: transaction, acceptedRevision: 11, state: .accepted)
        LibreWatchSessionStore.saveSession(session, defaults: defaults)
        LibreWatchSessionStore.saveOwnership(.watch, defaults: defaults)
        XCTAssertTrue(LibreWatchSessionStore.saveOfflineTakeoverReceipt(accepted, defaults: defaults))
        LibreWatchSessionStore.saveOwnershipRevision(12, defaults: defaults)
        // Simulates a process stop after the revocation epoch but before owner/receipt.
        XCTAssertTrue(LibreWatchOfflinePhoneReleaseCoordinator.recoverInterruptedRevocation(
            session: session, defaults: defaults))
        XCTAssertEqual(LibreWatchSessionStore.loadOwnership(defaults: defaults), .iphone)
        let retired = try XCTUnwrap(LibreWatchSessionStore.loadOfflineTakeoverReceipt(defaults: defaults))
        XCTAssertEqual(retired.state, .retired)
        XCTAssertEqual(retired.acceptedRevision, 12)
        let startup = LibreWatchPhoneStartupDecision.resolve(
            persistedOwnership: LibreWatchSessionStore.loadOwnership(defaults: defaults), persistedSession: session,
            activeSensorUID: session.sensorUID, activePatchInfo: session.patchInfo)
        XCTAssertFalse(startup.phoneConnectionIsBlocked)
        let snapshot = try XCTUnwrap(LibreWatchHandoffSnapshotCache(defaults: defaults).resolve(
            session: session, calibration: calibration, ownership: startup.ownership, settings: settings,
            delegation: nil, offlineTakeoverOfferID: UUID(), ownershipRevision: 12,
            offlineTakeoverReceipt: retired, at: date))
        XCTAssertEqual(snapshot.ownership, .iphone)
        XCTAssertNotNil(LibreWatchHandoffSnapshotCache.payload(snapshot))
        XCTAssertEqual(LibreWatchOfflineTakeoverPolicy.phoneDecision(transaction: transaction,
            currentSession: session, currentCalibration: calibration, currentAlarmSettings: settings,
            activeOfferID: snapshot.offlineTakeoverOfferID, ownership: .iphone, ownershipRevision: 12,
            receipt: retired, at: date), .staleOwnership)
        XCTAssertFalse(LibreWatchOfflinePhoneReleaseCoordinator.recoverInterruptedRevocation(
            session: session, defaults: defaults), "The recovered phone snapshot remains available on repeated startup")
        // A second stop during the repair, after owner=phone but before retirement,
        // still has recognizable evidence and finishes without granting Watch again.
        XCTAssertTrue(LibreWatchSessionStore.saveOfflineTakeoverReceipt(accepted, defaults: defaults))
        XCTAssertTrue(LibreWatchOfflinePhoneReleaseCoordinator.recoverInterruptedRevocation(
            session: session, defaults: defaults))
        XCTAssertEqual(LibreWatchSessionStore.loadOwnership(defaults: defaults), .iphone)
        XCTAssertEqual(LibreWatchSessionStore.loadOfflineTakeoverReceipt(defaults: defaults)?.state, .retired)
    }

    func testPhoneRestartRevocationRecoveryPreservesValidWatchAndUnrelatedSessions() {
        let name = "WatchSnapshotSemanticsTests.\(UUID())"; let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let (session, calibration, settings) = fixtures()
        let transaction = LibreWatchOfflineTakeoverTransaction(originInstallationID: UUID(), offerID: UUID(),
            session: session, calibration: calibration, alarmSettings: settings, startingRevision: 10, createdAt: date)
        var receipt = LibreWatchOfflineTakeoverReceipt(transaction: transaction, acceptedRevision: 11, state: .accepted)
        LibreWatchSessionStore.saveOwnership(.watch, defaults: defaults)
        LibreWatchSessionStore.saveOwnershipRevision(1, defaults: defaults)
        XCTAssertTrue(LibreWatchSessionStore.saveOfflineTakeoverReceipt(receipt, defaults: defaults))
        XCTAssertFalse(LibreWatchOfflinePhoneReleaseCoordinator.recoverInterruptedRevocation(
            session: session, defaults: defaults))
        XCTAssertEqual(LibreWatchSessionStore.loadOwnership(defaults: defaults), .watch)
        receipt.state = .releasing; receipt.acceptedRevision = 0
        XCTAssertTrue(LibreWatchSessionStore.saveOfflineTakeoverReceipt(receipt, defaults: defaults))
        XCTAssertFalse(LibreWatchOfflinePhoneReleaseCoordinator.recoverInterruptedRevocation(
            session: session, defaults: defaults), "An ordinary interrupted release still belongs to Watch")
        LibreWatchSessionStore.saveOwnershipRevision(12, defaults: defaults)
        XCTAssertFalse(LibreWatchOfflinePhoneReleaseCoordinator.recoverInterruptedRevocation(
            session: fixtures().0, defaults: defaults), "An unrelated current session cannot be reset by an old receipt")
        XCTAssertEqual(LibreWatchSessionStore.loadOwnership(defaults: defaults), .watch)
        XCTAssertTrue(LibreWatchOfflinePhoneReleaseCoordinator.recoverInterruptedRevocation(
            session: session, defaults: defaults))
        XCTAssertEqual(LibreWatchSessionStore.loadOwnership(defaults: defaults), .iphone)
    }
}


final class WatchPenConfigurationSignatureCacheTests: XCTestCase {
    private let confirmationDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func isolatedDefaults() -> UserDefaults {
        let name = "WatchPenConfigurationSignatureCacheTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func confirmedProfile(maximumUnits: Double = 25,
                                  confirmedAt: Date? = nil) -> PenDoseProfile {
        var settings = PenDoseProfile.prefilledUnconfirmed.settings
        settings.maximumSuggestionUnits = maximumUnits
        return PenDoseProfile(settings: settings, confirmedSettings: settings,
            confirmedAt: confirmedAt ?? confirmationDate)
    }

    // Preserve the original decoding and signature expression as the output oracle.
    private func uncachedSignature(defaults: UserDefaults) -> String {
        let profile: PenDoseProfile
        if let data = defaults.data(forKey: PenDoseProfile.storageKey),
           let decoded = try? JSONDecoder().decode(PenDoseProfile.self, from: data),
           decoded.version == PenDoseProfile.schemaVersion, decoded.settings.isValid {
            profile = decoded
        } else {
            profile = .prefilledUnconfirmed
        }
        let pizza = PizzaSplitSettings.load(defaults: defaults)
        return [WatchPenPhoneService.profileSignature(profile), String(pizza.isEnabled),
            String(pizza.percentageNow), String(pizza.reminderMinutes)].joined(separator: "|")
    }

    func testRepeatedAndUnrelatedDefaultsChangesReuseTheRealProfileSignature() {
        let defaults = isolatedDefaults()
        XCTAssertTrue(confirmedProfile().persist(defaults: defaults))
        var builds = 0
        var cache = WatchPenConfigurationSignatureCache { profile in
            builds += 1
            return WatchPenPhoneService.profileSignature(profile)
        }
        let expected = uncachedSignature(defaults: defaults)
        for revision in 0..<30 {
            defaults.set(revision, forKey: "unrelated.settings.revision")
            XCTAssertEqual(cache.signature(defaults: defaults), expected)
            XCTAssertEqual(cache.signature(defaults: defaults), expected)
        }
        XCTAssertEqual(builds, 1)
    }

    func testProfileEditsConfirmationRemovalAndReconfirmationInvalidateTheCache() {
        let defaults = isolatedDefaults()
        var profile = confirmedProfile()
        XCTAssertTrue(profile.persist(defaults: defaults))
        var builds = 0
        var cache = WatchPenConfigurationSignatureCache { profile in
            builds += 1
            return WatchPenPhoneService.profileSignature(profile)
        }
        let original = cache.signature(defaults: defaults)
        XCTAssertEqual(original, uncachedSignature(defaults: defaults))
        profile.settings.maximumSuggestionUnits = 20
        XCTAssertFalse(profile.isConfirmed)
        XCTAssertTrue(profile.persist(defaults: defaults))
        let edited = cache.signature(defaults: defaults)
        XCTAssertEqual(edited, uncachedSignature(defaults: defaults))
        XCTAssertNotEqual(edited, original)
        XCTAssertEqual(builds, 2)

        profile = confirmedProfile(maximumUnits: 20)
        XCTAssertTrue(profile.persist(defaults: defaults))
        let reconfirmed = cache.signature(defaults: defaults)
        XCTAssertEqual(reconfirmed, uncachedSignature(defaults: defaults))
        XCTAssertNotEqual(reconfirmed, edited)
        XCTAssertEqual(builds, 3)

        let unconfirmed = PenDoseProfile(settings: profile.settings)
        XCTAssertTrue(unconfirmed.persist(defaults: defaults))
        XCTAssertEqual(cache.signature(defaults: defaults), uncachedSignature(defaults: defaults))
        XCTAssertEqual(builds, 4)
        let updatedConfirmation = confirmedProfile(maximumUnits: 20,
            confirmedAt: confirmationDate.addingTimeInterval(60))
        XCTAssertTrue(updatedConfirmation.persist(defaults: defaults))
        let updated = cache.signature(defaults: defaults)
        XCTAssertEqual(updated, uncachedSignature(defaults: defaults))
        XCTAssertNotEqual(updated, reconfirmed)
        XCTAssertEqual(cache.signature(defaults: defaults), updated)
        XCTAssertEqual(builds, 5)
    }

    func testEachPizzaSettingInvalidatesWhileEquivalentDefaultsRemainCached() {
        let defaults = isolatedDefaults()
        XCTAssertTrue(confirmedProfile().persist(defaults: defaults))
        var builds = 0
        var cache = WatchPenConfigurationSignatureCache { profile in
            builds += 1
            return WatchPenPhoneService.profileSignature(profile)
        }
        let original = cache.signature(defaults: defaults)
        var pizza = PizzaSplitSettings.load(defaults: defaults)
        XCTAssertTrue(pizza.persist(defaults: defaults))
        XCTAssertEqual(cache.signature(defaults: defaults), original,
            "Explicitly storing fallback values does not change the effective settings")
        XCTAssertEqual(builds, 1)

        pizza.isEnabled.toggle()
        XCTAssertTrue(pizza.persist(defaults: defaults))
        let disabled = cache.signature(defaults: defaults)
        XCTAssertEqual(disabled, uncachedSignature(defaults: defaults))
        XCTAssertNotEqual(disabled, original)
        XCTAssertEqual(builds, 2)
        pizza.percentageNow = 60
        XCTAssertTrue(pizza.persist(defaults: defaults))
        let percentageChanged = cache.signature(defaults: defaults)
        XCTAssertEqual(percentageChanged, uncachedSignature(defaults: defaults))
        XCTAssertNotEqual(percentageChanged, disabled)
        XCTAssertEqual(builds, 3)
        pizza.reminderMinutes = 120
        XCTAssertTrue(pizza.persist(defaults: defaults))
        let reminderChanged = cache.signature(defaults: defaults)
        XCTAssertEqual(reminderChanged, uncachedSignature(defaults: defaults))
        XCTAssertNotEqual(reminderChanged, percentageChanged)
        XCTAssertEqual(cache.signature(defaults: defaults), reminderChanged)
        XCTAssertEqual(builds, 4)
    }

    func testMissingCorruptUnsupportedAndInvalidProfilesKeepFallbackSemantics() throws {
        let defaults = isolatedDefaults()
        var unsupported = confirmedProfile()
        unsupported.version = PenDoseProfile.schemaVersion + 1
        var invalid = confirmedProfile()
        invalid.settings.maximumSuggestionUnits = 0
        let payloads: [Data?] = [nil, Data("not JSON".utf8),
            try JSONEncoder().encode(unsupported), try JSONEncoder().encode(invalid)]
        var builds = 0
        var cache = WatchPenConfigurationSignatureCache { profile in
            builds += 1
            return WatchPenPhoneService.profileSignature(profile)
        }
        for (index, payload) in payloads.enumerated() {
            defaults.set(payload, forKey: PenDoseProfile.storageKey)
            XCTAssertEqual(PenDoseProfile.load(data: payload), .prefilledUnconfirmed)
            XCTAssertEqual(PenDoseProfile.load(defaults: defaults), .prefilledUnconfirmed)
            let signature = cache.signature(defaults: defaults)
            XCTAssertEqual(signature, uncachedSignature(defaults: defaults))
            XCTAssertEqual(signature.components(separatedBy: "|").first, "")
            XCTAssertEqual(cache.signature(defaults: defaults), signature)
            XCTAssertEqual(builds, index + 1,
                "Different stored bytes invalidate even when both decode to the fallback")
        }
        XCTAssertTrue(confirmedProfile().persist(defaults: defaults))
        let recovered = cache.signature(defaults: defaults)
        XCTAssertEqual(recovered, uncachedSignature(defaults: defaults))
        XCTAssertFalse(try XCTUnwrap(recovered.components(separatedBy: "|").first).isEmpty)
        XCTAssertEqual(builds, payloads.count + 1)
    }

    func testEquivalentProfileJSONReencodingRebuildsWithoutChangingTheSignature() throws {
        let defaults = isolatedDefaults()
        let profile = confirmedProfile()
        let compactEncoder = JSONEncoder()
        compactEncoder.outputFormatting = [.sortedKeys]
        let prettyEncoder = JSONEncoder()
        prettyEncoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let compact = try compactEncoder.encode(profile)
        let pretty = try prettyEncoder.encode(profile)
        XCTAssertNotEqual(compact, pretty)
        XCTAssertEqual(PenDoseProfile.load(data: compact), profile)
        XCTAssertEqual(PenDoseProfile.load(data: pretty), profile)
        defaults.set(compact, forKey: PenDoseProfile.storageKey)
        var builds = 0
        var cache = WatchPenConfigurationSignatureCache { profile in
            builds += 1
            return WatchPenPhoneService.profileSignature(profile)
        }
        let original = cache.signature(defaults: defaults)
        defaults.set(pretty, forKey: PenDoseProfile.storageKey)
        XCTAssertEqual(cache.signature(defaults: defaults), original)
        XCTAssertEqual(cache.signature(defaults: defaults), uncachedSignature(defaults: defaults))
        XCTAssertEqual(builds, 2)
    }

    func testBuilderMutationCannotMixCapturedProfileAndPizzaSettings() throws {
        let defaults = isolatedDefaults()
        let originalProfile = confirmedProfile()
        let updatedProfile = confirmedProfile(maximumUnits: 20)
        let updatedData = try JSONEncoder().encode(updatedProfile)
        XCTAssertTrue(originalProfile.persist(defaults: defaults))
        let original = uncachedSignature(defaults: defaults)
        var profilesBuilt: [PenDoseProfile] = []
        var cache = WatchPenConfigurationSignatureCache { profile in
            profilesBuilt.append(profile)
            if profilesBuilt.count == 1 {
                defaults.set(updatedData, forKey: PenDoseProfile.storageKey)
                defaults.set(false, forKey: PizzaSplitSettings.enabledKey)
                defaults.set(60, forKey: PizzaSplitSettings.percentageKey)
                defaults.set(120, forKey: PizzaSplitSettings.reminderKey)
            }
            return WatchPenPhoneService.profileSignature(profile)
        }
        XCTAssertEqual(cache.signature(defaults: defaults), original,
            "The result must represent the inputs captured before the signature builder ran")
        let updated = uncachedSignature(defaults: defaults)
        XCTAssertNotEqual(updated, original)
        XCTAssertEqual(cache.signature(defaults: defaults), updated)
        XCTAssertEqual(cache.signature(defaults: defaults), updated)
        XCTAssertEqual(profilesBuilt, [originalProfile, updatedProfile])
    }

    func testIndependentCacheInstancesEachBuildTheirOwnInitialSignature() {
        let defaults = isolatedDefaults()
        XCTAssertTrue(confirmedProfile().persist(defaults: defaults))
        var firstBuilds = 0
        var secondBuilds = 0
        var first = WatchPenConfigurationSignatureCache { profile in
            firstBuilds += 1
            return WatchPenPhoneService.profileSignature(profile)
        }
        var second = WatchPenConfigurationSignatureCache { profile in
            secondBuilds += 1
            return WatchPenPhoneService.profileSignature(profile)
        }
        let expected = uncachedSignature(defaults: defaults)
        XCTAssertEqual(first.signature(defaults: defaults), expected)
        XCTAssertEqual(first.signature(defaults: defaults), expected)
        XCTAssertEqual(secondBuilds, 0)
        XCTAssertEqual(second.signature(defaults: defaults), expected)
        XCTAssertEqual(firstBuilds, 1)
        XCTAssertEqual(secondBuilds, 1)
        defaults.removeObject(forKey: PenDoseProfile.storageKey)
        XCTAssertEqual(first.signature(defaults: defaults), uncachedSignature(defaults: defaults))
        XCTAssertEqual(secondBuilds, 1)
        XCTAssertEqual(second.signature(defaults: defaults), uncachedSignature(defaults: defaults))
        XCTAssertEqual(firstBuilds, 2)
        XCTAssertEqual(secondBuilds, 2)
    }

    func testSwitchingDefaultsSuitesNeverReturnsAnotherSuitesConfiguration() {
        let firstDefaults = isolatedDefaults()
        let secondDefaults = isolatedDefaults()
        XCTAssertTrue(confirmedProfile().persist(defaults: firstDefaults))
        secondDefaults.set(false, forKey: PizzaSplitSettings.enabledKey)
        var builds = 0
        var cache = WatchPenConfigurationSignatureCache { profile in
            builds += 1
            return WatchPenPhoneService.profileSignature(profile)
        }
        let first = cache.signature(defaults: firstDefaults)
        XCTAssertEqual(first, uncachedSignature(defaults: firstDefaults))
        let second = cache.signature(defaults: secondDefaults)
        XCTAssertEqual(second, uncachedSignature(defaults: secondDefaults))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(cache.signature(defaults: firstDefaults), first)
        XCTAssertEqual(cache.signature(defaults: firstDefaults), first)
        XCTAssertEqual(builds, 3)
    }
}
