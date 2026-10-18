//
//  GlucoseForecastDataAdapter.swift
//  xdrip
//
//  A read-only boundary between persisted observations and the local forecast.
//  Neither forecast inputs nor outputs are written to glucose or treatment storage.
//

import CoreData
import Foundation

struct GlucoseForecastPresentationOutcome: Sendable {
    let result: GlucoseForecastResult
    /// Separate, hypothetical curve for unconfirmed scheduled food; never an input to ML/alarms.
    let conditionalPlannedPoints: [GlucoseForecastPoint]?

    init(result: GlucoseForecastResult,
         conditionalPlannedPoints: [GlucoseForecastPoint]? = nil) {
        self.result = result
        self.conditionalPlannedPoints = conditionalPlannedPoints
    }
}

/// A single validated, read-only engine calculation for safety decisions. All auxiliary
/// values derive from the same detached treatment and glucose snapshot as `result`.
struct GlucoseForecastSafetyOutcome: Sendable {
    let result: GlucoseForecastResult
    let referenceGlucoseMgdl: Double?
    let activeInsulinUnits: Double?
    let slope15MgdlPerMinute: Double?
    let highAdvisory: HighSoonAdvisoryContext?

    init(result: GlucoseForecastResult, referenceGlucoseMgdl: Double?,
         activeInsulinUnits: Double?, slope15MgdlPerMinute: Double?,
         highAdvisory: HighSoonAdvisoryContext? = nil) {
        self.result = result
        self.referenceGlucoseMgdl = referenceGlucoseMgdl
        self.activeInsulinUnits = activeInsulinUnits
        self.slope15MgdlPerMinute = slope15MgdlPerMinute
        self.highAdvisory = highAdvisory
    }
}

/// Core Data reads run on a serial worker. Home can cancel or supersede its awaiting Task
/// without ever blocking rendering or adding a polling timer.
final class GlucoseForecastDataAdapter {
    /// Executes on the managed-object context queue; injectable for read-failure tests.
    typealias GlucoseFetch = (NSManagedObjectContext, NSFetchRequest<BgReading>) throws -> [BgReading]
    private let coreDataManager: CoreDataManager
    private let therapyManager: TherapyMetricsManager
    private let defaults: UserDefaults
    private let healthImporter: HealthKitTherapyImportManager
    private let logForecast: (GlucoseForecastLogSnapshot) -> Void
    private let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    private let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    private let worker = DispatchQueue(label: "glucose.forecast.inputs", qos: .utility)
    /// Injectable dispatch/read boundaries for deterministic cancellation tests.
    private let enqueuePresentation: ((DispatchWorkItem) -> Void)?
    private let presentationGlucoseFetch: GlucoseFetch?
    private let cacheLock = NSLock()
    private var cache: (key: CacheKey, result: GlucoseForecastResult)?

    init(coreDataManager: CoreDataManager,
         therapyManager: TherapyMetricsManager = .shared,
         defaults: UserDefaults = .standard,
         healthImporter: HealthKitTherapyImportManager = .shared,
         logForecast: @escaping (GlucoseForecastLogSnapshot) -> Void = { GlucoseForecastLog.shared.enqueue($0) },
         enqueuePresentation: ((DispatchWorkItem) -> Void)? = nil,
         presentationGlucoseFetch: GlucoseFetch? = nil) {
        self.coreDataManager = coreDataManager
        self.therapyManager = therapyManager
        self.defaults = defaults
        self.healthImporter = healthImporter
        self.logForecast = logForecast
        self.enqueuePresentation = enqueuePresentation
        self.presentationGlucoseFetch = presentationGlucoseFetch
    }

    func forecast(horizonMinutes: Int, at now: Date = .now) async -> GlucoseForecastResult {
        await forecastForPresentation(horizonMinutes: horizonMinutes, at: now).result
    }

