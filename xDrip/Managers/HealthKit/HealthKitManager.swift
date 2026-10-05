import Foundation
import CoreData
import HealthKit
import os
import UIKit

extension Notification.Name {
    static let healthKitPhoneAuthorizationDidChange = Notification.Name("HealthKitPhoneAuthorizationDidChange")
    static let healthKitExportStatusDidChange = Notification.Name("HealthKitExportStatusDidChange")
}

enum HealthKitExportKind: String, CaseIterable {
    case glucose, insulin, carbohydrates

    var quantityIdentifier: HKQuantityTypeIdentifier {
        switch self {
        case .glucose: .bloodGlucose
        case .insulin: .insulinDelivery
        case .carbohydrates: .dietaryCarbohydrates
        }
    }
}

/// All iPhone authorization prompts use the same nonempty read and write sets. A completed
/// request only means HealthKit processed the sheet; sharing status remains type-specific.
protocol HealthKitAuthorizationStoring: AnyObject {
    func requestAuthorization(toShare: Set<HKSampleType>?, read: Set<HKObjectType>?,
                              completion: @escaping @Sendable (Bool, Error?) -> Void)
    func getRequestStatusForAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>,
                                          completion: @escaping @Sendable (HKAuthorizationRequestStatus, Error?) -> Void)
    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus
}

extension HKHealthStore: HealthKitAuthorizationStoring {}

final class HealthKitPhoneAuthorizationCenter {
    static let shared = HealthKitPhoneAuthorizationCenter()

    private let store: HealthKitAuthorizationStoring
    private let isAvailable: () -> Bool
    private var inFlight = false
    private var callbacks: [(Bool, Error?) -> Void] = []

    init(store: HealthKitAuthorizationStoring = HKHealthStore(),
         isAvailable: @escaping () -> Bool = { HKHealthStore.isHealthDataAvailable() }) {
        self.store = store
        self.isAvailable = isAvailable
    }

    private var types: [HKQuantityType]? {
        guard isAvailable() else { return nil }
        let values = HealthKitExportKind.allCases.compactMap {
            HKObjectType.quantityType(forIdentifier: $0.quantityIdentifier)
        }
        return values.count == HealthKitExportKind.allCases.count ? values : nil
    }

    func sharingStatus(for kind: HealthKitExportKind) -> HKAuthorizationStatus? {
        guard let type = HKObjectType.quantityType(forIdentifier: kind.quantityIdentifier),
              isAvailable() else { return nil }
        return store.authorizationStatus(for: type)
    }

    func requestStatus(completion: @escaping (HKAuthorizationRequestStatus?, Error?) -> Void) {
        DispatchQueue.main.async {
            guard let types = self.types else {
                completion(nil, NSError(domain: "HealthKitAuthorization", code: 1)); return
            }
            self.store.getRequestStatusForAuthorization(toShare: Set(types.map { $0 as HKSampleType }),
                read: Set(types.map { $0 as HKObjectType })) { status, error in
                DispatchQueue.main.async { completion(status, error) }
            }
        }
    }

    func request(completion: @escaping (Bool, Error?) -> Void) {
        DispatchQueue.main.async {
            self.callbacks.append(completion)
            guard !self.inFlight else { return }
            guard let types = self.types else {
                self.complete(false, NSError(domain: "HealthKitAuthorization", code: 1)); return
            }
            self.inFlight = true
            self.store.requestAuthorization(toShare: Set(types.map { $0 as HKSampleType }),
                read: Set(types.map { $0 as HKObjectType })) { completed, error in
                DispatchQueue.main.async { self.complete(completed, error) }
            }
        }
    }

    private func complete(_ completed: Bool, _ error: Error?) {
        inFlight = false
        let waiting = callbacks
        callbacks.removeAll()
        NotificationCenter.default.post(name: .healthKitPhoneAuthorizationDidChange, object: nil)
        waiting.forEach { $0(completed, error) }
    }
}

struct HealthKitExportStatus {
    let lastConfirmedWrite: Date?
    let pendingWrites: Int?
    let pendingDeletes: Int?
    let lastErrorOperation: String?
    let lastErrorDomain: String?
    let lastErrorCode: Int?
}

/// Stores only technical receipts. Never persist a sample, dose, amount or HealthKit userInfo.
final class HealthKitExportStatusStore {
    static let shared = HealthKitExportStatusStore()
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func snapshot(_ kind: HealthKitExportKind) -> HealthKitExportStatus {
        let prefix = "healthKitExportStatus.\(kind.rawValue)."
        return HealthKitExportStatus(
            lastConfirmedWrite: defaults.object(forKey: prefix + "lastWrite") as? Date,
            pendingWrites: defaults.object(forKey: prefix + "pendingWrites") as? Int,
            pendingDeletes: defaults.object(forKey: prefix + "pendingDeletes") as? Int,
            lastErrorOperation: defaults.string(forKey: prefix + "errorOperation"),
            lastErrorDomain: defaults.string(forKey: prefix + "errorDomain"),
            lastErrorCode: defaults.object(forKey: prefix + "errorCode") as? Int)
    }

