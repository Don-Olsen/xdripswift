//
//  GlucoseForecastEngine.swift
//  xdrip
//
//  A local, display-only estimate. It never changes stored glucose, treatment,
//  alarm, or dosing state.
//

import Foundation

struct GlucoseForecastSample: Sendable, Equatable {
    let date: Date
    let glucoseMgdl: Double
    let sensorID: String?

    init(date: Date, glucoseMgdl: Double, sensorID: String? = nil) {
        self.date = date
        self.glucoseMgdl = glucoseMgdl
        self.sensorID = sensorID
    }
}

struct GlucoseForecastPoint: Sendable, Equatable {
    let date: Date
    let glucoseMgdl: Double
}

enum GlucoseForecastUnavailableReason: String, Error, Sendable {
    case missingGlucose
    case staleGlucose
    case insufficientHistory
    case historyGap
    case missingProfile
    case invalidProfile
    case profileChange
    case externalOwner
    case dataUnavailable
    case awaitingNextReading
    case ambiguousTreatmentSources
    case invalidSettings
    case invalidHorizon
    case invalidTreatment
    case outOfRange
}

enum GlucoseForecastParameterSource: String, Sendable {
    case nightscoutProfile
    case manual
}

struct GlucoseForecastInput: Sendable {
    let glucose: [GlucoseForecastSample]
    /// Already filtered by TherapyMetricsManager for source, identity and deletion.
    /// An empty array must represent a successfully loaded treatment window.
    let treatments: [TherapyTreatment]
    let settings: TherapyModelSettings
    /// The applicable, user-confirmed profile values at the reference time.
    let sensitivityMgdlPerUnit: Double?
    let carbohydrateRatioGramsPerUnit: Double?
    let horizonMinutes: Int
    let now: Date

    init(glucose: [GlucoseForecastSample], treatments: [TherapyTreatment],
         settings: TherapyModelSettings, sensitivityMgdlPerUnit: Double?,
         carbohydrateRatioGramsPerUnit: Double?, horizonMinutes: Int = 60,
         now: Date = .now) {
        self.glucose = glucose
        self.treatments = treatments
        self.settings = settings
        self.sensitivityMgdlPerUnit = sensitivityMgdlPerUnit
        self.carbohydrateRatioGramsPerUnit = carbohydrateRatioGramsPerUnit
        self.horizonMinutes = horizonMinutes
        self.now = now
    }
}

struct GlucoseForecastResult: Sendable {
    let points: [GlucoseForecastPoint]
    let referenceDate: Date?
    let reason: GlucoseForecastUnavailableReason?
    let parameterSource: GlucoseForecastParameterSource?
    /// The sensor behind the reference reading, used to avoid showing an older estimate
    /// against a chart that has already switched to a different sensor.
    let referenceSensorID: String?
    /// Optional display-only ML correction. The authoritative engine points above are unchanged.
    let mlForecast: GlucoseForecastMLForecast?

    init(points: [GlucoseForecastPoint], referenceDate: Date?,
         reason: GlucoseForecastUnavailableReason?,
         parameterSource: GlucoseForecastParameterSource? = nil,
         referenceSensorID: String? = nil,
         mlForecast: GlucoseForecastMLForecast? = nil) {
        self.points = points
        self.referenceDate = referenceDate
        self.reason = reason
        self.parameterSource = parameterSource
        self.referenceSensorID = referenceSensorID
        self.mlForecast = mlForecast
    }

    func value(atMinutes minutes: Int) -> Double? {
        guard reason == nil, let referenceDate else { return nil }
        let date = referenceDate.addingTimeInterval(TimeInterval(minutes * 60))
        return points.first { abs($0.date.timeIntervalSince(date)) < 0.5 }?.glucoseMgdl
    }
}

/// The engine and prospective log share this immutable definition. Changes to
/// these constants require a new engineVersion; personal therapy settings do not.
struct GlucoseForecastEngineConfiguration: Codable, Sendable, Equatable {
    let historyWindowMinutes: Double
    let historyMinimumSamples: Int
    let historyMinimumSpanMinutes: Double
    let momentumRegressionMinutes: Double
    let momentumMinimumSamples: Int
    let momentumMinimumSpanMinutes: Double
    let momentumDecayMinutes: Double
    let correctionContributionEnabled: Bool
    let correctionWeight: Double
    let integrationStepMinutes: Double
    let cadenceToleranceSeconds: TimeInterval
    let maximumGlucoseAgeSeconds: TimeInterval
    let maximumHistoryGapSeconds: TimeInterval
    let minimumGlucoseMgdl: Double
    let maximumGlucoseMgdl: Double
    let supportedHorizonMinutes: [Int]
}

