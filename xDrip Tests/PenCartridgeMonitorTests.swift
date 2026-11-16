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

    private func waitFor(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}
