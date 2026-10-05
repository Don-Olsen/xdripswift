import CoreData
import Foundation
import HealthKit
import UIKit

/// Health therapy import is deliberately separate from glucose export and local therapy writing.
/// Import callbacks never write therapy back to Health.
enum HealthTherapyImportKind: String, CaseIterable {
    case insulin
    case carbohydrates

    var quantityIdentifier: HKQuantityTypeIdentifier {
        self == .insulin ? .insulinDelivery : .dietaryCarbohydrates
    }

    var unit: HKUnit {
        self == .insulin ? .internationalUnit() : .gram()
    }

    var treatmentType: TreatmentType {
        self == .insulin ? .Insulin : .Carbs
    }

    var exportKind: HealthKitExportKind {
        self == .insulin ? .insulin : .carbohydrates
    }
}

struct HealthTherapyImportSource: Equatable {
    let bundleIdentifier: String
    let name: String

    var isMySugr: Bool {
        name.localizedCaseInsensitiveContains("mysugr") ||
            bundleIdentifier.localizedCaseInsensitiveContains("mysugr")
    }
}

/// A stable namespace keeps our writes out of imported therapy, including after reinstall.
enum HealthLocalTherapyIdentity {
    static let syncPrefix = "xdrip.therapy."

    static func isOwn(sourceBundleID: String, syncIdentifier: String?,
                      appBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        (appBundleID != nil && sourceBundleID == appBundleID) ||
            (syncIdentifier?.hasPrefix(syncPrefix) == true)
    }
}

struct HealthTherapyImportStatus {
    let lastSync: Date?
    let message: String
    let isIncomplete: Bool
}

/// One durable source boundary shared by the live therapy calculation and historical replay.
/// The event time, not the time a backdated entry was saved, selects its source. A single
/// encoded value prevents a crash from persisting a cutoff without its source identities.
struct TreatmentSourceCutover: Codable, Equatable, Sendable {
    static let defaultsKey = "localTreatmentSourceCutover.v1"
    static let restoreRequiresSourceSetupKey = "therapyRestoreRequiresSourceSetup"
    let cutoff: Date
    let insulinSourceBundleID: String
    let carbohydrateSourceBundleID: String

    static func current(defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.cutoff.isFiniteDate,
              !value.insulinSourceBundleID.isEmpty,
              !value.carbohydrateSourceBundleID.isEmpty else { return nil }
        return value
    }

    /// A damaged stored boundary must never be interpreted as "no cutover".
    static func hasInvalidStoredValue(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) != nil && current(defaults: defaults) == nil
    }

    static func hasStoredValue(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: defaultsKey) != nil
    }

    @discardableResult
    static func persist(_ value: Self, defaults: UserDefaults = .standard) -> Bool {
        guard value.cutoff.isFiniteDate,
              !value.insulinSourceBundleID.isEmpty,
              !value.carbohydrateSourceBundleID.isEmpty,
              defaults.object(forKey: defaultsKey) == nil,
              let encoded = try? JSONEncoder().encode(value) else { return false }
        defaults.set(encoded, forKey: defaultsKey)
        return current(defaults: defaults) == value
    }

    func permitsImported(eventDate: Date, kind: HealthTherapyImportKind,
                         sourceBundleID: String?) -> Bool {
        guard eventDate.isFiniteDate, eventDate < cutoff else { return false }
        return sourceBundleID == (kind == .insulin ? insulinSourceBundleID : carbohydrateSourceBundleID)
    }

    func permitsLocal(eventDate: Date, localTreatmentUUID: String?,
                      watchSourceUUID: String?) -> Bool {
        eventDate.isFiniteDate && eventDate >= cutoff &&
            ((localTreatmentUUID?.isEmpty == false) || (watchSourceUUID?.isEmpty == false))
    }
}

private extension Date {
    var isFiniteDate: Bool { timeIntervalSinceReferenceDate.isFinite }
}

/// Presentation-only proof for a routine anchored reread. Calculations must continue to use
/// `localInputIsIncomplete`; this never makes a partial page or pending save authoritative.
struct HealthTherapyRoutineRefreshState {
    let generation: Int
    let startedAt: Date
    let allEnabledKindsCommitted: Bool
}

/// Value-only query data allows the import and persistence rules to be tested without a real
/// Health database. HealthKit objects never leave the query adapter.
struct HealthTherapyIncomingSample {
    let uuid: UUID
    let kind: HealthTherapyImportKind
    let source: HealthTherapyImportSource
    let startDate: Date
    let endDate: Date
    let quantity: Double
    let insulinReason: Int?
    let hasUndeterminedDuration: Bool
    let sampleCount: Int
    let externalUUID: String?
    let syncIdentifier: String?

    var classification: String {
        guard quantity.isFinite, quantity > 0 else { return "invalid" }
        // Basal metadata is decisive even when a pump records a delivery interval. It is
        // retained for provenance but never represented as a bolus treatment.
        if kind == .insulin && insulinReason == HKInsulinDeliveryReason.basal.rawValue {
            return "basal"
        }
        guard startDate == endDate, !hasUndeterminedDuration, sampleCount == 1 else {
            return "ambiguousInterval"
        }
        if kind == .carbohydrates { return "carbohydrates" }
        switch insulinReason {
        case HKInsulinDeliveryReason.bolus.rawValue: return "bolus"
        default: return "unclassifiedInsulin"
        }
    }

    var contributesToTherapy: Bool {
        classification == "bolus" || classification == "carbohydrates"
    }
}

struct HealthTherapyImportPage {
    let samples: [HealthTherapyIncomingSample]
    let deletedUUIDs: [UUID]
    /// Opaque, securely archived HKQueryAnchor. Tests use an opaque synthetic value.
    let nextAnchor: Data
    let hasMore: Bool
}

protocol HealthTherapyQuerying: AnyObject {
    func requestReadAuthorization(for kind: HealthTherapyImportKind, completion: @escaping (Error?) -> Void)
    func discoverSources(for kind: HealthTherapyImportKind,
                         completion: @escaping ([HealthTherapyImportSource], Error?) -> Void)
    func page(for kind: HealthTherapyImportKind, since: Date, anchor: Data?, limit: Int,
              completion: @escaping (Result<HealthTherapyImportPage, Error>) -> Void)
    func observe(_ kind: HealthTherapyImportKind,
                 onChange: @escaping (@escaping () -> Void) -> Void)
    func stopObserving(_ kind: HealthTherapyImportKind)
}

extension HealthTherapyQuerying {
    func stopObserving(_ kind: HealthTherapyImportKind) {}
}

/// Only this adapter touches the live Health database. It observes each enabled type, then
/// drains anchored pages; observer callbacks do not themselves represent stored treatments.
final class LiveHealthTherapyQuery: HealthTherapyQuerying {
    private let healthStore = HKHealthStore()
    private var observers: [HealthTherapyImportKind: HKObserverQuery] = [:]

