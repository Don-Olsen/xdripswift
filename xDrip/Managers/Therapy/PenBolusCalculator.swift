//
//  PenBolusCalculator.swift
//  xdrip
//
//  A read-only, user-confirmed pen suggestion. Nothing in this file delivers insulin.
//

import Foundation

struct PenDoseProfile: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let storageKey = "penDoseProfile.v1"

    struct ScheduleValue: Codable, Equatable, Sendable {
        /// Minutes since local midnight. Repeated DST hours use the same entry.
        var startMinute: Int
        var value: Double
    }

    struct Settings: Codable, Equatable, Sendable {
        var carbohydrateRatios: [ScheduleValue]
        var targetsMmol: [ScheduleValue]
        var correctionMmolPerUnit: Double
        var penStepUnits: Double
        var maximumSuggestionUnits: Double

        var isValid: Bool {
            func validSchedule(_ values: [ScheduleValue], allowed: ClosedRange<Double>) -> Bool {
                guard values.first?.startMinute == 0 else { return false }
                return values.enumerated().allSatisfy { index, item in
                    (0..<24 * 60).contains(item.startMinute) &&
                        item.value.isFinite && allowed.contains(item.value) &&
                        (index == 0 || values[index - 1].startMinute < item.startMinute)
                }
            }
            return validSchedule(carbohydrateRatios, allowed: 1...100) &&
                validSchedule(targetsMmol, allowed: 3...20) &&
                correctionMmolPerUnit.isFinite && (0.1...10).contains(correctionMmolPerUnit) &&
                penStepUnits.isFinite && (0.1...1).contains(penStepUnits) &&
                maximumSuggestionUnits.isFinite && (1...25).contains(maximumSuggestionUnits)
        }
    }

    var version: Int = Self.schemaVersion
    var settings: Settings {
        didSet {
            if settings != oldValue {
                confirmedSettings = nil
                confirmedAt = nil
            }
        }
    }
    private(set) var confirmedSettings: Settings?
    private(set) var confirmedAt: Date?

    init(settings: Settings, confirmedSettings: Settings? = nil,
         confirmedAt: Date? = nil) {
        self.settings = settings
        self.confirmedSettings = confirmedSettings
        self.confirmedAt = confirmedAt
    }

    var isConfirmed: Bool {
        version == Self.schemaVersion && settings.isValid &&
            confirmedSettings == settings && confirmedAt != nil
    }

    static var prefilledUnconfirmed: Self {
        // These are the user's supplied mySugr numbers, not forecast/ML parameters.
        Self(settings: Settings(
            carbohydrateRatios: [
                ScheduleValue(startMinute: 0, value: 7.5),
                ScheduleValue(startMinute: 4 * 60 + 30, value: 5),
                ScheduleValue(startMinute: 9 * 60 + 30, value: 6)
            ],
            targetsMmol: [
                ScheduleValue(startMinute: 0, value: (6.7 + 7.0) / 2),
                ScheduleValue(startMinute: 21 * 60 + 30, value: (7.5 + 8.0) / 2)
            ],
            correctionMmolPerUnit: 1.2,
            penStepUnits: 0.5,
            maximumSuggestionUnits: 25))
    }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Self.self, from: data),
              decoded.version == schemaVersion, decoded.settings.isValid else {
            return .prefilledUnconfirmed
        }
        return decoded
    }

    @discardableResult
    mutating func confirm(at date: Date = .now) -> Bool {
        guard version == Self.schemaVersion, settings.isValid, date <= Date().addingTimeInterval(60) else {
            return false
        }
        confirmedSettings = settings
        confirmedAt = date
        return true
    }

    @discardableResult
    func persist(defaults: UserDefaults = .standard) -> Bool {
        guard version == Self.schemaVersion, settings.isValid,
              let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: Self.storageKey)
        return true
    }

    func values(at date: Date, calendar: Calendar = .current)
        -> (carbohydrateRatio: Double, targetMmol: Double, correctionMmolPerUnit: Double)? {
        guard isConfirmed else { return nil }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return nil }
        let localMinute = hour * 60 + minute
        guard let ratio = settings.carbohydrateRatios.last(where: { $0.startMinute <= localMinute })?.value,
              let target = settings.targetsMmol.last(where: { $0.startMinute <= localMinute })?.value else {
            return nil
        }
        return (ratio, target, settings.correctionMmolPerUnit)
    }
}

enum PenDoseGlucoseInput: Sendable {
    case currentCGM
    /// The exact CGM sample explicitly chosen by the user. A subsequent sample
    /// must not silently replace this value while its trend remains unavailable.
    case confirmedStale(valueMgdl: Double, measuredAt: Date, sensorID: String)
    case manual(valueMgdl: Double, measuredAt: Date)
}

