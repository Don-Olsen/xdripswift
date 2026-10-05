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
    /// A second, scoped read of CGM history for the optional COB reduction. Nil means
    /// no usable historical evidence; it never changes the proven curve COB above.
    let historicalGlucose: [GlucoseForecastSample]?
    let historicalGlucoseIssue: PenCOBFallbackReason?
    let sourceSignature: String

    static func make(capturedAt: Date, glucose: [GlucoseForecastSample],
                     treatments: [TherapyTreatment], therapySettings: TherapyModelSettings,
                     treatmentRevision: Int, historicalGlucose: [GlucoseForecastSample]? = nil,
                     historicalGlucoseIssue: PenCOBFallbackReason? = nil,
                     sourceSignature: String = "") -> Result<Self, PenDoseUnavailableReason> {
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
                guard duration.isFinite,
                      (30.0...PenCGMCOBEstimator.maximumCarbohydrateDurationMinutes).contains(duration) else {
                    return .failure(.invalidTreatment)
                }
                cob += TherapyCalculations.carbsRemaining(grams: treatment.amount,
                    minutes: age, duration: duration)
            }
        }
        guard iob.isFinite, cob.isFinite else { return .failure(.invalidTreatment) }
        return .success(Self(capturedAt: capturedAt, glucose: glucose,
            treatments: treatments, therapySettings: therapySettings,
            treatmentRevision: treatmentRevision, iobUnits: iob, cobGrams: cob,
            historicalGlucose: historicalGlucose,
            historicalGlucoseIssue: historicalGlucoseIssue,
            sourceSignature: sourceSignature))
    }
}

enum PenCOBFallbackReason: String, Error, Sendable {
    case noCurrentMeal
    case manualOrUntrendedGlucose
    case missingHistory
    case incompleteTreatmentHistory
    case changedInputs
    case historicalProfileUnknown
    case missingTreatmentIdentity
    case duplicateTreatmentIdentity
    case sensorMismatch
    case historyGap
    case invalidHistory
    case oscillatingSignal
    case insufficientIntervals
}

/// An optional reduction of the existing curve COB, scoped to one reviewed dose snapshot.
/// The estimated value can never increase the carbohydrate contribution to a dose.
struct PenCOBEvidence: Sendable {
    let curveGrams: Double
    let estimatedGrams: Double?
    let usedGrams: Double
    let fallbackReason: PenCOBFallbackReason?
}

/// A deterministic, retrospective CGM estimate of already absorbed meal carbohydrate.
/// It is not a replacement for the shared therapy curve, Home COB, forecast or alarms.
enum PenCGMCOBEstimator {
    static let maximumHistorySeconds: TimeInterval = 24 * 60 * 60
    static let intervalSeconds: TimeInterval = 5 * 60
    static let maximumRawGapSeconds: TimeInterval = 15 * 60
    static let maximumCarbohydrateDurationMinutes = 480.0

    /// The treatment read must prove that no older meal can overlap a meal inside
    /// the 24-hour glucose window, and must include any earlier active rapid bolus.
    static func requiredTreatmentLookbackMinutes(settings: TherapyModelSettings) -> Double {
        maximumHistorySeconds / 60 + 1.5 * maximumCarbohydrateDurationMinutes +
            settings.insulinDuration
    }

    /// Includes earlier meals that overlap the earliest still-active meal. Earlier rapid
    /// boluses are retained separately for their modeled effect in these intervals.
    static func historyStart(treatments: [TherapyTreatment], settings: TherapyModelSettings,
                             at now: Date) -> Date? {
        let meals = treatments.filter { !$0.isIOB && $0.date <= now && $0.amount > 0 }
        func end(_ meal: TherapyTreatment) -> Date {
            meal.date.addingTimeInterval(1.5 * meal.carbohydrateDuration(or: settings.carbDuration) * 60)
        }
        guard var start = meals.filter({ end($0) > now }).map(\.date).min() else { return nil }
        // Overlap is transitive: an expired meal may overlap an earlier meal that in turn
        // overlaps the current one. Its glucose response still belongs to the same period.
        while let earlier = meals.filter({ end($0) >= start }).map(\.date).min(), earlier < start {
            start = earlier
        }
        return start
    }