    func requestReadAuthorization(for kind: HealthTherapyImportKind, completion: @escaping (Error?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable(),
              HKObjectType.quantityType(forIdentifier: kind.quantityIdentifier) != nil else {
            completion(HealthTherapyImportError.unavailable)
            return
        }
        // A successful dialog is NOT proof of read authorization. Apple intentionally does not
        // disclose whether the user granted read access to a particular sample type.
        HealthKitPhoneAuthorizationCenter.shared.request { _, error in
            completion(error)
        }
    }

    func discoverSources(for kind: HealthTherapyImportKind,
                         completion: @escaping ([HealthTherapyImportSource], Error?) -> Void) {
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.quantityType(forIdentifier: kind.quantityIdentifier) else {
            completion([], HealthTherapyImportError.unavailable)
            return
        }
        let query = HKSourceQuery(sampleType: type, samplePredicate: nil) { _, sources, error in
            let values = (sources ?? []).map {
                HealthTherapyImportSource(bundleIdentifier: $0.bundleIdentifier, name: $0.name)
            }.filter { !$0.bundleIdentifier.isEmpty }
                .sorted { ($0.name, $0.bundleIdentifier) < ($1.name, $1.bundleIdentifier) }
            completion(values, error)
        }
        healthStore.execute(query)
    }

    func page(for kind: HealthTherapyImportKind, since: Date, anchor data: Data?, limit: Int,
              completion: @escaping (Result<HealthTherapyImportPage, Error>) -> Void) {
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.quantityType(forIdentifier: kind.quantityIdentifier) else {
            completion(.failure(HealthTherapyImportError.unavailable))
            return
        }
        let anchor: HKQueryAnchor?
        if let data {
            do {
                anchor = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
                guard anchor != nil else { throw HealthTherapyImportError.invalidAnchor }
            } catch {
                completion(.failure(HealthTherapyImportError.invalidAnchor))
                return
            }
        } else {
            anchor = nil
        }
        // Keep the same initial history boundary with every anchor. The query is unfiltered by
        // source so switching the selected source cannot skip additions or deletion UUIDs.
        let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: .strictStartDate)
        let query = HKAnchoredObjectQuery(type: type, predicate: predicate, anchor: anchor,
                                          limit: limit) { _, added, deleted, nextAnchor, error in
            if let error { completion(.failure(error)); return }
            guard let nextAnchor,
                  let nextData = try? NSKeyedArchiver.archivedData(withRootObject: nextAnchor,
                                                                   requiringSecureCoding: true) else {
                completion(.failure(HealthTherapyImportError.invalidAnchor))
                return
            }
            let samples = (added ?? []).compactMap { object -> HealthTherapyIncomingSample? in
                guard let sample = object as? HKQuantitySample else { return nil }
                return HealthTherapyIncomingSample(
                    uuid: sample.uuid,
                    kind: kind,
                    source: HealthTherapyImportSource(
                        bundleIdentifier: sample.sourceRevision.source.bundleIdentifier,
                        name: sample.sourceRevision.source.name
                    ),
                    startDate: sample.startDate,
                    endDate: sample.endDate,
                    quantity: sample.quantity.doubleValue(for: kind.unit),
                    insulinReason: (sample.metadata?[HKMetadataKeyInsulinDeliveryReason] as? NSNumber)?.intValue,
                    hasUndeterminedDuration: sample.hasUndeterminedDuration,
                    sampleCount: sample.count,
                    externalUUID: sample.metadata?[HKMetadataKeyExternalUUID] as? String,
                    syncIdentifier: sample.metadata?[HKMetadataKeySyncIdentifier] as? String
                )
            }
            completion(.success(HealthTherapyImportPage(
                samples: samples,
                deletedUUIDs: (deleted ?? []).map(\.uuid),
                nextAnchor: nextData,
                hasMore: (added?.count ?? 0) + (deleted?.count ?? 0) >= limit
            )))
        }
        healthStore.execute(query)
    }

    func observe(_ kind: HealthTherapyImportKind,
                 onChange: @escaping (@escaping () -> Void) -> Void) {
        guard observers[kind] == nil,
              HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.quantityType(forIdentifier: kind.quantityIdentifier) else { return }
        let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
            if error == nil { onChange(completion) } else { completion() }
        }
        observers[kind] = query
        healthStore.execute(query)
        // Failure to obtain background delivery does not disable foreground/startup catch-up.
        healthStore.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
    }

    func stopObserving(_ kind: HealthTherapyImportKind) {
        if let observer = observers.removeValue(forKey: kind) { healthStore.stop(observer) }
        if let type = HKObjectType.quantityType(forIdentifier: kind.quantityIdentifier) {
            healthStore.disableBackgroundDelivery(for: type) { _, _ in }
        }
    }
}

enum HealthTherapyImportError: Error {
    case unavailable
    case invalidAnchor
    case storeFailure
    case notConfigured
    case finalSyncIncomplete
    case switchAlreadyRunning
}

/// Serializes each type's anchored pages and advances its checkpoint only after Core Data has
/// committed both the sample ledger and eligible TreatmentEntry rows to the parent store.
final class HealthKitTherapyImportManager {
    static let shared = HealthKitTherapyImportManager(query: LiveHealthTherapyQuery(), defaults: .standard)
    static let statusDidChange = Notification.Name("HealthKitTherapyImportStatusDidChange")
    static let pageLimit = 200
    private static let keyPrefix = "healthTherapyImport.v1."

