//
//  TherapyMetricsManager.swift
//  xdrip
//
//  Created by Paul Plant on 12/8/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation
import CoreData

extension DataFlowPolicy {
    var externalIOBSource: TherapyMetricSource? {
        importsTherapyFromCareLink ? .careLink : importsStatusFromNightscout ? .nightscout : nil
    }
    var externalCOBSource: TherapyMetricSource? { importsStatusFromNightscout ? .nightscout : nil }
}

struct TherapyTreatment: Sendable {
    let date: Date
    let amount: Double
    let isIOB: Bool
    /// Stable, source-qualified identity for the optional CGM-based pen COB calculation.
    /// A missing identity does not alter ordinary IOB/COB or forecast calculations.
    let stableIdentity: String?
    /// A nil value is retained for older test callers; persisted carbohydrate rows supply 240.
    let carbohydrateDurationMinutes: Double?
    /// A local revision is usable in historical replay only after this instant.
    let knownAt: Date?
    let createdAt: Date?
    let modifiedAt: Date?
    let isAppLocal: Bool
    /// Replay-only tombstone: an earlier value cannot be reconstructed after deletion.
    let isDeletedCurrentRevision: Bool

    init(date: Date, amount: Double, isIOB: Bool,
         carbohydrateDurationMinutes: Double? = nil, knownAt: Date? = nil,
         createdAt: Date? = nil, modifiedAt: Date? = nil,
         isAppLocal: Bool = false, isDeletedCurrentRevision: Bool = false,
         stableIdentity: String? = nil) {
        self.date = date
        self.amount = amount
        self.isIOB = isIOB
        self.stableIdentity = stableIdentity
        self.carbohydrateDurationMinutes = carbohydrateDurationMinutes
        self.knownAt = knownAt
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isAppLocal = isAppLocal
        self.isDeletedCurrentRevision = isDeletedCurrentRevision
    }

    func carbohydrateDuration(or fallback: Double) -> Double {
        carbohydrateDurationMinutes ?? fallback
    }
}

/// Detached CGM evidence for the calculator's optional historical COB estimate.
/// Rejected newer readings must remain visible to this check even when the normal
/// latest-valid-CGM selection correctly omits them.
struct PenCOBGlucoseRow {
    let date: Date
    let sensorID: String?
    let valueMgdl: Double
    let isValid: Bool
    let isSuppressed: Bool
}

private struct PenCOBHistoryRead: Equatable {
    let samples: [GlucoseForecastSample]?
    let issue: PenCOBFallbackReason?
}

struct TherapyChartLoad {
    let series: TherapyChartSeries
    let inputsComplete: Bool
}

struct HomeTreatmentCommitDisplayState {
    let generation: Int
    let startedAt: Date
}

/// Forecast-only save provenance. A writer commit can confirm only the mutations forwarded
/// before that writer save began; newer child/main work must remain unavailable.
struct ForecastInputCommitState {
    private var mutationGeneration = 0
    private var forwardedGeneration = 0
    private var committedGeneration = 0
    private var writerSaveGeneration: Int?

    var hasPendingChanges: Bool { mutationGeneration > committedGeneration }

    mutating func childDidSave() { mutationGeneration += 1 }

    mutating func mainDidSave() {
        mutationGeneration += 1
        forwardedGeneration = mutationGeneration
    }

    mutating func writerWillSave() { writerSaveGeneration = forwardedGeneration }

    mutating func writerDidSaveTreatments() {
        guard let generation = writerSaveGeneration else { return }
        committedGeneration = max(committedGeneration, generation)
        writerSaveGeneration = nil
    }
}

