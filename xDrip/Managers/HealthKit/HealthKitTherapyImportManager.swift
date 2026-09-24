import CoreData
import Foundation
import HealthKit
import UIKit

/// Health therapy import is deliberately separate from the existing glucose export manager.
/// Neither enabling a read type nor receiving a HealthKit callback writes therapy to Health.
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
}

struct HealthTherapyImportSource: Equatable {
    let bundleIdentifier: String
    let name: String
}

struct HealthTherapyImportStatus {
    let lastSync: Date?
    let message: String
    let isIncomplete: Bool
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
              let type = HKObjectType.quantityType(forIdentifier: kind.quantityIdentifier) else {
            completion(HealthTherapyImportError.unavailable)
            return
        }
        // A successful dialog is NOT proof of read authorization. Apple intentionally does not
        // disclose whether the user granted read access to a particular sample type.
        healthStore.requestAuthorization(toShare: [], read: [type]) { _, error in
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
    private var observerInstalled = Set<HealthTherapyImportKind>()
    private var observerCompletions: [HealthTherapyImportKind: [() -> Void]] = [:]
    /// Injected only by isolated tests to fail one parent-store save at a precise boundary.
    var saveImportedPage: ((CoreDataManager, @escaping (Bool) -> Void) -> Void)?

    init(query: HealthTherapyQuerying, defaults: UserDefaults) {
        self.query = query
        self.defaults = defaults
    }

    func configure(coreDataManager: CoreDataManager) {
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
        defaults.bool(forKey: key(kind, "enabled"))
    }

    func selectedSource(_ kind: HealthTherapyImportKind) -> HealthTherapyImportSource? {
        guard let id = defaults.string(forKey: key(kind, "sourceBundleID")), !id.isEmpty else { return nil }
        return HealthTherapyImportSource(bundleIdentifier: id,
            name: defaults.string(forKey: key(kind, "sourceName")) ?? id)
    }

    func discoveredSources(_ kind: HealthTherapyImportKind,
                           completion: @escaping ([HealthTherapyImportSource], Error?) -> Void) {
        query.discoverSources(for: kind, completion: completion)
    }

    func setEnabled(_ enabled: Bool, kind: HealthTherapyImportKind,
                    completion: @escaping (Error?) -> Void) {
        guard enabled else {
            defaults.set(false, forKey: key(kind, "enabled"))
            defaults.removeObject(forKey: key(kind, "syncInProgress"))
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
        guard !source.bundleIdentifier.isEmpty else { return }
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
        TherapyMetricsManager.shared.invalidate()
        notifyStatusChanged()
    }

    private func installObserver(_ kind: HealthTherapyImportKind) {
        guard observerInstalled.insert(kind).inserted else { return }
        query.observe(kind) { completion in
            self.queue.async {
                self.observerCompletions[kind, default: []].append(completion)
                self.startSync(kind)
            }
        }
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
        defaults.set(true, forKey: key(kind, "syncInProgress"))
        defaults.removeObject(forKey: key(kind, "error"))
        TherapyMetricsManager.shared.invalidate(treatmentsChanged: false)
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
                    self.complete(kind)
                    return
                }
                guard self.isEnabled(kind) else { self.complete(kind); return }
                self.drain(kind, since: since)
            }
        }
    }

    private func drain(_ kind: HealthTherapyImportKind, since: Date) {
        let anchor = defaults.data(forKey: key(kind, "anchor"))
        query.page(for: kind, since: since, anchor: anchor, limit: Self.pageLimit) { result in
            self.queue.async {
                guard self.isEnabled(kind) else { self.complete(kind); return }
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
                    self.complete(kind)
                case let .success(page):
                    self.persist(page, kind: kind) { saved in
                        self.queue.async {
                            guard saved else {
                                self.setStatus(kind, message: "Local storage failed. Import will retry without moving its checkpoint.")
                                self.complete(kind)
                                return
                            }
                            guard self.isEnabled(kind) else { self.complete(kind); return }
                            self.defaults.set(page.nextAnchor, forKey: self.key(kind, "anchor"))
                            if page.hasMore {
                                self.drain(kind, since: since)
                            } else {
                                // A page is durable before its anchor advances. Only the final
                                // page certifies that the current catch-up reached its end.
                                self.defaults.set(Date(), forKey: self.key(kind, "lastSync"))
                                self.defaults.removeObject(forKey: self.key(kind, "syncInProgress"))
                                self.setStatus(kind, message: nil)
                                self.complete(kind)
                            }
                        }
                    }
                }
            }
        }
    }

    private func complete(_ kind: HealthTherapyImportKind) {
        active.remove(kind)
        finishObserverCallbacks(kind)
        if pending.remove(kind) != nil { startSync(kind) }
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
                for sample in page.samples where sample.kind == kind {
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
                        TherapyMetricsManager.shared.invalidate()
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
                        TherapyMetricsManager.shared.invalidate()
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
