import XCTest
@testable import xdrip

final class WatchDeliveryEvidenceTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private var uptime: TimeInterval = 500

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = "WatchDeliveryEvidenceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        now = Date(timeIntervalSince1970: 1_800_000_000)
        uptime = 500
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func origin(device: String = "watch", build: String = "test4259", installation: UUID = UUID()) -> WatchDeliveryEvidenceOrigin {
        .init(device: device, installation: installation, process: UUID(), build: build, sourceCommit: "synthetic-test-sha")
    }

    private func store(origin: WatchDeliveryEvidenceOrigin? = nil,
                       limits: WatchDeliveryEvidenceStore.Limits = .init(),
                       append: ((Data, URL) throws -> Void)? = nil,
                       replace: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) -> WatchDeliveryEvidenceStore {
        WatchDeliveryEvidenceStore(directory: directory.appendingPathComponent("journal"), origin: origin ?? self.origin(),
            clock: { [unowned self] in self.now }, uptime: { [unowned self] in self.uptime },
            limits: limits, append: append, replace: replace)
    }

    private func reading(id: UUID = UUID(), session: UUID = UUID(), sensorMinute: UInt16 = 120) -> LibreWatchDirectReadingPayload {
        .init(id: id, sessionID: session, valueDomain: .factoryNativeMGDL, nativeGlucoseMGDL: 110,
            previousNativeGlucoseMGDL: 108, rawGlucose: 110, previousRawGlucose: 108,
            sensorTimeInMinutes: sensorMinute, receivedAt: now, calibrationRevision: 1)
    }

    func testDecodedFrameUsesSameExplicitIDThroughProductionPayloadAdapter() {
        let id = UUID(), session = UUID()
        let frame = Libre2WatchDirectReading(nativeGlucoseMGDL: 110, previousNativeGlucoseMGDL: 108,
            rawGlucose: 110, previousRawGlucose: 108, sensorTimeInMinutes: 120, receivedAt: now)
        let payload = frame.payload(id: id, sessionID: session, valueDomain: .factoryNativeMGDL, calibrationRevision: 1)
        let journal = store()
        journal.record(stage: .decoded, payloadID: id, sessionID: session, measuredAt: frame.receivedAt,
            sensorElapsedMinutes: frame.sensorTimeInMinutes)
        journal.recordReading(.accepted, reading: payload)
        XCTAssertEqual(journal.snapshot().events.map(\.payloadID), [id, id])
        XCTAssertEqual(journal.snapshot().events.map(\.sensorTime), [nil, nil])
        XCTAssertEqual(journal.snapshot().events.map(\.watchReceivedAt), [now, now])
    }

    func testActualAtomicOutboxSaveAndRestartAreIndependentOfDiagnosticJournal() throws {
        let payload = reading(), journal = store()
        let outboxURL = directory.appendingPathComponent("real-outbox.json")
        let fileStore = LibreWatchOutboxFileStore(fileURL: outboxURL, defaults: defaults)
        var outbox = try fileStore.load(at: now)
        let item = LibreWatchOutboxItem.reading(payload)
        XCTAssertTrue(outbox.enqueue(item, now: now))
        journal.recordReading(.accepted, reading: payload)
        XCTAssertFalse(journal.snapshot().events.contains { $0.stage == .localWriteConfirmed })
        try fileStore.save(outbox)
        WatchDeliveryEvidencePipeline.localWrite(true, item: item, store: journal)
        let restarted = LibreWatchOutboxFileStore(fileURL: outboxURL, defaults: defaults)
        XCTAssertEqual(try restarted.load(at: now).items.first?.reading?.id, payload.id)
        XCTAssertEqual(journal.snapshot().events.last?.stage, .localWriteConfirmed)
    }

    func testFailedOutboxWriteNeverAppearsAsConfirmedStorage() throws {
        let payload = reading(), journal = store()
        let fileStore = LibreWatchOutboxFileStore(fileURL: directory.appendingPathComponent("outbox.json"), defaults: defaults,
            writer: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        var outbox = try fileStore.load(at: now)
        let item = LibreWatchOutboxItem.reading(payload)
        XCTAssertTrue(outbox.enqueue(item, now: now))
        XCTAssertThrowsError(try fileStore.save(outbox))
        WatchDeliveryEvidencePipeline.localWrite(false, item: item, store: journal)
        XCTAssertEqual(outbox.items.first?.reading?.id, payload.id)
        XCTAssertEqual(journal.snapshot().events.map(\.stage), [.localWriteFailed])
    }

    func testJournalWriteFailureDoesNotChangeClinicalOutboxOrRecurse() {
        var appendCalls = 0
        let journal = store(append: { _, _ in appendCalls += 1; throw CocoaError(.fileWriteOutOfSpace) })
        let payload = reading(), item = LibreWatchOutboxItem.reading(reading())
        var outbox = LibreWatchConnectivityOutbox()
        XCTAssertTrue(outbox.enqueue(item, now: now))
        let before = outbox
        XCTAssertFalse(journal.recordReading(.accepted, reading: payload))
        XCTAssertEqual(appendCalls, 1)
        XCTAssertEqual(outbox, before)
        XCTAssertEqual(journal.snapshot().writeFailures, 1)
        XCTAssertTrue(journal.snapshot().events.isEmpty)
    }

    func testTruncatedFailedAppendIsRepairedBeforeNextEventAndRestart() throws {
        var fail = true
        let journal = store(append: { data, url in
            if fail {
                fail = false
                try data.prefix(12).write(to: url)
                throw CocoaError(.fileWriteOutOfSpace)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        })
        XCTAssertFalse(journal.recordReading(.decoded, reading: reading()))
        let kept = reading()
        XCTAssertTrue(journal.recordReading(.accepted, reading: kept))
        let restored = store()
        XCTAssertEqual(restored.snapshot().events.map(\.payloadID), [kept.id])
        XCTAssertEqual(restored.snapshot().writeFailures, 1)
    }

    func testFailedCompactionDoesNotAllowJournalToExceedCapacity() {
        var failRewrite = false
        let journal = store(limits: .init(age: 3600, events: 2, bytes: 50_000), replace: { data, url in
            if failRewrite && url.lastPathComponent == "delivery-events-v1.jsonl" { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        XCTAssertTrue(journal.recordReading(.decoded, reading: reading()))
        XCTAssertTrue(journal.recordReading(.accepted, reading: reading()))
        failRewrite = true
        XCTAssertFalse(journal.recordReading(.sendAttempt, reading: reading()))
        XCTAssertEqual(journal.snapshot().events.count, 2)
        XCTAssertEqual(journal.snapshot().rotatedEvents, 0)
        XCTAssertGreaterThan(journal.snapshot().writeFailures, 0)
    }

    func testPhoneStorageEvidenceWaitsForActualDurableCompletionAdapter() {
        let payload = reading(), journal = store(origin: origin(device: "phone"))
        journal.recordReading(.phoneReceived, reading: payload, outcome: "queuedUserInfo")
        XCTAssertEqual(journal.snapshot().events.map(\.stage), [.phoneReceived])
        WatchDeliveryEvidencePipeline.phoneStorage(false, outcome: .historyNotInserted, reading: payload, store: journal)
        WatchDeliveryEvidencePipeline.phoneStorage(true, outcome: .historicalInserted, reading: payload, store: journal)
        XCTAssertEqual(journal.snapshot().events.map(\.stage), [.phoneReceived, .phoneRejected, .phoneStored])
        XCTAssertEqual(journal.snapshot().events.last?.outcome, "historicalInserted")
    }

    func testLostReceiptAndDuplicatePreserveOriginalPayloadIDAndDeliveryPolicy() {
        let payload = reading(), journal = store(), item = LibreWatchOutboxItem.reading(reading())
        XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: true, outcome: .liveAccepted, durableReceipt: false))
        WatchDeliveryEvidencePipeline.acknowledgement(reading: payload, success: true, durable: false, outcome: "liveAccepted", store: journal)
        WatchDeliveryEvidencePipeline.acknowledgement(reading: payload, success: true, durable: true, outcome: "duplicate", store: journal)
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: true, outcome: .duplicate, durableReceipt: true))
        XCTAssertEqual(journal.snapshot().events.map(\.payloadID), [payload.id, payload.id])
        XCTAssertEqual(journal.snapshot().transportCounters["receipt.received.duplicate"], 1)
    }

    func testAcceptanceRejectionsExplainActualProductionPolicyWithoutChangingIt() {
        var policy = LibreWatchReadingAcceptancePolicy()
        let payload = reading()
        XCTAssertTrue(policy.accept(payload, for: payload.sessionID, now: now))
        XCTAssertFalse(policy.accept(payload, for: payload.sessionID, now: now))
        XCTAssertEqual(WatchDeliveryEvidencePipeline.rejection(of: payload, policy: policy, at: now), "duplicatePayloadID")
        let repeatedMinute = reading(session: payload.sessionID)
        XCTAssertFalse(policy.accept(repeatedMinute, for: payload.sessionID, now: now))
        XCTAssertEqual(WatchDeliveryEvidencePipeline.rejection(of: repeatedMinute, policy: policy, at: now), "nonIncreasingSensorMinute")
        XCTAssertEqual(WatchDeliveryEvidencePipeline.rejection(of: payload, policy: policy, at: now.addingTimeInterval(181)), "tooOld")
    }

    func testOriginProvenanceSurvivesRestartAndNewExporterBuild() {
        let oldOrigin = origin(build: "old-watch-build")
        let old = store(origin: oldOrigin)
        old.recordReading(.decoded, reading: reading())
        let newOrigin = origin(build: "new-watch-build", installation: oldOrigin.installation)
        let restarted = store(origin: newOrigin)
        restarted.recordReading(.accepted, reading: reading())
        let exported = restarted.snapshot()
        XCTAssertEqual(exported.origin.build, "new-watch-build")
        XCTAssertEqual(exported.events.map { $0.origin.build }, ["old-watch-build", "new-watch-build"])
        XCTAssertNotEqual(exported.events[0].origin.process, exported.events[1].origin.process)
    }

    func testWallClockAdjustmentDoesNotAlterRecordedMonotonicDuration() {
        let journal = store(), payload = reading()
        journal.recordReading(.decoded, reading: payload)
        now = now.addingTimeInterval(-300)
        uptime += 10
        journal.recordReading(.accepted, reading: payload)
        let events = journal.snapshot().events
        XCTAssertEqual(events[1].uptime - events[0].uptime, 10)
        XCTAssertEqual(events[1].at.timeIntervalSince(events[0].at), -300)
        XCTAssertTrue(journal.snapshot().clockNote.contains("offset is unknown"))
    }

    func testCapacityRotationReportsActualCoverageWithoutClaimingGlucoseLoss() {
        let journal = store(limits: .init(age: 3600, events: 4, bytes: 50_000))
        for _ in 0..<9 { journal.recordReading(.decoded, reading: reading()); now += 60; uptime += 60 }
        let snapshot = journal.snapshot()
        XCTAssertLessThanOrEqual(snapshot.events.count, 4)
        XCTAssertEqual(snapshot.rotatedEvents + UInt64(snapshot.events.count), 9)
        XCTAssertEqual(snapshot.firstRetainedAt, snapshot.events.first?.at)
        XCTAssertTrue(snapshot.coverageNote.contains("not lost glucose"))
    }

    func testAgePruningAndRestartRetainRotationCounts() {
        let journal = store(limits: .init(age: 60, events: 100, bytes: 50_000))
        journal.recordReading(.decoded, reading: reading())
        now += 61; uptime += 61
        XCTAssertTrue(journal.snapshot().events.isEmpty)
        XCTAssertEqual(journal.snapshot().rotatedEvents, 1)
        XCTAssertEqual(store(limits: .init(age: 60, events: 100, bytes: 50_000)).snapshot().rotatedEvents, 1)
    }

    func testCounterTicksDoNotAppendOrRepeatedlySerializeEventJournal() {
        var appended = 0, replacements = 0
        let journal = store(append: { _, _ in appended += 1 }, replace: { data, url in
            replacements += 1; try data.write(to: url, options: .atomic)
        })
        for _ in 0..<1000 { journal.recordTransport(stream: .status, action: "coalesced") }
        XCTAssertEqual(appended, 0)
        XCTAssertEqual(replacements, 1)
        uptime += 60
        journal.recordTransport(stream: .graph, action: "attempt")
        XCTAssertEqual(replacements, 2)
        XCTAssertEqual(journal.snapshot().transportCounters["status.coalesced.none"], 1000)
        XCTAssertEqual(journal.snapshot().transportCounters["graph.attempt.none"], 1)
    }

    func testCounterStreamsAreSeparatedAndCardinalityBounded() {
        let journal = store()
        for stream in [WatchDeliveryEvidenceStream.status, .graph, .agp, .session, .reading, .receipt, .diagnostic] {
            journal.recordTransport(stream: stream, action: "attempt")
        }
        for index in 0..<300 { journal.recordTransport(stream: .status, action: "failure\(index)") }
        let counters = journal.snapshot().transportCounters
        XCTAssertLessThanOrEqual(counters.count, 161)
        XCTAssertEqual(counters["session.attempt.none"], 1)
        XCTAssertEqual(counters["reading.attempt.none"], 1)
        XCTAssertNotNil(counters["overflow"])
    }

    func testManualSupportExportExplicitlyReportsMissingWatchMaterial() throws {
        let phone = store(origin: origin(device: "phone"))
        let transfer = WatchDeliveryEvidenceTransfer(directory: directory.appendingPathComponent("received"), defaults: defaults, store: phone)
        let data = transfer.supportData(store: phone)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue((json["missingMaterial"] as? String)?.contains("No local Watch snapshot") == true)
        XCTAssertNil(json["watch"])
    }

    func testManualTransferImportsLocalOfflineStagesBeforeDelegateReturns() throws {
        let watch = store(), payload = reading()
        watch.recordReading(.decoded, reading: payload)
        watch.recordReading(.accepted, reading: payload)
        WatchDeliveryEvidencePipeline.localWrite(true, item: .reading(payload), store: watch)
        let id = UUID(), file = try watch.exportFile(requestID: id)
        let transfer = WatchDeliveryEvidenceTransfer(directory: directory.appendingPathComponent("received"), defaults: defaults, store: watch)
        XCTAssertTrue(transfer.receive(fileURL: file, metadata: [WatchDeliveryEvidenceTransfer.fileKey: 1, WatchDeliveryEvidenceTransfer.requestIDKey: id.uuidString]))
        try FileManager.default.removeItem(at: file) // WCSession may remove its temporary file immediately.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: transfer.supportData(store: watch)) as? [String: Any])
        let imported = try XCTUnwrap(json["watch"] as? [String: Any])
        let events = try XCTUnwrap(imported["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events.last?["payloadID"] as? String, payload.id.uuidString)
        XCTAssertEqual(events.last?["stage"] as? String, "localWriteConfirmed")
    }

    func testDelayedOlderSupportFileCannotReplaceNewerSnapshot() throws {
        let watch = store()
        watch.recordReading(.decoded, reading: reading())
        let older = try watch.exportFile(requestID: UUID())
        now += 60; uptime += 60
        watch.recordReading(.accepted, reading: reading())
        let newer = try watch.exportFile(requestID: UUID())
        let transfer = WatchDeliveryEvidenceTransfer(directory: directory.appendingPathComponent("received"), defaults: defaults, store: watch)
        XCTAssertTrue(transfer.receive(fileURL: newer, metadata: [WatchDeliveryEvidenceTransfer.fileKey: 1]))
        XCTAssertTrue(transfer.receive(fileURL: older, metadata: [WatchDeliveryEvidenceTransfer.fileKey: 1]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: transfer.supportData(store: watch)) as? [String: Any])
        let imported = try XCTUnwrap(json["watch"] as? [String: Any])
        XCTAssertEqual((imported["events"] as? [Any])?.count, 2)
    }

    func testInvalidSupportFileDoesNotCreateFalseCompleteSnapshot() throws {
        let journal = store()
        let file = directory.appendingPathComponent("bad.json")
        try Data("{\"notOurJournal\":true}".utf8).write(to: file)
        let transfer = WatchDeliveryEvidenceTransfer(directory: directory.appendingPathComponent("received"), defaults: defaults, store: journal)
        XCTAssertTrue(transfer.receive(fileURL: file, metadata: [WatchDeliveryEvidenceTransfer.fileKey: 1]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: transfer.supportData(store: journal)) as? [String: Any])
        XCTAssertNil(json["watch"])
    }

    func testJournalContainsNoClinicalValuesOrRawSensorBytes() throws {
        let journal = store(), payload = reading()
        journal.recordReading(.decoded, reading: payload)
        let data = try journal.snapshotData()
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for forbidden in ["nativeGlucoseMGDL", "rawGlucose", "sensorUID", "patchInfo", "calibrationRevision", "token", "https:"] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
        XCTAssertTrue(text.contains(payload.id.uuidString))
        XCTAssertTrue(text.contains("sensorElapsedMinutes"))
    }
}
