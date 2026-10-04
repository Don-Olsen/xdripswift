// Deterministic retrospective examples. Event time is not proof of ingestion time.
import Foundation

enum GlucoseForecastMLAvailabilityProvenance: String, Codable, Sendable {
    case knownAtReference
    case retrospectiveUnknown
}

struct GlucoseForecastMLReplayExample: Sendable {
    let row: GlucoseForecastMLFeatureRow
    let targetDate: Date
    let targetGlucoseMgdl: Double
    let engineTargetGlucoseMgdl: Double
    /// Complete five-minute engine knots from t=0 through t=120. All three rows
    /// from one anchor share this immutable array for live-style overlay scoring.
    let engineTrajectoryMgdl: [Double]
    let sourceIdentity: String
    let treatmentAvailability: GlucoseForecastMLAvailabilityProvenance
    let settingsAvailability: GlucoseForecastMLAvailabilityProvenance
    /// The exact event-time treatment window handed to the forecast engine.
    /// These totals are diagnostic; they do not establish import availability.
    let bolusUnitsInWindow: Double
    let carbohydrateGramsInWindow: Double

    init(row: GlucoseForecastMLFeatureRow, targetDate: Date,
         targetGlucoseMgdl: Double, engineTargetGlucoseMgdl: Double,
         engineTrajectoryMgdl: [Double], sourceIdentity: String,
         treatmentAvailability: GlucoseForecastMLAvailabilityProvenance,
         settingsAvailability: GlucoseForecastMLAvailabilityProvenance,
         bolusUnitsInWindow: Double = 0, carbohydrateGramsInWindow: Double = 0) {
        self.row = row
        self.targetDate = targetDate
        self.targetGlucoseMgdl = targetGlucoseMgdl
        self.engineTargetGlucoseMgdl = engineTargetGlucoseMgdl
        self.engineTrajectoryMgdl = engineTrajectoryMgdl
        self.sourceIdentity = sourceIdentity
        self.treatmentAvailability = treatmentAvailability
        self.settingsAvailability = settingsAvailability
        self.bolusUnitsInWindow = bolusUnitsInWindow
        self.carbohydrateGramsInWindow = carbohydrateGramsInWindow
    }
}

struct GlucoseForecastMLReplayBatch: Sendable {
    let examples: [GlucoseForecastMLReplayExample]
    /// Carry this across bounded fetch chunks so anchor spacing is global.
    let lastAnchorDate: Date?
}

enum GlucoseForecastMLReplay {
    // A fixed ten-minute schedule meets the >=4-minute independence rule while
    // bounding 240 days of minute-cadence history to about 104k horizon rows.
    // It never down-samples the glucose inside a selected engine/feature window.
    static let minimumAnchorSpacing: TimeInterval = 10 * 60
    static let targetTolerance: TimeInterval = 2 * 60

