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
        XCTAssertFalse(period(duration: 3601).isActive(at: when))
        XCTAssertTrue(period(duration: 3600).isActive(at: when))
        XCTAssertFalse(period("").isActive(at: when))
        XCTAssertFalse(MealQuietPeriod(mealID: "bad", startedAt: when,
            until: Date(timeIntervalSince1970: .infinity)).isActive(at: when))
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
