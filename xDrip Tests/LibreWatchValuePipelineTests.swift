import XCTest
import CoreData
import HealthKit
@testable import xdrip

extension LibreWatchValuePipelineTests {
    func testConfiguredReadSuccessCadenceDoesNotShrinkDuringOutageOrBackfill() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(3600)
        let contexts = [TransmitterReadSuccessContext(effectiveAt: start, source: "Libre2", interval: 60, visibleInterval: 60)]
        let before = TransmitterReadSuccessPolicy.counts(timestamps: [start, start.addingTimeInterval(60)],
            start: start, end: end, contexts: contexts, fallbackInterval: 60)
        XCTAssertEqual(before.expected, 60)
        XCTAssertEqual(before.actual, 2)
        let after = TransmitterReadSuccessPolicy.counts(timestamps: (0..<60).map { start.addingTimeInterval(Double($0) * 60) },
            start: start, end: end, contexts: contexts, fallbackInterval: 60)
        XCTAssertEqual(after.expected, before.expected)
        XCTAssertEqual(after.actual, 60)
    }

    func testConfiguredReadSuccessMixedIntervalsAndMinuteJitter() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let contexts = [
            TransmitterReadSuccessContext(effectiveAt: start, source: "Libre2", interval: 60, visibleInterval: 60),
            TransmitterReadSuccessContext(effectiveAt: start.addingTimeInterval(3600), source: "Dexcom", interval: 300, visibleInterval: 300)
        ]
        let counts = TransmitterReadSuccessPolicy.counts(timestamps: [], start: start,
            end: start.addingTimeInterval(7200), contexts: contexts, fallbackInterval: 60)
        XCTAssertEqual(counts.expected, 72)
        let jitter = TransmitterReadSuccessPolicy.counts(timestamps: [59, 120.1, 179].map { start.addingTimeInterval($0) },
            start: start, end: start.addingTimeInterval(180), contexts: contexts, fallbackInterval: 60)
        XCTAssertEqual(jitter, .init(expected: 3, actual: 3))
        let visibleOnly = Array(contexts.prefix(1)) + [TransmitterReadSuccessContext(effectiveAt: start.addingTimeInterval(30),
            source: "Libre2", interval: 60, visibleInterval: 300)]
        XCTAssertEqual(TransmitterReadSuccessPolicy.counts(timestamps: [], start: start,
            end: start.addingTimeInterval(180), contexts: Array(visibleOnly), fallbackInterval: 60).expected, 3)
        let unknown = [contexts[0],
            TransmitterReadSuccessContext(effectiveAt: start.addingTimeInterval(3600), source: "Bubble", interval: 0, visibleInterval: 300),
            TransmitterReadSuccessContext(effectiveAt: start.addingTimeInterval(7200), source: "Libre2", interval: 60, visibleInterval: 60)]
        XCTAssertEqual(TransmitterReadSuccessPolicy.counts(timestamps: [], start: start,
            end: start.addingTimeInterval(10800), contexts: unknown, fallbackInterval: 60).expected, 120)
    }

    @MainActor
    func testReadSuccessUsesCurrentSensorAndSeparatesDelayedPhoneStorage() throws {
        let suite = "ReadSuccessRegression-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.cgmTransmitterTypeAsString = CGMTransmitterType.Libre2.rawValue
        let now = Date()
        let start = now.addingTimeInterval(-600)
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let sensor = Sensor(startDate: start, nsManagedObjectContext: stack.mainManagedObjectContext)
        let other = Sensor(startDate: start, nsManagedObjectContext: stack.mainManagedObjectContext)
        let current = BgReading(timeStamp: start.addingTimeInterval(60), sensor: sensor, calibration: nil,
            rawData: 85, deviceName: nil, nsManagedObjectContext: stack.mainManagedObjectContext)
        current.calculatedValue = 85
        current.ageAdjustedRawValue = 85
        let unrelated = BgReading(timeStamp: start.addingTimeInterval(120), sensor: other, calibration: nil,
            rawData: 86, deviceName: nil, nsManagedObjectContext: stack.mainManagedObjectContext)
        unrelated.calculatedValue = 86
        unrelated.ageAdjustedRawValue = 86
        XCTAssertTrue(stack.saveChanges())
        let receipt = TransmitterReadSuccessReceipt(id: current.id, sensorID: sensor.id,
            measuredAt: current.timeStamp, storedAt: now, fromWatch: true, historical: true)
        TransmitterReadSuccessEvidence.record(receipt, defaults: defaults)
        TransmitterReadSuccessEvidence.record(receipt, defaults: defaults)
        let display = TransmitterReadSuccessManager(bgReadingsAccessor: BgReadingsAccessor(coreDataManager: stack),
            nowProvider: { now }, defaults: defaults).getReadSuccess(forSensor: sensor)
        XCTAssertEqual(display.expected24h, 10)
        XCTAssertEqual(display.actual24h, 1)
        XCTAssertEqual(display.timelyReceiptCount, 0)
        XCTAssertEqual(display.delayedReceiptCount, 1)
        XCTAssertTrue(display.deliveryEvidence.contains("BLE outages and transport delay are separate"))
    }

    func testCorrectedLogDeliveryIntervalsRemainHistoricalNotCurrent() {
        // Receipt-minus-measurement intervals from the supplied 18:58:25 report.
        // These prove late phone registration, not the location of the delay or a BLE outage.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for age in [519.0, 2_415, 206, 184] {
            XCTAssertGreaterThan(age, LibreWatchReadingAcceptancePolicy.maximumTransportAge)
            XCTAssertLessThan(age, LibreWatchHistoryPolicy.maximumAge)
            XCTAssertTrue(LibreWatchStoredReadingPolicy.requiresHistoricalPath(measuredAt: now.addingTimeInterval(-age),
                latestStoredAt: now.addingTimeInterval(-60)))
            let routing = LibreWatchGlucoseProcessingMode.historicalBackfill.routing
            XCTAssertFalse(routing.triggersAlerts)
            XCTAssertFalse(routing.resetsMissedReadingState)
            XCTAssertFalse(routing.updatesCurrentValue)
        }
    }

    func testStoredWatchReceiptDistinguishesPermanentErrorAndPendingCalibration() {
        XCTAssertEqual(LibreWatchStoredReadingPolicy.outcome(isValid: false, calculatedValue: 0), .historyNotInserted)
        XCTAssertEqual(LibreWatchStoredReadingPolicy.outcome(isValid: false, calculatedValue: 38), .invalidPayload)
        XCTAssertEqual(LibreWatchStoredReadingPolicy.outcome(isValid: true, calculatedValue: 38), .duplicate)
        XCTAssertEqual(LibreWatchStoredReadingPolicy.outcome(isValid: true, calculatedValue: 39), .duplicate)
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.isTerminal(.invalidPayload))
        XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.isTerminal(.historyNotInserted))
    }

    @MainActor
    func testWatchStorageConfirmationWaitsForParentStoreAndCanRetryFailedChildSave() async throws {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let sensor = Sensor(startDate: Date().addingTimeInterval(-3600), nsManagedObjectContext: stack.mainManagedObjectContext)
        let reading = BgReading(timeStamp: Date(), sensor: sensor, calibration: nil, rawData: 85,
            deviceName: nil, nsManagedObjectContext: stack.mainManagedObjectContext)
        reading.calculatedValue = 85
        reading.ageAdjustedRawValue = 85
        let id = reading.id
        reading.setValue(nil, forKey: "id")
        let failed = expectation(description: "Invalid child save is not a receipt")
        stack.saveChanges { saved in XCTAssertFalse(saved); failed.fulfill() }
        await fulfillment(of: [failed], timeout: 5)
        reading.id = id
        let confirmed = expectation(description: "Valid retry is durable before receipt")
        stack.saveChanges { saved in
            XCTAssertTrue(saved)
            let reader = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            reader.persistentStoreCoordinator = stack.privateManagedObjectContext.persistentStoreCoordinator
            reader.perform {
                let request: NSFetchRequest<BgReading> = BgReading.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", id)
                XCTAssertEqual(try? reader.count(for: request), 1)
                confirmed.fulfill()
            }
        }
        await fulfillment(of: [confirmed], timeout: 5)
    }
}

extension LibreWatchValuePipelineTests {
    func testNightscoutDispatchGateHonorsDisabledEnabledAndDisabledDuringRead() async {
        let reading: [String: Any] = ["_id": "enabled-gate", "type": "sgv", "date": 1_000, "sgv": 85]
        var enabled = false
        var actions = [String]()
        let disabled = await NightscoutReadingConfirmation.reconcile([reading], isUploadAllowed: { enabled },
            fetch: { _ in actions.append("read"); return [] }, upload: { _ in actions.append("write"); return true })
        XCTAssertFalse(disabled)
        XCTAssertTrue(actions.isEmpty)
        enabled = true
        var stored = false
        let accepted = await NightscoutReadingConfirmation.reconcile([reading], isUploadAllowed: { enabled },
            fetch: { _ in actions.append("read"); return stored ? [reading] : [] },
            upload: { _ in actions.append("write"); stored = true; return true })
        XCTAssertTrue(accepted)
        XCTAssertEqual(actions, ["read", "write", "read"])
        actions.removeAll()
        let toggled = await NightscoutReadingConfirmation.reconcile([reading], isUploadAllowed: { enabled },
            fetch: { _ in actions.append("read"); enabled = false; return [] },
            upload: { _ in actions.append("write"); return true })
        XCTAssertFalse(toggled)
        XCTAssertEqual(actions, ["read"], "Turning upload off while a request is pending must prevent its retry POST")
    }

    func testHealthKitDispatchGateHonorsDisabledEnabledAndDisabledDuringQuery() {
        var enabled = false
        var actions = [String]()
        HealthKitLegacyReplacement.perform(isEnabled: { enabled },
            query: { complete in actions.append("query"); complete(.success([String]())) },
            remove: { _, complete in actions.append("delete"); complete(true) },
            save: { actions.append("save") }, failed: { actions.append("retained") })
        XCTAssertEqual(actions, ["retained"])
        actions.removeAll()
        enabled = true
        HealthKitLegacyReplacement.perform(isEnabled: { enabled },
            query: { complete in actions.append("query"); complete(.success([String]())) },
            remove: { _, complete in actions.append("delete"); complete(true) },
            save: { actions.append("save") }, failed: { actions.append("retained") })
        XCTAssertEqual(actions, ["query", "save"])
        actions.removeAll()
        HealthKitLegacyReplacement.perform(isEnabled: { enabled },
            query: { complete in actions.append("query"); enabled = false; complete(.success(["legacy"])) },
            remove: { _, complete in actions.append("delete"); complete(true) },
            save: { actions.append("save") }, failed: { actions.append("retained") })
        XCTAssertEqual(actions, ["query", "retained"])
    }

    func testCalendarDispatchGateHonorsDisabledAndEnabled() {
        var actions = [String]()
        XCTAssertFalse(CalendarShareReplacement.perform(enabled: false, save: { actions.append("save") },
            removePrevious: { actions.append("removePrevious") }))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(CalendarShareReplacement.perform(enabled: true, save: { actions.append("save") },
            removePrevious: { actions.append("removePrevious") }))
        XCTAssertEqual(actions, ["save", "removePrevious"])
    }

    func testNightscoutCode66RequiresPerReadingConfirmationOfMixedBatch() async {
        let first: [String: Any] = ["_id": "first", "type": "sgv", "date": 1_000, "sgv": 85]
        let second: [String: Any] = ["_id": "second", "type": "sgv", "date": 61_000, "sgv": 89]
        var server = ["first": first]
        var posts = [String]()
        let confirmed = await NightscoutReadingConfirmation.reconcile([first, second], fetch: { id in
            server[id].map { [$0] } ?? []
        }, upload: { reading in
            let id = reading["_id"] as! String
            posts.append(id)
            server[id] = reading
            return true
        })
        XCTAssertTrue(confirmed)
        XCTAssertEqual(posts, ["second"])
        let replay = await NightscoutReadingConfirmation.reconcile([first, second], fetch: { id in
            server[id].map { [$0] } ?? []
        }, upload: { _ in XCTFail("Confirmed IDs must not be posted again"); return false })
        XCTAssertTrue(replay)
    }

    func testNightscoutDoesNotConfirmConflictsFailedPostOrFailedRead() async {
        let reading: [String: Any] = ["_id": "first", "type": "sgv", "date": 1_000, "sgv": 85]
        var conflicting = reading
        conflicting["sgv"] = 90
        let conflict = await NightscoutReadingConfirmation.reconcile([reading], fetch: { _ in [conflicting] }, upload: { _ in
            XCTFail("A real collision must not overwrite server data"); return false
        })
        XCTAssertFalse(conflict)
        let failedPost = await NightscoutReadingConfirmation.reconcile([reading], fetch: { _ in [] }, upload: { _ in false })
        XCTAssertFalse(failedPost)
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, 401, 500] {
            let failedRead = await NightscoutReadingConfirmation.reconcile([reading], fetch: { _ in
                throw NSError(domain: "TestTransport", code: code)
            }, upload: { _ in XCTFail("An unverified read must not lead to blind posting"); return false })
            XCTAssertFalse(failedRead)
        }
    }

    func testNightscoutCode66IsFailureNotBatchReceiptAndCheckpointIsMonotonic() {
        let body = Data(#"{"description":{"code":66}}"#.utf8)
        XCTAssertTrue(NightscoutReadingConfirmation.isDuplicateBatchFailure(status: 500, data: body))
        XCTAssertFalse(NightscoutReadingConfirmation.isDuplicateBatchFailure(status: 401, data: body))
        XCTAssertFalse(NightscoutReadingConfirmation.isDuplicateBatchFailure(status: 500, data: Data("bad response".utf8)))
        let current = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(NightscoutReadingConfirmation.checkpoint(current: current, confirmed: current.addingTimeInterval(-60)), current)
        XCTAssertEqual(NightscoutReadingConfirmation.checkpoint(current: current, confirmed: current.addingTimeInterval(60)), current.addingTimeInterval(60))
    }

    func testHistoricalNightscoutQueueRetainsUnconfirmedAndNewerRevisionsAcrossRestart() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var queue = NightscoutHistoricalQueue(siteFingerprint: "site-fingerprint")
        let old = NightscoutHistoricalQueue.Entry(id: "reading", measuredAt: now.addingTimeInterval(-600), payload: Data("old".utf8))
        queue.enqueue(old, now: now)
        queue = try JSONDecoder().decode(NightscoutHistoricalQueue.self, from: JSONEncoder().encode(queue))
        XCTAssertEqual(queue.entries, [old])
        let corrected = NightscoutHistoricalQueue.Entry(id: old.id, measuredAt: old.measuredAt, payload: Data("corrected".utf8))
        queue.enqueue(corrected, now: now)
        queue.confirm([old])
        XCTAssertEqual(queue.entries, [corrected], "An older in-flight response cannot clear a newer pending payload")
        queue.confirm([corrected])
        XCTAssertTrue(queue.entries.isEmpty)
    }

    func testHealthKitRetryKeepsSyncIdentityAndRevisionAndDoesNotClearNewerValue() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var queue = HealthKitReplacementQueue()
        queue.enqueue(id: "reading", timeStamp: now.addingTimeInterval(-600), value: 85, now: now)
        let original = try XCTUnwrap(queue.entries.first)
        XCTAssertEqual(original.metadata[HKMetadataKeySyncIdentifier] as? String, "xdrip.bg.reading")
        XCTAssertEqual((original.metadata[HKMetadataKeySyncVersion] as? NSNumber)?.int64Value, original.revision)
        queue = try JSONDecoder().decode(HealthKitReplacementQueue.self, from: JSONEncoder().encode(queue))
        queue.enqueue(id: original.id, timeStamp: original.timeStamp, value: original.value, now: now.addingTimeInterval(30))
        XCTAssertEqual(queue.entries, [original], "A retry must retain the persisted sync version")
        queue.enqueue(id: original.id, timeStamp: original.timeStamp, value: 90, now: now.addingTimeInterval(31))
        let corrected = try XCTUnwrap(queue.entries.first)
        XCTAssertGreaterThan(corrected.revision, original.revision)
        queue.confirm(original)
        XCTAssertEqual(queue.entries, [corrected])
        queue.confirm(corrected)
        XCTAssertTrue(queue.entries.isEmpty)
    }

    func testHealthKitLegacyReplacementDoesNotSaveAfterQueryOrDeleteFailure() {
        enum Failure: Error { case query }
        var actions = [String]()
        HealthKitLegacyReplacement.perform(query: { complete in
            complete(.failure(Failure.query))
        }, remove: { (_: [String], complete: (Bool) -> Void) in actions.append("delete"); complete(true) },
           save: { actions.append("save") }, failed: { actions.append("retry") })
        XCTAssertEqual(actions, ["retry"])
        actions.removeAll()
        HealthKitLegacyReplacement.perform(query: { complete in complete(.success(["legacy"])) },
            remove: { _, complete in actions.append("delete"); complete(false) },
            save: { actions.append("save") }, failed: { actions.append("retry") })
        XCTAssertEqual(actions, ["delete", "retry"])
        actions.removeAll()
        HealthKitLegacyReplacement.perform(query: { complete in complete(.success(["legacy"])) },
            remove: { _, complete in actions.append("delete"); complete(true) },
            save: { actions.append("save") }, failed: { actions.append("retry") })
        XCTAssertEqual(actions, ["delete", "save"])
    }

    func testCalendarReplacementPreservesExistingEventWhenSaveFails() {
        enum Failure: Error { case save }
        var actions = [String]()
        XCTAssertThrowsError(try CalendarShareReplacement.perform(save: {
            actions.append("save")
            throw Failure.save
        }, removePrevious: { actions.append("removePrevious") }))
        XCTAssertEqual(actions, ["save"])
        actions.removeAll()
        CalendarShareReplacement.perform(save: { actions.append("save") }, removePrevious: { actions.append("removePrevious") })
        XCTAssertEqual(actions, ["save", "removePrevious"])
    }
}

extension LibreWatchValuePipelineTests {
    @MainActor
    func testLiveGapBoundariesKeepStoredCalibrationHistory() throws {
        // 15:03:55 -> 15:06:54 is a 179-second gap, processed later at 15:09:07.
        // Calibration history comes from storage, not the +/-150-second duplicate window.
        let start = Date(timeIntervalSince1970: 1_788_613_435)
        for gap in [149.0, 150, 151, 179, 290, 291] {
            let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
            let context = stack.mainManagedObjectContext
            let sensor = Sensor(startDate: start.addingTimeInterval(-3_600), nsManagedObjectContext: context)
            let calibration = Calibration(timeStamp: start.addingTimeInterval(-1_800), sensor: sensor,
                bg: 100, rawValue: 100, adjustedRawValue: 100, sensorConfidence: 1,
                rawTimeStamp: start.addingTimeInterval(-1_800), slope: 1.1, intercept: 4,
                distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: 100, slopeConfidence: 1,
                deviceName: nil, nsManagedObjectContext: context)
            let previous = BgReading(timeStamp: start, sensor: sensor, calibration: calibration,
                rawData: 100, deviceName: nil, nsManagedObjectContext: context)
            previous.calculatedValue = 114
            previous.ageAdjustedRawValue = 100
            XCTAssertTrue(stack.saveChanges())
            let incomingAt = start.addingTimeInterval(gap)
            XCTAssertEqual(GlucoseReadingInsertionPolicy.disposition(measuredAt: incomingAt,
                latestStoredAt: start, isNewestInBatch: true, historicalOnly: false,
                hasSameSlot: gap <= 150), .live)

            let accessor = BgReadingsAccessor(coreDataManager: stack)
            var history = accessor.calibrationHistory(before: incomingAt, for: sensor)
            XCTAssertEqual(history.map(\.id), [previous.id], "gap=\(gap)")
            var calibrations = [calibration]
            let result = Libre1Calibrator().createNewBgReading(rawData: 110_000,
                timeStamp: incomingAt, sensor: sensor, last3Readings: &history,
                lastCalibrationsForActiveSensorInLastXDays: &calibrations,
                firstCalibration: calibration, lastCalibration: calibration, deviceName: nil,
                nsManagedObjectContext: context)
            XCTAssertEqual(result.calculatedValue, 125, accuracy: 0.000_001)
            XCTAssertTrue(result.isValidForDownstream)
            XCTAssertTrue(stack.saveChanges())
            XCTAssertEqual(accessor.last(forSensor: sensor, includingSuppressed: true)?.timeStamp, incomingAt)
        }
    }

    @MainActor
    func testExistingCalibrationCalculatesEvenWithoutPreviousRows() {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = stack.mainManagedObjectContext
        let now = Date(timeIntervalSince1970: 1_788_613_807)
        let sensor = Sensor(startDate: now.addingTimeInterval(-3_600), nsManagedObjectContext: context)
        let calibration = Calibration(timeStamp: now.addingTimeInterval(-1_800), sensor: sensor,
            bg: 100, rawValue: 100, adjustedRawValue: 100, sensorConfidence: 1,
            rawTimeStamp: now.addingTimeInterval(-1_800), slope: 1.1, intercept: 4,
            distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: 100, slopeConfidence: 1,
            deviceName: nil, nsManagedObjectContext: context)
        let calibrators: [Calibrator] = [Libre1Calibrator(), Libre1NonFixedSlopeCalibrator()]
        for calibrator in calibrators {
            var history = [BgReading]()
            var calibrations = [calibration]
            let result = calibrator.createNewBgReading(rawData: 110_000, timeStamp: now, sensor: sensor,
                last3Readings: &history, lastCalibrationsForActiveSensorInLastXDays: &calibrations,
                firstCalibration: calibration, lastCalibration: calibration, deviceName: nil,
                nsManagedObjectContext: context)
            XCTAssertEqual(result.calculatedValue, 125, accuracy: 0.000_001)
            XCTAssertTrue(result.isValidForDownstream)
        }
    }

