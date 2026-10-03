import XCTest
@testable import xdrip

final class GlucoseForecastMLReplayTests: XCTestCase {
    private let reference = Date(timeIntervalSince1970: 1_800_000_000)
    private let settings = TherapyModelSettings()

    private func observation(_ minute: Int, value: Double = 120, sensor: String? = "A",
                             valid: Bool = true, suppressed: Bool = false)
        -> GlucoseForecastGlucoseObservation {
        GlucoseForecastGlucoseObservation(date: reference.addingTimeInterval(Double(minute) * 60),
            glucoseMgdl: value, sensorID: sensor, isValidForDownstream: valid,
            isSuppressedByFiveMinuteCadence: suppressed)
    }

    private func readings(from first: Int = -30, through last: Int = 150, by step: Int = 1,
                          sensor: String = "A") -> [GlucoseForecastGlucoseObservation] {
        stride(from: first, through: last, by: step).map { observation($0, sensor: sensor) }
    }

    private func batch(_ observations: [GlucoseForecastGlucoseObservation],
                       treatments: [TherapyTreatment] = [], minutes: Int = 1,
                       previous: Date? = nil) -> GlucoseForecastMLReplayBatch {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return GlucoseForecastMLReplay.batch(observations: observations, treatments: treatments,
            settings: settings, sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, anchorStart: reference,
            anchorEnd: reference.addingTimeInterval(Double(minutes) * 60),
            previousAnchorDate: previous, calendar: calendar)
    }

    func testSharedSelectorKeepsEveryRawPointAndRejectsAmbiguousSensorHistory() {
        let minuteHistory = (-30...0).map { observation($0) }
        let selected = GlucoseForecastGlucoseSelection.select(minuteHistory, at: reference)
        XCTAssertEqual(selected.count, 31)
        XCTAssertEqual(selected.map(\.date), minuteHistory.map(\.date))
        XCTAssertEqual(GlucoseForecastGlucoseSelection.select(
            minuteHistory + [observation(0, value: 121)], at: reference).count, 0)
        XCTAssertEqual(GlucoseForecastGlucoseSelection.select(
            minuteHistory + [observation(1, sensor: "B", valid: false)],
            at: reference.addingTimeInterval(60)).count, 0)
        XCTAssertEqual(GlucoseForecastGlucoseSelection.select(
            minuteHistory + [observation(0, sensor: nil)], at: reference).count, 0)
    }

    func testOneAndFiveMinuteCadenceSelectDeterministicTenMinuteAnchors() {
        let oneMinute = batch(readings(), minutes: 21)
        let fiveMinute = batch(readings(by: 5), minutes: 21)
        func anchors(_ examples: [GlucoseForecastMLReplayExample]) -> [Int] {
            examples.filter { $0.row.horizonMinutes == 30 }.map {
                Int($0.row.referenceDate.timeIntervalSince(reference) / 60)
            }
        }
        XCTAssertEqual(anchors(oneMinute.examples), [0, 10, 20])
        XCTAssertEqual(anchors(fiveMinute.examples), [0, 10, 20])
        XCTAssertEqual(oneMinute.examples.count, 9)
        XCTAssertEqual(fiveMinute.examples.count, 9)
        XCTAssertEqual(oneMinute.lastAnchorDate, reference.addingTimeInterval(20 * 60))
        XCTAssertEqual(batch(readings(), minutes: 11, previous: reference.addingTimeInterval(-60))
            .examples.first?.row.referenceDate, reference.addingTimeInterval(9 * 60))
    }

