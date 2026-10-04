import Foundation

enum GlucoseForecastMLHistorySource: String, Sendable {
    case healthKit
    case local
}

struct GlucoseForecastMLSourceSegment: Sendable {
    let source: GlucoseForecastMLHistorySource
    let sourceBundleIdentifier: String?
    let sensorID: String
    let startDate: Date
    let endDate: Date
}

struct GlucoseForecastMLHistoryCoverage: Sendable {
    let requestedDays: Int
    let completedDays: Int
    let usableDays: Int
    let healthKitDays: Int
    let localFallbackDays: Int
    let healthCandidateDays: Int
    let localCandidateDays: Int
    let unknownInsulinDays: Int
    let unknownCarbohydrateDays: Int
    let conflictingGlucoseTimestamps: Int
    let mergedHealthGlucoseTimestamps: Int
    let discardedHealthGlucoseTimestamps: Int
    let healthLocalComparisonCount: Int
    let healthLocalAbsoluteDifferenceMedianMgdl: Double?
    let healthLocalAbsoluteDifferenceP95Mgdl: Double?
    let exampleCountsByHorizon: [Int: Int]
}

struct GlucoseForecastMLHistoryLoadResult: Sendable {
    let examples: [GlucoseForecastMLReplayExample]
    let coverage: GlucoseForecastMLHistoryCoverage
    let segments: [GlucoseForecastMLSourceSegment]
}

struct GlucoseForecastMLHistoryTaggedObservation {
    let observation: GlucoseForecastGlucoseObservation
    let source: GlucoseForecastMLHistorySource
    let sourceBundleIdentifier: String?
}

/// Explicit source evidence is deliberately stricter than observing a successful
/// HealthKit callback. Apple may return an empty history when read access is denied.
struct GlucoseForecastMLTherapyEvidence {
    let sourceDays: Set<Date>
    let ambiguousDays: Set<Date>
    let historyStart: Date?
    let requiresSelectedSource: Bool

    func covers(from start: Date, to end: Date, calendar: Calendar,
                usingLocalImport: Bool) -> Bool {
        guard start <= end else { return false }
        if usingLocalImport && requiresSelectedSource {
            guard let historyStart, start >= historyStart else { return false }
        }
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while day <= last {
            guard sourceDays.contains(day), !ambiguousDays.contains(day),
                  let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else {
                return false
            }
            day = next
        }
        return true
    }
}

enum GlucoseForecastMLHistoryCoverageRules {
    static let maximumReadDays = 365
    static let maximumContinuousGlucoseGap: TimeInterval = 330
    static let maximumSameTimestampSpreadMgdl = 3.6

    struct HealthGlucoseNormalization {
        let observationsByBundle: [String: [GlucoseForecastGlucoseObservation]]
        let conflicts: Set<Date>
        let invalidOnlyDates: Set<Date>
        let mergedTimestamps: Int
    }

    struct HealthLocalComparison {
        let count: Int
        let medianAbsoluteDifferenceMgdl: Double?
        let p95AbsoluteDifferenceMgdl: Double?
    }

    static func matchingGlucoseSources(_ sources: [GlucoseForecastMLHealthSource])
        -> [GlucoseForecastMLHealthSource] {
        let candidates = sources.filter {
            !$0.bundleIdentifier.isEmpty && $0.name.localizedCaseInsensitiveContains("xDrip")
        }
        let byBundle = Dictionary(grouping: candidates, by: \.bundleIdentifier)
        return byBundle.keys.sorted().compactMap { byBundle[$0]?.first }
    }

    private static func validGlucose(_ sample: GlucoseForecastMLHealthSample) -> Bool {
        sample.startDate == sample.endDate && !sample.hasUndeterminedDuration &&
            sample.sampleCount == 1 && sample.value.isFinite &&
            (20...600).contains(sample.value)
    }

    private static func median(_ sortedValues: [Double]) -> Double {
        let middle = sortedValues.count / 2
        if sortedValues.count.isMultiple(of: 2) {
            return sortedValues[middle - 1] / 2 + sortedValues[middle] / 2
        }
        return sortedValues[middle]
    }