enum PenDoseNewCarbs: Sendable {
    /// Only carbohydrates not represented in the validated COB snapshot.
    case unrecorded(grams: Double)
    /// Backdated or edited meal already present in COB; never add it twice.
    case alreadyRecorded
}

enum PenDoseUnavailableReason: String, Error, Sendable {
    case unconfirmedProfile
    case invalidProfile
    case incompleteTherapySources
    case uncommittedTreatments
    case treatmentReadFailed
    case treatmentChangedDuringRead
    case invalidTreatment
    case invalidGlucose
    case glucoseNeedsConfirmation
    case missingGlucose
    case missingTwentyMinuteTrend
    case invalidCarbohydrates
    case invalidCalculation
}

/// Detached values from one completed source-selected treatment read. An empty treatment
/// array with complete provenance gives known zero IOB/COB; nil/unread data never does.
struct PenDoseInputSnapshot: Sendable {
    let capturedAt: Date
    let glucose: [GlucoseForecastSample]
    let treatments: [TherapyTreatment]
    let therapySettings: TherapyModelSettings
    let treatmentRevision: Int
    let iobUnits: Double
    let cobGrams: Double

    static func make(capturedAt: Date, glucose: [GlucoseForecastSample],
                     treatments: [TherapyTreatment], therapySettings: TherapyModelSettings,
                     treatmentRevision: Int) -> Result<Self, PenDoseUnavailableReason> {
        guard therapySettings.validInsulin, therapySettings.validCarbs else {
            return .failure(.invalidTreatment)
        }
        guard glucose.allSatisfy({
            $0.date <= capturedAt && $0.glucoseMgdl.isFinite &&
                (20...600).contains($0.glucoseMgdl)
        }), zip(glucose, glucose.dropFirst()).allSatisfy({
            $0.0.date < $0.1.date && $0.0.sensorID == $0.1.sensorID
        }) else { return .failure(.invalidGlucose) }
        var iob = 0.0, cob = 0.0
        for treatment in treatments where treatment.date <= capturedAt {
            guard treatment.amount.isFinite, treatment.amount > 0 else {
                return .failure(.invalidTreatment)
            }
            let age = capturedAt.timeIntervalSince(treatment.date) / 60
            if treatment.isIOB {
                iob += TherapyCalculations.insulinRemaining(units: treatment.amount,
                    minutes: age, duration: therapySettings.insulinDuration,
                    peak: therapySettings.insulinPeak)
            } else {
                let duration = treatment.carbohydrateDuration(or: therapySettings.carbDuration)
                guard duration.isFinite, (30...480).contains(duration) else {
                    return .failure(.invalidTreatment)
                }
                cob += TherapyCalculations.carbsRemaining(grams: treatment.amount,
                    minutes: age, duration: duration)
            }
        }
        guard iob.isFinite, cob.isFinite else { return .failure(.invalidTreatment) }
        return .success(Self(capturedAt: capturedAt, glucose: glucose,
            treatments: treatments, therapySettings: therapySettings,
            treatmentRevision: treatmentRevision, iobUnits: iob, cobGrams: cob))
    }
}

struct PenDoseLineItems: Sendable {
    let carbohydratesUnits: Double
    let correctionUnits: Double
    let trendUnits: Double
    let insulinOnBoardUnits: Double
    let rawUnits: Double
}

enum PenDoseSafetyState: Sendable {
    case checked
    case eatFirst
    case eatFirstForecastUnchecked(GlucoseForecastUnavailableReason)
    case blockedCurrentLow
    case blockedForecastLow
    /// A numeric suggestion may still be shown, explicitly not safety-checked.
    case forecastUnchecked(GlucoseForecastUnavailableReason)
}

struct PenDoseCalculation: Sendable {
    let suggestedUnits: Double?
    let lines: PenDoseLineItems?
    let safety: PenDoseSafetyState?
    let unavailableReason: PenDoseUnavailableReason?
    let glucoseMgdl: Double?
    let glucoseMeasuredAt: Date?
    let glucoseSensorID: String?
    let trendWasIntentionallyZero: Bool
    let forecastMinimumMgdl: Double?
    var isAvailable: Bool { suggestedUnits != nil && unavailableReason == nil }
}

enum PenBolusCalculator {
    static let mgdlPerMmol = 1 / ConstantsBloodGlucose.mgDlToMmoll
    static let freshCGMSeconds: TimeInterval = 15 * 60
    static let trendWindowSeconds: TimeInterval = 20 * 60
    static let minimumTrendSpanSeconds: TimeInterval = 15 * 60
    static let maximumTrendGapSeconds: TimeInterval = 5.5 * 60

