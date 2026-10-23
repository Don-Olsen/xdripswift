import XCTest
import CoreData
import SwiftUI
@testable import xdrip

/// These tests drive the real durable manager and its suspended forecast task. Only external
/// inputs are substituted; the start, expiry, policy, revision and persistence decisions run normally.
final class MealQuietTests: XCTestCase {
    @MainActor func testDisabledAndUnselectedDurationCannotStart() {
        let inputs = MealQuietInputs()
        let manager = inputs.manager(configured: false)
        XCTAssertFalse(manager.isEnabled)
        XCTAssertNil(manager.durationMinutes)
        inputs.consider(manager)
        XCTAssertTrue(manager.document.records.isEmpty)
        manager.setEnabled(true)
        manager.setDurationMinutes(20)
        XCTAssertNil(manager.durationMinutes)
        inputs.consider(manager)
        XCTAssertEqual(manager.document.records["meal"]?.decision, .rejected)
        XCTAssertEqual(inputs.requests, 0)
        XCTAssertFalse(manager.shouldSuppress(.high, at: inputs.now))
    }

    @MainActor func testPendingSafeForecastActivatesOnlyPermittedAlertsWithAbsoluteExpiry() async throws {
        let inputs = MealQuietInputs()
        let manager = inputs.manager()
        let eaten = inputs.now.addingTimeInterval(-120)
        inputs.consider(manager, eatingAt: eaten)
        XCTAssertEqual(manager.document.records["meal"]?.decision, .pending)
        XCTAssertNil(manager.activePeriod(at: inputs.now))
        XCTAssertFalse(manager.shouldSuppress(.high, at: inputs.now))
        await waitUntil { inputs.requests == 1 }
        inputs.complete()
        await waitUntil { inputs.returned == 1 }
        let period = try XCTUnwrap(manager.activePeriod(at: inputs.now))
        XCTAssertEqual(period.startedAt, eaten)
        XCTAssertEqual(period.until, eaten.addingTimeInterval(30 * 60))
        XCTAssertEqual(manager.document.active?.sourceSignature, inputs.signature)
        XCTAssertTrue(manager.shouldSuppress(.high, at: inputs.now))
        XCTAssertTrue(manager.shouldSuppressHighSoon(at: inputs.now))
        XCTAssertTrue(manager.shouldSuppress(.fastrise, at: inputs.now))
        for kind in AlertKind.allCases where kind != .high && kind != .fastrise {
            XCTAssertFalse(manager.shouldSuppress(kind, at: inputs.now), "Never change \(kind)")
        }
        XCTAssertEqual(inputs.clearCalls, 1)
        manager.setDurationMinutes(60)
        inputs.consider(manager)
        inputs.consider(manager, mealID: "secondMeal")
        XCTAssertEqual(manager.activePeriod(at: inputs.now), period)
        XCTAssertEqual(manager.document.records["secondMeal"]?.decision, .rejected)
        XCTAssertEqual(inputs.requests, 1)
        inputs.now = period.until
        manager.refreshMeasuredBasis(at: inputs.now)
        XCTAssertEqual(manager.document.records["meal"]?.decision, .ended)
        inputs.consider(manager)
        XCTAssertNil(manager.activePeriod(at: inputs.now))
        XCTAssertEqual(inputs.requests, 1)
    }

    @MainActor func testSecondCommitCannotReplacePeriodEndedByItsChangedInput() async {
        for observerRunsFirst in [false, true] {
            let inputs = MealQuietInputs()
            let manager = inputs.manager()
            await activate(manager, inputs: inputs)
            inputs.now = inputs.now.addingTimeInterval(60)
            let eventAt = inputs.now // Captured before the second treatment is saved.
            inputs.now = inputs.now.addingTimeInterval(1)
            inputs.token = "second-meal-commit"
            inputs.treatmentRevision += 1
            if observerRunsFirst { manager.refreshMeasuredBasis(at: inputs.now) }
            inputs.consider(manager, mealID: "secondMeal", eatingAt: eventAt, eventAt: eventAt)
            XCTAssertEqual(manager.document.records["meal"]?.decision, .ended)
            XCTAssertEqual(manager.document.records["meal"]?.endedAt, inputs.now)
            XCTAssertEqual(manager.document.records["secondMeal"]?.decision, .rejected)
            XCTAssertNil(manager.activePeriod(at: inputs.now))
            XCTAssertEqual(inputs.requests, 1, "No replacement forecast or later queued period")
        }
    }

    @MainActor func testSecondCommitRemainsRejectedAfterObserverAndRestart() async {
        let inputs = MealQuietInputs()
        let manager = inputs.manager()
        await activate(manager, inputs: inputs)
        inputs.now = inputs.now.addingTimeInterval(60)
        let eventAt = inputs.now
        inputs.now = inputs.now.addingTimeInterval(1)
        inputs.token = "second-meal-commit"
        inputs.treatmentRevision += 1
        manager.refreshMeasuredBasis(at: inputs.now)
        let restored = inputs.manager(configured: false)
        inputs.consider(restored, mealID: "secondMeal", eatingAt: eventAt, eventAt: eventAt)
        XCTAssertEqual(restored.document.records["secondMeal"]?.decision, .rejected)
        XCTAssertNil(restored.activePeriod(at: inputs.now))
        XCTAssertEqual(inputs.requests, 1)
    }

