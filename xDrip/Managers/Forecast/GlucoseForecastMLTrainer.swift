// Local Create ML training. All input rows and evaluation periods are chronological.
// Retrospective availability is recorded explicitly because historical imports do
// not prove when a treatment or settings choice became known to the app.
import Foundation
import CoreML
#if canImport(CreateML)
import CreateML
import Combine
import TabularData
#endif

/// Session compatibility is needed on simulator builds where Create ML itself
/// is unavailable. Keep the recipe identity independent of the fitting type.
enum GlucoseForecastMLTrainingRecipe {
    static let randomSeed = 42
    static let maxDepth = 6
    static let maxIterations = 400
    static let minChildWeight = 50.0
    static let stepSize = 0.05
    static let checkpointInterval = 50
    /// Bump when fold formation, targets, or fit semantics change without a
    /// feature/engine version change; old Create ML sessions must not resume.
    static let revision = 1
    static var signature: String {
        "\(revision)|\(maxDepth)|\(maxIterations)|\(minChildWeight)|"
            + "\(stepSize)|\(randomSeed)|\(checkpointInterval)"
    }
}

enum GlucoseForecastMLTrainingFailure: String, Error, Sendable {
    case insufficientHistory
    case insufficientTrainingRows
    case insufficientCalibrationRows
    case insufficientSelfCheckRows
    case insufficientWalkForwardRows
    case invalidFeatureRow
    case invalidModelOutput
    case trainingUnavailable
    case trainingProducedNoModel
    case packageInvalid
    case io
}

/// A count or freshness gate is reported with the exact period and horizon
/// that failed. This is deliberately separate from the legacy error codes so
/// a user never sees five different causes as one "not enough history" error.
struct GlucoseForecastMLTrainingIssue: Error, Sendable {
    enum Phase: Sendable, Equatable {
        case history, training, walkForward, calibration, selfCheck, freshness
    }
    enum Unit: Sendable, Equatable {
        case usableDays, rows, residuals, calibrationPredictions, ageHours, spanDays
    }

    let phase: Phase
    let horizonMinutes: Int?
    let fold: Int?
    let actual: Int
    let required: Int
    let unit: Unit
    let periodStart: Date?
    let periodEnd: Date?

    init(_ phase: Phase, horizonMinutes: Int? = nil, fold: Int? = nil,
         actual: Int, required: Int, unit: Unit,
         periodStart: Date? = nil, periodEnd: Date? = nil) {
        self.phase = phase
        self.horizonMinutes = horizonMinutes
        self.fold = fold
        self.actual = actual
        self.required = required
        self.unit = unit
        self.periodStart = periodStart
        self.periodEnd = periodEnd
    }

    var danishMessage: String {
        let name: String
        switch phase {
        case .history: name = "Historik"
        case .training: name = "Træning"
        case .walkForward: name = "Tidsopdelt træning"
        case .calibration: name = "Kalibrering"
        case .selfCheck: name = "Selvtjek"
        case .freshness: name = "Datafriskhed"
        }
        var label = name
        if let horizonMinutes { label += " (+\(horizonMinutes))" }
        if let fold { label += " · fold \(fold)" }
        let quantity: String
        switch unit {
        case .usableDays: quantity = "\(actual) af \(required) brugbare dage"
        case .rows: quantity = "\(actual) af \(required) rækker"
        case .residuals: quantity = "\(actual) af \(required) residualer"
        case .calibrationPredictions: quantity = "\(actual) af \(required) gyldige kalibreringsprognoser"
        case .ageHours: quantity = "seneste anker er \(actual) timer gammelt (højst \(required) timer)"
        case .spanDays: quantity = "kalibrering og selvtjek spænder over \(actual) kalenderdage (højst \(required))"
        }
        let dates: String
        if let periodStart {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "da_DK")
            formatter.timeZone = .current
            formatter.dateFormat = "dd.MM.yyyy"
            dates = " (\(formatter.string(from: periodStart))–\(formatter.string(from: periodEnd ?? periodStart)))"
        } else {
            dates = ""
        }
        return "\(label): \(quantity)\(dates)."
    }
}

struct GlucoseForecastMLContext: Codable, Equatable, Sendable {
    let engineVersion: String
    let featureVersion: String
    let sourceSignature: String
    let sensitivityMgdlPerUnit: Double
    let carbohydrateRatioGramsPerUnit: Double
    let insulinDurationMinutes: Double
    let insulinPeakMinutes: Double
    let carbohydrateDurationMinutes: Double

    init?(sensitivityMgdlPerUnit: Double, carbohydrateRatioGramsPerUnit: Double,
          settings: TherapyModelSettings, sourceSignature: String) {
        guard !sourceSignature.isEmpty, sensitivityMgdlPerUnit.isFinite, sensitivityMgdlPerUnit > 0,
              carbohydrateRatioGramsPerUnit.isFinite, carbohydrateRatioGramsPerUnit > 0,
              settings.validInsulin, settings.validCarbs else { return nil }
        engineVersion = GlucoseForecastEngine.engineVersion
        featureVersion = GlucoseForecastMLFeatures.featureVersion
        self.sourceSignature = sourceSignature
        self.sensitivityMgdlPerUnit = sensitivityMgdlPerUnit
        self.carbohydrateRatioGramsPerUnit = carbohydrateRatioGramsPerUnit
        insulinDurationMinutes = settings.insulinDuration
        insulinPeakMinutes = settings.insulinPeak
        carbohydrateDurationMinutes = settings.carbDuration
    }

    init?(input: GlucoseForecastInput, sourceSignature: String) {
        guard let sensitivity = input.sensitivityMgdlPerUnit,
              let ratio = input.carbohydrateRatioGramsPerUnit else { return nil }
        self.init(sensitivityMgdlPerUnit: sensitivity, carbohydrateRatioGramsPerUnit: ratio,
                  settings: input.settings, sourceSignature: sourceSignature)
    }
}

struct GlucoseForecastMLCalibration: Codable, Sendable {
    let multiplier: Double
    let count: Int
    let method: String
    let observedCoverage: Double
}

struct GlucoseForecastMLHorizonMetrics: Codable, Sendable {
    let count: Int
    let engineMAE: Double
    let candidateMAE: Double
    let activeMAE: Double?
    let candidateBias: Double
    let candidateCoverage: Double
    let medianBandWidthMgdl: Double
    let candidateFallbackCount: Int
    let activeFallbackCount: Int?
    // Optional so a 4294 package remains readable. New reviews always fill them.
    let engineBias: Double?
    let unchangedMAE: Double?
    let unchangedBias: Double?
}

