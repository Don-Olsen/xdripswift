import Foundation
import HealthKit
import os

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
    
    /// metadata key used to identify individual BG readings in HealthKit
    private let bgReadingIdMetadataKey = "BgReadingId"
    
    // MARK: - intialization
    
    init(coreDataManager: CoreDataManager) {
        // initialize non optional private properties
        self.coreDataManager = coreDataManager
        bgReadingsAccessor = BgReadingsAccessor(coreDataManager: coreDataManager)
        
        // call super.init
        super.init()

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
            bgReading: bgReading,
            bloodGlucoseType: bloodGlucoseType,
            bloodGlucoseUnit: bloodGlucoseUnit,
            shouldUpdateLatestTimeStamp: true
        )
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
        
        if !UserDefaults.standard.storeReadingsInHealthkit || !healthKitInitialized {
            return
        }
        
        guard let bloodGlucoseType = bloodGlucoseType else { return }
        
        let bloodGlucoseUnit = HKUnit(from: "mg/dL")
        
        for bgReading in bgReadings where bgReading.isValidForDownstream {
            guard uploadState.beginReplacement(timeStamp: bgReading.timeStamp) else { continue }
            deleteExistingBgReadingsFromHealthKit(bgReading: bgReading, bloodGlucoseType: bloodGlucoseType, bloodGlucoseUnit: bloodGlucoseUnit)
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
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.storeReadingsInHealthkitAuthorized.rawValue)
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.storeReadingsInHealthkit.rawValue)
    }
    
    private func deleteExistingBgReadingsFromHealthKit(bgReading: BgReadingSnapshot, bloodGlucoseType: HKQuantityType, bloodGlucoseUnit: HKUnit) {
        let metadataPredicate = HKQuery.predicateForObjects(withMetadataKey: bgReadingIdMetadataKey, allowedValues: [bgReading.id])
        let sampleQuery = HKSampleQuery(sampleType: bloodGlucoseType, predicate: metadataPredicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { [weak self] _, samples, error in
            guard let self = self else { return }

            DispatchQueue.main.async {
                if let error = error {
                    trace("failed query existing healthkit BG reading, error = %{public}@", log: self.log, category: ConstantsLog.categoryHealthKitManager, type: .error, error.localizedDescription)
                    self.saveBgReadingInHealthKit(bgReading: bgReading, bloodGlucoseType: bloodGlucoseType, bloodGlucoseUnit: bloodGlucoseUnit, shouldUpdateLatestTimeStamp: false)
                    return
                }

                guard let samples = samples, samples.count > 0 else {
                    self.saveBgReadingInHealthKit(bgReading: bgReading, bloodGlucoseType: bloodGlucoseType, bloodGlucoseUnit: bloodGlucoseUnit, shouldUpdateLatestTimeStamp: false)
                    return
                }

                self.healthStore.delete(samples) { success, deleteError in
                    DispatchQueue.main.async {
                        if !success, let deleteError = deleteError {
                            trace("failed delete existing healthkit BG reading, error = %{public}@", log: self.log, category: ConstantsLog.categoryHealthKitManager, type: .error, deleteError.localizedDescription)
                        }

                        self.saveBgReadingInHealthKit(bgReading: bgReading, bloodGlucoseType: bloodGlucoseType, bloodGlucoseUnit: bloodGlucoseUnit, shouldUpdateLatestTimeStamp: false)
                    }
                }
            }
        }
        
        healthStore.execute(sampleQuery)
    }
    
    private func saveBgReadingInHealthKit(bgReading: BgReadingSnapshot, bloodGlucoseType: HKQuantityType, bloodGlucoseUnit: HKUnit, shouldUpdateLatestTimeStamp: Bool) {
        guard bgReading.isValidForDownstream else {
            if shouldUpdateLatestTimeStamp {
                _ = uploadState.finish(timeStamp: bgReading.timeStamp, succeeded: false, retryDelay: 30)
            } else {
                uploadState.finishReplacement(timeStamp: bgReading.timeStamp)
            }
            return
        }

        let quantity = HKQuantity(unit: bloodGlucoseUnit, doubleValue: bgReading.finalValue)
        let metadata = [bgReadingIdMetadataKey: bgReading.id]
        let sample = HKQuantitySample(type: bloodGlucoseType, quantity: quantity, start: bgReading.timeStamp, end: bgReading.timeStamp, metadata: metadata)
        let timeStampLastReadingToUpload = bgReading.timeStamp

        healthStore.save(sample, withCompletion: { [weak self]
            (success: Bool, error: Error?) in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if !shouldUpdateLatestTimeStamp {
                    self.uploadState.finishReplacement(timeStamp: timeStampLastReadingToUpload)
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
