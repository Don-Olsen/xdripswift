// Fixed, value-only feature contract shared by live inference and historical replay.
import Foundation

struct GlucoseForecastMLFeatureRow: Sendable {
    let horizonMinutes: Int
    let referenceDate: Date
    let engineValue: Double
    let glucose: Double
    let sensorID: String?
    /// Ordered exactly as GlucoseForecastMLFeatures.featureNames.
    let values: [Double]
}

enum GlucoseForecastMLFeatures {
    // The feature order is unchanged; the version also binds the corrected
    // historical data formation used to train the model.
    static let featureVersion = "glucose-forecast-16-v3"
    static let featureNames = [
        "glucoseMgdl", "rawSlope15MgdlPerMinute", "rawSlope30MgdlPerMinute",
        "engineDeltaMgdl", "insulinNextUnits", "carbsNextGrams", "iobUnits",
        "cobGrams", "minutesSinceBolus", "lastBolusUnits", "minutesSinceCarbs",
        "lastCarbsGrams", "hourSin", "hourCos", "weekdayMondayZero", "samples30"
    ]

    /// Only a successful engine result can produce a feature row. The engine remains
    /// the source of validation and of the uncorrected prediction at this horizon.
    static func row(input: GlucoseForecastInput, result: GlucoseForecastResult,
                    horizonMinutes: Int, calendar: Calendar = .current)
        -> GlucoseForecastMLFeatureRow? {
        guard [30, 60, 120].contains(horizonMinutes), result.reason == nil,
              let referenceDate = result.referenceDate,
              referenceDate <= input.now,
              let engineValue = result.value(atMinutes: horizonMinutes), engineValue.isFinite,
              input.settings.validInsulin, input.settings.validCarbs else { return nil }
        let constants = GlucoseForecastEngine.configuration
        let bounds = constants.minimumGlucoseMgdl...constants.maximumGlucoseMgdl
        let ordered = input.glucose.filter {
            $0.date <= referenceDate && $0.glucoseMgdl.isFinite && bounds.contains($0.glucoseMgdl)
        }.sorted { $0.date < $1.date }
        var unique = [GlucoseForecastSample]()
        for sample in ordered {
            if unique.last?.date == sample.date { unique[unique.count - 1] = sample }
            else { unique.append(sample) }
        }
        guard let reference = unique.last, reference.date == referenceDate,
              result.points.first?.date == referenceDate,
              result.points.first?.glucoseMgdl == reference.glucoseMgdl,
              result.referenceSensorID == nil || result.referenceSensorID == reference.sensorID
        else { return nil }
        let history30 = unique.filter {
            $0.date >= referenceDate.addingTimeInterval(
                -constants.historyWindowMinutes * 60 - constants.cadenceToleranceSeconds)
        }
        let history15 = history30.filter {
            $0.date >= referenceDate.addingTimeInterval(
                -constants.momentumRegressionMinutes * 60 - constants.cadenceToleranceSeconds)
        }
        guard let slope15 = regressionSlope(history15, referenceDate: referenceDate),
              let slope30 = regressionSlope(history30, referenceDate: referenceDate) else { return nil }

        let treatments = input.treatments.filter {
            $0.amount.isFinite && $0.amount > 0 && $0.date <= referenceDate
        }
        var insulinNext = 0.0, carbsNext = 0.0, iob = 0.0, cob = 0.0
        let futureDate = referenceDate.addingTimeInterval(Double(horizonMinutes) * 60)
        for treatment in treatments {
            let age = referenceDate.timeIntervalSince(treatment.date) / 60
            let futureAge = futureDate.timeIntervalSince(treatment.date) / 60
            if treatment.isIOB {
                let current = TherapyCalculations.insulinRemaining(units: treatment.amount,
                    minutes: age, duration: input.settings.insulinDuration,
                    peak: input.settings.insulinPeak)
                let future = TherapyCalculations.insulinRemaining(units: treatment.amount,
                    minutes: futureAge, duration: input.settings.insulinDuration,
                    peak: input.settings.insulinPeak)
                iob += current
                insulinNext += current - future
            } else {
                let current = TherapyCalculations.carbsRemaining(grams: treatment.amount,
                    minutes: age, duration: input.settings.carbDuration)
                let future = TherapyCalculations.carbsRemaining(grams: treatment.amount,
                    minutes: futureAge, duration: input.settings.carbDuration)
                cob += current
                carbsNext += current - future
            }
        }
        func latest(_ isIOB: Bool) -> TherapyTreatment? {
            treatments.filter { $0.isIOB == isIOB }.max {
                if $0.date != $1.date { return $0.date < $1.date }
                return $0.amount < $1.amount
            }
        }
        let lastBolus = latest(true), lastCarbs = latest(false)
        func age(_ treatment: TherapyTreatment?) -> Double {
            treatment.map { min(600, referenceDate.timeIntervalSince($0.date) / 60) } ?? 600
        }
        let clock = calendar.dateComponents([.hour, .minute, .second, .nanosecond, .weekday],
                                            from: referenceDate)
        guard let hour = clock.hour, let minute = clock.minute, let weekday = clock.weekday else { return nil }
        let hourFraction = Double(hour) + Double(minute) / 60 +
            Double(clock.second ?? 0) / 3600 + Double(clock.nanosecond ?? 0) / 3_600_000_000_000
        let angle = 2 * Double.pi * hourFraction / 24
        let values = [reference.glucoseMgdl, slope15, slope30,
                      engineValue - reference.glucoseMgdl, insulinNext, carbsNext, iob, cob,
                      age(lastBolus), lastBolus?.amount ?? 0, age(lastCarbs),
                      lastCarbs?.amount ?? 0, sin(angle), cos(angle),
                      Double((weekday + 5) % 7), Double(history30.count)]
        guard values.count == featureNames.count, values.allSatisfy(\.isFinite) else { return nil }
        return GlucoseForecastMLFeatureRow(horizonMinutes: horizonMinutes,
            referenceDate: referenceDate, engineValue: engineValue,
            glucose: reference.glucoseMgdl, sensorID: reference.sensorID, values: values)
    }

    private static func regressionSlope(_ samples: [GlucoseForecastSample], referenceDate: Date)
        -> Double? {
        guard samples.count >= 2 else { return nil }
        let xs = samples.map { $0.date.timeIntervalSince(referenceDate) / 60 }
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = samples.reduce(0) { $0 + $1.glucoseMgdl } / Double(samples.count)
        var numerator = 0.0, denominator = 0.0
        for (x, sample) in zip(xs, samples) {
            numerator += (x - meanX) * (sample.glucoseMgdl - meanY)
            denominator += (x - meanX) * (x - meanX)
        }
        guard denominator > 0 else { return nil }
        let slope = numerator / denominator
        return slope.isFinite ? slope : nil
    }
}
