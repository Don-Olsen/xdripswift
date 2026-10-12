//
//  SensorNoisePersistenceTests.swift
//  xdripTests
//
//  Created by Paul Plant on 2/8/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import CoreData
import XCTest
@testable import xdrip

/// Covers persistent-noise coverage, thresholds and flatline recovery.
final class SensorNoisePersistenceTests: XCTestCase {
    private let calculator = SensorNoiseCalculator()
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testPersistenceRequiresMinimumCoverage() {
        let assessment = calculator.calculatePersistence(readings: noisyReadings(hours: 8))

        XCTAssertNil(assessment.value)
    }

    func testPersistenceReportsHighMedianWithCompleteCoverage() throws {
        let assessment = calculator.calculatePersistence(readings: noisyReadings(hours: 12.5))

        XCTAssertGreaterThanOrEqual(assessment.coverage, 0.70)
        let median = try XCTUnwrap(assessment.value)
        XCTAssertGreaterThanOrEqual(
            ConstantsSensorNoise.state(for: median, sensitivity: .normal).rawValue,
            SensorNoiseState.veryHigh.rawValue
        )
    }

    func testLargeDataGapReducesCoverageBelowTrigger() {
        let readings = noisyReadings(hours: 12.5).filter { reading in
            let elapsed = reading.timeStamp.timeIntervalSince(start)
            return elapsed < .hours(3) || elapsed > .hours(8)
        }

        let assessment = calculator.calculatePersistence(readings: readings)

        XCTAssertLessThan(assessment.coverage, 0.70)
        XCTAssertNil(assessment.value)
    }

    func testPersistedEstimateHistoryRebuildsTwelveHourMedianAndCoverage() throws {
        let estimates = (0 ... 72).map { index in
            (
                timeStamp: start.addingTimeInterval(.minutes(Double(index * 10))),
                noise: index.isMultiple(of: 3) ? 9.0 : 8.0
            )
        }

        let assessment = calculator.calculatePersistence(
            estimates: estimates,
            endingAt: start.addingTimeInterval(.hours(12))
        )

        XCTAssertEqual(assessment.coverage, 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(assessment.value), 8, accuracy: 0.001)
    }

    func testPersistedEstimateHistoryAllowsNormalSchedulingDelays() throws {
        let estimates = (0 ... 48).map { index in
            (
                timeStamp: start.addingTimeInterval(.minutes(Double(index * 15))),
                noise: index.isMultiple(of: 3) ? 9.0 : 8.0
            )
        }

        let assessment = calculator.calculatePersistence(
            estimates: estimates,
            endingAt: start.addingTimeInterval(.hours(12))
        )

        XCTAssertEqual(assessment.coverage, 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(assessment.value), 8, accuracy: 0.001)
    }

    func testPersistedEstimateHistoryRejectsLargeDataGap() {
        let estimates = (0 ... 72).compactMap { index -> (timeStamp: Date, noise: Double)? in
            let elapsedMinutes = index * 10
            guard elapsedMinutes < 180 || elapsedMinutes > 480 else { return nil }

            return (
                timeStamp: start.addingTimeInterval(.minutes(Double(elapsedMinutes))),
                noise: 8.0
            )
        }

        let assessment = calculator.calculatePersistence(
            estimates: estimates,
            endingAt: start.addingTimeInterval(.hours(12))
        )

        XCTAssertLessThan(assessment.coverage, ConstantsSensorNoise.minimumPersistentNoiseCoverage)
        XCTAssertNil(assessment.value)
    }

    func testPersistedEstimateHistoryDoesNotCarryAnOldValueForward() {
        let estimates = (0 ... 72).map { index in
            (
                timeStamp: start.addingTimeInterval(.minutes(Double(index * 10))),
                noise: 8.0
            )
        }

        let assessment = calculator.calculatePersistence(
            estimates: estimates,
            endingAt: start.addingTimeInterval(.hours(16))
        )

        XCTAssertNil(assessment.value)
    }

