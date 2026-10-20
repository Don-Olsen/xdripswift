//
//  BasalInjectionTests.swift
//  xdripTests
//
//  Created by Paul Plant on 7/9/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
import UIKit
import SwiftUI
import UserNotifications
@testable import xdrip

final class BasalInjectionTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_788_804_000)

    func testBasalReminderDefaultsOffAndPersistsClockTime() {
        let suiteName = "BasalReminderSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(BasalReminderSettings.load(from: defaults),
                       BasalReminderSettings(isEnabled: false, minuteOfDay: 20 * 60))
        BasalReminderSettings(isEnabled: true, minuteOfDay: 21 * 60 + 15).persist(to: defaults)
        XCTAssertEqual(BasalReminderSettings.load(from: defaults),
                       BasalReminderSettings(isEnabled: true, minuteOfDay: 21 * 60 + 15))
        BasalReminderSettings(isEnabled: false, minuteOfDay: 21 * 60 + 15).persist(to: defaults)
        XCTAssertFalse(BasalReminderSettings.load(from: defaults).isEnabled)
    }

    func testBasalReminderTwelveHourBoundaryAndDeletedOrEditedDose() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Copenhagen"))
        let due = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 5,
                                                                    hour: 20, minute: 0)))
        let now = due.addingTimeInterval(-60 * 60)
        let settings = BasalReminderSettings(isEnabled: true, minuteOfDay: 20 * 60)
        let boundary = try XCTUnwrap(BasalReminderInjection(date: due.addingTimeInterval(-12 * 60 * 60),
                                                             units: 20, insulinDescription: "Tresiba"))
        let beforeBoundary = try XCTUnwrap(BasalReminderInjection(date: boundary.date.addingTimeInterval(-1),
                                                                   units: 20, insulinDescription: "Tresiba"))
        XCTAssertTrue(BasalReminderPlanner.plan(now: now, settings: settings,
            injections: [boundary], calendar: calendar, horizonDays: 1).isEmpty)
        XCTAssertEqual(BasalReminderPlanner.plan(now: now, settings: settings,
            injections: [beforeBoundary], calendar: calendar, horizonDays: 1).count, 1)
        // An edit moves the persisted treatment into the window; deletion removes it again.
        let edited = try XCTUnwrap(BasalReminderInjection(date: due.addingTimeInterval(-30 * 60),
                                                           units: 22, insulinDescription: "Lantus"))
        XCTAssertTrue(BasalReminderPlanner.plan(now: now, settings: settings,
            injections: [edited], calendar: calendar, horizonDays: 1).isEmpty)
        XCTAssertEqual(BasalReminderPlanner.plan(now: now, settings: settings,
            injections: [], calendar: calendar, horizonDays: 1).count, 1)
    }

    func testBasalReminderCalendarUsesOneLocalOccurrenceAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Copenhagen"))
        let settings = BasalReminderSettings(isEnabled: true, minuteOfDay: 2 * 60 + 30)
        let springNow = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-28T00:00:00Z"))
        let spring = BasalReminderPlanner.plan(now: springNow, settings: settings,
                                                injections: [], calendar: calendar, horizonDays: 3)
        XCTAssertEqual(spring.map(\.dayKey), ["2026-03-28", "2026-03-29", "2026-03-30"])
        XCTAssertEqual(calendar.component(.hour, from: spring[1].dueAt), 3)
        XCTAssertEqual(Set(spring.map(\.dayKey)).count, 3)

        let fallNow = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-24T00:00:00Z"))
        let fall = BasalReminderPlanner.plan(now: fallNow, settings: settings,
                                              injections: [], calendar: calendar, horizonDays: 3)
        XCTAssertEqual(fall.map(\.dayKey), ["2026-10-24", "2026-10-25", "2026-10-26"])
        XCTAssertEqual(calendar.component(.hour, from: fall[1].dueAt), 2)
        XCTAssertEqual(calendar.timeZone.secondsFromGMT(for: fall[1].dueAt), 2 * 60 * 60)
        XCTAssertEqual(Set(fall.map(\.dayKey)).count, 3)
    }

    func testBasalReminderTimeZoneReplansAtSameLocalHour() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-05T06:00:00Z"))
        let settings = BasalReminderSettings(isEnabled: true, minuteOfDay: 20 * 60)
        var copenhagen = Calendar(identifier: .gregorian)
        copenhagen.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Copenhagen"))
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let danishDue = try XCTUnwrap(BasalReminderPlanner.plan(now: now, settings: settings,
            injections: [], calendar: copenhagen, horizonDays: 1).first?.dueAt)
        let americanDue = try XCTUnwrap(BasalReminderPlanner.plan(now: now, settings: settings,
            injections: [], calendar: newYork, horizonDays: 1).first?.dueAt)
        XCTAssertEqual(copenhagen.component(.hour, from: danishDue), 20)
        XCTAssertEqual(newYork.component(.hour, from: americanDue), 20)
        XCTAssertEqual(americanDue.timeIntervalSince(danishDue), 6 * 60 * 60)
    }

    @MainActor func testBasalReminderSnoozeOnlyOnceAndStopsAfterSavedDose() throws {
        let due = Date(timeIntervalSince1970: 1_791_220_000)
        let dayKey = "2026-10-05"
        let now = due.addingTimeInterval(60)
        XCTAssertTrue(BasalReminderPlanner.canSnooze(dayKey: dayKey, dueAt: due, now: now,
            alreadySnoozed: [], injections: []))
        XCTAssertFalse(BasalReminderPlanner.canSnooze(dayKey: dayKey, dueAt: due, now: now,
            alreadySnoozed: [dayKey], injections: []))
        let saved = try XCTUnwrap(BasalReminderInjection(date: now, units: 20,
                                                         insulinDescription: "Tresiba"))
        XCTAssertFalse(BasalReminderPlanner.canSnooze(dayKey: dayKey, dueAt: due, now: now,
            alreadySnoozed: [], injections: [saved]))
        XCTAssertEqual(BasalReminderScheduler.dailyIdentifier(for: dayKey),
                       "xdrip.basalReminder.day.2026-10-05")
        XCTAssertEqual(BasalReminderScheduler.snoozeIdentifier(for: dayKey),
                       "xdrip.basalReminder.snooze.2026-10-05")
    }

    func testBasalSnoozeActionSurvivesColdStartUntilStoreIsReady() throws {
        let suiteName = "BasalPendingSnoozeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = Date(timeIntervalSince1970: 1_791_220_000)
        let otherDay = first.addingTimeInterval(24 * 60 * 60)
        BasalReminderPendingSnoozes.enqueue(dayKey: "2026-10-05", dueAt: first, defaults: defaults)
        BasalReminderPendingSnoozes.enqueue(dayKey: "2026-10-05",
                                             dueAt: first.addingTimeInterval(60), defaults: defaults)
        BasalReminderPendingSnoozes.enqueue(dayKey: "2026-10-06", dueAt: otherDay, defaults: defaults)
        // A new reader after cold-start configuration sees the original action exactly once.
        let restored = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(BasalReminderPendingSnoozes.load(defaults: restored),
                       ["2026-10-05": first, "2026-10-06": otherDay])
        BasalReminderPendingSnoozes.remove(dayKey: "2026-10-05", defaults: restored)
        XCTAssertEqual(BasalReminderPendingSnoozes.load(defaults: defaults),
                       ["2026-10-06": otherDay])
    }

    @MainActor func testBasalReminderNotificationUsesHistoricDoseAndOneShotCalendarTrigger() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Copenhagen"))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-05T06:00:00Z"))
        let past = try XCTUnwrap(BasalReminderInjection(date: now.addingTimeInterval(-24 * 60 * 60),
                                                        units: 20, insulinDescription: "Tresiba"))
        let occurrence = try XCTUnwrap(BasalReminderPlanner.plan(now: now,
            settings: BasalReminderSettings(isEnabled: true, minuteOfDay: 20 * 60),
            injections: [past], calendar: calendar, horizonDays: 1).first)
        let request = BasalReminderScheduler.dailyRequest(for: occurrence, calendar: calendar)
        XCTAssertEqual(request.content.title, "Husk basal")
        XCTAssertEqual(request.content.body, "Senest registreret: 20 E Tresiba")
        XCTAssertEqual(request.identifier, BasalReminderScheduler.dailyIdentifier(for: "2026-10-05"))
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertFalse(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents.hour, 20)
        XCTAssertEqual(trigger.dateComponents.minute, 0)
        XCTAssertEqual(trigger.dateComponents.timeZone, calendar.timeZone)
    }

    func testBasalReminderPermissionIsShownWhenNotGranted() {
        XCTAssertFalse(BasalReminderPermission.isAvailable(.notDetermined))
        XCTAssertFalse(BasalReminderPermission.isAvailable(.denied))
        XCTAssertTrue(BasalReminderPermission.isAvailable(.authorized))
        XCTAssertTrue(BasalReminderPermission.isAvailable(.provisional))
    }

    @MainActor func testBasalReminderOpensPrefilledDraftWithoutWritingTreatment() throws {
        try withRestoredDefaults {
            let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
            let older = Date().addingTimeInterval(-36 * 60 * 60)
            _ = TreatmentEntry(date: older, value: 18, treatmentType: .BasalInjection,
                               nightscoutEventType: "Note", enteredBy: "Test", notes: "Lantus",
                               nsManagedObjectContext: core.mainManagedObjectContext)
            let latest = TreatmentEntry(date: Date().addingTimeInterval(-24 * 60 * 60), value: 20,
                                        treatmentType: .BasalInjection, nightscoutEventType: "Note",
                                        enteredBy: "Test", notes: "Tresiba",
                                        nsManagedObjectContext: core.mainManagedObjectContext)
            let deleted = TreatmentEntry(date: Date().addingTimeInterval(-60 * 60), value: 30,
                                         treatmentType: .BasalInjection, nightscoutEventType: "Note",
                                         enteredBy: "Test", notes: "Deleted",
                                         nsManagedObjectContext: core.mainManagedObjectContext)
            deleted.treatmentdeleted = true
            XCTAssertTrue(core.saveChangesSynchronously())
            UserDefaults.standard.lastBasalInjectionUnits = 99
            UserDefaults.standard.lastBasalInjectionInsulinDescription = "Stale"
            XCTAssertTrue(BasalReminderScheduler.prepareDraftPrefill(coreDataManager: core))
            let draft = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: nil,
                                                 initialType: .BasalInjection)
            XCTAssertEqual(draft.enteredValue, "20")
            XCTAssertEqual(draft.enteredInsulinDescription, "Tresiba")
            XCTAssertEqual(latest.value, 20)
            XCTAssertEqual(try BasalReminderScheduler.storedInjections(coreDataManager: core).count, 2)
            XCTAssertEqual(TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil).count, 3)
            // Merely constructing and dismissing the draft cannot insert another treatment.
        }
    }

    /// Use the reported Note verbatim through the same JSON parser and storage path as follower sync.
    @MainActor func testReportedLantusNoteImportsAsBasalInjection() throws {
        let notes = """
        Basal injection: Lantus, 14 U

        ---------
        xDrip4iOS:BasalInjection:eyJpbnN1bGluRGVzY3JpcHRpb24iOiJMYW50dXMiLCJ1bml0cyI6MTQsInZlcnNpb24iOjF9
        """
        let data = try JSONSerialization.data(withJSONObject: [document(notes: notes)])
        let responses = try XCTUnwrap(TreatmentNSResponse.arrayFromData(data))
        XCTAssertEqual(responses.count, 1)
        let response = try XCTUnwrap(responses.first)
        XCTAssertEqual(response.eventType, .BasalInjection)
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let entry = try XCTUnwrap(response.asNewTreatmentEntry(nsManagedObjectContext: coreDataManager.mainManagedObjectContext))
        let snapshot = TreatmentSnapshot(treatmentEntry: entry)
        XCTAssertEqual(snapshot.treatmentType, .BasalInjection)
        XCTAssertEqual(snapshot.valueText, "14")
        XCTAssertEqual(snapshot.unitText, "U")
        XCTAssertEqual(entry.notes, "Lantus")
    }

    /// Missing from a bulk download is not enough: only a successful empty exact-id result deletes.
    @MainActor func testRemoteDeletionRequiresConfirmedAbsence() {
        for (body, succeeded, shouldDelete) in [("[]", true, true), ("[]", false, false), ("[{\"_id\":\"still-present\"}]", true, false), ("{}", true, false), ("invalid", true, false)] {
            let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
            let manager = NightscoutSyncManager(coreDataManager: coreDataManager, messageHandler: nil)
            let remoteID = "6cd9bfc2-1eb0-4fdd-890d-59c47067d9e6"
            let entry = TreatmentEntry(id: remoteID + "-note", date: Date(), value: 14, treatmentType: .BasalInjection, nightscoutEventType: "Note", enteredBy: "Test", notes: "Lantus", nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
            var completed = false
            manager.reconcileRemoteTreatmentDeletions(treatments: [entry], downloaded: [], lookup: { id, finished in
                XCTAssertEqual(id, remoteID)
                finished(Data(body.utf8), succeeded)
            }) { count in
                completed = true
                XCTAssertEqual(count, shouldDelete ? 1 : 0)
            }
            XCTAssertTrue(completed)
            XCTAssertEqual(entry.treatmentdeleted, shouldDelete)
            XCTAssertTrue(entry.uploaded)
        }
    }

    /// Local edits remain authoritative while waiting for confirmation from Nightscout.
    @MainActor func testRemoteDeletionPreservesAnEditMadeDuringLookup() {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let manager = NightscoutSyncManager(coreDataManager: coreDataManager, messageHandler: nil)
        let entry = TreatmentEntry(id: "basal-note", date: Date(), value: 14, treatmentType: .BasalInjection, nightscoutEventType: "Note", enteredBy: "Test", notes: "Lantus", nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
        manager.reconcileRemoteTreatmentDeletions(treatments: [entry], downloaded: [], lookup: { _, finished in
            entry.value = 15
            entry.uploaded = false
            finished(Data("[]".utf8), true)
        }) { count in
            XCTAssertEqual(count, 0)
        }
        XCTAssertFalse(entry.treatmentdeleted)
        XCTAssertFalse(entry.uploaded)
    }

    /// Present records and unsynced local entries do not need a remote absence check.
    @MainActor func testRemoteDeletionDoesNotLookUpPresentOrUnsyncedTreatments() {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let manager = NightscoutSyncManager(coreDataManager: coreDataManager, messageHandler: nil)
        let present = TreatmentEntry(id: "present-note", date: Date(), value: 14, treatmentType: .BasalInjection, nightscoutEventType: "Note", enteredBy: "Test", notes: "Lantus", nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
        let local = TreatmentEntry(date: Date(), value: 14, treatmentType: .BasalInjection, nightscoutEventType: "Note", enteredBy: "Test", notes: "Lantus", nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
        let response = TreatmentNSResponse(id: present.id, createdAt: present.date, eventType: .BasalInjection, nightscoutEventType: "Note", value: 14, valueSecondary: nil, enteredBy: "Test", notes: "Lantus")
        manager.reconcileRemoteTreatmentDeletions(treatments: [present, local], downloaded: [response], lookup: { _, _ in
            XCTFail("No lookup should be needed")
        }) { count in
            XCTAssertEqual(count, 0)
        }
        XCTAssertFalse(present.treatmentdeleted)
        XCTAssertFalse(local.treatmentdeleted)
    }

    func testPayloadRoundTripIgnoresReadableSummary() throws {
        let payload = try XCTUnwrap(BasalInjectionPayload(units: 20, insulinDescription: "Tresiba"))
        let notes = try XCTUnwrap(payload.encodedNotes())
        XCTAssertTrue(notes.hasPrefix("Basal injection: Tresiba, 20 U\n\n---------\n"))
        let changedSummary = notes.replacingOccurrences(of: "Basal injection: Tresiba, 20 U", with: "Texto cambiado: 99 U")
        XCTAssertEqual(BasalInjectionPayload.decode(from: changedSummary), payload)
    }

    func testFractionalNonFiniteAndNonPositiveDosesAreRejected() {
        for units in [0.0, -1, 20.5, .nan, .infinity, Double.greatestFiniteMagnitude] {
            XCTAssertNil(BasalInjectionPayload(units: units, insulinDescription: "Tresiba"))
        }
    }

    func testMalformedFutureAndFractionalPayloadsRemainNotes() throws {
        let invalidNotes = [
            "Basal injection: Tresiba, 20 U",
            BasalInjectionPayload.prefix + "invalid",
            envelope(#"{"version":2,"units":20,"insulinDescription":"Tresiba"}"#),
            envelope(#"{"version":1,"units":20.5,"insulinDescription":"Tresiba"}"#),
            envelope(#"{"version":1,"units":0,"insulinDescription":"Tresiba"}"#)
        ]
        for notes in invalidNotes {
            XCTAssertNil(BasalInjectionPayload.decode(from: notes))
            let responses = TreatmentNSResponse.fromNightscout(dictionary: document(notes: notes))
            XCTAssertEqual(responses.count, 1)
            XCTAssertEqual(responses.first?.eventType, .Note)
            XCTAssertEqual(responses.first?.notes, notes)
        }
    }

    func testRecognisedNoteProducesOnlyOneInjectionEvenWithNumericFields() throws {
        let notes = try XCTUnwrap(BasalInjectionPayload(units: 20, insulinDescription: "Tresiba")?.encodedNotes())
        let input = document(notes: notes).mutableCopy() as! NSMutableDictionary
        input["insulin"] = 20
        input["carbs"] = 10
        let responses = TreatmentNSResponse.fromNightscout(dictionary: input)
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.eventType, .BasalInjection)
        XCTAssertEqual(responses.first?.value, 20)
        XCTAssertEqual(responses.first?.notes, "Tresiba")
        XCTAssertEqual(responses.first?.id, "basaltest-note")
    }

    @MainActor func testUploadRoundTripOmitsActiveInsulinAndPumpBasalFields() throws {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let entry = TreatmentEntry(date: date, value: 20, treatmentType: .BasalInjection, nightscoutEventType: nil, enteredBy: "Test", notes: "Tresiba", nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
        var upload = entry.dictionaryRepresentationForNightscoutUpload()
        XCTAssertEqual(upload["eventType"] as? String, "Note")
        for key in ["insulin", "rate", "absolute", "duration"] {
            XCTAssertNil(upload[key], "Basal injection must omit \(key)")
        }
        upload["_id"] = "basaltest"
        let response = try XCTUnwrap(TreatmentNSResponse.fromNightscout(dictionary: upload as NSDictionary).first)
        XCTAssertTrue(response.matchesTreatmentEntry(entry))
        XCTAssertEqual(response.eventType, .BasalInjection)
    }

    @MainActor func testDraftDefaultsRequireSaveAndRemainEditable() throws {
        try withRestoredDefaults {
            UserDefaults.standard.lastBasalInjectionUnits = 20
            UserDefaults.standard.lastBasalInjectionInsulinDescription = "Tresiba"
            let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
            let draft = TreatmentEditorViewModel(coreDataManager: coreDataManager, treatmentToEdit: nil, initialType: .BasalInjection)
            XCTAssertTrue(draft.didPrefillBasalInjection)
            XCTAssertEqual(draft.enteredValue, "20")
            XCTAssertEqual(draft.enteredInsulinDescription, "Tresiba")
            draft.enteredValue = "22"
            draft.enteredInsulinDescription = "Lantus"
            XCTAssertEqual(UserDefaults.standard.lastBasalInjectionUnits, 20)
            XCTAssertEqual(UserDefaults.standard.lastBasalInjectionInsulinDescription, "Tresiba")
            XCTAssertTrue(draft.saveTreatment())
            XCTAssertEqual(UserDefaults.standard.lastBasalInjectionUnits, 22)
            XCTAssertEqual(UserDefaults.standard.lastBasalInjectionInsulinDescription, "Lantus")
            let saved = try XCTUnwrap(TreatmentEntryAccessor(coreDataManager: coreDataManager).getLatestTreatments(howOld: nil).first)
            XCTAssertEqual(saved.treatmentType, .BasalInjection)
            XCTAssertEqual(saved.value, 22)
            XCTAssertEqual(saved.notes, "Lantus")
        }
    }

    @MainActor func testFractionalDraftAndFailedSaveDoNotReplaceDefaults() throws {
        withRestoredDefaults {
            UserDefaults.standard.lastBasalInjectionUnits = 20
            let draft = TreatmentEditorViewModel(coreDataManager: nil, treatmentToEdit: nil, initialType: .BasalInjection)
            for input in ["20.5", "0", "-1"] {
                draft.enteredValue = input
                XCTAssertFalse(draft.canSaveTreatment)
            }
            draft.enteredValue = "22"
            draft.enteredInsulinDescription = "Tresiba"
            XCTAssertTrue(draft.canSaveTreatment)
            XCTAssertFalse(draft.saveTreatment())
            XCTAssertEqual(UserDefaults.standard.lastBasalInjectionUnits, 20)
        }
    }

    @MainActor func testEditUsesSavedInjectionAndDetectsDescriptionOnlyChanges() throws {
        withRestoredDefaults {
            UserDefaults.standard.lastBasalInjectionUnits = 30
            UserDefaults.standard.lastBasalInjectionInsulinDescription = "Lantus"
            let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
            let entry = TreatmentEntry(date: date, value: 20, treatmentType: .BasalInjection, nightscoutEventType: "Note", enteredBy: "Test", notes: "Tresiba", nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
            XCTAssertTrue(coreDataManager.saveChanges())
            let editor = TreatmentEditorViewModel(coreDataManager: coreDataManager, treatmentToEdit: entry)
            XCTAssertFalse(editor.didPrefillBasalInjection)
            XCTAssertEqual(editor.enteredValue, "20")
            XCTAssertEqual(editor.enteredInsulinDescription, "Tresiba")
            XCTAssertFalse(editor.canSaveTreatment)
            editor.enteredInsulinDescription = "Toujeo"
            XCTAssertTrue(editor.canSaveTreatment)
            XCTAssertTrue(editor.saveTreatment())
            XCTAssertEqual(entry.notes, "Toujeo")
            XCTAssertEqual(UserDefaults.standard.lastBasalInjectionInsulinDescription, "Toujeo")
        }
    }

    @MainActor func testInjectionHasIndependentListFilterAndEditablePresentation() throws {
        withRestoredDefaults {
            let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
            let injection = TreatmentEntry(date: Date(), value: 20, treatmentType: .BasalInjection, nightscoutEventType: "Note", enteredBy: "Test", notes: "Tresiba", nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
            _ = TreatmentEntry(date: Date(), value: 0, treatmentType: .Note, nightscoutEventType: "Note", enteredBy: "Test", notes: "Ordinary note", nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
            XCTAssertTrue(coreDataManager.saveChanges())
            UserDefaults.standard.showNoteTreatmentsInList = false
            UserDefaults.standard.showBasalInjectionTreatmentsInList = true
            let model = TreatmentsViewModel(coreDataManager: coreDataManager)
            model.reloadTreatments()
            XCTAssertEqual(model.filteredTreatments.map(\.treatmentType), [.BasalInjection])
            let snapshot = TreatmentSnapshot(treatmentEntry: injection)
            XCTAssertTrue(snapshot.isEditable)
            XCTAssertEqual(snapshot.valueText, "20")
            XCTAssertEqual(snapshot.unitText, "U")
            XCTAssertNil(snapshot.secondaryText)
            XCTAssertEqual(snapshot.iconSystemName, "arrowtriangle.down.fill")
            model.toggleBasalInjectionFilter()
            XCTAssertTrue(model.filteredTreatments.isEmpty)
            model.toggleNoteFilter()
            XCTAssertEqual(model.filteredTreatments.map(\.treatmentType), [.Note])
        }
    }

    @MainActor func testChartKeepsInjectionBelowBolusAndOutsideNoteSeries() async throws {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let treatmentDate = Date().addingTimeInterval(-60)
        _ = TreatmentEntry(date: treatmentDate, value: 3, treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "Test", nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
        _ = TreatmentEntry(date: treatmentDate, value: 20, treatmentType: .BasalInjection, nightscoutEventType: "Note", enteredBy: "Test", notes: "Tresiba", nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
        XCTAssertTrue(coreDataManager.saveChanges())
        let syncManager = NightscoutSyncManager(coreDataManager: coreDataManager, messageHandler: nil)
        let chart = GlucoseChartStateManager(coreDataManager: coreDataManager, nightscoutSyncManager: syncManager)
        let state: GlucoseChartState = await withCheckedContinuation { continuation in
            chart.updateState(endDate: Date(), startDate: treatmentDate.addingTimeInterval(-3600), forceReset: true, showTreatments: true) {
                continuation.resume(returning: $0)
            }
        }
        let injection = try XCTUnwrap(state.treatmentPoints.basalInjections.first)
        let bolus = try XCTUnwrap(state.treatmentPoints.boluses.first)
        XCTAssertEqual(state.treatmentPoints.basalInjections.count, 1)
        XCTAssertTrue(state.treatmentPoints.notes.isEmpty)
        XCTAssertLessThan(injection.yValue, bolus.yValue)
        XCTAssertEqual(injection.label, "20")
        XCTAssertEqual(bolus.label, "3")
        XCTAssertEqual(injection.notes, "Tresiba")

        // Exercise the incremental range merge as well as the initial chart load.
        let scrolled: GlucoseChartState = await withCheckedContinuation { continuation in
            chart.updateState(endDate: Date(), startDate: treatmentDate.addingTimeInterval(-7200), showTreatments: true) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(scrolled.treatmentPoints.basalInjections.count, 1)
    }

    @MainActor func testRecoveryImporterRecognisesInjectionAndDoesNotDuplicateIt() async throws {
        let defaults = UserDefaults.standard
        let keys = ["nightscoutUrl", "nightscoutPort"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.nightscoutUrl = "https://basal-injection-tests.invalid"
        defaults.nightscoutPort = 0
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BasalInjectionTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let importer = NightscoutImportService(coreDataManager: coreDataManager, session: session)
        let timestamp = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T20:00:00Z"))
        let interval = DateInterval(start: timestamp.addingTimeInterval(-60), end: timestamp.addingTimeInterval(60))
        let first = try await importer.mergeTreatments(in: interval)
        XCTAssertEqual(first.treatmentsAdded, 1)
        let second = try await importer.mergeTreatments(in: interval)
        XCTAssertEqual(second.treatmentsAdded, 0)
        let treatments = TreatmentEntryAccessor(coreDataManager: coreDataManager).getLatestTreatments(howOld: nil)
        XCTAssertEqual(treatments.count, 1)
        XCTAssertEqual(treatments.first?.treatmentType, .BasalInjection)
        XCTAssertEqual(treatments.first?.value, 20)
        XCTAssertEqual(treatments.first?.notes, "Tresiba")
    }

    @MainActor func testBasalInjectionRequiresBothFieldsBeforeSaving() {
        withRestoredDefaults {
            let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
            let draft = TreatmentEditorViewModel(coreDataManager: coreDataManager, treatmentToEdit: nil, initialType: .BasalInjection)
            draft.enteredValue = "20"
            for description in ["", "   ", "\n"] {
                draft.enteredInsulinDescription = description
                XCTAssertFalse(draft.canSaveTreatment)
                XCTAssertFalse(draft.saveTreatment())
            }
            draft.enteredInsulinDescription = "Tresiba"
            draft.enteredValue = ""
            XCTAssertFalse(draft.canSaveTreatment)
            draft.enteredValue = "20"
            XCTAssertTrue(draft.canSaveTreatment)
        }
    }

    func testNativeTreatmentSymbolsExistInFilledAndUnfilledForms() {
        for symbol in [GlucoseChartTreatmentStyle.bolusSymbol, GlucoseChartTreatmentStyle.carbsSymbol, GlucoseChartTreatmentStyle.basalInjectionSymbol, GlucoseChartTreatmentStyle.bgCheckSymbol, GlucoseChartTreatmentStyle.noteSymbol] {
            XCTAssertNotNil(UIImage(systemName: symbol), symbol)
            let unfilled = symbol.replacingOccurrences(of: ".fill", with: "")
            XCTAssertNotNil(UIImage(systemName: unfilled), unfilled)
        }
    }

    @MainActor func testEditingAfterTemporaryObjectIDChangesDoesNotInsertTreatment() throws {
        try withRestoredDefaults {
            UserDefaults.standard.nightscoutEnabled = false
            let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
            let entry = TreatmentEntry(date: Date(), value: 20, treatmentType: .BasalInjection, nightscoutEventType: "Note", enteredBy: "Test", notes: "Tresiba", nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
            XCTAssertTrue(entry.objectID.isTemporaryID)
            let editor = TreatmentEditorViewModel(coreDataManager: coreDataManager, treatmentToEdit: entry)

            // A treatment can be shown while its parent-context save is still pending. Reproduce
            // the identity promotion after the editor has captured the original temporary ID.
            try coreDataManager.mainManagedObjectContext.obtainPermanentIDs(for: [entry])
            XCTAssertFalse(entry.objectID.isTemporaryID)
            XCTAssertTrue(coreDataManager.saveChangesSynchronously())
            editor.enteredValue = "22"
            XCTAssertTrue(editor.saveTreatment())
            let entries = TreatmentEntryAccessor(coreDataManager: coreDataManager).getLatestTreatments(howOld: nil)
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entry.value, 22)
        }
    }

    @MainActor func testTreatmentListPublishesPermanentIDsForPendingLocalEntries() throws {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let entry = TreatmentEntry(date: Date(), value: 20, treatmentType: .BasalInjection, nightscoutEventType: nil, enteredBy: "Test", notes: "Tresiba", nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
        XCTAssertTrue(entry.objectID.isTemporaryID)
        let model = TreatmentsViewModel(coreDataManager: coreDataManager)
        model.reloadTreatments()
        XCTAssertFalse(entry.objectID.isTemporaryID)
        XCTAssertTrue(coreDataManager.saveChangesSynchronously())
        let resolved = TreatmentEntryAccessor(coreDataManager: coreDataManager).getTreatment(objectID: entry.objectID)
        XCTAssertTrue(resolved === entry)
    }

    @MainActor func testDeletedEditTargetCannotBecomeANewTreatment() {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let entry = TreatmentEntry(date: Date(), value: 3, treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "Test", nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
        let editor = TreatmentEditorViewModel(coreDataManager: coreDataManager, treatmentToEdit: entry)
        coreDataManager.mainManagedObjectContext.delete(entry)
        XCTAssertTrue(coreDataManager.saveChangesSynchronously())
        editor.enteredValue = "4"
        XCTAssertFalse(editor.isAddMode)
        XCTAssertFalse(editor.saveTreatment())
        XCTAssertTrue(TreatmentEntryAccessor(coreDataManager: coreDataManager).getLatestTreatments(howOld: nil).isEmpty)
    }

    @MainActor func testLocalEditUpdatesOneRecordForEveryEditableTreatmentType() throws {
        try withRestoredDefaults {
            UserDefaults.standard.nightscoutEnabled = false
            for type in TreatmentEditorViewModel.supportedTreatmentTypes {
                let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
                let entry = TreatmentEntry(date: Date(), value: 20, treatmentType: type, nightscoutEventType: nil, enteredBy: "Test", notes: type == .BasalInjection ? "Tresiba" : "Original", nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
                let editor = TreatmentEditorViewModel(coreDataManager: coreDataManager, treatmentToEdit: entry)
                try coreDataManager.mainManagedObjectContext.obtainPermanentIDs(for: [entry])
                XCTAssertTrue(coreDataManager.saveChangesSynchronously())
                editor.enteredValue = "22"
                editor.enteredNotesValue = "Edited"
                XCTAssertTrue(editor.saveTreatment(), type.asString())
                let records = TreatmentEntryAccessor(coreDataManager: coreDataManager).getLatestTreatments(howOld: nil)
                XCTAssertEqual(records.count, 1, type.asString())
                XCTAssertTrue(records.first === entry, type.asString())
            }
        }
    }

    @MainActor func testTreatmentDatePickerLimitsFutureEntry() {
        for type in TreatmentEditorViewModel.supportedTreatmentTypes {
            let editor = TreatmentEditorViewModel(coreDataManager: nil, treatmentToEdit: nil, initialType: type)
            editor.enteredValue = "20"
            editor.enteredInsulinDescription = "Tresiba"
            editor.enteredNotesValue = "Note"
            let expectedLimit: TimeInterval = [.BgCheck, .Insulin, .BasalInjection, .Carbs].contains(type) ? 0 : 3600
            XCTAssertEqual(editor.latestSelectableDate.timeIntervalSinceNow, expectedLimit, accuracy: 1)
            editor.selectedDate = Date().addingTimeInterval(7200)
            XCTAssertFalse(editor.canSaveTreatment)
            editor.validateSelectedDateIfNeeded()
            XCTAssertLessThanOrEqual(editor.selectedDate.timeIntervalSinceNow, expectedLimit)
            XCTAssertTrue(editor.canSaveTreatment)
            if expectedLimit > 0 {
                editor.selectedDate = Date().addingTimeInterval(3599)
                XCTAssertTrue(editor.canSaveTreatment)
            }
        }

        let plannedCarbs = TreatmentEditorViewModel(coreDataManager: nil, treatmentToEdit: nil, initialType: .Carbs)
        plannedCarbs.isPlanningNewMeal = true
        XCTAssertEqual(plannedCarbs.latestSelectableDate.timeIntervalSinceNow, 3600, accuracy: 1)
    }

    func testDoseSymbolSizingInterpolatesAndClamps() {
        for range in [GlucoseChartTreatmentStyle.bolusSymbolSizing, GlucoseChartTreatmentStyle.carbsSymbolSizing] {
            XCTAssertEqual(range.size(for: range.minimumValue), range.minimumSize)
            XCTAssertEqual(range.size(for: range.maximumValue), range.maximumSize)
            XCTAssertEqual(range.size(for: 0), range.minimumSize)
            XCTAssertEqual(range.size(for: range.maximumValue * 10), range.maximumSize)
            XCTAssertEqual(range.size(for: (range.minimumValue + range.maximumValue) / 2), (range.minimumSize + range.maximumSize) / 2, accuracy: 0.0001)
            let lower = range.minimumValue + (range.maximumValue - range.minimumValue) * 0.25
            let upper = range.minimumValue + (range.maximumValue - range.minimumValue) * 0.75
            XCTAssertLessThan(range.size(for: lower), range.size(for: upper))
            XCTAssertEqual(range.size(for: .nan), range.minimumSize)
        }
    }

    func testNoteChartLabelsAreCompactWithoutChangingTheirContent() {
        XCTAssertNil(GlucoseChartTreatmentStyle.noteLabel(nil))
        XCTAssertNil(GlucoseChartTreatmentStyle.noteLabel("  \n "))
        XCTAssertEqual(GlucoseChartTreatmentStyle.noteLabel("  Before\n breakfast  "), "Before breakfast")
        let exact = String(repeating: "a", count: GlucoseChartTreatmentStyle.noteLabelCharacterLimit)
        XCTAssertEqual(GlucoseChartTreatmentStyle.noteLabel(exact), exact)
        let longNote = String(repeating: "👨‍👩‍👧‍👦", count: 25)
        let label = GlucoseChartTreatmentStyle.noteLabel(longNote)
        XCTAssertEqual(label?.count, GlucoseChartTreatmentStyle.noteLabelCharacterLimit)
        XCTAssertTrue(label?.hasSuffix("…") == true)
        XCTAssertEqual(longNote.count, 25)
    }

    private func envelope(_ json: String) -> String {
        BasalInjectionPayload.prefix + Data(json.utf8).base64EncodedString()
    }

    private func document(notes: String) -> NSDictionary {
        ["_id": "basaltest", "created_at": "2026-09-07T20:00:00Z", "eventType": "Note", "notes": notes]
    }

    /// Keep tests isolated from the simulator's saved treatment and sync preferences.
    @MainActor private func withRestoredDefaults(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = ["nightscoutEnabled", "lastBasalInjectionUnits", "lastBasalInjectionInsulinDescription", "showBasalInjectionTreatmentsInList", "showNoteTreatmentsInList", "timeStampLatestNightscoutSyncRequest", "nightscoutSyncRequired"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        try body()
    }
}

/// The local meal flow shares the established editor with insulin and basal entries.
final class LocalTreatmentPlanningTests: XCTestCase {
    @MainActor func testMealQuietReceivesOnlyNewVerifiedPairWithOriginalTimeForEveryMealKind() throws {
        for kind in [TreatmentMealKind.fast, .normal, .slow] {
            let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = PenDoseLogJournal(directory: directory)
            let metadata = MealPlanMetadataStore(directory: directory)
            let operation = PenDoseLogOperation()
            let eatingAt = Date().addingTimeInterval(-120)
            let receivedAt = eatingAt.addingTimeInterval(90)
            var events = 0
            let consider: (String, String, Date, Date, Bool) -> Void = { meal, bolus, eaten, known, allowed in
                events += 1
                XCTAssertEqual(meal, operation.mealUUID)
                XCTAssertEqual(bolus, operation.bolusUUID)
                XCTAssertEqual(eaten, eatingAt)
                XCTAssertEqual(known, eatingAt)
                XCTAssertTrue(allowed)
                XCTAssertEqual(journal.recoveryState(coreDataManager: core), .ready)
                let rows = try? MealPlanReminderCoordinator.storedTreatments(
                    coreDataManager: core, uuids: [meal, bolus])
                XCTAssertEqual(rows?.count, 2, "Both rows must already exist in the permanent store")
                XCTAssertEqual(rows?.first(where: { $0.uuid == meal })?.value, 1)
                XCTAssertEqual(rows?.first(where: { $0.uuid == bolus })?.value, 0.5)
            }
            for _ in 0..<2 {
                let result = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 0.5,
                    carbohydrateGrams: 1, mealKind: kind, plannedDate: nil, operation: operation,
                    now: eatingAt, knownAt: receivedAt, journal: journal,
                    penSettings: PenDoseProfile.prefilledUnconfirmed.settings,
                    pizzaSettings: PizzaSplitSettings(isEnabled: false, percentageNow: 70, reminderMinutes: 90),
                    metadataStore: metadata, considerMealQuiet: consider)
                guard case .success = result else { return XCTFail("The paired treatment should save") }
                XCTAssertEqual(events, 1, "Acknowledging the same operation must not repeat the meal event")
            }
            XCTAssertEqual(try metadata.metadata(for: operation.mealUUID)?.bolusUUID, operation.bolusUUID)
        }
    }

    @MainActor func testMealQuietRejectsUnpairedPlannedAndUncertainRegistrations() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PenDoseLogJournal(directory: directory)
        let metadata = MealPlanMetadataStore(directory: directory)
        let now = Date()
        var events = 0
        let consider: (String, String, Date, Date, Bool) -> Void = { _, _, _, _, _ in events += 1 }
        for (insulin, carbs, planned) in [(0.0, 12.0, false), (1.0, 0.0, false), (1.0, 12.0, true)] {
            let result = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: insulin,
                carbohydrateGrams: carbs, mealKind: .fast,
                plannedDate: planned ? now.addingTimeInterval(15 * 60) : nil,
                now: now, journal: journal, penSettings: PenDoseProfile.prefilledUnconfirmed.settings,
                metadataStore: metadata, considerMealQuiet: consider)
            guard case .success = result else { return XCTFail("Valid treatment should still save") }
        }
        XCTAssertEqual(events, 0, "Separate entries at the same time must never be paired")

        let uncertain = PenDoseLogOperation()
        let failed = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 1,
            carbohydrateGrams: 12, mealKind: .normal, plannedDate: nil, operation: uncertain,
            now: now, journal: journal, penSettings: PenDoseProfile.prefilledUnconfirmed.settings,
            metadataStore: metadata, saveOverride: { false }, considerMealQuiet: consider)
        guard case .failure(.storageFailed) = failed else { return XCTFail("Save must be unverified") }
        XCTAssertEqual(events, 0)
        let retry = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 1,
            carbohydrateGrams: 12, mealKind: .normal, plannedDate: nil, operation: uncertain,
            now: now, journal: journal, penSettings: PenDoseProfile.prefilledUnconfirmed.settings,
            metadataStore: metadata, considerMealQuiet: consider)
        guard case .success = retry else { return XCTFail("The existing retry contract must remain intact") }
        XCTAssertEqual(events, 0, "Resolving an uncertain attempt is not a fresh meal event")
    }

    @MainActor func testMealQuietKeepsOfflineOriginIneligibleAfterVerifiedPhoneStorage() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let eatingAt = Date().addingTimeInterval(-120)
        let receivedAt = Date()
        var permissions: [Bool] = []
        let result = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 1,
            carbohydrateGrams: 12, mealKind: .normal, plannedDate: nil,
            now: eatingAt, knownAt: receivedAt, journal: PenDoseLogJournal(directory: directory),
            penSettings: PenDoseProfile.prefilledUnconfirmed.settings,
            metadataStore: MealPlanMetadataStore(directory: directory), allowsMealQuietStart: false,
            considerMealQuiet: { _, _, eaten, received, allowed in
                XCTAssertEqual(eaten, eatingAt)
                XCTAssertEqual(received, eatingAt)
                permissions.append(allowed)
            })
        guard case .success = result else { return XCTFail("Offline treatment must still be stored") }
        XCTAssertEqual(permissions, [false])
    }

    @MainActor func testMealQuietPlannedMealRequiresExplicitVerifiedConfirmationAndExistingBolus() throws {
        for hasBolus in [false, true] {
            let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let journal = PenDoseLogJournal(directory: directory)
            let metadata = MealPlanMetadataStore(directory: directory)
            let operation = PenDoseLogOperation()
            let now = Date()
            var events = 0
            let consider: (String, String, Date, Date, Bool) -> Void = { meal, bolus, eaten, known, allowed in
                events += 1
                XCTAssertEqual(meal, operation.mealUUID)
                XCTAssertEqual(bolus, operation.bolusUUID)
                XCTAssertLessThanOrEqual(eaten, known)
                XCTAssertTrue(allowed)
                XCTAssertEqual(journal.recoveryState(coreDataManager: core), .ready)
                let rows = try? MealPlanReminderCoordinator.storedTreatments(
                    coreDataManager: core, uuids: [meal, bolus])
                XCTAssertTrue(rows?.first(where: { $0.uuid == meal })?.isConfirmedMeal == true)
                XCTAssertEqual(rows?.first(where: { $0.uuid == meal })?.date, eaten)
            }
            let result = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: hasBolus ? 1 : 0,
                carbohydrateGrams: 12, mealKind: .normal, plannedDate: now.addingTimeInterval(15 * 60),
                operation: operation, now: now, journal: journal,
                penSettings: PenDoseProfile.prefilledUnconfirmed.settings,
                metadataStore: metadata, considerMealQuiet: consider)
            guard case .success = result else { return XCTFail("Plan should save") }
            let meal = try XCTUnwrap(TreatmentEntryAccessor(coreDataManager: core)
                .getLatestTreatments(howOld: nil).first { $0.localTreatmentUUID == operation.mealUUID })
            let edit = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: meal,
                localSaveJournal: journal, mealMetadataStore: metadata, considerMealQuiet: consider)
            edit.enteredValue = "14"
            XCTAssertTrue(edit.saveTreatment())
            XCTAssertEqual(events, 0, "A plan edit is not evidence of eating")
            let confirmation = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: meal,
                localSaveJournal: journal, mealMetadataStore: metadata, considerMealQuiet: consider)
            confirmation.selectedDate = now.addingTimeInterval(-30)
            XCTAssertTrue(confirmation.confirmPlannedMeal())
            XCTAssertEqual(events, hasBolus ? 1 : 0)
            let ordinaryEdit = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: meal,
                localSaveJournal: journal, mealMetadataStore: metadata, considerMealQuiet: consider)
            ordinaryEdit.enteredValue = "16"
            XCTAssertTrue(ordinaryEdit.saveTreatment())
            XCTAssertEqual(events, hasBolus ? 1 : 0, "An eaten-meal edit must never start another period")
        }
    }

    @MainActor func testMealQuietDoesNotStartOnFailedPlannedConfirmationOrQuickCarbs() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PenDoseLogJournal(directory: directory)
        let metadata = MealPlanMetadataStore(directory: directory)
        var events = 0
        let consider: (String, String, Date, Date, Bool) -> Void = { _, _, _, _, _ in events += 1 }
        let quickCarbs = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: nil,
            quickCarbohydrateGrams: 12, localSaveJournal: journal,
            mealMetadataStore: metadata, considerMealQuiet: consider)
        XCTAssertTrue(quickCarbs.saveTreatment())
        XCTAssertEqual(events, 0)
        let operation = PenDoseLogOperation()
        let result = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 1,
            carbohydrateGrams: 12, mealKind: .normal,
            plannedDate: Date().addingTimeInterval(15 * 60), operation: operation,
            journal: journal, penSettings: PenDoseProfile.prefilledUnconfirmed.settings,
            metadataStore: metadata, considerMealQuiet: consider)
        guard case .success = result else { return XCTFail("Plan should save") }
        let meal = try XCTUnwrap(TreatmentEntryAccessor(coreDataManager: core)
            .getLatestTreatments(howOld: nil).first { $0.localTreatmentUUID == operation.mealUUID })
        let confirmation = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: meal,
            localSaveJournal: journal, localSaveOverride: { false }, mealMetadataStore: metadata,
            considerMealQuiet: consider)
        XCTAssertFalse(confirmation.confirmPlannedMealNow())
        XCTAssertEqual(events, 0)
    }

    @MainActor func testPlannedMealStaysUnconfirmedUntilExplicitAction() throws {
        let manager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let draft = TreatmentEditorViewModel(coreDataManager: manager, treatmentToEdit: nil, initialType: .Carbs)
        draft.enteredValue = "35"
        draft.selectedMealKind = .slow
        draft.isPlanningNewMeal = true
        draft.selectedDate = Date().addingTimeInterval(25 * 60)
        XCTAssertTrue(draft.saveTreatment())

        let entry = try XCTUnwrap(TreatmentEntryAccessor(coreDataManager: manager).getLatestTreatments(howOld: nil).first)
        XCTAssertTrue(entry.isPlannedMeal)
        XCTAssertFalse(entry.isConfirmedMeal)
        XCTAssertEqual(entry.mealKind, .slow)
        XCTAssertEqual(entry.effectiveCarbohydrateDurationMinutes, 300)
        XCTAssertNil(entry.healthKitSyncStateRaw)
        let identity = try XCTUnwrap(entry.localTreatmentUUID)
        let createdAt = try XCTUnwrap(entry.createdAt)

        let editor = TreatmentEditorViewModel(coreDataManager: manager, treatmentToEdit: entry)
        XCTAssertFalse(editor.deletionMayLeaveHealthCopy)
        XCTAssertFalse(editor.confirmPlannedMeal(), "A future meal cannot be declared eaten early")
        XCTAssertTrue(entry.isPlannedMeal)
        editor.enteredValue = "40"
        XCTAssertTrue(editor.saveTreatment())
        XCTAssertTrue(entry.isPlannedMeal, "Editing is not confirmation")
        XCTAssertEqual(entry.value, 40)

        let confirmation = TreatmentEditorViewModel(coreDataManager: manager, treatmentToEdit: entry)
        confirmation.selectedDate = Date().addingTimeInterval(-60)
        XCTAssertTrue(confirmation.confirmPlannedMeal())
        XCTAssertTrue(entry.isConfirmedMeal)
        XCTAssertFalse(entry.isPlannedMeal)
        XCTAssertEqual(entry.localTreatmentUUID, identity)
        XCTAssertEqual(entry.createdAt, createdAt)
        XCTAssertEqual(entry.healthKitSyncVersion?.intValue, 1)
        XCTAssertEqual(entry.healthKitSyncStateRaw, "pending")
        XCTAssertTrue(TreatmentEditorViewModel(coreDataManager: manager, treatmentToEdit: entry).deletionMayLeaveHealthCopy)
        XCTAssertTrue(TreatmentSnapshot(treatmentEntry: entry).deletionMayLeaveHealthCopy)
        XCTAssertEqual(TreatmentEntryAccessor(coreDataManager: manager).getLatestTreatments(howOld: nil).count, 1)
        let removal = TreatmentEditorViewModel(coreDataManager: manager, treatmentToEdit: entry)
        XCTAssertTrue(removal.deleteTreatment())
        XCTAssertTrue(entry.treatmentdeleted)
        XCTAssertFalse(entry.isDeleted, "Local deletion retains the record; Health deletion is not attempted")
    }

    @MainActor func testCancellationAndQuickCarbsStayDistinct() throws {
        let manager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let draft = TreatmentEditorViewModel(coreDataManager: manager, treatmentToEdit: nil, initialType: .Carbs)
        draft.enteredValue = "20"
        draft.isPlanningNewMeal = true
        draft.selectedDate = Date().addingTimeInterval(10 * 60)
        XCTAssertTrue(draft.saveTreatment())
        let entry = try XCTUnwrap(TreatmentEntryAccessor(coreDataManager: manager).getLatestTreatments(howOld: nil).first)
        let editor = TreatmentEditorViewModel(coreDataManager: manager, treatmentToEdit: entry)
        XCTAssertTrue(editor.cancelPlannedMeal())
        XCTAssertTrue(entry.isCancelledMeal)
        XCTAssertFalse(entry.isConfirmedMeal)
        XCTAssertNil(entry.healthKitSyncStateRaw)

        let quick = TreatmentEditorViewModel(coreDataManager: manager, treatmentToEdit: nil,
                                             initialType: .Carbs, quickCarbohydrateGrams: 15)
        XCTAssertEqual(quick.enteredValue, "15")
        XCTAssertEqual(quick.selectedMealKind, .fast)
        XCTAssertFalse(quick.isPlanningNewMeal)
        XCTAssertTrue(quick.saveTreatment())
        let entries = TreatmentEntryAccessor(coreDataManager: manager).getLatestTreatments(howOld: nil)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first(where: { $0.isConfirmedMeal })?.effectiveCarbohydrateDurationMinutes, 30)
    }

    @MainActor func testCutoverHistoryAndChartOnlyShowEligibleConsumedTreatments() async throws {
        let defaults = UserDefaults.standard
        let cutoverKey = TreatmentSourceCutover.defaultsKey
        let oldCutover = defaults.object(forKey: cutoverKey)
        let oldTherapySource = defaults.therapyDataSourceType
        let oldBolusVisible = defaults.showBolusTreatmentsInList
        let oldSmallBolusVisible = defaults.showSmallBolusTreatmentsInList
        let oldCarbsVisible = defaults.showCarbsTreatmentsInList
        defer {
            if let oldCutover { defaults.set(oldCutover, forKey: cutoverKey) }
            else { defaults.removeObject(forKey: cutoverKey) }
            defaults.therapyDataSourceType = oldTherapySource
            defaults.showBolusTreatmentsInList = oldBolusVisible
            defaults.showSmallBolusTreatmentsInList = oldSmallBolusVisible
            defaults.showCarbsTreatmentsInList = oldCarbsVisible
        }
        defaults.removeObject(forKey: cutoverKey)
        defaults.therapyDataSourceType = .none
        defaults.showBolusTreatmentsInList = true
        defaults.showSmallBolusTreatmentsInList = true
        defaults.showCarbsTreatmentsInList = true

        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        // Keep the chart window in the past and all list entries on one calendar day.
        let previousDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1,
            to: Calendar.current.startOfDay(for: Date())))
        let noon = previousDay.addingTimeInterval(12 * 3600)
        let cutoff = noon.addingTimeInterval(-3600)
        XCTAssertTrue(TreatmentSourceCutover.persist(.init(
            cutoff: cutoff, insulinSourceBundleID: "test.mysugr",
            carbohydrateSourceBundleID: "test.mysugr")))

        func treatment(_ date: Date, _ value: Double, _ type: TreatmentType) -> TreatmentEntry {
            TreatmentEntry(date: date, value: value, treatmentType: type,
                nightscoutEventType: nil, enteredBy: "Test",
                nsManagedObjectContext: core.mainManagedObjectContext)
        }
        let historic = treatment(noon.addingTimeInterval(-2 * 3600), 2, .Insulin)
        historic.healthKitSampleUUID = UUID().uuidString
        historic.healthKitSourceBundleIdentifier = "test.mysugr"
        let wrongSource = treatment(noon.addingTimeInterval(-2.5 * 3600), 3, .Insulin)
        wrongSource.healthKitSampleUUID = UUID().uuidString
        wrongSource.healthKitSourceBundleIdentifier = "test.other"
        let importedAfterCutover = treatment(noon.addingTimeInterval(-1800), 4, .Insulin)
        importedAfterCutover.healthKitSampleUUID = UUID().uuidString
        importedAfterCutover.healthKitSourceBundleIdentifier = "test.mysugr"
        let consumedLocal = treatment(noon.addingTimeInterval(-30 * 60), 18, .Carbs)
        consumedLocal.localTreatmentUUID = UUID().uuidString
        let planned = treatment(noon.addingTimeInterval(-20 * 60), 30, .Carbs)
        planned.localTreatmentUUID = UUID().uuidString
        planned.plannedMealStateRaw = TreatmentMealState.planned.rawValue
        let cancelled = treatment(noon.addingTimeInterval(-10 * 60), 40, .Carbs)
        cancelled.localTreatmentUUID = UUID().uuidString
        cancelled.plannedMealStateRaw = TreatmentMealState.cancelled.rawValue
        XCTAssertTrue(core.saveChangesSynchronously())

        let list = TreatmentsViewModel(coreDataManager: core)
        list.reloadTreatments()
        list.selectedDateChanged(noon)
        let listIDs = Set(list.filteredTreatments.map(\.objectID))
        XCTAssertEqual(listIDs, Set([historic, consumedLocal, planned, cancelled].map(\.objectID)),
                       "Old selected mySugr history and local plans remain visible after importer shutdown")

        let sync = NightscoutSyncManager(coreDataManager: core, messageHandler: nil)
        let chart = GlucoseChartStateManager(coreDataManager: core, nightscoutSyncManager: sync)
        let state: GlucoseChartState = await withCheckedContinuation { continuation in
            chart.updateState(endDate: noon, startDate: noon.addingTimeInterval(-3 * 3600),
                              forceReset: true, showTreatments: true) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(state.treatmentPoints.boluses.count, 1)
        XCTAssertEqual(state.treatmentPoints.carbs.count, 1,
                       "Unconfirmed and cancelled meals never become consumed chart markers")
        XCTAssertEqual(state.treatmentPoints.boluses.first?.label, "2")
        XCTAssertEqual(state.treatmentPoints.carbs.first?.label, "18")
    }

    @MainActor func testHealthSyncedLocalTreatmentCannotChangeTypeUnderSameSyncID() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let entry = TreatmentEntry(date: Date().addingTimeInterval(-60), value: 2,
            treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "Test",
            nsManagedObjectContext: core.mainManagedObjectContext)
        entry.localTreatmentUUID = UUID().uuidString
        entry.createdAt = entry.date
        entry.modifiedAt = entry.date
        entry.healthKitSyncVersion = NSNumber(value: 1)
        entry.healthKitSyncStateRaw = "synced"
        XCTAssertTrue(core.saveChangesSynchronously())

        let editor = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: entry)
        editor.selectedType = .Carbs
        editor.enteredValue = "20"
        XCTAssertFalse(editor.canSaveTreatment)
        XCTAssertFalse(editor.saveTreatment())
        XCTAssertTrue(editor.alertMessage?.message.contains("Sundhed") == true)
        XCTAssertEqual(entry.treatmentType, .Insulin)
        XCTAssertEqual(entry.value, 2)
        XCTAssertEqual(entry.healthKitSyncVersion?.intValue, 1)

        editor.selectedType = .Insulin
        editor.enteredValue = "2.5"
        XCTAssertTrue(editor.canSaveTreatment)
        XCTAssertTrue(editor.saveTreatment(), "Same-type edits retain the stable Health sync ID")
        XCTAssertEqual(entry.treatmentType, .Insulin)
        XCTAssertEqual(entry.value, 2.5)
        XCTAssertEqual(entry.healthKitSyncVersion?.intValue, 2)
    }

    func testReminderRequiresFuturePlanAndCannotBeClearedAsGlucoseAlert() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let uuid = UUID().uuidString
        let reminder = try XCTUnwrap(PlannedMealReminder.request(uuid: uuid, grams: 45,
            bolusUnits: 4, at: now.addingTimeInterval(600), now: now, locale: Locale(identifier: "da_DK")))
        XCTAssertEqual(reminder.identifier, PlannedMealReminder.identifier(for: uuid))
        XCTAssertEqual(PlannedMealReminder.tappedUUID(from: reminder), uuid)
        XCTAssertEqual(reminder.content.title, "Tid til at spise")
        XCTAssertEqual(reminder.content.body,
            "Du har registreret 4,0 E til 45 g. Tryk og bekræft, når du spiser.")
        let withoutBolus = try XCTUnwrap(PlannedMealReminder.request(uuid: uuid, grams: 45,
            bolusUnits: nil, at: now.addingTimeInterval(600), now: now, locale: Locale(identifier: "da_DK")))
        XCTAssertEqual(withoutBolus.content.body,
            "45 g er planlagt nu. Tryk og bekræft, når du spiser.")
        let followup = try XCTUnwrap(PlannedMealReminder.followupRequest(uuid: uuid,
            bolusUnits: 4, at: now.addingTimeInterval(25 * 60), now: now,
            locale: Locale(identifier: "da_DK")))
        XCTAssertEqual(followup.identifier, PlannedMealReminder.followupIdentifier(for: uuid))
        XCTAssertEqual(PlannedMealReminder.tappedUUID(from: followup), uuid)
        XCTAssertEqual(followup.content.title, "Har du spist?")
        XCTAssertEqual(followup.content.body,
            "Du har registreret 4,0 E, men måltidet er ikke bekræftet. Åbn xDrip og kontrollér planen.")
        XCTAssertNotEqual(followup.identifier, reminder.identifier)
        XCTAssertNil(PlannedMealReminder.request(uuid: uuid, grams: 45, bolusUnits: 4, at: now, now: now))
        XCTAssertNil(PlannedMealReminder.request(uuid: uuid, grams: 45, bolusUnits: 4,
            at: now.addingTimeInterval(61 * 60), now: now))
        XCTAssertFalse(AlertManager.ownedPendingNotificationIdentifiers.contains(reminder.identifier))
        XCTAssertFalse(AlertManager.ownedPendingNotificationIdentifiers.contains(followup.identifier))
        XCTAssertTrue(AlertManager.ownedPendingNotificationIdentifiers.contains(AlertKind.missedreading.notificationIdentifier()))
    }

    func testQuickAmountHasNoUnrequestedDefault() {
        let key = UserDefaults.Key.quickCarbohydrateGrams.rawValue
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.quickCarbohydrateGrams = nil
        XCTAssertNil(UserDefaults.standard.quickCarbohydrateGrams)
        UserDefaults.standard.quickCarbohydrateGrams = 12.5
        XCTAssertEqual(UserDefaults.standard.quickCarbohydrateGrams, 12.5)
        UserDefaults.standard.quickCarbohydrateGrams = .infinity
        XCTAssertNil(UserDefaults.standard.quickCarbohydrateGrams)
    }

    func testPizzaReminderPromptsFreshCalculationWithoutEmbeddingDose() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let uuid = UUID().uuidString
        let request = try XCTUnwrap(PizzaSplitReminder.request(uuid: uuid, after: 90, now: now))
        XCTAssertEqual(request.identifier, PizzaSplitReminder.identifier(for: uuid))
        XCTAssertEqual(PizzaSplitReminder.tappedUUID(from: request), uuid)
        XCTAssertEqual(request.content.userInfo.count, 1)
        XCTAssertEqual(request.content.userInfo[PizzaSplitReminder.uuidUserInfoKey] as? String, uuid)
        XCTAssertFalse(request.content.body.contains("restdosis"))
        XCTAssertFalse(AlertManager.ownedPendingNotificationIdentifiers.contains(request.identifier))
        XCTAssertNil(PizzaSplitReminder.request(uuid: uuid, after: 0, now: now))
        XCTAssertNil(PizzaSplitReminder.request(uuid: uuid, after: 241, now: now))
    }

    func testManualDoseGlucosePersistsOnlyAsExplicitCalculatorRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let measuredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let store = ManualDoseGlucoseStore(directory: directory)
        let initial = await store.load()
        XCTAssertNil(initial)
        let record = try await store.save(valueMgdl: 108, measuredAt: measuredAt,
                                          now: measuredAt.addingTimeInterval(60))
        XCTAssertEqual(record.source, "manual")
        XCTAssertEqual(record.measuredAt, measuredAt)
        XCTAssertEqual(record.valueMgdl, 108)
        let reloaded = await ManualDoseGlucoseStore(directory: directory).load()
        XCTAssertEqual(reloaded, record)
        XCTAssertNil(ManualDoseGlucoseRecord(valueMgdl: .infinity, measuredAt: measuredAt))
        XCTAssertNil(ManualDoseGlucoseRecord(valueMgdl: 108,
            measuredAt: measuredAt.addingTimeInterval(61), recordedAt: measuredAt.addingTimeInterval(60)))
    }

    func testPenSettingsNeedExplicitConfirmationAndPizzaDefaults() throws {
        let profile = PenDoseProfile.prefilledUnconfirmed
        XCTAssertFalse(profile.isConfirmed)
        var draft = PenDoseProfileDraft(profile: profile)
        XCTAssertEqual(draft.settings, profile.settings)
        draft.ratioMorning = ""
        XCTAssertNil(draft.settings)
        draft.ratioMorning = "5,0"
        XCTAssertEqual(draft.settings?.carbohydrateRatios[1].value, 5)

        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pizza = PizzaSplitSettings.load(defaults: defaults)
        XCTAssertEqual(pizza, PizzaSplitSettings(isEnabled: true, percentageNow: 70, reminderMinutes: 90))
        XCTAssertTrue(pizza.persist(defaults: defaults))
        XCTAssertEqual(PizzaSplitSettings.load(defaults: defaults), pizza)
    }

    @MainActor func testPenDoseLogPersistsBolusAndEatenMealTogetherWithLocalIdentity() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PenDoseLogJournal(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let result = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 2.5,
            carbohydrateGrams: 32, mealKind: .slow, plannedDate: nil, now: now, journal: journal)
        guard case .success(let receipt) = result else {
            return XCTFail("A valid user-confirmed treatment must save locally")
        }
        let entries = TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil)
        let bolus = try XCTUnwrap(entries.first { $0.treatmentType == .Insulin })
        let meal = try XCTUnwrap(entries.first { $0.treatmentType == .Carbs })
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(bolus.value, 2.5)
        XCTAssertEqual(meal.value, 32)
        XCTAssertEqual(meal.date, now)
        XCTAssertEqual(meal.mealKind, .slow)
        XCTAssertEqual(meal.effectiveCarbohydrateDurationMinutes, 300)
        XCTAssertTrue(meal.isConfirmedMeal)
        XCTAssertNotNil(bolus.localTreatmentUUID)
        XCTAssertEqual(receipt.confirmedMealUUID, meal.localTreatmentUUID)
        XCTAssertEqual(bolus.healthKitSyncVersion?.intValue, 1)
        XCTAssertEqual(meal.healthKitSyncVersion?.intValue, 1)
    }

    @MainActor func testPenDosePlannedMealIsNotConfirmedOrHealthPending() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PenDoseLogJournal(directory: directory)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(30 * 60)
        let result = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 0,
            carbohydrateGrams: 20, mealKind: .normal, plannedDate: future, now: now, journal: journal)
        guard case .success(let receipt) = result else {
            return XCTFail("A valid planned meal must save locally")
        }
        let meal = try XCTUnwrap(TreatmentEntryAccessor(coreDataManager: core)
            .getLatestTreatments(howOld: nil).first)
        XCTAssertTrue(meal.isPlannedMeal)
        XCTAssertFalse(meal.isConfirmedMeal)
        XCTAssertEqual(meal.date, future)
        XCTAssertNil(meal.healthKitSyncVersion)
        XCTAssertNil(receipt.confirmedMealUUID)
        let invalid = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 1,
            carbohydrateGrams: 0, mealKind: .normal, plannedDate: future, now: now, journal: journal)
        guard case .failure(.invalidInput) = invalid else {
            return XCTFail("A planned date without food must be rejected")
        }
    }

    @MainActor func testMealMetadataUnchangedReplacePreservesFileAcrossStoreRecreation() throws {
        let date = Date(timeIntervalSince1970: 1_788_804_000)
        let files = MealMetadataProtectionFileManager()
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: directory) }
        let metadata = MealPlanMetadata(mealUUID: UUID().uuidString, bolusUUID: UUID().uuidString,
            loggedAt: date, plannedAt: date.addingTimeInterval(900), grams: 35,
            pizzaSettings: PizzaSplitSettings(isEnabled: true, percentageNow: 70, reminderMinutes: 90),
            mealKind: .slow)
        try MealPlanMetadataStore(directory: directory, fileManager: files).stage(metadata)
        let url = directory.appendingPathComponent("PenDose/MealPlans/\(metadata.mealUUID).json")
        let untouchedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try files.setAttributes([.modificationDate: untouchedDate], ofItemAtPath: url.path)
        let before = try files.attributesOfItem(atPath: url.path)
        let bytes = try Data(contentsOf: url)

        for _ in 0..<3 {
            try MealPlanMetadataStore(directory: directory, fileManager: files).replace(metadata)
        }

        let after = try files.attributesOfItem(atPath: url.path)
        XCTAssertEqual(after[.modificationDate] as? Date, untouchedDate)
        XCTAssertEqual(try XCTUnwrap(after[.systemFileNumber] as? NSNumber),
                       try XCTUnwrap(before[.systemFileNumber] as? NSNumber))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try MealPlanMetadataStore(directory: directory, fileManager: files).metadata(for: metadata.mealUUID), metadata)
    }

    @MainActor func testMealMetadataReplacePersistsReminderFieldsOutsideLogIdentity() throws {
        let date = Date(timeIntervalSince1970: 1_788_804_000)
        let files = MealMetadataProtectionFileManager()
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: directory) }
        let store = MealPlanMetadataStore(directory: directory, fileManager: files)
        let original = MealPlanMetadata(mealUUID: UUID().uuidString, bolusUUID: UUID().uuidString,
            loggedAt: date, plannedAt: nil, grams: 40,
            pizzaSettings: PizzaSplitSettings(isEnabled: true, percentageNow: 70, reminderMinutes: 90),
            mealKind: .slow)
        try store.stage(original)
        var changed = original
        changed.pizzaReminderAt = date.addingTimeInterval(120 * 60)
        changed.pizzaReminderEligible = false
        XCTAssertTrue(original.matchesLogAttempt(changed),
            "A reminder edit must still persist when the original log identity is unchanged")

        try store.replace(changed)

        XCTAssertEqual(try MealPlanMetadataStore(directory: directory, fileManager: files).metadata(for: original.mealUUID), changed)
    }

    @MainActor func testMealMetadataReplaceReadsPersistedStateAfterRemovalOrDamage() throws {
        let date = Date(timeIntervalSince1970: 1_788_804_000)
        let files = MealMetadataProtectionFileManager()
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: directory) }
        let store = MealPlanMetadataStore(directory: directory, fileManager: files)
        let metadata = MealPlanMetadata(mealUUID: UUID().uuidString, bolusUUID: nil,
            loggedAt: date, plannedAt: nil, grams: 30, pizzaSettings: nil, mealKind: .normal)
        try store.replace(metadata)
        let url = directory.appendingPathComponent("PenDose/MealPlans/\(metadata.mealUUID).json")
        try files.removeItem(at: url)
        try store.replace(metadata)
        XCTAssertEqual(try MealPlanMetadataStore(directory: directory, fileManager: files).metadata(for: metadata.mealUUID), metadata)

        try Data("damaged metadata".utf8).write(to: url, options: .atomic)
        XCTAssertThrowsError(try store.stage(metadata), "Staging must still reject unreadable existing metadata")
        try store.replace(metadata)
        XCTAssertEqual(try MealPlanMetadataStore(directory: directory, fileManager: files).metadata(for: metadata.mealUUID), metadata,
            "An explicit replacement must retain its existing ability to repair damaged data")
    }

    @MainActor func testMealMetadataUnchangedReplaceRepairsIncompleteFileProtection() throws {
        let date = Date(timeIntervalSince1970: 1_788_804_000)
        let files = MealMetadataProtectionFileManager()
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: directory) }
        let store = MealPlanMetadataStore(directory: directory, fileManager: files)
        let metadata = MealPlanMetadata(mealUUID: UUID().uuidString, bolusUUID: nil,
            loggedAt: date, plannedAt: nil, grams: 30, pizzaSettings: nil, mealKind: .normal)
        try store.replace(metadata)
        let metadataDirectory = directory.appendingPathComponent("PenDose/MealPlans")
        let url = metadataDirectory.appendingPathComponent("\(metadata.mealUUID).json")

        // Exercise each protection failure separately: an earlier write could have stopped
        // after either the directory or the file was created, before its protection was set.
        for path in [metadataDirectory.path, url.path] {
            let untouchedDate = Date(timeIntervalSince1970: 1_700_000_000)
            try files.setAttributes([.modificationDate: untouchedDate], ofItemAtPath: url.path)
            try files.setAttributes([.protectionKey: FileProtectionType.none], ofItemAtPath: path)
            XCTAssertEqual(try files.attributesOfItem(atPath: path)[.protectionKey] as? FileProtectionType,
                           FileProtectionType.none)
            try store.replace(metadata)
            let directoryAttributes = try files.attributesOfItem(atPath: metadataDirectory.path)
            let fileAttributes = try files.attributesOfItem(atPath: url.path)
            XCTAssertNotEqual(fileAttributes[.modificationDate] as? Date, untouchedDate,
                "Either incomplete protection must take the real durable replacement path")
            XCTAssertEqual(directoryAttributes[.protectionKey] as? FileProtectionType,
                           .completeUntilFirstUserAuthentication)
            XCTAssertEqual(fileAttributes[.protectionKey] as? FileProtectionType,
                           .completeUntilFirstUserAuthentication)
            XCTAssertEqual(try MealPlanMetadataStore(directory: directory, fileManager: files).metadata(for: metadata.mealUUID), metadata)
        }
    }

    @MainActor func testUnchangedMealReminderRefreshSkipsWritesButPersistsEditsAndDeletion() throws {
        let date = Date(timeIntervalSince1970: 1_788_804_000)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let files = MealMetadataProtectionFileManager()
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: directory) }
        let store = MealPlanMetadataStore(directory: directory, fileManager: files)
        let uuid = UUID().uuidString
        let meal = TreatmentEntry(date: date, value: 30, treatmentType: .Carbs,
            nightscoutEventType: nil, enteredBy: "xDrip4iOS",
            nsManagedObjectContext: core.mainManagedObjectContext)
        meal.localTreatmentUUID = uuid
        meal.mealKindRaw = TreatmentMealKind.normal.rawValue
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertNil(MealPlanReminderCoordinator.refresh(coreDataManager: core,
            mealUUID: uuid, now: date, store: store))
        let original = try XCTUnwrap(store.metadata(for: uuid))
        let url = directory.appendingPathComponent("PenDose/MealPlans/\(uuid).json")
        let untouchedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try files.setAttributes([.modificationDate: untouchedDate], ofItemAtPath: url.path)
        let before = try files.attributesOfItem(atPath: url.path)

        for _ in 0..<3 {
            XCTAssertNil(MealPlanReminderCoordinator.refresh(coreDataManager: core,
                mealUUID: uuid, now: date.addingTimeInterval(60), store: store))
        }
        let unchanged = try files.attributesOfItem(atPath: url.path)
        XCTAssertEqual(unchanged[.modificationDate] as? Date, untouchedDate)
        XCTAssertEqual(try XCTUnwrap(unchanged[.systemFileNumber] as? NSNumber),
                       try XCTUnwrap(before[.systemFileNumber] as? NSNumber))
        XCTAssertEqual(try store.metadata(for: uuid), original)

        meal.value = 45
        meal.date = date.addingTimeInterval(120)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertNil(MealPlanReminderCoordinator.refresh(coreDataManager: core,
            mealUUID: uuid, now: date.addingTimeInterval(180), store: store))
        let edited = try XCTUnwrap(MealPlanMetadataStore(directory: directory, fileManager: files).metadata(for: uuid))
        XCTAssertEqual(edited.lastStoredMealGrams, 45)
        XCTAssertEqual(edited.lastStoredMealDate, meal.date)

        meal.treatmentdeleted = true
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertNil(MealPlanReminderCoordinator.refresh(coreDataManager: core,
            mealUUID: uuid, now: date.addingTimeInterval(240), store: store))
        XCTAssertNil(try store.metadata(for: uuid))
        XCTAssertFalse(files.fileExists(atPath: url.path))
    }

    @MainActor func testPlannedPizzaKeepsLinkAndSettingsUntilActualMealConfirmation() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealPlanMetadataStore(directory: directory)
        let journal = PenDoseLogJournal(directory: directory)
        let operation = PenDoseLogOperation()
        let loggedAt = Date()
        let plannedAt = loggedAt.addingTimeInterval(15 * 60)
        let pizza = PizzaSplitSettings(isEnabled: true, percentageNow: 70, reminderMinutes: 90)
        let result = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 4,
            carbohydrateGrams: 45, mealKind: .slow, plannedDate: plannedAt,
            operation: operation, now: loggedAt, journal: journal,
            pizzaSettings: pizza, metadataStore: store)
        guard case .success = result else { return XCTFail("Planned 🍕 treatment should save") }
        let initial = try XCTUnwrap(store.metadata(for: operation.mealUUID))
        XCTAssertEqual(initial.bolusUUID, operation.bolusUUID)
        XCTAssertEqual(initial.plannedAt, plannedAt)
        XCTAssertEqual(initial.followupAt, plannedAt.addingTimeInterval(15 * 60))
        XCTAssertEqual(initial.pizzaPercentageNow, 70)
        XCTAssertEqual(initial.pizzaReminderMinutes, 90)
        XCTAssertNil(initial.pizzaReminderAt, "A planned meal must not start the 🍕 reevaluation timer")

        let entries = TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil)
        let meal = try XCTUnwrap(entries.first { $0.localTreatmentUUID == operation.mealUUID })
        let bolus = try XCTUnwrap(entries.first { $0.localTreatmentUUID == operation.bolusUUID })
        XCTAssertEqual(bolus.date, loggedAt, "Pre-bolus time is registration time")
        XCTAssertTrue(meal.isPlannedMeal)
        let editor = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: meal,
            localSaveJournal: journal, mealMetadataStore: store)
        XCTAssertFalse(editor.confirmPlannedMeal(), "The planned time is not actual eating time")
        XCTAssertTrue(editor.confirmPlannedMealNow())
        XCTAssertTrue(meal.isConfirmedMeal)
        XCTAssertEqual(TreatmentEntryAccessor(coreDataManager: core)
            .getLatestTreatments(howOld: nil).filter { $0.treatmentType == .Carbs }.count, 1)
        let confirmed = try XCTUnwrap(store.metadata(for: operation.mealUUID))
        let due = try XCTUnwrap(confirmed.pizzaReminderAt)
        let expectedDue = MealPlanMetadata.pizzaDueAt(actualMealAt: meal.date,
            confirmedAt: meal.modifiedAt ?? .distantPast, intervalMinutes: 90)
        XCTAssertEqual(due.timeIntervalSince(expectedDue), 0, accuracy: 2)
        XCTAssertEqual(confirmed.pizzaReminderMinutes, 90,
            "Later global settings must not replace the logged meal's choice")
    }

    @MainActor func testCancellingPlanKeepsBolusAndRemovesOnlyMealMetadata() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealPlanMetadataStore(directory: directory)
        let journal = PenDoseLogJournal(directory: directory)
        let operation = PenDoseLogOperation()
        let now = Date()
        let plannedAt = now.addingTimeInterval(20 * 60)
        let result = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 2,
            carbohydrateGrams: 30, mealKind: .normal, plannedDate: plannedAt,
            operation: operation, now: now, journal: journal, metadataStore: store)
        guard case .success = result else { return XCTFail("Planned meal should save") }
        let entries = TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil)
        let meal = try XCTUnwrap(entries.first { $0.localTreatmentUUID == operation.mealUUID })
        let editor = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: meal,
            localSaveJournal: journal, mealMetadataStore: store)
        XCTAssertTrue(editor.cancelPlannedMeal())
        XCTAssertTrue(meal.isCancelledMeal)
        XCTAssertNil(try store.metadata(for: operation.mealUUID))
        let bolus = try XCTUnwrap(entries.first { $0.localTreatmentUUID == operation.bolusUUID })
        XCTAssertFalse(bolus.treatmentdeleted)
        XCTAssertEqual(bolus.value, 2)
    }

    @MainActor func testBolusDeletionRemovesInsulinFollowupButKeepsFoodPlan() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealPlanMetadataStore(directory: directory)
        let journal = PenDoseLogJournal(directory: directory)
        let operation = PenDoseLogOperation()
        let now = Date()
        let result = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 3,
            carbohydrateGrams: 35, mealKind: .normal, plannedDate: now.addingTimeInterval(20 * 60),
            operation: operation, now: now, journal: journal, metadataStore: store)
        guard case .success = result else { return XCTFail("Planned meal should save") }
        let entries = TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil)
        let bolus = try XCTUnwrap(entries.first { $0.localTreatmentUUID == operation.bolusUUID })
        let meal = try XCTUnwrap(entries.first { $0.localTreatmentUUID == operation.mealUUID })
        let editor = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: bolus,
            localSaveJournal: journal, mealMetadataStore: store)
        XCTAssertTrue(editor.deleteTreatment())
        let metadata = try XCTUnwrap(store.metadata(for: operation.mealUUID))
        XCTAssertNil(metadata.bolusUUID)
        XCTAssertNil(metadata.followupAt)
        XCTAssertTrue(meal.isPlannedMeal)
        XCTAssertFalse(meal.treatmentdeleted)
    }

    @MainActor func testReminderMetadataFailureAfterVerifiedSaveCannotDuplicateTreatment() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealPlanMetadataStore(directory: directory)
        let journal = PenDoseLogJournal(directory: directory)
        let operation = PenDoseLogOperation()
        let now = Date()
        let result = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 2,
            carbohydrateGrams: 25, mealKind: .slow, plannedDate: now.addingTimeInterval(15 * 60),
            operation: operation, now: now, journal: journal, metadataStore: store,
            saveOverride: {
                guard core.saveChangesSynchronously() else { return false }
                let url = directory.appendingPathComponent("PenDose/MealPlans/\(operation.mealUUID).json")
                try? Data("damaged metadata".utf8).write(to: url, options: .atomic)
                return true
            })
        guard case .success(let receipt) = result else {
            return XCTFail("Verified treatment must not be reported as a failed log")
        }
        XCTAssertNotNil(receipt.reminderWarning)
        XCTAssertEqual(TreatmentEntryAccessor(coreDataManager: core)
            .getLatestTreatments(howOld: nil).filter { !$0.treatmentdeleted }.count, 2)
        XCTAssertEqual(journal.recoveryState(coreDataManager: core), .ready)
    }

    @MainActor func testJournalIdentityCannotBeRetriedWithDifferentAmountsOrTime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PenDoseLogJournal(directory: directory)
        let operation = PenDoseLogOperation()
        let now = Date()
        let original = PenDoseLogIntent(insulinUnits: 2, carbohydrateGrams: 30,
            mealKind: .slow, insulinDate: now, mealDate: now.addingTimeInterval(15 * 60))
        XCTAssertTrue(journal.begin(operation, expectsBolus: true, expectsMeal: true, intent: original))
        XCTAssertTrue(journal.begin(operation, expectsBolus: true, expectsMeal: true, intent: original))
        let changedAmount = PenDoseLogIntent(insulinUnits: 2.5, carbohydrateGrams: 30,
            mealKind: .slow, insulinDate: now, mealDate: now.addingTimeInterval(15 * 60))
        XCTAssertFalse(journal.begin(operation, expectsBolus: true, expectsMeal: true,
            intent: changedAmount))
        let changedTime = PenDoseLogIntent(insulinUnits: 2, carbohydrateGrams: 30,
            mealKind: .slow, insulinDate: now.addingTimeInterval(10),
            mealDate: now.addingTimeInterval(15 * 60))
        XCTAssertFalse(journal.begin(operation, expectsBolus: true, expectsMeal: true,
            intent: changedTime))
    }

    @MainActor func testLoggerChecksConfiguredPenMaximumAndStepBeforeStoreWrite() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = PenDoseProfile.prefilledUnconfirmed.settings
        settings.penStepUnits = 0.25
        settings.maximumSuggestionUnits = 3
        let journal = PenDoseLogJournal(directory: directory)
        let store = MealPlanMetadataStore(directory: directory)
        let tooHigh = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 3.25,
            carbohydrateGrams: 0, mealKind: .normal, plannedDate: nil, journal: journal,
            penSettings: settings, metadataStore: store)
        guard case .failure(.invalidInput) = tooHigh else { return XCTFail("Configured maximum must apply") }
        let offStep = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 2.3,
            carbohydrateGrams: 0, mealKind: .normal, plannedDate: nil, journal: journal,
            penSettings: settings, metadataStore: store)
        guard case .failure(.invalidInput) = offStep else { return XCTFail("Configured pen step must apply") }
        XCTAssertTrue(TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil).isEmpty)
        let valid = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 2.25,
            carbohydrateGrams: 0, mealKind: .normal, plannedDate: nil, journal: journal,
            penSettings: settings, metadataStore: store)
        guard case .success = valid else { return XCTFail("An exact 0.25 E step must be accepted") }
        XCTAssertEqual(TreatmentEntryAccessor(coreDataManager: core)
            .getLatestTreatments(howOld: nil).first?.value, 2.25)
    }

    @MainActor func testLoggerKeepsCarbohydrateOnlyLogAvailableWithoutPenBounds() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var unavailable = PenDoseProfile.prefilledUnconfirmed.settings
        unavailable.penStepUnits = 0
        unavailable.maximumSuggestionUnits = 0
        let journal = PenDoseLogJournal(directory: directory)
        let metadata = MealPlanMetadataStore(directory: directory)
        let food = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 0,
            carbohydrateGrams: 18, mealKind: .fast, plannedDate: nil,
            journal: journal, penSettings: unavailable, metadataStore: metadata)
        guard case .success = food else {
            return XCTFail("Carbohydrates must be loggable without insulin pen bounds")
        }
        let insulin = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 2,
            carbohydrateGrams: 0, mealKind: .normal, plannedDate: nil,
            journal: journal, penSettings: unavailable, metadataStore: metadata)
        guard case .failure(.invalidInput) = insulin else {
            return XCTFail("Insulin must still require valid pen bounds")
        }
        let entries = TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.treatmentType, .Carbs)
        XCTAssertEqual(entries.first?.value, 18)
    }

    @MainActor func testConfirmedPizzaEditUpdatesFutureReminderWithoutRevivingPastOne() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealPlanMetadataStore(directory: directory)
        let journal = PenDoseLogJournal(directory: directory)
        let operation = PenDoseLogOperation()
        let now = Date()
        let pizza = PizzaSplitSettings(isEnabled: true, percentageNow: 70, reminderMinutes: 90)
        let logged = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 2,
            carbohydrateGrams: 45, mealKind: .slow, plannedDate: nil,
            operation: operation, now: now, journal: journal,
            pizzaSettings: pizza, metadataStore: store)
        guard case .success = logged else { return XCTFail("Pizza treatment should save") }
        let originalDue = try XCTUnwrap(store.metadata(for: operation.mealUUID)?.pizzaReminderAt)
        let meal = try XCTUnwrap(TreatmentEntryAccessor(coreDataManager: core)
            .getLatestTreatments(howOld: nil).first { $0.localTreatmentUUID == operation.mealUUID })
        let editor = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: meal,
            localSaveJournal: journal, mealMetadataStore: store)
        editor.selectedDate = now.addingTimeInterval(-10 * 60)
        editor.enteredValue = "50"
        XCTAssertTrue(editor.saveTreatment())
        let edited = try XCTUnwrap(store.metadata(for: operation.mealUUID))
        let editedDue = try XCTUnwrap(edited.pizzaReminderAt)
        XCTAssertLessThan(editedDue, originalDue)
        XCTAssertEqual(edited.lastStoredMealGrams, 50)
        XCTAssertEqual(edited.lastStoredMealDate, meal.date)
        meal.date = now.addingTimeInterval(-15 * 60)
        XCTAssertTrue(core.saveChangesSynchronously())
        let warning = MealPlanReminderCoordinator.refresh(coreDataManager: core,
            mealUUID: operation.mealUUID, now: editedDue.addingTimeInterval(1), store: store)
        XCTAssertNil(warning)
        XCTAssertEqual(try store.metadata(for: operation.mealUUID)?.pizzaReminderAt, editedDue,
            "A due reminder must never be recreated with a new deadline")
        meal.mealKindRaw = TreatmentMealKind.normal.rawValue
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertNil(MealPlanReminderCoordinator.refresh(coreDataManager: core,
            mealUUID: operation.mealUUID, store: store))
        XCTAssertNil(try store.metadata(for: operation.mealUUID)?.pizzaReminderAt)
        meal.mealKindRaw = TreatmentMealKind.slow.rawValue
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertNil(MealPlanReminderCoordinator.refresh(coreDataManager: core,
            mealUUID: operation.mealUUID, store: store))
        XCTAssertNil(try store.metadata(for: operation.mealUUID)?.pizzaReminderAt,
            "Changing the kind back must not revive an obsolete split reminder")
    }

    @MainActor func testManualInsulinCanLogWithNoCalculationAfterSingleConfirmation() async throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var profile = PenDoseProfile.prefilledUnconfirmed
        XCTAssertTrue(profile.confirm())
        let vm = PenDoseCalculatorViewModel(coreDataManager: core,
            logJournal: PenDoseLogJournal(directory: directory),
            metadataStore: MealPlanMetadataStore(directory: directory),
            profileProvider: { profile }, sourceReadyOverride: { true },
            snapshotProvider: { _, _ in .failure(.missingGlucose) })
        vm.insulinToLogText = "2,0"
        XCTAssertEqual(vm.carbohydratesText, "")
        XCTAssertTrue(vm.canLog)
        XCTAssertTrue(vm.requestLog(), "Missing calculation requires one confirmation")
        XCTAssertEqual(vm.confirmationDraft?.insulinUnits, 2)
        XCTAssertEqual(vm.confirmationDraft?.carbohydrateGrams, 0)
        XCTAssertFalse(vm.canLog, "The same registration cannot start twice")
        let saved = await vm.confirmLog()
        XCTAssertTrue(saved)
        XCTAssertNil(vm.confirmationDraft)
        XCTAssertEqual(TreatmentEntryAccessor(coreDataManager: core)
            .getLatestTreatments(howOld: nil).filter { $0.treatmentType == .Insulin }.count, 1)
    }

    @MainActor func testStaleConfirmationDoesNotBackdateInsulinOrClearEnteredDose() async throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let vm = PenDoseCalculatorViewModel(coreDataManager: core,
            logJournal: PenDoseLogJournal(directory: directory),
            metadataStore: MealPlanMetadataStore(directory: directory),
            sourceReadyOverride: { true },
            snapshotProvider: { _, _ in .failure(.missingGlucose) })
        vm.insulinToLogText = "2,0"
        XCTAssertTrue(vm.requestLog())
        let requestedAt = try XCTUnwrap(vm.confirmationDraft?.loggedAt)
        let saved = await vm.confirmLog(at: requestedAt.addingTimeInterval(6 * 60))
        XCTAssertFalse(saved)
        XCTAssertNil(vm.confirmationDraft)
        XCTAssertEqual(vm.insulinToLogText, "2,0")
        XCTAssertTrue(TreatmentEntryAccessor(coreDataManager: core)
            .getLatestTreatments(howOld: nil).isEmpty)
        XCTAssertTrue(vm.requestLog(), "A new tap creates a fresh registration attempt")
    }

    @MainActor func testEmptyAmountsAndCalculationFailurePreserveUserFields() async throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var profile = PenDoseProfile.prefilledUnconfirmed
        XCTAssertTrue(profile.confirm())
        let vm = PenDoseCalculatorViewModel(coreDataManager: core,
            logJournal: PenDoseLogJournal(directory: directory),
            metadataStore: MealPlanMetadataStore(directory: directory),
            profileProvider: { profile }, sourceReadyOverride: { true },
            snapshotProvider: { _, _ in .failure(.missingGlucose) })
        XCTAssertFalse(vm.canLog)
        vm.carbohydratesText = "45"
        XCTAssertTrue(vm.canLog)
        XCTAssertFalse(vm.requestLog(), "Carbohydrates alone need no insulin warning")
        XCTAssertEqual(vm.confirmationDraft?.insulinUnits, 0)
        vm.cancelLogConfirmation()
        vm.insulinToLogText = "2"
        await vm.calculate()
        XCTAssertEqual(vm.carbohydratesText, "45")
        XCTAssertEqual(vm.insulinToLogText, "2")
        XCTAssertNil(vm.suggestedUnits)
        vm.carbohydratesText = "0"
        vm.insulinToLogText = "0"
        XCTAssertFalse(vm.canLog)
        vm.carbohydratesText = "abc"
        XCTAssertFalse(vm.canLog, "Invalid nonempty text is never zero")
    }

    @MainActor func testExpiredPlanDuringConfirmationDoesNotSaveOrConsumeFood() async throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var profile = PenDoseProfile.prefilledUnconfirmed
        XCTAssertTrue(profile.confirm())
        let vm = PenDoseCalculatorViewModel(coreDataManager: core,
            logJournal: PenDoseLogJournal(directory: directory),
            metadataStore: MealPlanMetadataStore(directory: directory),
            profileProvider: { profile }, sourceReadyOverride: { true })
        vm.carbohydratesText = "45"
        vm.insulinToLogText = "2"
        vm.isPlannedMeal = true
        vm.plannedDate = Date().addingTimeInterval(1.5)
        XCTAssertTrue(vm.requestLog())
        try await Task.sleep(for: .seconds(1.7))
        let saved = await vm.confirmLog()
        XCTAssertFalse(saved)
        XCTAssertTrue(vm.expiredPlan)
        XCTAssertTrue(TreatmentEntryAccessor(coreDataManager: core)
            .getLatestTreatments(howOld: nil).isEmpty)
    }

    @MainActor func testPenDoseRetryAfterUncertainSaveReusesStableTreatmentIDs() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PenDoseLogJournal(directory: directory, processToken: "first-launch")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let operation = PenDoseLogOperation(bolusUUID: UUID().uuidString, mealUUID: UUID().uuidString)
        let uncertain = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 2,
            carbohydrateGrams: 24, mealKind: .normal, plannedDate: nil,
            operation: operation, now: now, journal: journal, saveOverride: { false })
        guard case .failure(.storageFailed) = uncertain else {
            return XCTFail("An unconfirmed save must not produce a success receipt")
        }
        XCTAssertEqual(journal.recoveryState(coreDataManager: core), .awaitingRestart)
        let reopenedSameProcess = PenDoseCalculatorViewModel(coreDataManager: core,
            logJournal: journal)
        XCTAssertEqual(reopenedSameProcess.storageGateState, .awaitingRestart)
        XCTAssertFalse(reopenedSameProcess.canLog)
        let differentOperation = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 2,
            carbohydrateGrams: 24, mealKind: .normal, plannedDate: nil,
            operation: PenDoseLogOperation(), now: now, journal: journal)
        guard case .failure(.storageFailed) = differentOperation else {
            return XCTFail("A new ID must be blocked while the prior save is uncertain")
        }
        let retried = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 2,
            carbohydrateGrams: 24, mealKind: .normal, plannedDate: nil,
            operation: operation, now: now, journal: journal)
        guard case .success = retried else { return XCTFail("Retry with the same IDs should save") }
        let entries = TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.compactMap(\.localTreatmentUUID)),
                       Set([operation.bolusUUID, operation.mealUUID]))
    }

    @MainActor func testPenDoseDraftCannotLogWithoutACompletedReview() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = PenDoseCalculatorViewModel(coreDataManager: core,
            logJournal: PenDoseLogJournal(directory: directory))
        XCTAssertNil(draft.calculation)
        XCTAssertFalse(draft.canLog)
        draft.insulinToLogText = "0"
        XCTAssertFalse(draft.canLog, "Unknown IOB or COB must never appear as a valid zero dose")
    }

    @MainActor func testPenDosePendingJournalBlocksReopenAfterDurableButUnacknowledgedSave() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = PenDoseLogJournal(directory: directory, processToken: "first")
        let operation = PenDoseLogOperation()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let uncertain = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 1,
            carbohydrateGrams: 12, mealKind: .normal, plannedDate: nil,
            operation: operation, now: now, journal: first,
            saveOverride: { core.saveChangesSynchronously() && false })
        guard case .failure(.storageFailed) = uncertain else { return XCTFail() }
        let afterRestart = PenDoseLogJournal(directory: directory, processToken: "second")
        XCTAssertEqual(afterRestart.recoveryState(coreDataManager: core), .foundPriorEntry)
        let reopened = PenDoseCalculatorViewModel(coreDataManager: core, logJournal: afterRestart)
        XCTAssertEqual(reopened.storageGateState, .foundPriorEntry)
        XCTAssertFalse(reopened.canLog)
        reopened.acknowledgePreviouslyFoundTreatment()
        XCTAssertEqual(reopened.storageGateState, .ready)
        XCTAssertEqual(afterRestart.recoveryState(coreDataManager: core), .ready)
    }

    @MainActor func testDirectEditorWritesMarkerBeforeNewBolusAndBlocksUncertainReopen() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PenDoseLogJournal(directory: directory, processToken: "first")
        let editor = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: nil,
            initialType: .Insulin, localSaveJournal: journal,
            localSaveOverride: {
                XCTAssertEqual(journal.recoveryState(coreDataManager: core), .awaitingRestart,
                    "The marker must be written before inserting/saving the treatment")
                return core.saveChangesSynchronously() && false
            })
        editor.enteredValue = "2"
        XCTAssertFalse(editor.saveTreatment())
        XCTAssertEqual(editor.localSaveGateState, .awaitingRestart)
        XCTAssertFalse(editor.canSaveTreatment)

        let sameProcess = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: nil,
            initialType: .Insulin, localSaveJournal: journal)
        sameProcess.enteredValue = "2"
        XCTAssertFalse(sameProcess.canSaveTreatment, "A reopened editor must not create a second dose")

        let afterRestart = PenDoseLogJournal(directory: directory, processToken: "second")
        let newEditor = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: nil,
            initialType: .Insulin, localSaveJournal: afterRestart)
        XCTAssertEqual(newEditor.localSaveGateState, .foundPriorEntry)
        XCTAssertFalse(newEditor.canSaveTreatment)
        XCTAssertEqual(TreatmentEntryAccessor(coreDataManager: core)
            .getLatestTreatments(howOld: nil).filter { $0.treatmentType == .Insulin }.count, 1)
        newEditor.acknowledgePreviouslyFoundTreatment()
        XCTAssertEqual(newEditor.localSaveGateState, .ready)
    }

    @MainActor func testMissingLocalRowAfterFailureRequiresHealthReviewBeforeRetry() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = PenDoseLogJournal(directory: directory, processToken: "first")
        XCTAssertTrue(first.begin(PenDoseLogOperation(), expectsBolus: true, expectsMeal: false))
        let afterRestart = PenDoseLogJournal(directory: directory, processToken: "second")
        XCTAssertEqual(afterRestart.recoveryState(coreDataManager: core), .noLocalEntryHealthUncertain)
        XCTAssertFalse(afterRestart.begin(PenDoseLogOperation(), expectsBolus: true, expectsMeal: false),
            "Zero local rows must not silently erase uncertainty about a possible Health copy")
        let editor = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: nil,
            initialType: .Insulin, localSaveJournal: afterRestart)
        XCTAssertFalse(editor.canSaveTreatment)
        editor.acknowledgePreviouslyFoundTreatment()
        XCTAssertEqual(editor.localSaveGateState, .ready)
    }

    @MainActor func testPenDoseReviewRejectsSameTimeRecalibrationAndTreatmentRevisionChange() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let settings = TherapyModelSettings(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let glucose = [GlucoseForecastSample(date: now, glucoseMgdl: 120, sensorID: "sensor")]
        let original = try XCTUnwrap(PenDoseInputSnapshot.make(capturedAt: now,
            glucose: glucose, treatments: [], therapySettings: settings,
            treatmentRevision: 1).get())
        let same = try XCTUnwrap(PenDoseInputSnapshot.make(capturedAt: now.addingTimeInterval(10),
            glucose: glucose, treatments: [], therapySettings: settings,
            treatmentRevision: 1).get())
        XCTAssertTrue(PenDoseCalculatorViewModel.reviewInputsMatch(original, same))
        let recalibrated = try XCTUnwrap(PenDoseInputSnapshot.make(capturedAt: now,
            glucose: [GlucoseForecastSample(date: now, glucoseMgdl: 121, sensorID: "sensor")],
            treatments: [], therapySettings: settings, treatmentRevision: 1).get())
        XCTAssertFalse(PenDoseCalculatorViewModel.reviewInputsMatch(original, recalibrated))
        let changedSource = try XCTUnwrap(PenDoseInputSnapshot.make(capturedAt: now,
            glucose: [GlucoseForecastSample(date: now, glucoseMgdl: 120, sensorID: "other")],
            treatments: [], therapySettings: settings, treatmentRevision: 1).get())
        XCTAssertFalse(PenDoseCalculatorViewModel.reviewInputsMatch(original, changedSource))
        let changedRevision = try XCTUnwrap(PenDoseInputSnapshot.make(capturedAt: now,
            glucose: glucose, treatments: [], therapySettings: settings,
            treatmentRevision: 2).get())
        XCTAssertFalse(PenDoseCalculatorViewModel.reviewInputsMatch(original, changedRevision))
    }

    @MainActor func testEditedDoseRequiresFreshStoreVerificationBeforeClearingMutationGate() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PenDoseLogJournal(directory: directory)
        let entry = TreatmentEntry(date: Date().addingTimeInterval(-60), value: 2,
            treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "Test",
            nsManagedObjectContext: core.mainManagedObjectContext)
        entry.localTreatmentUUID = UUID().uuidString
        XCTAssertTrue(core.saveChangesSynchronously())
        let editor = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: entry,
            localSaveJournal: journal)
        editor.enteredValue = "2.5"
        XCTAssertTrue(editor.saveTreatment())
        XCTAssertEqual(journal.recoveryState(coreDataManager: core), .ready)
        XCTAssertEqual(entry.value, 2.5)
    }

    @MainActor func testFailedDoseEditRemainsBlockedAfterLaterStoreSaveAndRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("dose.sqlite")
        let core = try CoreDataManager(testModelName: ConstantsCoreData.modelName,
                                      persistentStoreURL: storeURL)
        let journal = PenDoseLogJournal(directory: directory, processToken: "before-restart")
        let entry = TreatmentEntry(date: Date().addingTimeInterval(-60), value: 2,
            treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "Test",
            nsManagedObjectContext: core.mainManagedObjectContext)
        entry.localTreatmentUUID = UUID().uuidString
        XCTAssertTrue(core.saveChangesSynchronously())
        let editor = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: entry,
            localSaveJournal: journal, localSaveOverride: {
                // Simulate the child succeeding and the private-store save failing. Its dirty
                // parent can later commit during unrelated work, but the durable gate remains.
                do { try core.mainManagedObjectContext.save() }
                catch { XCTFail("Child save failed: \(error)") }
                return false
            })
        editor.enteredValue = "3"
        XCTAssertFalse(editor.saveTreatment())
        XCTAssertEqual(journal.recoveryState(coreDataManager: core), .awaitingRestart)
        let calculator = PenDoseCalculatorViewModel(coreDataManager: core, logJournal: journal)
        XCTAssertFalse(calculator.canLog)
        XCTAssertTrue(core.saveChangesSynchronously(), "An unrelated later save can persist the edit")
        XCTAssertEqual(journal.recoveryState(coreDataManager: core), .awaitingRestart,
                       "A later save must not silently certify the failed mutation")

        try core.disconnectPersistentStoresForTesting()
        let reopened = try CoreDataManager(testModelName: ConstantsCoreData.modelName,
                                           persistentStoreURL: storeURL)
        let afterRestart = PenDoseLogJournal(directory: directory, processToken: "after-restart")
        XCTAssertEqual(afterRestart.recoveryState(coreDataManager: reopened), .uncertainMutationAfterRestart)
        let reopenedCalculator = PenDoseCalculatorViewModel(coreDataManager: reopened,
                                                            logJournal: afterRestart)
        XCTAssertFalse(reopenedCalculator.canLog)
        let persisted = TreatmentEntryAccessor(coreDataManager: reopened)
            .getLatestTreatments(howOld: nil).first
        XCTAssertEqual(persisted?.value, 3)
    }

    @MainActor func testSwipeDoseDeletionNeedsVerifiedStoreSaveAndKeepsFailureGate() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PenDoseLogJournal(directory: directory, processToken: "delete")
        let entry = TreatmentEntry(date: Date(), value: 20, treatmentType: .Carbs,
            nightscoutEventType: nil, enteredBy: "Test",
            nsManagedObjectContext: core.mainManagedObjectContext)
        entry.localTreatmentUUID = UUID().uuidString
        XCTAssertTrue(core.saveChangesSynchronously())
        let snapshot = TreatmentSnapshot(treatmentEntry: entry)
        let list = TreatmentsViewModel(coreDataManager: core, localSaveJournal: journal,
            localSaveOverride: {
                do { try core.mainManagedObjectContext.save() }
                catch { XCTFail("Child save failed: \(error)") }
                return false
            })
        XCTAssertFalse(list.deleteTreatment(snapshot))
        XCTAssertNotNil(list.deletionFailureMessage)
        XCTAssertEqual(journal.recoveryState(coreDataManager: core), .awaitingRestart)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertEqual(journal.recoveryState(coreDataManager: core), .awaitingRestart)
        let second = PenDoseTreatmentLogger.log(coreDataManager: core, insulinUnits: 2,
            carbohydrateGrams: 0, mealKind: .normal, plannedDate: nil, journal: journal)
        guard case .failure(.storageFailed) = second else {
            return XCTFail("Uncertain deletion must block a new dose")
        }
    }
}

