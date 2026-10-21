import Foundation
import UserNotifications

/// Immutable provenance for the existing pen calculator, run with no NEW carbohydrates.
/// The advisory carries no dose to the UI: opening always requests a fresh calculation.
struct HighSoonAdvisoryContext: Sendable {
    let capturedAt: Date
    let treatmentRevision: Int
    let forecastInputChangeRevision: Int
    let sourceSignature: String
    let profile: PenDoseProfile
    let safetyForecast: GlucoseForecastResult
    let calculation: PenDoseCalculation
}

/// Optional early high advice. The existing measured-high and low alarms are independent.
/// A forecast crossing alone is insufficient: the same snapshot's existing calculator must
/// have a positive, checked result after IOB, COB, trend, limits and pen rounding.
enum HighSoonAdvisoryPolicy {
    static let enabledKey = "highSoonAdvisoryEnabled"
    static let notificationIdentifier = "highSoonAdvisory"
    static let categoryIdentifier = "highSoonAdvisoryCategory"
    static let openActionIdentifier = "highSoonOpenCalculator"
    static let lastScheduledKey = "highSoonLastScheduledAt"
    static let minimumInterval: TimeInterval = 30 * 60

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }

    struct Prediction {
        let peakMgdl: Double
        let peakDate: Date
        let windowStart: Date
        let activeInsulinUnits: Double
    }

    static func prediction(from outcome: GlucoseForecastSafetyOutcome,
                           expectedReferenceDate: Date, expectedSensorID: String?,
                           expectedGlucoseMgdl: Double, highLimitMgdl: Double,
                           at now: Date) -> Prediction? {
        // Reuse the established complete-grid/freshness/reference validation. Low-soon's
        // separate 60-minute result remains unchanged even if the 120-minute check fails.
        guard let window = LowSoonAlertPolicy.validatedPrediction(from: outcome,
                expectedReferenceDate: expectedReferenceDate, expectedSensorID: expectedSensorID,
                expectedGlucoseMgdl: expectedGlucoseMgdl, at: now),
              highLimitMgdl.isFinite,
              highLimitMgdl > LowSoonAlertPolicy.predictedLimitMgdl,
              highLimitMgdl <= GlucoseForecastEngine.configuration.maximumGlucoseMgdl,
              window.currentMgdl < highLimitMgdl,
              window.minimumMgdl >= LowSoonAlertPolicy.predictedLimitMgdl,
              let slope = outcome.slope15MgdlPerMinute, slope.isFinite, slope > 0,
              let context = outcome.highAdvisory,
              (0...30).contains(now.timeIntervalSince(context.capturedAt)),
              context.profile.isConfirmed,
              context.safetyForecast.reason == nil,
              context.safetyForecast.referenceDate == expectedReferenceDate,
              context.safetyForecast.referenceSensorID == expectedSensorID,
              context.safetyForecast.value(atMinutes: 120) != nil,
              context.safetyForecast.points.prefix(outcome.result.points.count)
                .elementsEqual(outcome.result.points),
              context.calculation.isAvailable,
              case .checked? = context.calculation.safety,
              !context.calculation.trendWasIntentionallyZero,
              context.calculation.glucoseMgdl == expectedGlucoseMgdl,
              context.calculation.glucoseMeasuredAt == expectedReferenceDate,
              context.calculation.glucoseSensorID == expectedSensorID,
              context.calculation.lines?.insulinOnBoardUnits == window.activeInsulinUnits,
              let units = context.calculation.suggestedUnits, units.isFinite, units > 0,
              let atNow = LowSoonAlertPolicy.interpolated(outcome.result.points, at: now),
              let atEnd = LowSoonAlertPolicy.interpolated(outcome.result.points, at: window.windowEnd)
        else { return nil }
        let points = [atNow] + outcome.result.points.filter {
            $0.date > now && $0.date < window.windowEnd
        } + [atEnd]
        guard let peak = points.max(by: { $0.glucoseMgdl < $1.glucoseMgdl }),
              peak.glucoseMgdl > highLimitMgdl else { return nil }
        return Prediction(peakMgdl: peak.glucoseMgdl, peakDate: peak.date,
            windowStart: now, activeInsulinUnits: window.activeInsulinUnits)
    }

    static func maySchedule(lastScheduled: Date?, at now: Date) -> Bool {
        guard now.timeIntervalSinceReferenceDate.isFinite else { return false }
        guard let lastScheduled else { return true }
        return now.timeIntervalSince(lastScheduled) >= minimumInterval
    }
}

/// A separate notification sound preference; it never changes the measured-high Alert Type.
enum HighSoonAdvisorySound: Equatable {
    case systemDefault
    case silent
    case named(ConstantsSounds)

    static let defaultsKey = "highSoonAdvisorySound"
    // UNNotificationSound requires files shorter than 30 seconds. These existing alarm
    // sounds are 30 seconds or longer; the ordinary alarm catalogue remains unchanged.
    static var availableSounds: [ConstantsSounds] {
        ConstantsSounds.allCases.filter {
            switch $0 {
            case .batterwakeup, .bruteforce, .modernalarm2, .modernalarm, .spaceship,
                 .Early_Sunrise, .Nightguard: return false
            default: return true
            }
        }
    }
    static var choices: [Self] { [.silent, .systemDefault] + availableSounds.map { .named($0) } }

    static func load(defaults: UserDefaults = .standard) -> Self {
        guard let stored = defaults.string(forKey: defaultsKey) else { return .systemDefault }
        if stored.isEmpty { return .silent }
        guard let sound = ConstantsSounds(rawValue: stored), availableSounds.contains(sound)
        else { return .systemDefault }
        return .named(sound)
    }

    func store(defaults: UserDefaults = .standard) {
        switch self {
        case .systemDefault: defaults.removeObject(forKey: Self.defaultsKey)
        case .silent: defaults.set("", forKey: Self.defaultsKey)
        case .named(let sound): defaults.set(sound.rawValue, forKey: Self.defaultsKey)
        }
    }

    var notificationSound: UNNotificationSound? {
        switch self {
        case .systemDefault: return .default
        case .silent: return nil
        case .named(let sound):
            return UNNotificationSound(named: UNNotificationSoundName(ConstantsSounds.getSoundFile(forSound: sound)))
        }
    }
}
