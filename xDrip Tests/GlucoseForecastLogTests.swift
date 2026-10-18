import XCTest
import CoreData
import CryptoKit
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

    func testJSONDateCodecPreservesFixedUTCBytesAndOffsetParsing() throws {
        let dates = [now, now.addingTimeInterval(-36000), now.addingTimeInterval(86400)]
        let expected = #"["2027-01-15T08:00:00.125Z","2027-01-14T22:00:00.125Z","2027-01-16T08:00:00.125Z"]"#
        let encoder = GlucoseForecastLogSnapshot.encoder()
        XCTAssertEqual(try encoder.encode(dates), Data(expected.utf8))
        XCTAssertEqual(try encoder.encode(Array(dates.reversed())),
            Data(#"["2027-01-16T08:00:00.125Z","2027-01-14T22:00:00.125Z","2027-01-15T08:00:00.125Z"]"#.utf8))
        let decoder = GlucoseForecastLogSnapshot.decoder()
        XCTAssertEqual(try decoder.decode([Date].self, from: Data(expected.utf8)), dates)
        let offsetDates = #"["2027-01-15T09:00:00.125+01:00","2027-01-14T17:00:00.125-05:00","2027-01-16T08:00:00.125Z"]"#
        XCTAssertEqual(try decoder.decode([Date].self, from: Data(offsetDates.utf8)), dates)
        XCTAssertThrowsError(try decoder.decode([Date].self, from: Data(#"["not-a-date"]"#.utf8)))
    }

    func testJSONLSnapshotAndFingerprintPreserveLegacyEncoding() throws {
        let treatments = [TherapyTreatment(date: now.addingTimeInterval(-300), amount: 1, isIOB: true),
            TherapyTreatment(date: now.addingTimeInterval(-600), amount: 10, isIOB: false)]
        let value = try snapshot(input(treatments: treatments))
        XCTAssertEqual(value.referenceIdentity,
            "916bb4eeb1ff72806f33c0817466a2f4f2db13f499f2294cb37706893c6c4cca")
        // Pin the fingerprint's wire contract independently of the production codec.
        struct Fingerprint: Encodable {
            let source: String; let sensor: String?; let horizon: Int
            let inputs: GlucoseForecastLogSnapshot.Inputs
            let parameters: GlucoseForecastLogSnapshot.Parameters
            let constants: GlucoseForecastEngineConfiguration
        }
        let fingerprint = Fingerprint(source: value.sourceIdentity, sensor: value.sensorIdentity,
            horizon: value.horizonMinutes, inputs: try XCTUnwrap(value.inputs),
            parameters: value.parameters, constants: value.constants)
        let expectedFingerprint = SHA256.hash(data: try legacyEncoder().encode(fingerprint))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(value.inputFingerprint, expectedFingerprint)
        let legacyBytes = try legacyEncoder().encode(value)
        XCTAssertEqual(try GlucoseForecastLogSnapshot.encoder().encode(value), legacyBytes)
        let decoded = try GlucoseForecastLogSnapshot.decoder().decode(GlucoseForecastLogSnapshot.self, from: legacyBytes)
        XCTAssertEqual(try legacyEncoder().encode(decoded), legacyBytes)
        let logger = log(); logger.enqueue(value); logger.waitUntilIdle()
        var expectedLine = legacyBytes
        expectedLine.append(contentsOf: [UInt8(10)])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(dailyFiles().first)), expectedLine)
    }

    /// Pre-optimization JSON date strategy, kept local to the compatibility fixture.
    private func legacyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
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

    func testCSVInvariantCellsAndPointColumnsRemainExactForBothHorizons() throws {
        let source = "sensor:Æble,\"one\"\r\nline"
        for horizon in [60, 120] {
            let value = try snapshot(input(horizon: horizon), computedAt: now.addingTimeInterval(86400), source: source)
            let encodedRows = try GlucoseForecastCSV.rows(value)
            XCTAssertEqual(encodedRows.count, horizon / 5 + 1)
            XCTAssertTrue(encodedRows.allSatisfy { $0.hasSuffix("\r\n") })
            XCTAssertTrue(encodedRows.allSatisfy { $0.contains("\"sensor:Æble,\"\"one\"\"\r\nline\"") })
            let rows = parseCSV(encodedRows.joined())
            XCTAssertEqual(rows.count, horizon / 5 + 1)
            let expectedCells = ["source_identity": source,
                "reference_date_utc": "2027-01-15T08:00:00.125Z",
                "computed_at_utc": "2027-01-16T08:00:00.125Z",
                "treatment_window_start_utc": "2027-01-14T22:00:00.125Z",
                "treatment_window_end_utc": "2027-01-15T08:00:00.125Z",
                "horizon_minutes": String(horizon), "reference_glucose_mgdl": "120.0",
                "prediction_mgdl": "120.0", "reason": "", "insulin_model": "Fiasp"]
            let offsetColumn = try XCTUnwrap(GlucoseForecastCSV.columns.firstIndex(of: "offset_minutes"))
            for (index, row) in rows.enumerated() {
                guard row.count == GlucoseForecastCSV.columns.count else {
                    XCTFail("Unexpected CSV column count: \(row.count)")
                    continue
                }
                for (name, expected) in expectedCells {
                    let column = try XCTUnwrap(GlucoseForecastCSV.columns.firstIndex(of: name))
                    XCTAssertEqual(row[column], expected, "\(name), horizon \(horizon), row \(index)")
                }
                XCTAssertEqual(row[offsetColumn], String(index * 5))
            }
        }
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

    private func presentationFixture(_ value: GlucoseForecastInput? = nil,
                                     modelID: String? = "synthetic-model-A", correction: Double = 12,
                                     capped: Bool = true, computedAt: Date? = nil) throws -> (
        input: GlucoseForecastInput, result: GlucoseForecastResult,
        raw: GlucoseForecastMLForecast?, snapshot: GlucoseForecastLogSnapshot
    ) {
        let value = value ?? input()
        let calculated = GlucoseForecastEngine.predict(value)
        let engine = GlucoseForecastResult(points: calculated.points, referenceDate: calculated.referenceDate,
            reason: calculated.reason, referenceSensorID: "sensor-A")
        let raw = modelID.map { modelID in
            let points = engine.points.enumerated().map { index, point in
                GlucoseForecastPoint(date: point.date, glucoseMgdl: point.glucoseMgdl +
                    (index == 0 ? 0 : (index == 2 ? -8 : correction)))
            }
            return GlucoseForecastMLForecast(points: points, band: points.map {
                .init(date: $0.date, lowerMgdl: $0.glucoseMgdl - 10, upperMgdl: $0.glucoseMgdl + 10)
            }, modelID: modelID)
        }
        let selected = raw.flatMap {
            GlucoseForecastMLPresentation.cappedBelowEngine($0, engine: engine,
                currentGlucoseMgdl: value.glucose.last?.glucoseMgdl,
                slope15MgdlPerMinute: 0, lowSoonActive: capped)
        }
        let result = GlucoseForecastResult(points: engine.points, referenceDate: engine.referenceDate,
            reason: engine.reason, referenceSensorID: engine.referenceSensorID, mlForecast: selected)
        let snapshot = try GlucoseForecastLogSnapshot.make(input: value, result: result,
            context: context(at: computedAt ?? value.now, horizon: value.horizonMinutes,
                known: value.glucose.last), capturesPresentation: true, mlBeforeCap: raw)
        return (value, result, raw, snapshot)
    }

    func testPresentationSnapshotPreservesExactEngineRawAndCappedCurvesForBothHorizons() throws {
        for horizon in [60, 120] {
            let fixture = try presentationFixture(input(horizon: horizon))
            let snapshot = fixture.snapshot
            let evidence = try XCTUnwrap(snapshot.presentation)
            XCTAssertEqual(snapshot.schemaVersion, 3)
            XCTAssertEqual(snapshot.recordType, .presentation)
            XCTAssertEqual(evidence.modelID, "synthetic-model-A")
            XCTAssertNil(evidence.presentedAt, "Computing a curve does not prove Home displayed it")
            XCTAssertEqual(snapshot.points.map(\.glucoseMgdl), fixture.result.points.map(\.glucoseMgdl))
            XCTAssertEqual(evidence.mlBeforeCapPoints?.map(\.glucoseMgdl), fixture.raw?.points.map(\.glucoseMgdl))
            XCTAssertEqual(evidence.displayedPoints.map(\.glucoseMgdl),
                GlucoseForecastMLPresentation.points(in: fixture.result).map(\.glucoseMgdl))
            XCTAssertEqual(evidence.displayedPoints.map(\.offsetMinutes), Array(stride(from: 0, through: horizon, by: 5)))
            XCTAssertEqual(evidence.mlBeforeCapPoints?[1].glucoseMgdl, 132)
            XCTAssertEqual(evidence.displayedPoints[1].glucoseMgdl, 120)
            XCTAssertEqual(evidence.mlBeforeCapPoints?[2].glucoseMgdl, 112)
            XCTAssertEqual(evidence.displayedPoints[2].glucoseMgdl, 112)
            XCTAssertEqual(snapshot.points[2].glucoseMgdl, 120)
            let confirmed = try XCTUnwrap(snapshot.confirmingPresentation(of: fixture.result,
                at: now.addingTimeInterval(1.250)))
            let decoded = try GlucoseForecastLogSnapshot.decoder().decode(GlucoseForecastLogSnapshot.self,
                from: GlucoseForecastLogSnapshot.encoder().encode(confirmed))
            XCTAssertEqual(try GlucoseForecastLogSnapshot.encoder().encode(decoded),
                try GlucoseForecastLogSnapshot.encoder().encode(confirmed))
            XCTAssertEqual(decoded.presentation?.presentedAt, now.addingTimeInterval(1.250))
            XCTAssertNil(snapshot.presentation?.presentedAt, "Confirming returns a value copy")
        }
    }

    func testPresentationRequiresMatchingConfirmedResultBeforeItCanBeStoredOrExported() throws {
        let fixture = try presentationFixture()
        let result = fixture.result
        let snapshot = fixture.snapshot
        func changed(points: [GlucoseForecastPoint]? = nil, reference: Date? = nil,
                     sensor: String = "sensor-A", model: GlucoseForecastMLForecast? = nil) -> GlucoseForecastResult {
            .init(points: points ?? result.points, referenceDate: reference ?? result.referenceDate,
                reason: nil, referenceSensorID: sensor, mlForecast: model ?? result.mlForecast)
        }
        var changedEngine = result.points
        changedEngine[1] = .init(date: changedEngine[1].date, glucoseMgdl: changedEngine[1].glucoseMgdl + 1)
        var changedDisplayed = try XCTUnwrap(result.mlForecast).points
        changedDisplayed[1] = .init(date: changedDisplayed[1].date, glucoseMgdl: changedDisplayed[1].glucoseMgdl + 1)
        let selected = try XCTUnwrap(result.mlForecast)
        let otherModel = GlucoseForecastMLForecast(points: selected.points, band: selected.band, modelID: "model-B")
        let otherDisplay = GlucoseForecastMLForecast(points: changedDisplayed, band: selected.band, modelID: selected.modelID)
        for mismatch in [changed(points: changedEngine), changed(reference: now.addingTimeInterval(1)),
                         changed(sensor: "sensor-B"), changed(model: otherModel), changed(model: otherDisplay)] {
            XCTAssertNil(snapshot.confirmingPresentation(of: mismatch, at: now.addingTimeInterval(2)))
        }
        XCTAssertNil(snapshot.confirmingPresentation(of: nil, at: now.addingTimeInterval(2)))
        XCTAssertNil(snapshot.confirmingPresentation(of: result, at: now.addingTimeInterval(-1)))
        XCTAssertNil(snapshot.confirmingPresentation(of: result, at: Date(timeIntervalSince1970: .nan)))
        XCTAssertThrowsError(try GlucoseForecastCSV.rows(snapshot))
        var failures = [GlucoseForecastLogFailure]()
        let logger = log(diagnostic: { failures.append($0) })
        logger.enqueue(snapshot); logger.waitUntilIdle()
        XCTAssertTrue(try records().isEmpty)
        XCTAssertEqual(failures, [.invalidSnapshot])
        let confirmed = try XCTUnwrap(snapshot.confirmingPresentation(of: result, at: now.addingTimeInterval(2)))
        logger.enqueue(confirmed); logger.waitUntilIdle()
        XCTAssertEqual(try records().count, 1, "Rejected drafts must not reserve the deduplication key")
    }

    func testInvalidOrMismatchedMLCannotProducePresentationEvidence() throws {
        let fixture = try presentationFixture()
        let raw = try XCTUnwrap(fixture.raw)
        let context = context(known: fixture.input.glucose.last)
        func make(_ raw: GlucoseForecastMLForecast?, result: GlucoseForecastResult? = nil) throws {
            _ = try GlucoseForecastLogSnapshot.make(input: fixture.input, result: result ?? fixture.result,
                context: context, capturesPresentation: true, mlBeforeCap: raw)
        }
        XCTAssertThrowsError(try make(nil))
        XCTAssertThrowsError(try make(.init(points: raw.points, band: raw.band, modelID: "other-model")))
        XCTAssertThrowsError(try make(.init(points: Array(raw.points.dropLast()), band: raw.band, modelID: raw.modelID)))
        for invalid in [Double.nan, .infinity, 0, 1000] {
            var points = raw.points
            points[1] = .init(date: points[1].date, glucoseMgdl: invalid)
            XCTAssertThrowsError(try make(.init(points: points, band: raw.band, modelID: raw.modelID)))
        }
        var wrongAnchor = raw.points
        wrongAnchor[0] = .init(date: wrongAnchor[0].date, glucoseMgdl: 121)
        XCTAssertThrowsError(try make(.init(points: wrongAnchor, band: raw.band, modelID: raw.modelID)))
        var wrongTime = raw.points
        wrongTime[1] = .init(date: wrongTime[1].date.addingTimeInterval(1), glucoseMgdl: wrongTime[1].glucoseMgdl)
        XCTAssertThrowsError(try make(.init(points: wrongTime, band: raw.band, modelID: raw.modelID)))
        let engineOnly = GlucoseForecastResult(points: fixture.result.points, referenceDate: now,
            reason: nil, referenceSensorID: "sensor-A")
        XCTAssertThrowsError(try make(raw, result: engineOnly))
        let unavailable = GlucoseForecastResult(points: [], referenceDate: nil, reason: .dataUnavailable)
        XCTAssertThrowsError(try make(nil, result: unavailable))
        var arbitraryDisplay = try XCTUnwrap(fixture.result.mlForecast).points
        arbitraryDisplay[1] = .init(date: arbitraryDisplay[1].date, glucoseMgdl: 119)
        let arbitrary = GlucoseForecastResult(points: fixture.result.points, referenceDate: now,
            reason: nil, referenceSensorID: "sensor-A", mlForecast: .init(points: arbitraryDisplay,
                band: raw.band, modelID: raw.modelID))
        XCTAssertThrowsError(try make(raw, result: arbitrary), "A display point must be raw ML or the actual engine cap")
    }

    func testFirstPresentationSurvivesChangedInputsRestartAndMidnightOnReferenceDay() throws {
        let reference = try XCTUnwrap(GlucoseForecastLogSnapshot.parseDate("2027-01-15T23:59:30.125Z"))
        let first = try presentationFixture(input(at: reference), computedAt: reference.addingTimeInterval(45))
        let firstSaved = try XCTUnwrap(first.snapshot.confirmingPresentation(of: first.result,
            at: reference.addingTimeInterval(46)))
        let logger = log(at: reference.addingTimeInterval(60))
        logger.enqueue(firstSaved); logger.enqueue(firstSaved); logger.waitUntilIdle()
        let file = try XCTUnwrap(dailyFiles().first)
        XCTAssertEqual(file.lastPathComponent, "2027-01-15.jsonl")
        let originalBytes = try Data(contentsOf: file)
        let changed = try presentationFixture(input(at: reference, sensitivity: 55), correction: 20,
            computedAt: reference.addingTimeInterval(90))
        XCTAssertNotEqual(first.snapshot.inputFingerprint, changed.snapshot.inputFingerprint)
        let restarted = log(at: reference.addingTimeInterval(120))
        restarted.enqueue(try XCTUnwrap(changed.snapshot.confirmingPresentation(of: changed.result,
            at: reference.addingTimeInterval(91))))
        restarted.waitUntilIdle()
        XCTAssertEqual(try records().count, 1)
        XCTAssertEqual(try Data(contentsOf: file), originalBytes)
        XCTAssertEqual(try records().first?.presentation?.mlBeforeCapPoints?[1].glucoseMgdl, 132)
        XCTAssertEqual(try records().first?.presentation?.presentedAt, reference.addingTimeInterval(46))
    }

    func testPresentationDedupSeparatesModelsHorizonsEngineOnlyAndLegacyEngineRecords() throws {
        let logger = log()
        logger.enqueue(try snapshot())
        for (horizon, model) in [(60, "synthetic-model-A" as String?), (60, "synthetic-model-B"),
                                  (120, "synthetic-model-A"), (60, nil)] {
            let fixture = try presentationFixture(input(horizon: horizon), modelID: model)
            let confirmed = try XCTUnwrap(fixture.snapshot.confirmingPresentation(of: fixture.result,
                at: now.addingTimeInterval(1)))
            logger.enqueue(confirmed); logger.enqueue(confirmed)
        }
        logger.waitUntilIdle()
        let saved = try records()
        XCTAssertEqual(saved.count, 5)
        XCTAssertEqual(saved.filter { $0.recordType == .forecast }.count, 1)
        XCTAssertEqual(saved.filter { $0.recordType == .presentation && $0.horizonMinutes == 60 }.count, 3)
        let noML = try XCTUnwrap(saved.first { $0.recordType == .presentation && $0.presentation?.modelID == nil })
        XCTAssertNil(noML.presentation?.mlBeforeCapPoints)
        XCTAssertEqual(noML.presentation?.displayedPoints.map(\.glucoseMgdl), noML.points.map(\.glucoseMgdl))
    }

    func testLegacyJSONWithoutPresentationDecodesWithoutInventingDisplayedEvidence() throws {
        let legacy = try snapshot()
        let encoded = try GlucoseForecastLogSnapshot.encoder().encode(legacy)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["presentation"])
        for schema in [1, 2] {
            object["schemaVersion"] = schema
            let decoded = try GlucoseForecastLogSnapshot.decoder().decode(GlucoseForecastLogSnapshot.self,
                from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded.schemaVersion, schema)
            XCTAssertEqual(decoded.recordType, .forecast)
            XCTAssertNil(decoded.presentation)
            XCTAssertEqual(decoded.points.map(\.glucoseMgdl), legacy.points.map(\.glucoseMgdl))
            let rows = parseCSV(try GlucoseForecastCSV.rows(decoded).joined())
            for row in rows {
                for name in ["model_id", "ml_prediction_mgdl", "displayed_prediction_mgdl", "low_glucose_cap_applied", "presented_at_utc"] {
                    XCTAssertEqual(row[try XCTUnwrap(GlucoseForecastCSV.columns.firstIndex(of: name))], "")
                }
            }
        }
    }

    func testPresentationCSVPreservesRawDisplayedModelCapAndFractionalUTCTimestamps() throws {
        let logger = log()
        let model = "synthetic,\"model\"\nÆ"
        for horizon in [60, 120] {
            let fixture = try presentationFixture(input(horizon: horizon), modelID: model)
            logger.enqueue(try XCTUnwrap(fixture.snapshot.confirmingPresentation(of: fixture.result,
                at: now.addingTimeInterval(1.250))))
        }
        let fallback = try presentationFixture(modelID: nil)
        logger.enqueue(try XCTUnwrap(fallback.snapshot.confirmingPresentation(of: fallback.result,
            at: now.addingTimeInterval(2))))
        logger.waitUntilIdle()
        let destination = folder.appendingPathComponent("presentation.csv")
        try logger.exportCSVForTesting(to: destination)
        // Synthetic cross-language fixture for the Python evaluator integration check.
        let integrationCopy = FileManager.default.temporaryDirectory.appendingPathComponent("forecast-evidence-integration.csv")
        try Data(contentsOf: destination).write(to: integrationCopy)
        let rows = parseCSV(try String(contentsOf: destination, encoding: .utf8))
        XCTAssertEqual(rows.first, GlucoseForecastCSV.columns)
        XCTAssertEqual(rows.count, 1 + 13 + 25 + 13)
        XCTAssertTrue(rows.allSatisfy { $0.count == GlucoseForecastCSV.columns.count })
        func cell(_ row: [String], _ name: String) -> String { row[GlucoseForecastCSV.columns.firstIndex(of: name)!] }
        for row in rows.dropFirst() {
            let offset = try XCTUnwrap(Int(cell(row, "offset_minutes")))
            XCTAssertEqual(cell(row, "schema_version"), "3")
            XCTAssertEqual(cell(row, "record_type"), "presentation")
            XCTAssertEqual(cell(row, "prediction_mgdl"), "120.0")
            if cell(row, "model_id").isEmpty {
                XCTAssertEqual(cell(row, "ml_prediction_mgdl"), "", "Absent ML must remain missing, not become zero")
                XCTAssertEqual(cell(row, "low_glucose_cap_applied"), "")
                XCTAssertEqual(cell(row, "displayed_prediction_mgdl"), "120.0")
                XCTAssertEqual(cell(row, "presented_at_utc"), "2027-01-15T08:00:02.125Z")
            } else {
                XCTAssertEqual(cell(row, "model_id"), model)
                XCTAssertEqual(cell(row, "presented_at_utc"), "2027-01-15T08:00:01.375Z")
                let capped = offset > 0 && offset != 10
                XCTAssertEqual(cell(row, "ml_prediction_mgdl"), offset == 0 ? "120.0" : (capped ? "132.0" : "112.0"))
                XCTAssertEqual(cell(row, "displayed_prediction_mgdl"), offset == 0 || capped ? "120.0" : "112.0")
                XCTAssertEqual(cell(row, "low_glucose_cap_applied"), capped ? "true" : "false")
            }
        }
    }

    func testPresentationWriteFailureCanRetrySameEvidenceWithoutChangingForecast() throws {
        let fixture = try presentationFixture()
        let confirmed = try XCTUnwrap(fixture.snapshot.confirmingPresentation(of: fixture.result,
            at: now.addingTimeInterval(1)))
        let blocked = folder.appendingPathComponent("retry-directory")
        try Data("blocked".utf8).write(to: blocked)
        var failures = [GlucoseForecastLogFailure]()
        let logger = GlucoseForecastLog(directory: blocked, clock: { self.now }, diagnostic: { failures.append($0) })
        let points = fixture.result.points
        let displayed = GlucoseForecastMLPresentation.points(in: fixture.result)
        logger.enqueue(confirmed); logger.enqueue(confirmed); logger.waitUntilIdle()
        XCTAssertEqual(failures, [.io])
        XCTAssertEqual(fixture.result.points, points)
        XCTAssertEqual(GlucoseForecastMLPresentation.points(in: fixture.result), displayed)
        try FileManager.default.removeItem(at: blocked)
        logger.enqueue(confirmed); logger.enqueue(confirmed); logger.waitUntilIdle()
        let file = blocked.appendingPathComponent("2027-01-15.jsonl")
        let lines = try Data(contentsOf: file).split(separator: 10)
        XCTAssertEqual(lines.count, 1)
        let saved = try GlucoseForecastLogSnapshot.decoder().decode(GlucoseForecastLogSnapshot.self,
            from: Data(try XCTUnwrap(lines.first)))
        XCTAssertEqual(try GlucoseForecastLogSnapshot.encoder().encode(saved),
            try GlucoseForecastLogSnapshot.encoder().encode(confirmed))
        XCTAssertEqual(fixture.result.points, points)
        XCTAssertEqual(GlucoseForecastMLPresentation.points(in: fixture.result), displayed)
    }

    @MainActor
    private func evaluationStack() throws -> CoreDataManager {
        let directory = folder.appendingPathComponent("database-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let core = try CoreDataManager(testModelName: ConstantsCoreData.modelName,
            persistentStoreURL: directory.appendingPathComponent("synthetic.sqlite"))
        addTeardownBlock { try? core.disconnectPersistentStoresForTesting() }
        return core
    }

    @MainActor @discardableResult
    private func evaluationReading(_ id: String, at date: Date, value: Double,
                                   sensor: Sensor?, context: NSManagedObjectContext,
                                   suppressed: Bool = false) -> BgReading {
        let row = BgReading(timeStamp: date, sensor: sensor, calibration: nil, rawData: 1,
            deviceName: "Synthetic evaluation fixture", nsManagedObjectContext: context)
        row.id = id
        row.calculatedValue = value
        row.isSuppressedByFiveMinuteCadence = suppressed
        return row
    }

    private func evaluationSnapshot(sensorID: String, reference: Date? = nil,
                                    horizon: Int = 120) throws -> GlucoseForecastLogSnapshot {
        let base = input(at: reference, horizon: horizon)
        let value = GlucoseForecastInput(glucose: base.glucose.map {
            GlucoseForecastSample(date: $0.date, glucoseMgdl: $0.glucoseMgdl, sensorID: sensorID)
        }, treatments: base.treatments, settings: base.settings,
            sensitivityMgdlPerUnit: base.sensitivityMgdlPerUnit,
            carbohydrateRatioGramsPerUnit: base.carbohydrateRatioGramsPerUnit,
            horizonMinutes: horizon, now: base.now)
        return try .make(input: value, result: GlucoseForecastEngine.predict(value),
            context: .init(appVersion: "7.1.1", appBuild: "synthetic", sourceIdentity: "sensor:" + sensorID,
                sensorIdentity: sensorID, knownReference: value.glucose.last,
                computedAt: base.now, horizonMinutes: horizon, insulinModel: "Fiasp",
                treatmentWindowStart: base.now.addingTimeInterval(-36000), treatmentWindowEnd: base.now))
    }

    private func evaluationCSV(_ bundle: ForecastEvaluationExport, actual: Bool) throws -> (URL, [[String]]) {
        for url in bundle.urls where url.pathExtension == "csv" {
            let rows = parseCSV(try String(contentsOf: url, encoding: .utf8))
            if rows.first?.first == (actual ? "date_utc" : "schema_version") {
                return (url, rows)
            }
        }
        XCTFail("Combined export must contain both evaluator CSV files")
        throw GlucoseForecastLogFailure.io
    }

    @MainActor
    func testEvaluationExportUsesExactStoredFinalValuesUnitsDatesAndEscapedIdentity() throws {
        let core = try evaluationStack()
        let context = core.mainManagedObjectContext
        let sensor = Sensor(startDate: now.addingTimeInterval(-3600), nsManagedObjectContext: context)
        sensor.id = "sensor-A,\"quoted\"\nÆ"
        let dates = (0..<4).map { now.addingTimeInterval(1800 + Double($0) * 60 + 0.25) }
        evaluationReading("calculated", at: dates[0], value: 137.125, sensor: sensor, context: context)
        let adjusted = evaluationReading("adjusted", at: dates[1], value: 90, sensor: sensor, context: context)
        adjusted.adjustedValue = NSNumber(value: 142.625)
        let smoothed = evaluationReading("smoothed", at: dates[2], value: 90, sensor: sensor, context: context)
        smoothed.adjustedValue = NSNumber(value: 141)
        smoothed.smoothedValue = NSNumber(value: 148.375)
        let hidden = evaluationReading("display-suppressed-original", at: dates[3], value: 153.875,
            sensor: sensor, context: context, suppressed: true)
        hidden.rawData = 0
        XCTAssertTrue(core.saveChangesSynchronously())
        let logger = log(at: now.addingTimeInterval(10800))
        logger.enqueue(try evaluationSnapshot(sensorID: sensor.id)); logger.waitUntilIdle()
        let bundle = try logger.exportEvaluationForTesting(coreDataManager: core,
            to: folder.appendingPathComponent("final-values"))
        let rows = try evaluationCSV(bundle, actual: true).1
        XCTAssertEqual(rows.first, ["date_utc", "glucose_mgdl", "source_identity", "sensor_identity"])
        XCTAssertEqual(rows.count, 5)
        for (index, row) in rows.dropFirst().enumerated() {
            XCTAssertEqual(row, [GlucoseForecastLogSnapshot.isoDate(dates[index]),
                String([137.125, 142.625, 148.375, 153.875][index]), "sensor:" + sensor.id, sensor.id])
        }
        XCTAssertEqual(rows[1][0], "2027-01-15T08:30:00.375Z")
        XCTAssertTrue(bundle.coverageSummary.contains("Eksporterede glukoserækker: 4"))
        XCTAssertFalse(context.hasChanges, "Export cannot alter or save clinical rows")
    }

    @MainActor
    func testEvaluationExportPreservesSensorSwitchDuplicatesAndConflictsAndReportsExclusions() throws {
        let core = try evaluationStack()
        let context = core.mainManagedObjectContext
        func sensor(_ id: String) -> Sensor {
            let sensor = Sensor(startDate: now.addingTimeInterval(-3600), nsManagedObjectContext: context)
            sensor.id = id
            return sensor
        }
        let first = sensor("sensor-A"), second = sensor("sensor-B"), unrelated = sensor("sensor-C")
        let empty = sensor("")
        let target = now.addingTimeInterval(1800)
        for (id, value) in [("same-id", 110.0), ("same-id", 110.0), ("conflicting", 125.0)] {
            evaluationReading(id, at: target, value: value, sensor: first, context: context)
        }
        evaluationReading("sensor-switched", at: target, value: 135, sensor: second, context: context)
        evaluationReading("unrelated", at: target, value: 145, sensor: unrelated, context: context)
        evaluationReading("missing", at: target, value: 155, sensor: nil, context: context)
        evaluationReading("empty", at: target, value: 156, sensor: empty, context: context)
        evaluationReading("invalid-low", at: target, value: 0, sensor: first, context: context)
        evaluationReading("invalid-high", at: target, value: 601, sensor: first, context: context)
        evaluationReading("internal-error", at: target, value: 38, sensor: first, context: context)
        let nativeLow = evaluationReading("native-low", at: target.addingTimeInterval(60), value: 38,
            sensor: first, context: context)
        nativeLow.rawData = 38
        XCTAssertTrue(core.saveChangesSynchronously())
        let logger = log(at: now.addingTimeInterval(10800))
        logger.enqueue(try evaluationSnapshot(sensorID: first.id))
        logger.enqueue(try evaluationSnapshot(sensorID: second.id)); logger.waitUntilIdle()
        let bundle = try logger.exportEvaluationForTesting(coreDataManager: core,
            to: folder.appendingPathComponent("identities"), pageSize: 2)
        let rows = try evaluationCSV(bundle, actual: true).1.dropFirst()
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.filter { $0[3] == first.id }.map { $0[1] }.sorted(), ["110.0", "110.0", "125.0", "38.0"])
        XCTAssertEqual(rows.filter { $0[3] == second.id }.map { $0[1] }, ["135.0"])
        XCTAssertTrue(rows.allSatisfy { $0[2] == "sensor:" + $0[3] })
        let reportURL = try XCTUnwrap(bundle.urls.first { $0.lastPathComponent == "coverage.txt" })
        let report = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertTrue(report.contains("Udeladt: ugyldige glukoserækker: 3"))
        XCTAssertTrue(report.contains("Udeladt: manglende sensor-ID: 2"))
        XCTAssertTrue(report.contains("Udeladt: uden matchende prognoseidentitet/periode: 1"))
    }

    @MainActor
    func testEvaluationExportIncludesToleranceEndpointsAndClipsAtExportTime() throws {
        let core = try evaluationStack()
        let context = core.mainManagedObjectContext
        let sensor = Sensor(startDate: now.addingTimeInterval(-3600), nsManagedObjectContext: context)
        sensor.id = "sensor-A"
        let offsets: [Double] = [-150.001, -150, 1650, 1950, 3450, 3750, 7050, 7350, 7350.001]
        for (index, offset) in offsets.enumerated() {
            evaluationReading("boundary-\(index)", at: now.addingTimeInterval(offset), value: Double(100 + index),
                sensor: sensor, context: context)
        }
        XCTAssertTrue(core.saveChangesSynchronously())
        let logger = log(at: now.addingTimeInterval(10800))
        logger.enqueue(try evaluationSnapshot(sensorID: sensor.id)); logger.waitUntilIdle()
        let complete = try logger.exportEvaluationForTesting(coreDataManager: core,
            to: folder.appendingPathComponent("boundaries"))
        XCTAssertEqual(try evaluationCSV(complete, actual: true).1.dropFirst().map { $0[1] },
            (101...107).map { String(Double($0)) })
        let clipped = try log(at: now.addingTimeInterval(3750)).exportEvaluationForTesting(coreDataManager: core,
            to: folder.appendingPathComponent("future-clipped"))
        XCTAssertEqual(try evaluationCSV(clipped, actual: true).1.dropFirst().map { $0[1] },
            (101...105).map { String(Double($0)) })
    }

    @MainActor
    func testEvaluationExportReadsMoreThan500RowsWithoutDroppingRepeatedTimestamps() throws {
        let core = try evaluationStack()
        let context = core.mainManagedObjectContext
        let sensor = Sensor(startDate: now.addingTimeInterval(-3600), nsManagedObjectContext: context)
        sensor.id = "sensor-A"
        // Tied timestamps and duplicate IDs cross page boundaries; export preserves every row.
        for index in 0..<1103 {
            evaluationReading("row-\(index % 7)", at: now.addingTimeInterval(1800),
                value: Double(100 + index % 200), sensor: sensor, context: context,
                suppressed: index % 2 == 0)
        }
        XCTAssertTrue(core.saveChangesSynchronously())
        let logger = log(at: now.addingTimeInterval(10800))
        logger.enqueue(try evaluationSnapshot(sensorID: sensor.id)); logger.waitUntilIdle()
        var pages = [Int]()
        let bundle = try logger.exportEvaluationForTesting(coreDataManager: core,
            to: folder.appendingPathComponent("many-rows"), pageRead: { index, _ in pages.append(index) })
        let rows = try evaluationCSV(bundle, actual: true).1.dropFirst()
        XCTAssertEqual(rows.count, 1103)
        XCTAssertGreaterThanOrEqual(pages.count, 3)
        XCTAssertEqual(Array(pages.prefix(3)), [0, 1, 2])
        for value in 100..<300 {
            XCTAssertEqual(rows.filter { $0[1] == String(Double(value)) }.count, value < 203 ? 6 : 5)
        }
    }

    @MainActor
    func testEvaluationExportPinsOneSQLiteGenerationAcrossConcurrentPageChanges() throws {
        let core = try evaluationStack()
        let context = core.mainManagedObjectContext
        let sensor = Sensor(startDate: now.addingTimeInterval(-3600), nsManagedObjectContext: context)
        sensor.id = "sensor-A"
        for index in 0..<8 {
            evaluationReading("original-\(index)", at: now.addingTimeInterval(1800 + Double(index)),
                value: Double(100 + index), sensor: sensor, context: context)
        }
        XCTAssertTrue(core.saveChangesSynchronously())
        let logger = log(at: now.addingTimeInterval(10800))
        logger.enqueue(try evaluationSnapshot(sensorID: sensor.id)); logger.waitUntilIdle()
        var changed = false
        let bundle = try logger.exportEvaluationForTesting(coreDataManager: core,
            to: folder.appendingPathComponent("pinned"), pageSize: 3, pageRead: { page, reader in
                XCTAssertNotNil(reader.queryGenerationToken)
                guard page == 1 else { return }
                let writer = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
                writer.persistentStoreCoordinator = reader.persistentStoreCoordinator
                try writer.performAndWait {
                    let request = BgReading.fetchRequest()
                    request.predicate = NSPredicate(format: "id == %@", "original-6")
                    let original = try XCTUnwrap(writer.fetch(request).first)
                    original.calculatedValue = 206
                    let deletedRequest = BgReading.fetchRequest()
                    deletedRequest.predicate = NSPredicate(format: "id == %@", "original-4")
                    writer.delete(try XCTUnwrap(writer.fetch(deletedRequest).first))
                    let added = BgReading(timeStamp: self.now.addingTimeInterval(1806.5), sensor: original.sensor,
                        calibration: nil, rawData: 1, deviceName: "Synthetic concurrent writer",
                        nsManagedObjectContext: writer)
                    added.calculatedValue = 250
                    try writer.save()
                }
                changed = true
            })
        XCTAssertTrue(changed)
        XCTAssertEqual(try evaluationCSV(bundle, actual: true).1.dropFirst().map { $0[1] },
            (100...107).map { String(Double($0)) })
        let fresh = try logger.exportEvaluationForTesting(coreDataManager: core,
            to: folder.appendingPathComponent("fresh"), pageSize: 3)
        XCTAssertEqual(try evaluationCSV(fresh, actual: true).1.dropFirst().map { $0[1] },
            ["100.0", "101.0", "102.0", "103.0", "105.0", "206.0", "250.0", "107.0"])
    }

    @MainActor
    func testEvaluationReadFailureRemovesPartialBundleAndDiffersFromNoRetainedActuals() throws {
        let core = try evaluationStack()
        let context = core.mainManagedObjectContext
        let sensor = Sensor(startDate: now.addingTimeInterval(-3600), nsManagedObjectContext: context)
        sensor.id = "sensor-A"
        for index in 0..<4 {
            evaluationReading("row-\(index)", at: now.addingTimeInterval(1800 + Double(index)),
                value: 120, sensor: sensor, context: context)
        }
        XCTAssertTrue(core.saveChangesSynchronously())
        let logger = log(at: now.addingTimeInterval(10800))
        logger.enqueue(try evaluationSnapshot(sensorID: sensor.id)); logger.waitUntilIdle()
        let failedDirectory = folder.appendingPathComponent("failed-bundle")
        XCTAssertThrowsError(try logger.exportEvaluationForTesting(coreDataManager: core,
            to: failedDirectory, pageSize: 2, pageRead: { page, _ in
                if page == 1 { throw GlucoseForecastLogFailure.io }
            }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedDirectory.path),
            "A failed read cannot leave apparently usable partial files")
        let empty = try evaluationStack()
        let successful = try logger.exportEvaluationForTesting(coreDataManager: empty,
            to: folder.appendingPathComponent("no-retained-actuals"))
        XCTAssertEqual(try evaluationCSV(successful, actual: true).1.count, 1)
        XCTAssertTrue(successful.coverageSummary.contains("Eksporterede glukoserækker: 0"))
    }

    @MainActor
    func testEvaluationExportPreservesLegacyCSVAndSourceLogAndDoesNotSavePendingChanges() throws {
        let core = try evaluationStack()
        let context = core.mainManagedObjectContext
        let sensor = Sensor(startDate: now.addingTimeInterval(-3600), nsManagedObjectContext: context)
        sensor.id = "sensor-A"
        let original = evaluationReading("committed", at: now.addingTimeInterval(1800), value: 120,
            sensor: sensor, context: context)
        XCTAssertTrue(core.saveChangesSynchronously())
        original.calculatedValue = 150
        evaluationReading("pending", at: now.addingTimeInterval(3600), value: 160,
            sensor: sensor, context: context)
        let logger = log(at: now.addingTimeInterval(10800))
        logger.enqueue(try snapshot())
        let fixture = try presentationFixture(input(horizon: 120), modelID: "synthetic,\"model\"\nÆ")
        logger.enqueue(try XCTUnwrap(fixture.snapshot.confirmingPresentation(of: fixture.result,
            at: now.addingTimeInterval(1.250))))
        logger.waitUntilIdle()
        let sources = try dailyFiles().map { ($0, try Data(contentsOf: $0)) }
        let legacy = folder.appendingPathComponent("legacy-compatible.csv")
        try logger.exportCSVForTesting(to: legacy)
        let bundle = try logger.exportEvaluationForTesting(coreDataManager: core,
            to: folder.appendingPathComponent("read-only"))
        XCTAssertEqual(try Data(contentsOf: evaluationCSV(bundle, actual: false).0), try Data(contentsOf: legacy))
        for (url, bytes) in sources { XCTAssertEqual(try Data(contentsOf: url), bytes) }
        XCTAssertEqual(try evaluationCSV(bundle, actual: true).1.dropFirst().map { $0[1] }, ["120.0"])
        XCTAssertTrue(context.hasChanges)
        XCTAssertEqual(original.calculatedValue, 150)
    }

    @MainActor
    func testEmptyEvaluationExportCreatesHeaderOnlyFilesWithoutReadingGlucose() throws {
        let core = try evaluationStack()
        let logger = log()
        var reads = 0
        let bundle = try logger.exportEvaluationForTesting(coreDataManager: core,
            to: folder.appendingPathComponent("empty"), pageRead: { _, _ in reads += 1 })
        XCTAssertEqual(try evaluationCSV(bundle, actual: false).1.count, 1)
        XCTAssertEqual(try evaluationCSV(bundle, actual: true).1.count, 1)
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(try dailyFiles().isEmpty)
        XCTAssertTrue(bundle.coverageSummary.contains("Eksporterede glukoserækker: 0"))
    }

    @MainActor
    func testCombinedEvaluationExportProducesRealSwiftFilesForEvaluatorKnownAnswers() throws {
        let core = try evaluationStack()
        let context = core.mainManagedObjectContext
        let sensor = Sensor(startDate: now.addingTimeInterval(-3600), nsManagedObjectContext: context)
        sensor.id = "sensor-A"
        for (minutes, glucose) in [(30, 125.0), (60, 130.0), (120, 140.0)] {
            evaluationReading("actual-\(minutes)", at: now.addingTimeInterval(Double(minutes * 60)), value: glucose,
                sensor: sensor, context: context, suppressed: minutes == 30)
        }
        XCTAssertTrue(core.saveChangesSynchronously())
        let logger = log(at: now.addingTimeInterval(10800))
        let model = "synthetic,\"model\"\nÆ"
        for horizon in [60, 120] {
            let fixture = try presentationFixture(input(horizon: horizon), modelID: model)
            logger.enqueue(try XCTUnwrap(fixture.snapshot.confirmingPresentation(of: fixture.result,
                at: now.addingTimeInterval(1.250))))
        }
        let fallback = try presentationFixture(modelID: nil)
        logger.enqueue(try XCTUnwrap(fallback.snapshot.confirmingPresentation(of: fallback.result,
            at: now.addingTimeInterval(2))))
        logger.waitUntilIdle()
        let bundle = try logger.exportEvaluationForTesting(coreDataManager: core,
            to: folder.appendingPathComponent("integration"))
        XCTAssertEqual(try evaluationCSV(bundle, actual: true).1.count, 4)
        // Only synthetic fixtures leave this test's directory, for the actual Python CLI check.
        for actual in [false, true] {
            let source = try evaluationCSV(bundle, actual: actual).0
            let name = actual ? "forecast-evaluation-actual-integration.csv" : "forecast-evaluation-forecast-integration.csv"
            try Data(contentsOf: source).write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name))
        }
    }

    @MainActor
    func testEvaluationExportReportsCorruptCompleteAndInterruptedRecordsWithoutChangingLog() throws {
        let core = try evaluationStack()
        let logger = log(at: now.addingTimeInterval(10800))
        logger.enqueue(try snapshot()); logger.waitUntilIdle()
        let source = try XCTUnwrap(dailyFiles().first)
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"broken\":true}\n{\"incomplete\":".utf8))
        try handle.close()
        let before = try Data(contentsOf: source)
        let bundle = try logger.exportEvaluationForTesting(coreDataManager: core,
            to: folder.appendingPathComponent("corrupt-records"))
        XCTAssertEqual(try evaluationCSV(bundle, actual: false).1.count, 14)
        XCTAssertEqual(try evaluationCSV(bundle, actual: true).1.count, 1)
        XCTAssertTrue(bundle.coverageSummary.contains("Oversprungne ulæselige prognoseposter: 2"))
        let reportURL = try XCTUnwrap(bundle.urls.first { $0.lastPathComponent == "coverage.txt" })
        XCTAssertTrue(try String(contentsOf: reportURL, encoding: .utf8)
            .contains("Oversprungne ulæselige prognoseposter: 2"))
        XCTAssertEqual(try Data(contentsOf: source), before)
    }

    @MainActor
    func testPublicEvaluationExportCompletesOnMainWithAllThreeFilesReady() async throws {
        let core = try evaluationStack()
        let logger = log(at: now.addingTimeInterval(10800))
        logger.enqueue(try snapshot()); logger.waitUntilIdle()
        let bundle: ForecastEvaluationExport = try await withCheckedThrowingContinuation { continuation in
            logger.exportEvaluation(coreDataManager: core) { outcome in
                XCTAssertTrue(Thread.isMainThread)
                if case .success(let result) = outcome {
                    XCTAssertEqual(Set(result.urls.map(\.lastPathComponent)),
                        Set(["forecast.csv", "actual-glucose.csv", "coverage.txt"]))
                    XCTAssertTrue(result.urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
                }
                continuation.resume(with: outcome)
            }
        }
        let exportedDirectory = try XCTUnwrap(bundle.urls.first).deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: exportedDirectory) }
        XCTAssertEqual(try evaluationCSV(bundle, actual: false).1.count, 14)
        XCTAssertEqual(try evaluationCSV(bundle, actual: true).1.count, 1)
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
