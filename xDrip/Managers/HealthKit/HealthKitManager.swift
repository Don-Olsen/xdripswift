import Foundation
import HealthKit
import os

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

public class HealthKitManager: NSObject {
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
    
    /// metadata key used to identify individual BG readings in HealthKit
    private let bgReadingIdMetadataKey = "BgReadingId"
    
    // MARK: - intialization
    
    init(coreDataManager: CoreDataManager) {
        // initialize non optional private properties
        self.coreDataManager = coreDataManager
        bgReadingsAccessor = BgReadingsAccessor(coreDataManager: coreDataManager)
        
        // call super.init
        super.init()

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
        
        // do first store
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
            UserDefaults.standard.storeReadingsInHealthkitAuthorized = false
            return false
        case .sharingAuthorized:
            break
        @unknown default:
            trace("unknown authorizationstatus for healthkit - HealthKitManager.swift", log: log, category: ConstantsLog.categoryHealthKitManager, type: .error, troubleshooting: .detailed(.integration(name: .healthKit, activity: .failed)))
            UserDefaults.standard.storeReadingsInHealthkitAuthorized = false
            return false
        }
        
        // all checks ok , return true
        return true
    }
    
    /// stores latest readings in healthkit, only if HK supported, authorized, enabled in settings
    public func storeBgReadings() {
        // ensure this function runs on main thread because it accesses objects from the main managedObjectContext
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.storeBgReadings()
            }
            return
        }
        // healthkit setting must be on, and healthkit must be initialized successfully
        if !UserDefaults.standard.storeReadingsInHealthkit || !healthKitInitialized {
            return
        }
        
        // bloodGlucoseType should not be nil
        guard let bloodGlucoseType = bloodGlucoseType else { return }

        drainHealthKitReplacements()
        
        let persistedLatestTimeStamp = UserDefaults.standard.timeStampLatestHealthKitStoreBgReading ?? .distantPast
        uploadState.synchronizeLatestStoredTimeStamp(persistedLatestTimeStamp)
        let strictLatestHealthKitStoredTimeStamp = uploadState.latestStoredTimeStamp
        
        // user setting to allow more frequent HealthKit writes (e.g. Libre 2 Direct 60-second cadence)
        let storeFrequentReadingsInHealthKit = UserDefaults.standard.storeFrequentReadingsInHealthKit
        
        // get readings to store, limit to 2016 = maximum 1 week - just to avoid a huge array is being returned here, applying minimumTimeBetweenTwoReadingsInMinutes filter
        let bgReadingsToStore = bgReadingsAccessor.getLatestBgReadingSnapshots(limit: 2016, fromDate: strictLatestHealthKitStoredTimeStamp, forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: false).filter(minimumTimeBetweenTwoReadingsInMinutes: storeFrequentReadingsInHealthKit ? 0 : ConstantsHealthKit.minimiumTimeBetweenTwoReadingsInMinutes, lastConnectionStatusChangeTimeStamp: nil, timeStampLastProcessedBgReading: strictLatestHealthKitStoredTimeStamp)
        
        let bgReadingsToStoreAfterApplyingStrictBoundary = bgReadingsToStore.filter {
            let isAfterStrictBoundary = $0.timeStamp > strictLatestHealthKitStoredTimeStamp
            let respectsFrequentWriteSpacing = !storeFrequentReadingsInHealthKit || ($0.timeStamp.timeIntervalSince(strictLatestHealthKitStoredTimeStamp) > 50)
            return isAfterStrictBoundary
                && respectsFrequentWriteSpacing
                && $0.isValidForDownstream
                && !uploadState.isInFlight(timeStamp: $0.timeStamp)
        }
        
        let bloodGlucoseUnit = HKUnit(from: "mg/dL")
        
        // The accessor returns newest first. Upload the oldest eligible reading and drain the
        // remaining catch-up set from each asynchronous completion.
        guard let bgReading = bgReadingsToStoreAfterApplyingStrictBoundary.last,
              uploadState.begin(timeStamp: bgReading.timeStamp)
        else { return }

        saveBgReadingInHealthKit(
            bgReading: HealthKitExportReading(id: bgReading.id, timeStamp: bgReading.timeStamp, value: bgReading.finalValue, revision: 1),
            bloodGlucoseType: bloodGlucoseType,
            bloodGlucoseUnit: bloodGlucoseUnit,
            shouldUpdateLatestTimeStamp: true
        )
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
        guard UserDefaults.standard.storeReadingsInHealthkit, healthKitInitialized,
              !replacementInFlight, replacementRetryWorkItem == nil,
              let bloodGlucoseType, let reading = replacementQueue.entries.first,
              uploadState.beginReplacement(timeStamp: reading.timeStamp)
        else { return }
        replacementInFlight = true
        deleteExistingBgReadingsFromHealthKit(bgReading: reading, bloodGlucoseType: bloodGlucoseType, bloodGlucoseUnit: HKUnit(from: "mg/dL"))
    }

    private func finishHealthKitReplacement(_ reading: HealthKitExportReading, succeeded: Bool) {
        uploadState.finishReplacement(timeStamp: reading.timeStamp)
        replacementInFlight = false
        if succeeded {
            replacementQueue.confirm(reading)
            persistHealthKitReplacements()
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
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.storeReadingsInHealthkitAuthorized.rawValue)
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.storeReadingsInHealthkit.rawValue)
    }
    
    private func deleteExistingBgReadingsFromHealthKit(bgReading: HealthKitExportReading, bloodGlucoseType: HKQuantityType, bloodGlucoseUnit: HKUnit) {
        HealthKitLegacyReplacement.perform(isEnabled: {
            UserDefaults.standard.storeReadingsInHealthkit && self.healthKitInitialized
        }, query: { completion in
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                HKQuery.predicateForObjects(withMetadataKey: self.bgReadingIdMetadataKey, allowedValues: [bgReading.id]),
                HKQuery.predicateForObjects(from: HKSource.default())
            ])
            let query = HKSampleQuery(sampleType: bloodGlucoseType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                DispatchQueue.main.async {
                    if let error {
                        completion(.failure(error))
                    } else {
                        // Sync-versioned objects update atomically. Only legacy objects need deletion.
                        completion(.success((samples ?? []).filter { $0.metadata?[HKMetadataKeySyncIdentifier] == nil }))
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
            self.finishHealthKitReplacement(bgReading, succeeded: false)
        })
    }
    
    private func saveBgReadingInHealthKit(bgReading: HealthKitExportReading, bloodGlucoseType: HKQuantityType, bloodGlucoseUnit: HKUnit, shouldUpdateLatestTimeStamp: Bool) {
        // Callers validate the canonical BgReading before creating this immutable export value.
        let quantity = HKQuantity(unit: bloodGlucoseUnit, doubleValue: bgReading.value)
        let sample = HKQuantitySample(type: bloodGlucoseType, quantity: quantity, start: bgReading.timeStamp, end: bgReading.timeStamp, metadata: bgReading.metadata)
        let timeStampLastReadingToUpload = bgReading.timeStamp

        healthStore.save(sample, withCompletion: { [weak self]
            (success: Bool, error: Error?) in
            guard let self = self else { return }
            DispatchQueue.main.async {
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
                        self.healthKitRetryWorkItem?.cancel()
                        self.healthKitRetryWorkItem = nil
                        self.storeBgReadings()
                    }
                    return
                }

                let errorDescription = error?.localizedDescription ?? "HealthKit save returned no error"
                trace("failed store reading in healthkit, error = %{public}@", log: self.log, category: ConstantsLog.categoryHealthKitManager, type: .error, troubleshooting: .detailed(.integration(name: .healthKit, activity: .failed)), errorDescription)

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
        })
    }
}