/// Core Data is read only on its owning queue. Caches contain detached value types.
/// Reads happen outside the cache lock so a Core Data save notification cannot deadlock a fetch.
final class TherapyMetricsManager {
    static let shared = TherapyMetricsManager()
    static let changed = Notification.Name("TherapyMetricsChanged")
    // Configured during app setup. Snapshot/status providers are read by main-thread consumers.
    // Worker queues use only Core Data queue operations and immutable calculation inputs.
    private var coreDataManager: CoreDataManager?
    private var externalStatus: (() -> AIDStatus?)?
    private let lock = NSLock()
    private var revision = 0
    private var treatmentCache: [String: [TherapyTreatment]] = [:]
    private var treatmentRevision = 0
    private var treatmentPresentationRevision = 0
    /// Separates unrelated/manual treatment edits from HealthKit pages for Home-only continuity.
    private var nonHealthTreatmentPresentationRevision = 0
    /// Presentation provenance only; cache/status invalidations are not treatment mutations.
    private var forecastInputRevision = 0
    private var forecastCommitState = ForecastInputCommitState()
    private var pendingTreatmentCommit = false
    private var pendingHomeTreatmentCommit: HomeTreatmentCommitDisplayState?
    private var nextHomeTreatmentCommitGeneration = 0
    private var pendingReads = Set<String>()
    private var failedReads: [String: Date] = [:]
    private let inputQueue = DispatchQueue(label: "therapy.inputs", qos: .utility)
    private let chartQueue = DispatchQueue(label: "therapy.chart", qos: .utility)
    private var externalHistory = TherapyStatusHistoryCache()
    private var chartCache: [String: TherapyChartSeries] = [:]
    private var preferenceSignature = ""
    private var observers: [NSObjectProtocol] = []

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func configure(coreDataManager: CoreDataManager, externalStatus: @escaping () -> AIDStatus?) {
        self.coreDataManager = coreDataManager
        self.externalStatus = externalStatus
        guard observers.isEmpty else {
            lock.lock()
            forecastCommitState = ForecastInputCommitState()
            lock.unlock()
            invalidate(forecastInputsInvalidated: true)
            return
        }
        for name in [Notification.Name.NSManagedObjectContextWillSave, .NSManagedObjectContextDidSave, .NSManagedObjectContextObjectsDidChange, NSNotification.Name.NSSystemClockDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                if name == .NSManagedObjectContextWillSave {
                    guard let self,
                          notification.object as? NSManagedObjectContext === self.coreDataManager?.privateManagedObjectContext else { return }
                    self.lock.lock()
                    self.forecastCommitState.writerWillSave()
                    self.lock.unlock()
                    return
                }
                if name == .NSManagedObjectContextObjectsDidChange {
                    guard notification.object as? NSManagedObjectContext === self?.coreDataManager?.privateManagedObjectContext,
                          notification.userInfo?[NSInvalidatedAllObjectsKey] != nil else { return }
                }
                var treatmentsChanged = true
                if name == .NSManagedObjectContextDidSave {
                    guard let context = notification.object as? NSManagedObjectContext else { return }
                    let keys = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey]
                    let objects = keys.flatMap { notification.userInfo?[$0] as? Set<NSManagedObject> ?? [] }
                    treatmentsChanged = objects.contains { $0 is TreatmentEntry }
                    let nonHealthTreatmentChanged = objects.contains {
                        guard let entry = $0 as? TreatmentEntry else { return false }
                        return !entry.isHealthKitImported
                    }
                    if context === self?.coreDataManager?.mainManagedObjectContext {
                        if treatmentsChanged { self?.markPendingTreatmentCommit(nonHealthTreatmentChanged: nonHealthTreatmentChanged) }
                        return
                    }
                    if context.parent === self?.coreDataManager?.mainManagedObjectContext {
                        if treatmentsChanged { self?.markForecastInputMutation(nonHealthTreatmentChanged: nonHealthTreatmentChanged) }
                        return
                    }
                    guard context === self?.coreDataManager?.privateManagedObjectContext else { return }
                    guard treatmentsChanged || objects.contains(where: { $0 is NightscoutDeviceStatusEntry }) else { return }
                    if treatmentsChanged, let self {
                        self.lock.lock()
                        self.forecastCommitState.writerDidSaveTreatments()
                        self.lock.unlock()
                    }
                    self?.invalidate(treatmentsChanged: treatmentsChanged,
                        committedTreatmentSave: treatmentsChanged)
                    return
                }
                self?.invalidate(treatmentsChanged: treatmentsChanged, forecastInputsInvalidated: true)
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .coreDataContextSaveFailed,
            object: nil, queue: nil) { [weak self] notification in
            guard let self, let context = notification.object as? NSManagedObjectContext,
                  context === self.coreDataManager?.mainManagedObjectContext
                    || context === self.coreDataManager?.privateManagedObjectContext else { return }
            self.lock.lock()
            self.pendingHomeTreatmentCommit = nil
            self.lock.unlock()
            self.publishStatusChange()
        })
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            // Do not make background defaults writers wait for the main queue.
            DispatchQueue.main.async { [weak self] in
                // Cache keys include only the relevant preferences. Unrelated defaults do not flush inputs.
                guard let self else { return }
                let signature = "\(UserDefaults.standard.dataFlowPolicy)-\(TherapyModelSettings(defaults: .standard))"
                    + "-\(UserDefaults.standard.showIOBCOB)"
                guard signature != self.preferenceSignature else { return }
                self.preferenceSignature = signature
                NotificationCenter.default.post(name: Self.changed, object: self)
            }
        })
    }

    /// Import children can publish a known mutation before their main/writer saves run.
    /// Invalidate only forecast presentation here; existing cache and pending-save rules stay intact.
    private func markForecastInputMutation(nonHealthTreatmentChanged: Bool) {
        lock.lock()
        forecastCommitState.childDidSave()
        forecastInputRevision &+= 1
        if nonHealthTreatmentChanged {
            nonHealthTreatmentPresentationRevision &+= 1
            beginHomeTreatmentCommit()
        }
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: self) }
    }

    private func markPendingTreatmentCommit(nonHealthTreatmentChanged: Bool) {
        lock.lock()
        pendingTreatmentCommit = true
        forecastCommitState.mainDidSave()
        treatmentPresentationRevision &+= 1
        forecastInputRevision &+= 1
        if nonHealthTreatmentChanged {
            nonHealthTreatmentPresentationRevision &+= 1
            beginHomeTreatmentCommit()
        }
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: self) }
    }

    func invalidate(treatmentsChanged: Bool = true, committedTreatmentSave: Bool = false,
                    forecastInputsInvalidated: Bool = false) {
        lock.lock()
        revision &+= 1
        if committedTreatmentSave || forecastInputsInvalidated { forecastInputRevision &+= 1 }
        // A failed private save has no DidSave notification, so Home stays unavailable until
        // a later successful treatment commit rather than confirming old persisted inputs.
        if committedTreatmentSave {
            pendingTreatmentCommit = false
            if !forecastCommitState.hasPendingChanges { pendingHomeTreatmentCommit = nil }
        }
        if treatmentsChanged {
            treatmentRevision &+= 1
            treatmentPresentationRevision &+= 1
            treatmentCache.removeAll()
            failedReads.removeAll()
        }
        chartCache.removeAll()
        lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: self) }
    }

    /// A Health import phase changed without a treatment write. Rebuild Home's strict status,
    /// but leave its cached treatment and chart inputs untouched for an unchanged reread.
    func publishStatusChange() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.changed, object: self,
                                            userInfo: ["statusOnly": true])
        }
    }

    /// A child-context save is not confirmed until the private persistent-store save commits.
    /// Forecasts must not use the previous treatment snapshot during this interval.
    var hasUncommittedTreatmentChanges: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingTreatmentCommit
    }

    /// Only treatment changes invalidate a briefly retained local Home amount.
    var treatmentChangeRevision: Int {
        lock.lock()
        defer { lock.unlock() }
        return treatmentPresentationRevision
    }

    var nonHealthTreatmentChangeRevision: Int {
        lock.lock()
        defer { lock.unlock() }
        return nonHealthTreatmentPresentationRevision
    }

    private func beginHomeTreatmentCommit() {
        // Caller holds `lock`. A child and its main-context forwarding are one display window.
        guard pendingHomeTreatmentCommit == nil else { return }
        nextHomeTreatmentCommitGeneration &+= 1
        pendingHomeTreatmentCommit = HomeTreatmentCommitDisplayState(
            generation: nextHomeTreatmentCommitGeneration, startedAt: Date())
    }

    func pendingHomeTreatmentCommitState(at now: Date = .now) -> HomeTreatmentCommitDisplayState? {
        lock.lock()
        defer { lock.unlock() }
        guard let pendingHomeTreatmentCommit,
              pendingTreatmentCommit || forecastCommitState.hasPendingChanges,
              (0..<30).contains(now.timeIntervalSince(pendingHomeTreatmentCommit.startedAt)) else { return nil }
        return pendingHomeTreatmentCommit
    }

    /// A private import child may have saved before the main/writer chain commits. Forecast
    /// reads remain unavailable across that interval without changing normal snapshot behavior.
    var hasUncommittedForecastInputChanges: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingTreatmentCommit || forecastCommitState.hasPendingChanges
    }

    /// Pending and committed treatment mutations invalidate forecasts immediately. Import
    /// status/cache refreshes keep this identity, and source/settings have separate UI guards.
    var forecastInputChangeRevision: Int {
        lock.lock()
        defer { lock.unlock() }
        return forecastInputRevision
    }

    /// A fresh, immutable dosing input. This never borrows the Home display cache: a loaded
    /// empty treatment window is known zero, while an incomplete import or save is unknown.
    func penDoseSnapshot(at date: Date = .now, allowMissingGlucose: Bool = false) async
        -> Result<PenDoseInputSnapshot, PenDoseUnavailableReason> {
        await withCheckedContinuation { continuation in
            inputQueue.async { [self] in
                continuation.resume(returning: makePenDoseSnapshot(at: date,
                    allowMissingGlucose: allowMissingGlucose))
            }
        }
    }

    private func makePenDoseSnapshot(at date: Date, allowMissingGlucose: Bool)
        -> Result<PenDoseInputSnapshot, PenDoseUnavailableReason> {
        guard let coreDataManager else { return .failure(.treatmentReadFailed) }
        let defaults = UserDefaults.standard
        let policy = defaults.dataFlowPolicy
        guard Self.doseSourceIsReady(policy,
              cutover: TreatmentSourceCutover.current(defaults: defaults), defaults: defaults) else {
            return .failure(.incompleteTherapySources)
        }
        let importer = HealthKitTherapyImportManager.shared
        guard !importer.localInputIsIncomplete(.insulin),
              !importer.localInputIsIncomplete(.carbohydrates),
              Self.sourceInputsUnambiguousForDose(policy: policy, importer: importer) else {
            return .failure(.incompleteTherapySources)
        }
        guard !hasUncommittedForecastInputChanges else {
            return .failure(.uncommittedTreatments)
        }
        let settings = TherapyModelSettings(defaults: defaults)
        guard settings.validInsulin, settings.validCarbs else {
            return .failure(.invalidTreatment)
        }
        let sourceSignature = GlucoseForecastDataAdapter.presentationInputSignature(
            horizonMinutes: 120, defaults: defaults, importer: importer)
        let revision = treatmentChangeRevision
        // Glucose and treatments are read at one logical date on the same serial worker.
        // Check both the treatment revision and newest glucose again before publishing, so
        // a save or arriving minute cannot make a mixed, apparently fresh dosing snapshot.
        let glucoseReader = GlucoseForecastDataAdapter(coreDataManager: coreDataManager,
            therapyManager: self, defaults: defaults, healthImporter: importer)
        let firstGlucose = glucoseReader.recentGlucose(at: date)
        guard firstGlucose != nil || allowMissingGlucose else {
            return .failure(.missingGlucose)
        }
        // Include a meal that began before the CGM window but still overlaps it,
        // plus any rapid bolus already active when that overlap began.
        let windowMinutes = PenCGMCOBEstimator.requiredTreatmentLookbackMinutes(
            settings: settings)
        guard let treatments = treatments(from: date.addingTimeInterval(-windowMinutes * 60),
                                           to: date, policy: policy, settings: settings) else {
            return .failure(.treatmentReadFailed)
        }
        let historyStart = PenCGMCOBEstimator.historyStart(treatments: treatments,
            settings: settings, at: date)
        let historicalTreatmentCoverageUnknown: Bool = {
            guard let start = historyStart,
                  let cutover = TreatmentSourceCutover.current(defaults: defaults) else { return false }
            let priorActiveBolus = treatments.filter { $0.isIOB && $0.date < start &&
                $0.date.addingTimeInterval(settings.insulinDuration * 60) > start
            }.map(\.date).min()
            let provenanceStart = min(start, priorActiveBolus ?? start)
            guard provenanceStart < cutover.cutoff else { return false }
            return HealthTherapyImportKind.allCases.contains { kind in
                guard let coveredSince = importer.historyStart(kind) else { return true }
                return coveredSince > provenanceStart
            }
        }()
        func readScopedHistory(for glucose: [GlucoseForecastSample]?) -> PenCOBHistoryRead {
            guard let start = historyStart else { return PenCOBHistoryRead(samples: nil, issue: nil) }
            guard let latest = glucose?.last else {
                return PenCOBHistoryRead(samples: nil, issue: .missingHistory)
            }
            return penCOBGlucoseHistory(from: start.addingTimeInterval(
                -PenCGMCOBEstimator.maximumRawGapSeconds), through: date, latest: latest)
        }
        let firstHistory = readScopedHistory(for: firstGlucose)
        let finalGlucose = glucoseReader.recentGlucose(at: date)
        guard firstGlucose == finalGlucose,
              finalGlucose != nil || allowMissingGlucose,
              abs(Date().timeIntervalSince(date)) <= 30,
              revision == treatmentChangeRevision,
              !hasUncommittedForecastInputChanges,
              !importer.localInputIsIncomplete(.insulin),
              !importer.localInputIsIncomplete(.carbohydrates),
              Self.doseSourceIsReady(defaults.dataFlowPolicy,
                  cutover: TreatmentSourceCutover.current(defaults: defaults), defaults: defaults),
              sourceSignature == GlucoseForecastDataAdapter.presentationInputSignature(
                  horizonMinutes: 120, defaults: defaults, importer: importer) else {
            return .failure(.treatmentChangedDuringRead)
        }
        let finalHistory = readScopedHistory(for: finalGlucose)
        guard revision == treatmentChangeRevision,
              !hasUncommittedForecastInputChanges,
              !importer.localInputIsIncomplete(.insulin),
              !importer.localInputIsIncomplete(.carbohydrates),
              sourceSignature == GlucoseForecastDataAdapter.presentationInputSignature(
                  horizonMinutes: 120, defaults: defaults, importer: importer) else {
            return .failure(.treatmentChangedDuringRead)
        }
        let historyChanged = firstHistory != finalHistory
        return PenDoseInputSnapshot.make(capturedAt: date, glucose: finalGlucose ?? [],
            treatments: treatments.filter { $0.date <= date }, therapySettings: settings,
            treatmentRevision: revision,
            historicalGlucose: historyChanged ? nil : finalHistory.samples,
            historicalGlucoseIssue: historicalTreatmentCoverageUnknown ? .incompleteTreatmentHistory :
                historyChanged ? .changedInputs :
                finalHistory.issue,
            sourceSignature: sourceSignature)
    }

    /// The optional calculator estimate reads only its relevant historical window. A failed
    /// read or mismatched sensor leaves the original curve COB available as the fallback.
    private func penCOBGlucoseHistory(from start: Date, through end: Date,
                                      latest: GlucoseForecastSample) -> PenCOBHistoryRead {
        guard let coreDataManager, let sensorID = latest.sensorID, !sensorID.isEmpty,
              start < end else { return PenCOBHistoryRead(samples: nil, issue: .missingHistory) }
        let context = coreDataManager.privateManagedObjectContext
        var result = PenCOBHistoryRead(samples: nil, issue: .missingHistory)
        context.performAndWait {
            let request: NSFetchRequest<BgReading> = BgReading.fetchRequest()
            request.predicate = NSPredicate(format: "timeStamp >= %@ AND timeStamp <= %@",
                start as NSDate, end as NSDate)
            request.sortDescriptors = [NSSortDescriptor(key: #keyPath(BgReading.timeStamp), ascending: true)]
            request.fetchBatchSize = 200
            request.relationshipKeyPathsForPrefetching = ["sensor"]
            do {
                let readings = try context.fetch(request)
                let rows = readings.map { reading in
                    PenCOBGlucoseRow(date: reading.timeStamp, sensorID: reading.sensor?.id,
                        valueMgdl: reading.finalValue,
                        isValid: reading.isValidForDownstream,
                        isSuppressed: reading.isSuppressedByFiveMinuteCadence)
                }
                switch Self.scopedPenCOBHistory(rows: rows, sensorID: sensorID,
                                                 latestDate: latest.date) {
                case .success(let samples):
                    result = PenCOBHistoryRead(samples: samples, issue: nil)
                case .failure(let reason):
                    result = PenCOBHistoryRead(samples: nil, issue: reason)
                }
            } catch { result = PenCOBHistoryRead(samples: nil, issue: .missingHistory) }
        }
        return result
    }

    static func scopedPenCOBHistory(rows: [PenCOBGlucoseRow], sensorID: String,
                                    latestDate: Date)
        -> Result<[GlucoseForecastSample], PenCOBFallbackReason> {
        guard !sensorID.isEmpty else { return .failure(.sensorMismatch) }
        var values = [Date: Double]()
        for row in rows.sorted(by: { $0.date < $1.date }) where !row.isSuppressed {
            guard row.sensorID == sensorID else { return .failure(.sensorMismatch) }
            guard row.isValid, row.valueMgdl.isFinite,
                  (20...600).contains(row.valueMgdl) else { return .failure(.invalidHistory) }
            // A newer rejected reading must be seen above; a newer valid reading means
            // latest-valid selection changed during the read. Neither proves absorption.
            guard row.date <= latestDate else { return .failure(.changedInputs) }
            if let previous = values[row.date], previous != row.valueMgdl {
                return .failure(.invalidHistory)
            }
            values[row.date] = row.valueMgdl
        }
        let samples = values.map { GlucoseForecastSample(date: $0.key,
            glucoseMgdl: $0.value, sensorID: sensorID) }.sorted { $0.date < $1.date }
        return samples.isEmpty ? .failure(.missingHistory) : .success(samples)
    }

    private static func sourceInputsUnambiguousForDose(policy: DataFlowPolicy,
        importer: HealthKitTherapyImportManager) -> Bool {
        !policy.importsTreatmentsFromNightscout ||
            (!importer.isEnabled(.insulin) && !importer.isEnabled(.carbohydrates))
    }

    static func doseSourceIsReady(_ policy: DataFlowPolicy,
        cutover: TreatmentSourceCutover?, defaults: UserDefaults = .standard) -> Bool {
        // A successful Phase B source switch persists this boundary only after the final
        // Health import. Without it an empty local window cannot prove zero IOB or COB.
        cutover != nil && policy.therapyDataSource == .none &&
            !policy.importsTreatmentsFromNightscout &&
            cutoverPolicyIsConsistent(policy, cutover: cutover, defaults: defaults)
    }

    /// Detached values from the last complete local read. Home may age these during a brief
    /// Health reread; this never changes the strict current snapshot used by calculations.
    func completeLocalTreatmentsForHome(at date: Date = .now) -> [TherapyTreatment]? {
        guard !hasUncommittedForecastInputChanges,
              !HealthKitTherapyImportManager.shared.localInputIsIncomplete(.insulin),
              !HealthKitTherapyImportManager.shared.localInputIsIncomplete(.carbohydrates) else { return nil }
        let policy = UserDefaults.standard.dataFlowPolicy
        guard Self.cutoverPolicyIsConsistent(policy,
            cutover: TreatmentSourceCutover.current()) else { return nil }
        let settings = TherapyModelSettings(defaults: .standard)
        return treatments(from: date.addingTimeInterval(-TherapyModelSettings.visibilityInterval),
            to: min(Date(), date.addingTimeInterval(TherapyModelSettings.visibilityInterval)),
            policy: policy, settings: settings)
    }

    private func key(policy: DataFlowPolicy, settings: TherapyModelSettings) -> String {
        lock.lock(); let version = revision; lock.unlock()
        return "\(version)-\(UserDefaults.standard.nightscoutTreatmentsUpdateCounter)-\(policy.therapyDataSource.rawValue)-\(policy.nightscoutFollowType.rawValue)-\(settings)"
    }

    static func cutoverPolicyIsConsistent(_ policy: DataFlowPolicy,
                                         cutover: TreatmentSourceCutover?,
                                         defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey) &&
            !TreatmentSourceCutover.hasInvalidStoredValue(defaults: defaults) &&
            (cutover == nil || policy.therapyDataSource == .none)
    }

    func snapshot(at date: Date = .now, external: AIDStatus? = nil, historical: Bool = false) -> TherapyMetricsSnapshot {
        let policy = UserDefaults.standard.dataFlowPolicy
        guard Self.cutoverPolicyIsConsistent(policy,
            cutover: TreatmentSourceCutover.current()) else {
            let unavailable = TherapyMetricState(amount: nil, source: .local,
                referenceDate: date, reason: .readFailed)
            return TherapyMetricsSnapshot(iob: unavailable, cob: unavailable)
        }
        let settings = TherapyModelSettings(defaults: .standard)
        let status = historical ? external : externalStatus?() ?? external
        let needsInputs = policy.externalIOBSource == nil || policy.externalCOBSource == nil
        let currentDate = Date()
        let window = TherapyModelSettings.visibilityInterval
        // A child-context save can precede its asynchronous persistent-store save. Until the
        // latter commits, cached inputs describe the old treatment set and cannot confirm Home.
        lock.lock(); let pendingCommit = pendingTreatmentCommit; lock.unlock()
        let entries: [TherapyTreatment]? = needsInputs
            ? (pendingCommit ? nil : treatments(from: date.addingTimeInterval(-window),
                to: min(currentDate, date.addingTimeInterval(window)), policy: policy, settings: settings))
            : []
        let recentEntries: [TherapyTreatment]? = needsInputs && historical
            ? (pendingCommit ? nil : treatments(from: currentDate.addingTimeInterval(-window),
                to: currentDate, policy: policy, settings: settings))
            : []
        return Self.resolve(at: date, external: status, policy: policy, settings: settings, entries: entries,
            currentDate: currentDate, recentEntries: recentEntries,
            localIOBAvailable: !HealthKitTherapyImportManager.shared.localInputIsIncomplete(.insulin),
            localCOBAvailable: !HealthKitTherapyImportManager.shared.localInputIsIncomplete(.carbohydrates))
    }

    static func resolve(at date: Date, external status: AIDStatus?, policy: DataFlowPolicy, settings: TherapyModelSettings, entries: [TherapyTreatment]?, currentDate: Date? = nil, recentEntries: [TherapyTreatment]? = [], localIOBAvailable: Bool = true, localCOBAvailable: Bool = true) -> TherapyMetricsSnapshot {
        var result = TherapyMetricsSnapshot.external(status, at: date)
        // Ownership is configured capability, even when a poll has returned no status at all.
        if let source = policy.externalIOBSource {
            result.iob.source = source
            if status == nil { result.iob.reason = .missingExternalData }
        }
        if let source = policy.externalCOBSource {
            result.cob.source = source
            if status == nil { result.cob.reason = .missingExternalData }
        }
        if policy.externalIOBSource == nil {
            result.iob = Self.localMetric(entries: localIOBAvailable ? entries : nil, isIOB: true, date: date, settings: settings, currentDate: currentDate, recentEntries: localIOBAvailable ? recentEntries : nil)
        }
        if policy.externalCOBSource == nil {
            result.cob = Self.localMetric(entries: localCOBAvailable ? entries : nil, isIOB: false, date: date, settings: settings, currentDate: currentDate, recentEntries: localCOBAvailable ? recentEntries : nil)
        }
        return result
    }

    static func localMetric(entries: [TherapyTreatment]?, isIOB: Bool, date: Date, settings: TherapyModelSettings,
                            currentDate: Date? = nil, recentEntries: [TherapyTreatment]? = []) -> TherapyMetricState {
        let currentDate = currentDate ?? date
        let window = TherapyModelSettings.visibilityInterval
        var state = TherapyMetricState(source: .local, referenceDate: date, reason: .noTreatments)
        let validSettings = isIOB ? settings.validInsulin : settings.validCarbs
        let inputsAvailable = entries != nil && recentEntries != nil
        if !validSettings { state.reason = .invalidSettings }
        else if !inputsAvailable { state.reason = .readFailed }
        // A loaded recent window can prove visibility while the historical window is loading.
        // Keep the amount unavailable until both reads complete, never infer zero from a miss.
        // One pass avoids allocating several filtered treatment arrays for every chart sample.
        // Either treatment type enables both metrics, but only matching past entries add amount.
        var deadline: Date?
        var amount = 0.0
        func includeVisibility(_ entry: TherapyTreatment, nearby: Bool) {
            if nearby, abs(entry.date.timeIntervalSince(date)) < window {
                deadline = max(deadline ?? .distantPast, entry.date.addingTimeInterval(window))
            }
            if entry.date > currentDate.addingTimeInterval(-window) {
                let recentDeadline = date.addingTimeInterval(entry.date.addingTimeInterval(window).timeIntervalSince(currentDate))
                deadline = max(deadline ?? .distantPast, recentDeadline)
            }
        }
        for entry in entries ?? [] where entry.amount.isFinite && entry.amount > 0 && entry.date <= currentDate {
            includeVisibility(entry, nearby: true)
            guard validSettings, inputsAvailable, entry.isIOB == isIOB, entry.date <= date, entry.date > date.addingTimeInterval(-window) else { continue }
            let minutes = date.timeIntervalSince(entry.date) / 60
            amount += isIOB
                ? TherapyCalculations.insulinRemaining(units: entry.amount, minutes: minutes, duration: settings.insulinDuration, peak: settings.insulinPeak)
                : TherapyCalculations.carbsRemaining(grams: entry.amount, minutes: minutes,
                    duration: entry.carbohydrateDuration(or: settings.carbDuration))
        }
        for entry in recentEntries ?? [] where entry.amount.isFinite && entry.amount > 0 && entry.date <= currentDate {
            includeVisibility(entry, nearby: false)
        }
        guard let deadline else { return state }
        state.visibilityDeadline = deadline
        guard validSettings, inputsAvailable else { return state }
        state.amount = amount.isFinite ? amount : nil
        state.expiresAt = min(date.addingTimeInterval(TherapyModelSettings.freshnessInterval), deadline)
        state.reason = state.amount?.isFinite == true ? nil : .invalidSettings
        return state
    }

    func treatments(from start: Date, to end: Date, policy: DataFlowPolicy, settings: TherapyModelSettings) -> [TherapyTreatment]? {
        guard let coreDataManager else { return nil }
        guard Self.cutoverPolicyIsConsistent(policy,
            cutover: TreatmentSourceCutover.current()) else { return nil }
        // Hour buckets let 15-second refreshes reuse the same input snapshot, including future entries.
        let from = Date(timeIntervalSince1970: floor(start.timeIntervalSince1970 / 3600) * 3600)
        let to = Date(timeIntervalSince1970: (floor(end.timeIntervalSince1970 / 3600) + 1) * 3600)
        let importer = HealthKitTherapyImportManager.shared
        // A source choice can change eligibility without any Core Data save. Include it in the
        // cache identity so a previously selected source never leaks into a new forecast.
        let cutover = TreatmentSourceCutover.current()
        let sourceSignature = "\(importer.isEnabled(.insulin))-\(importer.selectedSource(.insulin)?.bundleIdentifier ?? "")-" +
            "\(importer.isEnabled(.carbohydrates))-\(importer.selectedSource(.carbohydrates)?.bundleIdentifier ?? "")-" +
            "\(cutover?.cutoff.timeIntervalSince1970 ?? 0)-\(cutover?.insulinSourceBundleID ?? "")-\(cutover?.carbohydrateSourceBundleID ?? "")"
        lock.lock()
        let generation = treatmentRevision
        let cacheKey = "\(generation)-\(policy.therapyDataSource.rawValue)-\(policy.nightscoutFollowType.rawValue)-\(sourceSignature)-\(from)-\(to)"
        let cached = treatmentCache[cacheKey]
        let recentlyFailed = failedReads[cacheKey].map { Date().timeIntervalSince($0) < 60 } ?? false
        if let cached { lock.unlock(); return cached }
        if recentlyFailed { lock.unlock(); return nil }
        if Thread.isMainThread {
            let shouldFetch = pendingReads.count < 8 && pendingReads.insert(cacheKey).inserted
            lock.unlock()
            if shouldFetch {
                inputQueue.async { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let stillNeeded = generation == self.treatmentRevision
                    self.lock.unlock()
                    if stillNeeded { _ = self.treatments(from: start, to: end, policy: policy, settings: settings) }
                    self.lock.lock()
                    self.pendingReads.remove(cacheKey)
                    let current = generation == self.treatmentRevision
                    self.lock.unlock()
                    if current {
                        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.changed, object: self) }
                    }
                }
            }
            // A missing/failed read is unavailable, never a confident zero. Publication
            // is refreshed when the immutable input snapshot arrives.
            return nil
        }
        lock.unlock()
        // Only worker queues wait for Core Data. Failed/pending saves cannot leak
        // optimistic amounts into the display.
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coreDataManager.privateManagedObjectContext.persistentStoreCoordinator
        var result: [TherapyTreatment]?
        context.performAndWait {
            let request = TreatmentEntry.fetchRequest()
            request.predicate = NSPredicate(format: "date >= %@ AND date <= %@ AND (treatmentdeleted == NO OR treatmentdeleted == nil) AND treatmentType IN %@", from as NSDate, to as NSDate, [TreatmentType.Insulin.rawValue, TreatmentType.Carbs.rawValue])
            do {
                let fetched = try context.fetch(request)
                let selectedInsulin = HealthKitTherapyImportManager.shared.selectedSource(.insulin)?.bundleIdentifier
                let selectedCarbs = HealthKitTherapyImportManager.shared.selectedSource(.carbohydrates)?.bundleIdentifier
                let healthInsulinOn = HealthKitTherapyImportManager.shared.isEnabled(.insulin)
                let healthCarbsOn = HealthKitTherapyImportManager.shared.isEnabled(.carbohydrates)
                result = Self.eligibleTreatments(fetched, policy: policy,
                    insulinSource: selectedInsulin, carbsSource: selectedCarbs,
                    insulinEnabled: healthInsulinOn, carbsEnabled: healthCarbsOn,
                    cutover: cutover)
                    .map {
                        TherapyTreatment(date: $0.date, amount: $0.value,
                            isIOB: $0.treatmentType == .Insulin,
                            carbohydrateDurationMinutes: $0.treatmentType == .Carbs
                                ? $0.effectiveCarbohydrateDurationMinutes : nil,
                            knownAt: $0.isAppLocalTreatment ? $0.knownAtForCurrentRevision : nil,
                            createdAt: $0.isAppLocalTreatment ? $0.createdAt : nil,
                            modifiedAt: $0.isAppLocalTreatment ? $0.modifiedAt : nil,
                            isAppLocal: $0.isAppLocalTreatment,
                            stableIdentity: Self.stablePenTreatmentIdentity($0))
                    }
            } catch { result = nil }
        }
        lock.lock()
        defer { lock.unlock() }
        guard generation == treatmentRevision else { return nil }
        if treatmentCache.count > 6 { treatmentCache.removeAll() }
        if failedReads.count > 6 { failedReads.removeAll() }
        treatmentCache[cacheKey] = result
        if result == nil { failedReads[cacheKey] = Date() }
        return result
    }

    private static func stablePenTreatmentIdentity(_ entry: TreatmentEntry) -> String? {
        if let value = entry.localTreatmentUUID, !value.isEmpty { return "local:\(value)" }
        if let value = entry.watchSourceUUID, !value.isEmpty { return "watch:\(value)" }
        if let value = entry.healthKitSampleUUID, !value.isEmpty { return "health:\(value)" }
        if let value = entry.careLinkSourceIdentifier, !value.isEmpty { return "carelink:\(value)" }
        if !entry.id.isEmpty { return "nightscout:\(entry.id)" }
        return nil
    }

    /// Source selection and cross-import precedence are pure so synthetic Core Data tests can
    /// assert that only shared origin identifiers deduplicate. Time and dose are never identity.
    static func eligibleTreatments(_ fetched: [TreatmentEntry], policy: DataFlowPolicy,
                                   insulinSource: String?, carbsSource: String?,
                                   insulinEnabled: Bool, carbsEnabled: Bool,
                                   cutover: TreatmentSourceCutover? = nil) -> [TreatmentEntry] {
        let sourceEligible = fetched.filter { entry in
            guard entry.treatmentType == .Insulin || entry.treatmentType == .Carbs else {
                return false
            }
            guard !entry.treatmentdeleted else { return false }
            if entry.treatmentType == .Carbs && !entry.isConfirmedMeal { return false }
            let careLink = entry.careLinkSourceIdentifier != nil ||
                (entry.nightscoutEventType != nil && entry.enteredBy == "CareLink")
            if let cutover {
                if entry.isHealthKitImported {
                    let kind: HealthTherapyImportKind =
                        entry.treatmentType == .Insulin ? .insulin : .carbohydrates
                    return cutover.permitsImported(eventDate: entry.date, kind: kind,
                        sourceBundleID: entry.healthKitSourceBundleIdentifier)
                }
                return cutover.permitsLocal(eventDate: entry.date,
                    localTreatmentUUID: entry.localTreatmentUUID,
                    watchSourceUUID: entry.watchSourceUUID)
            }
            if careLink { return policy.importsTherapyFromCareLink }
            if entry.isHealthKitImported {
                let selected = entry.treatmentType == .Insulin ? insulinSource : carbsSource
                let enabled = entry.treatmentType == .Insulin ? insulinEnabled : carbsEnabled
                return enabled && selected != nil && entry.healthKitSourceBundleIdentifier == selected
            }
            // Local entries keep a nil remote event type through upload and reconciliation.
            // enteredBy is editable text, not reliable source identity.
            let local = entry.id.isEmpty || entry.nightscoutEventType == nil
            return local || policy.importsTreatmentsFromNightscout
        }
        var higherPriorityIDs: [Int16: Set<String>] = [:]
        for entry in sourceEligible where !entry.isHealthKitImported {
            var ids = [String]()
            if let careLinkID = entry.careLinkSourceIdentifier { ids.append(careLinkID) }
            if !entry.id.isEmpty {
                ids.append(entry.id)
                let suffix = entry.treatmentType.idExtension()
                if entry.id.hasSuffix(suffix) { ids.append(String(entry.id.dropLast(suffix.count))) }
            }
            higherPriorityIDs[entry.treatmentType.rawValue, default: []].formUnion(ids)
        }
        return sourceEligible.filter { entry in
            guard entry.isHealthKitImported else { return true }
            let ids = higherPriorityIDs[entry.treatmentType.rawValue] ?? []
            return ![entry.healthKitExternalUUID, entry.healthKitSyncIdentifier]
                .compactMap { $0 }.contains(where: ids.contains)
        }
    }

    func chart(from start: Date, to end: Date) async -> TherapyChartSeries {
        await chartForHome(from: start, to: end).series
    }

    func chartForHome(from start: Date, to end: Date) async -> TherapyChartLoad {
        let cancellation = TherapyChartCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                chartQueue.async(execute: DispatchWorkItem {
                    continuation.resume(returning: self.buildChart(from: start, to: end, isCancelled: { cancellation.isCancelled }))
                })
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func buildChart(from start: Date, to end: Date, isCancelled: () -> Bool) -> TherapyChartLoad {
        // Serial GCD work does not block Swift concurrency's cooperative executor.
        // Superseded requests leave the queue without fetching or calculating.
        let unavailable = TherapyChartLoad(series: TherapyChartSeries(), inputsComplete: false)
        guard !isCancelled() else { return unavailable }
        guard let coreDataManager else { return unavailable }
        let end = min(end, Date())
        guard start < end else { return unavailable }
        let policy = UserDefaults.standard.dataFlowPolicy
        guard Self.cutoverPolicyIsConsistent(policy,
            cutover: TreatmentSourceCutover.current()) else { return unavailable }
        let settings = TherapyModelSettings(defaults: .standard)
        let cacheKey = "\(key(policy: policy, settings: settings))-\(start.timeIntervalSince1970)-\(floor(end.timeIntervalSince1970 / 300))-\(floor(Date().timeIntervalSince1970 / 60))"
        lock.lock(); let cached = chartCache[cacheKey]; let generation = revision; lock.unlock()
        let needsLocalInputs = policy.externalIOBSource == nil || policy.externalCOBSource == nil
        let localEligibilityComplete = !needsLocalInputs || (!hasUncommittedForecastInputChanges
            && !HealthKitTherapyImportManager.shared.localInputIsIncomplete(.insulin)
            && !HealthKitTherapyImportManager.shared.localInputIsIncomplete(.carbohydrates))
        if let cached, localEligibilityComplete {
            return TherapyChartLoad(series: cached, inputsComplete: true)
        }
        let currentDate = Date()
        let window = TherapyModelSettings.visibilityInterval
        let entries = needsLocalInputs ? treatments(from: start.addingTimeInterval(-window), to: min(currentDate, end.addingTimeInterval(window)), policy: policy, settings: settings) : []
        let recentEntries = needsLocalInputs ? treatments(from: currentDate.addingTimeInterval(-window), to: currentDate, policy: policy, settings: settings) : []
        let localInputsComplete = localEligibilityComplete && (entries != nil && recentEntries != nil)
        let statuses = policy.aidAnalyticsSource.map { source in
            externalHistory.load(key: "\(generation)-\(policy.therapyDataSource.rawValue)-\(policy.nightscoutFollowType.rawValue)",
                from: start.addingTimeInterval(-TherapyModelSettings.externalChartJoinInterval), to: end) { from, to in
                NightscoutDeviceStatusAccessor(coreDataManager: coreDataManager).fetch(fromDate: from, toDate: to)
                    .filter { source.ownsDeviceStatus(with: $0.device) }
            }
        } ?? []
        guard !isCancelled() else { return unavailable }
        let result = Self.chartSeries(entries: entries, statuses: statuses, policy: policy, settings: settings, start: start, end: end, currentDate: currentDate, recentEntries: recentEntries,
            localIOBAvailable: !HealthKitTherapyImportManager.shared.localInputIsIncomplete(.insulin),
            localCOBAvailable: !HealthKitTherapyImportManager.shared.localInputIsIncomplete(.carbohydrates),
            isCancelled: isCancelled)
        guard !isCancelled() else { return unavailable }
        let stillComplete = !needsLocalInputs || (!hasUncommittedForecastInputChanges
            && !HealthKitTherapyImportManager.shared.localInputIsIncomplete(.insulin)
            && !HealthKitTherapyImportManager.shared.localInputIsIncomplete(.carbohydrates))
        lock.lock(); defer { lock.unlock() }
        guard generation == revision else { return unavailable }
        if localInputsComplete && stillComplete {
            if chartCache.count > 6 { chartCache.removeAll() }
            chartCache[cacheKey] = result
        }
        return TherapyChartLoad(series: result, inputsComplete: localInputsComplete && stillComplete)
    }
    static func chartSeries(entries: [TherapyTreatment]?, statuses: [NightscoutDeviceStatusSnapshot], policy: DataFlowPolicy, settings: TherapyModelSettings, start: Date, end: Date, currentDate: Date? = nil, recentEntries: [TherapyTreatment]? = [], localIOBAvailable: Bool = true, localCOBAvailable: Bool = true, isCancelled: () -> Bool = { false }) -> TherapyChartSeries {
        func series(isIOB: Bool) -> [TherapyChartPoint] {
            guard !isCancelled() else { return [] }
            if (isIOB ? policy.externalIOBSource : policy.externalCOBSource) != nil {
                return externalChartPoints(statuses: statuses, isIOB: isIOB, start: start, end: end, isCancelled: isCancelled)
            }
            guard isIOB ? localIOBAvailable : localCOBAvailable else { return [] }
            guard let entries else { return [] }
            var dates = Set([start, end])
            var t = ceil(start.timeIntervalSince1970 / 300) * 300
            while t < end.timeIntervalSince1970 { dates.insert(Date(timeIntervalSince1970: t)); t += 300 }
            for entry in entries {
                guard !isCancelled() else { return [] }
                for offset in [-TherapyModelSettings.visibilityInterval, 0.0,
                    entry.isIOB ? settings.insulinDuration * 60 :
                        (entry.carbohydrateDuration(or: settings.carbDuration) + TherapyModelSettings.carbDelay) * 60,
                    TherapyModelSettings.visibilityInterval] {
                    let boundary = entry.date.addingTimeInterval(offset)
                    for date in [boundary.addingTimeInterval(-0.001), boundary, boundary.addingTimeInterval(0.001)] where date >= start && date <= end { dates.insert(date) }
                }
            }
            var segment = 0, points: [TherapyChartPoint] = []
            for date in dates.sorted() {
                guard !isCancelled() else { return [] }
                let state = Self.localMetric(entries: entries, isIOB: isIOB, date: date, settings: settings, currentDate: currentDate ?? end, recentEntries: recentEntries)
                guard let amount = state.value(at: date) else { segment += 1; continue }
                // Keep the treatment's before/after values at exactly the same time.
                // This draws a vertical jump without anticipating the dose or breaking the line.
                let added = entries.filter {
                    $0.isIOB == isIOB && $0.date == date && $0.amount.isFinite && $0.amount > 0
                }.reduce(0) { $0 + $1.amount }
                let before = max(0, amount - added)
                if added > 0, before != amount {
                    points.append(TherapyChartPoint(date: date, amount: before, segment: segment))
                }
                points.append(TherapyChartPoint(date: date, amount: amount, segment: segment))
            }
            return points
        }
        return TherapyChartSeries(iob: series(isIOB: true), cob: series(isIOB: false))
    }

    /// Status rows may contain only pump/uploader changes. An absent metric does not
    /// invalidate a nearby AID reading. Continuity depends on time between valid readings.
    static func externalChartPoints(statuses: [NightscoutDeviceStatusSnapshot], isIOB: Bool, start: Date, end: Date, isCancelled: () -> Bool = { false }) -> [TherapyChartPoint] {
        guard !isCancelled() else { return [] }
        let freshness = TherapyModelSettings.freshnessInterval
        var values: [Date: Double] = [:]
        for status in statuses.sorted(by: {
            if $0.updatedDate != $1.updatedDate { return $0.updatedDate < $1.updatedDate }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }) {
            guard !isCancelled() else { return [] }
            guard status.createdAt <= end,
                  let amount = isIOB ? status.iob : status.cob, amount.isFinite else { continue }
            // AID systems can upload the same calculation several times with new createdAt
            // values. Plot one point at calculation time, not a staircase of upload times.
            let date: Date
            if let calculatedAt = status.timestamp, calculatedAt > .distantPast,
               calculatedAt <= status.createdAt.addingTimeInterval(60) {
                guard status.createdAt.timeIntervalSince(calculatedAt) < freshness else { continue }
                date = calculatedAt
            } else {
                date = status.createdAt
            }
            guard date <= end else { continue }
            // Keep the latest stored revision of a calculation, independently per metric.
            values[date] = amount
        }
        let dates = values.keys.sorted()
        var points: [TherapyChartPoint] = [], segment = 0
        func append(_ date: Date, _ amount: Double) {
            guard date >= start && date <= end else { return }
            points.append(TherapyChartPoint(date: date, amount: amount, segment: segment))
        }
        for (index, date) in dates.enumerated() {
            guard !isCancelled() else { return [] }
            guard let amount = values[date] else { continue }
            let next = index + 1 < dates.count ? dates[index + 1] : nil
            let joinsNext = next.map { $0.timeIntervalSince(date) < TherapyModelSettings.externalChartJoinInterval } ?? false
            if date < start, (joinsNext || start < date.addingTimeInterval(freshness)), (next.map { $0 > start } ?? true) {
                let boundaryAmount: Double
                if joinsNext, let next, let nextAmount = values[next] {
                    boundaryAmount = amount + (nextAmount - amount) * start.timeIntervalSince(date) / next.timeIntervalSince(date)
                } else {
                    boundaryAmount = amount
                }
                append(start, boundaryAmount)
            }
            append(date, amount)
            if !joinsNext {
                // A fresh isolated reading still has a visible segment. Stop before expiry.
                // Never connect across a genuine outage or extend a frozen value indefinitely.
                let freshEnd = min(end, date.addingTimeInterval(freshness - 0.001))
                if freshEnd > max(date, start) { append(freshEnd, amount) }
                segment += 1
            }
        }
        return points
    }

}

