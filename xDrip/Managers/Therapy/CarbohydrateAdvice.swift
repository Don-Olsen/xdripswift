import Foundation

/// All inputs are captured with the completed, authoritative safety forecast. The caller
/// supplies a source-validated snapshot; no defaults, Core Data, ML or second read is used.
struct CarbohydrateAdviceContext: Sendable {
    let snapshot: PenDoseInputSnapshot
    let forecast: GlucoseForecastResult
    let glucoseInput: PenDoseGlucoseInput
    let sensitivityMgdlPerUnit: Double?
    let carbohydrateRatioGramsPerUnit: Double?
    let computedAt: Date
}

struct CarbohydrateAdviceResult: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case noRisk, estimated, currentLow, tooSoon, aboveModelLimit, recentCarbs
        case missingData, manualGlucose
    }

    struct FastCarbohydrates: Codable, Equatable, Sendable {
        let stableIdentity: String?
        let grams: Double
        let date: Date
    }

    let status: Status
    /// Whole grams, only when status == estimated. An abstention is never a zero dose.
    let grams: Int?
    let forecastMinimumMgdl: Double?
    let forecastMinimumDate: Date?
    let latestFastCarbs: FastCarbohydrates?
    let referenceDate: Date?
    let computedAt: Date
}

/// A bounded, read-only what-if estimate for the existing short-term warning margin.
/// It is not Trio's pump algorithm, a treatment of current hypoglycaemia, or a promise
/// that food will prevent a low. The personal bolus target is intentionally not used.
/// Existing insulin/carbohydrate effects are already in the forecast and are not subtracted
/// again. Only the existing fast-carbohydrate curve is added, starting at the actual now.
enum CarbohydrateAdvice {
    static let version = "fast-carb-pointwise30-v1"
    static let horizonMinutes = 30
    static let maximumAutomaticGrams = 15
    static let maximumSnapshotAge: TimeInterval = 30
    static let bufferMgdl = LowSoonAlertPolicy.predictedLimitMgdl
    static let currentLowMgdl = LowSoonAlertPolicy.currentMinimumMgdl
    static var recentFastCarbohydrateInterval: TimeInterval {
        (TreatmentMealKind.fast.durationMinutes + TherapyModelSettings.carbDelay) * 60
    }

