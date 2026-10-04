import XCTest
@testable import xdrip

final class LowSoonStatisticsTests: XCTestCase {
    private let minute: TimeInterval = 60
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(_ minuteIndex: Int, _ mgdl: Double,
                        sensor: String? = "sensor-A") -> LowSoonStatisticsGlucose {
        .init(date: start.addingTimeInterval(Double(minuteIndex) * minute),
              mgdl: mgdl, sensorID: sensor)
    }

    private func evaluation(_ minuteIndex: Int,
                            _ status: LowSoonStatisticsEvaluation.Status = .noWarning)
        -> LowSoonStatisticsEvaluation {
        let date = start.addingTimeInterval(Double(minuteIndex) * minute)
        return .init(referenceDate: date, computedAt: date, status: status)
    }

    func testSustainedLowCountsAndPlannedWarningLeadUsesSameThirtyMinuteWindow() {
        let glucose = (0...90).map { sample($0, (40...56).contains($0) ? 65 : 110) }
        let evaluations = (0...90).map { evaluation($0, $0 == 25 ? .warningRequested : .noWarning) }
        let result = LowSoonStatisticsCalculator.calculate(glucose: glucose,
            evaluations: evaluations, confirmedCarbDates: [],
            period: DateInterval(start: start, end: start.addingTimeInterval(90 * minute)))
        XCTAssertEqual(result.lowEpisodes, 1)
        XCTAssertEqual(result.evaluableEpisodes, 1)
        XCTAssertEqual(result.episodesWithPlannedWarning, 1)
        XCTAssertEqual(result.meanPlannedLeadMinutes, 15)
        XCTAssertEqual(result.plannedWarningFraction, 1)
        // The journal records a scheduling request, never observed delivery.
        XCTAssertEqual(result.evaluableDays, 0)
    }

    func testShortLowAndDataGapCannotBecomeSustainedEpisode() {
        let brief = (0...40).map { sample($0, (10...24).contains($0) ? 65 : 110) }
        let period = DateInterval(start: start, end: start.addingTimeInterval(40 * minute))
        XCTAssertEqual(LowSoonStatisticsCalculator.calculate(glucose: brief,
            evaluations: [], confirmedCarbDates: [], period: period).lowEpisodes, 0)

        let split = (0...40).filter { !(18...26).contains($0) }
            .map { sample($0, (10...34).contains($0) ? 65 : 110) }
        XCTAssertEqual(LowSoonStatisticsCalculator.calculate(glucose: split,
            evaluations: [], confirmedCarbDates: [], period: period).lowEpisodes, 0)
    }

    func testConflictingOrInvalidTimestampBreaksEpisodeAndCoverage() {
        var glucose = (0...40).map { sample($0, (10...30).contains($0) ? 65 : 110) }
        glucose.append(sample(20, 115))
        let period = DateInterval(start: start, end: start.addingTimeInterval(40 * minute))
        XCTAssertEqual(LowSoonStatisticsCalculator.calculate(glucose: glucose,
            evaluations: [], confirmedCarbDates: [], period: period).lowEpisodes, 0)
        glucose.removeLast()
        glucose.append(sample(20, .nan))
        XCTAssertEqual(LowSoonStatisticsCalculator.calculate(glucose: glucose,
            evaluations: [], confirmedCarbDates: [], period: period).lowEpisodes, 0)
    }

