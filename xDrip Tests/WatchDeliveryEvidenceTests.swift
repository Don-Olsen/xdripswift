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

    private func frameState(runtime: Bool, phase: String, generation: UUID = UUID()) -> WatchDeliveryEvidenceFrameState {
        .init(applicationState: runtime ? "active" : "inactive", runtimeRunning: runtime,
              connectionPhase: phase, peripheralState: phase == "receiving" ? "connected" : "connecting",
              connectionGeneration: generation)
    }

    func testFrameGapShowsNoInterveningNotificationsAndPersistsExecutionContext() throws {
        var tracker = LibreWatchFrameGapTracker()
        let before = frameState(runtime: true, phase: "receiving")
        let after = frameState(runtime: false, phase: "receiving")
        tracker.notification()
        XCTAssertNil(tracker.decoded(minute: 100, at: now, state: before))
        tracker.linkInterrupted()
        tracker.runtimeDidInvalidate()
        now += 180
        tracker.notification() // The single callback that decoded the later frame.
        let gap = try XCTUnwrap(tracker.decoded(minute: 103, at: now, state: after))
        XCTAssertEqual(gap.previousSensorElapsedMinutes, 100)
        XCTAssertEqual(gap.missingSensorMinutes, 2)
        XCTAssertEqual(gap.notificationCallbacks, 1)
        XCTAssertEqual(gap.partialFragments, 0)
        XCTAssertEqual(gap.linkInterruptions, 1)
        XCTAssertTrue(gap.runtimeInvalidated)
        XCTAssertEqual(gap.previousState, before)
        XCTAssertEqual(gap.currentState, after)

        let journal = store()
        XCTAssertTrue(journal.record(stage: .frameGap, sensorElapsedMinutes: 103,
            outcome: "missingDecodedSensorMinutes", stream: .diagnostic, frameGap: gap))
        let exported = try JSONEncoder().encode(journal.snapshot())
        let restored = try JSONDecoder().decode(WatchDeliveryEvidenceSnapshot.self, from: exported)
        XCTAssertEqual(restored.events.first?.frameGap, gap)
        XCTAssertEqual(restored.events.first?.stream, .diagnostic)
    }

    func testFrameGapDistinguishesAbandonedPartialAndDecodeFailureThenResets() throws {
        var tracker = LibreWatchFrameGapTracker()
        let state = frameState(runtime: false, phase: "receiving")
        XCTAssertNil(tracker.decoded(minute: 200, at: now, state: state))
        tracker.notification()
        tracker.partialFragment(at: now.addingTimeInterval(60))
        tracker.assemblerReset(hadPartial: true)
        tracker.notification()
        tracker.notificationError()
        tracker.assemblyFailure()
        tracker.decodeFailure()
        tracker.notification()
        let gap = try XCTUnwrap(tracker.decoded(minute: 203, at: now.addingTimeInterval(180), state: state))
        XCTAssertEqual(gap.notificationCallbacks, 3)
        XCTAssertEqual(gap.partialFragments, 1)
        XCTAssertEqual(gap.abandonedPartialFrames, 1)
        XCTAssertEqual(gap.notificationErrors, 1)
        XCTAssertEqual(gap.assemblyFailures, 1)
        XCTAssertEqual(gap.decodeFailures, 1)
        tracker.notification()
        XCTAssertNil(tracker.decoded(minute: 204, at: now.addingTimeInterval(240), state: state))
        tracker.notification()
        XCTAssertNil(tracker.decoded(minute: 202, at: now.addingTimeInterval(300), state: state))
        tracker.notification()
        let next = try XCTUnwrap(tracker.decoded(minute: 206, at: now.addingTimeInterval(360), state: state))
        XCTAssertEqual(next.previousSensorElapsedMinutes, 204)
        XCTAssertEqual(next.missingSensorMinutes, 1)
        XCTAssertEqual(next.notificationCallbacks, 2)
        XCTAssertEqual(next.partialFragments, 0)
        XCTAssertEqual(next.decodeFailures, 0)
    }

    func testDuplicateAndOlderDecodedMinutesPreserveGapBaselineAndCallbacks() throws {
        var tracker = LibreWatchFrameGapTracker()
        let state = frameState(runtime: false, phase: "receiving")
        XCTAssertNil(tracker.decoded(minute: 100, at: now, state: state))
        tracker.linkInterrupted()
        tracker.notification()
        XCTAssertNil(tracker.decoded(minute: 100, at: now.addingTimeInterval(60), state: state))
        tracker.notification()
        XCTAssertNil(tracker.decoded(minute: 90, at: now.addingTimeInterval(90), state: state))
        tracker.notification()
        let gap = try XCTUnwrap(tracker.decoded(minute: 102, at: now.addingTimeInterval(120), state: state))
        XCTAssertEqual(gap.previousDecodedAt, now)
        XCTAssertEqual(gap.previousSensorElapsedMinutes, 100)
        XCTAssertEqual(gap.missingSensorMinutes, 1)
        XCTAssertEqual(gap.notificationCallbacks, 3)
        XCTAssertEqual(gap.linkInterruptions, 1)
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

    private var journalFile: URL { directory.appendingPathComponent("journal/delivery-events-v1.jsonl") }
    private var repairSourceFile: URL { directory.appendingPathComponent("journal/delivery-events-v1.pre-repair.jsonl") }

    /// Intentionally uses the released iPhone overload to reproduce the on-device format.
    private func legacyJournal(_ events: [WatchDeliveryEvidenceEvent]) throws -> Data {
        var data = Data()
        for event in events {
            data.append(try JSONEncoder().encode(event))
            data.append(0x0a)
        }
        return data
    }

    func testProductionJournalRetainsMultipleEventsAcrossTwoRestarts() throws {
        let payload = reading(), first = store(origin: origin(device: "phone"))
        for stage in [WatchDeliveryEvidenceStage.phoneReceived, .phoneStored, .sendAttempt] {
            XCTAssertTrue(first.recordReading(stage, reading: payload))
        }
        let second = store(origin: origin(device: "phone"))
        XCTAssertEqual(second.snapshot().events.map(\.stage), [.phoneReceived, .phoneStored, .sendAttempt])
        XCTAssertTrue(second.recordReading(.acknowledgement, reading: payload, stream: .receipt))
        let third = store(origin: origin(device: "phone")), snapshot = third.snapshot()
        XCTAssertEqual(snapshot.events.map(\.sequence), [1, 2, 3, 4])
        XCTAssertEqual(snapshot.events.map(\.payloadID), [payload.id, payload.id, payload.id, payload.id])
        XCTAssertEqual(snapshot.unreadableLines, 0)
        XCTAssertEqual(snapshot.rotatedEvents, 0)
        XCTAssertEqual(snapshot.recoveredLegacyEvents, 0)
        let data = try Data(contentsOf: journalFile)
        XCTAssertFalse(data.contains(0))
        XCTAssertEqual(data.filter { $0 == 0x0a }.count, 4)
        XCTAssertEqual(data.last, UInt8(0x0a))
        XCTAssertFalse(FileManager.default.fileExists(atPath: repairSourceFile.path))
    }

    func testKnownLegacyPaddingMigratesOnceAndPreservesRawSourceAndOriginalProvenance() throws {
        let oldOrigin = origin(device: "phone", build: "4261"), initial = store(origin: oldOrigin)
        for stage in [WatchDeliveryEvidenceStage.phoneReceived, .phoneStored, .acknowledgement] {
            XCTAssertTrue(initial.recordReading(stage, reading: reading()))
        }
        let originalEvents = initial.snapshot().events
        let legacy = try legacyJournal(originalEvents)
        XCTAssertEqual(legacy.suffix(7), Data(repeating: 0, count: 7))
        try legacy.write(to: journalFile)

        // Simulate the existing v1 metadata, preserving prior error and rotation evidence.
        let metadataFile = directory.appendingPathComponent("journal/delivery-metadata-v1.json")
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataFile)) as? [String: Any])
        metadata.removeValue(forKey: "recoveredLegacyEvents")
        metadata.removeValue(forKey: "preservedRepairSourceBytes")
        metadata["unreadable"] = 828
        metadata["rotated"] = 12
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataFile)

        let migrated = store(origin: origin(device: "phone", build: "new-test-build"))
        let snapshot = migrated.snapshot()
        XCTAssertEqual(snapshot.events, originalEvents)
        XCTAssertEqual(snapshot.events.map(\.origin), [oldOrigin, oldOrigin, oldOrigin])
        XCTAssertEqual(snapshot.recoveredLegacyEvents, 2) // First row was already readable.
        XCTAssertEqual(snapshot.unreadableLines, 828)
        XCTAssertEqual(snapshot.rotatedEvents, 12)
        XCTAssertEqual(snapshot.preservedRepairSourceBytes, legacy.count)
        XCTAssertEqual(try Data(contentsOf: repairSourceFile), legacy)
        XCTAssertFalse(try Data(contentsOf: journalFile).contains(0))

        XCTAssertTrue(migrated.recordReading(.sendAttempt, reading: reading()))
        let restarted = store(), again = restarted.snapshot()
        XCTAssertEqual(again.events.map(\.sequence), [1, 2, 3, 4])
        XCTAssertEqual(again.recoveredLegacyEvents, 2)
        XCTAssertEqual(again.unreadableLines, 828)
        XCTAssertEqual(again.rotatedEvents, 12)
        XCTAssertEqual(try Data(contentsOf: repairSourceFile), legacy)
        XCTAssertTrue(again.coverageNote.contains("not included in this export"))
    }

    func testLegacyPaddingDoesNotMakeMalformedOrArbitraryNullPaddedJSONValid() throws {
        let initial = store()
        XCTAssertTrue(initial.recordReading(.decoded, reading: reading()))
        let event = try XCTUnwrap(initial.snapshot().events.first)
        let json = try JSONEncoder().encode(event)
        var raw = json
        raw.append(UInt8(0x0a))
        raw.append(Data(repeating: 0, count: 3)) // Not the released seven-byte padding.
        raw.append(json)
        raw.append(UInt8(0x0a))
        raw.append(Data(repeating: 0, count: 7))
        raw.append(Data("{broken".utf8))
        raw.append(UInt8(0x0a))
        raw.append(Data(repeating: 0, count: 8)) // Do not strip an arbitrary number of NULs.
        raw.append(json)
        raw.append(UInt8(0x0a))
        try raw.write(to: journalFile)

        let repaired = store(), snapshot = repaired.snapshot()
        XCTAssertEqual(snapshot.events, [event])
        XCTAssertEqual(snapshot.unreadableLines, 3)
        XCTAssertEqual(snapshot.recoveredLegacyEvents, 0)
        XCTAssertEqual(snapshot.rotatedEvents, 0)
        XCTAssertEqual(try Data(contentsOf: repairSourceFile), raw)
        XCTAssertEqual(store().snapshot().unreadableLines, 3)
    }

    func testLegacyRecoveryRequiresAnObservedNewlineBeforePadding() throws {
        let initial = store()
        XCTAssertTrue(initial.recordReading(.decoded, reading: reading()))
        let event = try XCTUnwrap(initial.snapshot().events.first)
        var raw = Data(repeating: 0, count: 7)
        raw.append(try JSONEncoder().encode(event))
        raw.append(UInt8(0x0a))
        try raw.write(to: journalFile)
        let snapshot = store().snapshot()
        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertEqual(snapshot.unreadableLines, 1)
        XCTAssertEqual(snapshot.recoveredLegacyEvents, 0)
        XCTAssertEqual(try Data(contentsOf: repairSourceFile), raw)
    }

    func testRepairDoesNotOverwriteFirstRawSourceOnLaterCorruption() throws {
        let initial = store()
        XCTAssertTrue(initial.recordReading(.decoded, reading: reading()))
        let legacy = try legacyJournal(initial.snapshot().events)
        try legacy.write(to: journalFile)
        let migrated = store()
        XCTAssertEqual(migrated.snapshot().events.count, 1)
        var damaged = try Data(contentsOf: journalFile)
        damaged.append(Data("bad later line\n".utf8))
        try damaged.write(to: journalFile)
        let snapshot = store().snapshot()
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.unreadableLines, 1)
        XCTAssertEqual(try Data(contentsOf: repairSourceFile), legacy)
        XCTAssertTrue(snapshot.coverageNote.contains("Later damaged raw sources are not archived"))
    }

    func testFailedRawPreservationPreventsDestructiveRepairAndAppend() throws {
        let initial = store()
        XCTAssertTrue(initial.recordReading(.decoded, reading: reading()))
        let legacy = try legacyJournal(initial.snapshot().events)
        try legacy.write(to: journalFile)
        var failPreservation = true
        let migrated = store(replace: { data, url in
            if failPreservation && url.lastPathComponent == "delivery-events-v1.pre-repair.jsonl" {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: .atomic)
        })
        XCTAssertFalse(migrated.recordReading(.accepted, reading: reading()))
        XCTAssertEqual(try Data(contentsOf: journalFile), legacy)
        XCTAssertGreaterThan(migrated.snapshot().writeFailures, 0)
        XCTAssertNil(migrated.snapshot().preservedRepairSourceBytes)
        failPreservation = false
        XCTAssertTrue(migrated.recordReading(.accepted, reading: reading()))
        XCTAssertEqual(try Data(contentsOf: repairSourceFile), legacy)
        XCTAssertEqual(store().snapshot().events.map(\.sequence), [1, 2])
    }

    func testOversizedSourceIsNotDestroyedOrCopiedByRepair() throws {
        _ = store(limits: .init(age: 3600, events: 4, bytes: 1000))
        let oversized = Data(repeating: 0x20, count: 16_385)
        try oversized.write(to: journalFile)
        let journal = store(limits: .init(age: 3600, events: 4, bytes: 1000))
        XCTAssertFalse(journal.recordReading(.decoded, reading: reading()))
        XCTAssertEqual(try Data(contentsOf: journalFile), oversized)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repairSourceFile.path))
        XCTAssertGreaterThan(journal.snapshot().writeFailures, 0)
    }

    func testFailedMigrationDoesNotPersistSuccessfulRecoveryCountBeforeRewrite() throws {
        let initial = store()
        XCTAssertTrue(initial.recordReading(.decoded, reading: reading()))
        XCTAssertTrue(initial.recordReading(.accepted, reading: reading()))
        let legacy = try legacyJournal(initial.snapshot().events)
        try legacy.write(to: journalFile)
        let failed = store(replace: { data, url in
            if url.lastPathComponent == "delivery-events-v1.jsonl" { throw CocoaError(.fileWriteOutOfSpace) }
            try data.write(to: url, options: .atomic)
        })
        XCTAssertEqual(failed.snapshot().events.count, 2)
        XCTAssertEqual(failed.snapshot().recoveredLegacyEvents, 0)
        XCTAssertEqual(try Data(contentsOf: journalFile), legacy)
        XCTAssertEqual(store().snapshot().recoveredLegacyEvents, 1)
        XCTAssertEqual(store().snapshot().recoveredLegacyEvents, 1)
    }

    func testMigrationThenCapacityRotationKeepsCoverageAcrossTwoRestarts() throws {
        let limits = WatchDeliveryEvidenceStore.Limits(age: 3600, events: 4, bytes: 50_000)
        let initial = store(limits: limits)
        for _ in 0..<4 {
            XCTAssertTrue(initial.recordReading(.decoded, reading: reading()))
            now += 1; uptime += 1
        }
        let legacy = try legacyJournal(initial.snapshot().events)
        try legacy.write(to: journalFile)
        let migrated = store(limits: limits)
        XCTAssertTrue(migrated.recordReading(.accepted, reading: reading()))
        let first = migrated.snapshot(), restarted = store(limits: limits).snapshot()
        XCTAssertEqual(first.events.map(\.sequence), [2, 3, 4, 5])
        XCTAssertEqual(restarted.events, first.events)
        XCTAssertEqual(restarted.rotatedEvents, 1)
        XCTAssertEqual(restarted.recoveredLegacyEvents, 3)
        XCTAssertEqual(restarted.unreadableLines, 0)
        XCTAssertEqual(restarted.firstRetainedAt, restarted.events.first?.at)
        XCTAssertEqual(restarted.lastRetainedAt, restarted.events.last?.at)
        XCTAssertEqual(try Data(contentsOf: repairSourceFile), legacy)
    }

    func testOlderSnapshotWithoutRepairFieldsStillDecodes() throws {
        let journal = store()
        XCTAssertTrue(journal.recordReading(.decoded, reading: reading()))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: journal.snapshotData()) as? [String: Any])
        json.removeValue(forKey: "recoveredLegacyEvents")
        json.removeValue(forKey: "preservedRepairSourceBytes")
        let decoded = try JSONDecoder().decode(WatchDeliveryEvidenceSnapshot.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.events.count, 1)
        XCTAssertNil(decoded.recoveredLegacyEvents)
        XCTAssertNil(decoded.preservedRepairSourceBytes)
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
