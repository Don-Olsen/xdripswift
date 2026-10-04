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
            return TherapyTreatment(date: startDate, amount: value, isIOB: false)
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
    func samples(for kind: GlucoseForecastMLHealthKind, from start: Date, to end: Date,
                 sourceBundleIdentifier: String,
                 completion: @escaping (Result<[GlucoseForecastMLHealthSample], Error>) -> Void)
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
                 completion: @escaping (Result<[GlucoseForecastMLHealthSample], Error>) -> Void)
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
            let values = (samples ?? []).compactMap { object -> GlucoseForecastMLHealthSample? in
                guard let sample = object as? HKQuantitySample,
                      sample.sourceRevision.source.bundleIdentifier == sourceBundleIdentifier,
                      sample.startDate >= start, sample.startDate < end else { return nil }
                return GlucoseForecastMLHealthSample(uuid: sample.uuid,
                    sourceBundleIdentifier: sample.sourceRevision.source.bundleIdentifier,
                    startDate: sample.startDate, endDate: sample.endDate,
                    value: sample.quantity.doubleValue(for: kind.unit),
                    insulinReason: (sample.metadata?[HKMetadataKeyInsulinDeliveryReason] as? NSNumber)?.intValue,
                    hasUndeterminedDuration: sample.hasUndeterminedDuration,
                    sampleCount: sample.count)
            }
            completion(.success(values))
        }
        store.execute(query)
        return GlucoseForecastMLHealthQueryTicket { [store] in store.stop(query) }
    }
}

private enum GlucoseForecastMLHealthQueryError: Error { case unavailable }
