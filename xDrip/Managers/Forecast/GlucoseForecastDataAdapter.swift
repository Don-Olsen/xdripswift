//
//  GlucoseForecastDataAdapter.swift
//  xdrip
//
//  A read-only boundary between persisted observations and the local forecast.
//  Neither forecast inputs nor outputs are written to glucose or treatment storage.
//

import CoreData
import Foundation

/// Core Data reads run on a serial worker. Home can cancel or supersede its awaiting Task
/// without ever blocking rendering or adding a polling timer.
final class GlucoseForecastDataAdapter {
    private let coreDataManager: CoreDataManager
    private let therapyManager: TherapyMetricsManager
    private let defaults: UserDefaults
    private let worker = DispatchQueue(label: "glucose.forecast.inputs", qos: .utility)
    private let cacheLock = NSLock()
    private var cache: (key: CacheKey, result: GlucoseForecastResult)?

    init(coreDataManager: CoreDataManager,
         therapyManager: TherapyMetricsManager = .shared,
         defaults: UserDefaults = .standard) {
        self.coreDataManager = coreDataManager
        self.therapyManager = therapyManager
        self.defaults = defaults
    }

    func forecast(horizonMinutes: Int, at now: Date = .now) async -> GlucoseForecastResult {
        guard horizonMinutes == 60 || horizonMinutes == 120 else {
            return Self.unavailable(horizonMinutes == 0 ? .dataUnavailable : .invalidHorizon)
        }
        let policy = defaults.dataFlowPolicy
        // External AID/pump amounts own Home therapy. The local treatment cache is not a
        // substitute when an external status is missing or late.
        guard Self.sourceAllowsForecast(policy) else {
            return Self.unavailable(.externalOwner)
        }
        let importer = HealthKitTherapyImportManager.shared
        guard Self.treatmentSourcesAreUnambiguous(policy,
                                                   healthInsulinEnabled: importer.isEnabled(.insulin),
                                                   healthCarbsEnabled: importer.isEnabled(.carbohydrates)) else {
            return Self.unavailable(.ambiguousTreatmentSources)
        }
        let settings = TherapyModelSettings(defaults: defaults)
        guard settings.validInsulin, settings.validCarbs else {
            return Self.unavailable(.invalidSettings)
        }
        let manualSensitivity = defaults.glucoseForecastManualSensitivityMgdlPerUnit
        let manualRatio = defaults.glucoseForecastManualCarbRatioGramsPerUnit
        let parameters = Self.manualParameters(sensitivity: manualSensitivity, ratio: manualRatio)
        if case .failure(let reason) = parameters { return Self.unavailable(reason) }
        return await withCheckedContinuation { continuation in
            worker.async(execute: DispatchWorkItem { [self] in
                continuation.resume(returning: buildForecast(
                    horizonMinutes: horizonMinutes,
                    at: now,
                    policy: policy,
                    settings: settings,
                    manualSensitivity: manualSensitivity,
                    manualRatio: manualRatio
                ))
            })
        }
    }