/// Simulator file protection setters succeed but reads omit protectionKey. Keep only that
/// attribute in an overlay tied to the real file identity; all disk reads/writes remain real.
/// These tests exercise the protection guard, not physical iOS at-rest data protection.
private final class MealMetadataProtectionFileManager: FileManager, @unchecked Sendable {
    private let protectionLock = NSLock()
    private var protections: [String: (fileNumber: NSNumber, value: FileProtectionType)] = [:]

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        try super.setAttributes(attributes, ofItemAtPath: path)
        if let protection = attributes[.protectionKey] as? FileProtectionType,
           let fileNumber = try super.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber {
            protectionLock.lock()
            protections[path] = (fileNumber, protection)
            protectionLock.unlock()
        }
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        var attributes = try super.attributesOfItem(atPath: path)
        protectionLock.lock()
        let protection = protections[path]
        protectionLock.unlock()
        if let protection, attributes[.systemFileNumber] as? NSNumber == protection.fileNumber {
            attributes[.protectionKey] = protection.value
        }
        return attributes
    }
}

/// Serves a fixed treatment response without contacting a Nightscout server.
private final class BasalInjectionTestURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let notes = BasalInjectionPayload(units: 20, insulinDescription: "Tresiba")!.encodedNotes()!
        let data = try! JSONSerialization.data(withJSONObject: [["_id": "basaltest", "created_at": "2026-09-07T20:00:00Z", "eventType": "Note", "notes": notes, "insulin": 20] as [String: Any]])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor final class WatchPenPhoneServiceTests: XCTestCase {
    private func operation(insulin: Double, carbs: Double, meal: String = "normal",
                           pizzaReminder: Bool = false,
                           recordedAt: Date = Date()) -> WatchBolusOperation {
        WatchBolusOperation(operationID: UUID(), insulinID: UUID(), carbsID: UUID(),
            recordedAt: recordedAt, insulinUnits: insulin,
            carbohydrateGrams: carbs, mealKindRaw: meal,
            pizzaReminderRequested: pizzaReminder,
            manualWithoutCurrentSuggestion: insulin > 0,
            penStepUnits: insulin > 0 ? 0.5 : nil,
            maximumUnits: insulin > 0 ? 25 : nil,
            profileSignature: insulin > 0 ? "confirmed-on-watch" : nil)
    }

    func testCombinedWatchLogUsesFrozenIDsTimeMealAndSurvivesLostReceiptAndEdit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let ledger = WatchPenOperationLedger(directory: root.appendingPathComponent("receipts"))
        let journal = PenDoseLogJournal(directory: root)
        let metadata = MealPlanMetadataStore(directory: root)
        let when = Date().addingTimeInterval(-120)
        let frozen = operation(insulin: 4.5, carbs: 30, meal: "slow",
            pizzaReminder: false, recordedAt: when)

        func submit(_ item: WatchBolusOperation,
                    using receiptStore: WatchPenOperationLedger) -> WatchPenPhoneService.LogOutcome {
            WatchPenPhoneService.log(item, coreDataManager: core, ledger: receiptStore,
                journal: journal, metadataStore: metadata,
                sourceReadyOverride: { true })
        }
        XCTAssertEqual(submit(frozen, using: ledger), .stored)
        let entries = TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil)
        XCTAssertEqual(entries.count, 2)
        let bolus = try XCTUnwrap(entries.first { $0.localTreatmentUUID == frozen.insulinID.uuidString })
        let meal = try XCTUnwrap(entries.first { $0.localTreatmentUUID == frozen.carbsID.uuidString })
        XCTAssertEqual(bolus.date, when)
        XCTAssertEqual(meal.date, when)
        XCTAssertEqual(meal.mealKind, .slow)
        XCTAssertEqual(meal.effectiveCarbohydrateDurationMinutes, 300)
        XCTAssertEqual(bolus.notes, "Manuelt logget uden aktuelt kontrolleret forslag")
        XCTAssertNil(try metadata.metadata(for: frozen.carbsID.uuidString)?.pizzaReminderAt,
            "An offline Watch log must never acquire a pizza reminder during phone delivery")

        // The first acknowledgement was lost; the process may have rebuilt its receipt store.
        let reopenedLedger = WatchPenOperationLedger(directory: root.appendingPathComponent("receipts"))
        XCTAssertEqual(submit(frozen, using: reopenedLedger), .stored)
        bolus.value = 5
        meal.treatmentdeleted = true
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertEqual(submit(frozen, using: reopenedLedger), .stored,
            "A known retry acknowledges the original operation without restoring user edits")
        let all = try core.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest())
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(bolus.value, 5)
        XCTAssertTrue(meal.treatmentdeleted)

        let conflicting = WatchBolusOperation(operationID: frozen.operationID,
            insulinID: frozen.insulinID, carbsID: frozen.carbsID,
            recordedAt: when, insulinUnits: 5, carbohydrateGrams: 30,
            mealKindRaw: "slow", pizzaReminderRequested: false,
            manualWithoutCurrentSuggestion: true,
            penStepUnits: 0.5, maximumUnits: 25,
            profileSignature: "confirmed-on-watch")
        XCTAssertEqual(submit(conflicting, using: reopenedLedger), .conflictingOperation)
        XCTAssertEqual(try core.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest()).count, 2)
    }

    func testDurableWatchLogRecoveryRefreshesFrozenPizzaReminderWithoutNewRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let ledger = WatchPenOperationLedger(directory: root.appendingPathComponent("receipts"))
        let metadata = MealPlanMetadataStore(directory: root)
        let now = Date()
        let frozen = operation(insulin: 2.5, carbs: 30, meal: "slow",
            pizzaReminder: true, recordedAt: now.addingTimeInterval(-60))
        let pizza = PizzaSplitSettings(isEnabled: true, percentageNow: 70, reminderMinutes: 90)
        guard case .pending = ledger.reserve(frozen, pizzaSettings: pizza) else {
            return XCTFail("The operation must first have a durable pending receipt")
        }
        var staged = MealPlanMetadata(mealUUID: frozen.carbsID.uuidString,
            bolusUUID: frozen.insulinID.uuidString, loggedAt: frozen.recordedAt,
            plannedAt: nil, grams: frozen.carbohydrateGrams,
            pizzaSettings: pizza, mealKind: .slow)
        staged.pizzaReminderAt = nil // Prior process ended before its reminder refresh.
        try metadata.stage(staged)
        let bolus = TreatmentEntry(date: frozen.recordedAt, value: frozen.insulinUnits,
            treatmentType: .Insulin, nightscoutEventType: nil,
            enteredBy: "xDrip4iOS Watch", nsManagedObjectContext: core.mainManagedObjectContext)
        bolus.localTreatmentUUID = frozen.insulinID.uuidString
        let meal = TreatmentEntry(date: frozen.recordedAt, value: frozen.carbohydrateGrams,
            treatmentType: .Carbs, nightscoutEventType: nil,
            enteredBy: "xDrip4iOS Watch", nsManagedObjectContext: core.mainManagedObjectContext)
        meal.localTreatmentUUID = frozen.carbsID.uuidString
        meal.mealKindRaw = frozen.mealKindRaw
        XCTAssertTrue(core.saveChangesSynchronously())

        XCTAssertEqual(WatchPenPhoneService.log(frozen, coreDataManager: core,
            ledger: ledger, metadataStore: metadata, now: now), .stored)
        let recovered = try XCTUnwrap(metadata.metadata(for: frozen.carbsID.uuidString))
        XCTAssertEqual(recovered.pizzaReminderAt,
            MealPlanMetadata.pizzaDueAt(actualMealAt: frozen.recordedAt,
                confirmedAt: now, intervalMinutes: 90))
        XCTAssertEqual(try core.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest()).count, 2)
        XCTAssertEqual(WatchPenPhoneService.log(frozen, coreDataManager: core,
            ledger: ledger, metadataStore: metadata, now: now), .stored)
        XCTAssertEqual(try core.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest()).count, 2)
    }

    func testWatchCarbsOnlyNeedsNoPenBoundsAndInsulinOnlyUsesFrozenBounds() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let ledger = WatchPenOperationLedger(directory: root.appendingPathComponent("receipts"))
        let journal = PenDoseLogJournal(directory: root)
        let metadata = MealPlanMetadataStore(directory: root)
        let food = operation(insulin: 0, carbs: 18, meal: "fast")
        XCTAssertEqual(WatchPenPhoneService.log(food, coreDataManager: core,
            ledger: ledger, journal: journal, metadataStore: metadata,
            sourceReadyOverride: { true }), .stored)
        let insulin = operation(insulin: 2.5, carbs: 0)
        XCTAssertEqual(WatchPenPhoneService.log(insulin, coreDataManager: core,
            ledger: ledger, journal: journal, metadataStore: metadata,
            sourceReadyOverride: { true }), .stored)
        let entries = TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first { $0.treatmentType == .Carbs }?.mealKind, .fast)
        XCTAssertEqual(entries.first { $0.treatmentType == .Insulin }?.value, 2.5)
    }

    func testWatchCalculationRejectsPendingTherapyAndCGMBeforeReadingSnapshot() async {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let request = WatchPenCalculationRequest(requestID: UUID(), carbohydrateGrams: 30,
            mealKindRaw: "normal", pendingTreatmentIDs: [UUID()], pendingReadingIDs: [],
            latestWatchReadingAt: nil, profileSignature: "stale")
        let result = await WatchPenPhoneService.calculate(request, coreDataManager: core)
        guard case .failure(let error) = result else {
            return XCTFail("Unconfirmed Watch treatments must stop calculation")
        }
        XCTAssertTrue(error.message.contains("Ventende behandlinger"))

        let legacyID = request.pendingTreatmentIDs[0]
        let legacy = TreatmentEntry(date: Date(), value: 2,
            treatmentType: .Insulin, nightscoutEventType: nil,
            enteredBy: "xDrip4iOS Watch", nsManagedObjectContext: core.mainManagedObjectContext)
        legacy.watchSourceUUID = legacyID.uuidString
        XCTAssertTrue(core.saveChangesSynchronously())
        let afterStorage = await WatchPenPhoneService.calculate(request, coreDataManager: core)
        guard case .failure(let laterError) = afterStorage else {
            return XCTFail("The deliberately stale profile should still reject calculation")
        }
        XCTAssertTrue(laterError.message.contains("Doseringsprofilen"),
            "Durable legacy Watch treatment storage must satisfy the pending-ID gate")

        let readingRequest = WatchPenCalculationRequest(requestID: UUID(),
            carbohydrateGrams: 30, mealKindRaw: "normal", pendingTreatmentIDs: [],
            pendingReadingIDs: [UUID()], latestWatchReadingAt: nil,
            profileSignature: "stale")
        let afterReadingStorage = await WatchPenPhoneService.calculate(readingRequest,
            coreDataManager: core, confirmedReading: { $0 == readingRequest.pendingReadingIDs[0] })
        guard case .failure(let readingError) = afterReadingStorage else {
            return XCTFail("The deliberately stale profile should still reject calculation")
        }
        XCTAssertTrue(readingError.message.contains("Doseringsprofilen"),
            "Existing Libre durable storage evidence must satisfy the pending CGM gate")
    }

    func testPendingWatchCGMRequiresValidatedParentStoreCommit() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let sensor = Sensor(startDate: Date().addingTimeInterval(-3600),
            nsManagedObjectContext: core.mainManagedObjectContext)
        let payloadID = UUID()
        let reading = BgReading(timeStamp: Date(), sensor: sensor, calibration: nil,
            rawData: 85, deviceName: nil,
            nsManagedObjectContext: core.mainManagedObjectContext)
        reading.id = payloadID.uuidString
        reading.calculatedValue = 85
        reading.ageAdjustedRawValue = 85
        XCTAssertTrue(reading.isValidForDownstream)
        XCTAssertFalse(WatchPenPhoneService.durablyStoredWatchReading(payloadID,
            sensorID: sensor.id, coreDataManager: core),
            "A validated row in the child context is not yet a durable CGM receipt")

        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertTrue(WatchPenPhoneService.durablyStoredWatchReading(payloadID,
            sensorID: sensor.id, coreDataManager: core))
        XCTAssertFalse(WatchPenPhoneService.durablyStoredWatchReading(payloadID,
            sensorID: UUID().uuidString, coreDataManager: core),
            "A stored reading from another sensor cannot clear the pending ID")

        reading.calculatedValue = 0
        reading.ageAdjustedRawValue = 0
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertFalse(WatchPenPhoneService.durablyStoredWatchReading(payloadID,
            sensorID: sensor.id, coreDataManager: core),
            "A persisted reading that fails downstream validation is not confirmed")
    }
}


