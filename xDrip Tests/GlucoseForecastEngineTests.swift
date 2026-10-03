import XCTest
@testable import xdrip

final class GlucoseForecastEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func glucose(_ value: Double = 120, spacingMinutes: Int = 1,
                         omit: Set<Int> = []) -> [GlucoseForecastSample] {
        stride(from: -30, through: 0, by: spacingMinutes).compactMap { minute in
            guard !omit.contains(minute) else { return nil }
            return GlucoseForecastSample(date: now.addingTimeInterval(Double(minute) * 60),
                                         glucoseMgdl: value)
        }
    }

    private func input(_ samples: [GlucoseForecastSample]? = nil,
                       treatments: [TherapyTreatment] = [], horizon: Int = 60,
                       sensitivity: Double? = 40, ratio: Double? = 10,
                       at date: Date? = nil) -> GlucoseForecastInput {
        GlucoseForecastInput(glucose: samples ?? glucose(), treatments: treatments,
                             settings: TherapyModelSettings(),
                             sensitivityMgdlPerUnit: sensitivity,
                             carbohydrateRatioGramsPerUnit: ratio,
                             horizonMinutes: horizon, now: date ?? now)
    }

    private func treatment(_ amount: Double, minutesAgo: Double = 0,
                           insulin: Bool) -> TherapyTreatment {
        TherapyTreatment(date: now.addingTimeInterval(-minutesAgo * 60),
                         amount: amount, isIOB: insulin)
    }

    func testFlatHistoryWithoutTreatmentsStaysFlatAtBothHorizons() {
        for horizon in [60, 120] {
            let result = GlucoseForecastEngine.predict(input(horizon: horizon))
            XCTAssertNil(result.reason)
            XCTAssertEqual(result.points.count, horizon / 5 + 1)
            XCTAssertEqual(result.referenceDate, now)
            XCTAssertEqual(result.value(atMinutes: 30), 120)
            XCTAssertEqual(result.value(atMinutes: horizon), 120)
            XCTAssertNil(result.value(atMinutes: 35 + horizon))
            XCTAssertEqual(result.points.map(\.date), stride(from: 0, through: horizon, by: 5)
                .map { now.addingTimeInterval(Double($0 * 60)) })
        }
    }

    func testInsulinAndCarbohydratesUseRemainingCurvesNotCurrentAmounts() throws {
        let dose = treatment(1, insulin: true)
        let meal = treatment(10, insulin: false)
        let insulin = GlucoseForecastEngine.predict(input(treatments: [dose]))
        let carbs = GlucoseForecastEngine.predict(input(treatments: [meal]))
        let both = GlucoseForecastEngine.predict(input(treatments: [dose, meal]))
        for minute in [5, 30, 60] {
            let i = try XCTUnwrap(insulin.value(atMinutes: minute))
            let c = try XCTUnwrap(carbs.value(atMinutes: minute))
            let b = try XCTUnwrap(both.value(atMinutes: minute))
            let insulinAbsorbed = 1 - TherapyCalculations.insulinRemaining(units: 1,
                minutes: Double(minute), duration: TherapyModelSettings.defaultInsulinDuration,
                peak: TherapyModelSettings().insulinPeak)
            let carbsAbsorbed = 10 - TherapyCalculations.carbsRemaining(grams: 10,
                minutes: Double(minute), duration: TherapyModelSettings().carbDuration)
            XCTAssertEqual(i, 120 - 40 * insulinAbsorbed, accuracy: 1e-8)
            XCTAssertEqual(c, 120 + 4 * carbsAbsorbed, accuracy: 1e-8)
            XCTAssertEqual(b, i + c - 120, accuracy: 1e-8)
        }
        XCTAssertLessThan(try XCTUnwrap(insulin.value(atMinutes: 5)), 120)
        // xDrip's selected carbohydrate curve includes its existing 10-min delay.
        XCTAssertEqual(try XCTUnwrap(carbs.value(atMinutes: 5)), 120, accuracy: 1e-8)
        XCTAssertGreaterThan(try XCTUnwrap(carbs.value(atMinutes: 30)), 120)
    }

    func testEarlierDoseOnlyCountsEffectStillPendingAtReferenceTime() throws {
        // The model's future drop begins from remaining insulin at now, not
        // from its original amount. A completely spent treatment has no effect.
        let recent = treatment(2, minutesAgo: 120, insulin: true)
        // Fully spent throughout the 30-minute history window, so it cannot
        // affect either future modeled therapy or observed residual momentum.
        let spent = treatment(4, minutesAgo: 631, insulin: true)
        let reference = GlucoseForecastEngine.predict(input(treatments: [recent]))
        let withSpent = GlucoseForecastEngine.predict(input(treatments: [recent, spent]))
        XCTAssertEqual(try XCTUnwrap(reference.value(atMinutes: 60)),
                       try XCTUnwrap(withSpent.value(atMinutes: 60)), accuracy: 1e-10)
        XCTAssertNotEqual(try XCTUnwrap(reference.value(atMinutes: 5)),
                          try XCTUnwrap(reference.value(atMinutes: 60)))
    }

    func testTreatmentsPastModelDurationDoNotCreateFutureEffect() {
        let spentInsulin = treatment(3, minutesAgo: 631, insulin: true)
        // Carb model also has its existing ten-minute delay.
        let spentCarbs = treatment(30, minutesAgo: 281, insulin: false)
        let result = GlucoseForecastEngine.predict(input(treatments: [spentInsulin, spentCarbs],
                                                         horizon: 120))
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.value(atMinutes: 0), 120)
        XCTAssertEqual(result.value(atMinutes: 60), 120)
        XCTAssertEqual(result.value(atMinutes: 120), 120)
    }

    func testModeledRecentMealIsRemovedFromObservedMomentum() throws {
        let meal = treatment(20, minutesAgo: 30, insulin: false)
        let settings = TherapyModelSettings()
        let samples = stride(from: -30, through: 0, by: 1).map { minute -> GlucoseForecastSample in
            let elapsed = Double(minute + 30)
            let absorbed = 20 - TherapyCalculations.carbsRemaining(grams: 20,
                minutes: elapsed, duration: settings.carbDuration)
            return GlucoseForecastSample(date: now.addingTimeInterval(Double(minute) * 60),
                glucoseMgdl: 120 + absorbed * 4)
        }
        let result = GlucoseForecastEngine.predict(input(samples, treatments: [meal]))
        XCTAssertNil(result.reason)
        let current = try XCTUnwrap(samples.last).glucoseMgdl
        let futureAbsorbed = 20 - TherapyCalculations.carbsRemaining(grams: 20,
            minutes: 60 + 30, duration: settings.carbDuration)
        let currentAbsorbed = 20 - TherapyCalculations.carbsRemaining(grams: 20,
            minutes: 30, duration: settings.carbDuration)
        XCTAssertEqual(try XCTUnwrap(result.value(atMinutes: 60)),
            current + (futureAbsorbed - currentAbsorbed) * 4, accuracy: 1e-7)
    }

    func testResidualMomentumDecaysInsteadOfExtrapolatingForTwoHours() throws {
        let samples = stride(from: -30, through: 0, by: 1).map { minute in
            GlucoseForecastSample(date: now.addingTimeInterval(Double(minute) * 60),
                                  glucoseMgdl: 120 + Double(minute))
        }
        let result = GlucoseForecastEngine.predict(input(samples, horizon: 120))
        XCTAssertNil(result.reason)
        XCTAssertGreaterThan(try XCTUnwrap(result.value(atMinutes: 30)), 120)
        XCTAssertLessThan(try XCTUnwrap(result.value(atMinutes: 120)), 120 + 120)
        XCTAssertEqual(try XCTUnwrap(result.value(atMinutes: 120)),
                       try XCTUnwrap(result.value(atMinutes: 60)), accuracy: 1e-7)
    }

    func testStaleMissingAndInterruptedGlucoseAreUnavailable() {
        XCTAssertEqual(GlucoseForecastEngine.predict(input([])).reason, .missingGlucose)
        XCTAssertEqual(GlucoseForecastEngine.predict(input(at: now.addingTimeInterval(331))).reason,
                       .staleGlucose)
        let gap = glucose(omit: Set(-24 ... -16))
        XCTAssertEqual(GlucoseForecastEngine.predict(input(gap)).reason, .historyGap)
        let short = glucose().filter { $0.date >= now.addingTimeInterval(-20 * 60) }
        XCTAssertEqual(GlucoseForecastEngine.predict(input(short)).reason, .insufficientHistory)
    }

    func testMissingOrInvalidProfileIsNotTreatedAsZero() {
        XCTAssertEqual(GlucoseForecastEngine.predict(input(sensitivity: nil)).reason, .missingProfile)
        XCTAssertEqual(GlucoseForecastEngine.predict(input(ratio: nil)).reason, .missingProfile)
        XCTAssertEqual(GlucoseForecastEngine.predict(input(sensitivity: 0)).reason, .invalidProfile)
        XCTAssertEqual(GlucoseForecastEngine.predict(input(ratio: .nan)).reason, .invalidProfile)
        XCTAssertEqual(GlucoseForecastEngine.predict(input(horizon: 35)).reason, .invalidHorizon)
        XCTAssertEqual(GlucoseForecastEngine.predict(input(treatments: [treatment(.nan, insulin: true)])).reason,
                       .invalidTreatment)
    }

    func testActualSampleTimesDriveTrend() throws {
        let minutes = [-30, -27, -24, -21, -18, -15, -12, -10, -8, -6, -4, -2, 0]
        let samples = minutes.map { minute in
            GlucoseForecastSample(date: now.addingTimeInterval(Double(minute * 60)),
                                  glucoseMgdl: 120 + Double(minute) / 2)
        }
        let result = GlucoseForecastEngine.predict(input(samples))
        XCTAssertNil(result.reason)
        XCTAssertGreaterThan(try XCTUnwrap(result.value(atMinutes: 5)), 120)
        XCTAssertLessThan(try XCTUnwrap(result.value(atMinutes: 60)), 150)
    }

    func testContinuousFiveMinuteSensorHistoryIsSufficient() {
        let result = GlucoseForecastEngine.predict(input(glucose(spacingMinutes: 5)))
        XCTAssertNil(result.reason)
        XCTAssertEqual(result.value(atMinutes: 60), 120)

        let jittered = glucose(spacingMinutes: 5).map { sample in
            GlucoseForecastSample(date: sample.date == now ? sample.date : sample.date.addingTimeInterval(-2),
                                  glucoseMgdl: sample.glucoseMgdl)
        }
        let jitteredResult = GlucoseForecastEngine.predict(input(jittered))
        XCTAssertNil(jitteredResult.reason)
        XCTAssertEqual(jitteredResult.value(atMinutes: 60), 120)
    }
}