    private let query: HealthTherapyQuerying
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "health.therapy.import", qos: .utility)
    private var coreDataManager: CoreDataManager?
    private var active = Set<HealthTherapyImportKind>()
    private var pending = Set<HealthTherapyImportKind>()
    private let presentationLock = NSLock()
    private struct RoutineRefresh {
        let generation: Int
        let startedAt: Date
        let sources: [HealthTherapyImportKind: String]
        let lastSyncs: [HealthTherapyImportKind: Date]
        var waitingFor: Set<HealthTherapyImportKind>
    }
    private var routineRefresh: RoutineRefresh?
    private var nextRoutineRefreshGeneration = 0
    private var observerInstalled = Set<HealthTherapyImportKind>()
    private var observerCompletions: [HealthTherapyImportKind: [() -> Void]] = [:]
    private var cutoverCompletion: ((Error?) -> Void)?
    private var cutoverWaitingFor = Set<HealthTherapyImportKind>()
    private var cutoverSources: [HealthTherapyImportKind: String] = [:]
    /// Injected only by isolated tests to fail one parent-store save at a precise boundary.
    var saveImportedPage: ((CoreDataManager, @escaping (Bool) -> Void) -> Void)?

    init(query: HealthTherapyQuerying, defaults: UserDefaults) {
        self.query = query
        self.defaults = defaults
    }

    func configure(coreDataManager: CoreDataManager) {
        if self === Self.shared {
            HealthKitLocalTherapyWriter.shared.configure(coreDataManager: coreDataManager)
        }
        queue.async {
            self.coreDataManager = coreDataManager
            for kind in HealthTherapyImportKind.allCases where self.isEnabled(kind) {
                self.installObserver(kind)
                self.startSync(kind)
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(retryEnabledImports),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(retryEnabledImports),
                                               name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
    }

    func isEnabled(_ kind: HealthTherapyImportKind) -> Bool {
        !TreatmentSourceCutover.hasStoredValue(defaults: defaults) &&
            defaults.bool(forKey: key(kind, "enabled"))
    }

    /// Finish both selected-source reads and their durable Core Data commits before moving the
    /// event-time boundary. If either type fails, keep both imports active and report failure.
    func switchToLocalLogging(completion: @escaping (Error?) -> Void) {
        queue.async {
            guard !TreatmentSourceCutover.hasInvalidStoredValue(defaults: self.defaults) else {
                DispatchQueue.main.async { completion(HealthTherapyImportError.storeFailure) }
                return
            }
            guard TreatmentSourceCutover.current(defaults: self.defaults) == nil else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            guard self.cutoverCompletion == nil else {
                DispatchQueue.main.async { completion(HealthTherapyImportError.switchAlreadyRunning) }
                return
            }
            guard self.coreDataManager != nil,
                  self.isEnabled(.insulin), self.isEnabled(.carbohydrates),
                  let insulinSource = self.selectedSource(.insulin), insulinSource.isMySugr,
                  let carbohydrateSource = self.selectedSource(.carbohydrates),
                  carbohydrateSource.isMySugr else {
                DispatchQueue.main.async { completion(HealthTherapyImportError.notConfigured) }
                return
            }
            let insulin = insulinSource.bundleIdentifier
            let carbohydrates = carbohydrateSource.bundleIdentifier
            self.cutoverCompletion = completion
            self.cutoverWaitingFor = Set(HealthTherapyImportKind.allCases)
            self.cutoverSources = [.insulin: insulin, .carbohydrates: carbohydrates]
            self.queue.asyncAfter(deadline: .now() + 60) {
                if self.cutoverCompletion != nil {
                    self.finishCutover(error: HealthTherapyImportError.finalSyncIncomplete)
                }
            }
            // An already running query is queued for another pass. This is essential when the
            // user presses the switch during a partially saved anchored import.
            for kind in HealthTherapyImportKind.allCases { self.startSync(kind) }
        }
    }

    private func finishCutover(error: Error?) {
        let completion = cutoverCompletion
        cutoverCompletion = nil
        cutoverWaitingFor.removeAll()
        cutoverSources.removeAll()
        DispatchQueue.main.async { completion?(error) }
    }

    func selectedSource(_ kind: HealthTherapyImportKind) -> HealthTherapyImportSource? {
        guard let id = defaults.string(forKey: key(kind, "sourceBundleID")), !id.isEmpty else { return nil }
        return HealthTherapyImportSource(bundleIdentifier: id,
            name: defaults.string(forKey: key(kind, "sourceName")) ?? id)
    }

    /// The existing bounded-import cutoff, exposed read-only for historical coverage checks.
    func historyStart(_ kind: HealthTherapyImportKind) -> Date? {
        defaults.object(forKey: key(kind, "historyStart")) as? Date
    }

    func discoveredSources(_ kind: HealthTherapyImportKind,
                           completion: @escaping ([HealthTherapyImportSource], Error?) -> Void) {
        query.discoverSources(for: kind, completion: completion)
    }

    func setEnabled(_ enabled: Bool, kind: HealthTherapyImportKind,
                    completion: @escaping (Error?) -> Void) {
        if enabled && TreatmentSourceCutover.hasStoredValue(defaults: defaults) {
            completion(HealthTherapyImportError.notConfigured)
            return
        }
        guard enabled else {
            defaults.set(false, forKey: key(kind, "enabled"))
            defaults.removeObject(forKey: key(kind, "syncInProgress"))
            presentationLock.lock()
            routineRefresh = nil
            presentationLock.unlock()
            queue.async {
                if self.observerInstalled.remove(kind) != nil { self.query.stopObserving(kind) }
            }
            TherapyMetricsManager.shared.invalidate()
            notifyStatusChanged()
            completion(nil)
            return
        }
        query.requestReadAuthorization(for: kind) { error in
            guard error == nil else {
                self.setStatus(kind, message: "Health data is unavailable; retry in Settings.")
                completion(error)
                return
            }
            if self.selectedSource(kind) != nil {
                self.defaults.set(true, forKey: self.key(kind, "syncInProgress"))
            }
            self.defaults.set(true, forKey: self.key(kind, "enabled"))
            self.defaults.removeObject(forKey: self.key(kind, "error"))
            self.queue.async {
                self.installObserver(kind)
                self.startSync(kind)
            }
            TherapyMetricsManager.shared.invalidate()
            self.notifyStatusChanged()
            completion(nil)
        }
    }

    func selectSource(_ source: HealthTherapyImportSource, kind: HealthTherapyImportKind) {
        guard !TreatmentSourceCutover.hasStoredValue(defaults: defaults) else { return }
        guard !source.bundleIdentifier.isEmpty else { return }
        presentationLock.lock()
        routineRefresh = nil
        presentationLock.unlock()
        defaults.set(source.bundleIdentifier, forKey: key(kind, "sourceBundleID"))
        defaults.set(source.name, forKey: key(kind, "sourceName"))
        defaults.removeObject(forKey: key(kind, "observedSelectedSource"))
        defaults.removeObject(forKey: key(kind, "hasAmbiguousSelectedSource"))
        defaults.removeObject(forKey: key(kind, "error"))
        if isEnabled(kind) { defaults.set(true, forKey: key(kind, "syncInProgress")) }
        queue.async {
            self.startSync(kind)
        }
        TherapyMetricsManager.shared.invalidate()
        notifyStatusChanged()
    }

    func status(_ kind: HealthTherapyImportKind) -> HealthTherapyImportStatus {
        let lastSync = defaults.object(forKey: key(kind, "lastSync")) as? Date
        guard isEnabled(kind) else { return .init(lastSync: lastSync, message: "Import off", isIncomplete: false) }
        guard selectedSource(kind) != nil else {
            return .init(lastSync: lastSync, message: "Choose a Health data source to start importing.", isIncomplete: true)
        }
        if let error = defaults.string(forKey: key(kind, "error")) {
            return .init(lastSync: lastSync, message: error, isIncomplete: true)
        }
        if defaults.bool(forKey: key(kind, "syncInProgress")) {
            return .init(lastSync: lastSync,
                message: "Reading Apple Health; values may be incomplete until every page is saved.",
                isIncomplete: true)
        }
        if lastSync == nil {
            return .init(lastSync: nil, message: "Waiting for first import; data completeness is unknown.", isIncomplete: true)
        }
        if let lastSync, Date().timeIntervalSince(lastSync) > TherapyModelSettings.visibilityInterval {
            return .init(lastSync: lastSync,
                message: "The last Health sync is old. Existing values may be incomplete until the next successful read.",
                isIncomplete: true)
        }
        if defaults.bool(forKey: key(kind, "hasAmbiguousSelectedSource")) {
            return .init(lastSync: lastSync,
                message: "Some Health entries have unclear dose type, interval or amount and are excluded from the calculation.",
                isIncomplete: true)
        }
        if !defaults.bool(forKey: key(kind, "observedSelectedSource")) {
            return .init(lastSync: lastSync,
                message: "No matching records found. Apple Health does not reveal whether read access is complete.",
                isIncomplete: true)
        }
        return .init(lastSync: lastSync,
            message: "Imported recorded treatments. Apple Health does not disclose complete read access.",
            isIncomplete: false)
    }

    /// A failed read or missing selected source cannot be treated as a confident zero in local
    /// IOB/COB. The external source policy remains owned by TherapyMetricsManager.
    func localInputIsIncomplete(_ kind: HealthTherapyImportKind) -> Bool {
        isEnabled(kind) && status(kind).isIncomplete
    }

    /// A fixed 30-second Home display window. Its source and completeness proof is captured
    /// before the first read starts, and callbacks cannot move the deadline forward.
    func routineRefreshState(at now: Date = Date()) -> HealthTherapyRoutineRefreshState? {
        presentationLock.lock()
        let refresh = routineRefresh
        presentationLock.unlock()
        guard let refresh, (0..<30).contains(now.timeIntervalSince(refresh.startedAt)) else { return nil }
        for (kind, source) in refresh.sources {
            guard isEnabled(kind), selectedSource(kind)?.bundleIdentifier == source,
                  defaults.string(forKey: key(kind, "error")) == nil,
                  !defaults.bool(forKey: key(kind, "hasAmbiguousSelectedSource")),
                  defaults.bool(forKey: key(kind, "observedSelectedSource")),
                  let priorSync = refresh.lastSyncs[kind],
                  let currentSync = defaults.object(forKey: key(kind, "lastSync")) as? Date,
                  currentSync >= priorSync,
                  now.timeIntervalSince(priorSync) >= 0,
                  now.timeIntervalSince(priorSync) <= TherapyModelSettings.visibilityInterval,
                  now.timeIntervalSince(currentSync) >= 0,
                  now.timeIntervalSince(currentSync) <= TherapyModelSettings.visibilityInterval else { return nil }
        }
        let enabled = Set(HealthTherapyImportKind.allCases.filter(isEnabled))
        guard enabled == Set(refresh.sources.keys) else { return nil }
        return HealthTherapyRoutineRefreshState(generation: refresh.generation,
            startedAt: refresh.startedAt, allEnabledKindsCommitted: refresh.waitingFor.isEmpty)
    }

    @objc private func retryEnabledImports() {
        queue.async {
            for kind in HealthTherapyImportKind.allCases where self.isEnabled(kind) {
                self.installObserver(kind)
                self.startSync(kind)
            }
        }
    }

    private func key(_ kind: HealthTherapyImportKind, _ suffix: String) -> String {
        Self.keyPrefix + kind.rawValue + "." + suffix
    }

    private func notifyStatusChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.statusDidChange, object: self)
        }
    }

    private func setStatus(_ kind: HealthTherapyImportKind, message: String?) {
        if let message { defaults.set(message, forKey: key(kind, "error")) }
        else { defaults.removeObject(forKey: key(kind, "error")) }
        if message != nil {
            presentationLock.lock()
            routineRefresh = nil
            presentationLock.unlock()
        }
        TherapyMetricsManager.shared.publishStatusChange()
        notifyStatusChanged()
    }

    private func installObserver(_ kind: HealthTherapyImportKind) {
        guard observerInstalled.insert(kind).inserted else { return }
        query.observe(kind) { completion in
            self.queue.async {
                self.observerCompletions[kind, default: []].append(completion)
                // A Home snapshot contains both local metrics. Drain both enabled kinds for
                // one coherent completion even if Health notified only one sample type.
                for enabledKind in HealthTherapyImportKind.allCases where self.isEnabled(enabledKind) {
                    self.startSync(enabledKind)
                }
            }
        }
    }

    private func beginRoutineRefreshIfEligible(_ kind: HealthTherapyImportKind, at now: Date) {
        presentationLock.lock()
        if var existing = routineRefresh,
           (0..<30).contains(now.timeIntervalSince(existing.startedAt)) {
            existing.waitingFor.insert(kind)
            routineRefresh = existing
            presentationLock.unlock()
            return
        }
        presentationLock.unlock()
        let enabled = HealthTherapyImportKind.allCases.filter(isEnabled)
        guard !enabled.isEmpty, enabled.allSatisfy({ !status($0).isIncomplete }) else { return }
        let sources = Dictionary(uniqueKeysWithValues: enabled.compactMap { value in
            selectedSource(value).map { (value, $0.bundleIdentifier) }
        })
        let lastSyncs = Dictionary(uniqueKeysWithValues: enabled.compactMap { value in
            status(value).lastSync.map { (value, $0) }
        })
        guard sources.count == enabled.count, lastSyncs.count == enabled.count else { return }
        presentationLock.lock()
        nextRoutineRefreshGeneration &+= 1
        routineRefresh = RoutineRefresh(generation: nextRoutineRefreshGeneration, startedAt: now,
            sources: sources, lastSyncs: lastSyncs, waitingFor: Set(enabled))
        presentationLock.unlock()
    }

    private func startSync(_ kind: HealthTherapyImportKind) {
        guard isEnabled(kind), selectedSource(kind) != nil else {
            finishObserverCallbacks(kind)
            return
        }
        guard coreDataManager != nil else {
            setStatus(kind, message: "Local treatment store is not ready; import will retry.")
            finishObserverCallbacks(kind)
            return
        }
        guard active.insert(kind).inserted else { pending.insert(kind); return }
        beginRoutineRefreshIfEligible(kind, at: Date())
        defaults.set(true, forKey: key(kind, "syncInProgress"))
        defaults.removeObject(forKey: key(kind, "error"))
        TherapyMetricsManager.shared.publishStatusChange()
        notifyStatusChanged()
        let startKey = key(kind, "historyStart")
        let since: Date
        if let saved = defaults.object(forKey: startKey) as? Date {
            since = saved
        } else {
            since = Date().addingTimeInterval(-TherapyModelSettings.visibilityInterval)
            defaults.set(since, forKey: startKey)
        }
        // A selected source may already have pages in the unfiltered ledger. Reconstructing
        // eligible treatments before each anchored read also repairs a crashed source switch.
        materializeSelectedSource(kind) { saved in
            self.queue.async {
                guard saved else {
                    self.setStatus(kind, message: "Local storage failed. Import will retry without moving its checkpoint.")
                    self.complete(kind, succeeded: false)
                    return
                }
                guard self.isEnabled(kind) else { self.complete(kind, succeeded: false); return }
                self.drain(kind, since: since)
            }
        }
    }

    private func drain(_ kind: HealthTherapyImportKind, since: Date) {
        let anchor = defaults.data(forKey: key(kind, "anchor"))
        query.page(for: kind, since: since, anchor: anchor, limit: Self.pageLimit) { result in
            self.queue.async {
                guard self.isEnabled(kind) else { self.complete(kind, succeeded: false); return }
                switch result {
                case let .failure(error):
                    if case HealthTherapyImportError.invalidAnchor = error, anchor != nil {
                        // A corrupt/obsolete archived anchor can be discarded safely because
                        // Health UUIDs in the committed ledger make the bounded replay idempotent.
                        self.defaults.removeObject(forKey: self.key(kind, "anchor"))
                        self.drain(kind, since: since)
                        return
                    }
                    self.setStatus(kind, message: "Apple Health could not be read. Existing values may be incomplete; import will retry.")
                    self.complete(kind, succeeded: false)
                case let .success(page):
                    self.persist(page, kind: kind) { saved in
                        self.queue.async {
                            guard saved else {
                                self.setStatus(kind, message: "Local storage failed. Import will retry without moving its checkpoint.")
                                self.complete(kind, succeeded: false)
                                return
                            }
                            guard self.isEnabled(kind) else { self.complete(kind, succeeded: false); return }
                            self.defaults.set(page.nextAnchor, forKey: self.key(kind, "anchor"))
                            if page.hasMore {
                                self.drain(kind, since: since)
                            } else {
                                // A page is durable before its anchor advances. Only the final
                                // page certifies that the current catch-up reached its end.
                                self.defaults.set(Date(), forKey: self.key(kind, "lastSync"))
                                self.defaults.removeObject(forKey: self.key(kind, "syncInProgress"))
                                self.setStatus(kind, message: nil)
                                self.complete(kind, succeeded: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func complete(_ kind: HealthTherapyImportKind, succeeded: Bool) {
        presentationLock.lock()
        if var refresh = routineRefresh {
            if succeeded {
                if !pending.contains(kind) { refresh.waitingFor.remove(kind) }
                routineRefresh = refresh
            } else {
                routineRefresh = nil
            }
        }
        presentationLock.unlock()
        active.remove(kind)
        finishObserverCallbacks(kind)
        if cutoverCompletion != nil && !succeeded {
            finishCutover(error: HealthTherapyImportError.finalSyncIncomplete)
        }
        if pending.remove(kind) != nil {
            startSync(kind)
            return
        }
        if cutoverCompletion != nil {
            guard selectedSource(kind)?.bundleIdentifier == cutoverSources[kind] else {
                finishCutover(error: HealthTherapyImportError.finalSyncIncomplete)
                notifyStatusChanged()
                return
            }
            cutoverWaitingFor.remove(kind)
            if cutoverWaitingFor.isEmpty {
                guard HealthTherapyImportKind.allCases.allSatisfy({ selectedSource($0)?.bundleIdentifier == cutoverSources[$0] }) else {
                    finishCutover(error: HealthTherapyImportError.finalSyncIncomplete)
                    notifyStatusChanged()
                    return
                }
                guard HealthTherapyImportKind.allCases.allSatisfy({ !status($0).isIncomplete }) else {
                    finishCutover(error: HealthTherapyImportError.finalSyncIncomplete)
                    notifyStatusChanged()
                    return
                }
                let candidate = TreatmentSourceCutover(
                    cutoff: Date(),
                    insulinSourceBundleID: cutoverSources[.insulin] ?? "",
                    carbohydrateSourceBundleID: cutoverSources[.carbohydrates] ?? "")
                // Local logging must never coexist with an effective external IOB/COB owner.
                // Set local therapy ownership first: a crash here still leaves the selected
                // mySugr imports active, whereas the inverse order could hide local metrics.
                let priorTherapySource = defaults.therapyDataSourceType
                defaults.therapyDataSourceType = .none
                guard TreatmentSourceCutover.persist(candidate, defaults: defaults) else {
                    defaults.therapyDataSourceType = priorTherapySource
                    finishCutover(error: HealthTherapyImportError.storeFailure)
                    notifyStatusChanged()
                    return
                }
                // The single cutover blob already disables effective importing, even if the
                // process stops before both legacy enabled preferences are cleared.
                for stoppedKind in HealthTherapyImportKind.allCases {
                    defaults.set(false, forKey: key(stoppedKind, "enabled"))
                    defaults.removeObject(forKey: key(stoppedKind, "syncInProgress"))
                    if observerInstalled.remove(stoppedKind) != nil { query.stopObserving(stoppedKind) }
                }
                defaults.removeObject(forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey)
                TherapyMetricsManager.shared.invalidate()
                finishCutover(error: nil)
                HealthKitLocalTherapyWriter.shared.retryPending()
            }
        }
        notifyStatusChanged()
    }

    private func finishObserverCallbacks(_ kind: HealthTherapyImportKind) {
        let callbacks = observerCompletions.removeValue(forKey: kind) ?? []
        callbacks.forEach { $0() }
    }

    private func persist(_ page: HealthTherapyImportPage, kind: HealthTherapyImportKind,
                         completion: @escaping (Bool) -> Void) {
        guard let coreDataManager else { completion(false); return }
        let context = coreDataManager.privateChildManagedObjectContext()
        let selected = selectedSource(kind)?.bundleIdentifier
        context.perform {
            do {
                let deletionIDs = Set(page.deletedUUIDs.map(\.uuidString))
                let pageIDs = Set(page.samples.map { $0.uuid.uuidString }).union(deletionIDs)
                let ledgerRequest: NSFetchRequest<HealthKitTherapySample> = HealthKitTherapySample.fetchRequest()
                ledgerRequest.predicate = NSPredicate(format: "uuid IN %@", Array(pageIDs))
                var ledger = Dictionary(uniqueKeysWithValues: try context.fetch(ledgerRequest).map { ($0.uuid, $0) })
                let treatmentRequest: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
                treatmentRequest.predicate = NSPredicate(format: "healthKitSampleUUID IN %@", Array(pageIDs))
                var treatments = Dictionary(uniqueKeysWithValues: try context.fetch(treatmentRequest)
                    .compactMap { entry in entry.healthKitSampleUUID.map { ($0, entry) } })

                // A deletion contains only its UUID. Never infer deletion from an empty page and
                // never touch a manual/Nightscout/CareLink row without matching HK provenance.
                for id in deletionIDs {
                    ledger[id]?.wasDeletedInHealthKit = true
                    if let entry = treatments[id] { entry.treatmentdeleted = true }
                }
                for sample in page.samples where sample.kind == kind && !HealthLocalTherapyIdentity.isOwn(
                    sourceBundleID: sample.source.bundleIdentifier,
                    syncIdentifier: sample.syncIdentifier) {
                    let id = sample.uuid.uuidString
                    guard !deletionIDs.contains(id) else { continue }
                    let record: HealthKitTherapySample
                    if let existing = ledger[id] {
                        guard !existing.wasDeletedInHealthKit else { continue }
                        record = existing
                    } else {
                        record = HealthKitTherapySample(context: context)
                        record.uuid = id
                        record.kind = kind.rawValue
                        record.sourceBundleIdentifier = sample.source.bundleIdentifier
                        record.sourceName = sample.source.name
                        record.startDate = sample.startDate
                        record.endDate = sample.endDate
                        record.quantity = sample.quantity
                        record.classification = sample.classification
                        record.externalUUID = sample.externalUUID
                        record.syncIdentifier = sample.syncIdentifier
                        record.wasDeletedInHealthKit = false
                        ledger[id] = record
                    }
                    guard sample.source.bundleIdentifier == selected,
                          sample.contributesToTherapy,
                          treatments[id] == nil else { continue }
                    let entry = TreatmentEntry(date: record.startDate, value: record.quantity,
                        treatmentType: kind.treatmentType, nightscoutEventType: nil,
                        enteredBy: "Apple Health · " + record.sourceName,
                        nsManagedObjectContext: context)
                    entry.treatmentdeleted = false
                    entry.healthKitSampleUUID = id
                    entry.healthKitSourceBundleIdentifier = record.sourceBundleIdentifier
                    entry.healthKitExternalUUID = record.externalUUID
                    entry.healthKitSyncIdentifier = record.syncIdentifier
                    treatments[id] = entry
                }
                let hasRecentAmbiguity = try self.hasRecentAmbiguity(
                    kind: kind, sourceBundleIdentifier: selected, in: context)
                let changedTreatments = context.insertedObjects.contains { $0 is TreatmentEntry }
                    || context.updatedObjects.contains { $0 is TreatmentEntry }
                    || context.deletedObjects.contains { $0 is TreatmentEntry }
                if context.hasChanges { try context.save() }
                // The child save is not durable. Do not advance the anchor until the parent
                // private context has reached the persistent store.
                let observedSelected = page.samples.contains { $0.source.bundleIdentifier == selected }
                let didSave: (Bool) -> Void = { saved in
                    if saved {
                        if self.selectedSource(kind)?.bundleIdentifier == selected {
                            self.defaults.set(hasRecentAmbiguity,
                                forKey: self.key(kind, "hasAmbiguousSelectedSource"))
                            if observedSelected {
                                self.defaults.set(true, forKey: self.key(kind, "observedSelectedSource"))
                            }
                        }
                        if changedTreatments { TherapyMetricsManager.shared.invalidate() }
                    }
                    completion(saved)
                }
                if let saveImportedPage = self.saveImportedPage {
                    saveImportedPage(coreDataManager, didSave)
                } else {
                    coreDataManager.saveChanges(completion: didSave)
                }
            } catch {
                context.rollback()
                completion(false)
            }
        }
    }

    private func materializeSelectedSource(_ kind: HealthTherapyImportKind,
                                           completion: @escaping (Bool) -> Void) {
        guard let coreDataManager, let selected = selectedSource(kind)?.bundleIdentifier else {
            completion(false)
            return
        }
        let context = coreDataManager.privateChildManagedObjectContext()
        context.perform {
            do {
                let request: NSFetchRequest<HealthKitTherapySample> = HealthKitTherapySample.fetchRequest()
                request.predicate = NSPredicate(format: "kind == %@ AND sourceBundleIdentifier == %@ AND wasDeletedInHealthKit == NO AND startDate >= %@",
                    kind.rawValue, selected, Date().addingTimeInterval(-TherapyModelSettings.visibilityInterval) as NSDate)
                let records = try context.fetch(request)
                let ids = records.map(\.uuid)
                let existingRequest: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
                existingRequest.predicate = NSPredicate(format: "healthKitSampleUUID IN %@", ids)
                let existingIDs = Set(try context.fetch(existingRequest).compactMap(\.healthKitSampleUUID))
                for record in records where !existingIDs.contains(record.uuid) {
                    guard !HealthLocalTherapyIdentity.isOwn(
                        sourceBundleID: record.sourceBundleIdentifier,
                        syncIdentifier: record.syncIdentifier) else { continue }
                    guard record.classification == "bolus" || record.classification == "carbohydrates" else { continue }
                    let entry = TreatmentEntry(date: record.startDate, value: record.quantity,
                        treatmentType: kind.treatmentType, nightscoutEventType: nil,
                        enteredBy: "Apple Health · " + record.sourceName,
                        nsManagedObjectContext: context)
                    entry.treatmentdeleted = false
                    entry.healthKitSampleUUID = record.uuid
                    entry.healthKitSourceBundleIdentifier = record.sourceBundleIdentifier
                    entry.healthKitExternalUUID = record.externalUUID
                    entry.healthKitSyncIdentifier = record.syncIdentifier
                }
                let hasRecentAmbiguity = try self.hasRecentAmbiguity(
                    kind: kind, sourceBundleIdentifier: selected, in: context)
                let changedTreatments = context.insertedObjects.contains { $0 is TreatmentEntry }
                    || context.updatedObjects.contains { $0 is TreatmentEntry }
                    || context.deletedObjects.contains { $0 is TreatmentEntry }
                if context.hasChanges { try context.save() }
                let didSave: (Bool) -> Void = { saved in
                    if saved {
                        if self.selectedSource(kind)?.bundleIdentifier == selected {
                            self.defaults.set(hasRecentAmbiguity,
                                forKey: self.key(kind, "hasAmbiguousSelectedSource"))
                            if !records.isEmpty {
                                self.defaults.set(true, forKey: self.key(kind, "observedSelectedSource"))
                            }
                        }
                        if changedTreatments { TherapyMetricsManager.shared.invalidate() }
                    }
                    completion(saved)
                }
                if let saveImportedPage = self.saveImportedPage {
                    saveImportedPage(coreDataManager, didSave)
                } else {
                    coreDataManager.saveChanges(completion: didSave)
                }
            } catch {
                context.rollback()
                completion(false)
            }
        }
    }

    /// Only uncertainty in the active calculation window can make current IOB/COB incomplete.
    /// Recompute from the durable ledger after every page and source selection, so a documented
    /// deletion or an aged-out ambiguous record does not leave a permanent warning.
    private func hasRecentAmbiguity(kind: HealthTherapyImportKind,
                                    sourceBundleIdentifier: String?,
                                    in context: NSManagedObjectContext) throws -> Bool {
        guard let sourceBundleIdentifier else { return false }
        let ambiguous = kind == .insulin
            ? ["unclassifiedInsulin", "ambiguousInterval", "invalid"]
            : ["ambiguousInterval", "invalid"]
        let request: NSFetchRequest<HealthKitTherapySample> = HealthKitTherapySample.fetchRequest()
        request.predicate = NSPredicate(
            format: "kind == %@ AND sourceBundleIdentifier == %@ AND wasDeletedInHealthKit == NO AND classification IN %@ AND startDate >= %@",
            kind.rawValue, sourceBundleIdentifier, ambiguous,
            Date().addingTimeInterval(-TherapyModelSettings.visibilityInterval) as NSDate)
        request.fetchLimit = 1
        return try context.count(for: request) > 0
    }
}

/// An immutable value copied from the durable local treatment row before any HealthKit work.
/// Reusing this identity and version on retry makes an interrupted save idempotent.
struct HealthLocalTherapyWriteRequest: Equatable {
    let localUUID: String
    let kind: HealthTherapyImportKind
    let eventDate: Date
    let amount: Double
    let version: Int

    var syncIdentifier: String { HealthLocalTherapyIdentity.syncPrefix + localUUID }

    var isValid: Bool {
        !localUUID.isEmpty && eventDate.timeIntervalSinceReferenceDate.isFinite &&
            amount.isFinite && amount > 0 && version > 0
    }
}

/// A deleted local row remains in the persistent store. Its original sync identity and
/// treatment kind are enough to remove only the copy this app previously exported.
struct HealthLocalTherapyDeleteRequest: Equatable {
    let localUUID: String
    let kind: HealthTherapyImportKind
    let version: Int

    var syncIdentifier: String { HealthLocalTherapyIdentity.syncPrefix + localUUID }
    var isValid: Bool { !localUUID.isEmpty && version > 0 }
}

/// The token changes on every edit, even when a child/main Core Data context still
/// has the old `pending` value after the writer acknowledged in its parent context.
enum HealthLocalTherapySyncState {
    static let deleted = "deleted"
    static func pending(version: Int) -> String {
        version == 1 ? "pending" : "pending.\(version)"
    }

    static func isPending(_ raw: String?, version: Int) -> Bool {
        raw == "pending" || raw == pending(version: version)
    }
}

protocol HealthLocalTherapyWriting: AnyObject {
    func save(_ request: HealthLocalTherapyWriteRequest,
              completion: @escaping (Bool, Error?) -> Void)
    func delete(_ request: HealthLocalTherapyDeleteRequest,
                completion: @escaping (Bool, Error?) -> Void)
}

extension HealthLocalTherapyWriting {
    func delete(_ request: HealthLocalTherapyDeleteRequest,
                completion: @escaping (Bool, Error?) -> Void) {
        completion(false, HealthTherapyImportError.unavailable)
    }
}

private final class LiveHealthLocalTherapyStore: HealthLocalTherapyWriting {
    private let healthStore = HKHealthStore()

    func save(_ request: HealthLocalTherapyWriteRequest,
              completion: @escaping (Bool, Error?) -> Void) {
        guard request.isValid, HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.quantityType(forIdentifier: request.kind.quantityIdentifier) else {
            completion(false, HealthTherapyImportError.unavailable)
            return
        }
        let writeSample = {
            var metadata: [String: Any] = [
                HKMetadataKeySyncIdentifier: request.syncIdentifier,
                HKMetadataKeySyncVersion: NSNumber(value: request.version)
            ]
            if request.kind == .insulin {
                metadata[HKMetadataKeyInsulinDeliveryReason] = NSNumber(value: HKInsulinDeliveryReason.bolus.rawValue)
            }
            let sample = HKQuantitySample(type: type,
                quantity: HKQuantity(unit: request.kind.unit, doubleValue: request.amount),
                start: request.eventDate, end: request.eventDate, metadata: metadata)
            self.healthStore.save(sample) { success, error in completion(success, error) }
        }
        // Foreground and retry writes must never display a permission sheet.
        guard healthStore.authorizationStatus(for: type) == .sharingAuthorized else {
            completion(false, HealthTherapyImportError.unavailable)
            return
        }
        writeSample()
    }

    func delete(_ request: HealthLocalTherapyDeleteRequest,
                completion: @escaping (Bool, Error?) -> Void) {
        guard request.isValid, HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.quantityType(forIdentifier: request.kind.quantityIdentifier) else {
            completion(false, HealthTherapyImportError.unavailable)
            return
        }
        guard healthStore.authorizationStatus(for: type) == .sharingAuthorized else {
            completion(false, HealthTherapyImportError.unavailable)
            return
        }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier,
                                        allowedValues: [request.syncIdentifier]),
            HKQuery.predicateForObjects(from: HKSource.default())
        ])
        // HealthKit also enforces that an app can delete only its own saved objects. An empty
        // match is a successful idempotent retry; no unrelated source or datatype is queried.
        healthStore.deleteObjects(of: type, predicate: predicate) { success, _, error in
            completion(success, error)
        }
    }
}

/// One-at-a-time Health writes and deletions. The durable local row is authoritative: write
/// failures leave `pending`, while confirmed local tombstones remain eligible for deletion
/// until HealthKit has acknowledged removal. Nothing is written before the source cutover.
final class HealthKitLocalTherapyWriter {
    static let shared = HealthKitLocalTherapyWriter(store: LiveHealthLocalTherapyStore())

    private enum Work {
        case write(HealthLocalTherapyWriteRequest)
        case delete(HealthLocalTherapyDeleteRequest)
    }

    private let store: HealthLocalTherapyWriting
    private let defaults: UserDefaults
    private let acknowledgementSaver: (NSManagedObjectContext) throws -> Void
    private let deletionIsVerified: @MainActor (CoreDataManager) -> Bool
    private let queue = DispatchQueue(label: "health.therapy.local.write", qos: .utility)
    private var coreDataManager: CoreDataManager?
    private var saveObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?
    private var protectedDataObserver: NSObjectProtocol?
    private var authorizationObserver: NSObjectProtocol?
    private var inFlight = false
    private var failedOnce = false
    private var retryScheduled = false

    init(store: HealthLocalTherapyWriting, defaults: UserDefaults = .standard,
         acknowledgementSaver: @escaping (NSManagedObjectContext) throws -> Void = { try $0.save() },
         deletionIsVerified: @escaping @MainActor (CoreDataManager) -> Bool = {
             PenDoseLogJournal.shared.recoveryState(coreDataManager: $0) == .ready
         }) {
        self.store = store
        self.defaults = defaults
        self.acknowledgementSaver = acknowledgementSaver
        self.deletionIsVerified = deletionIsVerified
    }

    deinit {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
        if let protectedDataObserver { NotificationCenter.default.removeObserver(protectedDataObserver) }
        if let authorizationObserver { NotificationCenter.default.removeObserver(authorizationObserver) }
    }

    func configure(coreDataManager: CoreDataManager) {
        queue.async {
            self.coreDataManager = coreDataManager
            if let saveObserver = self.saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
            self.saveObserver = NotificationCenter.default.addObserver(
                forName: .NSManagedObjectContextDidSave,
                object: coreDataManager.privateManagedObjectContext,
                queue: nil) { [weak self] _ in self?.retryPending() }
            if self.foregroundObserver == nil {
                self.foregroundObserver = NotificationCenter.default.addObserver(
                    forName: UIApplication.didBecomeActiveNotification,
                    object: nil, queue: nil) { [weak self] _ in
                        self?.retryAfterAvailabilityChange()
                    }
            }
            if self.protectedDataObserver == nil {
                self.protectedDataObserver = NotificationCenter.default.addObserver(
                    forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                    object: nil, queue: nil) { [weak self] _ in self?.retryAfterAvailabilityChange() }
            }
            if self.authorizationObserver == nil {
                self.authorizationObserver = NotificationCenter.default.addObserver(
                    forName: .healthKitPhoneAuthorizationDidChange,
                    object: nil, queue: nil) { [weak self] _ in self?.retryAfterAvailabilityChange() }
            }
            self.refreshPendingCounts()
            self.attemptNext()
        }
    }

    func retryPending() {
        queue.async {
            self.refreshPendingCounts()
            self.attemptNext()
        }
    }

    private func retryAfterAvailabilityChange() {
        queue.async {
            self.failedOnce = false
            self.refreshPendingCounts()
            self.attemptNext()
        }
    }

    /// Counts the complete durable queue without loading treatment values into diagnostics.
    /// Settings may request a refresh on presentation; saves and completed operations refresh it too.
    func refreshPendingCounts() {
        queue.async {
            guard let coreDataManager = self.coreDataManager,
                  let coordinator = coreDataManager.privateManagedObjectContext.persistentStoreCoordinator else { return }
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            context.perform {
                let cutover = TreatmentSourceCutover.current(defaults: self.defaults)
                let counts = HealthTherapyImportKind.allCases.map { kind -> (HealthTherapyImportKind, Int, Int)? in
                    let writes: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
                    var writeParts: [NSPredicate] = [NSPredicate(format:
                        "localTreatmentUUID != nil AND localTreatmentUUID != '' AND healthKitSampleUUID == nil AND watchSourceUUID == nil AND (treatmentdeleted == NO OR treatmentdeleted == nil) AND treatmentType == %d AND (healthKitSyncStateRaw == %@ OR healthKitSyncStateRaw BEGINSWITH %@)",
                        kind.treatmentType.rawValue, "pending", "pending.")]
                    if let cutover {
                        writeParts.append(NSPredicate(format: "date >= %@", cutover.cutoff as NSDate))
                    }
                    if kind == .carbohydrates {
                        writeParts.append(NSPredicate(format:
                            "plannedMealStateRaw == nil OR plannedMealStateRaw == %@",
                            TreatmentMealState.confirmed.rawValue))
                    }
                    writes.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: writeParts)
                    let deletions: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
                    deletions.predicate = NSPredicate(format:
                        "localTreatmentUUID != nil AND localTreatmentUUID != '' AND healthKitSampleUUID == nil AND watchSourceUUID == nil AND treatmentdeleted == YES AND treatmentType == %d AND healthKitSyncVersion > 0 AND (healthKitSyncStateRaw != %@ OR healthKitSyncStateRaw == nil)",
                        kind.treatmentType.rawValue, HealthLocalTherapySyncState.deleted)
                    guard let writeCount = try? context.count(for: writes),
                          let deleteCount = try? context.count(for: deletions) else { return nil }
                    return (kind, writeCount, deleteCount)
                }
                DispatchQueue.main.async {
                    for (kind, writes, deletes) in counts.compactMap({ $0 }) {
                        HealthKitExportStatusStore.shared.setPending(kind: kind.exportKind,
                            writes: writes, deletes: deletes)
                    }
                    // A failed count must not be represented as a confirmed zero.
                    for kind in HealthTherapyImportKind.allCases where !counts.contains(where: { $0?.0 == kind }) {
                        HealthKitExportStatusStore.shared.clearPending(kind: kind.exportKind)
                    }
                }
            }
        }
    }

    private func attemptNext() {
        guard !inFlight, let coreDataManager,
              let coordinator = coreDataManager.privateManagedObjectContext.persistentStoreCoordinator else { return }
        inFlight = true // Reserve the worker before the asynchronous Core Data fetch.
        // A fresh coordinator-backed context sees only committed local rows. A child-context
        // mutation whose parent save failed must never trigger a Health deletion.
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.perform {
            let next: Work?
            do {
                if let deletion = try self.nextDeletion(in: context) {
                    next = .delete(deletion)
                } else if let cutover = TreatmentSourceCutover.current(defaults: self.defaults),
                          let write = try self.nextWrite(in: context, cutover: cutover) {
                    next = .write(write)
                } else {
                    next = nil
                }
            } catch { next = nil }
            self.queue.async {
                guard let next else { self.inFlight = false; return }
                switch next {
                case .write(let write):
                    self.store.save(write) { success, error in
                        self.queue.async {
                            if success && error == nil {
                                HealthKitExportStatusStore.shared.recordSuccess(kind: write.kind.exportKind,
                                    operation: "skrivning")
                                self.markSynced(write, in: coreDataManager)
                            } else {
                                HealthKitExportStatusStore.shared.recordFailure(kind: write.kind.exportKind,
                                    operation: "skrivning", error: error)
                                self.stopAfterFailure()
                            }
                        }
                    }
                case .delete(let deletion):
                    DispatchQueue.main.async {
                        let verified = self.deletionIsVerified(coreDataManager)
                        self.queue.async {
                            guard verified else {
                                self.inFlight = false
                                return
                            }
                            self.store.delete(deletion) { success, error in
                                self.queue.async {
                                    if success && error == nil {
                                        HealthKitExportStatusStore.shared.recordSuccess(kind: deletion.kind.exportKind,
                                            operation: "sletning")
                                        self.markDeleted(deletion, in: coreDataManager)
                                    } else {
                                        HealthKitExportStatusStore.shared.recordFailure(kind: deletion.kind.exportKind,
                                            operation: "sletning", error: error)
                                        self.stopAfterFailure()
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func nextDeletion(in context: NSManagedObjectContext) throws -> HealthLocalTherapyDeleteRequest? {
        let request: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
        request.predicate = NSPredicate(format:
            "localTreatmentUUID != nil AND localTreatmentUUID != '' AND healthKitSampleUUID == nil AND watchSourceUUID == nil AND healthKitSyncVersion > 0 AND treatmentdeleted == YES AND (healthKitSyncStateRaw != %@ OR healthKitSyncStateRaw == nil) AND treatmentType IN %@",
            HealthLocalTherapySyncState.deleted,
            [TreatmentType.Insulin.rawValue, TreatmentType.Carbs.rawValue])
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        request.fetchLimit = 1
        // This scans the durable table, including records omitted from the visible treatment
        // list and records before the current source cutoff. A deleted local row is the proof.
        return try context.fetch(request).compactMap { entry in
            guard !entry.isHealthKitImported, !entry.isWatchLocalOnly,
                  let localUUID = entry.localTreatmentUUID else { return nil }
            let kind: HealthTherapyImportKind = entry.treatmentType == .Insulin ? .insulin : .carbohydrates
            let value = HealthLocalTherapyDeleteRequest(localUUID: localUUID, kind: kind,
                version: entry.healthKitSyncVersion?.intValue ?? 0)
            return value.isValid ? value : nil
        }.first
    }

    private func nextWrite(in context: NSManagedObjectContext,
                           cutover: TreatmentSourceCutover) throws -> HealthLocalTherapyWriteRequest? {
        let request: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
        request.predicate = NSPredicate(
            format: "localTreatmentUUID != nil AND (healthKitSyncStateRaw == %@ OR healthKitSyncStateRaw BEGINSWITH %@) AND (treatmentdeleted == NO OR treatmentdeleted == nil)",
            "pending", "pending.")
        request.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
        return try context.fetch(request).compactMap { entry in
            guard !entry.isHealthKitImported, !entry.isWatchLocalOnly,
                  let uuid = entry.localTreatmentUUID,
                  cutover.permitsLocal(eventDate: entry.date,
                    localTreatmentUUID: uuid, watchSourceUUID: nil),
                  entry.treatmentType == .Insulin || entry.isConfirmedMeal else { return nil }
            let kind: HealthTherapyImportKind = entry.treatmentType == .Insulin
                ? .insulin : .carbohydrates
            let value = HealthLocalTherapyWriteRequest(localUUID: uuid, kind: kind,
                eventDate: entry.date, amount: entry.value,
                version: entry.healthKitSyncVersion?.intValue ?? 0)
            return value.isValid && HealthLocalTherapySyncState.isPending(
                entry.healthKitSyncStateRaw, version: value.version) ? value : nil
        }.first
    }

    private func stopAfterFailure() {
        inFlight = false
        refreshPendingCounts()
        // A bounded delayed retry covers a transient Health or local acknowledgement
        // failure. Persistent failures wait for foreground or another durable save.
        guard !failedOnce, !retryScheduled else { return }
        failedOnce = true
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.retryScheduled = false
            self?.attemptNext()
        }
    }

    private func markSynced(_ sent: HealthLocalTherapyWriteRequest, in core: CoreDataManager) {
        let context = core.privateManagedObjectContext
        context.perform {
            var acknowledged = false
            var superseded = false
            var deletedBeforeAcknowledgement = false
            var acknowledgementError: Error?
            do {
                let request: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
                request.predicate = NSPredicate(format: "localTreatmentUUID == %@", sent.localUUID)
                if let entry = try context.fetch(request).first {
                    deletedBeforeAcknowledgement = entry.treatmentdeleted
                    let storedVersion = entry.healthKitSyncVersion?.intValue ?? 0
                    if storedVersion > sent.version,
                       HealthLocalTherapySyncState.isPending(entry.healthKitSyncStateRaw,
                                                             version: storedVersion) {
                        superseded = true
                    } else if storedVersion == sent.version,
                              HealthLocalTherapySyncState.isPending(entry.healthKitSyncStateRaw,
                                                                    version: sent.version),
                              !entry.treatmentdeleted {
                        entry.healthKitSyncStateRaw = "synced"
                        do {
                            try self.acknowledgementSaver(context)
                            acknowledged = true
                        } catch {
                            acknowledgementError = error
                            context.refresh(entry, mergeChanges: false)
                        }
                    }
                }
            } catch {
                // A failed local acknowledgement leaves the same sync ID/version pending.
            }
            let didAcknowledge = acknowledged
            let newerEditIsPending = superseded
            let deletionIsPending = deletedBeforeAcknowledgement
            let localError = acknowledgementError
            self.queue.async {
                if let localError {
                    HealthKitExportStatusStore.shared.recordFailure(kind: sent.kind.exportKind,
                        operation: "skrivekvittering", error: localError)
                }
                if didAcknowledge || newerEditIsPending || deletionIsPending {
                    self.inFlight = false
                    self.failedOnce = false
                    self.refreshPendingCounts()
                    self.attemptNext()
                } else {
                    self.stopAfterFailure()
                }
            }
        }
    }

    private func markDeleted(_ sent: HealthLocalTherapyDeleteRequest, in core: CoreDataManager) {
        guard let coordinator = core.privateManagedObjectContext.persistentStoreCoordinator else {
            stopAfterFailure()
            return
        }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.perform {
            var acknowledged = false
            var acknowledgementError: Error?
            do {
                let request: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
                request.predicate = NSPredicate(format: "localTreatmentUUID == %@", sent.localUUID)
                if let entry = try context.fetch(request).first,
                   entry.treatmentdeleted,
                   entry.treatmentType == sent.kind.treatmentType,
                   entry.healthKitSyncVersion?.intValue == sent.version {
                    if entry.healthKitSyncStateRaw == HealthLocalTherapySyncState.deleted {
                        acknowledged = true
                    } else {
                        entry.healthKitSyncStateRaw = HealthLocalTherapySyncState.deleted
                        do {
                            try self.acknowledgementSaver(context)
                            acknowledged = true
                        } catch {
                            acknowledgementError = error
                            context.refresh(entry, mergeChanges: false)
                        }
                    }
                }
            } catch { acknowledgementError = error }
            let didAcknowledge = acknowledged
            let localError = acknowledgementError
            self.queue.async {
                if let localError {
                    HealthKitExportStatusStore.shared.recordFailure(kind: sent.kind.exportKind,
                        operation: "slettekvittering", error: localError)
                }
                if didAcknowledge {
                    self.inFlight = false
                    self.failedOnce = false
                    self.refreshPendingCounts()
                    self.attemptNext()
                } else {
                    self.stopAfterFailure()
                }
            }
        }
    }
}
