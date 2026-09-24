import CoreData
import HealthKit
import XCTest
@testable import xdrip

/// The query adapter is replaced with synthetic pages. These tests never read or write the
/// device's Health database, and every imported treatment uses an isolated Core Data store.
final class HealthKitTherapyImportTests: XCTestCase {
    private let sourceA = HealthTherapyImportSource(bundleIdentifier: "org.example.therapy.a", name: "Pump A")
    private let sourceB = HealthTherapyImportSource(bundleIdentifier: "org.example.therapy.b", name: "Pump B")

    private func anchor(_ text: String) -> Data { Data(text.utf8) }

    private func sample(_ kind: HealthTherapyImportKind, source: HealthTherapyImportSource,
                        uuid: UUID = UUID(), quantity: Double = 2,
                        date: Date = Date().addingTimeInterval(-300), endDate: Date? = nil,
                        reason: Int? = HKInsulinDeliveryReason.bolus.rawValue,
                        undetermined: Bool = false, count: Int = 1,
                        externalUUID: String? = nil, syncIdentifier: String? = nil) -> HealthTherapyIncomingSample {
        HealthTherapyIncomingSample(uuid: uuid, kind: kind, source: source,
            startDate: date, endDate: endDate ?? date, quantity: quantity,
            insulinReason: reason, hasUndeterminedDuration: undetermined,
            sampleCount: count, externalUUID: externalUUID, syncIdentifier: syncIdentifier)
    }

    private func page(_ samples: [HealthTherapyIncomingSample] = [],
                      deleted: [UUID] = [], next: String, more: Bool = false) -> HealthTherapyImportPage {
        HealthTherapyImportPage(samples: samples, deletedUUIDs: deleted,
                                nextAnchor: anchor(next), hasMore: more)
    }