    static func estimate(snapshot: PenDoseInputSnapshot, profile: PenDoseProfile,
                         at now: Date) -> Result<Double, PenCOBFallbackReason> {
        guard let start = historyStart(treatments: snapshot.treatments,
                                       settings: snapshot.therapySettings, at: now) else {
            return .failure(.noCurrentMeal)
        }
        if let issue = snapshot.historicalGlucoseIssue { return .failure(issue) }
        guard now.timeIntervalSince(start) <= maximumHistorySeconds,
              let latest = snapshot.glucose.last, let sensorID = latest.sensorID,
              !sensorID.isEmpty, let history = snapshot.historicalGlucose,
              !history.isEmpty else { return .failure(.missingHistory) }

        let meals = snapshot.treatments.filter { !$0.isIOB && $0.date <= now &&
            $0.date.addingTimeInterval(1.5 * $0.carbohydrateDuration(or: snapshot.therapySettings.carbDuration) * 60) >= start
        }.sorted {
            $0.date == $1.date ? ($0.stableIdentity ?? "") < ($1.stableIdentity ?? "") : $0.date < $1.date
        }
        let boluses = snapshot.treatments.filter { $0.isIOB && $0.date <= latest.date &&
            $0.date.addingTimeInterval(snapshot.therapySettings.insulinDuration * 60) > start
        }.sorted {
            $0.date == $1.date ? ($0.stableIdentity ?? "") < ($1.stableIdentity ?? "") : $0.date < $1.date
        }
        let relevant = meals + boluses
        guard relevant.allSatisfy({ $0.stableIdentity?.isEmpty == false }) else {
            return .failure(.missingTreatmentIdentity)
        }
        let identities = relevant.compactMap(\.stableIdentity)
        guard Set(identities).count == identities.count else { return .failure(.duplicateTreatmentIdentity) }
        let earliestEvent = min(start, boluses.map(\.date).min() ?? start)
        guard profile.isConfirmed, let confirmedAt = profile.confirmedAt,
              confirmedAt <= earliestEvent else { return .failure(.historicalProfileUnknown) }
        let mealRatios = meals.compactMap { profile.values(at: $0.date)?.carbohydrateRatio }
        guard mealRatios.count == meals.count,
              mealRatios.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return .failure(.historicalProfileUnknown)
        }
        guard history.last == latest else { return .failure(.missingHistory) }
        guard history.allSatisfy({ $0.sensorID == sensorID }) else {
            return .failure(.sensorMismatch)
        }
        guard history.allSatisfy({ $0.glucoseMgdl.isFinite &&
            (20...600).contains($0.glucoseMgdl)
        }) else { return .failure(.invalidHistory) }
        guard zip(history, history.dropFirst()).allSatisfy({
            $0.0.date < $0.1.date &&
                $0.1.date.timeIntervalSince($0.0.date) <= maximumRawGapSeconds
        }) else { return .failure(.historyGap) }

