// Bounded, read-only HealthKit and Core Data snapshots for retrospective replay.
import CoreData
import Foundation

/// DispatchQueue work does not inherit Swift Task cancellation while it reads
/// historical HealthKit and Core Data windows.
final class GlucoseForecastMLHistoryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

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
    private let worker = DispatchQueue(label: "glucose.forecast.ml.history", qos: .background)

    init(coreDataManager: CoreDataManager,
         therapyManager: TherapyMetricsManager = .shared,
         healthImporter: HealthKitTherapyImportManager = .shared,
         healthQuery: GlucoseForecastMLHealthQuerying = GlucoseForecastMLLiveHealthQuery()) {
        self.coreDataManager = coreDataManager
        self.therapyManager = therapyManager
        self.healthImporter = healthImporter
        self.healthQuery = healthQuery
    }

    /// A non-nil empty result means the available history is insufficient.
    /// Nil is reserved for cancellation, changed inputs, or failed local reads.
    func load(days: Int = 365, at endDate: Date = .now, policy: DataFlowPolicy,
              settings: TherapyModelSettings, sensitivityMgdlPerUnit: Double,
              carbohydrateRatioGramsPerUnit: Double, calendar: Calendar = .current,
              cancellation: GlucoseForecastMLHistoryCancellation? = nil,
              progress: (@Sendable (Int, Int) -> Void)? = nil)
        async -> GlucoseForecastMLHistoryLoadResult? {
        guard days > 0, endDate.timeIntervalSince1970.isFinite, !Task.isCancelled,
              GlucoseForecastDataAdapter.sourceAllowsForecast(policy),
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
        let insulinEnabled = healthImporter.isEnabled(.insulin)
        let carbsEnabled = healthImporter.isEnabled(.carbohydrates)
        let insulinBundle = healthImporter.selectedSource(.insulin)?.bundleIdentifier
        let carbsBundle = healthImporter.selectedSource(.carbohydrates)?.bundleIdentifier
        let insulinHistoryStart = healthImporter.historyStart(.insulin)
        let carbsHistoryStart = healthImporter.historyStart(.carbohydrates)

        // Freeze all xDrip-named glucose source bundle identifiers for this run.
        // An empty/denied HealthKit response is unknown, never proof of absence.
        let discovered: [GlucoseForecastMLHealthSource] = queryValue(
            cancellation: cancellation) { completion in
                healthQuery.sources(for: .glucose, completion: completion)
            } ?? []
        let glucoseBundles = GlucoseForecastMLHistoryCoverageRules
            .matchingGlucoseSources(discovered).map(\.bundleIdentifier)

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
        var completed = 0
        var dayStart = firstDay
        while dayStart < endDate {
            guard !cancellation.isCancelled,
                  inputsStable(policy: policy, signature: signature,
                               treatmentRevision: treatmentRevision,
                               cancellation: cancellation),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart),
                  nextDay > dayStart else { return nil }
            let dayEnd = min(nextDay, endDate)
            guard let local = readLocalDay(context: context, start: dayStart, end: dayEnd,
                                           policy: policy, cancellation: cancellation) else { return nil }
            let cleanLocal = GlucoseForecastMLHistoryCoverageRules.normalizedLocalGlucose(local.glucose)
            localTreatments.append(contentsOf: local.treatments)
            localInsulinDates.append(contentsOf: local.importedInsulinDates)
            localCarbsDates.append(contentsOf: local.importedCarbohydrateDates)
            allLocalInsulinDates.append(contentsOf: local.insulinDates)
            allLocalCarbsDates.append(contentsOf: local.carbohydrateDates)

            var byBundle = [String: [GlucoseForecastGlucoseObservation]]()
            var allHealthSamples = [GlucoseForecastMLHealthSample]()
            var healthConflicts = Set<Date>()
            for bundle in glucoseBundles {
                if let values = queryValue(cancellation: cancellation, start: { completion in
                    healthQuery.samples(for: .glucose, from: dayStart, to: dayEnd,
                                        sourceBundleIdentifier: bundle, completion: completion)
                }) {
                    let bounded = values.filter { $0.startDate >= dayStart && $0.startDate < dayEnd }
                    allHealthSamples.append(contentsOf: bounded)
                    let cleaned = GlucoseForecastMLHistoryCoverageRules.normalizedHealthGlucose(
                        bounded, sourceBundleIdentifier: bundle)
                    byBundle[bundle] = cleaned.observations
                    healthConflicts.formUnion(cleaned.conflicts)
                }
            }
            // Conflict detection spans all locked source bundles, including a
            // bundle that will not supply this day's selected segment.
            healthConflicts.formUnion(
                GlucoseForecastMLHistoryCoverageRules.conflictingHealthDates(allHealthSamples))
            for bundle in byBundle.keys {
                byBundle[bundle]?.removeAll { healthConflicts.contains($0.date) }
            }
            if insulinEnabled, let insulinBundle,
               let values = queryValue(cancellation: cancellation, start: { completion in
                   healthQuery.samples(for: .insulin, from: dayStart, to: dayEnd,
                                       sourceBundleIdentifier: insulinBundle, completion: completion)
               }) {
                for sample in values where sample.sourceBundleIdentifier == insulinBundle &&
                    sample.startDate >= dayStart && sample.startDate < dayEnd {
                    if !sample.isUnambiguous(kind: .insulin) {
                        ambiguousInsulinDates.append(sample.startDate)
                    }
                    if let treatment = sample.treatment(kind: .insulin) {
                        healthInsulinDates.append(sample.startDate)
                        directHealthInsulin.append(treatment)
                    }
                }
            }
            if carbsEnabled, let carbsBundle,
               let values = queryValue(cancellation: cancellation, start: { completion in
                   healthQuery.samples(for: .carbohydrates, from: dayStart, to: dayEnd,
                                       sourceBundleIdentifier: carbsBundle, completion: completion)
               }) {
                for sample in values where sample.sourceBundleIdentifier == carbsBundle &&
                    sample.startDate >= dayStart && sample.startDate < dayEnd {
                    if !sample.isUnambiguous(kind: .carbohydrates) {
                        ambiguousCarbsDates.append(sample.startDate)
                    }
                    if let treatment = sample.treatment(kind: .carbohydrates) {
                        healthCarbsDates.append(sample.startDate)
                        directHealthCarbs.append(treatment)
                    }
                }
            }
            guard !cancellation.isCancelled else { return nil }
            daysRead.append(DaySnapshot(start: dayStart, end: dayEnd,
                healthByBundle: byBundle, localGlucose: cleanLocal.observations,
                healthConflicts: healthConflicts, localConflicts: cleanLocal.conflicts))
            completed += 1
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
            let healthInsulinEvidence = insulinEnabled ? healthInsulin : localInsulin
            let healthCarbEvidence = carbsEnabled ? healthCarbs : localCarbs
            let insulinCovered = (healthPresent && healthInsulinEvidence.covers(
                from: day.start, to: day.start, calendar: calendar, usingLocalImport: false)) ||
                (localPresent && localInsulin.covers(
                    from: day.start, to: day.start, calendar: calendar, usingLocalImport: true))
            let carbsCovered = (healthPresent && healthCarbEvidence.covers(
                from: day.start, to: day.start, calendar: calendar, usingLocalImport: false)) ||
                (localPresent && localCarbs.covers(
                    from: day.start, to: day.start, calendar: calendar, usingLocalImport: true))
            if !insulinCovered { unknownInsulinDays += 1 }
            if !carbsCovered { unknownCarbsDays += 1 }
        }
        let healthSegments = GlucoseForecastMLHistoryCoverageRules.segments(
            GlucoseForecastMLHistoryCoverageRules.deduplicatedHealthTagged(healthTagged),
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
            let insulinEvents = insulinEnabled && !usingLocal
                ? directHealthInsulin : localTreatments.filter(\.isIOB)
            let carbEvents = carbsEnabled && !usingLocal
                ? directHealthCarbs : localTreatments.filter { !$0.isIOB }
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
                              insulinEvidence.covers(from: anchor.addingTimeInterval(
                                -settings.insulinDuration * 60), to: anchor,
                                calendar: calendar, usingLocalImport: usingLocal),
                              carbEvidence.covers(from: anchor.addingTimeInterval(
                                -settings.carbDuration * 60), to: anchor,
                                calendar: calendar, usingLocalImport: usingLocal) else { continue }
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
            completedDays: completed, usableDays: usableDays,
            healthKitDays: healthDays, localFallbackDays: localDays,
            unknownInsulinDays: unknownInsulinDays,
            unknownCarbohydrateDays: unknownCarbsDays,
            conflictingGlucoseTimestamps: blockedHealth.union(blockedLocal).count,
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
                "date >= %@ AND date < %@ AND (treatmentdeleted == NO OR treatmentdeleted == nil) AND treatmentType IN %@",
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
                let insulinBundle = healthImporter.selectedSource(.insulin)?.bundleIdentifier
                let carbsBundle = healthImporter.selectedSource(.carbohydrates)?.bundleIdentifier
                let eligible = TherapyMetricsManager.eligibleTreatments(fetched, policy: policy,
                    insulinSource: insulinBundle, carbsSource: carbsBundle,
                    insulinEnabled: healthImporter.isEnabled(.insulin),
                    carbsEnabled: healthImporter.isEnabled(.carbohydrates))
                let treatments = eligible.map {
                    TherapyTreatment(date: $0.date, amount: $0.value,
                                     isIOB: $0.treatmentType == .Insulin)
                }
                result = LocalDay(glucose: glucose, treatments: treatments,
                    importedInsulinDates: fetched.filter {
                        $0.isHealthKitImported && $0.treatmentType == .Insulin &&
                            $0.healthKitSourceBundleIdentifier == insulinBundle
                    }.map(\.date),
                    importedCarbohydrateDates: fetched.filter {
                        $0.isHealthKitImported && $0.treatmentType == .Carbs &&
                            $0.healthKitSourceBundleIdentifier == carbsBundle
                    }.map(\.date),
                    insulinDates: eligible.filter { $0.treatmentType == .Insulin }.map(\.date),
                    carbohydrateDates: eligible.filter { $0.treatmentType == .Carbs }.map(\.date))
            } catch { result = nil }
            context.reset()
        }
        return result
    }

    private func queryValue<T>(cancellation: GlucoseForecastMLHistoryCancellation,
                               start: (@escaping (Result<T, Error>) -> Void)
                                   -> GlucoseForecastMLHealthQueryTicket) -> T? {
        guard !cancellation.isCancelled else { return nil }
        let semaphore = DispatchSemaphore(value: 0)
        var response: Result<T, Error>?
        let ticket = start { result in response = result; semaphore.signal() }
        let deadline = Date().addingTimeInterval(45)
        while semaphore.wait(timeout: .now() + 0.25) == .timedOut {
            if cancellation.isCancelled || Date() >= deadline {
                ticket.cancel()
                return nil
            }
        }
        return try? response?.get()
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
        HealthTherapyImportKind.allCases.map { kind in
            "\(healthImporter.isEnabled(kind)):\(healthImporter.selectedSource(kind)?.bundleIdentifier ?? "")"
        }.joined(separator: "|")
    }
}