/// Exercises the production UUID loader and pending-request delivery, rather than a copy of
/// its age/status rules. The hosting regression also runs the actual Treatments sheets.
final class MealReminderNavigationTests: XCTestCase {
    @MainActor private func meal(_ core: CoreDataManager, age: TimeInterval = 4 * 60 * 60,
                                 state: TreatmentMealState = .confirmed) -> TreatmentEntry {
        let entry = TreatmentEntry(date: Date().addingTimeInterval(-age), value: 45,
            treatmentType: .Carbs, nightscoutEventType: nil, enteredBy: "Synthetic reminder test",
            nsManagedObjectContext: core.mainManagedObjectContext)
        entry.localTreatmentUUID = UUID().uuidString
        entry.mealKindRaw = TreatmentMealKind.slow.rawValue
        entry.plannedMealStateRaw = state.rawValue
        // Match the persisted identity used by the editor. A child-context save alone
        // can leave the test's original object with a temporary ID after parent commit.
        XCTAssertNoThrow(try core.mainManagedObjectContext.obtainPermanentIDs(for: [entry]))
        XCTAssertTrue(core.saveChangesSynchronously())
        return entry
    }

    @MainActor func testFourHourAndDelayedPizzaTapsResolveExactPersistedUUID() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        for age in [4 * 60 * 60, 4 * 60 * 60 + 1, 7 * 24 * 60 * 60] as [TimeInterval] {
            let entry = meal(core, age: age)
            let uuid = try XCTUnwrap(entry.localTreatmentUUID)
            guard case .pizza(let actual) = MealPlanReminderCoordinator.openDestination(
                coreDataManager: core, uuid: uuid, pizza: true) else {
                return XCTFail("A valid persisted meal must survive a delayed reminder tap")
            }
            XCTAssertEqual(actual, uuid)
        }
        XCTAssertEqual(TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil).count, 3,
                       "Resolving a reminder never logs another treatment")
    }

    @MainActor func testPlannedMealUsesStoredIdentityAndPreservesActualDateAndAmount() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let entry = meal(core, age: 2 * 24 * 60 * 60, state: .planned)
        guard case .plannedMeal(let snapshot) = MealPlanReminderCoordinator.openDestination(
            coreDataManager: core, uuid: try XCTUnwrap(entry.localTreatmentUUID), pizza: false) else {
            return XCTFail("An overdue plan still requires the existing confirmation editor")
        }
        XCTAssertEqual(snapshot.objectID, entry.objectID)
        XCTAssertFalse(snapshot.objectID.isTemporaryID)
        let editorEntry = try XCTUnwrap(TreatmentEntryAccessor(coreDataManager: core)
            .getTreatment(objectID: snapshot.objectID))
        XCTAssertEqual(editorEntry.localTreatmentUUID, entry.localTreatmentUUID)
        XCTAssertEqual(snapshot.date, entry.date)
        XCTAssertEqual(snapshot.rawValue, 45)
        XCTAssertTrue(snapshot.isPlannedMeal)
        XCTAssertTrue(entry.isPlannedMeal, "Opening does not confirm eating")
    }

    @MainActor func testDeletedCancelledAndChangedMealsGiveNoticeWithoutReopening() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let entry = meal(core)
        let uuid = try XCTUnwrap(entry.localTreatmentUUID)
        for state in [TreatmentMealState.planned, .cancelled] {
            entry.plannedMealStateRaw = state.rawValue
            XCTAssertTrue(core.saveChangesSynchronously())
            guard case .notice = MealPlanReminderCoordinator.openDestination(
                coreDataManager: core, uuid: uuid, pizza: true) else {
                return XCTFail("An old pizza notification must not reopen a changed meal")
            }
        }
        entry.treatmentdeleted = true
        XCTAssertTrue(core.saveChangesSynchronously())
        for pizza in [false, true] {
            guard case .notice(let message) = MealPlanReminderCoordinator.openDestination(
                coreDataManager: core, uuid: uuid, pizza: pizza) else { return XCTFail("Deleted meal reopened") }
            XCTAssertTrue(message.contains("slettet"))
        }
    }

    @MainActor func testUnavailableStoreKeepsPendingRequestDistinctFromDeletedMeal() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let entry = meal(core)
        let uuid = try XCTUnwrap(entry.localTreatmentUUID)
        try core.disconnectPersistentStoresForTesting()
        var consumed = false
        var reportedUnavailable = false
        XCTAssertTrue(MealPlanReminderCoordinator.deliverOpenRequest(coreDataManager: core,
            uuid: uuid, pizza: true, canPresent: true, present: {
                if case .unavailable = $0 { reportedUnavailable = true }
            }, consume: { _ in consumed = true }))
        XCTAssertTrue(reportedUnavailable)
        XCTAssertFalse(consumed)
    }

    @MainActor func testBlockedPresentationRetainsRequestAndRealSheetAwaitsAppearance() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let entry = meal(core)
        let uuid = try XCTUnwrap(entry.localTreatmentUUID)
        var presentations = 0
        var consumed = false
        for _ in 0..<3 {
            XCTAssertFalse(MealPlanReminderCoordinator.deliverOpenRequest(coreDataManager: core,
                uuid: uuid, pizza: true, canPresent: false,
                present: { _ in presentations += 1 }, consume: { _ in consumed = true }))
        }
        XCTAssertEqual(presentations, 0)
        XCTAssertFalse(consumed)
        XCTAssertTrue(MealPlanReminderCoordinator.deliverOpenRequest(coreDataManager: core,
            uuid: uuid, pizza: true, canPresent: true,
            present: { _ in presentations += 1 }, consume: { _ in consumed = true }))
        XCTAssertEqual(presentations, 1)
        XCTAssertFalse(consumed, "Only actual sheet appearance acknowledges an opening request")
        XCTAssertEqual(TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil).count, 1)
    }

    @MainActor func testOldPresentationAcknowledgementCannotConsumeNewerMealRequest() {
        let defaults = UserDefaults.standard
        let key = "pizzaSplitPendingOpenUUID"
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        let older = UUID().uuidString
        let newer = UUID().uuidString
        defaults.set(newer, forKey: key)
        PizzaSplitReminder.clearPendingOpenUUID(older)
        XCTAssertEqual(PizzaSplitReminder.pendingOpenUUID, newer)
        PizzaSplitReminder.clearPendingOpenUUID(newer)
        XCTAssertNil(PizzaSplitReminder.pendingOpenUUID)
    }

    @MainActor func testActualTreatmentsSheetOpensDelayedPizzaOnceAndPreservesOpenSheet() async throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let entry = meal(core, age: 4 * 60 * 60 + 30)
        let uuid = try XCTUnwrap(entry.localTreatmentUUID)
        let defaults = UserDefaults.standard
        let keys = ["pizzaSplitPendingOpenUUID", "plannedMealPendingOpenUUID"]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        keys.forEach { defaults.removeObject(forKey: $0) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: TreatmentsView(coreDataManager: core)
            .environment(\.scenePhase, .active))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            PlannedMealReminder.cancel(uuid: uuid)
            PizzaSplitReminder.cancel(uuid: uuid)
            try? MealPlanMetadataStore.shared.remove(uuid: uuid)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        let blocker = UIViewController()
        host.present(blocker, animated: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        PizzaSplitReminder.recordTap(uuid: uuid)
        XCTAssertTrue(host.presentedViewController === blocker)
        XCTAssertEqual(PizzaSplitReminder.pendingOpenUUID, uuid,
                       "A different root modal must retain the request and its inputs")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            host.dismiss(animated: false) {
                MealPlanReminderCoordinator.presentationFinished()
                continuation.resume()
            }
        }
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            host.presentedViewController != nil && PizzaSplitReminder.pendingOpenUUID == nil
        }, object: nil)
        await fulfillment(of: [shown], timeout: 4)
        let originalSheet = try XCTUnwrap(host.presentedViewController)
        for _ in 0..<3 { PizzaSplitReminder.recordTap(uuid: uuid) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(host.presentedViewController === originalSheet)
        XCTAssertNil(originalSheet.presentedViewController, "Repeated taps do not stack sheets")
        XCTAssertNil(PizzaSplitReminder.pendingOpenUUID)
        XCTAssertEqual(TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil).count, 1)
    }
}

