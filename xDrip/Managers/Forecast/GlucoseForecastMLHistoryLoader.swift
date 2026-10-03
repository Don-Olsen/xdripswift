// Bounded, read-only Core Data snapshots for retrospective forecast evaluation.
import CoreData
import Foundation

/// Shared with the detached preparation task because DispatchQueue work does not
/// inherit Swift Task cancellation while it reads the historical Core Data windows.
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
    private let coreDataManager: CoreDataManager
    private let therapyManager: TherapyMetricsManager
    private let healthImporter: HealthKitTherapyImportManager
    private let worker = DispatchQueue(label: "glucose.forecast.ml.history", qos: .background)

    init(coreDataManager: CoreDataManager,
         therapyManager: TherapyMetricsManager = .shared,
         healthImporter: HealthKitTherapyImportManager = .shared) {
        self.coreDataManager = coreDataManager
        self.therapyManager = therapyManager
        self.healthImporter = healthImporter
    }

    /// Reads all saved glucose in day-sized windows across the requested period.
    /// `nil` means a failed, inconsistent, or cancelled read; an empty array means no usable examples.
    func load(days: Int = 60, at endDate: Date = .now, policy: DataFlowPolicy,
              settings: TherapyModelSettings, sensitivityMgdlPerUnit: Double,
              carbohydrateRatioGramsPerUnit: Double, calendar: Calendar = .current,
              cancellation: GlucoseForecastMLHistoryCancellation? = nil)
        async -> [GlucoseForecastMLReplayExample]? {
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
                    continuation.resume(returning: loadSync(days: days, endDate: endDate,
                        policy: policy, settings: settings,
                        sensitivityMgdlPerUnit: sensitivityMgdlPerUnit,
                        carbohydrateRatioGramsPerUnit: carbohydrateRatioGramsPerUnit,
                        calendar: calendar, cancellation: cancellation))
                })
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func loadSync(days: Int, endDate: Date, policy: DataFlowPolicy,
                          settings: TherapyModelSettings, sensitivityMgdlPerUnit: Double,
                          carbohydrateRatioGramsPerUnit: Double, calendar: Calendar,
                          cancellation: GlucoseForecastMLHistoryCancellation)
        -> [GlucoseForecastMLReplayExample]? {
        guard !cancellation.isCancelled else { return nil }
        let sourceAtStart = sourceSignature()
        guard !cancellation.isCancelled, sourceIsAvailable(policy),
              !therapyManager.hasUncommittedForecastInputChanges else { return nil }
        let treatmentRevision = therapyManager.treatmentChangeRevision
        // Read the source context's coordinator on its own queue, then keep all
        // replay fetches on a separate private context. Never pass managed
        // objects into the training worker.
        let sourceContext = coreDataManager.privateManagedObjectContext
        var persistentStoreCoordinator: NSPersistentStoreCoordinator?
        sourceContext.performAndWait {
            persistentStoreCoordinator = sourceContext.persistentStoreCoordinator
        }
        guard let persistentStoreCoordinator else { return nil }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = persistentStoreCoordinator
        let startDate = endDate.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        var dayStart = startDate
        var lastAnchorDate: Date?
        var examples = [GlucoseForecastMLReplayExample]()
        while dayStart < endDate {
            guard !cancellation.isCancelled, sourceSignature() == sourceAtStart,
                  sourceIsAvailable(policy), !therapyManager.hasUncommittedForecastInputChanges,
                  therapyManager.treatmentChangeRevision == treatmentRevision else { return nil }
            let dayEnd = min(dayStart.addingTimeInterval(24 * 60 * 60), endDate)
            let glucoseStart = dayStart.addingTimeInterval(-GlucoseForecastGlucoseSelection.fetchWindow)
            let glucoseEnd = dayEnd.addingTimeInterval(122 * 60)
            var observations: [GlucoseForecastGlucoseObservation]?
            context.performAndWait {
                guard !cancellation.isCancelled else { return }
                let request: NSFetchRequest<BgReading> = BgReading.fetchRequest()
                request.predicate = NSPredicate(format: "timeStamp >= %@ AND timeStamp <= %@",
                    glucoseStart as NSDate, glucoseEnd as NSDate)
                request.sortDescriptors = [NSSortDescriptor(key: #keyPath(BgReading.timeStamp), ascending: true)]
                request.fetchBatchSize = 500
                request.relationshipKeyPathsForPrefetching = ["sensor"]
                do {
                    observations = try context.fetch(request).map { reading in
                        GlucoseForecastGlucoseObservation(date: reading.timeStamp,
                            glucoseMgdl: reading.finalValue, sensorID: reading.sensor?.id,
                            isValidForDownstream: reading.isValidForDownstream,
                            isSuppressedByFiveMinuteCadence: reading.isSuppressedByFiveMinuteCadence)
                    }
                } catch { observations = nil }
                context.reset()
            }
            guard !cancellation.isCancelled, let observations else { return nil }
            let treatmentStart = dayStart.addingTimeInterval(
                -max(settings.insulinDuration, settings.carbDuration) * 60)
            guard let treatments = therapyManager.treatments(from: treatmentStart, to: dayEnd,
                policy: policy, settings: settings), !cancellation.isCancelled else { return nil }
            let batch = GlucoseForecastMLReplay.batch(observations: observations,
                treatments: treatments, settings: settings,
                sensitivityMgdlPerUnit: sensitivityMgdlPerUnit,
                carbohydrateRatioGramsPerUnit: carbohydrateRatioGramsPerUnit,
                anchorStart: dayStart, anchorEnd: dayEnd,
                previousAnchorDate: lastAnchorDate, calendar: calendar)
            guard !cancellation.isCancelled else { return nil }
            examples.append(contentsOf: batch.examples)
            lastAnchorDate = batch.lastAnchorDate
            dayStart = dayEnd
        }
        guard !cancellation.isCancelled, sourceSignature() == sourceAtStart,
              sourceIsAvailable(policy), !therapyManager.hasUncommittedForecastInputChanges,
              therapyManager.treatmentChangeRevision == treatmentRevision else { return nil }
        return examples
    }

    private func sourceIsAvailable(_ policy: DataFlowPolicy) -> Bool {
        GlucoseForecastDataAdapter.treatmentSourcesAreUnambiguous(policy,
            healthInsulinEnabled: healthImporter.isEnabled(.insulin),
            healthCarbsEnabled: healthImporter.isEnabled(.carbohydrates)) &&
            !healthImporter.localInputIsIncomplete(.insulin) &&
            !healthImporter.localInputIsIncomplete(.carbohydrates)
    }

    private func sourceSignature() -> String {
        HealthTherapyImportKind.allCases.map { kind in
            "\(healthImporter.isEnabled(kind)):\(healthImporter.selectedSource(kind)?.bundleIdentifier ?? "")"
        }.joined(separator: "|")
    }
}
