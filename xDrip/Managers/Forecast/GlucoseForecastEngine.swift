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

    init(points: [GlucoseForecastPoint], referenceDate: Date?,
         reason: GlucoseForecastUnavailableReason?,
         parameterSource: GlucoseForecastParameterSource? = nil) {
        self.points = points
        self.referenceDate = referenceDate
        self.reason = reason
        self.parameterSource = parameterSource
    }

    func value(atMinutes minutes: Int) -> Double? {
        guard reason == nil, let referenceDate else { return nil }
        let date = referenceDate.addingTimeInterval(TimeInterval(minutes * 60))
        return points.first { abs($0.date.timeIntervalSince(date)) < 0.5 }?.glucoseMgdl
    }
}

/// A deliberately small Swift adaptation of LoopKit's prediction principles:
/// combine date-aligned treatment effects, short glucose momentum and a fading
/// retrospective discrepancy. No LoopKit framework or pump dosing code is used.
///
/// Therapy effects are the CHANGE in absorbed bolus/carbohydrates after the
/// latest CGM value, not present IOB/COB multiplied by a constant. Before
/// fitting momentum, the same modeled effects are removed from observed CGM
/// movement; this prevents a recent dose/meal from being counted twice.
/// Residual short-term and 30-minute rates are BLENDED, never added together.
/// The residual correction fades to zero by 60 minutes. A stable unmodeled
/// background (including long-acting basal such as Tresiba) is assumed.
///
/// This is not LoopKit's full pump prediction or StandardRetrospectiveCorrection:
/// no basal schedule, pump zero-temp, dynamic carbohydrate absorption, or dose
/// recommendation is ported. The existing selected xDrip insulin duration,
/// insulin peak and carbohydrate absorption duration remain intact.
/// LoopKit source revision: 1b09bddd22bd91fb81e4b074f7638bc9e987246e
/// (MIT; Copyright 2015 Nathan Racklyeft, 2016 LoopKit Authors).
/// See docs/GLUCOSE-FORECAST.md for attribution and modeling limitations.
enum GlucoseForecastEngine {
    private static let lookbackMinutes = 30.0
    private static let momentumMinutes = 15.0
    private static let correctionMinutes = 60.0
    private static let stepMinutes = 5.0
    private static let fiveMinuteCadenceTolerance: TimeInterval = 30
    static let maximumGlucoseAge: TimeInterval = 5 * 60 + fiveMinuteCadenceTolerance

    static func predict(_ input: GlucoseForecastInput) -> GlucoseForecastResult {
        func unavailable(_ reason: GlucoseForecastUnavailableReason, at date: Date? = nil) -> GlucoseForecastResult {
            GlucoseForecastResult(points: [], referenceDate: date, reason: reason)
        }

        guard input.horizonMinutes == 60 || input.horizonMinutes == 120 else {
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

        // The caller supplies valid, source-selected CGM samples; validate the
        // numeric/timing invariants again so a cache miss never becomes zero.
        let ordered = input.glucose
            .filter { $0.date <= input.now && $0.glucoseMgdl.isFinite && (20...600).contains($0.glucoseMgdl) }
            .sorted { $0.date < $1.date }
        guard let latest = ordered.last else { return unavailable(.missingGlucose) }
        guard input.now.timeIntervalSince(latest.date) <= maximumGlucoseAge else {
            return unavailable(.staleGlucose, at: latest.date)
        }
        let cutoff = latest.date.addingTimeInterval(-lookbackMinutes * 60 - fiveMinuteCadenceTolerance)
        // Two observations at one timestamp are one moment, not extra history.
        var history: [GlucoseForecastSample] = []
        for sample in ordered where sample.date >= cutoff {
            if history.last?.date == sample.date { history[history.count - 1] = sample }
            else { history.append(sample) }
        }
        guard history.count >= 6,
              let first = history.first,
              latest.date.timeIntervalSince(first.date) >= 25 * 60 else {
            return unavailable(.insufficientHistory, at: latest.date)
        }
        guard zip(history, history.dropFirst()).allSatisfy({ pair in
            pair.1.date.timeIntervalSince(pair.0.date) <= 5 * 60 + fiveMinuteCadenceTolerance
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
        let shortStart = latest.date.addingTimeInterval(-momentumMinutes * 60 - fiveMinuteCadenceTolerance)
        let short = residuals.filter { $0.date >= shortStart }
        guard short.count >= 4,
              latest.date.timeIntervalSince(short[0].date) >= 10 * 60,
              let momentumRate = regressionRate(short, relativeTo: latest.date),
              let correctionRate = regressionRate(residuals, relativeTo: latest.date) else {
            return unavailable(.insufficientHistory, at: latest.date)
        }

        var points = [GlucoseForecastPoint(date: latest.date, glucoseMgdl: latest.glucoseMgdl)]
        var residualEffect = 0.0
        for minute in stride(from: Int(stepMinutes), through: input.horizonMinutes, by: Int(stepMinutes)) {
            let midpoint = Double(minute) - stepMinutes / 2
            let momentumWeight = max(0, 1 - midpoint / momentumMinutes)
            let correctionWeight = max(0, 1 - midpoint / correctionMinutes)
            // Only the unexplained component is extended. The short-term rate
            // gives way to the 30-minute discrepancy, which then decays.
            let rate = momentumWeight * momentumRate
                + (1 - momentumWeight) * correctionWeight * correctionRate
            residualEffect += rate * stepMinutes
            let date = latest.date.addingTimeInterval(Double(minute) * 60)
            let value = latest.glucoseMgdl
                + modeledChange(from: latest.date, to: date) + residualEffect
            guard value.isFinite, (20...600).contains(value) else {
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