    func recordSuccess(kind: HealthKitExportKind, operation: String) {
        let prefix = "healthKitExportStatus.\(kind.rawValue)."
        if operation == "skrivning" { defaults.set(Date(), forKey: prefix + "lastWrite") }
        notify()
    }

    func recordFailure(kind: HealthKitExportKind, operation: String, error: Error?) {
        let nsError = (error ?? NSError(domain: "HealthKit", code: -1)) as NSError
        let prefix = "healthKitExportStatus.\(kind.rawValue)."
        defaults.set(operation, forKey: prefix + "errorOperation")
        defaults.set(nsError.domain, forKey: prefix + "errorDomain")
        defaults.set(nsError.code, forKey: prefix + "errorCode")
        notify()
    }

    func setPending(kind: HealthKitExportKind, writes: Int? = nil, deletes: Int? = nil) {
        let prefix = "healthKitExportStatus.\(kind.rawValue)."
        if let writes { defaults.set(writes, forKey: prefix + "pendingWrites") }
        if let deletes { defaults.set(deletes, forKey: prefix + "pendingDeletes") }
        notify()
    }

    func clearPending(kind: HealthKitExportKind) {
        let prefix = "healthKitExportStatus.\(kind.rawValue)."
        defaults.removeObject(forKey: prefix + "pendingWrites")
        defaults.removeObject(forKey: prefix + "pendingDeletes")
        notify()
    }

    func invalidatePendingWrites(kind: HealthKitExportKind) {
        let key = "healthKitExportStatus.\(kind.rawValue).pendingWrites"
        guard defaults.object(forKey: key) != nil else { return }
        defaults.removeObject(forKey: key)
        notify()
    }

    private func notify() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .healthKitExportStatusDidChange, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .healthKitExportStatusDidChange, object: nil)
            }
        }
    }
}

struct HealthKitExportReading: Codable, Equatable {
    let id: String
    let timeStamp: Date
    let value: Double
    let revision: Int64

    var metadata: [String: Any] {
        ["BgReadingId": id, HKMetadataKeySyncIdentifier: "xdrip.bg." + id,
         HKMetadataKeySyncVersion: NSNumber(value: revision)]
    }
}

/// Pending historical/recalculated values survive restart. Their sync revision is assigned
/// once, so retries update one HealthKit object rather than creating another object.
struct HealthKitReplacementQueue: Codable {
    private(set) var entries: [HealthKitExportReading] = []
    private(set) var lastRevision: Int64 = 1

    mutating func enqueue(id: String, timeStamp: Date, value: Double, now: Date) {
        prune(at: now)
        guard !id.isEmpty, value.isFinite, value > 0,
              now.timeIntervalSince(timeStamp) <= 7 * 24 * 3600,
              !entries.contains(where: { $0.id == id && $0.timeStamp == timeStamp && $0.value == value })
        else { return }
        lastRevision = max(lastRevision + 1, Int64(now.timeIntervalSince1970 * 1000))
        entries.removeAll { $0.id == id }
        entries.append(.init(id: id, timeStamp: timeStamp, value: value, revision: lastRevision))
        entries.sort { $0.timeStamp < $1.timeStamp }
        if entries.count > 10_080 { entries.removeFirst(entries.count - 10_080) }
    }

    mutating func confirm(_ reading: HealthKitExportReading) {
        entries.removeAll { $0 == reading }
    }

    mutating func remove(ids: Set<String>) {
        entries.removeAll { ids.contains($0.id) }
    }

    mutating func prune(at now: Date) {
        entries.removeAll { now.timeIntervalSince($0.timeStamp) > 7 * 24 * 3600 }
    }
}

/// The same callback sequence is used by HealthKit and deterministic error tests.
/// A failed lookup/delete never falls through to an unverified additional save.
enum HealthKitLegacyReplacement {
    static func perform<Sample>(
        isEnabled: @escaping () -> Bool = { true },
        query: (@escaping (Result<[Sample], Error>) -> Void) -> Void,
        remove: @escaping ([Sample], @escaping (Bool) -> Void) -> Void,
        save: @escaping () -> Void,
        failed: @escaping () -> Void
    ) {
        guard isEnabled() else { failed(); return }
        query { result in
            guard isEnabled() else { failed(); return }
            switch result {
            case .failure:
                failed()
            case let .success(samples):
                guard !samples.isEmpty else { save(); return }
                remove(samples) { success in
                    if success && isEnabled() { save() } else { failed() }
                }
            }
        }
    }
}

/// Pure state for the one-at-a-time HealthKit catch-up pipeline.
/// `HealthKitManager` owns this value exclusively on the main queue so Core Data,
/// UserDefaults and upload bookkeeping never need a synchronous cross-queue hop.
struct HealthKitUploadState: Equatable {
    enum Completion: Equatable {
        case ignored
        case stored(Date)
        case retry(Date)
    }

    private(set) var latestStoredTimeStamp: Date
    private(set) var inFlightTimeStamp: Date?
    private(set) var replacementTimeStampsInFlight = Set<Date>()
    private(set) var retryNotBefore: Date?

