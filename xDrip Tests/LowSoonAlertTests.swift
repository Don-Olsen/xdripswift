import XCTest
@testable import xdrip

final class LowSoonAlertTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testThresholdsAreStrictAndRequireCurrentNotAlreadyLow() {
        XCTAssertTrue(LowSoonAlertPolicy.condition(currentMgdl: LowSoonAlertPolicy.currentMinimumMgdl,
                                                   predicted30Mgdl: LowSoonAlertPolicy.predictedLimitMgdl - 0.01))
        XCTAssertFalse(LowSoonAlertPolicy.condition(currentMgdl: LowSoonAlertPolicy.currentMinimumMgdl - 0.01,
                                                    predicted30Mgdl: 4.0 / ConstantsBloodGlucose.mgDlToMmoll))
        XCTAssertFalse(LowSoonAlertPolicy.condition(currentMgdl: 6.0 / ConstantsBloodGlucose.mgDlToMmoll,
                                                    predicted30Mgdl: LowSoonAlertPolicy.predictedLimitMgdl))
        XCTAssertFalse(LowSoonAlertPolicy.condition(currentMgdl: .nan, predicted30Mgdl: 60))
        XCTAssertFalse(LowSoonAlertPolicy.condition(currentMgdl: 90, predicted30Mgdl: .infinity))
    }

    func testThirtyMinuteLimitSurvivesRestartAndClockRollback() {
        XCTAssertTrue(LowSoonAlertPolicy.maySchedule(lastScheduled: nil, at: now))
        XCTAssertFalse(LowSoonAlertPolicy.maySchedule(lastScheduled: now, at: now.addingTimeInterval(1799)))
        XCTAssertTrue(LowSoonAlertPolicy.maySchedule(lastScheduled: now, at: now.addingTimeInterval(1800)))
        XCTAssertFalse(LowSoonAlertPolicy.maySchedule(lastScheduled: now, at: now.addingTimeInterval(-60)))

        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(now, forKey: LowSoonAlertState.lastScheduledDefaultsKey)
        XCTAssertTrue(LowSoonAlertState.isActive(at: now.addingTimeInterval(1799), defaults: defaults))
        XCTAssertFalse(LowSoonAlertState.isActive(at: now.addingTimeInterval(1800), defaults: defaults))
        XCTAssertFalse(LowSoonAlertState.isActive(at: now.addingTimeInterval(-1), defaults: defaults))
    }

    func testDelayedOrIncompleteForecastCannotProduceAnAlertInput() {
        func outcome(reference: Date, sensor: String? = "sensor-A", point: Double? = 70,
                     reason: GlucoseForecastUnavailableReason? = nil,
                     iob: Double? = 1.5) -> GlucoseForecastSafetyOutcome {
            let points = point.map {
                [GlucoseForecastPoint(date: reference.addingTimeInterval(30 * 60), glucoseMgdl: $0)]
            } ?? []
            return GlucoseForecastSafetyOutcome(
                result: GlucoseForecastResult(points: points, referenceDate: reference,
                    reason: reason, referenceSensorID: sensor),
                referenceGlucoseMgdl: 95, activeInsulinUnits: iob,
                slope15MgdlPerMinute: -0.1)
        }
        let valid = outcome(reference: now)
        XCTAssertEqual(LowSoonAlertPolicy.validatedPrediction(from: valid,
            expectedReferenceDate: now, expectedSensorID: "sensor-A",
            expectedGlucoseMgdl: 95,
            at: now.addingTimeInterval(330))?.predicted30Mgdl, 70)
        XCTAssertNil(LowSoonAlertPolicy.validatedPrediction(from: valid,
            expectedReferenceDate: now, expectedSensorID: "sensor-A",
            expectedGlucoseMgdl: 95,
            at: now.addingTimeInterval(331)))
        XCTAssertNil(LowSoonAlertPolicy.validatedPrediction(from: valid,
            expectedReferenceDate: now, expectedSensorID: "sensor-A",
            expectedGlucoseMgdl: 95,
            at: now.addingTimeInterval(-1)))
        XCTAssertNil(LowSoonAlertPolicy.validatedPrediction(from: valid,
            expectedReferenceDate: now, expectedSensorID: "sensor-B",
            expectedGlucoseMgdl: 95, at: now))
        XCTAssertNil(LowSoonAlertPolicy.validatedPrediction(from: valid,
            expectedReferenceDate: now, expectedSensorID: "sensor-A",
            expectedGlucoseMgdl: 96, at: now))
        XCTAssertNil(LowSoonAlertPolicy.validatedPrediction(from: valid,
            expectedReferenceDate: now.addingTimeInterval(60), expectedSensorID: "sensor-A",
            expectedGlucoseMgdl: 95, at: now))
        XCTAssertNil(LowSoonAlertPolicy.validatedPrediction(from: outcome(reference: now, point: nil),
            expectedReferenceDate: now, expectedSensorID: "sensor-A",
            expectedGlucoseMgdl: 95, at: now))
        XCTAssertNil(LowSoonAlertPolicy.validatedPrediction(from: outcome(reference: now, reason: .dataUnavailable),
            expectedReferenceDate: now, expectedSensorID: "sensor-A",
            expectedGlucoseMgdl: 95, at: now))
        XCTAssertNil(LowSoonAlertPolicy.validatedPrediction(from: outcome(reference: now, iob: nil),
            expectedReferenceDate: now, expectedSensorID: "sensor-A",
            expectedGlucoseMgdl: 95, at: now))
    }

    func testPersistedAlertKindAndIndependentNotificationOwnership() {
        XCTAssertEqual(AlertKind.lowSoon.rawValue, 14)
        XCTAssertFalse(AlertKind.lowSoon.defaultIsDisabled())
        XCTAssertFalse(AlertKind.lowSoon.needsAlertValue())
        XCTAssertFalse(AlertKind.lowSoon.supportsAlertSchedules())
        XCTAssertTrue(AlertKind.visibleAlertKinds(for: nil).contains(.lowSoon))
        XCTAssertFalse(AlertManager.ownedPendingNotificationIdentifiers.contains(AlertKind.lowSoon.notificationIdentifier()))
        XCTAssertTrue(AlertManager.ownedPendingNotificationIdentifiers.contains(AlertKind.low.notificationIdentifier()))
    }

    func testJournalPreservesTypedEvidenceAndIncompleteLastLine() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = LowSoonEvaluationJournal(directory: folder)
        let good = LowSoonEvaluationRecord(referenceDate: now, computedAt: now.addingTimeInterval(20),
            currentMgdl: 100, predicted30Mgdl: 72, iobUnits: 2.5, sensorID: "sensor-A",
            status: .warningRequested, detail: nil)
        journal.enqueue(good)
        let firstRead = await journal.records(from: now, to: now.addingTimeInterval(60))
        XCTAssertEqual(firstRead.map(\.status), [.warningRequested])
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: nil).first)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"truncated\":".utf8))
        try handle.close()
        let loaded = await journal.records(from: now, to: now.addingTimeInterval(60))
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.referenceDate, now)
        XCTAssertEqual(loaded.first?.iobUnits, 2.5)
        XCTAssertEqual(loaded.first?.sensorID, "sensor-A")
        journal.enqueue(.init(referenceDate: now.addingTimeInterval(40),
                              computedAt: now.addingTimeInterval(40), currentMgdl: 100,
                              predicted30Mgdl: 75, iobUnits: 2.0, sensorID: "sensor-A",
                              status: .noWarning, detail: nil))
        let recovered = await journal.records(from: now, to: now.addingTimeInterval(60))
        XCTAssertEqual(recovered.map(\.status), [.warningRequested, .noWarning])
    }

    func testJournalPrunesOnlyOldKnownDailyFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = LowSoonEvaluationJournal(directory: folder)
        let old = now.addingTimeInterval(-40 * 24 * 60 * 60)
        journal.enqueue(.init(referenceDate: old, computedAt: old, currentMgdl: nil,
                              predicted30Mgdl: nil, iobUnits: nil, sensorID: nil,
                              status: .unavailable, detail: "missingGlucose"))
        _ = await journal.records(from: old.addingTimeInterval(-1), to: now)
        let unrelated = folder.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: unrelated)
        journal.enqueue(.init(referenceDate: now, computedAt: now, currentMgdl: 120,
                              predicted30Mgdl: 110, iobUnits: 0, sensorID: "A",
                              status: .noWarning, detail: nil))
        let recent = await journal.records(from: old, to: now)
        XCTAssertEqual(recent.map(\.status), [.noWarning])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
