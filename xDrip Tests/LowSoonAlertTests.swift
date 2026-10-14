import XCTest
import UserNotifications
@testable import xdrip

final class LowSoonAlertTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func points(_ values: [Double] = [95, 90, 85, 75, 80, 85, 90],
                        reference: Date? = nil) -> [GlucoseForecastPoint] {
        stride(from: 0, through: 60, by: 5).map { minute in
            GlucoseForecastPoint(date: (reference ?? now).addingTimeInterval(Double(minute) * 60),
                glucoseMgdl: values[min(minute / 5, values.count - 1)])
        }
    }

    private func outcome(points: [GlucoseForecastPoint]? = nil, reference: Date? = nil,
                         sensor: String? = "sensor-A", current: Double? = 95,
                         reason: GlucoseForecastUnavailableReason? = nil,
                         iob: Double? = 1.5) -> GlucoseForecastSafetyOutcome {
        GlucoseForecastSafetyOutcome(
            result: GlucoseForecastResult(points: points ?? self.points(reference: reference),
                referenceDate: reference ?? now, reason: reason, referenceSensorID: sensor),
            referenceGlucoseMgdl: current, activeInsulinUnits: iob, slope15MgdlPerMinute: -0.1)
    }

    private func validated(_ outcome: GlucoseForecastSafetyOutcome,
                           reference: Date? = nil, at date: Date? = nil,
                           expectedCurrent: Double = 95) -> LowSoonAlertPolicy.ValidatedPrediction? {
        LowSoonAlertPolicy.validatedPrediction(from: outcome,
            expectedReferenceDate: reference ?? now, expectedSensorID: "sensor-A",
            expectedGlucoseMgdl: expectedCurrent, at: date ?? now)
    }

    func testThresholdsAreStrictAndRequireCurrentNotAlreadyLow() {
        let currentLimit = LowSoonAlertPolicy.currentMinimumMgdl
        let predictedLimit = LowSoonAlertPolicy.predictedLimitMgdl
        XCTAssertTrue(LowSoonAlertPolicy.condition(currentMgdl: currentLimit,
                                                   minimumMgdl: predictedLimit.nextDown))
        XCTAssertFalse(LowSoonAlertPolicy.condition(currentMgdl: currentLimit.nextDown,
                                                    minimumMgdl: 4.0 / ConstantsBloodGlucose.mgDlToMmoll))
        XCTAssertFalse(LowSoonAlertPolicy.condition(currentMgdl: 6.0 / ConstantsBloodGlucose.mgDlToMmoll,
                                                    minimumMgdl: predictedLimit))
        XCTAssertFalse(LowSoonAlertPolicy.condition(currentMgdl: .nan, minimumMgdl: 60))
        XCTAssertFalse(LowSoonAlertPolicy.condition(currentMgdl: 90, minimumMgdl: .infinity))
    }

    func testRealEngineDipAndRecoveryWarnsWithoutChangingItsForecast() throws {
        // Measured downward momentum briefly crosses the warning margin before the
        // already recorded fast meal's modeled effect lifts the +30-minute endpoint.
        let samples = stride(from: -30, through: 0, by: 5).map { minute in
            GlucoseForecastSample(date: now.addingTimeInterval(Double(minute) * 60),
                glucoseMgdl: 100 - Double(minute) * 5, sensorID: "sensor-A")
        }
        let treatments = [TherapyTreatment(date: now, amount: 1, isIOB: true),
            TherapyTreatment(date: now, amount: 20, isIOB: false,
                carbohydrateDurationMinutes: TreatmentMealKind.fast.durationMinutes)]
        let input = GlucoseForecastInput(glucose: samples, treatments: treatments,
            settings: TherapyModelSettings(), sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, horizonMinutes: 60, now: now)
        let forecast = GlucoseForecastEngine.predict(input)
        XCTAssertNil(forecast.reason)
        let safety = outcome(points: forecast.points, current: 100, iob: 1)
        let prediction = try XCTUnwrap(validated(safety, expectedCurrent: 100))
        XCTAssertEqual(prediction.currentMgdl, 100)
        XCTAssertEqual(prediction.activeInsulinUnits, 1)
        XCTAssertEqual(prediction.minimumDate, now.addingTimeInterval(10 * 60))
        XCTAssertLessThan(prediction.minimumMgdl, LowSoonAlertPolicy.predictedLimitMgdl)
        XCTAssertGreaterThan(prediction.predicted30Mgdl, LowSoonAlertPolicy.predictedLimitMgdl)
        XCTAssertTrue(LowSoonAlertPolicy.condition(currentMgdl: prediction.currentMgdl,
                                                   minimumMgdl: prediction.minimumMgdl))
        XCTAssertFalse(LowSoonAlertPolicy.condition(currentMgdl: prediction.currentMgdl,
                                                    minimumMgdl: prediction.predicted30Mgdl),
            "the former endpoint-only decision misses this engine-produced dip")
        XCTAssertEqual(safety.result.points, forecast.points)
        XCTAssertEqual(GlucoseForecastEngine.predict(input).points, forecast.points)
    }

    func testPastDipIsExcludedAndNowBoundaryIsInterpolated() throws {
        let reference = now.addingTimeInterval(-330)
        let forecast = points([95, 75, 125], reference: reference)
        let prediction = try XCTUnwrap(validated(outcome(points: forecast, reference: reference),
            reference: reference))
        XCTAssertEqual(prediction.minimumMgdl, 80, accuracy: 1e-9)
        XCTAssertEqual(prediction.minimumDate, now)
        XCTAssertFalse(LowSoonAlertPolicy.condition(currentMgdl: prediction.currentMgdl,
                                                    minimumMgdl: prediction.minimumMgdl))
        XCTAssertEqual(prediction.windowStart, now)
        XCTAssertEqual(prediction.windowEnd, now.addingTimeInterval(30 * 60))
    }

    func testInterpolatedLowAtNowAndExactNowPointAreIncluded() throws {
        let reference = now.addingTimeInterval(-330)
        let forecast = points([95, 70, 120], reference: reference)
        let interpolated = try XCTUnwrap(validated(outcome(points: forecast, reference: reference),
            reference: reference))
        XCTAssertEqual(interpolated.minimumMgdl, 75, accuracy: 1e-9)
        XCTAssertEqual(interpolated.minimumDate, now)
        XCTAssertTrue(LowSoonAlertPolicy.condition(currentMgdl: interpolated.currentMgdl,
                                                   minimumMgdl: interpolated.minimumMgdl))
        let exactNow = reference.addingTimeInterval(300)
        let exact = try XCTUnwrap(validated(outcome(points: forecast, reference: reference),
            reference: reference, at: exactNow))
        XCTAssertEqual(exact.minimumMgdl, 70)
        XCTAssertEqual(exact.minimumDate, exactNow)
    }

    func testThirtyMinuteEndpointIsIncluded() throws {
        let prediction = try XCTUnwrap(validated(outcome(points: points([95, 95, 95, 95, 95, 95, 70]))))
        XCTAssertEqual(prediction.minimumMgdl, 70)
        XCTAssertEqual(prediction.minimumDate, now.addingTimeInterval(30 * 60))
        XCTAssertEqual(prediction.predicted30Mgdl, 70)
        XCTAssertTrue(LowSoonAlertPolicy.condition(currentMgdl: prediction.currentMgdl,
                                                   minimumMgdl: prediction.minimumMgdl))
    }

    func testAgedAnchorUsesThirtyMinutesFromNowAndRetainsReferenceThirtyValue() throws {
        let reference = now.addingTimeInterval(-330)
        let forecast = points([95, 95, 95, 95, 95, 95, 95, 80, 20], reference: reference)
        let prediction = try XCTUnwrap(validated(outcome(points: forecast, reference: reference),
            reference: reference))
        // now+30 is reference+35.5: interpolate 10% from 80 toward 20. The
        // lower points after that boundary must not influence this decision.
        XCTAssertEqual(prediction.minimumMgdl, 74, accuracy: 1e-9)
        XCTAssertEqual(prediction.minimumDate, now.addingTimeInterval(30 * 60))
        XCTAssertEqual(prediction.predicted30Mgdl, 95)
        XCTAssertTrue(LowSoonAlertPolicy.condition(currentMgdl: prediction.currentMgdl,
                                                   minimumMgdl: prediction.minimumMgdl))
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
        let valid = outcome()
        XCTAssertNotNil(validated(valid, at: now.addingTimeInterval(330)))
        XCTAssertNil(validated(valid, at: now.addingTimeInterval(330.01)))
        XCTAssertNil(validated(valid, at: now.addingTimeInterval(-1)))
        XCTAssertNil(validated(outcome(sensor: "sensor-B")))
        XCTAssertNil(validated(valid, expectedCurrent: 96))
        XCTAssertNil(validated(valid, reference: now.addingTimeInterval(60)))
        XCTAssertNil(validated(outcome(reason: .dataUnavailable)))
        XCTAssertNil(validated(outcome(points: [])))
        XCTAssertNil(validated(outcome(points: [GlucoseForecastPoint(
            date: now.addingTimeInterval(30 * 60), glucoseMgdl: 70)])))
    }

    func testMalformedGridCannotBeSortedFilledOrPartiallyAccepted() {
        let complete = points()
        var missing = complete
        missing.remove(at: 2)
        var duplicate = complete
        duplicate.insert(complete[2], at: 2)
        var unordered = complete
        unordered.swapAt(2, 3)
        var offGrid = complete
        offGrid[2] = .init(date: complete[2].date.addingTimeInterval(1), glucoseMgdl: 85)
        var wrongAnchorDate = complete
        wrongAnchorDate[0] = .init(date: now.addingTimeInterval(-300), glucoseMgdl: 95)
        var wrongAnchorValue = complete
        wrongAnchorValue[0] = .init(date: now, glucoseMgdl: 94)
        for grid in [missing, duplicate, unordered, offGrid, wrongAnchorDate,
                     wrongAnchorValue, Array(complete.prefix(6))] {
            XCTAssertNil(validated(outcome(points: grid)))
        }
        // A 30-minute grid from the reading is insufficient when consumed 330 seconds later.
        XCTAssertNil(validated(outcome(points: Array(complete.prefix(7))), at: now.addingTimeInterval(330)))
    }

    func testEntireGridRequiresFiniteInRangeValuesAndFiniteDates() {
        for invalid in [Double.nan, .infinity, -.infinity, 19, 601] {
            for index in [3, 12] {
                var grid = points()
                grid[index] = .init(date: grid[index].date, glucoseMgdl: invalid)
                XCTAssertNil(validated(outcome(points: grid)), "Invalid glucose at point \(index)")
            }
        }
        for invalid in [Double.nan, .infinity, -.infinity] {
            for index in [3, 12] {
                var grid = points()
                grid[index] = .init(date: Date(timeIntervalSinceReferenceDate: invalid), glucoseMgdl: 90)
                XCTAssertNil(validated(outcome(points: grid)), "Invalid date at point \(index)")
            }
            let date = Date(timeIntervalSinceReferenceDate: invalid)
            XCTAssertNil(validated(outcome(), at: date))
            XCTAssertNil(validated(outcome(), reference: date))
        }
        for valid in [20.0, 600] {
            XCTAssertNotNil(validated(outcome(points: points([95, valid]))))
        }
    }

    func testUnknownOrInvalidMeasuredGlucoseAndInsulinAreUnavailable() {
        for current: Double? in [nil, .nan, .infinity, -.infinity, 0, 19, 601] {
            XCTAssertNil(validated(outcome(current: current), expectedCurrent: current ?? 95))
        }
        for iob: Double? in [nil, .nan, .infinity, -.infinity, -0.01] {
            XCTAssertNil(validated(outcome(iob: iob)))
        }
        XCTAssertNotNil(validated(outcome(iob: 0)))
        XCTAssertNil(validated(outcome(), expectedCurrent: .nan))
        XCTAssertNil(validated(outcome(), expectedCurrent: .infinity))
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

    func testNotificationBodyUsesMinimumAndTimeFromActualNowInBothUnits() throws {
        let prediction = try XCTUnwrap(validated(outcome(points: points([95, 90, 72, 95])),
            at: now.addingTimeInterval(31)))
        let mgdl = AlertManager.lowSoonNotificationBody(prediction, usesMgDl: true)
        let mmol = AlertManager.lowSoonNotificationBody(prediction, usesMgDl: false)
        XCTAssertTrue(mgdl.contains("Forventet lavpunkt: ca. 72 mg/dL om 10 min"))
        XCTAssertTrue(mmol.contains("Forventet lavpunkt: ca. 4.0 mmol/L om 10 min"))
        let insulin = String(format: "%.1f", locale: Locale.current, 1.5)
        XCTAssertTrue(mgdl.contains("aktiv insulin \(insulin) E"))
        XCTAssertTrue(mmol.contains("aktiv insulin \(insulin) E"))
        XCTAssertFalse(mgdl.contains("om 30 min"))
        XCTAssertFalse(mgdl.contains("95 mg/dL"))
    }

    func testNotificationBodyDistinguishesMinimumNowAndAtWindowEnd() throws {
        let reference = now.addingTimeInterval(-330)
        let immediate = try XCTUnwrap(validated(outcome(
            points: points([95, 70, 120], reference: reference), reference: reference),
            reference: reference))
        XCTAssertTrue(AlertManager.lowSoonNotificationBody(immediate, usesMgDl: true)
            .contains("75 mg/dL nu"))
        let endpoint = try XCTUnwrap(validated(outcome(points: points([95, 95, 95, 95, 95, 95, 70]))))
        XCTAssertTrue(AlertManager.lowSoonNotificationBody(endpoint, usesMgDl: true)
            .contains("70 mg/dL om 30 min"))
    }

    func testDedicatedNotificationCategoriesPreserveOptionalSnoozeAndDismissal() throws {
        let plain = AlertManager.lowSoonNotificationCategory(snoozeAction: nil)
        XCTAssertEqual(plain.identifier, "lowSoonCalculatorDismiss")
        XCTAssertEqual(plain.actions.map(\.identifier), [AlertManager.lowSoonCalculatorActionIdentifier])
        let open = try XCTUnwrap(plain.actions.first)
        XCTAssertEqual(open.title, "Åbn beregner")
        XCTAssertEqual(open.options, [.foreground])
        XCTAssertTrue(plain.options.contains(.customDismissAction))
        let snooze = UNNotificationAction(identifier: "snoozeActionIdentifier", title: "Snooze",
            options: [.authenticationRequired])
        let withSnooze = AlertManager.lowSoonNotificationCategory(snoozeAction: snooze)
        XCTAssertEqual(withSnooze.identifier, "lowSoonCalculatorSnooze")
        XCTAssertNotEqual(withSnooze.identifier, plain.identifier)
        XCTAssertEqual(withSnooze.actions.map(\.identifier),
            [AlertManager.lowSoonCalculatorActionIdentifier, snooze.identifier])
        XCTAssertEqual(withSnooze.actions[0].options, [.foreground])
        XCTAssertEqual(withSnooze.actions[1].title, snooze.title)
        XCTAssertEqual(withSnooze.actions[1].options, snooze.options)
        XCTAssertTrue(withSnooze.options.contains(.customDismissAction))
    }

    func testOnlyExactLowSoonCalculatorActionOpensCalculator() {
        let notification = AlertKind.lowSoon.notificationIdentifier()
        let action = AlertManager.lowSoonCalculatorActionIdentifier
        XCTAssertTrue(AlertManager.opensLowSoonCalculator(notificationIdentifier: notification,
                                                           actionIdentifier: action))
        for other in [UNNotificationDefaultActionIdentifier, UNNotificationDismissActionIdentifier,
                      "snoozeActionIdentifier", action + ".other", ""] {
            XCTAssertFalse(AlertManager.opensLowSoonCalculator(notificationIdentifier: notification,
                                                                actionIdentifier: other))
        }
        for other in [AlertKind.low.notificationIdentifier(), notification + ".other", ""] {
            XCTAssertFalse(AlertManager.opensLowSoonCalculator(notificationIdentifier: other,
                                                                actionIdentifier: action))
        }
    }

    func testJournalPreservesTypedEvidenceAndIncompleteLastLine() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = LowSoonEvaluationJournal(directory: folder)
        let good = LowSoonEvaluationRecord(referenceDate: now, computedAt: now.addingTimeInterval(20),
            currentMgdl: 100, predicted30Mgdl: 72, iobUnits: 2.5, sensorID: "sensor-A",
            status: .warningRequested, detail: nil, policyVersion: LowSoonAlertPolicy.version,
            windowStart: now.addingTimeInterval(20), windowEnd: now.addingTimeInterval(1820),
            minimumMgdl: 65, minimumDate: now.addingTimeInterval(600))
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
        XCTAssertEqual(loaded.first?.predicted30Mgdl, 72)
        XCTAssertEqual(loaded.first?.policyVersion, LowSoonAlertPolicy.version)
        XCTAssertEqual(loaded.first?.windowStart, now.addingTimeInterval(20))
        XCTAssertEqual(loaded.first?.windowEnd, now.addingTimeInterval(1820))
        XCTAssertEqual(loaded.first?.minimumMgdl, 65)
        XCTAssertEqual(loaded.first?.minimumDate, now.addingTimeInterval(600))
        journal.enqueue(.init(referenceDate: now.addingTimeInterval(40),
                              computedAt: now.addingTimeInterval(40), currentMgdl: 100,
                              predicted30Mgdl: 75, iobUnits: 2.0, sensorID: "sensor-A",
                              status: .noWarning, detail: nil))
        let recovered = await journal.records(from: now, to: now.addingTimeInterval(60))
        XCTAssertEqual(recovered.map(\.status), [.warningRequested, .noWarning])
    }

    func testLegacyJournalJSONDecodesWithoutInventingNewPolicyEvidence() throws {
        let json = """
        {"referenceDate":123,"computedAt":143,"currentMgdl":100,"predicted30Mgdl":72,
         "iobUnits":2.5,"sensorID":"sensor-A","status":"warningRequested"}
        """
        let record = try JSONDecoder().decode(LowSoonEvaluationRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.referenceDate, Date(timeIntervalSinceReferenceDate: 123))
        XCTAssertEqual(record.computedAt, Date(timeIntervalSinceReferenceDate: 143))
        XCTAssertEqual(record.status, .warningRequested)
        XCTAssertEqual(record.predicted30Mgdl, 72)
        XCTAssertNil(record.policyVersion)
        XCTAssertNil(record.windowStart)
        XCTAssertNil(record.windowEnd)
        XCTAssertNil(record.minimumMgdl)
        XCTAssertNil(record.minimumDate)
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