    @MainActor
    func testDelayedCalibrationContextExcludesFutureAndOtherSensorRows() {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = stack.mainManagedObjectContext
        let now = Date(timeIntervalSince1970: 1_788_613_807)
        let sensor = Sensor(startDate: now.addingTimeInterval(-3_600), nsManagedObjectContext: context)
        let otherSensor = Sensor(startDate: now.addingTimeInterval(-4_000), nsManagedObjectContext: context)
        let earlier = BgReading(timeStamp: now.addingTimeInterval(-600), sensor: sensor,
            calibration: nil, rawData: 100, deviceName: nil, nsManagedObjectContext: context)
        earlier.calculatedValue = 100
        let later = BgReading(timeStamp: now, sensor: sensor, calibration: nil,
            rawData: 120, deviceName: nil, nsManagedObjectContext: context)
        later.calculatedValue = 120
        let other = BgReading(timeStamp: now.addingTimeInterval(-450), sensor: otherSensor,
            calibration: nil, rawData: 110, deviceName: nil, nsManagedObjectContext: context)
        other.calculatedValue = 110
        XCTAssertTrue(stack.saveChanges())
        let delayedAt = now.addingTimeInterval(-300)
        let disposition = GlucoseReadingInsertionPolicy.disposition(measuredAt: delayedAt,
            latestStoredAt: now, isNewestInBatch: true, historicalOnly: false, hasSameSlot: false)
        XCTAssertEqual(disposition, .historical)
        let history = BgReadingsAccessor(coreDataManager: stack).calibrationHistory(before: delayedAt, for: sensor)
        XCTAssertEqual(history.map(\.id), [earlier.id])
        XCTAssertFalse(LibreWatchGlucoseProcessingMode.historicalBackfill.permitsCurrentValueAndLiveSideEffects)
        XCTAssertEqual(later.calculatedValue, 120)
    }
}

final class LibreWatchValuePipelineTests: XCTestCase {
    private let receivedAt = Date(timeIntervalSince1970: 1_788_333_200)

    override func tearDown() {
        clearPhoneLibreParserCache()
        super.tearDown()
    }

    func testSameDecryptedFrameProducesSameNativeValueOnWatchAndIPhone() throws {
        let frame = decryptedFrame(currentRaw: 847, previousRaw: 830)
        let watchReading = try Libre2WatchDirectAlgorithms.parseDirectReading(
            decryptedData: frame,
            parameters: watchAlgorithmParameters,
            receivedAt: receivedAt
        )

        let phoneReading = phoneParsedValue(frame: frame, parameters: phoneAlgorithmParameters)

        XCTAssertEqual(watchReading.rawGlucose, 847)
        XCTAssertEqual(watchReading.previousRawGlucose, 830)
        XCTAssertEqual(watchReading.nativeGlucoseMGDL, phoneReading, accuracy: 0.000_001)
    }

    func testRawGlucoseTimesLibreMultiplierMatchesNormalIPhoneXDripInput() throws {
        let frame = decryptedFrame(currentRaw: 847, previousRaw: 830)
        let watchReading = try Libre2WatchDirectAlgorithms.parseDirectReading(
            decryptedData: frame,
            parameters: watchAlgorithmParameters,
            receivedAt: receivedAt
        )
        let payload = watchReading.payload(
            sessionID: session.id,
            valueDomain: .xDripRawGlucose,
            calibrationRevision: 10
        )

        let phoneInput = phoneParsedValue(frame: frame, parameters: nil)

        XCTAssertEqual(payload.xDripCalibrationInput, Double(847) * ConstantsBloodGlucose.libreMultiplier)
        XCTAssertEqual(payload.xDripCalibrationInput, phoneInput, accuracy: 0.000_001)
    }

    func testWatchAndIPhoneFinalValuesMatchForFixedAndNonFixedSlope() throws {
        let reading = payload(raw: 900, previousRaw: 875, domain: .xDripRawGlucose)

        for calibrationType in [LibreWatchCalibrationType.fixedSlope, .nonFixedSlope] {
            let snapshot = calibration(
                type: calibrationType,
                slope: 1.08,
                intercept: -7.5
            )
            let iPhoneDivider = calibrationType == .fixedSlope
                ? Libre1Calibrator().rawValueDivider
                : Libre1NonFixedSlopeCalibrator().rawValueDivider
            let expectedIPhoneValue = iphoneCalibratedValue(
                input: reading.xDripCalibrationInput,
                slope: snapshot.slope,
                intercept: snapshot.intercept,
                divider: iPhoneDivider
            )

            XCTAssertEqual(snapshot.rawValueDivider, iPhoneDivider)
            let watchValue = try XCTUnwrap(snapshot.displayedGlucose(for: reading))
            XCTAssertEqual(watchValue, expectedIPhoneValue, accuracy: 0.000_001)
        }
    }

    func testFactoryValueUsesNativeDomainWithoutSecondCalibration() throws {
        let reading = payload(
            native: 112.4,
            previousNative: 110.2,
            raw: 950,
            previousRaw: 930,
            domain: .factoryNativeMGDL
        )
        let snapshot = calibration(type: .factoryCalibrated, slope: 1, intercept: 0)

        let watchValue = try XCTUnwrap(snapshot.displayedGlucose(for: reading))
        XCTAssertEqual(watchValue, 112.4, accuracy: 0.000_001)
        XCTAssertEqual(reading.sourceValue(for: snapshot.requiredValueDomain), 112.4, accuracy: 0.000_001)
        XCTAssertNotEqual(watchValue, reading.xDripCalibrationInput)
    }

    func testNativeFourPointSevenDoesNotBecomeLowWithXDripCalibration() throws {
        let reading = payload(
            native: 4.7 / ConstantsBloodGlucose.mgDlToMmoll,
            previousNative: 82,
            raw: 720,
            previousRaw: 700,
            domain: .xDripRawGlucose
        )
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let iPhoneDivider = Libre1Calibrator().rawValueDivider

        let displayed = try XCTUnwrap(snapshot.displayedGlucose(for: reading))
        XCTAssertEqual(displayed, Double(720) * ConstantsBloodGlucose.libreMultiplier / iPhoneDivider, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(displayed, 40)
        XCTAssertEqual(displayed * ConstantsBloodGlucose.mgDlToMmoll, 4.7, accuracy: 0.02)

        let formerWrongDomainResult = iphoneCalibratedValue(
            input: reading.nativeGlucoseMGDL,
            slope: 1,
            intercept: 0,
            divider: 1_000
        )
        XCTAssertEqual(formerWrongDomainResult, 38)
        XCTAssertNotEqual(displayed, formerWrongDomainResult)
    }

    func testTrendAndDeltaUseSelectedDomainWithoutIntercept() throws {
        let reading = payload(raw: 900, previousRaw: 850, domain: .xDripRawGlucose)
        let snapshot = calibration(type: .nonFixedSlope, slope: 1.2, intercept: 45)
        let sourceDifference = Double(60) * ConstantsBloodGlucose.libreMultiplier

        let expectedTrend = 1.2 * (
            (Double(900 - 850) * ConstantsBloodGlucose.libreMultiplier) / 2
        ) / 1_000
        let expectedDelta = 1.2 * sourceDifference / 1_000

        let watchTrend = try XCTUnwrap(snapshot.displayedTrend(for: reading))
        let watchDelta = try XCTUnwrap(snapshot.displayedDelta(sourceDelta: sourceDifference))
        XCTAssertEqual(watchTrend, expectedTrend, accuracy: 0.000_001)
        XCTAssertEqual(watchDelta, expectedDelta, accuracy: 0.000_001)
        XCTAssertNotEqual(watchTrend, expectedTrend + snapshot.intercept)
        XCTAssertNotEqual(watchDelta, expectedDelta + snapshot.intercept)
    }

    func testOldOrIncompletePayloadCannotProduceOrPersistFalseLow() throws {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let oldVersion = payload(
            version: 1,
            raw: 720,
            previousRaw: 700,
            domain: .xDripRawGlucose
        )
        let incomplete = payload(
            raw: 0,
            previousRaw: 700,
            domain: .xDripRawGlucose
        )

        XCTAssertFalse(oldVersion.isValid(for: snapshot))
        XCTAssertFalse(incomplete.isValid(for: snapshot))
        XCTAssertNil(snapshot.displayedGlucose(for: oldVersion))
        XCTAssertNil(snapshot.displayedGlucose(for: incomplete))

        let legacyJSON = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString,
            "sessionID": session.id.uuidString,
            "glucoseMGDL": 84.7,
            "sensorTimeInMinutes": 1_000,
            "receivedAt": receivedAt.timeIntervalSinceReferenceDate
        ])
        XCTAssertNil(try? JSONDecoder().decode(LibreWatchDirectReadingPayload.self, from: legacyJSON))