    /// The existing forecast engine is reused only as a read-only safety guard. This does not
    /// change its points, use ML, include planned food, log a prediction or deliver insulin.
    static func safetyForecast(snapshot: PenDoseInputSnapshot, at now: Date = .now,
                               defaults: UserDefaults = .standard,
                               horizonMinutes: Int = 120) -> GlucoseForecastResult {
        guard let reference = snapshot.glucose.last else {
            return GlucoseForecastResult(points: [], referenceDate: nil, reason: .missingGlucose)
        }
        guard !GlucoseForecastDataAdapter.hasTreatmentAfterReading(snapshot.treatments,
            referenceDate: reference.date, calculationDate: now) else {
            return GlucoseForecastResult(points: [], referenceDate: reference.date,
                reason: .awaitingNextReading)
        }
        let parameters = GlucoseForecastDataAdapter.manualParameters(
            sensitivity: defaults.glucoseForecastManualSensitivityMgdlPerUnit,
            ratio: defaults.glucoseForecastManualCarbRatioGramsPerUnit)
        guard case .success(let pair) = parameters else {
            if case .failure(let reason) = parameters {
                return GlucoseForecastResult(points: [], referenceDate: reference.date, reason: reason)
            }
            return GlucoseForecastResult(points: [], referenceDate: reference.date,
                reason: .invalidProfile)
        }
        let start = reference.date.addingTimeInterval(-max(
            snapshot.therapySettings.insulinDuration,
            snapshot.therapySettings.carbDuration) * 60)
        let input = GlucoseForecastInput(glucose: snapshot.glucose,
            treatments: GlucoseForecastDataAdapter.treatmentsKnownAtReference(
                snapshot.treatments, from: start, referenceDate: reference.date),
            settings: snapshot.therapySettings,
            sensitivityMgdlPerUnit: pair.sensitivity,
            carbohydrateRatioGramsPerUnit: pair.ratio,
            horizonMinutes: horizonMinutes, now: now)
        let result = GlucoseForecastEngine.predict(input)
        return GlucoseForecastResult(points: result.points,
            referenceDate: result.referenceDate,
            reason: result.reason, parameterSource: .manual,
            referenceSensorID: reference.sensorID)
    }