/// Real root/tab/sheet regression: only the scene phase and synthetic database are injected.
/// No manual Treatments tap or artificial dismissal notification may rescue the route.
final class ReminderRootPresentationTests: XCTestCase {
    @MainActor func testPendingSnoozePickerDoesNotDimHomeBehindAnotherPresentation() async throws {
        let h = try ReminderRootHarness()
        defer { h.finish() }
        h.configure()
        await h.mount(in: self)
        let host = try XCTUnwrap(h.host)
        let blocker = UIViewController()
        blocker.modalPresentationStyle = .overFullScreen
        blocker.view.backgroundColor = .clear
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            host.present(blocker, animated: false) { c.resume() }
        }
        await h.render()
        let before = try rootBrightness(host.view, attachmentName: "Synthetic Home before pending snooze")
        var confirmed: [Int] = []
        var cancelled = 0
        var selected: [Int] = []
        h.root.presentPicker(PickerViewData(withMainTitle: "Synthetic alert",
            withSubTitle: "Select snooze period", withData: ["5 minutes", "15 minutes"],
            selectedRow: 1, withPriority: .normal, actionButtonText: "Snooze",
            cancelButtonText: "Cancel", onActionClick: { confirmed.append($0) },
            onCancelClick: { cancelled += 1 }, didSelectRowHandler: { selected.append($0) }))
        let requestedID = try XCTUnwrap(h.root.pickerData?.id)
        await h.render()