/// MAE and signed error always use the identical reference/actual pairs.
struct GlucoseForecastMLFairAccuracy: Equatable {
    let count: Int
    let maeMgdl: Double
    let signedErrorMgdl: Double

    static func measure(predictions: [Double], actuals: [Double]) -> Self? {
        guard !predictions.isEmpty, predictions.count == actuals.count,
              predictions.allSatisfy(\.isFinite), actuals.allSatisfy(\.isFinite) else { return nil }
        let errors = zip(predictions, actuals).map(-)
        let denominator = Double(errors.count)
        return Self(count: errors.count,
                    maeMgdl: errors.reduce(0) { $0 + abs($1) } / denominator,
                    signedErrorMgdl: errors.reduce(0, +) / denominator)
    }
}

struct GlucoseForecastMLSelfCheck: Codable, Sendable {
    let startedAt: Date
    let endedAt: Date
    /// Last reference anchor, distinct from the last matched target in endedAt.
    let referenceEndAt: Date?
    let horizons: [Int: GlucoseForecastMLHorizonMetrics]
    let activeComparisonWasFair: Bool
    let promoted: Bool
    let rejectionReasons: [String]
    let retrospectiveUnknownCount: Int

    init(startedAt: Date, endedAt: Date, referenceEndAt: Date? = nil,
         horizons: [Int: GlucoseForecastMLHorizonMetrics],
         activeComparisonWasFair: Bool, promoted: Bool,
         rejectionReasons: [String], retrospectiveUnknownCount: Int) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.referenceEndAt = referenceEndAt
        self.horizons = horizons
        self.activeComparisonWasFair = activeComparisonWasFair
        self.promoted = promoted
        self.rejectionReasons = rejectionReasons
        self.retrospectiveUnknownCount = retrospectiveUnknownCount
    }
}

/// One immutable C-period anchor. This is only exported on explicit share;
/// it is never sent to HealthKit, Nightscout, Watch or Git.
struct GlucoseForecastMLReviewRow: Sendable {
    let referenceDate: Date
    let sourceIdentity: String
    let glucoseMgdl: Double
    let engineMgdl: [Int: Double]
    let mlMgdl: [Int: Double]
    let actualMgdl: [Int: Double]
    let actualDate: [Int: Date]
    let iobUnits: Double
    let cobGrams: Double
    let bolusUnitsInWindow: Double
    let carbohydrateGramsInWindow: Double
}

enum GlucoseForecastMLReviewCSV {
    static let header = "reference_utc,source_identity,engine_version,feature_version,source_signature,isf_mgdl_per_unit,carb_ratio_grams_per_unit,insulin_model,insulin_peak_minutes,insulin_duration_minutes,carb_duration_minutes,reference_glucose_mgdl,engine_30_mgdl,engine_60_mgdl,engine_120_mgdl,ml_30_mgdl,ml_60_mgdl,ml_120_mgdl,actual_30_mgdl,actual_60_mgdl,actual_120_mgdl,actual_30_utc,actual_60_utc,actual_120_utc,iob_units,cob_grams,bolus_units_in_window,carbohydrate_grams_in_window\r\n"

    static func data(_ rows: [GlucoseForecastMLReviewRow],
                     context: GlucoseForecastMLContext) -> Data? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        func number(_ value: Double?) -> String {
            guard let value, value.isFinite else { return "" }
            return String(value)
        }
        func cell(_ value: String) -> String {
            if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
                return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }
            return value
        }
        var csv = header
        for row in rows {
            let fields = [formatter.string(from: row.referenceDate), row.sourceIdentity,
                context.engineVersion, context.featureVersion, context.sourceSignature,
                number(context.sensitivityMgdlPerUnit),
                number(context.carbohydrateRatioGramsPerUnit),
                TherapyInsulinPreset.nearest(to: context.insulinPeakMinutes).rawValue,
                number(context.insulinPeakMinutes), number(context.insulinDurationMinutes),
                number(context.carbohydrateDurationMinutes), number(row.glucoseMgdl)]
                + [30, 60, 120].map { number(row.engineMgdl[$0]) }
                + [30, 60, 120].map { number(row.mlMgdl[$0]) }
                + [30, 60, 120].map { number(row.actualMgdl[$0]) }
                + [30, 60, 120].map { row.actualDate[$0].map(formatter.string(from:)) ?? "" }
                + [number(row.iobUnits), number(row.cobGrams),
                   number(row.bolusUnitsInWindow), number(row.carbohydrateGramsInWindow)]
            csv += fields.map(cell).joined(separator: ",") + "\r\n"
        }
        return csv.data(using: .utf8)
    }
}

struct GlucoseForecastMLModelMetadata: Codable, Sendable {
    // Historical input formation changed: older model packages and checkpoints
    // can include treatment windows whose availability was not established.
    static let schemaVersion = 3
    let schemaVersion: Int
    let modelID: String
    let trainedAt: Date
    let context: GlucoseForecastMLContext
    let featureNames: [String]
    let trainingStart: Date
    let trainingEnd: Date
    let calibrationStart: Date
    let calibrationEnd: Date
    let usableDayCount: Int
    let trainingCounts: [Int: Int]
    let walkForwardCounts: [Int: Int]
    let calibrationCounts: [Int: Int]
    let selfCheckCounts: [Int: Int]
    let calibrations: [Int: GlucoseForecastMLCalibration]
    let selfCheck: GlucoseForecastMLSelfCheck
    let retrospectiveUnknownCount: Int
}

/// Split by complete usable anchors, then by whole local calendar days. A
/// target that reaches into B or C is excluded from the earlier period,
/// including the allowed ±2-minute target join.
enum GlucoseForecastMLChronology {
    static let horizons = [30, 60, 120]
    static let minimumUsableDays = 60
    static let minimumTrainingRows = 300
    static let minimumCalibrationRows = 100
    static let minimumSelfCheckRows = 100
    static let minimumWalkForwardRows = 100
    static let correctionLimitMgdl = 27.0
    static let errorFloorMgdl = 1.0
    static let modelAgeLimit: TimeInterval = 7 * 24 * 60 * 60
    static let maximumRecentAnchorAge: TimeInterval = 48 * 60 * 60
    static let maximumBCSpanDays = 60

    struct CompleteAnchor {
        let rows: [Int: GlucoseForecastMLReplayExample]
        let engineTrajectory: [Double]