    @MainActor
    func testStoredHistoryRollingWindowMatchesUnboundedHistoryAcrossFourteenDays() throws {
        let intervalCount = 14 * 24 * 6
        let points: [SensorNoiseHistoryPoint] = (0 ... intervalCount).map { index in
            historyPoint(minutes: Double(index * 10), noise: Double((index * 7) % 19) + 0.25)
        }

        let snapshot = try storedHistorySnapshot(points: points)
        XCTAssertEqual(snapshot.points, unboundedPersistence(points: points))
        XCTAssertEqual(snapshot.points.count, points.count)
        XCTAssertEqual(snapshot.persistentCoverage, 1, accuracy: 0.001)
        let lastPoint = try XCTUnwrap(snapshot.points.last)
        XCTAssertEqual(snapshot.persistentNoise, lastPoint.persistentNoise)
    }

    @MainActor
    func testStoredHistoryRollingWindowMatchesUnboundedHistoryWithGapsAndMissingNoise() throws {
        let points = (0 ... 72 * 6).compactMap { index -> SensorNoiseHistoryPoint? in
            let minute = index * 10
            // A genuine gap, then stored points whose short-term estimate is missing. The
            // latter must still advance the window and reduce coverage as old estimates expire.
            guard !(900 ... 1200).contains(minute) else { return nil }
            let noise = (2520 ... 3420).contains(minute) || index.isMultiple(of: 11)
                ? nil : Double((index * 3) % 13) + 1
            return historyPoint(minutes: Double(minute), noise: noise)
        }

        let snapshot = try storedHistorySnapshot(points: points)
        XCTAssertEqual(snapshot.points, unboundedPersistence(points: points))
        let endOfMissingNoise = try XCTUnwrap(snapshot.points.first {
            $0.timeStamp == start.addingTimeInterval(.minutes(3420))
        })
        XCTAssertNil(endOfMissingNoise.persistentNoise)
        XCTAssertEqual(endOfMissingNoise.persistentCoverage, 0)
        XCTAssertEqual(snapshot.points.count, points.count)
    }

    @MainActor
    func testStoredHistoryKeepsExactTwelveHourBoundaryThenExpiresItWithoutNewNoise() throws {
        var points = (0 ... 72).map { index in
            historyPoint(minutes: Double(index * 10), noise: index == 0 ? 1 : 9)
        }
        points.append(historyPoint(minutes: 720 + 1.0 / 60, noise: nil))
        points.append(historyPoint(minutes: 1440 + 1.0 / 60, noise: nil))

        let snapshot = try storedHistorySnapshot(points: points)
        XCTAssertEqual(snapshot.points, unboundedPersistence(points: points))
        XCTAssertEqual(snapshot.points[72].persistentCoverage, 1, accuracy: 0.000001)
        XCTAssertEqual(snapshot.points[72].persistentNoise, 9)
        XCTAssertEqual(snapshot.points[73].persistentCoverage, 71.0 / 72, accuracy: 0.000001)
        XCTAssertEqual(snapshot.points[73].persistentNoise, 9)
        XCTAssertEqual(snapshot.points[74].persistentCoverage, 0)
        XCTAssertNil(snapshot.points[74].persistentNoise)
    }

    func testSensitivityThresholdBoundaryForEveryLevel() {
        for sensitivity in SensorNoiseSensitivity.allCases {
            let boundary = ConstantsSensorNoise.threshold(
                ConstantsSensorNoise.veryHighNoiseStandardDeviation,
                sensitivity: sensitivity
            )

            XCTAssertEqual(ConstantsSensorNoise.state(for: boundary, sensitivity: sensitivity), .elevated)
            XCTAssertEqual(ConstantsSensorNoise.state(for: boundary.nextUp, sensitivity: sensitivity), .veryHigh)
        }
    }