/// A bounded, retained history window. Scrolls append/prepend only missing edges.
/// Source changes, data revisions and disjoint jumps reset it. Owned by the serial chart queue.
struct TherapyStatusHistoryCache {
    private var key: String?
    private var range: ClosedRange<Date>?
    private var records: [String: NightscoutDeviceStatusSnapshot] = [:]

    mutating func load(key: String, from start: Date, to end: Date,
                       fetch: (Date, Date) -> [NightscoutDeviceStatusSnapshot]) -> [NightscoutDeviceStatusSnapshot] {
        guard start <= end else { return [] }
        let request = start...end
        if self.key != key || range.map({ !$0.overlaps(request) }) ?? true {
            records.removeAll()
            range = nil
            self.key = key
        }
        var missing: [(Date, Date)] = []
        if let range {
            if start < range.lowerBound { missing.append((start, range.lowerBound)) }
            if end > range.upperBound { missing.append((range.upperBound, end)) }
        } else {
            missing.append((start, end))
        }
        for (from, to) in missing {
            for record in fetch(from, to) { records[record.id] = record }
        }
        let lower = min(range?.lowerBound ?? start, start)
        let upper = max(range?.upperBound ?? end, end)
        let buffer = min(max(end.timeIntervalSince(start) * 0.5, 3600), 24 * 3600)
        let retained = max(lower, start.addingTimeInterval(-buffer))...min(upper, end.addingTimeInterval(buffer))
        records = records.filter { retained.contains($0.value.createdAt) }
        range = retained
        return records.values.filter { request.contains($0.createdAt) }
    }
}

/// Cancellation crosses the task and serial worker queues without retaining a task's closure.
final class TherapyChartCancellation: @unchecked Sendable {
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
