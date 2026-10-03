import XCTest
@testable import xdrip

final class GlucoseForecastMLTrainerTests: XCTestCase {
    private let utc = Calendar(identifier: .gregorian)

    func testTrainingSessionsAreProtectedAndStaleCleanupPreservesActiveAndUnknownData() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                      isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let store = GlucoseForecastMLModelStore(directory: root)
        let active = try store.prepareTrainingSession()
        let sessionsRoot = root.appendingPathComponent("training-sessions", isDirectory: true)
        let job = active.appendingPathComponent("correction_30", isDirectory: true)
        try GlucoseForecastMLStoragePolicy.secureDirectory(job)
        for directory in [sessionsRoot, active, job] {
            XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup, true)
            #if os(iOS) && !targetEnvironment(simulator)
            let protection = try files.attributesOfItem(atPath: directory.path)[.protectionKey]
            XCTAssertEqual(protection as? FileProtectionType,
                           .completeUntilFirstUserAuthentication)
            #endif
        }
        let stale = sessionsRoot.appendingPathComponent(UUID().uuidString.lowercased(),
                                                        isDirectory: true)
        let unrelated = sessionsRoot.appendingPathComponent("keep-unrelated", isDirectory: true)
        try files.createDirectory(at: stale, withIntermediateDirectories: false)
        try files.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try store.cleanupStaleTrainingSessions()
        XCTAssertTrue(files.fileExists(atPath: active.path))
        XCTAssertFalse(files.fileExists(atPath: stale.path))
        XCTAssertTrue(files.fileExists(atPath: unrelated.path))

        store.finishTrainingSession(active)
        XCTAssertFalse(files.fileExists(atPath: active.path))
        let interrupted = sessionsRoot.appendingPathComponent(UUID().uuidString.lowercased(),
                                                              isDirectory: true)
        try files.createDirectory(at: interrupted, withIntermediateDirectories: false)
        try GlucoseForecastMLModelStore(directory: root).cleanupStaleTrainingSessions()
        XCTAssertFalse(files.fileExists(atPath: interrupted.path))
        XCTAssertTrue(files.fileExists(atPath: unrelated.path))
    }

    func testModelRetentionKeepsActiveLatestVerifiedPreviousAndUnknownDirectories() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                      isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let models = root.appendingPathComponent("models", isDirectory: true)
        try files.createDirectory(at: models, withIntermediateDirectories: true)
        let activeID = UUID().uuidString.lowercased()
        let previousID = UUID().uuidString.lowercased()
        let oldID = UUID().uuidString.lowercased()
        let unknownID = UUID().uuidString.lowercased()
        let stagingID = UUID().uuidString.lowercased()
        for name in [activeID, previousID, oldID, unknownID, stagingID + ".staging"] {
            try files.createDirectory(at: models.appendingPathComponent(name, isDirectory: true),
                                      withIntermediateDirectories: false)
        }
        try Data("{\"modelID\":\"\(activeID)\"}".utf8)
            .write(to: root.appendingPathComponent("active.json"))
        let store = GlucoseForecastMLModelStore(directory: root)
        let dates = [oldID: Date(timeIntervalSince1970: 100),
                     previousID: Date(timeIntervalSince1970: 200)]
        try await store.pruneModelDirectories(activeModelID: activeID) {
            dates[$0.lastPathComponent]
        }
        XCTAssertTrue(files.fileExists(atPath: models.appendingPathComponent(activeID).path))
        XCTAssertTrue(files.fileExists(atPath: models.appendingPathComponent(previousID).path))
        XCTAssertFalse(files.fileExists(atPath: models.appendingPathComponent(oldID).path))
        XCTAssertTrue(files.fileExists(atPath: models.appendingPathComponent(unknownID).path))
        try store.cleanupAbandonedStaging(activeModelID: activeID)
        XCTAssertFalse(files.fileExists(atPath: models.appendingPathComponent(stagingID + ".staging").path))

        // Pointer uncertainty is a hard stop even if a verifier reports a package.
        try Data("{\"modelID\":\"unreadable\"}".utf8)
            .write(to: root.appendingPathComponent("active.json"), options: .atomic)
        try await store.pruneModelDirectories(activeModelID: activeID) { _ in .distantPast }
        XCTAssertTrue(files.fileExists(atPath: models.appendingPathComponent(previousID).path))
        XCTAssertTrue(files.fileExists(atPath: models.appendingPathComponent(unknownID).path))
    }

    func testInstallRetentionKeepsExactFormerActiveModelInsteadOfNewerOrphan() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                      isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let models = root.appendingPathComponent("models", isDirectory: true)
        try files.createDirectory(at: models, withIntermediateDirectories: true)
        let activeID = UUID().uuidString.lowercased()
        let formerActiveID = UUID().uuidString.lowercased()
        let newerOrphanID = UUID().uuidString.lowercased()
        for id in [activeID, formerActiveID, newerOrphanID] {
            try files.createDirectory(at: models.appendingPathComponent(id, isDirectory: true),
                                      withIntermediateDirectories: false)
        }
        try Data("{\"modelID\":\"\(activeID)\"}".utf8)
            .write(to: root.appendingPathComponent("active.json"))
        let dates = [formerActiveID: Date(timeIntervalSince1970: 100),
                     newerOrphanID: Date(timeIntervalSince1970: 200)]
        try await GlucoseForecastMLModelStore(directory: root).pruneModelDirectories(
            activeModelID: activeID, protectedPreviousModelID: formerActiveID) {
                dates[$0.lastPathComponent]
            }
        XCTAssertTrue(files.fileExists(atPath: models.appendingPathComponent(activeID).path))
        XCTAssertTrue(files.fileExists(atPath: models.appendingPathComponent(formerActiveID).path))
        XCTAssertFalse(files.fileExists(atPath: models.appendingPathComponent(newerOrphanID).path))
    }

    private func examples(days: Int = 60, anchorsPerDay: Int = 10) -> [GlucoseForecastMLReplayExample] {
        var calendar = utc
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        return (0..<days).flatMap { day -> [GlucoseForecastMLReplayExample] in
            let date = calendar.date(byAdding: .day, value: day, to: start)!
            return (0..<anchorsPerDay).flatMap { anchor -> [GlucoseForecastMLReplayExample] in
                let reference = date.addingTimeInterval(12 * 3600 + Double(anchor * 10 * 60))
                return [30, 60, 120].map { horizon in
                    let row = GlucoseForecastMLFeatureRow(
                        horizonMinutes: horizon, referenceDate: reference,
                        engineValue: 150, glucose: 145, sensorID: "sensor-a",
                        values: Array(repeating: 1, count: 16))
                    return GlucoseForecastMLReplayExample(
                        row: row, targetDate: reference.addingTimeInterval(Double(horizon * 60)),
                        targetGlucoseMgdl: 155, engineTargetGlucoseMgdl: 150,
                        engineTrajectoryMgdl: Array(repeating: 150, count: 25),
                        sourceIdentity: "sensor:sensor-a",
                        treatmentAvailability: .retrospectiveUnknown,
                        settingsAvailability: .retrospectiveUnknown)
                }
            }
        }
    }

    func testChronologyKeepsThreeDisjointPeriodsAndEmbargoesCrossBoundaryTarget() throws {
        var calendar = utc
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var rows = examples()
        let bStart = calendar.date(from: DateComponents(year: 2026, month: 2, day: 2))!
        let crossingReference = bStart.addingTimeInterval(-90 * 60)
        let crossing = GlucoseForecastMLReplayExample(
            row: GlucoseForecastMLFeatureRow(horizonMinutes: 120,
                referenceDate: crossingReference, engineValue: 150, glucose: 145,
                sensorID: "sensor-a", values: Array(repeating: 1, count: 16)),
            targetDate: crossingReference.addingTimeInterval(120 * 60),
            targetGlucoseMgdl: 155, engineTargetGlucoseMgdl: 150,
            engineTrajectoryMgdl: Array(repeating: 150, count: 25),
            sourceIdentity: "sensor:sensor-a", treatmentAvailability: .retrospectiveUnknown,
            settingsAvailability: .retrospectiveUnknown)
        rows.append(crossing)
        let split = try GlucoseForecastMLChronology.split(rows, calendar: calendar)
        XCTAssertEqual(split.usableDayCount, 60)
        XCTAssertEqual(split.bStart, bStart)
        for horizon in [30, 60, 120] {
            XCTAssertEqual(split.a[horizon]?.count, 320)
            XCTAssertEqual(split.b[horizon]?.count, 140)
            XCTAssertEqual(split.c[horizon]?.count, 140)
            XCTAssertTrue(split.a[horizon]!.allSatisfy { $0.targetDate < split.bStart })
            XCTAssertTrue(split.b[horizon]!.allSatisfy { $0.targetDate < split.cStart })
        }
        XCTAssertFalse(split.a[120]!.contains { $0.row.referenceDate == crossingReference })
    }

    func testSparseRecentPeriodCannotSelfCheckOrPromote() {
        var calendar = utc
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cStart = calendar.date(from: DateComponents(year: 2026, month: 2, day: 16))!
        // Keep one +120 example on each of C's 14 days, below the count floor.
        let curtailed = examples().filter { example in
            !(example.row.horizonMinutes == 120 && example.row.referenceDate >=
              cStart
              && calendar.component(.hour, from: example.row.referenceDate) == 12
              && calendar.component(.minute, from: example.row.referenceDate) >= 10)
        }
        XCTAssertThrowsError(try GlucoseForecastMLChronology.split(curtailed, calendar: calendar))
    }

    func testCorrectionLimitAndUnsafeCenterUseWholeEngineFallback() {
        XCTAssertEqual(GlucoseForecastMLChronology.clampedCorrection(40), 27)
        XCTAssertEqual(GlucoseForecastMLChronology.clampedCorrection(-40), -27)
        XCTAssertEqual(GlucoseForecastMLChronology.finalGlucose(engine: 570, correction: 40), 597)
        XCTAssertNil(GlucoseForecastMLChronology.finalGlucose(engine: 580, correction: 40))
        XCTAssertNil(GlucoseForecastMLChronology.finalGlucose(engine: 30, correction: -40))
        XCTAssertEqual(GlucoseForecastMLChronology.positiveError(-5), 1)
        XCTAssertNil(GlucoseForecastMLChronology.positiveError(.nan))
    }

    func testCalibrationUsesDeterministicNearestRank() {
        XCTAssertEqual(GlucoseForecastMLChronology.percentile80([10, 1, 8, 2, 5]), 8)
        XCTAssertEqual(GlucoseForecastMLChronology.percentile80([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]), 8)
        XCTAssertEqual(GlucoseForecastMLChronology.percentile80([0, 2, 2, 5, 9]), 5)
        XCTAssertEqual(GlucoseForecastMLChronology.percentile80([7]), 7)
        XCTAssertNil(GlucoseForecastMLChronology.percentile80([]))
        XCTAssertNil(GlucoseForecastMLChronology.percentile80([-1, 2]))
        XCTAssertNil(GlucoseForecastMLChronology.percentile80([1, .infinity]))
    }

    func testMedianUsesMiddleValueOrAverageAndRejectsNonfiniteSamples() {
        XCTAssertEqual(GlucoseForecastMLChronology.median([9, 1, 5]), 5)
        XCTAssertEqual(GlucoseForecastMLChronology.median([10, 2, 8, 4]), 6)
        XCTAssertEqual(GlucoseForecastMLChronology.median([3, 3, 3, 3]), 3)
        XCTAssertNil(GlucoseForecastMLChronology.median([]))
        XCTAssertNil(GlucoseForecastMLChronology.median([1, .nan]))
    }

    func testContextMatchesOnlyExactSourceAndTherapySettings() throws {
        let settings = TherapyModelSettings()
        let trained = try XCTUnwrap(GlucoseForecastMLContext(
            sensitivityMgdlPerUnit: 40, carbohydrateRatioGramsPerUnit: 10,
            settings: settings, sourceSignature: "sensor-a|source-a"))
        let liveInput = GlucoseForecastInput(glucose: [], treatments: [], settings: settings,
            sensitivityMgdlPerUnit: 40, carbohydrateRatioGramsPerUnit: 10, horizonMinutes: 120)
        XCTAssertEqual(GlucoseForecastMLContext(input: liveInput,
            sourceSignature: "sensor-a|source-a"), trained)
        XCTAssertEqual(trained.engineVersion, GlucoseForecastEngine.engineVersion)
        XCTAssertEqual(trained.featureVersion, GlucoseForecastMLFeatures.featureVersion)
        XCTAssertNotEqual(GlucoseForecastMLContext(input: liveInput,
            sourceSignature: "sensor-a|source-b"), trained)
        XCTAssertNil(GlucoseForecastMLContext(input: liveInput, sourceSignature: ""))

        var changed = settings
        changed.insulinDuration = 570
        XCTAssertNotEqual(GlucoseForecastMLContext(sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, settings: changed,
            sourceSignature: "sensor-a|source-a"), trained)
        changed = settings
        changed.insulinPeak = 70
        XCTAssertNotEqual(GlucoseForecastMLContext(sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, settings: changed,
            sourceSignature: "sensor-a|source-a"), trained)
        changed = settings
        changed.carbDuration = 300
        XCTAssertNotEqual(GlucoseForecastMLContext(sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, settings: changed,
            sourceSignature: "sensor-a|source-a"), trained)
        XCTAssertNotEqual(GlucoseForecastMLContext(sensitivityMgdlPerUnit: 41,
            carbohydrateRatioGramsPerUnit: 10, settings: settings,
            sourceSignature: "sensor-a|source-a"), trained)
        XCTAssertNotEqual(GlucoseForecastMLContext(sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 11, settings: settings,
            sourceSignature: "sensor-a|source-a"), trained)
        changed = settings
        changed.carbDuration = 61
        XCTAssertNil(GlucoseForecastMLContext(sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, settings: changed,
            sourceSignature: "sensor-a|source-a"))
    }

    func testCurveInterpolatesCorrectionAndBandAtFiveMinutePoints() throws {
        let engine = Array(repeating: 150.0, count: 25)
        let knots = [
            GlucoseForecastMLChronology.Knot(minute: 0, correction: 0, halfWidth: 0),
            .init(minute: 30, correction: 12, halfWidth: 6),
            .init(minute: 60, correction: -6, halfWidth: 12),
            .init(minute: 120, correction: 18, halfWidth: 24)
        ]
        let overlay = try XCTUnwrap(GlucoseForecastMLChronology.assemble(
            engine: engine, knots: knots, horizonMinutes: 120))
        XCTAssertEqual(overlay.central.count, engine.count)
        XCTAssertEqual(overlay.halfWidth.count, engine.count)
        XCTAssertEqual([overlay.central[0], overlay.central[3], overlay.central[6],
                        overlay.central[9], overlay.central[12], overlay.central[18],
                        overlay.central[24]], [150, 156, 162, 153, 144, 156, 168])
        XCTAssertEqual([overlay.halfWidth[0], overlay.halfWidth[3], overlay.halfWidth[6],
                        overlay.halfWidth[9], overlay.halfWidth[12], overlay.halfWidth[18],
                        overlay.halfWidth[24]], [0, 3, 6, 9, 12, 18, 24])
    }

    func testUnsafePointRejectsWholeCurveForEngineFallback() {
        let knots = [
            GlucoseForecastMLChronology.Knot(minute: 0, correction: 0, halfWidth: 0),
            .init(minute: 30, correction: 0, halfWidth: 6),
            .init(minute: 60, correction: 12, halfWidth: 12)
        ]
        var engine = Array(repeating: 150.0, count: 13)
        engine[11] = 598 // +55 minutes: interpolated correction is +10, beyond 600.
        XCTAssertNil(GlucoseForecastMLChronology.assemble(
            engine: engine, knots: knots, horizonMinutes: 60))
        engine[11] = .nan
        XCTAssertNil(GlucoseForecastMLChronology.assemble(
            engine: engine, knots: knots, horizonMinutes: 60))
        engine[11] = 150
        XCTAssertNil(GlucoseForecastMLChronology.assemble(engine: engine,
            knots: [knots[0], .init(minute: 30, correction: 28, halfWidth: 6), knots[2]],
            horizonMinutes: 60))
        XCTAssertNil(GlucoseForecastMLChronology.assemble(engine: engine,
            knots: [knots[0], .init(minute: 30, correction: 0, halfWidth: -1), knots[2]],
            horizonMinutes: 60))
        XCTAssertNil(GlucoseForecastMLChronology.assemble(
            engine: Array(engine.dropLast()), knots: knots, horizonMinutes: 60))
    }

    func testSplitEmbargoesTheTwoMinuteJoinAtBothPeriodBoundaries() throws {
        var calendar = utc
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let base = examples()
        let baseline = try GlucoseForecastMLChronology.split(base, calendar: calendar)
        let acceptedA = baseline.bStart.addingTimeInterval(-32 * 60 - 1)
        let embargoedA = baseline.bStart.addingTimeInterval(-32 * 60)
        let acceptedB = baseline.cStart.addingTimeInterval(-32 * 60 - 1)
        let embargoedB = baseline.cStart.addingTimeInterval(-32 * 60)
        let additional = [acceptedA, embargoedA, acceptedB, embargoedB].map { reference in
            GlucoseForecastMLReplayExample(
                row: GlucoseForecastMLFeatureRow(horizonMinutes: 30,
                    referenceDate: reference, engineValue: 150, glucose: 145,
                    sensorID: "sensor-a", values: Array(repeating: 1, count: 16)),
                targetDate: reference.addingTimeInterval(30 * 60),
                targetGlucoseMgdl: 155, engineTargetGlucoseMgdl: 150,
                engineTrajectoryMgdl: Array(repeating: 150, count: 25),
                sourceIdentity: "sensor:sensor-a", treatmentAvailability: .retrospectiveUnknown,
                settingsAvailability: .retrospectiveUnknown)
        }
        let split = try GlucoseForecastMLChronology.split(base + additional, calendar: calendar)
        XCTAssertEqual(split.a[30]?.count, baseline.a[30]!.count + 1)
        XCTAssertEqual(split.b[30]?.count, baseline.b[30]!.count + 1)
        XCTAssertEqual(split.c[30]?.count, baseline.c[30]!.count)
        XCTAssertTrue(split.a[30]!.contains { $0.row.referenceDate == acceptedA })
        XCTAssertTrue(split.b[30]!.contains { $0.row.referenceDate == acceptedB })
        XCTAssertFalse(split.a[30]!.contains { $0.row.referenceDate == embargoedA })
        XCTAssertFalse(split.b[30]!.contains { $0.row.referenceDate == embargoedB })
        XCTAssertFalse(split.c[30]!.contains { $0.row.referenceDate == embargoedB })
    }
}