        XCTAssertTrue(host.presentedViewController === blocker)
        XCTAssertNil(blocker.presentedViewController, "The picker is pending, not visibly presented")
        XCTAssertEqual(h.root.pickerData?.id, requestedID)
        XCTAssertEqual(h.selectedTab, 0)
        let pending = try rootBrightness(host.view, attachmentName: "Synthetic Home with pending snooze")
        for (name, baseline, actual) in [
            ("Home and tabs", before.whole, pending.whole),
            ("Lower Home and tab bar", before.bottom, pending.bottom)
        ] {
            XCTAssertGreaterThan(baseline, 0.001, "\(name) must contain visible content")
            XCTAssertEqual(actual, baseline, accuracy: max(0.002, baseline * 0.05),
                "\(name) must not darken merely because a picker request is pending")
        }
        XCTAssertTrue(confirmed.isEmpty)
        XCTAssertEqual(cancelled, 0)
        XCTAssertTrue(selected.isEmpty)
        h.root.pickerData = nil
        await h.render()
    }

    @MainActor func testRootSnoozeSheetsRetainWheelSelectionAndDismissalCallbacks() async throws {
        let defaults = UserDefaults.standard
        let keys = [UserDefaults.Key.preferLargeSnoozeScreen.rawValue,
                    UserDefaults.Key.updateSnoozeStatus.rawValue]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        for large in [false, true] {
            defaults.preferLargeSnoozeScreen = large
            let h = try ReminderRootHarness()
            defer { h.finish() }
            h.configure()
            await h.mount(in: self)
            var confirmed: [Int] = []
            var cancelled = 0
            var selected: [Int] = []
            h.root.presentPicker(PickerViewData(withMainTitle: "Synthetic alert",
                withSubTitle: "Select snooze period", withData: ["5 minutes", "15 minutes"],
                selectedRow: 1, withPriority: .normal, actionButtonText: "Snooze",
                cancelButtonText: "Cancel", onActionClick: { confirmed.append($0) },
                onCancelClick: { cancelled += 1 }, didSelectRowHandler: { selected.append($0) }))
            await wait { h.host?.presentedViewController != nil }
            let sheet = try XCTUnwrap(h.host?.presentedViewController)
            await h.render()
            let wheel = try XCTUnwrap(ReminderRootHarness.descendants(sheet.view)
                .compactMap { $0 as? UIPickerView }.first)
            sheet.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: sheet.view.bounds).image { _ in
                XCTAssertTrue(sheet.view.drawHierarchy(in: sheet.view.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = large ? "Synthetic large snooze sheet" : "Synthetic standard snooze sheet"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(wheel.numberOfRows(inComponent: 0), 2)
            XCTAssertEqual(wheel.selectedRow(inComponent: 0), 1)
            wheel.selectRow(0, inComponent: 0, animated: false)
            wheel.delegate?.pickerView?(wheel, didSelectRow: 0, inComponent: 0)
            await h.render()
            XCTAssertEqual(selected, [0])
            XCTAssertTrue(confirmed.isEmpty, "Changing the wheel must not snooze the alert")
            XCTAssertEqual(cancelled, 0)

            if large {
                // Large alerts prohibit interactive dismissal; ending their presentation
                // programmatically must not manufacture a Cancel or Snooze action.
                h.root.pickerData = nil
            } else {
                sheet.dismiss(animated: false)
            }
            await wait { h.host?.presentedViewController == nil }
            await h.render()
            XCTAssertNil(h.root.pickerData)
            XCTAssertEqual(cancelled, large ? 0 : 1)
            XCTAssertTrue(confirmed.isEmpty)
            XCTAssertEqual(h.treatmentCount, 0)
        }
    }

    /// Snapshot the mounted production root, excluding the transparent blocking controller.
    /// Mean luminance catches a full-screen tint without depending on text rasterization.
    @MainActor private func rootBrightness(_ view: UIView, attachmentName: String) throws -> (whole: Double, bottom: Double) {
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            XCTAssertTrue(view.drawHierarchy(in: view.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = attachmentName
        attachment.lifetime = .keepAlways
        add(attachment)
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                    CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        XCTAssertTrue(rendered)
        var whole = 0.0
        var bottom = 0.0
        let bottomStart = height * 3 / 4
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let luminance = (0.2126 * Double(pixels[offset]) +
                    0.7152 * Double(pixels[offset + 1]) + 0.0722 * Double(pixels[offset + 2])) / 255
                whole += luminance
                if y >= bottomStart { bottom += luminance }
            }
        }
        return (whole / Double(width * height), bottom / Double(width * (height - bottomStart)))
    }

    @MainActor func testPlannedTapBeforeActivationOpensFromHomeWithoutAnotherEvent() async throws {
        let h = try ReminderRootHarness(phase: .inactive)
        defer { h.finish() }
        let uuid = try h.makePlan()
        h.configure()
        await h.mount(in: self)
        PlannedMealReminder.recordTap(uuid: uuid)
        await h.render()
        XCTAssertEqual(h.selectedTab, 0)
        XCTAssertNil(h.host?.presentedViewController)
        XCTAssertEqual(PlannedMealReminder.pendingOpenUUID, uuid)
        h.phase.value = .active
        await assertMealPresented(h, uuid: uuid)
        XCTAssertEqual(h.selectedTab, 1)
        XCTAssertEqual(h.treatmentCount, 1)
    }

    @MainActor func testColdRequestWaitsForDependenciesThenOpensExactlyOnce() async throws {
        let h = try ReminderRootHarness(phase: .inactive)
        defer { h.finish() }
        let uuid = try h.makePlan()
        await h.mount(in: self)
        PlannedMealReminder.recordTap(uuid: uuid)
        h.phase.value = .active
        await h.render()
        XCTAssertNil(h.host?.presentedViewController)
        XCTAssertEqual(PlannedMealReminder.pendingOpenUUID, uuid)
        h.configure()
        await assertMealPresented(h, uuid: uuid)
        let sheet = try XCTUnwrap(h.host?.presentedViewController)
        for _ in 0..<3 { PlannedMealReminder.recordTap(uuid: uuid) }
        await h.render()
        XCTAssertTrue(h.host?.presentedViewController === sheet)
        XCTAssertNil(sheet.presentedViewController)
        XCTAssertNil(PlannedMealReminder.pendingOpenUUID)
        XCTAssertEqual(h.treatmentCount, 1)
    }

    @MainActor func testAlreadySelectedTreatmentsUsesNewActivationPhase() async throws {
        let h = try ReminderRootHarness(phase: .inactive, treatmentsOnly: true)
        defer { h.finish() }
        let uuid = try h.makePlan()
        await h.mount(in: self)
        PlannedMealReminder.recordTap(uuid: uuid)
        await h.render()
        XCTAssertNil(h.host?.presentedViewController)
        h.phase.value = .active
        await assertMealPresented(h, uuid: uuid)
        XCTAssertEqual(h.treatmentCount, 1)
    }

    @MainActor func testWarmTapWaitsForAnimatedModalRemovalWithoutSyntheticRetry() async throws {
        let h = try ReminderRootHarness()
        defer { h.finish() }
        let uuid = try h.makePlan()
        h.configure()
        await h.mount(in: self)
        let blocker = UIViewController()
        blocker.modalPresentationStyle = .pageSheet
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            h.host!.present(blocker, animated: true) { c.resume() }
        }
        PlannedMealReminder.recordTap(uuid: uuid)
        await h.render()
        XCTAssertTrue(h.host?.presentedViewController === blocker)
        XCTAssertEqual(h.selectedTab, 0)
        XCTAssertEqual(PlannedMealReminder.pendingOpenUUID, uuid)
        // No call to presentationFinished: production must observe actual UIKit removal.
        blocker.dismiss(animated: true)
        await assertMealPresented(h, uuid: uuid)
        XCTAssertFalse(h.host?.presentedViewController === blocker)
        XCTAssertEqual(h.treatmentCount, 1)
    }

    @MainActor func testRootAlertDismissalResumesPendingMealAfterAnimation() async throws {
        let h = try ReminderRootHarness()
        defer { h.finish() }
        let uuid = try h.makePlan()
        h.configure()
        await h.mount(in: self)
        h.root.presentAlert(title: "Synthetic blocking alert", message: "No health data")
        await wait { h.host?.presentedViewController != nil }
        let blocker = try XCTUnwrap(h.host?.presentedViewController)
        PlannedMealReminder.recordTap(uuid: uuid)
        await h.render()
        XCTAssertEqual(PlannedMealReminder.pendingOpenUUID, uuid)
        // Like the alert's button, dismiss UIKit and update the SwiftUI binding. Clearing
        // only the model in a hosted test does not simulate the user's alert dismissal.
        blocker.dismiss(animated: true) { h.root.updatePresentedAlert(nil) }
        await assertMealPresented(h, uuid: uuid)
        XCTAssertFalse(h.host?.presentedViewController === blocker)
        XCTAssertEqual(h.treatmentCount, 1)
    }

    @MainActor func testRepeatedBasalTapKeepsDraftAndDoesNotReopenAfterClosing() async throws {
        let h = try ReminderRootHarness(phase: .inactive)
        defer { h.finish() }
        h.configure()
        await h.mount(in: self)
        BasalReminderScheduler.recordTap()
        await h.render()
        XCTAssertEqual(h.selectedTab, 0)
        XCTAssertTrue(BasalReminderScheduler.hasPendingOpen)
        h.phase.value = .active
        await wait { h.host?.presentedViewController != nil && !BasalReminderScheduler.hasPendingOpen }
        let sheet = try XCTUnwrap(h.host?.presentedViewController)
        let field = try XCTUnwrap(ReminderRootHarness.descendants(sheet.view).compactMap { $0 as? UITextField }.first)
        field.text = "17"
        field.sendActions(for: .editingChanged)
        for _ in 0..<3 { BasalReminderScheduler.recordTap() }
        await h.render()
        XCTAssertTrue(h.host?.presentedViewController === sheet)
        XCTAssertEqual(field.text, "17")
        XCTAssertFalse(BasalReminderScheduler.hasPendingOpen)
        sheet.dismiss(animated: true)
        await wait { h.host?.presentedViewController == nil }
        await h.render()
        XCTAssertNil(h.host?.presentedViewController)
        XCTAssertFalse(BasalReminderScheduler.hasPendingOpen)
        XCTAssertEqual(h.treatmentCount, 0)
    }

    @MainActor func testDifferentMealWaitsForOpenDraftAndLateAcknowledgementCannotLoseIt() async throws {
        let h = try ReminderRootHarness()
        defer { h.finish() }
        let first = try h.makePlan()
        let second = try h.makePlan()
        h.configure()
        await h.mount(in: self)
        PlannedMealReminder.recordTap(uuid: first)
        await assertMealPresented(h, uuid: first)
        let sheet = try XCTUnwrap(h.host?.presentedViewController)
        PlannedMealReminder.recordTap(uuid: second)
        await h.render()
        XCTAssertTrue(h.host?.presentedViewController === sheet)
        XCTAssertEqual(PlannedMealReminder.pendingOpenUUID, second)
        sheet.dismiss(animated: true)
        await assertMealPresented(h, uuid: second)
        XCTAssertFalse(h.host?.presentedViewController === sheet)
        XCTAssertEqual(h.treatmentCount, 2)
    }

    @MainActor private func assertMealPresented(_ h: ReminderRootHarness, uuid: String,
                                               file: StaticString = #filePath, line: UInt = #line) async {
        await wait(file: file, line: line) {
            h.host?.presentedViewController != nil && PlannedMealReminder.pendingOpenUUID == nil
        }
        let rows = try? MealPlanReminderCoordinator.storedTreatments(coreDataManager: h.core, uuids: [uuid])
        XCTAssertTrue(rows?.first?.isPlannedMeal == true, "Opening never confirms eating", file: file, line: line)
    }

    @MainActor private func wait(file: StaticString = #filePath, line: UInt = #line,
                                _ condition: @escaping () -> Bool) async {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        await fulfillment(of: [ready], timeout: 4)
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

@MainActor private final class ReminderRootPhase: ObservableObject {
    @Published var value: ScenePhase
    init(_ value: ScenePhase) { self.value = value }
}

@MainActor private final class ReminderRootHarness {
    let root = RootTabStateModel()
    let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
    let home = RootHomeStateModel()
    let phase: ReminderRootPhase
    let coordinator: RootApplicationCoordinator
    let treatmentsOnly: Bool
    private(set) var host: UIViewController?
    private var window: UIWindow?
    private weak var previousWindow: UIWindow?
    private var plans: [String] = []
    private let savedDefaults: [(String, Any?)]
    private let sensorSuite = "ReminderRootHarness.\(UUID().uuidString)"
    private var sensorDefaults: UserDefaults?

    init(phase: ScenePhase = .active, treatmentsOnly: Bool = false) throws {
        self.phase = ReminderRootPhase(phase)
        self.treatmentsOnly = treatmentsOnly
        coordinator = RootApplicationCoordinator(homeStateModelForTesting: home)
        let defaults = UserDefaults.standard
        let keys = ["plannedMealPendingOpenUUID", "pizzaSplitPendingOpenUUID", "basalReminderPendingOpen",
            UserDefaults.Key.nightscoutEnabled.rawValue, UserDefaults.Key.isMaster.rawValue,
            UserDefaults.Key.therapyDataSourceType.rawValue, UserDefaults.Key.glucoseForecastHorizonMinutes.rawValue,
            UserDefaults.Key.lastBasalInjectionUnits.rawValue, UserDefaults.Key.lastBasalInjectionInsulinDescription.rawValue,
            TreatmentSourceCutover.defaultsKey, TreatmentSourceCutover.restoreRequiresSourceSetupKey]
        savedDefaults = keys.map { ($0, defaults.object(forKey: $0)) }
        for key in keys.prefix(3) { defaults.removeObject(forKey: key) }
        defaults.nightscoutEnabled = false
        defaults.isMaster = true
        defaults.therapyDataSourceType = .none
        defaults.set(0, forKey: UserDefaults.Key.glucoseForecastHorizonMinutes.rawValue)
        defaults.set(false, forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey)
        defaults.set(try JSONEncoder().encode(TreatmentSourceCutover(cutoff: Date().addingTimeInterval(-86400),
            insulinSourceBundleID: "synthetic.insulin", carbohydrateSourceBundleID: "synthetic.carbs")),
            forKey: TreatmentSourceCutover.defaultsKey)
    }

    func configure() {
        let readings = BgReadingsAccessor(coreDataManager: core)
        let sound = SoundPlayer()
        let defaults = UserDefaults(suiteName: sensorSuite)!
        sensorDefaults = defaults
        let health = SensorHealthIssueManager(userDefaults: defaults)
        let nightscout = NightscoutSyncManager(coreDataManager: core, messageHandler: nil, observesSettings: false)
        // Empty synthetic database: this manager has no peripherals and cannot start a sensor.
        let bluetooth = BluetoothPeripheralManager(coreDataManager: core, cgmTransmitterDelegate: coordinator,
            messageHandler: { _, _ in }, heartBeatFunction: nil, cgmTransmitterInfoChanged: {})
        root.configure(coreDataManager: core, statisticsManager: StatisticsManager(coreDataManager: core),
            bgReadingsAccessor: readings, calibrationsAccessor: CalibrationsAccessor(coreDataManager: core),
            treatmentEntryAccessor: TreatmentEntryAccessor(coreDataManager: core),
            alertManager: AlertManager(coreDataManager: core, soundPlayer: sound),
            bgPostProcessingManager: BgPostProcessingManager(coreDataManager: core, nightscoutSyncManager: nil, healthKitManager: nil),
            sensorNoiseManager: SensorNoiseManager(coreDataManager: core, bgReadingsAccessor: readings, sensorHealthIssueManager: health),
            sensorHealthIssueManager: health, bluetoothPeripheralManager: bluetooth, soundPlayer: sound,
            nightscoutSyncManager: nightscout, rootHomeStateModel: home, rootHomeActions: RootHomeActions(),
            activeSensorProvider: { nil }, transmitterProvider: { nil }, startSensor: { _ in }, stopSensor: {},
            submitCalibration: { _ in nil }, updateScreenLock: { _, _ in false },
            selectedFollowerActions: .none, sensorProvider: coordinator)
    }

    func makePlan() throws -> String {
        let entry = TreatmentEntry(date: Date().addingTimeInterval(15 * 60), value: 45,
            treatmentType: .Carbs, nightscoutEventType: nil, enteredBy: "Synthetic reminder routing",
            nsManagedObjectContext: core.mainManagedObjectContext)
        let uuid = UUID().uuidString
        entry.localTreatmentUUID = uuid
        entry.plannedMealStateRaw = TreatmentMealState.planned.rawValue
        entry.mealKindRaw = TreatmentMealKind.normal.rawValue
        try core.mainManagedObjectContext.obtainPermanentIDs(for: [entry])
        XCTAssertTrue(core.saveChangesSynchronously())
        plans.append(uuid)
        return uuid
    }

    func mount(in test: XCTestCase) async {
        let appeared = XCTestExpectation(description: "Root mounted")
        let controller = UIHostingController(rootView: ReminderRootContent(harness: self,
            onAppear: { appeared.fulfill() }))
        host = controller
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            XCTFail("Hosted navigation requires active XCTest scene")
            return
        }
        previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        self.window = window
        window.rootViewController = controller
        window.makeKeyAndVisible()
        await test.fulfillment(of: [appeared], timeout: 3)
        await render()
    }

    func render() async { try? await Task.sleep(nanoseconds: 200_000_000) }
    var treatmentCount: Int { TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil).count }
    var selectedTab: Int? {
        func find(_ c: UIViewController) -> UITabBarController? {
            if let tabs = c as? UITabBarController { return tabs }
            return c.children.compactMap(find).first
        }
        return host.flatMap(find)?.selectedIndex
    }
    static func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }

    func finish() {
        host?.dismiss(animated: false)
        window?.isHidden = true
        window?.rootViewController = nil
        host = nil
        previousWindow?.makeKeyAndVisible()
        for uuid in plans {
            PlannedMealReminder.cancel(uuid: uuid)
            PizzaSplitReminder.cancel(uuid: uuid)
            try? MealPlanMetadataStore.shared.remove(uuid: uuid)
        }
        let ns = UserDefaults.Key.nightscoutEnabled.rawValue
        for (key, value) in savedDefaults.filter({ $0.0 != ns }) + savedDefaults.filter({ $0.0 == ns }) {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        sensorDefaults?.removePersistentDomain(forName: sensorSuite)
    }
}

