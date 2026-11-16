import CoreData
import XCTest
@testable import xdrip

final class PenCartridgeInventoryTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    private let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("baseline.json")

    override func tearDownWithError() throws {
        let folder = fileURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        try super.tearDownWithError()
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "PenCartridgeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.therapyDataSourceType = .none
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor @discardableResult
    private func entry(_ core: CoreDataManager, seconds: Double = 1, units: Double = 3,
                       type: TreatmentType = .Insulin, id: String? = UUID().uuidString) -> TreatmentEntry {
        let entry = TreatmentEntry(date: start.addingTimeInterval(seconds), value: units, treatmentType: type,
                                   nightscoutEventType: nil, enteredBy: nil,
                                   nsManagedObjectContext: core.mainManagedObjectContext)
        entry.localTreatmentUUID = id
        return entry
    }

    @MainActor func testManualAndNewBaselinesValidatePersistAndKeepIndependentCartridgeIdentity() {
        let defaults = isolatedDefaults()
        let inventory = PenCartridgeInventory(defaults: defaults, fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        XCTAssertEqual(inventory.snapshot(coreDataManager: core), .unconfigured)
        XCTAssertTrue(inventory.setRemaining(75.5, at: start))
        let first = inventory.snapshot(coreDataManager: core, now: start)
        XCTAssertEqual(first.remainingUnits, 75.5)
        XCTAssertNotNil(first.cartridgeID)
        XCTAssertNotNil(first.baselineID)
        for invalid in [-0.1, 300.1, Double.infinity, -.infinity, .nan] {
            XCTAssertFalse(inventory.setRemaining(invalid, at: start))
        }
        XCTAssertFalse(inventory.newCartridge(at: Date(timeIntervalSinceReferenceDate: .infinity)))
        XCTAssertEqual(PenCartridgeInventory(defaults: defaults, fileURL: fileURL).snapshot(coreDataManager: core, now: start), first)
        XCTAssertTrue(inventory.setRemaining(0, at: start))
        let corrected = inventory.snapshot(coreDataManager: core, now: start)
        XCTAssertEqual(corrected.remainingUnits, 0)
        XCTAssertEqual(corrected.cartridgeID, first.cartridgeID)
        XCTAssertNotEqual(corrected.baselineID, first.baselineID)
        XCTAssertTrue(inventory.newCartridge(at: start))
        let new = inventory.snapshot(coreDataManager: core, now: start)
        XCTAssertEqual(new.remainingUnits, 300)
        XCTAssertNotEqual(new.cartridgeID, first.cartridgeID)
        XCTAssertTrue(inventory.beginCartridge(remaining: 25, at: start))
        XCTAssertNotEqual(inventory.cartridgeID, new.cartridgeID)
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: start).remainingUnits, 25)
    }

    @MainActor func testOnlyActualCommittedLocalRapidBolusesAndTheirPrimingConsumeStock() {
        let inventory = PenCartridgeInventory(defaults: isolatedDefaults(), fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        XCTAssertTrue(inventory.newCartridge(at: start))
        let bolus = entry(core, units: 4.5)
        // Uploading a local row keeps it attributable to this pen.
        bolus.id = "server-insulin"
        bolus.uploaded = true
        entry(core, units: 4.5) // Distinct dose at the exact same time.
        entry(core, units: 0)
        entry(core, type: .BasalInjection)
        entry(core, type: .Basal)
        entry(core, type: .AutomaticBasal)
        entry(core, type: .Carbs)
        entry(core, type: .Note)
        entry(core).treatmentdeleted = true
        entry(core).healthKitSampleUUID = UUID().uuidString
        entry(core).careLinkSourceIdentifier = "import"
        entry(core).nightscoutEventType = "Bolus"
        entry(core, id: nil)
        entry(core, seconds: 0) // At the physical count; already included in it.
        entry(core, seconds: 11)
        let now = start.addingTimeInterval(10)
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: now).remainingUnits, 300)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: now).remainingUnits, 287)
        XCTAssertEqual(bolus.value, 4.5)
        // An unsaved edit cannot change the committed inventory.
        bolus.value = 6
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: now).remainingUnits, 287)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: now).remainingUnits, 285.5)
        bolus.treatmentdeleted = true
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: now).remainingUnits, 293.5)
    }

    @MainActor func testOfflineWatchDeliveryAndRedeliveryRespectCorrectionAndRecordedTime() async {
        let inventory = PenCartridgeInventory(defaults: isolatedDefaults(), fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        XCTAssertTrue(inventory.newCartridge(at: start))
        let correctedAt = start.addingTimeInterval(20)
        XCTAssertTrue(inventory.setRemaining(10, at: correctedAt))
        let delivery = start.addingTimeInterval(60)
        func receive(_ treatment: WatchManualTreatment) async -> WatchManualTreatmentStore.Outcome {
            await withCheckedContinuation { continuation in
                WatchManualTreatmentStore.save(treatment, coreDataManager: core, at: delivery) {
                    continuation.resume(returning: $0)
                }
            }
        }
        let old = WatchManualTreatment(id: UUID(), recordedAt: correctedAt.addingTimeInterval(-1),
                                       kind: .insulin, amount: 4)
        let recent = WatchManualTreatment(id: UUID(), recordedAt: correctedAt.addingTimeInterval(1),
                                          kind: .insulin, amount: 9)
        let oldResult = await receive(old)
        XCTAssertEqual(oldResult, .stored)
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: delivery).remainingUnits, 10)
        let first = await receive(recent)
        let replay = await receive(recent)
        XCTAssertEqual(first, .stored)
        XCTAssertEqual(replay, .alreadyStored)
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: delivery).remainingUnits, -1)
        XCTAssertTrue(inventory.newCartridge(at: delivery))
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: delivery).remainingUnits, 300)
    }

    @MainActor func testStoreUnavailableCorruptBaselineOrInconsistentSourceCannotReportAFullPen() throws {
        let defaults = isolatedDefaults()
        let inventory = PenCartridgeInventory(defaults: defaults, fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let now = start.addingTimeInterval(30)
        XCTAssertTrue(inventory.newCartridge(at: start))
        entry(core, seconds: 1)
        entry(core, seconds: 2)
        entry(core, seconds: 3)
        XCTAssertTrue(core.saveChangesSynchronously())
        let cutover = TreatmentSourceCutover(cutoff: start.addingTimeInterval(2),
                                            insulinSourceBundleID: "test", carbohydrateSourceBundleID: "test")
        XCTAssertTrue(TreatmentSourceCutover.persist(cutover, defaults: defaults))
        XCTAssertNil(inventory.snapshot(coreDataManager: core, now: now).remainingUnits,
                     "A new source boundary inside the baseline must not return insulin to stock")
        XCTAssertTrue(inventory.setRemaining(300, at: cutover.cutoff))
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: now).remainingUnits, 295)
        defaults.set(true, forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey)
        XCTAssertNil(inventory.snapshot(coreDataManager: core, now: now).remainingUnits)
        defaults.removeObject(forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey)
        defaults.set(Data(), forKey: TreatmentSourceCutover.defaultsKey)
        XCTAssertNil(inventory.snapshot(coreDataManager: core, now: now).remainingUnits)
        defaults.removeObject(forKey: TreatmentSourceCutover.defaultsKey)
        XCTAssertNil(inventory.snapshot(coreDataManager: core, now: start.addingTimeInterval(-1)).remainingUnits)
        try core.disconnectPersistentStoresForTesting()
        XCTAssertNil(inventory.snapshot(coreDataManager: core, now: now).remainingUnits)
        try Data().write(to: fileURL)
        let damaged = inventory.snapshot(coreDataManager: core, now: now)
        XCTAssertTrue(damaged.isConfigured)
        XCTAssertNil(damaged.baselineID)
        XCTAssertNil(damaged.remainingUnits)
    }

    @MainActor func testAtomicBaselineFailurePreservesPriorCountAndDirectoryIsExcludedFromBackup() throws {
        let inventory = PenCartridgeInventory(defaults: isolatedDefaults(), fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        XCTAssertTrue(inventory.setRemaining(90, at: start))
        let folder = fileURL.deletingLastPathComponent()
        XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        // Block directory creation with a regular file, then restore the last successful write.
        let saved = folder.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: folder, to: saved)
        defer { try? FileManager.default.removeItem(at: saved) }
        try Data().write(to: folder)
        XCTAssertFalse(inventory.setRemaining(52, at: start))
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: saved, to: folder)
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: start).remainingUnits, 90)
    }

    @MainActor func testOverlappingReplacedHistoryInvalidatesUntilPhysicalCorrectionEvenAfterRestart() throws {
        let defaults = isolatedDefaults()
        let inventory = PenCartridgeInventory(defaults: defaults, fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        XCTAssertTrue(inventory.setRemaining(80, at: start))
        let first = inventory.snapshot(coreDataManager: core, now: start)
        inventory.invalidateIfHistoryWasReplaced(through: start)
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: start), first)
        inventory.invalidateIfHistoryWasReplaced(through: start.addingTimeInterval(1))
        let reopened = PenCartridgeInventory(defaults: defaults, fileURL: fileURL)
        let invalidated = reopened.snapshot(coreDataManager: core, now: start)
        XCTAssertTrue(invalidated.isConfigured)
        XCTAssertNil(invalidated.remainingUnits)
        XCTAssertEqual(invalidated.cartridgeID, first.cartridgeID)
        XCTAssertNotEqual(invalidated.baselineID, first.baselineID)
        XCTAssertTrue(reopened.setRemaining(50, at: start))
        XCTAssertEqual(reopened.snapshot(coreDataManager: core, now: start).remainingUnits, 50)

        // If the local file is unreadable during a restore, a later successful read must
        // not reactivate that old count. Maintenance itself can still finish.
        let persisted = try Data(contentsOf: fileURL)
        try Data([0xff]).write(to: fileURL)
        reopened.invalidateIfHistoryWasReplaced(through: start.addingTimeInterval(10))
        try persisted.write(to: fileURL)
        XCTAssertNil(reopened.snapshot(coreDataManager: core, now: start).remainingUnits)
        XCTAssertTrue(reopened.setRemaining(30, at: start))
        XCTAssertEqual(reopened.snapshot(coreDataManager: core, now: start).remainingUnits, 30)
    }

    @MainActor func testFractionalArithmeticReturnsExactThresholdAndZero() {
        let inventory = PenCartridgeInventory(defaults: isolatedDefaults(), fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        XCTAssertTrue(inventory.setRemaining(11.3, at: start))
        entry(core, seconds: 1, units: 2)
        XCTAssertTrue(core.saveChangesSynchronously())
        let corrected = start.addingTimeInterval(2)
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: corrected).remainingUnits, 7.3)
        XCTAssertTrue(inventory.setRemaining(4.3, at: corrected))
        entry(core, seconds: 3, units: 0.1)
        entry(core, seconds: 4, units: 0.2)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: start.addingTimeInterval(4)).remainingUnits, 0)
    }

    @MainActor func testExternalTherapyOwnerWithoutCutoverCannotEstablishLocalPenCoverage() {
        let defaults = isolatedDefaults()
        let inventory = PenCartridgeInventory(defaults: defaults, fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        XCTAssertTrue(inventory.setRemaining(25, at: start))
        XCTAssertNil(TreatmentSourceCutover.current(defaults: defaults))
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: start).remainingUnits, 25)
        defaults.nightscoutEnabled = true
        defaults.therapyDataSourceType = .nightscout
        XCTAssertEqual(defaults.dataFlowPolicy.therapyDataSource, .nightscout)
        XCTAssertNil(inventory.snapshot(coreDataManager: core, now: start).remainingUnits)
    }

    @MainActor func testDuplicateStableIdentityCountsOnceAndConflictingAmountsGiveUnknown() {
        let defaults = isolatedDefaults()
        let inventory = PenCartridgeInventory(defaults: defaults, fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        XCTAssertTrue(inventory.setRemaining(10, at: start))
        let id = UUID().uuidString
        entry(core, id: id)
        let duplicate = entry(core, id: id.lowercased())
        let now = start.addingTimeInterval(20)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: now).remainingUnits, 5)
        duplicate.value += 1
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertNil(inventory.snapshot(coreDataManager: core, now: now).remainingUnits)
    }
}
