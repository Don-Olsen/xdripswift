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

        var isValid: Bool {
            date.timeIntervalSinceReferenceDate.isFinite && (0...PenCartridgeInventory.capacity).contains(units) &&
                PenCartridgeInventory.decimalUnits(units) != nil
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
        let updated = Baseline(cartridgeID: id, baselineID: UUID(), date: date, units: units, historyIsIntact: true)
        guard updated.isValid else { return false }
        do {
            try write(updated)
            defaults.removeObject(forKey: Self.invalidationKey)
            return true
        } catch { return false }
    }

    /// History replacement can remove a dose without leaving a deletion record. Mark the
    /// estimate unknown until the user checks the pen. Old history before the count is irrelevant.
    func invalidateIfHistoryWasReplaced(through date: Date) {
        Self.writeLock.lock()
        do {
            guard var prior = try read(), prior.historyIsIntact, date > prior.date else {
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
        request.predicate = NSPredicate(format: "treatmentType == %d AND date > %@ AND date <= %@",
                                        TreatmentType.Insulin.rawValue, baseline.date as NSDate, now as NSDate)
        guard let entries = try? context.fetch(request) else { return nil }

        var seen = [String: (date: Date, units: Double)]()
        guard var remaining = decimalUnits(baseline.units) else { return nil }
        for entry in entries {
            guard !entry.treatmentdeleted, entry.isAppLocalTreatment,
                  entry.healthKitSourceBundleIdentifier == nil, entry.careLinkSourceIdentifier == nil,
                  entry.nightscoutEventType == nil else { continue }
            // A Watch operation logged through the calculator has a local UUID; manual Watch
            // treatments use watchSourceUUID. Neither time/amount nor the upload ID identifies a dose.
            guard let identity = [entry.watchSourceUUID, entry.localTreatmentUUID].compactMap({ $0 })
                    .first(where: { !$0.isEmpty }) else { continue }
            guard entry.value.isFinite, entry.value >= 0 else { return nil }
            guard entry.value > 0 else { continue }

            let key = UUID(uuidString: identity)?.uuidString ?? identity
            if let prior = seen[key] {
                guard prior.date == entry.date, prior.units == entry.value else { return nil }
                continue
            }
            seen[key] = (entry.date, entry.value)
            guard let units = decimalUnits(entry.value) else { return nil }
            remaining -= units + primingUnits
        }
        guard !remaining.isNaN else { return nil }
        return Double(NSDecimalNumber(decimal: remaining).stringValue)
    }
}