        var referenceDate: Date { rows[30]!.row.referenceDate }
        func example(at horizon: Int) -> GlucoseForecastMLReplayExample { rows[horizon]! }
    }

    /// A single reference is usable only when all three horizons originate
    /// from the same source, sensor segment and engine trajectory. This one
    /// definition is used for period selection and the actual model replay.
    static func completeAnchors(_ examples: [GlucoseForecastMLReplayExample]) -> [CompleteAnchor] {
        let grouped = Dictionary(grouping: examples, by: { $0.row.referenceDate })
        return grouped.keys.sorted().compactMap { referenceDate in
            guard let rows = grouped[referenceDate], rows.count == horizons.count,
                  Set(rows.map { $0.row.horizonMinutes }) == Set(horizons),
                  let first = rows.first,
                  rows.allSatisfy({ $0.sourceIdentity == first.sourceIdentity
                      && $0.row.sensorID == first.row.sensorID
                      && $0.engineTrajectoryMgdl == first.engineTrajectoryMgdl }) else {
                return nil
            }
            return CompleteAnchor(rows: Dictionary(uniqueKeysWithValues:
                rows.map { ($0.row.horizonMinutes, $0) }),
                engineTrajectory: first.engineTrajectoryMgdl)
        }
    }

    struct Knot {
        let minute: Int
        let correction: Double
        let halfWidth: Double
    }

    struct Overlay {
        let central: [Double]
        let halfWidth: [Double]
    }

    /// Shared by live inference and C. Any bad knot or intermediate point
    /// rejects the entire forecast; no central value is clipped to the range.
    static func assemble(engine: [Double], knots: [Knot], horizonMinutes: Int) -> Overlay? {
        guard [60, 120].contains(horizonMinutes),
              engine.count == horizonMinutes / 5 + 1,
              knots.first?.minute == 0, knots.last?.minute == horizonMinutes,
              knots.count == (horizonMinutes == 60 ? 3 : 4),
              knots.map(\.minute) == (horizonMinutes == 60 ? [0, 30, 60] : [0, 30, 60, 120]),
              knots.allSatisfy({ $0.correction.isFinite && $0.halfWidth.isFinite
                  && $0.halfWidth >= 0 && abs($0.correction) <= correctionLimitMgdl }) else {
            return nil
        }
        var central = [Double]()
        var widths = [Double]()
        for (index, baseline) in engine.enumerated() {
            let minute = index * 5
            guard let upperIndex = knots.firstIndex(where: { $0.minute >= minute }) else { return nil }
            let upper = knots[upperIndex]
            let lower = upperIndex == 0 ? upper : knots[upperIndex - 1]
            let fraction = upper.minute == lower.minute ? 0
                : Double(minute - lower.minute) / Double(upper.minute - lower.minute)
            let correction = lower.correction + fraction * (upper.correction - lower.correction)
            let width = lower.halfWidth + fraction * (upper.halfWidth - lower.halfWidth)
            let value = baseline + correction
            guard value.isFinite, (20...600).contains(value), width.isFinite, width >= 0 else {
                return nil
            }
            central.append(value)
            widths.append(width)
        }
        return Overlay(central: central, halfWidth: widths)
    }

    struct Split {
        let a: [Int: [GlucoseForecastMLReplayExample]]
        let b: [Int: [GlucoseForecastMLReplayExample]]
        let c: [Int: [GlucoseForecastMLReplayExample]]
        let bStart: Date
        let cStart: Date
        let usableDayCount: Int
        let retrospectiveUnknownCount: Int
    }