    func testSharedSixteenFeaturesUseRawSlopesAndTreatmentCurves() throws {
        let samples = (-30...0).map { minute in
            GlucoseForecastSample(date: reference.addingTimeInterval(Double(minute) * 60),
                                  glucoseMgdl: 120 + Double(minute), sensorID: "A")
        }
        let dose = TherapyTreatment(date: reference.addingTimeInterval(-20 * 60), amount: 2, isIOB: true)
        let meal = TherapyTreatment(date: reference.addingTimeInterval(-10 * 60), amount: 15, isIOB: false)
        let input = GlucoseForecastInput(glucose: samples, treatments: [dose, meal],
            settings: settings, sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, horizonMinutes: 60, now: reference)
        let result = GlucoseForecastEngine.predict(input)
        let row = try XCTUnwrap(GlucoseForecastMLFeatures.row(input: input, result: result,
            horizonMinutes: 30))
        XCTAssertEqual(GlucoseForecastMLFeatures.featureNames.count, 16)
        XCTAssertEqual(row.values.count, 16)
        XCTAssertEqual(row.values[0], 120)
        XCTAssertEqual(row.values[1], 1, accuracy: 1e-10)
        XCTAssertEqual(row.values[2], 1, accuracy: 1e-10)
        XCTAssertEqual(row.values[3], row.engineValue - row.glucose, accuracy: 1e-10)
        XCTAssertEqual(row.values[8], 20)
        XCTAssertEqual(row.values[9], 2)
        XCTAssertEqual(row.values[10], 10)
        XCTAssertEqual(row.values[11], 15)
        XCTAssertEqual(row.values[15], 31)
        let currentIOB = TherapyCalculations.insulinRemaining(units: 2, minutes: 20,
            duration: settings.insulinDuration, peak: settings.insulinPeak)
        let futureIOB = TherapyCalculations.insulinRemaining(units: 2, minutes: 50,
            duration: settings.insulinDuration, peak: settings.insulinPeak)
        XCTAssertEqual(row.values[6], currentIOB, accuracy: 1e-10)
        XCTAssertEqual(row.values[4], currentIOB - futureIOB, accuracy: 1e-10)
        XCTAssertEqual(row.values[7], TherapyCalculations.carbsRemaining(grams: 15,
            minutes: 10, duration: settings.carbDuration), accuracy: 1e-10)
    }

    func testFutureTreatmentDoesNotEnterFeaturesAndHistoricalKnownTimeIsUnknown() throws {
        let base = batch(readings(), minutes: 1)
        let futureDose = TherapyTreatment(date: reference.addingTimeInterval(60), amount: 20, isIOB: true)
        let withFuture = batch(readings(), treatments: [futureDose], minutes: 1)
        XCTAssertEqual(base.examples.count, 3)
        XCTAssertEqual(withFuture.examples.count, 3)
        for (original, changed) in zip(base.examples, withFuture.examples) {
            XCTAssertEqual(original.row.values, changed.row.values)
            XCTAssertEqual(original.row.engineValue, changed.row.engineValue)
            XCTAssertEqual(changed.treatmentAvailability, .retrospectiveUnknown)
            XCTAssertEqual(changed.settingsAvailability, .retrospectiveUnknown)
        }
    }

    func testTargetUsesNearestValidSameSensorReadingWithEarlierTie() throws {
        let history = readings(through: 0, by: 5)
        let nearby = history + [observation(29, value: 131), observation(31, value: 141),
                                observation(60, value: 150), observation(120, value: 160)]
        let examples = batch(nearby, minutes: 1).examples
        XCTAssertEqual(examples.count, 3)
        XCTAssertEqual(examples[0].row.horizonMinutes, 30)
        XCTAssertEqual(examples[0].targetDate, reference.addingTimeInterval(29 * 60))
        XCTAssertEqual(examples[0].targetGlucoseMgdl, 131)
        XCTAssertEqual(examples[0].engineTrajectoryMgdl.count, 25)
        XCTAssertEqual(examples[0].engineTrajectoryMgdl, examples[1].engineTrajectoryMgdl)
        XCTAssertEqual(examples[1].engineTrajectoryMgdl, examples[2].engineTrajectoryMgdl)
        XCTAssertEqual(batch(history + [observation(30, sensor: "B"), observation(60),
            observation(120)], minutes: 1).examples.count, 0)
        XCTAssertEqual(batch(history + [observation(30), observation(30, value: 121),
            observation(60), observation(120)],
            minutes: 1).examples.count, 0)
    }

    func testMissingOneTargetDropsTheWholeAnchorTriple() {
        let history = readings(through: 0, by: 5)
        XCTAssertTrue(batch(history + [observation(30), observation(60)], minutes: 1)
            .examples.isEmpty)
    }
}
