import CoreData
import UserNotifications
import XCTest
@testable import xdrip

@MainActor final class PenCartridgeMonitorTests: XCTestCase {
    private final class Delivery: PenCartridgeNotificationDelivery {
        var requests = [UNNotificationRequest]()
        var removed = [String]()
        var systemRequests = [String: UNNotificationRequest]()
        func contains(identifier: String, snoozeID: UUID?) async -> Bool {
            guard let request = systemRequests[identifier] else { return false }
            return request.content.userInfo["snooze"] as? String == snoozeID?.uuidString
        }
        var failNext = false
        var interruptAcknowledgment = false

        func add(_ request: UNNotificationRequest) async throws {
            if failNext {
                failNext = false
                throw CocoaError(.fileWriteUnknown)
            }
            requests.append(request)
            systemRequests[request.identifier] = request
            if interruptAcknowledgment { throw CocoaError(.fileWriteUnknown) }
        }

        func remove(_ identifiers: [String]) {
            removed.append(contentsOf: identifiers)
            identifiers.forEach { systemRequests[$0] = nil }
        }
    }

    @MainActor private final class Fixture {
        let defaults: UserDefaults
        let suite = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let delivery = Delivery()
        var now = Date(timeIntervalSince1970: 1_800_000_000)

        init() {
            defaults = UserDefaults(suiteName: suite)!
            defaults.therapyDataSourceType = .none
        }

        func monitor(configured: Bool = true) -> PenCartridgeMonitor {
            let inventory = PenCartridgeInventory(defaults: defaults, fileURL: directory.appendingPathComponent("baseline.json"))
            let monitor = PenCartridgeMonitor(defaults: defaults, inventory: inventory, delivery: delivery, clock: { self.now })
            if configured { monitor.configure(coreDataManager: core) }
            return monitor
        }

        func calculator(_ monitor: PenCartridgeMonitor, automatic: Bool = false) -> PenDoseCalculatorViewModel {
            var profile = PenDoseProfile.prefilledUnconfirmed
            XCTAssertTrue(profile.confirm())
            let confirmed = profile
            return PenDoseCalculatorViewModel(coreDataManager: core,
                logJournal: PenDoseLogJournal(directory: directory.appendingPathComponent("journal")),
                metadataStore: MealPlanMetadataStore(directory: directory.appendingPathComponent("meals")),
                profileProvider: { confirmed }, sourceReadyOverride: { true },
                snapshotProvider: { date, _ in
                    let samples = stride(from: -30, through: 0, by: 5).map {
                        GlucoseForecastSample(date: date.addingTimeInterval(Double($0) * 60),
                            glucoseMgdl: 140, sensorID: "synthetic-cartridge-sensor")
                    }
                    return PenDoseInputSnapshot.make(capturedAt: date, glucose: samples, treatments: [],
                        therapySettings: TherapyModelSettings(), treatmentRevision: 1,
                        sourceSignature: "synthetic-local-source")
                }, automaticallyFillMealDose: automatic, forecastDefaults: defaults,
                mealShortcutDefaults: defaults, cartridgeMonitor: monitor)
        }

        func editor(_ entry: TreatmentEntry, monitor: PenCartridgeMonitor) -> TreatmentEditorViewModel {
            TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: entry,
                localSaveJournal: PenDoseLogJournal(directory: directory.appendingPathComponent("editor-journal")),
                cartridgeMonitor: monitor)
        }