    /// Inspect all frozen xDrip bundles before computing any per-bundle median.
    /// A wide cross-bundle disagreement must not be concealed by repeated copies
    /// from one source. Invalid raw samples are not candidates for either rule.
    static func normalizeHealthGlucose(_ samples: [GlucoseForecastMLHealthSample])
        -> HealthGlucoseNormalization {
        let groups = Dictionary(grouping: samples, by: \.startDate)
        var observationsByBundle = [String: [GlucoseForecastGlucoseObservation]]()
        var conflicts = Set<Date>()
        var invalidOnlyDates = Set<Date>()
        var mergedTimestamps = 0
        for date in groups.keys.sorted() {
            guard let rawGroup = groups[date] else { continue }
            let group = rawGroup.filter(validGlucose)
            guard !group.isEmpty else {
                // Do not bridge a known invalid-only reading while constructing
                // a replay segment, even when the neighboring gap is short.
                invalidOnlyDates.insert(date)
                continue
            }
            let values = group.map(\.value).sorted()
            guard let minimum = values.first, let maximum = values.last,
                  maximum - minimum <= maximumSameTimestampSpreadMgdl else {
                conflicts.insert(date)
                continue
            }
            if group.count > 1 { mergedTimestamps += 1 }
            let byBundle = Dictionary(grouping: group, by: \.sourceBundleIdentifier)
            for bundle in byBundle.keys.sorted() {
                guard let sourceValues = byBundle[bundle]?.map(\.value).sorted() else { continue }
                observationsByBundle[bundle, default: []].append(
                    GlucoseForecastGlucoseObservation(date: date,
                        glucoseMgdl: median(sourceValues), sensorID: "health:" + bundle,
                        isValidForDownstream: true, isSuppressedByFiveMinuteCadence: false))
            }
        }
        return HealthGlucoseNormalization(observationsByBundle: observationsByBundle,
            conflicts: conflicts, invalidOnlyDates: invalidOnlyDates,
            mergedTimestamps: mergedTimestamps)
    }

    static func conflictingHealthDates(_ samples: [GlucoseForecastMLHealthSample]) -> Set<Date> {
        normalizeHealthGlucose(samples).conflicts
    }

    /// Same rule as the whole-batch normalizer: callers must pass *all* frozen
    /// xDrip bundles so a different bundle cannot hide a global conflict.
    static func normalizedHealthGlucose(_ samples: [GlucoseForecastMLHealthSample],
                                        sourceBundleIdentifier: String)
        -> (observations: [GlucoseForecastGlucoseObservation], conflicts: Set<Date>) {
        let normalized = normalizeHealthGlucose(samples)
        return (normalized.observationsByBundle[sourceBundleIdentifier] ?? [], normalized.conflicts)
    }

    static func normalizedLocalGlucose(_ samples: [GlucoseForecastGlucoseObservation])
        -> (observations: [GlucoseForecastGlucoseObservation], conflicts: Set<Date>) {
        let groups = Dictionary(grouping: samples, by: \.date)
        var observations = [GlucoseForecastGlucoseObservation]()
        var conflicts = Set<Date>()
        for date in groups.keys.sorted() {
            guard let group = groups[date] else { continue }
            let first = group[0]
            guard group.allSatisfy({
                $0.sensorID == first.sensorID && $0.glucoseMgdl == first.glucoseMgdl &&
                    $0.isValidForDownstream == first.isValidForDownstream &&
                    $0.isSuppressedByFiveMinuteCadence == first.isSuppressedByFiveMinuteCadence
            }) else { conflicts.insert(date); continue }
            observations.append(first)
        }
        return (observations, conflicts)
    }

    /// Keep a bundle while its compatible export continues, then switch when it
    /// stops. This fallback applies the same global spread and per-bundle median
    /// if given raw tagged duplicates; the loader normally supplies normalized rows.
    static func deduplicatedHealthTagged(_ tagged: [GlucoseForecastMLHistoryTaggedObservation])
        -> [GlucoseForecastMLHistoryTaggedObservation] {
        let valid = tagged.filter {
            $0.observation.isValidForDownstream &&
                !$0.observation.isSuppressedByFiveMinuteCadence &&
                $0.observation.glucoseMgdl.isFinite &&
                (20...600).contains($0.observation.glucoseMgdl)
        }
        let groups = Dictionary(grouping: valid, by: { $0.observation.date })
        var selected = [GlucoseForecastMLHistoryTaggedObservation]()
        var currentBundle: String?
        for date in groups.keys.sorted() {
            guard let group = groups[date],
                  let minimum = group.map({ $0.observation.glucoseMgdl }).min(),
                  let maximum = group.map({ $0.observation.glucoseMgdl }).max(),
                  minimum.isFinite, maximum.isFinite,
                  maximum - minimum <= maximumSameTimestampSpreadMgdl
            else { continue }
            let byBundle = Dictionary(grouping: group, by: { $0.sourceBundleIdentifier ?? "" })
            let bundle = currentBundle.flatMap { byBundle[$0] == nil ? nil : $0 } ??
                byBundle.keys.sorted().first!
            guard let sourceRows = byBundle[bundle], let chosen = sourceRows.first else { continue }
            let sourceValues = sourceRows.map { $0.observation.glucoseMgdl }.sorted()
            let row = chosen.observation
            selected.append(GlucoseForecastMLHistoryTaggedObservation(
                observation: GlucoseForecastGlucoseObservation(date: row.date,
                    glucoseMgdl: median(sourceValues), sensorID: row.sensorID,
                    isValidForDownstream: true, isSuppressedByFiveMinuteCadence: false),
                source: chosen.source, sourceBundleIdentifier: chosen.sourceBundleIdentifier))
            currentBundle = chosen.sourceBundleIdentifier
        }
        return selected
    }