        let firstTick = ceil(start.timeIntervalSince1970 / intervalSeconds) * intervalSeconds
        let lastTick = floor(latest.date.timeIntervalSince1970 / intervalSeconds) * intervalSeconds
        guard lastTick - firstTick >= 2 * intervalSeconds else { return .failure(.insufficientIntervals) }
        let times = stride(from: firstTick, through: lastTick, by: intervalSeconds)
            .map { Date(timeIntervalSince1970: $0) }
        var levels = [Double]()
        levels.reserveCapacity(times.count)
        for time in times {
            guard let level = interpolatedGlucose(at: time, history: history) else {
                return .failure(.historyGap)
            }
            levels.append(level)
        }
        var absorbed = [Double](repeating: 0, count: meals.count)
        var positiveResidualMgdl = 0.0
        var netResidualMgdl = 0.0
        // Non-overlapping ten-minute nets cancel a five-minute up/down oscillation.
        // A residual must persist across the pair before it can reduce dose COB.
        for index in stride(from: 0, to: times.count - 2, by: 2) {
            let from = times[index], to = times[index + 2]
            let insulinUnits = boluses.reduce(0.0) { partial, bolus in
                partial + absorbedInsulin(bolus, at: to, settings: snapshot.therapySettings)
                    - absorbedInsulin(bolus, at: from, settings: snapshot.therapySettings)
            }
            let insulinEffectMgdl = -insulinUnits * profile.settings.correctionMmolPerUnit *
                PenBolusCalculator.mgdlPerMmol
            let residualMgdl = levels[index + 2] - levels[index] - insulinEffectMgdl
            guard residualMgdl.isFinite else {
                return .failure(.invalidHistory)
            }
            netResidualMgdl += residualMgdl
            positiveResidualMgdl += max(0, residualMgdl)
            let effectUnits = max(0, residualMgdl) /
                (profile.settings.correctionMmolPerUnit * PenBolusCalculator.mgdlPerMmol)
            guard effectUnits.isFinite else { return .failure(.invalidHistory) }
            allocate(effectUnits: effectUnits, from: from, to: to, meals: meals,
                     carbohydrateRatios: mealRatios, settings: snapshot.therapySettings,
                     absorbed: &absorbed)
        }
        // Summing only upward fluctuations would count a later reversal as another meal.
        // Without evidence of a sustained net response, retain the established curve COB.
        guard positiveResidualMgdl.isFinite, netResidualMgdl.isFinite,
              positiveResidualMgdl <= max(0, netResidualMgdl) + 5 else {
            return .failure(.oscillatingSignal)
        }
        var remaining = 0.0
        for (index, meal) in meals.enumerated() {
            let duration = meal.carbohydrateDuration(or: snapshot.therapySettings.carbDuration)
            let elapsed = max(0, now.timeIntervalSince(meal.date) / 60)
            let floorAbsorbed = meal.amount * min(1, elapsed / (1.5 * duration))
            let finalAbsorbed = min(meal.amount, max(absorbed[index], floorAbsorbed))
            remaining += max(0, meal.amount - finalAbsorbed)
        }
        guard remaining.isFinite, remaining >= 0 else { return .failure(.invalidHistory) }
        return .success(remaining)
    }

    private static func absorbedInsulin(_ bolus: TherapyTreatment, at date: Date,
                                        settings: TherapyModelSettings) -> Double {
        guard date > bolus.date else { return 0 }
        let minutes = date.timeIntervalSince(bolus.date) / 60
        return bolus.amount - TherapyCalculations.insulinRemaining(units: bolus.amount,
            minutes: minutes, duration: settings.insulinDuration, peak: settings.insulinPeak)
    }

    private static func interpolatedGlucose(at date: Date,
                                             history: [GlucoseForecastSample]) -> Double? {
        if let exact = history.first(where: { $0.date == date }) { return exact.glucoseMgdl }
        guard let rightIndex = history.firstIndex(where: { $0.date > date }), rightIndex > 0 else { return nil }
        let left = history[rightIndex - 1], right = history[rightIndex]
        let span = right.date.timeIntervalSince(left.date)
        guard span > 0, span <= maximumRawGapSeconds else { return nil }
        let fraction = date.timeIntervalSince(left.date) / span
        return left.glucoseMgdl + fraction * (right.glucoseMgdl - left.glucoseMgdl)
    }

    static func allocate(effectUnits: Double, from: Date, to: Date,
                         meals: [TherapyTreatment], carbohydrateRatios: [Double],
                         settings: TherapyModelSettings,
                         absorbed: inout [Double]) {
        guard effectUnits > 0, carbohydrateRatios.count == meals.count else { return }
        var left = effectUnits
        var eligible = meals.indices.filter { index in
            let meal = meals[index]
            let duration = meal.carbohydrateDuration(or: settings.carbDuration)
            return meal.date <= from &&
                meal.date.addingTimeInterval(1.5 * duration * 60) >= to &&
                absorbed[index] < meal.amount &&
                carbohydrateRatios[index].isFinite && carbohydrateRatios[index] > 0
        }
        while left > 1e-9 && !eligible.isEmpty {
            let weights = eligible.map { meals[$0].amount /
                (1.5 * meals[$0].carbohydrateDuration(or: settings.carbDuration)) }
            let totalWeight = weights.reduce(0, +)
            guard totalWeight.isFinite, totalWeight > 0 else { return }
            let roundInput = left
            var assigned = 0.0
            for (position, index) in eligible.enumerated() {
                let ratio = carbohydrateRatios[index]
                let roomUnits = max(0, meals[index].amount - absorbed[index]) / ratio
                let portionUnits = min(roomUnits, roundInput * weights[position] / totalWeight)
                absorbed[index] += portionUnits * ratio
                assigned += portionUnits
            }
            guard assigned > 1e-9 else { return }
            left -= assigned
            eligible.removeAll { absorbed[$0] >= meals[$0].amount - 1e-9 }
        }
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
    let cobEvidence: PenCOBEvidence?
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
                trendWasIntentionallyZero: false, forecastMinimumMgdl: nil,
                cobEvidence: nil)
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
        let cobEvidence: PenCOBEvidence
        if zeroTrend {
            cobEvidence = PenCOBEvidence(curveGrams: snapshot.cobGrams,
                estimatedGrams: nil, usedGrams: snapshot.cobGrams,
                fallbackReason: .manualOrUntrendedGlucose)
        } else {
            switch PenCGMCOBEstimator.estimate(snapshot: snapshot, profile: profile, at: now) {
            case .success(let estimated):
                let used = min(snapshot.cobGrams, max(0, estimated))
                cobEvidence = PenCOBEvidence(curveGrams: snapshot.cobGrams,
                    estimatedGrams: estimated, usedGrams: used, fallbackReason: nil)
            case .failure(let reason):
                cobEvidence = PenCOBEvidence(curveGrams: snapshot.cobGrams,
                    estimatedGrams: nil, usedGrams: snapshot.cobGrams,
                    fallbackReason: reason)
            }
        }
        let glucoseMmol = glucoseValue / mgdlPerMmol
        let carbUnits = (cobEvidence.usedGrams + extraCarbs) / profileValues.carbohydrateRatio
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
            trendWasIntentionallyZero: zeroTrend, forecastMinimumMgdl: forecastMinimum,
            cobEvidence: cobEvidence)
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