@MainActor private struct ReminderRootContent: View {
    let harness: ReminderRootHarness
    @ObservedObject var phase: ReminderRootPhase
    let onAppear: () -> Void
    init(harness: ReminderRootHarness, onAppear: @escaping () -> Void) {
        self.harness = harness
        phase = harness.phase
        self.onAppear = onAppear
    }
    var body: some View {
        Group {
            if harness.treatmentsOnly {
                TreatmentsView(coreDataManager: harness.core)
            } else {
                RootTabView(stateModel: harness.root, applicationCoordinator: harness.coordinator,
                    tabTitles: RootTabTitles(home: "Home", treatments: "Treatments", statistics: "Statistics",
                        devices: "Devices", settings: "Settings"))
            }
        }
        .environment(\.scenePhase, phase.value)
        .onAppear(perform: onAppear)
    }
}

extension BasalInjectionTests {
    @MainActor private func reminderEntry(_ core: CoreDataManager, uuid: String = UUID().uuidString,
        type: TreatmentType = .Carbs, value: Double = 30, date: Date,
        state: TreatmentMealState? = nil, kind: TreatmentMealKind = .normal,
        deleted: Bool = false) -> TreatmentEntry {
        let entry = TreatmentEntry(date: date, value: value, treatmentType: type,
            nightscoutEventType: nil, enteredBy: "xDrip4iOS",
            nsManagedObjectContext: core.mainManagedObjectContext)
        entry.localTreatmentUUID = uuid
        entry.plannedMealStateRaw = state?.rawValue
        entry.mealKindRaw = kind.rawValue
        entry.treatmentdeleted = deleted
        return entry
    }

