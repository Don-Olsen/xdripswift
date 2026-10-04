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
    let unknownInsulinDays: Int
    let unknownCarbohydrateDays: Int
    let conflictingGlucoseTimestamps: Int
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

    static func matchingGlucoseSources(_ sources: [GlucoseForecastMLHealthSource])
        -> [GlucoseForecastMLHealthSource] {
        let candidates = sources.filter {
            !$0.bundleIdentifier.isEmpty && $0.name.localizedCaseInsensitiveContains("xDrip")
        }
        let byBundle = Dictionary(grouping: candidates, by: \.bundleIdentifier)
        return byBundle.keys.sorted().compactMap { byBundle[$0]?.first }
    }

    static func conflictingHealthDates(_ samples: [GlucoseForecastMLHealthSample]) -> Set<Date> {
        let groups = Dictionary(grouping: samples, by: \.startDate)
        return Set(groups.compactMap { date, group in
            let first = group[0].value
            return group.allSatisfy({
                $0.value.isFinite && (20...600).contains($0.value) &&
                    $0.startDate == $0.endDate && !$0.hasUndeterminedDuration &&
                    $0.sampleCount == 1 && $0.value == first
            }) ? nil : date
        })
    }

    /// Exact identical records collapse. Every value at a conflicting timestamp
    /// is discarded; the ambiguous instant cannot become an anchor or target.
    static func normalizedHealthGlucose(_ samples: [GlucoseForecastMLHealthSample],
                                        sourceBundleIdentifier: String)
        -> (observations: [GlucoseForecastGlucoseObservation], conflicts: Set<Date>) {
        let selected = samples.filter { $0.sourceBundleIdentifier == sourceBundleIdentifier }
        let groups = Dictionary(grouping: selected, by: \.startDate)
        var observations = [GlucoseForecastGlucoseObservation]()
        var conflicts = Set<Date>()
        for date in groups.keys.sorted() {
            guard let group = groups[date] else { continue }
            let firstValue = group[0].value
            let valid = group.allSatisfy {
                $0.startDate == $0.endDate && !$0.hasUndeterminedDuration &&
                    $0.sampleCount == 1 && $0.value.isFinite &&
                    (20...600).contains($0.value) && $0.value == firstValue
            }
            guard valid else { conflicts.insert(date); continue }
            observations.append(GlucoseForecastGlucoseObservation(date: date,
                glucoseMgdl: firstValue, sensorID: "health:" + sourceBundleIdentifier,
                isValidForDownstream: true, isSuppressedByFiveMinuteCadence: false))
        }
        return (observations, conflicts)
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

    /// Keep a bundle while its identical export continues, then switch when it
    /// stops. Every frozen xDrip bundle can therefore contribute separate runs.
    static func deduplicatedHealthTagged(_ tagged: [GlucoseForecastMLHistoryTaggedObservation])
        -> [GlucoseForecastMLHistoryTaggedObservation] {
        let groups = Dictionary(grouping: tagged, by: { $0.observation.date })
        var selected = [GlucoseForecastMLHistoryTaggedObservation]()
        var currentBundle: String?
        for date in groups.keys.sorted() {
            guard let group = groups[date], let first = group.first,
                  group.allSatisfy({ $0.observation.glucoseMgdl == first.observation.glucoseMgdl })
            else { continue }
            let chosen = group.first { $0.sourceBundleIdentifier == currentBundle } ??
                group.sorted { ($0.sourceBundleIdentifier ?? "") < ($1.sourceBundleIdentifier ?? "") }.first!
            selected.append(chosen)
            currentBundle = chosen.sourceBundleIdentifier
        }
        return selected
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