    @MainActor func testDelayedWatchPairUsesOriginalEventForQuietButReceiptForProvenance() async throws {
        let inputs = MealQuietInputs()
        let manager = inputs.manager()
        await activate(manager, inputs: inputs)
        inputs.now = inputs.now.addingTimeInterval(60)
        let recordedAt = inputs.now
        inputs.now = inputs.now.addingTimeInterval(1)
        manager.end(reason: "Afsluttet før levering", at: inputs.now)
        inputs.now = inputs.now.addingTimeInterval(4)
        let receivedAt = inputs.now
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let operation = PenDoseLogOperation()
        let result = PenDoseTreatmentLogger.log(coreDataManager: inputs.core,
            insulinUnits: 1, carbohydrateGrams: 15, mealKind: .normal, plannedDate: nil,
            operation: operation, now: recordedAt, knownAt: receivedAt,
            journal: PenDoseLogJournal(directory: directory),
            penSettings: PenDoseProfile.prefilledUnconfirmed.settings,
            pizzaSettings: PizzaSplitSettings(isEnabled: false, percentageNow: 70, reminderMinutes: 90),
            metadataStore: MealPlanMetadataStore(directory: directory),
            considerMealQuiet: { mealID, bolusID, eatenAt, eventAt, allowed in
                XCTAssertEqual(eventAt, recordedAt)
                manager.considerCommittedMeal(coreDataManager: inputs.core, mealID: mealID,
                    bolusID: bolusID, eatingAt: eatenAt, eventAt: eventAt, allowsStart: allowed)
            })
        guard case .success = result else { return XCTFail("Treatments must still be stored") }
        let rows = TreatmentEntryAccessor(coreDataManager: inputs.core).getLatestTreatments(howOld: nil)
            .filter { [operation.mealUUID, operation.bolusUUID].contains($0.localTreatmentUUID ?? "") }
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.date == recordedAt && $0.createdAt == receivedAt })
        XCTAssertEqual(manager.document.records[operation.mealUUID]?.decision, .rejected)
        XCTAssertNil(manager.activePeriod(at: inputs.now))
        XCTAssertEqual(inputs.requests, 1)
    }

    @MainActor func testDelayedExpiryCleanupAllowsGenuinelyLaterMeal() async throws {
        let inputs = MealQuietInputs()
        let manager = inputs.manager()
        await activate(manager, inputs: inputs)
        let until = try XCTUnwrap(manager.activePeriod(at: inputs.now)?.until)
        inputs.now = until.addingTimeInterval(60)
        inputs.sample = .init(date: inputs.now, glucoseMgdl: 120, sensorID: "sensor-A")
        inputs.token = "new-meal-after-expiry"
        inputs.treatmentRevision += 1
        // considerCommittedMeal is the first event to discover the expired old period.
        await activate(manager, inputs: inputs, mealID: "laterMeal")
        XCTAssertEqual(manager.document.records["meal"]?.endedAt, until)
        XCTAssertEqual(manager.activePeriod(at: inputs.now)?.mealID, "laterMeal")
        XCTAssertEqual(inputs.requests, 2)
    }

    @MainActor func testExplicitStopRejectsInFlightMealButAllowsNewEventAfterStop() async {
        let inputs = MealQuietInputs()
        let manager = inputs.manager()
        await activate(manager, inputs: inputs)
        inputs.now = inputs.now.addingTimeInterval(60)
        let inFlightEvent = inputs.now
        inputs.now = inputs.now.addingTimeInterval(1)
        manager.end(reason: "Afsluttet af brugeren", at: inputs.now)
        let endedAt = inputs.now
        inputs.consider(manager, mealID: "inFlight", eatingAt: inFlightEvent, eventAt: inFlightEvent)
        XCTAssertEqual(manager.document.records["inFlight"]?.decision, .rejected)
        inputs.now = inputs.now.addingTimeInterval(1)
        await activate(manager, inputs: inputs, mealID: "newEvent")
        XCTAssertEqual(manager.document.records["meal"]?.endedAt, endedAt)
        XCTAssertEqual(manager.activePeriod(at: inputs.now)?.mealID, "newEvent")
        XCTAssertEqual(inputs.requests, 2)
    }

    @MainActor func testLowRiskAndMalformedForecastRejectWithoutLaterResurrection() async {
        for unavailable in [false, true] {
            let inputs = MealQuietInputs()
            let manager = inputs.manager()
            inputs.consider(manager)
            await waitUntil { inputs.requests == 1 }
            inputs.complete(inputs.outcome(risk: !unavailable, unavailable: unavailable))
            await waitUntil { inputs.returned == 1 }
            XCTAssertEqual(manager.document.records["meal"]?.decision, .rejected)
            manager.acceptSafetyOutcome(inputs.outcome(), token: inputs.token, at: inputs.now)
            inputs.consider(manager)
            XCTAssertNil(manager.activePeriod(at: inputs.now))
            XCTAssertEqual(inputs.requests, 1)
            XCTAssertEqual(inputs.clearCalls, 0)
        }
    }

    @MainActor func testFreshEventStillRejectsOfflineOldMissingOrInvalidStartBasis() {
        let cases: [(MealQuietInputs) -> Void] = [
            { $0.pairValid = false },
            { $0.rules = nil },
            { $0.rules = .init(low: 180, high: 120, urgentHigh: 250) },
            { $0.token = nil },
            { $0.sample = nil },
            { $0.sample = .init(date: $0.now.addingTimeInterval(-331), glucoseMgdl: 120, sensorID: "sensor-A") },
            { $0.sample = .init(date: $0.now, glucoseMgdl: 180, sensorID: "sensor-A") },
            { $0.sample = .init(date: $0.now, glucoseMgdl: .nan, sensorID: "sensor-A") }
        ]
        for change in cases {
            let inputs = MealQuietInputs()
            let manager = inputs.manager()
            change(inputs)
            inputs.consider(manager)
            XCTAssertEqual(manager.document.records["meal"]?.decision, .rejected)
            XCTAssertEqual(inputs.requests, 0)
        }
        let inputs = MealQuietInputs()
        let manager = inputs.manager()
        inputs.consider(manager, mealID: "offline", allowsStart: false)
        inputs.consider(manager, mealID: "oldReceipt", eventAt: inputs.now.addingTimeInterval(-31))
        inputs.consider(manager, mealID: "future", eatingAt: inputs.now.addingTimeInterval(1))
        inputs.consider(manager, mealID: "expiredMeal", eatingAt: inputs.now.addingTimeInterval(-30 * 60))
        XCTAssertTrue(manager.document.records.values.allSatisfy { $0.decision == .rejected })
        XCTAssertEqual(inputs.requests, 0)
    }

    @MainActor func testMeasuredFloorRemainsThreePointNineEvenWithLowerConfiguredLow() {
        let floor = LowSoonAlertPolicy.currentMinimumMgdl
        XCTAssertEqual(floor, 3.9 / ConstantsBloodGlucose.mgDlToMmoll)
        let rules = MealQuietRules(low: 55, high: 180, urgentHigh: 250)
        XCTAssertFalse(rules.permitsCurrent(floor.nextDown, starting: true))
        XCTAssertTrue(rules.permitsCurrent(floor, starting: true))
        let inputs = MealQuietInputs()
        let manager = inputs.manager()
        inputs.rules = rules
        inputs.sample = .init(date: inputs.now, glucoseMgdl: floor.nextDown, sensorID: "sensor-A")
        inputs.consider(manager)
        XCTAssertEqual(manager.document.records["meal"]?.decision, .rejected)
        XCTAssertEqual(inputs.requests, 0)
    }

    @MainActor func testDelayedStartCannotUseChangedInputsOrExpiredTime() async {
        let mutations: [(MealQuietInputs) -> Void] = [
            { $0.token = "changed-revision"; $0.treatmentRevision += 1 },
            { $0.sample = .init(date: $0.now, glucoseMgdl: 121, sensorID: "sensor-A") },
            { $0.pairValid = false },
            { $0.rules = nil },
            { $0.now = $0.now.addingTimeInterval(331) }
        ]
        for mutate in mutations {
            let inputs = MealQuietInputs()
            let manager = inputs.manager()
            inputs.consider(manager)
            await waitUntil { inputs.requests == 1 }
            let originalOutcome = inputs.outcome()
            mutate(inputs)
            inputs.complete(originalOutcome)
            await waitUntil { inputs.returned == 1 }
            XCTAssertEqual(manager.document.records["meal"]?.decision, .rejected)
            XCTAssertNil(manager.activePeriod(at: inputs.now))
            XCTAssertEqual(inputs.clearCalls, 0)
        }
    }

    @MainActor func testEndedPendingAttemptCannotReactivateAfterLateCompletion() async {
        let inputs = MealQuietInputs()
        let manager = inputs.manager()
        inputs.consider(manager)
        await waitUntil { inputs.requests == 1 }
        manager.end(reason: "Afsluttet af brugeren", at: inputs.now)
        inputs.complete()
        await waitUntil { inputs.returned == 1 }
        XCTAssertEqual(manager.document.records["meal"]?.decision, .rejected)
        XCTAssertNil(manager.activePeriod(at: inputs.now))
        inputs.consider(manager)
        XCTAssertEqual(inputs.requests, 1)
        inputs.now = inputs.now.addingTimeInterval(1)
        await activate(manager, inputs: inputs, mealID: "nextMeal")
        let period = manager.activePeriod(at: inputs.now)
        manager.setEnabled(false)
        manager.setEnabled(true)
        inputs.consider(manager, mealID: "nextMeal")
        XCTAssertNil(manager.activePeriod(at: inputs.now))
        XCTAssertEqual(manager.document.records["nextMeal"]?.decision, .ended)
        XCTAssertNotNil(period)
        XCTAssertEqual(inputs.requests, 2)
    }

    @MainActor func testRestartRejectsPendingAndRevalidatesActiveWithoutExtendingIt() async throws {
        let inputs = MealQuietInputs()
        let manager = inputs.manager()
        inputs.consider(manager)
        await waitUntil { inputs.requests == 1 }
        let pendingRestart = inputs.manager(configured: false)
        XCTAssertEqual(pendingRestart.document.records["meal"]?.decision, .rejected)
        pendingRestart.configure(coreDataManager: inputs.core)
        inputs.consider(pendingRestart)
        XCTAssertEqual(inputs.requests, 1)
        manager.end(reason: "Test ended", at: inputs.now)
        inputs.complete()
        await waitUntil { inputs.returned == 1 }
        inputs.now = inputs.now.addingTimeInterval(1)
        await activate(pendingRestart, inputs: inputs, mealID: "activeMeal")
        let original = try XCTUnwrap(pendingRestart.activePeriod(at: inputs.now))
        let activeRestart = inputs.manager(configured: false)
        XCTAssertEqual(activeRestart.activePeriod(at: inputs.now), original)
        XCTAssertFalse(activeRestart.shouldSuppress(.high, at: inputs.now), "Persisted activity is not persisted safety")
        activeRestart.configure(coreDataManager: inputs.core)
        await waitUntil { inputs.requests == 3 }
        XCTAssertFalse(activeRestart.shouldSuppress(.high, at: inputs.now))
        inputs.complete()
        await waitUntil { inputs.returned == 3 }
        XCTAssertTrue(activeRestart.shouldSuppress(.high, at: inputs.now))
        XCTAssertEqual(activeRestart.activePeriod(at: inputs.now), original)
    }

    @MainActor func testLegacyActiveRecordWithoutSourceSignatureEndsOnRestore() throws {
        let inputs = MealQuietInputs()
        var saved = MealQuietDocument()
        saved.enabled = true
        saved.durationMinutes = 30
        saved.records["meal"] = .init(mealID: "meal", bolusID: "bolus", eatingAt: inputs.now,
            until: inputs.now.addingTimeInterval(1800), decision: .active, reason: "Legacy")
        inputs.data = try JSONEncoder().encode(saved)
        let manager = inputs.manager(configured: false)
        manager.configure(coreDataManager: inputs.core)
        XCTAssertNil(manager.activePeriod(at: inputs.now))
        XCTAssertEqual(manager.document.records["meal"]?.decision, .ended)
        XCTAssertEqual(inputs.requests, 0)
    }

    @MainActor func testNewerReadingCanCarrySafeBasisButHighUrgentAndLowRulesStillApply() async {
        let inputs = MealQuietInputs()
        let manager = inputs.manager()
        await activate(manager, inputs: inputs)
        let oldOutcome = inputs.outcome()
        inputs.now = inputs.now.addingTimeInterval(60)
        inputs.sample = .init(date: inputs.now, glucoseMgdl: 190, sensorID: "sensor-A")
        XCTAssertTrue(manager.shouldSuppress(.high, at: inputs.now))
        XCTAssertTrue(manager.shouldSuppressHighSoon(at: inputs.now))
        XCTAssertFalse(manager.shouldSuppress(.fastrise, at: inputs.now), "Fast rise only quiets below the current high threshold")
        manager.acceptSafetyOutcome(oldOutcome, token: inputs.token, at: inputs.now)
        XCTAssertTrue(manager.shouldSuppress(.high, at: inputs.now))
        manager.acceptSafetyOutcome(inputs.outcome(risk: true), token: inputs.token, at: inputs.now)
        XCTAssertEqual(manager.document.records["meal"]?.decision, .ended)
        XCTAssertFalse(manager.shouldSuppress(.high, at: inputs.now))
    }

    @MainActor func testChangedIdentityOrInputRevisionCannotReusePriorSafety() async {
        let mutations: [(MealQuietInputs) -> Void] = [
            { $0.sample = .init(date: $0.now, glucoseMgdl: 121, sensorID: "sensor-A") },
            { $0.sample = .init(date: $0.now, glucoseMgdl: 120, sensorID: "sensor-B") },
            { $0.sample = .init(date: $0.now.addingTimeInterval(-1), glucoseMgdl: 120, sensorID: "sensor-A") },
            { $0.token = "new-treatment"; $0.treatmentRevision += 1 },
            { $0.hasUncommitted = true; $0.token = nil }
        ]
        for change in mutations {
            let inputs = MealQuietInputs()
            let manager = inputs.manager()
            await activate(manager, inputs: inputs)
            change(inputs)
            XCTAssertFalse(manager.shouldSuppress(.high, at: inputs.now))
            XCTAssertEqual(manager.document.records["meal"]?.decision, .ended)
            XCTAssertNil(manager.watchState.period)
            inputs.hasUncommitted = false
            inputs.token = "initial-revision"
            inputs.sample = .init(date: inputs.now, glucoseMgdl: 120, sensorID: "sensor-A")
            manager.acceptSafetyOutcome(inputs.outcome(), token: inputs.token, at: inputs.now)
            inputs.consider(manager)
            XCTAssertEqual(manager.document.records["meal"]?.decision, .ended)
            XCTAssertNil(manager.activePeriod(at: inputs.now))
            XCTAssertNil(manager.watchState.period)
            XCTAssertEqual(inputs.requests, 1, "Restoring valid inputs cannot restart the same meal")
        }
    }

    @MainActor func testLaterLowUrgentInvalidRulesSourceChangeOrDeletedPairEndPeriod() async {
        let mutations: [(MealQuietInputs) -> Void] = [
            { $0.sample = .init(date: $0.now, glucoseMgdl: 65, sensorID: "sensor-A") },
            { $0.sample = .init(date: $0.now, glucoseMgdl: 250, sensorID: "sensor-A") },
            { $0.rules = nil },
            { $0.signature = "changed-source" },
            { $0.pairValid = false; $0.treatmentRevision += 1; $0.token = "deleted" },
            { $0.now = $0.now.addingTimeInterval(331) }
        ]
        for change in mutations {
            let inputs = MealQuietInputs()
            let manager = inputs.manager()
            await activate(manager, inputs: inputs)
            change(inputs)
            XCTAssertFalse(manager.shouldSuppress(.high, at: inputs.now))
            XCTAssertEqual(manager.document.records["meal"]?.decision, .ended)
            XCTAssertNil(manager.watchState.period)
            manager.acceptSafetyOutcome(inputs.outcome(), token: inputs.token, at: inputs.now)
            XCTAssertNil(manager.activePeriod(at: inputs.now))
        }
    }

    @MainActor func testWriteFailureAndCorruptRestoreNeverPermitSuppression() async {
        let pending = MealQuietInputs()
        let pendingManager = pending.manager()
        pending.failWrites = true
        pending.consider(pendingManager)
        XCTAssertEqual(pending.requests, 0)
        XCTAssertEqual(pendingManager.document.records["meal"]?.decision, .rejected)
        pending.failWrites = false
        pendingManager.setDurationMinutes(45)
        pending.consider(pendingManager)
        XCTAssertEqual(pendingManager.document.records["meal"]?.decision, .rejected)
        XCTAssertEqual(pending.requests, 0, "A later successful settings write cannot revive the failed start")
        XCTAssertFalse(pendingManager.shouldSuppress(.high, at: pending.now))
        XCTAssertNil(pendingManager.watchState.period)

        let active = MealQuietInputs()
        let activeManager = active.manager()
        active.consider(activeManager)
        await waitUntil { active.requests == 1 }
        active.failWrites = true
        active.complete()
        await waitUntil { active.returned == 1 }
        XCTAssertNil(activeManager.activePeriod(at: active.now))
        XCTAssertFalse(activeManager.shouldSuppress(.high, at: active.now))
        XCTAssertNil(activeManager.watchState.period)
        XCTAssertEqual(active.clearCalls, 0)

        let corrupt = MealQuietInputs()
        corrupt.data = Data("not valid JSON".utf8)
        let corruptManager = corrupt.manager(configured: false)
        XCTAssertFalse(corruptManager.isEnabled)
        XCTAssertNil(corruptManager.watchState.period)
        corrupt.consider(corruptManager)
        XCTAssertTrue(corruptManager.document.records.isEmpty)
    }

    @MainActor func testFailedEndCannotRestoreTheOldActiveFileAfterRestart() async throws {
        let suite = "MealQuietRecoveryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let inputs = MealQuietInputs()
        inputs.recoveryDefaults = defaults
        let manager = inputs.manager()
        await activate(manager, inputs: inputs)
        let activeData = try XCTUnwrap(inputs.data)
        XCTAssertEqual(try JSONDecoder().decode(MealQuietDocument.self, from: activeData).active?.mealID, "meal")
        inputs.failWrites = true
        manager.end(reason: "Afsluttet af brugeren", at: inputs.now)
        XCTAssertEqual(inputs.data, activeData, "The simulated failed write leaves the old active file intact")
        XCTAssertFalse(manager.shouldSuppress(.high, at: inputs.now))
        XCTAssertNil(manager.watchState.period)
        inputs.failWrites = false
        let restored = inputs.manager(configured: false)
        restored.configure(coreDataManager: inputs.core)
        XCTAssertFalse(restored.isEnabled)
        XCTAssertEqual(restored.document.records["meal"]?.decision, .ended)
        XCTAssertNil(restored.activePeriod(at: inputs.now))
        XCTAssertNil(restored.watchState.period)
        restored.setEnabled(true)
        inputs.consider(restored)
        XCTAssertNil(restored.activePeriod(at: inputs.now))
        XCTAssertEqual(inputs.requests, 1, "The fence must not turn the replay into a new start attempt")
    }

    @MainActor func testConfiguredManagerDoesNotMakePrivateSaveWaitForMainQueue() async throws {
        let inputs = MealQuietInputs()
        let manager = inputs.manager()
        manager.configure(coreDataManager: inputs.core)
        let writer = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        writer.persistentStoreCoordinator = try XCTUnwrap(
            inputs.core.privateManagedObjectContext.persistentStoreCoordinator)
        let returned = DispatchSemaphore(value: 0)
        let saved = expectation(description: "Private save returns")
        let enqueue: (@escaping () -> Void) -> Void = writer.perform
        enqueue {
            let sensor = NSEntityDescription.insertNewObject(forEntityName: "Sensor", into: writer)
            sensor.setValue(UUID().uuidString, forKey: "id")
            sensor.setValue(Date(), forKey: "startDate")
            do { try writer.save() }
            catch { XCTFail("Private context save failed: \(error)") }
            returned.signal()
            saved.fulfill()
        }
        // Deliberately keep main occupied, as the existing synchronous save caller does.
        // A DidSave observer on queue.main blocks the private writer until this times out.
        XCTAssertEqual(returned.wait(timeout: .now() + 2), .success)
        await fulfillment(of: [saved], timeout: 3)
        withExtendedLifetime(manager) {}
    }

    @MainActor func testRestartWithDifferentSensorEndsBeforeRequestingForecast() async throws {
        let inputs = MealQuietInputs()
        let manager = inputs.manager()
        await activate(manager, inputs: inputs)
        let stored = try JSONDecoder().decode(MealQuietDocument.self, from: XCTUnwrap(inputs.data))
        XCTAssertEqual(stored.active?.sensorID, "sensor-A")
        inputs.sample = .init(date: inputs.now, glucoseMgdl: 120, sensorID: "sensor-B")
        let restored = inputs.manager(configured: false)
        restored.configure(coreDataManager: inputs.core)
        XCTAssertEqual(restored.document.records["meal"]?.decision, .ended)
        XCTAssertNil(restored.activePeriod(at: inputs.now))
        XCTAssertNil(restored.watchState.period)
        inputs.sample = .init(date: inputs.now, glucoseMgdl: 120, sensorID: "sensor-A")
        restored.acceptSafetyOutcome(inputs.outcome(), token: inputs.token, at: inputs.now)
        inputs.consider(restored)
        XCTAssertEqual(inputs.requests, 1)
        XCTAssertNil(restored.activePeriod(at: inputs.now))
    }

    func testAlarmBoundariesFollowExistingUnitModePrecision() {
        let mgdl = MealQuietRules(low: 75, high: 180, urgentHigh: 250)
        XCTAssertFalse(mgdl.permitsCurrent(75.4, starting: true))
        XCTAssertTrue(mgdl.permitsCurrent(75.6, starting: true))
        XCTAssertFalse(mgdl.belowHigh(179.6))
        XCTAssertTrue(mgdl.belowHigh(179.4))
        XCTAssertFalse(mgdl.permitsCurrent(249.6, starting: false))
        XCTAssertTrue(mgdl.permitsCurrent(249.4, starting: false))

        // Match AlertKind.alertNeeded: bgValueRounded changes precision only;
        // it does not convert these stored mg/dL inputs to mmol/L.
        let decimalMode = MealQuietRules(low: 75, high: 180, urgentHigh: 250, usesMgDl: false)
        XCTAssertFalse(decimalMode.permitsCurrent(75.04, starting: true))
        XCTAssertTrue(decimalMode.permitsCurrent(75.06, starting: true))
        XCTAssertFalse(decimalMode.belowHigh(179.96))
        XCTAssertTrue(decimalMode.belowHigh(179.94))
        XCTAssertFalse(decimalMode.permitsCurrent(249.96, starting: false))
        XCTAssertTrue(decimalMode.permitsCurrent(249.94, starting: false))
    }

    @MainActor func testNinetyMinuteSelectionRestoresAndKeepsOriginalExpiry() async throws {
        let inputs = MealQuietInputs()
        let manager = inputs.manager()
        manager.setDurationMinutes(90)
        await activate(manager, inputs: inputs)
        let period = try XCTUnwrap(manager.activePeriod(at: inputs.now))
        XCTAssertEqual(period.until.timeIntervalSince(period.startedAt), 5400)
        manager.setDurationMinutes(15)
        XCTAssertEqual(manager.activePeriod(at: inputs.now), period)
        XCTAssertEqual(manager.watchState.period, period)

        inputs.now = period.startedAt.addingTimeInterval(61 * 60)
        inputs.sample = .init(date: inputs.now, glucoseMgdl: 120, sensorID: "sensor-A")
        let restored = inputs.manager(configured: false)
        XCTAssertEqual(restored.durationMinutes, 15, "Changed duration applies only to a future meal")
        XCTAssertEqual(restored.activePeriod(at: inputs.now), period)
        XCTAssertFalse(restored.shouldSuppress(.high, at: inputs.now), "Fresh safety must still be revalidated")
        restored.configure(coreDataManager: inputs.core)
        await waitUntil { inputs.requests == 2 }
        inputs.complete()
        await waitUntil { inputs.returned == 2 }
        XCTAssertTrue(restored.shouldSuppress(.high, at: inputs.now))
        XCTAssertFalse(restored.shouldSuppress(.veryhigh, at: inputs.now))
        XCTAssertEqual(restored.watchState.period, period)
        XCTAssertNotNil(restored.activePeriod(at: period.until.addingTimeInterval(-0.001)))
        inputs.now = period.until
        restored.refreshMeasuredBasis(at: inputs.now)
        XCTAssertNil(restored.activePeriod(at: inputs.now))
        XCTAssertNil(restored.watchState.period)
        XCTAssertEqual(restored.document.records["meal"]?.decision, .ended)
    }

    @MainActor func testDurationBeyondNinetyMinutesRemainsInvalid() throws {
        let inputs = MealQuietInputs()
        let manager = inputs.manager()
        manager.setDurationMinutes(90)
        for invalid in [0, 75, 91, 120] { manager.setDurationMinutes(invalid) }
        XCTAssertEqual(manager.durationMinutes, 90)
        var saved = manager.document
        saved.records["meal"] = .init(mealID: "meal", bolusID: "bolus", eatingAt: inputs.now,
            until: inputs.now.addingTimeInterval(5401), decision: .active, reason: "Invalid test interval")
        inputs.data = try JSONEncoder().encode(saved)
        let restored = inputs.manager(configured: false)
        XCTAssertFalse(restored.isEnabled)
        XCTAssertNil(restored.watchState.period)
        XCTAssertEqual(restored.latestExplanation,
            "Måltidsro er ikke aktiv: Tilstanden kunne ikke læses eller gemmes.")
    }

    @MainActor func testExplanationUsesActualDecisionAndReadingItHasNoSideEffects() {
        let inputs = MealQuietInputs()
        let manager = inputs.manager()
        XCTAssertNil(manager.latestExplanation)
        inputs.consider(manager, allowsStart: false)
        XCTAssertEqual(manager.latestExplanation,
            "Måltidsro startede ikke: Registreringen havde ikke et aktuelt startgrundlag.")
        let document = manager.document
        let saved = inputs.data
        _ = manager.latestExplanation
        XCTAssertEqual(manager.document, document)
        XCTAssertEqual(inputs.data, saved)
        XCTAssertEqual(inputs.requests, 0)
        let restored = inputs.manager(configured: false)
        XCTAssertEqual(restored.latestExplanation, manager.latestExplanation)
        manager.setEnabled(false)
        XCTAssertNil(manager.latestExplanation)
    }

    @MainActor func testPendingAndActiveMealHideOlderExplanationAndLowRiskShowsEndReason() async {
        let inputs = MealQuietInputs()
        let manager = inputs.manager()
        inputs.consider(manager, mealID: "rejected", allowsStart: false)
        XCTAssertNotNil(manager.latestExplanation)
        inputs.now = inputs.now.addingTimeInterval(1)
        inputs.consider(manager)
        XCTAssertNil(manager.latestExplanation)
        await waitUntil { inputs.requests == 1 }
        inputs.complete()
        await waitUntil { inputs.returned == 1 }
        XCTAssertNil(manager.latestExplanation)
        manager.acceptSafetyOutcome(inputs.outcome(risk: true), token: inputs.token, at: inputs.now)
        XCTAssertEqual(manager.latestExplanation,
            "Måltidsro afsluttet: Risiko for lavt blodsukker.")
        XCTAssertFalse(manager.shouldSuppress(.high, at: inputs.now))
        let restored = inputs.manager(configured: false)
        XCTAssertEqual(restored.latestExplanation, manager.latestExplanation)
    }

    @MainActor func testExplanationOrdersByDecisionTimeNotBackdatedEatingTime() {
        let inputs = MealQuietInputs()
        let manager = inputs.manager()
        inputs.consider(manager, mealID: "earlier", allowsStart: false)
        inputs.now = inputs.now.addingTimeInterval(10)
        inputs.pairValid = false
        inputs.consider(manager, mealID: "later", eatingAt: inputs.now.addingTimeInterval(-300))
        XCTAssertEqual(manager.latestExplanation,
            "Måltidsro startede ikke: Gemte mad- og insulinregistreringer kunne ikke bekræftes.")
        XCTAssertEqual(inputs.manager(configured: false).latestExplanation, manager.latestExplanation)
    }

    @MainActor func testLegacyExplanationWithoutDecisionTimeAndStorageFailure() async throws {
        let inputs = MealQuietInputs()
        var saved = MealQuietDocument()
        saved.enabled = true
        saved.durationMinutes = 60
        saved.records["legacy"] = .init(mealID: "legacy", bolusID: "bolus", eatingAt: inputs.now,
            until: inputs.now.addingTimeInterval(3600), decision: .rejected, reason: "Varighed er ikke valgt")
        let data = try JSONEncoder().encode(saved)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let records = try XCTUnwrap(object["records"] as? [String: [String: Any]])
        XCTAssertNil(records["legacy"]?["decisionAt"])
        inputs.data = data
        let manager = inputs.manager(configured: false)
        XCTAssertEqual(manager.latestExplanation, "Måltidsro startede ikke: Varighed er ikke valgt.")
        inputs.failWrites = true
        manager.setDurationMinutes(90)
        XCTAssertEqual(manager.latestExplanation,
            "Måltidsro er ikke aktiv: Tilstanden kunne ikke læses eller gemmes.")
        XCTAssertNil(manager.watchState.period)
    }

    @MainActor func testHostedHomeStatusTracksCommittedPeriodWithoutChangingTreatments() async throws {
        let inputs = MealQuietInputs()
        inputs.now = Date()
        inputs.sample = .init(date: inputs.now, glucoseMgdl: 120, sensorID: "sensor-A")
        let manager = inputs.manager(configured: false)
        let host = try HostedMealQuietStatus(manager: manager)
        defer { host.finish() }
        await waitUntil { host.height >= 0 }
        XCTAssertLessThan(host.height, 1, "Disabled status must not reserve a Home row")

        manager.setDurationMinutes(30)
        manager.setEnabled(true)
        inputs.consider(manager)
        await waitUntil { inputs.requests == 1 }
        await host.render()
        XCTAssertEqual(manager.document.records["meal"]?.decision, .pending)
        XCTAssertLessThan(host.height, 1, "Pending is not an active quiet period")
        inputs.complete()
        await waitUntil { host.height >= 44 }
        XCTAssertNotNil(manager.activePeriod())
        for category in [ContentSizeCategory.large, .accessibilityExtraExtraExtraLarge] {
            host.setTextSize(category)
            await host.render()
            let attachment = XCTAttachment(image: host.image())
            attachment.name = "Synthetic Home meal quiet \(category)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let document = manager.document
        let saved = inputs.data
        await host.render()
        XCTAssertGreaterThanOrEqual(host.height, 44)
        XCTAssertEqual(manager.document, document, "Presentation must not reassess or extend a period")
        XCTAssertEqual(inputs.data, saved)
        XCTAssertEqual(inputs.requests, 1)
        XCTAssertEqual(inputs.clearCalls, 1)
        XCTAssertEqual(host.snoozeRequests, 0)
        XCTAssertTrue(try inputs.core.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest()).isEmpty)
        XCTAssertFalse(inputs.core.mainManagedObjectContext.hasChanges)

        manager.end(reason: "Hosted test stopped period")
        await waitUntil { host.height < 1 }
        XCTAssertEqual(manager.document.records["meal"]?.decision, .ended)
        XCTAssertNil(manager.activePeriod())
        XCTAssertFalse(inputs.core.mainManagedObjectContext.hasChanges)
    }

    @MainActor func testHostedHomeStatusExpiresWithoutManagerPublicationOrPersistence() async throws {
        let inputs = MealQuietInputs()
        let until = Date().addingTimeInterval(2)
        var document = MealQuietDocument()
        document.enabled = true
        document.durationMinutes = 15
        document.records["meal"] = .init(mealID: "meal", bolusID: "bolus",
            eatingAt: until.addingTimeInterval(-15 * 60), until: until,
            decision: .active, reason: "Synthetic restored period")
        inputs.data = try JSONEncoder().encode(document)
        let manager = inputs.manager(configured: false)
        let saved = inputs.data
        let revision = manager.revision
        let host = try HostedMealQuietStatus(manager: manager)
        defer { host.finish() }
        await waitUntil { host.height >= 44 }
        await waitUntil { host.height >= 0 && host.height < 1 }

        XCTAssertGreaterThanOrEqual(Date(), until)
        XCTAssertNil(manager.activePeriod())
        XCTAssertEqual(manager.document, document, "The view must only hide the expired record")
        XCTAssertEqual(manager.revision, revision, "No manager publication may be needed for expiry")
        XCTAssertEqual(inputs.data, saved)
        XCTAssertEqual(inputs.requests, 0)
        XCTAssertEqual(inputs.clearCalls, 0)
        XCTAssertEqual(host.snoozeRequests, 0)
        XCTAssertFalse(inputs.core.mainManagedObjectContext.hasChanges)
    }

    @MainActor private func activate(_ manager: MealQuietManager, inputs: MealQuietInputs,
                                    mealID: String = "meal") async {
        let next = inputs.requests + 1
        inputs.consider(manager, mealID: mealID)
        await waitUntil { inputs.requests == next }
        inputs.complete()
        await waitUntil { inputs.returned == next }
        XCTAssertEqual(manager.document.records[mealID]?.decision, .active)
    }

    @MainActor private func waitUntil(_ condition: @escaping () -> Bool,
                                     file: StaticString = #filePath, line: UInt = #line) async {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

@MainActor private final class HostedMealQuietStatus {
    private let controller: UIHostingController<AnyView>
    private let content: AnyView
    private let window: UIWindow
    private weak var previousKeyWindow: UIWindow?
    private let observed: Observations
    private final class Observations {
        var height: CGFloat = -1
        var snoozeRequests = 0
    }

    init(manager: MealQuietManager) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let observed = Observations()
        self.observed = observed
        let content = VStack(spacing: 0) {
            RootHomeMealQuietStatusView(mealQuiet: manager,
                openSnooze: { observed.snoozeRequests += 1 })
        }
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { observed.height = geometry.size.height }
                .onChange(of: geometry.size.height) { observed.height = $0 }
        })
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        self.content = AnyView(content)
        controller = UIHostingController(rootView: self.content)
        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 300)
        window.rootViewController = controller
        window.makeKeyAndVisible()
    }

    var height: CGFloat { observed.height }
    var snoozeRequests: Int { observed.snoozeRequests }

    func setTextSize(_ size: ContentSizeCategory) {
        controller.rootView = AnyView(content.environment(\.sizeCategory, size))
    }

    func render() async {
        try? await Task.sleep(nanoseconds: 150_000_000)
        controller.view.layoutIfNeeded()
    }

    func image() -> UIImage {
        UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            XCTAssertTrue(controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true))
        }
    }

    func finish() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }
}