    private func policy(_ therapy: TherapyDataSourceType = .nightscout) -> DataFlowPolicy {
        DataFlowPolicy(isMaster: true, followerDataSource: .careLink,
            therapyDataSourceSelection: therapy, nightscoutEnabled: therapy == .nightscout,
            masterUploadsGlucoseToNightscout: false, followerUploadsGlucoseToNightscout: false,
            nightscoutFollowType: .none)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping () -> Bool) {
        let fulfilled = expectation(description: description)
        func poll() {
            if condition() { fulfilled.fulfill() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll) }
        }
        poll()
        wait(for: [fulfilled], timeout: timeout)
        XCTAssertTrue(condition(), description, file: file, line: line)
    }

    private func enable(_ kind: HealthTherapyImportKind, source: HealthTherapyImportSource,
                        fixture: ImportFixture) {
        // Set the same persisted choice that selectSource writes before enabling the type.
        // The switch test below exercises selectSource itself. This ordering gives each test
        // exactly one initial query and makes the deliberate failed-save case deterministic.
        fixture.defaults.set(source.bundleIdentifier,
                             forKey: "healthTherapyImport.v1.\(kind.rawValue).sourceBundleID")
        fixture.defaults.set(source.name,
                             forKey: "healthTherapyImport.v1.\(kind.rawValue).sourceName")
        let authorized = expectation(description: "read request returned")
        fixture.manager.setEnabled(true, kind: kind) { error in
            XCTAssertNil(error)
            authorized.fulfill()
        }
        wait(for: [authorized], timeout: 3)
        fixture.configureOnce()
    }

    private func treatments(in core: CoreDataManager) -> [TreatmentEntry] {
        var entries: [TreatmentEntry] = []
        core.mainManagedObjectContext.performAndWait {
            entries = (try? core.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest())) ?? []
        }
        return entries
    }

    private func ledger(in core: CoreDataManager) -> [HealthKitTherapySample] {
        var records: [HealthKitTherapySample] = []
        core.mainManagedObjectContext.performAndWait {
            records = (try? core.mainManagedObjectContext.fetch(HealthKitTherapySample.fetchRequest())) ?? []
        }
        return records
    }

    func testClassificationAcceptsOnlyPointBolusAndIndividualCarbEntries() {
        let at = Date().addingTimeInterval(-120)
        XCTAssertEqual(sample(.insulin, source: sourceA, date: at).classification, "bolus")
        XCTAssertTrue(sample(.insulin, source: sourceA, date: at).contributesToTherapy)
        let basal = sample(.insulin, source: sourceA, date: at,
                           reason: HKInsulinDeliveryReason.basal.rawValue)
        XCTAssertEqual(basal.classification, "basal")
        XCTAssertFalse(basal.contributesToTherapy)
        let unknown = sample(.insulin, source: sourceA, date: at, reason: nil)
        XCTAssertEqual(unknown.classification, "unclassifiedInsulin")
        XCTAssertFalse(unknown.contributesToTherapy)
        let interval = sample(.insulin, source: sourceA, date: at,
                              endDate: at.addingTimeInterval(60))
        XCTAssertEqual(interval.classification, "ambiguousInterval")
        XCTAssertFalse(interval.contributesToTherapy)
        XCTAssertFalse(sample(.insulin, source: sourceA, date: at,
                              undetermined: true).contributesToTherapy)
        XCTAssertFalse(sample(.carbohydrates, source: sourceA, date: at,
                              count: 2).contributesToTherapy)
        XCTAssertEqual(sample(.carbohydrates, source: sourceA, quantity: 34,
                              date: at).classification, "carbohydrates")
        for value in [0, -2, Double.nan, Double.infinity] {
            XCTAssertEqual(sample(.carbohydrates, source: sourceA, quantity: value,
                                  date: at).classification, "invalid")
        }
    }

    func testOptInIsOffByDefaultAndEmptyReadDoesNotProveCompleteness() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let manager = fixture.manager
        XCTAssertFalse(manager.isEnabled(.insulin))
        XCTAssertFalse(manager.isEnabled(.carbohydrates))
        XCTAssertEqual(manager.status(.insulin).message, "Import off")
        fixture.query.setPage(page(next: "empty"), for: .insulin, after: nil)
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("first empty Health page completed") {
            fixture.anchor(for: .insulin) == self.anchor("empty")
        }
        XCTAssertTrue(manager.status(.insulin).isIncomplete)
        XCTAssertNotNil(manager.status(.insulin).lastSync)
        XCTAssertTrue(treatments(in: fixture.core).isEmpty)
        XCTAssertNil(fixture.anchor(for: .carbohydrates))
    }

    func testUnavailableAuthorizationLeavesImportOffAndAnchorUnchanged() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        fixture.query.setAuthorizationError(ReadFailure.locked, for: .insulin)
        let returned = expectation(description: "unavailable Health database")
        fixture.manager.setEnabled(true, kind: .insulin) { error in
            XCTAssertNotNil(error)
            returned.fulfill()
        }
        wait(for: [returned], timeout: 3)
        XCTAssertFalse(fixture.manager.isEnabled(.insulin))
        XCTAssertNil(fixture.anchor(for: .insulin))
        XCTAssertTrue(treatments(in: fixture.core).isEmpty)
    }

    func testEnabledImportWaitsForAnExplicitSourceChoice() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let returned = expectation(description: "read dialog returned")
        fixture.manager.setEnabled(true, kind: .insulin) { error in
            XCTAssertNil(error)
            returned.fulfill()
        }
        wait(for: [returned], timeout: 3)
        XCTAssertTrue(fixture.manager.isEnabled(.insulin))
        XCTAssertNil(fixture.manager.selectedSource(.insulin))
        XCTAssertTrue(fixture.manager.localInputIsIncomplete(.insulin))
        XCTAssertNil(fixture.anchor(for: .insulin))
        XCTAssertTrue(fixture.query.anchors(for: .insulin).isEmpty)
    }

    func testInsulinAndCarbsKeepOriginalTimeAndUnitsWithoutBasalOrUnknownIOB() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let recorded = Date().addingTimeInterval(-7200)
        let bolus = sample(.insulin, source: sourceA, quantity: 2.5, date: recorded)
        let basal = sample(.insulin, source: sourceA, quantity: 0.7, date: recorded,
                           reason: HKInsulinDeliveryReason.basal.rawValue)
        let unknown = sample(.insulin, source: sourceA, quantity: 4, date: recorded, reason: nil)
        let carbs = sample(.carbohydrates, source: sourceA, quantity: 42, date: recorded)
        fixture.query.setPage(page([bolus, basal, unknown], next: "i1"), for: .insulin, after: nil)
        fixture.query.setPage(page([carbs], next: "c1"), for: .carbohydrates, after: nil)

        enable(.insulin, source: sourceA, fixture: fixture)
        enable(.carbohydrates, source: sourceA, fixture: fixture)
        waitUntil("both quantities saved before anchors") {
            fixture.anchor(for: .insulin) == self.anchor("i1") &&
            fixture.anchor(for: .carbohydrates) == self.anchor("c1")
        }
        let rows = treatments(in: fixture.core)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.treatmentType == .Insulin })?.value, 2.5)
        XCTAssertEqual(rows.first(where: { $0.treatmentType == .Carbs })?.value, 42)
        XCTAssertTrue(rows.allSatisfy { $0.date == recorded })
        XCTAssertEqual(Set(rows.compactMap(\.healthKitSampleUUID)),
                       Set([bolus.uuid.uuidString, carbs.uuid.uuidString]))
        let records = ledger(in: fixture.core)
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(Set(records.map(\.classification)),
                       Set(["bolus", "basal", "unclassifiedInsulin", "carbohydrates"]))
    }

    func testRepeatedCallbackAndRestartedAnchorCannotDuplicateAHealthSample() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let first = sample(.insulin, source: sourceA)
        fixture.query.setPage(page([first], next: "a1"), for: .insulin, after: nil)
        fixture.query.setPage(page([first], next: "a2"), for: .insulin, after: anchor("a1"))
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("first sample saved") { fixture.anchor(for: .insulin) == self.anchor("a1") }
        fixture.query.emit(.insulin)
        waitUntil("replayed sample checkpointed") { fixture.anchor(for: .insulin) == self.anchor("a2") }
        XCTAssertEqual(ledger(in: fixture.core).count, 1)
        XCTAssertEqual(treatments(in: fixture.core).count, 1)
        XCTAssertEqual(Array(fixture.query.anchors(for: .insulin).prefix(2)), [nil, anchor("a1")])
    }

    func testDocumentedDeletionOnlyMarksMatchingHealthImportAndReplacementIsNew() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let first = sample(.carbohydrates, source: sourceA, quantity: 20)
        let replacement = sample(.carbohydrates, source: sourceA, quantity: 22)
        fixture.query.setPage(page([first], next: "a1"), for: .carbohydrates, after: nil)
        enable(.carbohydrates, source: sourceA, fixture: fixture)
        waitUntil("first meal saved") { fixture.anchor(for: .carbohydrates) == self.anchor("a1") }
        let manual = TreatmentEntry(date: first.startDate, value: 20, treatmentType: .Carbs,
                                    nightscoutEventType: nil, enteredBy: "Test",
                                    nsManagedObjectContext: fixture.core.mainManagedObjectContext)
        XCTAssertTrue(fixture.core.saveChangesSynchronously())
        // Make the deletion available only after the first checkpoint. An unrelated extra
        // startup callback must not race this two-stage test past its first assertion.
        fixture.query.setPage(page([replacement], deleted: [first.uuid], next: "a2"),
                              for: .carbohydrates, after: anchor("a1"))
        fixture.query.emit(.carbohydrates)
        waitUntil("deletion and replacement checkpointed") {
            fixture.anchor(for: .carbohydrates) == self.anchor("a2")
        }
        let rows = treatments(in: fixture.core)
        XCTAssertEqual(rows.count, 3)
        XCTAssertFalse(manual.treatmentdeleted)
        XCTAssertEqual(rows.first(where: { $0.healthKitSampleUUID == first.uuid.uuidString })?.treatmentdeleted, true)
        XCTAssertEqual(rows.first(where: { $0.healthKitSampleUUID == replacement.uuid.uuidString })?.treatmentdeleted, false)
        XCTAssertEqual(ledger(in: fixture.core).first(where: { $0.uuid == first.uuid.uuidString })?.wasDeletedInHealthKit, true)
    }

    func testSourceChoiceIsBasedOnRealSourceIdentityAndSwitchKeepsProvenance() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let a = sample(.insulin, source: sourceA, quantity: 1.25)
        let b = sample(.insulin, source: sourceB, quantity: 2.75)
        fixture.query.setPage(page([a, b], next: "a1"), for: .insulin, after: nil)
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("both sources recorded") { fixture.anchor(for: .insulin) == self.anchor("a1") }
        XCTAssertEqual(ledger(in: fixture.core).count, 2)
        XCTAssertEqual(treatments(in: fixture.core).compactMap(\.healthKitSourceBundleIdentifier), [sourceA.bundleIdentifier])
        fixture.manager.selectSource(sourceB, kind: .insulin)
        waitUntil("new source materialized") { self.treatments(in: fixture.core).count == 2 }
        XCTAssertEqual(fixture.manager.selectedSource(.insulin)?.bundleIdentifier, sourceB.bundleIdentifier)
        XCTAssertEqual(Set(treatments(in: fixture.core).compactMap(\.healthKitSourceBundleIdentifier)),
                       Set([sourceA.bundleIdentifier, sourceB.bundleIdentifier]))
    }

    func testReadFailureDoesNotMoveAnchorAndCanRetryOnObserverCallback() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        fixture.query.setError(ReadFailure.locked, for: .insulin)
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("locked read reported") { fixture.manager.status(.insulin).message.contains("could not be read") }
        XCTAssertNil(fixture.anchor(for: .insulin))
        XCTAssertTrue(fixture.manager.localInputIsIncomplete(.insulin))
        let dose = sample(.insulin, source: sourceA)
        fixture.query.setError(nil, for: .insulin)
        fixture.query.setPage(page([dose], next: "after-lock"), for: .insulin, after: nil)
        fixture.query.emit(.insulin)
        waitUntil("locked read retried") { fixture.anchor(for: .insulin) == self.anchor("after-lock") }
        XCTAssertEqual(treatments(in: fixture.core).count, 1)
    }

    func testInitialBackfillDrainsPagesAndRetainsBackdatedTimestamps() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let backdated = Date().addingTimeInterval(-7 * 3600)
        let first = sample(.carbohydrates, source: sourceA, quantity: 30, date: backdated)
        let second = sample(.carbohydrates, source: sourceA, quantity: 12,
                            date: Date().addingTimeInterval(-1800))
        fixture.query.setPage(page([first], next: "p1", more: true), for: .carbohydrates, after: nil)
        fixture.query.setPage(page([second], next: "p2"), for: .carbohydrates, after: anchor("p1"))
        enable(.carbohydrates, source: sourceA, fixture: fixture)
        waitUntil("both backfill pages saved") {
            fixture.anchor(for: .carbohydrates) == self.anchor("p2")
        }
        let rows = treatments(in: fixture.core)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.healthKitSampleUUID == first.uuid.uuidString })?.date, backdated)
        XCTAssertEqual(rows.first(where: { $0.healthKitSampleUUID == second.uuid.uuidString })?.date, second.startDate)
        XCTAssertEqual(Array(fixture.query.anchors(for: .carbohydrates).prefix(2)), [nil, anchor("p1")])
    }

    func testSuccessfulFirstPageDoesNotClaimCompleteInputsBeforeFinalPage() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let first = sample(.insulin, source: sourceA, quantity: 1)
        let second = sample(.insulin, source: sourceA, quantity: 2)
        fixture.query.setPage(page([first], next: "first", more: true), for: .insulin, after: nil)
        fixture.query.setPage(page([second], next: "last"), for: .insulin, after: anchor("first"))
        fixture.query.holdPage(for: .insulin, after: anchor("first"))
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("first page durable and next page pending") {
            fixture.anchor(for: .insulin) == self.anchor("first") &&
            fixture.query.anchors(for: .insulin).contains(where: { $0 == self.anchor("first") })
        }
        XCTAssertTrue(fixture.manager.localInputIsIncomplete(.insulin))
        XCTAssertTrue(fixture.manager.status(.insulin).message.contains("every page"))
        XCTAssertNil(fixture.manager.status(.insulin).lastSync)
        let reopened = HealthKitTherapyImportManager(query: FakeQuery(), defaults: fixture.defaults)
        XCTAssertTrue(reopened.localInputIsIncomplete(.insulin),
                      "an interrupted multi-page import cannot look complete after restart")
        fixture.query.releaseHeldPage(for: .insulin, after: anchor("first"))
        waitUntil("final page durable") { fixture.anchor(for: .insulin) == self.anchor("last") }
        XCTAssertEqual(treatments(in: fixture.core).count, 2)
        XCTAssertFalse(fixture.manager.localInputIsIncomplete(.insulin))
        XCTAssertNotNil(fixture.manager.status(.insulin).lastSync)
    }

    func testRecentUnclassifiedInsulinKeepsIOBIncompleteUntilDeleted() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let uncertain = sample(.insulin, source: sourceA, quantity: 2, reason: nil)
        fixture.query.setPage(page([uncertain], next: "uncertain"), for: .insulin, after: nil)
        fixture.query.setPage(page(deleted: [uncertain.uuid], next: "deleted"),
                              for: .insulin, after: anchor("uncertain"))
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("unclassified Health entry persisted") {
            fixture.anchor(for: .insulin) == self.anchor("uncertain")
        }
        XCTAssertTrue(fixture.manager.localInputIsIncomplete(.insulin))
        XCTAssertTrue(fixture.manager.status(.insulin).message.contains("unclear dose"))
        XCTAssertTrue(treatments(in: fixture.core).isEmpty)
        let reopened = HealthKitTherapyImportManager(query: FakeQuery(), defaults: fixture.defaults)
        XCTAssertTrue(reopened.localInputIsIncomplete(.insulin))
        fixture.query.emit(.insulin)
        waitUntil("documented deletion persisted") {
            fixture.anchor(for: .insulin) == self.anchor("deleted")
        }
        XCTAssertFalse(fixture.defaults.bool(forKey: "healthTherapyImport.v1.insulin.hasAmbiguousSelectedSource"))
        XCTAssertFalse(fixture.manager.localInputIsIncomplete(.insulin))
    }

    func testOldAmbiguousCarbRecordDoesNotLeavePermanentIncompleteStatus() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let old = Date().addingTimeInterval(-TherapyModelSettings.visibilityInterval - 60)
        let uncertain = sample(.carbohydrates, source: sourceA, quantity: 30,
                               date: old, endDate: old.addingTimeInterval(20))
        fixture.query.setPage(page([uncertain], next: "old"), for: .carbohydrates, after: nil)
        enable(.carbohydrates, source: sourceA, fixture: fixture)
        waitUntil("old ambiguous entry persisted") {
            fixture.anchor(for: .carbohydrates) == self.anchor("old")
        }
        XCTAssertFalse(fixture.defaults.bool(forKey: "healthTherapyImport.v1.carbohydrates.hasAmbiguousSelectedSource"))
        XCTAssertFalse(fixture.manager.localInputIsIncomplete(.carbohydrates))
    }

    func testFailedParentSaveLeavesAnchorBehindAndRetryDoesNotDuplicate() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let dose = sample(.insulin, source: sourceA)
        fixture.query.setPage(page([dose], next: "durable"), for: .insulin, after: nil)
        let saveLock = NSLock()
        var saveCalls = 0
        fixture.manager.saveImportedPage = { core, completion in
            saveLock.lock()
            saveCalls += 1
            let failIncomingPage = saveCalls == 2 // first save is selected-source materialization
            saveLock.unlock()
            if failIncomingPage {
                completion(false)
            } else {
                core.saveChanges(completion: completion)
            }
        }
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("failed save reported") {
            fixture.manager.status(.insulin).message.contains("Local storage failed")
        }
        XCTAssertNil(fixture.anchor(for: .insulin))
        fixture.query.emit(.insulin)
        waitUntil("retry committed") { fixture.anchor(for: .insulin) == self.anchor("durable") }
        XCTAssertEqual(ledger(in: fixture.core).count, 1)
        XCTAssertEqual(treatments(in: fixture.core).count, 1)
    }

    func testRestartReopensStoredTreatmentAndResumesFromDurableAnchor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthKitTherapyRestart.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("therapy.sqlite")
        let suite = "HealthKitTherapyRestart.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dose = sample(.insulin, source: sourceA)
        let firstQuery = FakeQuery()
        firstQuery.setPage(page([dose], next: "saved"), for: .insulin, after: nil)
        let firstCore = try CoreDataManager(testModelName: ConstantsCoreData.modelName,
                                            persistentStoreURL: storeURL)
        let firstManager = HealthKitTherapyImportManager(query: firstQuery, defaults: defaults)
        firstManager.configure(coreDataManager: firstCore)
        defaults.set(sourceA.bundleIdentifier,
                     forKey: "healthTherapyImport.v1.insulin.sourceBundleID")
        defaults.set(sourceA.name, forKey: "healthTherapyImport.v1.insulin.sourceName")
        let authorized = expectation(description: "read request returned")
        firstManager.setEnabled(true, kind: .insulin) { error in
            XCTAssertNil(error)
            authorized.fulfill()
        }
        wait(for: [authorized], timeout: 3)
        waitUntil("initial SQLite import saved") {
            defaults.data(forKey: "healthTherapyImport.v1.insulin.anchor") == self.anchor("saved")
        }
        XCTAssertEqual(treatments(in: firstCore).count, 1)
        try firstCore.disconnectPersistentStoresForTesting()

        let secondQuery = FakeQuery()
        // Replayed UUID after a process restart must not create a second dose.
        secondQuery.setPage(page([dose], next: "resumed"), for: .insulin,
                            after: anchor("saved"))
        let secondCore = try CoreDataManager(testModelName: ConstantsCoreData.modelName,
                                             persistentStoreURL: storeURL)
        defer { try? secondCore.disconnectPersistentStoresForTesting() }
        let secondManager = HealthKitTherapyImportManager(query: secondQuery, defaults: defaults)
        secondManager.configure(coreDataManager: secondCore)
        waitUntil("restart query resumed") {
            defaults.data(forKey: "healthTherapyImport.v1.insulin.anchor") == self.anchor("resumed")
        }
        XCTAssertEqual(Array(secondQuery.anchors(for: .insulin).prefix(1)), [anchor("saved")])
        XCTAssertEqual(ledger(in: secondCore).count, 1)
        XCTAssertEqual(treatments(in: secondCore).count, 1)
    }

    func testSourceFilterAndExactOriginIDPrecedencePreserveRealRepeatAndManualEntries() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let date = Date().addingTimeInterval(-120)
        let external = TreatmentEntry(id: "shared-insulin", date: date, value: 2,
            treatmentType: .Insulin, nightscoutEventType: "Bolus", enteredBy: "Upstream",
            nsManagedObjectContext: core.mainManagedObjectContext)
        let matchingHealth = TreatmentEntry(date: date, value: 2,
            treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "Apple Health",
            nsManagedObjectContext: core.mainManagedObjectContext)
        matchingHealth.healthKitSampleUUID = UUID().uuidString
        matchingHealth.healthKitSourceBundleIdentifier = sourceA.bundleIdentifier
        matchingHealth.healthKitExternalUUID = "shared"
        let realRepeat = TreatmentEntry(date: date, value: 2,
            treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "Apple Health",
            nsManagedObjectContext: core.mainManagedObjectContext)
        realRepeat.healthKitSampleUUID = UUID().uuidString
        realRepeat.healthKitSourceBundleIdentifier = sourceA.bundleIdentifier
        realRepeat.healthKitExternalUUID = "distinct"
        let manual = TreatmentEntry(date: date, value: 2,
            treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "Manual",
            nsManagedObjectContext: core.mainManagedObjectContext)
        let carbsSameOrigin = TreatmentEntry(date: date, value: 2,
            treatmentType: .Carbs, nightscoutEventType: nil, enteredBy: "Apple Health",
            nsManagedObjectContext: core.mainManagedObjectContext)
        carbsSameOrigin.healthKitSampleUUID = UUID().uuidString
        carbsSameOrigin.healthKitSourceBundleIdentifier = sourceA.bundleIdentifier
        carbsSameOrigin.healthKitSyncIdentifier = "shared"
        let rows = [external, matchingHealth, realRepeat, manual, carbsSameOrigin]

        let selected = TherapyMetricsManager.eligibleTreatments(rows, policy: policy(),
            insulinSource: sourceA.bundleIdentifier, carbsSource: sourceA.bundleIdentifier,
            insulinEnabled: true, carbsEnabled: true)
        XCTAssertEqual(selected.count, 4)
        XCTAssertTrue(selected.contains(external))
        XCTAssertFalse(selected.contains(matchingHealth))
        XCTAssertTrue(selected.contains(realRepeat), "equal time and amount are not a duplicate")
        XCTAssertTrue(selected.contains(manual))
        XCTAssertTrue(selected.contains(carbsSameOrigin), "a carb ID cannot mask an insulin dose")

        let switched = TherapyMetricsManager.eligibleTreatments(rows, policy: policy(),
            insulinSource: sourceB.bundleIdentifier, carbsSource: sourceB.bundleIdentifier,
            insulinEnabled: true, carbsEnabled: true)
        XCTAssertEqual(switched.count, 2)
        XCTAssertTrue(switched.contains(external))
        XCTAssertTrue(switched.contains(manual))
        let off = TherapyMetricsManager.eligibleTreatments(rows, policy: policy(),
            insulinSource: sourceA.bundleIdentifier, carbsSource: sourceA.bundleIdentifier,
            insulinEnabled: false, carbsEnabled: false)
        XCTAssertEqual(off.count, 2)
    }

    func testHealthImportsNeverEnterNightscoutUploadFetch() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let local = TreatmentEntry(date: Date(), value: 2, treatmentType: .Insulin,
            nightscoutEventType: nil, enteredBy: "Manual",
            nsManagedObjectContext: core.mainManagedObjectContext)
        let health = TreatmentEntry(date: Date(), value: 20, treatmentType: .Carbs,
            nightscoutEventType: nil, enteredBy: "Apple Health",
            nsManagedObjectContext: core.mainManagedObjectContext)
        health.healthKitSampleUUID = UUID().uuidString
        health.healthKitSourceBundleIdentifier = sourceA.bundleIdentifier
        XCTAssertTrue(core.saveChangesSynchronously())
        let uploadRows = TreatmentEntryAccessor(coreDataManager: core)
            .getLatestTreatmentsForNightscout(limit: 10)
        XCTAssertEqual(uploadRows.count, 1)
        XCTAssertTrue(uploadRows.first === local)
    }

    private enum ReadFailure: Error { case locked }

    private final class ImportFixture {
        let suiteName = "HealthKitTherapyImportTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let query = FakeQuery()
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let manager: HealthKitTherapyImportManager
        private var configured = false

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            manager = HealthKitTherapyImportManager(query: query, defaults: defaults)
        }

        func configureOnce() {
            guard !configured else { return }
            configured = true
            manager.configure(coreDataManager: core)
        }

        func anchor(for kind: HealthTherapyImportKind) -> Data? {
            defaults.data(forKey: "healthTherapyImport.v1.\(kind.rawValue).anchor")
        }

        func close() { defaults.removePersistentDomain(forName: suiteName) }
    }

    private final class FakeQuery: HealthTherapyQuerying {
        private let lock = NSLock()
        private var pages: [String: HealthTherapyImportPage] = [:]
        private var failures: [HealthTherapyImportKind: Error] = [:]
        private var authorizationFailures: [HealthTherapyImportKind: Error] = [:]
        private var observed: [HealthTherapyImportKind: (@escaping () -> Void) -> Void] = [:]
        private var requestedAnchors: [HealthTherapyImportKind: [Data?]] = [:]
        private var heldPages = Set<String>()
        private var pendingDeliveries: [String: () -> Void] = [:]

        private func key(_ kind: HealthTherapyImportKind, _ anchor: Data?) -> String {
            kind.rawValue + ":" + (anchor.flatMap { String(data: $0, encoding: .utf8) } ?? "initial")
        }

        func setPage(_ page: HealthTherapyImportPage, for kind: HealthTherapyImportKind, after anchor: Data?) {
            lock.lock(); defer { lock.unlock() }
            pages[key(kind, anchor)] = page
        }

        func holdPage(for kind: HealthTherapyImportKind, after anchor: Data?) {
            lock.lock(); defer { lock.unlock() }
            heldPages.insert(key(kind, anchor))
        }

        func releaseHeldPage(for kind: HealthTherapyImportKind, after anchor: Data?) {
            lock.lock()
            let key = key(kind, anchor)
            heldPages.remove(key)
            let deliver = pendingDeliveries.removeValue(forKey: key)
            lock.unlock()
            deliver?()
        }

        func setError(_ error: Error?, for kind: HealthTherapyImportKind) {
            lock.lock(); defer { lock.unlock() }
            failures[kind] = error
        }

        func setAuthorizationError(_ error: Error?, for kind: HealthTherapyImportKind) {
            lock.lock(); defer { lock.unlock() }
            authorizationFailures[kind] = error
        }

        func anchors(for kind: HealthTherapyImportKind) -> [Data?] {
            lock.lock(); defer { lock.unlock() }
            return requestedAnchors[kind] ?? []
        }

        func emit(_ kind: HealthTherapyImportKind) {
            lock.lock()
            let callback = observed[kind]
            lock.unlock()
            callback?({})
        }

        func requestReadAuthorization(for kind: HealthTherapyImportKind,
                                      completion: @escaping (Error?) -> Void) {
            lock.lock()
            let failure = authorizationFailures[kind]
            lock.unlock()
            completion(failure)
        }

        func discoverSources(for kind: HealthTherapyImportKind,
                             completion: @escaping ([HealthTherapyImportSource], Error?) -> Void) {
            completion([], nil)
        }

        func page(for kind: HealthTherapyImportKind, since: Date, anchor: Data?, limit: Int,
                  completion: @escaping (Result<HealthTherapyImportPage, Error>) -> Void) {
            lock.lock()
            requestedAnchors[kind, default: []].append(anchor)
            let error = failures[kind]
            let response = pages[key(kind, anchor)]
            let pageKey = key(kind, anchor)
            let isHeld = heldPages.contains(pageKey)
            let delivery = {
                if let error { completion(.failure(error)); return }
                completion(.success(response ?? HealthTherapyImportPage(
                    samples: [], deletedUUIDs: [], nextAnchor: anchor ?? Data("empty".utf8), hasMore: false)))
            }
            if isHeld { pendingDeliveries[pageKey] = delivery }
            lock.unlock()
            if !isHeld { delivery() }
        }

        func observe(_ kind: HealthTherapyImportKind,
                     onChange: @escaping (@escaping () -> Void) -> Void) {
            lock.lock(); defer { lock.unlock() }
            observed[kind] = onChange
        }
    }
}
