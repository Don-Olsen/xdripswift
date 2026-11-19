import Combine
import CoreData
import Foundation
import UserNotifications

@MainActor protocol PenCartridgeNotificationDelivery {
    func contains(identifier: String, snoozeID: UUID?) async -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func remove(_ identifiers: [String])
}

private struct SystemCartridgeNotifications: PenCartridgeNotificationDelivery {
    func contains(identifier: String, snoozeID: UUID?) async -> Bool {
        func matches(_ request: UNNotificationRequest) -> Bool {
            request.identifier == identifier && request.content.userInfo["snooze"] as? String == snoozeID?.uuidString
        }
        let center = UNUserNotificationCenter.current()
        if await center.pendingNotificationRequests().contains(where: matches) { return true }
        return await center.deliveredNotifications().contains { matches($0.request) }
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }

    func remove(_ identifiers: [String]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

struct PenCartridgeAllocationRequest: Identifiable {
    let id = UUID()
    let baselineID: UUID
    let bolusID: String
    let totalUnits: Double
    let suggestedOldUnits: Double?
    let startsNewCartridge: Bool
    let allowsCartridgeChoice: Bool
    let penStepUnits: Double
    // Nil for a live injection; a retrospective choice freezes the committed event time.
    var committedTreatmentDate: Date? = nil
}

@MainActor final class PenCartridgeMonitor: ObservableObject {
    static let shared = PenCartridgeMonitor()
    static let openRequested = Notification.Name("xdrip.penCartridge.openRequested")
    nonisolated static let identifierPrefix = "xdrip.penCartridge."
    nonisolated static let categoryID = identifierPrefix + "actions"
    nonisolated static let laterActionID = identifierPrefix + "later"
    static let snoozeInterval: TimeInterval = 60 * 60

    nonisolated static var category: UNNotificationCategory {
        let later = UNNotificationAction(identifier: laterActionID, title: "Mind mig senere (1 time)", options: [])
        return UNNotificationCategory(identifier: categoryID, actions: [later], intentIdentifiers: [], options: [])
    }

    /// The threshold exists only after the user saves it together with a physical count.
    private static let thresholdKey = "penCartridge.threshold.v1"
    private static let reminderKey = "penCartridge.reminder.v1"

    private struct Reminder: Codable, Equatable {
        let cartridgeID: UUID
        // Keep cartridgeID after a correction to prevent a second automatic alert.
        var baselineID: UUID?
        var initialActionAvailable = true
        var initialSubmitted = false
        var snoozeDue: Date?
        var snoozeSubmitted = false
        var snoozeID: UUID?
        var lastTapID: String?
        var wantsDetails = false
    }

    private let inventory: PenCartridgeInventory
    private let defaults: UserDefaults
    private let delivery: PenCartridgeNotificationDelivery
    private let clock: () -> Date
    private weak var coreDataManager: CoreDataManager?
    private var saveObserver: NSObjectProtocol?
    private var inventoryObserver: NSObjectProtocol?
    private var cutoverObserver: NSObjectProtocol?
    private var lastCutover: Data?
    private var verifyRestoredSnooze = true
    private var revision = 0
    private var refreshTask: Task<Void, Never>?
    private var responseCompletions: [() -> Void] = []
    private var wakeTask: Task<Void, Never>?
    @Published private var reminder: Reminder? {
        didSet {
            guard reminder != oldValue else { return }
            if let reminder {
                defaults.set(try? JSONEncoder().encode(reminder), forKey: Self.reminderKey)
            } else {
                defaults.removeObject(forKey: Self.reminderKey)
            }
        }
    }

    @Published private(set) var snapshot = PenCartridgeSnapshot.unconfigured
    @Published private(set) var threshold: Double?
    @Published private(set) var snoozedUntil: Date?
    @Published private(set) var issueMessage: String?
    @Published private(set) var pendingOpenID: UUID?
    var isEnabled: Bool { threshold != nil }
    var isLow: Bool {
        guard let threshold, let remaining = snapshot.remainingUnits else { return false }
        return remaining <= threshold
    }
    var canRemindLater: Bool {
        isLow && reminder?.baselineID == snapshot.baselineID && snoozedUntil == nil
    }

    init(defaults: UserDefaults = .standard,
         inventory: PenCartridgeInventory? = nil,
         delivery: PenCartridgeNotificationDelivery? = nil,
         clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.delivery = delivery ?? SystemCartridgeNotifications()
        self.inventory = inventory ?? PenCartridgeInventory()
        self.clock = clock
        if let stored = defaults.object(forKey: Self.thresholdKey) as? Double,
           Self.validThreshold(stored) {
            threshold = stored
        }
        if let data = defaults.data(forKey: Self.reminderKey) {
            reminder = try? JSONDecoder().decode(Reminder.self, from: data)
        }
    }

    deinit {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        if let inventoryObserver { NotificationCenter.default.removeObserver(inventoryObserver) }
        if let cutoverObserver { NotificationCenter.default.removeObserver(cutoverObserver) }
        wakeTask?.cancel()
    }

    func configure(coreDataManager: CoreDataManager) {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        if let inventoryObserver { NotificationCenter.default.removeObserver(inventoryObserver) }
        let baselineFile = inventory.fileURL
        inventoryObserver = NotificationCenter.default.addObserver(forName: PenCartridgeInventory.didChange,
            object: nil, queue: nil) { [weak self] note in
                guard note.object as? URL == baselineFile else { return }
                Task { @MainActor in self?.refresh() }
            }
        if let cutoverObserver { NotificationCenter.default.removeObserver(cutoverObserver) }
        lastCutover = defaults.data(forKey: TreatmentSourceCutover.defaultsKey)
        cutoverObserver = NotificationCenter.default.addObserver(forName: HealthKitTherapyImportManager.statusDidChange,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isEnabled else { return }
                    let current = self.defaults.data(forKey: TreatmentSourceCutover.defaultsKey)
                    guard current != self.lastCutover else { return }
                    self.lastCutover = current
                    self.refresh()
                }
            }
        self.coreDataManager = coreDataManager
        let coordinator = coreDataManager.privateManagedObjectContext.persistentStoreCoordinator
        // Also catches direct store contexts. Child saves have not yet committed to disk.
        saveObserver = NotificationCenter.default.addObserver(forName: NSManagedObjectContext.didSaveObjectIDsNotification,
                                                              object: nil, queue: nil) { [weak self] note in
            guard let context = note.object as? NSManagedObjectContext,
                  context.parent == nil, let coordinator, context.persistentStoreCoordinator === coordinator else { return }
            let includesTreatment = [NSInsertedObjectIDsKey, NSUpdatedObjectIDsKey, NSDeletedObjectIDsKey].contains { key in
                (note.userInfo?[key] as? Set<NSManagedObjectID>)?.contains { $0.entity.name == "TreatmentEntry" } == true
            }
            guard includesTreatment else { return }
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    private static func validThreshold(_ amount: Double) -> Bool {
        (1...PenCartridgeInventory.capacity).contains(amount)
    }

    @discardableResult
    func start(remaining units: Double, threshold: Double) -> Bool {
        guard !isEnabled, Self.validThreshold(threshold),
              inventory.beginCartridge(remaining: units, at: clock()) else { return false }
        defaults.set(threshold, forKey: Self.thresholdKey)
        self.threshold = threshold
        didSetBaseline(remaining: units)
        return true
    }

    func setEnabled(_ enabled: Bool) {
        // Activation requires the two explicit values in start(remaining:threshold:).
        guard !enabled, isEnabled else { return }
        defaults.removeObject(forKey: Self.thresholdKey)
        threshold = nil
        invalidateRequests()
        reminder = nil
        snapshot = .unconfigured
        issueMessage = nil
        refresh()
    }

    func setThreshold(_ units: Double) {
        guard isEnabled, Self.validThreshold(units), units != threshold else { return }
        defaults.set(units, forKey: Self.thresholdKey)
        threshold = units
        if !isLow { invalidateRequests() }
        refresh()
    }

    @discardableResult
    func setRemaining(_ units: Double) -> Bool {
        guard isEnabled, inventory.setRemaining(units, at: clock()) else { return false }
        didSetBaseline(remaining: units)
        return true
    }

    @discardableResult
    func newCartridge() -> Bool {
        guard isEnabled, inventory.newCartridge(at: clock()) else { return false }
        didSetBaseline(remaining: PenCartridgeInventory.capacity)
        return true
    }

    var allocation: PenCartridgeAllocation? { inventory.allocation }

    /// Read from the committed store. A child-context draft cannot establish stock use.
    static func storedDose(_ id: String, coreDataManager: CoreDataManager) throws -> Double? {
        try storedDoseDetails(id, coreDataManager: coreDataManager)?.units
    }

    private static func storedDoseDetails(_ id: String, coreDataManager: CoreDataManager) throws -> (units: Double, date: Date)? {
        guard UUID(uuidString: id) != nil,
              let coordinator = coreDataManager.privateManagedObjectContext.persistentStoreCoordinator,
              !coordinator.persistentStores.isEmpty else { throw CocoaError(.fileReadUnknown) }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return try context.performAndWait {
            let request: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
            request.predicate = NSPredicate(format: "localTreatmentUUID ==[c] %@ OR watchSourceUUID ==[c] %@", id, id)
            let entries = try context.fetch(request)
            guard !entries.isEmpty else { return nil }
            if entries.allSatisfy({ $0.treatmentdeleted }) { return nil }
            guard entries.allSatisfy({ !$0.treatmentdeleted }) else { throw CocoaError(.fileReadCorruptFile) }
            guard let first = entries.first,
                  entries.allSatisfy({ $0.treatmentType == .Insulin && $0.isAppLocalTreatment &&
                      $0.healthKitSourceBundleIdentifier == nil && $0.careLinkSourceIdentifier == nil &&
                      $0.nightscoutEventType == nil && $0.value == first.value && $0.date == first.date }),
                  first.value.isFinite, first.value > 0,
                  first.date.timeIntervalSinceReferenceDate.isFinite else { throw CocoaError(.fileReadCorruptFile) }
            return (first.value, first.date)
        }
    }

    func allocationRequest(bolusID: String, total: Double, penStep: Double,
                           existingTreatment: Bool) -> PenCartridgeAllocationRequest? {
        guard isEnabled, total.isFinite, total > 0, penStep.isFinite, penStep > 0,
              let coreDataManager, let baselineID = inventory.baselineID else { return nil }
        let committedDate: Date?
        if existingTreatment {
            do {
                guard let dose = try Self.storedDoseDetails(bolusID, coreDataManager: coreDataManager),
                      dose.units == total, dose.date <= clock() else { return nil }
                committedDate = dose.date
            } catch { return nil }
        } else { committedDate = nil }
        let current = inventory.allocation
        let matches = current?.normalizedBolusID == UUID(uuidString: bolusID)?.uuidString
        let fresh = inventory.snapshot(coreDataManager: coreDataManager, now: clock())
        let suggestion = matches ? current?.oldUnits : (existingTreatment ? nil :
            PenCartridgeInventory.suggestedOldUnits(total: total, remaining: fresh.remainingUnits, penStep: penStep))
        var canUseCurrent = inventory.canAllocateCurrentCartridge
        if let current, !matches {
            do {
                if canUseCurrent {
                    canUseCurrent = try Self.storedDose(current.bolusID, coreDataManager: coreDataManager) == nil
                }
            }
            catch { return nil }
        }
        return PenCartridgeAllocationRequest(baselineID: baselineID, bolusID: bolusID,
            totalUnits: total, suggestedOldUnits: suggestion,
            startsNewCartridge: !matches && !(existingTreatment && canUseCurrent),
            allowsCartridgeChoice: existingTreatment && canUseCurrent && !matches,
            penStepUnits: penStep, committedTreatmentDate: committedDate)
    }

    @discardableResult
    func saveAllocation(_ request: PenCartridgeAllocationRequest, oldUnits: Double,
                        startsNewCartridge: Bool) -> Bool {
        guard isEnabled, inventory.baselineID == request.baselineID,
              startsNewCartridge == request.startsNewCartridge || request.allowsCartridgeChoice,
              request.penStepUnits.isFinite, request.penStepUnits > 0 else { return false }
        if let committedDate = request.committedTreatmentDate {
            guard let coreDataManager else { return false }
            do {
                guard let dose = try Self.storedDoseDetails(request.bolusID, coreDataManager: coreDataManager),
                      dose.units == request.totalUnits, dose.date == committedDate,
                      dose.date <= clock() else { return false }
            } catch { return false }
        }
        let allocation = PenCartridgeAllocation(bolusID: request.bolusID,
            oldUnits: oldUnits, totalUnits: request.totalUnits)
        guard allocation.isValid,
              abs(oldUnits / request.penStepUnits - (oldUnits / request.penStepUnits).rounded()) < 0.000001 else { return false }
        // A completed split must never be reassigned to an unrelated treatment. A pending
        // split can be explicitly linked to the saved dose from its treatment editor.
        if !startsNewCartridge, let prior = inventory.allocation,
           prior.normalizedBolusID != allocation.normalizedBolusID {
            guard let coreDataManager else { return false }
            do { guard try Self.storedDose(prior.bolusID, coreDataManager: coreDataManager) == nil else { return false } }
            catch { return false }
        }
        // A retrospective switch belongs to the saved injection, so later doses still
        // debit the new cartridge. The inventory rejects dates before a newer physical count.
        let switchDate = request.committedTreatmentDate ?? clock()
        let saved = startsNewCartridge
            ? inventory.newCartridge(allocation: allocation, expectedBaselineID: request.baselineID, at: switchDate)
            : inventory.updateAllocation(allocation, expectedBaselineID: request.baselineID)
        guard saved else { return false }
        invalidateRequests()
        snapshot = PenCartridgeSnapshot(cartridgeID: inventory.cartridgeID, baselineID: inventory.baselineID,
                                        remainingUnits: nil, isConfigured: true)
        refresh()
        return true
    }

    func invalidateAllocationEstimate() {
        inventory.invalidateEstimate()
        snapshot = PenCartridgeSnapshot(cartridgeID: inventory.cartridgeID, baselineID: inventory.baselineID,
                                        remainingUnits: nil, isConfigured: true)
        refresh()
    }

    private func didSetBaseline(remaining: Double) {
        invalidateRequests()
        snapshot = PenCartridgeSnapshot(cartridgeID: inventory.cartridgeID, baselineID: inventory.baselineID,
                                        remainingUnits: remaining, isConfigured: true)
        issueMessage = nil
        refresh()
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        revision += 1
        guard isEnabled, coreDataManager != nil else {
            if !isEnabled {
                invalidateRequests()
                finishResponses()
            }
            return refreshTask
        }
        if let refreshTask { return refreshTask }
        refreshTask = Task { [weak self] in
            guard let self else { return }
            var checked: Int
            repeat {
                checked = self.revision
                if self.isEnabled, let coreDataManager = self.coreDataManager {
                    let inventory = self.inventory
                    let now = self.clock()
                    let latest = await Task.detached(priority: .utility) {
                        inventory.snapshot(coreDataManager: coreDataManager, now: now)
                    }.value
                    if checked == self.revision {
                        if self.snapshot != latest { self.snapshot = latest }
                        await self.reconcile()
                    }
                }
            } while checked != self.revision
            self.refreshTask = nil
            self.finishResponses()
        }
        return refreshTask
    }

    private func reconcile() async {
        guard let cartridgeID = snapshot.cartridgeID, let baselineID = snapshot.baselineID,
              snapshot.remainingUnits != nil else {
            invalidateRequests()
            issueMessage = inventory.allocation == nil ? "Ampulens restmængde kunne ikke beregnes." :
                "Kontrollér dosisfordelingen i Behandlinger. En manglende eller ændret registrering gør ampulresten usikker."
            return
        }
        issueMessage = nil
        guard isLow else { invalidateRequests(); return }

        if reminder?.cartridgeID != cartridgeID {
            invalidateRequests()
            reminder = Reminder(cartridgeID: cartridgeID, baselineID: baselineID)
        } else if reminder?.baselineID != baselineID {
            invalidateRequests()
            reminder?.baselineID = baselineID
        }

        if reminder?.initialSubmitted == false, reminder?.initialActionAvailable == true {
            do {
                guard try await ensureRequest(baselineID, snoozeID: nil, due: nil) else { return }
                reminder?.initialSubmitted = true
            } catch {
                issueMessage = "Påmindelsen kunne ikke sendes."
                return
            }
        }

        if let due = reminder?.snoozeDue, let token = reminder?.snoozeID,
           reminder?.snoozeSubmitted == false || (verifyRestoredSnooze && due > clock()) {
            do {
                guard try await ensureRequest(baselineID, snoozeID: token, due: due) else { return }
                reminder?.snoozeSubmitted = true
            } catch {
                reminder?.snoozeSubmitted = false
                issueMessage = "Udsættelsen kunne ikke planlægges."
            }
        }
        verifyRestoredSnooze = false
        publishSnooze()
        if reminder?.wantsDetails == true, pendingOpenID != baselineID {
            pendingOpenID = baselineID
            NotificationCenter.default.post(name: Self.openRequested, object: self)
        }
    }

    /// The durable intent precedes the iOS request. An interrupted submission checks
    /// both system queues before retrying the same identifier and the original deadline.
    private func ensureRequest(_ baseline: UUID, snoozeID: UUID?, due: Date?) async throws -> Bool {
        let id = Self.identifier(baseline, snooze: due != nil)
        let checked = revision
        let exists = await delivery.contains(identifier: id, snoozeID: snoozeID)
        guard revision == checked, reminder?.baselineID == baseline else { return false }
        if !exists {
            try await delivery.add(Self.request(baseline: baseline, delay: due?.timeIntervalSince(clock()), snoozeID: snoozeID))
        }
        guard reminder?.baselineID == baseline else {
            delivery.remove([id])
            return false
        }
        return true
    }

    private static func identifier(_ baseline: UUID, snooze: Bool) -> String {
        identifierPrefix + (snooze ? "later." : "low.") + baseline.uuidString
    }

    static func request(baseline: UUID, delay: TimeInterval?, snoozeID: UUID? = nil) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Husk en ekstra ampul"
        content.body = "Kontrollér pennen, og tag en ekstra ampul med."
        content.sound = .default
        if delay == nil { content.categoryIdentifier = categoryID }
        content.userInfo = ["baseline": baseline.uuidString]
        if let snoozeID { content.userInfo["snooze"] = snoozeID.uuidString }
        return UNNotificationRequest(identifier: identifier(baseline, snooze: delay != nil), content: content,
            trigger: delay.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false) })
    }

