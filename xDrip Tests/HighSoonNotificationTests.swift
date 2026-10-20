import CoreData
import UserNotifications
import XCTest
@testable import xdrip

@MainActor
final class HighSoonNotificationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func outcome(at date: Date) throws -> GlucoseForecastSafetyOutcome {
        // A real engine/calculator run: rising measured glucose crosses 180 mg/dL,
        // with complete known-zero treatment history and a confirmed pen profile.
        let samples = stride(from: -30, through: 0, by: 5).map { minute in
            GlucoseForecastSample(date: date.addingTimeInterval(Double(minute) * 60),
                glucoseMgdl: 175 + Double(minute) * 2, sensorID: "high-soon-test-sensor")
        }
        let snapshot = try PenDoseInputSnapshot.make(capturedAt: date, glucose: samples,
            treatments: [], therapySettings: TherapyModelSettings(), treatmentRevision: 1,
            sourceSignature: "synthetic-local-source").get()
        let settings = PenDoseProfile.Settings(
            carbohydrateRatios: [.init(startMinute: 0, value: 10)],
            targetsMmol: [.init(startMinute: 0, value: 6)],
            correctionMmolPerUnit: 2, penStepUnits: 0.5, maximumSuggestionUnits: 25)
        let profile = PenDoseProfile(settings: settings, confirmedSettings: settings,
            confirmedAt: date.addingTimeInterval(-3600))
        let result = GlucoseForecastDataAdapter.engineOnlyOutcome(snapshot: snapshot,
            at: date, sensitivityMgdlPerUnit: 40, carbohydrateRatioGramsPerUnit: 10,
            highAdvisoryProfile: profile)
        XCTAssertNotNil(HighSoonAdvisoryPolicy.prediction(from: result,
            expectedReferenceDate: date, expectedSensorID: "high-soon-test-sensor",
            expectedGlucoseMgdl: 175, highLimitMgdl: 180, at: date),
            "The scheduling fixture must pass the production safety policy")
        return result
    }

    func testRealSchedulingUsesIndependentNotificationAndReservesBeforeSystemReply() throws {
        let harness = Harness()
        defer { harness.finish() }
        let prediction = try outcome(at: now)
        harness.evaluate(prediction, at: now)
        harness.evaluate(prediction, at: now)

        let request = try XCTUnwrap(harness.requests.first)
        XCTAssertEqual(harness.requests.count, 1)
        XCTAssertEqual(request.identifier, HighSoonAdvisoryPolicy.notificationIdentifier)
        XCTAssertEqual(request.content.categoryIdentifier, HighSoonAdvisoryPolicy.categoryIdentifier)
        XCTAssertEqual(request.content.title, "Højt om lidt")
        XCTAssertNotNil(request.content.sound)
        XCTAssertEqual(request.content.interruptionLevel, .active)
        XCTAssertNil(request.trigger)
        XCTAssertTrue(request.content.userInfo.isEmpty, "No frozen dose is transported by a notification")
        XCTAssertEqual(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey) as? Date, now)
        XCTAssertNil(harness.defaults.object(forKey: LowSoonAlertState.lastScheduledDefaultsKey))
        XCTAssertFalse(AlertManager.ownedPendingNotificationIdentifiers.contains(request.identifier))
        XCTAssertTrue(AlertManager.ownedPendingNotificationIdentifiers.contains(AlertKind.high.notificationIdentifier()))
        XCTAssertFalse(harness.manager.getSnoozeParameters(alertKind: .high).getSnoozeValue().isSnoozed)
        XCTAssertTrue(try harness.core.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest()).isEmpty)
    }

    func testFailedSchedulingReleasesOnlyItsReservationAndAllowsRetry() async throws {
        let harness = Harness()
        defer { harness.finish() }
        let prediction = try outcome(at: now)
        harness.evaluate(prediction, at: now)
        harness.completions[0](NSError(domain: "SyntheticNotificationFailure", code: 1))
        await drainCallbacks()
        XCTAssertNil(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey))

        harness.evaluate(prediction, at: now)
        XCTAssertEqual(harness.requests.count, 2)
        harness.completions[1](nil)
        await drainCallbacks()
        harness.evaluate(prediction, at: now)
        XCTAssertEqual(harness.requests.count, 2, "A successful request keeps the persisted repeat limit")
    }

    func testMealQuietBeforeSchedulingLeavesExistingReservationAndSnoozeUntouched() throws {
        let harness = Harness()
        defer { harness.finish() }
        let previous = now.addingTimeInterval(-3600)
        harness.defaults.set(previous, forKey: HighSoonAdvisoryPolicy.lastScheduledKey)
        let high = harness.manager.getSnoozeParameters(alertKind: .high)
        let snoozeStamp = high.snoozeTimeStamp
        let snoozeMinutes = high.snoozePeriodInMinutes
        harness.mealQuietState = (true, 1)
        harness.evaluate(try outcome(at: now), at: now)
        XCTAssertTrue(harness.requests.isEmpty)
        XCTAssertEqual(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey) as? Date, previous)
        XCTAssertEqual(high.snoozeTimeStamp, snoozeStamp)
        XCTAssertEqual(high.snoozePeriodInMinutes, snoozeMinutes)
    }

    func testMealQuietDuringPendingReplyRestoresOnlyItsPriorReservation() async throws {
        let previousReservations: [Date?] = [nil, now.addingTimeInterval(-3600)]
        for previous in previousReservations {
            let harness = Harness()
            defer { harness.finish() }
            if let previous { harness.defaults.set(previous, forKey: HighSoonAdvisoryPolicy.lastScheduledKey) }
            harness.evaluate(try outcome(at: now), at: now)
            harness.mealQuietState = (true, 1)
            harness.completions[0](nil)
            await drainCallbacks()
            XCTAssertEqual(harness.clearCount, 1)
            XCTAssertEqual(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey) as? Date, previous)
            XCTAssertFalse(harness.manager.getSnoozeParameters(alertKind: .high).getSnoozeValue().isSnoozed)

            // The canceled request no longer owns the reservation or notification identifier.
            harness.completions[0](nil)
            await drainCallbacks()
            XCTAssertEqual(harness.clearCount, 1)
            harness.mealQuietState = (false, 1)
            harness.evaluate(try outcome(at: now), at: now)
            XCTAssertEqual(harness.requests.count, 2, "A suppressed request must not count as sent")
        }
    }

    func testMealQuietEndingBeforeSystemReplyCannotReviveOldAdvisory() async throws {
        let harness = Harness()
        defer { harness.finish() }
        harness.evaluate(try outcome(at: now), at: now)
        // The current flag is false again, but an intervening quiet activation advanced its epoch.
        harness.mealQuietState = (false, 1)
        harness.completions[0](nil)
        await drainCallbacks()
        XCTAssertEqual(harness.clearCount, 1)
        XCTAssertNil(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey))
    }

    func testOldQuietReplyCannotClearNewerAttemptOrRestoreItsReservation() async throws {
        let harness = Harness()
        defer { harness.finish() }
        harness.evaluate(try outcome(at: now), at: now)
        let later = now.addingTimeInterval(HighSoonAdvisoryPolicy.minimumInterval)
        harness.evaluate(try outcome(at: later), at: later)
        harness.mealQuietState = (true, 1)
        harness.completions[0](nil)
        await drainCallbacks()
        XCTAssertEqual(harness.clearCount, 0, "The older callback no longer owns the shared notification ID")
        XCTAssertEqual(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey) as? Date, later)
        harness.completions[1](nil)
        await drainCallbacks()
        XCTAssertEqual(harness.clearCount, 1)
        XCTAssertEqual(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey) as? Date, now)
    }

    func testSameTimestampReplacementStillRejectsOlderCallbackOwnership() async throws {
        let harness = Harness()
        defer { harness.finish() }
        harness.evaluate(try outcome(at: now), at: now)
        // Force a second request with the same timestamp to prove ownership is more than Date equality.
        harness.defaults.removeObject(forKey: HighSoonAdvisoryPolicy.lastScheduledKey)
        harness.evaluate(try outcome(at: now), at: now)
        XCTAssertEqual(harness.requests.count, 2)
        harness.mealQuietState = (false, 1)
        harness.completions[0](nil)
        await drainCallbacks()
        XCTAssertEqual(harness.clearCount, 0)
        XCTAssertEqual(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey) as? Date, now)
        harness.completions[1](nil)
        await drainCallbacks()
        XCTAssertEqual(harness.clearCount, 1)
        XCTAssertNil(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey))
    }

    func testOldFailedRequestCannotEraseANewerReservation() async throws {
        let harness = Harness()
        defer { harness.finish() }
        harness.evaluate(try outcome(at: now), at: now)
        let later = now.addingTimeInterval(HighSoonAdvisoryPolicy.minimumInterval)
        harness.evaluate(try outcome(at: later), at: later)
        XCTAssertEqual(harness.requests.count, 2)
        harness.completions[0](NSError(domain: "SyntheticNotificationFailure", code: 2))
        await drainCallbacks()
        XCTAssertEqual(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey) as? Date, later)
    }

    func testPersistedReservationSurvivesNewManagerAndClockReversal() throws {
        let harness = Harness()
        defer { harness.finish() }
        harness.evaluate(try outcome(at: now), at: now)
        let restarted = AlertManager(coreDataManager: harness.core, soundPlayer: nil)
        for date in [now.addingTimeInterval(-60), now.addingTimeInterval(1799)] {
            restarted.checkHighSoon(try outcome(at: date), expectedReferenceDate: date,
                expectedSensorID: "high-soon-test-sensor", expectedGlucoseMgdl: 175,
                at: date, defaults: harness.defaults,
                schedule: { _, _ in XCTFail("A persisted reservation must suppress a repeat") })
        }
    }

    func testDisabledSettingDisabledHighAndDisabledAlertTypeSuppressWithoutReservation() throws {
        let harness = Harness()
        defer { harness.finish() }
        let prediction = try outcome(at: now)
        harness.defaults.set(false, forKey: HighSoonAdvisoryPolicy.enabledKey)
        harness.evaluate(prediction, at: now)
        harness.defaults.set(true, forKey: HighSoonAdvisoryPolicy.enabledKey)
        harness.entry.isDisabled = true
        harness.evaluate(prediction, at: now)
        harness.entry.isDisabled = false
        harness.type.enabled = false
        harness.evaluate(prediction, at: now)
        XCTAssertTrue(harness.requests.isEmpty)
        XCTAssertNil(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey))
        harness.type.enabled = true
        harness.evaluate(prediction, at: now)
        XCTAssertEqual(harness.requests.count, 1)
    }

    func testSnoozeAllAndHighSnoozeSuppressButLowSoonStateDoesNot() throws {
        let harness = Harness()
        defer { harness.finish() }
        let prediction = try outcome(at: now)
        harness.defaults.snoozeAllAlertsUntilDate = now.addingTimeInterval(60)
        harness.evaluate(prediction, at: now)
        harness.defaults.snoozeAllAlertsUntilDate = nil
        let high = harness.manager.getSnoozeParameters(alertKind: .high)
        high.snoozeTimeStamp = now
        high.snoozePeriodInMinutes = 30
        harness.evaluate(prediction, at: now)
        XCTAssertTrue(harness.requests.isEmpty)
        XCTAssertNil(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey))
        XCTAssertEqual(high.snoozeTimeStamp, now)
        XCTAssertEqual(high.snoozePeriodInMinutes, 30)

        high.unSnooze()
        let low = harness.manager.getSnoozeParameters(alertKind: .lowSoon)
        low.snoozeTimeStamp = now
        low.snoozePeriodInMinutes = 30
        harness.defaults.set(now, forKey: LowSoonAlertState.lastScheduledDefaultsKey)
        harness.evaluate(prediction, at: now)
        XCTAssertEqual(harness.requests.count, 1)
        XCTAssertEqual(low.snoozeTimeStamp, now)
        XCTAssertEqual(low.snoozePeriodInMinutes, 30)
        XCTAssertEqual(harness.defaults.object(forKey: LowSoonAlertState.lastScheduledDefaultsKey) as? Date, now)
    }

    func testOrdinaryHighScheduleSelectsCurrentThreshold() throws {
        let harness = Harness()
        defer { harness.finish() }
        let calendar = Calendar.current
        let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 12)))
        let next = AlertEntry(isDisabled: false, value: 190, triggerValue: 0, alertKind: .high,
            start: 12 * 60 + 1, alertType: harness.type,
            nsManagedObjectContext: harness.core.mainManagedObjectContext)
        harness.evaluate(try outcome(at: date.addingTimeInterval(60)), at: date.addingTimeInterval(60))
        XCTAssertTrue(harness.requests.isEmpty, "The new 190 mg/dL schedule entry suppresses the 185 forecast")
        harness.evaluate(try outcome(at: date), at: date)
        XCTAssertEqual(harness.requests.count, 1, "The earlier 180 mg/dL entry still allows this crossing")
        XCTAssertEqual(next.value, 190)
        XCTAssertEqual(harness.entry.value, 180)
    }

    func testInvalidOutcomeCannotSchedule() throws {
        let harness = Harness()
        defer { harness.finish() }
        let invalid = GlucoseForecastSafetyOutcome(result: .init(points: [], referenceDate: now,
            reason: .dataUnavailable, referenceSensorID: "high-soon-test-sensor"),
            referenceGlucoseMgdl: 175, activeInsulinUnits: 0, slope15MgdlPerMinute: 2)
        harness.evaluate(invalid, at: now)
        XCTAssertTrue(harness.requests.isEmpty)
        XCTAssertNil(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey))
    }

    func testDisableDuringSystemRequestClearsAcceptedAdvisoryWithoutRemovingThrottle() async throws {
        let harness = Harness()
        defer { harness.finish() }
        harness.evaluate(try outcome(at: now), at: now)
        harness.defaults.set(false, forKey: HighSoonAdvisoryPolicy.enabledKey)
        harness.completions[0](nil)
        await drainCallbacks()
        XCTAssertEqual(harness.clearCount, 1)
        XCTAssertEqual(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey) as? Date, now)
    }

    func testDisableClearsOnlyOwnedPendingAndDeliveredNotifications() {
        var pending: [[String]] = []
        var delivered: [[String]] = []
        let clear = {
            AlertManager.clearHighSoonNotifications(removePending: { pending.append($0) },
                removeDelivered: { delivered.append($0) })
        }
        AlertManager.highSoonSettingDidChange(isEnabled: true, clearNotifications: clear)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(delivered.isEmpty)
        AlertManager.highSoonSettingDidChange(isEnabled: false, clearNotifications: clear)
        XCTAssertEqual(pending, [[HighSoonAdvisoryPolicy.notificationIdentifier]])
        XCTAssertEqual(delivered, [[HighSoonAdvisoryPolicy.notificationIdentifier]])
    }

    func testBodyUsesPeakTimeAndUnitsWithoutDoseAndCategoryHasOnlyForegroundCalculatorAction() throws {
        let prediction = HighSoonAdvisoryPolicy.Prediction(peakMgdl: 216,
            peakDate: now.addingTimeInterval(601), windowStart: now, activeInsulinUnits: 9.75)
        let mgdl = AlertManager.highSoonNotificationBody(prediction, usesMgDl: true)
        let mmol = AlertManager.highSoonNotificationBody(prediction, usesMgDl: false)
        XCTAssertTrue(mgdl.contains("216 mg/dL om 11 min"))
        XCTAssertTrue(mmol.contains("12.0 mmol/L om 11 min"))
        for text in [mgdl, mmol] {
            XCTAssertFalse(text.contains("9.75"))
            XCTAssertFalse(text.contains("9,75"))
            XCTAssertFalse(text.contains(" E"))
            XCTAssertFalse(text.contains("insulin"))
        }
        let category = AlertManager.highSoonNotificationCategory()
        XCTAssertEqual(category.identifier, HighSoonAdvisoryPolicy.categoryIdentifier)
        XCTAssertEqual(category.actions.count, 1)
        let action = try XCTUnwrap(category.actions.first)
        XCTAssertEqual(action.identifier, HighSoonAdvisoryPolicy.openActionIdentifier)
        XCTAssertEqual(action.title, "Åbn beregner")
        XCTAssertEqual(action.options, [.foreground])
        XCTAssertTrue(category.options.isEmpty)
    }

    func testOnlyExactHighAdvisoryDefaultAndOpenActionRouteToCalculator() {
        for action in [UNNotificationDefaultActionIdentifier, HighSoonAdvisoryPolicy.openActionIdentifier] {
            XCTAssertTrue(AlertManager.opensHighSoonCalculator(
                notificationIdentifier: HighSoonAdvisoryPolicy.notificationIdentifier, actionIdentifier: action))
            for identifier in [AlertKind.high.notificationIdentifier(), AlertKind.lowSoon.notificationIdentifier(),
                               HighSoonAdvisoryPolicy.notificationIdentifier + ".other", ""] {
                XCTAssertFalse(AlertManager.opensHighSoonCalculator(notificationIdentifier: identifier,
                    actionIdentifier: action))
            }
        }
        for action in [UNNotificationDismissActionIdentifier, "snoozeActionIdentifier",
                       AlertManager.lowSoonCalculatorActionIdentifier, "unknown", ""] {
            XCTAssertFalse(AlertManager.opensHighSoonCalculator(
                notificationIdentifier: HighSoonAdvisoryPolicy.notificationIdentifier, actionIdentifier: action))
        }
    }

    private func drainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor private final class Harness {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let defaults: UserDefaults
        let suiteName = "HighSoonNotificationTests.\(UUID().uuidString)"
        let type: AlertType
        let entry: AlertEntry
        let manager: AlertManager
        var requests: [UNNotificationRequest] = []
        var completions: [(Error?) -> Void] = []
        var clearCount = 0
        var mealQuietState = (suppressed: false, revision: 0)

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set(false, forKey: UserDefaults.Key.bloodGlucoseUnitIsMgDl.rawValue)
            type = AlertType(enabled: true, name: "Synthetic high rule", overrideMute: true,
                snooze: true, snoozePeriod: 15, vibrate: true, soundName: "", alertEntries: nil,
                nsManagedObjectContext: core.mainManagedObjectContext)
            entry = AlertEntry(isDisabled: false, value: 180, triggerValue: 0, alertKind: .high,
                start: 0, alertType: type, nsManagedObjectContext: core.mainManagedObjectContext)
            manager = AlertManager(coreDataManager: core, soundPlayer: nil)
        }

        func evaluate(_ outcome: GlucoseForecastSafetyOutcome, at now: Date) {
            manager.checkHighSoon(outcome, expectedReferenceDate: now,
                expectedSensorID: "high-soon-test-sensor", expectedGlucoseMgdl: 175, at: now,
                defaults: defaults, schedule: { [unowned self] request, completion in
                    requests.append(request)
                    completions.append(completion)
                }, clearNotifications: { [weak self] in self?.clearCount += 1 },
                mealQuietState: { [unowned self] in mealQuietState })
        }

        func finish() {
            completions.removeAll()
            defaults.removePersistentDomain(forName: suiteName)
        }
    }
}