    func testWarningWithoutLowRequiresCompleteDayAndTracksCarbsAndNearLowSeparately() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayStart = calendar.startOfDay(for: start)
        let dateAt: (Int) -> Date = { dayStart.addingTimeInterval(Double($0) * 60) }
        let glucose = (0..<1440).map { index in
            LowSoonStatisticsGlucose(date: dateAt(index),
                mgdl: index == 76 ? 74 : 110, sensorID: "sensor-A")
        }
        let evaluations = (0..<1440).map { index in
            LowSoonStatisticsEvaluation(referenceDate: dateAt(index), computedAt: dateAt(index),
                status: index == 60 ? .warningRequested : .noWarning)
        }
        let result = LowSoonStatisticsCalculator.calculate(glucose: glucose,
            evaluations: evaluations, confirmedCarbDates: [dateAt(65)],
            period: DateInterval(start: dayStart, end: dateAt(1440)), calendar: calendar)
        XCTAssertEqual(result.evaluableDays, 1)
        XCTAssertEqual(result.plannedWarningsWithoutRecordedLow, 1)
        XCTAssertEqual(result.thoseWithRecordedCarbs, 1)
        XCTAssertEqual(result.thoseReachingBelow4Point4, 1)
        XCTAssertEqual(result.plannedWarningsWithoutLowPerEvaluableDay, 1)
    }

    func testMissingReadingsOrEvaluationsMakeFalseAlarmRateUnknown() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayStart = calendar.startOfDay(for: start)
        let dateAt: (Int) -> Date = { dayStart.addingTimeInterval(Double($0) * 60) }
        let glucose = (0..<1440).filter { !(500...510).contains($0) }.map { index in
            LowSoonStatisticsGlucose(date: dateAt(index), mgdl: 110, sensorID: "sensor-A")
        }
        let evaluations = (0..<1440).map { index in
            LowSoonStatisticsEvaluation(referenceDate: dateAt(index), computedAt: dateAt(index),
                status: index == 60 ? .warningRequested : .noWarning)
        }
        let period = DateInterval(start: dayStart, end: dateAt(1440))
        let missingGlucose = LowSoonStatisticsCalculator.calculate(glucose: glucose,
            evaluations: evaluations, confirmedCarbDates: [], period: period, calendar: calendar)
        XCTAssertEqual(missingGlucose.evaluableDays, 0)
        XCTAssertNil(missingGlucose.plannedWarningsWithoutLowPerEvaluableDay)
        XCTAssertEqual(missingGlucose.unevaluableWarnings, 1)

        let completeGlucose = (0..<1440).map { index in
            LowSoonStatisticsGlucose(date: dateAt(index), mgdl: 110, sensorID: "sensor-A")
        }
        let incompleteEvaluations = evaluations.filter {
            !(500...510).contains(Int($0.computedAt.timeIntervalSince(dayStart) / 60))
        }
        let missingEvaluation = LowSoonStatisticsCalculator.calculate(glucose: completeGlucose,
            evaluations: incompleteEvaluations, confirmedCarbDates: [], period: period, calendar: calendar)
        XCTAssertEqual(missingEvaluation.evaluableDays, 0)
        XCTAssertEqual(missingEvaluation.unevaluableWarnings, 1)
    }

    func testFailedSchedulingDoesNotCountAsPlannedWarning() {
        let glucose = (0...90).map { sample($0, (40...56).contains($0) ? 65 : 110) }
        let evaluations = (0...90).map { evaluation($0,
            $0 == 25 ? .warningSchedulingFailed : .noWarning) }
        let result = LowSoonStatisticsCalculator.calculate(glucose: glucose,
            evaluations: evaluations, confirmedCarbDates: [],
            period: DateInterval(start: start, end: start.addingTimeInterval(90 * minute)))
        XCTAssertEqual(result.lowEpisodes, 1)
        XCTAssertEqual(result.evaluableEpisodes, 1)
        XCTAssertEqual(result.episodesWithPlannedWarning, 0)
        XCTAssertEqual(result.plannedWarningFraction, 0)
    }

    func testFiveMinuteCadenceIsContinuousButSensorChangeEndsEpisode() {
        let fiveMinute = stride(from: 0, through: 50, by: 5).map {
            sample($0, (10...30).contains($0) ? 65 : 110)
        }
        let period = DateInterval(start: start, end: start.addingTimeInterval(50 * minute))
        XCTAssertEqual(LowSoonStatisticsCalculator.calculate(glucose: fiveMinute,
            evaluations: [], confirmedCarbDates: [], period: period).lowEpisodes, 1)

        let changedSensor = fiveMinute.map { point in
            LowSoonStatisticsGlucose(date: point.date, mgdl: point.mgdl,
                sensorID: point.date >= start.addingTimeInterval(20 * minute) ? "sensor-B" : "sensor-A")
        }
        XCTAssertEqual(LowSoonStatisticsCalculator.calculate(glucose: changedSensor,
            evaluations: [], confirmedCarbDates: [], period: period).lowEpisodes, 0)
    }

    func testDuplicateSchedulingRecordIsNotCountedTwice() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let dayStart = calendar.startOfDay(for: start)
        let dateAt: (Int) -> Date = { dayStart.addingTimeInterval(Double($0) * 60) }
        let glucose = (0..<1440).map { index in
            LowSoonStatisticsGlucose(date: dateAt(index), mgdl: 110, sensorID: "sensor-A")
        }
        var evaluations = (0..<1440).map { index in
            LowSoonStatisticsEvaluation(referenceDate: dateAt(index), computedAt: dateAt(index),
                status: index == 60 ? .warningRequested : .noWarning)
        }
        evaluations.append(.init(referenceDate: dateAt(60),
                                 computedAt: dateAt(60).addingTimeInterval(1),
                                 status: .warningRequested))
        let result = LowSoonStatisticsCalculator.calculate(glucose: glucose,
            evaluations: evaluations, confirmedCarbDates: [],
            period: DateInterval(start: dayStart, end: dateAt(1440)), calendar: calendar)
        XCTAssertEqual(result.evaluableDays, 1)
        XCTAssertEqual(result.plannedWarningsWithoutRecordedLow, 1)
    }

    func testDisabledOrSnoozedRuleIsUnknownCoverageRatherThanNoWarning() {
        for detail in ["disabled", "snoozed"] {
            let record = LowSoonEvaluationRecord(referenceDate: start, computedAt: start,
                currentMgdl: 90, predicted30Mgdl: 75, iobUnits: 1,
                sensorID: "sensor-A", status: .suppressed, detail: detail)
            XCTAssertEqual(LowSoonStatisticsEvaluation.fromJournal(record).status, .unavailable)
        }
        let cooldown = LowSoonEvaluationRecord(referenceDate: start, computedAt: start,
            currentMgdl: 90, predicted30Mgdl: 75, iobUnits: 1,
            sensorID: "sensor-A", status: .suppressed, detail: "thirtyMinuteLimit")
        XCTAssertEqual(LowSoonStatisticsEvaluation.fromJournal(cooldown).status, .suppressed)
    }
}
