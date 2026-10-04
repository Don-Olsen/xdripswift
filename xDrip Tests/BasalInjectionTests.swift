//
//  BasalInjectionTests.swift
//  xdripTests
//
//  Created by Paul Plant on 7/9/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
import UIKit
import UserNotifications
@testable import xdrip

final class BasalInjectionTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_788_804_000)

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
        let noon = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
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
        let reminder = try XCTUnwrap(PlannedMealReminder.request(uuid: uuid, at: now.addingTimeInterval(600), now: now))
        XCTAssertEqual(reminder.identifier, PlannedMealReminder.identifier(for: uuid))
        XCTAssertEqual(PlannedMealReminder.tappedUUID(from: reminder), uuid)
        XCTAssertNil(PlannedMealReminder.request(uuid: uuid, at: now, now: now))
        XCTAssertNil(PlannedMealReminder.request(uuid: uuid, at: now.addingTimeInterval(61 * 60), now: now))
        XCTAssertFalse(AlertManager.ownedPendingNotificationIdentifiers.contains(reminder.identifier))
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
