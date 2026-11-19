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

    func testSplitSuggestionUsesInventoryAfterPrimingAndTheActualPenStep() {
        XCTAssertEqual(PenCartridgeInventory.suggestedOldUnits(total: 6, remaining: 5, penStep: 0.5), 3)
        XCTAssertEqual(PenCartridgeInventory.suggestedOldUnits(total: 6, remaining: 3, penStep: 0.5), 1)
        XCTAssertEqual(PenCartridgeInventory.suggestedOldUnits(total: 6, remaining: 5.4, penStep: 0.5), 3)
        XCTAssertEqual(PenCartridgeInventory.suggestedOldUnits(total: 6, remaining: 50, penStep: 0.5), 6)
        XCTAssertEqual(PenCartridgeInventory.suggestedOldUnits(total: 6, remaining: 1, penStep: 0.5), 0)
        XCTAssertEqual(PenCartridgeInventory.suggestedOldUnits(total: 0.3, remaining: 2.3, penStep: 0.1), 0.3)
        let invalidRemaining: [Double?] = [nil, -.infinity, .infinity, .nan, -1, 301]
        for remaining in invalidRemaining {
            XCTAssertNil(PenCartridgeInventory.suggestedOldUnits(total: 6, remaining: remaining, penStep: 0.5))
        }
        XCTAssertNil(PenCartridgeInventory.suggestedOldUnits(total: 6, remaining: 5, penStep: 0))
        XCTAssertNil(PenCartridgeInventory.suggestedOldUnits(total: .infinity, remaining: 5, penStep: 0.5))
    }

    @MainActor func testSameSplitDebitsNewShareOnceBeforeAtAndAfterCartridgeChange() throws {
        let defaults = isolatedDefaults()
        let inventory = PenCartridgeInventory(defaults: defaults, fileURL: fileURL)
        for recordedSeconds in [5.0, 10.0, 15.0] {
            let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
            XCTAssertTrue(inventory.setRemaining(5, at: start))
            let id = UUID().uuidString
            let allocation = PenCartridgeAllocation(bolusID: id, oldUnits: 3, totalUnits: 6)
            let origin = try XCTUnwrap(inventory.baselineID)
            XCTAssertTrue(inventory.newCartridge(allocation: allocation, expectedBaselineID: origin,
                                                at: start.addingTimeInterval(10)))
            let dose = entry(core, seconds: recordedSeconds, units: 6, id: id.lowercased())
            entry(core, seconds: recordedSeconds, units: 6, id: id)
            entry(core, seconds: 20, units: 2)
            XCTAssertTrue(core.saveChangesSynchronously())
            let now = start.addingTimeInterval(30)
            XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: now).remainingUnits, 291)
            XCTAssertEqual(dose.value, 6, "Inventory attribution preserves the complete administered treatment")
            let reopened = PenCartridgeInventory(defaults: defaults, fileURL: fileURL)
            XCTAssertEqual(reopened.snapshot(coreDataManager: core, now: now),
                           inventory.snapshot(coreDataManager: core, now: now))
        }
    }

    @MainActor func testPhysicalSplitIsUnknownUntilItsExactDoseIsDurablyCommitted() throws {
        let defaults = isolatedDefaults()
        let inventory = PenCartridgeInventory(defaults: defaults, fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        XCTAssertTrue(inventory.setRemaining(5, at: start))
        let allocation = PenCartridgeAllocation(bolusID: UUID().uuidString, oldUnits: 3, totalUnits: 6)
        XCTAssertTrue(inventory.newCartridge(allocation: allocation,
            expectedBaselineID: try XCTUnwrap(inventory.baselineID), at: start.addingTimeInterval(10)))
        let now = start.addingTimeInterval(30)
        let reopened = PenCartridgeInventory(defaults: defaults, fileURL: fileURL)
        XCTAssertEqual(reopened.allocation, allocation)
        XCTAssertNil(reopened.snapshot(coreDataManager: core, now: now).remainingUnits)
        entry(core, seconds: 15, units: 6) // An unrelated dose cannot complete the pending split.
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertNil(reopened.snapshot(coreDataManager: core, now: now).remainingUnits)
        entry(core, seconds: 5, units: 6, id: allocation.bolusID)
        XCTAssertNil(reopened.snapshot(coreDataManager: core, now: now).remainingUnits)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertEqual(reopened.snapshot(coreDataManager: core, now: now).remainingUnits, 287)
    }

    @MainActor func testRepeatedPhysicalSplitPreservesCartridgeAndRejectsConflictingOrStaleChanges() throws {
        let inventory = PenCartridgeInventory(defaults: isolatedDefaults(), fileURL: fileURL)
        XCTAssertTrue(inventory.setRemaining(5, at: start))
        let origin = try XCTUnwrap(inventory.baselineID)
        let allocation = PenCartridgeAllocation(bolusID: UUID().uuidString, oldUnits: 3, totalUnits: 6)
        XCTAssertTrue(inventory.newCartridge(allocation: allocation, expectedBaselineID: origin,
                                            at: start.addingTimeInterval(10)))
        let persisted = try Data(contentsOf: fileURL)
        XCTAssertTrue(inventory.newCartridge(allocation: allocation, expectedBaselineID: origin,
                                            at: start.addingTimeInterval(20)))
        XCTAssertEqual(try Data(contentsOf: fileURL), persisted)
        let conflicting = PenCartridgeAllocation(bolusID: allocation.bolusID, oldUnits: 2, totalUnits: 6)
        XCTAssertFalse(inventory.newCartridge(allocation: conflicting, expectedBaselineID: origin,
                                             at: start.addingTimeInterval(20)))
        XCTAssertFalse(inventory.updateAllocation(conflicting, expectedBaselineID: origin))
        XCTAssertEqual(try Data(contentsOf: fileURL), persisted)
        for invalid in [PenCartridgeAllocation(bolusID: "", oldUnits: 3, totalUnits: 6),
                        PenCartridgeAllocation(bolusID: allocation.bolusID, oldUnits: -1, totalUnits: 6),
                        PenCartridgeAllocation(bolusID: allocation.bolusID, oldUnits: 7, totalUnits: 6),
                        PenCartridgeAllocation(bolusID: allocation.bolusID, oldUnits: .nan, totalUnits: 6),
                        PenCartridgeAllocation(bolusID: allocation.bolusID, oldUnits: 0, totalUnits: 0)] {
            XCTAssertFalse(inventory.updateAllocation(invalid, expectedBaselineID: try XCTUnwrap(inventory.baselineID)))
        }
    }

    @MainActor func testEditedSplitRequiresExplicitNewAllocationAndDeletionRemovesItsDebit() throws {
        let inventory = PenCartridgeInventory(defaults: isolatedDefaults(), fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        XCTAssertTrue(inventory.newCartridge(at: start.addingTimeInterval(10)))
        let dose = entry(core, seconds: 5, units: 6)
        XCTAssertTrue(core.saveChangesSynchronously())
        let id = try XCTUnwrap(dose.localTreatmentUUID)
        XCTAssertTrue(inventory.updateAllocation(PenCartridgeAllocation(bolusID: id, oldUnits: 3, totalUnits: 6),
            expectedBaselineID: try XCTUnwrap(inventory.baselineID)))
        let now = start.addingTimeInterval(30)
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: now).remainingUnits, 295)
        dose.value = 7
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: now).remainingUnits, 295)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertNil(inventory.snapshot(coreDataManager: core, now: now).remainingUnits)
        let revision = try XCTUnwrap(inventory.baselineID)
        let corrected = PenCartridgeAllocation(bolusID: id, oldUnits: 3, totalUnits: 7)
        XCTAssertTrue(inventory.updateAllocation(corrected, expectedBaselineID: revision))
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: now).remainingUnits, 294)
        let revised = try XCTUnwrap(inventory.baselineID)
        XCTAssertTrue(inventory.updateAllocation(corrected, expectedBaselineID: revised))
        XCTAssertEqual(inventory.baselineID, revised)
        dose.treatmentdeleted = true
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: now).remainingUnits, 300)
    }

    @MainActor func testSplitWithAllUnitsFromOldCartridgeDoesNotPrimeUnusedNewCartridge() throws {
        let inventory = PenCartridgeInventory(defaults: isolatedDefaults(), fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        XCTAssertTrue(inventory.newCartridge(at: start))
        let dose = entry(core, units: 6)
        XCTAssertTrue(core.saveChangesSynchronously())
        let id = try XCTUnwrap(dose.localTreatmentUUID)
        XCTAssertTrue(inventory.updateAllocation(PenCartridgeAllocation(bolusID: id, oldUnits: 6, totalUnits: 6),
            expectedBaselineID: try XCTUnwrap(inventory.baselineID)))
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: start.addingTimeInterval(2)).remainingUnits, 300)
        XCTAssertTrue(inventory.updateAllocation(PenCartridgeAllocation(bolusID: id, oldUnits: 0, totalUnits: 6),
            expectedBaselineID: try XCTUnwrap(inventory.baselineID)))
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: start.addingTimeInterval(2)).remainingUnits, 292)
    }

    @MainActor func testManualCorrectionClearsAllocationAndCannotBeReopenedByAnOldCallback() throws {
        let inventory = PenCartridgeInventory(defaults: isolatedDefaults(), fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        XCTAssertTrue(inventory.newCartridge(at: start))
        let id = UUID().uuidString
        let allocation = PenCartridgeAllocation(bolusID: id, oldUnits: 3, totalUnits: 6)
        XCTAssertTrue(inventory.updateAllocation(allocation, expectedBaselineID: try XCTUnwrap(inventory.baselineID)))
        let oldRevision = try XCTUnwrap(inventory.baselineID)
        entry(core, seconds: 1, units: 6, id: id)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertTrue(inventory.setRemaining(280, at: start.addingTimeInterval(5)))
        XCTAssertNil(inventory.allocation)
        XCTAssertFalse(inventory.canAllocateCurrentCartridge)
        XCTAssertFalse(inventory.updateAllocation(allocation, expectedBaselineID: oldRevision))
        XCTAssertFalse(inventory.updateAllocation(allocation, expectedBaselineID: try XCTUnwrap(inventory.baselineID)))
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: start.addingTimeInterval(10)).remainingUnits, 280)
    }

    @MainActor func testLegacyBaselineReadsWithoutInventingAnAllocationOrAConfirmedPhysicalChange() throws {
        let inventory = PenCartridgeInventory(defaults: isolatedDefaults(), fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        XCTAssertTrue(inventory.newCartridge(at: start))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        legacy.removeValue(forKey: "isNewCartridge")
        legacy.removeValue(forKey: "allocation")
        legacy.removeValue(forKey: "allocationSourceBaselineID")
        try JSONSerialization.data(withJSONObject: legacy).write(to: fileURL)
        entry(core, units: 6)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertNil(inventory.allocation)
        XCTAssertFalse(inventory.canAllocateCurrentCartridge)
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: start.addingTimeInterval(10)).remainingUnits, 292)
    }

    @MainActor func testSplitCannotTrustForeignBasalFutureOrConflictingLinkedTreatment() throws {
        let inventory = PenCartridgeInventory(defaults: isolatedDefaults(), fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        XCTAssertTrue(inventory.newCartridge(at: start.addingTimeInterval(10)))
        let dose = entry(core, seconds: 5, units: 6)
        let id = try XCTUnwrap(dose.localTreatmentUUID)
        XCTAssertTrue(inventory.updateAllocation(PenCartridgeAllocation(bolusID: id, oldUnits: 3, totalUnits: 6),
            expectedBaselineID: try XCTUnwrap(inventory.baselineID)))
        let now = start.addingTimeInterval(20)
        dose.healthKitSampleUUID = UUID().uuidString
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertNil(inventory.snapshot(coreDataManager: core, now: now).remainingUnits)
        dose.healthKitSampleUUID = nil
        dose.treatmentType = .BasalInjection
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertNil(inventory.snapshot(coreDataManager: core, now: now).remainingUnits)
        dose.treatmentType = .Insulin
        dose.date = now.addingTimeInterval(1)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertNil(inventory.snapshot(coreDataManager: core, now: now).remainingUnits)
        dose.date = start.addingTimeInterval(5)
        let duplicate = entry(core, seconds: 5, units: 6, id: id)
        duplicate.treatmentdeleted = true
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertNil(inventory.snapshot(coreDataManager: core, now: now).remainingUnits)
    }

    @MainActor func testHistoryReplacementBeforeSwitchInvalidatesAllocation() throws {
        let defaults = isolatedDefaults()
        let inventory = PenCartridgeInventory(defaults: defaults, fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        XCTAssertTrue(inventory.newCartridge(at: start.addingTimeInterval(10)))
        let dose = entry(core, seconds: 5, units: 6)
        XCTAssertTrue(core.saveChangesSynchronously())
        let allocation = PenCartridgeAllocation(bolusID: try XCTUnwrap(dose.localTreatmentUUID), oldUnits: 3, totalUnits: 6)
        XCTAssertTrue(inventory.updateAllocation(allocation, expectedBaselineID: try XCTUnwrap(inventory.baselineID)))
        let now = start.addingTimeInterval(30)
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: now).remainingUnits, 295)
        inventory.invalidateIfHistoryWasReplaced(through: start.addingTimeInterval(5))
        XCTAssertNil(PenCartridgeInventory(defaults: defaults, fileURL: fileURL)
            .snapshot(coreDataManager: core, now: now).remainingUnits)
        XCTAssertFalse(inventory.updateAllocation(allocation, expectedBaselineID: try XCTUnwrap(inventory.baselineID)))
    }


    @MainActor func testOfflineWatchSplitUsesBoundIdentityAndOriginalTimeAcrossRedelivery() async throws {
        let inventory = PenCartridgeInventory(defaults: isolatedDefaults(), fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let operation = WatchManualTreatment(id: UUID(), recordedAt: start.addingTimeInterval(5),
                                            kind: .insulin, amount: 6)
        XCTAssertTrue(inventory.newCartridge(at: start.addingTimeInterval(10)))
        XCTAssertTrue(inventory.updateAllocation(PenCartridgeAllocation(bolusID: operation.id.uuidString,
            oldUnits: 3, totalUnits: 6), expectedBaselineID: try XCTUnwrap(inventory.baselineID)))
        let delivery = start.addingTimeInterval(30)
        XCTAssertNil(inventory.snapshot(coreDataManager: core, now: delivery).remainingUnits)
        func receive() async -> WatchManualTreatmentStore.Outcome {
            await withCheckedContinuation { continuation in
                WatchManualTreatmentStore.save(operation, coreDataManager: core, at: delivery) {
                    continuation.resume(returning: $0)
                }
            }
        }
        let first = await receive()
        let duplicate = await receive()
        XCTAssertEqual(first, .stored)
        XCTAssertEqual(duplicate, .alreadyStored)
        XCTAssertEqual(inventory.snapshot(coreDataManager: core, now: delivery).remainingUnits, 295)
    }

    @MainActor func testFailedPhysicalSplitWritePreservesThePriorBaseline() throws {
        let inventory = PenCartridgeInventory(defaults: isolatedDefaults(), fileURL: fileURL)
        XCTAssertTrue(inventory.setRemaining(5, at: start))
        let origin = try XCTUnwrap(inventory.baselineID)
        let original = try Data(contentsOf: fileURL)
        let allocation = PenCartridgeAllocation(bolusID: UUID().uuidString, oldUnits: 3, totalUnits: 6)
        // The blocked storage path cannot establish a new physical-change record.
        let folder = fileURL.deletingLastPathComponent()
        let saved = folder.appendingPathExtension("saved")
        try FileManager.default.moveItem(at: folder, to: saved)
        defer { try? FileManager.default.removeItem(at: saved) }
        try Data().write(to: folder)
        XCTAssertFalse(inventory.newCartridge(allocation: allocation, expectedBaselineID: origin,
                                             at: start.addingTimeInterval(10)))
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: saved, to: folder)
        XCTAssertEqual(try Data(contentsOf: fileURL), original)
        XCTAssertEqual(inventory.baselineID, origin)
        XCTAssertNil(inventory.allocation)
    }


    @MainActor func testStaleSplitInvalidatesCurrentCountAcrossRestartUntilPhysicalCorrection() throws {
        let defaults = isolatedDefaults()
        let inventory = PenCartridgeInventory(defaults: defaults, fileURL: fileURL)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        XCTAssertTrue(inventory.newCartridge(at: start))
        entry(core, seconds: 1, units: 6)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertTrue(inventory.setRemaining(280, at: start.addingTimeInterval(5)))
        let priorFile = try Data(contentsOf: fileURL)
        let cartridge = inventory.cartridgeID
        inventory.invalidateEstimate()
        let reopened = PenCartridgeInventory(defaults: defaults, fileURL: fileURL)
        let now = start.addingTimeInterval(10)
        XCTAssertEqual(reopened.cartridgeID, cartridge)
        XCTAssertNil(reopened.snapshot(coreDataManager: core, now: now).remainingUnits)
        // Even an unreadable/failed baseline update cannot reactivate the previous count.
        try priorFile.write(to: fileURL)
        XCTAssertNil(reopened.snapshot(coreDataManager: core, now: now).remainingUnits)
        XCTAssertTrue(reopened.setRemaining(270, at: now))
        XCTAssertEqual(reopened.snapshot(coreDataManager: core, now: now).remainingUnits, 270)
    }

}