    static func split(_ examples: [GlucoseForecastMLReplayExample],
                      calendar: Calendar = .current, now: Date = .now) throws -> Split {
        let featureCount = GlucoseForecastMLFeatures.featureNames.count
        guard featureCount == 16 else { throw GlucoseForecastMLTrainingFailure.invalidFeatureRow }
        let valid = examples.filter { example in
            let row = example.row
            return horizons.contains(row.horizonMinutes)
                && row.values.count == featureCount && row.values.allSatisfy(\.isFinite)
                && row.glucose.isFinite && row.engineValue.isFinite
                && example.targetGlucoseMgdl.isFinite
                && (20...600).contains(example.targetGlucoseMgdl)
                && example.engineTargetGlucoseMgdl.isFinite
                && abs(example.engineTargetGlucoseMgdl - row.engineValue) < 0.001
                && example.engineTrajectoryMgdl.count == 25
                && example.engineTrajectoryMgdl.allSatisfy(\.isFinite)
                && abs(example.engineTrajectoryMgdl[row.horizonMinutes / 5] - row.engineValue) < 0.001
                && example.targetDate > row.referenceDate
                && abs(example.targetDate.timeIntervalSince(row.referenceDate)
                       - Double(row.horizonMinutes * 60)) <= 120
        }
        let anchors = completeAnchors(valid)
        let byDay = Dictionary(grouping: anchors, by: { calendar.startOfDay(for: $0.referenceDate) })
        let days = byDay.keys.sorted()
        let historyStart = days.first
        let historyEnd = days.last
        guard days.count >= minimumUsableDays else {
            throw GlucoseForecastMLTrainingIssue(.history, actual: days.count,
                required: minimumUsableDays, unit: .usableDays,
                periodStart: historyStart, periodEnd: historyEnd)
        }

        // C and B choose the latest distinct days with a complete three-knot
        // anchor. A gap in calendar time does not consume a usable day. The
        // B candidate immediately before C can lose all anchors to the target
        // embargo, so select its replacement farther back before fixing B.
        let cDays = Array(days.suffix(14))
        let cStart = cDays[0]
        let latestCAnchor = cDays.compactMap { byDay[$0]?.last?.referenceDate }.max()!
        let age = now.timeIntervalSince(latestCAnchor)
        if !age.isFinite || age < 0 || age > maximumRecentAnchorAge {
            throw GlucoseForecastMLTrainingIssue(.freshness,
                actual: age.isFinite ? max(0, Int(ceil(age / 3600))) : Int.max,
                required: 48,
                unit: .ageHours, periodStart: cStart, periodEnd: cDays.last)
        }
        let cAnchors = cDays.flatMap { byDay[$0] ?? [] }
        let eligibleBDays = days.filter { day in
            day < cStart && (byDay[day] ?? []).contains {
                $0.referenceDate.addingTimeInterval(120 * 60 + 120) < cStart
            }
        }
        let bDays = Array(eligibleBDays.suffix(14))
        guard let bStart = bDays.first else {
            throw GlucoseForecastMLTrainingIssue(.calibration,
                actual: 0, required: 10, unit: .usableDays,
                periodStart: historyStart, periodEnd: cStart)
        }
        let bAnchors = bDays.flatMap { byDay[$0] ?? [] }.filter {
            $0.referenceDate.addingTimeInterval(120 * 60 + 120) < cStart
        }
        let aAnchors = anchors.filter {
            $0.referenceDate < bStart
                && $0.referenceDate.addingTimeInterval(120 * 60 + 120) < bStart
        }
        let retainedAnchors = aAnchors + bAnchors + cAnchors
        let retainedDays = Set(retainedAnchors.map { calendar.startOfDay(for: $0.referenceDate) })
        guard retainedDays.count >= minimumUsableDays else {
            throw GlucoseForecastMLTrainingIssue(.history, actual: retainedDays.count,
                required: minimumUsableDays, unit: .usableDays,
                periodStart: retainedDays.min(), periodEnd: retainedDays.max())
        }
        let bcSpan = calendar.dateComponents([.day], from: bStart, to: cDays.last!).day! + 1
        guard bcSpan <= maximumBCSpanDays else {
            throw GlucoseForecastMLTrainingIssue(.freshness, actual: bcSpan,
                required: maximumBCSpanDays, unit: .spanDays,
                periodStart: bStart, periodEnd: cDays.last)
        }
        var a = [Int: [GlucoseForecastMLReplayExample]]()
        var b = [Int: [GlucoseForecastMLReplayExample]]()
        var c = [Int: [GlucoseForecastMLReplayExample]]()
        for horizon in horizons { a[horizon] = []; b[horizon] = []; c[horizon] = [] }
        for (periodAnchors, period) in [(aAnchors, 0), (bAnchors, 1), (cAnchors, 2)] {
            for anchor in periodAnchors {
                for horizon in horizons {
                    switch period {
                    case 0: a[horizon, default: []].append(anchor.example(at: horizon))
                    case 1: b[horizon, default: []].append(anchor.example(at: horizon))
                    default: c[horizon, default: []].append(anchor.example(at: horizon))
                    }
                }
            }
        }
        for horizon in horizons {
            for (phase, period, minimumDays, minimumRows) in [
                (GlucoseForecastMLTrainingIssue.Phase.training, a[horizon] ?? [], 30, minimumTrainingRows),
                (.calibration, b[horizon] ?? [], 10, minimumCalibrationRows),
                (.selfCheck, c[horizon] ?? [], 10, minimumSelfCheckRows)
            ] {
                let periodDays = Set(period.map { calendar.startOfDay(for: $0.row.referenceDate) })
                let periodStart = period.first?.row.referenceDate ??
                    (phase == .calibration ? bStart : phase == .selfCheck ? cStart : historyStart)
                let periodEnd = period.last?.row.referenceDate
                guard periodDays.count >= minimumDays else {
                    throw GlucoseForecastMLTrainingIssue(phase, horizonMinutes: horizon,
                        actual: periodDays.count, required: minimumDays,
                        unit: .usableDays, periodStart: periodStart, periodEnd: periodEnd)
                }
                guard period.count >= minimumRows else {
                    throw GlucoseForecastMLTrainingIssue(phase, horizonMinutes: horizon,
                        actual: period.count, required: minimumRows,
                        unit: .rows, periodStart: periodStart, periodEnd: periodEnd)
                }
            }
        }
        let retained = horizons.flatMap { (a[$0] ?? []) + (b[$0] ?? []) + (c[$0] ?? []) }
        let unknown = retained.filter {
            $0.treatmentAvailability == .retrospectiveUnknown
                || $0.settingsAvailability == .retrospectiveUnknown
        }.count
        return Split(a: a, b: b, c: c, bStart: bStart, cStart: cStart,
                     usableDayCount: retainedDays.count, retrospectiveUnknownCount: unknown)
    }

    static func clampedCorrection(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return min(correctionLimitMgdl, max(-correctionLimitMgdl, value))
    }

    static func finalGlucose(engine: Double, correction: Double) -> Double? {
        guard engine.isFinite, let correction = clampedCorrection(correction) else { return nil }
        let central = engine + correction
        return (20...600).contains(central) ? central : nil
    }

    static func positiveError(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        return max(errorFloorMgdl, value)
    }

    static func percentile80(_ values: [Double]) -> Double? {
        let sorted = values.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard sorted.count == values.count, !sorted.isEmpty else { return nil }
        let index = max(0, Int(ceil(0.8 * Double(sorted.count))) - 1)
        return sorted[index]
    }

    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard sorted.count == values.count, !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

#if canImport(CreateML)
struct GlucoseForecastMLTrainedCandidate {
    let models: [String: MLBoostedTreeRegressor]
    let metadata: GlucoseForecastMLModelMetadata
    let reviewRows: [GlucoseForecastMLReviewRow]

    init(models: [String: MLBoostedTreeRegressor], metadata: GlucoseForecastMLModelMetadata,
         reviewRows: [GlucoseForecastMLReviewRow] = []) {
        self.models = models
        self.metadata = metadata
        self.reviewRows = reviewRows
    }
}

enum GlucoseForecastMLTrainer {
    static let targetColumn = "target"
    private typealias Recipe = GlucoseForecastMLTrainingRecipe

    /// A completed Create ML fit is only reused with the exact replay snapshot
    /// admitted by the enclosing training-session manifest. If completion was
    /// interrupted before this marker was written, Create ML resumes its last
    /// checkpoint instead of substituting an unverified partial model.
    private struct CompletedFit: Codable {
        static let schemaVersion = 1
        let schemaVersion: Int
        let checkpointRelativePath: String
        let iteration: Int
    }

    static func key(_ kind: String, _ horizon: Int) -> String { "\(kind)_\(horizon)" }

    private typealias ReplayAnchor = GlucoseForecastMLChronology.CompleteAnchor

    private struct ReplayLine {
        let overlay: GlucoseForecastMLChronology.Overlay
        let predictedErrors: [Int: Double]

        func central(at horizon: Int) -> Double { overlay.central[horizon / 5] }
        func halfWidth(at horizon: Int) -> Double { overlay.halfWidth[horizon / 5] }
    }