        let defaults = isolatedDefaults()
        defaults.set(legacyJSON, forKey: LibreWatchMessageKey.legacyPersistedReading)
        XCTAssertNil(LibreWatchSessionStore.loadReading(defaults: defaults))
        XCTAssertNil(defaults.data(forKey: LibreWatchMessageKey.legacyPersistedReading))
    }

    func testCalibrationAndAlgorithmStayStableAcrossOwnershipCycle() {
        let defaults = isolatedDefaults()
        let snapshot = calibration(type: .nonFixedSlope, slope: 1.17, intercept: -11)
        LibreWatchSessionStore.saveSession(session, defaults: defaults)
        LibreWatchSessionStore.saveCalibration(snapshot, defaults: defaults)

        var ownership = LibreWatchOwnership.iphone
        for next in [
            LibreWatchOwnership.releasingToWatch,
            .watch,
            .watch,
            .releasingToPhone,
            .iphone
        ] {
            XCTAssertTrue(ownership.canTransition(to: next))
            ownership = next
            LibreWatchSessionStore.saveOwnership(ownership, defaults: defaults)
            XCTAssertEqual(LibreWatchSessionStore.loadCalibration(defaults: defaults), snapshot)
            XCTAssertEqual(
                LibreWatchSessionStore.loadCalibration(defaults: defaults)?.requiredValueDomain,
                .xDripRawGlucose
            )
        }
    }

    func testReadingOlderThanThreeMinutesKeepsValueButHidesTrendAndDelta() throws {
        let reading = payload(raw: 900, previousRaw: 875, domain: .xDripRawGlucose)
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let sourceDelta = Double(25) * ConstantsBloodGlucose.libreMultiplier

        let current = try XCTUnwrap(snapshot.presentation(
            for: reading,
            sourceDelta: sourceDelta,
            at: receivedAt.addingTimeInterval(179)
        ))
        let stale = try XCTUnwrap(snapshot.presentation(
            for: reading,
            sourceDelta: sourceDelta,
            at: receivedAt.addingTimeInterval(181)
        ))

        XCTAssertFalse(current.isStale)
        XCTAssertNotNil(current.trendMGDLPerMinute)
        XCTAssertNotNil(current.deltaMGDL)
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.glucoseMGDL, current.glucoseMGDL, accuracy: 0.000_001)
        XCTAssertNil(stale.trendMGDLPerMinute)
        XCTAssertNil(stale.deltaMGDL)
    }

    func testDirectDeltaAcceptsThreeMinuteBoundaryButRejectsLongSuspensionGap() throws {
        let snapshot = calibration(type: .fixedSlope, slope: 1.1, intercept: 20)
        let previous = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: receivedAt
        )
        let boundary = payload(
            raw: 820,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: receivedAt.addingTimeInterval(LibreWatchDirectDeltaPolicy.maximumGap)
        )
        let afterSuspension = payload(
            raw: 830,
            previousRaw: 820,
            domain: .xDripRawGlucose,
            sensorTime: 1_002,
            at: receivedAt.addingTimeInterval(LibreWatchDirectDeltaPolicy.maximumGap + 0.001)
        )

        XCTAssertEqual(
            try XCTUnwrap(LibreWatchDirectDeltaPolicy.sourceDelta(
                current: boundary,
                previous: previous,
                calibration: snapshot
            )),
            boundary.xDripCalibrationInput - previous.xDripCalibrationInput,
            accuracy: 0.000_001
        )
        XCTAssertNil(LibreWatchDirectDeltaPolicy.sourceDelta(
            current: afterSuspension,
            previous: previous,
            calibration: snapshot
        ))
    }

    func testDirectDeltaRejectsWrongSessionDomainRevisionAndSensorOrder() {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0, revision: 10)
        let previous = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: receivedAt,
            revision: 10
        )
        let wrongSession = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: receivedAt.addingTimeInterval(60),
            sessionID: UUID()
        )
        let wrongDomain = payload(
            raw: 810,
            previousRaw: 800,
            domain: .factoryNativeMGDL,
            sensorTime: 1_001,
            at: receivedAt.addingTimeInterval(60)
        )
        let wrongRevision = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: receivedAt.addingTimeInterval(60),
            revision: 9
        )
        let nonIncreasingSensorTime = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: receivedAt.addingTimeInterval(60)
        )

        for current in [wrongSession, wrongDomain, wrongRevision, nonIncreasingSensorTime] {
            XCTAssertNil(LibreWatchDirectDeltaPolicy.sourceDelta(
                current: current,
                previous: previous,
                calibration: snapshot
            ))
        }
    }

    func testFortyEightMinuteGapFromNinePointSevenToSixPointSevenHasNoDeltaButKeepsTrend() throws {
        let snapshot = calibration(type: .factoryCalibrated, slope: 1, intercept: 0)
        let previous = payload(
            native: 9.7 * ConstantsBloodGlucose.mmollToMgdl,
            previousNative: 9.6 * ConstantsBloodGlucose.mmollToMgdl,
            raw: 900,
            previousRaw: 890,
            domain: .factoryNativeMGDL,
            sensorTime: 1_000,
            at: receivedAt
        )
        let current = payload(
            native: 6.7 * ConstantsBloodGlucose.mmollToMgdl,
            previousNative: 6.6 * ConstantsBloodGlucose.mmollToMgdl,
            raw: 700,
            previousRaw: 690,
            domain: .factoryNativeMGDL,
            sensorTime: 1_048,
            at: receivedAt.addingTimeInterval(48 * 60)
        )

        let sourceDelta = LibreWatchDirectDeltaPolicy.sourceDelta(
            current: current,
            previous: previous,
            calibration: snapshot
        )
        let presentation = try XCTUnwrap(snapshot.presentation(
            for: current,
            sourceDelta: sourceDelta,
            at: current.receivedAt.addingTimeInterval(1)
        ))

        XCTAssertNil(sourceDelta)
        XCTAssertNil(presentation.deltaMGDL)
        XCTAssertNotNil(presentation.trendMGDLPerMinute)
    }

    func testActiveApplicationAllowsRecoveryWithoutExtendedRuntime() {
        XCTAssertTrue(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: true,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.shouldStartExtendedRuntime(
            userInitiatedTakeover: true,
            applicationIsActive: true,
            ownership: .watch,
            alreadyHasSession: false
        ))
    }

    func testInactiveApplicationAllowsRecoveryWhileExtendedRuntimeIsRunning() {
        XCTAssertTrue(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: false,
            extendedRuntimeIsRunning: true,
            ownership: .watch
        ))
    }

    func testInactiveWatchOwnerPreservesCoreBluetoothWithoutStartingTimedRecovery() {
        XCTAssertFalse(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: false,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(
            ownership: .watch
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.shouldStartExtendedRuntime(
            userInitiatedTakeover: false,
            applicationIsActive: true,
            ownership: .watch,
            alreadyHasSession: false
        ))
    }

    func testSystemAutoReconnectDoesNotStartParallelManualConnection() {
        let action = LibreWatchLifecyclePolicy.disconnectRecoveryAction(
            isDeliberate: false,
            systemIsReconnecting: true,
            ownership: .watch
        )

        XCTAssertEqual(action, .waitForSystemReconnect)
        XCTAssertNotEqual(action, .reconnectManually)
    }

    func testLongInactivePeriodPreservesEventDrivenRecoveryAfterForegroundRefresh() {
        XCTAssertFalse(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: false,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: true,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(
            ownership: .watch
        ))
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.disconnectRecoveryAction(
                isDeliberate: false,
                systemIsReconnecting: true,
                ownership: .watch
            ),
            .waitForSystemReconnect
        )
    }

    func testInactiveWatchOwnerAllowsOnlyOneManualConnectPerDisconnectDelivery() {
        let action = LibreWatchLifecyclePolicy.disconnectRecoveryAction(
            isDeliberate: false,
            systemIsReconnecting: false,
            ownership: .watch
        )
        var disconnectWasHandled = false
        var manualConnectCount = 0

        for _ in 0 ..< 2 {
            guard LibreWatchLifecyclePolicy.shouldHandleDisconnect(
                alreadyHandled: disconnectWasHandled
            ) else { continue }
            disconnectWasHandled = true
            if action == .reconnectManually {
                manualConnectCount += 1
            }
        }

        XCTAssertEqual(action, .reconnectManually)
        XCTAssertEqual(manualConnectCount, 1)
    }

    func testSuspendedWatchOwnerStartsNoFallbackTimerOrScanLoop() {
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.reconnectFallbackAction(
                deadline: receivedAt.addingTimeInterval(90),
                now: receivedAt.addingTimeInterval(300),
                applicationIsActive: false,
                extendedRuntimeIsRunning: false,
                ownership: .watch
            ),
            .noAdditionalWork
        )
        XCTAssertNil(LibreWatchLifecyclePolicy.noDataRecoveryDelay(
            applicationIsActive: false,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
    }

    func testReceivingSuspensionResumesBudgetWithoutImmediateBluetoothAction() throws {
        var timing = LibreWatchConnectionTiming()
        let firstFrameAt = receivedAt
        timing.receivedPacketOrEnabledNotifications(at: firstFrameAt)
        timing.recordReceivingProgress(
            at: firstFrameAt,
            timeout: 120,
            executionIsAvailable: true,
            monotonicTime: 1_000
        )
        let generation = timing.generation
        let beforeSuspension = try XCTUnwrap(timing.deadline)

        let suspendedAt = firstFrameAt.addingTimeInterval(30)
        XCTAssertTrue(timing.setExecutionAvailable(
            false,
            at: suspendedAt,
            monotonicTime: 1_030
        ))
        XCTAssertNil(timing.deadline)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(
                at: suspendedAt,
                monotonicTime: 1_030
            )),
            90,
            accuracy: 0.000_001
        )

        // Several wall-clock minutes without execution do not consume the paused allowance.
        let resumedAt = suspendedAt.addingTimeInterval(20 * 60)
        XCTAssertTrue(timing.setExecutionAvailable(
            true,
            at: resumedAt,
            monotonicTime: 2_500
        ))
        let resumed = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(timing.generation, generation)
        XCTAssertEqual(resumed.expiresAt, resumedAt.addingTimeInterval(90))
        XCTAssertFalse(timing.timeoutIsCurrent(
            beforeSuspension,
            ownership: .watch,
            cancelling: false,
            at: resumedAt,
            monotonicTime: 2_500
        ))
        XCTAssertFalse(timing.timeoutIsCurrent(
            resumed,
            ownership: .watch,
            cancelling: false,
            at: resumedAt,
            monotonicTime: 2_500
        ))
        let timeoutIsDue = timing.timeoutIsCurrent(
            resumed,
            ownership: .watch,
            cancelling: false,
            at: resumedAt,
            monotonicTime: 2_500
        )
        let recordedBluetoothActions: [LibreWatchExpiredPhaseAction] = timeoutIsDue
            ? [LibreWatchExpiredPhasePolicy.action(
                phase: timing.phase,
                peripheralState: .connected,
                ownership: .watch,
                cancellationIsActive: false
            )]
            : []
        XCTAssertTrue(recordedBluetoothActions.isEmpty) // no cancel, scan, or connect
    }

    func testValidFrameAfterResumeInvalidatesOldTimerBeforeDownstreamDecision() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        timing.recordReceivingProgress(
            at: receivedAt,
            timeout: 120,
            executionIsAvailable: true,
            monotonicTime: 100
        )
        XCTAssertTrue(timing.setExecutionAvailable(
            false,
            at: receivedAt.addingTimeInterval(20),
            monotonicTime: 120
        ))
        let resumedAt = receivedAt.addingTimeInterval(900)
        XCTAssertTrue(timing.setExecutionAvailable(
            true,
            at: resumedAt,
            monotonicTime: 900
        ))
        let resumeTimer = try XCTUnwrap(timing.deadline)

        var liveness = LibreWatchFrameLiveness()
        let frameAt = resumedAt.addingTimeInterval(61)
        liveness.validFrame(at: frameAt)
        timing.receivedPacketOrEnabledNotifications(at: frameAt)
        timing.recordReceivingProgress(
            at: frameAt,
            timeout: 120,
            executionIsAvailable: true,
            monotonicTime: 961
        )
        let accepted = false // duplicate/out-of-order clinical payload

        XCTAssertFalse(accepted)
        XCTAssertEqual(liveness.lastValidBLEFrameAt, frameAt)
        XCTAssertEqual(timing.dataExpectedSince, frameAt)
        XCTAssertFalse(timing.timeoutIsCurrent(
            resumeTimer,
            ownership: .watch,
            cancelling: false,
            at: resumeTimer.expiresAt,
            monotonicTime: try XCTUnwrap(resumeTimer.monotonicExpiresAt)
        ))
        XCTAssertNotEqual(timing.deadline?.token, resumeTimer.token)
    }

    func testRestoredConnectedStreamWaitsForPoweredOnThenReusesExactNotificationStream() {
        let generation = UUID()
        var restoration = LibreWatchRestorationState(
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: generation
        )

        XCTAssertEqual(restorationAction(
            &restoration,
            generation: generation,
            centralIsPoweredOn: false
        ), .waitForBluetooth)
        XCTAssertFalse(restoration.awaitingStreamEvidence)

        XCTAssertEqual(restorationAction(
            &restoration,
            generation: generation
        ), .awaitExistingStream)
        XCTAssertTrue(restoration.awaitingStreamEvidence)
    }

    func testPartialRestorationDiscoversOnlyTheFirstMissingLayer() {
        let generation = UUID()
        XCTAssertEqual(freshRestorationAction(
            generation: generation,
            hasService: false,
            hasWriteCharacteristic: false,
            hasReceiveCharacteristic: false,
            receiveIsNotifying: false
        ),
                       .discoverServices)
        XCTAssertEqual(freshRestorationAction(
            generation: generation,
            hasService: true,
            hasWriteCharacteristic: true,
            hasReceiveCharacteristic: false,
            receiveIsNotifying: false
        ),
                       .discoverCharacteristics)
        XCTAssertEqual(freshRestorationAction(
            generation: generation,
            hasService: true,
            hasWriteCharacteristic: true,
            hasReceiveCharacteristic: true,
            receiveIsNotifying: false
        ),
                       .enableNotifications)
        XCTAssertEqual(freshRestorationAction(
            generation: generation,
            hasService: true,
            hasWriteCharacteristic: true,
            hasReceiveCharacteristic: true,
            receiveIsNotifying: true
        ),
                       .awaitExistingStream)
    }

    func testRepeatedRestorationCallbacksDoNotRenewInFlightGATTBudget() throws {
        let generation = UUID()
        var restoration = LibreWatchRestorationState(
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: generation
        )
        var timing = LibreWatchConnectionTiming()
        timing.beginSetup(at: receivedAt, startingAt: .notifications)
        let original = try XCTUnwrap(timing.deadline)

        for _ in 0 ..< 5 {
            XCTAssertEqual(restorationAction(
                &restoration,
                generation: generation,
                connectionPhase: timing.phase
            ), .waitForCurrentOperation)
        }
        XCTAssertEqual(timing.deadline, original)
    }

    func testUnknownRestoredUnlockStatusGetsOneBoundedUnlockAttempt() throws {
        let generation = UUID()
        let token = UUID()
        var restoration = LibreWatchRestorationState(
            token: token,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: generation
        )
        XCTAssertEqual(restorationAction(
            &restoration,
            generation: generation
        ), .awaitExistingStream)

        XCTAssertTrue(restoration.claimUnknownUnlockRecovery(
            capturedToken: token,
            currentGeneration: generation,
            phase: .notifications,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            ownership: .watch,
            cancellationIsActive: false
        ))
        XCTAssertFalse(restoration.claimUnknownUnlockRecovery(
            capturedToken: token,
            currentGeneration: generation,
            phase: .notifications,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            ownership: .watch,
            cancellationIsActive: false
        ))
    }

    func testRestoredFrameEvidencePreventsFallbackUnlockAndPreservesStream() {
        let generation = UUID()
        let token = UUID()
        var restoration = LibreWatchRestorationState(
            token: token,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: generation
        )
        restoration.beginAwaitingStreamEvidence()
        restoration.recordStreamEvidence()

        XCTAssertFalse(restoration.claimUnknownUnlockRecovery(
            capturedToken: token,
            currentGeneration: generation,
            phase: .notifications,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            ownership: .watch,
            cancellationIsActive: false
        ))
        XCTAssertEqual(restorationAction(
            &restoration,
            generation: generation,
            connectionPhase: .receiving
        ), .preserveActiveStream)
    }

    func testNewRestoredConnectionGenerationRequiresFreshStreamEvidence() {
        let oldGeneration = UUID()
        var restoration = LibreWatchRestorationState(
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: oldGeneration
        )
        restoration.beginAwaitingStreamEvidence()
        restoration.recordStreamEvidence()

        let newGeneration = UUID()
        restoration.beginConnectionGeneration(newGeneration)

        XCTAssertEqual(restoration.generation, newGeneration)
        XCTAssertFalse(restoration.streamEvidenceWasReceived)
        XCTAssertFalse(restoration.awaitingStreamEvidence)
        XCTAssertFalse(restoration.unlockWasRequested)
        XCTAssertEqual(restorationAction(
            &restoration,
            generation: newGeneration
        ), .awaitExistingStream)
    }

    func testRestorationRejectsChangedOwnershipSessionGenerationAndStaleObjects() {
        let generation = UUID()
        let token = UUID()
        var restoration = LibreWatchRestorationState(
            token: token,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: generation
        )
        restoration.beginAwaitingStreamEvidence()

        XCTAssertFalse(restoration.claimUnknownUnlockRecovery(
            capturedToken: token,
            currentGeneration: generation,
            phase: .notifications,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            ownership: .iphone,
            cancellationIsActive: false
        ))
        XCTAssertFalse(restoration.claimUnknownUnlockRecovery(
            capturedToken: token,
            currentGeneration: UUID(),
            phase: .notifications,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            ownership: .watch,
            cancellationIsActive: false
        ))
        XCTAssertFalse(restoration.claimUnknownUnlockRecovery(
            capturedToken: token,
            currentGeneration: generation,
            phase: .notifications,
            sessionID: UUID(),
            sensorIdentity: session.redactedIdentity(),
            ownership: .watch,
            cancellationIsActive: false
        ))

        let current = NSObject()
        let stale = NSObject()
        XCTAssertTrue(LibreWatchRestoredObjectIdentity.isCurrent(current, expected: current))
        XCTAssertFalse(LibreWatchRestoredObjectIdentity.isCurrent(stale, expected: current))
        XCTAssertFalse(LibreWatchRestoredObjectIdentity.isCurrent(current, expected: nil))
    }

    func testRestoredGATTPhaseHasFreshBudgetIndependentOfOldConnectionAge() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(at: receivedAt, applicationIsActive: false)
        let oldConnection = try XCTUnwrap(timing.deadline)
        let connectedAt = receivedAt.addingTimeInterval(300)
        timing.beginSetup(at: connectedAt, startingAt: .notifications)
        let restoredSetup = try XCTUnwrap(timing.deadline)

        XCTAssertEqual(timing.phase, .notifications)
        XCTAssertEqual(restoredSetup.expiresAt, connectedAt.addingTimeInterval(60))
        XCTAssertFalse(timing.timeoutIsCurrent(
            oldConnection,
            ownership: .watch,
            cancelling: false,
            at: oldConnection.expiresAt
        ))
    }

    func testReceivingBudgetExpiresOnceAndStillRequiresConfirmedCancellation() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        timing.recordReceivingProgress(
            at: receivedAt,
            timeout: 120,
            executionIsAvailable: true,
            monotonicTime: 1_000
        )
        let deadline = try XCTUnwrap(timing.deadline)
        let expiryUptime = try XCTUnwrap(deadline.monotonicExpiresAt)
        XCTAssertTrue(timing.timeoutIsCurrent(
            deadline,
            ownership: .watch,
            cancelling: false,
            at: deadline.expiresAt,
            monotonicTime: expiryUptime
        ))
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: timing.phase,
                peripheralState: .connected,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .beginControlledRecovery
        )

        timing.beginCancellation(at: deadline.expiresAt)
        XCTAssertFalse(timing.timeoutIsCurrent(
            deadline,
            ownership: .watch,
            cancelling: true,
            at: deadline.expiresAt,
            monotonicTime: expiryUptime
        ))
        XCTAssertFalse(timing.canStartBluetoothOperation)
        let cancellation = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(timing.finishCancellation(
            cancellation,
            ownership: .watch,
            returningToPhone: false,
            peripheralIsDisconnected: true,
            at: deadline.expiresAt.addingTimeInterval(1)
        ), .confirmedDisconnected)
        XCTAssertTrue(timing.canStartBluetoothOperation)
    }

    func testReceivingLifecycleChurnCannotRefillFiniteExecutionBudget() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        timing.recordReceivingProgress(
            at: receivedAt,
            timeout: 120,
            executionIsAvailable: true,
            monotonicTime: 0
        )
        let generation = timing.generation
        var wallTime = receivedAt
        var uptime: TimeInterval = 0

        for (cycle, consumed) in [30.0, 20.0, 20.0].enumerated() {
            wallTime = wallTime.addingTimeInterval(consumed)
            uptime += consumed
            XCTAssertTrue(timing.setExecutionAvailable(
                false,
                at: wallTime,
                monotonicTime: uptime
            ))
            wallTime = wallTime.addingTimeInterval(10_000)
            let remaining = try XCTUnwrap(timing.remainingExecutionTime(
                at: wallTime,
                monotonicTime: uptime
            ))
            XCTAssertEqual(remaining, 90 - TimeInterval(cycle * 20), accuracy: 0.000_001)
            XCTAssertFalse(timing.setExecutionAvailable(
                false,
                at: wallTime,
                monotonicTime: uptime
            ))
            XCTAssertTrue(timing.setExecutionAvailable(
                true,
                at: wallTime,
                monotonicTime: uptime
            ))
        }

        XCTAssertEqual(timing.generation, generation)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(
                at: wallTime.addingTimeInterval(20),
                monotonicTime: 90
            )),
            30,
            accuracy: 0.000_001
        )
    }

    func testInactiveAndBackgroundRemainDistinctWithoutClaimingTimerExecution() {
        XCTAssertTrue(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationState: .active,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationState: .inactive,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationState: .background,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationState: .inactive,
            extendedRuntimeIsRunning: true,
            ownership: .watch
        ))
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.receivingExecutionBudget(
                applicationState: .active,
                extendedRuntimeIsRunning: false
            ),
            120
        )
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.receivingExecutionBudget(
                applicationState: .background,
                extendedRuntimeIsRunning: true
            ),
            180
        )
    }

    func testExpiredReceivingTimerReconcilesSystemReconnectInsteadOfCancellingIt() {
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .receiving,
                peripheralState: .connecting,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .reconcileObservedLink
        )
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .notifications,
                peripheralState: .disconnected,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .reconcileObservedLink
        )
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .connection,
                peripheralState: .connected,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .beginGATTSetup
        )
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .connection,
                peripheralState: .connecting,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .beginControlledRecovery
        )
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .connection,
                peripheralState: .disconnected,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .beginControlledRecovery,
            "an expired system reconnect must not reschedule the same zero-second deadline"
        )
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .receiving,
                peripheralState: .connected,
                ownership: .iphone,
                cancellationIsActive: false
            ),
            .noAdditionalWork
        )
    }

    func testConnectionBudgetsStartWithSixtyForegroundOrNinetyRuntimeSeconds() throws {
        for (active, duration) in [(true, 60.0), (false, 90.0)] {
            var timing = LibreWatchConnectionTiming()
            timing.beginConnection(
                at: receivedAt,
                applicationIsActive: active,
                executionIsAvailable: true
            )
            let deadline = try XCTUnwrap(timing.deadline)
            XCTAssertEqual(deadline.expiresAt, receivedAt.addingTimeInterval(duration))
            XCTAssertEqual(
                try XCTUnwrap(timing.remainingExecutionTime(at: receivedAt)),
                duration,
                accuracy: 0.000_001
            )
            XCTAssertFalse(timing.timeoutIsCurrent(
                deadline, ownership: .watch, cancelling: false,
                at: receivedAt.addingTimeInterval(duration - 1)
            ))
            XCTAssertTrue(timing.timeoutIsCurrent(
                deadline, ownership: .watch, cancelling: false, at: deadline.expiresAt
            ))
        }
    }

    func testEighteenMinuteTwentyNineSecondSuspensionPreservesRemainingExecutionBudget() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(
            at: receivedAt,
            applicationIsActive: true,
            executionIsAvailable: true
        )
        let prePause = try XCTUnwrap(timing.deadline)
        let pausedAt = receivedAt.addingTimeInterval(12)

        XCTAssertTrue(timing.setExecutionAvailable(false, at: pausedAt))
        XCTAssertNil(timing.deadline)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: pausedAt)),
            48,
            accuracy: 0.000_001
        )
        XCTAssertFalse(timing.timeoutIsCurrent(
            prePause,
            ownership: .watch,
            cancelling: false,
            at: pausedAt.addingTimeInterval(18 * 60 + 29)
        ))

        let resumedAt = pausedAt.addingTimeInterval(18 * 60 + 29)
        XCTAssertTrue(timing.setExecutionAvailable(true, at: resumedAt))
        let resumed = try XCTUnwrap(timing.deadline)
        XCTAssertNotEqual(resumed.token, prePause.token)
        XCTAssertEqual(resumed.expiresAt, resumedAt.addingTimeInterval(48))
        XCTAssertFalse(timing.timeoutIsCurrent(
            resumed,
            ownership: .watch,
            cancelling: false,
            at: resumedAt.addingTimeInterval(47.999)
        ))
        XCTAssertTrue(timing.timeoutIsCurrent(
            resumed,
            ownership: .watch,
            cancelling: false,
            at: resumed.expiresAt
        ))
    }

    func testDocumentedBackgroundConnectingEpisodeStartsPausedAndDoesNotCancelOnWake() throws {
        var timing = LibreWatchConnectionTiming()
        let observedConnectingAt = receivedAt
        timing.beginConnection(
            at: observedConnectingAt,
            applicationIsActive: false,
            executionIsAvailable: false
        )
        let generation = timing.generation

        XCTAssertNil(timing.deadline)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: observedConnectingAt)),
            90,
            accuracy: 0.000_001
        )

        let foregroundWake = observedConnectingAt.addingTimeInterval(3 * 60 * 60)
        XCTAssertTrue(timing.setExecutionAvailable(true, at: foregroundWake))
        let armed = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(timing.generation, generation)
        XCTAssertEqual(armed.expiresAt, foregroundWake.addingTimeInterval(90))
        XCTAssertFalse(timing.timeoutIsCurrent(
            armed,
            ownership: .watch,
            cancelling: false,
            at: foregroundWake
        ))
    }

    func testOnlyCoreBluetoothCallbacksGrantEventDrivenBluetoothActions() {
        let callbackSources: [LibreWatchRecoveryReconcileSource] = [
            .centralStateUpdate,
            .stateRestoration,
            .didConnect,
            .didFailToConnect,
            .didDisconnect,
            .gattCallback,
            .bleNotification
        ]
        let lifecycleAndTimerSources: [LibreWatchRecoveryReconcileSource] = [
            .initialPreparation,
            .sceneActivation,
            .sceneDeactivation,
            .sceneInactive,
            .sceneBackground,
            .extendedRuntimeStarted,
            .extendedRuntimeWillExpire,
            .extendedRuntimeInvalidated,
            .healthTimer,
            .executionBudgetExpired,
            .cancellationWatchdog
        ]

        for source in callbackSources {
            XCTAssertTrue(source.grantsEventDrivenBluetoothAction, "Expected callback source: \(source)")
        }
        for source in lifecycleAndTimerSources {
            XCTAssertFalse(source.grantsEventDrivenBluetoothAction, "Expected passive source: \(source)")
        }
    }

    func testRepeatedWakeTransitionsDoNotRefillOrMoveActiveBudget() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(
            at: receivedAt,
            applicationIsActive: false,
            executionIsAvailable: true
        )
        let generation = timing.generation
        let pausedAt = receivedAt.addingTimeInterval(20)
        XCTAssertTrue(timing.setExecutionAvailable(false, at: pausedAt))
        XCTAssertFalse(timing.setExecutionAvailable(false, at: pausedAt.addingTimeInterval(300)))
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: pausedAt.addingTimeInterval(300))),
            70,
            accuracy: 0.000_001
        )

        let resumedAt = pausedAt.addingTimeInterval(600)
        XCTAssertTrue(timing.setExecutionAvailable(true, at: resumedAt))
        let activeDeadline = try XCTUnwrap(timing.deadline)
        XCTAssertFalse(timing.setExecutionAvailable(true, at: resumedAt.addingTimeInterval(10)))
        XCTAssertEqual(timing.deadline, activeDeadline)
        XCTAssertEqual(timing.generation, generation)

        let secondPause = resumedAt.addingTimeInterval(25)
        XCTAssertTrue(timing.setExecutionAvailable(false, at: secondPause))
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: secondPause)),
            45,
            accuracy: 0.000_001
        )
    }

    func testPrePauseTimerIsStaleEvenWhenPauseAndResumeShareTimestamp() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(
            at: receivedAt,
            applicationIsActive: true,
            executionIsAvailable: true
        )
        let old = try XCTUnwrap(timing.deadline)
        let transitionAt = receivedAt.addingTimeInterval(10)
        XCTAssertTrue(timing.setExecutionAvailable(false, at: transitionAt))
        XCTAssertTrue(timing.setExecutionAvailable(true, at: transitionAt))
        let current = try XCTUnwrap(timing.deadline)

        XCTAssertNotEqual(old.token, current.token)
        XCTAssertEqual(current.expiresAt, old.expiresAt)
        XCTAssertFalse(timing.timeoutIsCurrent(
            old,
            ownership: .watch,
            cancelling: false,
            at: old.expiresAt
        ))
        XCTAssertTrue(timing.timeoutIsCurrent(
            current,
            ownership: .watch,
            cancelling: false,
            at: current.expiresAt
        ))
    }

    func testLegacyDisconnectWithoutModernCallbackIsHandled() throws {
        var gate = LibreWatchLegacyDisconnectGate()
        let pending = try XCTUnwrap(gate.scheduleLegacy())
        XCTAssertTrue(gate.accept(legacyToken: pending))
        XCTAssertTrue(gate.handled)
        XCTAssertNil(gate.pendingToken)
    }

    func testModernDisconnectCancelsPendingLegacyFallback() throws {
        var gate = LibreWatchLegacyDisconnectGate()
        let pending = try XCTUnwrap(gate.scheduleLegacy())
        XCTAssertTrue(gate.accept())
        XCTAssertNil(gate.pendingToken)
        XCTAssertFalse(gate.accept(legacyToken: pending))
    }

    func testBothDisconnectCallbacksProduceOnlyOneRecoveryInEitherOrder() throws {
        for modernFirst in [true, false] {
            var gate = LibreWatchLegacyDisconnectGate()
            let pending = try XCTUnwrap(gate.scheduleLegacy())
            let deliveries: [UUID?] = modernFirst ? [nil, pending] : [pending, nil]
            var handledCount = 0
            for token in deliveries {
                if gate.accept(legacyToken: token) { handledCount += 1 }
            }
            XCTAssertEqual(handledCount, 1)
            XCTAssertNil(gate.scheduleLegacy())
        }
    }

    func testDidConnectCancelsOldLegacyCallbackButAllowsTheNextRealDisconnect() throws {
        var gate = LibreWatchLegacyDisconnectGate()
        let old = try XCTUnwrap(gate.scheduleLegacy())
        gate.reset() // Accepted didConnect.
        let next = try XCTUnwrap(gate.scheduleLegacy())
        XCTAssertFalse(gate.accept(legacyToken: old))
        XCTAssertEqual(gate.pendingToken, next)
        XCTAssertTrue(gate.accept(legacyToken: next))
    }

    func testReceivingThenObservedConnectingWithoutAnyDisconnectCreatesOneDeadline() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        // The real failure: receiving with no disconnect callback and NO pre-created deadline.
        XCTAssertEqual(timing.phase, .receiving)
        XCTAssertNil(timing.deadline)
        let observedAt = receivedAt.addingTimeInterval(93)
        XCTAssertTrue(timing.observeLink(
            connected: false, connecting: true, hasReceptionState: true,
            at: observedAt, applicationIsActive: true
        ))
        let deadline = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(deadline.expiresAt, observedAt.addingTimeInterval(60))
        XCTAssertEqual(timing.phase, .connection)
        XCTAssertNil(timing.dataExpectedSince)
        XCTAssertFalse(timing.setupInProgress)
        XCTAssertFalse(timing.canStartBluetoothOperation)
        for seconds in [1.0, 20.0, 80.0] {
            XCTAssertFalse(timing.observeLink(
                connected: false, connecting: true, hasReceptionState: false,
                at: observedAt.addingTimeInterval(seconds), applicationIsActive: false
            ))
            XCTAssertEqual(timing.deadline, deadline)
        }
    }

    func testDisconnectedOrDisconnectingObservationClearsOldSetupOnlyOnce() {
        var timing = LibreWatchConnectionTiming()
        timing.beginSetup(at: receivedAt)
        XCTAssertTrue(timing.observeLink(
            connected: false, connecting: false, hasReceptionState: true,
            at: receivedAt.addingTimeInterval(5), applicationIsActive: false
        ))
        XCTAssertNil(timing.deadline)
        XCTAssertNil(timing.dataExpectedSince)
        XCTAssertFalse(timing.setupInProgress)
        XCTAssertFalse(timing.observeLink(
            connected: false, connecting: false, hasReceptionState: false,
            at: receivedAt.addingTimeInterval(6), applicationIsActive: true
        ))
    }

    func testDidConnectEndsConnectionTimeoutAndStartsFreshGATTIndependentOfOldPacket() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        timing.observeLink(
            connected: false, connecting: true, hasReceptionState: true,
            at: receivedAt.addingTimeInterval(93), applicationIsActive: true
        )
        let oldConnection = try XCTUnwrap(timing.deadline)
        let connectedAt = receivedAt.addingTimeInterval(600)
        timing.beginSetup(at: connectedAt) // didConnect wins before queued timeout cancellation.
        let setup = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(setup.expiresAt, connectedAt.addingTimeInterval(60))
        XCTAssertFalse(timing.timeoutIsCurrent(
            oldConnection, ownership: .watch, cancelling: false, at: connectedAt
        ))
        XCTAssertFalse(timing.timeoutIsCurrent(
            setup, ownership: .watch, cancelling: false, at: connectedAt.addingTimeInterval(13)
        ))
        XCTAssertFalse(timing.noDataIsOverdue(
            lastPacketAt: receivedAt, at: connectedAt.addingTimeInterval(13), timeout: 120
        ))
    }

    func testEveryGATTProgressRefreshesWatchdogAndUnlockStartsFreshNoDataGrace() throws {
        var timing = LibreWatchConnectionTiming()
        let connectedAt = receivedAt.addingTimeInterval(600)
        timing.beginSetup(at: connectedAt)
        let stages: [LibreWatchConnectionTiming.Phase] = [.services, .characteristics, .notifications, .unlock]
        var progressAt = connectedAt
        for stage in stages {
            let old = try XCTUnwrap(timing.deadline)
            progressAt = progressAt.addingTimeInterval(59)
            XCTAssertTrue(timing.setupProgress(stage, at: progressAt))
            XCTAssertFalse(timing.timeoutIsCurrent(
                old, ownership: .watch, cancelling: false, at: old.expiresAt
            ))
            if stage != .unlock {
                XCTAssertEqual(timing.deadline?.expiresAt, progressAt.addingTimeInterval(60))
            }
        }
        XCTAssertNil(timing.deadline)
        XCTAssertFalse(timing.setupInProgress)
        XCTAssertEqual(timing.phase, .receiving)
        XCTAssertEqual(timing.dataExpectedSince, progressAt)
        for limit in [120.0, 180.0] {
            XCTAssertFalse(timing.noDataIsOverdue(
                lastPacketAt: receivedAt, at: progressAt.addingTimeInterval(limit - 1), timeout: limit
            ))
            XCTAssertTrue(timing.noDataIsOverdue(
                lastPacketAt: receivedAt, at: progressAt.addingTimeInterval(limit), timeout: limit
            ))
        }
    }

    func testGATTProgressAtDeadlineWinsUnlessCancellationAlreadyStarted() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginSetup(at: receivedAt)
        let old = try XCTUnwrap(timing.deadline)
        XCTAssertTrue(timing.setupProgress(.services, at: old.expiresAt))
        XCTAssertFalse(timing.timeoutIsCurrent(
            old, ownership: .watch, cancelling: false, at: old.expiresAt
        ))
        let current = try XCTUnwrap(timing.deadline)
        XCTAssertTrue(timing.timeoutIsCurrent(
            current, ownership: .watch, cancelling: false, at: current.expiresAt
        ))
        timing.invalidate() // Controlled cancellation has begun on the serial main queue.
        XCTAssertFalse(timing.setupProgress(.characteristics, at: current.expiresAt))
        XCTAssertNil(timing.deadline)
    }

    func testPausedGATTCallbacksAdvanceAndReceiveFreshPausedBudgets() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginSetup(at: receivedAt, executionIsAvailable: false)
        XCTAssertEqual(timing.phase, .services)
        XCTAssertNil(timing.deadline)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: receivedAt)),
            60,
            accuracy: 0.000_001
        )

        let servicesAt = receivedAt.addingTimeInterval(600)
        XCTAssertTrue(timing.setupProgress(
            .services,
            at: servicesAt,
            executionIsAvailable: false
        ))
        XCTAssertEqual(timing.phase, .characteristics)
        XCTAssertNil(timing.deadline)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: servicesAt)),
            60,
            accuracy: 0.000_001
        )

        XCTAssertTrue(timing.setExecutionAvailable(true, at: servicesAt))
        let characteristicsDeadline = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(characteristicsDeadline.expiresAt, servicesAt.addingTimeInterval(60))

        XCTAssertTrue(timing.setupProgress(
            .characteristics,
            at: characteristicsDeadline.expiresAt,
            executionIsAvailable: true
        ))
        XCTAssertEqual(timing.phase, .notifications)
        XCTAssertFalse(timing.timeoutIsCurrent(
            characteristicsDeadline,
            ownership: .watch,
            cancelling: false,
            at: characteristicsDeadline.expiresAt
        ))
        XCTAssertEqual(
            timing.deadline?.expiresAt,
            characteristicsDeadline.expiresAt.addingTimeInterval(60)
        )
    }

    func testStaleTimersCannotCancelNewAttemptSetupOrHealthyNotifications() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(at: receivedAt, applicationIsActive: true)
        let oldAttempt = try XCTUnwrap(timing.deadline)
        timing.invalidate() // An explicitly retired generation permits a new attempt.
        timing.beginConnection(at: receivedAt.addingTimeInterval(1), applicationIsActive: false)
        let currentAttempt = try XCTUnwrap(timing.deadline)
        XCTAssertNotEqual(oldAttempt.token, currentAttempt.token)
        XCTAssertFalse(timing.timeoutIsCurrent(
            oldAttempt, ownership: .watch, cancelling: false, at: oldAttempt.expiresAt
        ))
        timing.beginSetup(at: receivedAt.addingTimeInterval(2))
        let setup = try XCTUnwrap(timing.deadline)
        timing.receivedPacketOrEnabledNotifications(at: receivedAt.addingTimeInterval(3))
        for retired in [oldAttempt, currentAttempt, setup] {
            XCTAssertFalse(timing.timeoutIsCurrent(
                retired, ownership: .watch, cancelling: false, at: receivedAt.addingTimeInterval(300)
            ))
        }
    }

    func testReturnToPhoneInvalidatesAllWatchTimingAndPreventsFurtherRecovery() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginSetup(at: receivedAt)
        let old = try XCTUnwrap(timing.deadline)
        timing.invalidate()
        XCTAssertNil(timing.phase)
        XCTAssertNil(timing.dataExpectedSince)
        XCTAssertFalse(timing.setupProgress(.services, at: old.expiresAt))
        XCTAssertFalse(timing.timeoutIsCurrent(
            old, ownership: .iphone, cancelling: false, at: old.expiresAt
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(ownership: .iphone))
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.reconnectFallbackAction(
                deadline: old.expiresAt, now: old.expiresAt,
                applicationIsActive: true,
                extendedRuntimeIsRunning: true,
                ownership: .iphone
            ),
            .noAdditionalWork
        )
    }

    func testAnExistingConnectionOrSetupNeverStartsParallelScanOrConnect() {
        var timing = LibreWatchConnectionTiming()
        XCTAssertTrue(timing.canStartBluetoothOperation)
        timing.beginConnection(at: receivedAt, applicationIsActive: true)
        XCTAssertFalse(timing.canStartBluetoothOperation)
        timing.beginSetup(at: receivedAt.addingTimeInterval(10))
        XCTAssertFalse(timing.canStartBluetoothOperation)
        timing.receivedPacketOrEnabledNotifications(at: receivedAt.addingTimeInterval(15))
        XCTAssertFalse(timing.canStartBluetoothOperation)
        timing.invalidate() // Only the retired attempt releases the gate for filtered scanning.
        XCTAssertTrue(timing.canStartBluetoothOperation)
    }

    func testForegroundAndRuntimeNoDataRecoveryKeepTheirOwnLimits() {
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.noDataRecoveryDelay(
                applicationIsActive: true,
                extendedRuntimeIsRunning: true,
                ownership: .watch
            ),
            2 * 60
        )
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.noDataRecoveryDelay(
                applicationIsActive: false,
                extendedRuntimeIsRunning: true,
                ownership: .watch
            ),
            3 * 60
        )
    }

    func testRepeatedConnectionFailuresDoNotRefillBudgetOrChangeGeneration() throws {
        for activeAtStart in [true, false] {
            var timing = LibreWatchConnectionTiming()
            timing.beginConnection(
                at: receivedAt,
                applicationIsActive: activeAtStart,
                executionIsAvailable: true
            )
            let original = try XCTUnwrap(timing.deadline)
            let generation = timing.generation
            // didFailToConnect retries use the same beginConnection entry point, without
            // invalidating timing. No callback silently refills the phase budget.
            for seconds in [1.0, 15.0, 30.0, 59.0] {
                timing.beginConnection(at: receivedAt.addingTimeInterval(seconds),
                                       applicationIsActive: !activeAtStart,
                                       executionIsAvailable: true)
                XCTAssertEqual(timing.deadline, original)
                XCTAssertEqual(timing.generation, generation)
                let duration = activeAtStart ? 60.0 : 90.0
                XCTAssertEqual(
                    try XCTUnwrap(timing.remainingExecutionTime(
                        at: receivedAt.addingTimeInterval(seconds)
                    )),
                    duration - seconds,
                    accuracy: 0.000_001
                )
                XCTAssertTrue(timing.canConnect(at: receivedAt.addingTimeInterval(seconds),
                                                peripheralIsDisconnected: true,
                                                retiredPeripheralIsReleased: true))
            }
        }
    }

    func testRetryCannotRenewAnExhaustedExecutionBudget() throws {
        for activeAtStart in [true, false] {
            var timing = LibreWatchConnectionTiming()
            timing.beginConnection(
                at: receivedAt,
                applicationIsActive: activeAtStart,
                executionIsAvailable: true
            )
            let original = try XCTUnwrap(timing.deadline)
            XCTAssertEqual(
                timing.failedConnectionAction(
                    at: original.expiresAt.addingTimeInterval(-0.001),
                    bluetoothIsPoweredOn: true
                ),
                .retryConfirmedPeripheral
            )
            for delay in [0.0, 60.0, 600.0] {
                let now = original.expiresAt.addingTimeInterval(delay)
                timing.beginConnection(
                    at: now,
                    applicationIsActive: !activeAtStart,
                    executionIsAvailable: true
                )
                XCTAssertEqual(timing.deadline, original)
                XCTAssertFalse(timing.canConnect(at: now, peripheralIsDisconnected: true,
                                                 retiredPeripheralIsReleased: true))
                XCTAssertTrue(timing.timeoutIsCurrent(
                    original, ownership: .watch, cancelling: false, at: now
                ))
                XCTAssertEqual(
                    timing.failedConnectionAction(at: now, bluetoothIsPoweredOn: true),
                    .scanConfirmedSensor
                )
                XCTAssertEqual(
                    timing.failedConnectionAction(at: now, bluetoothIsPoweredOn: false),
                    .waitForBluetooth
                )
            }
        }
    }

    func testMissingCancelCallbackRetiresForOneFilteredScanAtWatchdogDeadline() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(at: receivedAt, applicationIsActive: true)
        timing.beginCancellation(at: receivedAt.addingTimeInterval(60))
        let cancellation = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(cancellation.expiresAt, receivedAt.addingTimeInterval(65))
        XCTAssertNil(timing.finishCancellation(
            cancellation, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: false, at: cancellation.expiresAt.addingTimeInterval(-1)
        ))
        XCTAssertFalse(timing.canStartBluetoothOperation)
        XCTAssertEqual(timing.finishCancellation(
            cancellation, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: false, at: cancellation.expiresAt
        ), .retireForScan)
        XCTAssertTrue(timing.canStartBluetoothOperation)
        XCTAssertNil(timing.finishCancellation(
            cancellation, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: false, at: cancellation.expiresAt.addingTimeInterval(30)
        ))
    }

    func testCancellationProofRemainsWallClockAndIgnoresExecutionPauses() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginCancellation(at: receivedAt)
        let cancellation = try XCTUnwrap(timing.deadline)

        XCTAssertFalse(timing.setExecutionAvailable(false, at: receivedAt.addingTimeInterval(1)))
        XCTAssertFalse(timing.setExecutionAvailable(true, at: receivedAt.addingTimeInterval(120)))
        XCTAssertEqual(timing.deadline, cancellation)
        XCTAssertNil(timing.finishCancellation(
            cancellation,
            ownership: .watch,
            returningToPhone: false,
            peripheralIsDisconnected: false,
            at: cancellation.expiresAt.addingTimeInterval(-0.001)
        ))
        XCTAssertEqual(timing.finishCancellation(
            cancellation,
            ownership: .watch,
            returningToPhone: false,
            peripheralIsDisconnected: false,
            at: cancellation.expiresAt
        ), .retireForScan)
    }

    func testOldCancellationWatchdogCannotAffectNewConnectionOrSetup() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginCancellation(at: receivedAt)
        let old = try XCTUnwrap(timing.deadline)
        let retiredGeneration = timing.generation
        XCTAssertEqual(timing.finishCancellation(
            old, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: true, at: receivedAt.addingTimeInterval(1)
        ), .confirmedDisconnected)
        timing.beginConnection(at: receivedAt.addingTimeInterval(2), applicationIsActive: true)
        let connection = timing.deadline
        XCTAssertNotEqual(timing.generation, retiredGeneration)
        XCTAssertNil(timing.finishCancellation(
            old, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: false, at: old.expiresAt
        ))
        XCTAssertEqual(timing.deadline, connection)
        timing.beginSetup(at: receivedAt.addingTimeInterval(3))
        let setup = timing.deadline
        XCTAssertNil(timing.finishCancellation(
            old, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: false, at: old.expiresAt
        ))
        XCTAssertEqual(timing.deadline, setup)
    }

    func testConfirmedCancellationWithoutDelegateCallbackCompletesOnlyOnce() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginCancellation(at: receivedAt)
        let deadline = try XCTUnwrap(timing.deadline)
        // A lifecycle/watchdog observation of native .disconnected is also confirmation.
        XCTAssertEqual(timing.finishCancellation(
            deadline, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: true, at: receivedAt.addingTimeInterval(1)
        ), .confirmedDisconnected)
        XCTAssertNil(timing.finishCancellation(
            deadline, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: true, at: deadline.expiresAt
        ))
    }

    func testReturnToPhoneTimeoutNeverSubstitutesForConfirmedDisconnection() throws {
        for ownership in [LibreWatchOwnership.watch, .iphone] {
            var timing = LibreWatchConnectionTiming()
            timing.receivedPacketOrEnabledNotifications(at: receivedAt)
            timing.beginCancellation(at: receivedAt)
            let deadline = try XCTUnwrap(timing.deadline)
            XCTAssertEqual(timing.finishCancellation(
                deadline, ownership: ownership, returningToPhone: true,
                peripheralIsDisconnected: false, at: deadline.expiresAt
            ), .awaitConfirmedDisconnection)
            XCTAssertTrue(timing.cancellationWatchdogDidFire)
            XCTAssertFalse(timing.canStartBluetoothOperation)
            XCTAssertNil(timing.finishCancellation(
                deadline, ownership: ownership, returningToPhone: true,
                peripheralIsDisconnected: false, at: deadline.expiresAt.addingTimeInterval(30)
            ))
            XCTAssertEqual(timing.finishCancellation(
                deadline, ownership: ownership, returningToPhone: true,
                peripheralIsDisconnected: true, at: deadline.expiresAt.addingTimeInterval(31)
            ), .confirmedDisconnected)
            XCTAssertFalse(LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(ownership: .iphone))
        }
    }

    func testCancellationAndRetiredPeripheralPreventParallelConnect() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginCancellation(at: receivedAt)
        let cancellation = timing.deadline
        timing.beginConnection(at: receivedAt, applicationIsActive: true)
        timing.beginSetup(at: receivedAt)
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        XCTAssertFalse(timing.observeLink(
            connected: false, connecting: true, hasReceptionState: true,
            at: receivedAt, applicationIsActive: true
        ))
        XCTAssertEqual(timing.phase, .cancelling)
        XCTAssertEqual(timing.deadline, cancellation)
        XCTAssertFalse(timing.canStartBluetoothOperation)
        timing.invalidate()
        timing.beginConnection(at: receivedAt, applicationIsActive: true)
        XCTAssertFalse(timing.canConnect(at: receivedAt, peripheralIsDisconnected: true,
                                         retiredPeripheralIsReleased: false))
        XCTAssertFalse(timing.canConnect(at: receivedAt, peripheralIsDisconnected: false,
                                         retiredPeripheralIsReleased: true))
        XCTAssertTrue(timing.canConnect(at: receivedAt, peripheralIsDisconnected: true,
                                        retiredPeripheralIsReleased: true))
    }

    func testInvalidFrameKeepsTechnicalNoDataMonitoringAndResetsAssembly() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        var liveness = LibreWatchFrameLiveness()
        var assembler = Libre2WatchDirectFrameAssembler()
        XCTAssertThrowsError(try assembler.append(
            fragment: Data(repeating: 0, count: Libre2WatchDirectConstants.encryptedFrameLength + 1),
            at: receivedAt.addingTimeInterval(60)
        ))
        assembler.reset() // Same catch path as the collector; UI failure does not alter timing.
        XCTAssertFalse(liveness.invalidFrame())
        XCTAssertEqual(assembler.assembledByteCount, 0)
        XCTAssertEqual(timing.phase, .receiving)
        XCTAssertEqual(timing.dataExpectedSince, receivedAt)
        XCTAssertTrue(timing.noDataIsOverdue(
            lastPacketAt: receivedAt, at: receivedAt.addingTimeInterval(120), timeout: 120
        ))
        XCTAssertNil(try assembler.append(
            fragment: Data(repeating: 0, count: 20), at: receivedAt.addingTimeInterval(121)
        ))
        XCTAssertEqual(assembler.assembledByteCount, 20)
    }

    func testValidFrameRecordsTechnicalLivenessAndResetsInvalidFrameCounter() {
        var liveness = LibreWatchFrameLiveness()
        let reading = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            at: receivedAt
        )
        var deliveryAcceptance = LibreWatchReadingAcceptancePolicy()
        XCTAssertTrue(deliveryAcceptance.accept(
            reading,
            for: session.id,
            now: receivedAt.addingTimeInterval(1)
        ))
        XCTAssertFalse(deliveryAcceptance.accept(
            reading,
            for: session.id,
            now: receivedAt.addingTimeInterval(2)
        ))
        XCTAssertFalse(liveness.invalidFrame())
        XCTAssertFalse(liveness.invalidFrame())
        XCTAssertEqual(liveness.consecutiveInvalidFrames, 2)
        let validFrameAt = receivedAt.addingTimeInterval(45)
        liveness.validFrame(at: validFrameAt)
        let livenessWasVisibleBeforeDownstreamRejection =
            liveness.lastValidBLEFrameAt == validFrameAt
        let downstreamAccepted = false
        XCTAssertFalse(downstreamAccepted)
        XCTAssertTrue(livenessWasVisibleBeforeDownstreamRejection)
        XCTAssertEqual(liveness.consecutiveInvalidFrames, 0)
        XCTAssertFalse(liveness.recoveryRequested)
        XCTAssertEqual(liveness.lastValidBLEFrameAt, validFrameAt)
        XCTAssertFalse(liveness.invalidFrame())
        XCTAssertEqual(liveness.consecutiveInvalidFrames, 1)
    }

    func testThreeConsecutiveInvalidFramesRequestExactlyOneRecovery() {
        var liveness = LibreWatchFrameLiveness()
        let requests = (0 ..< 10).map { _ in liveness.invalidFrame() }
        XCTAssertEqual(LibreWatchFrameLiveness.invalidFrameLimit, 3)
        XCTAssertEqual(Array(requests.prefix(3)), [false, false, true])
        XCTAssertEqual(requests.filter { $0 }.count, 1)
        XCTAssertEqual(liveness.consecutiveInvalidFrames, 3)
    }

    func testDelayedLegacyDisconnectMustMatchGenerationAndDisconnectedState() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        let oldGeneration = timing.generation
        var gate = LibreWatchLegacyDisconnectGate()
        let token = try XCTUnwrap(gate.scheduleLegacy())
        XCTAssertTrue(gate.legacyIsCurrent(
            token, scheduledGeneration: oldGeneration, currentGeneration: timing.generation,
            peripheralIsDisconnectedOrDisconnecting: true
        ))
        XCTAssertFalse(gate.legacyIsCurrent(
            token, scheduledGeneration: oldGeneration, currentGeneration: timing.generation,
            peripheralIsDisconnectedOrDisconnecting: false
        ))
        timing.invalidate()
        timing.beginConnection(at: receivedAt.addingTimeInterval(1), applicationIsActive: true)
        XCTAssertFalse(gate.legacyIsCurrent(
            token, scheduledGeneration: oldGeneration, currentGeneration: timing.generation,
            peripheralIsDisconnectedOrDisconnecting: true
        ))
        gate.cancelLegacy()
        XCTAssertFalse(gate.accept(legacyToken: token))
    }

    func testModernCallbackAndDidConnectInvalidateDelayedLegacyWork() throws {
        for didConnectFirst in [true, false] {
            var gate = LibreWatchLegacyDisconnectGate()
            let token = try XCTUnwrap(gate.scheduleLegacy())
            let generation = UUID()
            if didConnectFirst {
                gate.reset()
            } else {
                XCTAssertTrue(gate.accept())
            }
            XCTAssertFalse(gate.legacyIsCurrent(
                token, scheduledGeneration: generation, currentGeneration: generation,
                peripheralIsDisconnectedOrDisconnecting: true
            ))
            XCTAssertFalse(gate.accept(legacyToken: token))
        }
    }

    func testLegacyDiagnosticEventsStillDecodeWithoutNewContext() throws {
        let data = Data(#"{"kind":"disconnected","isReconnecting":true,"errorCode":7}"#.utf8)
        let event = try JSONDecoder().decode(LibreWatchDiagnosticEvent.self, from: data)
        XCTAssertNil(event.eventID)
        XCTAssertEqual(event.kind, .disconnected)
        XCTAssertEqual(event.isReconnecting, true)
        XCTAssertEqual(event.errorCode, 7)
        XCTAssertNil(event.watchTimestamp)
        XCTAssertNil(event.trigger)
        XCTAssertNil(event.generation)
        XCTAssertNil(event.deadlineAt)
        XCTAssertNil(event.attemptID)
        XCTAssertNil(event.attemptStartedAt)
        XCTAssertNil(event.sessionID)
        XCTAssertNil(event.sensorIdentity)
        XCTAssertNil(event.reconcileSource)
        XCTAssertNil(event.remainingExecutionBudget)
        XCTAssertNil(event.runtimeInvalidationReason)
        XCTAssertNil(event.runtimeError)
        XCTAssertNil(event.applicationState)
        XCTAssertNil(event.sequenceNumber)
        XCTAssertNil(event.bluetoothErrorClassification)
        XCTAssertNil(event.extendedRuntimeState)
        XCTAssertNil(event.extendedRuntimeStartRequested)
    }

    func testBackgroundNotificationQuotaErrorsNeverCountAsInvalidFramesOrStartRecovery() {
        let quotaActions: [LibreWatchNotificationErrorAction] = [
            LibreWatchNotificationErrorPolicy.action(
                isNearBackgroundNotificationLimit: true,
                isExceededBackgroundNotificationLimit: false
            ),
            LibreWatchNotificationErrorPolicy.action(
                isNearBackgroundNotificationLimit: false,
                isExceededBackgroundNotificationLimit: true
            )
        ]
        var liveness = LibreWatchFrameLiveness()
        var recoveryCount = 0

        for action in quotaActions {
            switch action {
            case .recoverBluetoothLink:
                if liveness.invalidFrame() { recoveryCount += 1 }
            case .preserveConnectionNearBackgroundLimit,
                 .preserveConnectionExceededBackgroundLimit:
                break
            }
        }

        XCTAssertEqual(quotaActions.map(\.diagnosticName), [
            "backgroundBudgetNear",
            "backgroundBudgetExceeded"
        ])
        XCTAssertEqual(liveness.consecutiveInvalidFrames, 0)
        XCTAssertEqual(recoveryCount, 0)
        XCTAssertEqual(
            LibreWatchNotificationErrorPolicy.action(
                isNearBackgroundNotificationLimit: false,
                isExceededBackgroundNotificationLimit: false
            ),
            .recoverBluetoothLink
        )
    }

    func testDiagnosticJournalPersistsOriginalOrderAndPendingDeliveryAcrossRestart() throws {
        let defaults = isolatedDefaults()
        let firstID = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "A2000000-0000-0000-0000-000000000002")!
        let first = LibreWatchDiagnosticEvent(
            eventID: firstID,
            kind: .lifecycleChanged,
            watchTimestamp: receivedAt,
            trigger: "background",
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            applicationState: .background
        )
        let second = LibreWatchDiagnosticEvent(
            eventID: secondID,
            kind: .coreBluetoothCallback,
            watchTimestamp: receivedAt.addingTimeInterval(5),
            trigger: "didConnect",
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            applicationState: .active
        )
        var journal = LibreWatchDiagnosticJournal()

        let firstResult = journal.append(first, at: receivedAt.addingTimeInterval(1))
        let secondResult = journal.append(second, at: receivedAt.addingTimeInterval(6))
        XCTAssertTrue(firstResult.inserted)
        XCTAssertTrue(secondResult.inserted)
        XCTAssertEqual(firstResult.event.sequenceNumber, 1)
        XCTAssertEqual(secondResult.event.sequenceNumber, 2)
        XCTAssertFalse(journal.append(first, at: receivedAt.addingTimeInterval(7)).inserted)

        LibreWatchSessionStore.saveDiagnosticJournal(
            journal,
            defaults: defaults,
            at: receivedAt.addingTimeInterval(7)
        )
        var restored = LibreWatchSessionStore.loadDiagnosticJournal(
            defaults: defaults,
            at: receivedAt.addingTimeInterval(8)
        )
        XCTAssertEqual(
            restored.pendingEvents(for: session.id).compactMap(\.eventID),
            [firstID, secondID]
        )
        XCTAssertTrue(restored.pendingEvents(for: UUID()).isEmpty)
        restored.markHandedToWatchConnectivity(
            eventID: firstID,
            at: receivedAt.addingTimeInterval(10)
        )
        XCTAssertEqual(restored.pendingEvents(for: session.id).compactMap(\.eventID), [firstID, secondID])
        restored.markAcknowledgedByPhone(eventID: firstID, at: receivedAt.addingTimeInterval(10.5))
        LibreWatchSessionStore.saveDiagnosticJournal(
            restored,
            defaults: defaults,
            at: receivedAt.addingTimeInterval(11)
        )
        let deliveredState = LibreWatchSessionStore.loadDiagnosticJournal(
            defaults: defaults,
            at: receivedAt.addingTimeInterval(12)
        )
        XCTAssertEqual(
            deliveredState.pendingEvents(for: session.id).compactMap(\.eventID),
            [secondID]
        )
        XCTAssertEqual(deliveredState.entries.first?.event.watchTimestamp, receivedAt)
    }

    func testDiagnosticJournalIsBoundedAndRecordsDroppedEntriesWithoutRecursiveEvents() throws {
        var journal = LibreWatchDiagnosticJournal()
        let start = receivedAt
        for index in 0 ..< 300 {
            _ = journal.append(LibreWatchDiagnosticEvent(
                kind: .coreBluetoothCallback,
                watchTimestamp: start.addingTimeInterval(TimeInterval(index)),
                trigger: "centralState:poweredOn",
                sessionID: session.id,
                sensorIdentity: session.redactedIdentity(),
                applicationState: .active,
                actionReason: String(repeating: "x", count: 2_000)
            ), at: start.addingTimeInterval(TimeInterval(index)))
        }

        let encoded = try JSONEncoder().encode(journal)
        XCTAssertLessThanOrEqual(journal.entries.count, LibreWatchDiagnosticJournal.maximumEntries)
        XCTAssertLessThanOrEqual(encoded.count, LibreWatchDiagnosticJournal.maximumEncodedBytes)
        XCTAssertGreaterThan(journal.droppedCount, 0)
        XCTAssertTrue(journal.entries.allSatisfy { $0.event.actionReason?.count == 513 })
        XCTAssertEqual(
            journal.entries.compactMap { $0.event.sequenceNumber },
            journal.entries.compactMap { $0.event.sequenceNumber }.sorted()
        )
        XCTAssertFalse(journal.entries.contains { $0.event.kind == .journalRotated })
    }

    func testDiagnosticJournalAssignsStableIDAndExpiresByLocalRecordTime() throws {
        var journal = LibreWatchDiagnosticJournal()
        let event = LibreWatchDiagnosticEvent(
            eventID: nil,
            kind: .callbackRejected,
            watchTimestamp: receivedAt.addingTimeInterval(365 * 24 * 60 * 60),
            trigger: "staleSetupGeneration",
            sessionID: session.id
        )
        let result = journal.append(event, at: receivedAt)
        let generatedID = try XCTUnwrap(result.event.eventID)
        XCTAssertEqual(journal.entries.first?.event.eventID, generatedID)

        journal.prune(at: receivedAt.addingTimeInterval(
            LibreWatchDiagnosticJournal.maximumAge + 0.001
        ))
        XCTAssertTrue(journal.entries.isEmpty)
        XCTAssertGreaterThan(journal.droppedCount, 0)
    }

    func testQueuedDiagnosticPreservesWatchTimestampAndPhaseContext() throws {
        let eventID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let attemptID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let event = LibreWatchDiagnosticEvent(
            eventID: eventID, kind: .recoveryStarted,
            watchTimestamp: receivedAt, trigger: "invalidFrames",
            applicationIsActive: false, extendedRuntimeIsRunning: true,
            peripheralState: "connected", connectionPhase: "cancelling",
            deadlinePhase: "cancelling", deadlineAt: receivedAt.addingTimeInterval(5),
            generation: UUID(), attemptID: attemptID,
            attemptStartedAt: receivedAt.addingTimeInterval(-30),
            sessionID: session.id, sensorIdentity: session.redactedIdentity(),
            reconcileSource: .gattCallback, remainingExecutionBudget: 42
        )
        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(
            LibreWatchDiagnosticEvent.self, from: encoded
        )
        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.eventID, eventID)
        XCTAssertEqual(decoded.attemptID, attemptID)
        XCTAssertEqual(decoded.remainingExecutionBudget, 42)
        XCTAssertEqual(decoded.watchTimestamp, receivedAt) // Not the later iPhone receipt time.

        // A fallback delivery must persist the exact snapshot, not reconstruct it later.
        let item = LibreWatchOutboxItem.command(
            .reportDiagnostic,
            sessionID: session.id,
            diagnosticEvent: encoded,
            id: eventID,
            createdAt: receivedAt.addingTimeInterval(60)
        )
        let queuedEvent = try JSONDecoder().decode(
            LibreWatchDiagnosticEvent.self,
            from: try XCTUnwrap(item.diagnosticEvent)
        )
        XCTAssertEqual(queuedEvent, event)
    }

    func testRecoveryAttemptRetainsImmutableContextUntilSuccessOrInvalidation() throws {
        let original = LibreWatchRecoveryAttemptContext(
            attemptID: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            originalTrigger: "disconnect",
            startedAt: receivedAt,
            generation: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity()
        )
        let later = LibreWatchRecoveryAttemptContext(
            originalTrigger: "sceneActivation",
            startedAt: receivedAt.addingTimeInterval(600),
            generation: UUID(),
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity()
        )
        var state = LibreWatchRecoveryAttemptState()

        XCTAssertEqual(state.begin(original), original)
        XCTAssertNil(state.begin(later))
        XCTAssertEqual(state.context, original)
        XCTAssertEqual(state.reportFailure(), original)
        XCTAssertNil(state.reportFailure())
        XCTAssertEqual(state.context?.startedAt, receivedAt)

        let defaults = isolatedDefaults()
        LibreWatchSessionStore.saveRecoveryAttempt(state, defaults: defaults)
        var restored = LibreWatchSessionStore.loadRecoveryAttempt(defaults: defaults)
        XCTAssertEqual(restored, state)
        XCTAssertNil(restored.reportFailure()) // The one failure report survives restoration too.
        XCTAssertEqual(restored.finishSuccess(), original)
        LibreWatchSessionStore.saveRecoveryAttempt(restored, defaults: defaults)
        XCTAssertNil(LibreWatchSessionStore.loadRecoveryAttempt(defaults: defaults).context)
        XCTAssertNil(defaults.data(forKey: LibreWatchMessageKey.persistedRecoveryAttempt))
    }

    func testDiagnosticReceiptDeduplicatesStableEventIDAndAcceptsLegacyEvents() {
        let eventID = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
        var ledger = LibreWatchDiagnosticReceiptLedger()

        XCTAssertTrue(ledger.accept(eventID, at: receivedAt))
        XCTAssertFalse(ledger.accept(eventID, at: receivedAt.addingTimeInterval(1)))
        XCTAssertTrue(ledger.accept(nil, at: receivedAt.addingTimeInterval(2)))
        XCTAssertTrue(ledger.accept(nil, at: receivedAt.addingTimeInterval(3)))
        XCTAssertEqual(ledger.receipts[eventID], receivedAt)

        ledger.prune(at: receivedAt.addingTimeInterval(LibreWatchDiagnosticReceiptLedger.maximumAge))
        XCTAssertNotNil(ledger.receipts[eventID])
        ledger.prune(at: receivedAt.addingTimeInterval(
            LibreWatchDiagnosticReceiptLedger.maximumAge + 0.001
        ))
        XCTAssertNil(ledger.receipts[eventID])
    }

    func testConnectivityDeliveryPolicyCoversActivationAndReachability() {
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.action(
                sessionIsActivated: false,
                phoneIsReachable: false
            ),
            .activateAndQueue
        )
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.action(
                sessionIsActivated: false,
                phoneIsReachable: true
            ),
            .activateAndQueue
        )
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.action(
                sessionIsActivated: true,
                phoneIsReachable: false
            ),
            .transferUserInfo
        )
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.action(
                sessionIsActivated: true,
                phoneIsReachable: true
            ),
            .sendMessage
        )
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.actionAfterSendError(
                sessionIsActivated: true
            ),
            .transferUserInfo
        )
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.actionAfterSendError(
                sessionIsActivated: false
            ),
            .activateAndQueue
        )
        XCTAssertTrue(
            LibreWatchConnectivityDeliveryPolicy.shouldRetryReadingAsQueued(
                after: .wrongOwnership
            )
        )
        XCTAssertTrue(
            LibreWatchConnectivityDeliveryPolicy.shouldRetryReadingAsQueued(
                after: .tooOld
            )
        )
        XCTAssertFalse(
            LibreWatchConnectivityDeliveryPolicy.shouldRetryReadingAsQueued(
                after: .wrongSession
            )
        )
        XCTAssertFalse(
            LibreWatchConnectivityDeliveryPolicy.shouldRetryReadingAsQueued(
                after: .duplicate
            )
        )
    }

    func testHistoricalProcessingModeCannotDriveCurrentValueOrLiveAlerts() {
        let live = LibreWatchGlucoseProcessingMode.live
        XCTAssertTrue(live.permitsCurrentValueAndLiveSideEffects)
        XCTAssertEqual(
            live.routing,
            LibreWatchGlucoseProcessingRouting(
                updatesCurrentValue: true,
                resetsMissedReadingState: true,
                triggersAlerts: true,
                exportsToIntegrations: true
            )
        )

        let historical = LibreWatchGlucoseProcessingMode.historicalBackfill
        XCTAssertFalse(historical.permitsCurrentValueAndLiveSideEffects)
        XCTAssertFalse(historical.routing.updatesCurrentValue)
        XCTAssertFalse(historical.routing.resetsMissedReadingState)
        XCTAssertFalse(historical.routing.triggersAlerts)
        XCTAssertFalse(historical.routing.exportsToIntegrations)
    }

    func testOutboxDeduplicatesOrdersPersistsAndAcknowledgesByStableID() throws {
        let now = Date()
        let older = payload(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
            raw: 790,
            previousRaw: 780,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-60)
        )
        let newer = payload(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000007")!,
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: now
        )
        let commandID = UUID(uuidString: "80000000-0000-0000-0000-000000000008")!
        let command = LibreWatchOutboxItem.command(
            .updateUnlockCounter,
            sessionID: session.id,
            unlockCounter: 9,
            id: commandID,
            createdAt: now.addingTimeInterval(-120)
        )
        var outbox = LibreWatchConnectivityOutbox()

        outbox.enqueue(.reading(newer), now: now)
        outbox.enqueue(command, now: now)
        outbox.enqueue(.reading(older), now: now)
        outbox.enqueue(.reading(older), now: now)
        XCTAssertEqual(outbox.items.map(\.id), [commandID, older.id, newer.id])
        XCTAssertEqual(outbox.next?.id, commandID)

        let defaults = isolatedDefaults()
        LibreWatchSessionStore.saveOutbox(outbox, defaults: defaults)
        var restored = LibreWatchSessionStore.loadOutbox(defaults: defaults)
        XCTAssertEqual(restored, outbox)
        restored.remove(id: newer.id)
        XCTAssertEqual(restored.items.map(\.id), [commandID, older.id])
        XCTAssertNotNil(restored.items.first(where: { $0.id == older.id }))
        XCTAssertNotNil(restored.items.first(where: { $0.id == commandID }))
    }

    func testOutboxCapacityTrimsOldestPayloadRegardlessOfKind() {
        let now = receivedAt.addingTimeInterval(1_000)
        var outbox = LibreWatchConnectivityOutbox()
        for offset in 0 ..< LibreWatchConnectivityOutbox.maximumItems {
            outbox.enqueue(.command(
                .reportDiagnostic,
                sessionID: session.id,
                diagnosticEvent: Data([UInt8(offset & 0xFF)]),
                createdAt: now.addingTimeInterval(TimeInterval(offset))
            ), now: now)
        }
        let reading = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_500,
            at: now.addingTimeInterval(TimeInterval(LibreWatchConnectivityOutbox.maximumItems))
        )

        outbox.enqueue(.reading(reading), now: now)

        XCTAssertEqual(outbox.items.count, LibreWatchConnectivityOutbox.maximumItems)
        XCTAssertEqual(outbox.items.last?.id, reading.id)
        XCTAssertTrue(outbox.items.contains(where: { $0.id == reading.id }))
    }

    func testOutboxPrunesStrictlyAfterSixtyMinutesAndRetainsOnlyActiveSession() {
        let active = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            at: receivedAt
        )
        let otherSessionID = UUID(uuidString: "90000000-0000-0000-0000-000000000009")!
        let other = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_235,
            at: receivedAt.addingTimeInterval(1),
            sessionID: otherSessionID
        )
        var outbox = LibreWatchConnectivityOutbox()
        outbox.enqueue(.reading(active), now: receivedAt.addingTimeInterval(1))
        outbox.enqueue(.reading(other), now: receivedAt.addingTimeInterval(1))

        outbox.prune(at: receivedAt.addingTimeInterval(LibreWatchConnectivityOutbox.maximumAge))
        XCTAssertEqual(Set(outbox.items.map(\.id)), Set([active.id, other.id]))
        outbox.retain(sessionID: session.id)
        XCTAssertEqual(outbox.items.map(\.id), [active.id])

        outbox.prune(at: receivedAt.addingTimeInterval(
            LibreWatchConnectivityOutbox.maximumAge + 0.001
        ))
        XCTAssertTrue(outbox.items.isEmpty)
    }

    func testReadingAcceptanceRejectsDuplicateStaleAndOutOfOrderPayloads() {
        let firstID = UUID()
        let first = payload(
            id: firstID,
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: receivedAt
        )
        var acceptance = LibreWatchReadingAcceptancePolicy()

        XCTAssertTrue(acceptance.accept(first, for: session.id, now: receivedAt.addingTimeInterval(1)))
        XCTAssertFalse(acceptance.accept(first, for: session.id, now: receivedAt.addingTimeInterval(2)))

        let lowerSensorTime = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 999,
            at: receivedAt.addingTimeInterval(60)
        )
        XCTAssertFalse(acceptance.accept(
            lowerSensorTime,
            for: session.id,
            now: receivedAt.addingTimeInterval(61)
        ))

        let olderTimestamp = payload(
            raw: 820,
            previousRaw: 810,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: receivedAt
        )
        XCTAssertFalse(acceptance.accept(
            olderTimestamp,
            for: session.id,
            now: receivedAt.addingTimeInterval(62)
        ))

        let staleTransport = payload(
            raw: 830,
            previousRaw: 820,
            domain: .xDripRawGlucose,
            sensorTime: 1_002,
            at: receivedAt.addingTimeInterval(120)
        )
        XCTAssertFalse(acceptance.accept(
            staleTransport,
            for: session.id,
            now: receivedAt.addingTimeInterval(301)
        ))
    }

    func testLiveTransportKeepsThreeMinuteBoundary() {
        let now = receivedAt.addingTimeInterval(600)
        let exactBoundary = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-LibreWatchReadingAcceptancePolicy.maximumTransportAge)
        )
        let pastBoundary = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: now.addingTimeInterval(-LibreWatchReadingAcceptancePolicy.maximumTransportAge - 0.001)
        )
        var exactAcceptance = LibreWatchReadingAcceptancePolicy()
        var staleAcceptance = LibreWatchReadingAcceptancePolicy()

        XCTAssertTrue(exactAcceptance.accept(exactBoundary, for: session.id, now: now))
        XCTAssertFalse(staleAcceptance.accept(pastBoundary, for: session.id, now: now))
    }

    func testQueuedHistoryUsesReceiverTransportAndSixtyMinuteBoundary() {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let now = receivedAt.addingTimeInterval(4_000)
        let exactBoundary = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-LibreWatchHistoryPolicy.maximumAge)
        )
        let pastBoundary = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: now.addingTimeInterval(-LibreWatchHistoryPolicy.maximumAge - 0.001)
        )
        let future = payload(
            raw: 820,
            previousRaw: 810,
            domain: .xDripRawGlucose,
            sensorTime: 1_002,
            at: now.addingTimeInterval(1)
        )

        XCTAssertNil(LibreWatchHistoryPolicy.rejection(
            reading: exactBoundary,
            transport: .queuedUserInfo,
            session: session,
            calibration: snapshot,
            ownership: .watch,
            now: now
        ))
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: exactBoundary,
            transport: .interactiveMessage,
            session: session,
            calibration: snapshot,
            ownership: .watch,
            now: now
        ), .invalidPayload)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: pastBoundary,
            transport: .queuedUserInfo,
            session: session,
            calibration: snapshot,
            ownership: .watch,
            now: now
        ), .tooOld)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: future,
            transport: .queuedUserInfo,
            session: session,
            calibration: snapshot,
            ownership: .watch,
            now: now
        ), .tooOld)
    }

    func testFreshQueuedFallbackUsesLiveRouteBeforeHistoricalBackfill() {
        XCTAssertEqual(
            LibreWatchQueuedReadingRoutingPolicy.route(
                transportAge: LibreWatchReadingAcceptancePolicy.maximumTransportAge,
                ownership: .watch
            ),
            .attemptLiveAcceptance
        )
        XCTAssertEqual(
            LibreWatchQueuedReadingRoutingPolicy.route(
                transportAge: LibreWatchReadingAcceptancePolicy.maximumTransportAge + 0.001,
                ownership: .watch
            ),
            .historicalBackfill
        )
        XCTAssertEqual(
            LibreWatchQueuedReadingRoutingPolicy.route(transportAge: 30, ownership: .iphone),
            .historicalBackfill
        )
    }

    func testReleaseReceiptAllowsOnlyPreCutoffQueuedHistoryAcrossPhoneReturn() throws {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let cutoff = receivedAt.addingTimeInterval(600)
        var receipt = try XCTUnwrap(LibreWatchReleaseReceipt(
            session: session,
            calibration: snapshot,
            cutoff: cutoff,
            now: cutoff
        ))
        let before = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: cutoff.addingTimeInterval(-60)
        )
        let after = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: cutoff.addingTimeInterval(1)
        )

        XCTAssertNil(LibreWatchHistoryPolicy.rejection(
            reading: before, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .releasingToPhone,
            receipt: receipt, now: cutoff.addingTimeInterval(10)
        ))
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: before, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .iphone,
            receipt: receipt, now: cutoff.addingTimeInterval(10)
        ), .missingReceipt)

        receipt.complete()
        XCTAssertNil(LibreWatchHistoryPolicy.rejection(
            reading: before, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .iphone,
            receipt: receipt, now: cutoff.addingTimeInterval(10)
        ))
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: after, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .iphone,
            receipt: receipt, now: cutoff.addingTimeInterval(10)
        ), .afterCutoff)
    }

    func testReleaseReceiptIsPersistedAndCannotCrossSessionOrCalibration() throws {
        let defaults = isolatedDefaults()
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let cutoff = receivedAt.addingTimeInterval(600)
        var receipt = try XCTUnwrap(LibreWatchReleaseReceipt(
            session: session,
            calibration: snapshot,
            cutoff: cutoff,
            now: cutoff
        ))
        receipt.complete()
        LibreWatchSessionStore.saveSession(session, defaults: defaults)
        LibreWatchSessionStore.saveReleaseReceipt(receipt, defaults: defaults)
        XCTAssertEqual(LibreWatchSessionStore.loadReleaseReceipt(defaults: defaults), receipt)

        let changedCalibration = calibration(type: .fixedSlope, slope: 1.1, intercept: 0)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: payload(
                raw: 800,
                previousRaw: 790,
                domain: .xDripRawGlucose,
                sensorTime: 1_000,
                at: cutoff.addingTimeInterval(-60)
            ),
            transport: .queuedUserInfo,
            session: session,
            calibration: changedCalibration,
            ownership: .iphone,
            receipt: receipt,
            now: cutoff.addingTimeInterval(10)
        ), .missingReceipt)

        let replacementSession = LibreWatchDirectSession(
            sensorUID: session.sensorUID,
            patchInfo: session.patchInfo,
            sensorSerialNumber: session.sensorSerialNumber,
            sensorTypeRawValue: session.sensorTypeRawValue,
            expectedPeripheralName: session.expectedPeripheralName,
            unlockCode: session.unlockCode,
            unlockCount: session.unlockCount,
            algorithmParameters: session.algorithmParameters
        )
        LibreWatchSessionStore.saveSession(replacementSession, defaults: defaults)
        XCTAssertNil(LibreWatchSessionStore.loadReleaseReceipt(defaults: defaults))
    }

    func testFailedReleaseClearsReceiptAndRestoresConservativeWatchOwner() throws {
        let defaults = isolatedDefaults()
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let cutoff = receivedAt.addingTimeInterval(600)
        let receipt = try XCTUnwrap(LibreWatchReleaseReceipt(
            session: session,
            calibration: snapshot,
            cutoff: cutoff,
            now: cutoff
        ))
        LibreWatchSessionStore.saveSession(session, defaults: defaults)
        LibreWatchSessionStore.saveReleaseReceipt(receipt, defaults: defaults)
        LibreWatchSessionStore.saveOwnership(.releasingToPhone, defaults: defaults)

        // Mirrors the failed returnSensorToPhone branch: never enable iPhone when
        // the physical release was not completed.
        LibreWatchSessionStore.clearReleaseReceipt(defaults: defaults)
        LibreWatchSessionStore.saveOwnership(.watch, defaults: defaults)

        XCTAssertNil(LibreWatchSessionStore.loadReleaseReceipt(defaults: defaults))
        let startup = LibreWatchPhoneStartupDecision.resolve(
            persistedOwnership: LibreWatchSessionStore.loadOwnership(defaults: defaults),
            persistedSession: LibreWatchSessionStore.loadSession(defaults: defaults),
            activeSensorUID: session.sensorUID,
            activePatchInfo: session.patchInfo
        )
        XCTAssertTrue(startup.phoneConnectionIsBlocked)
        XCTAssertEqual(startup.ownership, .watch)
    }

    func testExpiredReceiptCannotAuthorizeQueuedHistoryAfterReturn() throws {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let cutoff = receivedAt.addingTimeInterval(600)
        var receipt = try XCTUnwrap(LibreWatchReleaseReceipt(
            session: session,
            calibration: snapshot,
            cutoff: cutoff,
            now: cutoff
        ))
        receipt.complete()
        let reading = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: cutoff.addingTimeInterval(-60)
        )
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: reading,
            transport: .queuedUserInfo,
            session: session,
            calibration: snapshot,
            ownership: .iphone,
            receipt: receipt,
            now: receipt.expiresAt.addingTimeInterval(0.001)
        ), .tooOld)
    }

    @MainActor
    func testBackfillUsesPersistentPayloadIdentityAndPreservesPhoneCollision() async throws {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = stack.mainManagedObjectContext
        let sensor = Sensor(startDate: session.createdAt, nsManagedObjectContext: context)
        let reading = payload(
            raw: 847,
            previousRaw: 830,
            domain: .factoryNativeMGDL,
            sensorTime: 1_234,
            at: receivedAt
        )
        let phone = BgReading(
            timeStamp: receivedAt,
            sensor: sensor,
            calibration: nil,
            rawData: 120,
            deviceName: nil,
            nsManagedObjectContext: context
        )
        phone.calculatedValue = 120
        phone.id = reading.id.uuidString
        XCTAssertTrue(stack.saveChanges())

        let sensorID = sensor.id
        await stack.privateManagedObjectContext.perform {}
        context.reset()
        let request: NSFetchRequest<BgReading> = BgReading.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", reading.id.uuidString)
        let stored = try XCTUnwrap(context.fetch(request).first)

        XCTAssertFalse(stored.objectID.isTemporaryID)
        XCTAssertTrue(LibreWatchHistoryPolicy.collides(
            payloadID: reading.id.uuidString,
            measuredAt: receivedAt.addingTimeInterval(-600),
            sensorID: sensorID,
            existingID: stored.id,
            existingAt: stored.timeStamp,
            existingSensorID: stored.sensor?.id
        ))
        XCTAssertTrue(LibreWatchHistoryPolicy.collides(
            payloadID: UUID().uuidString,
            measuredAt: receivedAt.addingTimeInterval(5),
            sensorID: sensorID,
            existingID: stored.id,
            existingAt: stored.timeStamp,
            existingSensorID: stored.sensor?.id
        ))
        XCTAssertFalse(LibreWatchHistoryPolicy.collides(
            payloadID: reading.id.uuidString,
            measuredAt: receivedAt,
            sensorID: "another-sensor",
            existingID: stored.id,
            existingAt: stored.timeStamp,
            existingSensorID: stored.sensor?.id
        ))
        XCTAssertEqual(stored.calculatedValue, 120)
        XCTAssertEqual(try context.count(for: BgReading.fetchRequest()), 1)
    }

    @MainActor
    func testHistoricalTimeCollisionIgnoresInvalidDifferentPayloadButPreservesExactIdentity() throws {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = stack.mainManagedObjectContext
        let sensor = Sensor(startDate: session.createdAt, nsManagedObjectContext: context)
        let invalid = BgReading(
            timeStamp: receivedAt,
            sensor: sensor,
            calibration: nil,
            rawData: 100,
            deviceName: nil,
            nsManagedObjectContext: context
        )
        invalid.calculatedValue = 0
        invalid.id = UUID().uuidString
        let incomingID = UUID().uuidString

        XCTAssertFalse(invalid.isValidForDownstream)
        XCTAssertFalse(LibreWatchHistoryPolicy.collides(
            payloadID: incomingID,
            measuredAt: receivedAt,
            sensorID: sensor.id,
            existingID: invalid.id,
            existingAt: invalid.timeStamp,
            existingSensorID: invalid.sensor?.id,
            existingIsValid: invalid.isValidForDownstream
        ))
        XCTAssertTrue(LibreWatchHistoryPolicy.collides(
            payloadID: invalid.id,
            measuredAt: receivedAt.addingTimeInterval(-600),
            sensorID: sensor.id,
            existingID: invalid.id,
            existingAt: invalid.timeStamp,
            existingSensorID: invalid.sensor?.id,
            existingIsValid: invalid.isValidForDownstream
        ))
        XCTAssertEqual(
            LibreWatchStoredReadingPolicy.outcome(
                isValid: invalid.isValidForDownstream,
                calculatedValue: invalid.calculatedValue
            ),
            .historyNotInserted
        )

        invalid.calculatedValue = 100
        invalid.ageAdjustedRawValue = 100
        XCTAssertTrue(invalid.isValidForDownstream)
        XCTAssertTrue(LibreWatchHistoryPolicy.collides(
            payloadID: incomingID,
            measuredAt: receivedAt,
            sensorID: sensor.id,
            existingID: invalid.id,
            existingAt: invalid.timeStamp,
            existingSensorID: invalid.sensor?.id,
            existingIsValid: invalid.isValidForDownstream
        ))
    }

    @MainActor
    func testHistoricalCalibrationDoesNotRefineCalibrationOrChangeCurrentValueAndTrend() throws {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = stack.mainManagedObjectContext
        let sensor = Sensor(startDate: session.createdAt, nsManagedObjectContext: context)
        let calibration = Calibration(
            timeStamp: receivedAt.addingTimeInterval(-600),
            sensor: sensor,
            bg: 100,
            rawValue: 100,
            adjustedRawValue: 100,
            sensorConfidence: 1,
            rawTimeStamp: receivedAt.addingTimeInterval(-600),
            slope: 1.1,
            intercept: 4,
            distanceFromEstimate: 0,
            estimateRawAtTimeOfCalibration: 100,
            slopeConfidence: 1,
            deviceName: nil,
            nsManagedObjectContext: context
        )
        let current = BgReading(
            timeStamp: receivedAt,
            sensor: sensor,
            calibration: calibration,
            rawData: 100,
            deviceName: nil,
            nsManagedObjectContext: context
        )
        current.calculatedValue = 114
        current.calculatedValueSlope = 0.02
        current.calibrationFlag = true

        let calibrators: [Calibrator] = [Libre1Calibrator(), Libre1NonFixedSlopeCalibrator()]
        for calibrator in calibrators {
            var previous = [current]
            var calibrations = [calibration]
            let reading = calibrator.createHistoricalBgReading(
                rawData: 847 * ConstantsBloodGlucose.libreMultiplier,
                timeStamp: receivedAt.addingTimeInterval(-300),
                sensor: sensor,
                last3Readings: &previous,
                lastCalibrationsForActiveSensorInLastXDays: &calibrations,
                firstCalibration: calibration,
                lastCalibration: calibration,
                deviceName: nil,
                nsManagedObjectContext: context
            )
            XCTAssertEqual(
                reading.calculatedValue,
                iphoneCalibratedValue(
                    input: 847 * ConstantsBloodGlucose.libreMultiplier,
                    slope: 1.1,
                    intercept: 4,
                    divider: 1_000
                ),
                accuracy: 0.000_001
            )
            XCTAssertEqual(calibration.slope, 1.1)
            XCTAssertEqual(calibration.intercept, 4)
            XCTAssertEqual(calibration.estimateRawAtTimeOfCalibration, 100)
            XCTAssertEqual(current.calculatedValue, 114)
            XCTAssertEqual(current.calculatedValueSlope, 0.02)
        }
    }

    func testHistoricalOutOfOrderEligibilityDoesNotMoveLiveWatermark() {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let now = receivedAt.addingTimeInterval(3_600)
        let live = payload(
            raw: 900,
            previousRaw: 890,
            domain: .xDripRawGlucose,
            sensorTime: 2_000,
            at: now
        )
        let historicalNewer = payload(
            raw: 850,
            previousRaw: 840,
            domain: .xDripRawGlucose,
            sensorTime: 1_500,
            at: now.addingTimeInterval(-600)
        )
        let historicalOlder = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-1_800)
        )
        var liveAcceptance = LibreWatchReadingAcceptancePolicy()
        XCTAssertTrue(liveAcceptance.accept(live, for: session.id, now: now))

        for reading in [historicalNewer, historicalOlder] {
            XCTAssertNil(LibreWatchHistoryPolicy.rejection(
                reading: reading,
                transport: .queuedUserInfo,
                session: session,
                calibration: snapshot,
                ownership: .watch,
                now: now
            ))
        }
        XCTAssertEqual(liveAcceptance.lastSensorTimeInMinutes, live.sensorTimeInMinutes)
        XCTAssertEqual(liveAcceptance.lastReceivedAt, live.receivedAt)
        XCTAssertTrue(liveAcceptance.accept(
            payload(
                raw: 910,
                previousRaw: 900,
                domain: .xDripRawGlucose,
                sensorTime: 2_001,
                at: now.addingTimeInterval(60)
            ),
            for: session.id,
            now: now.addingTimeInterval(60)
        ))
    }

    func testQueuedHistoryRejectsOwnershipSessionCalibrationAndValueMismatches() {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let now = receivedAt.addingTimeInterval(600)
        let valid = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-300)
        )
        let wrongSession = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-300),
            sessionID: UUID()
        )
        let wrongRevision = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-300),
            revision: snapshot.revision - 1
        )
        let invalidValue = payload(
            native: 0,
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-300)
        )
        let zeroID = payload(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-300)
        )
        let beforeSession = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: session.createdAt.addingTimeInterval(-1)
        )
        let zeroSensorTime = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 0,
            at: now.addingTimeInterval(-300)
        )

        XCTAssertNil(LibreWatchHistoryPolicy.rejection(
            reading: valid, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .watch, now: now
        ))
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: valid, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .iphone, now: now
        ), .missingReceipt)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: wrongSession, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .watch, now: now
        ), .wrongSession)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: wrongRevision, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .watch, now: now
        ), .wrongCalibration)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: invalidValue, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .watch, now: now
        ), .invalidPayload)
        for invalid in [zeroID, beforeSession, zeroSensorTime] {
            XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
                reading: invalid, transport: .queuedUserInfo, session: session,
                calibration: snapshot, ownership: .watch, now: now
            ), .invalidPayload)
        }
    }

    func testReadingAcceptanceAllowsFreshLowThenNextNormalReading() throws {
        let snapshot = calibration(type: .factoryCalibrated, slope: 1, intercept: 0)
        let low = payload(
            native: 38,
            previousNative: 45,
            raw: 1,
            previousRaw: 2,
            domain: .factoryNativeMGDL,
            sensorTime: 1_000,
            at: receivedAt
        )
        let normal = payload(
            native: 90,
            previousNative: 85,
            raw: 900,
            previousRaw: 850,
            domain: .factoryNativeMGDL,
            sensorTime: 1_001,
            at: receivedAt.addingTimeInterval(60)
        )
        var acceptance = LibreWatchReadingAcceptancePolicy()

        XCTAssertEqual(try XCTUnwrap(snapshot.displayedGlucose(for: low)), 38)
        XCTAssertTrue(acceptance.accept(low, for: session.id, now: receivedAt.addingTimeInterval(1)))
        XCTAssertTrue(acceptance.accept(
            normal,
            for: session.id,
            now: receivedAt.addingTimeInterval(61)
        ))
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.displayedGlucose(for: normal)), 38)
    }

    func testInternalCalibrationMarkerIsNotAClinicalLowButCompletedThirtyNineIsValid() {
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: 92,
                rawData: 92,
                ageAdjustedRawValue: 0,
                finalValue: 92,
                calibrationUsesErrorSentinel: false
            ),
            .valid
        )
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: 38,
                rawData: 0.12,
                ageAdjustedRawValue: 0.12,
                finalValue: 38,
                calibrationUsesErrorSentinel: true
            ),
            .internalCalibrationError
        )
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: 39,
                rawData: 11.7,
                ageAdjustedRawValue: 11.7,
                finalValue: 39,
                calibrationUsesErrorSentinel: true
            ),
            .valid
        )
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: 95,
                rawData: 95,
                ageAdjustedRawValue: 0,
                finalValue: 95,
                calibrationUsesErrorSentinel: false
            ),
            .valid
        )
    }

    func testFreshNativeThirtyEightRemainsAValidPhysiologicalLow() {
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: 38,
                rawData: 38,
                ageAdjustedRawValue: 0,
                finalValue: 38,
                calibrationUsesErrorSentinel: false
            ),
            .valid
        )
    }

    func testTwoUncalibratedRawReadingsRequestInitialCalibrationExactlyOnce() {
        var gate = InitialCalibrationRequestGate()

        XCTAssertFalse(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: false,
            validRawReadingCount: 2,
            initialCalibrationIsRequired: true
        ))
        XCTAssertFalse(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: true,
            validRawReadingCount: 1,
            initialCalibrationIsRequired: true
        ))
        XCTAssertTrue(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: true,
            validRawReadingCount: 2,
            initialCalibrationIsRequired: true
        ))
        XCTAssertFalse(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: true,
            validRawReadingCount: 3,
            initialCalibrationIsRequired: true
        ))
        XCTAssertEqual(gate.requestedSensorID, "sensor-a")
    }

    func testUncalibratedRawReadingsRemainUnavailableToDownstreamConsumers() {
        let readings = [
            (rawValue: 82.0, calculatedValue: 0.0),
            (rawValue: 84.0, calculatedValue: 0.0)
        ]
        var gate = InitialCalibrationRequestGate()

        XCTAssertTrue(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: true,
            validRawReadingCount: readings.count,
            initialCalibrationIsRequired: true
        ))

        let downstreamReadings = readings.filter {
            BgReadingDownstreamPolicy.validity(
                calculatedValue: $0.calculatedValue,
                rawData: $0.rawValue,
                ageAdjustedRawValue: $0.rawValue,
                finalValue: $0.calculatedValue,
                calibrationUsesErrorSentinel: true
            ) == .valid
        }

        XCTAssertTrue(downstreamReadings.isEmpty)
    }

    func testCompletedReadingResumesDownstreamAfterInitialCalibration() {
        var gate = InitialCalibrationRequestGate()
        let completed = (rawValue: 84.0, calculatedValue: 91.0)

        XCTAssertFalse(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: true,
            validRawReadingCount: 2,
            initialCalibrationIsRequired: false
        ))
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: completed.calculatedValue,
                rawData: completed.rawValue,
                ageAdjustedRawValue: completed.rawValue,
                finalValue: completed.calculatedValue,
                calibrationUsesErrorSentinel: true
            ),
            .valid
        )
    }

    func testWatchRejectsFailedXDripCalculationInsteadOfDisplayingFalseLow() {
        let failed = payload(
            native: 84,
            previousNative: 83,
            raw: 1,
            previousRaw: 1,
            domain: .xDripRawGlucose
        )
        let completedLow = payload(
            native: 84,
            previousNative: 83,
            raw: 100,
            previousRaw: 100,
            domain: .xDripRawGlucose
        )
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)

        XCTAssertNil(snapshot.displayedGlucose(for: failed))
        XCTAssertEqual(snapshot.displayedGlucose(for: completedLow), 39)
    }

    func testHealthKitUploadStateSerializesConcurrentStoreRequestsWithoutSkippingFailures() {
        let first = receivedAt
        let second = receivedAt.addingTimeInterval(60)
        var state = HealthKitUploadState(latestStoredTimeStamp: receivedAt.addingTimeInterval(-60))

        XCTAssertTrue(state.begin(timeStamp: first, now: receivedAt))
        XCTAssertFalse(state.begin(timeStamp: second, now: receivedAt))
        XCTAssertFalse(state.beginReplacement(timeStamp: first))
        XCTAssertTrue(state.beginReplacement(timeStamp: second))
        XCTAssertTrue(state.isInFlight(timeStamp: second))
        state.finishReplacement(timeStamp: second)
        XCTAssertEqual(
            state.finish(timeStamp: second, succeeded: true, now: receivedAt),
            .ignored
        )

        let retryAt = receivedAt.addingTimeInterval(30)
        XCTAssertEqual(
            state.finish(timeStamp: first, succeeded: false, now: receivedAt),
            .retry(retryAt)
        )
        XCTAssertEqual(state.latestStoredTimeStamp, receivedAt.addingTimeInterval(-60))
        XCTAssertFalse(state.begin(timeStamp: first, now: retryAt.addingTimeInterval(-1)))
        XCTAssertTrue(state.begin(timeStamp: first, now: retryAt))
        XCTAssertEqual(
            state.finish(timeStamp: first, succeeded: true, now: retryAt),
            .stored(first)
        )
        XCTAssertTrue(state.begin(timeStamp: second, now: retryAt))
        XCTAssertEqual(
            state.finish(timeStamp: second, succeeded: true, now: retryAt),
            .stored(second)
        )
        state.synchronizeLatestStoredTimeStamp(first)
        XCTAssertEqual(state.latestStoredTimeStamp, second)
    }

    func testColdLaunchWithMatchingWatchOwnerBlocksPhoneBeforeBluetoothStarts() {
        let decision = LibreWatchPhoneStartupDecision.resolve(
            persistedOwnership: .watch,
            persistedSession: session,
            activeSensorUID: session.sensorUID,
            activePatchInfo: session.patchInfo
        )

        XCTAssertEqual(decision.ownership, .watch)
        XCTAssertTrue(decision.phoneConnectionIsBlocked)
        XCTAssertEqual(decision.session?.id, session.id)
    }

    func testCompletedReturnToIPhoneAllowsNormalPhoneConnection() {
        let decision = LibreWatchPhoneStartupDecision.resolve(
            persistedOwnership: .iphone,
            persistedSession: session,
            activeSensorUID: session.sensorUID,
            activePatchInfo: session.patchInfo
        )

        XCTAssertEqual(decision.ownership, .iphone)
        XCTAssertFalse(decision.phoneConnectionIsBlocked)
    }

    func testInterruptedHandoffsStayWithWatchAndSensorChangeCannotCreateDualOwnership() {
        for interrupted in [
            LibreWatchOwnership.releasingToWatch,
            .releasingToPhone,
            .recovery
        ] {
            let decision = LibreWatchPhoneStartupDecision.resolve(
                persistedOwnership: interrupted,
                persistedSession: session,
                activeSensorUID: session.sensorUID,
                activePatchInfo: session.patchInfo
            )
            XCTAssertEqual(decision.ownership, .watch)
            XCTAssertTrue(decision.phoneConnectionIsBlocked)
        }

        let changedSensor = LibreWatchPhoneStartupDecision.resolve(
            persistedOwnership: .watch,
            persistedSession: session,
            activeSensorUID: Data(repeating: 9, count: 8),
            activePatchInfo: session.patchInfo
        )
        XCTAssertEqual(changedSensor.ownership, .iphone)
        XCTAssertFalse(changedSensor.phoneConnectionIsBlocked)
    }

    func testReadingAcceptanceResetsForNewOwnershipSession() {
        let first = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: receivedAt
        )
        var acceptance = LibreWatchReadingAcceptancePolicy()
        XCTAssertTrue(acceptance.accept(first, for: session.id, now: receivedAt.addingTimeInterval(1)))

        acceptance.reset(for: session.id)
        XCTAssertTrue(acceptance.accept(first, for: session.id, now: receivedAt.addingTimeInterval(2)))

        acceptance.reset()
        XCTAssertNil(acceptance.sessionID)
        XCTAssertNil(acceptance.lastSensorTimeInMinutes)
        XCTAssertNil(acceptance.lastReceivedAt)
    }

    func testReturningOwnershipToIPhoneStopsRuntimeAndRecovery() {
        XCTAssertTrue(LibreWatchLifecyclePolicy.shouldStopExtendedRuntime(
            ownership: .releasingToPhone
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.shouldStopExtendedRuntime(
            ownership: .iphone
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: true,
            extendedRuntimeIsRunning: true,
            ownership: .iphone
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(
            ownership: .iphone
        ))
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.disconnectRecoveryAction(
                isDeliberate: false,
                systemIsReconnecting: false,
                ownership: .iphone
            ),
            .noAdditionalWork
        )
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.disconnectRecoveryAction(
                isDeliberate: true,
                systemIsReconnecting: false,
                ownership: .watch
            ),
            .finishDeliberateDisconnect
        )
    }

    private func restorationAction(
        _ restoration: inout LibreWatchRestorationState,
        generation: UUID,
        centralIsPoweredOn: Bool = true,
        peripheralState: LibreWatchObservedPeripheralState = .connected,
        hasService: Bool = true,
        hasWriteCharacteristic: Bool = true,
        hasReceiveCharacteristic: Bool = true,
        receiveIsNotifying: Bool = true,
        connectionPhase: LibreWatchConnectionTiming.Phase? = nil,
        ownership: LibreWatchOwnership = .watch,
        cancellationIsActive: Bool = false
    ) -> LibreWatchRestorationState.Action {
        restoration.nextAction(
            centralIsPoweredOn: centralIsPoweredOn,
            peripheralState: peripheralState,
            hasService: hasService,
            hasWriteCharacteristic: hasWriteCharacteristic,
            hasReceiveCharacteristic: hasReceiveCharacteristic,
            receiveIsNotifying: receiveIsNotifying,
            connectionPhase: connectionPhase,
            currentGeneration: generation,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            ownership: ownership,
            cancellationIsActive: cancellationIsActive
        )
    }

    private func freshRestorationAction(
        generation: UUID,
        hasService: Bool,
        hasWriteCharacteristic: Bool,
        hasReceiveCharacteristic: Bool,
        receiveIsNotifying: Bool
    ) -> LibreWatchRestorationState.Action {
        var restoration = LibreWatchRestorationState(
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: generation
        )
        return restorationAction(
            &restoration,
            generation: generation,
            hasService: hasService,
            hasWriteCharacteristic: hasWriteCharacteristic,
            hasReceiveCharacteristic: hasReceiveCharacteristic,
            receiveIsNotifying: receiveIsNotifying
        )
    }

    private var watchAlgorithmParameters: LibreWatchAlgorithmParameters {
        LibreWatchAlgorithmParameters(
            slopeSlope: 0,
            slopeOffset: 0,
            offsetSlope: 0.1,
            offsetOffset: 0,
            extraSlope: 1,
            extraOffset: 0,
            sensorSerialNumber: "TEST-SENSOR"
        )
    }

    private var phoneAlgorithmParameters: Libre1DerivedAlgorithmParameters {
        Libre1DerivedAlgorithmParameters(
            slope_slope: watchAlgorithmParameters.slopeSlope,
            slope_offset: watchAlgorithmParameters.slopeOffset,
            offset_slope: watchAlgorithmParameters.offsetSlope,
            offset_offset: watchAlgorithmParameters.offsetOffset,
            isValidForFooterWithReverseCRCs: 0,
            extraSlope: watchAlgorithmParameters.extraSlope,
            extraOffset: watchAlgorithmParameters.extraOffset,
            sensorSerialNumber: watchAlgorithmParameters.sensorSerialNumber
        )
    }

    private var session: LibreWatchDirectSession {
        LibreWatchDirectSession(
            id: UUID(uuidString: "A0B1C2D3-E4F5-4678-9123-456789ABCDEF")!,
            createdAt: receivedAt.addingTimeInterval(-3_600),
            sensorUID: Data([1, 2, 3, 4, 5, 6, 7, 8]),
            patchInfo: Data([0, 1, 2, 3, 4, 5]),
            sensorSerialNumber: "TEST-SENSOR",
            sensorTypeRawValue: "7F",
            expectedPeripheralName: "AABBCCDDEEFF",
            unlockCode: 1_000,
            unlockCount: 4,
            algorithmParameters: watchAlgorithmParameters
        )
    }

    private func calibration(
        type: LibreWatchCalibrationType,
        slope: Double,
        intercept: Double,
        revision: UInt64 = 10
    ) -> LibreWatchCalibrationSnapshot {
        LibreWatchCalibrationSnapshot(
            activeSensorID: "active-sensor",
            sensorUID: session.sensorUID,
            sensorSerialNumber: session.sensorSerialNumber,
            watchSessionID: session.id,
            calibrationType: type,
            slope: slope,
            intercept: intercept,
            rawValueDivider: type.usesXDripCalibration ? 1_000 : 1,
            calibratedAt: receivedAt.addingTimeInterval(-600),
            revision: revision
        )
    }

    private func payload(
        version: Int = LibreWatchDirectReadingPayload.currentVersion,
        id: UUID = UUID(),
        native: Double = 84.7,
        previousNative: Double = 82.9,
        raw: UInt16,
        previousRaw: UInt16,
        domain: LibreWatchValueDomain,
        sensorTime: UInt16 = 1_234,
        at timestamp: Date? = nil,
        sessionID: UUID? = nil,
        revision: UInt64 = 10
    ) -> LibreWatchDirectReadingPayload {
        LibreWatchDirectReadingPayload(
            version: version,
            id: id,
            sessionID: sessionID ?? session.id,
            valueDomain: domain,
            nativeGlucoseMGDL: native,
            previousNativeGlucoseMGDL: previousNative,
            rawGlucose: raw,
            previousRawGlucose: previousRaw,
            sensorTimeInMinutes: sensorTime,
            receivedAt: timestamp ?? receivedAt,
            calibrationRevision: revision
        )
    }

    private func iphoneCalibratedValue(
        input: Double,
        slope: Double,
        intercept: Double,
        divider: Double
    ) -> Double {
        let calculated = slope * (input / divider) + intercept
        if calculated < 10 { return 38 }
        return min(400, max(39, calculated))
    }

    private func phoneParsedValue(
        frame: Data,
        parameters: Libre1DerivedAlgorithmParameters?
    ) -> Double {
        clearPhoneLibreParserCache()
        defer { clearPhoneLibreParserCache() }
        return Libre2BLEUtilities.parseBLEData(
            frame,
            libre1DerivedAlgorithmParameters: parameters
        ).bleGlucose.first!.glucoseLevelRaw
    }

    private func decryptedFrame(currentRaw: Int, previousRaw: Int) -> Data {
        var frame = Data(repeating: 0, count: Libre2WatchDirectConstants.decryptedFrameLength)
        for sampleIndex in 0 ..< 7 {
            let raw = max(1, currentRaw - sampleIndex * (currentRaw - previousRaw))
            setBits(raw, in: &frame, byteOffset: sampleIndex * 4, bitOffset: 0, bitCount: 14)
            setBits(2_000, in: &frame, byteOffset: sampleIndex * 4, bitOffset: 14, bitCount: 12)
        }
        frame[40] = 0xD2
        frame[41] = 0x04
        return frame
    }

    private func setBits(
        _ value: Int,
        in data: inout Data,
        byteOffset: Int,
        bitOffset: Int,
        bitCount: Int
    ) {
        for index in 0 ..< bitCount {
            let absoluteBit = byteOffset * 8 + bitOffset + index
            let byteIndex = absoluteBit / 8
            let bitMask = UInt8(1 << (absoluteBit % 8))
            if (value & (1 << index)) != 0 {
                data[byteIndex] |= bitMask
            } else {
                data[byteIndex] &= ~bitMask
            }
        }
    }

    private func clearPhoneLibreParserCache() {
        UserDefaults.standard.previousRawGlucoseValues = nil
        UserDefaults.standard.previousRawTemperatureValues = nil
        UserDefaults.standard.previousTemperatureAdjustmentValues = nil
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "LibreWatchValuePipelineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

extension LibreWatchValuePipelineTests {
    func testComplicationMissingOrCorruptStorageNeverProducesSampleReadings() throws {
        XCTAssertNil(ComplicationSharedUserDefaultsModel.decodeStoredData(nil))
        XCTAssertNil(ComplicationSharedUserDefaultsModel.decodeStoredData(Data("invalid".utf8)))
        var model = complicationModel()
        model.bgReadingDatesAsDouble = []
        XCTAssertNil(ComplicationSharedUserDefaultsModel.decodeStoredData(try JSONEncoder().encode(model)))
    }

    func testDirectComplicationTimelineExpiresWithoutAnotherWatchUpdate() throws {
        let model = complicationModel()
        let readingDate = try XCTUnwrap(model.latestReadingDate)
        let entries = model.timelineDates(startingAt: readingDate.addingTimeInterval(30))
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(model.readingIsCurrent(at: entries[0]))
        XCTAssertTrue(model.readingIsCurrent(at: readingDate.addingTimeInterval(180)))
        XCTAssertFalse(model.readingIsCurrent(at: entries[1]))
        XCTAssertEqual(entries[1].timeIntervalSince(readingDate), 180.001, accuracy: 0.0001)
        XCTAssertEqual(model.bgReadingValues, [85])
        XCTAssertEqual(model.slopeOrdinal, 4) // Storage is unchanged; the expired presentation hides it.
    }

    func testDirectComplicationExpirySurvivesProcessRestart() throws {
        let model = complicationModel()
        let restarted = try XCTUnwrap(ComplicationSharedUserDefaultsModel.decodeStoredData(JSONEncoder().encode(model)))
        let now = try XCTUnwrap(model.latestReadingDate).addingTimeInterval(240)
        XCTAssertEqual(restarted.readingSource, .directLibre)
        XCTAssertEqual(restarted.latestReadingDate, model.latestReadingDate)
        XCTAssertFalse(restarted.readingIsCurrent(at: now))
        XCTAssertEqual(restarted.timelineDates(startingAt: now), [now])
    }

    func testLegacyPhoneComplicationStorageKeepsItsExistingFreshnessWindow() throws {
        var model = complicationModel()
        model.readingSource = nil
        let encoded = try JSONEncoder().encode(model)
        let legacy = try XCTUnwrap(ComplicationSharedUserDefaultsModel.decodeStoredData(encoded))
        let readingDate = try XCTUnwrap(legacy.latestReadingDate)
        XCTAssertNil(legacy.readingSource)
        XCTAssertTrue(legacy.readingIsCurrent(at: readingDate.addingTimeInterval(181)))
        XCTAssertFalse(legacy.readingIsCurrent(at: readingDate.addingTimeInterval(1_201)))
    }

    func testComplicationKeepsValidLowAndDoesNotInventDataWhenDisabled() throws {
        var model = complicationModel()
        model.bgReadingValues = [38]
        let decoded = try XCTUnwrap(ComplicationSharedUserDefaultsModel.decodeStoredData(JSONEncoder().encode(model)))
        XCTAssertEqual(decoded.bgReadingValues, [38])
        model.keepAliveIsDisabled = true
        let now = try XCTUnwrap(model.latestReadingDate)
        XCTAssertFalse(model.readingIsCurrent(at: now))
        XCTAssertEqual(model.timelineDates(startingAt: now), [now])
    }

    private func complicationModel() -> ComplicationSharedUserDefaultsModel {
        ComplicationSharedUserDefaultsModel(
            bgReadingValues: [85],
            bgReadingDatesAsDouble: [Date(timeIntervalSince1970: 1_783_000_000).timeIntervalSince1970],
            isMgDl: false,
            slopeOrdinal: 4,
            deltaValueInUserUnit: 0.1,
            urgentLowLimitInMgDl: 60,
            lowLimitInMgDl: 80,
            highLimitInMgDl: 180,
            urgentHighLimitInMgDl: 250,
            keepAliveIsDisabled: false,
            readingSource: .directLibre
        )
    }
}

extension LibreWatchValuePipelineTests {
    func testWatchAlarmsUseActualThresholdsAndAcceptGenuineLow() {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        let lease = alarmDelegation(settings)
        let low = state.accept(id: UUID(), measuredAt: receivedAt, glucose: 38, settings: settings,
            delegation: lease, watchOwnsSensor: true, now: receivedAt)
        XCTAssertEqual(low?.kind, .veryLow)
        let next = receivedAt.addingTimeInterval(60)
        XCTAssertNil(state.accept(id: UUID(), measuredAt: next, glucose: 120, settings: settings,
            delegation: lease, watchOwnsSensor: true, now: next))
        let high = next.addingTimeInterval(60)
        XCTAssertEqual(state.accept(id: UUID(), measuredAt: high, glucose: 260, settings: settings,
            delegation: lease, watchOwnsSensor: true, now: high)?.kind, .veryHigh)
    }

    func testWatchAlarmsDoNotEnableDisabledRulesOrDelegateWithoutPermission() {
        let enabled = alarmSettings()
        XCTAssertNil(enabled.readinessRevision(notificationsAuthorized: false))
        let disabled = alarmSettings(enabled: false)
        XCTAssertEqual(disabled.readinessRevision(notificationsAuthorized: false), disabled.revision)
        var state = LibreWatchAlarmState()
        state.use(disabled)
        XCTAssertNil(state.accept(id: UUID(), measuredAt: receivedAt, glucose: 38, settings: disabled,
            delegation: alarmDelegation(disabled), watchOwnsSensor: true, now: receivedAt))
        XCTAssertNil(state.nextMissedAlarm(settings: disabled, delegation: alarmDelegation(disabled),
            watchOwnsSensor: true, now: receivedAt))
    }

    func testWatchAlarmsRequireMatchingDelegationAndCurrentOwnership() {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        let wrong = LibreWatchAlarmDelegation(sessionID: UUID(), sensorIdentity: settings.sensorIdentity, settingsRevision: settings.revision)
        XCTAssertNil(state.accept(id: UUID(), measuredAt: receivedAt, glucose: 38, settings: settings,
            delegation: wrong, watchOwnsSensor: true, now: receivedAt))
        XCTAssertNil(state.accept(id: UUID(), measuredAt: receivedAt, glucose: 38, settings: settings,
            delegation: alarmDelegation(settings), watchOwnsSensor: false, now: receivedAt))
        XCTAssertNil(state.lastReadingAt)
        XCTAssertNil(state.nextMissedAlarm(settings: settings, delegation: alarmDelegation(settings),
            watchOwnsSensor: false, now: receivedAt))
    }

    func testWatchAlarmsRejectHistoricalDuplicateAndOutOfOrderReadings() {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        let lease = alarmDelegation(settings)
        XCTAssertNil(state.accept(id: UUID(), measuredAt: receivedAt.addingTimeInterval(-181), glucose: 38,
            settings: settings, delegation: lease, watchOwnsSensor: true, now: receivedAt))
        XCTAssertNil(state.lastReadingAt)
        let id = UUID()
        XCTAssertNil(state.accept(id: id, measuredAt: receivedAt, glucose: 120,
            settings: settings, delegation: lease, watchOwnsSensor: true, now: receivedAt))
        XCTAssertNil(state.accept(id: id, measuredAt: receivedAt, glucose: 38,
            settings: settings, delegation: lease, watchOwnsSensor: true, now: receivedAt))
        XCTAssertNil(state.accept(id: UUID(), measuredAt: receivedAt.addingTimeInterval(-60), glucose: 38,
            settings: settings, delegation: lease, watchOwnsSensor: true, now: receivedAt))
        XCTAssertEqual(state.lastReadingAt, receivedAt)
    }

    func testWatchMissedAlarmUsesOriginalMeasurementAndSnoozeDeadlineAfterRestart() throws {
        let defaults = isolatedDefaults()
        let until = receivedAt.addingTimeInterval(20 * 60)
        let settings = alarmSettings(snoozeAllUntil: until)
        var state = LibreWatchAlarmState()
        state.use(settings)
        XCTAssertNil(state.accept(id: UUID(), measuredAt: receivedAt, glucose: 38,
            settings: settings, delegation: alarmDelegation(settings), watchOwnsSensor: true, now: receivedAt))
        state.snooze(.missed, until: receivedAt.addingTimeInterval(30 * 60))
        LibreWatchAlarmStore.save(state, defaults: defaults)
        LibreWatchAlarmStore.save(settings, defaults: defaults)
        LibreWatchAlarmStore.save(alarmDelegation(settings), defaults: defaults)
        let restored = LibreWatchAlarmStore.state(defaults: defaults)
        let restoredSettings = try XCTUnwrap(LibreWatchAlarmStore.settings(defaults: defaults))
        let due = restored.nextMissedAlarm(settings: restoredSettings,
            delegation: LibreWatchAlarmStore.delegation(defaults: defaults), watchOwnsSensor: true,
            now: receivedAt.addingTimeInterval(60))
        XCTAssertEqual(due?.date, receivedAt.addingTimeInterval(30 * 60))
        XCTAssertEqual(restored.lastReadingAt, receivedAt)
        XCTAssertEqual(restoredSettings.snoozeAllUntil, until)
    }

    func testWatchLowSnoozeAlsoSuppressesUrgentLowAndSurvivesNewConfig() {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        state.snooze(.low, until: receivedAt.addingTimeInterval(600))
        var newer = settings
        newer.revision += 1
        state.use(newer)
        XCTAssertNil(state.accept(id: UUID(), measuredAt: receivedAt, glucose: 38,
            settings: newer, delegation: alarmDelegation(newer), watchOwnsSensor: true, now: receivedAt))
        let later = receivedAt.addingTimeInterval(601)
        XCTAssertEqual(state.accept(id: UUID(), measuredAt: later, glucose: 38,
            settings: newer, delegation: alarmDelegation(newer), watchOwnsSensor: true, now: later)?.kind, .veryLow)
    }

    func testWatchAlarmSensorSessionChangeInvalidatesPreviousMeasurementAndSnooze() {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        _ = state.accept(id: UUID(), measuredAt: receivedAt, glucose: 120,
            settings: settings, delegation: alarmDelegation(settings), watchOwnsSensor: true, now: receivedAt)
        state.snooze(.low, until: receivedAt.addingTimeInterval(600))
        let changed = LibreWatchAlarmSettings(sessionID: UUID(), sensorIdentity: "Libre-other", revision: 3,
            generatedAt: receivedAt, isMgDl: false, rules: settings.rules, snoozes: [], snoozeAllUntil: nil)
        state.use(changed)
        XCTAssertNil(state.lastReadingAt)
        XCTAssertTrue(state.snoozes.isEmpty)
        XCTAssertNil(state.nextMissedAlarm(settings: changed, delegation: alarmDelegation(settings),
            watchOwnsSensor: true, now: receivedAt))
    }

    func testWatchSnoozeBecomesPhoneAuthoritativeOnlyAfterStoredExpiryIsReturned() {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        let expiry = receivedAt.addingTimeInterval(600)
        state.snooze(.low, until: expiry)
        state.acknowledgePhoneSnoozes(settings)
        XCTAssertFalse(state.snoozes.isEmpty)
        let echoed = LibreWatchAlarmSettings(sessionID: settings.sessionID, sensorIdentity: settings.sensorIdentity,
            revision: 2, generatedAt: receivedAt, isMgDl: settings.isMgDl, rules: settings.rules,
            snoozes: state.snoozes, snoozeAllUntil: nil)
        state.acknowledgePhoneSnoozes(echoed)
        XCTAssertTrue(state.snoozes.isEmpty)
        XCTAssertEqual(state.snoozedUntil(.low, settings: echoed), expiry)
        XCTAssertEqual(state.snoozedUntil(.low, settings: settings), .distantPast)
    }

    func testWatchAlarmCompletionRevalidatesSettingsPermissionSnoozeAndLatestReading() throws {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        let readingID = UUID()
        let rule = try XCTUnwrap(state.accept(id: readingID, measuredAt: receivedAt, glucose: 38,
            settings: settings, delegation: alarmDelegation(settings), watchOwnsSensor: true, now: receivedAt))
        func permitted(_ state: LibreWatchAlarmState, _ current: LibreWatchAlarmSettings?, authorized: Bool = true) -> Bool {
            state.glucoseNotificationIsCurrent(readingID: readingID, rule: rule, submittedSettings: settings,
                currentSettings: current, delegation: alarmDelegation(settings), watchOwnsSensor: true,
                notificationsAuthorized: authorized, now: receivedAt)
        }
        XCTAssertTrue(permitted(state, settings))
        XCTAssertFalse(permitted(state, settings, authorized: false))
        var newer = settings
        newer.revision += 1
        XCTAssertFalse(permitted(state, newer))
        let snoozed = alarmSettings(snoozeAllUntil: receivedAt.addingTimeInterval(60))
        XCTAssertFalse(permitted(state, snoozed))
        var locallySnoozed = state
        locallySnoozed.snooze(.low, until: receivedAt.addingTimeInterval(60))
        XCTAssertFalse(permitted(locallySnoozed, settings))
        _ = state.accept(id: UUID(), measuredAt: receivedAt.addingTimeInterval(1), glucose: 120,
            settings: settings, delegation: alarmDelegation(settings), watchOwnsSensor: true,
            now: receivedAt.addingTimeInterval(1))
        XCTAssertFalse(permitted(state, settings))
    }

    func testWatchMissedAlarmRestoresUnconfirmedIntentButNotAlreadyDeliveredAlarm() throws {
        var state = LibreWatchAlarmState()
        state.scheduledMissedID = "scheduled-test"
        state.scheduledMissedAt = receivedAt.addingTimeInterval(300)
        state.scheduledMissedConfirmed = false
        let restored = try JSONDecoder().decode(LibreWatchAlarmState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(restored.shouldRestoreMissingMissedNotification(at: receivedAt.addingTimeInterval(600)))
        state.scheduledMissedConfirmed = true
        XCTAssertTrue(state.shouldRestoreMissingMissedNotification(at: receivedAt))
        XCTAssertFalse(state.shouldRestoreMissingMissedNotification(at: receivedAt.addingTimeInterval(600)))
        state.scheduledMissedID = nil
        XCTAssertFalse(state.shouldRestoreMissingMissedNotification(at: receivedAt))
    }

    func testQueuedWatchAlarmPresentationRechecksAuthorityButAllowsMissingReading() {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        let readingID = UUID()
        state.lastReadingID = readingID
        state.lastReadingAt = receivedAt.addingTimeInterval(-3600)
        func permitted(_ kind: LibreWatchAlarmKind, owner: Bool = true, authorized: Bool = true,
                       notificationSessionID: String? = nil, lease: LibreWatchAlarmDelegation? = nil) -> Bool {
            state.notificationMayBePresented(kind: kind,
                notificationSessionID: notificationSessionID ?? settings.sessionID.uuidString,
                notificationReadingID: readingID,
                settings: settings, delegation: lease ?? alarmDelegation(settings), watchOwnsSensor: owner,
                notificationsAuthorized: authorized, at: receivedAt)
        }
        XCTAssertTrue(permitted(.missed))
        XCTAssertFalse(permitted(.missed, owner: false))
        XCTAssertFalse(permitted(.missed, authorized: false))
        XCTAssertFalse(permitted(.low, notificationSessionID: UUID().uuidString))
        XCTAssertFalse(permitted(.low, lease: LibreWatchAlarmDelegation(sessionID: settings.sessionID,
            sensorIdentity: settings.sensorIdentity, settingsRevision: settings.revision + 1)))
        state.lastReadingAt = receivedAt
        state.recordAutomaticThrottle(.low, readingID: readingID, until: receivedAt.addingTimeInterval(300))
        XCTAssertTrue(permitted(.low), "Automatic post-enqueue throttle must not suppress its own notification")
        state.snooze(.low, until: receivedAt.addingTimeInterval(100))
        XCTAssertFalse(permitted(.low), "A manual snooze must suppress even with an unchanged maximum expiry")
    }

    func testQueuedGlucoseAlarmDoesNotOutliveItsReadingOrManualSnoozeAfterRestart() throws {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        let oldID = UUID()
        _ = state.accept(id: oldID, measuredAt: receivedAt, glucose: 38, settings: settings,
            delegation: alarmDelegation(settings), watchOwnsSensor: true, now: receivedAt)
        state.recordAutomaticThrottle(.veryLow, readingID: oldID, until: receivedAt.addingTimeInterval(300))
        func permitted(_ value: LibreWatchAlarmState) -> Bool {
            value.notificationMayBePresented(kind: .veryLow, notificationSessionID: settings.sessionID.uuidString,
                notificationReadingID: oldID, settings: settings, delegation: alarmDelegation(settings),
                watchOwnsSensor: true, notificationsAuthorized: true, at: receivedAt.addingTimeInterval(60))
        }
        let restored = try JSONDecoder().decode(LibreWatchAlarmState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(permitted(restored))
        state.snooze(.low, until: receivedAt.addingTimeInterval(600))
        let snoozed = try JSONDecoder().decode(LibreWatchAlarmState.self, from: JSONEncoder().encode(state))
        XCTAssertFalse(permitted(snoozed))
        state = restored
        _ = state.accept(id: UUID(), measuredAt: receivedAt.addingTimeInterval(60), glucose: 120,
            settings: settings, delegation: alarmDelegation(settings), watchOwnsSensor: true,
            now: receivedAt.addingTimeInterval(60))
        XCTAssertFalse(permitted(state), "A queued low from the previous reading is no longer current")
    }

    func testWatchMissedAlarmUsesPhoneMidnightBaseSchedule() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 86_400 + 2 * 60)
        let settings = alarmSettings()
        XCTAssertEqual(settings.rules.filter { $0.kind == .missed }.first?.startMinute, 0)
        var state = LibreWatchAlarmState()
        state.use(settings)
        state.lastReadingAt = now.addingTimeInterval(-4 * 60)
        state.lastReadingID = UUID()
        let next = state.nextMissedAlarm(settings: settings, delegation: alarmDelegation(settings),
            watchOwnsSensor: true, now: now, calendar: calendar)
        XCTAssertEqual(next?.date, now.addingTimeInterval(60))
        XCTAssertEqual(next?.rule.startMinute, 0)
    }

    func testWatchDelegationDoesNotSuppressNewlyEnabledPhoneAlarmWhileOffline() throws {
        let disabled = alarmSettings(enabled: false)
        let lease = LibreWatchAlarmDelegation.confirmed(for: disabled)
        XCTAssertFalse(lease.covers(.low))
        var enabled = alarmSettings()
        enabled.revision = disabled.revision + 1
        XCTAssertFalse(lease.matches(enabled))
        XCTAssertFalse(lease.covers(.low), "New phone settings do not enlarge an offline Watch delegation")
        let confirmed = LibreWatchAlarmDelegation.confirmed(for: enabled)
        XCTAssertTrue(confirmed.covers(.low))
        XCTAssertTrue(confirmed.matches(enabled))
        let restored = try JSONDecoder().decode(LibreWatchAlarmDelegation.self,
            from: JSONEncoder().encode(confirmed))
        XCTAssertTrue(restored.covers(.missed))
        let legacy = LibreWatchAlarmDelegation(sessionID: enabled.sessionID,
            sensorIdentity: enabled.sensorIdentity, settingsRevision: enabled.revision)
        XCTAssertFalse(legacy.covers(.low), "Unspecified legacy delegation must never suppress phone alarms")
        XCTAssertFalse(legacy.matches(enabled), "Unspecified legacy delegation must not enable local Watch alarms")
    }

    private func alarmSettings(enabled: Bool = true, snoozeAllUntil: Date? = nil) -> LibreWatchAlarmSettings {
        let rules = zip(LibreWatchAlarmKind.allCases, [60.0, 80, 180, 250, 5]).map { kind, value in
            LibreWatchAlarmRule(kind: kind, startMinute: 0, value: value, enabled: enabled,
                snoozeMinutes: 15, allowsSnooze: true, soundEnabled: false, vibrate: false, title: "Test")
        }
        return LibreWatchAlarmSettings(sessionID: session.id, sensorIdentity: session.redactedIdentity(), revision: 1,
            generatedAt: receivedAt, isMgDl: false, rules: rules, snoozes: [], snoozeAllUntil: snoozeAllUntil)
    }

    private func alarmDelegation(_ settings: LibreWatchAlarmSettings) -> LibreWatchAlarmDelegation {
        LibreWatchAlarmDelegation.confirmed(for: settings)
    }
}

extension LibreWatchValuePipelineTests {
    func testTakeoverSnapshotRequiresMatchingCalibrationBeforeWatchOwnership() throws {
        let snapshot = LibreWatchHandoffSnapshot(
            session: session,
            calibration: calibration(type: .fixedSlope, slope: 1, intercept: 0),
            ownership: .watch,
            revision: 31
        )
        XCTAssertTrue(snapshot.canApply(after: 30))
        XCTAssertFalse(snapshot.canApply(after: 31))
        XCTAssertFalse(snapshot.canApply(after: 32))
        XCTAssertEqual(try JSONDecoder().decode(LibreWatchHandoffSnapshot.self,
            from: JSONEncoder().encode(snapshot)), snapshot)
        XCTAssertFalse(LibreWatchHandoffSnapshot(
            session: session, calibration: nil, ownership: .watch, revision: 32
        ).isValid)
        var anotherSession = session
        anotherSession.unlockCount += 1
        let current = LibreWatchHandoffSnapshot(
            session: anotherSession, calibration: snapshot.calibration, ownership: .watch, revision: 32
        )
        XCTAssertTrue(current.isValid)
        XCTAssertEqual(current.session.unlockCount, session.unlockCount + 1)
    }

    func testPhoneReconnectsAndDelayedCounterMessageNeverRollBackUnlockCounter() {
        var prepared = session
        prepared.unlockCount = 4
        var persisted = session
        persisted.unlockCount = 7
        XCTAssertEqual(LibreWatchUnlockCounterPolicy.highest(
            incoming: 5, session: prepared, storedSession: persisted,
            activeSensorUID: session.sensorUID, activePatchInfo: session.patchInfo,
            activeCounter: 12
        ), 12)
        XCTAssertEqual(LibreWatchUnlockCounterPolicy.highest(
            incoming: 14, session: prepared, storedSession: persisted,
            activeSensorUID: session.sensorUID, activePatchInfo: session.patchInfo,
            activeCounter: 12
        ), 14)
        XCTAssertEqual(LibreWatchUnlockCounterPolicy.highest(
            incoming: 5, session: prepared, storedSession: nil,
            activeSensorUID: Data(repeating: 0, count: 8), activePatchInfo: session.patchInfo,
            activeCounter: 500
        ), 5)
    }

    func testHandoffRevisionPersistsAndRejectsDelayedOwnershipContextAfterRestart() {
        let defaults = isolatedDefaults()
        let first = LibreWatchSessionStore.nextHandoffRevision(at: receivedAt, defaults: defaults)
        let second = LibreWatchSessionStore.nextHandoffRevision(at: receivedAt.addingTimeInterval(-60), defaults: defaults)
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(LibreWatchSessionStore.loadHandoffRevision(defaults: defaults), second)
        let delayed = LibreWatchHandoffSnapshot(
            session: session, calibration: nil, ownership: .iphone, revision: first
        )
        XCTAssertFalse(delayed.canApply(after: LibreWatchSessionStore.loadHandoffRevision(defaults: defaults)))
    }

    func testWatchOutboxRetainsSubmittedPayloadUntilDurableReceiverReceipt() throws {
        let item = LibreWatchOutboxItem.reading(payload(raw: 847, previousRaw: 829, domain: .factoryNativeMGDL))
        var outbox = LibreWatchConnectivityOutbox()
        outbox.enqueue(item, now: receivedAt)
        outbox.markSubmitted(id: item.id, at: receivedAt)
        XCTAssertEqual(outbox.items.map(\.id), [item.id])
        XCTAssertNil(outbox.nextEligible(at: receivedAt.addingTimeInterval(59)))
        let restored = try JSONDecoder().decode(LibreWatchConnectivityOutbox.self,
            from: JSONEncoder().encode(outbox))
        XCTAssertEqual(restored.nextEligible(at: receivedAt.addingTimeInterval(60))?.id, item.id)
        XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: true, outcome: nil))
        XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: false, outcome: .historyNotInserted))
        XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: false, outcome: .collectorUnavailable))
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: true, outcome: .liveAccepted, durableReceipt: true))
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: true, outcome: .historicalInserted, durableReceipt: true))
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: true, outcome: .duplicate, durableReceipt: true))
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: false, outcome: .wrongCalibration))
        outbox.remove(id: item.id)
        XCTAssertNil(outbox.nextEligible(at: receivedAt.addingTimeInterval(61)))
    }

    func testLegacyOutboxDecodesWithoutSubmissionMetadataAndKeepsStableIDs() throws {
        let item = LibreWatchOutboxItem.reading(payload(raw: 847, previousRaw: 829, domain: .factoryNativeMGDL))
        let legacy = try JSONSerialization.data(withJSONObject: [
            "items": try JSONSerialization.jsonObject(with: JSONEncoder().encode([item]))
        ])
        let outbox = try JSONDecoder().decode(LibreWatchConnectivityOutbox.self, from: legacy)
        XCTAssertEqual(outbox.nextEligible(at: receivedAt)?.id, item.id)
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldRetryReadingAsQueued(after: .outOfOrder))
        XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.isTerminal(.outOfOrder))
    }

    func testDiagnosticJournalSeparatesConfirmedRotationFromUnacknowledgedLoss() throws {
        var journal = LibreWatchDiagnosticJournal()
        for index in 0 ..< 160 {
            let date = receivedAt.addingTimeInterval(Double(index))
            let event = LibreWatchDiagnosticEvent(kind: .coreBluetoothCallback,
                watchTimestamp: date, trigger: "didConnect", sessionID: session.id, appBuild: "4252")
            _ = journal.append(event, at: date)
            journal.markHandedToWatchConnectivity(eventID: event.eventID, at: date)
            journal.markAcknowledgedByPhone(eventID: event.eventID, at: date.addingTimeInterval(0.5))
        }
        XCTAssertGreaterThan(journal.droppedCount, 0)
        XCTAssertEqual(journal.unacknowledgedDropCount ?? 0, 0)
        for index in 160 ..< 320 {
            _ = journal.append(LibreWatchDiagnosticEvent(kind: .disconnected,
                sessionID: UUID(), appBuild: "4252"), at: receivedAt.addingTimeInterval(Double(index)))
        }
        XCTAssertGreaterThan(journal.unacknowledgedDropCount ?? 0, 0)
        let restored = try JSONDecoder().decode(LibreWatchDiagnosticJournal.self,
            from: JSONEncoder().encode(journal))
        XCTAssertEqual(restored.unacknowledgedDropCount, journal.unacknowledgedDropCount)
        XCTAssertFalse(restored.pendingEvents().isEmpty)
        XCTAssertTrue(restored.entries.allSatisfy { $0.event.appBuild == "4252" })
    }

    func testSessionChangeKeepsPendingDiagnosticsButNeverOldSensorReadings() {
        let diagnostic = LibreWatchOutboxItem.command(.reportDiagnostic, sessionID: session.id,
            diagnosticEvent: Data("{}".utf8), createdAt: receivedAt)
        let reading = LibreWatchOutboxItem.reading(payload(raw: 847, previousRaw: 829, domain: .factoryNativeMGDL))
        var outbox = LibreWatchConnectivityOutbox()
        outbox.enqueue(diagnostic, now: receivedAt)
        outbox.enqueue(reading, now: receivedAt)
        outbox.retain(sessionID: UUID())
        XCTAssertEqual(outbox.items.map(\.id), [diagnostic.id])
    }

    func testOldPhoneSuccessDoesNotAcknowledgeReadingOrDiagnosticStorage() throws {
        let reading = LibreWatchOutboxItem.reading(payload(raw: 847, previousRaw: 829, domain: .factoryNativeMGDL))
        let event = LibreWatchDiagnosticEvent(kind: .recoveryStarted, watchTimestamp: receivedAt, sessionID: session.id)
        let diagnostic = LibreWatchOutboxItem.command(.reportDiagnostic, sessionID: session.id,
            diagnosticEvent: try JSONEncoder().encode(event), id: try XCTUnwrap(event.eventID), createdAt: receivedAt)
        let counter = LibreWatchOutboxItem.command(.updateUnlockCounter, sessionID: session.id,
            unlockCounter: 42, createdAt: receivedAt)
        var outbox = LibreWatchConnectivityOutbox()
        for item in [reading, diagnostic] {
            outbox.enqueue(item, now: receivedAt)
            let oldOutcome: LibreWatchDeliveryOutcome? = item.kind == .reading ? .liveAccepted : nil
            XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: true, outcome: oldOutcome))
            XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: true, outcome: oldOutcome, durableReceipt: false))
            outbox.markSubmitted(id: item.id, at: receivedAt)
        }
        let restored = try JSONDecoder().decode(LibreWatchConnectivityOutbox.self, from: JSONEncoder().encode(outbox))
        XCTAssertEqual(Set(restored.items.map(\.id)), Set([reading.id, diagnostic.id]))
        XCTAssertNotNil(restored.nextEligible(at: receivedAt.addingTimeInterval(60)))
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(reading, success: true, outcome: .liveAccepted, durableReceipt: true))
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(diagnostic, success: true, outcome: nil, durableReceipt: true))
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(counter, success: true, outcome: nil))
        XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.shouldFinish(diagnostic, success: false, outcome: nil))
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(diagnostic, success: false, outcome: .invalidPayload))
    }
}