@MainActor private final class MealQuietInputs {
    let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var sample: GlucoseForecastSample?
    var rules: MealQuietRules? = .init(low: 65, high: 180, urgentHigh: 250)
    var pairValid = true
    var token: String? = "initial-revision"
    var treatmentRevision = 1
    var hasUncommitted = false
    var signature = "testcontext"
    var data: Data?
    var failWrites = false
    var recoveryDefaults: UserDefaults?
    var requests = 0
    var returned = 0
    var clearCalls = 0
    private var continuation: CheckedContinuation<GlucoseForecastSafetyOutcome, Never>?

    init() { sample = .init(date: now, glucoseMgdl: 120, sensorID: "sensor-A") }

    func manager(configured: Bool = true) -> MealQuietManager {
        let overrides = MealQuietManager.InputOverrides(
            pairIsValid: { [self] _ in pairValid }, latestGlucose: { [self] in sample },
            currentRules: { [self] _ in rules }, inputState: { [self] in
                .init(token: token, treatmentRevision: treatmentRevision, hasUncommitted: hasUncommitted)
            }, contextSignature: { [self] in signature }, forecast: { [self] _, _ in
                let result = await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    requests += 1
                }
                returned += 1
                return result
            })
        let manager = MealQuietManager(load: { [self] in data }, save: { [self] saved in
            if failWrites { throw CocoaError(.fileWriteUnknown) }
            data = saved
        }, inputOverrides: overrides, clock: { [self] in now }, recoveryDefaults: recoveryDefaults, clearHighSoon: { [self] in clearCalls += 1 })
        if configured {
            manager.setDurationMinutes(30)
            manager.setEnabled(true)
        }
        return manager
    }

    func consider(_ manager: MealQuietManager, mealID: String = "meal", eatingAt: Date? = nil,
                  eventAt: Date? = nil, allowsStart: Bool = true) {
        manager.considerCommittedMeal(coreDataManager: core, mealID: mealID, bolusID: "bolus-\(mealID)",
            eatingAt: eatingAt ?? now, eventAt: eventAt ?? now, allowsStart: allowsStart)
    }

    func complete(_ supplied: GlucoseForecastSafetyOutcome? = nil) {
        guard let continuation else { XCTFail("No forecast request is waiting"); return }
        self.continuation = nil
        continuation.resume(returning: supplied ?? outcome())
    }

    func outcome(risk: Bool = false, unavailable: Bool = false) -> GlucoseForecastSafetyOutcome {
        let reference = sample?.date ?? now
        let glucose = sample?.glucoseMgdl ?? 120
        let points = stride(from: 0, through: 60, by: 5).map { minute in
            GlucoseForecastPoint(date: reference.addingTimeInterval(Double(minute) * 60),
                glucoseMgdl: risk && minute == 10 ? 70 : glucose)
        }
        return .init(result: .init(points: points, referenceDate: reference,
            reason: unavailable ? .dataUnavailable : nil, referenceSensorID: sample?.sensorID),
            referenceGlucoseMgdl: glucose, activeInsulinUnits: 1, slope15MgdlPerMinute: 0)
    }
}