    static func calculate(snapshot: PenDoseInputSnapshot, profile: PenDoseProfile,
                          glucose: PenDoseGlucoseInput, newCarbs: PenDoseNewCarbs,
                          safetyForecast: GlucoseForecastResult?, at now: Date = .now) -> PenDoseCalculation {
        func unavailable(_ reason: PenDoseUnavailableReason) -> PenDoseCalculation {
            PenDoseCalculation(suggestedUnits: nil, lines: nil, safety: nil,
                unavailableReason: reason, glucoseMgdl: nil, glucoseMeasuredAt: nil,
                glucoseSensorID: nil,
                trendWasIntentionallyZero: false, forecastMinimumMgdl: nil)
        }
        guard profile.settings.isValid else { return unavailable(.invalidProfile) }
        guard let profileValues = profile.values(at: now) else { return unavailable(.unconfirmedProfile) }
        guard abs(now.timeIntervalSince(snapshot.capturedAt)) <= 30,
              snapshot.iobUnits.isFinite, snapshot.iobUnits >= 0,
              snapshot.cobGrams.isFinite, snapshot.cobGrams >= 0 else {
            return unavailable(.incompleteTherapySources)
        }
        let extraCarbs: Double
        switch newCarbs {
        case .alreadyRecorded: extraCarbs = 0
        case .unrecorded(let grams):
            guard grams.isFinite, grams >= 0, grams <= 500 else {
                return unavailable(.invalidCarbohydrates)
            }
            extraCarbs = grams
        }
        let glucoseValue: Double
        let glucoseDate: Date
        let glucoseSensorID: String?
        let trendMgdl: Double
        let zeroTrend: Bool
        let canCheckForecast: Bool
        switch glucose {
        case .currentCGM:
            guard let latest = snapshot.glucose.last else { return unavailable(.missingGlucose) }
            glucoseValue = latest.glucoseMgdl
            glucoseDate = latest.date
            glucoseSensorID = latest.sensorID
            let age = now.timeIntervalSince(latest.date)
            guard age >= -30 else { return unavailable(.invalidGlucose) }
            guard age <= freshCGMSeconds else { return unavailable(.glucoseNeedsConfirmation) }
            guard let trend = twentyMinuteChange(snapshot.glucose, at: latest.date) else {
                return unavailable(.missingTwentyMinuteTrend)
            }
            trendMgdl = trend
            zeroTrend = false
            canCheckForecast = true
        case .confirmedStale(let value, let date, let sensorID):
            guard !sensorID.isEmpty,
                  snapshot.glucose.last.map({ $0.sensorID == sensorID && $0.date >= date }) ?? true,
                  !snapshot.glucose.contains(where: {
                      $0.sensorID == sensorID && $0.date == date && $0.glucoseMgdl != value
                  }) else { return unavailable(.invalidGlucose) }
            glucoseValue = value
            glucoseDate = date
            glucoseSensorID = sensorID
            trendMgdl = 0
            zeroTrend = true
            canCheckForecast = false
        case .manual(let value, let date):
            glucoseValue = value
            glucoseDate = date
            glucoseSensorID = nil
            trendMgdl = 0
            zeroTrend = true
            canCheckForecast = false
        }
        guard glucoseValue.isFinite, (20...600).contains(glucoseValue),
              glucoseDate <= now.addingTimeInterval(30) else {
            return unavailable(.invalidGlucose)
        }
        let glucoseMmol = glucoseValue / mgdlPerMmol
        let carbUnits = (snapshot.cobGrams + extraCarbs) / profileValues.carbohydrateRatio
        let correctionUnits = (glucoseMmol - profileValues.targetMmol) /
            profileValues.correctionMmolPerUnit
        let trendUnits = (trendMgdl / mgdlPerMmol) / profileValues.correctionMmolPerUnit
        let raw = carbUnits + correctionUnits + trendUnits - snapshot.iobUnits
        guard raw.isFinite, carbUnits.isFinite, correctionUnits.isFinite,
              trendUnits.isFinite else { return unavailable(.invalidCalculation) }
        let lines = PenDoseLineItems(carbohydratesUnits: carbUnits,
            correctionUnits: correctionUnits, trendUnits: trendUnits,
            insulinOnBoardUnits: snapshot.iobUnits, rawUnits: raw)
        let forecastMinimum: Double?
        let safety: PenDoseSafetyState
        if glucoseMmol < 3.0 {
            safety = .blockedCurrentLow
            forecastMinimum = nil
        } else if canCheckForecast,
                  let forecast = safetyForecast, forecast.reason == nil,
                  forecast.referenceDate == snapshot.glucose.last?.date,
                  forecast.referenceSensorID == snapshot.glucose.last?.sensorID,
                  abs((forecast.points.first?.glucoseMgdl ?? .nan) - glucoseValue) < 0.01,
                  forecast.value(atMinutes: 120) != nil,
                  forecast.points.allSatisfy({ $0.glucoseMgdl.isFinite }) {
            let minimum = forecast.points.map(\.glucoseMgdl).min()!
            forecastMinimum = minimum
            if minimum / mgdlPerMmol < 3.0 { safety = .blockedForecastLow }
            else if glucoseMmol < 3.9 { safety = .eatFirst }
            else { safety = .checked }
        } else {
            forecastMinimum = nil
            let reason = canCheckForecast ? (safetyForecast?.reason ?? .dataUnavailable) :
                .dataUnavailable
            safety = glucoseMmol < 3.9 ? .eatFirstForecastUnchecked(reason) :
                .forecastUnchecked(reason)
        }
        let blocks: Bool
        switch safety {
        case .blockedCurrentLow, .blockedForecastLow: blocks = true
        default: blocks = false
        }
        let bounded = min(profile.settings.maximumSuggestionUnits, max(0, raw))
        let roundedDown = floor((bounded / profile.settings.penStepUnits) + 1e-10) *
            profile.settings.penStepUnits
        return PenDoseCalculation(suggestedUnits: blocks ? nil : roundedDown,
            lines: lines, safety: safety, unavailableReason: nil,
            glucoseMgdl: glucoseValue, glucoseMeasuredAt: glucoseDate,
            glucoseSensorID: glucoseSensorID,
            trendWasIntentionallyZero: zeroTrend, forecastMinimumMgdl: forecastMinimum)
    }

    /// Use a real 15–20-minute span from one sensor; never extrapolate a shorter movement.
    static func twentyMinuteChange(_ samples: [GlucoseForecastSample], at latestDate: Date)
        -> Double? {
        guard let latest = samples.last, latest.date == latestDate,
              let sensorID = latest.sensorID, !sensorID.isEmpty else { return nil }
        let relevant = samples.filter {
            $0.sensorID == sensorID && $0.glucoseMgdl.isFinite &&
                $0.date >= latestDate.addingTimeInterval(-trendWindowSeconds) &&
                $0.date <= latestDate
        }.sorted { $0.date < $1.date }
        guard let oldest = relevant.first,
              latestDate.timeIntervalSince(oldest.date) >= minimumTrendSpanSeconds else { return nil }
        for (left, right) in zip(relevant, relevant.dropFirst()) where
            right.date.timeIntervalSince(left.date) > maximumTrendGapSeconds { return nil }
        return latest.glucoseMgdl - oldest.glucoseMgdl
    }
}