    /// A period boundary can embargo the 120-minute row while retaining shorter
    /// rows. Score only complete anchors so every replayed knot came from the same
    /// reference and the same engine run.
    private static func completeAnchors(_ period: [Int: [GlucoseForecastMLReplayExample]])
        -> [ReplayAnchor] {
        GlucoseForecastMLChronology.completeAnchors(
            GlucoseForecastMLChronology.horizons.flatMap { period[$0] ?? [] })
    }

    /// This follows live inference: validate each needed correction and error,
    /// then interpolate every five-minute point. A single bad knot or point
    /// makes the entire selected forecast fall back to its engine trajectory.
    private static func replayLine(anchor: ReplayAnchor, horizonMinutes: Int,
                                   multiplier: (Int) -> Double?,
                                   prediction: (String, Int, GlucoseForecastMLFeatureRow) -> Double?)
        -> ReplayLine? {
        guard [60, 120].contains(horizonMinutes) else { return nil }
        let selected = GlucoseForecastMLChronology.horizons.filter { $0 <= horizonMinutes }
        var knots = [GlucoseForecastMLChronology.Knot(minute: 0, correction: 0, halfWidth: 0)]
        var errors = [Int: Double]()
        for horizon in selected {
            let example = anchor.example(at: horizon)
            guard let correction = prediction("correction", horizon, example.row),
                  let capped = GlucoseForecastMLChronology.clampedCorrection(correction),
                  GlucoseForecastMLChronology.finalGlucose(
                    engine: example.engineTargetGlucoseMgdl, correction: correction) != nil,
                  let rawError = prediction("error", horizon, example.row),
                  let error = GlucoseForecastMLChronology.positiveError(rawError),
                  let scale = multiplier(horizon), scale.isFinite, scale > 0 else { return nil }
            let width = error * scale
            guard width.isFinite, width >= 0 else { return nil }
            knots.append(GlucoseForecastMLChronology.Knot(
                minute: horizon, correction: capped, halfWidth: width))
            errors[horizon] = error
        }
        let engine = Array(anchor.engineTrajectory.prefix(horizonMinutes / 5 + 1))
        guard let overlay = GlucoseForecastMLChronology.assemble(
            engine: engine, knots: knots, horizonMinutes: horizonMinutes) else { return nil }
        return ReplayLine(overlay: overlay, predictedErrors: errors)
    }