    /// Exact-timestamp comparison only. The returned aggregates are diagnostics,
    /// not a transformation of either the Health or the stored live readings.
    static func compareHealthWithLocal(
        health: [GlucoseForecastMLHistoryTaggedObservation],
        local: [GlucoseForecastMLHistoryTaggedObservation]) -> HealthLocalComparison {
        let localGroups = Dictionary(grouping: local, by: { $0.observation.date })
        let localValues = localGroups.compactMapValues { rows -> Double? in
            guard let first = rows.first?.observation,
                  first.isValidForDownstream, !first.isSuppressedByFiveMinuteCadence,
                  first.glucoseMgdl.isFinite, (20...600).contains(first.glucoseMgdl),
                  rows.allSatisfy({ row in
                      row.observation.isValidForDownstream &&
                          !row.observation.isSuppressedByFiveMinuteCadence &&
                          row.observation.glucoseMgdl == first.glucoseMgdl
                  }) else { return nil }
            return first.glucoseMgdl
        }
        let differences = health.compactMap { tagged -> Double? in
            guard let localValue = localValues[tagged.observation.date],
                  localValue.isFinite, (20...600).contains(localValue),
                  tagged.observation.glucoseMgdl.isFinite else { return nil }
            return abs(tagged.observation.glucoseMgdl - localValue)
        }.sorted()
        guard !differences.isEmpty else {
            return HealthLocalComparison(count: 0, medianAbsoluteDifferenceMgdl: nil,
                p95AbsoluteDifferenceMgdl: nil)
        }
        let p95Index = max(0, Int(ceil(Double(differences.count) * 0.95)) - 1)
        return HealthLocalComparison(count: differences.count,
            medianAbsoluteDifferenceMgdl: median(differences),
            p95AbsoluteDifferenceMgdl: differences[p95Index])
    }

    static func segments(_ tagged: [GlucoseForecastMLHistoryTaggedObservation],
                         blockedDates: Set<Date>)
        -> [(GlucoseForecastMLSourceSegment, [GlucoseForecastGlucoseObservation])] {
        let ordered = tagged.sorted { $0.observation.date < $1.observation.date }
        var result = [(GlucoseForecastMLSourceSegment, [GlucoseForecastGlucoseObservation])]()
        var current = [GlucoseForecastGlucoseObservation]()
        var currentSource: GlucoseForecastMLHistorySource?
        var currentBundle: String?
        var currentSensor: String?
        let barriers = blockedDates.sorted()
        var barrierIndex = 0
        func flush() {
            guard let first = current.first, let last = current.last,
                  let currentSource, let currentSensor else { return }
            // HealthKit has no physical sensor identifier. Give each continuous
            // source run a synthetic, deterministic segment ID before replay.
            let segmentSensor = currentSource == .healthKit
                ? "health-segment:\(currentBundle ?? ""):\(Int64(first.date.timeIntervalSince1970 * 1000))"
                : currentSensor
            let rows = currentSource == .healthKit ? current.map {
                GlucoseForecastGlucoseObservation(date: $0.date, glucoseMgdl: $0.glucoseMgdl,
                    sensorID: segmentSensor, isValidForDownstream: $0.isValidForDownstream,
                    isSuppressedByFiveMinuteCadence: $0.isSuppressedByFiveMinuteCadence)
            } : current
            result.append((GlucoseForecastMLSourceSegment(source: currentSource,
                sourceBundleIdentifier: currentBundle, sensorID: segmentSensor,
                startDate: first.date, endDate: last.date), rows))
            current = []
        }
        for taggedRow in ordered {
            let row = taggedRow.observation
            guard let sensor = row.sensorID, !sensor.isEmpty,
                  row.isValidForDownstream, !row.isSuppressedByFiveMinuteCadence,
                  row.glucoseMgdl.isFinite, (20...600).contains(row.glucoseMgdl) else {
                flush()
                currentSource = nil
                currentSensor = nil
                continue
            }
            while barrierIndex < barriers.count &&
                (current.last?.date ?? row.date) >= barriers[barrierIndex] { barrierIndex += 1 }
            let crossesBarrier = barrierIndex < barriers.count &&
                barriers[barrierIndex] <= row.date
            let gap = current.last.map { row.date.timeIntervalSince($0.date) } ?? 0
            if !current.isEmpty && (taggedRow.source != currentSource ||
                taggedRow.sourceBundleIdentifier != currentBundle || sensor != currentSensor ||
                gap <= 0 || gap > maximumContinuousGlucoseGap || crossesBarrier) {
                flush()
            }
            currentSource = taggedRow.source
            currentBundle = taggedRow.sourceBundleIdentifier
            currentSensor = sensor
            current.append(row)
        }
        flush()
        return result
    }

    static func daySet(_ dates: [Date], calendar: Calendar) -> Set<Date> {
        Set(dates.map { calendar.startOfDay(for: $0) })
    }
}
