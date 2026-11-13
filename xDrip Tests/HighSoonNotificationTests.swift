import AVFoundation
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

    func testEndingExpiredSilenceNeverStartsANewPause() {
        let harness = Harness()
        defer { harness.finish() }
        SelectiveAlarmSilence.toggle(at: now.addingTimeInterval(-7200), defaults: harness.defaults)
        XCTAssertFalse(SelectiveAlarmSilence.isActive(at: now, defaults: harness.defaults))
        SelectiveAlarmSilence.end(defaults: harness.defaults)
        SelectiveAlarmSilence.end(defaults: harness.defaults)
        XCTAssertNil(SelectiveAlarmSilence.until(defaults: harness.defaults))
        XCTAssertFalse(SelectiveAlarmSilence.isActive(at: now, defaults: harness.defaults))
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

    func testRealNotificationUsesIndependentSoundPreferenceWithSafeDefaultFallback() throws {
        let cases: [(String?, UNNotificationSound?)] = [
            (nil, .default),
            ("", nil),
            (ConstantsSounds.shorthigh1.rawValue,
             UNNotificationSound(named: UNNotificationSoundName("shorthigh1.caf"))),
            ("unknown-sound.caf", .default),
            (ConstantsSounds.Early_Sunrise.rawValue, .default)
        ]
        for (stored, expectedSound) in cases {
            let harness = Harness()
            defer { harness.finish() }
            if let stored { harness.defaults.set(stored, forKey: HighSoonAdvisorySound.defaultsKey) }
            harness.evaluate(try outcome(at: now), at: now)
            let request = try XCTUnwrap(harness.requests.first)
            XCTAssertEqual(request.content.sound, expectedSound)
            XCTAssertEqual(request.content.interruptionLevel, .active)
            XCTAssertEqual(request.content.categoryIdentifier, HighSoonAdvisoryPolicy.categoryIdentifier)
            XCTAssertNil(request.trigger)
            XCTAssertEqual(harness.type.soundname, "", "The measured-high alarm stays independently silent")
            XCTAssertTrue(harness.type.overridemute, "No measured-high alert settings are rewritten")
            XCTAssertFalse(harness.manager.getSnoozeParameters(alertKind: .high).getSnoozeValue().isSnoozed)
            harness.evaluate(try outcome(at: now), at: now)
            XCTAssertEqual(harness.requests.count, 1, "Changing sound does not remove the repeat limit")
        }
    }

    func testSoundPickerPreviewsAndCancellationStopsWithoutSaving() throws {
        let harness = Harness()
        defer { harness.finish() }
        let player = PreviewSoundPlayer()
        let model = AlertsSettingsViewModel(coreDataManager: harness.core,
            defaults: harness.defaults, soundPlayer: player)
        let picker = model.highSoonSoundSelection()
        let namedIndex = try XCTUnwrap(HighSoonAdvisorySound.choices.firstIndex(of: .named(.shorthigh1)))
        let silentIndex = try XCTUnwrap(HighSoonAdvisorySound.choices.firstIndex(of: .silent))
        XCTAssertEqual(picker.selectedRow, HighSoonAdvisorySound.choices.firstIndex(of: .systemDefault))
        XCTAssertEqual(model.highSoonSoundTitle, "Standardlyd")
        picker.didSelectRow?(namedIndex)
        XCTAssertEqual(player.played, ["shorthigh1.caf"])
        XCTAssertTrue(player.isPlaying())
        XCTAssertNil(harness.defaults.object(forKey: HighSoonAdvisorySound.defaultsKey))
        picker.didSelectRow?(silentIndex)
        XCTAssertFalse(player.isPlaying(), "Selecting silence stops the previous preview")
        picker.didSelectRow?(namedIndex)
        picker.cancel?()
        XCTAssertFalse(player.isPlaying())
        XCTAssertEqual(player.stopCount, 4)
        XCTAssertEqual(model.highSoonSound, .systemDefault)
        XCTAssertNil(harness.defaults.object(forKey: HighSoonAdvisorySound.defaultsKey))
    }

    func testSoundPickerConfirmationPersistsNamedSilentAndDefaultAcrossReopening() throws {
        let harness = Harness()
        defer { harness.finish() }
        let player = PreviewSoundPlayer()
        let model = AlertsSettingsViewModel(coreDataManager: harness.core,
            defaults: harness.defaults, soundPlayer: player)
        let choices: [HighSoonAdvisorySound] = [.named(.shorthigh1), .silent, .systemDefault]
        let titles = ["Short High 1", "Ingen lyd",
                      "Standardlyd"]
        for (choice, title) in zip(choices, titles) {
            let picker = model.highSoonSoundSelection()
            let index = try XCTUnwrap(HighSoonAdvisorySound.choices.firstIndex(of: choice))
            picker.didSelectRow?(index)
            picker.action(index)
            XCTAssertFalse(player.isPlaying(), "Confirming stops the preview")
            XCTAssertEqual(model.highSoonSound, choice)
            XCTAssertEqual(model.highSoonSoundTitle, title)
            let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: harness.suiteName))
            let reopened = AlertsSettingsViewModel(coreDataManager: harness.core,
                defaults: reopenedDefaults, soundPlayer: player)
            XCTAssertEqual(reopened.highSoonSound, choice)
            XCTAssertEqual(reopened.highSoonSoundSelection().selectedRow, index)
            XCTAssertEqual(reopened.highSoonSoundTitle, title)
        }
        XCTAssertNil(harness.defaults.object(forKey: HighSoonAdvisorySound.defaultsKey),
            "Restoring the default preserves the original unset preference")
        XCTAssertEqual(harness.type.soundname, "")
    }

    func testUnknownOrTooLongStoredSoundShowsDefaultAndCanBeReplaced() throws {
        for stored in ["removed-sound", ConstantsSounds.Nightguard.rawValue] {
            let harness = Harness()
            defer { harness.finish() }
            harness.defaults.set(stored, forKey: HighSoonAdvisorySound.defaultsKey)
            let model = AlertsSettingsViewModel(coreDataManager: harness.core,
                defaults: harness.defaults, soundPlayer: PreviewSoundPlayer())
            XCTAssertEqual(model.highSoonSound, .systemDefault)
            XCTAssertEqual(model.highSoonSoundTitle, "Standardlyd")
            let picker = model.highSoonSoundSelection()
            XCTAssertEqual(picker.selectedRow, HighSoonAdvisorySound.choices.firstIndex(of: .systemDefault))
            let index = try XCTUnwrap(HighSoonAdvisorySound.choices.firstIndex(of: .named(.shorthigh2)))
            picker.action(index)
            XCTAssertEqual(HighSoonAdvisorySound.load(defaults: harness.defaults), .named(.shorthigh2))
        }
    }

    func testEverySelectableNamedSoundExistsInAppBundleAndIsShorterThanThirtySeconds() throws {
        XCTAssertFalse(HighSoonAdvisorySound.availableSounds.isEmpty)
        for sound in HighSoonAdvisorySound.availableSounds {
            let filename = ConstantsSounds.getSoundFile(forSound: sound)
            let url = try XCTUnwrap(Bundle.main.url(forResource: filename, withExtension: ""), filename)
            let file = try AVAudioFile(forReading: url)
            XCTAssertGreaterThan(file.processingFormat.sampleRate, 0, filename)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            XCTAssertGreaterThan(duration, 0, filename)
            XCTAssertLessThan(duration, 30, "\(filename) cannot be used as a custom notification sound")
        }
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

    func testSelectiveSilenceProtectsEveryLowAndMissingDataKind() throws {
        let harness = Harness()
        defer { harness.finish() }
        let date = Date()
        SelectiveAlarmSilence.toggle(at: date, defaults: harness.defaults)
        let protected: Set<AlertKind> = [.verylow, .low, .lowSoon, .missedreading, .sensorTransmitterFailure]
        for kind in AlertKind.allCases {
            XCTAssertEqual(SelectiveAlarmSilence.suppresses(kind, at: date, defaults: harness.defaults),
                           !protected.contains(kind), "Unexpected selective policy for \(kind)")
            XCTAssertEqual(harness.manager.quietPeriodSuppresses(kind), !protected.contains(kind))
        }
        let cleared = Set(SelectiveAlarmSilence.notificationIdentifiers)
        XCTAssertEqual(cleared.count, SelectiveAlarmSilence.kinds.count + 1)
        XCTAssertTrue(cleared.contains(HighSoonAdvisoryPolicy.notificationIdentifier))
        for kind in protected { XCTAssertFalse(cleared.contains(kind.notificationIdentifier())) }
        XCTAssertNil(harness.defaults.snoozeAllAlertsUntilDate)
        XCTAssertTrue(try harness.core.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest()).isEmpty)
    }

    func testSelectiveSilenceHasFixedExpiryAcrossRestartAndDurationChange() throws {
        let harness = Harness()
        defer { harness.finish() }
        harness.defaults.set(30, forKey: SelectiveAlarmSilence.durationKey)
        SelectiveAlarmSilence.toggle(at: now, defaults: harness.defaults)
        let expiry = now.addingTimeInterval(30 * 60)
        let revision = try XCTUnwrap(SelectiveAlarmSilence.revision(defaults: harness.defaults))
        let reopened = try XCTUnwrap(UserDefaults(suiteName: harness.suiteName))
        XCTAssertEqual(SelectiveAlarmSilence.until(defaults: reopened), expiry)
        XCTAssertEqual(SelectiveAlarmSilence.revision(defaults: reopened), revision)
        reopened.set(120, forKey: SelectiveAlarmSilence.durationKey)
        XCTAssertEqual(SelectiveAlarmSilence.until(defaults: reopened), expiry,
                       "Changing the next duration cannot extend an active pause")
        XCTAssertTrue(SelectiveAlarmSilence.isActive(at: expiry.addingTimeInterval(-0.001), defaults: reopened))
        XCTAssertFalse(SelectiveAlarmSilence.isActive(at: expiry, defaults: reopened))
        XCTAssertFalse(SelectiveAlarmSilence.isActive(at: expiry.addingTimeInterval(1), defaults: reopened))
        SelectiveAlarmSilence.toggle(at: expiry, defaults: reopened)
        XCTAssertEqual(SelectiveAlarmSilence.until(defaults: reopened), expiry.addingTimeInterval(120 * 60))
        XCTAssertNotEqual(SelectiveAlarmSilence.revision(defaults: reopened), revision)
    }

    func testSelectiveSilenceInvalidDurationAndStateDoNotCreateUnlimitedPause() {
        let harness = Harness()
        defer { harness.finish() }
        for value in [-1, 0, 1, 99999] {
            harness.defaults.set(value, forKey: SelectiveAlarmSilence.durationKey)
            XCTAssertEqual(SelectiveAlarmSilence.durationMinutes(defaults: harness.defaults),
                           SelectiveAlarmSilence.defaultDurationMinutes)
        }
        let malformedStates: [Any] = ["invalid", ["until": "invalid"], ["revision": "ended"]]
        for stored in malformedStates {
            harness.defaults.set(stored, forKey: SelectiveAlarmSilence.stateKey)
            XCTAssertFalse(SelectiveAlarmSilence.isActive(at: now, defaults: harness.defaults))
        }
    }

    func testSelectiveSilenceStartEndAndRestartPreserveIndependentCoreDataSnoozes() throws {
        let harness = Harness()
        defer { harness.finish() }
        let date = Date()
        for (index, kind) in AlertKind.allCases.enumerated() {
            let item = harness.manager.getSnoozeParameters(alertKind: kind)
            item.snoozeTimeStamp = date.addingTimeInterval(-Double(index))
            item.snoozePeriodInMinutes = Int16(index + 15)
        }
        try harness.core.mainManagedObjectContext.save()
        let before = AlertKind.allCases.map { kind -> (Date?, Int16) in
            let item = harness.manager.getSnoozeParameters(alertKind: kind)
            return (item.snoozeTimeStamp, item.snoozePeriodInMinutes)
        }
        SelectiveAlarmSilence.toggle(at: date, defaults: harness.defaults)
        // An independent later user change must also survive ending the icon pause.
        let high = harness.manager.getSnoozeParameters(alertKind: .high)
        high.snoozePeriodInMinutes = 240
        try harness.core.mainManagedObjectContext.save()
        let reopened = try XCTUnwrap(UserDefaults(suiteName: harness.suiteName))
        let restarted = AlertManager(coreDataManager: harness.core, soundPlayer: nil,
                                     silenceDefaults: reopened)
        SelectiveAlarmSilence.toggle(at: date.addingTimeInterval(1), defaults: reopened)
        XCTAssertFalse(SelectiveAlarmSilence.isActive(at: date.addingTimeInterval(1), defaults: reopened))
        for (index, kind) in AlertKind.allCases.enumerated() {
            let item = restarted.getSnoozeParameters(alertKind: kind)
            XCTAssertEqual(item.snoozeTimeStamp, before[index].0)
            XCTAssertEqual(item.snoozePeriodInMinutes, kind == .high ? 240 : before[index].1)
        }
        XCTAssertNil(reopened.snoozeAllAlertsUntilDate)
        XCTAssertTrue(try harness.core.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest()).isEmpty)
    }

    func testSelectiveSilencePreventsRealHighSoonSchedulingWithoutChangingReservation() throws {
        let harness = Harness()
        defer { harness.finish() }
        let previous = now.addingTimeInterval(-3600)
        harness.defaults.set(previous, forKey: HighSoonAdvisoryPolicy.lastScheduledKey)
        SelectiveAlarmSilence.toggle(at: now, defaults: harness.defaults)
        harness.evaluate(try outcome(at: now), at: now)
        XCTAssertTrue(harness.requests.isEmpty)
        XCTAssertEqual(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey) as? Date, previous)
        XCTAssertFalse(harness.manager.getSnoozeParameters(alertKind: .high).getSnoozeValue().isSnoozed)
        SelectiveAlarmSilence.toggle(at: now, defaults: harness.defaults)
        harness.evaluate(try outcome(at: now), at: now)
        XCTAssertEqual(harness.requests.count, 1)
    }

    func testSelectiveSilenceStartThenEndRejectsPendingHighSoonReplyAndRestoresReservation() async throws {
        let reservations: [Date?] = [nil, now.addingTimeInterval(-3600)]
        for previous in reservations {
            let harness = Harness()
            defer { harness.finish() }
            if let previous { harness.defaults.set(previous, forKey: HighSoonAdvisoryPolicy.lastScheduledKey) }
            harness.evaluate(try outcome(at: now), at: now)
            SelectiveAlarmSilence.toggle(at: now, defaults: harness.defaults)
            SelectiveAlarmSilence.toggle(at: now.addingTimeInterval(1), defaults: harness.defaults)
            harness.completions[0](nil)
            await drainCallbacks()
            XCTAssertEqual(harness.clearCount, 1)
            XCTAssertEqual(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey) as? Date, previous)
            harness.completions[0](nil)
            await drainCallbacks()
            XCTAssertEqual(harness.clearCount, 1, "The canceled callback cannot clear a future advisory")
            harness.evaluate(try outcome(at: now), at: now)
            XCTAssertEqual(harness.requests.count, 2, "Suppression must not count as a delivered advisory")
        }
    }

    func testSelectiveSilenceOldHighSoonReplyCannotEraseNewerAdvisory() async throws {
        let harness = Harness()
        defer { harness.finish() }
        harness.evaluate(try outcome(at: now), at: now)
        SelectiveAlarmSilence.toggle(at: now, defaults: harness.defaults)
        SelectiveAlarmSilence.toggle(at: now.addingTimeInterval(1), defaults: harness.defaults)
        let later = now.addingTimeInterval(HighSoonAdvisoryPolicy.minimumInterval)
        harness.evaluate(try outcome(at: later), at: later)
        XCTAssertEqual(harness.requests.count, 2)
        harness.completions[0](nil)
        await drainCallbacks()
        XCTAssertEqual(harness.clearCount, 0)
        XCTAssertEqual(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey) as? Date, later)
        harness.completions[1](nil)
        await drainCallbacks()
        XCTAssertEqual(harness.clearCount, 0)
        XCTAssertEqual(harness.defaults.object(forKey: HighSoonAdvisoryPolicy.lastScheduledKey) as? Date, later)
    }

    func testSelectiveSilenceRejectsOrdinaryAttachmentRetryAfterPauseAlreadyEnded() async throws {
        let harness = Harness()
        defer { harness.finish() }
        let context = try XCTUnwrap(harness.manager.quietRequestContext(for: .veryhigh))
        var retries = 0
        SelectiveAlarmSilence.toggle(defaults: harness.defaults)
        SelectiveAlarmSilence.toggle(defaults: harness.defaults)
        harness.manager.handleNotificationReply(for: .veryhigh, context: context) { retries += 1 }
        await drainCallbacks()
        XCTAssertEqual(retries, 0, "An old async failure cannot create an attachment-free alarm after the pause")
        let newer = try XCTUnwrap(harness.manager.quietRequestContext(for: .veryhigh))
        harness.manager.handleNotificationReply(for: .veryhigh, context: context) { retries += 100 }
        harness.manager.handleNotificationReply(for: .veryhigh, context: newer) { retries += 1 }
        await drainCallbacks()
        XCTAssertEqual(retries, 1)
    }

    func testSelectiveSilenceLeavesLowAndMissingDataRepliesOutsideQuietCancellation() {
        let harness = Harness()
        defer { harness.finish() }
        SelectiveAlarmSilence.toggle(defaults: harness.defaults)
        var delivered: [AlertKind] = []
        for kind in [AlertKind.verylow, .low, .lowSoon, .missedreading, .sensorTransmitterFailure] {
            let context = harness.manager.quietRequestContext(for: kind)
            XCTAssertNil(context)
            harness.manager.handleNotificationReply(for: kind, context: context) { delivered.append(kind) }
        }
        XCTAssertEqual(delivered, [.verylow, .low, .lowSoon, .missedreading, .sensorTransmitterFailure])
    }

    func testSelectiveSilenceStopsOnlySelectedCurrentlyPlayingAlarmSound() {
        for kind in [AlertKind.high, .veryhigh, .fastrise, .low, .verylow, .lowSoon, .sensorTransmitterFailure] {
            let player = PreviewSoundPlayer()
            let harness = Harness(soundPlayer: player)
            defer { harness.finish() }
            harness.type.soundname = nil
            harness.manager.applyImmediatePresentation(from: harness.type,
                to: UNMutableNotificationContent(), kind: kind)
            XCTAssertTrue(player.isPlaying())
            SelectiveAlarmSilence.toggle(defaults: harness.defaults)
            XCTAssertEqual(player.isPlaying(), !SelectiveAlarmSilence.kinds.contains(kind))
            XCTAssertEqual(player.stopCount, SelectiveAlarmSilence.kinds.contains(kind) ? 1 : 0)
        }
    }

    func testUserHighSnoozePickerUsesExactDeadlineAndPreservesProtectedSnoozes() throws {
        let contents: [UNNotificationContent?] = [nil, UNMutableNotificationContent()]
        for kind in [AlertKind.high, .veryhigh] {
            for content in contents {
                let harness = Harness()
                defer { harness.finish() }
                let protected: [AlertKind] = [.low, .verylow, .lowSoon, .missedreading, .sensorTransmitterFailure]
                let baseline = Date().addingTimeInterval(-60)
                for protectedKind in protected {
                    let snooze = harness.manager.getSnoozeParameters(alertKind: protectedKind)
                    snooze.snoozeTimeStamp = baseline
                    snooze.snoozePeriodInMinutes = 15
                }
                try harness.core.mainManagedObjectContext.save()
                var confirmations = 0
                let picker = harness.manager.createPickerViewData(forAlertKind: kind, content: content,
                    actionHandler: { confirmations += 1 }, cancelHandler: nil)
                XCTAssertNil(SelectiveAlarmSilence.until(defaults: harness.defaults),
                    "Opening a picker must not silence anything")
                picker.actionHandler(try XCTUnwrap(ConstantsAlerts.snoozeValueMinutes.firstIndex(of: 30)))
                let snooze = harness.manager.getSnoozeParameters(alertKind: kind)
                let startedAt = try XCTUnwrap(snooze.snoozeTimeStamp)
                XCTAssertEqual(snooze.snoozePeriodInMinutes, 30)
                XCTAssertEqual(SelectiveAlarmSilence.until(defaults: harness.defaults),
                    startedAt.addingTimeInterval(30 * 60), "Both pauses use the same actual deadline")
                XCTAssertEqual(confirmations, 1)
                for protectedKind in protected {
                    let unchanged = harness.manager.getSnoozeParameters(alertKind: protectedKind)
                    XCTAssertEqual(unchanged.snoozeTimeStamp, baseline)
                    XCTAssertEqual(unchanged.snoozePeriodInMinutes, 15)
                    XCTAssertFalse(SelectiveAlarmSilence.suppresses(protectedKind, defaults: harness.defaults))
                }
                XCTAssertNil(harness.defaults.snoozeAllAlertsUntilDate)
                XCTAssertTrue(try harness.core.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest()).isEmpty)
            }
        }
    }

    func testCancelingHighPickerAndConfirmingOtherKindsNeverStartSelectiveSilence() throws {
        let harness = Harness()
        defer { harness.finish() }
        for kind in [AlertKind.high, .veryhigh] {
            let picker = harness.manager.createPickerViewData(forAlertKind: kind,
                content: UNMutableNotificationContent(), actionHandler: nil, cancelHandler: nil)
            picker.cancelHandler?()
            XCTAssertNil(SelectiveAlarmSilence.until(defaults: harness.defaults))
            XCTAssertNil(harness.manager.getSnoozeParameters(alertKind: kind).snoozeTimeStamp)
        }
        for kind in [AlertKind.low, .verylow, .lowSoon, .fastrise, .fastdrop, .calibration] {
            let picker = harness.manager.createPickerViewData(forAlertKind: kind,
                content: UNMutableNotificationContent(), actionHandler: nil, cancelHandler: nil)
            picker.actionHandler(try XCTUnwrap(ConstantsAlerts.snoozeValueMinutes.firstIndex(of: 30)))
            XCTAssertEqual(harness.manager.getSnoozeParameters(alertKind: kind).snoozePeriodInMinutes, 30)
            XCTAssertNil(SelectiveAlarmSilence.until(defaults: harness.defaults),
                "Only an explicit high/very-high action starts the shared pause")
        }
        XCTAssertTrue(try harness.core.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest()).isEmpty)
    }

    func testProgrammaticHighSnoozeNeverStartsSelectiveSilence() {
        let harness = Harness()
        defer { harness.finish() }
        for kind in [AlertKind.high, .veryhigh, .fastrise, .fastdrop] {
            harness.manager.snooze(alertKind: kind, snoozePeriodInMinutes: 5, response: nil)
            XCTAssertTrue(harness.manager.getSnoozeParameters(alertKind: kind).getSnoozeValue().isSnoozed)
            XCTAssertNil(SelectiveAlarmSilence.until(defaults: harness.defaults),
                "Automatic throttling and programmatic snoozes are not user confirmation")
        }
    }

    func testRepeatedUserHighSnoozeCannotToggleOrShortenPauseAndSurvivesRestart() throws {
        let harness = Harness()
        defer { harness.finish() }
        let picker = harness.manager.createPickerViewData(forAlertKind: .high,
            content: UNMutableNotificationContent(), actionHandler: nil, cancelHandler: nil)
        picker.actionHandler(try XCTUnwrap(ConstantsAlerts.snoozeValueMinutes.firstIndex(of: 120)))
        let expiry = try XCTUnwrap(SelectiveAlarmSilence.until(defaults: harness.defaults))
        let revision = SelectiveAlarmSilence.revision(defaults: harness.defaults)
        picker.actionHandler(try XCTUnwrap(ConstantsAlerts.snoozeValueMinutes.firstIndex(of: 10)))
        XCTAssertEqual(SelectiveAlarmSilence.until(defaults: harness.defaults), expiry)
        XCTAssertNotEqual(SelectiveAlarmSilence.revision(defaults: harness.defaults), revision)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: harness.suiteName))
        XCTAssertEqual(SelectiveAlarmSilence.until(defaults: reopened), expiry)
        reopened.set(30, forKey: SelectiveAlarmSilence.durationKey)
        XCTAssertEqual(SelectiveAlarmSilence.until(defaults: reopened), expiry)
        XCTAssertTrue(SelectiveAlarmSilence.isActive(at: expiry.addingTimeInterval(-0.001), defaults: reopened))
        XCTAssertFalse(SelectiveAlarmSilence.isActive(at: expiry, defaults: reopened))
        SelectiveAlarmSilence.end(at: expiry.addingTimeInterval(1), defaults: reopened)
        XCTAssertNil(SelectiveAlarmSilence.until(defaults: reopened))
        XCTAssertEqual(harness.manager.getSnoozeParameters(alertKind: .high).snoozePeriodInMinutes, 10,
            "Ending Lydløs must not erase the separate per-alarm snooze")
    }

    func testExplicitSelectiveSilenceRejectsInvalidDeadlinesAndRetainsExistingPause() {
        let harness = Harness()
        defer { harness.finish() }
        let expiry = now.addingTimeInterval(30 * 60)
        SelectiveAlarmSilence.start(until: expiry, at: now, defaults: harness.defaults)
        let revision = SelectiveAlarmSilence.revision(defaults: harness.defaults)
        for invalid in [now, now.addingTimeInterval(-1), now.addingTimeInterval(7 * 24 * 60 * 60 + 1),
                        Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity)] {
            SelectiveAlarmSilence.start(until: invalid, at: now, defaults: harness.defaults)
            XCTAssertEqual(SelectiveAlarmSilence.until(defaults: harness.defaults), expiry)
            XCTAssertEqual(SelectiveAlarmSilence.revision(defaults: harness.defaults), revision)
        }
        SelectiveAlarmSilence.start(until: expiry, at: Date(timeIntervalSince1970: .nan), defaults: harness.defaults)
        XCTAssertEqual(SelectiveAlarmSilence.revision(defaults: harness.defaults), revision)
        let week = now.addingTimeInterval(7 * 24 * 60 * 60)
        SelectiveAlarmSilence.start(until: week, at: now, defaults: harness.defaults)
        XCTAssertEqual(SelectiveAlarmSilence.until(defaults: harness.defaults), week,
            "An existing supported one-week snooze is not silently shortened")
    }

    func testStaleHighPickerConfirmationAndCancelPreserveNewerProtectedAlarmSound() throws {
        for highKind in [AlertKind.high, .veryhigh] {
            for playingKind in [AlertKind.low, .verylow, .lowSoon, .missedreading, .sensorTransmitterFailure] {
                let player = PreviewSoundPlayer()
                let harness = Harness(soundPlayer: player)
                defer { harness.finish() }
                let picker = harness.manager.createPickerViewData(forAlertKind: highKind,
                    content: UNMutableNotificationContent(), actionHandler: nil, cancelHandler: nil)
                harness.type.soundname = nil
                harness.manager.applyImmediatePresentation(from: harness.type,
                    to: UNMutableNotificationContent(), kind: playingKind)
                XCTAssertTrue(player.isPlaying())
                picker.cancelHandler?()
                XCTAssertTrue(player.isPlaying(), "Canceling the old high picker must preserve a newer protected alarm")
                XCTAssertNil(SelectiveAlarmSilence.until(defaults: harness.defaults))
                picker.actionHandler(try XCTUnwrap(ConstantsAlerts.snoozeValueMinutes.firstIndex(of: 30)))
                XCTAssertTrue(player.isPlaying(), "Confirming high snooze must not stop the protected alarm")
                XCTAssertEqual(player.stopCount, 0)
                XCTAssertTrue(SelectiveAlarmSilence.isActive(defaults: harness.defaults))
            }
        }
    }

    func testUserHighSnoozeInvalidatesPendingHighReplyWhileProtectedRepliesRemainValid() async throws {
        let harness = Harness()
        defer { harness.finish() }
        let highContext = try XCTUnwrap(harness.manager.quietRequestContext(for: .veryhigh))
        let protected: [AlertKind] = [.low, .verylow, .lowSoon, .missedreading, .sensorTransmitterFailure]
        let protectedContexts = protected.map { harness.manager.quietRequestContext(for: $0) }
        let picker = harness.manager.createPickerViewData(forAlertKind: .high,
            content: UNMutableNotificationContent(), actionHandler: nil, cancelHandler: nil)
        picker.actionHandler(try XCTUnwrap(ConstantsAlerts.snoozeValueMinutes.firstIndex(of: 30)))
        SelectiveAlarmSilence.end(defaults: harness.defaults)
        var highRetries = 0
        var protectedReplies: [AlertKind] = []
        harness.manager.handleNotificationReply(for: .veryhigh, context: highContext) { highRetries += 1 }
        for (kind, context) in zip(protected, protectedContexts) {
            XCTAssertNil(context)
            harness.manager.handleNotificationReply(for: kind, context: context) { protectedReplies.append(kind) }
        }
        await drainCallbacks()
        XCTAssertEqual(highRetries, 0, "Ending the pause cannot revive an already invalidated high request")
        XCTAssertEqual(protectedReplies, protected)
    }

    private func drainCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private final class PreviewSoundPlayer: SoundPlayer {
        var played: [String] = []
        var stopCount = 0
        private var playing = false

        override func playSound(soundFileName: String) {
            played.append(soundFileName)
            playing = true
        }

        override func isPlaying() -> Bool { playing }

        override func stopPlaying() {
            stopCount += 1
            playing = false
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

        init(soundPlayer: SoundPlayer? = nil) {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set(false, forKey: UserDefaults.Key.bloodGlucoseUnitIsMgDl.rawValue)
            type = AlertType(enabled: true, name: "Synthetic high rule", overrideMute: true,
                snooze: true, snoozePeriod: 15, vibrate: true, soundName: "", alertEntries: nil,
                nsManagedObjectContext: core.mainManagedObjectContext)
            entry = AlertEntry(isDisabled: false, value: 180, triggerValue: 0, alertKind: .high,
                start: 0, alertType: type, nsManagedObjectContext: core.mainManagedObjectContext)
            manager = AlertManager(coreDataManager: core, soundPlayer: soundPlayer, silenceDefaults: defaults)
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
