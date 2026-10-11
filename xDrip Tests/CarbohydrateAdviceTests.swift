import XCTest
@testable import xdrip

final class CarbohydrateAdviceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func context(values: [Double] = [100, 100, 100, 78, 76, 74, 72],
                         treatments: [TherapyTreatment] = [],
                         glucoseInput: PenDoseGlucoseInput = .currentCGM,
                         sensitivity: Double? = 40, ratio: Double? = 10,
                         glucoseAge: TimeInterval = 0,
                         capturedAt: Date? = nil, computedAt: Date? = nil,
                         source: String = "validated-local-source",
                         sensor: String? = "sensor-a", forecastSensor: String? = "sensor-a",
                         forecastReason: GlucoseForecastUnavailableReason? = nil,
                         forecastReferenceShift: TimeInterval = 0,
                         omitForecastMinute: Int? = nil) throws -> CarbohydrateAdviceContext {
        let reference = now.addingTimeInterval(-glucoseAge)
        let glucose = stride(from: -30, through: 0, by: 5).map {
            GlucoseForecastSample(date: reference.addingTimeInterval(Double($0) * 60),
                glucoseMgdl: values[0], sensorID: sensor)
        }
        let snapshot = try PenDoseInputSnapshot.make(capturedAt: capturedAt ?? now,
            glucose: glucose, treatments: treatments, therapySettings: TherapyModelSettings(),
            treatmentRevision: 1, sourceSignature: source).get()
        let points = stride(from: 0, through: 60, by: 5).compactMap { minute -> GlucoseForecastPoint? in
            guard minute != omitForecastMinute else { return nil }
            return GlucoseForecastPoint(date: reference.addingTimeInterval(Double(minute) * 60),
                glucoseMgdl: values[min(minute / 5, values.count - 1)])
        }
        let forecast = GlucoseForecastResult(points: points,
            referenceDate: reference.addingTimeInterval(forecastReferenceShift),
            reason: forecastReason, referenceSensorID: forecastSensor)
        return CarbohydrateAdviceContext(snapshot: snapshot, forecast: forecast,
            glucoseInput: glucoseInput, sensitivityMgdlPerUnit: sensitivity,
            carbohydrateRatioGramsPerUnit: ratio, computedAt: computedAt ?? now)
    }

    private func fastCarbs(grams: Double = 10, minutesAgo: Double,
                           deleted: Bool = false) -> TherapyTreatment {
        TherapyTreatment(date: now.addingTimeInterval(-minutesAgo * 60), amount: grams,
            isIOB: false, carbohydrateDurationMinutes: TreatmentMealKind.fast.durationMinutes,
            isAppLocal: true, isDeletedCurrentRevision: deleted, stableIdentity: "local.fast.1")
    }

    func testWholeGramEstimateMeetsEveryPointWithoutChangingBaseForecast() throws {
        let input = try context()
        let before = input.forecast.points
        let result = CarbohydrateAdvice.evaluate(input, at: now)
        XCTAssertEqual(result.status, .estimated)
        XCTAssertEqual(result.grams, 3, "hand calculation: the +15 min point requires about 2.34 g")
        XCTAssertEqual(result.forecastMinimumMgdl, 72)
        XCTAssertEqual(result.forecastMinimumDate, now.addingTimeInterval(30 * 60))
        XCTAssertEqual(input.forecast.points, before)
        let grams = Double(try XCTUnwrap(result.grams))
        for point in before where point.date > now && point.date <= now.addingTimeInterval(30 * 60) {
            let absorbed = grams - TherapyCalculations.carbsRemaining(grams: grams,
                minutes: point.date.timeIntervalSince(now) / 60, duration: 30)
            XCTAssertGreaterThanOrEqual(point.glucoseMgdl + absorbed * 4, CarbohydrateAdvice.bufferMgdl)
        }
        let at15 = try XCTUnwrap(before.first { $0.date == now.addingTimeInterval(15 * 60) })
        let smallerAbsorption = 2 - TherapyCalculations.carbsRemaining(grams: 2, minutes: 15, duration: 30)
        XCTAssertLessThan(at15.glucoseMgdl + smallerAbsorption * 4, CarbohydrateAdvice.bufferMgdl,
            "a whole gram less must fail at the constraining point")
    }

    func testStableBelowWarningMarginDoesNotChasePersonalTarget() throws {
        XCTAssertEqual(CarbohydrateAdvice.evaluate(try context(values: [76]), at: now).status, .noRisk)
        XCTAssertEqual(CarbohydrateAdvice.evaluate(try context(values: [100]), at: now).status, .noRisk)
        XCTAssertEqual(CarbohydrateAdvice.evaluate(try context(values: [76, 77, 78, 79, 80, 81, 82]),
            at: now).status, .noRisk)
    }

    func testCurrentLowWinsOverRecentCarbohydratesAndUnavailableForecast() throws {
        let input = try context(values: [65], treatments: [fastCarbs(minutesAgo: 2)],
            forecastReason: .historyGap)
        let result = CarbohydrateAdvice.evaluate(input, at: now)
        XCTAssertEqual(result.status, .currentLow)
        XCTAssertNil(result.grams)
        XCTAssertEqual(result.latestFastCarbs?.grams, 10)
    }

    func testNoEstimateWhenBufferIsCrossedBeforeModelledFoodEffect() throws {
        for values: [Double] in [[100, 78, 77, 76, 75, 74, 73], [100, 90, 78, 77, 76, 75, 74]] {
            let result = CarbohydrateAdvice.evaluate(try context(values: values), at: now)
            XCTAssertEqual(result.status, .tooSoon)
            XCTAssertNil(result.grams)
        }
    }

    func testFoodIsNotBackdatedToReferenceReading() throws {
        // At +15 from reference the hypothetical food is only ten minutes old.
        let result = CarbohydrateAdvice.evaluate(try context(glucoseAge: 5 * 60), at: now)
        XCTAssertEqual(result.status, .tooSoon)
        XCTAssertNil(result.grams)
    }

    func testTheWindowCoversThirtyMinutesFromNowNotFromOldCGM() throws {
        let input = try context(values: [100, 100, 100, 90, 90, 90, 90, 70], glucoseAge: 60)
        let result = CarbohydrateAdvice.evaluate(input, at: now)
        XCTAssertEqual(result.status, .noRisk, "at now+30 (+31 from reading), interpolation is 86")
        let later = try context(values: [100, 100, 100, 90, 90, 90, 80, 70], glucoseAge: 60)
        let laterResult = CarbohydrateAdvice.evaluate(later, at: now)
        XCTAssertEqual(laterResult.status, .estimated)
        XCTAssertEqual(laterResult.forecastMinimumDate, now.addingTimeInterval(30 * 60))
        XCTAssertEqual(laterResult.forecastMinimumMgdl, 78)
    }

    func testLargerRequirementAbstainsRatherThanClampingToFifteen() throws {
        let result = CarbohydrateAdvice.evaluate(try context(sensitivity: 5), at: now)
        XCTAssertEqual(result.status, .aboveModelLimit)
        XCTAssertNil(result.grams)
    }

    func testWholeGramRoundoffAndEstimatorLimitAreDistinguished() throws {
        let fraction = 1 - TherapyCalculations.carbsRemaining(grams: 1, minutes: 30, duration: 30)
        for grams in [3.0, 15.0] {
            let endpoint = CarbohydrateAdvice.bufferMgdl - grams * 4 * fraction
            let result = CarbohydrateAdvice.evaluate(try context(
                values: [100, 100, 100, 100, 100, 100, endpoint]), at: now)
            XCTAssertEqual(result.status, .estimated)
            XCTAssertEqual(result.grams, Int(grams))
        }
        let endpoint = CarbohydrateAdvice.bufferMgdl - 15.0001 * 4 * fraction
        let larger = CarbohydrateAdvice.evaluate(try context(
            values: [100, 100, 100, 100, 100, 100, endpoint]), at: now)
        XCTAssertEqual(larger.status, .aboveModelLimit)
        XCTAssertNil(larger.grams)
    }

    func testFastCarbohydratesPreventRepeatProposalUntilModelledWindowEnds() throws {
        let input = try context(treatments: [fastCarbs(minutesAgo: 39)])
        let result = CarbohydrateAdvice.evaluate(input, at: now)
        XCTAssertEqual(result.status, .recentCarbs)
        XCTAssertNil(result.grams)
        XCTAssertEqual(result.latestFastCarbs?.stableIdentity, "local.fast.1")
        XCTAssertEqual(result.latestFastCarbs?.date, now.addingTimeInterval(-39 * 60))
        XCTAssertEqual(CarbohydrateAdvice.evaluate(try context(treatments: [fastCarbs(minutesAgo: 40)]),
            at: now).status, .estimated)
        let worsening = try context(values: [100, 78, 77, 76, 75, 74, 73],
            treatments: [fastCarbs(minutesAgo: 2)])
        XCTAssertEqual(CarbohydrateAdvice.evaluate(worsening, at: now).status, .tooSoon,
            "recent food must not hide that the buffer is crossed before modeled new food can act")
    }

    func testDeletedOrFutureFoodDoesNotCreateRepeatEvidence() throws {
        let result = CarbohydrateAdvice.evaluate(try context(treatments: [
            fastCarbs(minutesAgo: 5, deleted: true), fastCarbs(minutesAgo: -10)]), at: now)
        XCTAssertEqual(result.status, .estimated)
        XCTAssertNil(result.latestFastCarbs)
    }

    func testChangedTreatmentsAfterReferenceRequireNewMeasurement() throws {
        let result = CarbohydrateAdvice.evaluate(try context(treatments: [fastCarbs(minutesAgo: 1)],
            glucoseAge: 120), at: now)
        XCTAssertEqual(result.status, .missingData)
        XCTAssertNil(result.grams)
    }

    func testManualAndExplicitlyUntrendedCGMAreNeverAutomaticallyEstimated() throws {
        let modes: [PenDoseGlucoseInput] = [.manual(valueMgdl: 100, measuredAt: now),
            .confirmedStale(valueMgdl: 100, measuredAt: now, sensorID: "sensor-a")]
        for mode in modes {
            let result = CarbohydrateAdvice.evaluate(try context(glucoseInput: mode), at: now)
            XCTAssertEqual(result.status, .manualGlucose)
            XCTAssertNil(result.grams)
        }
    }

    func testSnapshotAndResultExpireEvenWithSameFreshCGM() throws {
        let input = try context()
        XCTAssertEqual(CarbohydrateAdvice.evaluate(input, at: now.addingTimeInterval(31)).status, .missingData)
        XCTAssertEqual(CarbohydrateAdvice.evaluate(try context(computedAt: now.addingTimeInterval(-31)),
            at: now).status, .missingData)
        XCTAssertEqual(CarbohydrateAdvice.evaluate(try context(computedAt: now.addingTimeInterval(1)),
            at: now).status, .missingData)
        XCTAssertEqual(CarbohydrateAdvice.evaluate(try context(glucoseAge: 331), at: now).status, .missingData)
    }

    func testMismatchedSensorAnchorOrUnavailableForecastCannotEstimate() throws {
        let inputs = [try context(forecastSensor: "sensor-b"), try context(sensor: nil),
            try context(forecastReferenceShift: 1), try context(forecastReason: .historyGap),
            try context(source: ""), try context(omitForecastMinute: 10)]
        for input in inputs {
            let result = CarbohydrateAdvice.evaluate(input, at: now)
            XCTAssertEqual(result.status, .missingData)
            XCTAssertNil(result.grams)
        }
    }

    func testInvalidParametersAndForecastValuesAreNotConvertedToZero() throws {
        XCTAssertEqual(CarbohydrateAdvice.evaluate(try context(sensitivity: nil), at: now).status, .missingData)
        XCTAssertEqual(CarbohydrateAdvice.evaluate(try context(ratio: nil), at: now).status, .missingData)
        for sensitivity in [Double.nan, .infinity, 0, -1] {
            XCTAssertEqual(CarbohydrateAdvice.evaluate(try context(sensitivity: sensitivity), at: now).status,
                .missingData)
        }
        for ratio in [Double.nan, .infinity, 0, -1] {
            XCTAssertEqual(CarbohydrateAdvice.evaluate(try context(ratio: ratio), at: now).status, .missingData)
        }
        for value in [Double.nan, .infinity, 19, 601] {
            let result = CarbohydrateAdvice.evaluate(try context(values: [100, 100, 100, value]), at: now)
            XCTAssertEqual(result.status, .missingData, "Invalid forecast glucose: \(value)")
            XCTAssertNil(result.grams)
        }
    }

    func testEquivalentGlucoseUnitsGiveIdenticalEstimate() throws {
        let mgdlSensitivity = 40.0
        let mmolSensitivity = mgdlSensitivity * ConstantsBloodGlucose.mgDlToMmoll
        let mgdl = CarbohydrateAdvice.evaluate(try context(sensitivity: mgdlSensitivity), at: now)
        let converted = CarbohydrateAdvice.evaluate(try context(
            sensitivity: mmolSensitivity / ConstantsBloodGlucose.mgDlToMmoll), at: now)
        XCTAssertEqual(mgdl.grams, converted.grams)
        XCTAssertEqual(mgdl.status, converted.status)
    }

    func testRealEngineWithExistingInsulinAndCarbsIsUnmodifiedAndNotCountedTwice() throws {
        let bolus = TherapyTreatment(date: now.addingTimeInterval(-60 * 60), amount: 8, isIOB: true)
        let meal = TherapyTreatment(date: now.addingTimeInterval(-45 * 60), amount: 4, isIOB: false,
            carbohydrateDurationMinutes: 240)
        let basic = try context(values: [110], treatments: [bolus, meal])
        let engineInput = GlucoseForecastInput(glucose: basic.snapshot.glucose,
            treatments: basic.snapshot.treatments, settings: basic.snapshot.therapySettings,
            sensitivityMgdlPerUnit: 40, carbohydrateRatioGramsPerUnit: 10,
            horizonMinutes: 60, now: now)
        let predicted = GlucoseForecastEngine.predict(engineInput)
        XCTAssertNil(predicted.reason)
        let forecast = GlucoseForecastResult(points: predicted.points,
            referenceDate: predicted.referenceDate, reason: predicted.reason, referenceSensorID: "sensor-a")
        let input = CarbohydrateAdviceContext(snapshot: basic.snapshot, forecast: forecast,
            glucoseInput: .currentCGM, sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, computedAt: now)
        let result = CarbohydrateAdvice.evaluate(input, at: now)
        XCTAssertEqual(result.status, .estimated)
        let grams = Double(try XCTUnwrap(result.grams))
        let conditional = try XCTUnwrap(GlucoseForecastEngine.conditionalPlannedCarbohydratePoints(
            base: forecast, planned: [TherapyTreatment(date: now, amount: grams, isIOB: false,
                carbohydrateDurationMinutes: 30)], sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, settings: basic.snapshot.therapySettings))
        XCTAssertTrue(conditional.filter { $0.date <= now.addingTimeInterval(30 * 60) }
            .allSatisfy { $0.glucoseMgdl >= CarbohydrateAdvice.bufferMgdl })
        XCTAssertEqual(GlucoseForecastEngine.predict(engineInput).points, predicted.points)
        XCTAssertEqual(input.snapshot.iobUnits, basic.snapshot.iobUnits)
        XCTAssertEqual(input.snapshot.cobGrams, basic.snapshot.cobGrams)
    }

    func testResultCanBeRecordedWithoutChangingItsImmutableEvidence() throws {
        let result = CarbohydrateAdvice.evaluate(try context(), at: now)
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(CarbohydrateAdviceResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }
}
