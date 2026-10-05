// Read-only HealthKit snapshots for retrospective forecast training. The query
// adapter never requests authorization or persists samples.
import Foundation
import HealthKit

enum GlucoseForecastMLHealthKind: CaseIterable, Sendable {
    case glucose
    case insulin
    case carbohydrates

    var quantityIdentifier: HKQuantityTypeIdentifier {
        switch self {
        case .glucose: return .bloodGlucose
        case .insulin: return .insulinDelivery
        case .carbohydrates: return .dietaryCarbohydrates
        }
    }

    var unit: HKUnit {
        switch self {
        case .glucose: return HKUnit(from: "mg/dL")
        case .insulin: return .internationalUnit()
        case .carbohydrates: return .gram()
        }
    }
}

struct GlucoseForecastMLHealthSource: Equatable, Sendable {
    let bundleIdentifier: String
    let name: String
}

struct GlucoseForecastMLHealthSample: Sendable {
    let uuid: UUID
    let sourceBundleIdentifier: String
    let startDate: Date
    let endDate: Date
    let value: Double
    let insulinReason: Int?
    let hasUndeterminedDuration: Bool
    let sampleCount: Int

    func treatment(kind: GlucoseForecastMLHealthKind) -> TherapyTreatment? {
        guard kind != .glucose, value.isFinite, value > 0,
              startDate == endDate, !hasUndeterminedDuration, sampleCount == 1 else { return nil }
        switch kind {
        case .insulin:
            guard insulinReason == HKInsulinDeliveryReason.bolus.rawValue else { return nil }
            return TherapyTreatment(date: startDate, amount: value, isIOB: true)
        case .carbohydrates:
            // Imported/legacy meals have no per-entry type and are normal 240-minute meals.
            return TherapyTreatment(date: startDate, amount: value, isIOB: false,
                carbohydrateDurationMinutes: TreatmentMealKind.normal.durationMinutes)
        case .glucose:
            return nil
        }
    }

    func isUnambiguous(kind: GlucoseForecastMLHealthKind) -> Bool {
        guard value.isFinite, value > 0, startDate == endDate,
              !hasUndeterminedDuration, sampleCount == 1 else { return false }
        return kind != .insulin || insulinReason == HKInsulinDeliveryReason.bolus.rawValue ||
            insulinReason == HKInsulinDeliveryReason.basal.rawValue
    }
}

/// Counts are captured from the HealthKit callback before the adapter applies
/// any source or sample conversion filter. The loader keeps only aggregate
/// evidence; no HealthKit quantities are written to diagnostics.
struct GlucoseForecastMLHealthSampleBatch: Sendable {
    let samples: [GlucoseForecastMLHealthSample]
    let rawCount: Int
    let rawSourceCounts: [String: Int]

    init(samples: [GlucoseForecastMLHealthSample], rawCount: Int? = nil,
         rawSourceCounts: [String: Int]? = nil) {
        self.samples = samples
        self.rawCount = rawCount ?? samples.count
        self.rawSourceCounts = rawSourceCounts ??
            Dictionary(grouping: samples, by: \.sourceBundleIdentifier).mapValues(\.count)
    }
}

final class GlucoseForecastMLHealthQueryTicket {
    private let lock = NSLock()
    private var cancelAction: (() -> Void)?

    init(_ cancelAction: @escaping () -> Void = {}) { self.cancelAction = cancelAction }

    func cancel() {
        lock.lock()
        let action = cancelAction
        cancelAction = nil
        lock.unlock()
        action?()
    }
}

/// A value-only seam for isolated tests. Both methods are bounded and read-only.
protocol GlucoseForecastMLHealthQuerying: AnyObject {
    @discardableResult
    func sources(for kind: GlucoseForecastMLHealthKind,
                 completion: @escaping (Result<[GlucoseForecastMLHealthSource], Error>) -> Void)
        -> GlucoseForecastMLHealthQueryTicket