    static func evaluate(_ context: CarbohydrateAdviceContext,
                         at now: Date = .now) -> CarbohydrateAdviceResult {
        let snapshot = context.snapshot
        let forecast = context.forecast
        let reference = snapshot.glucose.last
        let latestFastCarbs = snapshot.treatments.filter {
            !$0.isIOB && !$0.isDeletedCurrentRevision && $0.amount.isFinite && $0.amount > 0 &&
                $0.date <= now && ($0.knownAt.map { $0 <= now } ?? true) &&
                $0.carbohydrateDurationMinutes == TreatmentMealKind.fast.durationMinutes
        }.max { $0.date < $1.date }.map {
            CarbohydrateAdviceResult.FastCarbohydrates(stableIdentity: $0.stableIdentity,
                                                       grams: $0.amount, date: $0.date)
        }
        func result(_ status: CarbohydrateAdviceResult.Status, grams: Int? = nil,
                    minimum: GlucoseForecastPoint? = nil) -> CarbohydrateAdviceResult {
            CarbohydrateAdviceResult(status: status, grams: grams,
                forecastMinimumMgdl: minimum?.glucoseMgdl, forecastMinimumDate: minimum?.date,
                latestFastCarbs: latestFastCarbs, referenceDate: reference?.date,
                computedAt: context.computedAt)
        }
        // Manual and explicitly untrended readings never acquire an automatic carb estimate.
        guard case .currentCGM = context.glucoseInput else { return result(.manualGlucose) }
        let limits = GlucoseForecastEngine.configuration
        let validGlucose: ClosedRange<Double> = limits.minimumGlucoseMgdl...limits.maximumGlucoseMgdl
        guard let reference, reference.glucoseMgdl.isFinite,
              validGlucose.contains(reference.glucoseMgdl),
              (0...GlucoseForecastEngine.maximumGlucoseAge).contains(now.timeIntervalSince(reference.date)),
              (0...maximumSnapshotAge).contains(now.timeIntervalSince(snapshot.capturedAt)),
              (0...maximumSnapshotAge).contains(now.timeIntervalSince(context.computedAt)),
              !snapshot.sourceSignature.isEmpty,
              snapshot.iobUnits.isFinite, snapshot.iobUnits >= 0,
              snapshot.cobGrams.isFinite, snapshot.cobGrams >= 0,
              snapshot.therapySettings.validInsulin, snapshot.therapySettings.validCarbs else {
            return result(.missingData)
        }
        // A current low always wins over recent food or missing predictive evidence.
        guard reference.glucoseMgdl >= currentLowMgdl else { return result(.currentLow) }
        guard let sensorID = reference.sensorID, !sensorID.isEmpty,
              snapshot.glucose.allSatisfy({ $0.sensorID == sensorID }),
              PenBolusCalculator.twentyMinuteChange(snapshot.glucose, at: reference.date) != nil,
              forecast.reason == nil, forecast.referenceDate == reference.date,
              forecast.referenceSensorID == sensorID,
              let first = forecast.points.first, first.date == reference.date,
              first.glucoseMgdl == reference.glucoseMgdl,
              let sensitivity = context.sensitivityMgdlPerUnit, sensitivity.isFinite, sensitivity > 0,
              let ratio = context.carbohydrateRatioGramsPerUnit, ratio.isFinite, ratio > 0,
              !GlucoseForecastDataAdapter.hasTreatmentAfterReading(snapshot.treatments,
                referenceDate: reference.date, calculationDate: now) else { return result(.missingData) }
        let scale = sensitivity / ratio
        guard scale.isFinite, scale > 0 else { return result(.missingData) }
        let end = now.addingTimeInterval(Double(horizonMinutes) * 60)
        let step = GlucoseForecastEngine.configuration.integrationStepMinutes * 60
        // Validate the actual engine grid before using its future points; missing points,
        // duplicate dates and forged partial forecasts are not silently interpolated away.
        guard let last = forecast.points.last, last.date >= end,
              forecast.points.allSatisfy({ $0.glucoseMgdl.isFinite && validGlucose.contains($0.glucoseMgdl) }),
              zip(forecast.points, forecast.points.dropFirst()).allSatisfy({
                  abs($0.1.date.timeIntervalSince($0.0.date) - step) < 0.001
              }), let atNow = interpolated(forecast.points, at: now),
              let atEnd = interpolated(forecast.points, at: end) else { return result(.missingData) }
        let points = [atNow] + forecast.points.filter { $0.date > now && $0.date < end } + [atEnd]
        guard let minimum = points.min(by: { $0.glucoseMgdl < $1.glucoseMgdl }) else {
            return result(.missingData)
        }
        // A stable value between 3.9 and 4.4 does not become a request to eat to the
        // personal target. There must be a modeled fall below the existing warning margin.
        guard minimum.glucoseMgdl < bufferMgdl,
              minimum.glucoseMgdl < reference.glucoseMgdl - 1e-9 else {
            return result(.noRisk, minimum: minimum)
        }
        var required = 0.0
        for point in points where point.glucoseMgdl < bufferMgdl {
            let elapsed = point.date.timeIntervalSince(now) / 60
            let absorbedFraction = 1 - TherapyCalculations.carbsRemaining(grams: 1,
                minutes: elapsed, duration: TreatmentMealKind.fast.durationMinutes)
            // Food is proposed now, not backdated to an older reference reading. The
            // curve's ten-minute delay cannot be bypassed by a very large gram count.
            guard absorbedFraction > 1e-9 else { return result(.tooSoon, minimum: minimum) }
            let grams = (bufferMgdl - point.glucoseMgdl) / (scale * absorbedFraction)
            guard grams.isFinite, grams >= 0 else { return result(.missingData, minimum: minimum) }
            required = max(required, grams)
        }
        // Existing fast food remains in the base prediction. This separate conservative
        // repeat guard offers no new quantity during its modeled delay+absorption window;
        // it never advises the user to wait or suppresses the separate measured-low alarms.
        if let latestFastCarbs,
           now.timeIntervalSince(latestFastCarbs.date) < recentFastCarbohydrateInterval {
            return result(.recentCarbs, minimum: minimum)
        }
        // Undo only machine-roundoff at an exact integer (e.g. 3.000000000000002).
        // This is not a clinical tolerance: a genuinely larger requirement still rounds up.
        let nearestInteger = required.rounded()
        let roundoff = max(1, abs(required)) * Double.ulpOfOne * 16
        let wholeGrams = ceil(abs(required - nearestInteger) <= roundoff ? nearestInteger : required)
        guard wholeGrams.isFinite, wholeGrams >= 1 else { return result(.missingData, minimum: minimum) }
        // This is a limit of this automatic estimator, NOT a patient's maximum treatment.
        // A larger modeled requirement is withheld, never clamped to a reassuring 15 g.
        guard wholeGrams <= Double(maximumAutomaticGrams) else {
            return result(.aboveModelLimit, minimum: minimum)
        }
        return result(.estimated, grams: Int(wholeGrams), minimum: minimum)
    }

    private static func interpolated(_ points: [GlucoseForecastPoint], at date: Date)
        -> GlucoseForecastPoint? {
        if let exact = points.first(where: { $0.date == date }) { return exact }
        guard let rightIndex = points.firstIndex(where: { $0.date > date }), rightIndex > 0 else { return nil }
        let left = points[rightIndex - 1], right = points[rightIndex]
        let fraction = date.timeIntervalSince(left.date) / right.date.timeIntervalSince(left.date)
        return GlucoseForecastPoint(date: date,
            glucoseMgdl: left.glucoseMgdl + fraction * (right.glucoseMgdl - left.glucoseMgdl))
    }
}
