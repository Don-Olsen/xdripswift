//
//  GlucoseForecastDataAdapter.swift
//  xdrip
//
//  A read-only boundary between persisted observations and the local forecast.
//  Neither forecast inputs nor outputs are written to glucose or treatment storage.
//

import CoreData
import Foundation

/// A refresh hint accompanies an unavailable calculation; it is never logged as a valid result.
struct GlucoseForecastRefreshReference: Equatable, Sendable {
    let date: Date
    let sensorID: String
    let glucoseMgdl: Double
    let treatmentRevision: Int
    let inputSignature: String

    func matches(_ result: GlucoseForecastResult) -> Bool {
        result.reason == nil && result.referenceDate == date && result.referenceSensorID == sensorID
            && result.points.first?.date == date && result.points.first?.glucoseMgdl == glucoseMgdl
    }
}

struct GlucoseForecastPresentationOutcome: Sendable {
    let result: GlucoseForecastResult
    var refreshReference: GlucoseForecastRefreshReference? = nil
}

/// Core Data reads run on a serial worker. Home can cancel or supersede its awaiting Task
/// without ever blocking rendering or adding a polling timer.
final class GlucoseForecastDataAdapter {
    private let coreDataManager: CoreDataManager
    private let therapyManager: TherapyMetricsManager
    private let defaults: UserDefaults
    private let healthImporter: HealthKitTherapyImportManager
    private let logForecast: (GlucoseForecastLogSnapshot) -> Void
    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    private let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    private let worker = DispatchQueue(label: "glucose.forecast.inputs", qos: .utility)
    private let cacheLock = NSLock()
    private var cache: (key: CacheKey, result: GlucoseForecastResult)?

    init(coreDataManager: CoreDataManager,
         therapyManager: TherapyMetricsManager = .shared,
         defaults: UserDefaults = .standard,
         healthImporter: HealthKitTherapyImportManager = .shared,
         logForecast: @escaping (GlucoseForecastLogSnapshot) -> Void = { GlucoseForecastLog.shared.enqueue($0) }) {
        self.coreDataManager = coreDataManager
        self.therapyManager = therapyManager
        self.defaults = defaults
        self.healthImporter = healthImporter
        self.logForecast = logForecast
    }

    func forecast(horizonMinutes: Int, at now: Date = .now) async -> GlucoseForecastResult {
        await forecastForPresentation(horizonMinutes: horizonMinutes, at: now).result
    }

    static func presentationInputSignature(horizonMinutes: Int, defaults: UserDefaults = .standard,
                                          importer: HealthKitTherapyImportManager = .shared) -> String {
        "\(defaults.dataFlowPolicy)|\(TherapyModelSettings(defaults: defaults))|\(horizonMinutes)|"
            + "\(defaults.glucoseForecastManualSensitivityMgdlPerUnit ?? 0)|\(defaults.glucoseForecastManualCarbRatioGramsPerUnit ?? 0)|"
            + HealthTherapyImportKind.allCases.map {
                "\(importer.isEnabled($0)):\(importer.selectedSource($0)?.bundleIdentifier ?? "")"
            }.joined(separator: "|")
    }

    func forecastForPresentation(horizonMinutes: Int, at now: Date = .now) async -> GlucoseForecastPresentationOutcome {
        // Disabling the feature is not a failed calculation attempt.
        if horizonMinutes == 0 { return .init(result: Self.unavailable(.dataUnavailable)) }
        func unavailable(_ reason: GlucoseForecastUnavailableReason) -> GlucoseForecastPresentationOutcome {
            .init(result: record(Self.unavailable(reason), horizonMinutes: horizonMinutes))
        }
        let inputSignature = Self.presentationInputSignature(horizonMinutes: horizonMinutes,
                                                            defaults: defaults, importer: healthImporter)
        let mlSourceSignature = Self.presentationInputSignature(horizonMinutes: 120,
                                                                defaults: defaults, importer: healthImporter)
        guard horizonMinutes == 60 || horizonMinutes == 120 else {
            return unavailable(.invalidHorizon)
        }
        let policy = defaults.dataFlowPolicy
        // External AID/pump amounts own Home therapy. The local treatment cache is not a
        // substitute when an external status is missing or late.
        guard Self.sourceAllowsForecast(policy) else {
            return unavailable(.externalOwner)
        }
        let importer = healthImporter
        guard Self.treatmentSourcesAreUnambiguous(policy,
                                                   healthInsulinEnabled: importer.isEnabled(.insulin),
                                                   healthCarbsEnabled: importer.isEnabled(.carbohydrates)) else {
            return unavailable(.ambiguousTreatmentSources)
        }
        let settings = TherapyModelSettings(defaults: defaults)
        guard settings.validInsulin, settings.validCarbs else {
            return unavailable(.invalidSettings)
        }
        let manualSensitivity = defaults.glucoseForecastManualSensitivityMgdlPerUnit
        let manualRatio = defaults.glucoseForecastManualCarbRatioGramsPerUnit
        let parameters = Self.manualParameters(sensitivity: manualSensitivity, ratio: manualRatio)
        if case .failure(let reason) = parameters { return unavailable(reason) }
        return await withCheckedContinuation { continuation in
            worker.async(execute: DispatchWorkItem { [self] in
                continuation.resume(returning: buildForecast(
                    horizonMinutes: horizonMinutes,
                    at: now,
                    policy: policy,
                    settings: settings,
                    manualSensitivity: manualSensitivity,
                    manualRatio: manualRatio,
                    inputSignature: inputSignature,
                    mlSourceSignature: mlSourceSignature
                ))
            })
        }
    }

