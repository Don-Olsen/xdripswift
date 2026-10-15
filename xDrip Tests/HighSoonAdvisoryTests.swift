import XCTest
@testable import xdrip

final class HighSoonAdvisoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func outcome(insulin: Double = 0, current: Double = 175,
                         slope: Double = 2, sensitivity: Double? = 10,
                         confirmed: Bool = true) throws -> GlucoseForecastSafetyOutcome {
        let samples = stride(from: -30, through: 0, by: 5).map { minute in
            GlucoseForecastSample(date: now.addingTimeInterval(Double(minute) * 60),
                glucoseMgdl: current + Double(minute) * slope, sensorID: "synthetic-sensor")
        }
        let snapshot = try PenDoseInputSnapshot.make(capturedAt: now, glucose: samples,
            treatments: insulin > 0 ? [TherapyTreatment(date: now, amount: insulin, isIOB: true)] : [],
            therapySettings: TherapyModelSettings(), treatmentRevision: 7,
            sourceSignature: "synthetic-local-source").get()
        let settings = PenDoseProfile.Settings(carbohydrateRatios: [.init(startMinute: 0, value: 10)],
            targetsMmol: [.init(startMinute: 0, value: 6)], correctionMmolPerUnit: 2,
            penStepUnits: 0.5, maximumSuggestionUnits: 25)
        let profile = PenDoseProfile(settings: settings,
            confirmedSettings: confirmed ? settings : nil,
            confirmedAt: confirmed ? now.addingTimeInterval(-3600) : nil)
        return GlucoseForecastDataAdapter.engineOnlyOutcome(snapshot: snapshot, at: now,
            sensitivityMgdlPerUnit: sensitivity, carbohydrateRatioGramsPerUnit: 10,
            highAdvisoryProfile: profile)
    }

    private func prediction(_ outcome: GlucoseForecastSafetyOutcome, limit: Double = 180,
                            current: Double = 175, sensor: String? = "synthetic-sensor",
                            at date: Date? = nil) -> HighSoonAdvisoryPolicy.Prediction? {
        HighSoonAdvisoryPolicy.prediction(from: outcome, expectedReferenceDate: now,
            expectedSensorID: sensor, expectedGlucoseMgdl: current,
            highLimitMgdl: limit, at: date ?? now)
    }

    private func replacing(_ value: GlucoseForecastSafetyOutcome,
                           points: [GlucoseForecastPoint]? = nil,
                           slope: Double? = nil, iob: Double? = nil,
                           context: HighSoonAdvisoryContext? = nil) -> GlucoseForecastSafetyOutcome {
        GlucoseForecastSafetyOutcome(result: .init(points: points ?? value.result.points,
            referenceDate: value.result.referenceDate, reason: value.result.reason,
            referenceSensorID: value.result.referenceSensorID),
            referenceGlucoseMgdl: value.referenceGlucoseMgdl,
            activeInsulinUnits: iob ?? value.activeInsulinUnits,
            slope15MgdlPerMinute: slope ?? value.slope15MgdlPerMinute,
            highAdvisory: context ?? value.highAdvisory)
    }

    func testRealEngineCrossingBeforeMeasuredHighRequestsAdvice() throws {
        let value = try outcome()
        let result = try XCTUnwrap(prediction(value))
        XCTAssertEqual(value.referenceGlucoseMgdl, 175)
        XCTAssertEqual(result.peakMgdl, 185, accuracy: 1e-9)
        XCTAssertEqual(result.peakDate, now.addingTimeInterval(10 * 60))
        XCTAssertEqual(result.windowStart, now)
        XCTAssertEqual(result.activeInsulinUnits, 0)
        XCTAssertGreaterThan(try XCTUnwrap(value.highAdvisory?.calculation.suggestedUnits), 0)
        XCTAssertEqual(value.result.points, try outcome().result.points,
            "Advising must not alter the existing engine curve")
    }

    func testThresholdIsStrictAndAlreadyHighRemainsWithMeasuredAlarm() throws {
        let value = try outcome()
        XCTAssertNil(prediction(value, limit: 185))
        XCTAssertNotNil(prediction(value, limit: 185.nextDown))
        XCTAssertNil(prediction(value, limit: 175))
        XCTAssertNil(prediction(try outcome(current: 190), current: 190))
        for invalid in [Double.nan, .infinity, 0, LowSoonAlertPolicy.predictedLimitMgdl, 601] {
            XCTAssertNil(prediction(value, limit: invalid))
        }
    }

    func testActiveInsulinCanSuppressAdviceDespiteRealForecastCrossing() throws {
        let value = try outcome(insulin: 3)
        XCTAssertNil(value.result.reason)
        XCTAssertGreaterThan(try XCTUnwrap(value.result.points.map(\.glucoseMgdl).max()), 180)
        let calculation = try XCTUnwrap(value.highAdvisory?.calculation)
        XCTAssertEqual(calculation.lines?.insulinOnBoardUnits, 3)
        XCTAssertEqual(calculation.suggestedUnits, 0)
        if case .checked? = calculation.safety {} else { XCTFail("This must be a checked zero, not unavailable") }
        XCTAssertNil(prediction(value))
    }

    func testNoCorrectionProfileOrUncheckedSafetyCannotAdvise() throws {
        XCTAssertNil(prediction(try outcome(confirmed: false)))
        let unavailable = try outcome(sensitivity: nil)
        XCTAssertNil(prediction(unavailable))
        XCTAssertEqual(unavailable.result.reason, .missingProfile)
        let valid = try outcome()
        let noContext = GlucoseForecastSafetyOutcome(result: valid.result,
            referenceGlucoseMgdl: valid.referenceGlucoseMgdl, activeInsulinUnits: valid.activeInsulinUnits,
            slope15MgdlPerMinute: valid.slope15MgdlPerMinute)
        XCTAssertNil(prediction(noContext))
    }

    func testMustBeRisingAndCannotHideAComingLow() throws {
        let value = try outcome()
        for slope in [0.0, -0.1, Double.nan, .infinity] {
            XCTAssertNil(prediction(replacing(value, slope: slope)))
        }
        // Both grids contain the same dip: this must fail on the coming-low rule,
        // not merely because the safety and warning forecasts have different prefixes.
        let dip = try coherentCurve(value, values: [175, 70, 185])
        XCTAssertEqual(Array(try XCTUnwrap(dip.highAdvisory).safetyForecast.points.prefix(13)),
                       dip.result.points)
        XCTAssertNil(prediction(dip))
    }

    func testExpectedReadingAndInsulinMustMatchSameSnapshot() throws {
        let value = try outcome()
        XCTAssertNil(prediction(value, current: 174))
        XCTAssertNil(prediction(value, sensor: "another-sensor"))
        XCTAssertNil(prediction(replacing(value, iob: 1)))
        XCTAssertNil(prediction(replacing(value, iob: .nan)))
    }

    func testDelayedCalculationCannotUseAStaleSnapshot() throws {
        let value = try outcome()
        XCTAssertNotNil(prediction(value, at: now.addingTimeInterval(30)))
        XCTAssertNil(prediction(value, at: now.addingTimeInterval(30.01)))
        XCTAssertNil(prediction(value, at: now.addingTimeInterval(-1)))
        XCTAssertNil(prediction(value, at: now.addingTimeInterval(331)))
    }

    func testMalformedAndInvalidForecastPointsAreRejected() throws {
        let value = try outcome()
        var missing = value.result.points
        missing.remove(at: 3)
        var duplicate = value.result.points
        duplicate.insert(duplicate[3], at: 3)
        for grid in [[], missing, duplicate, Array(value.result.points.prefix(6))] {
            XCTAssertNil(prediction(replacing(value, points: grid)))
        }
        for glucose in [Double.nan, .infinity, 19, 601] {
            var grid = value.result.points
            grid[3] = .init(date: grid[3].date, glucoseMgdl: glucose)
            XCTAssertNil(prediction(replacing(value, points: grid)))
        }
    }

    func testDifferentSafetyForecastCannotBeMixedWithPrediction() throws {
        let value = try outcome()
        let context = try XCTUnwrap(value.highAdvisory)
        let wrongContext = HighSoonAdvisoryContext(capturedAt: context.capturedAt,
            treatmentRevision: context.treatmentRevision,
            forecastInputChangeRevision: context.forecastInputChangeRevision,
            sourceSignature: context.sourceSignature, profile: context.profile,
            safetyForecast: try XCTUnwrap(outcome(current: 176).highAdvisory?.safetyForecast),
            calculation: context.calculation)
        XCTAssertNil(prediction(replacing(value, context: wrongContext)))
    }

    /// Synthetic curves isolate peak-window boundaries while retaining a coherent pair
    /// of 60/120-minute grids and the separately tested, real calculator context.
    private func coherentCurve(_ value: GlucoseForecastSafetyOutcome, values: [Double],
                               capturedAt: Date? = nil) throws -> GlucoseForecastSafetyOutcome {
        let old = try XCTUnwrap(value.highAdvisory)
        let points = stride(from: 0, through: 120, by: 5).map { minute in
            GlucoseForecastPoint(date: now.addingTimeInterval(Double(minute) * 60),
                glucoseMgdl: values[min(minute / 5, values.count - 1)])
        }
        let context = HighSoonAdvisoryContext(capturedAt: capturedAt ?? old.capturedAt,
            treatmentRevision: old.treatmentRevision,
            forecastInputChangeRevision: old.forecastInputChangeRevision,
            sourceSignature: old.sourceSignature, profile: old.profile,
            safetyForecast: .init(points: points, referenceDate: now, reason: nil,
                referenceSensorID: "synthetic-sensor"), calculation: old.calculation)
        return replacing(value, points: Array(points.prefix(13)), context: context)
    }

    func testAlreadyPassedHighPeakIsNotAnUpcomingHigh() throws {
        let nowAfterPeak = now.addingTimeInterval(330)
        let curve = try coherentCurve(outcome(), values: [175, 181, 160], capturedAt: nowAfterPeak)
        XCTAssertNil(prediction(curve, at: nowAfterPeak),
            "At now the interpolated curve is already below180, and the only high peak is in the past")
        let original = try coherentCurve(outcome(), values: [175, 181, 160])
        XCTAssertNotNil(prediction(original), "The same peak was relevant before it occurred")
    }

    func testInterpolatedThirtyMinuteBoundaryIncludesCrossingButNotLaterPeak() throws {
        let curve = try coherentCurve(outcome(), values: [175, 175, 175, 175, 175, 175, 179, 199, 250])
        let assessmentTime = now.addingTimeInterval(30)
        let result = try XCTUnwrap(prediction(curve, at: assessmentTime))
        XCTAssertEqual(result.peakDate, assessmentTime.addingTimeInterval(30 * 60))
        XCTAssertEqual(result.peakMgdl, 181, accuracy: 1e-9)
        XCTAssertNil(prediction(curve), "At the original anchor, the +30 endpoint has not crossed")
    }

    func testDefaultEnabledAndThirtyMinuteLimitAreIndependentAndPersistent() throws {
        let suite = "HighSoonAdvisoryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(HighSoonAdvisoryPolicy.isEnabled(defaults: defaults))
        defaults.set(false, forKey: HighSoonAdvisoryPolicy.enabledKey)
        XCTAssertFalse(HighSoonAdvisoryPolicy.isEnabled(defaults: defaults))
        XCTAssertTrue(HighSoonAdvisoryPolicy.maySchedule(lastScheduled: nil, at: now))
        XCTAssertFalse(HighSoonAdvisoryPolicy.maySchedule(lastScheduled: now, at: now.addingTimeInterval(1799)))
        XCTAssertTrue(HighSoonAdvisoryPolicy.maySchedule(lastScheduled: now, at: now.addingTimeInterval(1800)))
        XCTAssertFalse(HighSoonAdvisoryPolicy.maySchedule(lastScheduled: now, at: now.addingTimeInterval(-1)))
    }
}