    @discardableResult
    /// Glucose remains source-filtered. Therapy returns all same-day sources so
    /// the loader can count rows before applying its existing exact source rule.
    func samples(for kind: GlucoseForecastMLHealthKind, from start: Date, to end: Date,
                 sourceBundleIdentifier: String,
                 completion: @escaping (Result<GlucoseForecastMLHealthSampleBatch, Error>) -> Void)
        -> GlucoseForecastMLHealthQueryTicket
}

final class GlucoseForecastMLLiveHealthQuery: GlucoseForecastMLHealthQuerying {
    private let store: HKHealthStore

    init(store: HKHealthStore = HKHealthStore()) { self.store = store }

    func sources(for kind: GlucoseForecastMLHealthKind,
                 completion: @escaping (Result<[GlucoseForecastMLHealthSource], Error>) -> Void)
        -> GlucoseForecastMLHealthQueryTicket {
        guard HKHealthStore.isHealthDataAvailable(),
              let type = HKObjectType.quantityType(forIdentifier: kind.quantityIdentifier) else {
            completion(.failure(GlucoseForecastMLHealthQueryError.unavailable))
            return GlucoseForecastMLHealthQueryTicket()
        }
        let query = HKSourceQuery(sampleType: type, samplePredicate: nil) { _, sources, error in
            if let error { completion(.failure(error)); return }
            completion(.success((sources ?? []).map {
                GlucoseForecastMLHealthSource(bundleIdentifier: $0.bundleIdentifier, name: $0.name)
            }))
        }
        store.execute(query)
        return GlucoseForecastMLHealthQueryTicket { [store] in store.stop(query) }
    }

    func samples(for kind: GlucoseForecastMLHealthKind, from start: Date, to end: Date,
                 sourceBundleIdentifier: String,
                 completion: @escaping (Result<GlucoseForecastMLHealthSampleBatch, Error>) -> Void)
        -> GlucoseForecastMLHealthQueryTicket {
        guard HKHealthStore.isHealthDataAvailable(), start < end,
              let type = HKObjectType.quantityType(forIdentifier: kind.quantityIdentifier) else {
            completion(.failure(GlucoseForecastMLHealthQueryError.unavailable))
            return GlucoseForecastMLHealthQueryTicket()
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end,
                                                    options: .strictStartDate)
        let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(
                                    key: HKSampleSortIdentifierStartDate, ascending: true)]) {
            _, samples, error in
            if let error { completion(.failure(error)); return }
            let rawSamples = samples ?? []
            let rawSourceCounts = Dictionary(grouping: rawSamples,
                by: { $0.sourceRevision.source.bundleIdentifier }).mapValues(\.count)
            let values = (samples ?? []).compactMap { object -> GlucoseForecastMLHealthSample? in
                guard let sample = object as? HKQuantitySample,
                      (kind != .glucose ||
                        sample.sourceRevision.source.bundleIdentifier == sourceBundleIdentifier),
                      (kind != .glucose ||
                        (sample.startDate >= start && sample.startDate < end)) else { return nil }
                return GlucoseForecastMLHealthSample(uuid: sample.uuid,
                    sourceBundleIdentifier: sample.sourceRevision.source.bundleIdentifier,
                    startDate: sample.startDate, endDate: sample.endDate,
                    value: sample.quantity.doubleValue(for: kind.unit),
                    insulinReason: (sample.metadata?[HKMetadataKeyInsulinDeliveryReason] as? NSNumber)?.intValue,
                    hasUndeterminedDuration: sample.hasUndeterminedDuration,
                    sampleCount: sample.count)
            }
            completion(.success(GlucoseForecastMLHealthSampleBatch(samples: values,
                rawCount: rawSamples.count, rawSourceCounts: rawSourceCounts)))
        }
        store.execute(query)
        return GlucoseForecastMLHealthQueryTicket { [store] in store.stop(query) }
    }
}

private enum GlucoseForecastMLHealthQueryError: Error { case unavailable }
