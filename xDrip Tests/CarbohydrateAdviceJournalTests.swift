import XCTest
@testable import xdrip

final class CarbohydrateAdviceJournalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000.125)
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    private func journal(at date: Date? = nil,
                         diagnostic: @escaping (CarbohydrateAdviceJournalFailure) -> Void = { _ in }) -> CarbohydrateAdviceJournal {
        let date = date ?? now
        return CarbohydrateAdviceJournal(directory: directory, clock: { date }, diagnostic: diagnostic)
    }
    private func evidence(_ id: String = "synthetic-assessment", at date: Date? = nil,
                          grams: Double? = 8, event: CarbohydrateAdviceEvidence.Event = .assessed,
                          points: [CarbohydrateAdviceEvidence.Point] = []) -> CarbohydrateAdviceEvidence {
        CarbohydrateAdviceEvidence(recordID: id, event: event, recordedAt: date ?? now,
            referenceDate: now, engineVersion: "synthetic-engine", sourceSignature: "synthetic-source",
            treatmentRevision: 3, glucoseMgdl: 100, predictedMinimumMgdl: 65,
            predictedMinimumDate: now.addingTimeInterval(1800), estimatedGrams: grams,
            status: "synthetic-test", sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, fastAbsorptionMinutes: 30, targetMgdl: 80,
            treatmentID: event == .registered ? "synthetic-treatment" : nil,
            actualCarbohydrateGrams: event == .registered ? 10 : nil,
            treatmentDate: event == .registered ? now : nil, forecastPoints: points)
    }
    private func records(_ journal: CarbohydrateAdviceJournal) async throws -> [CarbohydrateAdviceEvidence] {
        try await journal.records(from: now.addingTimeInterval(-500 * 86400), to: now.addingTimeInterval(2 * 86400))
    }
    private func file() throws -> URL {
        try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "jsonl" })
    }

    func testFirstImmutableRecordDeduplicatesAcrossRestartAndChangedRecordDate() async throws {
        let first = evidence()
        let writer = journal()
        writer.enqueue(first); writer.enqueue(first); writer.waitUntilIdle()
        let restarted = journal(at: now.addingTimeInterval(86400))
        restarted.enqueue(evidence(at: now.addingTimeInterval(86400), grams: 22))
        restarted.waitUntilIdle()
        let saved = try await records(restarted)
        XCTAssertEqual(saved, [first])
    }

    func testAssessmentAndVerifiedRegistrationHaveSeparateStableIDs() async throws {
        let writer = journal()
        let assessed = evidence("assessment")
        let registered = evidence("registration", event: .registered)
        writer.enqueue(assessed); writer.enqueue(registered); writer.enqueue(registered)
        let saved = try await records(writer)
        XCTAssertEqual(saved, [assessed, registered])
        XCTAssertNil(saved[0].treatmentID)
        XCTAssertEqual(saved[1].actualCarbohydrateGrams, 10)
        XCTAssertEqual(saved[1].treatmentDate, now)
    }

    func testVerifiedRegistrationCopiesOriginalAssessmentWithoutReplacingIt() async throws {
        let point = CarbohydrateAdviceEvidence.Point(date: now.addingTimeInterval(300), glucoseMgdl: 95)
        let assessment = evidence(points: [point])
        let registeredAt = now.addingTimeInterval(120)
        let actualDate = now.addingTimeInterval(60)
        let registered = assessment.recordingVerifiedCarbohydrates(
            id: "actual-treatment", grams: 11.5, date: actualDate, at: registeredAt)
        let writer = journal(); writer.enqueue(assessment); writer.enqueue(registered)
        let saved = try await records(writer)
        XCTAssertEqual(saved, [assessment, registered])
        XCTAssertEqual(registered.recordID, "registered|actual-treatment")
        XCTAssertEqual(registered.event, .registered)
        XCTAssertEqual(registered.recordedAt, registeredAt)
        XCTAssertEqual(registered.referenceDate, assessment.referenceDate)
        XCTAssertEqual(registered.estimatedGrams, 8)
        XCTAssertEqual(registered.actualCarbohydrateGrams, 11.5)
        XCTAssertEqual(registered.treatmentDate, actualDate)
        XCTAssertEqual(registered.forecastPoints, [point])
        XCTAssertNil(assessment.treatmentID)
        XCTAssertEqual(assessment.event, .assessed)
    }

    func testMissingReferenceRemainsMissingAndSnapshotArraysDoNotChange() async throws {
        var points = [CarbohydrateAdviceEvidence.Point(date: now, glucoseMgdl: 100)]
        let missing = CarbohydrateAdviceEvidence(recordID: "missing-reference", event: .assessed,
            recordedAt: now, engineVersion: "synthetic-engine", status: "missing-data")
        let original = evidence("snapshot", points: points)
        let writer = journal()
        writer.enqueue(missing); writer.enqueue(original)
        points.append(.init(date: now.addingTimeInterval(300), glucoseMgdl: 120))
        let saved = try await records(writer)
        XCTAssertEqual(saved.first, missing)
        XCTAssertNil(saved.first?.referenceDate)
        XCTAssertNil(saved.first?.glucoseMgdl)
        XCTAssertNil(saved.first?.estimatedGrams)
        XCTAssertEqual(saved.last?.forecastPoints, [.init(date: now, glucoseMgdl: 100)])
        XCTAssertEqual(saved.last?.sensitivityMgdlPerUnit, 40)
    }

    func testInterruptedTailPreservesPriorBytesAndAllowsFutureAppend() async throws {
        let writer = journal(); writer.enqueue(evidence()); writer.waitUntilIdle()
        let path = try file()
        let bytes = try Data(contentsOf: path)
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"recordID\":\"interrupted".utf8)); try handle.close()
        var failures = [CarbohydrateAdviceJournalFailure]()
        let restarted = journal(diagnostic: { failures.append($0) })
        restarted.enqueue(evidence("next")); restarted.waitUntilIdle()
        XCTAssertTrue(try Data(contentsOf: path).starts(with: bytes))
        let saved = try await records(restarted)
        XCTAssertEqual(Set(saved.map(\.recordID)), ["synthetic-assessment", "next"])
        XCTAssertTrue(failures.contains(.corruptRecord))
    }

    func testCompleteTailWithoutNewlineSurvivesRestartAndDeduplicates() async throws {
        let record = evidence()
        let path = directory.appendingPathComponent(String(GlucoseForecastLogSnapshot.isoDate(now).prefix(10)) + ".jsonl")
        try GlucoseForecastLogSnapshot.encoder().encode(record).write(to: path)
        let restarted = journal(); restarted.enqueue(record); restarted.enqueue(evidence("next"))
        let saved = try await records(restarted)
        XCTAssertEqual(saved.count, 2)
        XCTAssertEqual(saved.first { $0.recordID == record.recordID }, record)
    }

    func testCompletedCorruptLineIsPreservedWhileLaterRecordsRemainReadable() async throws {
        let writer = journal(); writer.enqueue(evidence()); writer.waitUntilIdle()
        let path = try file()
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{broken}\n".utf8)); try handle.close()
        let before = try Data(contentsOf: path)
        let restarted = journal(); restarted.enqueue(evidence("next"))
        let saved = try await records(restarted)
        XCTAssertEqual(saved.count, 2)
        XCTAssertTrue(try Data(contentsOf: path).starts(with: before))
    }

    func testRetentionKeeps400UTCDaysAndNeverDeletesUnrelatedFiles() async throws {
        let old = now.addingTimeInterval(-400 * 86400)
        let boundary = now.addingTimeInterval(-399 * 86400)
        let oldWriter = journal(at: old); oldWriter.enqueue(evidence("old", at: old)); oldWriter.waitUntilIdle()
        let boundaryWriter = journal(at: boundary)
        boundaryWriter.enqueue(evidence("boundary", at: boundary)); boundaryWriter.waitUntilIdle()
        let unrelated = directory.appendingPathComponent("preserve.txt")
        try Data("synthetic".utf8).write(to: unrelated)
        let current = journal(); current.enqueue(evidence("current")); current.enqueue(evidence("expired", at: old))
        let saved = try await records(current)
        XCTAssertEqual(Set(saved.map(\.recordID)), ["boundary", "current"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testDiskFailureIsSanitizedDoesNotCrashAndRetryRecovers() async throws {
        try FileManager.default.removeItem(at: directory)
        try Data("synthetic-blocking-file".utf8).write(to: directory)
        var failures = [CarbohydrateAdviceJournalFailure]()
        let writer = journal(diagnostic: { failures.append($0) })
        writer.enqueue(evidence()); writer.waitUntilIdle()
        XCTAssertFalse(failures.isEmpty)
        do { _ = try await records(writer); XCTFail("IO failure must not become a successful empty history") }
        catch { XCTAssertTrue(error is CarbohydrateAdviceJournalFailure) }
        try FileManager.default.removeItem(at: directory)
        writer.enqueue(evidence())
        let saved = try await records(writer)
        XCTAssertEqual(saved.count, 1)
    }

    func testInvalidValuesFailWithoutConsumingRecordIdentity() async throws {
        var failures = [CarbohydrateAdviceJournalFailure]()
        let writer = journal(diagnostic: { failures.append($0) })
        writer.enqueue(evidence(grams: .nan))
        writer.enqueue(CarbohydrateAdviceEvidence(recordID: "invalid-date", event: .assessed,
            recordedAt: now, referenceDate: Date(timeIntervalSince1970: .nan),
            engineVersion: "synthetic-engine", status: "invalid"))
        writer.enqueue(evidence("invalid-point", points: [.init(date: now, glucoseMgdl: .infinity)]))
        writer.waitUntilIdle()
        writer.enqueue(evidence()); writer.waitUntilIdle()
        let saved = try await records(writer)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.estimatedGrams, 8)
        XCTAssertFalse(failures.isEmpty)
    }

    func testReadBoundsAreInclusiveExclusiveAndBackupRemainsEnabled() async throws {
        let writer = journal()
        writer.enqueue(evidence("first")); writer.enqueue(evidence("second", at: now.addingTimeInterval(60)))
        let saved = try await writer.records(from: now, to: now.addingTimeInterval(60))
        XCTAssertEqual(saved.map(\.recordID), ["first"])
        let values = try file().resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertNotEqual(values.isExcludedFromBackup, true)
        #if (os(iOS) || os(watchOS)) && !targetEnvironment(simulator)
        // Simulator storage does not expose real iOS Data Protection attributes.
        let attributes = try FileManager.default.attributesOfItem(atPath: try file().path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType,
                       .completeUntilFirstUserAuthentication)
        #endif
    }
}
