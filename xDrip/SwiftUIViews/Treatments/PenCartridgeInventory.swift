import CoreData
import Foundation

struct PenCartridgeSnapshot: Equatable {
    let cartridgeID: UUID?
    let baselineID: UUID?
    /// A negative estimate calls for a manual correction and still qualifies as low.
    /// Nil means there is no usable estimate.
    let remainingUnits: Double?
    let isConfigured: Bool

    static let unconfigured = Self(cartridgeID: nil, baselineID: nil, remainingUnits: nil, isConfigured: false)
}

/// Inventory attribution for one actual dose split across a physical cartridge change.
/// The treatment retains its full dose. Only the new cartridge's share is debited here.
struct PenCartridgeAllocation: Codable, Equatable {
    let bolusID: String
    let oldUnits: Double
    let totalUnits: Double

    init(bolusID: String, oldUnits: Double, totalUnits: Double) {
        self.bolusID = UUID(uuidString: bolusID)?.uuidString ?? bolusID
        self.oldUnits = oldUnits
        self.totalUnits = totalUnits
    }

    var isValid: Bool {
        UUID(uuidString: bolusID) != nil && oldUnits.isFinite && totalUnits.isFinite &&
            totalUnits > 0 && totalUnits <= PenCartridgeInventory.capacity &&
            oldUnits >= 0 && oldUnits <= totalUnits
    }

    var normalizedBolusID: String? { UUID(uuidString: bolusID)?.uuidString }
}

/// Stores the user's last physical count; committed treatment history supplies all debits.
/// Priming is inventory consumption only. It never creates or modifies a treatment.
struct PenCartridgeInventory {
    static let capacity = 300.0
    private static let primingUnits: Decimal = 2
    private static let decimalLocale = Locale(identifier: "en_US_POSIX")
    static let didChange = Notification.Name("penCartridge.inventoryDidChange")
    // A failed write during history replacement must leave the estimate unknown.
    // The marker has no dose or balance and is excluded from settings backups.
    private static let invalidationKey = "penCartridge.historyInvalidated"
    private static let writeLock = NSLock()

    private struct Baseline: Codable {
        let cartridgeID: UUID
        var baselineID: UUID
        let date: Date
        let units: Double
        var historyIsIntact: Bool
        // Optional fields keep existing baselines readable. Only a known physical change
        // can receive an allocation; a later manual count already includes prior use.
        var isNewCartridge: Bool?
        var allocation: PenCartridgeAllocation?
        var allocationSourceBaselineID: UUID?

        var isValid: Bool {
            date.timeIntervalSinceReferenceDate.isFinite && (0...PenCartridgeInventory.capacity).contains(units) &&
                PenCartridgeInventory.decimalUnits(units) != nil &&
                (allocation.map { $0.isValid && isNewCartridge == true && units == PenCartridgeInventory.capacity } ?? true)
        }
    }