    private func buildForecast(horizonMinutes: Int, at now: Date, policy: DataFlowPolicy,
                               settings: TherapyModelSettings, manualSensitivity: Double?,
                               manualRatio: Double?, inputSignature: String,
                               mlSourceSignature: String) -> GlucoseForecastPresentationOutcome {
        var knownReference: GlucoseForecastSample?
        func unavailable(_ reason: GlucoseForecastUnavailableReason) -> GlucoseForecastPresentationOutcome {
            .init(result: record(Self.unavailable(reason), horizonMinutes: horizonMinutes,
                                 knownReference: knownReference, settings: settings))
        }
        let treatmentRevision = therapyManager.forecastInputChangeRevision
        guard !Task.isCancelled else { return unavailable(.dataUnavailable) }
        guard let glucose = recentGlucose(at: now) else { return unavailable(.dataUnavailable) }
        knownReference = glucose.last
        guard let referenceDate = glucose.last?.date else { return unavailable(.missingGlucose) }
        let importer = healthImporter
        // This distinct outcome is allowed only for a previously complete source's active read.
        // All calculation guards below remain unchanged, including generic read failures.
        if !therapyManager.hasUncommittedForecastInputChanges,
           importer.isRefreshingPreviouslyCompleteInputs(at: now),
           let latest = glucose.last, let sensorID = latest.sensorID, !sensorID.isEmpty,
           latest.glucoseMgdl.isFinite, latest.glucoseMgdl > 0,
           now >= latest.date, now.timeIntervalSince(latest.date) <= GlucoseForecastEngine.maximumGlucoseAge,
           treatmentRevision == therapyManager.forecastInputChangeRevision,
           inputSignature == Self.presentationInputSignature(horizonMinutes: horizonMinutes,
                                                            defaults: defaults, importer: importer) {
            var outcome = unavailable(.dataUnavailable)
            outcome.refreshReference = GlucoseForecastRefreshReference(date: latest.date, sensorID: sensorID,
                glucoseMgdl: latest.glucoseMgdl, treatmentRevision: treatmentRevision, inputSignature: inputSignature)
            return outcome
        }
        guard !therapyManager.hasUncommittedForecastInputChanges,
              !importer.localInputIsIncomplete(.insulin),
              !importer.localInputIsIncomplete(.carbohydrates)
        else { return unavailable(.dataUnavailable) }
        guard Self.treatmentSourcesAreUnambiguous(policy,
                                                   healthInsulinEnabled: importer.isEnabled(.insulin),
                                                   healthCarbsEnabled: importer.isEnabled(.carbohydrates)) else {
            return unavailable(.ambiguousTreatmentSources)
        }

        // TherapyMetricsManager fetches hour buckets. Include the interval since the newest
        // CGM value so a newly recorded bolus or meal cannot be silently ignored. Wait for a
        // fresh CGM anchor rather than predicting from a pre-treatment measurement.
        let start = referenceDate.addingTimeInterval(-max(settings.insulinDuration, settings.carbDuration) * 60)
        guard let fetchedTreatments = therapyManager.treatments(from: start, to: now,
                                                                policy: policy, settings: settings)
        else { return unavailable(.dataUnavailable) }
        guard !Self.hasTreatmentAfterReading(fetchedTreatments, referenceDate: referenceDate,
                                             calculationDate: now) else {
            return unavailable(.awaitingNextReading)
        }
        guard !therapyManager.hasUncommittedForecastInputChanges else {
            return unavailable(.dataUnavailable)
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
        case .failure(let reason): return unavailable(reason)
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
        let key = CacheKey(glucose: input.glucose.map { Stamp(date: $0.date, value: $0.glucoseMgdl,
                                                            sensorID: $0.sensorID) },
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
        if let cached {
            if cached.reason == nil {
                GlucoseForecastMLTrainingCoordinator.shared.scheduleIfNeeded(
                    coreDataManager: coreDataManager, policy: policy, settings: settings,
                    sensitivity: sensitivity, ratio: ratio,
                    sourceSignature: mlSourceSignature)
            }
            return .init(result: addMLIfUsable(to: cached, input: input, sourceSignature: mlSourceSignature))
        }
        guard !Task.isCancelled else { return unavailable(.dataUnavailable) }
        let calculated = GlucoseForecastEngine.predict(input)
        let engineResult = GlucoseForecastResult(points: calculated.points,
                                                 referenceDate: calculated.referenceDate,
                                                 reason: calculated.reason,
                                                 parameterSource: .manual,
                                                 referenceSensorID: glucose.last?.sensorID)
        guard !therapyManager.hasUncommittedForecastInputChanges else {
            return unavailable(.dataUnavailable)
        }
        cacheLock.lock()
        cache = (key, engineResult)
        cacheLock.unlock()
        // Replay and Create ML run on independent low-priority workers only after
        // the unchanged forecast engine has accepted the current sensor inputs.
        if engineResult.reason == nil {
            GlucoseForecastMLTrainingCoordinator.shared.scheduleIfNeeded(
                coreDataManager: coreDataManager, policy: policy, settings: settings,
                sensitivity: sensitivity, ratio: ratio,
                sourceSignature: mlSourceSignature)
        }
        // Keep the prospective evidence log's engine baseline immutable. A cached
        // engine result can be re-presented with a newly validated local ML model.
        let recordedEngineResult = record(engineResult, horizonMinutes: horizonMinutes,
            input: input, knownReference: knownReference, settings: settings,
            treatmentWindowStart: start, treatmentWindowEnd: referenceDate)
        return .init(result: addMLIfUsable(to: recordedEngineResult, input: input, sourceSignature: mlSourceSignature))
    }

    private func addMLIfUsable(to engineResult: GlucoseForecastResult,
                               input: GlucoseForecastInput,
                               sourceSignature: String) -> GlucoseForecastResult {
        // A treatment source can change while the serial data read is in flight.
        // Never decorate a result from the old source with a model for the new one.
        guard engineResult.reason == nil,
              sourceSignature == Self.presentationInputSignature(horizonMinutes: 120,
                  defaults: defaults, importer: healthImporter),
              let mlForecast = GlucoseForecastMLManager.shared.infer(input: input,
                  result: engineResult, sourceSignature: sourceSignature) else {
            return engineResult
        }
        return GlucoseForecastResult(points: engineResult.points,
                                     referenceDate: engineResult.referenceDate,
                                     reason: engineResult.reason,
                                     parameterSource: engineResult.parameterSource,
                                     referenceSensorID: engineResult.referenceSensorID,
                                     mlForecast: mlForecast)
    }

    private func record(_ result: GlucoseForecastResult, horizonMinutes: Int,
                        input: GlucoseForecastInput? = nil,
                        knownReference: GlucoseForecastSample? = nil,
                        settings: TherapyModelSettings? = nil,
                        treatmentWindowStart: Date? = nil,
                        treatmentWindowEnd: Date? = nil) -> GlucoseForecastResult {
        let sensorID = knownReference?.sensorID
        let context = GlucoseForecastLogContext(
            appVersion: appVersion, appBuild: appBuild,
            sourceIdentity: sensorID.map { "sensor:" + $0 } ?? "unresolved",
            sensorIdentity: sensorID, knownReference: knownReference,
            computedAt: Date(), horizonMinutes: horizonMinutes,
            insulinModel: settings.map { TherapyInsulinPreset.nearest(to: $0.insulinPeak).rawValue },
            treatmentWindowStart: treatmentWindowStart, treatmentWindowEnd: treatmentWindowEnd)
        do {
            logForecast(try GlucoseForecastLogSnapshot.make(input: input, result: result, context: context))
        } catch {
            // Deliberately excludes inputs, paths and the error's potentially sensitive text.
            GlucoseForecastLog.shared.captureFailure()
        }
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
            // The time window bounds this query. A count cap could hide the last valid
            // Home reading behind many rejected rows and create a false missing-data state.
            request.fetchBatchSize = 200
            request.relationshipKeyPathsForPrefetching = ["sensor"]
            do {
                let fetched = try context.fetch(request)
                let observations = fetched.map { reading in
                    GlucoseForecastGlucoseObservation(date: reading.timeStamp,
                        glucoseMgdl: reading.finalValue, sensorID: reading.sensor?.id,
                        isValidForDownstream: reading.isValidForDownstream,
                        isSuppressedByFiveMinuteCadence: reading.isSuppressedByFiveMinuteCadence)
                }
                result = GlucoseForecastGlucoseSelection.select(observations, at: now)
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

    private struct Stamp: Hashable { let date: Date; let value: Double; let sensorID: String? }
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