    /// Unlike Home presentation, this performs no ML inference, logging, planned-food
    /// overlay, cache reuse or training. An incomplete source stays unavailable.
    func engineOnlyForecast(horizonMinutes: Int = 60, at now: Date = .now,
                            includeHighAdvisory: Bool = false)
        async -> GlucoseForecastSafetyOutcome {
        let snapshot = await therapyManager.penDoseSnapshot(at: now)
        switch snapshot {
        case .failure:
            return GlucoseForecastSafetyOutcome(
                result: GlucoseForecastResult(points: [], referenceDate: nil,
                    reason: .dataUnavailable), referenceGlucoseMgdl: nil,
                activeInsulinUnits: nil, slope15MgdlPerMinute: nil)
        case .success(let input):
            // Preserve Low soon's existing post-read parameter selection. Freeze these
            // same values for high advice, which also requires matching snapshot provenance.
            let sourceSignature = Self.presentationInputSignature(horizonMinutes: 120,
                defaults: defaults, importer: healthImporter)
            let profile = includeHighAdvisory ? PenDoseProfile.load(defaults: defaults) : nil
            let sensitivity = defaults.glucoseForecastManualSensitivityMgdlPerUnit
            let ratio = defaults.glucoseForecastManualCarbRatioGramsPerUnit
            let forecastRevision = therapyManager.forecastInputChangeRevision
            let frozenSettingsMatch = sourceSignature == Self.presentationInputSignature(horizonMinutes: 120,
                defaults: defaults, importer: healthImporter)
            // Pure value work must not wait behind this adapter's optional Home/ML queue.
            return await Task.detached(priority: .userInitiated) {
                Self.engineOnlyOutcome(snapshot: input,
                    horizonMinutes: horizonMinutes, at: now,
                    sensitivityMgdlPerUnit: sensitivity,
                    carbohydrateRatioGramsPerUnit: ratio,
                    highAdvisoryProfile: frozenSettingsMatch && input.sourceSignature == sourceSignature ? profile : nil,
                    forecastInputChangeRevision: forecastRevision)
            }.value
        }
    }

    /// Pure assembly from one detached, source-validated snapshot. The two-hour correction
    /// safety check cannot replace the original shorter forecast: a later out-of-range point
    /// may invalidate two hours while the complete first hour still supports a low warning.
    static func engineOnlyOutcome(snapshot: PenDoseInputSnapshot, horizonMinutes: Int = 60,
                                  at now: Date,
                                  sensitivityMgdlPerUnit: Double?,
                                  carbohydrateRatioGramsPerUnit: Double?,
                                  highAdvisoryProfile: PenDoseProfile? = nil,
                                  forecastInputChangeRevision: Int = 0)
        -> GlucoseForecastSafetyOutcome {
        let result = PenBolusCalculator.safetyForecast(snapshot: snapshot, at: now,
            sensitivityMgdlPerUnit: sensitivityMgdlPerUnit,
            carbohydrateRatioGramsPerUnit: carbohydrateRatioGramsPerUnit,
            horizonMinutes: horizonMinutes)
        let highAdvisory = highAdvisoryProfile.map { profile in
            let safety = PenBolusCalculator.safetyForecast(snapshot: snapshot, at: now,
                sensitivityMgdlPerUnit: sensitivityMgdlPerUnit,
                carbohydrateRatioGramsPerUnit: carbohydrateRatioGramsPerUnit,
                horizonMinutes: 120)
            let calculation = PenBolusCalculator.calculate(snapshot: snapshot, profile: profile,
                glucose: .currentCGM, newCarbs: .unrecorded(grams: 0),
                safetyForecast: safety, at: now)
            return HighSoonAdvisoryContext(capturedAt: snapshot.capturedAt,
                treatmentRevision: snapshot.treatmentRevision,
                forecastInputChangeRevision: forecastInputChangeRevision,
                sourceSignature: snapshot.sourceSignature, profile: profile,
                safetyForecast: safety, calculation: calculation)
        }
        return GlucoseForecastSafetyOutcome(result: result,
            referenceGlucoseMgdl: snapshot.glucose.last?.glucoseMgdl,
            activeInsulinUnits: result.reason == nil ? snapshot.iobUnits : nil,
            slope15MgdlPerMinute: rawSlope15(snapshot.glucose), highAdvisory: highAdvisory)
    }