    private let defaults: UserDefaults
    let fileURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.init(defaults: .standard, fileURL: support.appendingPathComponent("PenCartridge/baseline.json"))
    }

    init(defaults: UserDefaults, fileURL: URL) {
        self.defaults = defaults
        self.fileURL = fileURL
    }

    private func read() throws -> Baseline? {
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        let value = try JSONDecoder().decode(Baseline.self, from: data)
        guard value.isValid else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }

    private func write(_ value: Baseline) throws {
        var folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
        ])
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try folder.setResourceValues(resources)
        let data = try JSONEncoder().encode(value)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    var cartridgeID: UUID? { (try? read())?.cartridgeID }
    var baselineID: UUID? { (try? read())?.baselineID }
    var allocation: PenCartridgeAllocation? { (try? read())?.allocation }
    var canAllocateCurrentCartridge: Bool {
        guard let baseline = try? read() else { return false }
        return baseline.isNewCartridge == true && baseline.units == Self.capacity &&
            baseline.historyIsIntact && !defaults.bool(forKey: Self.invalidationKey)
    }
    var isConfigured: Bool {
        do { return try read() != nil }
        catch { return true }
    }

    @discardableResult
    func newCartridge(at date: Date = .now) -> Bool {
        beginCartridge(remaining: Self.capacity, at: date)
    }

    @discardableResult
    func beginCartridge(remaining: Double, at date: Date = .now) -> Bool {
        setBaseline(remaining, at: date, startsNewCartridge: true)
    }

    @discardableResult
    func setRemaining(_ units: Double, at date: Date = .now) -> Bool {
        setBaseline(units, at: date, startsNewCartridge: false)
    }

    private func setBaseline(_ units: Double, at date: Date, startsNewCartridge: Bool) -> Bool {
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        let id = startsNewCartridge ? UUID() : cartridgeID ?? UUID()
        let updated = Baseline(cartridgeID: id, baselineID: UUID(), date: date, units: units,
                               historyIsIntact: true, isNewCartridge: startsNewCartridge)
        guard updated.isValid else { return false }
        do {
            try write(updated)
            defaults.removeObject(forKey: Self.invalidationKey)
            return true
        } catch { return false }
    }

    /// Called only after the user confirms the physical change. A repeated delivery
    /// retains the first switch time and cartridge identity.
    @discardableResult
    func newCartridge(allocation: PenCartridgeAllocation, expectedBaselineID: UUID,
                      at date: Date = .now) -> Bool {
        guard allocation.isValid, date.timeIntervalSinceReferenceDate.isFinite else { return false }
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        do {
            guard let prior = try read() else { return false }
            if prior.allocationSourceBaselineID == expectedBaselineID, prior.allocation == allocation,
               prior.historyIsIntact, !defaults.bool(forKey: Self.invalidationKey) {
                return true
            }
            guard prior.baselineID == expectedBaselineID, date >= prior.date,
                  prior.allocation?.normalizedBolusID != allocation.normalizedBolusID else { return false }
            let updated = Baseline(cartridgeID: UUID(), baselineID: UUID(), date: date,
                units: Self.capacity, historyIsIntact: true, isNewCartridge: true,
                allocation: allocation, allocationSourceBaselineID: expectedBaselineID)
            try write(updated)
            defaults.removeObject(forKey: Self.invalidationKey)
            return true
        } catch { return false }
    }

    /// The caller verifies the selected, committed treatment. This compare-and-swap
    /// also permits explicitly attaching an abandoned pending split to that treatment.
    @discardableResult
    func updateAllocation(_ allocation: PenCartridgeAllocation, expectedBaselineID: UUID) -> Bool {
        guard allocation.isValid else { return false }
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        do {
            guard var baseline = try read(), baseline.baselineID == expectedBaselineID,
                  baseline.isNewCartridge == true, baseline.units == Self.capacity,
                  baseline.historyIsIntact, !defaults.bool(forKey: Self.invalidationKey) else { return false }
            if baseline.allocation == allocation { return true }
            baseline.allocation = allocation
            baseline.baselineID = UUID()
            try write(baseline)
            return true
        } catch { return false }
    }

    /// The balance includes priming. Quantize the usable portion to the actual pen
    /// step so an estimate never assigns a fraction the pen cannot deliver.
    static func suggestedOldUnits(total: Double, remaining: Double?, penStep: Double) -> Double? {
        guard total.isFinite, total > 0, total <= capacity,
              let remaining, remaining.isFinite, (0...capacity).contains(remaining),
              penStep.isFinite, penStep > 0, penStep <= capacity,
              let totalDecimal = decimalUnits(total), let remainingDecimal = decimalUnits(remaining),
              let step = decimalUnits(penStep) else { return nil }
        let usable = min(totalDecimal, max(0, remainingDecimal - primingUnits))
        var steps = usable / step
        var roundedSteps = Decimal()
        NSDecimalRound(&roundedSteps, &steps, 0, .down)
        return Double(NSDecimalNumber(decimal: roundedSteps * step).stringValue)
    }

    /// A saved dose can outlive the cartridge selection made in its editor. Preserve
    /// that treatment, but require a physical count before publishing another estimate.
    func invalidateEstimate() {
        Self.writeLock.lock()
        defaults.set(true, forKey: Self.invalidationKey)
        if var baseline = try? read() {
            baseline.historyIsIntact = false
            baseline.baselineID = UUID()
            try? write(baseline)
        }
        Self.writeLock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: fileURL)
    }

    /// History replacement can remove a dose without leaving a deletion record. Mark the
    /// estimate unknown until the user checks the pen. A linked split can precede the count.
    func invalidateIfHistoryWasReplaced(through date: Date) {
        Self.writeLock.lock()
        do {
            guard var prior = try read(), prior.historyIsIntact,
                  date > prior.date || prior.allocation != nil else {
                Self.writeLock.unlock()
                return
            }
            prior.historyIsIntact = false
            prior.baselineID = UUID()
            try write(prior)
        } catch {
            defaults.set(true, forKey: Self.invalidationKey)
        }
        Self.writeLock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: fileURL)
    }

    func snapshot(coreDataManager: CoreDataManager, now: Date = .now) -> PenCartridgeSnapshot {
        let baseline: Baseline
        do {
            guard let stored = try read() else { return .unconfigured }
            baseline = stored
        } catch {
            return PenCartridgeSnapshot(cartridgeID: nil, baselineID: nil, remainingUnits: nil, isConfigured: true)
        }
        let cutover = TreatmentSourceCutover.current(defaults: defaults)
        let policy = defaults.dataFlowPolicy
        var remaining: Double?
        if baseline.historyIsIntact, !defaults.bool(forKey: Self.invalidationKey),
           now.timeIntervalSinceReferenceDate.isFinite, now >= baseline.date,
           // A new source boundary inside the count interval could omit earlier doses.
           cutover.map({ $0.cutoff <= baseline.date }) ?? true,
           policy.therapyDataSource == .none,
           TherapyMetricsManager.cutoverPolicyIsConsistent(policy, cutover: cutover, defaults: defaults),
           let coordinator = coreDataManager.privateManagedObjectContext.persistentStoreCoordinator,
           !coordinator.persistentStores.isEmpty {
            // A child save or an uncommitted edit must never debit the cartridge.
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            context.performAndWait {
                remaining = Self.remaining(from: baseline, through: now, in: context)
            }
        }
        return PenCartridgeSnapshot(cartridgeID: baseline.cartridgeID, baselineID: baseline.baselineID,
                                    remainingUnits: remaining, isConfigured: true)
    }

    // Use the decimal representation of each entered amount. Binary subtraction can turn
    // an exact zero negative or leave an exact threshold a fraction above its alert boundary.
    private static func decimalUnits(_ value: Double) -> Decimal? {
        guard value.isFinite else { return nil }
        return Decimal(string: String(value), locale: decimalLocale)
    }

    private static func remaining(from baseline: Baseline, through now: Date,
                                  in context: NSManagedObjectContext) -> Double? {
        let request: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
        // The manual count already includes everything at or before its timestamp.
        // A delayed Watch delivery uses the recorded injection time, never the receipt time.
        let interval = NSPredicate(format: "treatmentType == %d AND date > %@ AND date <= %@",
                                   TreatmentType.Insulin.rawValue, baseline.date as NSDate, now as NSDate)
        if let identity = baseline.allocation?.normalizedBolusID {
            let linked = NSPredicate(format: "localTreatmentUUID ==[c] %@ OR watchSourceUUID ==[c] %@", identity, identity)
            request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [interval, linked])
        } else {
            request.predicate = interval
        }
        guard let entries = try? context.fetch(request) else { return nil }

        var seen = [String: (date: Date, units: Double, deleted: Bool)]()
        var foundAllocatedDose = baseline.allocation == nil
        guard var remaining = decimalUnits(baseline.units) else { return nil }
        for entry in entries {
            // A Watch operation logged through the calculator has a local UUID; manual Watch
            // treatments use watchSourceUUID. Neither time/amount nor the upload ID identifies a dose.
            guard let identity = [entry.watchSourceUUID, entry.localTreatmentUUID].compactMap({ $0 })
                    .first(where: { !$0.isEmpty }) else { continue }
            let key = UUID(uuidString: identity)?.uuidString ?? identity
            let isAllocated = key == baseline.allocation?.normalizedBolusID
            guard entry.isAppLocalTreatment, entry.treatmentType == .Insulin,
                  entry.healthKitSourceBundleIdentifier == nil, entry.careLinkSourceIdentifier == nil,
                  entry.nightscoutEventType == nil else {
                if isAllocated { return nil }
                continue
            }
            if !isAllocated, entry.treatmentdeleted { continue }
            guard entry.date <= now, entry.date.timeIntervalSinceReferenceDate.isFinite,
                  entry.value.isFinite, entry.value >= 0 else { return nil }
            if let prior = seen[key] {
                guard prior.date == entry.date, prior.units == entry.value,
                      prior.deleted == entry.treatmentdeleted else { return nil }
                continue
            }
            seen[key] = (entry.date, entry.value, entry.treatmentdeleted)
            if isAllocated, let allocation = baseline.allocation {
                foundAllocatedDose = true
                if entry.treatmentdeleted { continue }
                guard entry.value == allocation.totalUnits,
                      let total = decimalUnits(entry.value),
                      let old = decimalUnits(allocation.oldUnits) else { return nil }
                let newUnits = total - old
                if newUnits > 0 { remaining -= newUnits + primingUnits }
            } else if entry.value > 0 {
                guard let units = decimalUnits(entry.value) else { return nil }
                remaining -= units + primingUnits
            }
        }
        // A confirmed physical change can precede Log or arrive before its treatment.
        // Until that exact ID is committed, do not show a deceptively full cartridge.
        guard foundAllocatedDose else { return nil }
        guard !remaining.isNaN else { return nil }
        return Double(NSDecimalNumber(decimal: remaining).stringValue)
    }
}