    @MainActor func testMealReconcileReadsOneUniqueUUIDBatchForZeroOneAndHundredMeals() throws {
        let now = Date(timeIntervalSince1970: 1_788_804_000)
        for count in [0, 1, 100] {
            let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = MealPlanMetadataStore(directory: directory)
            let journal = PenDoseLogJournal(directory: directory)
            var expected: [MealPlanMetadata] = []
            let sharedBolus = UUID().uuidString
            if count > 0 {
                _ = reminderEntry(core, uuid: sharedBolus, type: .Insulin, value: 2, date: now)
            }
            for index in 0..<count {
                let meal = reminderEntry(core, date: now.addingTimeInterval(Double(-index * 60)))
                let metadata = MealPlanMetadata(mealUUID: meal.localTreatmentUUID!, bolusUUID: sharedBolus,
                    loggedAt: meal.date, plannedAt: nil, grams: meal.value,
                    pizzaSettings: nil, mealKind: .normal)
                try store.stage(metadata)
                expected.append(metadata)
            }
            XCTAssertTrue(core.saveChangesSynchronously())
            var reads = 0
            var fetchedUUIDs: [String] = []
            MealPlanReminderCoordinator.reconcile(coreDataManager: core, journal: journal,
                store: store, now: now, readTreatments: { uuids in
                    reads += 1
                    fetchedUUIDs = uuids
                    return try MealPlanReminderCoordinator.storedTreatments(coreDataManager: core, uuids: uuids)
                }, onIssue: { XCTFail($0) })
            XCTAssertEqual(reads, count == 0 ? 0 : 1)
            XCTAssertEqual(fetchedUUIDs.count, Set(fetchedUUIDs).count)
            XCTAssertEqual(Set(fetchedUUIDs), Set(expected.flatMap { [$0.mealUUID, sharedBolus] }))
            XCTAssertEqual(Set(try store.allMetadata().map(\.mealUUID)), Set(expected.map(\.mealUUID)))
            for metadata in expected { XCTAssertEqual(try store.metadata(for: metadata.mealUUID), metadata) }
            XCTAssertEqual(TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil).count,
                           count == 0 ? 0 : count + 1)
        }
    }

    @MainActor func testMealReconcileBatchMatchesFreshRefreshForEditsDeletionAndReminderTimes() throws {
        let now = Date(timeIntervalSince1970: 1_788_804_000)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let batch = MealPlanMetadataStore(directory: directory.appendingPathComponent("batch"))
        let original = MealPlanMetadataStore(directory: directory.appendingPathComponent("original"))
        let journal = PenDoseLogJournal(directory: directory)
        let pizza = PizzaSplitSettings(isEnabled: true, percentageNow: 70, reminderMinutes: 90)
        let bolus = reminderEntry(core, type: .Insulin, value: 3, date: now)
        var metadata: [MealPlanMetadata] = []
        for index in 0..<8 {
            let uuid = UUID().uuidString
            let state: TreatmentMealState? = index == 0 || index == 5 ? .planned :
                (index == 3 ? .cancelled : nil)
            let meal = reminderEntry(core, uuid: uuid, date: now.addingTimeInterval(15 * 60),
                state: state, kind: index == 1 ? .slow : .normal, deleted: index == 2)
            var item = MealPlanMetadata(mealUUID: uuid,
                bolusUUID: index >= 5 ? UUID().uuidString : bolus.localTreatmentUUID,
                loggedAt: now, plannedAt: state == .planned ? meal.date : nil,
                grams: meal.value, pizzaSettings: pizza, mealKind: meal.mealKind)
            if index == 1 {
                item.pizzaReminderAt = now.addingTimeInterval(80 * 60)
                meal.date = now.addingTimeInterval(-10 * 60)
                meal.value = 45
            }
            if index == 4 { core.mainManagedObjectContext.delete(meal) }
            if index == 6 {
                _ = reminderEntry(core, uuid: item.bolusUUID!, type: .Insulin,
                    value: 3, date: now, deleted: true)
            }
            if index == 7 {
                _ = reminderEntry(core, uuid: item.bolusUUID!, type: .Insulin, value: 0, date: now)
            }
            try batch.stage(item)
            try original.stage(item)
            metadata.append(item)
        }
        XCTAssertTrue(core.saveChangesSynchronously())
        defer {
            for item in metadata {
                PlannedMealReminder.cancel(uuid: item.mealUUID)
                PizzaSplitReminder.cancel(uuid: item.mealUUID)
            }
        }
        for item in metadata {
            XCTAssertNil(MealPlanReminderCoordinator.refresh(coreDataManager: core,
                mealUUID: item.mealUUID, now: now, store: original))
        }
        MealPlanReminderCoordinator.reconcile(coreDataManager: core, journal: journal,
            store: batch, now: now)
        for item in metadata {
            XCTAssertEqual(try batch.metadata(for: item.mealUUID), try original.metadata(for: item.mealUUID))
        }
        XCTAssertEqual(try batch.metadata(for: metadata[0].mealUUID)?.followupAt,
                       now.addingTimeInterval(30 * 60))
        XCTAssertEqual(try batch.metadata(for: metadata[1].mealUUID)?.pizzaReminderAt,
                       now.addingTimeInterval(80 * 60))
        for index in [2, 3, 4] { XCTAssertNil(try batch.metadata(for: metadata[index].mealUUID)) }
        for index in [5, 6, 7] { XCTAssertNil(try batch.metadata(for: metadata[index].mealUUID)?.bolusUUID) }
        XCTAssertNil(try batch.metadata(for: metadata[5].mealUUID)?.followupAt)
    }

    @MainActor func testMealReconcileReadFailuresPreserveAllMetadata() throws {
        let now = Date(timeIntervalSince1970: 1_788_804_000)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealPlanMetadataStore(directory: directory)
        let journal = PenDoseLogJournal(directory: directory)
        let item = MealPlanMetadata(mealUUID: UUID().uuidString, bolusUUID: UUID().uuidString,
            loggedAt: now, plannedAt: now.addingTimeInterval(900), grams: 30,
            pizzaSettings: nil, mealKind: .normal)
        try store.stage(item)
        var issues: [String] = []
        MealPlanReminderCoordinator.reconcile(coreDataManager: core, journal: journal,
            store: store, now: now, readTreatments: { _ in
                throw NSError(domain: "MealReconcileTests", code: 1)
            }, onIssue: { issues.append($0) })
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(try store.metadata(for: item.mealUUID), item)
        try core.disconnectPersistentStoresForTesting()
        MealPlanReminderCoordinator.reconcile(coreDataManager: core, journal: journal,
            store: store, now: now, onIssue: { issues.append($0) })
        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(try store.metadata(for: item.mealUUID), item)
    }

    @MainActor func testMealReconcilePendingJournalPreservesMissingAndUncommittedMealsAcrossRestart() throws {
        let now = Date(timeIntervalSince1970: 1_788_804_000)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealPlanMetadataStore(directory: directory)
        let first = PenDoseLogJournal(directory: directory, processToken: "first")
        let operation = PenDoseLogOperation()
        let item = MealPlanMetadata(mealUUID: operation.mealUUID, bolusUUID: nil,
            loggedAt: now, plannedAt: now.addingTimeInterval(-60), grams: 30,
            pizzaSettings: nil, mealKind: .normal)
        try store.stage(item)
        XCTAssertTrue(first.begin(operation, expectsBolus: false, expectsMeal: true))
        let unsaved = reminderEntry(core, uuid: operation.mealUUID, value: 45, date: now, state: .planned)
        let restarted = PenDoseLogJournal(directory: directory, processToken: "second")
        for journal in [first, restarted] {
            MealPlanReminderCoordinator.reconcile(coreDataManager: core, journal: journal,
                store: store, now: now, onIssue: { XCTFail($0) })
            XCTAssertEqual(try store.metadata(for: item.mealUUID), item,
                "An uncommitted row is not deletion evidence, including after restart")
        }
        XCTAssertTrue(core.saveChangesSynchronously())
        MealPlanReminderCoordinator.reconcile(coreDataManager: core, journal: restarted,
            store: store, now: now, onIssue: { XCTFail($0) })
        XCTAssertEqual(try store.metadata(for: item.mealUUID)?.lastStoredMealGrams, 45)
        XCTAssertTrue(restarted.complete())
        unsaved.treatmentdeleted = true
        XCTAssertTrue(core.saveChangesSynchronously())
        MealPlanReminderCoordinator.reconcile(coreDataManager: core, journal: restarted,
            store: store, now: now, onIssue: { XCTFail($0) })
        XCTAssertNil(try store.metadata(for: item.mealUUID))
    }

    @MainActor func testMealReconcileDoesNotRetainSnapshotsOrReadUnsavedEdits() throws {
        let now = Date(timeIntervalSince1970: 1_788_804_000)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealPlanMetadataStore(directory: directory)
        let journal = PenDoseLogJournal(directory: directory)
        let bolus = reminderEntry(core, type: .Insulin, value: 2, date: now)
        let meal = reminderEntry(core, date: now, state: .planned)
        let item = MealPlanMetadata(mealUUID: meal.localTreatmentUUID!, bolusUUID: bolus.localTreatmentUUID,
            loggedAt: now, plannedAt: now, grams: 30, pizzaSettings: nil, mealKind: .normal)
        try store.stage(item)
        XCTAssertTrue(core.saveChangesSynchronously())
        meal.value = 45
        meal.date = now.addingTimeInterval(-60)
        bolus.treatmentdeleted = true
        MealPlanReminderCoordinator.reconcile(coreDataManager: core, journal: journal, store: store, now: now)
        XCTAssertEqual(try store.metadata(for: item.mealUUID), item,
            "Only durable treatment values may affect reminders")
        XCTAssertTrue(core.saveChangesSynchronously())
        MealPlanReminderCoordinator.reconcile(coreDataManager: core, journal: journal, store: store, now: now)
        let updated = try XCTUnwrap(store.metadata(for: item.mealUUID))
        XCTAssertEqual(updated.lastStoredMealGrams, 45)
        XCTAssertEqual(updated.lastStoredMealDate, meal.date)
        XCTAssertNil(updated.bolusUUID)
        XCTAssertNil(updated.followupAt)
        meal.treatmentdeleted = true
        XCTAssertTrue(core.saveChangesSynchronously())
        MealPlanReminderCoordinator.reconcile(coreDataManager: core, journal: journal, store: store, now: now)
        XCTAssertNil(try store.metadata(for: item.mealUUID))
    }

    @MainActor func testMealReconcileAmbiguousMealAndBolusUUIDsPreservePlans() throws {
        let now = Date(timeIntervalSince1970: 1_788_804_000)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealPlanMetadataStore(directory: directory)
        let journal = PenDoseLogJournal(directory: directory)
        var items: [MealPlanMetadata] = []
        for duplicateMeal in [true, false] {
            let mealUUID = UUID().uuidString
            let bolusUUID = UUID().uuidString
            _ = reminderEntry(core, uuid: mealUUID, date: now)
            _ = reminderEntry(core, uuid: bolusUUID, type: .Insulin, value: 2, date: now)
            _ = reminderEntry(core, uuid: duplicateMeal ? mealUUID : bolusUUID,
                type: duplicateMeal ? .Carbs : .Insulin, value: 10, date: now, deleted: true)
            let item = MealPlanMetadata(mealUUID: mealUUID, bolusUUID: bolusUUID,
                loggedAt: now, plannedAt: now, grams: 30, pizzaSettings: nil, mealKind: .normal)
            try store.stage(item)
            items.append(item)
        }
        XCTAssertTrue(core.saveChangesSynchronously())
        var issues: [String] = []
        MealPlanReminderCoordinator.reconcile(coreDataManager: core, journal: journal,
            store: store, now: now, onIssue: { issues.append($0) })
        XCTAssertEqual(issues.count, 2)
        for item in items { XCTAssertEqual(try store.metadata(for: item.mealUUID), item) }
    }
}

