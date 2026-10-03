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
}

struct GlucoseForecastMLSelfCheck: Codable, Sendable {
    let startedAt: Date
    let endedAt: Date
    let horizons: [Int: GlucoseForecastMLHorizonMetrics]
    let activeComparisonWasFair: Bool
    let promoted: Bool
    let rejectionReasons: [String]
    let retrospectiveUnknownCount: Int
}

struct GlucoseForecastMLModelMetadata: Codable, Sendable {
    static let schemaVersion = 1
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

/// Split by whole local calendar days. A target that reaches into B or C is
/// excluded from the earlier period, including the allowed ±2-minute target join.
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
                      calendar: Calendar = .current) throws -> Split {
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
        var daysByHorizon = [Int: Set<Date>]()
        for horizon in horizons { daysByHorizon[horizon] = [] }
        for example in valid {
            daysByHorizon[example.row.horizonMinutes, default: []].insert(
                calendar.startOfDay(for: example.row.referenceDate))
        }
        let commonDays = horizons.dropFirst().reduce(daysByHorizon[horizons[0]] ?? []) {
            $0.intersection(daysByHorizon[$1] ?? [])
        }
        guard commonDays.count >= minimumUsableDays, let lastDay = commonDays.max(),
              let cStart = calendar.date(byAdding: .day, value: -13, to: lastDay),
              let bStart = calendar.date(byAdding: .day, value: -14, to: cStart) else {
            throw GlucoseForecastMLTrainingFailure.insufficientHistory
        }
        var a = [Int: [GlucoseForecastMLReplayExample]]()
        var b = [Int: [GlucoseForecastMLReplayExample]]()
        var c = [Int: [GlucoseForecastMLReplayExample]]()
        for horizon in horizons { a[horizon] = []; b[horizon] = []; c[horizon] = [] }
        for example in valid {
            let horizon = example.row.horizonMinutes
            let reference = example.row.referenceDate
            let latestPermittedTarget = reference.addingTimeInterval(Double(horizon * 60 + 120))
            if reference < bStart && latestPermittedTarget < bStart {
                a[horizon, default: []].append(example)
            } else if reference >= bStart && reference < cStart && latestPermittedTarget < cStart {
                b[horizon, default: []].append(example)
            } else if reference >= cStart {
                c[horizon, default: []].append(example)
            }
        }
        for horizon in horizons {
            a[horizon]?.sort { $0.row.referenceDate < $1.row.referenceDate }
            b[horizon]?.sort { $0.row.referenceDate < $1.row.referenceDate }
            c[horizon]?.sort { $0.row.referenceDate < $1.row.referenceDate }
            guard (a[horizon]?.count ?? 0) >= minimumTrainingRows else {
                throw GlucoseForecastMLTrainingFailure.insufficientTrainingRows
            }
            guard (b[horizon]?.count ?? 0) >= minimumCalibrationRows else {
                throw GlucoseForecastMLTrainingFailure.insufficientCalibrationRows
            }
            guard (c[horizon]?.count ?? 0) >= minimumSelfCheckRows else {
                throw GlucoseForecastMLTrainingFailure.insufficientSelfCheckRows
            }
            let countDays: ([GlucoseForecastMLReplayExample]) -> Int = {
                Set($0.map { calendar.startOfDay(for: $0.row.referenceDate) }).count
            }
            guard countDays(a[horizon] ?? []) >= 30 else {
                throw GlucoseForecastMLTrainingFailure.insufficientTrainingRows
            }
            guard countDays(b[horizon] ?? []) >= 10 else {
                throw GlucoseForecastMLTrainingFailure.insufficientCalibrationRows
            }
            guard countDays(c[horizon] ?? []) >= 10 else {
                throw GlucoseForecastMLTrainingFailure.insufficientSelfCheckRows
            }
        }
        let retained = horizons.flatMap { (a[$0] ?? []) + (b[$0] ?? []) + (c[$0] ?? []) }
        let unknown = retained.filter {
            $0.treatmentAvailability == .retrospectiveUnknown
                || $0.settingsAvailability == .retrospectiveUnknown
        }.count
        return Split(a: a, b: b, c: c, bStart: bStart, cStart: cStart,
                     usableDayCount: commonDays.count, retrospectiveUnknownCount: unknown)
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
}