        var entries: [TreatmentEntry] {
            TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil)
        }

        @discardableResult func dose(_ units: Double, at date: Date, watch: Bool = false) -> TreatmentEntry {
            let entry = TreatmentEntry(date: date, value: units, treatmentType: .Insulin,
                nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: core.mainManagedObjectContext)
            if watch { entry.watchSourceUUID = UUID().uuidString }
            else { entry.localTreatmentUUID = UUID().uuidString }
            XCTAssertTrue(core.saveChangesSynchronously())
            return entry
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testOptInValidatesBothInputsAndNotifiesOnceAtExactThresholdAcrossLaunches() async throws {
        let f = Fixture()
        defer { f.clean() }
        let monitor = f.monitor()
        XCTAssertFalse(monitor.isEnabled)
        monitor.setEnabled(true)
        XCTAssertFalse(monitor.isEnabled)
        for invalid in [0.0, -1, .infinity, .nan, 301] {
            XCTAssertFalse(monitor.start(remaining: 10, threshold: invalid))
        }
        XCTAssertFalse(monitor.start(remaining: 301, threshold: 10))
        XCTAssertFalse(monitor.isEnabled)
        XCTAssertTrue(f.delivery.requests.isEmpty)

        XCTAssertTrue(monitor.start(remaining: 10, threshold: 10))
        await monitor.refresh()?.value
        let request = try XCTUnwrap(f.delivery.requests.first)
        XCTAssertEqual(request.content.title, "Husk en ekstra ampul")
        XCTAssertEqual(request.content.body, "Kontrollér pennen, og tag en ekstra ampul med.")
        XCTAssertEqual(request.content.categoryIdentifier, PenCartridgeMonitor.categoryID)
        XCTAssertNil(request.trigger)
        XCTAssertEqual(Set(request.content.userInfo.keys.compactMap { $0 as? String }), ["baseline"])
        XCTAssertEqual(PenCartridgeMonitor.category.actions.first?.title, "Mind mig senere (1 time)")
        XCTAssertEqual(PenCartridgeMonitor.category.actions.first?.identifier, PenCartridgeMonitor.laterActionID)
        let resumed = f.monitor()
        await resumed.refresh()?.value
        XCTAssertTrue(resumed.isLow)
        XCTAssertEqual(f.delivery.requests.count, 1)
    }

    func testSavedWatchDoseTriggersAtThresholdAndSubsequentDoseDoesNotRepeat() async throws {
        let f = Fixture()
        defer { f.clean() }
        let monitor = f.monitor()
        XCTAssertTrue(monitor.start(remaining: 15, threshold: 10))
        await monitor.refresh()?.value
        f.now.addTimeInterval(60)

        let watch = TreatmentEntry(date: f.now, value: 3, treatmentType: .Insulin,
            nightscoutEventType: nil, enteredBy: "Watch", nsManagedObjectContext: f.core.mainManagedObjectContext)
        watch.watchSourceUUID = UUID().uuidString
        try f.core.mainManagedObjectContext.save()
        await monitor.refresh()?.value
        XCTAssertEqual(monitor.snapshot.remainingUnits, 15)
        XCTAssertTrue(f.delivery.requests.isEmpty)

        let parent = f.core.privateManagedObjectContext
        try parent.performAndWait { try parent.save() }
        await waitFor { f.delivery.requests.count == 1 }
        XCTAssertEqual(monitor.snapshot.remainingUnits, 10)
        let local = TreatmentEntry(date: f.now, value: 2, treatmentType: .Insulin,
            nightscoutEventType: nil, enteredBy: "iPhone", nsManagedObjectContext: f.core.mainManagedObjectContext)
        local.localTreatmentUUID = UUID().uuidString
        XCTAssertTrue(f.core.saveChangesSynchronously())
        await waitFor { monitor.snapshot.remainingUnits == 6 }
        XCTAssertEqual(f.delivery.requests.count, 1)
    }

    func testColdSnoozeUsesOriginalTapTimeAndDuplicateResponsesDoNotReplaceDeadline() async throws {
        let f = Fixture()
        defer { f.clean() }
        var previous: PenCartridgeMonitor? = f.monitor()
        XCTAssertTrue(previous!.start(remaining: 0, threshold: 10))
        await previous!.refresh()?.value
        let initial = try XCTUnwrap(f.delivery.requests.first)
        previous = nil

        let cold = f.monitor(configured: false)
        var completions = 0
        XCTAssertTrue(cold.handleResponse(request: initial, action: PenCartridgeMonitor.laterActionID) { completions += 1 })
        XCTAssertEqual(completions, 0)
        f.now.addTimeInterval(300)
        XCTAssertTrue(cold.handleResponse(request: initial, action: PenCartridgeMonitor.laterActionID) { completions += 1 })
        cold.configure(coreDataManager: f.core)
        await cold.refresh()?.value
        XCTAssertEqual(completions, 2)
        let snooze = try XCTUnwrap(f.delivery.requests.last)
        let trigger = try XCTUnwrap(snooze.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertFalse(trigger.repeats)
        XCTAssertEqual(trigger.timeInterval, 3300, accuracy: 0.01)
        XCTAssertEqual(cold.snoozedUntil, f.now.addingTimeInterval(3300))
        XCTAssertFalse(cold.canRemindLater)
        cold.remindLater()
        let restarted = f.monitor()
        await restarted.refresh()?.value
        XCTAssertEqual(f.delivery.requests.count, 2)
        XCTAssertEqual(restarted.snoozedUntil, cold.snoozedUntil)
    }

    func testCorrectionRevokesSnoozeAndTapsButOnlyReplacementRearmsAutomaticAlert() async throws {
        let f = Fixture()
        defer { f.clean() }
        let monitor = f.monitor()
        XCTAssertTrue(monitor.start(remaining: 7, threshold: 7))
        await monitor.refresh()?.value
        let initial = try XCTUnwrap(f.delivery.requests.first)
        monitor.remindLater()
        await monitor.refresh()?.value
        let snooze = try XCTUnwrap(f.delivery.requests.last)
        let id = try XCTUnwrap(monitor.snapshot.cartridgeID)
        XCTAssertTrue(monitor.setRemaining(5))
        await monitor.refresh()?.value
        XCTAssertEqual(monitor.snapshot.cartridgeID, id)
        XCTAssertNil(monitor.snoozedUntil)
        XCTAssertTrue(f.delivery.removed.contains(initial.identifier))
        XCTAssertTrue(f.delivery.removed.contains(snooze.identifier))
        XCTAssertTrue(monitor.handleResponse(request: snooze, action: UNNotificationDefaultActionIdentifier) {})
        XCTAssertNil(monitor.pendingOpenID)
        XCTAssertEqual(f.delivery.requests.count, 2)
        XCTAssertTrue(monitor.newCartridge())
        XCTAssertNotEqual(monitor.snapshot.cartridgeID, id)
        monitor.setThreshold(300)
        await monitor.refresh()?.value
        XCTAssertEqual(f.delivery.requests.count, 3)
        XCTAssertNotEqual(f.delivery.requests.last?.identifier, initial.identifier)
    }

    func testDefaultTapWaitsForVerifiedBalanceAndActualPresentationAcknowledgment() async throws {
        let f = Fixture()
        defer { f.clean() }
        let warm = f.monitor()
        XCTAssertTrue(warm.start(remaining: 1, threshold: 10))
        await warm.refresh()?.value
        let id = try XCTUnwrap(warm.snapshot.baselineID)
        let initial = try XCTUnwrap(f.delivery.requests.first)
        let cold = f.monitor(configured: false)
        XCTAssertTrue(cold.handleResponse(request: initial, action: UNNotificationDefaultActionIdentifier) {})
        XCTAssertNil(cold.pendingOpenID)
        cold.configure(coreDataManager: f.core)
        await cold.refresh()?.value
        XCTAssertEqual(cold.pendingOpenID, id)
        cold.acknowledgeOpen(id: UUID())
        XCTAssertEqual(cold.pendingOpenID, id)
        cold.acknowledgeOpen(id: id)
        XCTAssertNil(cold.pendingOpenID)
        XCTAssertTrue(cold.handleResponse(request: initial, action: UNNotificationDefaultActionIdentifier) {})
        await cold.refresh()?.value
        XCTAssertNil(cold.pendingOpenID)
        XCTAssertFalse(cold.handleResponse(request: UNNotificationRequest(identifier: "unrelated",
            content: UNMutableNotificationContent(), trigger: nil), action: UNNotificationDefaultActionIdentifier) {})
    }

    func testEditsAboveThresholdCancelQueuedSnoozeAndDisableCancelsOnlyOwnedIdentifiers() async throws {
        let f = Fixture()
        defer { f.clean() }
        let monitor = f.monitor()
        XCTAssertTrue(monitor.start(remaining: 11, threshold: 10))
        f.now.addTimeInterval(1)
        let entry = TreatmentEntry(date: f.now, value: 2, treatmentType: .Insulin, nightscoutEventType: nil,
                                   enteredBy: nil, nsManagedObjectContext: f.core.mainManagedObjectContext)
        entry.localTreatmentUUID = UUID().uuidString
        XCTAssertTrue(f.core.saveChangesSynchronously())
        await waitFor { f.delivery.requests.count == 1 }
        monitor.remindLater()
        await monitor.refresh()?.value
        let snooze = try XCTUnwrap(f.delivery.requests.last)
        entry.treatmentdeleted = true
        XCTAssertTrue(f.core.saveChangesSynchronously())
        await waitFor { monitor.snapshot.remainingUnits == 11 && monitor.snoozedUntil == nil }
        XCTAssertTrue(f.delivery.removed.contains(snooze.identifier))
        monitor.setThreshold(20)
        await monitor.refresh()?.value
        XCTAssertEqual(f.delivery.requests.count, 2)
        monitor.setEnabled(false)
        XCTAssertNil(monitor.threshold)
        XCTAssertFalse(monitor.isEnabled)
        XCTAssertNil(monitor.snapshot.remainingUnits)
        XCTAssertTrue(f.delivery.removed.allSatisfy { $0.hasPrefix(PenCartridgeMonitor.identifierPrefix) })
        XCTAssertTrue(monitor.start(remaining: 1, threshold: 5))
        await monitor.refresh()?.value
        XCTAssertEqual(f.delivery.requests.count, 3)
    }

    func testSubmissionFailureCanRetryAndStaleForegroundRequestIsSuppressed() async throws {
        let f = Fixture()
        defer { f.clean() }
        let monitor = f.monitor()
        f.delivery.failNext = true
        XCTAssertTrue(monitor.start(remaining: 7, threshold: 10))
        await monitor.refresh()?.value
        XCTAssertNotNil(monitor.issueMessage)
        XCTAssertTrue(f.delivery.requests.isEmpty)
        await monitor.refresh()?.value
        let initial = try XCTUnwrap(f.delivery.requests.first)
        let visible = await withCheckedContinuation { continuation in
            monitor.willPresent(initial) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(visible.contains(.banner))
        XCTAssertTrue(monitor.setRemaining(300))
        let stale = await withCheckedContinuation { continuation in
            monitor.willPresent(initial) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(stale.isEmpty)
        await monitor.refresh()?.value
    }

    func testInterruptedInitialAcknowledgmentRecognizesSystemRequestAfterRestart() async throws {
        let f = Fixture()
        defer { f.clean() }
        var monitor: PenCartridgeMonitor? = f.monitor()
        f.delivery.interruptAcknowledgment = true
        XCTAssertTrue(monitor!.start(remaining: 4, threshold: 5))
        await monitor!.refresh()?.value
        XCTAssertEqual(f.delivery.requests.count, 1)
        XCTAssertNotNil(monitor?.issueMessage)
        monitor = nil
        f.delivery.interruptAcknowledgment = false
        let restored = f.monitor()
        await restored.refresh()?.value
        XCTAssertEqual(f.delivery.requests.count, 1)
        XCTAssertNil(restored.issueMessage)
    }

    func testOverdueUnsubmittedSnoozeRecoversOnceWithoutResurrectingDeliveredReminder() async throws {
        let f = Fixture()
        defer { f.clean() }
        var monitor: PenCartridgeMonitor? = f.monitor()
        XCTAssertTrue(monitor!.start(remaining: 2, threshold: 5))
        await monitor!.refresh()?.value
        f.delivery.failNext = true
        monitor!.remindLater()
        await monitor!.refresh()?.value
        XCTAssertEqual(f.delivery.requests.count, 1)
        monitor = nil

        f.now.addTimeInterval(3900)
        var restored: PenCartridgeMonitor? = f.monitor()
        await restored!.refresh()?.value
        let recovered = try XCTUnwrap(f.delivery.requests.last)
        XCTAssertEqual(f.delivery.requests.count, 2)
        XCTAssertEqual((recovered.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval, 1)
        restored = nil
        // Simulate dismissing the delivered reminder from Notification Center.
        f.delivery.systemRequests[recovered.identifier] = nil
        let restarted = f.monitor()
        await restarted.refresh()?.value
        XCTAssertEqual(f.delivery.requests.count, 2)
    }

    func testMissingFutureSnoozeAtRestartKeepsDeadlineAndRequestIdentity() async throws {
        let f = Fixture()
        defer { f.clean() }
        var monitor: PenCartridgeMonitor? = f.monitor()
        XCTAssertTrue(monitor!.start(remaining: 2, threshold: 5))
        await monitor!.refresh()?.value
        monitor!.remindLater()
        await monitor!.refresh()?.value
        let original = try XCTUnwrap(f.delivery.requests.last)
        monitor = nil
        f.delivery.systemRequests[original.identifier] = nil
        f.now.addTimeInterval(500)
        let restored = f.monitor()
        await restored.refresh()?.value
        let repaired = try XCTUnwrap(f.delivery.requests.last)
        XCTAssertEqual(f.delivery.requests.count, 3)
        XCTAssertEqual(repaired.identifier, original.identifier)
        XCTAssertEqual(repaired.content.userInfo["snooze"] as? String, original.content.userInfo["snooze"] as? String)
        XCTAssertEqual((repaired.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval, 3100)
    }

    func testHomeSplitEntryPreservesOldBalanceAndRejectsStaleOrUnavailablePresentation() async throws {
        let f = Fixture()
        defer { f.clean() }
        f.now = Date().addingTimeInterval(-60)
        let monitor = f.monitor()
        XCTAssertTrue(monitor.start(remaining: 5, threshold: 1))
        await monitor.refresh()?.value
        let baseline = try XCTUnwrap(monitor.snapshot.baselineID)
        let cartridge = monitor.snapshot.cartridgeID
        var presentations = 0
        func open(expected: UUID? = nil, enabled: Bool = true, ready: Bool = true,
                  alreadyOpen: Bool = false) -> Bool {
            RootHomeCalculatorQuickActionPresentation.openCartridgeAllocation(
                expectedBaseline: expected, currentBaseline: monitor.snapshot.baselineID,
                isEnabled: enabled, isReady: ready, isAlreadyPresented: alreadyOpen) {
                    presentations += 1
                }
        }
        XCTAssertFalse(open())
        XCTAssertFalse(open(expected: UUID()))
        XCTAssertFalse(open(expected: baseline, enabled: false))
        XCTAssertFalse(open(expected: baseline, ready: false))
        XCTAssertFalse(open(expected: baseline, alreadyOpen: true))
        XCTAssertEqual(presentations, 0)
        XCTAssertTrue(open(expected: baseline))
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(monitor.snapshot.baselineID, baseline)
        XCTAssertEqual(monitor.snapshot.cartridgeID, cartridge)
        XCTAssertEqual(monitor.snapshot.remainingUnits, 5)
        XCTAssertNil(monitor.allocation)
        XCTAssertTrue(f.entries.isEmpty)
        let calculator = f.calculator(monitor)
        defer { calculator.stop() }
        XCTAssertNil(calculator.cartridgeAllocationRequest(), "An actual positive total is required")
        calculator.insulinToLogText = "6"
        let request = try XCTUnwrap(calculator.cartridgeAllocationRequest())
        XCTAssertEqual(request.baselineID, baseline)
        XCTAssertEqual(request.suggestedOldUnits, 3)
        XCTAssertEqual(request.totalUnits, 6)
        // Opening/cancelling either sheet does not confirm a switch or a treatment.
        calculator.stop()
        await monitor.refresh()?.value
        XCTAssertEqual(monitor.snapshot.baselineID, baseline)
        XCTAssertEqual(monitor.snapshot.remainingUnits, 5)
        XCTAssertTrue(f.entries.isEmpty)
        XCTAssertTrue(monitor.setRemaining(4))
        XCTAssertFalse(open(expected: baseline), "An old Home confirmation cannot replace a newer count")
    }

    func testCalculatorSplitPersistsBeforeLoggingAndLogsSixUnitsExactlyOnceAfterCancelledConfirmation() async throws {
        let f = Fixture()
        defer { f.clean() }
        f.now = Date().addingTimeInterval(-60)
        let monitor = f.monitor()
        XCTAssertTrue(monitor.start(remaining: 5, threshold: 1))
        await monitor.refresh()?.value
        let originalCartridge = monitor.snapshot.cartridgeID
        f.now.addTimeInterval(30)
        let calculator = f.calculator(monitor)
        defer { calculator.stop() }
        calculator.insulinToLogText = "6"
        let request = try XCTUnwrap(calculator.cartridgeAllocationRequest())
        XCTAssertEqual(request.suggestedOldUnits, 3, "The old cartridge must first cover its own priming")
        XCTAssertTrue(calculator.saveCartridgeAllocation(request, oldUnits: 3, startsNewCartridge: true))
        await monitor.refresh()?.value
        XCTAssertNotEqual(monitor.snapshot.cartridgeID, originalCartridge)
        XCTAssertNil(monitor.snapshot.remainingUnits, "The physical switch is durable but the dose is still unlogged")
        XCTAssertTrue(f.entries.isEmpty)
        XCTAssertTrue(calculator.requestLog())
        XCTAssertEqual(calculator.confirmationDraft?.operation.bolusUUID, request.bolusID)
        calculator.cancelLogConfirmation()
        XCTAssertTrue(f.entries.isEmpty)
        XCTAssertTrue(calculator.requestLog())
        XCTAssertEqual(calculator.confirmationDraft?.operation.bolusUUID, request.bolusID)
        let logged = await calculator.confirmLog()
        XCTAssertTrue(logged)
        let repeated = await calculator.confirmLog()
        XCTAssertFalse(repeated)
        f.now = Date().addingTimeInterval(1)
        await monitor.refresh()?.value
        XCTAssertEqual(f.entries.count, 1)
        XCTAssertEqual(f.entries.first?.value, 6)
        XCTAssertEqual(f.entries.first?.localTreatmentUUID, request.bolusID)
        XCTAssertEqual(monitor.snapshot.remainingUnits, 295)
        let reopened = f.monitor()
        await reopened.refresh()?.value
        XCTAssertEqual(reopened.snapshot.remainingUnits, 295)
        XCTAssertEqual(reopened.allocation?.oldUnits, 3)
    }

    func testCalculatorSplitKeepsOldPortionWhenTotalChangesAndCanCorrectItBeforeLogging() async throws {
        let f = Fixture()
        defer { f.clean() }
        f.now = Date().addingTimeInterval(-60)
        let monitor = f.monitor()
        XCTAssertTrue(monitor.start(remaining: 5, threshold: 1))
        await monitor.refresh()?.value
        let calculator = f.calculator(monitor)
        defer { calculator.stop() }
        calculator.insulinToLogText = "6"
        let request = try XCTUnwrap(calculator.cartridgeAllocationRequest())
        XCTAssertTrue(calculator.saveCartridgeAllocation(request, oldUnits: 3, startsNewCartridge: true))
        calculator.insulinToLogText = "2"
        XCTAssertFalse(calculator.canLog)
        calculator.insulinToLogText = "7"
        let correction = try XCTUnwrap(calculator.cartridgeAllocationRequest())
        XCTAssertFalse(correction.startsNewCartridge)
        XCTAssertEqual(correction.suggestedOldUnits, 3)
        XCTAssertEqual(correction.totalUnits, 7)
        XCTAssertTrue(calculator.saveCartridgeAllocation(correction, oldUnits: 2, startsNewCartridge: false))
        XCTAssertTrue(calculator.requestLog())
        let logged = await calculator.confirmLog()
        XCTAssertTrue(logged)
        f.now = Date().addingTimeInterval(1)
        await monitor.refresh()?.value
        XCTAssertEqual(f.entries.count, 1)
        XCTAssertEqual(f.entries.first?.value, 7)
        XCTAssertEqual(monitor.allocation?.oldUnits, 2)
        XCTAssertEqual(monitor.snapshot.remainingUnits, 293)
    }

    func testStaleCartridgeSheetCannotReplaceANewerPhysicalCount() async throws {
        let f = Fixture()
        defer { f.clean() }
        f.now = Date().addingTimeInterval(-60)
        let monitor = f.monitor()
        XCTAssertTrue(monitor.start(remaining: 5, threshold: 1))
        await monitor.refresh()?.value
        let calculator = f.calculator(monitor)
        defer { calculator.stop() }
        calculator.insulinToLogText = "6"
        let stale = try XCTUnwrap(calculator.cartridgeAllocationRequest())
        XCTAssertTrue(monitor.setRemaining(4))
        let correctedBaseline = monitor.snapshot.baselineID
        XCTAssertFalse(calculator.saveCartridgeAllocation(stale, oldUnits: 3, startsNewCartridge: true))
        await monitor.refresh()?.value
        XCTAssertEqual(monitor.snapshot.baselineID, correctedBaseline)
        XCTAssertEqual(monitor.snapshot.remainingUnits, 4)
        XCTAssertNil(monitor.allocation)
        XCTAssertTrue(f.entries.isEmpty)
    }

    func testNewPhysicalCountAfterSplitDoesNotBlockActualDoseOrSilentlyGuessTheStock() async throws {
        let f = Fixture()
        defer { f.clean() }
        f.now = Date().addingTimeInterval(-60)
        let monitor = f.monitor()
        XCTAssertTrue(monitor.start(remaining: 5, threshold: 1))
        await monitor.refresh()?.value
        let calculator = f.calculator(monitor)
        defer { calculator.stop() }
        calculator.insulinToLogText = "6"
        XCTAssertTrue(calculator.cartridgeNeedsReplacement)
        let request = try XCTUnwrap(calculator.cartridgeAllocationRequest())
        XCTAssertTrue(calculator.saveCartridgeAllocation(request, oldUnits: 3, startsNewCartridge: true))
        XCTAssertFalse(calculator.cartridgeNeedsReplacement)
        XCTAssertTrue(monitor.setRemaining(280))
        XCTAssertTrue(calculator.requestLog())
        let saved = await calculator.confirmLog()
        XCTAssertTrue(saved, "The actual injection must still be saved when its stock allocation is stale")
        f.now = Date().addingTimeInterval(1)
        await monitor.refresh()?.value
        XCTAssertEqual(f.entries.count, 1)
        XCTAssertEqual(f.entries.first?.value, 6)
        XCTAssertNil(monitor.snapshot.remainingUnits)
        XCTAssertTrue(calculator.postSaveReminderWarning?.contains("Kontrollér ampulresten") == true)
    }

    func testSavedLocalAndWatchDosesCanBindToAnAlreadyReplacedCartridgeAcrossTheTimestampBoundary() async throws {
        for doseBeforeSwitch in [true, false] {
            let f = Fixture()
            defer { f.clean() }
            f.now = Date().addingTimeInterval(-120)
            let monitor = f.monitor()
            XCTAssertTrue(monitor.start(remaining: 5, threshold: 1))
            f.now.addTimeInterval(60)
            XCTAssertTrue(monitor.newCartridge())
            let entry = f.dose(6, at: f.now.addingTimeInterval(doseBeforeSwitch ? -1 : 1), watch: doseBeforeSwitch)
            f.now.addTimeInterval(2)
            await monitor.refresh()?.value
            let currentCartridge = monitor.snapshot.cartridgeID
            let editor = f.editor(entry, monitor: monitor)
            let request = try XCTUnwrap(editor.cartridgeAllocationRequest())
            XCTAssertEqual(request.bolusID, doseBeforeSwitch ? entry.watchSourceUUID : entry.localTreatmentUUID)
            XCTAssertNil(request.suggestedOldUnits, "History alone does not reveal the actual split")
            XCTAssertFalse(request.startsNewCartridge)
            XCTAssertTrue(request.allowsCartridgeChoice)
            XCTAssertTrue(editor.saveCartridgeAllocation(request, oldUnits: 3, startsNewCartridge: false))
            await monitor.refresh()?.value
            XCTAssertEqual(monitor.snapshot.cartridgeID, currentCartridge)
            XCTAssertEqual(monitor.snapshot.remainingUnits, 295)
            XCTAssertEqual(f.entries.count, 1)
            XCTAssertEqual(entry.value, 6)
        }
    }

    func testSavedDoseCanEstablishThePhysicalSwitchAndEditsAndDeletionRemainExplicit() async throws {
        let f = Fixture()
        defer { f.clean() }
        f.now = Date().addingTimeInterval(-120)
        let monitor = f.monitor()
        XCTAssertTrue(monitor.start(remaining: 5, threshold: 1))
        let entry = f.dose(6, at: f.now.addingTimeInterval(1))
        f.now.addTimeInterval(30)
        let editor = f.editor(entry, monitor: monitor)
        let request = try XCTUnwrap(editor.cartridgeAllocationRequest())
        XCTAssertTrue(request.startsNewCartridge)
        XCTAssertFalse(request.allowsCartridgeChoice)
        XCTAssertTrue(editor.saveCartridgeAllocation(request, oldUnits: 3, startsNewCartridge: true))
        await monitor.refresh()?.value
        XCTAssertEqual(monitor.snapshot.remainingUnits, 295)
        entry.value = 7
        XCTAssertTrue(f.core.saveChangesSynchronously())
        await monitor.refresh()?.value
        XCTAssertNil(monitor.snapshot.remainingUnits, "An edited total must not silently move insulin between cartridges")
        let revisedEditor = f.editor(entry, monitor: monitor)
        let revised = try XCTUnwrap(revisedEditor.cartridgeAllocationRequest())
        XCTAssertTrue(revisedEditor.saveCartridgeAllocation(revised, oldUnits: 3, startsNewCartridge: false))
        await monitor.refresh()?.value
        XCTAssertEqual(monitor.snapshot.remainingUnits, 294)
        entry.treatmentdeleted = true
        XCTAssertTrue(f.core.saveChangesSynchronously())
        await monitor.refresh()?.value
        XCTAssertEqual(monitor.snapshot.remainingUnits, 300)
        XCTAssertFalse(revisedEditor.canAdjustCartridgeAllocation)
    }

    func testAbandonedCalculatorSplitSurvivesRestartAndCanBeLinkedToTheActualSavedDose() async throws {
        let f = Fixture()
        defer { f.clean() }
        f.now = Date().addingTimeInterval(-120)
        let monitor = f.monitor()
        XCTAssertTrue(monitor.start(remaining: 5, threshold: 1))
        let calculator = f.calculator(monitor)
        calculator.insulinToLogText = "6"
        let pending = try XCTUnwrap(calculator.cartridgeAllocationRequest())
        XCTAssertTrue(calculator.saveCartridgeAllocation(pending, oldUnits: 3, startsNewCartridge: true))
        calculator.stop()
        XCTAssertTrue(f.entries.isEmpty)
        let reopened = f.monitor()
        await reopened.refresh()?.value
        XCTAssertNil(reopened.snapshot.remainingUnits)
        XCTAssertEqual(reopened.allocation?.bolusID, pending.bolusID)
        let actual = f.dose(6, at: f.now, watch: true)
        let editor = f.editor(actual, monitor: reopened)
        let request = try XCTUnwrap(editor.cartridgeAllocationRequest())
        XCTAssertFalse(request.startsNewCartridge, "A pending split belongs to the cartridge that is already physically installed")
        XCTAssertTrue(editor.saveCartridgeAllocation(request, oldUnits: 3, startsNewCartridge: false))
        await reopened.refresh()?.value
        XCTAssertEqual(reopened.snapshot.remainingUnits, 295)
        XCTAssertEqual(reopened.allocation?.bolusID, actual.watchSourceUUID)
        XCTAssertEqual(f.entries.count, 1)
    }

    func testSplitPreventsAutomaticDoseChangesIncludingAfterExplicitSuggestionCopy() async throws {
        let f = Fixture()
        defer { f.clean() }
        f.now = Date().addingTimeInterval(-60)
        let monitor = f.monitor()
        XCTAssertTrue(monitor.start(remaining: 5, threshold: 1))
        let calculator = f.calculator(monitor, automatic: true)
        defer { calculator.stop() }
        calculator.carbohydratesText = "20"
        calculator.start()
        await calculator.calculate()
        calculator.insulinToLogText = "6"
        let request = try XCTUnwrap(calculator.cartridgeAllocationRequest())
        XCTAssertTrue(calculator.saveCartridgeAllocation(request, oldUnits: 1, startsNewCartridge: true))
        calculator.carbohydratesText = "60"
        await calculator.calculate()
        XCTAssertEqual(calculator.insulinToLogText, "6")
        XCTAssertFalse(calculator.usesAutomaticMealDose)
        let copied = try XCTUnwrap(calculator.suggestedUnits)
        calculator.copySuggestion()
        XCTAssertEqual(calculator.insulinToLogText, PenDoseDisplayFormatter.insulinInput(copied))
        XCTAssertFalse(calculator.usesAutomaticMealDose)
        calculator.carbohydratesText = "80"
        await calculator.calculate()
        XCTAssertEqual(calculator.insulinToLogText, PenDoseDisplayFormatter.insulinInput(copied))
        XCTAssertEqual(monitor.allocation?.oldUnits, 1)
        XCTAssertTrue(f.entries.isEmpty)
    }

    func testRetrospectiveNewCartridgeUsesSavedDoseTimeAndCountsLaterInjections() async throws {
        let f = Fixture()
        defer { f.clean() }
        f.now = Date().addingTimeInterval(-120)
        let monitor = f.monitor()
        XCTAssertTrue(monitor.start(remaining: 5, threshold: 1))
        f.now.addTimeInterval(10)
        let split = f.dose(6, at: f.now)
        f.now.addTimeInterval(10)
        f.dose(2, at: f.now)
        f.now.addTimeInterval(10)
        let editor = f.editor(split, monitor: monitor)
        let request = try XCTUnwrap(editor.cartridgeAllocationRequest())
        XCTAssertTrue(request.startsNewCartridge)
        XCTAssertEqual(request.committedTreatmentDate, split.date)
        XCTAssertTrue(editor.saveCartridgeAllocation(request, oldUnits: 3, startsNewCartridge: true))
        await monitor.refresh()?.value
        XCTAssertEqual(monitor.snapshot.remainingUnits, 291, "Both the split share and the later injection consume the new cartridge")
        let reopened = f.monitor()
        await reopened.refresh()?.value
        XCTAssertEqual(reopened.snapshot.remainingUnits, 291)
        XCTAssertEqual(f.entries.count, 2)
        XCTAssertEqual(split.value, 6)
    }

    func testRetrospectiveAllocationRejectsChangedCommittedTimeAmountOrDeletion() async throws {
        let f = Fixture()
        defer { f.clean() }
        f.now = Date().addingTimeInterval(-120)
        let monitor = f.monitor()
        XCTAssertTrue(monitor.start(remaining: 5, threshold: 1))
        f.now.addTimeInterval(10)
        let split = f.dose(6, at: f.now)
        f.now.addTimeInterval(10)
        let request = try XCTUnwrap(monitor.allocationRequest(bolusID: try XCTUnwrap(split.localTreatmentUUID),
            total: 6, penStep: 0.5, existingTreatment: true))
        let originalDate = split.date
        let baseline = monitor.snapshot.baselineID
        split.date = originalDate.addingTimeInterval(1)
        XCTAssertTrue(f.core.saveChangesSynchronously())
        XCTAssertFalse(monitor.saveAllocation(request, oldUnits: 3, startsNewCartridge: true))
        split.date = originalDate
        split.value = 7
        XCTAssertTrue(f.core.saveChangesSynchronously())
        XCTAssertFalse(monitor.saveAllocation(request, oldUnits: 3, startsNewCartridge: true))
        split.value = 6
        split.treatmentdeleted = true
        XCTAssertTrue(f.core.saveChangesSynchronously())
        XCTAssertFalse(monitor.saveAllocation(request, oldUnits: 3, startsNewCartridge: true))
        await monitor.refresh()?.value
        XCTAssertEqual(monitor.snapshot.baselineID, baseline)
        XCTAssertEqual(monitor.snapshot.remainingUnits, 5)
        XCTAssertNil(monitor.allocation)
    }

    func testRetrospectiveNewCartridgeCannotReplaceANewerPhysicalCount() async throws {
        let f = Fixture()
        defer { f.clean() }
        f.now = Date().addingTimeInterval(-120)
        let monitor = f.monitor()
        XCTAssertTrue(monitor.start(remaining: 5, threshold: 1))
        f.now.addTimeInterval(10)
        let split = f.dose(6, at: f.now)
        f.now.addTimeInterval(10)
        XCTAssertTrue(monitor.setRemaining(280))
        let baseline = monitor.snapshot.baselineID
        f.now.addTimeInterval(10)
        let editor = f.editor(split, monitor: monitor)
        let request = try XCTUnwrap(editor.cartridgeAllocationRequest())
        XCTAssertTrue(request.startsNewCartridge)
        XCTAssertFalse(editor.saveCartridgeAllocation(request, oldUnits: 3, startsNewCartridge: true))
        await monitor.refresh()?.value
        XCTAssertEqual(monitor.snapshot.baselineID, baseline)
        XCTAssertEqual(monitor.snapshot.remainingUnits, 280)
        XCTAssertNil(monitor.allocation)
        XCTAssertEqual(split.value, 6)
    }

    func testRetrospectiveAttachmentPreservesKnownSwitchTimeForOtherInjections() async throws {
        let f = Fixture()
        defer { f.clean() }
        f.now = Date().addingTimeInterval(-120)
        let monitor = f.monitor()
        XCTAssertTrue(monitor.start(remaining: 5, threshold: 1))
        f.now.addTimeInterval(10)
        let split = f.dose(6, at: f.now)
        f.now.addTimeInterval(5)
        f.dose(1, at: f.now) // The later known physical switch already accounts for this dose.
        f.now.addTimeInterval(5)
        XCTAssertTrue(monitor.newCartridge())
        let cartridge = monitor.snapshot.cartridgeID
        f.now.addTimeInterval(10)
        f.dose(2, at: f.now)
        f.now.addTimeInterval(10)
        let editor = f.editor(split, monitor: monitor)
        let request = try XCTUnwrap(editor.cartridgeAllocationRequest())
        XCTAssertFalse(request.startsNewCartridge)
        XCTAssertTrue(editor.saveCartridgeAllocation(request, oldUnits: 3, startsNewCartridge: false))
        await monitor.refresh()?.value
        XCTAssertEqual(monitor.snapshot.cartridgeID, cartridge)
        XCTAssertEqual(monitor.snapshot.remainingUnits, 291)
        XCTAssertEqual(f.entries.count, 3)
    }

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}