    /// Recheck provenance immediately before a delayed high advisory is consumed. This never
    /// reads another dosing snapshot or turns an incomplete source into known zero insulin.
    func highAdvisoryInputsAreCurrent(_ context: HighSoonAdvisoryContext,
                                     at now: Date = .now) -> Bool {
        let age = now.timeIntervalSince(context.capturedAt)
        let policy = defaults.dataFlowPolicy
        return age.isFinite && (0...30).contains(age) &&
            context.treatmentRevision == therapyManager.treatmentChangeRevision &&
            context.forecastInputChangeRevision == therapyManager.forecastInputChangeRevision &&
            !therapyManager.hasUncommittedForecastInputChanges &&
            !healthImporter.localInputIsIncomplete(.insulin) &&
            !healthImporter.localInputIsIncomplete(.carbohydrates) &&
            TherapyMetricsManager.doseSourceIsReady(policy,
                cutover: TreatmentSourceCutover.current(defaults: defaults), defaults: defaults) &&
            !context.sourceSignature.isEmpty &&
            context.sourceSignature == Self.presentationInputSignature(horizonMinutes: 120,
                defaults: defaults, importer: healthImporter) &&
            context.profile.isConfirmed && context.profile == PenDoseProfile.load(defaults: defaults)
    }

    static func rawSlope15(_ glucose: [GlucoseForecastSample]) -> Double? {
        guard let latest = glucose.last, let sensorID = latest.sensorID,
              !sensorID.isEmpty else { return nil }
        let values = glucose.filter {
            $0.sensorID == sensorID && $0.date >= latest.date.addingTimeInterval(-15 * 60)
        }
        guard values.count >= 4,
              let first = values.first,
              latest.date.timeIntervalSince(first.date) >= 10 * 60 else { return nil }
        let x = values.map { $0.date.timeIntervalSince(first.date) / 60 }
        let y = values.map(\.glucoseMgdl)
        let xMean = x.reduce(0, +) / Double(x.count)
        let yMean = y.reduce(0, +) / Double(y.count)
        let denominator = zip(x, x).reduce(0.0) { $0 + ($1.0 - xMean) * ($1.1 - xMean) }
        guard denominator > 0 else { return nil }
        let numerator = zip(x, y).reduce(0.0) { $0 + ($1.0 - xMean) * ($1.1 - yMean) }
        let slope = numerator / denominator
        return slope.isFinite ? slope : nil
    }

    static func presentationInputSignature(horizonMinutes: Int, defaults: UserDefaults = .standard,
                                          importer: HealthKitTherapyImportManager = .shared) -> String {
        let cutover = TreatmentSourceCutover.current(defaults: defaults)
        return "\(defaults.dataFlowPolicy)|\(TherapyModelSettings(defaults: defaults))|\(horizonMinutes)|"
            + "\(defaults.glucoseForecastManualSensitivityMgdlPerUnit ?? 0)|\(defaults.glucoseForecastManualCarbRatioGramsPerUnit ?? 0)|"
            + HealthTherapyImportKind.allCases.map {
                "\(importer.isEnabled($0)):\(importer.selectedSource($0)?.bundleIdentifier ?? "")"
            }.joined(separator: "|")
            + "|cutover:\(cutover?.cutoff.timeIntervalSince1970 ?? 0):" +
                "\(cutover?.insulinSourceBundleID ?? ""):\(cutover?.carbohydrateSourceBundleID ?? "")"
    }