/// A deliberately small Swift adaptation of LoopKit's prediction principles:
/// combine date-aligned treatment effects and short residual glucose momentum.
/// No LoopKit framework or pump dosing code is used.
///
/// Therapy effects are the CHANGE in absorbed bolus/carbohydrates after the
/// latest CGM value, not present IOB/COB multiplied by a constant. Before
/// fitting momentum, the same modeled effects are removed from observed CGM
/// movement; this prevents a recent dose/meal from being counted twice.
/// The 30-minute residual correction rate is still calculated, but its
/// contribution is explicitly disabled. Momentum uses 15 minutes of regression
/// history and fades over 10 future minutes. Its integrated effect is retained
/// thereafter; treatment curves continue through the selected forecast horizon.
/// A stable unmodeled background (including long-acting basal) is assumed.
///
/// This is not LoopKit's full pump prediction or StandardRetrospectiveCorrection:
/// no basal schedule, pump zero-temp, dynamic carbohydrate absorption, or dose
/// recommendation is ported. The existing selected xDrip insulin duration,
/// insulin peak and carbohydrate absorption duration remain intact.
/// LoopKit source revision: 1b09bddd22bd91fb81e4b074f7638bc9e987246e
/// (MIT; Copyright 2015 Nathan Racklyeft, 2016 LoopKit Authors).
/// See docs/GLUCOSE-FORECAST.md for attribution and modeling limitations.
enum GlucoseForecastEngine {
    static let engineVersion = "local-residual-momentum10-v2"
    static let configuration = GlucoseForecastEngineConfiguration(
        historyWindowMinutes: 30, historyMinimumSamples: 6, historyMinimumSpanMinutes: 25,
        momentumRegressionMinutes: 15, momentumMinimumSamples: 4, momentumMinimumSpanMinutes: 10,
        momentumDecayMinutes: 10, correctionContributionEnabled: false, correctionWeight: 0,
        integrationStepMinutes: 5, cadenceToleranceSeconds: 30,
        maximumGlucoseAgeSeconds: 330, maximumHistoryGapSeconds: 330,
        minimumGlucoseMgdl: 20, maximumGlucoseMgdl: 600, supportedHorizonMinutes: [60, 120])
    static var maximumGlucoseAge: TimeInterval { configuration.maximumGlucoseAgeSeconds }