    static func train(examples: [GlucoseForecastMLReplayExample],
                      context: GlucoseForecastMLContext,
                      active: GlucoseForecastMLLoadedBundle?,
                      sessionsDirectory: URL,
                      now: Date = .now,
                      onProgress: @escaping @Sendable (GlucoseForecastMLTrainingProgress) -> Void = { _ in })
        async throws -> GlucoseForecastMLTrainedCandidate {
        let split = try GlucoseForecastMLChronology.split(examples, now: now)
        try GlucoseForecastMLStoragePolicy.secureDirectory(sessionsDirectory)
        var models = [String: MLBoostedTreeRegressor]()
        var walkCounts = [Int: Int]()
        var trainingCounts = [Int: Int]()
        var completedModels = 0
        let totalModels = 12
        func modelCompleted() {
            completedModels += 1
            onProgress(.trainingModels(completed: completedModels, total: totalModels))
        }
        let fairActive = active.map {
            $0.metadata.context == context
                && $0.metadata.trainedAt < split.cStart
                && $0.metadata.trainingEnd < split.cStart
                && $0.metadata.calibrationEnd < split.cStart
        } ?? false

        // Every fold fits all three corrections from labels known before its
        // origin. Its complete holdout anchors then use the same 60/120-minute
        // assembly and whole-line fallback as live inference. Error models learn
        // the resulting out-of-sample residual, including any engine fallback.
        let aAnchors = completeAnchors(split.a)
        guard aAnchors.count >= GlucoseForecastMLChronology.minimumTrainingRows else {
            throw GlucoseForecastMLTrainingIssue(.walkForward,
                actual: aAnchors.count,
                required: GlucoseForecastMLChronology.minimumTrainingRows,
                unit: .rows, periodStart: aAnchors.first?.referenceDate,
                periodEnd: split.bStart)
        }
        let foldDates = [0.5, 0.75].map { fraction in
            aAnchors[Int(Double(aAnchors.count - 1) * fraction)]
                .example(at: 30).row.referenceDate
        }
        var outOfSample = [Int: [(GlucoseForecastMLReplayExample, Double)]]()
        for horizon in GlucoseForecastMLChronology.horizons { outOfSample[horizon] = [] }
        for (index, origin) in foldDates.enumerated() {
            try Task.checkCancellation()
            let end = index + 1 < foldDates.count ? foldDates[index + 1] : split.bStart
            var foldModels = [Int: MLBoostedTreeRegressor]()
            for horizon in GlucoseForecastMLChronology.horizons {
                let prefix = (split.a[horizon] ?? []).filter {
                    $0.row.referenceDate.addingTimeInterval(Double(horizon * 60 + 120)) < origin
                }
                guard prefix.count >= 200 else {
                    throw GlucoseForecastMLTrainingIssue(.walkForward,
                        horizonMinutes: horizon, fold: index + 1,
                        actual: prefix.count, required: 200, unit: .rows,
                        periodStart: aAnchors.first?.referenceDate,
                        periodEnd: origin)
                }
                foldModels[horizon] = try await fit(prefix,
                    targets: prefix.map { $0.targetGlucoseMgdl - $0.engineTargetGlucoseMgdl },
                    sessionDirectory: sessionsDirectory.appendingPathComponent("walk_\(horizon)_\(index)"))
                modelCompleted()
            }
            let holdout = aAnchors.filter {
                let reference = $0.example(at: 30).row.referenceDate
                return reference >= origin
                    && reference.addingTimeInterval(120 * 60 + 120) < end
            }
            guard !holdout.isEmpty else {
                throw GlucoseForecastMLTrainingIssue(.walkForward,
                    fold: index + 1, actual: 0, required: 1, unit: .rows,
                    periodStart: origin, periodEnd: end)
            }
            let foldPrediction: (String, Int, GlucoseForecastMLFeatureRow) -> Double? = {
                kind, horizon, row in
                // Width is irrelevant to the center; unit values let the shared
                // assembler validate the line before error models exist.
                if kind == "error" { return 1 }
                guard let model = foldModels[horizon] else { return nil }
                return predict(model.model, row: row)
            }
            for anchor in holdout {
                for horizon in GlucoseForecastMLChronology.horizons {
                    let example = anchor.example(at: horizon)
                    let line = replayLine(anchor: anchor,
                        horizonMinutes: horizon == 120 ? 120 : 60,
                        multiplier: { _ in 1 }, prediction: foldPrediction)
                    let central = line?.central(at: horizon) ?? example.engineTargetGlucoseMgdl
                    let error = max(GlucoseForecastMLChronology.errorFloorMgdl,
                                    abs(example.targetGlucoseMgdl - central))
                    outOfSample[horizon, default: []].append((example, error))
                }
            }
        }
        for horizon in GlucoseForecastMLChronology.horizons {
            try Task.checkCancellation()
            let a = split.a[horizon] ?? []
            let residuals = outOfSample[horizon] ?? []
            guard residuals.count >= GlucoseForecastMLChronology.minimumWalkForwardRows else {
                throw GlucoseForecastMLTrainingIssue(.walkForward,
                    horizonMinutes: horizon, actual: residuals.count,
                    required: GlucoseForecastMLChronology.minimumWalkForwardRows,
                    unit: .residuals, periodStart: aAnchors.first?.referenceDate,
                    periodEnd: split.bStart)
            }
            trainingCounts[horizon] = a.count
            walkCounts[horizon] = residuals.count
            models[key("correction", horizon)] = try await fit(a,
                targets: a.map { $0.targetGlucoseMgdl - $0.engineTargetGlucoseMgdl },
                sessionDirectory: sessionsDirectory.appendingPathComponent("correction_\(horizon)"))
            modelCompleted()
            models[key("error", horizon)] = try await fit(residuals.map(\.0),
                targets: residuals.map(\.1),
                sessionDirectory: sessionsDirectory.appendingPathComponent("error_\(horizon)"))
            modelCompleted()
        }

        onProgress(.calibrating)
        let bAnchors = completeAnchors(split.b)
        let cAnchors = completeAnchors(split.c)
        guard bAnchors.count >= GlucoseForecastMLChronology.minimumCalibrationRows else {
            throw GlucoseForecastMLTrainingIssue(.calibration,
                actual: bAnchors.count,
                required: GlucoseForecastMLChronology.minimumCalibrationRows,
                unit: .rows, periodStart: split.bStart,
                periodEnd: split.cStart)
        }
        guard cAnchors.count >= GlucoseForecastMLChronology.minimumSelfCheckRows else {
            throw GlucoseForecastMLTrainingIssue(.selfCheck,
                actual: cAnchors.count,
                required: GlucoseForecastMLChronology.minimumSelfCheckRows,
                unit: .rows, periodStart: split.cStart,
                periodEnd: cAnchors.last?.referenceDate)
        }
        let candidatePrediction: (String, Int, GlucoseForecastMLFeatureRow) -> Double? = {
            kind, horizon, row in
            guard let model = models[key(kind, horizon)] else { return nil }
            return predict(model.model, row: row)
        }

        // In B, use the complete 60-minute line for +30/+60 and the complete
        // 120-minute line for +120. Unit widths validate error predictions while
        // leaving the central line independent of the multiplier being fitted.
        var ratios = [Int: [Double]]()
        for horizon in GlucoseForecastMLChronology.horizons { ratios[horizon] = [] }
        for anchor in bAnchors {
            try Task.checkCancellation()
            for horizon in GlucoseForecastMLChronology.horizons {
                let lineMinutes = horizon == 120 ? 120 : 60
                guard let line = replayLine(anchor: anchor, horizonMinutes: lineMinutes,
                                            multiplier: { _ in 1 }, prediction: candidatePrediction),
                      let error = line.predictedErrors[horizon] else { continue }
                let example = anchor.example(at: horizon)
                ratios[horizon, default: []].append(
                    abs(example.targetGlucoseMgdl - line.central(at: horizon)) / error)
            }
        }
        var calibrations = [Int: GlucoseForecastMLCalibration]()
        var calibrationCounts = [Int: Int]()
        for horizon in GlucoseForecastMLChronology.horizons {
            let values = ratios[horizon] ?? []
            guard values.count >= GlucoseForecastMLChronology.minimumCalibrationRows,
                  let percentile = GlucoseForecastMLChronology.percentile80(values) else {
                throw GlucoseForecastMLTrainingIssue(.calibration,
                    horizonMinutes: horizon, actual: values.count,
                    required: GlucoseForecastMLChronology.minimumCalibrationRows,
                    unit: .calibrationPredictions,
                    periodStart: split.bStart,
                    periodEnd: bAnchors.last?.referenceDate)
            }
            calibrationCounts[horizon] = values.count
            calibrations[horizon] = GlucoseForecastMLCalibration(
                multiplier: max(0.01, percentile), count: values.count,
                method: "nearest-rank empirical 80th percentile of B full-line absolute-error / positive predicted error",
                observedCoverage: 0)
        }
        var coveredOnB = [Int: Int]()
        for anchor in bAnchors {
            try Task.checkCancellation()
            for horizon in GlucoseForecastMLChronology.horizons {
                let lineMinutes = horizon == 120 ? 120 : 60
                guard let line = replayLine(anchor: anchor, horizonMinutes: lineMinutes,
                                            multiplier: { calibrations[$0]?.multiplier },
                                            prediction: candidatePrediction) else { continue }
                let actual = anchor.example(at: horizon).targetGlucoseMgdl
                if abs(actual - line.central(at: horizon)) <= line.halfWidth(at: horizon) {
                    coveredOnB[horizon, default: 0] += 1
                }
            }
        }
        for horizon in GlucoseForecastMLChronology.horizons {
            let calibration = calibrations[horizon]!
            calibrations[horizon] = GlucoseForecastMLCalibration(
                multiplier: calibration.multiplier, count: calibration.count,
                method: calibration.method,
                observedCoverage: Double(coveredOnB[horizon, default: 0]) / Double(calibration.count))
        }

        onProgress(.selfChecking)
        var metrics = [Int: GlucoseForecastMLHorizonMetrics]()
        var selfCheckCounts = [Int: Int]()
        var rejections = [String]()
        var reviewMLValues = [Date: [Int: Double]]()
        for horizon in GlucoseForecastMLChronology.horizons {
            try Task.checkCancellation()
            let lineMinutes = horizon == 120 ? 120 : 60
            var actuals = [Double]()
            var candidatePredictions = [Double]()
            var enginePredictions = [Double]()
            var unchangedPredictions = [Double]()
            var activeAbsolute = [Double]()
            var candidateBiases = [Double]()
            var widths = [Double]()
            var covered = 0
            var candidateFallbacks = 0
            var activeFallbacks = 0
            for anchor in cAnchors {
                let example = anchor.example(at: horizon)
                let actual = example.targetGlucoseMgdl
                let baseline = example.engineTargetGlucoseMgdl
                actuals.append(actual)
                enginePredictions.append(baseline)
                unchangedPredictions.append(example.row.glucose)
                let candidateLine = replayLine(anchor: anchor, horizonMinutes: lineMinutes,
                    multiplier: { calibrations[$0]?.multiplier }, prediction: candidatePrediction)
                let candidateCentral: Double
                if let candidateLine {
                    candidateCentral = candidateLine.central(at: horizon)
                    let halfWidth = candidateLine.halfWidth(at: horizon)
                    widths.append(2 * halfWidth)
                    if abs(actual - candidateCentral) <= halfWidth { covered += 1 }
                } else {
                    candidateCentral = baseline
                    candidateFallbacks += 1
                }
                candidatePredictions.append(candidateCentral)
                reviewMLValues[anchor.referenceDate, default: [:]][horizon] = candidateCentral
                if let active, fairActive {
                    let activeLine = replayLine(anchor: anchor, horizonMinutes: lineMinutes,
                        multiplier: { selected in
                            guard let calibration = active.metadata.calibrations[selected],
                                  calibration.count >= GlucoseForecastMLChronology.minimumCalibrationRows
                            else { return nil }
                            return calibration.multiplier
                        }, prediction: { kind, selected, row in
                            active.prediction(kind: kind, horizon: selected, row: row)
                        })
                    if let activeLine {
                        activeAbsolute.append(abs(actual - activeLine.central(at: horizon)))
                    } else {
                        activeAbsolute.append(abs(actual - baseline))
                        activeFallbacks += 1
                    }
                }
            }
            guard let engineAccuracy = GlucoseForecastMLFairAccuracy.measure(
                    predictions: enginePredictions, actuals: actuals),
                  let candidateAccuracy = GlucoseForecastMLFairAccuracy.measure(
                    predictions: candidatePredictions, actuals: actuals),
                  let unchangedAccuracy = GlucoseForecastMLFairAccuracy.measure(
                    predictions: unchangedPredictions, actuals: actuals) else {
                throw GlucoseForecastMLTrainingFailure.invalidModelOutput
            }
            let mean: ([Double]) -> Double = { $0.reduce(0, +) / Double($0.count) }
            // With no successful ML line, every point falls back to the engine
            // and the candidate fails the improvement gate below.
            let medianWidth = GlucoseForecastMLChronology.median(widths) ?? 0
            let engineMAE = engineAccuracy.maeMgdl
            let candidateMAE = candidateAccuracy.maeMgdl
            let activeMAE = fairActive && activeAbsolute.count == cAnchors.count
                ? mean(activeAbsolute) : nil
            selfCheckCounts[horizon] = cAnchors.count
            metrics[horizon] = GlucoseForecastMLHorizonMetrics(
                count: cAnchors.count, engineMAE: engineMAE, candidateMAE: candidateMAE,
                activeMAE: activeMAE, candidateBias: candidateAccuracy.signedErrorMgdl,
                candidateCoverage: Double(covered) / Double(cAnchors.count),
                medianBandWidthMgdl: medianWidth,
                candidateFallbackCount: candidateFallbacks,
                activeFallbackCount: fairActive ? activeFallbacks : nil,
                engineBias: engineAccuracy.signedErrorMgdl,
                unchangedMAE: unchangedAccuracy.maeMgdl,
                unchangedBias: unchangedAccuracy.signedErrorMgdl)
            if !(candidateMAE < engineMAE) { rejections.append("candidateNotBetterThanEngineAt\(horizon)") }
            if let activeMAE, candidateMAE > activeMAE {
                rejections.append("candidateWorseThanActiveAt\(horizon)")
            }
        }
        guard let trainingStart = split.a.values.flatMap({ $0 }).map({ $0.row.referenceDate }).min(),
              let trainingEnd = split.a.values.flatMap({ $0 }).map({ $0.targetDate }).max(),
              let calibrationStart = bAnchors.first?.example(at: 30).row.referenceDate,
              let calibrationEnd = bAnchors.flatMap({ $0.rows.values }).map({ $0.targetDate }).max(),
              let testEnd = cAnchors.flatMap({ $0.rows.values }).map({ $0.targetDate }).max() else {
            throw GlucoseForecastMLTrainingIssue(.history,
                actual: 0, required: 1, unit: .rows,
                periodStart: split.bStart, periodEnd: split.cStart)
        }
        let report = GlucoseForecastMLSelfCheck(
            startedAt: split.cStart, endedAt: testEnd,
            referenceEndAt: cAnchors.last?.referenceDate, horizons: metrics,
            activeComparisonWasFair: fairActive, promoted: rejections.isEmpty,
            rejectionReasons: rejections, retrospectiveUnknownCount: split.retrospectiveUnknownCount)
        let reviewRows = cAnchors.map { anchor -> GlucoseForecastMLReviewRow in
            let first = anchor.example(at: 30)
            return GlucoseForecastMLReviewRow(
                referenceDate: anchor.referenceDate, sourceIdentity: first.sourceIdentity,
                glucoseMgdl: first.row.glucose,
                engineMgdl: Dictionary(uniqueKeysWithValues:
                    GlucoseForecastMLChronology.horizons.map { ($0, anchor.example(at: $0).engineTargetGlucoseMgdl) }),
                mlMgdl: reviewMLValues[anchor.referenceDate] ?? [:],
                actualMgdl: Dictionary(uniqueKeysWithValues:
                    GlucoseForecastMLChronology.horizons.map { ($0, anchor.example(at: $0).targetGlucoseMgdl) }),
                actualDate: Dictionary(uniqueKeysWithValues:
                    GlucoseForecastMLChronology.horizons.map { ($0, anchor.example(at: $0).targetDate) }),
                iobUnits: first.row.values[6], cobGrams: first.row.values[7],
                bolusUnitsInWindow: first.bolusUnitsInWindow,
                carbohydrateGramsInWindow: first.carbohydrateGramsInWindow)
        }
        let metadata = GlucoseForecastMLModelMetadata(
            schemaVersion: GlucoseForecastMLModelMetadata.schemaVersion,
            modelID: UUID().uuidString.lowercased(), trainedAt: now, context: context,
            featureNames: GlucoseForecastMLFeatures.featureNames,
            trainingStart: trainingStart, trainingEnd: trainingEnd,
            calibrationStart: calibrationStart, calibrationEnd: calibrationEnd,
            usableDayCount: split.usableDayCount, trainingCounts: trainingCounts,
            walkForwardCounts: walkCounts, calibrationCounts: calibrationCounts,
            selfCheckCounts: selfCheckCounts, calibrations: calibrations,
            selfCheck: report, retrospectiveUnknownCount: split.retrospectiveUnknownCount)
        return GlucoseForecastMLTrainedCandidate(models: models, metadata: metadata,
                                                 reviewRows: reviewRows)
    }