    /// `observations` contains original saved readings, including hidden/invalid rows,
    /// plus 45 minutes before and 122 minutes after the half-open anchor interval.
    /// Every input feature and treatment is cut at the reference date. Later glucose
    /// is inspected solely to attach the target label.
    static func batch(observations: [GlucoseForecastGlucoseObservation],
                      treatments: [TherapyTreatment], settings: TherapyModelSettings,
                      sensitivityMgdlPerUnit: Double, carbohydrateRatioGramsPerUnit: Double,
                      anchorStart: Date, anchorEnd: Date, previousAnchorDate: Date? = nil,
                      calendar: Calendar = .current) -> GlucoseForecastMLReplayBatch {
        guard anchorStart < anchorEnd else {
            return GlucoseForecastMLReplayBatch(examples: [], lastAnchorDate: previousAnchorDate)
        }
        let ordered = observations.sorted { a, b in
            if a.date != b.date { return a.date < b.date }
            if a.sensorID != b.sensorID { return (a.sensorID ?? "") < (b.sensorID ?? "") }
            return a.glucoseMgdl < b.glucoseMgdl
        }
        var examples = [GlucoseForecastMLReplayExample]()
        var lastAnchorDate = previousAnchorDate
        var cursor = lowerBound(ordered, date: anchorStart)
        while cursor < ordered.count && ordered[cursor].date < anchorEnd {
            let anchorDate = ordered[cursor].date
            let groupEnd = upperBound(ordered, date: anchorDate)
            defer { cursor = groupEnd }
            guard let anchor = uniqueUsable(ordered[cursor..<groupEnd]),
                  let sensorID = anchor.sensorID, !sensorID.isEmpty,
                  lastAnchorDate.map({ anchorDate.timeIntervalSince($0) >= minimumAnchorSpacing }) ?? true
            else { continue }
            // Reserve the timestamp before forecast/target validation; skipped examples
            // cannot shift later anchors to a more favorable phase.
            lastAnchorDate = anchorDate
            let historyStart = anchorDate.addingTimeInterval(-GlucoseForecastGlucoseSelection.fetchWindow)
            let history = Array(ordered[lowerBound(ordered, date: historyStart)..<groupEnd])
            let glucose = GlucoseForecastGlucoseSelection.select(history, at: anchorDate)
            guard let selected = glucose.last, selected.date == anchorDate,
                  selected.sensorID == sensorID, selected.glucoseMgdl == anchor.glucoseMgdl
            else { continue }
            let treatmentStart = anchorDate.addingTimeInterval(
                -max(settings.insulinDuration, settings.carbDuration) * 60)
            // A local row edited after this anchor no longer contains its earlier value.
            // Skipping just that row would falsely claim zero treatment at the anchor;
            // discard the entire example instead. Legacy/Watch local rows without
            // created-at provenance are likewise not proof of a complete past input.
            let localWindow = treatments.filter {
                $0.isAppLocal && $0.date >= treatmentStart && $0.date <= anchorDate
            }
            guard !localWindow.contains(where: {
                guard let createdAt = $0.createdAt else { return true }
                if $0.isDeletedCurrentRevision { return createdAt <= anchorDate }
                return createdAt <= anchorDate && ($0.modifiedAt.map { $0 > anchorDate } ?? false)
            }) else { continue }
            // Imported Health history lacks reliable registration time. It remains
            // event-time based and is marked retrospective/unknown in the report.
            let knownByEventTime = GlucoseForecastDataAdapter.treatmentsKnownAtReference(
                treatments, from: treatmentStart, referenceDate: anchorDate)
            let input = GlucoseForecastInput(glucose: glucose, treatments: knownByEventTime,
                settings: settings, sensitivityMgdlPerUnit: sensitivityMgdlPerUnit,
                carbohydrateRatioGramsPerUnit: carbohydrateRatioGramsPerUnit,
                horizonMinutes: 120, now: anchorDate)
            let result = GlucoseForecastEngine.predict(input)
            guard result.reason == nil, result.referenceDate == anchorDate,
                  result.points.count == 25 else { continue }
            let trajectory = result.points.map(\.glucoseMgdl)
            var triple = [GlucoseForecastMLReplayExample]()
            for horizon in [30, 60, 120] {
                guard let row = GlucoseForecastMLFeatures.row(input: input, result: result,
                    horizonMinutes: horizon, calendar: calendar),
                    let target = nearestTarget(ordered, to: anchorDate.addingTimeInterval(
                        Double(horizon) * 60), sensorID: sensorID)
                else { break }
                triple.append(GlucoseForecastMLReplayExample(row: row,
                    targetDate: target.date, targetGlucoseMgdl: target.glucoseMgdl,
                    engineTargetGlucoseMgdl: row.engineValue,
                    engineTrajectoryMgdl: trajectory,
                    sourceIdentity: "sensor:" + sensorID,
                    treatmentAvailability: .retrospectiveUnknown,
                    settingsAvailability: .retrospectiveUnknown,
                    bolusUnitsInWindow: knownByEventTime.filter(\.isIOB)
                        .reduce(0) { $0 + $1.amount },
                    carbohydrateGramsInWindow: knownByEventTime.filter { !$0.isIOB }
                        .reduce(0) { $0 + $1.amount }))
            }
            if triple.count == 3 { examples.append(contentsOf: triple) }
        }
        return GlucoseForecastMLReplayBatch(examples: examples, lastAnchorDate: lastAnchorDate)
    }

    private static func uniqueUsable(_ group: ArraySlice<GlucoseForecastGlucoseObservation>)
        -> GlucoseForecastGlucoseObservation? {
        guard let first = group.first, first.isValidForDownstream,
              !first.isSuppressedByFiveMinuteCadence, first.glucoseMgdl.isFinite,
              first.glucoseMgdl > 0, group.allSatisfy({
                  $0.sensorID == first.sensorID && $0.glucoseMgdl == first.glucoseMgdl &&
                      $0.isValidForDownstream && !$0.isSuppressedByFiveMinuteCadence
              }) else { return nil }
        return first
    }

    private static func nearestTarget(_ ordered: [GlucoseForecastGlucoseObservation],
                                      to expected: Date, sensorID: String)
        -> GlucoseForecastGlucoseObservation? {
        let earliest = expected.addingTimeInterval(-targetTolerance)
        let latest = expected.addingTimeInterval(targetTolerance)
        var cursor = lowerBound(ordered, date: earliest)
        var best: GlucoseForecastGlucoseObservation?
        while cursor < ordered.count && ordered[cursor].date <= latest {
            let date = ordered[cursor].date
            let end = upperBound(ordered, date: date)
            if let candidate = uniqueUsable(ordered[cursor..<end]), candidate.sensorID == sensorID {
                let distance = abs(candidate.date.timeIntervalSince(expected))
                if best == nil || distance < abs(best!.date.timeIntervalSince(expected)) ||
                    (distance == abs(best!.date.timeIntervalSince(expected)) && candidate.date < best!.date) {
                    best = candidate
                }
            }
            cursor = end
        }
        return best
    }

    private static func lowerBound(_ samples: [GlucoseForecastGlucoseObservation], date: Date) -> Int {
        var low = 0, high = samples.count
        while low < high {
            let middle = low + (high - low) / 2
            if samples[middle].date < date { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private static func upperBound(_ samples: [GlucoseForecastGlucoseObservation], date: Date) -> Int {
        var low = 0, high = samples.count
        while low < high {
            let middle = low + (high - low) / 2
            if samples[middle].date <= date { low = middle + 1 } else { high = middle }
        }
        return low
    }
}