extension BasalInjectionTests {
    @MainActor func testMealReconcileCleansInactiveMealDespiteAmbiguousLinkedBolus() throws {
        let now = Date(timeIntervalSince1970: 1_788_804_000)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MealPlanMetadataStore(directory: directory)
        let journal = PenDoseLogJournal(directory: directory)
        var uuids: [String] = []
        for state in 0..<3 {
            let mealUUID = UUID().uuidString
            let bolusUUID = UUID().uuidString
            if state > 0 {
                _ = reminderEntry(core, uuid: mealUUID, date: now,
                    state: state == 2 ? .cancelled : nil, deleted: state == 1)
            }
            for value in [1.0, 2.0] {
                _ = reminderEntry(core, uuid: bolusUUID, type: .Insulin, value: value, date: now)
            }
            try store.stage(MealPlanMetadata(mealUUID: mealUUID, bolusUUID: bolusUUID,
                loggedAt: now, plannedAt: now, grams: 30, pizzaSettings: nil, mealKind: .normal))
            uuids.append(mealUUID)
        }
        XCTAssertTrue(core.saveChangesSynchronously())
        MealPlanReminderCoordinator.reconcile(coreDataManager: core, journal: journal,
            store: store, now: now, onIssue: { XCTFail($0) })
        for uuid in uuids { XCTAssertNil(try store.metadata(for: uuid)) }
        XCTAssertEqual(TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil)
            .filter { $0.treatmentType == .Insulin }.count, 6, "Reminder cleanup must never change insulin")
    }
}