    private func buildForecast(horizonMinutes: Int, at now: Date, policy: DataFlowPolicy,
                               settings: TherapyModelSettings, manualSensitivity: Double?,
                               manualRatio: Double?) -> GlucoseForecastResult {
        guard !Task.isCancelled else { return Self.unavailable(.dataUnavailable) }
        guard let glucose = recentGlucose(at: now) else { return Self.unavailable(.dataUnavailable) }
        guard let referenceDate = glucose.last?.date else { return Self.unavailable(.missingGlucose) }
        let importer = HealthKitTherapyImportManager.shared
        guard !therapyManager.hasUncommittedTreatmentChanges,
              !importer.localInputIsIncomplete(.insulin),
              !importer.localInputIsIncomplete(.carbohydrates)
        else { return Self.unavailable(.dataUnavailable) }
        guard Self.treatmentSourcesAreUnambiguous(policy,
                                                   healthInsulinEnabled: importer.isEnabled(.insulin),
                                                   healthCarbsEnabled: importer.isEnabled(.carbohydrates)) else {
            return Self.unavailable(.ambiguousTreatmentSources)
        }

        // TherapyMetricsManager fetches hour buckets. Include the interval since the newest
        // CGM value so a newly recorded bolus or meal cannot be silently ignored. Wait for a
        // fresh CGM anchor rather than predicting from a pre-treatment measurement.
        let start = referenceDate.addingTimeInterval(-max(settings.insulinDuration, settings.carbDuration) * 60)
        guard let fetchedTreatments = therapyManager.treatments(from: start, to: now,
                                                                policy: policy, settings: settings)
        else { return Self.unavailable(.dataUnavailable) }
        guard !Self.hasTreatmentAfterReading(fetchedTreatments, referenceDate: referenceDate,
                                             calculationDate: now) else {
            return Self.unavailable(.awaitingNextReading)
        }
        guard !therapyManager.hasUncommittedTreatmentChanges else {
            return Self.unavailable(.dataUnavailable)
        }
        let treatments = Self.treatmentsKnownAtReference(fetchedTreatments,
                                                         from: start, referenceDate: referenceDate)
        // Existing persisted Nightscout profiles cannot prove which store entry was selected:
        // its importer may fall back to an arbitrary first entry when defaultProfile is absent.
        // Until the provenance is stored, only an explicit user-confirmed manual pair is safe.
        let parameters = Self.manualParameters(sensitivity: manualSensitivity, ratio: manualRatio)
        let sensitivity: Double
        let ratio: Double
        switch parameters {
        case .success(let pair): (sensitivity, ratio) = pair
        case .failure(let reason): return Self.unavailable(reason)
        }
        let input = GlucoseForecastInput(
            glucose: glucose,
            treatments: treatments,
            settings: settings,
            sensitivityMgdlPerUnit: sensitivity,
            carbohydrateRatioGramsPerUnit: ratio,
            horizonMinutes: horizonMinutes,
            now: now
        )
        let key = CacheKey(glucose: input.glucose.map { Stamp(date: $0.date, value: $0.glucoseMgdl) },
                           treatments: input.treatments.map { TreatmentStamp(date: $0.date,
                                                                               amount: $0.amount,
                                                                               isIOB: $0.isIOB) },
                           horizonMinutes: horizonMinutes,
                           nowMinute: Int(now.timeIntervalSince1970 / 60),
                           insulinDuration: settings.insulinDuration,
                           insulinPeak: settings.insulinPeak,
                           carbDuration: settings.carbDuration,
                           sensitivity: sensitivity,
                           ratio: ratio,
                           treatmentRevision: therapyManager.treatmentChangeRevision)
        cacheLock.lock()
        let cached = cache?.key == key ? cache?.result : nil
        cacheLock.unlock()
        if let cached { return cached }
        guard !Task.isCancelled else { return Self.unavailable(.dataUnavailable) }
        let calculated = GlucoseForecastEngine.predict(input)
        let result = GlucoseForecastResult(points: calculated.points,
                                           referenceDate: calculated.referenceDate,
                                           reason: calculated.reason,
                                           parameterSource: .manual)
        guard !therapyManager.hasUncommittedTreatmentChanges else {
            return Self.unavailable(.dataUnavailable)
        }
        cacheLock.lock()
        cache = (key, result)
        cacheLock.unlock()
        return result
    }

    static func sourceAllowsForecast(_ policy: DataFlowPolicy) -> Bool {
        policy.externalIOBSource == nil && policy.externalCOBSource == nil
    }

    /// Nightscout IDs and HealthKit UUIDs can refer to the same dose without matching.
    /// Existing exact-ID dedup cannot prove uniqueness when both imports are active.
    static func treatmentSourcesAreUnambiguous(_ policy: DataFlowPolicy,
                                                healthInsulinEnabled: Bool,
                                                healthCarbsEnabled: Bool) -> Bool {
        !policy.importsTreatmentsFromNightscout || (!healthInsulinEnabled && !healthCarbsEnabled)
    }

    static func hasTreatmentAfterReading(_ treatments: [TherapyTreatment], referenceDate: Date,
                                         calculationDate: Date) -> Bool {
        treatments.contains { $0.date > referenceDate && $0.date <= calculationDate &&
            $0.amount.isFinite && $0.amount > 0 }
    }