    func testFlatlineRequiresCurrentSixReadingWindowAndRecoversWithMovement() {
        let flat = (0 ..< 6).map { index in
            SensorNoiseReading(
                timeStamp: start.addingTimeInterval(.minutes(Double(index * 5))),
                calculatedValue: 110,
                rawData: 110,
                calibrationID: nil
            )
        }
        XCTAssertEqual(calculator.calculate(readings: flat).state, .flatlineSuspected)

        let moving = flat + [
            SensorNoiseReading(
                timeStamp: start.addingTimeInterval(.minutes(30)),
                calculatedValue: 112,
                rawData: 112,
                calibrationID: nil
            )
        ]
        XCTAssertNotEqual(calculator.calculate(readings: moving).state, .flatlineSuspected)
    }

    private func historyPoint(minutes: Double, noise: Double?) -> SensorNoiseHistoryPoint {
        SensorNoiseHistoryPoint(
            id: "noise-history-\(minutes)",
            timeStamp: start.addingTimeInterval(.minutes(minutes)),
            shortTermNoise: noise,
            longTermNoise: 4,
            persistentNoise: nil,
            persistentCoverage: 0,
            state: noise == nil ? .collecting : .low
        )
    }

    /// The previous manager implementation retained all prior estimates; the unchanged
    /// calculator alone restricted each assessment to its inclusive twelve-hour window.
    private func unboundedPersistence(points: [SensorNoiseHistoryPoint]) -> [SensorNoiseHistoryPoint] {
        var estimates = [(timeStamp: Date, noise: Double)]()
        return points.map { point in
            if let noise = point.shortTermNoise { estimates.append((point.timeStamp, noise)) }
            let assessment = calculator.calculatePersistence(estimates: estimates, endingAt: point.timeStamp)
            return SensorNoiseHistoryPoint(
                id: point.id,
                timeStamp: point.timeStamp,
                shortTermNoise: point.shortTermNoise,
                longTermNoise: point.longTermNoise,
                persistentNoise: assessment.value,
                persistentCoverage: assessment.coverage,
                state: point.state
            )
        }
    }

    @MainActor
    private func storedHistorySnapshot(points: [SensorNoiseHistoryPoint]) throws -> SensorNoiseHistorySnapshot {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = core.mainManagedObjectContext
        let sensor = Sensor(startDate: start, nsManagedObjectContext: context)
        // Reverse insertion order proves historySnapshot supplies chronological points to the
        // real rolling-window path rather than relying on insertion order or a test helper.
        for point in points.reversed() {
            let sample = SensorNoiseSample(
                timeStamp: point.timeStamp,
                measurement: SensorNoiseMeasurement(
                    shortTermNoise: point.shortTermNoise,
                    longTermNoise: point.longTermNoise,
                    shortTermCoverage: 0,
                    longTermCoverage: 0,
                    state: point.state,
                    latestReadingAt: point.timeStamp
                ),
                sensor: sensor,
                nsManagedObjectContext: context
            )
            sample.id = point.id
        }
        try context.save()
        let suite = "SensorNoisePersistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = SensorNoiseManager(
            coreDataManager: core,
            bgReadingsAccessor: BgReadingsAccessor(coreDataManager: core),
            sensorHealthIssueManager: SensorHealthIssueManager(userDefaults: defaults)
        )
        return try XCTUnwrap(manager.historySnapshot(sensorID: sensor.id, sessionStartDate: start))
    }

    private func noisyReadings(hours: Double) -> [SensorNoiseReading] {
        let count = Int(hours * 12) + 1
        return (0 ..< count).map { index in
            let value = index.isMultiple(of: 2) ? 80.0 : 180.0
            return SensorNoiseReading(
                timeStamp: start.addingTimeInterval(.minutes(Double(index * 5))),
                calculatedValue: value,
                rawData: value,
                calibrationID: nil
            )
        }
    }
}