    private static func fit(_ examples: [GlucoseForecastMLReplayExample],
                            targets: [Double],
                            sessionDirectory: URL) async throws -> MLBoostedTreeRegressor {
        try Task.checkCancellation()
        guard examples.count == targets.count,
              targets.allSatisfy(\.isFinite),
              examples.allSatisfy({ $0.row.values.count == GlucoseForecastMLFeatures.featureNames.count
                  && $0.row.values.allSatisfy(\.isFinite) }) else {
            throw GlucoseForecastMLTrainingFailure.invalidFeatureRow
        }
        try GlucoseForecastMLStoragePolicy.secureDirectory(sessionDirectory)
        // Reconstruct only a final checkpoint that was marked after the job
        // yielded a complete model. A bare checkpoint can still be resumed,
        // but is never treated as a finished fit.
        let sessionParameters = MLTrainingSessionParameters(sessionDirectory: sessionDirectory,
            reportInterval: 25, checkpointInterval: Recipe.checkpointInterval,
            iterations: Recipe.maxIterations)
        let completionURL = sessionDirectory.appendingPathComponent("completed-fit.json")
        if FileManager.default.fileExists(atPath: completionURL.path) {
            guard let markerData = try? Data(contentsOf: completionURL),
                  let marker = try? JSONDecoder().decode(CompletedFit.self, from: markerData),
                  marker.schemaVersion == CompletedFit.schemaVersion,
                  marker.iteration >= Recipe.maxIterations,
                  !marker.checkpointRelativePath.hasPrefix("/"),
                  !marker.checkpointRelativePath.split(separator: "/").contains(".."),
                  let restored = try? MLBoostedTreeRegressor.restoreTrainingSession(
                    sessionParameters: sessionParameters),
                  let checkpoint = restored.checkpoints.first(where: {
                    $0.iteration == marker.iteration
                        && $0.url.standardizedFileURL.path == sessionDirectory
                            .appendingPathComponent(marker.checkpointRelativePath)
                            .standardizedFileURL.path
                  }),
                  let model = try? MLBoostedTreeRegressor(checkpoint: checkpoint),
                  model.targetColumn == targetColumn,
                  model.featureColumns == GlucoseForecastMLFeatures.featureNames else {
                // A marked complete fit with unreadable state is a damaged
                // session, not permission to quietly reuse partial weights.
                throw GlucoseForecastMLTrainingFailure.packageInvalid
            }
            return model
        }
        // Create ML writes checkpoints as soon as the job starts.
        let job: MLJob<MLBoostedTreeRegressor>
        let entries = try FileManager.default.contentsOfDirectory(atPath: sessionDirectory.path)
        if !entries.isEmpty {
            guard let restored = try? MLBoostedTreeRegressor.restoreTrainingSession(
                sessionParameters: sessionParameters),
                  let resumed = try? MLBoostedTreeRegressor.resume(restored) else {
                throw GlucoseForecastMLTrainingFailure.packageInvalid
            }
            job = resumed
        } else {
            var data = DataFrame()
            for (index, name) in GlucoseForecastMLFeatures.featureNames.enumerated() {
                data.append(column: Column<Double>(name: name,
                    contents: examples.map { $0.row.values[index] }))
            }
            data.append(column: Column<Double>(name: targetColumn, contents: targets))
            let parameters = MLBoostedTreeRegressor.ModelParameters(
                validation: .none, maxDepth: Recipe.maxDepth,
                maxIterations: Recipe.maxIterations,
                minChildWeight: Recipe.minChildWeight,
                randomSeed: Recipe.randomSeed, stepSize: Recipe.stepSize)
            job = try MLBoostedTreeRegressor.train(
                trainingData: data, targetColumn: targetColumn,
                featureColumns: GlucoseForecastMLFeatures.featureNames,
                parameters: parameters, sessionParameters: sessionParameters)
        }
        let trained = try await withTaskCancellationHandler {
            for try await trained in job.result.values { return trained }
            throw GlucoseForecastMLTrainingFailure.trainingProducedNoModel
        } onCancel: { job.cancel() }
        // Create ML checkpoints every 50 iterations. A final checkpoint is
        // retained for the next launch only when it can recreate this model.
        if let restored = try? MLBoostedTreeRegressor.restoreTrainingSession(
            sessionParameters: sessionParameters),
           let checkpoint = restored.checkpoints.filter({ $0.iteration >= Recipe.maxIterations })
               .max(by: { $0.iteration < $1.iteration }),
           checkpoint.url.standardizedFileURL.path.hasPrefix(
               sessionDirectory.standardizedFileURL.path + "/"),
           (try? MLBoostedTreeRegressor(checkpoint: checkpoint)) != nil {
            let relative = String(checkpoint.url.standardizedFileURL.path.dropFirst(
                sessionDirectory.standardizedFileURL.path.count + 1))
            let marker = CompletedFit(schemaVersion: CompletedFit.schemaVersion,
                checkpointRelativePath: relative, iteration: checkpoint.iteration)
            if let data = try? JSONEncoder().encode(marker),
               (try? data.write(to: completionURL, options: .atomic)) != nil {
                #if os(iOS)
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: completionURL.path)
                #endif
            }
        }
        return trained
    }

    static func predict(_ model: MLModel, row: GlucoseForecastMLFeatureRow) -> Double? {
        guard row.values.count == GlucoseForecastMLFeatures.featureNames.count,
              row.values.allSatisfy(\.isFinite) else { return nil }
        do {
            let features = Dictionary(uniqueKeysWithValues:
                zip(GlucoseForecastMLFeatures.featureNames, row.values))
            let provider = try MLDictionaryFeatureProvider(dictionary: features)
            let output = try model.prediction(from: provider)
            let name = model.modelDescription.predictedFeatureName ?? targetColumn
            let value = output.featureValue(for: name)?.doubleValue
            return value?.isFinite == true ? value : nil
        } catch { return nil }
    }
}
#endif