    static func treatmentsKnownAtReference(_ treatments: [TherapyTreatment], from start: Date,
                                           referenceDate: Date) -> [TherapyTreatment] {
        treatments.filter { $0.date >= start && $0.date <= referenceDate }
    }

    /// Read the same downstream-valid final glucose value used by the Home graph. A fresh
    /// sensor's history is never spliced to an older sensor just to manufacture momentum.
    func recentGlucose(at now: Date) -> [GlucoseForecastSample]? {
        let context = coreDataManager.privateManagedObjectContext
        var result: [GlucoseForecastSample]?
        context.performAndWait {
            let request: NSFetchRequest<BgReading> = BgReading.fetchRequest()
            request.predicate = NSPredicate(
                format: "timeStamp >= %@ AND timeStamp <= %@",
                now.addingTimeInterval(-45 * 60) as NSDate, now as NSDate
            )
            request.sortDescriptors = [NSSortDescriptor(key: #keyPath(BgReading.timeStamp), ascending: false)]
            request.fetchLimit = 200
            request.relationshipKeyPathsForPrefetching = ["sensor"]
            do {
                let fetched = try context.fetch(request)
                guard let latest = fetched.first else { result = []; return }
                // Never discard a newer invalid observation and silently predict from an
                // older sensor/source. The most recent candidate must itself be usable.
                guard !latest.isSuppressedByFiveMinuteCadence,
                      latest.isValidForDownstream,
                      latest.finalValue.isFinite, latest.finalValue > 0 else {
                    result = []
                    return
                }
                guard let sensorID = latest.sensor?.id, !sensorID.isEmpty else {
                    // Device names identify models, not sensor instances. In particular, two
                    // successive Libre sensors can share the same name. Without a sensor ID,
                    // do not splice their histories to produce a confident trend.
                    result = [GlucoseForecastSample(date: latest.timeStamp, glucoseMgdl: latest.finalValue)]
                    return
                }
                let latestCandidates = fetched.prefix { $0.timeStamp == latest.timeStamp }
                guard latestCandidates.allSatisfy({ reading in
                    reading.sensor?.id == sensorID && !reading.isSuppressedByFiveMinuteCadence &&
                        reading.isValidForDownstream && reading.finalValue == latest.finalValue
                }) else {
                    // Core Data does not define an order for equal timestamps. A duplicate
                    // latest observation with a different source or value is ambiguous.
                    result = []
                    return
                }
                var byDate = [Date: Double]()
                for reading in fetched where reading.sensor?.id == sensorID &&
                    !reading.isSuppressedByFiveMinuteCadence && reading.isValidForDownstream &&
                    reading.finalValue.isFinite && reading.finalValue > 0 {
                    if let existing = byDate[reading.timeStamp], existing != reading.finalValue {
                        result = []
                        return
                    }
                    byDate[reading.timeStamp] = reading.finalValue
                }
                result = byDate.map { GlucoseForecastSample(date: $0.key, glucoseMgdl: $0.value) }
                    .sorted { $0.date < $1.date }
            } catch {
                result = nil
            }
        }
        return result
    }

    static func manualParameters(sensitivity: Double?, ratio: Double?)
        -> Result<(sensitivity: Double, ratio: Double), GlucoseForecastUnavailableReason> {
        guard let sensitivity, let ratio else { return .failure(.missingProfile) }
        guard sensitivity.isFinite, sensitivity > 0, ratio.isFinite, ratio > 0 else {
            return .failure(.invalidProfile)
        }
        return .success((sensitivity, ratio))
    }

    private static func unavailable(_ reason: GlucoseForecastUnavailableReason) -> GlucoseForecastResult {
        GlucoseForecastResult(points: [], referenceDate: nil, reason: reason)
    }

    private struct Stamp: Hashable { let date: Date; let value: Double }
    private struct TreatmentStamp: Hashable { let date: Date; let amount: Double; let isIOB: Bool }
    private struct CacheKey: Equatable {
        let glucose: [Stamp]
        let treatments: [TreatmentStamp]
        let horizonMinutes: Int
        let nowMinute: Int
        let insulinDuration: Double
        let insulinPeak: Double
        let carbDuration: Double
        let sensitivity: Double
        let ratio: Double
        let treatmentRevision: Int
    }
}