    init(latestStoredTimeStamp: Date = .distantPast) {
        self.latestStoredTimeStamp = latestStoredTimeStamp
    }

    mutating func synchronizeLatestStoredTimeStamp(_ timeStamp: Date) {
        latestStoredTimeStamp = max(latestStoredTimeStamp, timeStamp)
    }

    mutating func allowImmediateRetry() {
        retryNotBefore = nil
    }

    mutating func begin(timeStamp: Date, now: Date = Date()) -> Bool {
        guard inFlightTimeStamp == nil,
              !replacementTimeStampsInFlight.contains(timeStamp),
              timeStamp > latestStoredTimeStamp,
              retryNotBefore.map({ now >= $0 }) ?? true
        else { return false }

        inFlightTimeStamp = timeStamp
        return true
    }

    mutating func finish(
        timeStamp: Date,
        succeeded: Bool,
        now: Date = Date(),
        retryDelay: TimeInterval = 30
    ) -> Completion {
        guard inFlightTimeStamp == timeStamp else { return .ignored }
        inFlightTimeStamp = nil

        if succeeded {
            latestStoredTimeStamp = max(latestStoredTimeStamp, timeStamp)
            retryNotBefore = nil
            return .stored(latestStoredTimeStamp)
        }

        let retryDate = now.addingTimeInterval(retryDelay)
        retryNotBefore = retryDate
        return .retry(retryDate)
    }

    mutating func beginReplacement(timeStamp: Date) -> Bool {
        guard inFlightTimeStamp != timeStamp,
              !replacementTimeStampsInFlight.contains(timeStamp)
        else { return false }
        replacementTimeStampsInFlight.insert(timeStamp)
        return true
    }

    mutating func finishReplacement(timeStamp: Date) {
        replacementTimeStampsInFlight.remove(timeStamp)
    }

    func isInFlight(timeStamp: Date) -> Bool {
        inFlightTimeStamp == timeStamp || replacementTimeStampsInFlight.contains(timeStamp)
    }
}

enum HealthKitGlucoseBacklog {
    static func isEligible(_ timestamp: Date, after checkpoint: Date, frequent: Bool) -> Bool {
        timestamp.timeIntervalSince(checkpoint) >
            (frequent ? 50 : ConstantsHealthKit.minimiumTimeBetweenTwoReadingsInMinutes * 60)
    }

    static func oldestEligible<Row>(after checkpoint: Date, frequent: Bool, pageSize: Int,
                                    page: (Int) -> (rows: [Row], scannedCount: Int?),
                                    time: (Row) -> Date) -> Row? {
        var offset = 0
        while true {
            let batch = page(offset)
            guard let scanned = batch.scannedCount else { return nil }
            if let first = batch.rows.first(where: { isEligible(time($0), after: checkpoint, frequent: frequent) }) {
                return first
            }
            guard scanned == pageSize else { return nil }
            offset += scanned
        }
    }

    static func countEligible<Row>(after checkpoint: Date, frequent: Bool, pageSize: Int,
                                   page: (Int) -> (rows: [Row], scannedCount: Int?),
                                   time: (Row) -> Date) -> Int? {
        var offset = 0
        var lastEligible = checkpoint
        var count = 0
        while true {
            let batch = page(offset)
            guard let scanned = batch.scannedCount else { return nil }
            for row in batch.rows where isEligible(time(row), after: lastEligible, frequent: frequent) {
                count += 1
                lastEligible = time(row)
            }
            guard scanned == pageSize else { return count }
            offset += scanned
        }
    }
}

public class HealthKitManager: NSObject {
    static weak var active: HealthKitManager?
    // MARK: - public properties
    
    // MARK: - private properties
    
    /// to solve problem that sometemes UserDefaults key value changes is triggered twice for just one change
    private let keyValueObserverTimeKeeper: KeyValueObserverTimeKeeper = .init()
    
