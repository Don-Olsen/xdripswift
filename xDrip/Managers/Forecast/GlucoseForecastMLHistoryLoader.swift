// Bounded, read-only HealthKit and Core Data snapshots for retrospective replay.
import CoreData
import Foundation

/// DispatchQueue work does not inherit Swift Task cancellation while it reads
/// historical HealthKit and Core Data windows.
final class GlucoseForecastMLHistoryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var failure: String?
    private var diagnostic: String?

    var readFailure: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    var readDiagnostic: String? {
        lock.lock()
        defer { lock.unlock() }
        return diagnostic
    }

    func recordReadDiagnostic(_ message: String) {
        lock.lock()
        diagnostic = message
        lock.unlock()
    }

    func recordReadFailure(_ message: String) {
        lock.lock()
        if failure == nil { failure = message }
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class GlucoseForecastMLHistoryLoader {
    private struct LocalDay {
        let glucose: [GlucoseForecastGlucoseObservation]
        let treatments: [TherapyTreatment]
        let importedInsulinDates: [Date]
        let importedCarbohydrateDates: [Date]
        let insulinDates: [Date]
        let carbohydrateDates: [Date]
    }

    private struct DaySnapshot {
        let start: Date
        let end: Date
        let healthByBundle: [String: [GlucoseForecastGlucoseObservation]]
        let localGlucose: [GlucoseForecastGlucoseObservation]
        let healthConflicts: Set<Date>
        let localConflicts: Set<Date>
    }

    private let coreDataManager: CoreDataManager
    private let therapyManager: TherapyMetricsManager
    private let healthImporter: HealthKitTherapyImportManager
    private let healthQuery: GlucoseForecastMLHealthQuerying
    private let defaults: UserDefaults
    private let queryTimeout: TimeInterval
    private let worker = DispatchQueue(label: "glucose.forecast.ml.history", qos: .background)

    init(coreDataManager: CoreDataManager,
         therapyManager: TherapyMetricsManager = .shared,
         healthImporter: HealthKitTherapyImportManager = .shared,
         healthQuery: GlucoseForecastMLHealthQuerying = GlucoseForecastMLLiveHealthQuery(),
         defaults: UserDefaults = .standard, queryTimeout: TimeInterval = 45) {
        self.coreDataManager = coreDataManager
        self.therapyManager = therapyManager
        self.healthImporter = healthImporter
        self.healthQuery = healthQuery
        self.defaults = defaults
        self.queryTimeout = queryTimeout
    }

    /// A non-nil empty result means the available history is insufficient.
    /// Nil is reserved for cancellation, changed inputs, or failed local/Health reads.
    func load(days: Int = 365, at endDate: Date = .now, policy: DataFlowPolicy,
              settings: TherapyModelSettings, sensitivityMgdlPerUnit: Double,
              carbohydrateRatioGramsPerUnit: Double, calendar: Calendar = .current,
              cancellation: GlucoseForecastMLHistoryCancellation? = nil,
              progress: (@Sendable (Int, Int) -> Void)? = nil)
        async -> GlucoseForecastMLHistoryLoadResult? {
        guard days > 0, endDate.timeIntervalSince1970.isFinite, !Task.isCancelled,
              GlucoseForecastDataAdapter.sourceAllowsForecast(policy, defaults: defaults),
              settings.validInsulin, settings.validCarbs,
              case .success = GlucoseForecastDataAdapter.manualParameters(
                sensitivity: sensitivityMgdlPerUnit, ratio: carbohydrateRatioGramsPerUnit)
        else { return nil }
        let cancellation = cancellation ?? GlucoseForecastMLHistoryCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                worker.async(execute: DispatchWorkItem { [self] in
                    continuation.resume(returning: loadSync(
                        days: min(days, GlucoseForecastMLHistoryCoverageRules.maximumReadDays),
                        endDate: endDate, policy: policy, settings: settings,
                        sensitivityMgdlPerUnit: sensitivityMgdlPerUnit,
                        carbohydrateRatioGramsPerUnit: carbohydrateRatioGramsPerUnit,
                        calendar: calendar, cancellation: cancellation, progress: progress))
                })
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func loadSync(days: Int, endDate: Date, policy: DataFlowPolicy,
                          settings: TherapyModelSettings, sensitivityMgdlPerUnit: Double,
                          carbohydrateRatioGramsPerUnit: Double, calendar: Calendar,
                          cancellation: GlucoseForecastMLHistoryCancellation,
                          progress: (@Sendable (Int, Int) -> Void)?)
        -> GlucoseForecastMLHistoryLoadResult? {
        guard !cancellation.isCancelled else { return nil }
        let signature = sourceSignature()
        let treatmentRevision = therapyManager.treatmentChangeRevision
        guard inputsStable(policy: policy, signature: signature,
                           treatmentRevision: treatmentRevision,
                           cancellation: cancellation) else { return nil }
        let sourceContext = coreDataManager.privateManagedObjectContext
        var coordinator: NSPersistentStoreCoordinator?
        sourceContext.performAndWait { coordinator = sourceContext.persistentStoreCoordinator }
        guard let coordinator else { return nil }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator

        // Exactly days local calendar dates, including the possibly partial current date.
        guard let firstDay = calendar.date(byAdding: .day, value: 1 - days,
                                           to: calendar.startOfDay(for: endDate)) else { return nil }
        let cutover = TreatmentSourceCutover.current(defaults: defaults)
        // After the final mySugr import the periodic importer is off, but direct
        // historical Health reads still supply its pre-cutover training history.
        let insulinEnabled = healthImporter.isEnabled(.insulin) || cutover != nil
        let carbsEnabled = healthImporter.isEnabled(.carbohydrates) || cutover != nil
        let insulinBundle = cutover?.insulinSourceBundleID ??
            healthImporter.selectedSource(.insulin)?.bundleIdentifier
        let carbsBundle = cutover?.carbohydrateSourceBundleID ??
            healthImporter.selectedSource(.carbohydrates)?.bundleIdentifier
        let insulinHistoryStart = healthImporter.historyStart(.insulin)
        let carbsHistoryStart = healthImporter.historyStart(.carbohydrates)
        var insulinQuery = GlucoseForecastMLTreatmentQueryEvidence(
            effectiveImportEnabled: healthImporter.isEnabled(.insulin))
        var carbohydrateQuery = GlucoseForecastMLTreatmentQueryEvidence(
            effectiveImportEnabled: healthImporter.isEnabled(.carbohydrates))
        if !insulinEnabled {
            insulinQuery.skipReason = .importDisabledWithoutCutover
        } else if insulinBundle == nil {
            insulinQuery.skipReason = .missingSelectedSource
        }
        if !carbsEnabled {
            carbohydrateQuery.skipReason = .importDisabledWithoutCutover
        } else if carbsBundle == nil {
            carbohydrateQuery.skipReason = .missingSelectedSource
        }
        cancellation.recordReadDiagnostic(
            "Historikperiode: \(firstDay.ISO8601Format())–\(endDate.ISO8601Format()). " +
            "Kildeovergang: \(cutover == nil ? "mangler" : "gyldig"). " +
            "Valgt insulin-kilde: \(insulinBundle ?? "ingen"); kulhydrat-kilde: " +
            "\(carbsBundle ?? "ingen"). Løbende import: insulin " +
            "\(healthImporter.isEnabled(.insulin) ? "til" : "fra"), kulhydrat " +
            "\(healthImporter.isEnabled(.carbohydrates) ? "til" : "fra"). " +
            "Sundhed-kildeforespørgsler er endnu ikke afsluttet.")

        // Freeze all xDrip-named glucose source bundle identifiers for this run.
        // An empty/denied HealthKit response is unknown, never proof of absence.
        guard let discovered: [GlucoseForecastMLHealthSource] = queryValue(
            cancellation: cancellation, context: "glukosekilder", start: { completion in
                healthQuery.sources(for: .glucose, completion: completion)
            }) else { return nil }
        let glucoseBundles = GlucoseForecastMLHistoryCoverageRules
            .matchingGlucoseSources(discovered).map(\.bundleIdentifier)
        // Source discovery is diagnostic only. A similarly named source is
        // never selected in place of the persisted exact bundle identifier.
        var discoveredInsulinSources = [GlucoseForecastMLHealthSource]()
        var discoveredCarbohydrateSources = [GlucoseForecastMLHealthSource]()
        if insulinEnabled {
            guard let sources: [GlucoseForecastMLHealthSource] = queryValue(
                cancellation: cancellation, context: "insulinkilder", start: { completion in
                    healthQuery.sources(for: .insulin, completion: completion)
                }) else { return nil }
            discoveredInsulinSources = sources
        }
        if carbsEnabled {
            guard let sources: [GlucoseForecastMLHealthSource] = queryValue(
                cancellation: cancellation, context: "kulhydratkilder", start: { completion in
                    healthQuery.sources(for: .carbohydrates, completion: completion)
                }) else { return nil }
            discoveredCarbohydrateSources = sources
        }
        func diagnosticTrace() -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            func counts(_ evidence: GlucoseForecastMLTreatmentQueryEvidence,
                        selected: String?, discovered: [GlucoseForecastMLHealthSource]) -> String {
                let sources = discovered.map(\.bundleIdentifier).sorted().joined(separator: ", ")
                let rawSources = evidence.returnedSourceCounts.keys.sorted().map {
                    "\($0)=\(evidence.returnedSourceCounts[$0, default: 0])"
                }.joined(separator: ", ")
                return "\(evidence.executedQueries) forespørgsler, \(evidence.returnedCount) rå HK-samples, " +
                    "valgt \(selected ?? "intet") [fundet: \(sources)], " +
                    "rå kilder [\(rawSources)], \(evidence.sourceMatchedCount) efter kilde og tid, " +
                    "\(evidence.acceptedCount) gyldige poster"
            }
            let insulin = counts(insulinQuery, selected: insulinBundle,
                discovered: discoveredInsulinSources)
            let carbohydrate = counts(carbohydrateQuery, selected: carbsBundle,
                discovered: discoveredCarbohydrateSources)
            return "Historiklæsning \(formatter.string(from: firstDay))–" +
                "\(formatter.string(from: endDate)): insulin \(insulin); " +
                "kulhydrat \(carbohydrate)."
        }
        cancellation.recordReadDiagnostic(diagnosticTrace())
        var healthGlucoseByBundle = Dictionary(uniqueKeysWithValues: glucoseBundles.map {
            ($0, GlucoseForecastMLHistoryReadSpan())
        })
        var localGlucoseRead = GlucoseForecastMLHistoryReadSpan()
        var healthInsulinRead = GlucoseForecastMLHistoryReadSpan()
        var healthCarbohydrateRead = GlucoseForecastMLHistoryReadSpan()
        var localInsulinRead = GlucoseForecastMLHistoryReadSpan()
        var localCarbohydrateRead = GlucoseForecastMLHistoryReadSpan()

        var daysRead = [DaySnapshot]()
        var directHealthInsulin = [TherapyTreatment]()
        var directHealthCarbs = [TherapyTreatment]()
        var localTreatments = [TherapyTreatment]()
        var healthInsulinDates = [Date]()
        var healthCarbsDates = [Date]()
        var localInsulinDates = [Date]()
        var localCarbsDates = [Date]()
        var allLocalInsulinDates = [Date]()
        var allLocalCarbsDates = [Date]()
        var ambiguousInsulinDates = [Date]()
        var ambiguousCarbsDates = [Date]()
        var seenInsulinUUIDs = Set<UUID>()
        var seenCarbohydrateUUIDs = Set<UUID>()
        var mergedHealthGlucoseTimestamps = 0
        var discardedHealthGlucoseTimestamps = 0
        var completed = 0
        var dayStart = firstDay
        let dayFormatter = ISO8601DateFormatter()
        dayFormatter.formatOptions = [.withFullDate]
        dayFormatter.timeZone = calendar.timeZone
        while dayStart < endDate {
            guard !cancellation.isCancelled,
                  inputsStable(policy: policy, signature: signature,
                               treatmentRevision: treatmentRevision,
                               cancellation: cancellation),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart),
                  nextDay > dayStart else { return nil }
            let dayEnd = min(nextDay, endDate)
            let dayLabel = dayFormatter.string(from: dayStart)
            guard let local = readLocalDay(context: context, start: dayStart, end: dayEnd,
                                           policy: policy, cancellation: cancellation) else { return nil }
            let cleanLocal = GlucoseForecastMLHistoryCoverageRules.normalizedLocalGlucose(local.glucose)
            for row in local.glucose { localGlucoseRead.include(row.date) }
            for date in local.insulinDates { localInsulinRead.include(date) }
            for date in local.carbohydrateDates { localCarbohydrateRead.include(date) }
            localTreatments.append(contentsOf: local.treatments)
            localInsulinDates.append(contentsOf: local.importedInsulinDates)
            localCarbsDates.append(contentsOf: local.importedCarbohydrateDates)
            allLocalInsulinDates.append(contentsOf: local.insulinDates)
            allLocalCarbsDates.append(contentsOf: local.carbohydrateDates)

            var allHealthSamples = [GlucoseForecastMLHealthSample]()
            for bundle in glucoseBundles {
                guard let batch: GlucoseForecastMLHealthSampleBatch = queryValue(cancellation: cancellation,
                                              context: "glukose \(bundle) \(dayLabel)",
                                              start: { completion in
                    healthQuery.samples(for: .glucose, from: dayStart, to: dayEnd,
                                        sourceBundleIdentifier: bundle, completion: completion)
                }) else { return nil }
                let bounded = batch.samples.filter {
                    $0.sourceBundleIdentifier == bundle &&
                        $0.startDate >= dayStart && $0.startDate < dayEnd
                }
                for sample in bounded {
                    healthGlucoseByBundle[bundle, default: GlucoseForecastMLHistoryReadSpan()]
                        .include(sample.startDate)
                }
                allHealthSamples.append(contentsOf: bounded)
            }
            let normalizedHealth = GlucoseForecastMLHistoryCoverageRules.normalizeHealthGlucose(
                allHealthSamples)
            let byBundle = normalizedHealth.observationsByBundle
            let healthConflicts = normalizedHealth.conflicts.union(normalizedHealth.invalidOnlyDates)
            mergedHealthGlucoseTimestamps += normalizedHealth.mergedTimestamps
            discardedHealthGlucoseTimestamps += normalizedHealth.conflicts.count
            if insulinEnabled, let insulinBundle {
                insulinQuery.executedQueries += 1
                cancellation.recordReadDiagnostic(diagnosticTrace())
                guard let batch: GlucoseForecastMLHealthSampleBatch = queryValue(cancellation: cancellation,
                                              context: "insulin \(insulinBundle) \(dayLabel)",
                                              start: { completion in
                    healthQuery.samples(for: .insulin, from: dayStart, to: dayEnd,
                                        sourceBundleIdentifier: insulinBundle, completion: completion)
                }) else { return nil }
                insulinQuery.include(batch)
                for sample in batch.samples {
                    guard sample.sourceBundleIdentifier == insulinBundle else {
                        insulinQuery.sourceExcludedCount += 1
                        continue
                    }
                    guard sample.startDate >= dayStart && sample.startDate < dayEnd else {
                        insulinQuery.dateExcludedCount += 1
                        continue
                    }
                    insulinQuery.sourceMatchedCount += 1
                    healthInsulinRead.include(sample.startDate)
                    guard cutover?.permitsImported(eventDate: sample.startDate, kind: .insulin,
                        sourceBundleID: sample.sourceBundleIdentifier) ?? true else {
                        insulinQuery.cutoffExcludedCount += 1
                        continue
                    }
                    guard seenInsulinUUIDs.insert(sample.uuid).inserted else {
                        insulinQuery.duplicateExcludedCount += 1
                        continue
                    }
                    if !sample.isUnambiguous(kind: .insulin) {
                        ambiguousInsulinDates.append(sample.startDate)
                    }
                    if let treatment = sample.treatment(kind: .insulin) {
                        insulinQuery.acceptedCount += 1
                        healthInsulinDates.append(sample.startDate)
                        directHealthInsulin.append(treatment)
                    } else {
                        insulinQuery.invalidExcludedCount += 1
                    }
                }
            } else {
                insulinQuery.skippedQueries += 1
            }
            if carbsEnabled, let carbsBundle {
                carbohydrateQuery.executedQueries += 1
                cancellation.recordReadDiagnostic(diagnosticTrace())
                guard let batch: GlucoseForecastMLHealthSampleBatch = queryValue(cancellation: cancellation,
                                              context: "kulhydrat \(carbsBundle) \(dayLabel)",
                                              start: { completion in
                    healthQuery.samples(for: .carbohydrates, from: dayStart, to: dayEnd,
                                        sourceBundleIdentifier: carbsBundle, completion: completion)
                }) else { return nil }
                carbohydrateQuery.include(batch)
                for sample in batch.samples {
                    guard sample.sourceBundleIdentifier == carbsBundle else {
                        carbohydrateQuery.sourceExcludedCount += 1
                        continue
                    }
                    guard sample.startDate >= dayStart && sample.startDate < dayEnd else {
                        carbohydrateQuery.dateExcludedCount += 1
                        continue
                    }
                    carbohydrateQuery.sourceMatchedCount += 1
                    healthCarbohydrateRead.include(sample.startDate)
                    guard cutover?.permitsImported(eventDate: sample.startDate, kind: .carbohydrates,
                        sourceBundleID: sample.sourceBundleIdentifier) ?? true else {
                        carbohydrateQuery.cutoffExcludedCount += 1
                        continue
                    }
                    guard seenCarbohydrateUUIDs.insert(sample.uuid).inserted else {
                        carbohydrateQuery.duplicateExcludedCount += 1
                        continue
                    }
                    if !sample.isUnambiguous(kind: .carbohydrates) {
                        ambiguousCarbsDates.append(sample.startDate)
                    }
                    if let treatment = sample.treatment(kind: .carbohydrates) {
                        carbohydrateQuery.acceptedCount += 1
                        healthCarbsDates.append(sample.startDate)
                        directHealthCarbs.append(treatment)
                    } else {
                        carbohydrateQuery.invalidExcludedCount += 1
                    }
                }
            } else {
                carbohydrateQuery.skippedQueries += 1
            }
            guard !cancellation.isCancelled else { return nil }
            daysRead.append(DaySnapshot(start: dayStart, end: dayEnd,
                healthByBundle: byBundle, localGlucose: cleanLocal.observations,
                healthConflicts: healthConflicts, localConflicts: cleanLocal.conflicts))
            completed += 1
            cancellation.recordReadDiagnostic(diagnosticTrace())
            progress?(completed, days)
            dayStart = dayEnd
        }
        guard !cancellation.isCancelled,
              inputsStable(policy: policy, signature: signature,
                           treatmentRevision: treatmentRevision,
                           cancellation: cancellation) else { return nil }

        let healthInsulin = GlucoseForecastMLTherapyEvidence(
            sourceDays: GlucoseForecastMLHistoryCoverageRules.daySet(healthInsulinDates, calendar: calendar),
            ambiguousDays: GlucoseForecastMLHistoryCoverageRules.daySet(ambiguousInsulinDates, calendar: calendar),
            historyStart: nil, requiresSelectedSource: insulinEnabled)
        let healthCarbs = GlucoseForecastMLTherapyEvidence(
            sourceDays: GlucoseForecastMLHistoryCoverageRules.daySet(healthCarbsDates, calendar: calendar),
            ambiguousDays: GlucoseForecastMLHistoryCoverageRules.daySet(ambiguousCarbsDates, calendar: calendar),
            historyStart: nil, requiresSelectedSource: carbsEnabled)
        let localInsulin = GlucoseForecastMLTherapyEvidence(
            sourceDays: GlucoseForecastMLHistoryCoverageRules.daySet(
                insulinEnabled ? localInsulinDates : allLocalInsulinDates, calendar: calendar),
            ambiguousDays: GlucoseForecastMLHistoryCoverageRules.daySet(ambiguousInsulinDates, calendar: calendar),
            historyStart: insulinHistoryStart, requiresSelectedSource: insulinEnabled)
        let localCarbs = GlucoseForecastMLTherapyEvidence(
            sourceDays: GlucoseForecastMLHistoryCoverageRules.daySet(
                carbsEnabled ? localCarbsDates : allLocalCarbsDates, calendar: calendar),
            ambiguousDays: GlucoseForecastMLHistoryCoverageRules.daySet(ambiguousCarbsDates, calendar: calendar),
            historyStart: carbsHistoryStart, requiresSelectedSource: carbsEnabled)
        let cutoverInsulin = cutover.map { cutover in
            GlucoseForecastMLCutoverTherapyEvidence(cutoff: cutover.cutoff,
                importedBefore: healthInsulin,
                localAfter: GlucoseForecastMLTherapyEvidence(
                    sourceDays: GlucoseForecastMLHistoryCoverageRules.daySet(
                        allLocalInsulinDates, calendar: calendar),
                    ambiguousDays: [], historyStart: nil, requiresSelectedSource: false))
        }
        let cutoverCarbs = cutover.map { cutover in
            GlucoseForecastMLCutoverTherapyEvidence(cutoff: cutover.cutoff,
                importedBefore: healthCarbs,
                localAfter: GlucoseForecastMLTherapyEvidence(
                    sourceDays: GlucoseForecastMLHistoryCoverageRules.daySet(
                        allLocalCarbsDates, calendar: calendar),
                    ambiguousDays: [], historyStart: nil, requiresSelectedSource: false))
        }

        var healthTagged = [GlucoseForecastMLHistoryTaggedObservation]()
        var localTagged = [GlucoseForecastMLHistoryTaggedObservation]()
        var blockedHealth = Set<Date>()
        var blockedLocal = Set<Date>()
        var unknownInsulinDays = 0
        var unknownCarbsDays = 0
        for day in daysRead {
            blockedHealth.formUnion(day.healthConflicts)
            blockedLocal.formUnion(day.localConflicts)
            for bundle in day.healthByBundle.keys.sorted() {
                healthTagged.append(contentsOf: (day.healthByBundle[bundle] ?? []).map {
                    GlucoseForecastMLHistoryTaggedObservation(observation: $0, source: .healthKit,
                        sourceBundleIdentifier: bundle)
                })
            }
            localTagged.append(contentsOf: day.localGlucose.map {
                GlucoseForecastMLHistoryTaggedObservation(observation: $0, source: .local,
                    sourceBundleIdentifier: nil)
            })
            let healthPresent = day.healthByBundle.values.contains { !$0.isEmpty }
            let localPresent = !day.localGlucose.isEmpty
            let insulinCovered: Bool
            let carbsCovered: Bool
            if let cutoverInsulin, let cutoverCarbs {
                let lastDayInstant = Date(timeIntervalSinceReferenceDate:
                    day.end.timeIntervalSinceReferenceDate.nextDown)
                insulinCovered = (healthPresent || localPresent) && cutoverInsulin.covers(
                    from: day.start, to: lastDayInstant, calendar: calendar)
                carbsCovered = (healthPresent || localPresent) && cutoverCarbs.covers(
                    from: day.start, to: lastDayInstant, calendar: calendar)
            } else {
                let healthInsulinEvidence = insulinEnabled ? healthInsulin : localInsulin
                let healthCarbEvidence = carbsEnabled ? healthCarbs : localCarbs
                insulinCovered = (healthPresent && healthInsulinEvidence.covers(
                    from: day.start, to: day.start, calendar: calendar,
                    usingLocalImport: false)) || (localPresent && localInsulin.covers(
                    from: day.start, to: day.start, calendar: calendar,
                    usingLocalImport: true))
                carbsCovered = (healthPresent && healthCarbEvidence.covers(
                    from: day.start, to: day.start, calendar: calendar,
                    usingLocalImport: false)) || (localPresent && localCarbs.covers(
                    from: day.start, to: day.start, calendar: calendar,
                    usingLocalImport: true))
            }
            if !insulinCovered { unknownInsulinDays += 1 }
            if !carbsCovered { unknownCarbsDays += 1 }
        }
        let chosenHealthReadings = GlucoseForecastMLHistoryCoverageRules.deduplicatedHealthTagged(
            healthTagged)
        let healthLocalComparison = GlucoseForecastMLHistoryCoverageRules.compareHealthWithLocal(
            health: chosenHealthReadings, local: localTagged)
        let healthSegments = GlucoseForecastMLHistoryCoverageRules.segments(
            chosenHealthReadings,
            blockedDates: blockedHealth)
        let localSegments = GlucoseForecastMLHistoryCoverageRules.segments(
            localTagged, blockedDates: blockedLocal)
        let separated = healthSegments + localSegments
        var healthCandidates = [GlucoseForecastMLReplayExample]()
        var localCandidates = [GlucoseForecastMLReplayExample]()
        let longestTreatment = max(settings.insulinDuration, settings.carbDuration) * 60
        for (segment, readings) in separated {
            guard !cancellation.isCancelled else { return nil }
            let usingLocal = segment.source == .local
            let insulinEvidence = usingLocal || !insulinEnabled ? localInsulin : healthInsulin
            let carbEvidence = usingLocal || !carbsEnabled ? localCarbs : healthCarbs
            let insulinEvents = cutover != nil
                ? directHealthInsulin + localTreatments.filter(\.isIOB)
                : (insulinEnabled && !usingLocal ? directHealthInsulin :
                    localTreatments.filter(\.isIOB))
            let carbEvents = cutover != nil
                ? directHealthCarbs + localTreatments.filter { !$0.isIOB }
                : (carbsEnabled && !usingLocal ? directHealthCarbs :
                    localTreatments.filter { !$0.isIOB })
            var lastAnchorDate: Date?
            var anchorDay = calendar.startOfDay(for: segment.startDate)
            while anchorDay <= segment.endDate {
                guard !cancellation.isCancelled,
                      let nextDay = calendar.date(byAdding: .day, value: 1, to: anchorDay),
                      nextDay > anchorDay else { return nil }
                let anchorStart = max(anchorDay,
                    segment.startDate.addingTimeInterval(GlucoseForecastGlucoseSelection.fetchWindow))
                let latestAnchor = segment.endDate.addingTimeInterval(-120 * 60)
                let anchorEnd = min(nextDay, latestAnchor.addingTimeInterval(1))
                if anchorStart < anchorEnd {
                    let lookbackStart = anchorStart.addingTimeInterval(
                        -GlucoseForecastGlucoseSelection.fetchWindow)
                    let targetEnd = anchorEnd.addingTimeInterval(122 * 60)
                    let windowReadings = readings.filter {
                        $0.date >= lookbackStart && $0.date <= targetEnd
                    }
                    let treatmentStart = anchorStart.addingTimeInterval(-longestTreatment)
                    let windowTreatments = (insulinEvents + carbEvents).filter {
                        $0.date >= treatmentStart && $0.date <= anchorEnd
                    }
                    let batch = GlucoseForecastMLReplay.batch(observations: windowReadings,
                        treatments: windowTreatments, settings: settings,
                        sensitivityMgdlPerUnit: sensitivityMgdlPerUnit,
                        carbohydrateRatioGramsPerUnit: carbohydrateRatioGramsPerUnit,
                        anchorStart: anchorStart, anchorEnd: anchorEnd,
                        previousAnchorDate: lastAnchorDate, calendar: calendar)
                    lastAnchorDate = batch.lastAnchorDate
                    let triples = Dictionary(grouping: batch.examples, by: { $0.row.referenceDate })
                    for anchor in triples.keys.sorted() {
                        guard let rows = triples[anchor], rows.count == 3,
                              anchor.addingTimeInterval(120 * 60) <= segment.endDate,
                              (cutoverInsulin?.covers(from: anchor.addingTimeInterval(
                                -settings.insulinDuration * 60), to: anchor,
                                calendar: calendar) ?? insulinEvidence.covers(
                                from: anchor.addingTimeInterval(-settings.insulinDuration * 60),
                                to: anchor, calendar: calendar,
                                usingLocalImport: usingLocal)),
                              (cutoverCarbs?.covers(from: anchor.addingTimeInterval(
                                -max(settings.carbDuration, 480) * 60), to: anchor,
                                calendar: calendar) ?? carbEvidence.covers(
                                from: anchor.addingTimeInterval(-max(settings.carbDuration, 480) * 60),
                                to: anchor, calendar: calendar,
                                usingLocalImport: usingLocal)) else { continue }
                        let accepted = rows.sorted { $0.row.horizonMinutes < $1.row.horizonMinutes }
                        if usingLocal {
                            localCandidates.append(contentsOf: accepted)
                        } else {
                            healthCandidates.append(contentsOf: accepted)
                        }
                    }
                }
                anchorDay = nextDay
            }
        }
        guard !cancellation.isCancelled,
              inputsStable(policy: policy, signature: signature,
                           treatmentRevision: treatmentRevision,
                           cancellation: cancellation) else { return nil }
        // HealthKit receives priority at every covered anchor. A local anchor is
        // fallback only when no fully covered Health anchor lies within ten minutes.
        // Each candidate was replayed with one source's complete windows.
        let healthCandidateDays = Set(healthCandidates.map {
            calendar.startOfDay(for: $0.row.referenceDate)
        }).count
        let localCandidateDays = Set(localCandidates.map {
            calendar.startOfDay(for: $0.row.referenceDate)
        }).count
        let chosenHealth = spacedTriples(healthCandidates, excluding: [])
        let chosenLocal = spacedTriples(localCandidates,
            excluding: chosenHealth.map { $0.row.referenceDate })
        let examples = chosenHealth + chosenLocal
        let healthDays = Set(chosenHealth.map { calendar.startOfDay(for: $0.row.referenceDate) }).count
        let localDays = Set(chosenLocal.map { calendar.startOfDay(for: $0.row.referenceDate) }).count
        let orderedExamples = examples.sorted {
            if $0.row.referenceDate != $1.row.referenceDate {
                return $0.row.referenceDate < $1.row.referenceDate
            }
            return $0.row.horizonMinutes < $1.row.horizonMinutes
        }
        let usableDays = Set(orderedExamples.map {
            calendar.startOfDay(for: $0.row.referenceDate)
        }).count
        let counts = Dictionary(grouping: orderedExamples, by: {
            $0.row.horizonMinutes
        }).mapValues(\.count)
        let coverage = GlucoseForecastMLHistoryCoverage(requestedDays: days,
            requestedStart: firstDay, requestedEnd: endDate,
            healthGlucoseByBundle: healthGlucoseByBundle,
            localGlucoseRead: localGlucoseRead,
            healthInsulinRead: healthInsulinRead,
            healthCarbohydrateRead: healthCarbohydrateRead,
            localInsulinRead: localInsulinRead,
            localCarbohydrateRead: localCarbohydrateRead,
            insulinSourceBundleID: insulinBundle,
            carbohydrateSourceBundleID: carbsBundle,
            cutoverState: cutover == nil ? .missing : .valid,
            cutoverDate: cutover?.cutoff,
            cutoverInsulinSourceBundleID: cutover?.insulinSourceBundleID,
            cutoverCarbohydrateSourceBundleID: cutover?.carbohydrateSourceBundleID,
            discoveredInsulinSources: discoveredInsulinSources,
            discoveredCarbohydrateSources: discoveredCarbohydrateSources,
            insulinQuery: insulinQuery,
            carbohydrateQuery: carbohydrateQuery,
            acceptedHealthInsulinCount: healthInsulinDates.count,
            acceptedHealthCarbohydrateCount: healthCarbsDates.count,
            completedDays: completed, usableDays: usableDays,
            healthKitDays: healthDays, localFallbackDays: localDays,
            healthCandidateDays: healthCandidateDays,
            localCandidateDays: localCandidateDays,
            unknownInsulinDays: unknownInsulinDays,
            unknownCarbohydrateDays: unknownCarbsDays,
            conflictingGlucoseTimestamps: blockedHealth.union(blockedLocal).count,
            mergedHealthGlucoseTimestamps: mergedHealthGlucoseTimestamps,
            discardedHealthGlucoseTimestamps: discardedHealthGlucoseTimestamps,
            healthLocalComparisonCount: healthLocalComparison.count,
            healthLocalAbsoluteDifferenceMedianMgdl:
                healthLocalComparison.medianAbsoluteDifferenceMgdl,
            healthLocalAbsoluteDifferenceP95Mgdl:
                healthLocalComparison.p95AbsoluteDifferenceMgdl,
            exampleCountsByHorizon: counts)
        return GlucoseForecastMLHistoryLoadResult(examples: orderedExamples, coverage: coverage,
            segments: separated.map(\.0))
    }

    private func spacedTriples(_ examples: [GlucoseForecastMLReplayExample],
                               excluding excludedDates: [Date]) -> [GlucoseForecastMLReplayExample] {
        let grouped = Dictionary(grouping: examples, by: { $0.row.referenceDate })
        let excluded = Array(Set(excludedDates)).sorted()
        var exclusionIndex = 0
        var lastAccepted: Date?
        var accepted = [GlucoseForecastMLReplayExample]()
        for anchor in grouped.keys.sorted() {
            while exclusionIndex < excluded.count &&
                excluded[exclusionIndex] < anchor.addingTimeInterval(
                    -GlucoseForecastMLReplay.minimumAnchorSpacing) {
                exclusionIndex += 1
            }
            if exclusionIndex < excluded.count &&
                abs(excluded[exclusionIndex].timeIntervalSince(anchor)) <
                    GlucoseForecastMLReplay.minimumAnchorSpacing { continue }
            if let lastAccepted, anchor.timeIntervalSince(lastAccepted) <
                GlucoseForecastMLReplay.minimumAnchorSpacing { continue }
            guard let rows = grouped[anchor], rows.count == 3,
                  Set(rows.map { $0.row.horizonMinutes }) == Set([30, 60, 120]) else { continue }
            accepted.append(contentsOf: rows.sorted { $0.row.horizonMinutes < $1.row.horizonMinutes })
            lastAccepted = anchor
        }
        return accepted
    }

    private func readLocalDay(context: NSManagedObjectContext, start: Date, end: Date,
                              policy: DataFlowPolicy,
                              cancellation: GlucoseForecastMLHistoryCancellation) -> LocalDay? {
        var result: LocalDay?
        context.performAndWait {
            guard !cancellation.isCancelled else { return }
            let glucoseRequest: NSFetchRequest<BgReading> = BgReading.fetchRequest()
            glucoseRequest.predicate = NSPredicate(format: "timeStamp >= %@ AND timeStamp < %@",
                start as NSDate, end as NSDate)
            glucoseRequest.sortDescriptors = [
                NSSortDescriptor(key: #keyPath(BgReading.timeStamp), ascending: true)]
            glucoseRequest.fetchBatchSize = 500
            glucoseRequest.relationshipKeyPathsForPrefetching = ["sensor"]
            let treatmentRequest: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
            treatmentRequest.predicate = NSPredicate(format:
                "date >= %@ AND date < %@ AND treatmentType IN %@",
                start as NSDate, end as NSDate,
                [TreatmentType.Insulin.rawValue, TreatmentType.Carbs.rawValue])
            do {
                let glucose = try context.fetch(glucoseRequest).map { reading in
                    GlucoseForecastGlucoseObservation(date: reading.timeStamp,
                        glucoseMgdl: reading.finalValue, sensorID: reading.sensor?.id,
                        isValidForDownstream: reading.isValidForDownstream,
                        isSuppressedByFiveMinuteCadence: reading.isSuppressedByFiveMinuteCadence)
                }
                let fetched = try context.fetch(treatmentRequest)
                let cutover = TreatmentSourceCutover.current(defaults: defaults)
                let insulinBundle = cutover?.insulinSourceBundleID ??
                    healthImporter.selectedSource(.insulin)?.bundleIdentifier
                let carbsBundle = cutover?.carbohydrateSourceBundleID ??
                    healthImporter.selectedSource(.carbohydrates)?.bundleIdentifier
                let eligible = TherapyMetricsManager.eligibleTreatments(fetched, policy: policy,
                    insulinSource: insulinBundle, carbsSource: carbsBundle,
                    insulinEnabled: healthImporter.isEnabled(.insulin),
                    carbsEnabled: healthImporter.isEnabled(.carbohydrates),
                    cutover: cutover)
                // Direct Health history owns the pre-cutover portion in replay. Local
                // rows supply only app-origin records after the boundary, preventing
                // imported Core Data copies from being counted twice.
                let replayEligible = cutover == nil ? eligible :
                    eligible.filter { !$0.isHealthKitImported }
                let deletedLocal = fetched.filter { entry in
                    guard entry.treatmentdeleted, entry.isAppLocalTreatment,
                          (entry.treatmentType == .Insulin || entry.treatmentType == .Carbs) else {
                        return false
                    }
                    return cutover?.permitsLocal(eventDate: entry.date,
                        localTreatmentUUID: entry.localTreatmentUUID,
                        watchSourceUUID: entry.watchSourceUUID) ?? true
                }
                let treatments = (replayEligible + deletedLocal).map {
                    TherapyTreatment(date: $0.date, amount: $0.value,
                        isIOB: $0.treatmentType == .Insulin,
                        carbohydrateDurationMinutes: $0.treatmentType == .Carbs
                            ? $0.effectiveCarbohydrateDurationMinutes : nil,
                        knownAt: $0.isAppLocalTreatment ? $0.knownAtForCurrentRevision : nil,
                        createdAt: $0.isAppLocalTreatment ? $0.createdAt : nil,
                        modifiedAt: $0.isAppLocalTreatment ? $0.modifiedAt : nil,
                        isAppLocal: $0.isAppLocalTreatment,
                        isDeletedCurrentRevision: $0.treatmentdeleted)
                }
                result = LocalDay(glucose: glucose, treatments: treatments,
                    importedInsulinDates: fetched.filter {
                        !$0.treatmentdeleted && $0.isHealthKitImported && $0.treatmentType == .Insulin &&
                            $0.healthKitSourceBundleIdentifier == insulinBundle
                    }.map(\.date),
                    importedCarbohydrateDates: fetched.filter {
                        !$0.treatmentdeleted && $0.isHealthKitImported && $0.treatmentType == .Carbs &&
                            $0.healthKitSourceBundleIdentifier == carbsBundle
                    }.map(\.date),
                    insulinDates: replayEligible.filter { $0.treatmentType == .Insulin }.map(\.date),
                    carbohydrateDates: replayEligible.filter { $0.treatmentType == .Carbs }.map(\.date))
            } catch { result = nil }
            context.reset()
        }
        return result
    }

    private func queryValue<T>(cancellation: GlucoseForecastMLHistoryCancellation,
                               context: String,
                               start: (@escaping (Result<T, Error>) -> Void)
                                   -> GlucoseForecastMLHealthQueryTicket) -> T? {
        guard !cancellation.isCancelled else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var response: Result<T, Error>?
        let ticket = start { result in response = result; semaphore.signal() }
        let deadline = Date().addingTimeInterval(queryTimeout)
        while semaphore.wait(timeout: .now() + 0.25) == .timedOut {
            if cancellation.isCancelled {
                ticket.cancel()
                return nil
            }
            if Date() >= deadline {
                ticket.cancel()
                cancellation.recordReadFailure("Sundhed \(context): timeout uden svar")
                return nil
            }
        }
        guard let response else {
            cancellation.recordReadFailure("Sundhed \(context): intet svar")
            return nil
        }
        switch response {
        case .success(let value): return value
        case .failure(let error):
            let details = error as NSError
            cancellation.recordReadFailure(
                "Sundhed \(context): \(details.domain)/\(details.code)")
            return nil
        }
    }

    private func inputsStable(policy: DataFlowPolicy, signature: String,
                              treatmentRevision: Int,
                              cancellation: GlucoseForecastMLHistoryCancellation) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while true {
            guard !cancellation.isCancelled, sourceSignature() == signature,
                  therapyManager.treatmentChangeRevision == treatmentRevision,
                  !therapyManager.hasUncommittedForecastInputChanges,
                  GlucoseForecastDataAdapter.treatmentSourcesAreUnambiguous(policy,
                    healthInsulinEnabled: healthImporter.isEnabled(.insulin),
                    healthCarbsEnabled: healthImporter.isEnabled(.carbohydrates)) else { return false }
            let incomplete = healthImporter.localInputIsIncomplete(.insulin) ||
                healthImporter.localInputIsIncomplete(.carbohydrates)
            if !incomplete { return true }
            // A routine reread preserves prior completeness, but local Core Data
            // may be partway through its pages. Wait for all enabled kinds to
            // commit before taking another local snapshot. Any changed treatment
            // revision still aborts this run.
            guard let refresh = healthImporter.routineRefreshState() else { return false }
            if refresh.allEnabledKindsCommitted { return true }
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func sourceSignature() -> String {
        let sources = HealthTherapyImportKind.allCases.map { kind in
            "\(healthImporter.isEnabled(kind)):\(healthImporter.selectedSource(kind)?.bundleIdentifier ?? "")"
        }.joined(separator: "|")
        let cutover = TreatmentSourceCutover.current(defaults: defaults)
        return "\(sources)|\(cutover?.cutoff.timeIntervalSince1970 ?? 0):" +
            "\(cutover?.insulinSourceBundleID ?? ""):\(cutover?.carbohydrateSourceBundleID ?? "")"
    }
}