    static func predict(_ input: GlucoseForecastInput) -> GlucoseForecastResult {
        func unavailable(_ reason: GlucoseForecastUnavailableReason, at date: Date? = nil) -> GlucoseForecastResult {
            GlucoseForecastResult(points: [], referenceDate: date, reason: reason)
        }

        let constants = configuration
        let glucoseRange = constants.minimumGlucoseMgdl...constants.maximumGlucoseMgdl
        guard constants.supportedHorizonMinutes.contains(input.horizonMinutes) else {
            return unavailable(.invalidHorizon)
        }
        guard input.settings.validInsulin && input.settings.validCarbs else {
            return unavailable(.invalidSettings)
        }
        guard let sensitivity = input.sensitivityMgdlPerUnit,
              let ratio = input.carbohydrateRatioGramsPerUnit else {
            return unavailable(.missingProfile)
        }
        guard sensitivity.isFinite, ratio.isFinite, sensitivity > 0, ratio > 0 else {
            return unavailable(.invalidProfile)
        }
        guard input.treatments.allSatisfy({ $0.amount.isFinite && $0.amount >= 0 }) else {
            return unavailable(.invalidTreatment)
        }

        // The caller supplies valid, source-selected CGM samples. Do not silently skip a
        // newer visible value outside the model's numeric range and predict from older data.
        guard let newestDate = input.glucose.filter({ $0.date <= input.now }).map(\.date).max(),
              input.glucose.filter({ $0.date == newestDate }).allSatisfy({
                  $0.glucoseMgdl.isFinite && glucoseRange.contains($0.glucoseMgdl)
              }) else { return unavailable(.missingGlucose) }
        // Validate the remaining numeric/timing invariants so a cache miss never becomes zero.
        let ordered = input.glucose
            .filter { $0.date <= input.now && $0.glucoseMgdl.isFinite && glucoseRange.contains($0.glucoseMgdl) }
            .sorted { $0.date < $1.date }
        guard let latest = ordered.last else { return unavailable(.missingGlucose) }
        guard input.now.timeIntervalSince(latest.date) <= maximumGlucoseAge else {
            return unavailable(.staleGlucose, at: latest.date)
        }
        let cutoff = latest.date.addingTimeInterval(-constants.historyWindowMinutes * 60 - constants.cadenceToleranceSeconds)
        // Two observations at one timestamp are one moment, not extra history.
        var history: [GlucoseForecastSample] = []
        for sample in ordered where sample.date >= cutoff {
            if history.last?.date == sample.date { history[history.count - 1] = sample }
            else { history.append(sample) }
        }
        guard history.count >= constants.historyMinimumSamples,
              let first = history.first,
              latest.date.timeIntervalSince(first.date) >= constants.historyMinimumSpanMinutes * 60 else {
            return unavailable(.insufficientHistory, at: latest.date)
        }
        guard zip(history, history.dropFirst()).allSatisfy({ pair in
            pair.1.date.timeIntervalSince(pair.0.date) <= constants.maximumHistoryGapSeconds
        }) else {
            return unavailable(.historyGap, at: latest.date)
        }

        let treatments = input.treatments.filter { $0.amount > 0 && $0.date <= latest.date }
        func absorbed(_ treatment: TherapyTreatment, at date: Date) -> Double {
            guard date >= treatment.date else { return 0 }
            let elapsed = date.timeIntervalSince(treatment.date) / 60
            let remaining = treatment.isIOB
                ? TherapyCalculations.insulinRemaining(units: treatment.amount, minutes: elapsed,
                    duration: input.settings.insulinDuration, peak: input.settings.insulinPeak)
                : TherapyCalculations.carbsRemaining(grams: treatment.amount, minutes: elapsed,
                    duration: input.settings.carbDuration)
            return treatment.amount - remaining
        }
        func modeledChange(from start: Date, to end: Date) -> Double {
            treatments.reduce(0) { total, treatment in
                let delta = absorbed(treatment, at: end) - absorbed(treatment, at: start)
                return total + (treatment.isIOB ? -delta * sensitivity : delta / ratio * sensitivity)
            }
        }

        // Remove the already modeled therapy motion from each historical BG
        // sample before estimating unexplained glucose momentum/discrepancy.
        let residuals: [(date: Date, value: Double)] = history.map { sample in
            (sample.date, sample.glucoseMgdl - modeledChange(from: first.date, to: sample.date))
        }
        let shortStart = latest.date.addingTimeInterval(-constants.momentumRegressionMinutes * 60 - constants.cadenceToleranceSeconds)
        let short = residuals.filter { $0.date >= shortStart }
        guard short.count >= constants.momentumMinimumSamples,
              latest.date.timeIntervalSince(short[0].date) >= constants.momentumMinimumSpanMinutes * 60,
              let momentumRate = regressionRate(short, relativeTo: latest.date),
              let correctionRate = regressionRate(residuals, relativeTo: latest.date) else {
            return unavailable(.insufficientHistory, at: latest.date)
        }

        let stepMinutes = constants.integrationStepMinutes
        var points = [GlucoseForecastPoint(date: latest.date, glucoseMgdl: latest.glucoseMgdl)]
        var residualEffect = 0.0
        for minute in stride(from: Int(stepMinutes), through: input.horizonMinutes, by: Int(stepMinutes)) {
            let midpoint = Double(minute) - stepMinutes / 2
            let momentumWeight = max(0, 1 - midpoint / constants.momentumDecayMinutes)
            // Keep correctionRate and the blending structure explicit, but do not
            // contribute it. No zero-duration division or hidden long trend.
            let correctionWeight = constants.correctionContributionEnabled ? constants.correctionWeight : 0
            // Only unexplained momentum is integrated. Once its weight reaches
            // zero the accumulated residualEffect is retained, never reset.
            let rate = momentumWeight * momentumRate
                + (1 - momentumWeight) * correctionWeight * correctionRate
            residualEffect += rate * stepMinutes
            let date = latest.date.addingTimeInterval(Double(minute) * 60)
            let value = latest.glucoseMgdl
                + modeledChange(from: latest.date, to: date) + residualEffect
            guard value.isFinite, glucoseRange.contains(value) else {
                return unavailable(.outOfRange, at: latest.date)
            }
            points.append(GlucoseForecastPoint(date: date, glucoseMgdl: value))
        }
        return GlucoseForecastResult(points: points, referenceDate: latest.date, reason: nil)
    }

    private static func regressionRate(_ samples: [(date: Date, value: Double)],
                                       relativeTo referenceDate: Date) -> Double? {
        guard samples.count >= 2 else { return nil }
        let count = Double(samples.count)
        let xs = samples.map { $0.date.timeIntervalSince(referenceDate) / 60 }
        let xMean = xs.reduce(0, +) / count
        let yMean = samples.reduce(0) { $0 + $1.value } / count
        let denominator = xs.reduce(0) { $0 + pow($1 - xMean, 2) }
        guard denominator > 0 else { return nil }
        let numerator = zip(xs, samples).reduce(0) { partial, pair in
            partial + (pair.0 - xMean) * (pair.1.value - yMean)
        }
        let rate = numerator / denominator
        return rate.isFinite ? rate : nil
    }
}
