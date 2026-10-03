import XCTest
@testable import xdrip

final class GlucoseForecastLogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000.125)
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let folder { try? FileManager.default.removeItem(at: folder) } }

    private func input(at date: Date? = nil, horizon: Int = 60, sensitivity: Double = 40,
                       treatments: [TherapyTreatment] = []) -> GlucoseForecastInput {
        let reference = date ?? now
        return GlucoseForecastInput(glucose: stride(from: -30, through: 0, by: 1).map {
            GlucoseForecastSample(date: reference.addingTimeInterval(Double($0) * 60), glucoseMgdl: 120, sensorID: "sensor-A")
        }, treatments: treatments, settings: TherapyModelSettings(), sensitivityMgdlPerUnit: sensitivity,
        carbohydrateRatioGramsPerUnit: 10, horizonMinutes: horizon, now: reference)
    }
    private func context(at date: Date? = nil, horizon: Int = 60, known: GlucoseForecastSample? = nil,
                         source: String = "sensor:sensor-A", build: String = "candidate") -> GlucoseForecastLogContext {
        GlucoseForecastLogContext(appVersion: "7.1.1", appBuild: build, sourceIdentity: source,
            sensorIdentity: "sensor-A", knownReference: known, computedAt: date ?? now,
            horizonMinutes: horizon, insulinModel: "Fiasp", treatmentWindowStart: now.addingTimeInterval(-36000),
            treatmentWindowEnd: now)
    }
    private func snapshot(_ value: GlucoseForecastInput? = nil, computedAt: Date? = nil,
                          source: String = "sensor:sensor-A", build: String = "candidate") throws -> GlucoseForecastLogSnapshot {
        let value = value ?? input()
        return try .make(input: value, result: GlucoseForecastEngine.predict(value),
            context: context(at: computedAt, horizon: value.horizonMinutes, known: value.glucose.last, source: source, build: build))
    }
    private func unavailable(_ reason: GlucoseForecastUnavailableReason, at date: Date? = nil,
                             known: GlucoseForecastSample? = nil) throws -> GlucoseForecastLogSnapshot {
        try .make(input: nil, result: GlucoseForecastResult(points: [], referenceDate: nil, reason: reason),
                  context: context(at: date, known: known))
    }
    private func dailyFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}\.jsonl$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func records() throws -> [GlucoseForecastLogSnapshot] {
        try dailyFiles()
            .flatMap { file in
                try Data(contentsOf: file).split(separator: 10).map {
                    try GlucoseForecastLogSnapshot.decoder().decode(GlucoseForecastLogSnapshot.self, from: Data($0))
                }
            }
    }
    private func log(at date: Date? = nil, diagnostic: @escaping (GlucoseForecastLogFailure) -> Void = { _ in }) -> GlucoseForecastLog {
        let date = date ?? now
        return GlucoseForecastLog(directory: folder, clock: { date }, diagnostic: diagnostic)
    }

    func testFirstValidSnapshotSurvivesRepeatedCallsAndRestart() throws {
        let first = try snapshot()
        let log = log()
        log.enqueue(first); log.enqueue(first); log.waitUntilIdle()
        let later = try snapshot(input(sensitivity: 50), computedAt: now.addingTimeInterval(60), build: "later")
        let restarted = self.log()
        restarted.enqueue(later); restarted.waitUntilIdle()
        let saved = try records()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.parameters.sensitivityMgdlPerUnit, 40)
        XCTAssertEqual(saved.first?.computedAt, now)
        XCTAssertEqual(saved.first?.appBuild, "candidate")
        XCTAssertEqual(saved.first?.inputFingerprint, first.inputFingerprint)
    }

    func testValidDedupUsesReferenceDayWhenCompletionCrossesMidnight() throws {
        let reference = try XCTUnwrap(GlucoseForecastLogSnapshot.parseDate("2026-10-03T23:59:30.000Z"))
        let later = reference.addingTimeInterval(90)
        let logger = log(at: later)
        logger.enqueue(try snapshot(input(at: reference), computedAt: reference)); logger.waitUntilIdle()
        let restarted = log(at: later)
        restarted.enqueue(try snapshot(input(at: reference), computedAt: later)); restarted.waitUntilIdle()
        XCTAssertEqual(try records().count, 1)
    }

    func testBothHorizonsAndDifferentSensorsHaveIndependentValidRecords() throws {
        let logger = log()
        logger.enqueue(try snapshot()); logger.enqueue(try snapshot(input(horizon: 120)))
        logger.enqueue(try snapshot(source: "sensor:sensor-B")); logger.waitUntilIdle()
        XCTAssertEqual(try records().count, 3)
        XCTAssertEqual(Set(try records().map(\.horizonMinutes)), [60, 120])
    }

    func testUnavailableDoesNotBlockLaterValidAndIdenticalErrorsAreThrottled() throws {
        let value = input(); let reference = value.glucose.last
        let logger = log()
        logger.enqueue(try unavailable(.dataUnavailable, known: reference))
        logger.enqueue(try unavailable(.dataUnavailable, known: reference))
        logger.enqueue(try unavailable(.historyGap, known: reference))
        logger.enqueue(try snapshot(value)); logger.waitUntilIdle()
        XCTAssertEqual(try records().filter { $0.recordType == .unavailable }.count, 2)
        XCTAssertEqual(try records().filter { $0.recordType == .forecast }.count, 1)
        let restarted = log(); restarted.enqueue(try unavailable(.dataUnavailable, known: reference)); restarted.waitUntilIdle()
        XCTAssertEqual(try records().count, 3)
    }

    func testUnknownReferenceIsNilAndNeverInvented() throws {
        let value = try unavailable(.missingGlucose)
        XCTAssertNil(value.referenceDate); XCTAssertNil(value.referenceIdentity)
        XCTAssertNil(value.referenceGlucoseMgdl); XCTAssertNil(value.inputs)
        XCTAssertNil(value.treatmentSummary.bolusCount); XCTAssertNil(value.treatmentSummary.bolusUnits)
        let logger = log(); logger.enqueue(value); logger.waitUntilIdle()
        XCTAssertNil(try records().first?.referenceDate)
    }

    func testUnavailableNonfiniteInputsRemainMissingRatherThanBreakingTheLog() throws {
        var settings = TherapyModelSettings()
        settings.insulinPeak = .nan; settings.carbDuration = .infinity
        let sample = GlucoseForecastSample(date: now, glucoseMgdl: .nan, sensorID: "sensor-A")
        let invalid = GlucoseForecastInput(glucose: [sample], treatments: [], settings: settings,
            sensitivityMgdlPerUnit: .infinity, carbohydrateRatioGramsPerUnit: .nan, now: now)
        let result = GlucoseForecastEngine.predict(invalid)
        let value = try GlucoseForecastLogSnapshot.make(input: invalid, result: result,
            context: context(known: sample))
        XCTAssertEqual(value.reason, "invalidSettings")
        XCTAssertNil(value.referenceGlucoseMgdl)
        XCTAssertNil(value.parameters.insulinPeakMinutes)
        XCTAssertNil(value.parameters.carbohydrateDurationMinutes)
        XCTAssertNil(value.parameters.sensitivityMgdlPerUnit)
        XCTAssertNil(value.parameters.carbohydrateRatioGramsPerUnit)
        let logger = log(); logger.enqueue(value); logger.waitUntilIdle()
        XCTAssertEqual(try records().count, 1)
        XCTAssertEqual(try records().first?.reason, "invalidSettings")
        XCTAssertNil(try records().first?.referenceGlucoseMgdl)
    }

    func testValueSnapshotAndFingerprintDoNotFollowChangedSettings() throws {
        var settings = TherapyModelSettings()
        let original = input()
        let first = try snapshot(original)
        settings.carbDuration = 360; settings.insulinPeak = 55
        let changed = GlucoseForecastInput(glucose: original.glucose, treatments: original.treatments,
            settings: settings, sensitivityMgdlPerUnit: 30, carbohydrateRatioGramsPerUnit: 12,
            horizonMinutes: 60, now: now)
        let second = try snapshot(changed)
        XCTAssertEqual(first.parameters.carbohydrateDurationMinutes, 240)
        XCTAssertEqual(first.parameters.insulinPeakMinutes, 75)
        XCTAssertEqual(first.parameters.sensitivityMgdlPerUnit, 40)
        XCTAssertNotEqual(first.inputFingerprint, second.inputFingerprint)
        XCTAssertEqual(first.constants, GlucoseForecastEngine.configuration)
        XCTAssertEqual(first.engineVersion, GlucoseForecastEngine.engineVersion)
        XCTAssertEqual(first.inputFingerprint, try snapshot(original).inputFingerprint)
    }

    func testSnapshotContainsExactlyUsedHistoryAndPositiveKnownTherapy() throws {
        let treatments = [TherapyTreatment(date: now, amount: 1, isIOB: true),
            TherapyTreatment(date: now, amount: 10, isIOB: false),
            TherapyTreatment(date: now, amount: 0, isIOB: true),
            TherapyTreatment(date: now.addingTimeInterval(60), amount: 2, isIOB: true)]
        let original = input(treatments: treatments)
        let augmented = GlucoseForecastInput(glucose: [GlucoseForecastSample(date: now.addingTimeInterval(-3600), glucoseMgdl: 100)] + original.glucose,
            treatments: treatments, settings: original.settings, sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, horizonMinutes: 60, now: now)
        let value = try snapshot(augmented)
        XCTAssertEqual(value.inputs?.glucose.count, 31)
        XCTAssertEqual(value.inputs?.treatments.count, 2)
        XCTAssertEqual(value.treatmentSummary.bolusCount, 1); XCTAssertEqual(value.treatmentSummary.bolusUnits, 1)
        XCTAssertEqual(value.treatmentSummary.carbohydrateCount, 1); XCTAssertEqual(value.treatmentSummary.carbohydrateGrams, 10)
        XCTAssertEqual(value.inputs?.treatments.first { $0.kind == "bolus" }?.unit, "U")
        XCTAssertEqual(value.inputs?.treatments.first { $0.kind == "carbohydrate" }?.unit, "g")
    }

    func testEmptyKnownTherapyHasRealZerosRatherThanMissing() throws {
        let value = try snapshot()
        XCTAssertEqual(value.treatmentSummary.bolusCount, 0); XCTAssertEqual(value.treatmentSummary.bolusUnits, 0)
        XCTAssertEqual(value.treatmentSummary.carbohydrateCount, 0); XCTAssertEqual(value.treatmentSummary.carbohydrateGrams, 0)
    }

    func testRetentionKeepsAtMost400UTCDaysAndPreservesUnrelatedFiles() throws {
        let old = now.addingTimeInterval(-400 * 86400)
        let lastKept = now.addingTimeInterval(-399 * 86400)
        let oldLog = log(at: old); oldLog.enqueue(try snapshot(input(at: old), computedAt: old)); oldLog.waitUntilIdle()
        let keptLog = log(at: lastKept); keptLog.enqueue(try snapshot(input(at: lastKept), computedAt: lastKept)); keptLog.waitUntilIdle()
        let unrelated = folder.appendingPathComponent("notes.txt")
        try Data("preserve".utf8).write(to: unrelated)
        let current = log(); current.enqueue(try snapshot()); current.waitUntilIdle()
        XCTAssertEqual(try records().count, 2)
        XCTAssertTrue(try records().allSatisfy { $0.referenceDate! >= now.addingTimeInterval(-400 * 86400) })
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
        current.enqueue(try snapshot(input(at: old), computedAt: old)); current.waitUntilIdle()
        XCTAssertEqual(try records().count, 2)
    }

    func testPartialTailRecoveryPreservesExistingBytesAndAllowsFutureAppend() throws {
        let logger = log(); logger.enqueue(try snapshot()); logger.waitUntilIdle()
        let file = try XCTUnwrap(dailyFiles().first)
        let before = try Data(contentsOf: file)
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"schemaVersion\":1,\"broken\":".utf8)); try handle.close()
        var failures = [GlucoseForecastLogFailure]()
        let restarted = log(diagnostic: { failures.append($0) })
        restarted.enqueue(try snapshot(input(at: now.addingTimeInterval(60)), computedAt: now.addingTimeInterval(60)))
        restarted.waitUntilIdle()
        XCTAssertTrue(try Data(contentsOf: file).starts(with: before))
        XCTAssertEqual(try records().count, 2); XCTAssertTrue(failures.contains(.corruptRecord))
    }

    func testCompleteFinalLineWithoutNewlineIsPreservedAndDeduplicated() throws {
        let value = try snapshot()
        let name = String(GlucoseForecastLogSnapshot.isoDate(now).prefix(10)) + ".jsonl"
        try GlucoseForecastLogSnapshot.encoder().encode(value).write(to: folder.appendingPathComponent(name))
        let logger = log(); logger.enqueue(value); logger.waitUntilIdle()
        XCTAssertEqual(try records().count, 1)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)).last, 10)
    }

    func testFileFailureIsIsolatedAndOnlyReportsFixedCategory() throws {
        let blocked = folder.appendingPathComponent("not-directory")
        try Data("blocked".utf8).write(to: blocked)
        var failures = [GlucoseForecastLogFailure]()
        let logger = GlucoseForecastLog(directory: blocked, clock: { self.now }, diagnostic: { failures.append($0) })
        logger.enqueue(try snapshot()); logger.enqueue(try snapshot()); logger.waitUntilIdle()
        XCTAssertEqual(failures, [.io])
        XCTAssertEqual(try String(contentsOf: blocked, encoding: .utf8), "blocked")
        XCTAssertEqual(GlucoseForecastEngine.predict(input()).value(atMinutes: 60), 120)
    }

    func testCSVStreamingRoundTripPreservesTypesDatesUnitsNilAndEscaping() throws {
        let logger = log()
        let unusualSource = "sensor:Æble,\"one\"\nline"
        logger.enqueue(try snapshot(source: unusualSource)); logger.enqueue(try snapshot(input(horizon: 120)))
        logger.enqueue(try unavailable(.missingGlucose)); logger.waitUntilIdle()
        let csv = folder.appendingPathComponent("export.csv")
        try logger.exportCSVForTesting(to: csv)
        let rows = parseCSV(try String(contentsOf: csv, encoding: .utf8))
        XCTAssertEqual(rows[0], GlucoseForecastCSV.columns)
        XCTAssertEqual(rows.count, 1 + 13 + 25 + 1)
        XCTAssertTrue(rows.allSatisfy { $0.count == GlucoseForecastCSV.columns.count })
        func column(_ row: [String], _ name: String) -> String { row[GlucoseForecastCSV.columns.firstIndex(of: name)!] }
        let escaped = try XCTUnwrap(rows.dropFirst().first { column($0, "source_identity") == unusualSource })
        XCTAssertEqual(column(escaped, "reference_date_utc"), GlucoseForecastLogSnapshot.isoDate(now))
        XCTAssertEqual(column(escaped, "isf_mgdl_per_unit"), "40.0")
        XCTAssertEqual(column(escaped, "bolus_units"), "0.0")
        XCTAssertEqual(column(escaped, "prediction_mgdl"), "120.0")
        XCTAssertEqual(column(escaped, "engine_constants_json"), String(decoding: try GlucoseForecastLogSnapshot.encoder().encode(GlucoseForecastEngine.configuration), as: UTF8.self))
        let error = try XCTUnwrap(rows.dropFirst().first { column($0, "record_type") == "unavailable" })
        for name in ["reference_date_utc", "reference_glucose_mgdl", "prediction_mgdl", "offset_minutes", "bolus_units", "carb_count"] {
            XCTAssertEqual(column(error, name), "")
        }
        XCTAssertEqual(column(error, "reason"), "missingGlucose")
        XCTAssertEqual(rows.dropFirst().filter { column($0, "offset_minutes") == "120" }.count, 1)
    }

    func testSourceLogIsIncludedInBackupAndProtected() throws {
        let logger = log(); logger.enqueue(try snapshot()); logger.waitUntilIdle()
        let file = try XCTUnwrap(dailyFiles().first)
        XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, false)
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, false)
        #if os(iOS)
        XCTAssertEqual(GlucoseForecastLog.fileProtection, .completeUntilFirstUserAuthentication)
        // CoreSimulator accepts this attribute but does not expose hardware Data
        // Protection in attributesOfItem; verify its applied value on device only.
        #if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, GlucoseForecastLog.fileProtection)
        #endif
        #endif
    }

    func testJSONLinesUsesExactlyOneByteDelimiterDespiteIntegerAppendOverload() throws {
        let logger = log(); logger.enqueue(try snapshot()); logger.waitUntilIdle()
        let file = try XCTUnwrap(dailyFiles().first)
        let data = try Data(contentsOf: file)
        XCTAssertEqual(data.last, UInt8(10))
        XCTAssertFalse(data.contains(UInt8(0)))
        XCTAssertEqual(data.filter { $0 == UInt8(10) }.count, 1)
        XCTAssertEqual(try records().count, 1)
    }

    func testCSVExportDoesNotModifySourceSnapshots() throws {
        let logger = log(); logger.enqueue(try snapshot()); logger.waitUntilIdle()
        let file = try XCTUnwrap(dailyFiles().first)
        let before = try Data(contentsOf: file)
        try logger.exportCSVForTesting(to: folder.appendingPathComponent("first.csv"))
        try logger.exportCSVForTesting(to: folder.appendingPathComponent("second.csv"))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("first.csv")),
                       try Data(contentsOf: folder.appendingPathComponent("second.csv")))
    }

    /// Independent RFC-4180 reader for checking the writer, including quoted newlines.
    private func parseCSV(_ text: String) -> [[String]] {
        var rows = [[String]](), row = [String](), value = "", quoted = false
        let chars = Array(text); var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                if quoted && index + 1 < chars.count && chars[index + 1] == "\"" { value.append("\""); index += 1 }
                else { quoted.toggle() }
            } else if char == "," && !quoted { row.append(value); value = "" }
            else if (char == "\n" || char == "\r\n") && !quoted {
                row.append(value.hasSuffix("\r") ? String(value.dropLast()) : value); value = ""
                rows.append(row); row = []
            } else { value.append(char) }
            index += 1
        }
        if !value.isEmpty || !row.isEmpty { row.append(value); rows.append(row) }
        return rows
    }
}