    func forecastForPresentation(horizonMinutes: Int, at now: Date = .now) async -> GlucoseForecastPresentationOutcome {
        // Disabling the feature is not a failed calculation attempt.
        if horizonMinutes == 0 || Task.isCancelled { return Self.cancelledPresentation }
        func unavailable(_ reason: GlucoseForecastUnavailableReason) -> GlucoseForecastPresentationOutcome {
            .init(result: record(Self.unavailable(reason), horizonMinutes: horizonMinutes,
                                 isCancelled: { Task.isCancelled }))
        }
        let inputSignature = Self.presentationInputSignature(horizonMinutes: horizonMinutes,
                                                            defaults: defaults, importer: healthImporter)
        let mlSourceSignature = Self.presentationInputSignature(horizonMinutes: 120,
                                                                defaults: defaults, importer: healthImporter)
        guard horizonMinutes == 60 || horizonMinutes == 120 else {
            return unavailable(.invalidHorizon)
        }
        let policy = defaults.dataFlowPolicy
        guard !defaults.bool(forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey) else {
            return unavailable(.ambiguousTreatmentSources)
        }
        // External AID/pump amounts own Home therapy. The local treatment cache is not a
        // substitute when an external status is missing or late.
        guard Self.sourceAllowsForecast(policy, defaults: defaults) else {
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
        let cancellation = GlucoseForecastPresentationCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Never cancel the work item itself: even a superseded queued request
                // must run its cancellation check and resume this continuation once.
                let work = DispatchWorkItem { [self] in
                    continuation.resume(returning: buildForecast(
                        horizonMinutes: horizonMinutes,
                        at: now,
                        policy: policy,
                        settings: settings,
                        manualSensitivity: manualSensitivity,
                        manualRatio: manualRatio,
                        inputSignature: inputSignature,
                        mlSourceSignature: mlSourceSignature,
                        isCancelled: { cancellation.isCancelled }
                    ))
                }
                if let enqueuePresentation { enqueuePresentation(work) }
                else { worker.async(execute: work) }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func buildForecast(horizonMinutes: Int, at now: Date, policy: DataFlowPolicy,
                               settings: TherapyModelSettings, manualSensitivity: Double?,
                               manualRatio: Double?, inputSignature: String,
                               mlSourceSignature: String,
                               isCancelled: () -> Bool) -> GlucoseForecastPresentationOutcome {
        var knownReference: GlucoseForecastSample?
        func unavailable(_ reason: GlucoseForecastUnavailableReason) -> GlucoseForecastPresentationOutcome {
            guard !isCancelled() else { return Self.cancelledPresentation }
            return .init(result: record(Self.unavailable(reason), horizonMinutes: horizonMinutes,
                                       knownReference: knownReference, settings: settings,
                                       isCancelled: isCancelled))
        }
        guard !isCancelled() else { return Self.cancelledPresentation }
        guard let glucose = recentGlucose(at: now, fetch: presentationGlucoseFetch,
                                         isCancelled: isCancelled) else { return unavailable(.dataUnavailable) }
        guard !isCancelled() else { return Self.cancelledPresentation }
        knownReference = glucose.last
        guard let referenceDate = glucose.last?.date else { return unavailable(.missingGlucose) }
        let importer = healthImporter
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
        guard !isCancelled() else { return Self.cancelledPresentation }
        guard let fetchedTreatments = therapyManager.treatments(from: start, to: now,
                                                                policy: policy, settings: settings)
        else { return unavailable(.dataUnavailable) }
        guard !isCancelled() else { return Self.cancelledPresentation }
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
        guard !isCancelled() else { return Self.cancelledPresentation }
        let plannedMeals = futurePlannedMeals(from: referenceDate,
            through: referenceDate.addingTimeInterval(60 * 60), isCancelled: isCancelled)
        guard !isCancelled() else { return Self.cancelledPresentation }
        func presentation(_ result: GlucoseForecastResult) -> GlucoseForecastPresentationOutcome {
            guard !isCancelled() else { return Self.cancelledPresentation }
            let conditional = plannedMeals.flatMap { meals -> [GlucoseForecastPoint]? in
                guard !meals.isEmpty else { return nil }
                return GlucoseForecastEngine.conditionalPlannedCarbohydratePoints(
                    base: result, planned: meals, sensitivityMgdlPerUnit: sensitivity,
                    carbohydrateRatioGramsPerUnit: ratio, settings: settings)
            }
            guard !isCancelled() else { return Self.cancelledPresentation }
            let presentedResult = addMLIfUsable(to: result, input: input,
                sourceSignature: mlSourceSignature, isCancelled: isCancelled)
            guard !isCancelled() else { return Self.cancelledPresentation }
            return .init(result: presentedResult, conditionalPlannedPoints: conditional)
        }
        let key = CacheKey(glucose: input.glucose.map { Stamp(date: $0.date, value: $0.glucoseMgdl,
                                                            sensorID: $0.sensorID) },
                           treatments: input.treatments.map { TreatmentStamp(date: $0.date,
                                                                               amount: $0.amount,
                                                                               isIOB: $0.isIOB,
                                                                               carbohydrateDurationMinutes: $0.carbohydrateDurationMinutes,
                                                                               knownAt: $0.knownAt) },
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
        guard !isCancelled() else { return Self.cancelledPresentation }
        if let cached {
            if cached.reason == nil {
                GlucoseForecastMLTrainingCoordinator.shared.scheduleIfNeeded(
                    coreDataManager: coreDataManager, policy: policy, settings: settings,
                    sensitivity: sensitivity, ratio: ratio,
                    sourceSignature: mlSourceSignature)
            }
            return presentation(cached)
        }
        guard !isCancelled() else { return Self.cancelledPresentation }
        let calculated = GlucoseForecastEngine.predict(input)
        guard !isCancelled() else { return Self.cancelledPresentation }
        let engineResult = GlucoseForecastResult(points: calculated.points,
                                                 referenceDate: calculated.referenceDate,
                                                 reason: calculated.reason,
                                                 parameterSource: .manual,
                                                 referenceSensorID: glucose.last?.sensorID)
        guard !therapyManager.hasUncommittedForecastInputChanges else {
            return unavailable(.dataUnavailable)
        }
        // Replay and Create ML run on independent low-priority workers only after
        // the unchanged forecast engine has accepted the current sensor inputs.
        guard !isCancelled() else { return Self.cancelledPresentation }
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
            treatmentWindowStart: start, treatmentWindowEnd: referenceDate,
            isCancelled: isCancelled)
        guard !isCancelled() else { return Self.cancelledPresentation }
        // A request cancelled before logging must not suppress a later live attempt
        // by leaving an unrecorded engine result in the cache.
        cacheLock.lock()
        cache = (key, engineResult)
        cacheLock.unlock()
        return presentation(recordedEngineResult)
    }

    private func futurePlannedMeals(from start: Date, through end: Date,
                                    isCancelled: () -> Bool) -> [TherapyTreatment]? {
        guard !isCancelled() else { return nil }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator =
            coreDataManager.privateManagedObjectContext.persistentStoreCoordinator
        var result: [TherapyTreatment]?
        context.performAndWait {
            guard !isCancelled() else { return }
            defer { context.reset() }
            let request: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
            request.predicate = NSPredicate(format:
                "date >= %@ AND date <= %@ AND treatmentType == %d AND plannedMealStateRaw == %@ AND (treatmentdeleted == NO OR treatmentdeleted == nil)",
                start as NSDate, end as NSDate, TreatmentType.Carbs.rawValue,
                TreatmentMealState.planned.rawValue)
            do {
                let entries = try context.fetch(request)
                guard !isCancelled() else { return }
                result = entries.compactMap { entry in
                    guard entry.localTreatmentUUID?.isEmpty == false,
                          entry.hasValidMealMetadata, entry.value.isFinite,
                          entry.value > 0 else { return nil }
                    return TherapyTreatment(date: entry.date, amount: entry.value,
                        isIOB: false,
                        carbohydrateDurationMinutes: entry.effectiveCarbohydrateDurationMinutes)
                }
            } catch { result = nil }
        }
        return result
    }

    private func addMLIfUsable(to engineResult: GlucoseForecastResult,
                               input: GlucoseForecastInput,
                               sourceSignature: String,
                               isCancelled: () -> Bool) -> GlucoseForecastResult {
        // A treatment source can change while the serial data read is in flight.
        // Never decorate a result from the old source with a model for the new one.
        guard !isCancelled(), engineResult.reason == nil,
              sourceSignature == Self.presentationInputSignature(horizonMinutes: 120,
                  defaults: defaults, importer: healthImporter),
              let mlForecast = GlucoseForecastMLManager.shared.infer(input: input,
                  result: engineResult, sourceSignature: sourceSignature) else {
            return engineResult
        }
        guard !isCancelled() else { return engineResult }
        let selectedML = GlucoseForecastMLPresentation.cappedBelowEngine(mlForecast,
            engine: engineResult,
            currentGlucoseMgdl: input.glucose.last?.glucoseMgdl,
            slope15MgdlPerMinute: Self.rawSlope15(input.glucose),
            lowSoonActive: LowSoonAlertState.isActive(at: input.now, defaults: defaults))
        guard let selectedML, !isCancelled() else { return engineResult }
        // Record only a model that passed the final presentation guard. Compare the
        // raw old-model curve with the engine, so a display-only low-glucose cap
        // cannot contaminate the model's measured MAE.
        GlucoseForecastMLManager.shared.recordTransitionPair(
            engine: engineResult, modelForecast: mlForecast, input: input,
            sourceSignature: sourceSignature)
        return GlucoseForecastResult(points: engineResult.points,
                                     referenceDate: engineResult.referenceDate,
                                     reason: engineResult.reason,
                                     parameterSource: engineResult.parameterSource,
                                     referenceSensorID: engineResult.referenceSensorID,
                                     mlForecast: selectedML)
    }

    private func record(_ result: GlucoseForecastResult, horizonMinutes: Int,
                        input: GlucoseForecastInput? = nil,
                        knownReference: GlucoseForecastSample? = nil,
                        settings: TherapyModelSettings? = nil,
                        treatmentWindowStart: Date? = nil,
                        treatmentWindowEnd: Date? = nil,
                        isCancelled: () -> Bool) -> GlucoseForecastResult {
        guard !isCancelled() else { return result }
        let sensorID = knownReference?.sensorID
        let context = GlucoseForecastLogContext(
            appVersion: appVersion, appBuild: appBuild,
            sourceIdentity: sensorID.map { "sensor:" + $0 } ?? "unresolved",
            sensorIdentity: sensorID, knownReference: knownReference,
            computedAt: Date(), horizonMinutes: horizonMinutes,
            insulinModel: settings.map { TherapyInsulinPreset.nearest(to: $0.insulinPeak).rawValue },
            treatmentWindowStart: treatmentWindowStart, treatmentWindowEnd: treatmentWindowEnd)
        do {
            let snapshot = try GlucoseForecastLogSnapshot.make(input: input, result: result, context: context)
            guard !isCancelled() else { return result }
            logForecast(snapshot)
        } catch {
            guard !isCancelled() else { return result }
            // Deliberately excludes inputs, paths and the error's potentially sensitive text.
            GlucoseForecastLog.shared.captureFailure()
        }
        return result
    }

    static func sourceAllowsForecast(_ policy: DataFlowPolicy,
                                     defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey) &&
            !TreatmentSourceCutover.hasInvalidStoredValue(defaults: defaults) &&
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
        treatments.contains {
            (($0.date > referenceDate && $0.date <= calculationDate) ||
                ($0.knownAt.map { $0 > referenceDate && $0 <= calculationDate } ?? false)) &&
                $0.amount.isFinite && $0.amount > 0
        }
    }

    static func treatmentsKnownAtReference(_ treatments: [TherapyTreatment], from start: Date,
                                           referenceDate: Date) -> [TherapyTreatment] {
        treatments.filter {
            $0.date >= start && $0.date <= referenceDate &&
                ($0.knownAt.map { $0 <= referenceDate } ?? true)
        }
    }

    /// Read the same downstream-valid final glucose value used by the Home graph. A fresh
    /// sensor's history is never spliced to an older sensor just to manufacture momentum.
    /// A successful empty/filtered selection is []; nil means the store could not be read.
    func recentGlucose(at now: Date, fetch: GlucoseFetch? = nil,
                       isCancelled: () -> Bool = { false }) -> [GlucoseForecastSample]? {
        let context = coreDataManager.privateManagedObjectContext
        var result: [GlucoseForecastSample]?
        context.performAndWait {
            guard !isCancelled() else { return }
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
                let fetched = try fetch?(context, request) ?? context.fetch(request)
                guard !isCancelled() else { return }
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

    /// Called from the existing saved-glucose event, independently of Home visibility.
    /// Both readings and the prospective engine/old-model pair are captured through this adapter's
    /// normal validated path; no retrospective model inference is used at outcome time.
    func monitorTransitionAfterSavedReading(at now: Date = .now) async {
        let defaults = self.defaults
        guard let sensitivity = defaults.glucoseForecastManualSensitivityMgdlPerUnit,
              let ratio = defaults.glucoseForecastManualCarbRatioGramsPerUnit else { return }
        let signature = Self.presentationInputSignature(horizonMinutes: 120,
            defaults: defaults, importer: healthImporter)
        guard let context = GlucoseForecastMLContext(
            sensitivityMgdlPerUnit: sensitivity,
            carbohydrateRatioGramsPerUnit: ratio,
            settings: TherapyModelSettings(defaults: defaults),
            sourceSignature: signature),
              GlucoseForecastMLManager.shared.needsTransitionObservation(context: context)
        else { return }
        let readings: [GlucoseForecastSample]? = await withCheckedContinuation { continuation in
            worker.async(execute: DispatchWorkItem { [self] in
                continuation.resume(returning: recentGlucose(at: now))
            })
        }
        if let readings {
            GlucoseForecastMLManager.shared.observeTransition(readings: readings,
                at: now, context: context)
        }
        // The same immutable input goes through ordinary source/freshness guards and
        // captures the actual model +60 curve before the target glucose can exist.
        _ = await forecastForPresentation(horizonMinutes: 60, at: now)
    }

    static func manualParameters(sensitivity: Double?, ratio: Double?)
        -> Result<(sensitivity: Double, ratio: Double), GlucoseForecastUnavailableReason> {
        guard let sensitivity, let ratio else { return .failure(.missingProfile) }
        guard sensitivity.isFinite, sensitivity > 0, ratio.isFinite, ratio > 0 else {
            return .failure(.invalidProfile)
        }
        return .success((sensitivity, ratio))
    }

    /// Cancellation is a control-flow outcome, never a failed prospective forecast attempt.
    private static var cancelledPresentation: GlucoseForecastPresentationOutcome {
        .init(result: unavailable(.dataUnavailable))
    }

    private static func unavailable(_ reason: GlucoseForecastUnavailableReason) -> GlucoseForecastResult {
        GlucoseForecastResult(points: [], referenceDate: nil, reason: reason)
    }

    private struct Stamp: Hashable { let date: Date; let value: Double; let sensorID: String? }
    private struct TreatmentStamp: Hashable {
        let date: Date
        let amount: Double
        let isIOB: Bool
        let carbohydrateDurationMinutes: Double?
        let knownAt: Date?
    }
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

/// A Swift task's cancellation flag is not inherited by the serial GCD worker.
private final class GlucoseForecastPresentationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}