    private func invalidateRequests() {
        if let baseline = reminder?.baselineID {
            delivery.remove([Self.identifier(baseline, snooze: false), Self.identifier(baseline, snooze: true)])
            if var revoked = reminder {
                revoked.baselineID = nil
                revoked.initialActionAvailable = false
                revoked.snoozeDue = nil
                revoked.snoozeID = nil
                revoked.snoozeSubmitted = false
                revoked.wantsDetails = false
                reminder = revoked
            }
        }
        if pendingOpenID != nil { pendingOpenID = nil }
        if snoozedUntil != nil { snoozedUntil = nil }
        wakeTask?.cancel()
        wakeTask = nil
    }

    func remindLater() {
        guard canRemindLater, let baseline = snapshot.baselineID,
              baseline == reminder?.baselineID else { return }
        postpone()
        refresh()
    }

    private func postpone() {
        guard var updated = reminder else { return }
        if let due = updated.snoozeDue, due > clock() { return }
        updated.initialActionAvailable = false
        updated.snoozeDue = clock().addingTimeInterval(Self.snoozeInterval)
        updated.snoozeID = UUID()
        updated.snoozeSubmitted = false
        reminder = updated
    }

    private func publishSnooze() {
        let due = reminder?.snoozeDue.flatMap { $0 > clock() && reminder?.snoozeSubmitted == true ? $0 : nil }
        guard due != snoozedUntil else { return }
        snoozedUntil = due
        wakeTask?.cancel()
        if let due {
            let delay = max(0, due.timeIntervalSince(clock()))
            wakeTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(min(delay, Self.snoozeInterval) * 1_000_000_000))
                if !Task.isCancelled { self?.refresh() }
            }
        }
    }

    private func currentBaseline(for request: UNNotificationRequest) -> UUID? {
        guard isEnabled, let baseline = reminder?.baselineID, baseline == inventory.baselineID,
              request.content.userInfo["baseline"] as? String == baseline.uuidString else { return nil }
        if request.identifier == Self.identifier(baseline, snooze: false), reminder?.initialActionAvailable == true {
            return baseline
        }
        if request.identifier == Self.identifier(baseline, snooze: true),
           let snooze = reminder?.snoozeID, request.content.userInfo["snooze"] as? String == snooze.uuidString {
            return baseline
        }
        return nil
    }

    /// A delivery in the foreground is rechecked against the committed treatment store.
    func willPresent(_ request: UNNotificationRequest, completion: @escaping (UNNotificationPresentationOptions) -> Void) {
        guard let id = currentBaseline(for: request), let coreDataManager else { completion([]); return }
        let inventory = self.inventory
        let now = clock()
        Task {
            let latest = await Task.detached(priority: .utility) {
                inventory.snapshot(coreDataManager: coreDataManager, now: now)
            }.value
            guard latest.baselineID == id, let amount = latest.remainingUnits, let threshold,
                  amount <= threshold, currentBaseline(for: request) == id else { completion([]); return }
            completion([.banner, .list, .sound])
        }
    }

    func handleResponse(request: UNNotificationRequest, action: String, completion: @escaping () -> Void) -> Bool {
        guard request.identifier.hasPrefix(Self.identifierPrefix) else { return false }
        guard let baseline = currentBaseline(for: request) else { completion(); return true }
        // A response also proves that iOS accepted this request if the app stopped
        // between submission and recording the successful return.
        if request.identifier == Self.identifier(baseline, snooze: false) {
            reminder?.initialSubmitted = true
        } else {
            reminder?.snoozeSubmitted = true
        }
        if action == Self.laterActionID, request.identifier == Self.identifier(baseline, snooze: false) {
            postpone()
        } else if action == UNNotificationDefaultActionIdentifier {
            let tapID = request.content.userInfo["snooze"] as? String ?? request.identifier
            guard reminder?.lastTapID != tapID else { completion(); return true }
            if var updated = reminder {
                updated.lastTapID = tapID
                updated.wantsDetails = true
                reminder = updated
            }
        } else {
            completion()
            return true
        }
        // On cold launch the foreground tap or the background action may precede Core Data.
        // Keep iOS's completion until validation and any one-shot schedule have finished.
        responseCompletions.append(completion)
        refresh()
        return true
    }

    func acknowledgeOpen(id: UUID) {
        guard pendingOpenID == id, reminder?.baselineID == id else { return }
        reminder?.wantsDetails = false
        pendingOpenID = nil
    }

    private func finishResponses() {
        let completions = responseCompletions
        responseCompletions.removeAll()
        completions.forEach { $0() }
    }
}