    /// for logging
    private var log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryHealthKitManager)
    
    /// reference to coredatamanager
    private var coreDataManager: CoreDataManager
    
    /// reference to BgReadingsAccessor
    private var bgReadingsAccessor: BgReadingsAccessor
    
    /// is healthkit fully initiazed or not, that includes checking if healthkit is available, created successfully bloodGlucoseType, user authorized - value will get changed
    private var healthKitInitialized = false
    
    /// bloodGlucoseType - optional because if hk not available it can be initialized
    private var bloodGlucoseType: HKQuantityType?
    
    /// reference to HKHealthStore, should be used only if we're sure HealthKit is supported on the device
    private lazy var healthStore = HKHealthStore()
    
    /// Main-queue-confined upload state. Serial uploads preserve a strict checkpoint: a newer
    /// success can never skip over an older failed reading, and a failure remains retryable.
    private var uploadState = HealthKitUploadState()

    private var healthKitRetryWorkItem: DispatchWorkItem?
    private var replacementRetryWorkItem: DispatchWorkItem?
    private var replacementInFlight = false
    private var replacementQueue = HealthKitReplacementQueue()
    private let replacementQueueKey = "healthKitPendingReplacements.v1"
    private let glucosePageSize = 256
    private var lastGlucoseStatusScan: Date?
    
    /// metadata key used to identify individual BG readings in HealthKit
    private let bgReadingIdMetadataKey = "BgReadingId"
    
    // MARK: - intialization
    
    init(coreDataManager: CoreDataManager) {
        // initialize non optional private properties
        self.coreDataManager = coreDataManager
        bgReadingsAccessor = BgReadingsAccessor(coreDataManager: coreDataManager)
        
        // call super.init
        super.init()
        Self.active = self

        if let data = UserDefaults.standard.data(forKey: replacementQueueKey),
           let stored = try? JSONDecoder().decode(HealthKitReplacementQueue.self, from: data) {
            replacementQueue = stored
        }

        uploadState.synchronizeLatestStoredTimeStamp(
            UserDefaults.standard.timeStampLatestHealthKitStoreBgReading ?? .distantPast
        )
        
        // listen for changes to userdefaults storeReadingsInHealthkitAuthorized
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.storeReadingsInHealthkitAuthorized.rawValue, options: .new, context: nil)
        // listen for changes to userdefaults storeReadingsInHealthkit
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.storeReadingsInHealthkit.rawValue, options: .new, context: nil)

        // call initializeHealthKit, set healthKitInitialized according to result of initialization
        healthKitInitialized = initializeHealthKit()

        NotificationCenter.default.addObserver(self, selector: #selector(resumeHealthKitExports), name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumeHealthKitExports), name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(resumeHealthKitExports), name: .healthKitPhoneAuthorizationDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(glucoseContextDidSave(_:)), name: .NSManagedObjectContextDidSave, object: nil)
        
        // do first store
        refreshGlucosePendingStatus(force: true)
        storeBgReadings()
    }
    
    // MARK: - private functions
    
    /// checks if healthkit available, creates bloodGlucoseType, and checks if user authorized storing readings in healtkit
    /// - returns:
    ///     - result which indicates if initialize was successful or not, autorization request is done from within Settings views, when user enables HealthKit
    ///
    /// the return value of the function does not depend on UserDefaults.standard.storeReadingsInHealthkit - this setting needs to be verified each time there's  an new reading to store
    ///
    /// if authorizationStatus is notDetermined or sharingDenied, then UserDefaults.standard.storeReadingsInHealthkitAuthorized is set to false by this function
    private func initializeHealthKit() -> Bool {
        // if healthkit not available (ipad) then no further processing
        if !HKHealthStore.isHealthDataAvailable() {
            return false
        }
        
        // initialize bloodGlucoseType
        bloodGlucoseType = HKObjectType.quantityType(forIdentifier: .bloodGlucose)
        
        // if bloodGlucseType not correctly initialized then result is false
        guard let bloodGlucoseType = bloodGlucoseType else { return false }
        
        // set value of UserDefaults storeReadingsInHealthkitAuthorized according to actual value in HealthKit Store
        // because user might have first authorized, then remove the authorization - if it's not authorized, then set storeReadingsInHealthkitAuthorized to false
        let authorizationStatus = healthStore.authorizationStatus(for: bloodGlucoseType)
        switch authorizationStatus {
        case .notDetermined, .sharingDenied:
            if UserDefaults.standard.storeReadingsInHealthkit {
                trace("HealthKit sharing is not authorized", log: log, category: ConstantsLog.categoryHealthKitManager, type: .info, troubleshooting: .detailed(.integration(name: .healthKit, activity: .permissionDenied)))
            }
            if UserDefaults.standard.storeReadingsInHealthkitAuthorized {
                UserDefaults.standard.storeReadingsInHealthkitAuthorized = false
            }
            return false
        case .sharingAuthorized:
            if !UserDefaults.standard.storeReadingsInHealthkitAuthorized {
                UserDefaults.standard.storeReadingsInHealthkitAuthorized = true
            }
        @unknown default:
            trace("unknown authorizationstatus for healthkit - HealthKitManager.swift", log: log, category: ConstantsLog.categoryHealthKitManager, type: .error, troubleshooting: .detailed(.integration(name: .healthKit, activity: .failed)))
            if UserDefaults.standard.storeReadingsInHealthkitAuthorized {
                UserDefaults.standard.storeReadingsInHealthkitAuthorized = false
            }
            return false
        }
        
        // all checks ok , return true
        return true
    }

    @objc private func resumeHealthKitExports() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.resumeHealthKitExports() }
            return
        }
        healthKitInitialized = initializeHealthKit()
        guard healthKitInitialized else { refreshGlucosePendingStatus(force: true); return }
        uploadState.allowImmediateRetry()
        healthKitRetryWorkItem?.cancel()
        healthKitRetryWorkItem = nil
        replacementRetryWorkItem?.cancel()
        replacementRetryWorkItem = nil
        refreshGlucosePendingStatus(force: true)
        storeBgReadings()
    }

    @objc private func glucoseContextDidSave(_ notification: Notification) {
        guard let context = notification.object as? NSManagedObjectContext,
              context === coreDataManager.mainManagedObjectContext ||
                context === coreDataManager.privateManagedObjectContext else { return }
        let changedKeys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey]
        guard changedKeys.contains(where: {
            (notification.userInfo?[$0] as? Set<NSManagedObject>)?.contains(where: { $0 is BgReading }) == true
        }) else { return }
        HealthKitExportStatusStore.shared.invalidatePendingWrites(kind: .glucose)
    }
    
    /// stores latest readings in healthkit, only if HK supported, authorized, enabled in settings
    @objc public func storeBgReadings() {
        // ensure this function runs on main thread because it accesses objects from the main managedObjectContext
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.storeBgReadings()
            }
            return
        }
        // A former denied status is not permanent. A foreground or authorization callback
        // rechecks the current per-type sharing status without displaying a dialog.
        healthKitInitialized = initializeHealthKit()
        if !UserDefaults.standard.storeReadingsInHealthkit || !healthKitInitialized ||
            !UIApplication.shared.isProtectedDataAvailable || uploadState.inFlightTimeStamp != nil {
            return
        }
        
        // bloodGlucoseType should not be nil
        guard let bloodGlucoseType = bloodGlucoseType else { return }

        drainHealthKitReplacements()
        
        let persistedLatestTimeStamp = UserDefaults.standard.timeStampLatestHealthKitStoreBgReading ?? .distantPast
        uploadState.synchronizeLatestStoredTimeStamp(persistedLatestTimeStamp)
        let strictLatestHealthKitStoredTimeStamp = uploadState.latestStoredTimeStamp
        
        let bloodGlucoseUnit = HKUnit(from: "mg/dL")
        // Scan bounded Core Data pages from the oldest row. Even a page containing only
        // invalid or cadence-filtered rows cannot hide a valid later reading.
        guard let bgReading = oldestEligibleGlucose(after: strictLatestHealthKitStoredTimeStamp) else { return }
        if HealthKitExportStatusStore.shared.snapshot(.glucose).pendingWrites == 0 {
            // A new reading arrived after a previously empty backlog was counted.
            refreshGlucosePendingStatus(force: true)
        }
        guard uploadState.begin(timeStamp: bgReading.timeStamp) else { return }

        saveBgReadingInHealthKit(
            bgReading: HealthKitExportReading(id: bgReading.id, timeStamp: bgReading.timeStamp, value: bgReading.finalValue, revision: 1),
            bloodGlucoseType: bloodGlucoseType,
            bloodGlucoseUnit: bloodGlucoseUnit,
            shouldUpdateLatestTimeStamp: true
        )
    }

    private func oldestEligibleGlucose(after checkpoint: Date) -> BgReadingSnapshot? {
        HealthKitGlucoseBacklog.oldestEligible(after: checkpoint,
            frequent: UserDefaults.standard.storeFrequentReadingsInHealthKit,
            pageSize: glucosePageSize,
            page: { offset in
                let result = bgReadingsAccessor.getOldestBgReadingSnapshotPage(
                    limit: glucosePageSize, fromDate: checkpoint, offset: offset)
                return (result.snapshots, result.scannedCount)
            }, time: { $0.timeStamp })
    }

    /// Full pending count is computed on entry/foreground, then maintained from confirmed
    /// callbacks. The throttle avoids re-reading the entire backlog after every sample.
    func refreshGlucosePendingStatus(force: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refreshGlucosePendingStatus(force: force) }
            return
        }
        guard force || lastGlucoseStatusScan.map({ Date().timeIntervalSince($0) > 60 }) ?? true
        else { return }
        guard UIApplication.shared.isProtectedDataAvailable else {
            HealthKitExportStatusStore.shared.clearPending(kind: .glucose)
            return
        }
        let checkpoint = UserDefaults.standard.timeStampLatestHealthKitStoreBgReading ?? .distantPast
        let count = HealthKitGlucoseBacklog.countEligible(after: checkpoint,
            frequent: UserDefaults.standard.storeFrequentReadingsInHealthKit,
            pageSize: glucosePageSize,
            page: { offset in
                let result = bgReadingsAccessor.getOldestBgReadingSnapshotPage(
                    limit: glucosePageSize, fromDate: checkpoint, offset: offset)
                return (result.snapshots, result.scannedCount)
            }, time: { $0.timeStamp })
        guard let count else {
            HealthKitExportStatusStore.shared.clearPending(kind: .glucose)
            return
        }
        lastGlucoseStatusScan = Date()
        HealthKitExportStatusStore.shared.setPending(kind: .glucose,
            writes: count + replacementQueue.entries.count)
    }
    
    /// Backfill respects destination cadence using surrounding stored readings, not just
    /// the small newly inserted subset. It never advances the ordinary live checkpoint.
    public func storeHistoricalBgReadingsInHealthKit(bgReadings: [BgReading]) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.storeHistoricalBgReadingsInHealthKit(bgReadings: bgReadings) }
            return
        }
        guard let oldest = bgReadings.map(\.timeStamp).min(), let newest = bgReadings.map(\.timeStamp).max() else { return }
        let cadence = UserDefaults.standard.storeFrequentReadingsInHealthKit ? 0 : ConstantsHealthKit.minimiumTimeBetweenTwoReadingsInMinutes
        let context = bgReadingsAccessor.getLatestBgReadings(
            limit: nil, fromDate: oldest.addingTimeInterval(-300), forSensor: nil,
            ignoreRawData: true, ignoreCalculatedValue: false
        ).filter { $0.timeStamp <= newest.addingTimeInterval(300) }
        let eligibleIDs = Set(context.filter(minimumTimeBetweenTwoReadingsInMinutes: cadence,
            lastConnectionStatusChangeTimeStamp: nil, timeStampLastProcessedBgReading: nil).map(\.id))
        replaceBgReadingsInHealthKit(bgReadings: bgReadings.filter { eligibleIDs.contains($0.id) })
    }

    public func replaceBgReadingsInHealthKit(bgReadings: [BgReading]) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.replaceBgReadingsInHealthKit(bgReadings: bgReadings)
            }
            return
        }

        let bgReadingSnapshots = bgReadings.map {
            BgReadingSnapshot(timeStamp: $0.timeStamp, calculatedValue: $0.calculatedValue, rawData: $0.rawData, ageAdjustedRawValue: $0.ageAdjustedRawValue, finalValue: $0.finalValue, adjustedValue: $0.adjustedValue?.doubleValue, smoothedValue: $0.smoothedValue?.doubleValue, backfilledAt: $0.backfilledAt, calculatedValueSlope: $0.calculatedValueSlope, hideSlope: $0.hideSlope, id: $0.id, deviceName: $0.deviceName, calibrationSnapshot: $0.calibration.map { CalibrationSnapshot(id: $0.id, timeStamp: $0.timeStamp, slope: $0.slope, intercept: $0.intercept, bg: $0.bg, rawValue: $0.rawValue) }, sensorID: $0.sensor?.id, objectID: $0.objectID)
        }
        
        replaceBgReadingsInHealthKit(bgReadings: bgReadingSnapshots)
    }
    
    public func replaceBgReadingsInHealthKit(bgReadings: [BgReadingSnapshot]) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.replaceBgReadingsInHealthKit(bgReadings: bgReadings)
            }
            return
        }
        
        if !UserDefaults.standard.storeReadingsInHealthkit {
            return
        }
        
        for bgReading in bgReadings where bgReading.isValidForDownstream {
            replacementQueue.enqueue(id: bgReading.id, timeStamp: bgReading.timeStamp, value: bgReading.finalValue, now: Date())
        }
        persistHealthKitReplacements()
        drainHealthKitReplacements()
    }

    private func persistHealthKitReplacements() {
        if let data = try? JSONEncoder().encode(replacementQueue) {
            UserDefaults.standard.set(data, forKey: replacementQueueKey)
        }
    }

    private func drainHealthKitReplacements() {
        replacementQueue.prune(at: Date())
        persistHealthKitReplacements()
        // HealthKit accepts some writes while locked but cannot query legacy samples safely.
        guard UserDefaults.standard.storeReadingsInHealthkit, healthKitInitialized,
              UIApplication.shared.isProtectedDataAvailable,
              !replacementInFlight, replacementRetryWorkItem == nil,
              let bloodGlucoseType
        else { return }

        while let pending = replacementQueue.entries.first {
            // Upstream refreshes pending corrections from Core Data after restart. Keep our
            // durable revisions, but do not replay deleted, suppressed or superseded values.
            let request = BgReading.fetchRequest()
            request.predicate = NSPredicate(format: "id == %@ AND calculatedValue > 0 AND isSuppressedByFiveMinuteCadence == NO", pending.id)
            request.fetchLimit = 1
            do {
                guard let current = try coreDataManager.mainManagedObjectContext.fetch(request).first,
                      current.isValidForDownstream else {
                    replacementQueue.remove(ids: [pending.id])
                    persistHealthKitReplacements()
                    continue
                }
                replacementQueue.enqueue(id: current.id, timeStamp: current.timeStamp, value: current.finalValue, now: Date())
                persistHealthKitReplacements()
            } catch {
                trace("failed fetch pending healthkit BG reading, error = %{public}@", log: log, category: ConstantsLog.categoryHealthKitManager, type: .error, error.localizedDescription)
                return
            }
            guard let reading = replacementQueue.entries.first(where: { $0.id == pending.id }),
                  uploadState.beginReplacement(timeStamp: reading.timeStamp)
            else { return }
            replacementInFlight = true
            deleteExistingBgReadingsFromHealthKit(bgReading: reading, bloodGlucoseType: bloodGlucoseType, bloodGlucoseUnit: HKUnit(from: "mg/dL"))
            return
        }
    }

    private func finishHealthKitReplacement(_ reading: HealthKitExportReading, succeeded: Bool) {
        uploadState.finishReplacement(timeStamp: reading.timeStamp)
        replacementInFlight = false
        if succeeded {
            let previousCount = replacementQueue.entries.count
            replacementQueue.confirm(reading)
            persistHealthKitReplacements()
            HealthKitExportStatusStore.shared.recordSuccess(kind: .glucose, operation: "skrivning")
            if replacementQueue.entries.count < previousCount,
               let pending = HealthKitExportStatusStore.shared.snapshot(.glucose).pendingWrites {
                HealthKitExportStatusStore.shared.setPending(kind: .glucose, writes: max(0, pending - 1))
            }
            drainHealthKitReplacements()
            storeBgReadings()
        } else {
            replacementRetryWorkItem?.cancel()
            let retry = DispatchWorkItem { [weak self] in
                self?.replacementRetryWorkItem = nil
                self?.drainHealthKitReplacements()
            }
            replacementRetryWorkItem = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: retry)
        }
    }

    /// Removes readings hidden by an explicit five-minute cadence rebuild without
    /// touching the samples that remain visible and will be updated separately.
    public func deleteBgReadingsFromHealthKit(bgReadingIDs: [String]) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.deleteBgReadingsFromHealthKit(bgReadingIDs: bgReadingIDs)
            }
            return
        }

        healthKitInitialized = initializeHealthKit()
        guard UserDefaults.standard.storeReadingsInHealthkit,
              healthKitInitialized,
              let bloodGlucoseType = bloodGlucoseType,
              bgReadingIDs.count > 0
        else { return }

        let suppressedIDs = Set(bgReadingIDs)
        replacementQueue.remove(ids: suppressedIDs)
        persistHealthKitReplacements()

        let metadataPredicate = HKQuery.predicateForObjects(withMetadataKey: bgReadingIdMetadataKey, allowedValues: bgReadingIDs)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [metadataPredicate, HKQuery.predicateForObjects(from: HKSource.default())])
        let sampleQuery = HKSampleQuery(sampleType: bloodGlucoseType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { [weak self] _, samples, error in
            guard let self = self else { return }

            if let error = error {
                trace("failed query suppressed healthkit BG readings, error = %{public}@", log: self.log, category: ConstantsLog.categoryHealthKitManager, type: .error, error.localizedDescription)
                return
            }

            guard let samples = samples, samples.count > 0 else { return }

            self.healthStore.delete(samples) { success, deleteError in
                if !success, let deleteError = deleteError {
                    trace("failed delete suppressed healthkit BG readings, error = %{public}@", log: self.log, category: ConstantsLog.categoryHealthKitManager, type: .error, deleteError.localizedDescription)
                }
            }
        }

        healthStore.execute(sampleQuery)
    }
    
    // MARK: - observe function
    
    /// when UserDefaults storeReadingsInHealthkitAuthorized or storeReadingsInHealthkit changes, then reinitialize the property healthKitInitialized
    override public func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            }
            return
        }

        if let keyPath = keyPath {
            if let keyPathEnum = UserDefaults.Key(rawValue: keyPath) {
                switch keyPathEnum {
                case UserDefaults.Key.storeReadingsInHealthkitAuthorized, UserDefaults.Key.storeReadingsInHealthkit:
                    
                    // check latest change, to avoid there's an endless loop, because initializeHealthKit is actually setting value of storeReadingsInHealthkitAuthorized
                    if keyValueObserverTimeKeeper.verifyKey(forKey: keyPathEnum.rawValue, withMinimumDelayMilliSeconds: 100) {
                        // doesn't matter which if the two settings got changed, it's ok to call initialize
                        healthKitInitialized = initializeHealthKit()
                        
                        // doesn't matter which if the two settings got changed, it's ok to call initialize
                        storeBgReadings()
                    }

                default:
                    break
                }
            }
        }
    }
    
    deinit {
        healthKitRetryWorkItem?.cancel()
        replacementRetryWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.storeReadingsInHealthkitAuthorized.rawValue)
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.storeReadingsInHealthkit.rawValue)
    }
    
    private func deleteExistingBgReadingsFromHealthKit(bgReading: HealthKitExportReading, bloodGlucoseType: HKQuantityType, bloodGlucoseUnit: HKUnit) {
        HealthKitLegacyReplacement.perform(isEnabled: {
            UserDefaults.standard.storeReadingsInHealthkit &&
                self.healthStore.authorizationStatus(for: bloodGlucoseType) == .sharingAuthorized
        }, query: { completion in
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForObjects(withMetadataKey: self.bgReadingIdMetadataKey, allowedValues: [bgReading.id]),
                HKQuery.predicateForObjects(from: HKSource.default())
            ])
            let query = HKSampleQuery(sampleType: bloodGlucoseType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                DispatchQueue.main.async {
                    if let error {
                        completion(.failure(error))
                    } else if let samples {
                        // Sync-versioned objects update atomically. Only legacy objects need deletion.
                        completion(.success(samples.filter { $0.metadata?[HKMetadataKeySyncIdentifier] == nil }))
                    } else {
                        completion(.failure(NSError(domain: "HealthKitManager", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "HealthKit query returned no sample results"])))
                    }
                }
            }
            self.healthStore.execute(query)
        }, remove: { samples, completion in
            self.healthStore.delete(samples) { success, _ in
                DispatchQueue.main.async { completion(success) }
            }
        }, save: {
            self.saveBgReadingInHealthKit(bgReading: bgReading, bloodGlucoseType: bloodGlucoseType, bloodGlucoseUnit: bloodGlucoseUnit, shouldUpdateLatestTimeStamp: false)
        }, failed: {
            trace("HealthKit legacy replacement query/delete failed; value remains queued", log: self.log, category: ConstantsLog.categoryHealthKitManager, type: .error,
                  troubleshooting: .detailed(.integration(name: .healthKit, activity: .failed)))
            HealthKitExportStatusStore.shared.recordFailure(kind: .glucose, operation: "skrivning", error: nil)
            self.finishHealthKitReplacement(bgReading, succeeded: false)
        })
    }
    
    private func saveBgReadingInHealthKit(bgReading: HealthKitExportReading, bloodGlucoseType: HKQuantityType, bloodGlucoseUnit: HKUnit, shouldUpdateLatestTimeStamp: Bool) {
        // Keep HealthKit callback bookkeeping on main without synchronously blocking its queue.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.saveBgReadingInHealthKit(bgReading: bgReading, bloodGlucoseType: bloodGlucoseType, bloodGlucoseUnit: bloodGlucoseUnit, shouldUpdateLatestTimeStamp: shouldUpdateLatestTimeStamp)
            }
            return
        }
        if !shouldUpdateLatestTimeStamp, !replacementQueue.entries.contains(bgReading) {
            // A correction or explicit cadence deletion arrived during query/delete. Retire
            // only this operation; its newer revision, if any, stays queued for the next drain.
            uploadState.finishReplacement(timeStamp: bgReading.timeStamp)
            replacementInFlight = false
            drainHealthKitReplacements()
            return
        }
        // Callers validate the canonical BgReading before creating this immutable export value.
        let quantity = HKQuantity(unit: bloodGlucoseUnit, doubleValue: bgReading.value)
        let sample = HKQuantitySample(type: bloodGlucoseType, quantity: quantity, start: bgReading.timeStamp, end: bgReading.timeStamp, metadata: bgReading.metadata)
        let timeStampLastReadingToUpload = bgReading.timeStamp

        let completion: (Bool, Error?) -> Void = { [weak self]
            (success: Bool, error: Error?) in
            guard let self = self else { return }
            DispatchQueue.main.async { [self] in
                if !shouldUpdateLatestTimeStamp {
                    self.finishHealthKitReplacement(bgReading, succeeded: success)
                }
                if success {
                    trace("stored reading in HealthKit", log: self.log, category: ConstantsLog.categoryHealthKitManager, type: .debug, troubleshooting: .detailed(.integration(name: .healthKit, activity: .succeeded(itemCount: 1))))

                    if shouldUpdateLatestTimeStamp,
                       case let .stored(latestTimeStamp) = self.uploadState.finish(
                           timeStamp: timeStampLastReadingToUpload,
                           succeeded: true
                       ) {
                        let persisted = UserDefaults.standard.timeStampLatestHealthKitStoreBgReading ?? .distantPast
                        UserDefaults.standard.timeStampLatestHealthKitStoreBgReading = max(persisted, latestTimeStamp)
                        HealthKitExportStatusStore.shared.recordSuccess(kind: .glucose, operation: "skrivning")
                        if let pending = HealthKitExportStatusStore.shared.snapshot(.glucose).pendingWrites {
                            HealthKitExportStatusStore.shared.setPending(kind: .glucose, writes: max(0, pending - 1))
                        }
                        self.healthKitRetryWorkItem?.cancel()
                        self.healthKitRetryWorkItem = nil
                        self.storeBgReadings()
                    }
                    return
                }

                let nsError = (error ?? NSError(domain: "HealthKit", code: -1)) as NSError
                trace("failed store reading in healthkit, domain=%{public}@ code=%{public}ld", log: self.log, category: ConstantsLog.categoryHealthKitManager, type: .error, troubleshooting: .detailed(.integration(name: .healthKit, activity: .failed)), nsError.domain, nsError.code)
                HealthKitExportStatusStore.shared.recordFailure(kind: .glucose, operation: "skrivning", error: nsError)
                // New rows can arrive after the last Settings/foreground count. A failed
                // write leaves them pending, so recalculate the complete count now.
                self.refreshGlucosePendingStatus(force: true)

                guard shouldUpdateLatestTimeStamp,
                      case let .retry(retryDate) = self.uploadState.finish(
                          timeStamp: timeStampLastReadingToUpload,
                          succeeded: false
                      )
                else { return }

                self.healthKitRetryWorkItem?.cancel()
                let retry = DispatchWorkItem { [weak self] in
                    self?.healthKitRetryWorkItem = nil
                    self?.storeBgReadings()
                }
                self.healthKitRetryWorkItem = retry
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + max(0, retryDate.timeIntervalSinceNow),
                    execute: retry
                )
            }
        }
        guard UserDefaults.standard.storeReadingsInHealthkit,
              healthStore.authorizationStatus(for: bloodGlucoseType) == .sharingAuthorized else {
            completion(false, NSError(domain: "HealthKitAuthorization", code: 2))
            return
        }
        healthStore.save(sample, withCompletion: completion)
    }
}