enum GlucoseForecastMLTrainer {
    static let targetColumn = "target"
    static let randomSeed = 42

    static func key(_ kind: String, _ horizon: Int) -> String { "\(kind)_\(horizon)" }

    private struct ReplayAnchor {
        let rows: [Int: GlucoseForecastMLReplayExample]
        let engineTrajectory: [Double]

        func example(at horizon: Int) -> GlucoseForecastMLReplayExample {
            rows[horizon]!
        }
    }

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
        let grouped = Dictionary(grouping: GlucoseForecastMLChronology.horizons.flatMap {
            period[$0] ?? []
        }, by: { $0.row.referenceDate })
        return grouped.keys.sorted().compactMap { referenceDate in
            guard let examples = grouped[referenceDate], examples.count == 3,
                  Set(examples.map { $0.row.horizonMinutes }) == Set(GlucoseForecastMLChronology.horizons),
                  let first = examples.first,
                  examples.allSatisfy({ $0.sourceIdentity == first.sourceIdentity
                      && $0.row.sensorID == first.row.sensorID
                      && $0.engineTrajectoryMgdl == first.engineTrajectoryMgdl }) else {
                return nil
            }
            let rows = Dictionary(uniqueKeysWithValues: examples.map { ($0.row.horizonMinutes, $0) })
            return ReplayAnchor(rows: rows, engineTrajectory: first.engineTrajectoryMgdl)
        }
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
                      now: Date = .now) async throws -> GlucoseForecastMLTrainedCandidate {
        let split = try GlucoseForecastMLChronology.split(examples)
        try GlucoseForecastMLStoragePolicy.secureDirectory(sessionsDirectory)
        var models = [String: MLBoostedTreeRegressor]()
        var walkCounts = [Int: Int]()
        var trainingCounts = [Int: Int]()
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
            throw GlucoseForecastMLTrainingFailure.insufficientWalkForwardRows
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
                    throw GlucoseForecastMLTrainingFailure.insufficientWalkForwardRows
                }
                foldModels[horizon] = try await fit(prefix,
                    targets: prefix.map { $0.targetGlucoseMgdl - $0.engineTargetGlucoseMgdl },
                    sessionDirectory: sessionsDirectory.appendingPathComponent("walk_\(horizon)_\(index)"))
            }
            let holdout = aAnchors.filter {
                let reference = $0.example(at: 30).row.referenceDate
                return reference >= origin
                    && reference.addingTimeInterval(120 * 60 + 120) < end
            }
            guard !holdout.isEmpty else {
                throw GlucoseForecastMLTrainingFailure.insufficientWalkForwardRows
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
                throw GlucoseForecastMLTrainingFailure.insufficientWalkForwardRows
            }
            trainingCounts[horizon] = a.count
            walkCounts[horizon] = residuals.count
            models[key("correction", horizon)] = try await fit(a,
                targets: a.map { $0.targetGlucoseMgdl - $0.engineTargetGlucoseMgdl },
                sessionDirectory: sessionsDirectory.appendingPathComponent("correction_\(horizon)"))
            models[key("error", horizon)] = try await fit(residuals.map(\.0),
                targets: residuals.map(\.1),
                sessionDirectory: sessionsDirectory.appendingPathComponent("error_\(horizon)"))
        }

        let bAnchors = completeAnchors(split.b)
        let cAnchors = completeAnchors(split.c)
        guard bAnchors.count >= GlucoseForecastMLChronology.minimumCalibrationRows else {
            throw GlucoseForecastMLTrainingFailure.insufficientCalibrationRows
        }
        guard cAnchors.count >= GlucoseForecastMLChronology.minimumSelfCheckRows else {
            throw GlucoseForecastMLTrainingFailure.insufficientSelfCheckRows
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
                throw GlucoseForecastMLTrainingFailure.insufficientCalibrationRows
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

        var metrics = [Int: GlucoseForecastMLHorizonMetrics]()
        var selfCheckCounts = [Int: Int]()
        var rejections = [String]()
        for horizon in GlucoseForecastMLChronology.horizons {
            try Task.checkCancellation()
            let lineMinutes = horizon == 120 ? 120 : 60
            var candidateAbsolute = [Double]()
            var engineAbsolute = [Double]()
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
                engineAbsolute.append(abs(actual - baseline))
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
                candidateAbsolute.append(abs(actual - candidateCentral))
                candidateBiases.append(candidateCentral - actual)
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
            let mean: ([Double]) -> Double = { $0.reduce(0, +) / Double($0.count) }
            // With no successful ML line, every point falls back to the engine
            // and the candidate fails the improvement gate below.
            let medianWidth = GlucoseForecastMLChronology.median(widths) ?? 0
            let engineMAE = mean(engineAbsolute)
            let candidateMAE = mean(candidateAbsolute)
            let activeMAE = fairActive && activeAbsolute.count == cAnchors.count
                ? mean(activeAbsolute) : nil
            selfCheckCounts[horizon] = cAnchors.count
            metrics[horizon] = GlucoseForecastMLHorizonMetrics(
                count: cAnchors.count, engineMAE: engineMAE, candidateMAE: candidateMAE,
                activeMAE: activeMAE, candidateBias: mean(candidateBiases),
                candidateCoverage: Double(covered) / Double(cAnchors.count),
                medianBandWidthMgdl: medianWidth,
                candidateFallbackCount: candidateFallbacks,
                activeFallbackCount: fairActive ? activeFallbacks : nil)
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
            throw GlucoseForecastMLTrainingFailure.insufficientHistory
        }
        let report = GlucoseForecastMLSelfCheck(
            startedAt: split.cStart, endedAt: testEnd, horizons: metrics,
            activeComparisonWasFair: fairActive, promoted: rejections.isEmpty,
            rejectionReasons: rejections, retrospectiveUnknownCount: split.retrospectiveUnknownCount)
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
        return GlucoseForecastMLTrainedCandidate(models: models, metadata: metadata)
    }

    private static func fit(_ examples: [GlucoseForecastMLReplayExample],
                            targets: [Double],
                            sessionDirectory: URL) async throws -> MLBoostedTreeRegressor {
        try Task.checkCancellation()
        guard examples.count == targets.count else {
            throw GlucoseForecastMLTrainingFailure.invalidFeatureRow
        }
        var data = DataFrame()
        for (index, name) in GlucoseForecastMLFeatures.featureNames.enumerated() {
            data.append(column: Column<Double>(name: name, contents: examples.map { $0.row.values[index] }))
        }
        guard targets.allSatisfy(\.isFinite) else { throw GlucoseForecastMLTrainingFailure.invalidFeatureRow }
        data.append(column: Column<Double>(name: targetColumn, contents: targets))
        let parameters = MLBoostedTreeRegressor.ModelParameters(
            validation: .none, maxDepth: 6, maxIterations: 400,
            minChildWeight: 50, randomSeed: randomSeed, stepSize: 0.05)
        // Create ML writes checkpoints as soon as the job starts.
        try GlucoseForecastMLStoragePolicy.secureDirectory(sessionDirectory)
        let session = MLTrainingSessionParameters(sessionDirectory: sessionDirectory,
                                                   reportInterval: 25, checkpointInterval: 50,
                                                   iterations: 400)
        let job = try MLBoostedTreeRegressor.train(
            trainingData: data, targetColumn: targetColumn,
            featureColumns: GlucoseForecastMLFeatures.featureNames,
            parameters: parameters, sessionParameters: session)
        return try await withTaskCancellationHandler {
            for try await trained in job.result.values { return trained }
            throw GlucoseForecastMLTrainingFailure.trainingProducedNoModel
        } onCancel: { job.cancel() }
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
