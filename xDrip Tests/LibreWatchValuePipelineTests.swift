import XCTest
import CoreData
import HealthKit
import Combine
@testable import xdrip

extension LibreWatchValuePipelineTests {
    func testPhoneStatusPreservesIndependentlyConfiguredFiniteChartThresholds() throws {
        let (defaults, suite) = displaySnapshotDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var status = displayStatusSnapshot(at: now)
        status["urgentLowLimitInMgDl"] = 90.0
        status["lowLimitInMgDl"] = 80.0
        status["highLimitInMgDl"] = 0.0
        status["urgentHighLimitInMgDl"] = -1.0
        XCTAssertTrue(WatchPhoneSnapshotStore.accept(status, stream: .status, sessionID: nil, at: now, defaults: defaults))
        let saved = try XCTUnwrap(WatchPhoneSnapshotStore.stored(.status, defaults: defaults))
        XCTAssertEqual(saved["urgentLowLimitInMgDl"] as? Double, 90)
        XCTAssertEqual(saved["lowLimitInMgDl"] as? Double, 80)
        XCTAssertEqual(saved["highLimitInMgDl"] as? Double, 0)
        XCTAssertEqual(saved["urgentHighLimitInMgDl"] as? Double, -1)
        let invalidThresholds: [Any] = [Double.nan, Double.infinity, true, "80"]
        for invalid in invalidThresholds {
            var malformed = status
            malformed["generatedAt"] = now.addingTimeInterval(1).timeIntervalSince1970
            malformed["lowLimitInMgDl"] = invalid
            XCTAssertFalse(WatchPhoneSnapshotStore.accept(malformed, stream: .status, sessionID: nil, at: now, defaults: defaults))
        }
        XCTAssertEqual(WatchPhoneSnapshotStore.stored(.status, defaults: defaults)?["lowLimitInMgDl"] as? Double, 80)
    }

    func testUnscopedReinstalledPhoneSnapshotRequiresExplicitPhoneOwnedOptIn() {
        let (watch, watchSuite) = displaySnapshotDefaults()
        let (newPhone, phoneSuite) = displaySnapshotDefaults()
        defer { watch.removePersistentDomain(forName: watchSuite); newPhone.removePersistentDomain(forName: phoneSuite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let retainedWatchSession = UUID()
        let earlier = now.addingTimeInterval(-10)
        let previous = displayBGSnapshot(at: earlier, generation:
            WatchPhoneSnapshotStore.nextGeneration(sessionID: retainedWatchSession, at: earlier, defaults: watch))
        XCTAssertTrue(WatchPhoneSnapshotStore.accept(previous, stream: .bgReadings,
            sessionID: retainedWatchSession, at: now, defaults: watch))

        for stream in WatchPhoneSnapshotStore.Stream.allCases {
            let generation = WatchPhoneSnapshotStore.nextGeneration(sessionID: nil, at: now, defaults: newPhone)
            let unscoped = stream == .bgReadings
                ? displayBGSnapshot(at: now, generation: generation)
                : displayStatusSnapshot(at: now, generation: generation)
            // Default/Watch-owned validation stays strict, including after a new installation.
            XCTAssertFalse(WatchPhoneSnapshotStore.isValid(unscoped, stream: stream,
                sessionID: retainedWatchSession, at: now))
            XCTAssertFalse(WatchPhoneSnapshotStore.accept(unscoped, stream: stream,
                sessionID: retainedWatchSession, at: now, defaults: watch))
            XCTAssertFalse(WatchPhoneSnapshotStore.accept(unscoped, stream: stream,
                sessionID: retainedWatchSession, allowUnscopedPhoneSession: false, at: now, defaults: watch))
            // WatchStateModel supplies true only for its already-committed .iphone owner.
            XCTAssertTrue(WatchPhoneSnapshotStore.isValid(unscoped, stream: stream,
                sessionID: retainedWatchSession, allowUnscopedPhoneSession: true, at: now))
            XCTAssertTrue(WatchPhoneSnapshotStore.accept(unscoped, stream: stream,
                sessionID: retainedWatchSession, allowUnscopedPhoneSession: true, at: now, defaults: watch))
        }
        let differentSession = displayBGSnapshot(at: now, generation:
            WatchPhoneSnapshotStore.nextGeneration(sessionID: UUID(), at: now, defaults: newPhone))
        XCTAssertFalse(WatchPhoneSnapshotStore.isValid(differentSession, stream: .bgReadings,
            sessionID: retainedWatchSession, allowUnscopedPhoneSession: true, at: now))
        XCTAssertFalse(WatchPhoneSnapshotStore.accept(differentSession, stream: .bgReadings,
            sessionID: retainedWatchSession, allowUnscopedPhoneSession: true, at: now, defaults: watch))
        XCTAssertFalse(WatchPhoneSnapshotStore.accept(previous, stream: .bgReadings,
            sessionID: retainedWatchSession, allowUnscopedPhoneSession: true, at: now, defaults: watch))
    }
}

// Tests exercise the production shared storage/validation/expiry helpers, not a copied policy.
extension LibreWatchValuePipelineTests {
    private func displaySnapshotDefaults() -> (UserDefaults, String) {
        let suite = "WatchPhoneSnapshotTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    private func displayBGSnapshot(at date: Date, value: Double = 123,
                                   generation: [String: Any]? = nil) -> [String: Any] {
        let payload: [String: Any] = ["generatedAt": date.timeIntervalSince1970,
            "bgReadingValues": [value, 120.0],
            "bgReadingDatesAsDouble": [date.timeIntervalSince1970 - 10, date.timeIntervalSince1970 - 70],
            "slopeOrdinal": 4, "deltaValueInUserUnit": 3.0]
        return generation.map { WatchPhoneSnapshotStore.attaching($0, to: payload) } ?? payload
    }

    private func displayStatusSnapshot(at date: Date, generation: [String: Any]? = nil) -> [String: Any] {
        let payload: [String: Any] = ["generatedAt": date.timeIntervalSince1970,
            "isMgDl": true, "isMaster": true, "keepAliveIsDisabled": false,
            "urgentLowLimitInMgDl": 60.0, "lowLimitInMgDl": 80.0,
            "highLimitInMgDl": 170.0, "urgentHighLimitInMgDl": 250.0,
            "sensorAgeInMinutes": 100.0, "sensorMaxAgeInMinutes": 14400.0]
        return generation.map { WatchPhoneSnapshotStore.attaching($0, to: payload) } ?? payload
    }

    func testDisplayedDirectProvenanceKeepsThreeMinuteExpiryAcrossPersistence() throws {
        let measuredAt = Date(timeIntervalSince1970: 1_800_000_000)
        var cached = ComplicationSharedUserDefaultsModel(bgReadingValues: [123],
            bgReadingDatesAsDouble: [measuredAt.timeIntervalSince1970], isMgDl: true,
            slopeOrdinal: 4, deltaValueInUserUnit: 3, urgentLowLimitInMgDl: 60,
            lowLimitInMgDl: 80, highLimitInMgDl: 170, urgentHighLimitInMgDl: 250,
            keepAliveIsDisabled: false, readingSource: .directLibre)
        // Physical ownership is deliberately absent from the measurement expiry model.
        let restored = try XCTUnwrap(ComplicationSharedUserDefaultsModel.decodeStoredData(JSONEncoder().encode(cached)))
        XCTAssertEqual(restored.latestReadingDate, measuredAt)
        XCTAssertEqual(restored.readingSource, .directLibre)
        XCTAssertTrue(restored.readingIsCurrent(at: measuredAt.addingTimeInterval(180)))
        XCTAssertFalse(restored.readingIsCurrent(at: measuredAt.addingTimeInterval(181)))
        XCTAssertFalse(ComplicationReadingSource.directLibre.isCurrent(measuredAt: measuredAt, at: measuredAt.addingTimeInterval(181)))
        cached.readingSource = .phone // A validated phone replacement uses its own source window.
        XCTAssertTrue(cached.readingIsCurrent(at: measuredAt.addingTimeInterval(181)))
    }

    func testPhoneBGRejectsOutOfOrderAndAllowsNewerSnapshotCorrection() throws {
        let (defaults, suite) = displaySnapshotDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = displayBGSnapshot(at: now.addingTimeInterval(-5), generation:
            WatchPhoneSnapshotStore.nextGeneration(sessionID: nil, at: now.addingTimeInterval(-5), defaults: defaults))
        let b = displayBGSnapshot(at: now, generation:
            WatchPhoneSnapshotStore.nextGeneration(sessionID: nil, at: now, defaults: defaults))
        XCTAssertTrue(WatchPhoneSnapshotStore.accept(b, stream: .bgReadings, sessionID: nil, at: now, defaults: defaults))
        XCTAssertFalse(WatchPhoneSnapshotStore.accept(a, stream: .bgReadings, sessionID: nil, at: now, defaults: defaults))
        var correction = displayBGSnapshot(at: now, value: 125, generation:
            WatchPhoneSnapshotStore.nextGeneration(sessionID: nil, at: now, defaults: defaults))
        correction["generatedAt"] = now.addingTimeInterval(1).timeIntervalSince1970
        XCTAssertTrue(WatchPhoneSnapshotStore.accept(correction, stream: .bgReadings, sessionID: nil, at: now, defaults: defaults))
        XCTAssertEqual((WatchPhoneSnapshotStore.stored(.bgReadings, defaults: defaults)?["bgReadingValues"] as? [Double])?.first, 125)
        XCTAssertFalse(WatchPhoneSnapshotStore.accept(correction, stream: .bgReadings, sessionID: nil, at: now, defaults: defaults))
    }

    func testStatusOrderingDoesNotConsumeIndependentBGWatermark() {
        let (defaults, suite) = displaySnapshotDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bg = displayBGSnapshot(at: now.addingTimeInterval(-10), generation:
            WatchPhoneSnapshotStore.nextGeneration(sessionID: nil, at: now.addingTimeInterval(-10), defaults: defaults))
        let a = displayStatusSnapshot(at: now.addingTimeInterval(-5), generation:
            WatchPhoneSnapshotStore.nextGeneration(sessionID: nil, at: now.addingTimeInterval(-5), defaults: defaults))
        let b = displayStatusSnapshot(at: now, generation:
            WatchPhoneSnapshotStore.nextGeneration(sessionID: nil, at: now, defaults: defaults))
        XCTAssertTrue(WatchPhoneSnapshotStore.accept(b, stream: .status, sessionID: nil, at: now, defaults: defaults))
        XCTAssertFalse(WatchPhoneSnapshotStore.accept(a, stream: .status, sessionID: nil, at: now, defaults: defaults))
        XCTAssertTrue(WatchPhoneSnapshotStore.accept(bg, stream: .bgReadings, sessionID: nil, at: now, defaults: defaults))
    }

    func testPhoneSnapshotAndWatermarkRestoreTogetherAfterRestart() throws {
        let (defaults, suite) = displaySnapshotDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let firstGeneration = WatchPhoneSnapshotStore.nextGeneration(sessionID: nil, at: now, defaults: defaults)
        let bg = displayBGSnapshot(at: now, value: 147, generation: firstGeneration)
        XCTAssertTrue(WatchPhoneSnapshotStore.accept(bg, stream: .bgReadings, sessionID: nil, at: now, defaults: defaults))
        let restarted = try XCTUnwrap(UserDefaults(suiteName: suite))
        let restored = try XCTUnwrap(WatchPhoneSnapshotStore.stored(.bgReadings, defaults: restarted))
        XCTAssertTrue(WatchPhoneSnapshotStore.isValid(restored, stream: .bgReadings, sessionID: nil, at: now))
        XCTAssertEqual(restored["bgReadingValues"] as? [Double], [147, 120])
        XCTAssertFalse(WatchPhoneSnapshotStore.accept(bg, stream: .bgReadings, sessionID: nil, at: now, defaults: restarted))
        let next = WatchPhoneSnapshotStore.nextGeneration(sessionID: nil, at: now, defaults: restarted)
        XCTAssertEqual(next["installationID"] as? String, firstGeneration["installationID"] as? String)
        XCTAssertEqual(next["revision"] as? String, "2")
    }

    func testNewPhoneInstallationRetiresOldSnapshotsAcrossBothStreams() throws {
        let (watch, watchSuite) = displaySnapshotDefaults()
        let (newPhone, phoneSuite) = displaySnapshotDefaults()
        defer { watch.removePersistentDomain(forName: watchSuite); newPhone.removePersistentDomain(forName: phoneSuite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = displayBGSnapshot(at: now, generation:
            WatchPhoneSnapshotStore.nextGeneration(sessionID: nil, at: now, defaults: watch))
        XCTAssertTrue(WatchPhoneSnapshotStore.accept(old, stream: .bgReadings, sessionID: nil, at: now, defaults: watch))
        let later = now.addingTimeInterval(10)
        let newStatus = displayStatusSnapshot(at: later, generation:
            WatchPhoneSnapshotStore.nextGeneration(sessionID: nil, at: later, defaults: newPhone))
        XCTAssertTrue(WatchPhoneSnapshotStore.accept(newStatus, stream: .status, sessionID: nil, at: later, defaults: watch))
        XCTAssertNil(WatchPhoneSnapshotStore.stored(.bgReadings, defaults: watch))
        let oldPhoneDelayed = displayBGSnapshot(at: later, generation:
            WatchPhoneSnapshotStore.nextGeneration(sessionID: nil, at: later, defaults: watch))
        XCTAssertFalse(WatchPhoneSnapshotStore.accept(oldPhoneDelayed, stream: .bgReadings, sessionID: nil, at: later, defaults: watch))
        let newBG = displayBGSnapshot(at: later, generation:
            WatchPhoneSnapshotStore.nextGeneration(sessionID: nil, at: later, defaults: newPhone))
        XCTAssertTrue(WatchPhoneSnapshotStore.accept(newBG, stream: .bgReadings, sessionID: nil, at: later, defaults: watch))
    }

    func testSnapshotSessionChangeRejectsPriorSensorSession() {
        let (defaults, suite) = displaySnapshotDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldSession = UUID(), newSession = UUID()
        let old = displayBGSnapshot(at: now, generation:
            WatchPhoneSnapshotStore.nextGeneration(sessionID: oldSession, at: now, defaults: defaults))
        let current = displayBGSnapshot(at: now, generation:
            WatchPhoneSnapshotStore.nextGeneration(sessionID: newSession, at: now, defaults: defaults))
        XCTAssertFalse(WatchPhoneSnapshotStore.accept(old, stream: .bgReadings, sessionID: newSession, at: now, defaults: defaults))
        XCTAssertTrue(WatchPhoneSnapshotStore.accept(current, stream: .bgReadings, sessionID: newSession, at: now, defaults: defaults))
        XCTAssertFalse(WatchPhoneSnapshotStore.isValid(current, stream: .bgReadings, sessionID: nil, at: now))
    }

    func testLegacySnapshotsRemainMonotonicAndCannotDowngradeVersionedPhone() {
        let (defaults, suite) = displaySnapshotDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let a = displayBGSnapshot(at: now.addingTimeInterval(-10))
        let b = displayBGSnapshot(at: now.addingTimeInterval(-5))
        XCTAssertTrue(WatchPhoneSnapshotStore.accept(b, stream: .bgReadings, sessionID: nil, at: now, defaults: defaults))
        XCTAssertFalse(WatchPhoneSnapshotStore.accept(a, stream: .bgReadings, sessionID: nil, at: now, defaults: defaults))
        let versioned = displayBGSnapshot(at: now, generation:
            WatchPhoneSnapshotStore.nextGeneration(sessionID: nil, at: now, defaults: defaults))
        XCTAssertTrue(WatchPhoneSnapshotStore.accept(versioned, stream: .bgReadings, sessionID: nil, at: now, defaults: defaults))
        XCTAssertFalse(WatchPhoneSnapshotStore.accept(displayBGSnapshot(at: now.addingTimeInterval(1)), stream: .bgReadings,
            sessionID: nil, at: now, defaults: defaults))
        XCTAssertFalse(WatchPhoneSnapshotStore.accept(displayStatusSnapshot(at: now), stream: .status,
            sessionID: nil, at: now, defaults: defaults))
    }

    func testInvalidPhoneArraysNeverAdvanceSnapshotOrInventGlucose() {
        let (defaults, suite) = displaySnapshotDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let valid = displayBGSnapshot(at: now)
        var missing = valid; missing.removeValue(forKey: "bgReadingValues")
        var mismatch = valid; mismatch["bgReadingValues"] = [123.0]
        var empty = valid; empty["bgReadingValues"] = [Double](); empty["bgReadingDatesAsDouble"] = [Double]()
        var nonfinite = valid; nonfinite["bgReadingValues"] = [Double.nan, 120]
        var future = valid; future["bgReadingDatesAsDouble"] = [now.timeIntervalSince1970 + 21, now.timeIntervalSince1970]
        var unsorted = valid; unsorted["bgReadingDatesAsDouble"] = [now.timeIntervalSince1970 - 70, now.timeIntervalSince1970 - 10]
        var boolean = valid; boolean["bgReadingValues"] = [true, false]
        for bad in [missing, mismatch, empty, nonfinite, future, unsorted, boolean] {
            XCTAssertFalse(WatchPhoneSnapshotStore.accept(bad, stream: .bgReadings, sessionID: nil, at: now, defaults: defaults))
            XCTAssertNil(WatchPhoneSnapshotStore.stored(.bgReadings, defaults: defaults))
        }
        XCTAssertFalse(WatchPhoneSnapshotStore.accept(valid, stream: .bgReadings, sessionID: nil,
            displayedReadingDate: now, at: now, defaults: defaults))
        XCTAssertTrue(WatchPhoneSnapshotStore.accept(valid, stream: .bgReadings, sessionID: nil, at: now, defaults: defaults))
    }
}

private final class LibreWatchOwnershipPublicationFixture {
    @Published var ownership: LibreWatchOwnership = .iphone
}

extension LibreWatchValuePipelineTests {
    func testSubmittedPhoneReturnKeepsUnknownOutcomeAndCutoffThroughRestart() throws {
        let (defaults, suite) = displaySnapshotDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var pending = LibreWatchPhoneReturnTransaction(session: session, cutoff: receivedAt, startingRevision: 11)
        pending.wasSubmitted = true
        LibreWatchSessionStore.saveSession(session, defaults: defaults)
        LibreWatchSessionStore.saveOwnership(.releasingToPhone, defaults: defaults)
        LibreWatchSessionStore.savePhoneReturn(pending, defaults: defaults)
        let restarted = try XCTUnwrap(UserDefaults(suiteName: suite))
        let restored = try XCTUnwrap(LibreWatchSessionStore.loadPhoneReturn(defaults: restarted))
        XCTAssertEqual(restored, pending)
        for _ in 0..<4 {
            XCTAssertEqual(restored.resolution(for: .unknown,
                currentSession: LibreWatchSessionStore.loadSession(defaults: restarted),
                ownership: LibreWatchSessionStore.loadOwnership(defaults: restarted), acceptedRevision: 11), .pending)
            XCTAssertEqual(restored.resolution(for: .notSent, currentSession: session,
                ownership: .releasingToPhone, acceptedRevision: 11), .pending)
        }
        XCTAssertEqual(restored.cutoff, receivedAt)
        XCTAssertEqual(restored.id, pending.id)
    }

    func testPhoneReturnRequiresDefiniteResponseOrNewerAuthoritativePhoneOwner() {
        var pending = LibreWatchPhoneReturnTransaction(session: session, cutoff: receivedAt, startingRevision: 11)
        XCTAssertEqual(pending.resolution(for: .notSent, currentSession: session,
            ownership: .releasingToPhone, acceptedRevision: 11), .watch, "Nothing was submitted: local retry is safe")
        pending.wasSubmitted = true
        XCTAssertEqual(pending.resolution(for: .unknown, currentSession: session,
            ownership: .releasingToPhone, acceptedRevision: 99), .pending, "A revision alone is not a release receipt")
        XCTAssertEqual(pending.resolution(for: .unknown, currentSession: session,
            ownership: .iphone, acceptedRevision: 11), .obsolete, "An equal/old snapshot must not resolve this transaction")
        XCTAssertEqual(pending.resolution(for: .unknown, currentSession: session,
            ownership: .iphone, acceptedRevision: 12), .phone)
        XCTAssertEqual(pending.resolution(for: .accepted, currentSession: session,
            ownership: .releasingToPhone, acceptedRevision: 11), .phone)
        XCTAssertEqual(pending.resolution(for: .rejectedByWatchOwner, currentSession: session,
            ownership: .releasingToPhone, acceptedRevision: 11), .watch)
    }

    func testPhoneReturnReplyClassificationNeverReclaimsFromAmbiguousOrWrongSessionReply() {
        let pending = LibreWatchPhoneReturnTransaction(session: session, cutoff: receivedAt, startingRevision: 11)
        let replies: [(Bool, LibreWatchOwnership?, LibreWatchDeliveryOutcome?, LibreWatchPhoneReturnTransaction.Resolution)] = [
            (true, .iphone, nil, .phone),
            (false, .watch, .wrongOwnership, .watch),
            (false, .watch, .invalidPayload, .watch),
            (false, .watch, .wrongSession, .pending),
            (false, .iphone, .invalidPayload, .pending),
            (true, .watch, nil, .pending),
            (false, nil, nil, .pending)
        ]
        for (success, owner, outcome, expected) in replies {
            let response = LibreWatchPhoneReturnTransaction.response(success: success, owner: owner, outcome: outcome)
            XCTAssertEqual(pending.resolution(for: response, currentSession: session,
                ownership: .releasingToPhone, acceptedRevision: 11), expected)
        }
    }

    func testPhoneReturnRejectsChangedSessionAndChangedSensorWithSameSessionID() {
        let current = session
        let pending = LibreWatchPhoneReturnTransaction(session: current, cutoff: receivedAt, startingRevision: 11)
        func replacement(id: UUID, uid: Data) -> LibreWatchDirectSession {
            LibreWatchDirectSession(id: id, createdAt: current.createdAt, sensorUID: uid,
                patchInfo: current.patchInfo, sensorSerialNumber: current.sensorSerialNumber,
                sensorTypeRawValue: current.sensorTypeRawValue, expectedPeripheralName: current.expectedPeripheralName,
                unlockCode: current.unlockCode, unlockCount: current.unlockCount, algorithmParameters: current.algorithmParameters)
        }
        for changed in [replacement(id: UUID(), uid: current.sensorUID),
                        replacement(id: current.id, uid: Data([8, 7, 6, 5, 4, 3, 2, 1]))] {
            XCTAssertFalse(pending.matches(changed))
            XCTAssertEqual(pending.resolution(for: .accepted, currentSession: changed,
                ownership: .releasingToPhone, acceptedRevision: 12), .obsolete)
        }
        XCTAssertEqual(pending.resolution(for: .accepted, currentSession: nil,
            ownership: .releasingToPhone, acceptedRevision: 12), .obsolete)
    }

    func testInterruptedPhoneReturnCleanupRetainsResolvedOwnerAndDoesNotReclaimWatch() throws {
        let (defaults, suite) = displaySnapshotDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var pending = LibreWatchPhoneReturnTransaction(session: session, cutoff: receivedAt, startingRevision: 11)
        pending.wasSubmitted = true
        LibreWatchSessionStore.saveSession(session, defaults: defaults)
        LibreWatchSessionStore.savePhoneReturn(pending, defaults: defaults)
        LibreWatchSessionStore.saveHandoffRevision(12, defaults: defaults)
        LibreWatchSessionStore.saveOwnership(.iphone, defaults: defaults)
        // Simulate termination before the redundant transaction record is removed.
        let restored = try XCTUnwrap(LibreWatchSessionStore.loadPhoneReturn(defaults: defaults))
        XCTAssertEqual(restored.resolution(for: .unknown, currentSession: LibreWatchSessionStore.loadSession(defaults: defaults),
            ownership: LibreWatchSessionStore.loadOwnership(defaults: defaults), acceptedRevision: 12), .phone)
        LibreWatchSessionStore.savePhoneReturn(nil, defaults: defaults)
        XCTAssertNil(LibreWatchSessionStore.loadPhoneReturn(defaults: defaults))
        XCTAssertEqual(LibreWatchSessionStore.loadOwnership(defaults: defaults), .iphone)
    }

    func testPhoneReturnPersistenceIsOptionalAndSessionClearRemovesIt() {
        let (defaults, suite) = displaySnapshotDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(LibreWatchSessionStore.loadPhoneReturn(defaults: defaults))
        LibreWatchSessionStore.savePhoneReturn(.init(session: session, cutoff: receivedAt, startingRevision: 1), defaults: defaults)
        XCTAssertNotNil(LibreWatchSessionStore.loadPhoneReturn(defaults: defaults))
        LibreWatchSessionStore.clear(defaults: defaults)
        XCTAssertNil(LibreWatchSessionStore.loadPhoneReturn(defaults: defaults))
    }

    @MainActor
    func testWatchReceiptIsWithheldAfterParentSaveFailureAndRetryPersistsExactlyOnce() async throws {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let sensor = Sensor(startDate: receivedAt.addingTimeInterval(-3600), nsManagedObjectContext: stack.mainManagedObjectContext)
        let reading = BgReading(timeStamp: receivedAt, sensor: sensor, calibration: nil, rawData: 85,
            deviceName: nil, nsManagedObjectContext: stack.mainManagedObjectContext)
        reading.calculatedValue = 85
        reading.ageAdjustedRawValue = 85
        let id = reading.id
        let parent = stack.privateManagedObjectContext
        // An invalid object only in the parent allows the child save to succeed, then
        // fails the actual durable-save step (distinct from the existing child-failure test).
        var invalidParentObject: NSManagedObject?
        parent.performAndWait {
            invalidParentObject = NSEntityDescription.insertNewObject(forEntityName: "BgReading", into: parent)
            invalidParentObject?.setValue(nil, forKey: "id")
        }
        let failed = expectation(description: "Parent validation failure must withhold receipt")
        stack.saveChanges { saved in
            XCTAssertFalse(saved)
            XCTAssertFalse(stack.mainManagedObjectContext.hasChanges, "Child save already succeeded")
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 5)
        parent.performAndWait {
            if let invalidParentObject { parent.delete(invalidParentObject) }
        }
        let confirmed = expectation(description: "Retry flushes pending parent changes exactly once")
        stack.saveChanges { saved in
            XCTAssertTrue(saved)
            let reader = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            reader.persistentStoreCoordinator = parent.persistentStoreCoordinator
            reader.perform {
                let request: NSFetchRequest<BgReading> = BgReading.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", id)
                XCTAssertEqual(try? reader.count(for: request), 1)
                confirmed.fulfill()
            }
        }
        await fulfillment(of: [confirmed], timeout: 5)
    }
}

extension LibreWatchValuePipelineTests {
    func testCommittedOwnershipObserverStartsAfterAssignmentWithoutTakeoverCompletion() {
        let fixture = LibreWatchOwnershipPublicationFixture()
        let applied = expectation(description: "committed ownership delivered")
        var events: [LibreWatchOwnership] = []
        let subscription = LibreWatchLifecyclePolicy.observeCommittedOwnership(fixture.$ownership,
            current: { fixture.ownership }, receive: { value in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(fixture.ownership, .watch)
                events.append(value)
                applied.fulfill()
            })
        DispatchQueue.main.async {
            fixture.ownership = .watch
            XCTAssertTrue(events.isEmpty, "Reconciliation must not run inside Published.willSet")
        }
        wait(for: [applied], timeout: 5)
        withExtendedLifetime(subscription) { XCTAssertEqual(events, [.watch]) }
    }

    func testCommittedOwnershipObserverRejectsQueuedTakeoverAfterReturn() {
        let fixture = LibreWatchOwnershipPublicationFixture()
        let applied = expectation(description: "current phone ownership delivered")
        var events: [LibreWatchOwnership] = []
        let subscription = LibreWatchLifecyclePolicy.observeCommittedOwnership(fixture.$ownership,
            current: { fixture.ownership }, receive: { value in events.append(value); applied.fulfill() })
        DispatchQueue.main.async {
            fixture.ownership = .watch
            fixture.ownership = .iphone
        }
        wait(for: [applied], timeout: 5)
        withExtendedLifetime(subscription) { XCTAssertEqual(events, [.iphone]) }
    }

    func testLegacyConnectingObservationAdoptsExistingSystemAttemptWithoutManualConnect() {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        XCTAssertNil(timing.deadline, "Do not fabricate a connection deadline in this fixture")
        var gate = LibreWatchDisconnectGate()
        XCTAssertTrue(gate.accept())
        XCTAssertEqual(LibreWatchLifecyclePolicy.disconnectRecoveryAction(isDeliberate: false,
            systemIsReconnecting: true, ownership: .watch), .waitForSystemReconnect)
        timing.invalidate()
        timing.beginConnection(at: receivedAt, applicationIsActive: false, executionIsAvailable: false)
        let adoptedGeneration = timing.generation
        XCTAssertFalse(timing.canConnect(at: receivedAt, peripheralIsDisconnected: false, retiredPeripheralIsReleased: true))
        timing.beginConnection(at: receivedAt.addingTimeInterval(600), applicationIsActive: true)
        XCTAssertEqual(timing.generation, adoptedGeneration)
        XCTAssertEqual(timing.remainingExecutionTime(at: receivedAt.addingTimeInterval(600)), 90)
        XCTAssertFalse(gate.accept(), "A following modern callback cannot create a second recovery")
    }

    func testFinalTransientOutboxItemRetriesOnExistingExecutionOpportunityAfterReturn() throws {
        let item = LibreWatchOutboxItem.reading(payload(raw: 847, previousRaw: 829, domain: .factoryNativeMGDL))
        var outbox = LibreWatchConnectivityOutbox()
        outbox.enqueue(item, now: receivedAt)
        XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: false, outcome: .historyNotInserted))
        outbox.markSubmitted(id: item.id, at: receivedAt)
        XCTAssertFalse(outbox.retryIsDue(at: receivedAt.addingTimeInterval(59), opportunity: .existingExecution(isAvailable: true), hasInFlightItem: false))
        let restored = try JSONDecoder().decode(LibreWatchConnectivityOutbox.self, from: JSONEncoder().encode(outbox))
        let next = receivedAt.addingTimeInterval(60)
        XCTAssertFalse(restored.retryIsDue(at: next, opportunity: .existingExecution(isAvailable: false), hasInFlightItem: false))
        XCTAssertFalse(restored.retryIsDue(at: next, opportunity: .existingExecution(isAvailable: true), hasInFlightItem: true))
        XCTAssertTrue(restored.retryIsDue(at: next, opportunity: .existingExecution(isAvailable: true), hasInFlightItem: false))
        XCTAssertEqual(restored.nextEligible(at: next)?.id, item.id)
        // Ownership isn't an input to transport retry; the historical receiver still enforces cutoff.
        outbox.remove(id: item.id)
        XCTAssertFalse(outbox.retryIsDue(at: next, opportunity: .existingExecution(isAvailable: true), hasInFlightItem: false))
    }

    func testFirstWatchPacketMissedDeadlineExistsWithoutInventingAReading() throws {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        state.beginWatchOwnership(at: receivedAt)
        let due = try XCTUnwrap(state.nextMissedAlarm(settings: settings, delegation: alarmDelegation(settings),
            watchOwnsSensor: true, now: receivedAt))
        XCTAssertEqual(due.date, receivedAt.addingTimeInterval(300))
        XCTAssertNil(state.lastReadingAt)
        XCTAssertNil(state.lastReadingID)
        XCTAssertTrue(state.notificationMayBePresented(kind: .missed,
            notificationSessionID: session.id.uuidString, notificationReadingID: nil,
            settings: settings, delegation: alarmDelegation(settings), watchOwnsSensor: true,
            notificationsAuthorized: true, at: due.date, notificationMissedBaseline: receivedAt))
        XCTAssertFalse(state.notificationMayBePresented(kind: .low,
            notificationSessionID: session.id.uuidString, notificationReadingID: nil,
            settings: settings, delegation: alarmDelegation(settings), watchOwnsSensor: true,
            notificationsAuthorized: true, at: due.date))
    }

    func testFirstPacketDeadlinePersistsWithoutRenewingOnWakeAndRespectsSnooze() throws {
        let settings = alarmSettings(snoozeAllUntil: receivedAt.addingTimeInterval(600))
        var state = LibreWatchAlarmState()
        state.use(settings)
        state.beginWatchOwnership(at: receivedAt)
        state.snooze(.missed, until: receivedAt.addingTimeInterval(900))
        let defaults = isolatedDefaults()
        LibreWatchAlarmStore.save(state, defaults: defaults)
        var restored = LibreWatchAlarmStore.state(defaults: defaults)
        restored.beginWatchOwnership(at: receivedAt.addingTimeInterval(200))
        XCTAssertEqual(restored.ownershipStartedAt, receivedAt)
        XCTAssertEqual(restored.nextMissedAlarm(settings: settings, delegation: alarmDelegation(settings),
            watchOwnsSensor: true, now: receivedAt.addingTimeInterval(200))?.date, receivedAt.addingTimeInterval(900))
        XCTAssertNil(restored.nextMissedAlarm(settings: settings, delegation: alarmDelegation(settings),
            watchOwnsSensor: false, now: receivedAt))
    }

    func testFreshFrameInvalidatesFirstPacketDeadlineWithoutChangingMeasurementTime() {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        state.beginWatchOwnership(at: receivedAt)
        let measured = receivedAt.addingTimeInterval(60)
        _ = state.accept(id: UUID(), measuredAt: measured, glucose: 120, settings: settings,
            delegation: alarmDelegation(settings), watchOwnsSensor: true, now: measured)
        XCTAssertEqual(state.lastReadingAt, measured)
        XCTAssertEqual(state.nextMissedAlarm(settings: settings, delegation: alarmDelegation(settings),
            watchOwnsSensor: true, now: measured)?.date, measured.addingTimeInterval(300))
        XCTAssertFalse(state.notificationMayBePresented(kind: .missed,
            notificationSessionID: session.id.uuidString, notificationReadingID: nil,
            settings: settings, delegation: alarmDelegation(settings), watchOwnsSensor: true,
            notificationsAuthorized: true, at: measured, notificationMissedBaseline: receivedAt))
        state.endWatchOwnership()
        state.beginWatchOwnership(at: measured.addingTimeInterval(600))
        XCTAssertEqual(state.missedReadingBaseline, measured.addingTimeInterval(600))
    }

    func testPendingAlarmRevisionKeepsCommittedEvaluationAndMissedDeadline() throws {
        let initial = alarmSettings()
        let changedRules = initial.rules.map { rule in
            LibreWatchAlarmRule(kind: rule.kind, startMinute: rule.startMinute,
                value: rule.kind == .veryLow ? 70 : rule.value, enabled: rule.enabled,
                snoozeMinutes: rule.snoozeMinutes, allowsSnooze: rule.allowsSnooze,
                soundEnabled: rule.soundEnabled, vibrate: rule.vibrate, title: rule.title)
        }
        let next = LibreWatchAlarmSettings(sessionID: initial.sessionID, sensorIdentity: initial.sensorIdentity,
            revision: 2, generatedAt: receivedAt, isMgDl: initial.isMgDl, rules: changedRules,
            snoozes: initial.snoozes, snoozeAllUntil: initial.snoozeAllUntil)
        var configuration = LibreWatchAlarmConfiguration(settings: initial, delegation: alarmDelegation(initial))
        var state = LibreWatchAlarmState()
        state.use(initial)
        state.beginWatchOwnership(at: receivedAt)
        state.scheduledMissedID = "previous-system-request"
        let before = state.nextMissedAlarm(settings: initial, delegation: configuration.delegation, watchOwnsSensor: true, now: receivedAt)?.date
        XCTAssertTrue(configuration.propose(next, session: session))
        let effective = try XCTUnwrap(configuration.effectiveSettings)
        state.use(try XCTUnwrap(configuration.settings))
        XCTAssertEqual(configuration.offeredSettings?.revision, 2, "Acknowledge the candidate, not the old active revision")
        XCTAssertEqual(effective.revision, 1)
        XCTAssertEqual(state.scheduledMissedID, "previous-system-request")
        XCTAssertEqual(state.nextMissedAlarm(settings: effective, delegation: configuration.delegation,
            watchOwnsSensor: true, now: receivedAt)?.date, before)
        // A reply to an older ACK still carries D1, even when its R2-ready flag is false.
        XCTAssertTrue(configuration.confirm(alarmDelegation(initial), session: session))
        XCTAssertEqual(configuration.pendingSettings, next)
        XCTAssertEqual(configuration.effectiveSettings?.rules, initial.rules)
        XCTAssertEqual(state.accept(id: UUID(), measuredAt: receivedAt, glucose: 38,
            settings: effective, delegation: configuration.delegation, watchOwnsSensor: true, now: receivedAt)?.kind, .veryLow)
        XCTAssertTrue(configuration.confirm(alarmDelegation(next), session: session))
        XCTAssertNil(configuration.pendingSettings)
        XCTAssertEqual(configuration.settings?.revision, 2)
        XCTAssertEqual(configuration.effectiveSettings?.rules, changedRules)
        XCTAssertTrue(configuration.delegation?.matches(next) == true)
    }

    func testCommittedAlarmPairAndPendingRevisionSurviveRestartAtomically() throws {
        let initial = alarmSettings()
        var next = initial
        next.revision = 2
        var configuration = LibreWatchAlarmConfiguration(settings: initial, delegation: alarmDelegation(initial))
        XCTAssertTrue(configuration.propose(next, session: session))
        let defaults = isolatedDefaults()
        LibreWatchAlarmStore.save(configuration, defaults: defaults)
        let restored = LibreWatchAlarmStore.configuration(defaults: defaults)
        XCTAssertEqual(restored, configuration)
        XCTAssertTrue(restored.delegation?.matches(try XCTUnwrap(restored.settings)) == true)
        XCTAssertEqual(restored.offeredSettings?.revision, 2)
    }

    func testAlarmDelegationCarriesExactSettingsWhenNewerOfferOvertakesReply() throws {
        let first = alarmSettings()
        var second = first
        second.revision = 2
        var third = second
        third.revision = 3
        var configuration = LibreWatchAlarmConfiguration(settings: first, delegation: alarmDelegation(first))
        XCTAssertTrue(configuration.propose(third, session: session))
        XCTAssertTrue(configuration.confirm(alarmDelegation(second), session: session))
        XCTAssertEqual(configuration.settings, second)
        XCTAssertEqual(configuration.pendingSettings, third)
        XCTAssertFalse(configuration.confirm(alarmDelegation(first), session: session))
        XCTAssertTrue(configuration.confirm(alarmDelegation(third), session: session))
        XCTAssertEqual(configuration.settings, third)
        XCTAssertNil(configuration.pendingSettings)
    }

    func testPendingAlarmSnoozeAppliesImmediatelyButUnsnoozeWaitsForConfirmation() throws {
        let initial = alarmSettings()
        var snoozed = alarmSettings(snoozeAllUntil: receivedAt.addingTimeInterval(600))
        snoozed.revision = 2
        var configuration = LibreWatchAlarmConfiguration(settings: initial, delegation: alarmDelegation(initial))
        XCTAssertTrue(configuration.propose(snoozed, session: session))
        let effective = try XCTUnwrap(configuration.effectiveSettings)
        XCTAssertEqual(effective.snoozeAllUntil, snoozed.snoozeAllUntil)
        XCTAssertEqual(effective.rules, initial.rules)
        XCTAssertTrue(configuration.delegation?.matches(effective) == true)
        XCTAssertTrue(configuration.confirm(alarmDelegation(snoozed), session: session))
        var unsnoozed = initial
        unsnoozed.revision = 3
        XCTAssertTrue(configuration.propose(unsnoozed, session: session))
        XCTAssertEqual(configuration.effectiveSettings?.snoozeAllUntil, snoozed.snoozeAllUntil)
        XCTAssertTrue(configuration.confirm(alarmDelegation(unsnoozed), session: session))
        XCTAssertNil(configuration.effectiveSettings?.snoozeAllUntil)
    }

    func testAlarmRevocationRejectsDelayedOldDelegationAndSessionMismatch() {
        let first = alarmSettings()
        var second = first
        second.revision = 2
        var configuration = LibreWatchAlarmConfiguration(settings: first, delegation: alarmDelegation(first))
        XCTAssertTrue(configuration.propose(second, session: session))
        XCTAssertTrue(configuration.confirm(nil, session: session))
        XCTAssertNil(configuration.delegation)
        XCTAssertFalse(configuration.confirm(alarmDelegation(first), session: session))
        XCTAssertFalse(configuration.confirm(LibreWatchAlarmDelegation(sessionID: UUID(),
            sensorIdentity: first.sensorIdentity, settingsRevision: 3), session: session))
        XCTAssertEqual(configuration.settings, second)
    }

    func testLegacyAlarmConfigurationAndStateDecodeWithoutNewFields() throws {
        let settings = alarmSettings()
        let defaults = isolatedDefaults()
        var legacyDelegation = alarmDelegation(settings)
        legacyDelegation.confirmedSettings = nil
        LibreWatchAlarmStore.save(settings, defaults: defaults)
        LibreWatchAlarmStore.save(legacyDelegation, defaults: defaults)
        let restored = LibreWatchAlarmStore.configuration(defaults: defaults)
        XCTAssertEqual(restored.settings, settings)
        XCTAssertTrue(restored.delegation?.matches(settings) == true)
        XCTAssertNil(restored.pendingSettings)
        let state = try JSONDecoder().decode(LibreWatchAlarmState.self, from: Data("{\"snoozes\":[]}".utf8))
        XCTAssertNil(state.ownershipStartedAt)
        XCTAssertNil(state.lastReadingAt)
        LibreWatchAlarmStore.clearSession(defaults: defaults)
        XCTAssertNil(LibreWatchAlarmStore.configuration(defaults: defaults).settings)
    }
}

extension LibreWatchValuePipelineTests {
    func testConfiguredReadSuccessCadenceDoesNotShrinkDuringOutageOrBackfill() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(3600)
        let contexts = [TransmitterReadSuccessContext(effectiveAt: start, source: "Libre2", interval: 60, visibleInterval: 60)]
        let before = TransmitterReadSuccessPolicy.counts(timestamps: [start, start.addingTimeInterval(60)],
            start: start, end: end, contexts: contexts, fallbackInterval: 60)
        XCTAssertEqual(before.expected, 60)
        XCTAssertEqual(before.actual, 2)
        let after = TransmitterReadSuccessPolicy.counts(timestamps: (0..<60).map { start.addingTimeInterval(Double($0) * 60) },
            start: start, end: end, contexts: contexts, fallbackInterval: 60)
        XCTAssertEqual(after.expected, before.expected)
        XCTAssertEqual(after.actual, 60)
    }

    func testConfiguredReadSuccessMixedIntervalsAndMinuteJitter() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let contexts = [
            TransmitterReadSuccessContext(effectiveAt: start, source: "Libre2", interval: 60, visibleInterval: 60),
            TransmitterReadSuccessContext(effectiveAt: start.addingTimeInterval(3600), source: "Dexcom", interval: 300, visibleInterval: 300)
        ]
        let counts = TransmitterReadSuccessPolicy.counts(timestamps: [], start: start,
            end: start.addingTimeInterval(7200), contexts: contexts, fallbackInterval: 60)
        XCTAssertEqual(counts.expected, 72)
        let jitter = TransmitterReadSuccessPolicy.counts(timestamps: [59, 120.1, 179].map { start.addingTimeInterval($0) },
            start: start, end: start.addingTimeInterval(180), contexts: contexts, fallbackInterval: 60)
        XCTAssertEqual(jitter, .init(expected: 3, actual: 3))
        let visibleOnly = Array(contexts.prefix(1)) + [TransmitterReadSuccessContext(effectiveAt: start.addingTimeInterval(30),
            source: "Libre2", interval: 60, visibleInterval: 300)]
        XCTAssertEqual(TransmitterReadSuccessPolicy.counts(timestamps: [], start: start,
            end: start.addingTimeInterval(180), contexts: Array(visibleOnly), fallbackInterval: 60).expected, 3)
        let unknown = [contexts[0],
            TransmitterReadSuccessContext(effectiveAt: start.addingTimeInterval(3600), source: "Bubble", interval: 0, visibleInterval: 300),
            TransmitterReadSuccessContext(effectiveAt: start.addingTimeInterval(7200), source: "Libre2", interval: 60, visibleInterval: 60)]
        XCTAssertEqual(TransmitterReadSuccessPolicy.counts(timestamps: [], start: start,
            end: start.addingTimeInterval(10800), contexts: unknown, fallbackInterval: 60).expected, 120)
    }

    @MainActor
    func testReadSuccessUsesCurrentSensorAndSeparatesDelayedPhoneStorage() throws {
        let suite = "ReadSuccessRegression-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.cgmTransmitterTypeAsString = CGMTransmitterType.Libre2.rawValue
        let now = Date()
        let start = now.addingTimeInterval(-600)
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let sensor = Sensor(startDate: start, nsManagedObjectContext: stack.mainManagedObjectContext)
        let other = Sensor(startDate: start, nsManagedObjectContext: stack.mainManagedObjectContext)
        let current = BgReading(timeStamp: start.addingTimeInterval(60), sensor: sensor, calibration: nil,
            rawData: 85, deviceName: nil, nsManagedObjectContext: stack.mainManagedObjectContext)
        current.calculatedValue = 85
        current.ageAdjustedRawValue = 85
        let unrelated = BgReading(timeStamp: start.addingTimeInterval(120), sensor: other, calibration: nil,
            rawData: 86, deviceName: nil, nsManagedObjectContext: stack.mainManagedObjectContext)
        unrelated.calculatedValue = 86
        unrelated.ageAdjustedRawValue = 86
        XCTAssertTrue(stack.saveChanges())
        let receipt = TransmitterReadSuccessReceipt(id: current.id, sensorID: sensor.id,
            measuredAt: current.timeStamp, storedAt: now, fromWatch: true, historical: true)
        TransmitterReadSuccessEvidence.record(receipt, defaults: defaults)
        TransmitterReadSuccessEvidence.record(receipt, defaults: defaults)
        let display = TransmitterReadSuccessManager(bgReadingsAccessor: BgReadingsAccessor(coreDataManager: stack),
            nowProvider: { now }, defaults: defaults).getReadSuccess(forSensor: sensor)
        XCTAssertEqual(display.expected24h, 10)
        XCTAssertEqual(display.actual24h, 1)
        XCTAssertEqual(display.timelyReceiptCount, 0)
        XCTAssertEqual(display.delayedReceiptCount, 1)
        XCTAssertTrue(display.deliveryEvidence.contains("BLE outages and transport delay are separate"))
    }

    func testCorrectedLogDeliveryIntervalsRemainHistoricalNotCurrent() {
        // Receipt-minus-measurement intervals from the supplied 18:58:25 report.
        // These prove late phone registration, not the location of the delay or a BLE outage.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for age in [519.0, 2_415, 206, 184] {
            XCTAssertGreaterThan(age, LibreWatchReadingAcceptancePolicy.maximumTransportAge)
            XCTAssertLessThan(age, LibreWatchHistoryPolicy.maximumAge)
            XCTAssertTrue(LibreWatchStoredReadingPolicy.requiresHistoricalPath(measuredAt: now.addingTimeInterval(-age),
                latestStoredAt: now.addingTimeInterval(-60)))
            let routing = LibreWatchGlucoseProcessingMode.historicalBackfill.routing
            XCTAssertFalse(routing.triggersAlerts)
            XCTAssertFalse(routing.resetsMissedReadingState)
            XCTAssertFalse(routing.updatesCurrentValue)
        }
    }

    func testStoredWatchReceiptDistinguishesPermanentErrorAndPendingCalibration() {
        XCTAssertEqual(LibreWatchStoredReadingPolicy.outcome(isValid: false, calculatedValue: 0), .historyNotInserted)
        XCTAssertEqual(LibreWatchStoredReadingPolicy.outcome(isValid: false, calculatedValue: 38), .invalidPayload)
        XCTAssertEqual(LibreWatchStoredReadingPolicy.outcome(isValid: true, calculatedValue: 38), .duplicate)
        XCTAssertEqual(LibreWatchStoredReadingPolicy.outcome(isValid: true, calculatedValue: 39), .duplicate)
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.isTerminal(.invalidPayload))
        XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.isTerminal(.historyNotInserted))
    }

    @MainActor
    func testWatchStorageConfirmationWaitsForParentStoreAndCanRetryFailedChildSave() async throws {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let sensor = Sensor(startDate: Date().addingTimeInterval(-3600), nsManagedObjectContext: stack.mainManagedObjectContext)
        let reading = BgReading(timeStamp: Date(), sensor: sensor, calibration: nil, rawData: 85,
            deviceName: nil, nsManagedObjectContext: stack.mainManagedObjectContext)
        reading.calculatedValue = 85
        reading.ageAdjustedRawValue = 85
        let id = reading.id
        reading.setValue(nil, forKey: "id")
        let failed = expectation(description: "Invalid child save is not a receipt")
        stack.saveChanges { saved in XCTAssertFalse(saved); failed.fulfill() }
        await fulfillment(of: [failed], timeout: 5)
        reading.id = id
        let confirmed = expectation(description: "Valid retry is durable before receipt")
        stack.saveChanges { saved in
            XCTAssertTrue(saved)
            let reader = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            reader.persistentStoreCoordinator = stack.privateManagedObjectContext.persistentStoreCoordinator
            reader.perform {
                let request: NSFetchRequest<BgReading> = BgReading.fetchRequest()
                request.predicate = NSPredicate(format: "id == %@", id)
                XCTAssertEqual(try? reader.count(for: request), 1)
                confirmed.fulfill()
            }
        }
        await fulfillment(of: [confirmed], timeout: 5)
    }
}

extension LibreWatchValuePipelineTests {
    func testNightscoutDispatchGateHonorsDisabledEnabledAndDisabledDuringRead() async {
        let reading: [String: Any] = ["_id": "enabled-gate", "type": "sgv", "date": 1_000, "sgv": 85]
        var enabled = false
        var actions = [String]()
        let disabled = await NightscoutReadingConfirmation.reconcile([reading], isUploadAllowed: { enabled },
            fetch: { _ in actions.append("read"); return [] }, upload: { _ in actions.append("write"); return true })
        XCTAssertFalse(disabled)
        XCTAssertTrue(actions.isEmpty)
        enabled = true
        var stored = false
        let accepted = await NightscoutReadingConfirmation.reconcile([reading], isUploadAllowed: { enabled },
            fetch: { _ in actions.append("read"); return stored ? [reading] : [] },
            upload: { _ in actions.append("write"); stored = true; return true })
        XCTAssertTrue(accepted)
        XCTAssertEqual(actions, ["read", "write", "read"])
        actions.removeAll()
        let toggled = await NightscoutReadingConfirmation.reconcile([reading], isUploadAllowed: { enabled },
            fetch: { _ in actions.append("read"); enabled = false; return [] },
            upload: { _ in actions.append("write"); return true })
        XCTAssertFalse(toggled)
        XCTAssertEqual(actions, ["read"], "Turning upload off while a request is pending must prevent its retry POST")
    }

    func testHealthKitDispatchGateHonorsDisabledEnabledAndDisabledDuringQuery() {
        var enabled = false
        var actions = [String]()
        HealthKitLegacyReplacement.perform(isEnabled: { enabled },
            query: { complete in actions.append("query"); complete(.success([String]())) },
            remove: { _, complete in actions.append("delete"); complete(true) },
            save: { actions.append("save") }, failed: { actions.append("retained") })
        XCTAssertEqual(actions, ["retained"])
        actions.removeAll()
        enabled = true
        HealthKitLegacyReplacement.perform(isEnabled: { enabled },
            query: { complete in actions.append("query"); complete(.success([String]())) },
            remove: { _, complete in actions.append("delete"); complete(true) },
            save: { actions.append("save") }, failed: { actions.append("retained") })
        XCTAssertEqual(actions, ["query", "save"])
        actions.removeAll()
        HealthKitLegacyReplacement.perform(isEnabled: { enabled },
            query: { complete in actions.append("query"); enabled = false; complete(.success(["legacy"])) },
            remove: { _, complete in actions.append("delete"); complete(true) },
            save: { actions.append("save") }, failed: { actions.append("retained") })
        XCTAssertEqual(actions, ["query", "retained"])
    }

    func testCalendarDispatchGateHonorsDisabledAndEnabled() {
        var actions = [String]()
        XCTAssertFalse(CalendarShareReplacement.perform(enabled: false, save: { actions.append("save") },
            removePrevious: { actions.append("removePrevious") }))
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(CalendarShareReplacement.perform(enabled: true, save: { actions.append("save") },
            removePrevious: { actions.append("removePrevious") }))
        XCTAssertEqual(actions, ["save", "removePrevious"])
    }

    func testNightscoutCode66RequiresPerReadingConfirmationOfMixedBatch() async {
        let first: [String: Any] = ["_id": "first", "type": "sgv", "date": 1_000, "sgv": 85]
        let second: [String: Any] = ["_id": "second", "type": "sgv", "date": 61_000, "sgv": 89]
        var server = ["first": first]
        var posts = [String]()
        let confirmed = await NightscoutReadingConfirmation.reconcile([first, second], fetch: { id in
            server[id].map { [$0] } ?? []
        }, upload: { reading in
            let id = reading["_id"] as! String
            posts.append(id)
            server[id] = reading
            return true
        })
        XCTAssertTrue(confirmed)
        XCTAssertEqual(posts, ["second"])
        let replay = await NightscoutReadingConfirmation.reconcile([first, second], fetch: { id in
            server[id].map { [$0] } ?? []
        }, upload: { _ in XCTFail("Confirmed IDs must not be posted again"); return false })
        XCTAssertTrue(replay)
    }

    func testNightscoutDoesNotConfirmConflictsFailedPostOrFailedRead() async {
        let reading: [String: Any] = ["_id": "first", "type": "sgv", "date": 1_000, "sgv": 85]
        var conflicting = reading
        conflicting["sgv"] = 90
        let conflict = await NightscoutReadingConfirmation.reconcile([reading], fetch: { _ in [conflicting] }, upload: { _ in
            XCTFail("A real collision must not overwrite server data"); return false
        })
        XCTAssertFalse(conflict)
        let failedPost = await NightscoutReadingConfirmation.reconcile([reading], fetch: { _ in [] }, upload: { _ in false })
        XCTAssertFalse(failedPost)
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut, 401, 500] {
            let failedRead = await NightscoutReadingConfirmation.reconcile([reading], fetch: { _ in
                throw NSError(domain: "TestTransport", code: code)
            }, upload: { _ in XCTFail("An unverified read must not lead to blind posting"); return false })
            XCTAssertFalse(failedRead)
        }
    }

    func testNightscoutCode66IsFailureNotBatchReceiptAndCheckpointIsMonotonic() {
        let body = Data(#"{"description":{"code":66}}"#.utf8)
        XCTAssertTrue(NightscoutReadingConfirmation.isDuplicateBatchFailure(status: 500, data: body))
        XCTAssertFalse(NightscoutReadingConfirmation.isDuplicateBatchFailure(status: 401, data: body))
        XCTAssertFalse(NightscoutReadingConfirmation.isDuplicateBatchFailure(status: 500, data: Data("bad response".utf8)))
        let current = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(NightscoutReadingConfirmation.checkpoint(current: current, confirmed: current.addingTimeInterval(-60)), current)
        XCTAssertEqual(NightscoutReadingConfirmation.checkpoint(current: current, confirmed: current.addingTimeInterval(60)), current.addingTimeInterval(60))
    }

    func testHistoricalNightscoutQueueRetainsUnconfirmedAndNewerRevisionsAcrossRestart() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var queue = NightscoutHistoricalQueue(siteFingerprint: "site-fingerprint")
        let old = NightscoutHistoricalQueue.Entry(id: "reading", measuredAt: now.addingTimeInterval(-600), payload: Data("old".utf8))
        queue.enqueue(old, now: now)
        queue = try JSONDecoder().decode(NightscoutHistoricalQueue.self, from: JSONEncoder().encode(queue))
        XCTAssertEqual(queue.entries, [old])
        let corrected = NightscoutHistoricalQueue.Entry(id: old.id, measuredAt: old.measuredAt, payload: Data("corrected".utf8))
        queue.enqueue(corrected, now: now)
        queue.confirm([old])
        XCTAssertEqual(queue.entries, [corrected], "An older in-flight response cannot clear a newer pending payload")
        queue.confirm([corrected])
        XCTAssertTrue(queue.entries.isEmpty)
    }

    func testHealthKitRetryKeepsSyncIdentityAndRevisionAndDoesNotClearNewerValue() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var queue = HealthKitReplacementQueue()
        queue.enqueue(id: "reading", timeStamp: now.addingTimeInterval(-600), value: 85, now: now)
        let original = try XCTUnwrap(queue.entries.first)
        XCTAssertEqual(original.metadata[HKMetadataKeySyncIdentifier] as? String, "xdrip.bg.reading")
        XCTAssertEqual((original.metadata[HKMetadataKeySyncVersion] as? NSNumber)?.int64Value, original.revision)
        queue = try JSONDecoder().decode(HealthKitReplacementQueue.self, from: JSONEncoder().encode(queue))
        queue.enqueue(id: original.id, timeStamp: original.timeStamp, value: original.value, now: now.addingTimeInterval(30))
        XCTAssertEqual(queue.entries, [original], "A retry must retain the persisted sync version")
        queue.enqueue(id: original.id, timeStamp: original.timeStamp, value: 90, now: now.addingTimeInterval(31))
        let corrected = try XCTUnwrap(queue.entries.first)
        XCTAssertGreaterThan(corrected.revision, original.revision)
        queue.confirm(original)
        XCTAssertEqual(queue.entries, [corrected])
        queue.confirm(corrected)
        XCTAssertTrue(queue.entries.isEmpty)
    }

    func testHealthKitCadenceDeletionRetainsOtherRevisionsAndSurvivesRestart() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var queue = HealthKitReplacementQueue()
        queue.enqueue(id: "suppressed", timeStamp: now.addingTimeInterval(-600), value: 85, now: now)
        queue.enqueue(id: "visible", timeStamp: now.addingTimeInterval(-300), value: 90, now: now)
        let inFlight = try XCTUnwrap(queue.entries.first { $0.id == "suppressed" })
        let retained = try XCTUnwrap(queue.entries.first { $0.id == "visible" })

        queue.remove(ids: ["suppressed", "already-deleted"])
        queue = try JSONDecoder().decode(HealthKitReplacementQueue.self, from: JSONEncoder().encode(queue))
        XCTAssertEqual(queue.entries, [retained], "A cadence rebuild must retain other samples and their sync revisions")

        queue.enqueue(id: inFlight.id, timeStamp: inFlight.timeStamp, value: 88, now: now.addingTimeInterval(30))
        let reenabled = try XCTUnwrap(queue.entries.first { $0.id == inFlight.id })
        XCTAssertGreaterThan(reenabled.revision, inFlight.revision)
        queue.confirm(inFlight)
        XCTAssertTrue(queue.entries.contains(reenabled), "A late completion from before deletion cannot clear a later revision")
        XCTAssertTrue(queue.entries.contains(retained))
    }

    func testHealthKitLegacyReplacementDoesNotSaveAfterQueryOrDeleteFailure() {
        enum Failure: Error { case query }
        var actions = [String]()
        HealthKitLegacyReplacement.perform(query: { complete in
            complete(.failure(Failure.query))
        }, remove: { (_: [String], complete: (Bool) -> Void) in actions.append("delete"); complete(true) },
           save: { actions.append("save") }, failed: { actions.append("retry") })
        XCTAssertEqual(actions, ["retry"])
        actions.removeAll()
        HealthKitLegacyReplacement.perform(query: { complete in complete(.success(["legacy"])) },
            remove: { _, complete in actions.append("delete"); complete(false) },
            save: { actions.append("save") }, failed: { actions.append("retry") })
        XCTAssertEqual(actions, ["delete", "retry"])
        actions.removeAll()
        HealthKitLegacyReplacement.perform(query: { complete in complete(.success(["legacy"])) },
            remove: { _, complete in actions.append("delete"); complete(true) },
            save: { actions.append("save") }, failed: { actions.append("retry") })
        XCTAssertEqual(actions, ["delete", "save"])
    }

    func testCalendarReplacementPreservesExistingEventWhenSaveFails() {
        enum Failure: Error { case save }
        var actions = [String]()
        XCTAssertThrowsError(try CalendarShareReplacement.perform(save: {
            actions.append("save")
            throw Failure.save
        }, removePrevious: { actions.append("removePrevious") }))
        XCTAssertEqual(actions, ["save"])
        actions.removeAll()
        CalendarShareReplacement.perform(save: { actions.append("save") }, removePrevious: { actions.append("removePrevious") })
        XCTAssertEqual(actions, ["save", "removePrevious"])
    }
}

extension LibreWatchValuePipelineTests {
    @MainActor
    func testLiveGapBoundariesKeepStoredCalibrationHistory() throws {
        // 15:03:55 -> 15:06:54 is a 179-second gap, processed later at 15:09:07.
        // Calibration history comes from storage, not the +/-150-second duplicate window.
        let start = Date(timeIntervalSince1970: 1_788_613_435)
        for gap in [149.0, 150, 151, 179, 290, 291] {
            let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
            let context = stack.mainManagedObjectContext
            let sensor = Sensor(startDate: start.addingTimeInterval(-3_600), nsManagedObjectContext: context)
            let calibration = Calibration(timeStamp: start.addingTimeInterval(-1_800), sensor: sensor,
                bg: 100, rawValue: 100, adjustedRawValue: 100, sensorConfidence: 1,
                rawTimeStamp: start.addingTimeInterval(-1_800), slope: 1.1, intercept: 4,
                distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: 100, slopeConfidence: 1,
                deviceName: nil, nsManagedObjectContext: context)
            let previous = BgReading(timeStamp: start, sensor: sensor, calibration: calibration,
                rawData: 100, deviceName: nil, nsManagedObjectContext: context)
            previous.calculatedValue = 114
            previous.ageAdjustedRawValue = 100
            XCTAssertTrue(stack.saveChanges())
            let incomingAt = start.addingTimeInterval(gap)
            XCTAssertEqual(GlucoseReadingInsertionPolicy.disposition(measuredAt: incomingAt,
                latestStoredAt: start, isNewestInBatch: true, historicalOnly: false,
                hasSameSlot: gap <= 150), .live)

            let accessor = BgReadingsAccessor(coreDataManager: stack)
            var history = accessor.calibrationHistory(before: incomingAt, for: sensor)
            XCTAssertEqual(history.map(\.id), [previous.id], "gap=\(gap)")
            var calibrations = [calibration]
            let result = Libre1Calibrator().createNewBgReading(rawData: 110_000,
                timeStamp: incomingAt, sensor: sensor, last3Readings: &history,
                lastCalibrationsForActiveSensorInLastXDays: &calibrations,
                firstCalibration: calibration, lastCalibration: calibration, deviceName: nil,
                nsManagedObjectContext: context)
            XCTAssertEqual(result.calculatedValue, 125, accuracy: 0.000_001)
            XCTAssertTrue(result.isValidForDownstream)
            XCTAssertTrue(stack.saveChanges())
            XCTAssertEqual(accessor.last(forSensor: sensor, includingSuppressed: true)?.timeStamp, incomingAt)
        }
    }

    @MainActor
    func testExistingCalibrationCalculatesEvenWithoutPreviousRows() {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = stack.mainManagedObjectContext
        let now = Date(timeIntervalSince1970: 1_788_613_807)
        let sensor = Sensor(startDate: now.addingTimeInterval(-3_600), nsManagedObjectContext: context)
        let calibration = Calibration(timeStamp: now.addingTimeInterval(-1_800), sensor: sensor,
            bg: 100, rawValue: 100, adjustedRawValue: 100, sensorConfidence: 1,
            rawTimeStamp: now.addingTimeInterval(-1_800), slope: 1.1, intercept: 4,
            distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: 100, slopeConfidence: 1,
            deviceName: nil, nsManagedObjectContext: context)
        let calibrators: [Calibrator] = [Libre1Calibrator(), Libre1NonFixedSlopeCalibrator()]
        for calibrator in calibrators {
            var history = [BgReading]()
            var calibrations = [calibration]
            let result = calibrator.createNewBgReading(rawData: 110_000, timeStamp: now, sensor: sensor,
                last3Readings: &history, lastCalibrationsForActiveSensorInLastXDays: &calibrations,
                firstCalibration: calibration, lastCalibration: calibration, deviceName: nil,
                nsManagedObjectContext: context)
            XCTAssertEqual(result.calculatedValue, 125, accuracy: 0.000_001)
            XCTAssertTrue(result.isValidForDownstream)
        }
    }

    @MainActor
    func testDelayedCalibrationContextExcludesFutureAndOtherSensorRows() {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = stack.mainManagedObjectContext
        let now = Date(timeIntervalSince1970: 1_788_613_807)
        let sensor = Sensor(startDate: now.addingTimeInterval(-3_600), nsManagedObjectContext: context)
        let otherSensor = Sensor(startDate: now.addingTimeInterval(-4_000), nsManagedObjectContext: context)
        let earlier = BgReading(timeStamp: now.addingTimeInterval(-600), sensor: sensor,
            calibration: nil, rawData: 100, deviceName: nil, nsManagedObjectContext: context)
        earlier.calculatedValue = 100
        let later = BgReading(timeStamp: now, sensor: sensor, calibration: nil,
            rawData: 120, deviceName: nil, nsManagedObjectContext: context)
        later.calculatedValue = 120
        let other = BgReading(timeStamp: now.addingTimeInterval(-450), sensor: otherSensor,
            calibration: nil, rawData: 110, deviceName: nil, nsManagedObjectContext: context)
        other.calculatedValue = 110
        XCTAssertTrue(stack.saveChanges())
        let delayedAt = now.addingTimeInterval(-300)
        let disposition = GlucoseReadingInsertionPolicy.disposition(measuredAt: delayedAt,
            latestStoredAt: now, isNewestInBatch: true, historicalOnly: false, hasSameSlot: false)
        XCTAssertEqual(disposition, .historical)
        let history = BgReadingsAccessor(coreDataManager: stack).calibrationHistory(before: delayedAt, for: sensor)
        XCTAssertEqual(history.map(\.id), [earlier.id])
        XCTAssertFalse(LibreWatchGlucoseProcessingMode.historicalBackfill.permitsCurrentValueAndLiveSideEffects)
        XCTAssertEqual(later.calculatedValue, 120)
    }
}

private final class LibreWatchDiscoveryTestPeripheral {
    var isDisconnected = true
}

private final class LibreWatchDiscoveryTestClock {
    var uptime: TimeInterval = 1_000
}

// This fixture invokes the same production transitions as the collector. Only the native
// peripheral-state read and the actual connect side effect are replaced with test doubles.
private final class LibreWatchDiscoveryTestDriver {
    typealias Handoff = LibreWatchDiscoveryHandoff<LibreWatchDiscoveryTestPeripheral>
    let clock = LibreWatchDiscoveryTestClock()
    lazy var handoff = Handoff(now: { [clock] in clock.uptime })
    var session: LibreWatchDirectSession
    var centralInstanceID = UUID()
    var generation = UUID()
    var ownership: LibreWatchOwnership = .watch
    var poweredOn = true
    var selectionIsAllowed = true
    var retirementIsPending = true
    private(set) var connectRequests: [Handoff.Candidate] = []

    init(session: LibreWatchDirectSession) { self.session = session }

    var context: Handoff.Context {
        .init(session: session, centralInstanceID: centralInstanceID, generation: generation,
              ownership: ownership, bluetoothIsPoweredOn: poweredOn,
              selectionIsAllowed: selectionIsAllowed)
    }

    @discardableResult
    func discover(_ peripheral: LibreWatchDiscoveryTestPeripheral,
                  name: String?, advertisedName: String? = nil) -> Handoff.Outcome {
        handoff.didDiscover(peripheral, peripheralName: name, advertisedName: advertisedName,
            rssi: -60, context: context, retiredPeripheralIsReleased: !retirementIsPending,
            isDisconnected: { $0.isDisconnected }, connect: { self.connectRequests.append($0) })
    }

    @discardableResult
    func release() -> Handoff.Outcome {
        retirementIsPending = false
        return handoff.retiredPeripheralWasReleased(context: context,
            isDisconnected: { $0.isDisconnected }, connect: { self.connectRequests.append($0) })
    }
}

extension LibreWatchValuePipelineTests {
    func testDiscoveryBeforeRetiredDisconnectConnectsWithoutSecondAdvertisement() throws {
        let driver = LibreWatchDiscoveryTestDriver(session: session)
        let peripheral = LibreWatchDiscoveryTestPeripheral()
        // Reach the production retirement state via its existing cancellation watchdog.
        var timing = LibreWatchConnectionTiming()
        timing.beginCancellation(at: receivedAt)
        let deadline = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(timing.finishCancellation(deadline, ownership: .watch,
            returningToPhone: false, peripheralIsDisconnected: false, at: deadline.expiresAt), .retireForScan)
        driver.generation = timing.generation
        XCTAssertEqual(driver.discover(peripheral, name: session.expectedPeripheralName), .deferred)
        XCTAssertTrue(driver.connectRequests.isEmpty)
        XCTAssertNotNil(driver.handoff.pending)

        XCTAssertEqual(driver.release(), .connectRequested)
        XCTAssertNil(driver.handoff.pending)
        XCTAssertEqual(driver.connectRequests.count, 1)
        XCTAssertTrue(driver.connectRequests.first?.peripheral === peripheral)
        // The delivered candidate still enters normal connection timing; retirement cannot
        // itself bypass the native proof needed by canConnect or imply a received frame.
        timing.beginConnection(at: deadline.expiresAt, applicationIsActive: false,
            executionIsAvailable: false, monotonicTime: driver.clock.uptime)
        XCTAssertTrue(timing.canConnect(at: deadline.expiresAt, peripheralIsDisconnected: true,
            retiredPeripheralIsReleased: true, monotonicTime: driver.clock.uptime))
        XCTAssertFalse(timing.canConnect(at: deadline.expiresAt, peripheralIsDisconnected: true,
            retiredPeripheralIsReleased: false, monotonicTime: driver.clock.uptime))
        XCTAssertEqual(timing.phase, .connection)
    }

    func testDuplicateLegacyAndModernRetirementObservationsConsumeDiscoveryOnce() {
        let driver = LibreWatchDiscoveryTestDriver(session: session)
        let peripheral = LibreWatchDiscoveryTestPeripheral()
        XCTAssertEqual(driver.discover(peripheral, name: session.expectedPeripheralName), .deferred)
        XCTAssertEqual(driver.discover(peripheral, name: session.expectedPeripheralName), .duplicate)
        XCTAssertEqual(driver.release(), .connectRequested) // legacy callback or native-state observation
        XCTAssertEqual(driver.release(), .ignored) // duplicate modern callback
        XCTAssertEqual(driver.release(), .ignored)
        XCTAssertEqual(driver.connectRequests.count, 1)
    }

    func testPendingDiscoveryCanReuseRetiredNativeObjectOnlyOnceItIsDisconnected() {
        let driver = LibreWatchDiscoveryTestDriver(session: session)
        let peripheral = LibreWatchDiscoveryTestPeripheral()
        peripheral.isDisconnected = false
        XCTAssertEqual(driver.discover(peripheral, name: session.expectedPeripheralName), .deferred)
        XCTAssertTrue(driver.connectRequests.isEmpty)
        peripheral.isDisconnected = true
        XCTAssertEqual(driver.release(), .connectRequested)
        // Collector marks this old disconnect handled before reusing the object. didConnect,
        // not connect submission, is the existing reset boundary for the duplicate gate.
        var disconnectGate = LibreWatchDisconnectGate()
        XCTAssertTrue(disconnectGate.accept())
        XCTAssertFalse(disconnectGate.accept())
        disconnectGate.reset()
        XCTAssertTrue(disconnectGate.accept())
        XCTAssertEqual(driver.connectRequests.count, 1)
    }

    func testDiscoveryRetainsObservedAdvertisementNameWithoutInventingIdentity() {
        let driver = LibreWatchDiscoveryTestDriver(session: session)
        let peripheral = LibreWatchDiscoveryTestPeripheral()
        XCTAssertEqual(driver.discover(peripheral, name: nil), .ignored)
        XCTAssertNil(driver.handoff.pending)
        XCTAssertEqual(driver.discover(peripheral, name: nil,
            advertisedName: session.expectedPeripheralName.lowercased()), .deferred)
        XCTAssertEqual(driver.release(), .connectRequested)
        XCTAssertEqual(driver.connectRequests.first?.observedName, session.expectedPeripheralName.lowercased())
    }

    func testWrongObservedSensorCannotHideBehindMatchingAdvertisedNameOrReplacePending() {
        let driver = LibreWatchDiscoveryTestDriver(session: session)
        let correct = LibreWatchDiscoveryTestPeripheral()
        XCTAssertEqual(driver.discover(correct, name: session.expectedPeripheralName), .deferred)
        XCTAssertEqual(driver.discover(LibreWatchDiscoveryTestPeripheral(), name: "001122334455",
            advertisedName: session.expectedPeripheralName), .ignored)
        XCTAssertEqual(driver.release(), .connectRequested)
        XCTAssertTrue(driver.connectRequests.first?.peripheral === correct)
    }

    func testOnlyLatestVerifiedNativeCandidateIsRetainedDuringRetirement() {
        let driver = LibreWatchDiscoveryTestDriver(session: session)
        let first = LibreWatchDiscoveryTestPeripheral()
        let latest = LibreWatchDiscoveryTestPeripheral()
        XCTAssertEqual(driver.discover(first, name: session.expectedPeripheralName), .deferred)
        XCTAssertEqual(driver.discover(latest, name: session.expectedPeripheralName), .deferred)
        XCTAssertTrue(driver.connectRequests.isEmpty)
        XCTAssertEqual(driver.release(), .connectRequested)
        XCTAssertEqual(driver.connectRequests.count, 1)
        XCTAssertTrue(driver.connectRequests.first?.peripheral === latest)
    }

    func testPendingDiscoveryCannotCrossOwnershipChangeOrPhoneReturn() {
        for owner in [LibreWatchOwnership.iphone, .releasingToPhone, .releasingToWatch, .recovery] {
            let driver = LibreWatchDiscoveryTestDriver(session: session)
            driver.discover(LibreWatchDiscoveryTestPeripheral(), name: session.expectedPeripheralName)
            driver.ownership = owner
            XCTAssertEqual(driver.release(), .ignored)
            XCTAssertNil(driver.handoff.pending)
            driver.ownership = .watch
            XCTAssertEqual(driver.release(), .ignored)
            XCTAssertTrue(driver.connectRequests.isEmpty)
        }
    }

    func testPendingDiscoveryCannotCrossCentralOrConnectionGeneration() {
        for changesCentral in [false, true] {
            let driver = LibreWatchDiscoveryTestDriver(session: session)
            driver.discover(LibreWatchDiscoveryTestPeripheral(), name: session.expectedPeripheralName)
            if changesCentral { driver.centralInstanceID = UUID() } else { driver.generation = UUID() }
            XCTAssertEqual(driver.release(), .ignored)
            XCTAssertNil(driver.handoff.pending)
            XCTAssertTrue(driver.connectRequests.isEmpty)
        }
    }

    func testPendingDiscoveryCannotCrossSessionOrSensorChange() {
        for changesSession in [false, true] {
            let driver = LibreWatchDiscoveryTestDriver(session: session)
            driver.discover(LibreWatchDiscoveryTestPeripheral(), name: session.expectedPeripheralName)
            driver.session = LibreWatchDirectSession(
                id: changesSession ? UUID() : session.id, createdAt: session.createdAt,
                sensorUID: changesSession ? session.sensorUID : Data(repeating: 9, count: 8),
                patchInfo: session.patchInfo, sensorSerialNumber: session.sensorSerialNumber,
                sensorTypeRawValue: session.sensorTypeRawValue,
                expectedPeripheralName: session.expectedPeripheralName, unlockCode: session.unlockCode,
                unlockCount: session.unlockCount, algorithmParameters: session.algorithmParameters)
            XCTAssertEqual(driver.release(), .ignored)
            XCTAssertNil(driver.handoff.pending)
            XCTAssertTrue(driver.connectRequests.isEmpty)
        }
    }

    func testUnlockCounterRefreshDoesNotDiscardTheSameSensorDiscovery() {
        let driver = LibreWatchDiscoveryTestDriver(session: session)
        driver.discover(LibreWatchDiscoveryTestPeripheral(), name: session.expectedPeripheralName)
        driver.session.unlockCount += 1
        XCTAssertEqual(driver.release(), .connectRequested)
        XCTAssertEqual(driver.session.unlockCount, session.unlockCount + 1)
    }

    func testPendingDiscoveryRequiresPoweredOnAndAnAvailableSelectionPath() {
        for losesPower in [false, true] {
            let driver = LibreWatchDiscoveryTestDriver(session: session)
            driver.discover(LibreWatchDiscoveryTestPeripheral(), name: session.expectedPeripheralName)
            if losesPower { driver.poweredOn = false } else { driver.selectionIsAllowed = false }
            XCTAssertEqual(driver.release(), .ignored)
            driver.poweredOn = true
            driver.selectionIsAllowed = true
            XCTAssertEqual(driver.release(), .ignored)
            XCTAssertTrue(driver.connectRequests.isEmpty)
        }
    }

    func testStopOrPowerResetInvalidatesPendingBeforeAnyLaterCallback() {
        let driver = LibreWatchDiscoveryTestDriver(session: session)
        driver.discover(LibreWatchDiscoveryTestPeripheral(), name: session.expectedPeripheralName)
        driver.handoff.invalidate() // same production call used by stop/session/power-reset paths
        XCTAssertEqual(driver.release(), .ignored)
        XCTAssertTrue(driver.connectRequests.isEmpty)
    }

    func testPendingDiscoveryRejectsCandidateAlreadyConnectedOrConnectingElsewhere() {
        let driver = LibreWatchDiscoveryTestDriver(session: session)
        let peripheral = LibreWatchDiscoveryTestPeripheral()
        driver.discover(peripheral, name: session.expectedPeripheralName)
        peripheral.isDisconnected = false
        XCTAssertEqual(driver.release(), .ignored)
        XCTAssertNil(driver.handoff.pending)
        XCTAssertTrue(driver.connectRequests.isEmpty)
    }

    func testPendingAdvertisementExpiryUsesInjectedMonotonicClockWithoutTimer() {
        let driver = LibreWatchDiscoveryTestDriver(session: session)
        let peripheral = LibreWatchDiscoveryTestPeripheral()
        driver.discover(peripheral, name: session.expectedPeripheralName)
        driver.clock.uptime += 121
        // No background timer ran or changed Bluetooth state during this simulated suspension.
        XCTAssertNotNil(driver.handoff.pending)
        XCTAssertTrue(driver.connectRequests.isEmpty)
        XCTAssertEqual(driver.release(), .ignored)
        XCTAssertNil(driver.handoff.pending)
        XCTAssertEqual(driver.discover(peripheral, name: session.expectedPeripheralName), .connectRequested)
        XCTAssertEqual(driver.connectRequests.count, 1)
    }

    func testPendingDiscoveryIsRemovedBeforeReentrantReleaseAndImmediateDiscoveryStillWorks() {
        let driver = LibreWatchDiscoveryTestDriver(session: session)
        let peripheral = LibreWatchDiscoveryTestPeripheral()
        driver.discover(peripheral, name: session.expectedPeripheralName)
        var connections = 0
        XCTAssertEqual(driver.handoff.retiredPeripheralWasReleased(context: driver.context,
            isDisconnected: { $0.isDisconnected }, connect: { _ in
                connections += 1
                XCTAssertEqual(driver.handoff.retiredPeripheralWasReleased(context: driver.context,
                    isDisconnected: { $0.isDisconnected }, connect: { _ in connections += 1 }), .ignored)
            }), .connectRequested)
        XCTAssertEqual(connections, 1)
        driver.retirementIsPending = false
        XCTAssertEqual(driver.discover(peripheral, name: session.expectedPeripheralName), .connectRequested)
        XCTAssertEqual(driver.connectRequests.count, 1)
    }
}

final class LibreWatchValuePipelineTests: XCTestCase {
    private let receivedAt = Date(timeIntervalSince1970: 1_788_333_200)

    override func tearDown() {
        clearPhoneLibreParserCache()
        super.tearDown()
    }

    func testSameDecryptedFrameProducesSameNativeValueOnWatchAndIPhone() throws {
        let frame = decryptedFrame(currentRaw: 847, previousRaw: 830)
        let watchReading = try Libre2WatchDirectAlgorithms.parseDirectReading(
            decryptedData: frame,
            parameters: watchAlgorithmParameters,
            receivedAt: receivedAt
        )

        let phoneReading = phoneParsedValue(frame: frame, parameters: phoneAlgorithmParameters)

        XCTAssertEqual(watchReading.rawGlucose, 847)
        XCTAssertEqual(watchReading.previousRawGlucose, 830)
        XCTAssertEqual(watchReading.nativeGlucoseMGDL, phoneReading, accuracy: 0.000_001)
    }

    func testRawGlucoseTimesLibreMultiplierMatchesNormalIPhoneXDripInput() throws {
        let frame = decryptedFrame(currentRaw: 847, previousRaw: 830)
        let watchReading = try Libre2WatchDirectAlgorithms.parseDirectReading(
            decryptedData: frame,
            parameters: watchAlgorithmParameters,
            receivedAt: receivedAt
        )
        let payload = watchReading.payload(
            sessionID: session.id,
            valueDomain: .xDripRawGlucose,
            calibrationRevision: 10
        )

        let phoneInput = phoneParsedValue(frame: frame, parameters: nil)

        XCTAssertEqual(payload.xDripCalibrationInput, Double(847) * ConstantsBloodGlucose.libreMultiplier)
        XCTAssertEqual(payload.xDripCalibrationInput, phoneInput, accuracy: 0.000_001)
    }

    func testWatchAndIPhoneFinalValuesMatchForFixedAndNonFixedSlope() throws {
        let reading = payload(raw: 900, previousRaw: 875, domain: .xDripRawGlucose)

        for calibrationType in [LibreWatchCalibrationType.fixedSlope, .nonFixedSlope] {
            let snapshot = calibration(
                type: calibrationType,
                slope: 1.08,
                intercept: -7.5
            )
            let iPhoneDivider = calibrationType == .fixedSlope
                ? Libre1Calibrator().rawValueDivider
                : Libre1NonFixedSlopeCalibrator().rawValueDivider
            let expectedIPhoneValue = iphoneCalibratedValue(
                input: reading.xDripCalibrationInput,
                slope: snapshot.slope,
                intercept: snapshot.intercept,
                divider: iPhoneDivider
            )

            XCTAssertEqual(snapshot.rawValueDivider, iPhoneDivider)
            let watchValue = try XCTUnwrap(snapshot.displayedGlucose(for: reading))
            XCTAssertEqual(watchValue, expectedIPhoneValue, accuracy: 0.000_001)
        }
    }

    func testFactoryValueUsesNativeDomainWithoutSecondCalibration() throws {
        let reading = payload(
            native: 112.4,
            previousNative: 110.2,
            raw: 950,
            previousRaw: 930,
            domain: .factoryNativeMGDL
        )
        let snapshot = calibration(type: .factoryCalibrated, slope: 1, intercept: 0)

        let watchValue = try XCTUnwrap(snapshot.displayedGlucose(for: reading))
        XCTAssertEqual(watchValue, 112.4, accuracy: 0.000_001)
        XCTAssertEqual(reading.sourceValue(for: snapshot.requiredValueDomain), 112.4, accuracy: 0.000_001)
        XCTAssertNotEqual(watchValue, reading.xDripCalibrationInput)
    }

    func testNativeFourPointSevenDoesNotBecomeLowWithXDripCalibration() throws {
        let reading = payload(
            native: 4.7 / ConstantsBloodGlucose.mgDlToMmoll,
            previousNative: 82,
            raw: 720,
            previousRaw: 700,
            domain: .xDripRawGlucose
        )
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let iPhoneDivider = Libre1Calibrator().rawValueDivider

        let displayed = try XCTUnwrap(snapshot.displayedGlucose(for: reading))
        XCTAssertEqual(displayed, Double(720) * ConstantsBloodGlucose.libreMultiplier / iPhoneDivider, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(displayed, 40)
        XCTAssertEqual(displayed * ConstantsBloodGlucose.mgDlToMmoll, 4.7, accuracy: 0.02)

        let formerWrongDomainResult = iphoneCalibratedValue(
            input: reading.nativeGlucoseMGDL,
            slope: 1,
            intercept: 0,
            divider: 1_000
        )
        XCTAssertEqual(formerWrongDomainResult, 38)
        XCTAssertNotEqual(displayed, formerWrongDomainResult)
    }

    func testTrendAndDeltaUseSelectedDomainWithoutIntercept() throws {
        let reading = payload(raw: 900, previousRaw: 850, domain: .xDripRawGlucose)
        let snapshot = calibration(type: .nonFixedSlope, slope: 1.2, intercept: 45)
        let sourceDifference = Double(60) * ConstantsBloodGlucose.libreMultiplier

        let expectedTrend = 1.2 * (
            (Double(900 - 850) * ConstantsBloodGlucose.libreMultiplier) / 2
        ) / 1_000
        let expectedDelta = 1.2 * sourceDifference / 1_000

        let watchTrend = try XCTUnwrap(snapshot.displayedTrend(for: reading))
        let watchDelta = try XCTUnwrap(snapshot.displayedDelta(sourceDelta: sourceDifference))
        XCTAssertEqual(watchTrend, expectedTrend, accuracy: 0.000_001)
        XCTAssertEqual(watchDelta, expectedDelta, accuracy: 0.000_001)
        XCTAssertNotEqual(watchTrend, expectedTrend + snapshot.intercept)
        XCTAssertNotEqual(watchDelta, expectedDelta + snapshot.intercept)
    }

    func testOldOrIncompletePayloadCannotProduceOrPersistFalseLow() throws {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let oldVersion = payload(
            version: 1,
            raw: 720,
            previousRaw: 700,
            domain: .xDripRawGlucose
        )
        let incomplete = payload(
            raw: 0,
            previousRaw: 700,
            domain: .xDripRawGlucose
        )

        XCTAssertFalse(oldVersion.isValid(for: snapshot))
        XCTAssertFalse(incomplete.isValid(for: snapshot))
        XCTAssertNil(snapshot.displayedGlucose(for: oldVersion))
        XCTAssertNil(snapshot.displayedGlucose(for: incomplete))

        let legacyJSON = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString,
            "sessionID": session.id.uuidString,
            "glucoseMGDL": 84.7,
            "sensorTimeInMinutes": 1_000,
            "receivedAt": receivedAt.timeIntervalSinceReferenceDate
        ])
        XCTAssertNil(try? JSONDecoder().decode(LibreWatchDirectReadingPayload.self, from: legacyJSON))

        let defaults = isolatedDefaults()
        defaults.set(legacyJSON, forKey: LibreWatchMessageKey.legacyPersistedReading)
        XCTAssertNil(LibreWatchSessionStore.loadReading(defaults: defaults))
        XCTAssertNil(defaults.data(forKey: LibreWatchMessageKey.legacyPersistedReading))
    }

    func testCalibrationAndAlgorithmStayStableAcrossOwnershipCycle() {
        let defaults = isolatedDefaults()
        let snapshot = calibration(type: .nonFixedSlope, slope: 1.17, intercept: -11)
        LibreWatchSessionStore.saveSession(session, defaults: defaults)
        LibreWatchSessionStore.saveCalibration(snapshot, defaults: defaults)

        var ownership = LibreWatchOwnership.iphone
        for next in [
            LibreWatchOwnership.releasingToWatch,
            .watch,
            .watch,
            .releasingToPhone,
            .iphone
        ] {
            XCTAssertTrue(ownership.canTransition(to: next))
            ownership = next
            LibreWatchSessionStore.saveOwnership(ownership, defaults: defaults)
            XCTAssertEqual(LibreWatchSessionStore.loadCalibration(defaults: defaults), snapshot)
            XCTAssertEqual(
                LibreWatchSessionStore.loadCalibration(defaults: defaults)?.requiredValueDomain,
                .xDripRawGlucose
            )
        }
    }

    func testReadingOlderThanThreeMinutesKeepsValueButHidesTrendAndDelta() throws {
        let reading = payload(raw: 900, previousRaw: 875, domain: .xDripRawGlucose)
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let sourceDelta = Double(25) * ConstantsBloodGlucose.libreMultiplier

        let current = try XCTUnwrap(snapshot.presentation(
            for: reading,
            sourceDelta: sourceDelta,
            at: receivedAt.addingTimeInterval(179)
        ))
        let stale = try XCTUnwrap(snapshot.presentation(
            for: reading,
            sourceDelta: sourceDelta,
            at: receivedAt.addingTimeInterval(181)
        ))

        XCTAssertFalse(current.isStale)
        XCTAssertNotNil(current.trendMGDLPerMinute)
        XCTAssertNotNil(current.deltaMGDL)
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.glucoseMGDL, current.glucoseMGDL, accuracy: 0.000_001)
        XCTAssertNil(stale.trendMGDLPerMinute)
        XCTAssertNil(stale.deltaMGDL)
    }

    func testDirectDeltaAcceptsThreeMinuteBoundaryButRejectsLongSuspensionGap() throws {
        let snapshot = calibration(type: .fixedSlope, slope: 1.1, intercept: 20)
        let previous = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: receivedAt
        )
        let boundary = payload(
            raw: 820,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: receivedAt.addingTimeInterval(LibreWatchDirectDeltaPolicy.maximumGap)
        )
        let afterSuspension = payload(
            raw: 830,
            previousRaw: 820,
            domain: .xDripRawGlucose,
            sensorTime: 1_002,
            at: receivedAt.addingTimeInterval(LibreWatchDirectDeltaPolicy.maximumGap + 0.001)
        )

        XCTAssertEqual(
            try XCTUnwrap(LibreWatchDirectDeltaPolicy.sourceDelta(
                current: boundary,
                previous: previous,
                calibration: snapshot
            )),
            boundary.xDripCalibrationInput - previous.xDripCalibrationInput,
            accuracy: 0.000_001
        )
        XCTAssertNil(LibreWatchDirectDeltaPolicy.sourceDelta(
            current: afterSuspension,
            previous: previous,
            calibration: snapshot
        ))
    }

    func testDirectDeltaRejectsWrongSessionDomainRevisionAndSensorOrder() {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0, revision: 10)
        let previous = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: receivedAt,
            revision: 10
        )
        let wrongSession = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: receivedAt.addingTimeInterval(60),
            sessionID: UUID()
        )
        let wrongDomain = payload(
            raw: 810,
            previousRaw: 800,
            domain: .factoryNativeMGDL,
            sensorTime: 1_001,
            at: receivedAt.addingTimeInterval(60)
        )
        let wrongRevision = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: receivedAt.addingTimeInterval(60),
            revision: 9
        )
        let nonIncreasingSensorTime = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: receivedAt.addingTimeInterval(60)
        )

        for current in [wrongSession, wrongDomain, wrongRevision, nonIncreasingSensorTime] {
            XCTAssertNil(LibreWatchDirectDeltaPolicy.sourceDelta(
                current: current,
                previous: previous,
                calibration: snapshot
            ))
        }
    }

    func testFortyEightMinuteGapFromNinePointSevenToSixPointSevenHasNoDeltaButKeepsTrend() throws {
        let snapshot = calibration(type: .factoryCalibrated, slope: 1, intercept: 0)
        let previous = payload(
            native: 9.7 * ConstantsBloodGlucose.mmollToMgdl,
            previousNative: 9.6 * ConstantsBloodGlucose.mmollToMgdl,
            raw: 900,
            previousRaw: 890,
            domain: .factoryNativeMGDL,
            sensorTime: 1_000,
            at: receivedAt
        )
        let current = payload(
            native: 6.7 * ConstantsBloodGlucose.mmollToMgdl,
            previousNative: 6.6 * ConstantsBloodGlucose.mmollToMgdl,
            raw: 700,
            previousRaw: 690,
            domain: .factoryNativeMGDL,
            sensorTime: 1_048,
            at: receivedAt.addingTimeInterval(48 * 60)
        )

        let sourceDelta = LibreWatchDirectDeltaPolicy.sourceDelta(
            current: current,
            previous: previous,
            calibration: snapshot
        )
        let presentation = try XCTUnwrap(snapshot.presentation(
            for: current,
            sourceDelta: sourceDelta,
            at: current.receivedAt.addingTimeInterval(1)
        ))

        XCTAssertNil(sourceDelta)
        XCTAssertNil(presentation.deltaMGDL)
        XCTAssertNotNil(presentation.trendMGDLPerMinute)
    }

    func testActiveApplicationAllowsRecoveryWithoutExtendedRuntime() {
        XCTAssertTrue(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: true,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.shouldStartExtendedRuntime(
            userInitiatedTakeover: true,
            applicationIsActive: true,
            ownership: .watch,
            alreadyHasSession: false
        ))
    }

    func testInactiveApplicationAllowsRecoveryWhileExtendedRuntimeIsRunning() {
        XCTAssertTrue(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: false,
            extendedRuntimeIsRunning: true,
            ownership: .watch
        ))
    }

    func testInactiveWatchOwnerPreservesCoreBluetoothWithoutStartingTimedRecovery() {
        XCTAssertFalse(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: false,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(
            ownership: .watch
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.shouldStartExtendedRuntime(
            userInitiatedTakeover: false,
            applicationIsActive: true,
            ownership: .watch,
            alreadyHasSession: false
        ))
    }

    func testSystemAutoReconnectDoesNotStartParallelManualConnection() {
        let action = LibreWatchLifecyclePolicy.disconnectRecoveryAction(
            isDeliberate: false,
            systemIsReconnecting: true,
            ownership: .watch
        )

        XCTAssertEqual(action, .waitForSystemReconnect)
        XCTAssertNotEqual(action, .reconnectManually)
    }

    func testLongInactivePeriodPreservesEventDrivenRecoveryAfterForegroundRefresh() {
        XCTAssertFalse(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: false,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: true,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(
            ownership: .watch
        ))
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.disconnectRecoveryAction(
                isDeliberate: false,
                systemIsReconnecting: true,
                ownership: .watch
            ),
            .waitForSystemReconnect
        )
    }

    func testInactiveWatchOwnerAllowsOnlyOneManualConnectPerDisconnectDelivery() {
        let action = LibreWatchLifecyclePolicy.disconnectRecoveryAction(
            isDeliberate: false,
            systemIsReconnecting: false,
            ownership: .watch
        )
        var disconnectWasHandled = false
        var manualConnectCount = 0

        for _ in 0 ..< 2 {
            guard LibreWatchLifecyclePolicy.shouldHandleDisconnect(
                alreadyHandled: disconnectWasHandled
            ) else { continue }
            disconnectWasHandled = true
            if action == .reconnectManually {
                manualConnectCount += 1
            }
        }

        XCTAssertEqual(action, .reconnectManually)
        XCTAssertEqual(manualConnectCount, 1)
    }

    func testSuspendedWatchOwnerStartsNoFallbackTimerOrScanLoop() {
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.reconnectFallbackAction(
                deadline: receivedAt.addingTimeInterval(90),
                now: receivedAt.addingTimeInterval(300),
                applicationIsActive: false,
                extendedRuntimeIsRunning: false,
                ownership: .watch
            ),
            .noAdditionalWork
        )
        XCTAssertNil(LibreWatchLifecyclePolicy.noDataRecoveryDelay(
            applicationIsActive: false,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
    }

    func testReceivingSuspensionResumesBudgetWithoutImmediateBluetoothAction() throws {
        var timing = LibreWatchConnectionTiming()
        let firstFrameAt = receivedAt
        timing.receivedPacketOrEnabledNotifications(at: firstFrameAt)
        timing.recordReceivingProgress(
            at: firstFrameAt,
            timeout: 120,
            executionIsAvailable: true,
            monotonicTime: 1_000
        )
        let generation = timing.generation
        let beforeSuspension = try XCTUnwrap(timing.deadline)

        let suspendedAt = firstFrameAt.addingTimeInterval(30)
        XCTAssertTrue(timing.setExecutionAvailable(
            false,
            at: suspendedAt,
            monotonicTime: 1_030
        ))
        XCTAssertNil(timing.deadline)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(
                at: suspendedAt,
                monotonicTime: 1_030
            )),
            90,
            accuracy: 0.000_001
        )

        // Several wall-clock minutes without execution do not consume the paused allowance.
        let resumedAt = suspendedAt.addingTimeInterval(20 * 60)
        XCTAssertTrue(timing.setExecutionAvailable(
            true,
            at: resumedAt,
            monotonicTime: 2_500
        ))
        let resumed = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(timing.generation, generation)
        XCTAssertEqual(resumed.expiresAt, resumedAt.addingTimeInterval(90))
        XCTAssertFalse(timing.timeoutIsCurrent(
            beforeSuspension,
            ownership: .watch,
            cancelling: false,
            at: resumedAt,
            monotonicTime: 2_500
        ))
        XCTAssertFalse(timing.timeoutIsCurrent(
            resumed,
            ownership: .watch,
            cancelling: false,
            at: resumedAt,
            monotonicTime: 2_500
        ))
        let timeoutIsDue = timing.timeoutIsCurrent(
            resumed,
            ownership: .watch,
            cancelling: false,
            at: resumedAt,
            monotonicTime: 2_500
        )
        let recordedBluetoothActions: [LibreWatchExpiredPhaseAction] = timeoutIsDue
            ? [LibreWatchExpiredPhasePolicy.action(
                phase: timing.phase,
                peripheralState: .connected,
                ownership: .watch,
                cancellationIsActive: false
            )]
            : []
        XCTAssertTrue(recordedBluetoothActions.isEmpty) // no cancel, scan, or connect
    }

    func testValidFrameAfterResumeInvalidatesOldTimerBeforeDownstreamDecision() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        timing.recordReceivingProgress(
            at: receivedAt,
            timeout: 120,
            executionIsAvailable: true,
            monotonicTime: 100
        )
        XCTAssertTrue(timing.setExecutionAvailable(
            false,
            at: receivedAt.addingTimeInterval(20),
            monotonicTime: 120
        ))
        let resumedAt = receivedAt.addingTimeInterval(900)
        XCTAssertTrue(timing.setExecutionAvailable(
            true,
            at: resumedAt,
            monotonicTime: 900
        ))
        let resumeTimer = try XCTUnwrap(timing.deadline)

        var liveness = LibreWatchFrameLiveness()
        let frameAt = resumedAt.addingTimeInterval(61)
        liveness.validFrame(at: frameAt)
        timing.receivedPacketOrEnabledNotifications(at: frameAt)
        timing.recordReceivingProgress(
            at: frameAt,
            timeout: 120,
            executionIsAvailable: true,
            monotonicTime: 961
        )
        let accepted = false // duplicate/out-of-order clinical payload

        XCTAssertFalse(accepted)
        XCTAssertEqual(liveness.lastValidBLEFrameAt, frameAt)
        XCTAssertEqual(timing.dataExpectedSince, frameAt)
        XCTAssertFalse(timing.timeoutIsCurrent(
            resumeTimer,
            ownership: .watch,
            cancelling: false,
            at: resumeTimer.expiresAt,
            monotonicTime: try XCTUnwrap(resumeTimer.monotonicExpiresAt)
        ))
        XCTAssertNotEqual(timing.deadline?.token, resumeTimer.token)
    }

    func testRestoredConnectedStreamWaitsForPoweredOnThenReusesExactNotificationStream() {
        let generation = UUID()
        var restoration = LibreWatchRestorationState(
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: generation
        )

        XCTAssertEqual(restorationAction(
            &restoration,
            generation: generation,
            centralIsPoweredOn: false
        ), .waitForBluetooth)
        XCTAssertFalse(restoration.awaitingStreamEvidence)

        XCTAssertEqual(restorationAction(
            &restoration,
            generation: generation
        ), .awaitExistingStream)
        XCTAssertTrue(restoration.awaitingStreamEvidence)
    }

    func testPartialRestorationDiscoversOnlyTheFirstMissingLayer() {
        let generation = UUID()
        XCTAssertEqual(freshRestorationAction(
            generation: generation,
            hasService: false,
            hasWriteCharacteristic: false,
            hasReceiveCharacteristic: false,
            receiveIsNotifying: false
        ),
                       .discoverServices)
        XCTAssertEqual(freshRestorationAction(
            generation: generation,
            hasService: true,
            hasWriteCharacteristic: true,
            hasReceiveCharacteristic: false,
            receiveIsNotifying: false
        ),
                       .discoverCharacteristics)
        XCTAssertEqual(freshRestorationAction(
            generation: generation,
            hasService: true,
            hasWriteCharacteristic: true,
            hasReceiveCharacteristic: true,
            receiveIsNotifying: false
        ),
                       .enableNotifications)
        XCTAssertEqual(freshRestorationAction(
            generation: generation,
            hasService: true,
            hasWriteCharacteristic: true,
            hasReceiveCharacteristic: true,
            receiveIsNotifying: true
        ),
                       .awaitExistingStream)
    }

    func testDisconnectedRestorationDiscardsStaleGATTGraphBeforeReconnect() {
        let restoredGeneration = UUID()
        let reconnectedGeneration = UUID()
        var restoration = LibreWatchRestorationState(
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: restoredGeneration
        )

        // CoreBluetooth service/characteristic objects restored for the old link are invalid
        // after a real disconnect, even if their UUIDs and isNotifying flags still look usable.
        restoration.beginConnectionGeneration(reconnectedGeneration)
        XCTAssertEqual(restorationAction(
            &restoration,
            generation: reconnectedGeneration,
            hasService: true,
            hasWriteCharacteristic: true,
            hasReceiveCharacteristic: true,
            receiveIsNotifying: true
        ), .discoverServices)
    }

    func testRestorationObjectGraphIsReusableOnlyForAnActuallyConnectedRestore() {
        let generation = UUID()
        var connected = LibreWatchRestorationState(
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: generation,
            mayReuseRestoredObjectGraph: true
        )
        var disconnected = LibreWatchRestorationState(
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: generation,
            mayReuseRestoredObjectGraph: false
        )

        XCTAssertEqual(restorationAction(&connected, generation: generation), .awaitExistingStream)
        XCTAssertEqual(restorationAction(&disconnected, generation: generation), .discoverServices)
    }

    func testDidConnectRetiresStaleRestoredSetupAndReceivingGraphs() {
        for interruptedPhase in [
            LibreWatchConnectionTiming.Phase.services,
            .characteristics,
            .receiving
        ] {
            var timing = LibreWatchConnectionTiming()
            if interruptedPhase == .receiving {
                timing.receivedPacketOrEnabledNotifications(at: receivedAt)
            } else {
                timing.beginSetup(at: receivedAt, startingAt: interruptedPhase)
            }
            let oldGeneration = timing.generation
            var restoration = LibreWatchRestorationState(
                sessionID: session.id,
                sensorIdentity: session.redactedIdentity(),
                generation: oldGeneration,
                mayReuseRestoredObjectGraph: true
            )

            XCTAssertTrue(timing.acceptDidConnect(
                at: receivedAt.addingTimeInterval(1),
                applicationIsActive: false
            ))
            restoration.beginConnectionGeneration(timing.generation)

            XCTAssertNotEqual(timing.generation, oldGeneration)
            XCTAssertEqual(restorationAction(
                &restoration,
                generation: timing.generation,
                connectionPhase: timing.phase
            ), .discoverServices)
        }
    }

    func testRestoredPeripheralSelectionRequiresOneObservedExactName() {
        let expected = session.expectedPeripheralName
        XCTAssertEqual(
            LibreWatchRestoredPeripheralSelection.select(
                observedNames: ["WRONG", expected, nil], expectedSession: session
            ),
            .match(index: 1)
        )
        XCTAssertEqual(
            LibreWatchRestoredPeripheralSelection.unselectedIndices(count: 3, selectedIndex: 1),
            [0, 2]
        )
        XCTAssertEqual(
            LibreWatchRestoredPeripheralSelection.select(
                observedNames: [nil], expectedSession: session
            ),
            .unresolved
        )
        XCTAssertEqual(
            LibreWatchRestoredPeripheralSelection.select(
                observedNames: ["WRONG"], expectedSession: session
            ),
            .mismatch
        )
        XCTAssertEqual(
            LibreWatchRestoredPeripheralSelection.select(
                observedNames: [expected, expected], expectedSession: session
            ),
            .ambiguous
        )
    }

    func testRepeatedRestorationCallbacksDoNotRenewInFlightGATTBudget() throws {
        let generation = UUID()
        var restoration = LibreWatchRestorationState(
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: generation
        )
        var timing = LibreWatchConnectionTiming()
        timing.beginSetup(at: receivedAt, startingAt: .notifications)
        let original = try XCTUnwrap(timing.deadline)

        for _ in 0 ..< 5 {
            XCTAssertEqual(restorationAction(
                &restoration,
                generation: generation,
                connectionPhase: timing.phase
            ), .waitForCurrentOperation)
        }
        XCTAssertEqual(timing.deadline, original)
    }

    func testUnknownRestoredUnlockStatusGetsOneBoundedUnlockAttempt() throws {
        let generation = UUID()
        let token = UUID()
        var restoration = LibreWatchRestorationState(
            token: token,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: generation
        )
        XCTAssertEqual(restorationAction(
            &restoration,
            generation: generation
        ), .awaitExistingStream)

        XCTAssertTrue(restoration.claimUnknownUnlockRecovery(
            capturedToken: token,
            currentGeneration: generation,
            phase: .notifications,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            ownership: .watch,
            cancellationIsActive: false
        ))
        XCTAssertFalse(restoration.claimUnknownUnlockRecovery(
            capturedToken: token,
            currentGeneration: generation,
            phase: .notifications,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            ownership: .watch,
            cancellationIsActive: false
        ))
    }

    func testRestoredFrameEvidencePreventsFallbackUnlockAndPreservesStream() {
        let generation = UUID()
        let token = UUID()
        var restoration = LibreWatchRestorationState(
            token: token,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: generation
        )
        restoration.beginAwaitingStreamEvidence()
        restoration.recordStreamEvidence()

        XCTAssertFalse(restoration.claimUnknownUnlockRecovery(
            capturedToken: token,
            currentGeneration: generation,
            phase: .notifications,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            ownership: .watch,
            cancellationIsActive: false
        ))
        XCTAssertEqual(restorationAction(
            &restoration,
            generation: generation,
            connectionPhase: .receiving
        ), .preserveActiveStream)
    }

    func testNewRestoredConnectionGenerationRequiresFreshStreamEvidence() {
        let oldGeneration = UUID()
        var restoration = LibreWatchRestorationState(
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: oldGeneration
        )
        restoration.beginAwaitingStreamEvidence()
        restoration.recordStreamEvidence()

        let newGeneration = UUID()
        restoration.beginConnectionGeneration(newGeneration)

        XCTAssertEqual(restoration.generation, newGeneration)
        XCTAssertFalse(restoration.streamEvidenceWasReceived)
        XCTAssertFalse(restoration.awaitingStreamEvidence)
        XCTAssertFalse(restoration.unlockWasRequested)
        XCTAssertEqual(restorationAction(
            &restoration,
            generation: newGeneration
        ), .discoverServices)
    }

    func testRestorationRejectsChangedOwnershipSessionGenerationAndStaleObjects() {
        let generation = UUID()
        let token = UUID()
        var restoration = LibreWatchRestorationState(
            token: token,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: generation
        )
        restoration.beginAwaitingStreamEvidence()

        XCTAssertFalse(restoration.claimUnknownUnlockRecovery(
            capturedToken: token,
            currentGeneration: generation,
            phase: .notifications,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            ownership: .iphone,
            cancellationIsActive: false
        ))
        XCTAssertFalse(restoration.claimUnknownUnlockRecovery(
            capturedToken: token,
            currentGeneration: UUID(),
            phase: .notifications,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            ownership: .watch,
            cancellationIsActive: false
        ))
        XCTAssertFalse(restoration.claimUnknownUnlockRecovery(
            capturedToken: token,
            currentGeneration: generation,
            phase: .notifications,
            sessionID: UUID(),
            sensorIdentity: session.redactedIdentity(),
            ownership: .watch,
            cancellationIsActive: false
        ))

        let current = NSObject()
        let stale = NSObject()
        XCTAssertTrue(LibreWatchRestoredObjectIdentity.isCurrent(current, expected: current))
        XCTAssertFalse(LibreWatchRestoredObjectIdentity.isCurrent(stale, expected: current))
        XCTAssertFalse(LibreWatchRestoredObjectIdentity.isCurrent(current, expected: nil))
    }

    func testRestoredGATTPhaseHasFreshBudgetIndependentOfOldConnectionAge() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(at: receivedAt, applicationIsActive: false)
        let oldConnection = try XCTUnwrap(timing.deadline)
        let connectedAt = receivedAt.addingTimeInterval(300)
        timing.beginSetup(at: connectedAt, startingAt: .notifications)
        let restoredSetup = try XCTUnwrap(timing.deadline)

        XCTAssertEqual(timing.phase, .notifications)
        XCTAssertEqual(restoredSetup.expiresAt, connectedAt.addingTimeInterval(60))
        XCTAssertFalse(timing.timeoutIsCurrent(
            oldConnection,
            ownership: .watch,
            cancelling: false,
            at: oldConnection.expiresAt
        ))
    }

    func testReceivingBudgetExpiresOnceAndStillRequiresConfirmedCancellation() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        timing.recordReceivingProgress(
            at: receivedAt,
            timeout: 120,
            executionIsAvailable: true,
            monotonicTime: 1_000
        )
        let deadline = try XCTUnwrap(timing.deadline)
        let expiryUptime = try XCTUnwrap(deadline.monotonicExpiresAt)
        XCTAssertTrue(timing.timeoutIsCurrent(
            deadline,
            ownership: .watch,
            cancelling: false,
            at: deadline.expiresAt,
            monotonicTime: expiryUptime
        ))
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: timing.phase,
                peripheralState: .connected,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .beginControlledRecovery
        )

        timing.beginCancellation(at: deadline.expiresAt)
        XCTAssertFalse(timing.timeoutIsCurrent(
            deadline,
            ownership: .watch,
            cancelling: true,
            at: deadline.expiresAt,
            monotonicTime: expiryUptime
        ))
        XCTAssertFalse(timing.canStartBluetoothOperation)
        let cancellation = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(timing.finishCancellation(
            cancellation,
            ownership: .watch,
            returningToPhone: false,
            peripheralIsDisconnected: true,
            at: deadline.expiresAt.addingTimeInterval(1)
        ), .confirmedDisconnected)
        XCTAssertTrue(timing.canStartBluetoothOperation)
    }

    func testReceivingLifecycleChurnCannotRefillFiniteExecutionBudget() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        timing.recordReceivingProgress(
            at: receivedAt,
            timeout: 120,
            executionIsAvailable: true,
            monotonicTime: 0
        )
        let generation = timing.generation
        var wallTime = receivedAt
        var uptime: TimeInterval = 0

        for (cycle, consumed) in [30.0, 20.0, 20.0].enumerated() {
            wallTime = wallTime.addingTimeInterval(consumed)
            uptime += consumed
            XCTAssertTrue(timing.setExecutionAvailable(
                false,
                at: wallTime,
                monotonicTime: uptime
            ))
            wallTime = wallTime.addingTimeInterval(10_000)
            let remaining = try XCTUnwrap(timing.remainingExecutionTime(
                at: wallTime,
                monotonicTime: uptime
            ))
            XCTAssertEqual(remaining, 90 - TimeInterval(cycle * 20), accuracy: 0.000_001)
            XCTAssertFalse(timing.setExecutionAvailable(
                false,
                at: wallTime,
                monotonicTime: uptime
            ))
            XCTAssertTrue(timing.setExecutionAvailable(
                true,
                at: wallTime,
                monotonicTime: uptime
            ))
        }

        XCTAssertEqual(timing.generation, generation)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(
                at: wallTime.addingTimeInterval(20),
                monotonicTime: 90
            )),
            30,
            accuracy: 0.000_001
        )
    }

    func testInactiveAndBackgroundRemainDistinctWithoutClaimingTimerExecution() {
        XCTAssertTrue(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationState: .active,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationState: .inactive,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationState: .background,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationState: .inactive,
            extendedRuntimeIsRunning: true,
            ownership: .watch
        ))
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.receivingExecutionBudget(
                applicationState: .active,
                extendedRuntimeIsRunning: false
            ),
            120
        )
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.receivingExecutionBudget(
                applicationState: .background,
                extendedRuntimeIsRunning: true
            ),
            180
        )
    }

    func testExpiredReceivingTimerReconcilesSystemReconnectInsteadOfCancellingIt() {
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .receiving,
                peripheralState: .connecting,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .reconcileObservedLink
        )
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .notifications,
                peripheralState: .disconnected,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .reconcileObservedLink
        )
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .connection,
                peripheralState: .connected,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .beginGATTSetup
        )
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .connection,
                peripheralState: .connecting,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .beginControlledRecovery
        )
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .connection,
                peripheralState: .disconnected,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .beginControlledRecovery,
            "an expired system reconnect must not reschedule the same zero-second deadline"
        )
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .receiving,
                peripheralState: .connected,
                ownership: .iphone,
                cancellationIsActive: false
            ),
            .noAdditionalWork
        )
    }

    func testConnectionBudgetsStartWithSixtyForegroundOrNinetyRuntimeSeconds() throws {
        for (active, duration) in [(true, 60.0), (false, 90.0)] {
            var timing = LibreWatchConnectionTiming()
            timing.beginConnection(
                at: receivedAt,
                applicationIsActive: active,
                executionIsAvailable: true
            )
            let deadline = try XCTUnwrap(timing.deadline)
            XCTAssertEqual(deadline.expiresAt, receivedAt.addingTimeInterval(duration))
            XCTAssertEqual(
                try XCTUnwrap(timing.remainingExecutionTime(at: receivedAt)),
                duration,
                accuracy: 0.000_001
            )
            XCTAssertFalse(timing.timeoutIsCurrent(
                deadline, ownership: .watch, cancelling: false,
                at: receivedAt.addingTimeInterval(duration - 1)
            ))
            XCTAssertTrue(timing.timeoutIsCurrent(
                deadline, ownership: .watch, cancelling: false, at: deadline.expiresAt
            ))
        }
    }

    func testEighteenMinuteTwentyNineSecondSuspensionPreservesRemainingExecutionBudget() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(
            at: receivedAt,
            applicationIsActive: true,
            executionIsAvailable: true
        )
        let prePause = try XCTUnwrap(timing.deadline)
        let pausedAt = receivedAt.addingTimeInterval(12)

        XCTAssertTrue(timing.setExecutionAvailable(false, at: pausedAt))
        XCTAssertNil(timing.deadline)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: pausedAt)),
            48,
            accuracy: 0.000_001
        )
        XCTAssertFalse(timing.timeoutIsCurrent(
            prePause,
            ownership: .watch,
            cancelling: false,
            at: pausedAt.addingTimeInterval(18 * 60 + 29)
        ))

        let resumedAt = pausedAt.addingTimeInterval(18 * 60 + 29)
        XCTAssertTrue(timing.setExecutionAvailable(true, at: resumedAt))
        let resumed = try XCTUnwrap(timing.deadline)
        XCTAssertNotEqual(resumed.token, prePause.token)
        XCTAssertEqual(resumed.expiresAt, resumedAt.addingTimeInterval(48))
        XCTAssertFalse(timing.timeoutIsCurrent(
            resumed,
            ownership: .watch,
            cancelling: false,
            at: resumedAt.addingTimeInterval(47.999)
        ))
        XCTAssertTrue(timing.timeoutIsCurrent(
            resumed,
            ownership: .watch,
            cancelling: false,
            at: resumed.expiresAt
        ))
    }

    func testDocumentedBackgroundConnectingEpisodeStartsPausedAndDoesNotCancelOnWake() throws {
        var timing = LibreWatchConnectionTiming()
        let observedConnectingAt = receivedAt
        timing.beginConnection(
            at: observedConnectingAt,
            applicationIsActive: false,
            executionIsAvailable: false
        )
        let generation = timing.generation

        XCTAssertNil(timing.deadline)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: observedConnectingAt)),
            90,
            accuracy: 0.000_001
        )

        let foregroundWake = observedConnectingAt.addingTimeInterval(3 * 60 * 60)
        XCTAssertTrue(timing.setExecutionAvailable(true, at: foregroundWake))
        let armed = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(timing.generation, generation)
        XCTAssertEqual(armed.expiresAt, foregroundWake.addingTimeInterval(90))
        XCTAssertFalse(timing.timeoutIsCurrent(
            armed,
            ownership: .watch,
            cancelling: false,
            at: foregroundWake
        ))
    }

    func testOnlyCoreBluetoothCallbacksGrantEventDrivenBluetoothActions() {
        let callbackSources: [LibreWatchRecoveryReconcileSource] = [
            .centralStateUpdate,
            .stateRestoration,
            .didConnect,
            .didFailToConnect,
            .didDisconnect,
            .gattCallback,
            .bleNotification
        ]
        let lifecycleAndTimerSources: [LibreWatchRecoveryReconcileSource] = [
            .initialPreparation,
            .sceneActivation,
            .sceneDeactivation,
            .sceneInactive,
            .sceneBackground,
            .extendedRuntimeStarted,
            .extendedRuntimeWillExpire,
            .extendedRuntimeInvalidated,
            .healthTimer,
            .executionBudgetExpired,
            .cancellationWatchdog
        ]

        for source in callbackSources {
            XCTAssertTrue(source.grantsEventDrivenBluetoothAction, "Expected callback source: \(source)")
        }
        for source in lifecycleAndTimerSources {
            XCTAssertFalse(source.grantsEventDrivenBluetoothAction, "Expected passive source: \(source)")
        }
    }

    func testRepeatedWakeTransitionsDoNotRefillOrMoveActiveBudget() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(
            at: receivedAt,
            applicationIsActive: false,
            executionIsAvailable: true
        )
        let generation = timing.generation
        let pausedAt = receivedAt.addingTimeInterval(20)
        XCTAssertTrue(timing.setExecutionAvailable(false, at: pausedAt))
        XCTAssertFalse(timing.setExecutionAvailable(false, at: pausedAt.addingTimeInterval(300)))
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: pausedAt.addingTimeInterval(300))),
            70,
            accuracy: 0.000_001
        )

        let resumedAt = pausedAt.addingTimeInterval(600)
        XCTAssertTrue(timing.setExecutionAvailable(true, at: resumedAt))
        let activeDeadline = try XCTUnwrap(timing.deadline)
        XCTAssertFalse(timing.setExecutionAvailable(true, at: resumedAt.addingTimeInterval(10)))
        XCTAssertEqual(timing.deadline, activeDeadline)
        XCTAssertEqual(timing.generation, generation)

        let secondPause = resumedAt.addingTimeInterval(25)
        XCTAssertTrue(timing.setExecutionAvailable(false, at: secondPause))
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: secondPause)),
            45,
            accuracy: 0.000_001
        )
    }

    func testPrePauseTimerIsStaleEvenWhenPauseAndResumeShareTimestamp() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(
            at: receivedAt,
            applicationIsActive: true,
            executionIsAvailable: true
        )
        let old = try XCTUnwrap(timing.deadline)
        let transitionAt = receivedAt.addingTimeInterval(10)
        XCTAssertTrue(timing.setExecutionAvailable(false, at: transitionAt))
        XCTAssertTrue(timing.setExecutionAvailable(true, at: transitionAt))
        let current = try XCTUnwrap(timing.deadline)

        XCTAssertNotEqual(old.token, current.token)
        XCTAssertEqual(current.expiresAt, old.expiresAt)
        XCTAssertFalse(timing.timeoutIsCurrent(
            old,
            ownership: .watch,
            cancelling: false,
            at: old.expiresAt
        ))
        XCTAssertTrue(timing.timeoutIsCurrent(
            current,
            ownership: .watch,
            cancelling: false,
            at: current.expiresAt
        ))
    }

    func testLegacyDisconnectIsAcceptedSynchronouslyAndModernDuplicateIsRejected() {
        var gate = LibreWatchDisconnectGate()
        XCTAssertTrue(gate.accept())
        XCTAssertTrue(gate.handled)
        XCTAssertFalse(gate.accept(), "the later modern callback remains a duplicate")
    }

    func testDidConnectResetAllowsTheNextRealDisconnect() {
        var gate = LibreWatchDisconnectGate()
        XCTAssertTrue(gate.accept())
        gate.reset() // Accepted didConnect.
        XCTAssertFalse(gate.handled)
        XCTAssertTrue(gate.accept())
    }

    func testReceivingThenObservedConnectingWithoutAnyDisconnectCreatesOneDeadline() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        // The real failure: receiving with no disconnect callback and NO pre-created deadline.
        XCTAssertEqual(timing.phase, .receiving)
        XCTAssertNil(timing.deadline)
        let observedAt = receivedAt.addingTimeInterval(93)
        XCTAssertTrue(timing.observeLink(
            connected: false, connecting: true, hasReceptionState: true,
            at: observedAt, applicationIsActive: true
        ))
        let deadline = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(deadline.expiresAt, observedAt.addingTimeInterval(60))
        XCTAssertEqual(timing.phase, .connection)
        XCTAssertNil(timing.dataExpectedSince)
        XCTAssertFalse(timing.setupInProgress)
        XCTAssertFalse(timing.canStartBluetoothOperation)
        for seconds in [1.0, 20.0, 80.0] {
            XCTAssertFalse(timing.observeLink(
                connected: false, connecting: true, hasReceptionState: false,
                at: observedAt.addingTimeInterval(seconds), applicationIsActive: false
            ))
            XCTAssertEqual(timing.deadline, deadline)
        }
    }

    func testDisconnectedOrDisconnectingObservationClearsOldSetupOnlyOnce() {
        var timing = LibreWatchConnectionTiming()
        timing.beginSetup(at: receivedAt)
        XCTAssertTrue(timing.observeLink(
            connected: false, connecting: false, hasReceptionState: true,
            at: receivedAt.addingTimeInterval(5), applicationIsActive: false
        ))
        XCTAssertNil(timing.deadline)
        XCTAssertNil(timing.dataExpectedSince)
        XCTAssertFalse(timing.setupInProgress)
        XCTAssertFalse(timing.observeLink(
            connected: false, connecting: false, hasReceptionState: false,
            at: receivedAt.addingTimeInterval(6), applicationIsActive: true
        ))
    }

    func testDidConnectEndsConnectionTimeoutAndStartsFreshGATTIndependentOfOldPacket() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        timing.observeLink(
            connected: false, connecting: true, hasReceptionState: true,
            at: receivedAt.addingTimeInterval(93), applicationIsActive: true
        )
        let oldConnection = try XCTUnwrap(timing.deadline)
        let connectedAt = receivedAt.addingTimeInterval(600)
        timing.beginSetup(at: connectedAt) // didConnect wins before queued timeout cancellation.
        let setup = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(setup.expiresAt, connectedAt.addingTimeInterval(60))
        XCTAssertFalse(timing.timeoutIsCurrent(
            oldConnection, ownership: .watch, cancelling: false, at: connectedAt
        ))
        XCTAssertFalse(timing.timeoutIsCurrent(
            setup, ownership: .watch, cancelling: false, at: connectedAt.addingTimeInterval(13)
        ))
        XCTAssertFalse(timing.noDataIsOverdue(
            lastPacketAt: receivedAt, at: connectedAt.addingTimeInterval(13), timeout: 120
        ))
    }

    func testEveryGATTProgressRefreshesWatchdogAndUnlockStartsFreshNoDataGrace() throws {
        var timing = LibreWatchConnectionTiming()
        let connectedAt = receivedAt.addingTimeInterval(600)
        timing.beginSetup(at: connectedAt)
        let stages: [LibreWatchConnectionTiming.Phase] = [.services, .characteristics, .notifications, .unlock]
        var progressAt = connectedAt
        for stage in stages {
            let old = try XCTUnwrap(timing.deadline)
            progressAt = progressAt.addingTimeInterval(59)
            XCTAssertTrue(timing.setupProgress(stage, at: progressAt))
            XCTAssertFalse(timing.timeoutIsCurrent(
                old, ownership: .watch, cancelling: false, at: old.expiresAt
            ))
            if stage != .unlock {
                XCTAssertEqual(timing.deadline?.expiresAt, progressAt.addingTimeInterval(60))
            }
        }
        XCTAssertNil(timing.deadline)
        XCTAssertFalse(timing.setupInProgress)
        XCTAssertEqual(timing.phase, .receiving)
        XCTAssertEqual(timing.dataExpectedSince, progressAt)
        for limit in [120.0, 180.0] {
            XCTAssertFalse(timing.noDataIsOverdue(
                lastPacketAt: receivedAt, at: progressAt.addingTimeInterval(limit - 1), timeout: limit
            ))
            XCTAssertTrue(timing.noDataIsOverdue(
                lastPacketAt: receivedAt, at: progressAt.addingTimeInterval(limit), timeout: limit
            ))
        }
    }

    func testGATTProgressAtDeadlineWinsUnlessCancellationAlreadyStarted() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginSetup(at: receivedAt)
        let old = try XCTUnwrap(timing.deadline)
        XCTAssertTrue(timing.setupProgress(.services, at: old.expiresAt))
        XCTAssertFalse(timing.timeoutIsCurrent(
            old, ownership: .watch, cancelling: false, at: old.expiresAt
        ))
        let current = try XCTUnwrap(timing.deadline)
        XCTAssertTrue(timing.timeoutIsCurrent(
            current, ownership: .watch, cancelling: false, at: current.expiresAt
        ))
        timing.invalidate() // Controlled cancellation has begun on the serial main queue.
        XCTAssertFalse(timing.setupProgress(.characteristics, at: current.expiresAt))
        XCTAssertNil(timing.deadline)
    }

    func testPausedGATTCallbacksAdvanceAndReceiveFreshPausedBudgets() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginSetup(at: receivedAt, executionIsAvailable: false)
        XCTAssertEqual(timing.phase, .services)
        XCTAssertNil(timing.deadline)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: receivedAt)),
            60,
            accuracy: 0.000_001
        )

        let servicesAt = receivedAt.addingTimeInterval(600)
        XCTAssertTrue(timing.setupProgress(
            .services,
            at: servicesAt,
            executionIsAvailable: false
        ))
        XCTAssertEqual(timing.phase, .characteristics)
        XCTAssertNil(timing.deadline)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: servicesAt)),
            60,
            accuracy: 0.000_001
        )

        XCTAssertTrue(timing.setExecutionAvailable(true, at: servicesAt))
        let characteristicsDeadline = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(characteristicsDeadline.expiresAt, servicesAt.addingTimeInterval(60))

        XCTAssertTrue(timing.setupProgress(
            .characteristics,
            at: characteristicsDeadline.expiresAt,
            executionIsAvailable: true
        ))
        XCTAssertEqual(timing.phase, .notifications)
        XCTAssertFalse(timing.timeoutIsCurrent(
            characteristicsDeadline,
            ownership: .watch,
            cancelling: false,
            at: characteristicsDeadline.expiresAt
        ))
        XCTAssertEqual(
            timing.deadline?.expiresAt,
            characteristicsDeadline.expiresAt.addingTimeInterval(60)
        )
    }

    func testStaleTimersCannotCancelNewAttemptSetupOrHealthyNotifications() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(at: receivedAt, applicationIsActive: true)
        let oldAttempt = try XCTUnwrap(timing.deadline)
        timing.invalidate() // An explicitly retired generation permits a new attempt.
        timing.beginConnection(at: receivedAt.addingTimeInterval(1), applicationIsActive: false)
        let currentAttempt = try XCTUnwrap(timing.deadline)
        XCTAssertNotEqual(oldAttempt.token, currentAttempt.token)
        XCTAssertFalse(timing.timeoutIsCurrent(
            oldAttempt, ownership: .watch, cancelling: false, at: oldAttempt.expiresAt
        ))
        timing.beginSetup(at: receivedAt.addingTimeInterval(2))
        let setup = try XCTUnwrap(timing.deadline)
        timing.receivedPacketOrEnabledNotifications(at: receivedAt.addingTimeInterval(3))
        for retired in [oldAttempt, currentAttempt, setup] {
            XCTAssertFalse(timing.timeoutIsCurrent(
                retired, ownership: .watch, cancelling: false, at: receivedAt.addingTimeInterval(300)
            ))
        }
    }

    func testReturnToPhoneInvalidatesAllWatchTimingAndPreventsFurtherRecovery() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginSetup(at: receivedAt)
        let old = try XCTUnwrap(timing.deadline)
        timing.invalidate()
        XCTAssertNil(timing.phase)
        XCTAssertNil(timing.dataExpectedSince)
        XCTAssertFalse(timing.setupProgress(.services, at: old.expiresAt))
        XCTAssertFalse(timing.timeoutIsCurrent(
            old, ownership: .iphone, cancelling: false, at: old.expiresAt
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(ownership: .iphone))
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.reconnectFallbackAction(
                deadline: old.expiresAt, now: old.expiresAt,
                applicationIsActive: true,
                extendedRuntimeIsRunning: true,
                ownership: .iphone
            ),
            .noAdditionalWork
        )
    }

    func testAnExistingConnectionOrSetupNeverStartsParallelScanOrConnect() {
        var timing = LibreWatchConnectionTiming()
        XCTAssertTrue(timing.canStartBluetoothOperation)
        timing.beginConnection(at: receivedAt, applicationIsActive: true)
        XCTAssertFalse(timing.canStartBluetoothOperation)
        timing.beginSetup(at: receivedAt.addingTimeInterval(10))
        XCTAssertFalse(timing.canStartBluetoothOperation)
        timing.receivedPacketOrEnabledNotifications(at: receivedAt.addingTimeInterval(15))
        XCTAssertFalse(timing.canStartBluetoothOperation)
        timing.invalidate() // Only the retired attempt releases the gate for filtered scanning.
        XCTAssertTrue(timing.canStartBluetoothOperation)
    }

    func testForegroundAndRuntimeNoDataRecoveryKeepTheirOwnLimits() {
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.noDataRecoveryDelay(
                applicationIsActive: true,
                extendedRuntimeIsRunning: true,
                ownership: .watch
            ),
            2 * 60
        )
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.noDataRecoveryDelay(
                applicationIsActive: false,
                extendedRuntimeIsRunning: true,
                ownership: .watch
            ),
            3 * 60
        )
    }

    func testRepeatedConnectionFailuresDoNotRefillBudgetOrChangeGeneration() throws {
        for activeAtStart in [true, false] {
            var timing = LibreWatchConnectionTiming()
            timing.beginConnection(
                at: receivedAt,
                applicationIsActive: activeAtStart,
                executionIsAvailable: true
            )
            let original = try XCTUnwrap(timing.deadline)
            let generation = timing.generation
            // didFailToConnect retries use the same beginConnection entry point, without
            // invalidating timing. No callback silently refills the phase budget.
            for seconds in [1.0, 15.0, 30.0, 59.0] {
                timing.beginConnection(at: receivedAt.addingTimeInterval(seconds),
                                       applicationIsActive: !activeAtStart,
                                       executionIsAvailable: true)
                XCTAssertEqual(timing.deadline, original)
                XCTAssertEqual(timing.generation, generation)
                let duration = activeAtStart ? 60.0 : 90.0
                XCTAssertEqual(
                    try XCTUnwrap(timing.remainingExecutionTime(
                        at: receivedAt.addingTimeInterval(seconds)
                    )),
                    duration - seconds,
                    accuracy: 0.000_001
                )
                XCTAssertTrue(timing.canConnect(at: receivedAt.addingTimeInterval(seconds),
                                                peripheralIsDisconnected: true,
                                                retiredPeripheralIsReleased: true))
            }
        }
    }

    func testRetryCannotRenewAnExhaustedExecutionBudget() throws {
        for activeAtStart in [true, false] {
            var timing = LibreWatchConnectionTiming()
            timing.beginConnection(
                at: receivedAt,
                applicationIsActive: activeAtStart,
                executionIsAvailable: true
            )
            let original = try XCTUnwrap(timing.deadline)
            XCTAssertEqual(
                timing.failedConnectionAction(
                    at: original.expiresAt.addingTimeInterval(-0.001),
                    bluetoothIsPoweredOn: true
                ),
                .retryConfirmedPeripheral
            )
            for delay in [0.0, 60.0, 600.0] {
                let now = original.expiresAt.addingTimeInterval(delay)
                timing.beginConnection(
                    at: now,
                    applicationIsActive: !activeAtStart,
                    executionIsAvailable: true
                )
                XCTAssertEqual(timing.deadline, original)
                XCTAssertFalse(timing.canConnect(at: now, peripheralIsDisconnected: true,
                                                 retiredPeripheralIsReleased: true))
                XCTAssertTrue(timing.timeoutIsCurrent(
                    original, ownership: .watch, cancelling: false, at: now
                ))
                XCTAssertEqual(
                    timing.failedConnectionAction(at: now, bluetoothIsPoweredOn: true),
                    .scanConfirmedSensor
                )
                XCTAssertEqual(
                    timing.failedConnectionAction(at: now, bluetoothIsPoweredOn: false),
                    .waitForBluetooth
                )
            }
        }
    }

    func testMissingCancelCallbackRetiresForOneFilteredScanAtWatchdogDeadline() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(at: receivedAt, applicationIsActive: true)
        timing.beginCancellation(at: receivedAt.addingTimeInterval(60))
        let cancellation = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(cancellation.expiresAt, receivedAt.addingTimeInterval(65))
        XCTAssertNil(timing.finishCancellation(
            cancellation, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: false, at: cancellation.expiresAt.addingTimeInterval(-1)
        ))
        XCTAssertFalse(timing.canStartBluetoothOperation)
        XCTAssertEqual(timing.finishCancellation(
            cancellation, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: false, at: cancellation.expiresAt
        ), .retireForScan)
        XCTAssertTrue(timing.canStartBluetoothOperation)
        XCTAssertNil(timing.finishCancellation(
            cancellation, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: false, at: cancellation.expiresAt.addingTimeInterval(30)
        ))
    }

    func testCancellationProofRemainsWallClockAndIgnoresExecutionPauses() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginCancellation(at: receivedAt)
        let cancellation = try XCTUnwrap(timing.deadline)

        XCTAssertFalse(timing.setExecutionAvailable(false, at: receivedAt.addingTimeInterval(1)))
        XCTAssertFalse(timing.setExecutionAvailable(true, at: receivedAt.addingTimeInterval(120)))
        XCTAssertEqual(timing.deadline, cancellation)
        XCTAssertNil(timing.finishCancellation(
            cancellation,
            ownership: .watch,
            returningToPhone: false,
            peripheralIsDisconnected: false,
            at: cancellation.expiresAt.addingTimeInterval(-0.001)
        ))
        XCTAssertEqual(timing.finishCancellation(
            cancellation,
            ownership: .watch,
            returningToPhone: false,
            peripheralIsDisconnected: false,
            at: cancellation.expiresAt
        ), .retireForScan)
    }

    func testOldCancellationWatchdogCannotAffectNewConnectionOrSetup() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginCancellation(at: receivedAt)
        let old = try XCTUnwrap(timing.deadline)
        let retiredGeneration = timing.generation
        XCTAssertEqual(timing.finishCancellation(
            old, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: true, at: receivedAt.addingTimeInterval(1)
        ), .confirmedDisconnected)
        timing.beginConnection(at: receivedAt.addingTimeInterval(2), applicationIsActive: true)
        let connection = timing.deadline
        XCTAssertNotEqual(timing.generation, retiredGeneration)
        XCTAssertNil(timing.finishCancellation(
            old, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: false, at: old.expiresAt
        ))
        XCTAssertEqual(timing.deadline, connection)
        timing.beginSetup(at: receivedAt.addingTimeInterval(3))
        let setup = timing.deadline
        XCTAssertNil(timing.finishCancellation(
            old, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: false, at: old.expiresAt
        ))
        XCTAssertEqual(timing.deadline, setup)
    }

    func testConfirmedCancellationWithoutDelegateCallbackCompletesOnlyOnce() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginCancellation(at: receivedAt)
        let deadline = try XCTUnwrap(timing.deadline)
        // A lifecycle/watchdog observation of native .disconnected is also confirmation.
        XCTAssertEqual(timing.finishCancellation(
            deadline, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: true, at: receivedAt.addingTimeInterval(1)
        ), .confirmedDisconnected)
        XCTAssertNil(timing.finishCancellation(
            deadline, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: true, at: deadline.expiresAt
        ))
    }

    func testReturnToPhoneTimeoutNeverSubstitutesForConfirmedDisconnection() throws {
        for ownership in [LibreWatchOwnership.watch, .iphone] {
            var timing = LibreWatchConnectionTiming()
            timing.receivedPacketOrEnabledNotifications(at: receivedAt)
            timing.beginCancellation(at: receivedAt)
            let deadline = try XCTUnwrap(timing.deadline)
            XCTAssertEqual(timing.finishCancellation(
                deadline, ownership: ownership, returningToPhone: true,
                peripheralIsDisconnected: false, at: deadline.expiresAt
            ), .awaitConfirmedDisconnection)
            XCTAssertTrue(timing.cancellationWatchdogDidFire)
            XCTAssertFalse(timing.canStartBluetoothOperation)
            XCTAssertNil(timing.finishCancellation(
                deadline, ownership: ownership, returningToPhone: true,
                peripheralIsDisconnected: false, at: deadline.expiresAt.addingTimeInterval(30)
            ))
            XCTAssertEqual(timing.finishCancellation(
                deadline, ownership: ownership, returningToPhone: true,
                peripheralIsDisconnected: true, at: deadline.expiresAt.addingTimeInterval(31)
            ), .confirmedDisconnected)
            XCTAssertFalse(LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(ownership: .iphone))
        }
    }

    func testCancellationAndRetiredPeripheralPreventParallelConnect() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginCancellation(at: receivedAt)
        let cancellation = timing.deadline
        timing.beginConnection(at: receivedAt, applicationIsActive: true)
        timing.beginSetup(at: receivedAt)
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        XCTAssertFalse(timing.observeLink(
            connected: false, connecting: true, hasReceptionState: true,
            at: receivedAt, applicationIsActive: true
        ))
        XCTAssertEqual(timing.phase, .cancelling)
        XCTAssertEqual(timing.deadline, cancellation)
        XCTAssertFalse(timing.canStartBluetoothOperation)
        timing.invalidate()
        timing.beginConnection(at: receivedAt, applicationIsActive: true)
        XCTAssertFalse(timing.canConnect(at: receivedAt, peripheralIsDisconnected: true,
                                         retiredPeripheralIsReleased: false))
        XCTAssertFalse(timing.canConnect(at: receivedAt, peripheralIsDisconnected: false,
                                         retiredPeripheralIsReleased: true))
        XCTAssertTrue(timing.canConnect(at: receivedAt, peripheralIsDisconnected: true,
                                        retiredPeripheralIsReleased: true))
    }

    func testInvalidFrameKeepsTechnicalNoDataMonitoringAndResetsAssembly() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        var liveness = LibreWatchFrameLiveness()
        var assembler = Libre2WatchDirectFrameAssembler()
        XCTAssertThrowsError(try assembler.append(
            fragment: Data(repeating: 0, count: Libre2WatchDirectConstants.encryptedFrameLength + 1),
            at: receivedAt.addingTimeInterval(60)
        ))
        assembler.reset() // Same catch path as the collector; UI failure does not alter timing.
        XCTAssertFalse(liveness.invalidFrame())
        XCTAssertEqual(assembler.assembledByteCount, 0)
        XCTAssertEqual(timing.phase, .receiving)
        XCTAssertEqual(timing.dataExpectedSince, receivedAt)
        XCTAssertTrue(timing.noDataIsOverdue(
            lastPacketAt: receivedAt, at: receivedAt.addingTimeInterval(120), timeout: 120
        ))
        XCTAssertNil(try assembler.append(
            fragment: Data(repeating: 0, count: 20), at: receivedAt.addingTimeInterval(121)
        ))
        XCTAssertEqual(assembler.assembledByteCount, 20)
    }

    func testValidFrameRecordsTechnicalLivenessAndResetsInvalidFrameCounter() {
        var liveness = LibreWatchFrameLiveness()
        let reading = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            at: receivedAt
        )
        var deliveryAcceptance = LibreWatchReadingAcceptancePolicy()
        XCTAssertTrue(deliveryAcceptance.accept(
            reading,
            for: session.id,
            now: receivedAt.addingTimeInterval(1)
        ))
        XCTAssertFalse(deliveryAcceptance.accept(
            reading,
            for: session.id,
            now: receivedAt.addingTimeInterval(2)
        ))
        XCTAssertFalse(liveness.invalidFrame())
        XCTAssertFalse(liveness.invalidFrame())
        XCTAssertEqual(liveness.consecutiveInvalidFrames, 2)
        let validFrameAt = receivedAt.addingTimeInterval(45)
        liveness.validFrame(at: validFrameAt)
        let livenessWasVisibleBeforeDownstreamRejection =
            liveness.lastValidBLEFrameAt == validFrameAt
        let downstreamAccepted = false
        XCTAssertFalse(downstreamAccepted)
        XCTAssertTrue(livenessWasVisibleBeforeDownstreamRejection)
        XCTAssertEqual(liveness.consecutiveInvalidFrames, 0)
        XCTAssertFalse(liveness.recoveryRequested)
        XCTAssertEqual(liveness.lastValidBLEFrameAt, validFrameAt)
        XCTAssertFalse(liveness.invalidFrame())
        XCTAssertEqual(liveness.consecutiveInvalidFrames, 1)
    }

    func testThreeConsecutiveInvalidFramesRequestExactlyOneRecovery() {
        var liveness = LibreWatchFrameLiveness()
        let requests = (0 ..< 10).map { _ in liveness.invalidFrame() }
        XCTAssertEqual(LibreWatchFrameLiveness.invalidFrameLimit, 3)
        XCTAssertEqual(Array(requests.prefix(3)), [false, false, true])
        XCTAssertEqual(requests.filter { $0 }.count, 1)
        XCTAssertEqual(liveness.consecutiveInvalidFrames, 3)
    }

    func testNewPhysicalConnectionRotatesAStaleSetupGeneration() {
        for interruptedPhase in [
            LibreWatchConnectionTiming.Phase.services,
            .characteristics,
            .notifications,
            .unlock,
            .receiving
        ] {
            var timing = LibreWatchConnectionTiming()
            if interruptedPhase == .receiving {
                timing.receivedPacketOrEnabledNotifications(at: receivedAt)
            } else {
                timing.beginSetup(at: receivedAt, startingAt: interruptedPhase)
            }
            let disconnectedGeneration = timing.generation

            XCTAssertTrue(timing.acceptDidConnect(
                at: receivedAt.addingTimeInterval(1),
                applicationIsActive: false
            ))
            timing.beginSetup(at: receivedAt.addingTimeInterval(1), startingAt: .services)

            XCTAssertNotEqual(timing.generation, disconnectedGeneration,
                "A new observed connection must not accept callbacks from the old \(interruptedPhase.rawValue) phase")
            XCTAssertTrue(timing.acceptsSetup(.services))
        }
    }

    func testBackToBackReconnectsRetireServicesAndCharacteristicsGenerations() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginSetup(at: receivedAt, startingAt: .services)
        let servicesGeneration = timing.generation
        let servicesDeadline = try XCTUnwrap(timing.deadline)

        XCTAssertTrue(timing.acceptDidConnect(
            at: receivedAt.addingTimeInterval(1),
            applicationIsActive: false
        ))
        timing.beginSetup(
            at: receivedAt.addingTimeInterval(1),
            startingAt: .services
        )
        XCTAssertTrue(timing.setupProgress(
            .services,
            at: receivedAt.addingTimeInterval(2)
        ))
        let characteristicsGeneration = timing.generation
        let characteristicsDeadline = try XCTUnwrap(timing.deadline)
        XCTAssertTrue(timing.acceptsSetup(.characteristics))

        XCTAssertTrue(timing.acceptDidConnect(
            at: receivedAt.addingTimeInterval(3),
            applicationIsActive: false
        ))
        let finalGeneration = timing.generation
        timing.beginSetup(
            at: receivedAt.addingTimeInterval(3),
            startingAt: .services
        )

        XCTAssertNotEqual(servicesGeneration, characteristicsGeneration)
        XCTAssertNotEqual(characteristicsGeneration, finalGeneration)
        XCTAssertNotEqual(servicesGeneration, finalGeneration)
        XCTAssertFalse(timing.timeoutIsCurrent(
            servicesDeadline,
            ownership: .watch,
            cancelling: false,
            at: servicesDeadline.expiresAt
        ))
        XCTAssertFalse(timing.timeoutIsCurrent(
            characteristicsDeadline,
            ownership: .watch,
            cancelling: false,
            at: characteristicsDeadline.expiresAt
        ))
        XCTAssertTrue(timing.acceptsSetup(.services))
    }

    func testCompletedConnectionKeepsItsAlreadyFreshGenerationWhenSetupBegins() {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(at: receivedAt, applicationIsActive: false)
        let connectionGeneration = timing.generation
        XCTAssertFalse(timing.acceptDidConnect(
            at: receivedAt.addingTimeInterval(1),
            applicationIsActive: false
        ))
        timing.beginSetup(at: receivedAt.addingTimeInterval(1), startingAt: .services)

        XCTAssertEqual(timing.generation, connectionGeneration)
        XCTAssertTrue(timing.acceptsSetup(.services))
    }

    func testServiceInvalidationRetiresOnlyTheGATTGeneration() {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        let oldGeneration = timing.generation
        timing.beginSetup(
            at: receivedAt.addingTimeInterval(1),
            startingAt: .services,
            retiringCurrentGeneration: true
        )

        XCTAssertNotEqual(timing.generation, oldGeneration)
        XCTAssertTrue(timing.acceptsSetup(.services))
    }

    func testDisconnectTimestampRejectsOlderCallbackOnlyWhileCurrentLinkIsConnected() {
        let connectedAt = receivedAt.addingTimeInterval(10)
        XCTAssertFalse(LibreWatchDisconnectTimestampPolicy.belongsToCurrentConnection(
            disconnectedAt: connectedAt.addingTimeInterval(-0.001),
            currentConnectionAcceptedAt: connectedAt,
            observedPeripheralState: .connected
        ))
        XCTAssertTrue(LibreWatchDisconnectTimestampPolicy.belongsToCurrentConnection(
            disconnectedAt: connectedAt,
            currentConnectionAcceptedAt: connectedAt,
            observedPeripheralState: .connected
        ))
        XCTAssertTrue(LibreWatchDisconnectTimestampPolicy.belongsToCurrentConnection(
            disconnectedAt: connectedAt,
            currentConnectionAcceptedAt: nil,
            observedPeripheralState: .connected
        ))
        XCTAssertTrue(LibreWatchDisconnectTimestampPolicy.belongsToCurrentConnection(
            disconnectedAt: connectedAt.addingTimeInterval(-0.001),
            currentConnectionAcceptedAt: connectedAt,
            observedPeripheralState: .disconnected
        ))
    }

    func testCurrentServiceInvalidationUsesObjectIdentity() {
        let current = NSObject()
        let unrelated = NSObject()
        XCTAssertTrue(LibreWatchRestoredObjectIdentity.containsCurrent(
            [unrelated, current], expected: current
        ))
        XCTAssertFalse(LibreWatchRestoredObjectIdentity.containsCurrent(
            [unrelated], expected: current
        ))
        XCTAssertFalse(LibreWatchRestoredObjectIdentity.containsCurrent(
            [current], expected: nil
        ))
    }

    func testLegacyDiagnosticEventsStillDecodeWithoutNewContext() throws {
        let data = Data(#"{"kind":"disconnected","isReconnecting":true,"errorCode":7}"#.utf8)
        let event = try JSONDecoder().decode(LibreWatchDiagnosticEvent.self, from: data)
        XCTAssertNil(event.eventID)
        XCTAssertEqual(event.kind, .disconnected)
        XCTAssertEqual(event.isReconnecting, true)
        XCTAssertEqual(event.errorCode, 7)
        XCTAssertNil(event.watchTimestamp)
        XCTAssertNil(event.trigger)
        XCTAssertNil(event.generation)
        XCTAssertNil(event.deadlineAt)
        XCTAssertNil(event.attemptID)
        XCTAssertNil(event.attemptStartedAt)
        XCTAssertNil(event.sessionID)
        XCTAssertNil(event.sensorIdentity)
        XCTAssertNil(event.reconcileSource)
        XCTAssertNil(event.remainingExecutionBudget)
        XCTAssertNil(event.runtimeInvalidationReason)
        XCTAssertNil(event.runtimeError)
        XCTAssertNil(event.applicationState)
        XCTAssertNil(event.sequenceNumber)
        XCTAssertNil(event.bluetoothErrorClassification)
        XCTAssertNil(event.extendedRuntimeState)
        XCTAssertNil(event.extendedRuntimeStartRequested)
        XCTAssertNil(event.processID)
        XCTAssertNil(event.centralInstanceID)
        XCTAssertNil(event.connectionInstanceID)
        XCTAssertNil(event.reconnectObservationSource)
        XCTAssertNil(event.returnAttempt)
        XCTAssertNil(event.runtimeDiagnostic)
        XCTAssertNil(event.callbackElapsedSeconds)
        XCTAssertNil(event.completedCallbackTiming)
    }

    func testCallbackTimingMeasuresWorkAndFlushWithoutLosingLongestCompletedCallback() {
        var tracker = LibreWatchCallbackTimingTracker()
        tracker.begin(.value, at: receivedAt, uptime: 100)
        tracker.begin(.services, at: receivedAt.addingTimeInterval(1), uptime: 100.1)
        XCTAssertNil(tracker.summary, "the current callback is not a completed sample")
        XCTAssertEqual(tracker.elapsed(at: 100.25), 0.25)
        tracker.finish(workFinishedAt: 100.25, flushFinishedAt: 100.75)
        let first = tracker.summary
        XCTAssertEqual(first?.completedCount, 1)
        XCTAssertEqual(first?.last.kind, .value, "nested work belongs to the outer callback")
        XCTAssertEqual(first?.last.workSeconds, 0.25)
        XCTAssertEqual(first?.last.diagnosticFlushSeconds, 0.5)
        XCTAssertNil(tracker.elapsed(at: 101))

        // A wall-clock correction cannot change the monotonic callback duration.
        tracker.begin(.disconnectLegacy, at: receivedAt.addingTimeInterval(-60), uptime: 160)
        tracker.finish(workFinishedAt: 160.125, flushFinishedAt: 160.25)
        XCTAssertEqual(tracker.summary?.completedCount, 2)
        XCTAssertEqual(tracker.summary?.last.kind, .disconnectLegacy)
        XCTAssertEqual(tracker.summary?.last.elapsedSeconds, 0.25)
        XCTAssertEqual(tracker.summary?.longest, first?.last)
        XCTAssertEqual(first?.completedCount, 1, "captured diagnostic snapshots remain immutable")
    }

    func testInvalidCallbackClockSampleCannotFabricateACompletedCallbackOrPoisonNextSample() {
        var tracker = LibreWatchCallbackTimingTracker()
        tracker.begin(.connect, at: receivedAt, uptime: 50)
        XCTAssertNil(tracker.elapsed(at: 49))
        XCTAssertNil(tracker.elapsed(at: .infinity))
        tracker.finish(workFinishedAt: 49, flushFinishedAt: 51)
        XCTAssertNil(tracker.summary)
        tracker.begin(.connect, at: receivedAt, uptime: 60)
        tracker.finish(workFinishedAt: 61, flushFinishedAt: .nan)
        XCTAssertNil(tracker.summary)
        tracker.begin(.value, at: receivedAt, uptime: 70)
        tracker.finish(workFinishedAt: 70.125, flushFinishedAt: 70.25)
        XCTAssertEqual(tracker.summary?.completedCount, 1)
        XCTAssertEqual(tracker.summary?.last.elapsedSeconds, 0.25)
    }

    func testCoreBluetoothDiagnosticSnapshotsStayBufferedUntilCallbackWorkCompletes() {
        let connectionID = UUID()
        let entered = LibreWatchDiagnosticEvent(
            eventID: UUID(), kind: .coreBluetoothCallback, trigger: "didConnect",
            connectionPhase: "connection", connectionInstanceID: connectionID
        )
        let issued = LibreWatchDiagnosticEvent(
            eventID: UUID(), kind: .bluetoothAction,
            trigger: "freshConnectionSetup", connectionPhase: "services",
            bluetoothAction: "discoverServices", connectionInstanceID: connectionID
        )
        var buffer = LibreWatchCallbackDiagnosticBuffer()

        XCTAssertTrue(buffer.begin())
        XCTAssertFalse(buffer.begin(), "nested work must share the owning callback batch")
        XCTAssertTrue(buffer.capture(entered))
        XCTAssertEqual(buffer.finish(owner: false), [])
        XCTAssertTrue(buffer.capture(issued))
        let persisted = buffer.finish(owner: true)
        XCTAssertEqual(persisted, [entered, issued])
        XCTAssertEqual(persisted.map(\.connectionPhase), ["connection", "services"])
        XCTAssertEqual(Set(persisted.compactMap(\.connectionInstanceID)), Set([connectionID]))
        XCTAssertFalse(buffer.capture(entered), "outside a callback diagnostics persist immediately")
    }

    func testProcessLocalConnectionObservationStaysStableAcrossGATTAndChangesAtNextConnect() {
        let firstConnection = UUID()
        let secondConnection = UUID()
        let ignoredRepeatedRestorationID = UUID()
        var tracker = LibreWatchConnectionInstanceTracker()
        XCTAssertTrue(tracker.acceptConnectedRestoration(id: firstConnection))
        XCTAssertFalse(tracker.acceptConnectedRestoration(id: ignoredRepeatedRestorationID))
        XCTAssertEqual(tracker.currentID, firstConnection)

        let firstLinkEvents = ["didConnect", "didDiscoverServices", "didDiscoverCharacteristics", "didWriteUnlock"]
            .map {
                LibreWatchDiagnosticEvent(
                    kind: .coreBluetoothCallback, trigger: $0,
                    connectionInstanceID: tracker.currentID
                )
            }
        tracker.retire()
        XCTAssertNil(tracker.currentID)
        tracker.acceptDidConnect(id: secondConnection)
        let nextLinkEvent = LibreWatchDiagnosticEvent(
            kind: .coreBluetoothCallback, trigger: "didConnect",
            connectionInstanceID: tracker.currentID
        )

        XCTAssertEqual(Set(firstLinkEvents.compactMap(\.connectionInstanceID)), Set([firstConnection]))
        XCTAssertNotEqual(firstLinkEvents.last?.connectionInstanceID, nextLinkEvent.connectionInstanceID)
    }

    func testInterruptedServiceDiscoveryFencesExactlyOneAmbiguousCallback() {
        var timing = LibreWatchConnectionTiming()
        timing.beginSetup(at: receivedAt, startingAt: .services)
        let oldGeneration = timing.generation
        let interruptedPhase = timing.phase
        XCTAssertTrue(timing.acceptDidConnect(
            at: receivedAt.addingTimeInterval(1),
            applicationIsActive: false
        ))
        let newGeneration = timing.generation
        timing.beginSetup(at: receivedAt.addingTimeInterval(1), startingAt: .services)
        var fence = LibreWatchServiceDiscoveryFence()

        fence.begin(
            generation: newGeneration,
            interruptedServiceDiscovery: interruptedPhase == .services
        )
        XCTAssertFalse(fence.mustRediscoverBeforeAcceptingCallback(generation: oldGeneration))
        XCTAssertTrue(fence.mustRediscoverBeforeAcceptingCallback(generation: newGeneration))
        XCTAssertEqual(timing.phase, .services,
            "the ambiguous callback must not advance the new setup")
        XCTAssertFalse(fence.mustRediscoverBeforeAcceptingCallback(generation: newGeneration),
            "the bounded confirmation must not create a discovery loop")
        XCTAssertTrue(timing.setupProgress(
            .services,
            at: receivedAt.addingTimeInterval(2)
        ))
        XCTAssertEqual(timing.phase, .characteristics)

        fence.reset()
        XCTAssertNil(fence.generation)
    }

    func testConnectedRestorationWithoutDidConnectTimeAcceptsModernDisconnectTimestamp() {
        // A restored link predates this process. willRestoreState receipt time is not the link's
        // acceptance time and cannot be invented as a lower bound for Apple's callback timestamp.
        XCTAssertTrue(LibreWatchDisconnectTimestampPolicy.belongsToCurrentConnection(
            disconnectedAt: receivedAt,
            currentConnectionAcceptedAt: nil,
            observedPeripheralState: .connected
        ))
    }

    func testReturnPreflightRecordsIntentBeforePermittedDisconnect() {
        var order: [String] = []
        let rejection = LibreWatchReturnAttempt.performPreflight(
            ownership: .watch, activated: true, reachable: true,
            record: { stage, reason in
                order.append(stage.rawValue)
                XCTAssertNil(reason)
            },
            disconnect: { order.append("disconnect") }
        )
        XCTAssertNil(rejection)
        XCTAssertEqual(order, ["requested", "disconnect"])
    }

    func testReturnPreflightRecordsEveryRejectionWithoutDisconnecting() {
        let cases: [(LibreWatchOwnership, Bool, Bool, LibreWatchReturnDiagnostic.Reason)] = [
            (.iphone, true, true, .notWatchOwner),
            (.releasingToWatch, true, true, .notWatchOwner),
            (.releasingToPhone, true, true, .notWatchOwner),
            (.recovery, true, true, .notWatchOwner),
            (.watch, false, false, .notActivated),
            (.watch, false, true, .notActivated),
            (.watch, true, false, .phoneUnreachable)
        ]
        for (ownership, activated, reachable, expected) in cases {
            var stages: [LibreWatchReturnDiagnostic.Stage] = []
            var reasons: [LibreWatchReturnDiagnostic.Reason?] = []
            var disconnectCount = 0
            let rejection = LibreWatchReturnAttempt.performPreflight(
                ownership: ownership, activated: activated, reachable: reachable,
                record: { stage, reason in
                    stages.append(stage)
                    reasons.append(reason)
                },
                disconnect: { disconnectCount += 1 }
            )
            XCTAssertEqual(rejection, expected)
            XCTAssertEqual(stages, [.requested, .preflightRejected])
            XCTAssertEqual(reasons, [nil, expected])
            XCTAssertEqual(disconnectCount, 0)
        }
    }

    func testReturnStagesKeepOriginalAttemptContextAndDistinctEventIDs() throws {
        let attempt = LibreWatchReturnAttempt(
            startedAt: receivedAt, generation: UUID(), sessionID: session.id, origin: .sensorChanged)
        let stages: [LibreWatchReturnDiagnostic.Stage] = [
            .requested, .preflightRejected, .disconnectRequested, .awaitingDisconnection,
            .disconnectionConfirmed, .releasePreparing, .releaseSent, .replyAccepted,
            .replyRejected, .snapshotRejected, .transportFailed, .completed, .failed
        ]
        var eventIDs = Set<UUID>()
        for (index, stage) in stages.enumerated() {
            var event = LibreWatchDiagnosticEvent(kind: .lifecycleChanged,
                watchTimestamp: receivedAt.addingTimeInterval(TimeInterval(index)),
                generation: UUID(), sessionID: attempt.sessionID)
            event.returnAttempt = attempt.diagnostic(stage,
                activationState: index % 3, reachable: index.isMultiple(of: 2))
            let restored = try JSONDecoder().decode(LibreWatchDiagnosticEvent.self,
                from: JSONEncoder().encode(event))
            let context = try XCTUnwrap(restored.returnAttempt)
            XCTAssertEqual(context.attemptID, attempt.id)
            XCTAssertEqual(context.startedAt, receivedAt)
            XCTAssertEqual(context.initialGeneration, attempt.generation)
            XCTAssertEqual(context.origin, .sensorChanged)
            XCTAssertEqual(context.stage, stage)
            XCTAssertEqual(context.activationState, index % 3)
            XCTAssertEqual(context.reachable, index.isMultiple(of: 2))
            XCTAssertNil(restored.attemptID) // A return is not a BLE recovery attempt.
            XCTAssertNil(restored.attemptStartedAt)
            XCTAssertTrue(eventIDs.insert(try XCTUnwrap(restored.eventID)).inserted)
        }
        XCTAssertEqual(eventIDs.count, stages.count)
    }

    func testUnreachableReturnIntentAndRejectionSurviveOfflineJournalRestart() {
        let defaults = isolatedDefaults()
        let attempt = LibreWatchReturnAttempt(
            startedAt: receivedAt, generation: UUID(), sessionID: session.id)
        var journal = LibreWatchDiagnosticJournal()
        let rejection = LibreWatchReturnAttempt.performPreflight(
            ownership: .watch, activated: true, reachable: false,
            record: { stage, reason in
                var event = LibreWatchDiagnosticEvent(kind: .lifecycleChanged,
                    watchTimestamp: self.receivedAt, sessionID: attempt.sessionID)
                event.returnAttempt = attempt.diagnostic(stage,
                    activationState: 2, reachable: false, reason: reason)
                XCTAssertTrue(journal.append(event, at: self.receivedAt).inserted)
            },
            disconnect: { XCTFail("An unreachable return must not disconnect Watch") }
        )
        XCTAssertEqual(rejection, .phoneUnreachable)
        LibreWatchSessionStore.saveDiagnosticJournal(journal, defaults: defaults, at: receivedAt)
        let restored = LibreWatchSessionStore.loadDiagnosticJournal(
            defaults: defaults, at: receivedAt.addingTimeInterval(600))
        let pending = restored.pendingEvents(for: session.id)
        XCTAssertEqual(pending.compactMap(\.returnAttempt).map(\.stage), [.requested, .preflightRejected])
        XCTAssertEqual(pending.compactMap(\.returnAttempt).map(\.reason), [nil, .phoneUnreachable])
        XCTAssertEqual(pending.compactMap(\.returnAttempt).map(\.attemptID), [attempt.id, attempt.id])
        XCTAssertEqual(pending.map(\.watchTimestamp), [receivedAt, receivedAt])
        XCTAssertEqual(pending.map(\.sequenceNumber), [1, 2])
        XCTAssertEqual(pending.map(\.eventID), journal.pendingEvents(for: session.id).map(\.eventID))
    }

    func testBackgroundNotificationQuotaErrorsNeverCountAsInvalidFramesOrStartRecovery() {
        let quotaActions: [LibreWatchNotificationErrorAction] = [
            LibreWatchNotificationErrorPolicy.action(
                isNearBackgroundNotificationLimit: true,
                isExceededBackgroundNotificationLimit: false
            ),
            LibreWatchNotificationErrorPolicy.action(
                isNearBackgroundNotificationLimit: false,
                isExceededBackgroundNotificationLimit: true
            )
        ]
        var liveness = LibreWatchFrameLiveness()
        var recoveryCount = 0

        for action in quotaActions {
            switch action {
            case .recoverBluetoothLink:
                if liveness.invalidFrame() { recoveryCount += 1 }
            case .preserveConnectionNearBackgroundLimit,
                 .preserveConnectionExceededBackgroundLimit:
                break
            }
        }

        XCTAssertEqual(quotaActions.map(\.diagnosticName), [
            "backgroundBudgetNear",
            "backgroundBudgetExceeded"
        ])
        XCTAssertEqual(liveness.consecutiveInvalidFrames, 0)
        XCTAssertEqual(recoveryCount, 0)
        XCTAssertEqual(
            LibreWatchNotificationErrorPolicy.action(
                isNearBackgroundNotificationLimit: false,
                isExceededBackgroundNotificationLimit: false
            ),
            .recoverBluetoothLink
        )
    }

    func testDiagnosticJournalPersistsOriginalOrderAndPendingDeliveryAcrossRestart() throws {
        let defaults = isolatedDefaults()
        let firstID = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "A2000000-0000-0000-0000-000000000002")!
        let first = LibreWatchDiagnosticEvent(
            eventID: firstID,
            kind: .lifecycleChanged,
            watchTimestamp: receivedAt,
            trigger: "background",
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            applicationState: .background
        )
        let second = LibreWatchDiagnosticEvent(
            eventID: secondID,
            kind: .coreBluetoothCallback,
            watchTimestamp: receivedAt.addingTimeInterval(5),
            trigger: "didConnect",
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            applicationState: .active
        )
        var journal = LibreWatchDiagnosticJournal()

        let firstResult = journal.append(first, at: receivedAt.addingTimeInterval(1))
        let secondResult = journal.append(second, at: receivedAt.addingTimeInterval(6))
        XCTAssertTrue(firstResult.inserted)
        XCTAssertTrue(secondResult.inserted)
        XCTAssertEqual(firstResult.event.sequenceNumber, 1)
        XCTAssertEqual(secondResult.event.sequenceNumber, 2)
        XCTAssertFalse(journal.append(first, at: receivedAt.addingTimeInterval(7)).inserted)

        LibreWatchSessionStore.saveDiagnosticJournal(
            journal,
            defaults: defaults,
            at: receivedAt.addingTimeInterval(7)
        )
        var restored = LibreWatchSessionStore.loadDiagnosticJournal(
            defaults: defaults,
            at: receivedAt.addingTimeInterval(8)
        )
        XCTAssertEqual(
            restored.pendingEvents(for: session.id).compactMap(\.eventID),
            [firstID, secondID]
        )
        XCTAssertTrue(restored.pendingEvents(for: UUID()).isEmpty)
        restored.markHandedToWatchConnectivity(
            eventID: firstID,
            at: receivedAt.addingTimeInterval(10)
        )
        XCTAssertEqual(restored.pendingEvents(for: session.id).compactMap(\.eventID), [firstID, secondID])
        restored.markAcknowledgedByPhone(eventID: firstID, at: receivedAt.addingTimeInterval(10.5))
        LibreWatchSessionStore.saveDiagnosticJournal(
            restored,
            defaults: defaults,
            at: receivedAt.addingTimeInterval(11)
        )
        let deliveredState = LibreWatchSessionStore.loadDiagnosticJournal(
            defaults: defaults,
            at: receivedAt.addingTimeInterval(12)
        )
        XCTAssertEqual(
            deliveredState.pendingEvents(for: session.id).compactMap(\.eventID),
            [secondID]
        )
        XCTAssertEqual(deliveredState.entries.first?.event.watchTimestamp, receivedAt)
    }

    func testDiagnosticJournalIsBoundedAndRecordsDroppedEntriesWithoutRecursiveEvents() throws {
        var journal = LibreWatchDiagnosticJournal()
        let start = receivedAt
        for index in 0 ..< 300 {
            _ = journal.append(LibreWatchDiagnosticEvent(
                kind: .coreBluetoothCallback,
                watchTimestamp: start.addingTimeInterval(TimeInterval(index)),
                trigger: "centralState:poweredOn",
                sessionID: session.id,
                sensorIdentity: session.redactedIdentity(),
                applicationState: .active,
                actionReason: String(repeating: "x", count: 2_000)
            ), at: start.addingTimeInterval(TimeInterval(index)))
        }

        let encoded = try JSONEncoder().encode(journal)
        XCTAssertLessThanOrEqual(journal.entries.count, LibreWatchDiagnosticJournal.maximumEntries)
        XCTAssertLessThanOrEqual(encoded.count, LibreWatchDiagnosticJournal.maximumEncodedBytes)
        XCTAssertGreaterThan(journal.droppedCount, 0)
        XCTAssertTrue(journal.entries.allSatisfy { $0.event.actionReason?.count == 513 })
        XCTAssertEqual(
            journal.entries.compactMap { $0.event.sequenceNumber },
            journal.entries.compactMap { $0.event.sequenceNumber }.sorted()
        )
        XCTAssertFalse(journal.entries.contains { $0.event.kind == .journalRotated })
    }

    func testDiagnosticJournalAssignsStableIDAndExpiresByLocalRecordTime() throws {
        var journal = LibreWatchDiagnosticJournal()
        let event = LibreWatchDiagnosticEvent(
            eventID: nil,
            kind: .callbackRejected,
            watchTimestamp: receivedAt.addingTimeInterval(365 * 24 * 60 * 60),
            trigger: "staleSetupGeneration",
            sessionID: session.id
        )
        let result = journal.append(event, at: receivedAt)
        let generatedID = try XCTUnwrap(result.event.eventID)
        XCTAssertEqual(journal.entries.first?.event.eventID, generatedID)

        journal.prune(at: receivedAt.addingTimeInterval(
            LibreWatchDiagnosticJournal.maximumAge + 0.001
        ))
        XCTAssertTrue(journal.entries.isEmpty)
        XCTAssertGreaterThan(journal.droppedCount, 0)
    }

    func testQueuedDiagnosticPreservesWatchTimestampAndPhaseContext() throws {
        let eventID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let attemptID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let event = LibreWatchDiagnosticEvent(
            eventID: eventID, kind: .recoveryStarted,
            watchTimestamp: receivedAt, trigger: "invalidFrames",
            applicationIsActive: false, extendedRuntimeIsRunning: true,
            peripheralState: "connected", connectionPhase: "cancelling",
            deadlinePhase: "cancelling", deadlineAt: receivedAt.addingTimeInterval(5),
            generation: UUID(), attemptID: attemptID,
            attemptStartedAt: receivedAt.addingTimeInterval(-30),
            sessionID: session.id, sensorIdentity: session.redactedIdentity(),
            reconcileSource: .gattCallback, remainingExecutionBudget: 42
        )
        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(
            LibreWatchDiagnosticEvent.self, from: encoded
        )
        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.eventID, eventID)
        XCTAssertEqual(decoded.attemptID, attemptID)
        XCTAssertEqual(decoded.remainingExecutionBudget, 42)
        XCTAssertEqual(decoded.watchTimestamp, receivedAt) // Not the later iPhone receipt time.

        // A fallback delivery must persist the exact snapshot, not reconstruct it later.
        let item = LibreWatchOutboxItem.command(
            .reportDiagnostic,
            sessionID: session.id,
            diagnosticEvent: encoded,
            id: eventID,
            createdAt: receivedAt.addingTimeInterval(60)
        )
        let queuedEvent = try JSONDecoder().decode(
            LibreWatchDiagnosticEvent.self,
            from: try XCTUnwrap(item.diagnosticEvent)
        )
        XCTAssertEqual(queuedEvent, event)
    }

    func testRecoveryAttemptRetainsImmutableContextUntilSuccessOrInvalidation() throws {
        let original = LibreWatchRecoveryAttemptContext(
            attemptID: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            originalTrigger: "disconnect",
            startedAt: receivedAt,
            generation: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity()
        )
        let later = LibreWatchRecoveryAttemptContext(
            originalTrigger: "sceneActivation",
            startedAt: receivedAt.addingTimeInterval(600),
            generation: UUID(),
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity()
        )
        var state = LibreWatchRecoveryAttemptState()

        XCTAssertEqual(state.begin(original), original)
        XCTAssertNil(state.begin(later))
        XCTAssertEqual(state.context, original)
        XCTAssertEqual(state.reportFailure(), original)
        XCTAssertNil(state.reportFailure())
        XCTAssertEqual(state.context?.startedAt, receivedAt)

        let defaults = isolatedDefaults()
        LibreWatchSessionStore.saveRecoveryAttempt(state, defaults: defaults)
        var restored = LibreWatchSessionStore.loadRecoveryAttempt(defaults: defaults)
        XCTAssertEqual(restored, state)
        XCTAssertNil(restored.reportFailure()) // The one failure report survives restoration too.
        XCTAssertEqual(restored.finishSuccess(), original)
        LibreWatchSessionStore.saveRecoveryAttempt(restored, defaults: defaults)
        XCTAssertNil(LibreWatchSessionStore.loadRecoveryAttempt(defaults: defaults).context)
        XCTAssertNil(defaults.data(forKey: LibreWatchMessageKey.persistedRecoveryAttempt))
    }

    func testDiagnosticReceiptDeduplicatesStableEventIDAndAcceptsLegacyEvents() {
        let eventID = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
        var ledger = LibreWatchDiagnosticReceiptLedger()

        XCTAssertTrue(ledger.accept(eventID, at: receivedAt))
        XCTAssertFalse(ledger.accept(eventID, at: receivedAt.addingTimeInterval(1)))
        XCTAssertTrue(ledger.accept(nil, at: receivedAt.addingTimeInterval(2)))
        XCTAssertTrue(ledger.accept(nil, at: receivedAt.addingTimeInterval(3)))
        XCTAssertEqual(ledger.receipts[eventID], receivedAt)

        ledger.prune(at: receivedAt.addingTimeInterval(LibreWatchDiagnosticReceiptLedger.maximumAge))
        XCTAssertNotNil(ledger.receipts[eventID])
        ledger.prune(at: receivedAt.addingTimeInterval(
            LibreWatchDiagnosticReceiptLedger.maximumAge + 0.001
        ))
        XCTAssertNil(ledger.receipts[eventID])
    }

    func testConnectivityDeliveryPolicyCoversActivationAndReachability() {
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.action(
                sessionIsActivated: false,
                phoneIsReachable: false
            ),
            .activateAndQueue
        )
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.action(
                sessionIsActivated: false,
                phoneIsReachable: true
            ),
            .activateAndQueue
        )
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.action(
                sessionIsActivated: true,
                phoneIsReachable: false
            ),
            .transferUserInfo
        )
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.action(
                sessionIsActivated: true,
                phoneIsReachable: true
            ),
            .sendMessage
        )
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.actionAfterSendError(
                sessionIsActivated: true
            ),
            .transferUserInfo
        )
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.actionAfterSendError(
                sessionIsActivated: false
            ),
            .activateAndQueue
        )
        XCTAssertTrue(
            LibreWatchConnectivityDeliveryPolicy.shouldRetryReadingAsQueued(
                after: .wrongOwnership
            )
        )
        XCTAssertTrue(
            LibreWatchConnectivityDeliveryPolicy.shouldRetryReadingAsQueued(
                after: .tooOld
            )
        )
        XCTAssertFalse(
            LibreWatchConnectivityDeliveryPolicy.shouldRetryReadingAsQueued(
                after: .wrongSession
            )
        )
        XCTAssertFalse(
            LibreWatchConnectivityDeliveryPolicy.shouldRetryReadingAsQueued(
                after: .duplicate
            )
        )
    }

    func testHistoricalProcessingModeCannotDriveCurrentValueOrLiveAlerts() {
        let live = LibreWatchGlucoseProcessingMode.live
        XCTAssertTrue(live.permitsCurrentValueAndLiveSideEffects)
        XCTAssertEqual(
            live.routing,
            LibreWatchGlucoseProcessingRouting(
                updatesCurrentValue: true,
                resetsMissedReadingState: true,
                triggersAlerts: true,
                exportsToIntegrations: true
            )
        )

        let historical = LibreWatchGlucoseProcessingMode.historicalBackfill
        XCTAssertFalse(historical.permitsCurrentValueAndLiveSideEffects)
        XCTAssertFalse(historical.routing.updatesCurrentValue)
        XCTAssertFalse(historical.routing.resetsMissedReadingState)
        XCTAssertFalse(historical.routing.triggersAlerts)
        XCTAssertFalse(historical.routing.exportsToIntegrations)
    }

    func testBackgroundBLENotificationRetriesPersistedReadingsWithoutTimerPermission() throws {
        let now = receivedAt.addingTimeInterval(8 * 60)
        var outbox = LibreWatchConnectivityOutbox()
        let reading = outboxReading(index: 0, at: receivedAt)
        outbox.enqueue(reading, now: now)
        outbox.markSubmitted(id: reading.id, at: now.addingTimeInterval(-60))
        let restored = try JSONDecoder().decode(LibreWatchConnectivityOutbox.self,
            from: JSONEncoder().encode(outbox))
        let timed = LibreWatchLifecyclePolicy.recoveryIsAllowed(applicationState: .background,
            extendedRuntimeIsRunning: false, ownership: .watch)
        XCTAssertFalse(timed)
        XCTAssertFalse(restored.retryIsDue(at: now, opportunity: .existingExecution(isAvailable: timed),
            hasInFlightItem: false))
        XCTAssertTrue(restored.retryIsDue(at: now, opportunity: .validatedBLENotification(ownership: .watch),
            hasInFlightItem: false))
        XCTAssertEqual(restored.nextEligible(at: now)?.id, reading.id)
        var delivered: [UUID] = []
        LibreWatchConnectivityDeliveryPolicy.retryPendingDelivery(outbox: restored, at: now,
            opportunity: .validatedBLENotification(ownership: .watch), sessionIsActivated: true,
            hasInFlightItem: false) {
            delivered.append(reading.id)
        }
        XCTAssertEqual(delivered, [reading.id], "Drive the same dispatch boundary used by WatchStateModel")
        // A short callback can enqueue with the OS; it does not make the phone reachable
        // and does not authorize a timer, scan or connect in the lifecycle policy.
        XCTAssertEqual(LibreWatchConnectivityDeliveryPolicy.action(sessionIsActivated: true,
            phoneIsReachable: false), .transferUserInfo)
        XCTAssertFalse(LibreWatchLifecyclePolicy.recoveryIsAllowed(applicationState: .background,
            extendedRuntimeIsRunning: false, ownership: .watch))
    }

    func testPendingReadingsDoNotGrantBackgroundTimerExecutionWithoutBLEEvent() {
        var outbox = LibreWatchConnectivityOutbox()
        outbox.enqueue(outboxReading(index: 0), now: receivedAt)
        var deliveries = 0
        for seconds in [0.0, 60, 480, 1_800] {
            let timed = LibreWatchLifecyclePolicy.recoveryIsAllowed(applicationState: .background,
                extendedRuntimeIsRunning: false, ownership: .watch)
            XCTAssertFalse(outbox.retryIsDue(at: receivedAt.addingTimeInterval(seconds),
                opportunity: .existingExecution(isAvailable: timed), hasInFlightItem: false))
            LibreWatchConnectivityDeliveryPolicy.retryPendingDelivery(outbox: outbox,
                at: receivedAt.addingTimeInterval(seconds), opportunity: .existingExecution(isAvailable: timed),
                sessionIsActivated: true, hasInFlightItem: false) { deliveries += 1 }
        }
        XCTAssertEqual(deliveries, 0)
        XCTAssertNil(outbox.lastSubmittedAt)
        XCTAssertNil(outbox.didPrioritizeLatestReading)
    }

    func testBLENotificationCannotGrantDeliveryAfterOwnershipChanges() {
        var outbox = LibreWatchConnectivityOutbox()
        outbox.enqueue(outboxReading(index: 0), now: receivedAt)
        var deliveries = 0
        let nonWatchOwners: [LibreWatchOwnership] = [.iphone, .releasingToPhone, .releasingToWatch, .recovery]
        for owner in nonWatchOwners {
            XCTAssertFalse(outbox.retryIsDue(at: receivedAt,
                opportunity: .validatedBLENotification(ownership: owner), hasInFlightItem: false))
            LibreWatchConnectivityDeliveryPolicy.retryPendingDelivery(outbox: outbox, at: receivedAt,
                opportunity: .validatedBLENotification(ownership: owner), sessionIsActivated: true,
                hasInFlightItem: false) { deliveries += 1 }
        }
        XCTAssertEqual(deliveries, 0)
        // This restriction is on BLE-origin retries, not on the existing foreground/WC
        // path which must still drain already-owned pre-cutoff readings after a handoff.
        XCTAssertTrue(outbox.retryIsDue(at: receivedAt,
            opportunity: .existingExecution(isAvailable: true), hasInFlightItem: false))
    }

    func testBLEDeliveryOpportunityPreservesRetryBackoffAndInFlightGate() throws {
        var outbox = LibreWatchConnectivityOutbox()
        let reading = outboxReading(index: 0)
        outbox.enqueue(reading, now: receivedAt)
        outbox.markSubmitted(id: reading.id, at: receivedAt)
        let opportunity = LibreWatchOutboxDeliveryOpportunity.validatedBLENotification(ownership: .watch)
        var gate = LibreWatchConnectivitySendAttemptGate()
        XCTAssertEqual(LibreWatchConnectivityOutbox.retryInterval, 60)
        XCTAssertFalse(outbox.retryIsDue(at: receivedAt.addingTimeInterval(59.999),
            opportunity: opportunity, hasInFlightItem: !gate.isIdle))
        let due = receivedAt.addingTimeInterval(60)
        XCTAssertTrue(outbox.retryIsDue(at: due, opportunity: opportunity, hasInFlightItem: !gate.isIdle))
        let attempt = try XCTUnwrap(gate.begin(payloadID: reading.id))
        XCTAssertFalse(outbox.retryIsDue(at: due, opportunity: opportunity, hasInFlightItem: !gate.isIdle))
        XCTAssertTrue(gate.finish(attempt))
        XCTAssertTrue(outbox.retryIsDue(at: due, opportunity: opportunity, hasInFlightItem: !gate.isIdle))
        var deliveries = 0
        LibreWatchConnectivityDeliveryPolicy.retryPendingDelivery(outbox: outbox, at: due,
            opportunity: opportunity, sessionIsActivated: false, hasInFlightItem: false) { deliveries += 1 }
        LibreWatchConnectivityDeliveryPolicy.retryPendingDelivery(outbox: outbox, at: due,
            opportunity: opportunity, sessionIsActivated: true, hasInFlightItem: true) { deliveries += 1 }
        LibreWatchConnectivityDeliveryPolicy.retryPendingDelivery(outbox: outbox,
            at: receivedAt.addingTimeInterval(59.999), opportunity: opportunity,
            sessionIsActivated: true, hasInFlightItem: false) { deliveries += 1 }
        XCTAssertEqual(deliveries, 0)
        LibreWatchConnectivityDeliveryPolicy.retryPendingDelivery(outbox: outbox, at: due,
            opportunity: opportunity, sessionIsActivated: true, hasInFlightItem: false) { deliveries += 1 }
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(LibreWatchConnectivityDeliveryPolicy.action(sessionIsActivated: false,
            phoneIsReachable: true), .activateAndQueue)
    }

    func testEightMinuteOutboxSelectsNewestOnceThenAscendingCreatedAt() throws {
        let now = receivedAt.addingTimeInterval(8 * 60)
        var outbox = LibreWatchConnectivityOutbox()
        for minute in [3, 8, 0, 6, 2, 7, 1, 5, 4] {
            outbox.enqueue(outboxReading(index: minute,
                at: receivedAt.addingTimeInterval(Double(minute) * 60)), now: now)
        }
        var submitted: [UUID] = []
        while let item = outbox.nextEligible(at: now) {
            submitted.append(item.id)
            // Same reservation/persistence order as beginOutboxAttempt, before transport.
            outbox.markSelected(id: item.id)
            outbox = try JSONDecoder().decode(LibreWatchConnectivityOutbox.self,
                from: JSONEncoder().encode(outbox))
            outbox.remove(id: item.id)
        }
        XCTAssertEqual(submitted, ([8] + Array(0 ... 7)).map(outboxFixtureID))
        XCTAssertNil(outbox.didPrioritizeLatestReading)
    }

    func testFailedFreshnessPromotionAndNewArrivalsDoNotOvertakeBacklogAgain() throws {
        let now = receivedAt.addingTimeInterval(8 * 60)
        var outbox = LibreWatchConnectivityOutbox()
        for minute in [0, 4, 8] {
            outbox.enqueue(outboxReading(index: minute,
                at: receivedAt.addingTimeInterval(Double(minute) * 60)), now: now)
        }
        let latest = try XCTUnwrap(outbox.nextEligible(at: now))
        XCTAssertEqual(latest.id, outboxFixtureID(8))
        // A failed interactive attempt reserves its promotion before the error callback,
        // which records the unchanged retry backoff. Restore between those operations.
        outbox.markSelected(id: latest.id)
        outbox = try JSONDecoder().decode(LibreWatchConnectivityOutbox.self,
            from: JSONEncoder().encode(outbox))
        outbox.markSubmitted(id: latest.id, at: now)
        outbox.enqueue(outboxReading(index: 9, at: now.addingTimeInterval(1)), now: now.addingTimeInterval(1))
        XCTAssertEqual(outbox.nextEligible(at: now.addingTimeInterval(1))?.id, outboxFixtureID(0))
        outbox.markSubmitted(id: outboxFixtureID(0), at: now.addingTimeInterval(1))
        XCTAssertEqual(outbox.nextEligible(at: now.addingTimeInterval(1))?.id, outboxFixtureID(4))
        outbox.remove(id: outboxFixtureID(4))
        // Expired backoff rejoins by createdAt, not another newest-first promotion.
        XCTAssertEqual(outbox.nextEligible(at: now.addingTimeInterval(61))?.id, outboxFixtureID(0))
        outbox.remove(id: outboxFixtureID(0))
        XCTAssertEqual(outbox.nextEligible(at: now.addingTimeInterval(61))?.id, latest.id)
        outbox.retry(id: latest.id)
        XCTAssertEqual(outbox.nextEligible(at: now.addingTimeInterval(61))?.id, latest.id)
        outbox.remove(id: latest.id)
        XCTAssertEqual(outbox.nextEligible(at: now.addingTimeInterval(61))?.id, outboxFixtureID(9))
    }

    func testOutboxPromotionIsReservedBeforeReplyAndResetsOnlyWhenEmpty() throws {
        let now = receivedAt.addingTimeInterval(10)
        var outbox = LibreWatchConnectivityOutbox()
        for index in 0 ... 2 { outbox.enqueue(outboxReading(index: index), now: now) }
        let selected = try XCTUnwrap(outbox.nextEligible(at: now))
        XCTAssertEqual(selected.id, outboxFixtureID(2))
        // Merely evaluating retry eligibility must not consume the priority.
        XCTAssertEqual(outbox.nextEligible(at: now)?.id, selected.id)
        outbox.markSelected(id: selected.id)
        outbox = try JSONDecoder().decode(LibreWatchConnectivityOutbox.self,
            from: JSONEncoder().encode(outbox))
        XCTAssertEqual(outbox.nextEligible(at: now)?.id, outboxFixtureID(0))
        outbox.remove(id: selected.id)
        outbox.enqueue(outboxReading(index: 3), now: now)
        XCTAssertEqual(outbox.nextEligible(at: now)?.id, outboxFixtureID(0))
        for id in outbox.items.map(\.id) { outbox.remove(id: id) }
        for index in 4 ... 5 { outbox.enqueue(outboxReading(index: index), now: now) }
        XCTAssertEqual(outbox.nextEligible(at: now)?.id, outboxFixtureID(5))
    }

    func testLegacyOutboxPromotionUsesStableTieBreakAndCommandsKeepFIFOAfterward() throws {
        let now = receivedAt
        let olderCommand = LibreWatchOutboxItem.command(.updateUnlockCounter,
            sessionID: session.id, unlockCounter: 9, id: outboxFixtureID(10),
            createdAt: now.addingTimeInterval(-1))
        let items = [outboxReading(index: 2, at: now), olderCommand, outboxReading(index: 1, at: now)]
        let legacy = try JSONSerialization.data(withJSONObject: [
            "items": try JSONSerialization.jsonObject(with: JSONEncoder().encode(items))
        ])
        var outbox = try JSONDecoder().decode(LibreWatchConnectivityOutbox.self, from: legacy)
        outbox.prune(at: now)
        XCTAssertEqual(outbox.nextEligible(at: now)?.id, outboxFixtureID(2))
        outbox.markSelected(id: outboxFixtureID(2))
        outbox.remove(id: outboxFixtureID(2))
        XCTAssertEqual(outbox.nextEligible(at: now)?.id, olderCommand.id)
        outbox.remove(id: olderCommand.id)
        XCTAssertEqual(outbox.nextEligible(at: now)?.id, outboxFixtureID(1))
    }

    func testOutboxPriorityCannotExtendAgeOrChangeCapacityBounds() {
        let now = receivedAt.addingTimeInterval(300)
        let maximumItems = LibreWatchConnectivityOutbox.maximumItems
        var outbox = LibreWatchConnectivityOutbox()
        for index in 0 ..< LibreWatchConnectivityOutbox.maximumItems {
            outbox.enqueue(outboxReading(index: index, at: receivedAt), now: now)
        }
        outbox.markSelected(id: outboxFixtureID(maximumItems - 1))
        XCTAssertFalse(outbox.enqueue(outboxReading(index: maximumItems, at: receivedAt), now: now))
        XCTAssertEqual(outbox.items.count, maximumItems)
        XCTAssertEqual(LibreWatchConnectivityOutbox.maximumItems, 512)
        XCTAssertEqual(LibreWatchConnectivityOutbox.maximumAge, 6 * 60 * 60)
        XCTAssertEqual(LibreWatchDiagnosticJournal.maximumEncodedBytes, 64 * 1_024)
        outbox.prune(at: receivedAt.addingTimeInterval(LibreWatchConnectivityOutbox.maximumAge))
        XCTAssertEqual(outbox.items.count, maximumItems)
        XCTAssertEqual(outbox.didPrioritizeLatestReading, true)
        outbox.prune(at: receivedAt.addingTimeInterval(LibreWatchConnectivityOutbox.maximumAge + 0.001))
        XCTAssertTrue(outbox.items.isEmpty)
        XCTAssertNil(outbox.didPrioritizeLatestReading)
    }

    func testOutboxDeduplicatesOrdersPersistsAndAcknowledgesByStableID() throws {
        let now = Date()
        let older = payload(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
            raw: 790,
            previousRaw: 780,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-60)
        )
        let newer = payload(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000007")!,
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: now
        )
        let commandID = UUID(uuidString: "80000000-0000-0000-0000-000000000008")!
        let command = LibreWatchOutboxItem.command(
            .updateUnlockCounter,
            sessionID: session.id,
            unlockCounter: 9,
            id: commandID,
            createdAt: now.addingTimeInterval(-120)
        )
        var outbox = LibreWatchConnectivityOutbox()

        outbox.enqueue(.reading(newer), now: now)
        outbox.enqueue(command, now: now)
        outbox.enqueue(.reading(older), now: now)
        outbox.enqueue(.reading(older), now: now)
        XCTAssertEqual(outbox.items.map(\.id), [commandID, older.id, newer.id])
        XCTAssertEqual(outbox.next?.id, commandID)

        let defaults = isolatedDefaults()
        LibreWatchSessionStore.saveOutbox(outbox, defaults: defaults)
        var restored = LibreWatchSessionStore.loadOutbox(defaults: defaults)
        XCTAssertEqual(restored, outbox)
        restored.remove(id: newer.id)
        XCTAssertEqual(restored.items.map(\.id), [commandID, older.id])
        XCTAssertNotNil(restored.items.first(where: { $0.id == older.id }))
        XCTAssertNotNil(restored.items.first(where: { $0.id == commandID }))
    }

    func testOutboxDiagnosticStormRetainsOldestUnacknowledgedReading() {
        let now = receivedAt.addingTimeInterval(1_000)
        let reading = outboxReading(index: 0)
        var outbox = LibreWatchConnectivityOutbox()
        outbox.enqueue(reading, now: now)
        outbox.markSubmitted(id: reading.id, at: now)
        for offset in 1 ... (LibreWatchConnectivityOutbox.maximumItems + 16) {
            outbox.enqueue(.command(
                .reportDiagnostic,
                sessionID: session.id,
                diagnosticEvent: Data([UInt8(offset & 0xFF)]),
                id: outboxFixtureID(offset),
                createdAt: receivedAt.addingTimeInterval(Double(offset))
            ), now: now)
        }
        XCTAssertEqual(outbox.items.count, LibreWatchConnectivityOutbox.maximumItems)
        XCTAssertEqual(outbox.items.first, reading)
        XCTAssertEqual(outbox.lastSubmittedAt?[reading.id], now)
        XCTAssertEqual(outbox.nextEligible(at: now)?.id, outboxFixtureID(1))
        XCTAssertEqual(outbox.capacityDroppedReadings ?? 0, 0)
        XCTAssertEqual(outbox.capacityDroppedDiagnostics, 17)
    }

    func testOutboxMixedCapacityEvictsDiagnosticsThenCommandsAndPersistsSeparateCounts() throws {
        let now = receivedAt.addingTimeInterval(1_000)
        let maximumItems = LibreWatchConnectivityOutbox.maximumItems
        var outbox = LibreWatchConnectivityOutbox()
        for index in 0 ..< (LibreWatchConnectivityOutbox.maximumItems - 2) {
            outbox.enqueue(outboxReading(index: index), now: now)
        }
        let counter = LibreWatchOutboxItem.command(.updateUnlockCounter,
            sessionID: session.id, unlockCounter: 42, id: outboxFixtureID(900),
            createdAt: receivedAt.addingTimeInterval(-2))
        let diagnostic = LibreWatchOutboxItem.command(.reportDiagnostic,
            sessionID: session.id, diagnosticEvent: Data("{}".utf8), id: outboxFixtureID(901),
            createdAt: receivedAt.addingTimeInterval(-1))
        outbox.enqueue(counter, now: now)
        outbox.enqueue(diagnostic, now: now)
        outbox.markSubmitted(id: diagnostic.id, at: now)
        outbox.markSubmitted(id: counter.id, at: now)

        XCTAssertTrue(outbox.enqueue(outboxReading(index: maximumItems - 2), now: now))
        XCTAssertFalse(outbox.items.contains { $0.id == diagnostic.id })
        XCTAssertTrue(outbox.items.contains { $0.id == counter.id })
        XCTAssertNil(outbox.lastSubmittedAt?[diagnostic.id])
        XCTAssertTrue(outbox.enqueue(outboxReading(index: maximumItems - 1), now: now))
        XCTAssertFalse(outbox.items.contains { $0.id == counter.id })
        XCTAssertNil(outbox.lastSubmittedAt?[counter.id])
        XCTAssertEqual(outbox.items.map(\.id), (0 ..< maximumItems).map(outboxFixtureID))
        XCTAssertEqual(outbox.capacityDroppedDiagnostics, 1)
        XCTAssertEqual(outbox.capacityDroppedCommands, 1)
        XCTAssertEqual(outbox.capacityDroppedReadings ?? 0, 0)
        XCTAssertEqual(try JSONDecoder().decode(LibreWatchConnectivityOutbox.self,
            from: JSONEncoder().encode(outbox)), outbox)
    }

    func testOutboxReadingOnlyOverflowPreservesOldestFirstWithDeterministicTieBreak() {
        let now = receivedAt.addingTimeInterval(1_000)
        let maximumItems = LibreWatchConnectivityOutbox.maximumItems
        var outbox = LibreWatchConnectivityOutbox()
        for index in (1 ... LibreWatchConnectivityOutbox.maximumItems).reversed() {
            outbox.enqueue(outboxReading(index: index, at: receivedAt), now: now)
        }
        let rejected = outboxReading(index: maximumItems + 1, at: receivedAt)
        XCTAssertFalse(outbox.enqueue(rejected, now: now))
        XCTAssertTrue(outbox.enqueue(outboxReading(index: 0, at: receivedAt), now: now))
        XCTAssertEqual(outbox.items.map(\.id), (0 ..< maximumItems).map(outboxFixtureID))
        XCTAssertEqual(outbox.capacityDroppedReadings, 2)
        XCTAssertEqual(outbox.capacityDroppedDiagnostics ?? 0, 0)
    }

    func testOutboxFullDiagnosticReplayDoesNotChurnOrResetSubmissionThrottle() throws {
        let now = receivedAt.addingTimeInterval(1_000)
        var outbox = LibreWatchConnectivityOutbox()
        for index in 0 ..< (LibreWatchConnectivityOutbox.maximumItems - 1) {
            let item = outboxReading(index: index)
            outbox.enqueue(item, now: now)
            outbox.markSubmitted(id: item.id, at: now)
        }
        var journal = LibreWatchDiagnosticJournal()
        for index in 0 ..< 3 {
            _ = journal.append(LibreWatchDiagnosticEvent(eventID: outboxFixtureID(900 + index),
                kind: .disconnected, watchTimestamp: now,
                sessionID: session.id), at: now)
        }
        let events = journal.pendingEvents()
        let firstID = try XCTUnwrap(events.first?.eventID)
        let first = LibreWatchOutboxItem.command(.reportDiagnostic,
            sessionID: session.id, diagnosticEvent: try JSONEncoder().encode(events[0]),
            id: firstID, createdAt: now)
        XCTAssertTrue(outbox.enqueue(first, now: now))
        outbox.markSubmitted(id: firstID, at: now)
        let retainedIDs = outbox.items.map(\.id)

        // Reconciliation on consecutive flush opportunities must not create fresh eligible
        // replacements of submitted payloads merely because the journal remains unacked.
        for second in 1 ... 3 {
            let retryDate = now.addingTimeInterval(Double(second))
            for event in journal.pendingEvents() {
                outbox.enqueue(.command(.reportDiagnostic, sessionID: session.id,
                    diagnosticEvent: try JSONEncoder().encode(event),
                    id: try XCTUnwrap(event.eventID), createdAt: retryDate), now: retryDate)
            }
            XCTAssertEqual(outbox.items.map(\.id), retainedIDs)
            XCTAssertNil(outbox.nextEligible(at: retryDate))
            XCTAssertEqual(outbox.lastSubmittedAt?[firstID], now)
        }
        XCTAssertEqual(journal.pendingEvents().count, 3)
        journal.markAcknowledgedByPhone(eventID: firstID, at: now.addingTimeInterval(4))
        outbox.remove(id: firstID)
        let next = try XCTUnwrap(journal.pendingEvents().first)
        let nextID = try XCTUnwrap(next.eventID)
        XCTAssertTrue(outbox.enqueue(.command(.reportDiagnostic, sessionID: session.id,
            diagnosticEvent: try JSONEncoder().encode(next), id: nextID,
            createdAt: now.addingTimeInterval(4)), now: now.addingTimeInterval(4)))
        XCTAssertEqual(outbox.nextEligible(at: now.addingTimeInterval(4))?.id, nextID)
        XCTAssertEqual(outbox.items.filter { $0.kind == .reading }.count,
            LibreWatchConnectivityOutbox.maximumItems - 1)
    }

    func testOutboxDuplicateExpiredAndInvalidAdmissionsCannotEvictRetainedPayloads() {
        let now = receivedAt.addingTimeInterval(1_000)
        var outbox = LibreWatchConnectivityOutbox()
        for index in 0 ..< LibreWatchConnectivityOutbox.maximumItems {
            outbox.enqueue(outboxReading(index: index), now: now)
        }
        outbox.markSubmitted(id: outboxFixtureID(0), at: now)
        let before = outbox
        XCTAssertTrue(outbox.enqueue(outboxReading(index: 0), now: now))
        XCTAssertFalse(outbox.enqueue(outboxReading(index: 900,
            at: now.addingTimeInterval(-LibreWatchConnectivityOutbox.maximumAge - 0.001)), now: now))
        XCTAssertFalse(outbox.enqueue(.command(.reportDiagnostic, sessionID: session.id,
            id: outboxFixtureID(901), createdAt: now), now: now))
        XCTAssertEqual(outbox, before)
    }

    func testOutboxLegacyOversizedQueuePrunesCapacityWithoutDroppingOldestReading() throws {
        let now = receivedAt.addingTimeInterval(1_000)
        let reading = outboxReading(index: 0)
        let diagnostics = (1 ... LibreWatchConnectivityOutbox.maximumItems).map { index in
            LibreWatchOutboxItem.command(.reportDiagnostic, sessionID: session.id,
                diagnosticEvent: Data("{}".utf8), id: outboxFixtureID(index),
                createdAt: receivedAt.addingTimeInterval(Double(index)))
        }
        let legacy = try JSONSerialization.data(withJSONObject: [
            "items": try JSONSerialization.jsonObject(with: JSONEncoder().encode(Array(diagnostics.reversed()) + [reading]))
        ])
        var outbox = try JSONDecoder().decode(LibreWatchConnectivityOutbox.self, from: legacy)
        outbox.prune(at: now)
        XCTAssertEqual(outbox.items.count, LibreWatchConnectivityOutbox.maximumItems)
        XCTAssertEqual(outbox.items.first, reading)
        XCTAssertEqual(outbox.items.last?.id, outboxFixtureID(LibreWatchConnectivityOutbox.maximumItems - 1))
        XCTAssertEqual(outbox.capacityDroppedDiagnostics, 1)
    }

    func testOutboxRejectsSingleOversizedDiagnosticWithoutChangingRetainedRetries() throws {
        let now = receivedAt.addingTimeInterval(1_000)
        let reading = outboxReading(index: 0)
        let diagnostic = LibreWatchOutboxItem.command(.reportDiagnostic, sessionID: session.id,
            diagnosticEvent: Data("{}".utf8), id: outboxFixtureID(900), createdAt: receivedAt)
        var outbox = LibreWatchConnectivityOutbox()
        XCTAssertTrue(outbox.enqueue(reading, now: now))
        XCTAssertTrue(outbox.enqueue(diagnostic, now: now))
        for item in outbox.items { outbox.markSubmitted(id: item.id, at: now) }
        let retainedIDs = outbox.items.map(\.id)
        let submittedAt = outbox.lastSubmittedAt

        XCTAssertFalse(outbox.enqueue(.command(.reportDiagnostic, sessionID: session.id,
            diagnosticEvent: Data(repeating: 0, count: 512 * 1_024),
            id: outboxFixtureID(901), createdAt: now), now: now))
        XCTAssertEqual(outbox.items.map(\.id), retainedIDs)
        XCTAssertEqual(outbox.lastSubmittedAt, submittedAt)
        XCTAssertNil(outbox.nextEligible(at: now.addingTimeInterval(1)))
        XCTAssertEqual(outbox.capacityDroppedDiagnostics, 1)
        XCTAssertEqual(outbox.capacityDroppedReadings ?? 0, 0)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(outbox).count,
            LibreWatchConnectivityOutbox.maximumEncodedBytes)
    }

    func testOutboxByteFullDiagnosticReplayPreservesIDsAndSubmissionThrottleBelowItemLimit() throws {
        let now = receivedAt.addingTimeInterval(1_000)
        var outbox = LibreWatchConnectivityOutbox()
        XCTAssertTrue(outbox.enqueue(outboxReading(index: 0), now: now))
        XCTAssertTrue(outbox.enqueue(.command(.reportDiagnostic, sessionID: session.id,
            diagnosticEvent: Data("{}".utf8), id: outboxFixtureID(900), createdAt: now), now: now))
        for item in outbox.items { outbox.markSubmitted(id: item.id, at: now) }

        // Measure the empty Data wrapper, then fill its base64 in whole four-byte groups.
        var probe = outbox
        XCTAssertTrue(probe.enqueue(.command(.reportDiagnostic, sessionID: session.id,
            diagnosticEvent: Data(), id: outboxFixtureID(901), createdAt: now), now: now))
        let remainingBytes = LibreWatchConnectivityOutbox.maximumEncodedBytes - 1_024 -
            (try JSONEncoder().encode(probe).count)
        XCTAssertGreaterThan(remainingBytes, 0)
        XCTAssertTrue(outbox.enqueue(.command(.reportDiagnostic, sessionID: session.id,
            diagnosticEvent: Data(repeating: 0, count: remainingBytes / 4 * 3),
            id: outboxFixtureID(901), createdAt: now), now: now))
        outbox.markSubmitted(id: outboxFixtureID(901), at: now)
        XCTAssertLessThan(outbox.items.count, LibreWatchConnectivityOutbox.maximumItems)
        XCTAssertGreaterThan(try JSONEncoder().encode(outbox).count,
            LibreWatchConnectivityOutbox.maximumEncodedBytes - 1_024 - 4)
        let retainedIDs = outbox.items.map(\.id)
        let submittedAt = outbox.lastSubmittedAt

        var journal = LibreWatchDiagnosticJournal()
        for index in 0 ..< 3 {
            _ = journal.append(LibreWatchDiagnosticEvent(eventID: outboxFixtureID(910 + index),
                kind: .disconnected, watchTimestamp: now, sessionID: session.id), at: now)
        }
        for second in 1 ... 3 {
            let retryDate = now.addingTimeInterval(Double(second))
            for event in journal.pendingEvents() {
                XCTAssertFalse(outbox.enqueue(.command(.reportDiagnostic, sessionID: session.id,
                    diagnosticEvent: try JSONEncoder().encode(event),
                    id: try XCTUnwrap(event.eventID), createdAt: retryDate), now: retryDate))
            }
            XCTAssertEqual(outbox.items.map(\.id), retainedIDs)
            XCTAssertEqual(outbox.lastSubmittedAt, submittedAt)
            XCTAssertNil(outbox.nextEligible(at: retryDate))
            XCTAssertLessThanOrEqual(try JSONEncoder().encode(outbox).count,
                LibreWatchConnectivityOutbox.maximumEncodedBytes)
        }
        XCTAssertEqual(journal.pendingEvents().count, 3)
        XCTAssertEqual(outbox.capacityDroppedDiagnostics, 9)
        XCTAssertEqual(outbox.capacityDroppedReadings ?? 0, 0)
    }

    func testOutboxAllFiveHundredTwelveReadingsFitByteBoundWithSubmissionMetadata() throws {
        let now = receivedAt.addingTimeInterval(1_000)
        var outbox = LibreWatchConnectivityOutbox()
        XCTAssertEqual(LibreWatchConnectivityOutbox.maximumItems, 512)
        XCTAssertEqual(LibreWatchConnectivityOutbox.maximumEncodedBytes, 512 * 1_024)
        for index in 0 ..< LibreWatchConnectivityOutbox.maximumItems {
            XCTAssertTrue(outbox.enqueue(outboxReading(index: index), now: now))
        }
        for item in outbox.items { outbox.markSubmitted(id: item.id, at: now) }
        XCTAssertEqual(outbox.items.count, 512)
        XCTAssertEqual(outbox.lastSubmittedAt?.count, 512)
        XCTAssertEqual(outbox.didPrioritizeLatestReading, true)
        XCTAssertEqual(outbox.capacityDroppedReadings ?? 0, 0)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(outbox).count,
            LibreWatchConnectivityOutbox.maximumEncodedBytes)
    }

    func testOutboxLegacyOversizedDataPrunesDiagnosticsBeforeCommandsOrReadings() throws {
        let now = receivedAt.addingTimeInterval(1_000)
        let counter = LibreWatchOutboxItem.command(.updateUnlockCounter, sessionID: session.id,
            unlockCounter: 42, id: outboxFixtureID(900), createdAt: receivedAt.addingTimeInterval(-2))
        let oversized = LibreWatchOutboxItem.command(.reportDiagnostic, sessionID: session.id,
            diagnosticEvent: Data(repeating: 0, count: 512 * 1_024), id: outboxFixtureID(901),
            createdAt: receivedAt.addingTimeInterval(-1))
        let newerDiagnostic = LibreWatchOutboxItem.command(.reportDiagnostic, sessionID: session.id,
            diagnosticEvent: Data("{}".utf8), id: outboxFixtureID(902), createdAt: now)
        let items = [newerDiagnostic, outboxReading(index: 1), oversized, outboxReading(index: 0), counter]
        let legacy = try JSONSerialization.data(withJSONObject: [
            "items": try JSONSerialization.jsonObject(with: JSONEncoder().encode(items))
        ])
        var outbox = try JSONDecoder().decode(LibreWatchConnectivityOutbox.self, from: legacy)
        XCTAssertLessThan(outbox.items.count, LibreWatchConnectivityOutbox.maximumItems)
        XCTAssertGreaterThan(try JSONEncoder().encode(outbox).count,
            LibreWatchConnectivityOutbox.maximumEncodedBytes)
        XCTAssertNil(outbox.didPrioritizeLatestReading)
        outbox.prune(at: now)
        // Byte pressure uses the same newest-diagnostic-first retention priority as count pressure.
        XCTAssertEqual(outbox.items.map(\.id), [counter.id, outboxFixtureID(0), outboxFixtureID(1)])
        XCTAssertEqual(outbox.capacityDroppedDiagnostics, 2)
        XCTAssertEqual(outbox.capacityDroppedCommands ?? 0, 0)
        XCTAssertEqual(outbox.capacityDroppedReadings ?? 0, 0)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(outbox).count,
            LibreWatchConnectivityOutbox.maximumEncodedBytes)
        XCTAssertEqual(try JSONDecoder().decode(LibreWatchConnectivityOutbox.self,
            from: JSONEncoder().encode(outbox)), outbox)
    }

    private func outboxFixtureID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "A0000000-0000-0000-0000-%012d", index))!
    }

    private func outboxReading(index: Int, at date: Date? = nil) -> LibreWatchOutboxItem {
        .reading(payload(
            id: outboxFixtureID(index), raw: 800, previousRaw: 790,
            domain: .xDripRawGlucose, sensorTime: UInt16(1_000 + index),
            at: date ?? receivedAt.addingTimeInterval(Double(index))
        ))
    }

    func testOutboxSendAttemptRejectsBusyBeginAndStaleSamePayloadCallbacks() throws {
        let payloadID = outboxFixtureID(0)
        var gate = LibreWatchConnectivitySendAttemptGate()
        let attemptA = try XCTUnwrap(gate.begin(payloadID: payloadID, token: outboxFixtureID(1)))
        XCTAssertFalse(gate.isIdle)
        XCTAssertNil(gate.begin(payloadID: outboxFixtureID(10), token: outboxFixtureID(2)))
        XCTAssertTrue(gate.finish(attemptA))
        let attemptB = try XCTUnwrap(gate.begin(payloadID: payloadID, token: outboxFixtureID(3)))
        XCTAssertFalse(gate.matches(attemptA), "A delayed reply/error from attempt A is not attempt B")
        XCTAssertFalse(gate.finish(attemptA))
        XCTAssertTrue(gate.matches(attemptB))
        XCTAssertFalse(gate.finish(.init(payloadID: outboxFixtureID(10), token: attemptB.token)))
        XCTAssertTrue(gate.finish(attemptB))
        XCTAssertTrue(gate.isIdle)
    }

    func testOutboxSendAttemptInvalidationRejectsEveryOldSessionCallback() throws {
        var gate = LibreWatchConnectivitySendAttemptGate()
        let old = try XCTUnwrap(gate.begin(payloadID: outboxFixtureID(0), token: outboxFixtureID(1)))
        gate.invalidate()
        XCTAssertFalse(gate.matches(old))
        XCTAssertFalse(gate.finish(old))
        let current = try XCTUnwrap(gate.begin(payloadID: old.payloadID, token: outboxFixtureID(2)))
        XCTAssertFalse(gate.finish(old))
        XCTAssertEqual(gate.activeAttempt, current)
    }

    func testOutboxDurableReceiptReleasesOnlyMatchingActivePayloadAndRevokesItsCallback() throws {
        var outbox = LibreWatchConnectivityOutbox()
        let first = outboxReading(index: 0)
        let second = outboxReading(index: 1)
        outbox.enqueue(first, now: receivedAt.addingTimeInterval(1))
        outbox.enqueue(second, now: receivedAt.addingTimeInterval(1))
        var gate = LibreWatchConnectivitySendAttemptGate()
        let attempt = try XCTUnwrap(gate.begin(payloadID: second.id, token: outboxFixtureID(9)))

        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(first,
            success: true, outcome: .historicalInserted, durableReceipt: true))
        outbox.remove(id: first.id)
        if let active = gate.activeAttempt, active.payloadID == first.id { gate.finish(active) }
        XCTAssertEqual(gate.activeAttempt, attempt, "A receipt for another payload cannot release this attempt")

        XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.shouldFinish(second,
            success: true, outcome: .liveAccepted, durableReceipt: false))
        XCTAssertEqual(outbox.next?.id, second.id)
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(second,
            success: true, outcome: .liveAccepted, durableReceipt: true))
        outbox.remove(id: second.id)
        if let active = gate.activeAttempt, active.payloadID == second.id { gate.finish(active) }
        XCTAssertTrue(gate.isIdle)
        XCTAssertFalse(gate.matches(attempt), "The later interactive callback is revoked by the durable receipt")
        XCTAssertFalse(gate.finish(attempt))
        XCTAssertTrue(outbox.items.isEmpty)
    }

    func testOutboxPrunesStrictlyAfterSixHoursAndRetainsOnlyActiveSession() {
        let active = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            at: receivedAt
        )
        let otherSessionID = UUID(uuidString: "90000000-0000-0000-0000-000000000009")!
        let other = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_235,
            at: receivedAt.addingTimeInterval(1),
            sessionID: otherSessionID
        )
        var outbox = LibreWatchConnectivityOutbox()
        outbox.enqueue(.reading(active), now: receivedAt.addingTimeInterval(1))
        outbox.enqueue(.reading(other), now: receivedAt.addingTimeInterval(1))

        XCTAssertEqual(LibreWatchReadingAcceptancePolicy.maximumTransportAge, 3 * 60)
        XCTAssertTrue(active.isCurrent(at: receivedAt.addingTimeInterval(3 * 60)))
        XCTAssertFalse(active.isCurrent(at: receivedAt.addingTimeInterval(3 * 60 + 0.001)))
        XCTAssertEqual(LibreWatchConnectivityOutbox.maximumAge, 6 * 60 * 60)
        outbox.prune(at: receivedAt.addingTimeInterval(LibreWatchConnectivityOutbox.maximumAge))
        XCTAssertEqual(Set(outbox.items.map(\.id)), Set([active.id, other.id]))
        outbox.retain(sessionID: session.id)
        XCTAssertEqual(outbox.items.map(\.id), [active.id])

        outbox.prune(at: receivedAt.addingTimeInterval(
            LibreWatchConnectivityOutbox.maximumAge + 0.001
        ))
        XCTAssertTrue(outbox.items.isEmpty)
    }

    func testReadingAcceptanceRejectsDuplicateStaleAndOutOfOrderPayloads() {
        let firstID = UUID()
        let first = payload(
            id: firstID,
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: receivedAt
        )
        var acceptance = LibreWatchReadingAcceptancePolicy()

        XCTAssertTrue(acceptance.accept(first, for: session.id, now: receivedAt.addingTimeInterval(1)))
        XCTAssertFalse(acceptance.accept(first, for: session.id, now: receivedAt.addingTimeInterval(2)))

        let lowerSensorTime = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 999,
            at: receivedAt.addingTimeInterval(60)
        )
        XCTAssertFalse(acceptance.accept(
            lowerSensorTime,
            for: session.id,
            now: receivedAt.addingTimeInterval(61)
        ))

        let olderTimestamp = payload(
            raw: 820,
            previousRaw: 810,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: receivedAt
        )
        XCTAssertFalse(acceptance.accept(
            olderTimestamp,
            for: session.id,
            now: receivedAt.addingTimeInterval(62)
        ))

        let staleTransport = payload(
            raw: 830,
            previousRaw: 820,
            domain: .xDripRawGlucose,
            sensorTime: 1_002,
            at: receivedAt.addingTimeInterval(120)
        )
        XCTAssertFalse(acceptance.accept(
            staleTransport,
            for: session.id,
            now: receivedAt.addingTimeInterval(301)
        ))
    }

    func testLiveTransportKeepsThreeMinuteBoundary() {
        let now = receivedAt.addingTimeInterval(600)
        let exactBoundary = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-LibreWatchReadingAcceptancePolicy.maximumTransportAge)
        )
        let pastBoundary = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: now.addingTimeInterval(-LibreWatchReadingAcceptancePolicy.maximumTransportAge - 0.001)
        )
        var exactAcceptance = LibreWatchReadingAcceptancePolicy()
        var staleAcceptance = LibreWatchReadingAcceptancePolicy()

        XCTAssertTrue(exactAcceptance.accept(exactBoundary, for: session.id, now: now))
        XCTAssertFalse(staleAcceptance.accept(pastBoundary, for: session.id, now: now))
    }

    func testQueuedHistoryUsesReceiverTransportAndSixHourBoundary() {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        // Keep both age-boundary fixtures after the unchanged session start.
        let now = receivedAt.addingTimeInterval(LibreWatchHistoryPolicy.maximumAge + 400)
        XCTAssertEqual(LibreWatchHistoryPolicy.maximumAge, 6 * 60 * 60)
        let exactBoundary = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-LibreWatchHistoryPolicy.maximumAge)
        )
        let pastBoundary = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: now.addingTimeInterval(-LibreWatchHistoryPolicy.maximumAge - 0.001)
        )
        let future = payload(
            raw: 820,
            previousRaw: 810,
            domain: .xDripRawGlucose,
            sensorTime: 1_002,
            at: now.addingTimeInterval(1)
        )

        XCTAssertNil(LibreWatchHistoryPolicy.rejection(
            reading: exactBoundary,
            transport: .queuedUserInfo,
            session: session,
            calibration: snapshot,
            ownership: .watch,
            now: now
        ))
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: exactBoundary,
            transport: .interactiveMessage,
            session: session,
            calibration: snapshot,
            ownership: .watch,
            now: now
        ), .invalidPayload)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: pastBoundary,
            transport: .queuedUserInfo,
            session: session,
            calibration: snapshot,
            ownership: .watch,
            now: now
        ), .tooOld)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: future,
            transport: .queuedUserInfo,
            session: session,
            calibration: snapshot,
            ownership: .watch,
            now: now
        ), .tooOld)
    }

    func testFreshQueuedFallbackUsesLiveRouteBeforeHistoricalBackfill() {
        XCTAssertEqual(
            LibreWatchQueuedReadingRoutingPolicy.route(
                transportAge: LibreWatchReadingAcceptancePolicy.maximumTransportAge,
                ownership: .watch
            ),
            .attemptLiveAcceptance
        )
        XCTAssertEqual(
            LibreWatchQueuedReadingRoutingPolicy.route(
                transportAge: LibreWatchReadingAcceptancePolicy.maximumTransportAge + 0.001,
                ownership: .watch
            ),
            .historicalBackfill
        )
        XCTAssertEqual(
            LibreWatchQueuedReadingRoutingPolicy.route(transportAge: 30, ownership: .iphone),
            .historicalBackfill
        )
    }

    func testFourHundredSecondQueuedReadingRemainsHistoricalWithSixHourRetention() {
        let now = receivedAt.addingTimeInterval(600)
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let reading = payload(raw: 800, previousRaw: 790, domain: .xDripRawGlucose,
            sensorTime: 1_000, at: now.addingTimeInterval(-400))
        var outbox = LibreWatchConnectivityOutbox()
        XCTAssertTrue(outbox.enqueue(.reading(reading), now: now))
        XCTAssertEqual(outbox.items.map(\.id), [reading.id])
        XCTAssertEqual(LibreWatchQueuedReadingRoutingPolicy.route(
            transportAge: now.timeIntervalSince(reading.receivedAt), ownership: .watch), .historicalBackfill)

        var liveAcceptance = LibreWatchReadingAcceptancePolicy()
        XCTAssertFalse(liveAcceptance.accept(reading, for: session.id, now: now))
        XCTAssertNil(liveAcceptance.lastReceivedAt)
        XCTAssertNil(liveAcceptance.lastSensorTimeInMinutes)
        XCTAssertNil(LibreWatchHistoryPolicy.rejection(
            reading: reading, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .watch, now: now))
        let historical = LibreWatchGlucoseProcessingMode.historicalBackfill
        XCTAssertFalse(historical.permitsCurrentValueAndLiveSideEffects)
        XCTAssertFalse(historical.routing.updatesCurrentValue)
        XCTAssertFalse(historical.routing.resetsMissedReadingState)
        XCTAssertFalse(historical.routing.triggersAlerts)
        XCTAssertFalse(historical.routing.exportsToIntegrations)
    }

    func testSixtySecondQueuedReadingStillUsesLiveAcceptanceWithSixHourRetention() {
        let now = receivedAt.addingTimeInterval(600)
        let reading = payload(raw: 800, previousRaw: 790, domain: .xDripRawGlucose,
            sensorTime: 1_000, at: now.addingTimeInterval(-60))
        var outbox = LibreWatchConnectivityOutbox()
        XCTAssertTrue(outbox.enqueue(.reading(reading), now: now))
        XCTAssertEqual(outbox.items.map(\.id), [reading.id])
        XCTAssertEqual(LibreWatchReadingAcceptancePolicy.maximumTransportAge, 3 * 60)
        XCTAssertEqual(LibreWatchQueuedReadingRoutingPolicy.route(
            transportAge: now.timeIntervalSince(reading.receivedAt), ownership: .watch), .attemptLiveAcceptance)

        var liveAcceptance = LibreWatchReadingAcceptancePolicy()
        XCTAssertTrue(liveAcceptance.accept(reading, for: session.id, now: now))
        XCTAssertEqual(liveAcceptance.lastReceivedAt, reading.receivedAt)
        XCTAssertEqual(liveAcceptance.lastSensorTimeInMinutes, reading.sensorTimeInMinutes)
        XCTAssertTrue(LibreWatchGlucoseProcessingMode.live.permitsCurrentValueAndLiveSideEffects)
    }

    func testReleaseReceiptAllowsOnlyPreCutoffQueuedHistoryAcrossPhoneReturn() throws {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let cutoff = receivedAt.addingTimeInterval(600)
        var receipt = try XCTUnwrap(LibreWatchReleaseReceipt(
            session: session,
            calibration: snapshot,
            cutoff: cutoff,
            now: cutoff
        ))
        let before = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: cutoff.addingTimeInterval(-60)
        )
        let after = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: cutoff.addingTimeInterval(1)
        )

        XCTAssertNil(LibreWatchHistoryPolicy.rejection(
            reading: before, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .releasingToPhone,
            receipt: receipt, now: cutoff.addingTimeInterval(10)
        ))
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: before, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .iphone,
            receipt: receipt, now: cutoff.addingTimeInterval(10)
        ), .missingReceipt)

        receipt.complete()
        XCTAssertNil(LibreWatchHistoryPolicy.rejection(
            reading: before, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .iphone,
            receipt: receipt, now: cutoff.addingTimeInterval(10)
        ))
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: after, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .iphone,
            receipt: receipt, now: cutoff.addingTimeInterval(10)
        ), .afterCutoff)
    }

    func testReleaseReceiptIsPersistedAndCannotCrossSessionOrCalibration() throws {
        let defaults = isolatedDefaults()
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let cutoff = receivedAt.addingTimeInterval(600)
        var receipt = try XCTUnwrap(LibreWatchReleaseReceipt(
            session: session,
            calibration: snapshot,
            cutoff: cutoff,
            now: cutoff
        ))
        receipt.complete()
        LibreWatchSessionStore.saveSession(session, defaults: defaults)
        LibreWatchSessionStore.saveReleaseReceipt(receipt, defaults: defaults)
        XCTAssertEqual(LibreWatchSessionStore.loadReleaseReceipt(defaults: defaults), receipt)

        let changedCalibration = calibration(type: .fixedSlope, slope: 1.1, intercept: 0)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: payload(
                raw: 800,
                previousRaw: 790,
                domain: .xDripRawGlucose,
                sensorTime: 1_000,
                at: cutoff.addingTimeInterval(-60)
            ),
            transport: .queuedUserInfo,
            session: session,
            calibration: changedCalibration,
            ownership: .iphone,
            receipt: receipt,
            now: cutoff.addingTimeInterval(10)
        ), .missingReceipt)

        let replacementSession = LibreWatchDirectSession(
            sensorUID: session.sensorUID,
            patchInfo: session.patchInfo,
            sensorSerialNumber: session.sensorSerialNumber,
            sensorTypeRawValue: session.sensorTypeRawValue,
            expectedPeripheralName: session.expectedPeripheralName,
            unlockCode: session.unlockCode,
            unlockCount: session.unlockCount,
            algorithmParameters: session.algorithmParameters
        )
        LibreWatchSessionStore.saveSession(replacementSession, defaults: defaults)
        XCTAssertNil(LibreWatchSessionStore.loadReleaseReceipt(defaults: defaults))
    }

    func testFailedReleaseClearsReceiptAndRestoresConservativeWatchOwner() throws {
        let defaults = isolatedDefaults()
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let cutoff = receivedAt.addingTimeInterval(600)
        let receipt = try XCTUnwrap(LibreWatchReleaseReceipt(
            session: session,
            calibration: snapshot,
            cutoff: cutoff,
            now: cutoff
        ))
        LibreWatchSessionStore.saveSession(session, defaults: defaults)
        LibreWatchSessionStore.saveReleaseReceipt(receipt, defaults: defaults)
        LibreWatchSessionStore.saveOwnership(.releasingToPhone, defaults: defaults)

        // Mirrors the failed returnSensorToPhone branch: never enable iPhone when
        // the physical release was not completed.
        LibreWatchSessionStore.clearReleaseReceipt(defaults: defaults)
        LibreWatchSessionStore.saveOwnership(.watch, defaults: defaults)

        XCTAssertNil(LibreWatchSessionStore.loadReleaseReceipt(defaults: defaults))
        let startup = LibreWatchPhoneStartupDecision.resolve(
            persistedOwnership: LibreWatchSessionStore.loadOwnership(defaults: defaults),
            persistedSession: LibreWatchSessionStore.loadSession(defaults: defaults),
            activeSensorUID: session.sensorUID,
            activePatchInfo: session.patchInfo
        )
        XCTAssertTrue(startup.phoneConnectionIsBlocked)
        XCTAssertEqual(startup.ownership, .watch)
    }

    func testExpiredReceiptCannotAuthorizeQueuedHistoryAfterReturn() throws {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let cutoff = receivedAt.addingTimeInterval(600)
        var receipt = try XCTUnwrap(LibreWatchReleaseReceipt(
            session: session,
            calibration: snapshot,
            cutoff: cutoff,
            now: cutoff
        ))
        receipt.complete()
        let reading = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: cutoff.addingTimeInterval(-60)
        )
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: reading,
            transport: .queuedUserInfo,
            session: session,
            calibration: snapshot,
            ownership: .iphone,
            receipt: receipt,
            now: receipt.expiresAt.addingTimeInterval(0.001)
        ), .tooOld)
    }

    func testReleaseReceiptExpiresStrictlyAtSixHoursWhileReadingAgeBoundaryIsInclusive() throws {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let cutoff = receivedAt.addingTimeInterval(600)
        var receipt = try XCTUnwrap(LibreWatchReleaseReceipt(
            session: session, calibration: snapshot, cutoff: cutoff, now: cutoff))
        receipt.complete()
        XCTAssertEqual(receipt.expiresAt, cutoff.addingTimeInterval(6 * 60 * 60))
        // A reading exactly at cutoff stays age-valid at expiry, isolating the receipt guard.
        let reading = payload(raw: 800, previousRaw: 790, domain: .xDripRawGlucose,
            sensorTime: 1_000, at: cutoff)

        XCTAssertNil(LibreWatchHistoryPolicy.rejection(
            reading: reading, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .iphone, receipt: receipt,
            now: receipt.expiresAt.addingTimeInterval(-0.001)))
        XCTAssertNil(LibreWatchHistoryPolicy.rejection(
            reading: reading, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .watch, now: receipt.expiresAt))
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: reading, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .iphone, receipt: receipt,
            now: receipt.expiresAt), .missingReceipt)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: reading, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .iphone, receipt: receipt,
            now: receipt.expiresAt.addingTimeInterval(0.001)), .tooOld)
    }

    func testReleaseReceiptCreationKeepsStrictSixHourCutoffBoundary() throws {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let cutoff = receivedAt.addingTimeInterval(600)
        let expiresAt = cutoff.addingTimeInterval(LibreWatchHistoryPolicy.maximumAge)
        let receipt = try XCTUnwrap(LibreWatchReleaseReceipt(
            session: session, calibration: snapshot, cutoff: cutoff,
            now: expiresAt.addingTimeInterval(-0.001)))
        XCTAssertEqual(receipt.expiresAt, expiresAt)
        XCTAssertNil(LibreWatchReleaseReceipt(
            session: session, calibration: snapshot, cutoff: cutoff, now: expiresAt))
        XCTAssertNil(LibreWatchReleaseReceipt(
            session: session, calibration: snapshot, cutoff: cutoff,
            now: expiresAt.addingTimeInterval(0.001)))
    }

    @MainActor
    func testBackfillUsesPersistentPayloadIdentityAndPreservesPhoneCollision() async throws {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = stack.mainManagedObjectContext
        let sensor = Sensor(startDate: session.createdAt, nsManagedObjectContext: context)
        let reading = payload(
            raw: 847,
            previousRaw: 830,
            domain: .factoryNativeMGDL,
            sensorTime: 1_234,
            at: receivedAt
        )
        let phone = BgReading(
            timeStamp: receivedAt,
            sensor: sensor,
            calibration: nil,
            rawData: 120,
            deviceName: nil,
            nsManagedObjectContext: context
        )
        phone.calculatedValue = 120
        phone.id = reading.id.uuidString
        XCTAssertTrue(stack.saveChanges())

        let sensorID = sensor.id
        await stack.privateManagedObjectContext.perform {}
        context.reset()
        let request: NSFetchRequest<BgReading> = BgReading.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", reading.id.uuidString)
        let stored = try XCTUnwrap(context.fetch(request).first)

        XCTAssertFalse(stored.objectID.isTemporaryID)
        XCTAssertTrue(LibreWatchHistoryPolicy.collides(
            payloadID: reading.id.uuidString,
            measuredAt: receivedAt.addingTimeInterval(-600),
            sensorID: sensorID,
            existingID: stored.id,
            existingAt: stored.timeStamp,
            existingSensorID: stored.sensor?.id
        ))
        XCTAssertTrue(LibreWatchHistoryPolicy.collides(
            payloadID: UUID().uuidString,
            measuredAt: receivedAt.addingTimeInterval(5),
            sensorID: sensorID,
            existingID: stored.id,
            existingAt: stored.timeStamp,
            existingSensorID: stored.sensor?.id
        ))
        XCTAssertFalse(LibreWatchHistoryPolicy.collides(
            payloadID: reading.id.uuidString,
            measuredAt: receivedAt,
            sensorID: "another-sensor",
            existingID: stored.id,
            existingAt: stored.timeStamp,
            existingSensorID: stored.sensor?.id
        ))
        XCTAssertEqual(stored.calculatedValue, 120)
        XCTAssertEqual(try context.count(for: BgReading.fetchRequest()), 1)
    }

    @MainActor
    func testHistoricalTimeCollisionIgnoresInvalidDifferentPayloadButPreservesExactIdentity() throws {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = stack.mainManagedObjectContext
        let sensor = Sensor(startDate: session.createdAt, nsManagedObjectContext: context)
        let invalid = BgReading(
            timeStamp: receivedAt,
            sensor: sensor,
            calibration: nil,
            rawData: 100,
            deviceName: nil,
            nsManagedObjectContext: context
        )
        invalid.calculatedValue = 0
        invalid.id = UUID().uuidString
        let incomingID = UUID().uuidString

        XCTAssertFalse(invalid.isValidForDownstream)
        XCTAssertFalse(LibreWatchHistoryPolicy.collides(
            payloadID: incomingID,
            measuredAt: receivedAt,
            sensorID: sensor.id,
            existingID: invalid.id,
            existingAt: invalid.timeStamp,
            existingSensorID: invalid.sensor?.id,
            existingIsValid: invalid.isValidForDownstream
        ))
        XCTAssertTrue(LibreWatchHistoryPolicy.collides(
            payloadID: invalid.id,
            measuredAt: receivedAt.addingTimeInterval(-600),
            sensorID: sensor.id,
            existingID: invalid.id,
            existingAt: invalid.timeStamp,
            existingSensorID: invalid.sensor?.id,
            existingIsValid: invalid.isValidForDownstream
        ))
        XCTAssertEqual(
            LibreWatchStoredReadingPolicy.outcome(
                isValid: invalid.isValidForDownstream,
                calculatedValue: invalid.calculatedValue
            ),
            .historyNotInserted
        )

        invalid.calculatedValue = 100
        invalid.ageAdjustedRawValue = 100
        XCTAssertTrue(invalid.isValidForDownstream)
        XCTAssertTrue(LibreWatchHistoryPolicy.collides(
            payloadID: incomingID,
            measuredAt: receivedAt,
            sensorID: sensor.id,
            existingID: invalid.id,
            existingAt: invalid.timeStamp,
            existingSensorID: invalid.sensor?.id,
            existingIsValid: invalid.isValidForDownstream
        ))
    }

    @MainActor
    func testHistoricalCalibrationDoesNotRefineCalibrationOrChangeCurrentValueAndTrend() throws {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = stack.mainManagedObjectContext
        let sensor = Sensor(startDate: session.createdAt, nsManagedObjectContext: context)
        let calibration = Calibration(
            timeStamp: receivedAt.addingTimeInterval(-600),
            sensor: sensor,
            bg: 100,
            rawValue: 100,
            adjustedRawValue: 100,
            sensorConfidence: 1,
            rawTimeStamp: receivedAt.addingTimeInterval(-600),
            slope: 1.1,
            intercept: 4,
            distanceFromEstimate: 0,
            estimateRawAtTimeOfCalibration: 100,
            slopeConfidence: 1,
            deviceName: nil,
            nsManagedObjectContext: context
        )
        let current = BgReading(
            timeStamp: receivedAt,
            sensor: sensor,
            calibration: calibration,
            rawData: 100,
            deviceName: nil,
            nsManagedObjectContext: context
        )
        current.calculatedValue = 114
        current.calculatedValueSlope = 0.02
        current.calibrationFlag = true

        let calibrators: [Calibrator] = [Libre1Calibrator(), Libre1NonFixedSlopeCalibrator()]
        for calibrator in calibrators {
            var previous = [current]
            var calibrations = [calibration]
            let reading = calibrator.createHistoricalBgReading(
                rawData: 847 * ConstantsBloodGlucose.libreMultiplier,
                timeStamp: receivedAt.addingTimeInterval(-300),
                sensor: sensor,
                last3Readings: &previous,
                lastCalibrationsForActiveSensorInLastXDays: &calibrations,
                firstCalibration: calibration,
                lastCalibration: calibration,
                deviceName: nil,
                nsManagedObjectContext: context
            )
            XCTAssertEqual(
                reading.calculatedValue,
                iphoneCalibratedValue(
                    input: 847 * ConstantsBloodGlucose.libreMultiplier,
                    slope: 1.1,
                    intercept: 4,
                    divider: 1_000
                ),
                accuracy: 0.000_001
            )
            XCTAssertEqual(calibration.slope, 1.1)
            XCTAssertEqual(calibration.intercept, 4)
            XCTAssertEqual(calibration.estimateRawAtTimeOfCalibration, 100)
            XCTAssertEqual(current.calculatedValue, 114)
            XCTAssertEqual(current.calculatedValueSlope, 0.02)
        }
    }

    func testHistoricalOutOfOrderEligibilityDoesNotMoveLiveWatermark() {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let now = receivedAt.addingTimeInterval(3_600)
        let live = payload(
            raw: 900,
            previousRaw: 890,
            domain: .xDripRawGlucose,
            sensorTime: 2_000,
            at: now
        )
        let historicalNewer = payload(
            raw: 850,
            previousRaw: 840,
            domain: .xDripRawGlucose,
            sensorTime: 1_500,
            at: now.addingTimeInterval(-600)
        )
        let historicalOlder = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-1_800)
        )
        var liveAcceptance = LibreWatchReadingAcceptancePolicy()
        XCTAssertTrue(liveAcceptance.accept(live, for: session.id, now: now))

        for reading in [historicalNewer, historicalOlder] {
            XCTAssertNil(LibreWatchHistoryPolicy.rejection(
                reading: reading,
                transport: .queuedUserInfo,
                session: session,
                calibration: snapshot,
                ownership: .watch,
                now: now
            ))
        }
        XCTAssertEqual(liveAcceptance.lastSensorTimeInMinutes, live.sensorTimeInMinutes)
        XCTAssertEqual(liveAcceptance.lastReceivedAt, live.receivedAt)
        XCTAssertTrue(liveAcceptance.accept(
            payload(
                raw: 910,
                previousRaw: 900,
                domain: .xDripRawGlucose,
                sensorTime: 2_001,
                at: now.addingTimeInterval(60)
            ),
            for: session.id,
            now: now.addingTimeInterval(60)
        ))
    }

    func testQueuedHistoryRejectsOwnershipSessionCalibrationAndValueMismatches() {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let now = receivedAt.addingTimeInterval(600)
        let valid = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-300)
        )
        let wrongSession = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-300),
            sessionID: UUID()
        )
        let wrongRevision = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-300),
            revision: snapshot.revision - 1
        )
        let invalidValue = payload(
            native: 0,
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-300)
        )
        let zeroID = payload(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-300)
        )
        let beforeSession = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: session.createdAt.addingTimeInterval(-1)
        )
        let zeroSensorTime = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 0,
            at: now.addingTimeInterval(-300)
        )

        XCTAssertNil(LibreWatchHistoryPolicy.rejection(
            reading: valid, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .watch, now: now
        ))
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: valid, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .iphone, now: now
        ), .missingReceipt)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: wrongSession, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .watch, now: now
        ), .wrongSession)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: wrongRevision, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .watch, now: now
        ), .wrongCalibration)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: invalidValue, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .watch, now: now
        ), .invalidPayload)
        for invalid in [zeroID, beforeSession, zeroSensorTime] {
            XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
                reading: invalid, transport: .queuedUserInfo, session: session,
                calibration: snapshot, ownership: .watch, now: now
            ), .invalidPayload)
        }
    }

    func testReadingAcceptanceAllowsFreshLowThenNextNormalReading() throws {
        let snapshot = calibration(type: .factoryCalibrated, slope: 1, intercept: 0)
        let low = payload(
            native: 38,
            previousNative: 45,
            raw: 1,
            previousRaw: 2,
            domain: .factoryNativeMGDL,
            sensorTime: 1_000,
            at: receivedAt
        )
        let normal = payload(
            native: 90,
            previousNative: 85,
            raw: 900,
            previousRaw: 850,
            domain: .factoryNativeMGDL,
            sensorTime: 1_001,
            at: receivedAt.addingTimeInterval(60)
        )
        var acceptance = LibreWatchReadingAcceptancePolicy()

        XCTAssertEqual(try XCTUnwrap(snapshot.displayedGlucose(for: low)), 38)
        XCTAssertTrue(acceptance.accept(low, for: session.id, now: receivedAt.addingTimeInterval(1)))
        XCTAssertTrue(acceptance.accept(
            normal,
            for: session.id,
            now: receivedAt.addingTimeInterval(61)
        ))
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.displayedGlucose(for: normal)), 38)
    }

    func testInternalCalibrationMarkerIsNotAClinicalLowButCompletedThirtyNineIsValid() {
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: 92,
                rawData: 92,
                ageAdjustedRawValue: 0,
                finalValue: 92,
                calibrationUsesErrorSentinel: false
            ),
            .valid
        )
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: 38,
                rawData: 0.12,
                ageAdjustedRawValue: 0.12,
                finalValue: 38,
                calibrationUsesErrorSentinel: true
            ),
            .internalCalibrationError
        )
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: 39,
                rawData: 11.7,
                ageAdjustedRawValue: 11.7,
                finalValue: 39,
                calibrationUsesErrorSentinel: true
            ),
            .valid
        )
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: 95,
                rawData: 95,
                ageAdjustedRawValue: 0,
                finalValue: 95,
                calibrationUsesErrorSentinel: false
            ),
            .valid
        )
    }

    func testFreshNativeThirtyEightRemainsAValidPhysiologicalLow() {
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: 38,
                rawData: 38,
                ageAdjustedRawValue: 0,
                finalValue: 38,
                calibrationUsesErrorSentinel: false
            ),
            .valid
        )
    }

    func testTwoUncalibratedRawReadingsRequestInitialCalibrationExactlyOnce() {
        var gate = InitialCalibrationRequestGate()

        XCTAssertFalse(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: false,
            validRawReadingCount: 2,
            initialCalibrationIsRequired: true
        ))
        XCTAssertFalse(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: true,
            validRawReadingCount: 1,
            initialCalibrationIsRequired: true
        ))
        XCTAssertTrue(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: true,
            validRawReadingCount: 2,
            initialCalibrationIsRequired: true
        ))
        XCTAssertFalse(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: true,
            validRawReadingCount: 3,
            initialCalibrationIsRequired: true
        ))
        XCTAssertEqual(gate.requestedSensorID, "sensor-a")
    }

    func testUncalibratedRawReadingsRemainUnavailableToDownstreamConsumers() {
        let readings = [
            (rawValue: 82.0, calculatedValue: 0.0),
            (rawValue: 84.0, calculatedValue: 0.0)
        ]
        var gate = InitialCalibrationRequestGate()

        XCTAssertTrue(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: true,
            validRawReadingCount: readings.count,
            initialCalibrationIsRequired: true
        ))

        let downstreamReadings = readings.filter {
            BgReadingDownstreamPolicy.validity(
                calculatedValue: $0.calculatedValue,
                rawData: $0.rawValue,
                ageAdjustedRawValue: $0.rawValue,
                finalValue: $0.calculatedValue,
                calibrationUsesErrorSentinel: true
            ) == .valid
        }

        XCTAssertTrue(downstreamReadings.isEmpty)
    }

    func testCompletedReadingResumesDownstreamAfterInitialCalibration() {
        var gate = InitialCalibrationRequestGate()
        let completed = (rawValue: 84.0, calculatedValue: 91.0)

        XCTAssertFalse(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: true,
            validRawReadingCount: 2,
            initialCalibrationIsRequired: false
        ))
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: completed.calculatedValue,
                rawData: completed.rawValue,
                ageAdjustedRawValue: completed.rawValue,
                finalValue: completed.calculatedValue,
                calibrationUsesErrorSentinel: true
            ),
            .valid
        )
    }

    func testWatchRejectsFailedXDripCalculationInsteadOfDisplayingFalseLow() {
        let failed = payload(
            native: 84,
            previousNative: 83,
            raw: 1,
            previousRaw: 1,
            domain: .xDripRawGlucose
        )
        let completedLow = payload(
            native: 84,
            previousNative: 83,
            raw: 100,
            previousRaw: 100,
            domain: .xDripRawGlucose
        )
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)

        XCTAssertNil(snapshot.displayedGlucose(for: failed))
        XCTAssertEqual(snapshot.displayedGlucose(for: completedLow), 39)
    }

    func testHealthKitUploadStateSerializesConcurrentStoreRequestsWithoutSkippingFailures() {
        let first = receivedAt
        let second = receivedAt.addingTimeInterval(60)
        var state = HealthKitUploadState(latestStoredTimeStamp: receivedAt.addingTimeInterval(-60))

        XCTAssertTrue(state.begin(timeStamp: first, now: receivedAt))
        XCTAssertFalse(state.begin(timeStamp: second, now: receivedAt))
        XCTAssertFalse(state.beginReplacement(timeStamp: first))
        XCTAssertTrue(state.beginReplacement(timeStamp: second))
        XCTAssertTrue(state.isInFlight(timeStamp: second))
        state.finishReplacement(timeStamp: second)
        XCTAssertEqual(
            state.finish(timeStamp: second, succeeded: true, now: receivedAt),
            .ignored
        )

        let retryAt = receivedAt.addingTimeInterval(30)
        XCTAssertEqual(
            state.finish(timeStamp: first, succeeded: false, now: receivedAt),
            .retry(retryAt)
        )
        XCTAssertEqual(state.latestStoredTimeStamp, receivedAt.addingTimeInterval(-60))
        XCTAssertFalse(state.begin(timeStamp: first, now: retryAt.addingTimeInterval(-1)))
        XCTAssertTrue(state.begin(timeStamp: first, now: retryAt))
        XCTAssertEqual(
            state.finish(timeStamp: first, succeeded: true, now: retryAt),
            .stored(first)
        )
        XCTAssertTrue(state.begin(timeStamp: second, now: retryAt))
        XCTAssertEqual(
            state.finish(timeStamp: second, succeeded: true, now: retryAt),
            .stored(second)
        )
        state.synchronizeLatestStoredTimeStamp(first)
        XCTAssertEqual(state.latestStoredTimeStamp, second)
    }

    func testColdLaunchWithMatchingWatchOwnerBlocksPhoneBeforeBluetoothStarts() {
        let decision = LibreWatchPhoneStartupDecision.resolve(
            persistedOwnership: .watch,
            persistedSession: session,
            activeSensorUID: session.sensorUID,
            activePatchInfo: session.patchInfo
        )

        XCTAssertEqual(decision.ownership, .watch)
        XCTAssertTrue(decision.phoneConnectionIsBlocked)
        XCTAssertEqual(decision.session?.id, session.id)
    }

    func testCompletedReturnToIPhoneAllowsNormalPhoneConnection() {
        let decision = LibreWatchPhoneStartupDecision.resolve(
            persistedOwnership: .iphone,
            persistedSession: session,
            activeSensorUID: session.sensorUID,
            activePatchInfo: session.patchInfo
        )

        XCTAssertEqual(decision.ownership, .iphone)
        XCTAssertFalse(decision.phoneConnectionIsBlocked)
    }

    func testInterruptedHandoffsStayWithWatchAndSensorChangeCannotCreateDualOwnership() {
        for interrupted in [
            LibreWatchOwnership.releasingToWatch,
            .releasingToPhone,
            .recovery
        ] {
            let decision = LibreWatchPhoneStartupDecision.resolve(
                persistedOwnership: interrupted,
                persistedSession: session,
                activeSensorUID: session.sensorUID,
                activePatchInfo: session.patchInfo
            )
            XCTAssertEqual(decision.ownership, .watch)
            XCTAssertTrue(decision.phoneConnectionIsBlocked)
        }

        let changedSensor = LibreWatchPhoneStartupDecision.resolve(
            persistedOwnership: .watch,
            persistedSession: session,
            activeSensorUID: Data(repeating: 9, count: 8),
            activePatchInfo: session.patchInfo
        )
        XCTAssertEqual(changedSensor.ownership, .iphone)
        XCTAssertFalse(changedSensor.phoneConnectionIsBlocked)
    }

    func testReadingAcceptanceResetsForNewOwnershipSession() {
        let first = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: receivedAt
        )
        var acceptance = LibreWatchReadingAcceptancePolicy()
        XCTAssertTrue(acceptance.accept(first, for: session.id, now: receivedAt.addingTimeInterval(1)))

        acceptance.reset(for: session.id)
        XCTAssertTrue(acceptance.accept(first, for: session.id, now: receivedAt.addingTimeInterval(2)))

        acceptance.reset()
        XCTAssertNil(acceptance.sessionID)
        XCTAssertNil(acceptance.lastSensorTimeInMinutes)
        XCTAssertNil(acceptance.lastReceivedAt)
    }

    func testReturningOwnershipToIPhoneStopsRuntimeAndRecovery() {
        XCTAssertTrue(LibreWatchLifecyclePolicy.shouldStopExtendedRuntime(
            ownership: .releasingToPhone
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.shouldStopExtendedRuntime(
            ownership: .iphone
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: true,
            extendedRuntimeIsRunning: true,
            ownership: .iphone
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(
            ownership: .iphone
        ))
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.disconnectRecoveryAction(
                isDeliberate: false,
                systemIsReconnecting: false,
                ownership: .iphone
            ),
            .noAdditionalWork
        )
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.disconnectRecoveryAction(
                isDeliberate: true,
                systemIsReconnecting: false,
                ownership: .watch
            ),
            .finishDeliberateDisconnect
        )
    }

    private func restorationAction(
        _ restoration: inout LibreWatchRestorationState,
        generation: UUID,
        centralIsPoweredOn: Bool = true,
        peripheralState: LibreWatchObservedPeripheralState = .connected,
        hasService: Bool = true,
        hasWriteCharacteristic: Bool = true,
        hasReceiveCharacteristic: Bool = true,
        receiveIsNotifying: Bool = true,
        connectionPhase: LibreWatchConnectionTiming.Phase? = nil,
        ownership: LibreWatchOwnership = .watch,
        cancellationIsActive: Bool = false
    ) -> LibreWatchRestorationState.Action {
        restoration.nextAction(
            centralIsPoweredOn: centralIsPoweredOn,
            peripheralState: peripheralState,
            hasService: hasService,
            hasWriteCharacteristic: hasWriteCharacteristic,
            hasReceiveCharacteristic: hasReceiveCharacteristic,
            receiveIsNotifying: receiveIsNotifying,
            connectionPhase: connectionPhase,
            currentGeneration: generation,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            ownership: ownership,
            cancellationIsActive: cancellationIsActive
        )
    }

    private func freshRestorationAction(
        generation: UUID,
        hasService: Bool,
        hasWriteCharacteristic: Bool,
        hasReceiveCharacteristic: Bool,
        receiveIsNotifying: Bool
    ) -> LibreWatchRestorationState.Action {
        var restoration = LibreWatchRestorationState(
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: generation
        )
        return restorationAction(
            &restoration,
            generation: generation,
            hasService: hasService,
            hasWriteCharacteristic: hasWriteCharacteristic,
            hasReceiveCharacteristic: hasReceiveCharacteristic,
            receiveIsNotifying: receiveIsNotifying
        )
    }

    private var watchAlgorithmParameters: LibreWatchAlgorithmParameters {
        LibreWatchAlgorithmParameters(
            slopeSlope: 0,
            slopeOffset: 0,
            offsetSlope: 0.1,
            offsetOffset: 0,
            extraSlope: 1,
            extraOffset: 0,
            sensorSerialNumber: "TEST-SENSOR"
        )
    }

    private var phoneAlgorithmParameters: Libre1DerivedAlgorithmParameters {
        Libre1DerivedAlgorithmParameters(
            slope_slope: watchAlgorithmParameters.slopeSlope,
            slope_offset: watchAlgorithmParameters.slopeOffset,
            offset_slope: watchAlgorithmParameters.offsetSlope,
            offset_offset: watchAlgorithmParameters.offsetOffset,
            isValidForFooterWithReverseCRCs: 0,
            extraSlope: watchAlgorithmParameters.extraSlope,
            extraOffset: watchAlgorithmParameters.extraOffset,
            sensorSerialNumber: watchAlgorithmParameters.sensorSerialNumber
        )
    }

    private var session: LibreWatchDirectSession {
        LibreWatchDirectSession(
            id: UUID(uuidString: "A0B1C2D3-E4F5-4678-9123-456789ABCDEF")!,
            createdAt: receivedAt.addingTimeInterval(-3_600),
            sensorUID: Data([1, 2, 3, 4, 5, 6, 7, 8]),
            patchInfo: Data([0, 1, 2, 3, 4, 5]),
            sensorSerialNumber: "TEST-SENSOR",
            sensorTypeRawValue: "7F",
            expectedPeripheralName: "AABBCCDDEEFF",
            unlockCode: 1_000,
            unlockCount: 4,
            algorithmParameters: watchAlgorithmParameters
        )
    }

    private func calibration(
        type: LibreWatchCalibrationType,
        slope: Double,
        intercept: Double,
        revision: UInt64 = 10
    ) -> LibreWatchCalibrationSnapshot {
        LibreWatchCalibrationSnapshot(
            activeSensorID: "active-sensor",
            sensorUID: session.sensorUID,
            sensorSerialNumber: session.sensorSerialNumber,
            watchSessionID: session.id,
            calibrationType: type,
            slope: slope,
            intercept: intercept,
            rawValueDivider: type.usesXDripCalibration ? 1_000 : 1,
            calibratedAt: receivedAt.addingTimeInterval(-600),
            revision: revision
        )
    }

    private func payload(
        version: Int = LibreWatchDirectReadingPayload.currentVersion,
        id: UUID = UUID(),
        native: Double = 84.7,
        previousNative: Double = 82.9,
        raw: UInt16,
        previousRaw: UInt16,
        domain: LibreWatchValueDomain,
        sensorTime: UInt16 = 1_234,
        at timestamp: Date? = nil,
        sessionID: UUID? = nil,
        revision: UInt64 = 10
    ) -> LibreWatchDirectReadingPayload {
        LibreWatchDirectReadingPayload(
            version: version,
            id: id,
            sessionID: sessionID ?? session.id,
            valueDomain: domain,
            nativeGlucoseMGDL: native,
            previousNativeGlucoseMGDL: previousNative,
            rawGlucose: raw,
            previousRawGlucose: previousRaw,
            sensorTimeInMinutes: sensorTime,
            receivedAt: timestamp ?? receivedAt,
            calibrationRevision: revision
        )
    }

    private func iphoneCalibratedValue(
        input: Double,
        slope: Double,
        intercept: Double,
        divider: Double
    ) -> Double {
        let calculated = slope * (input / divider) + intercept
        if calculated < 10 { return 38 }
        return min(400, max(39, calculated))
    }

    private func phoneParsedValue(
        frame: Data,
        parameters: Libre1DerivedAlgorithmParameters?
    ) -> Double {
        clearPhoneLibreParserCache()
        defer { clearPhoneLibreParserCache() }
        return Libre2BLEUtilities.parseBLEData(
            frame,
            libre1DerivedAlgorithmParameters: parameters,
            newestReadingDate: receivedAt
        ).bleGlucose.first!.glucoseLevelRaw
    }

    private func decryptedFrame(currentRaw: Int, previousRaw: Int) -> Data {
        var frame = Data(repeating: 0, count: Libre2WatchDirectConstants.decryptedFrameLength)
        for sampleIndex in 0 ..< 7 {
            let raw = max(1, currentRaw - sampleIndex * (currentRaw - previousRaw))
            setBits(raw, in: &frame, byteOffset: sampleIndex * 4, bitOffset: 0, bitCount: 14)
            setBits(2_000, in: &frame, byteOffset: sampleIndex * 4, bitOffset: 14, bitCount: 12)
        }
        frame[40] = 0xD2
        frame[41] = 0x04
        return frame
    }

    private func setBits(
        _ value: Int,
        in data: inout Data,
        byteOffset: Int,
        bitOffset: Int,
        bitCount: Int
    ) {
        for index in 0 ..< bitCount {
            let absoluteBit = byteOffset * 8 + bitOffset + index
            let byteIndex = absoluteBit / 8
            let bitMask = UInt8(1 << (absoluteBit % 8))
            if (value & (1 << index)) != 0 {
                data[byteIndex] |= bitMask
            } else {
                data[byteIndex] &= ~bitMask
            }
        }
    }

    private func clearPhoneLibreParserCache() {
        UserDefaults.standard.previousRawGlucoseValues = nil
        UserDefaults.standard.previousRawTemperatureValues = nil
        UserDefaults.standard.previousTemperatureAdjustmentValues = nil
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "LibreWatchValuePipelineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

extension LibreWatchValuePipelineTests {
    func testComplicationMissingOrCorruptStorageNeverProducesSampleReadings() throws {
        XCTAssertNil(ComplicationSharedUserDefaultsModel.decodeStoredData(nil))
        XCTAssertNil(ComplicationSharedUserDefaultsModel.decodeStoredData(Data("invalid".utf8)))
        var model = complicationModel()
        model.bgReadingDatesAsDouble = []
        XCTAssertNil(ComplicationSharedUserDefaultsModel.decodeStoredData(try JSONEncoder().encode(model)))
    }

    func testDirectComplicationTimelineExpiresWithoutAnotherWatchUpdate() throws {
        let model = complicationModel()
        let readingDate = try XCTUnwrap(model.latestReadingDate)
        let entries = model.timelineDates(startingAt: readingDate.addingTimeInterval(30))
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(model.readingIsCurrent(at: entries[0]))
        XCTAssertTrue(model.readingIsCurrent(at: readingDate.addingTimeInterval(180)))
        XCTAssertFalse(model.readingIsCurrent(at: entries[1]))
        XCTAssertEqual(entries[1].timeIntervalSince(readingDate), 180.001, accuracy: 0.0001)
        XCTAssertEqual(model.bgReadingValues, [85])
        XCTAssertEqual(model.slopeOrdinal, 4) // Storage is unchanged; the expired presentation hides it.
    }

    func testDirectComplicationExpirySurvivesProcessRestart() throws {
        let model = complicationModel()
        let restarted = try XCTUnwrap(ComplicationSharedUserDefaultsModel.decodeStoredData(JSONEncoder().encode(model)))
        let now = try XCTUnwrap(model.latestReadingDate).addingTimeInterval(240)
        XCTAssertEqual(restarted.readingSource, .directLibre)
        XCTAssertEqual(restarted.latestReadingDate, model.latestReadingDate)
        XCTAssertFalse(restarted.readingIsCurrent(at: now))
        XCTAssertEqual(restarted.timelineDates(startingAt: now), [now])
    }

    func testLegacyPhoneComplicationStorageKeepsItsExistingFreshnessWindow() throws {
        var model = complicationModel()
        model.readingSource = nil
        let encoded = try JSONEncoder().encode(model)
        let legacy = try XCTUnwrap(ComplicationSharedUserDefaultsModel.decodeStoredData(encoded))
        let readingDate = try XCTUnwrap(legacy.latestReadingDate)
        XCTAssertNil(legacy.readingSource)
        XCTAssertTrue(legacy.readingIsCurrent(at: readingDate.addingTimeInterval(181)))
        XCTAssertFalse(legacy.readingIsCurrent(at: readingDate.addingTimeInterval(1_201)))
    }

    func testComplicationKeepsValidLowAndDoesNotInventDataWhenDisabled() throws {
        var model = complicationModel()
        model.bgReadingValues = [38]
        let decoded = try XCTUnwrap(ComplicationSharedUserDefaultsModel.decodeStoredData(JSONEncoder().encode(model)))
        XCTAssertEqual(decoded.bgReadingValues, [38])
        model.keepAliveIsDisabled = true
        let now = try XCTUnwrap(model.latestReadingDate)
        XCTAssertFalse(model.readingIsCurrent(at: now))
        XCTAssertEqual(model.timelineDates(startingAt: now), [now])
    }

    private func complicationModel() -> ComplicationSharedUserDefaultsModel {
        ComplicationSharedUserDefaultsModel(
            bgReadingValues: [85],
            bgReadingDatesAsDouble: [Date(timeIntervalSince1970: 1_783_000_000).timeIntervalSince1970],
            isMgDl: false,
            slopeOrdinal: 4,
            deltaValueInUserUnit: 0.1,
            urgentLowLimitInMgDl: 60,
            lowLimitInMgDl: 80,
            highLimitInMgDl: 180,
            urgentHighLimitInMgDl: 250,
            keepAliveIsDisabled: false,
            readingSource: .directLibre
        )
    }
}

extension LibreWatchValuePipelineTests {
    func testWatchAlarmsUseActualThresholdsAndAcceptGenuineLow() {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        let lease = alarmDelegation(settings)
        let low = state.accept(id: UUID(), measuredAt: receivedAt, glucose: 38, settings: settings,
            delegation: lease, watchOwnsSensor: true, now: receivedAt)
        XCTAssertEqual(low?.kind, .veryLow)
        let next = receivedAt.addingTimeInterval(60)
        XCTAssertNil(state.accept(id: UUID(), measuredAt: next, glucose: 120, settings: settings,
            delegation: lease, watchOwnsSensor: true, now: next))
        let high = next.addingTimeInterval(60)
        XCTAssertEqual(state.accept(id: UUID(), measuredAt: high, glucose: 260, settings: settings,
            delegation: lease, watchOwnsSensor: true, now: high)?.kind, .veryHigh)
    }

    func testWatchAlarmsDoNotEnableDisabledRulesOrDelegateWithoutPermission() {
        let enabled = alarmSettings()
        XCTAssertNil(enabled.readinessRevision(notificationsAuthorized: false))
        let disabled = alarmSettings(enabled: false)
        XCTAssertEqual(disabled.readinessRevision(notificationsAuthorized: false), disabled.revision)
        var state = LibreWatchAlarmState()
        state.use(disabled)
        XCTAssertNil(state.accept(id: UUID(), measuredAt: receivedAt, glucose: 38, settings: disabled,
            delegation: alarmDelegation(disabled), watchOwnsSensor: true, now: receivedAt))
        XCTAssertNil(state.nextMissedAlarm(settings: disabled, delegation: alarmDelegation(disabled),
            watchOwnsSensor: true, now: receivedAt))
    }

    func testWatchAlarmsRequireMatchingDelegationAndCurrentOwnership() {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        let wrong = LibreWatchAlarmDelegation(sessionID: UUID(), sensorIdentity: settings.sensorIdentity, settingsRevision: settings.revision)
        XCTAssertNil(state.accept(id: UUID(), measuredAt: receivedAt, glucose: 38, settings: settings,
            delegation: wrong, watchOwnsSensor: true, now: receivedAt))
        XCTAssertNil(state.accept(id: UUID(), measuredAt: receivedAt, glucose: 38, settings: settings,
            delegation: alarmDelegation(settings), watchOwnsSensor: false, now: receivedAt))
        XCTAssertNil(state.lastReadingAt)
        XCTAssertNil(state.nextMissedAlarm(settings: settings, delegation: alarmDelegation(settings),
            watchOwnsSensor: false, now: receivedAt))
    }

    func testWatchAlarmsRejectHistoricalDuplicateAndOutOfOrderReadings() {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        let lease = alarmDelegation(settings)
        XCTAssertNil(state.accept(id: UUID(), measuredAt: receivedAt.addingTimeInterval(-181), glucose: 38,
            settings: settings, delegation: lease, watchOwnsSensor: true, now: receivedAt))
        XCTAssertNil(state.lastReadingAt)
        let id = UUID()
        XCTAssertNil(state.accept(id: id, measuredAt: receivedAt, glucose: 120,
            settings: settings, delegation: lease, watchOwnsSensor: true, now: receivedAt))
        XCTAssertNil(state.accept(id: id, measuredAt: receivedAt, glucose: 38,
            settings: settings, delegation: lease, watchOwnsSensor: true, now: receivedAt))
        XCTAssertNil(state.accept(id: UUID(), measuredAt: receivedAt.addingTimeInterval(-60), glucose: 38,
            settings: settings, delegation: lease, watchOwnsSensor: true, now: receivedAt))
        XCTAssertEqual(state.lastReadingAt, receivedAt)
    }

    func testWatchMissedAlarmUsesOriginalMeasurementAndSnoozeDeadlineAfterRestart() throws {
        let defaults = isolatedDefaults()
        let until = receivedAt.addingTimeInterval(20 * 60)
        let settings = alarmSettings(snoozeAllUntil: until)
        var state = LibreWatchAlarmState()
        state.use(settings)
        XCTAssertNil(state.accept(id: UUID(), measuredAt: receivedAt, glucose: 38,
            settings: settings, delegation: alarmDelegation(settings), watchOwnsSensor: true, now: receivedAt))
        state.snooze(.missed, until: receivedAt.addingTimeInterval(30 * 60))
        LibreWatchAlarmStore.save(state, defaults: defaults)
        LibreWatchAlarmStore.save(settings, defaults: defaults)
        LibreWatchAlarmStore.save(alarmDelegation(settings), defaults: defaults)
        let restored = LibreWatchAlarmStore.state(defaults: defaults)
        let restoredSettings = try XCTUnwrap(LibreWatchAlarmStore.settings(defaults: defaults))
        let due = restored.nextMissedAlarm(settings: restoredSettings,
            delegation: LibreWatchAlarmStore.delegation(defaults: defaults), watchOwnsSensor: true,
            now: receivedAt.addingTimeInterval(60))
        XCTAssertEqual(due?.date, receivedAt.addingTimeInterval(30 * 60))
        XCTAssertEqual(restored.lastReadingAt, receivedAt)
        XCTAssertEqual(restoredSettings.snoozeAllUntil, until)
    }

    func testWatchLowSnoozeAlsoSuppressesUrgentLowAndSurvivesNewConfig() {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        state.snooze(.low, until: receivedAt.addingTimeInterval(600))
        var newer = settings
        newer.revision += 1
        state.use(newer)
        XCTAssertNil(state.accept(id: UUID(), measuredAt: receivedAt, glucose: 38,
            settings: newer, delegation: alarmDelegation(newer), watchOwnsSensor: true, now: receivedAt))
        let later = receivedAt.addingTimeInterval(601)
        XCTAssertEqual(state.accept(id: UUID(), measuredAt: later, glucose: 38,
            settings: newer, delegation: alarmDelegation(newer), watchOwnsSensor: true, now: later)?.kind, .veryLow)
    }

    func testWatchAlarmSensorSessionChangeInvalidatesPreviousMeasurementAndSnooze() {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        _ = state.accept(id: UUID(), measuredAt: receivedAt, glucose: 120,
            settings: settings, delegation: alarmDelegation(settings), watchOwnsSensor: true, now: receivedAt)
        state.snooze(.low, until: receivedAt.addingTimeInterval(600))
        let changed = LibreWatchAlarmSettings(sessionID: UUID(), sensorIdentity: "Libre-other", revision: 3,
            generatedAt: receivedAt, isMgDl: false, rules: settings.rules, snoozes: [], snoozeAllUntil: nil)
        state.use(changed)
        XCTAssertNil(state.lastReadingAt)
        XCTAssertTrue(state.snoozes.isEmpty)
        XCTAssertNil(state.nextMissedAlarm(settings: changed, delegation: alarmDelegation(settings),
            watchOwnsSensor: true, now: receivedAt))
    }

    func testWatchSnoozeBecomesPhoneAuthoritativeOnlyAfterStoredExpiryIsReturned() {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        let expiry = receivedAt.addingTimeInterval(600)
        state.snooze(.low, until: expiry)
        state.acknowledgePhoneSnoozes(settings)
        XCTAssertFalse(state.snoozes.isEmpty)
        let echoed = LibreWatchAlarmSettings(sessionID: settings.sessionID, sensorIdentity: settings.sensorIdentity,
            revision: 2, generatedAt: receivedAt, isMgDl: settings.isMgDl, rules: settings.rules,
            snoozes: state.snoozes, snoozeAllUntil: nil)
        state.acknowledgePhoneSnoozes(echoed)
        XCTAssertTrue(state.snoozes.isEmpty)
        XCTAssertEqual(state.snoozedUntil(.low, settings: echoed), expiry)
        XCTAssertEqual(state.snoozedUntil(.low, settings: settings), .distantPast)
    }

    func testWatchAlarmCompletionRevalidatesSettingsPermissionSnoozeAndLatestReading() throws {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        let readingID = UUID()
        let rule = try XCTUnwrap(state.accept(id: readingID, measuredAt: receivedAt, glucose: 38,
            settings: settings, delegation: alarmDelegation(settings), watchOwnsSensor: true, now: receivedAt))
        func permitted(_ state: LibreWatchAlarmState, _ current: LibreWatchAlarmSettings?, authorized: Bool = true) -> Bool {
            state.glucoseNotificationIsCurrent(readingID: readingID, rule: rule, submittedSettings: settings,
                currentSettings: current, delegation: alarmDelegation(settings), watchOwnsSensor: true,
                notificationsAuthorized: authorized, now: receivedAt)
        }
        XCTAssertTrue(permitted(state, settings))
        XCTAssertFalse(permitted(state, settings, authorized: false))
        var newer = settings
        newer.revision += 1
        XCTAssertFalse(permitted(state, newer))
        let snoozed = alarmSettings(snoozeAllUntil: receivedAt.addingTimeInterval(60))
        XCTAssertFalse(permitted(state, snoozed))
        var locallySnoozed = state
        locallySnoozed.snooze(.low, until: receivedAt.addingTimeInterval(60))
        XCTAssertFalse(permitted(locallySnoozed, settings))
        _ = state.accept(id: UUID(), measuredAt: receivedAt.addingTimeInterval(1), glucose: 120,
            settings: settings, delegation: alarmDelegation(settings), watchOwnsSensor: true,
            now: receivedAt.addingTimeInterval(1))
        XCTAssertFalse(permitted(state, settings))
    }

    func testWatchMissedAlarmRestoresUnconfirmedIntentButNotAlreadyDeliveredAlarm() throws {
        var state = LibreWatchAlarmState()
        state.scheduledMissedID = "scheduled-test"
        state.scheduledMissedAt = receivedAt.addingTimeInterval(300)
        state.scheduledMissedConfirmed = false
        let restored = try JSONDecoder().decode(LibreWatchAlarmState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(restored.shouldRestoreMissingMissedNotification(at: receivedAt.addingTimeInterval(600)))
        state.scheduledMissedConfirmed = true
        XCTAssertTrue(state.shouldRestoreMissingMissedNotification(at: receivedAt))
        XCTAssertFalse(state.shouldRestoreMissingMissedNotification(at: receivedAt.addingTimeInterval(600)))
        state.scheduledMissedID = nil
        XCTAssertFalse(state.shouldRestoreMissingMissedNotification(at: receivedAt))
    }

    func testQueuedWatchAlarmPresentationRechecksAuthorityButAllowsMissingReading() {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        let readingID = UUID()
        state.lastReadingID = readingID
        state.lastReadingAt = receivedAt.addingTimeInterval(-3600)
        func permitted(_ kind: LibreWatchAlarmKind, owner: Bool = true, authorized: Bool = true,
                       notificationSessionID: String? = nil, lease: LibreWatchAlarmDelegation? = nil) -> Bool {
            state.notificationMayBePresented(kind: kind,
                notificationSessionID: notificationSessionID ?? settings.sessionID.uuidString,
                notificationReadingID: readingID,
                settings: settings, delegation: lease ?? alarmDelegation(settings), watchOwnsSensor: owner,
                notificationsAuthorized: authorized, at: receivedAt)
        }
        XCTAssertTrue(permitted(.missed))
        XCTAssertFalse(permitted(.missed, owner: false))
        XCTAssertFalse(permitted(.missed, authorized: false))
        XCTAssertFalse(permitted(.low, notificationSessionID: UUID().uuidString))
        XCTAssertFalse(permitted(.low, lease: LibreWatchAlarmDelegation(sessionID: settings.sessionID,
            sensorIdentity: settings.sensorIdentity, settingsRevision: settings.revision + 1)))
        state.lastReadingAt = receivedAt
        state.recordAutomaticThrottle(.low, readingID: readingID, until: receivedAt.addingTimeInterval(300))
        XCTAssertTrue(permitted(.low), "Automatic post-enqueue throttle must not suppress its own notification")
        state.snooze(.low, until: receivedAt.addingTimeInterval(100))
        XCTAssertFalse(permitted(.low), "A manual snooze must suppress even with an unchanged maximum expiry")
    }

    func testQueuedGlucoseAlarmDoesNotOutliveItsReadingOrManualSnoozeAfterRestart() throws {
        let settings = alarmSettings()
        var state = LibreWatchAlarmState()
        state.use(settings)
        let oldID = UUID()
        _ = state.accept(id: oldID, measuredAt: receivedAt, glucose: 38, settings: settings,
            delegation: alarmDelegation(settings), watchOwnsSensor: true, now: receivedAt)
        state.recordAutomaticThrottle(.veryLow, readingID: oldID, until: receivedAt.addingTimeInterval(300))
        func permitted(_ value: LibreWatchAlarmState) -> Bool {
            value.notificationMayBePresented(kind: .veryLow, notificationSessionID: settings.sessionID.uuidString,
                notificationReadingID: oldID, settings: settings, delegation: alarmDelegation(settings),
                watchOwnsSensor: true, notificationsAuthorized: true, at: receivedAt.addingTimeInterval(60))
        }
        let restored = try JSONDecoder().decode(LibreWatchAlarmState.self, from: JSONEncoder().encode(state))
        XCTAssertTrue(permitted(restored))
        state.snooze(.low, until: receivedAt.addingTimeInterval(600))
        let snoozed = try JSONDecoder().decode(LibreWatchAlarmState.self, from: JSONEncoder().encode(state))
        XCTAssertFalse(permitted(snoozed))
        state = restored
        _ = state.accept(id: UUID(), measuredAt: receivedAt.addingTimeInterval(60), glucose: 120,
            settings: settings, delegation: alarmDelegation(settings), watchOwnsSensor: true,
            now: receivedAt.addingTimeInterval(60))
        XCTAssertFalse(permitted(state), "A queued low from the previous reading is no longer current")
    }

    func testWatchMissedAlarmUsesPhoneMidnightBaseSchedule() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 86_400 + 2 * 60)
        let settings = alarmSettings()
        XCTAssertEqual(settings.rules.filter { $0.kind == .missed }.first?.startMinute, 0)
        var state = LibreWatchAlarmState()
        state.use(settings)
        state.lastReadingAt = now.addingTimeInterval(-4 * 60)
        state.lastReadingID = UUID()
        let next = state.nextMissedAlarm(settings: settings, delegation: alarmDelegation(settings),
            watchOwnsSensor: true, now: now, calendar: calendar)
        XCTAssertEqual(next?.date, now.addingTimeInterval(60))
        XCTAssertEqual(next?.rule.startMinute, 0)
    }

    func testWatchDelegationDoesNotSuppressNewlyEnabledPhoneAlarmWhileOffline() throws {
        let disabled = alarmSettings(enabled: false)
        let lease = LibreWatchAlarmDelegation.confirmed(for: disabled)
        XCTAssertFalse(lease.covers(.low))
        var enabled = alarmSettings()
        enabled.revision = disabled.revision + 1
        XCTAssertFalse(lease.matches(enabled))
        XCTAssertFalse(lease.covers(.low), "New phone settings do not enlarge an offline Watch delegation")
        let confirmed = LibreWatchAlarmDelegation.confirmed(for: enabled)
        XCTAssertTrue(confirmed.covers(.low))
        XCTAssertTrue(confirmed.matches(enabled))
        let restored = try JSONDecoder().decode(LibreWatchAlarmDelegation.self,
            from: JSONEncoder().encode(confirmed))
        XCTAssertTrue(restored.covers(.missed))
        let legacy = LibreWatchAlarmDelegation(sessionID: enabled.sessionID,
            sensorIdentity: enabled.sensorIdentity, settingsRevision: enabled.revision)
        XCTAssertFalse(legacy.covers(.low), "Unspecified legacy delegation must never suppress phone alarms")
        XCTAssertFalse(legacy.matches(enabled), "Unspecified legacy delegation must not enable local Watch alarms")
    }

    private func alarmSettings(enabled: Bool = true, snoozeAllUntil: Date? = nil) -> LibreWatchAlarmSettings {
        let rules = zip(LibreWatchAlarmKind.allCases, [60.0, 80, 180, 250, 5]).map { kind, value in
            LibreWatchAlarmRule(kind: kind, startMinute: 0, value: value, enabled: enabled,
                snoozeMinutes: 15, allowsSnooze: true, soundEnabled: false, vibrate: false, title: "Test")
        }
        return LibreWatchAlarmSettings(sessionID: session.id, sensorIdentity: session.redactedIdentity(), revision: 1,
            generatedAt: receivedAt, isMgDl: false, rules: rules, snoozes: [], snoozeAllUntil: snoozeAllUntil)
    }

    private func alarmDelegation(_ settings: LibreWatchAlarmSettings) -> LibreWatchAlarmDelegation {
        LibreWatchAlarmDelegation.confirmed(for: settings)
    }
}

extension LibreWatchValuePipelineTests {
    func testTakeoverSnapshotRequiresMatchingCalibrationBeforeWatchOwnership() throws {
        let snapshot = LibreWatchHandoffSnapshot(
            session: session,
            calibration: calibration(type: .fixedSlope, slope: 1, intercept: 0),
            ownership: .watch,
            revision: 31
        )
        XCTAssertTrue(snapshot.canApply(after: 30))
        XCTAssertFalse(snapshot.canApply(after: 31))
        XCTAssertFalse(snapshot.canApply(after: 32))
        XCTAssertEqual(try JSONDecoder().decode(LibreWatchHandoffSnapshot.self,
            from: JSONEncoder().encode(snapshot)), snapshot)
        XCTAssertFalse(LibreWatchHandoffSnapshot(
            session: session, calibration: nil, ownership: .watch, revision: 32
        ).isValid)
        var anotherSession = session
        anotherSession.unlockCount += 1
        let current = LibreWatchHandoffSnapshot(
            session: anotherSession, calibration: snapshot.calibration, ownership: .watch, revision: 32
        )
        XCTAssertTrue(current.isValid)
        XCTAssertEqual(current.session.unlockCount, session.unlockCount + 1)
    }

    func testPhoneReconnectsAndDelayedCounterMessageNeverRollBackUnlockCounter() {
        var prepared = session
        prepared.unlockCount = 4
        var persisted = session
        persisted.unlockCount = 7
        XCTAssertEqual(LibreWatchUnlockCounterPolicy.highest(
            incoming: 5, session: prepared, storedSession: persisted,
            activeSensorUID: session.sensorUID, activePatchInfo: session.patchInfo,
            activeCounter: 12
        ), 12)
        XCTAssertEqual(LibreWatchUnlockCounterPolicy.highest(
            incoming: 14, session: prepared, storedSession: persisted,
            activeSensorUID: session.sensorUID, activePatchInfo: session.patchInfo,
            activeCounter: 12
        ), 14)
        XCTAssertEqual(LibreWatchUnlockCounterPolicy.highest(
            incoming: 5, session: prepared, storedSession: nil,
            activeSensorUID: Data(repeating: 0, count: 8), activePatchInfo: session.patchInfo,
            activeCounter: 500
        ), 5)
    }

    func testHandoffRevisionPersistsAndRejectsDelayedOwnershipContextAfterRestart() {
        let defaults = isolatedDefaults()
        let first = LibreWatchSessionStore.nextHandoffRevision(at: receivedAt, defaults: defaults)
        let second = LibreWatchSessionStore.nextHandoffRevision(at: receivedAt.addingTimeInterval(-60), defaults: defaults)
        XCTAssertGreaterThan(second, first)
        XCTAssertEqual(LibreWatchSessionStore.loadHandoffRevision(defaults: defaults), second)
        let delayed = LibreWatchHandoffSnapshot(
            session: session, calibration: nil, ownership: .iphone, revision: first
        )
        XCTAssertFalse(delayed.canApply(after: LibreWatchSessionStore.loadHandoffRevision(defaults: defaults)))
    }

    func testWatchOutboxRetainsSubmittedPayloadUntilDurableReceiverReceipt() throws {
        let item = LibreWatchOutboxItem.reading(payload(raw: 847, previousRaw: 829, domain: .factoryNativeMGDL))
        var outbox = LibreWatchConnectivityOutbox()
        outbox.enqueue(item, now: receivedAt)
        outbox.markSubmitted(id: item.id, at: receivedAt)
        XCTAssertEqual(outbox.items.map(\.id), [item.id])
        XCTAssertNil(outbox.nextEligible(at: receivedAt.addingTimeInterval(59)))
        let restored = try JSONDecoder().decode(LibreWatchConnectivityOutbox.self,
            from: JSONEncoder().encode(outbox))
        XCTAssertEqual(restored.nextEligible(at: receivedAt.addingTimeInterval(60))?.id, item.id)
        XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: true, outcome: nil))
        XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: false, outcome: .historyNotInserted))
        XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: false, outcome: .collectorUnavailable))
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: true, outcome: .liveAccepted, durableReceipt: true))
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: true, outcome: .historicalInserted, durableReceipt: true))
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: true, outcome: .duplicate, durableReceipt: true))
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: false, outcome: .wrongCalibration))
        outbox.remove(id: item.id)
        XCTAssertNil(outbox.nextEligible(at: receivedAt.addingTimeInterval(61)))
    }

    func testLegacyOutboxDecodesWithoutSubmissionMetadataAndKeepsStableIDs() throws {
        let item = LibreWatchOutboxItem.reading(payload(raw: 847, previousRaw: 829, domain: .factoryNativeMGDL))
        let legacy = try JSONSerialization.data(withJSONObject: [
            "items": try JSONSerialization.jsonObject(with: JSONEncoder().encode([item]))
        ])
        let outbox = try JSONDecoder().decode(LibreWatchConnectivityOutbox.self, from: legacy)
        XCTAssertEqual(outbox.nextEligible(at: receivedAt)?.id, item.id)
        XCTAssertNil(outbox.lastSubmittedAt)
        XCTAssertNil(outbox.capacityDroppedReadings)
        XCTAssertNil(outbox.capacityDroppedDiagnostics)
        XCTAssertNil(outbox.capacityDroppedCommands)
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldRetryReadingAsQueued(after: .outOfOrder))
        XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.isTerminal(.outOfOrder))
    }

    func testDiagnosticJournalSeparatesConfirmedRotationFromUnacknowledgedLoss() throws {
        var journal = LibreWatchDiagnosticJournal()
        for index in 0 ..< 160 {
            let date = receivedAt.addingTimeInterval(Double(index))
            let event = LibreWatchDiagnosticEvent(kind: .coreBluetoothCallback,
                watchTimestamp: date, trigger: "didConnect", sessionID: session.id, appBuild: "4252")
            _ = journal.append(event, at: date)
            journal.markHandedToWatchConnectivity(eventID: event.eventID, at: date)
            journal.markAcknowledgedByPhone(eventID: event.eventID, at: date.addingTimeInterval(0.5))
        }
        XCTAssertGreaterThan(journal.droppedCount, 0)
        XCTAssertEqual(journal.unacknowledgedDropCount ?? 0, 0)
        for index in 160 ..< 320 {
            _ = journal.append(LibreWatchDiagnosticEvent(kind: .disconnected,
                sessionID: UUID(), appBuild: "4252"), at: receivedAt.addingTimeInterval(Double(index)))
        }
        XCTAssertGreaterThan(journal.unacknowledgedDropCount ?? 0, 0)
        let restored = try JSONDecoder().decode(LibreWatchDiagnosticJournal.self,
            from: JSONEncoder().encode(journal))
        XCTAssertEqual(restored.unacknowledgedDropCount, journal.unacknowledgedDropCount)
        XCTAssertFalse(restored.pendingEvents().isEmpty)
        XCTAssertTrue(restored.entries.allSatisfy { $0.event.appBuild == "4252" })
    }

    func testSessionChangeKeepsPendingDiagnosticsButNeverOldSensorReadings() {
        let diagnostic = LibreWatchOutboxItem.command(.reportDiagnostic, sessionID: session.id,
            diagnosticEvent: Data("{}".utf8), createdAt: receivedAt)
        let reading = LibreWatchOutboxItem.reading(payload(raw: 847, previousRaw: 829, domain: .factoryNativeMGDL))
        var outbox = LibreWatchConnectivityOutbox()
        outbox.enqueue(diagnostic, now: receivedAt)
        outbox.enqueue(reading, now: receivedAt)
        outbox.retain(sessionID: UUID())
        XCTAssertEqual(outbox.items.map(\.id), [diagnostic.id])
    }

    func testOldPhoneSuccessDoesNotAcknowledgeReadingOrDiagnosticStorage() throws {
        let reading = LibreWatchOutboxItem.reading(payload(raw: 847, previousRaw: 829, domain: .factoryNativeMGDL))
        let event = LibreWatchDiagnosticEvent(kind: .recoveryStarted, watchTimestamp: receivedAt, sessionID: session.id)
        let diagnostic = LibreWatchOutboxItem.command(.reportDiagnostic, sessionID: session.id,
            diagnosticEvent: try JSONEncoder().encode(event), id: try XCTUnwrap(event.eventID), createdAt: receivedAt)
        let counter = LibreWatchOutboxItem.command(.updateUnlockCounter, sessionID: session.id,
            unlockCounter: 42, createdAt: receivedAt)
        var outbox = LibreWatchConnectivityOutbox()
        for item in [reading, diagnostic] {
            outbox.enqueue(item, now: receivedAt)
            let oldOutcome: LibreWatchDeliveryOutcome? = item.kind == .reading ? .liveAccepted : nil
            XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: true, outcome: oldOutcome))
            XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item, success: true, outcome: oldOutcome, durableReceipt: false))
            outbox.markSubmitted(id: item.id, at: receivedAt)
        }
        let restored = try JSONDecoder().decode(LibreWatchConnectivityOutbox.self, from: JSONEncoder().encode(outbox))
        XCTAssertEqual(Set(restored.items.map(\.id)), Set([reading.id, diagnostic.id]))
        XCTAssertNotNil(restored.nextEligible(at: receivedAt.addingTimeInterval(60)))
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(reading, success: true, outcome: .liveAccepted, durableReceipt: true))
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(diagnostic, success: true, outcome: nil, durableReceipt: true))
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(counter, success: true, outcome: nil))
        XCTAssertFalse(LibreWatchConnectivityDeliveryPolicy.shouldFinish(diagnostic, success: false, outcome: nil))
        XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(diagnostic, success: false, outcome: .invalidPayload))
    }
}

extension LibreWatchValuePipelineTests {
    func testObservedDisconnectedClearsStaleReceptionWithoutContinuousExecution() {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        let generation = timing.generation

        XCTAssertTrue(timing.observeLink(
            connected: false, connecting: false, hasReceptionState: true,
            at: receivedAt.addingTimeInterval(93), applicationIsActive: false,
            executionIsAvailable: false
        ))
        XCTAssertNotEqual(timing.generation, generation)
        XCTAssertNil(timing.phase)
        XCTAssertNil(timing.deadline)
    }

    func testCancellationDoesNotGrantRecoveryForPhoneOwnership() {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        timing.beginCancellation(at: receivedAt.addingTimeInterval(93))

        XCTAssertFalse(timing.observeLink(
            connected: false, connecting: false, hasReceptionState: true,
            at: receivedAt.addingTimeInterval(93.1), applicationIsActive: false,
            executionIsAvailable: false
        ))
        XCTAssertEqual(timing.phase, .cancelling)
        XCTAssertEqual(LibreWatchLifecyclePolicy.disconnectRecoveryAction(
            isDeliberate: true, systemIsReconnecting: false, ownership: .iphone
        ), .finishDeliberateDisconnect)
        for ownership in [LibreWatchOwnership.iphone, .releasingToPhone, .releasingToWatch, .recovery] {
            XCTAssertFalse(LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(ownership: ownership))
            XCTAssertEqual(LibreWatchLifecyclePolicy.disconnectRecoveryAction(
                isDeliberate: false, systemIsReconnecting: false, ownership: ownership
            ), .noAdditionalWork)
        }
    }
}

extension LibreWatchValuePipelineTests {
    private enum OutboxFileTestError: Error { case injectedWriteFailure }

    private func submissionCache(_ reading: LibreWatchDirectReadingPayload,
                                 confirmed: Bool? = nil) -> LibreWatchPersistedDirectReading {
        LibreWatchPersistedDirectReading(sessionID: session.id, sensorIdentity: session.redactedIdentity(),
            sourceReading: reading, displayedGlucoseMGDL: 100, displayedTrendMGDLPerMinute: nil,
            calibrationRevision: reading.calibrationRevision, queuePersistenceConfirmed: confirmed)
    }

    func testSubmissionCommitsRealOutboxBeforePublishingAndAllowsDiagnosticReads() throws {
        let fixture = try outboxFileFixture()
        let store = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        var outbox = try store.load(at: receivedAt)
        var acceptance = LibreWatchReadingAcceptancePolicy()
        var published = 0
        for index in 0..<3 {
            let now = receivedAt.addingTimeInterval(Double(index) * 60)
            let reading = try XCTUnwrap(fileOutboxReading(index, at: now).reading)
            XCTAssertTrue(LibreWatchReadingSubmission.receive(reading, sessionID: session.id,
                acceptance: acceptance, outbox: outbox, at: now,
                persist: { pending in
                    do { try store.prepareForDelivery(&pending, sessionID: self.session.id, at: now); return true }
                    catch { XCTFail("Unexpected persistence failure: \(error)"); return false }
                }, publishLocally: { commit in
                    // Use the same value-copy boundary as WatchStateModel, including reads
                    // during publication: no inout property may remain exclusively borrowed.
                    outbox = commit.outbox
                    acceptance = commit.acceptance
                    XCTAssertEqual(commit.persistence, .durable)
                    XCTAssertTrue(acceptance.acceptedPayloadIDs.contains(reading.id))
                    let restarted = try? LibreWatchOutboxFileStore(fileURL: fixture.fileURL,
                        defaults: fixture.defaults).load(at: now)
                    XCTAssertEqual(restarted, outbox, "Publication must follow the real file commit")
                    LibreWatchSessionStore.saveReading(self.submissionCache(reading, confirmed: true), defaults: fixture.defaults)
                    published += 1
                }))
        }
        XCTAssertEqual(published, 3)
        XCTAssertEqual(outbox.items.count, 3)
        XCTAssertEqual(LibreWatchSessionStore.loadReading(defaults: fixture.defaults)?.queuePersistenceConfirmed, true)
    }

    func testSubmissionRestartBetweenQueueAndDisplayCacheRecoversNewestReading() throws {
        let fixture = try outboxFileFixture()
        let store = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        let old = try XCTUnwrap(fileOutboxReading(0, at: receivedAt).reading)
        LibreWatchSessionStore.saveReading(submissionCache(old, confirmed: true), defaults: fixture.defaults)
        let now = receivedAt.addingTimeInterval(60)
        let newest = try XCTUnwrap(fileOutboxReading(1, at: now).reading)
        let outbox = try store.load(at: now)
        XCTAssertTrue(LibreWatchReadingSubmission.receive(newest, sessionID: session.id,
            acceptance: LibreWatchReadingAcceptancePolicy(), outbox: outbox, at: now,
            persist: { pending in
                do { try store.prepareForDelivery(&pending, sessionID: self.session.id, at: now); return true }
                catch { XCTFail("Unexpected persistence failure: \(error)"); return false }
            }, publishLocally: { _ in
                // Stop at the production publication boundary; deliberately no cache write.
            }))
        let restarted = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        let restored = try XCTUnwrap(LibreWatchReadingSubmission.restore(
            cached: LibreWatchSessionStore.loadReading(defaults: fixture.defaults),
            outbox: try restarted.load(at: now), session: session,
            calibration: calibration(type: .fixedSlope, slope: 1, intercept: 0), at: now,
            persist: { pending in (try? restarted.prepareForDelivery(&pending, sessionID: self.session.id, at: now)) != nil }))
        XCTAssertEqual(restored.reading, newest)
        XCTAssertEqual(restored.persistence, .durable)
        XCTAssertEqual(restored.outbox.items.map(\.id), [newest.id])
    }

    func testSubmissionRepairsLegacyAndFailedWriteCacheOnceWithoutChangingID() throws {
        for confirmed: Bool? in [nil, false] {
            let fixture = try outboxFileFixture()
            let reading = try XCTUnwrap(fileOutboxReading(0, at: receivedAt).reading)
            let original = submissionCache(reading, confirmed: confirmed)
            let encoded = try JSONEncoder().encode(original)
            if confirmed == nil {
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
                XCTAssertNil(json["queuePersistenceConfirmed"], "Old v2 cache needs no migration")
            }
            let cached = try JSONDecoder().decode(LibreWatchPersistedDirectReading.self, from: encoded)
            for _ in 0..<2 {
                let restarted = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
                let restored = try XCTUnwrap(LibreWatchReadingSubmission.restore(cached: cached,
                    outbox: try restarted.load(at: receivedAt), session: session,
                    calibration: calibration(type: .fixedSlope, slope: 1, intercept: 0), at: receivedAt,
                    persist: { pending in
                        (try? restarted.prepareForDelivery(&pending, sessionID: self.session.id, at: self.receivedAt)) != nil
                    }))
                XCTAssertEqual(restored.reading, reading)
                XCTAssertEqual(restored.outbox.items.map(\.id), [reading.id])
                XCTAssertEqual(restored.persistence, .durable)
            }
        }
    }

    func testSubmissionConfirmedAndAcknowledgedCacheIsNotRequeuedOnRestart() throws {
        let reading = try XCTUnwrap(fileOutboxReading(0, at: receivedAt).reading)
        let restored = try XCTUnwrap(LibreWatchReadingSubmission.restore(
            cached: submissionCache(reading, confirmed: true), outbox: LibreWatchConnectivityOutbox(),
            session: session, calibration: calibration(type: .fixedSlope, slope: 1, intercept: 0),
            at: receivedAt, persist: { _ in true }))
        XCTAssertEqual(restored.reading, reading)
        XCTAssertTrue(restored.outbox.items.isEmpty)
        XCTAssertEqual(restored.persistence, .durable)
    }

    func testSubmissionFailedWriteKeepsRAMAndClinicalPublicationThenRetries() throws {
        let fixture = try outboxFileFixture()
        var failWrite = false
        let store = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults) { data, url in
            if failWrite { throw OutboxFileTestError.injectedWriteFailure }
            try data.write(to: url, options: .atomic)
        }
        var outbox = try store.load(at: receivedAt)
        outbox.enqueue(fileOutboxReading(0, at: receivedAt), now: receivedAt)
        try store.save(outbox)
        let before = try Data(contentsOf: fixture.fileURL)
        failWrite = true
        let now = receivedAt.addingTimeInterval(60)
        let reading = try XCTUnwrap(fileOutboxReading(1, at: now).reading)
        var published = 0
        XCTAssertTrue(LibreWatchReadingSubmission.receive(reading, sessionID: session.id,
            acceptance: LibreWatchReadingAcceptancePolicy(), outbox: outbox, at: now,
            persist: { pending in (try? store.prepareForDelivery(&pending, sessionID: self.session.id, at: now)) != nil },
            publishLocally: { commit in
                outbox = commit.outbox
                XCTAssertEqual(commit.persistence, .pendingWrite)
                XCTAssertNotNil(commit.persistence.issue)
                LibreWatchSessionStore.saveReading(self.submissionCache(reading, confirmed: false), defaults: fixture.defaults)
                published += 1 // Local clinical path is not disabled by phone/disk availability.
            }))
        XCTAssertEqual(published, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), before)
        XCTAssertEqual(outbox.items.count, 2)
        XCTAssertEqual(LibreWatchSessionStore.loadReading(defaults: fixture.defaults)?.queuePersistenceConfirmed, false)
        failWrite = false
        try store.prepareForDelivery(&outbox, sessionID: session.id, at: now)
        XCTAssertEqual(try LibreWatchOutboxFileStore(fileURL: fixture.fileURL,
            defaults: fixture.defaults).load(at: now), outbox)
        XCTAssertEqual(published, 1, "Persistence retry must not publish or alarm again")
    }

    func testSubmissionRestartRepairsLatestCachedReadingAfterQueueWriteFailure() throws {
        let fixture = try outboxFileFixture()
        let reading = try XCTUnwrap(fileOutboxReading(0, at: receivedAt).reading)
        let failed = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults) { _, _ in
            throw OutboxFileTestError.injectedWriteFailure
        }
        let empty = try failed.load(at: receivedAt)
        XCTAssertTrue(LibreWatchReadingSubmission.receive(reading, sessionID: session.id,
            acceptance: LibreWatchReadingAcceptancePolicy(), outbox: empty, at: receivedAt,
            persist: { pending in (try? failed.prepareForDelivery(&pending, sessionID: self.session.id)) != nil },
            publishLocally: { commit in
                LibreWatchSessionStore.saveReading(self.submissionCache(reading,
                    confirmed: commit.persistence == .durable), defaults: fixture.defaults)
            }))
        let restarted = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        let restored = try XCTUnwrap(LibreWatchReadingSubmission.restore(
            cached: LibreWatchSessionStore.loadReading(defaults: fixture.defaults), outbox: try restarted.load(at: receivedAt),
            session: session, calibration: calibration(type: .fixedSlope, slope: 1, intercept: 0), at: receivedAt,
            persist: { pending in (try? restarted.prepareForDelivery(&pending, sessionID: self.session.id)) != nil }))
        XCTAssertEqual(restored.outbox.items.map(\.id), [reading.id])
        XCTAssertEqual(restored.persistence, .durable)
    }

    func testSubmissionDuplicateOutOfOrderAndWrongSessionDoNotPersistOrPublish() throws {
        let reading = try XCTUnwrap(fileOutboxReading(1, at: receivedAt).reading)
        var acceptance = LibreWatchReadingAcceptancePolicy()
        acceptance.reset(for: session.id, seeding: reading)
        let older = try XCTUnwrap(fileOutboxReading(0, at: receivedAt.addingTimeInterval(-60)).reading)
        for (candidate, expectedSession) in [(reading, session.id), (older, session.id), (reading, UUID())] {
            XCTAssertFalse(LibreWatchReadingSubmission.receive(candidate, sessionID: expectedSession,
                acceptance: acceptance, outbox: LibreWatchConnectivityOutbox(), at: receivedAt,
                persist: { _ in XCTFail("Rejected reading must not write"); return true },
                publishLocally: { _ in XCTFail("Rejected reading must not publish/alert") }))
        }
    }

    func testSubmissionRestorePreservesSessionCalibrationAndAgeBounds() throws {
        let reading = try XCTUnwrap(fileOutboxReading(0, at: receivedAt).reading)
        let cached = submissionCache(reading)
        var queue = LibreWatchConnectivityOutbox()
        queue.enqueue(.reading(reading), now: receivedAt)
        let newerCalibration = calibration(type: .fixedSlope, slope: 1, intercept: 0, revision: 11)
        let wrongSession = LibreWatchDirectSession(id: UUID(), createdAt: session.createdAt,
            sensorUID: session.sensorUID, patchInfo: session.patchInfo, sensorSerialNumber: session.sensorSerialNumber,
            sensorTypeRawValue: session.sensorTypeRawValue, expectedPeripheralName: session.expectedPeripheralName,
            unlockCode: session.unlockCode, unlockCount: session.unlockCount, algorithmParameters: session.algorithmParameters)
        XCTAssertNil(LibreWatchReadingSubmission.restore(cached: cached, outbox: queue, session: wrongSession,
            calibration: newerCalibration, at: receivedAt, persist: { _ in XCTFail("Wrong session"); return true }))
        // Display recalculation is still allowed; repair must not insert across calibration revisions.
        let recalibrated = try XCTUnwrap(LibreWatchReadingSubmission.restore(cached: cached,
            outbox: LibreWatchConnectivityOutbox(), session: session, calibration: newerCalibration,
            at: receivedAt, persist: { _ in true }))
        XCTAssertTrue(recalibrated.outbox.items.isEmpty)
        let expired = try XCTUnwrap(LibreWatchReadingSubmission.restore(cached: cached, outbox: queue, session: session,
            calibration: calibration(type: .fixedSlope, slope: 1, intercept: 0),
            at: receivedAt.addingTimeInterval(LibreWatchConnectivityOutbox.maximumAge + 1), persist: { _ in true }))
        XCTAssertTrue(expired.outbox.items.isEmpty)
        XCTAssertEqual(expired.reading.receivedAt, reading.receivedAt, "Do not freshen stale display timestamps")
        XCTAssertEqual(expired.persistence, .notRetained)
    }

    func testSubmissionRestoreSelectsNewerFileReadingAfterInitialReadFailure() throws {
        let fixture = try outboxFileFixture()
        let old = try XCTUnwrap(fileOutboxReading(0, at: receivedAt).reading)
        let now = receivedAt.addingTimeInterval(60)
        let newer = try XCTUnwrap(fileOutboxReading(1, at: now).reading)
        let firstStore = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        var onDisk = try firstStore.load(at: now)
        XCTAssertTrue(onDisk.enqueue(.reading(newer), now: now))
        try firstStore.save(onDisk)

        var readFails = true
        let recoveringStore = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults,
            reader: { url in
                if readFails { throw CocoaError(.fileReadNoPermission) }
                return try Data(contentsOf: url)
            })
        XCTAssertThrowsError(try recoveringStore.load(at: now))
        readFails = false
        let restored = try XCTUnwrap(LibreWatchReadingSubmission.restore(
            cached: submissionCache(old, confirmed: true),
            outbox: LibreWatchConnectivityOutbox(),
            session: session,
            calibration: calibration(type: .fixedSlope, slope: 1, intercept: 0),
            at: now,
            persist: { pending in
                (try? recoveringStore.prepareForDelivery(&pending, sessionID: self.session.id, at: now)) != nil
            }))
        XCTAssertEqual(restored.reading.id, newer.id)
        XCTAssertEqual(restored.outbox.items.map(\.id), [newer.id])
        XCTAssertEqual(restored.persistence, .durable)
        XCTAssertEqual(try LibreWatchOutboxFileStore(fileURL: fixture.fileURL,
            defaults: fixture.defaults).load(at: now), restored.outbox)
    }

    private func outboxFileFixture() throws -> (fileURL: URL, defaults: UserDefaults) {
        let identifier = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibreWatchOutboxFileTests-\(identifier)", isDirectory: true)
        let suiteName = "LibreWatchOutboxFileTests.\(identifier)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        return (directory.appendingPathComponent("queue/outbox-v2.json"), defaults)
    }

    private func fileOutboxReading(_ index: Int, at date: Date) -> LibreWatchOutboxItem {
        .reading(payload(id: outboxFixtureID(index), raw: 847, previousRaw: 829,
            domain: .xDripRawGlucose, sensorTime: UInt16(1_000 + index), at: date))
    }

    func testFileOutboxRestartsAfterEveryReadingAndDurableAcknowledgement() throws {
        let fixture = try outboxFileFixture()
        var expected = LibreWatchConnectivityOutbox()
        for index in 0..<12 {
            let now = receivedAt.addingTimeInterval(Double(index) * 60)
            let store = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
            var restored = try store.load(at: now)
            XCTAssertEqual(restored, expected)
            let item = fileOutboxReading(index, at: now)
            XCTAssertTrue(restored.enqueue(item, now: now))
            restored.markSubmitted(id: item.id, at: now)
            try store.save(restored)
            expected = restored
            XCTAssertEqual(try LibreWatchOutboxFileStore(fileURL: fixture.fileURL,
                defaults: fixture.defaults).load(at: now), expected,
                "Every reading is durable before another frame or batching interval")
        }

        let now = receivedAt.addingTimeInterval(12 * 60)
        for id in expected.items.map(\.id) {
            let store = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
            var restored = try store.load(at: now)
            let item = try XCTUnwrap(restored.items.first { $0.id == id })
            XCTAssertTrue(LibreWatchConnectivityDeliveryPolicy.shouldFinish(item,
                success: true, outcome: .historicalInserted, durableReceipt: true))
            restored.remove(id: id)
            try store.save(restored)
            expected = restored
            let restarted = try LibreWatchOutboxFileStore(fileURL: fixture.fileURL,
                defaults: fixture.defaults).load(at: now)
            XCTAssertEqual(restarted, expected)
            XCTAssertNil(restarted.lastSubmittedAt?[id])
        }
        XCTAssertTrue(expected.items.isEmpty)
        XCTAssertNil(expected.didPrioritizeLatestReading)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path),
            "An acknowledged empty queue remains an authoritative durable snapshot")
    }

    func testFileOutboxMigratesLegacyOnlyAfterFirstSuccessfulFileCommit() throws {
        let fixture = try outboxFileFixture()
        var legacy = LibreWatchConnectivityOutbox()
        let item = fileOutboxReading(0, at: receivedAt)
        legacy.enqueue(item, now: receivedAt)
        legacy.markSubmitted(id: item.id, at: receivedAt)
        let legacyData = try JSONEncoder().encode(legacy)
        fixture.defaults.set(legacyData, forKey: LibreWatchMessageKey.persistedOutbox)
        var writeCount = 0
        let store = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults) { data, url in
            writeCount += 1
            XCTAssertEqual(fixture.defaults.data(forKey: LibreWatchMessageKey.persistedOutbox), legacyData,
                "The migration source survives until the file commit succeeds")
            try data.write(to: url, options: .atomic)
        }
        let loaded = try store.load(at: receivedAt.addingTimeInterval(10))
        XCTAssertEqual(loaded, legacy)
        XCTAssertEqual(writeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        try store.save(loaded)
        XCTAssertEqual(writeCount, 1)
        XCTAssertNil(fixture.defaults.data(forKey: LibreWatchMessageKey.persistedOutbox))
        try store.save(loaded)
        XCTAssertEqual(writeCount, 1, "An identical successful snapshot needs no second write")
        let restarted = try LibreWatchOutboxFileStore(fileURL: fixture.fileURL,
            defaults: fixture.defaults).load(at: receivedAt.addingTimeInterval(10))
        XCTAssertEqual(restarted, legacy)
        XCTAssertNil(restarted.nextEligible(at: receivedAt.addingTimeInterval(59)))
        XCTAssertEqual(restarted.nextEligible(at: receivedAt.addingTimeInterval(60))?.id, item.id)
    }

    func testFileOutboxMigrationWriteFailureRetainsLegacyAndRetriesIdenticalSnapshot() throws {
        let fixture = try outboxFileFixture()
        var legacy = LibreWatchConnectivityOutbox()
        legacy.enqueue(fileOutboxReading(0, at: receivedAt), now: receivedAt)
        let legacyData = try JSONEncoder().encode(legacy)
        fixture.defaults.set(legacyData, forKey: LibreWatchMessageKey.persistedOutbox)
        var shouldFail = true
        var writeCount = 0
        let store = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults) { data, url in
            writeCount += 1
            if shouldFail { throw OutboxFileTestError.injectedWriteFailure }
            try data.write(to: url, options: .atomic)
        }
        let loaded = try store.load(at: receivedAt)
        XCTAssertThrowsError(try store.save(loaded))
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(fixture.defaults.data(forKey: LibreWatchMessageKey.persistedOutbox), legacyData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        XCTAssertEqual(try LibreWatchOutboxFileStore(fileURL: fixture.fileURL,
            defaults: fixture.defaults).load(at: receivedAt), legacy)

        shouldFail = false
        try store.save(loaded)
        XCTAssertEqual(writeCount, 2, "The failed snapshot was never cached as durable")
        XCTAssertNil(fixture.defaults.data(forKey: LibreWatchMessageKey.persistedOutbox))
        XCTAssertEqual(try LibreWatchOutboxFileStore(fileURL: fixture.fileURL,
            defaults: fixture.defaults).load(at: receivedAt), legacy)
    }

    func testDiagnosticCallbackBatchSurvivesOutboxWriteFailureAndReplaysOnceInOrder() throws {
        let fixture = try outboxFileFixture()
        let firstID = UUID()
        let secondID = UUID()
        let events = [
            LibreWatchDiagnosticEvent(
                eventID: firstID, kind: .coreBluetoothCallback,
                watchTimestamp: receivedAt, trigger: "didConnect"
            ),
            LibreWatchDiagnosticEvent(
                eventID: secondID, kind: .bluetoothAction,
                watchTimestamp: receivedAt, trigger: "freshConnectionSetup",
                bluetoothAction: "discoverServices"
            )
        ]
        var journal = LibreWatchDiagnosticJournal()
        var outbox = LibreWatchConnectivityOutbox()
        XCTAssertEqual(LibreWatchDiagnosticBatch.stage(
            events,
            fallbackSessionID: session.id,
            journal: &journal,
            outbox: &outbox,
            at: receivedAt
        ), [firstID, secondID])
        XCTAssertEqual(journal.entries.compactMap { $0.event.eventID }, [firstID, secondID])
        XCTAssertEqual(outbox.items.map(\.id), [firstID, secondID])
        XCTAssertEqual(LibreWatchDiagnosticBatch.stage(
            events,
            fallbackSessionID: session.id,
            journal: &journal,
            outbox: &outbox,
            at: receivedAt
        ), [])
        XCTAssertEqual(outbox.items.map(\.id), [firstID, secondID])

        LibreWatchSessionStore.saveDiagnosticJournal(
            journal, defaults: fixture.defaults, at: receivedAt
        )
        let failingStore = LibreWatchOutboxFileStore(
            fileURL: fixture.fileURL,
            defaults: fixture.defaults,
            writer: { _, _ in throw OutboxFileTestError.injectedWriteFailure }
        )
        _ = try failingStore.load(at: receivedAt)
        XCTAssertThrowsError(try failingStore.save(outbox))

        let restoredJournal = LibreWatchSessionStore.loadDiagnosticJournal(
            defaults: fixture.defaults, at: receivedAt
        )
        var restartedOutbox = LibreWatchConnectivityOutbox()
        XCTAssertEqual(LibreWatchDiagnosticBatch.replayPending(
            journal: restoredJournal,
            outbox: &restartedOutbox,
            at: receivedAt.addingTimeInterval(1)
        ), [firstID, secondID])
        XCTAssertEqual(restartedOutbox.items.map(\.id), [firstID, secondID])
        XCTAssertEqual(LibreWatchDiagnosticBatch.replayPending(
            journal: restoredJournal,
            outbox: &restartedOutbox,
            at: receivedAt.addingTimeInterval(1)
        ), [])
        XCTAssertEqual(restartedOutbox.items.map(\.id), [firstID, secondID])
    }

    func testFileOutboxFailedReplacementPreservesPreviousFileAndDoesNotAdvanceCache() throws {
        let fixture = try outboxFileFixture()
        var shouldFail = false
        var writeCount = 0
        let store = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults) { data, url in
            writeCount += 1
            if shouldFail { throw OutboxFileTestError.injectedWriteFailure }
            try data.write(to: url, options: .atomic)
        }
        var outbox = try store.load(at: receivedAt)
        outbox.enqueue(fileOutboxReading(0, at: receivedAt), now: receivedAt)
        try store.save(outbox)
        let previousFile = try Data(contentsOf: fixture.fileURL)
        let previousOutbox = outbox
        try store.save(outbox)
        XCTAssertEqual(writeCount, 1)

        outbox.enqueue(fileOutboxReading(1, at: receivedAt.addingTimeInterval(60)),
            now: receivedAt.addingTimeInterval(60))
        shouldFail = true
        XCTAssertThrowsError(try store.save(outbox))
        XCTAssertEqual(writeCount, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), previousFile)
        XCTAssertEqual(try LibreWatchOutboxFileStore(fileURL: fixture.fileURL,
            defaults: fixture.defaults).load(at: receivedAt.addingTimeInterval(60)), previousOutbox)
        XCTAssertEqual(outbox.items.count, 2, "The caller retains the new reading for a persistence retry")

        shouldFail = false
        try store.save(outbox)
        try store.save(outbox)
        XCTAssertEqual(writeCount, 3)
        XCTAssertEqual(try LibreWatchOutboxFileStore(fileURL: fixture.fileURL,
            defaults: fixture.defaults).load(at: receivedAt.addingTimeInterval(60)), outbox)
    }

    func testFileOutboxClearWritesEmptyTombstoneThatWinsOverStaleLegacyData() throws {
        let fixture = try outboxFileFixture()
        let store = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        var outbox = try store.load(at: receivedAt)
        outbox.enqueue(fileOutboxReading(0, at: receivedAt), now: receivedAt)
        try store.save(outbox)
        let staleLegacy = try JSONEncoder().encode(outbox)
        try store.clear()
        // Model termination after the atomic empty commit but before preferences removal.
        fixture.defaults.set(staleLegacy, forKey: LibreWatchMessageKey.persistedOutbox)
        let restarted = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        let empty = try restarted.load(at: receivedAt)
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        try restarted.save(empty)
        XCTAssertNil(fixture.defaults.data(forKey: LibreWatchMessageKey.persistedOutbox))
        XCTAssertTrue(try JSONDecoder().decode(LibreWatchConnectivityOutbox.self,
            from: Data(contentsOf: fixture.fileURL)).items.isEmpty)
    }

    func testFileOutboxCorruptPrimaryCannotFallBackToLegacyOrAuthorizeOverwrite() throws {
        let fixture = try outboxFileFixture()
        try FileManager.default.createDirectory(at: fixture.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let corrupt = Data("not an outbox snapshot".utf8)
        try corrupt.write(to: fixture.fileURL, options: .atomic)
        var legacy = LibreWatchConnectivityOutbox()
        legacy.enqueue(fileOutboxReading(0, at: receivedAt), now: receivedAt)
        let legacyData = try JSONEncoder().encode(legacy)
        fixture.defaults.set(legacyData, forKey: LibreWatchMessageKey.persistedOutbox)
        var writeCount = 0
        let store = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults) { _, _ in
            writeCount += 1
        }
        XCTAssertThrowsError(try store.load(at: receivedAt))
        XCTAssertThrowsError(try store.save(LibreWatchConnectivityOutbox()))
        XCTAssertThrowsError(try store.clear())
        XCTAssertEqual(writeCount, 0)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), corrupt)
        XCTAssertEqual(fixture.defaults.data(forKey: LibreWatchMessageKey.persistedOutbox), legacyData)
    }

    func testFileOutboxPrunedLoadMustCommitBeforeItsChangedSnapshotCanBeCached() throws {
        let fixture = try outboxFileFixture()
        var original = LibreWatchConnectivityOutbox()
        original.enqueue(fileOutboxReading(0, at: receivedAt), now: receivedAt)
        original.enqueue(fileOutboxReading(1, at: receivedAt.addingTimeInterval(60)),
            now: receivedAt.addingTimeInterval(60))
        let initialStore = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        _ = try initialStore.load(at: receivedAt)
        try initialStore.save(original)
        var writeCount = 0
        let store = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults) { data, url in
            writeCount += 1
            try data.write(to: url, options: .atomic)
        }
        let now = receivedAt.addingTimeInterval(LibreWatchConnectivityOutbox.maximumAge + 0.001)
        let pruned = try store.load(at: now)
        XCTAssertEqual(pruned.items.map(\.id), [outboxFixtureID(1)])
        XCTAssertEqual(try JSONDecoder().decode(LibreWatchConnectivityOutbox.self,
            from: Data(contentsOf: fixture.fileURL)), original)
        try store.save(pruned)
        try store.save(pruned)
        XCTAssertEqual(writeCount, 1)
        XCTAssertEqual(try LibreWatchOutboxFileStore(fileURL: fixture.fileURL,
            defaults: fixture.defaults).load(at: now), pruned)
    }

    func testFileOutboxRetriesInitialReadFailureWithoutLosingNewRAMReadings() throws {
        let fixture = try outboxFileFixture()
        let firstStore = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        var old = try firstStore.load(at: receivedAt)
        old.enqueue(fileOutboxReading(0, at: receivedAt), now: receivedAt)
        old.markSubmitted(id: outboxFixtureID(0), at: receivedAt)
        try firstStore.save(old)
        let previousFile = try Data(contentsOf: fixture.fileURL)
        var readFails = true
        let store = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults,
            reader: { url in
                if readFails { throw CocoaError(.fileReadNoPermission) }
                return try Data(contentsOf: url)
            })
        XCTAssertThrowsError(try store.load(at: receivedAt))
        var pending = LibreWatchConnectivityOutbox()
        pending.enqueue(fileOutboxReading(1, at: receivedAt.addingTimeInterval(1)),
            now: receivedAt.addingTimeInterval(1))
        // A late replay of an existing ID must not reset that payload's retry backoff.
        pending.enqueue(fileOutboxReading(0, at: receivedAt), now: receivedAt.addingTimeInterval(1))
        XCTAssertThrowsError(try store.prepareForDelivery(&pending, sessionID: session.id,
            at: receivedAt.addingTimeInterval(2)))
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), previousFile)
        XCTAssertEqual(pending.items.count, 2)
        readFails = false
        try store.prepareForDelivery(&pending, sessionID: session.id,
            at: receivedAt.addingTimeInterval(3))
        XCTAssertEqual(pending.items.map(\.id), [outboxFixtureID(0), outboxFixtureID(1)])
        XCTAssertEqual(pending.lastSubmittedAt?[outboxFixtureID(0)], receivedAt)
        XCTAssertEqual(pending.didPrioritizeLatestReading, true)
        XCTAssertEqual(try LibreWatchOutboxFileStore(fileURL: fixture.fileURL,
            defaults: fixture.defaults).load(at: receivedAt.addingTimeInterval(3)), pending)
    }

    func testFileOutboxReadRecoveryMergesLatestSubmissionBeforePersistingRetryBackoff() throws {
        let cases: [(stored: TimeInterval?, pending: TimeInterval)] = [
            (nil, 20), (10, 20), (20, 10), (20, 20)
        ]
        for offsets in cases {
            let fixture = try outboxFileFixture()
            let firstStore = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
            var stored = try firstStore.load(at: receivedAt)
            let item = fileOutboxReading(0, at: receivedAt)
            stored.enqueue(item, now: receivedAt)
            if let offset = offsets.stored {
                stored.markSubmitted(id: item.id, at: receivedAt.addingTimeInterval(offset))
            }
            try firstStore.save(stored)

            var readFails = true
            let store = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults,
                reader: { url in
                    if readFails { throw CocoaError(.fileReadNoPermission) }
                    return try Data(contentsOf: url)
                })
            XCTAssertThrowsError(try store.load(at: receivedAt.addingTimeInterval(30)))
            var pending = LibreWatchConnectivityOutbox()
            pending.enqueue(item, now: receivedAt)
            pending.markSubmitted(id: item.id, at: receivedAt.addingTimeInterval(offsets.pending))

            readFails = false
            try store.prepareForDelivery(&pending, sessionID: session.id,
                at: receivedAt.addingTimeInterval(30))
            let latestSubmission = receivedAt.addingTimeInterval(max(offsets.stored ?? 0, offsets.pending))
            XCTAssertEqual(pending.items.map(\.id), [item.id], "A replay remains one durable payload")
            XCTAssertEqual(pending.lastSubmittedAt?[item.id], latestSubmission)
            XCTAssertEqual(pending.didPrioritizeLatestReading, true)

            let restarted = try LibreWatchOutboxFileStore(fileURL: fixture.fileURL,
                defaults: fixture.defaults).load(at: receivedAt.addingTimeInterval(30))
            XCTAssertEqual(restarted, pending)
            XCTAssertNil(restarted.nextEligible(at: latestSubmission.addingTimeInterval(59)))
            XCTAssertEqual(restarted.nextEligible(at: latestSubmission.addingTimeInterval(60))?.id, item.id)
        }
    }

    func testFileOutboxLateReadRecoveryDoesNotReintroduceReplacedSensorSession() throws {
        let fixture = try outboxFileFixture()
        let firstStore = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        var old = try firstStore.load(at: receivedAt)
        old.enqueue(fileOutboxReading(0, at: receivedAt), now: receivedAt)
        try firstStore.save(old)
        var pending = LibreWatchConnectivityOutbox()
        let newSession = UUID()
        let newer = payload(id: outboxFixtureID(1), raw: 847, previousRaw: 829,
            domain: .xDripRawGlucose, sensorTime: 1_001, at: receivedAt, sessionID: newSession)
        pending.enqueue(.reading(newer), now: receivedAt)
        let store = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
        try store.prepareForDelivery(&pending, sessionID: newSession, at: receivedAt)
        XCTAssertEqual(pending.items.map(\.id), [newer.id])
        XCTAssertEqual(try LibreWatchOutboxFileStore(fileURL: fixture.fileURL,
            defaults: fixture.defaults).load(at: receivedAt).items.map(\.id), [newer.id])
    }

    func testFileOutboxSixHour360And400ReadingSnapshotsStayBoundedAcrossRestart() throws {
        XCTAssertEqual(LibreWatchConnectivityOutbox.maximumAge, 6 * 60 * 60)
        XCTAssertEqual(LibreWatchReadingAcceptancePolicy.maximumTransportAge, 3 * 60)
        for readingCount in [360, 400] {
            let fixture = try outboxFileFixture()
            let now = receivedAt.addingTimeInterval(6 * 60 * 60)
            var outbox = LibreWatchConnectivityOutbox()
            for index in 0..<readingCount {
                // Include an exact six-hour boundary and a full-capacity reading fixture;
                // cadence here is a storage input, not a claim about sensor production rate.
                let date = receivedAt.addingTimeInterval(Double(index) * (6 * 60 * 60) / Double(readingCount - 1))
                let item = fileOutboxReading(index, at: date)
                XCTAssertTrue(outbox.enqueue(item, now: now))
                if index % 10 == 0 { outbox.markSubmitted(id: item.id, at: now) }
            }
            XCTAssertEqual(outbox.items.count, readingCount)
            XCTAssertEqual(outbox.items.first?.createdAt, receivedAt)
            let store = LibreWatchOutboxFileStore(fileURL: fixture.fileURL, defaults: fixture.defaults)
            _ = try store.load(at: now)
            try store.save(outbox)
            let file = try Data(contentsOf: fixture.fileURL)
            print("Libre outbox file: \(readingCount) readings, \(file.count) encoded bytes")
            XCTAssertLessThanOrEqual(file.count, LibreWatchConnectivityOutbox.maximumEncodedBytes)
            XCTAssertEqual(try LibreWatchOutboxFileStore(fileURL: fixture.fileURL,
                defaults: fixture.defaults).load(at: now), outbox)
            let justExpired = try LibreWatchOutboxFileStore(fileURL: fixture.fileURL,
                defaults: fixture.defaults).load(at: now.addingTimeInterval(0.001))
            XCTAssertEqual(justExpired.items.count, readingCount - 1)
            XCTAssertFalse(justExpired.items.contains { $0.id == outboxFixtureID(0) })
            XCTAssertNil(justExpired.lastSubmittedAt?[outboxFixtureID(0)])
        }
    }
}
