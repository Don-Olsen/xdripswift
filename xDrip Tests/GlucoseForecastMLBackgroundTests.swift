import XCTest
@testable import xdrip

final class GlucoseForecastMLBackgroundTests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_800_000_000)

    private final class LockedValue<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    }

    /// Pause the first real lock holder, and observe each contender before it
    /// blocks. This gives the tests a deterministic contention boundary.
    private final class GatedLock: NSLock, @unchecked Sendable {
        private let requested: XCTestExpectation
        private let acquired: XCTestExpectation
        private let resumeGate = DispatchSemaphore(value: 0)
        private var pauseFirstHolder = true

        init(requested: XCTestExpectation, acquired: XCTestExpectation) {
            self.requested = requested
            self.acquired = acquired
            super.init()
        }

        override func lock() {
            requested.fulfill()
            super.lock()
            if pauseFirstHolder {
                pauseFirstHolder = false
                acquired.fulfill()
                resumeGate.wait()
            }
        }

        func resume() { resumeGate.signal() }
    }

    private actor ReadinessGate {
        private var opened = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }

    private func context(source: String = "prepared-history-test") -> GlucoseForecastMLContext {
        GlucoseForecastMLContext(sensitivityMgdlPerUnit: 40,
                                 carbohydrateRatioGramsPerUnit: 10,
                                 settings: TherapyModelSettings(),
                                 sourceSignature: source)!
    }

    private func examples(at reference: Date,
                          featureValue: Double = 1,
                          glucose: Double = 150) -> [GlucoseForecastMLReplayExample] {
        [30, 60, 120].map { horizon in
            let row = GlucoseForecastMLFeatureRow(
                horizonMinutes: horizon, referenceDate: reference,
                engineValue: 150, glucose: glucose, sensorID: "synthetic-sensor",
                values: Array(repeating: featureValue,
                              count: GlucoseForecastMLFeatures.featureNames.count))
            return GlucoseForecastMLReplayExample(
                row: row, targetDate: reference.addingTimeInterval(Double(horizon * 60)),
                targetGlucoseMgdl: 155, engineTargetGlucoseMgdl: 150,
                engineTrajectoryMgdl: Array(repeating: 150, count: 25),
                sourceIdentity: "sensor:synthetic-sensor",
                treatmentAvailability: .retrospectiveUnknown,
                settingsAvailability: .retrospectiveUnknown,
                bolusUnitsInWindow: 2.5, carbohydrateGramsInWindow: 32)
        }
    }

    private func snapshot(reference: Date? = nil,
                          preparedAt: Date? = nil,
                          examples rows: [GlucoseForecastMLReplayExample]? = nil,
                          context: GlucoseForecastMLContext? = nil,
                          timeZone: TimeZone = .current) -> GlucoseForecastMLPreparedHistory {
        let reference = reference ?? clock.addingTimeInterval(-3 * 3600)
        return GlucoseForecastMLPreparedHistory(
            context: context ?? self.context(),
            preparedAt: preparedAt ?? clock.addingTimeInterval(-30 * 60),
            examples: rows ?? examples(at: reference), timeZone: timeZone)
    }

    private func diagnosticDefaults(for directory: URL) -> UserDefaults {
        UserDefaults(suiteName: "GlucoseForecastMLBackgroundTests." + directory.lastPathComponent)!
    }

    private func makeStore(directory: URL, snapshotLock: NSLock = NSLock(),
                           attemptLock: NSLock = NSLock(), diagnosticDefaults: UserDefaults? = nil)
        -> GlucoseForecastMLPreparedHistoryStore {
        GlucoseForecastMLPreparedHistoryStore(directory: directory, snapshotLock: snapshotLock,
            attemptLock: attemptLock, diagnosticDefaults: diagnosticDefaults ?? self.diagnosticDefaults(for: directory))
    }

    private func temporaryStore() -> GlucoseForecastMLPreparedHistoryStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("forecast-prepared-\(UUID().uuidString)", isDirectory: true)
        let defaults = diagnosticDefaults(for: directory)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: "GlucoseForecastMLBackgroundTests." + directory.lastPathComponent)
        }
        return makeStore(directory: directory, diagnosticDefaults: defaults)
    }

    private func recentSnapshot(context: GlucoseForecastMLContext? = nil)
        -> GlucoseForecastMLPreparedHistory {
        let now = Date()
        return snapshot(reference: now.addingTimeInterval(-3 * 3600),
                        preparedAt: now.addingTimeInterval(-30 * 60), context: context)
    }

    private func backgroundDependencies(
        context: GlucoseForecastMLContext,
        waitUntilReady: @escaping @Sendable () async -> Void = {},
        enabled: @escaping @Sendable () async -> Bool = { true },
        dueDate: @escaping @Sendable (GlucoseForecastMLContext) -> Date? = { _ in nil },
        train: @escaping @Sendable (GlucoseForecastMLPreparedHistory,
                                   GlucoseForecastMLBackgroundRun,
                                   @escaping @Sendable (Bool) -> Void) -> Bool)
        -> GlucoseForecastMLTrainingCoordinator.BackgroundDependencies {
        .init(waitUntilReady: waitUntilReady,
              currentContext: { context }, forecastEnabled: enabled,
              currentDueDate: dueDate, train: train)
    }

    private func mutated(_ original: GlucoseForecastMLPreparedHistory,
                         change: (inout [String: Any]) -> Void) throws
        -> GlucoseForecastMLPreparedHistory {
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&object)
        return try JSONDecoder().decode(GlucoseForecastMLPreparedHistory.self,
                                        from: JSONSerialization.data(withJSONObject: object))
    }

    func testPreparedHistoryRoundTripsExactlyAndFingerprintTracksInputs() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let original = snapshot()
        XCTAssertTrue(original.isUsable(context: context(), at: clock))
        let fingerprint = try GlucoseForecastMLTrainingFingerprint.value(
            context: original.context, examples: original.examples)

        try store.save(original)
        let restartedStore = self.makeStore(directory: store.directory)
        let recovered = try XCTUnwrap(restartedStore.load(context: context(), at: clock))
        XCTAssertEqual(recovered.id, original.id)
        XCTAssertEqual(recovered.preparedAt, original.preparedAt)
        XCTAssertEqual(recovered.timeZoneIdentifier, original.timeZoneIdentifier)
        XCTAssertEqual(recovered.featureNames, original.featureNames)
        XCTAssertEqual(recovered.examples.count, 3)
        XCTAssertEqual(recovered.examples.map(\.row.horizonMinutes), [30, 60, 120])
        XCTAssertEqual(recovered.examples.map(\.row.values), original.examples.map(\.row.values))
        XCTAssertEqual(recovered.examples.map(\.targetDate), original.examples.map(\.targetDate))
        XCTAssertEqual(recovered.examples.map(\.bolusUnitsInWindow), [2.5, 2.5, 2.5])
        XCTAssertEqual(recovered.examples.map(\.carbohydrateGramsInWindow), [32, 32, 32])
        XCTAssertEqual(try GlucoseForecastMLTrainingFingerprint.value(
            context: recovered.context, examples: recovered.examples), fingerprint)
        XCTAssertEqual(fingerprint.count, 64)

        let changed = examples(at: original.examples[0].row.referenceDate, featureValue: 2)
        XCTAssertNotEqual(try GlucoseForecastMLTrainingFingerprint.value(
            context: context(), examples: changed), fingerprint)
        XCTAssertNotEqual(try GlucoseForecastMLTrainingFingerprint.value(
            context: context(source: "different-source"), examples: original.examples), fingerprint)
    }

    func testPreparedHistoryRejectsStaleReferenceAndChangedContextOrSchema() throws {
        let valid = snapshot()
        XCTAssertTrue(valid.isUsable(context: context(), at: clock))
        XCTAssertFalse(valid.isUsable(context: context(source: "new-owner"), at: clock))
        XCTAssertFalse(valid.isUsable(context: context(), at: valid.preparedAt.addingTimeInterval(-1)))

        let stalePreparation = snapshot(
            reference: clock.addingTimeInterval(-53 * 3600),
            preparedAt: clock.addingTimeInterval(-50 * 3600))
        XCTAssertFalse(stalePreparation.isUsable(context: context(), at: clock))
        let staleReference = snapshot(reference: clock.addingTimeInterval(-49 * 3600))
        XCTAssertFalse(staleReference.isUsable(context: context(), at: clock))

        let wrongSchema = try mutated(valid) { $0["schemaVersion"] = 99 }
        XCTAssertFalse(wrongSchema.isUsable(context: context(), at: clock))
        let wrongFeatures = try mutated(valid) { $0["featureNames"] = ["changed"] }
        XCTAssertFalse(wrongFeatures.isUsable(context: context(), at: clock))
        let wrongGeneration = try mutated(valid) { object in
            var storedContext = object["context"] as! [String: Any]
            storedContext["featureVersion"] = "obsolete-feature-contract"
            object["context"] = storedContext
        }
        XCTAssertFalse(wrongGeneration.isUsable(context: context(), at: clock))
        let otherZone = TimeZone(identifier: TimeZone.current.identifier == "UTC"
                                 ? "Europe/Copenhagen" : "UTC")!
        XCTAssertFalse(snapshot(timeZone: otherZone).isUsable(context: context(), at: clock))
    }

    func testPreparedHistoryRejectsIncompleteAndInvalidExamples() {
        let reference = clock.addingTimeInterval(-3 * 3600)
        let complete = examples(at: reference)
        XCTAssertFalse(snapshot(examples: Array(complete.dropLast()))
            .isUsable(context: context(), at: clock))
        XCTAssertFalse(snapshot(examples: [complete[0], complete[0], complete[2]])
            .isUsable(context: context(), at: clock))
        XCTAssertFalse(snapshot(examples: examples(at: reference, featureValue: .nan))
            .isUsable(context: context(), at: clock))
        XCTAssertFalse(snapshot(examples: examples(at: reference, glucose: .infinity))
            .isUsable(context: context(), at: clock))
        let futureTarget = examples(at: clock.addingTimeInterval(-60 * 60))
        XCTAssertFalse(snapshot(examples: futureTarget).isUsable(context: context(), at: clock))
    }

    func testCorruptionAndInterruptedReplacementDoNotYieldTrainingInputs() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let valid = snapshot()
        try store.save(valid)

        let invalid = snapshot(examples: examples(
            at: clock.addingTimeInterval(-3 * 3600), featureValue: .nan))
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(store.load(context: context(), at: clock)?.id, valid.id)

        let file = store.directory.appendingPathComponent("history.json")
        try Data("{\"schemaVersion\":1,\"examples\":[".utf8).write(to: file, options: .atomic)
        XCTAssertNil(store.load(context: context(), at: clock))
        try Data("not-json".utf8).write(to: file, options: .atomic)
        XCTAssertNil(self.makeStore(directory: store.directory)
            .load(context: context(), at: clock))
    }

    func testFinishingOldJobCannotRemoveNewerPreparedSnapshot() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let older = snapshot()
        let newer = snapshot()
        try store.save(older)
        try store.save(newer)

        store.remove(id: older.id)
        XCTAssertEqual(store.load(context: context(), at: clock)?.id, newer.id)
        store.remove(id: newer.id)
        XCTAssertNil(store.load(context: context(), at: clock))
    }

    func testAutomaticRetryPersistsAcrossRestartAndResetsForChangedContext() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let source = context()
        XCTAssertEqual(store.nextAutomaticAttempt(context: source, at: clock), clock)
        try store.recordAttempt(context: source, at: clock, completed: false)

        let restarted = self.makeStore(directory: store.directory)
        let oneHourLater = clock.addingTimeInterval(3600)
        XCTAssertEqual(restarted.nextAutomaticAttempt(context: source, at: oneHourLater),
                       clock.addingTimeInterval(24 * 3600))
        let afterRetry = clock.addingTimeInterval(25 * 3600)
        XCTAssertEqual(restarted.nextAutomaticAttempt(context: source, at: afterRetry), afterRetry)

        try restarted.recordAttempt(context: source, at: afterRetry, completed: true)
        let completedRestart = self.makeStore(directory: store.directory)
        XCTAssertEqual(completedRestart.nextAutomaticAttempt(
            context: source, at: afterRetry.addingTimeInterval(3600)),
            afterRetry.addingTimeInterval(GlucoseForecastMLChronology.modelAgeLimit))
        XCTAssertEqual(completedRestart.nextAutomaticAttempt(
            context: context(source: "new-source"), at: afterRetry.addingTimeInterval(3600)),
            afterRetry.addingTimeInterval(3600))
    }

    func testBlockedHistoryKeepsCooldownIOIndependentAndSnapshotOperationsSerialized() throws {
        let initialStore = temporaryStore()
        defer { try? FileManager.default.removeItem(at: initialStore.directory) }
        let older = snapshot()
        let newer = snapshot()
        let source = context()
        let now = clock
        try initialStore.save(older)

        let requested = expectation(description: "save, load and remove request the history lock")
        requested.expectedFulfillmentCount = 3
        let acquired = expectation(description: "replacement holds the history lock")
        let snapshotLock = GatedLock(requested: requested, acquired: acquired)
        let store = self.makeStore(directory: initialStore.directory,
                                                          snapshotLock: snapshotLock)
        let finished = expectation(description: "all file operations finish after release")
        finished.expectedFulfillmentCount = 4
        let metadataFinished = expectation(description: "cooldown IO finishes while history is held")
        let saved = LockedValue(false)
        let loaded = LockedValue(false)
        let removed = LockedValue(false)
        defer { snapshotLock.resume() }

        DispatchQueue.global().async {
            defer { saved.set(true); finished.fulfill() }
            do { try store.save(newer) } catch { XCTFail("Snapshot save failed: \(error)") }
        }
        wait(for: [acquired], timeout: 3)
        DispatchQueue.global().async {
            XCTAssertEqual(store.load(context: source, at: now)?.id, newer.id)
            loaded.set(true)
            finished.fulfill()
        }
        DispatchQueue.global().async {
            store.remove(id: older.id)
            removed.set(true)
            finished.fulfill()
        }
        DispatchQueue.global().async {
            defer { metadataFinished.fulfill(); finished.fulfill() }
            do {
                XCTAssertEqual(store.nextAutomaticAttempt(context: source, at: now), now)
                XCTAssertEqual(store.nextPreparationDate(context: source, at: now), now)
                try store.recordAttempt(context: source, at: now, completed: false)
                XCTAssertEqual(store.nextAutomaticAttempt(context: source, at: now),
                               now.addingTimeInterval(24 * 3600))
                XCTAssertEqual(store.nextPreparationDate(context: source, at: now),
                               now.addingTimeInterval(24 * 3600))
                try store.recordAttempt(context: source, at: now, completed: true)
                let restarted = self.makeStore(directory: store.directory)
                XCTAssertEqual(restarted.nextAutomaticAttempt(context: source, at: now),
                               now.addingTimeInterval(GlucoseForecastMLChronology.modelAgeLimit))
                XCTAssertEqual(restarted.nextPreparationDate(context: source, at: now),
                               now.addingTimeInterval(GlucoseForecastMLChronology.modelAgeLimit - 24 * 3600))
            } catch { XCTFail("Cooldown write failed: \(error)") }
        }
        wait(for: [requested, metadataFinished], timeout: 3)
        // All three history calls have reached the held lock. No sleep or
        // scheduler-speed assumption is needed to assert they cannot finish.
        XCTAssertFalse(saved.get())
        XCTAssertFalse(loaded.get())
        XCTAssertFalse(removed.get())
        snapshotLock.resume()
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(initialStore.load(context: source, at: now)?.id, newer.id)
    }

    func testCooldownReadersWaitForTheSameFileWriteAndObserveCompletedCadence() throws {
        let initialStore = temporaryStore()
        defer { try? FileManager.default.removeItem(at: initialStore.directory) }
        let source = context()
        let now = clock
        try initialStore.recordAttempt(context: source, at: now, completed: false)

        let requested = expectation(description: "writer and both cooldown readers request the attempt lock")
        requested.expectedFulfillmentCount = 3
        let acquired = expectation(description: "completed attempt holds its file lock")
        let attemptLock = GatedLock(requested: requested, acquired: acquired)
        let store = self.makeStore(directory: initialStore.directory,
                                                          attemptLock: attemptLock)
        let finished = expectation(description: "cooldown operations finish after release")
        finished.expectedFulfillmentCount = 3
        let attemptDate = LockedValue<Date?>(nil)
        let preparationDate = LockedValue<Date?>(nil)
        defer { attemptLock.resume() }

        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do { try store.recordAttempt(context: source, at: now, completed: true) }
            catch { XCTFail("Cooldown write failed: \(error)") }
        }
        wait(for: [acquired], timeout: 3)
        DispatchQueue.global().async {
            attemptDate.set(store.nextAutomaticAttempt(context: source, at: now))
            finished.fulfill()
        }
        DispatchQueue.global().async {
            preparationDate.set(store.nextPreparationDate(context: source, at: now))
            finished.fulfill()
        }
        wait(for: [requested], timeout: 3)
        XCTAssertNil(attemptDate.get())
        XCTAssertNil(preparationDate.get())
        attemptLock.resume()
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(attemptDate.get(), now.addingTimeInterval(GlucoseForecastMLChronology.modelAgeLimit))
        XCTAssertEqual(preparationDate.get(),
                       now.addingTimeInterval(GlucoseForecastMLChronology.modelAgeLimit - 24 * 3600))
        XCTAssertEqual(initialStore.nextAutomaticAttempt(context: source, at: now), attemptDate.get())
    }

    func testPreparedFilesAreExcludedFromBackupAndProtected() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.save(snapshot())
        try store.recordAttempt(context: context(), at: clock, completed: false)
        let files = [store.directory,
                     store.directory.appendingPathComponent("history.json"),
                     store.directory.appendingPathComponent("automatic-attempt.json")]
        for file in files {
            XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup, true)
            #if os(iOS) && !targetEnvironment(simulator)
            let protection = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey]
            XCTAssertEqual(protection as? FileProtectionType,
                           .completeUntilFirstUserAuthentication)
            #endif
        }
    }

    func testBackgroundEntryUsesExactProtectedSnapshotWithoutHealthOrCoreData() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let prepared = recentSnapshot()
        try store.save(prepared)
        let coordinator = GlucoseForecastMLTrainingCoordinator(
            preparedStore: store, observeLifecycle: false)
        let passed = LockedValue<GlucoseForecastMLPreparedHistory?>(nil)
        let trainStarted = expectation(description: "prepared snapshot handed to trainer")
        let finished = expectation(description: "background entry finishes once")
        let result = LockedValue<[Bool]>([])

        coordinator.runPreparedBackgroundTraining(dependencies: backgroundDependencies(
            context: context(), train: { snapshot, run, completion in
                XCTAssertFalse(run.isCancelled)
                passed.set(snapshot)
                trainStarted.fulfill()
                completion(true)
                return true
            })) { success in
                result.set(result.get() + [success])
                finished.fulfill()
            }
        await fulfillment(of: [trainStarted, finished], timeout: 3)
        let delivered = try XCTUnwrap(passed.get())
        XCTAssertEqual(delivered.id, prepared.id)
        XCTAssertEqual(delivered.context, prepared.context)
        XCTAssertEqual(delivered.preparedAt, prepared.preparedAt)
        XCTAssertEqual(delivered.examples.map(\.targetDate), prepared.examples.map(\.targetDate))
        XCTAssertEqual(delivered.examples.map(\.row.values), prepared.examples.map(\.row.values))
        XCTAssertEqual(result.get(), [true])
        XCTAssertNil(store.load(context: context(), at: Date()))
    }

    func testInvalidPreparedSnapshotNeverReachesBackgroundTraining() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.save(recentSnapshot(context: context(source: "old-context")))
        let coordinator = GlucoseForecastMLTrainingCoordinator(
            preparedStore: store, observeLifecycle: false)
        let calls = LockedValue(0)
        let finished = expectation(description: "invalid snapshot declines training")
        let result = LockedValue<Bool?>(nil)

        coordinator.runPreparedBackgroundTraining(dependencies: backgroundDependencies(
            context: context(), train: { _, _, _ in
                calls.set(calls.get() + 1)
                return true
            })) { success in
                result.set(success)
                finished.fulfill()
            }
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(calls.get(), 0)
        XCTAssertEqual(result.get(), false)
    }

    func testExpirationWhileWaitingForReadinessPreventsTraining() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.save(recentSnapshot())
        let coordinator = GlucoseForecastMLTrainingCoordinator(
            preparedStore: store, observeLifecycle: false)
        let gate = ReadinessGate()
        let waiting = expectation(description: "BG entry waits for model readiness")
        let firstFinished = expectation(description: "expired BG entry completes before readiness")
        let firstResumed = expectation(description: "expired entry resumes after the next run")
        let secondStarted = expectation(description: "new BG entry starts before old readiness")
        let secondFinished = expectation(description: "new BG entry completes")
        let firstCalls = LockedValue(0)
        let firstResults = LockedValue<[Bool]>([])
        let secondResults = LockedValue<[Bool]>([])
        let sourceContext = context()

        let firstDependencies = GlucoseForecastMLTrainingCoordinator.BackgroundDependencies(
            waitUntilReady: {
                waiting.fulfill()
                await gate.wait()
            }, currentContext: {
                firstResumed.fulfill()
                return sourceContext
            }, forecastEnabled: { true }, currentDueDate: { _ in nil },
            train: { _, _, _ in
                firstCalls.set(firstCalls.get() + 1)
                return true
            })
        coordinator.runPreparedBackgroundTraining(dependencies: firstDependencies) { success in
                firstResults.set(firstResults.get() + [success])
                firstFinished.fulfill()
            }
        await fulfillment(of: [waiting], timeout: 3)
        coordinator.cancelBackgroundTraining()
        // The first readiness gate deliberately stays closed: expiration must
        // release its lease now, rather than after a cold model load resumes.
        await fulfillment(of: [firstFinished], timeout: 3)
        coordinator.runPreparedBackgroundTraining(dependencies: backgroundDependencies(
            context: sourceContext, train: { _, _, completion in
                secondStarted.fulfill()
                completion(true)
                return true
            })) { success in
                secondResults.set(secondResults.get() + [success])
                secondFinished.fulfill()
            }
        await fulfillment(of: [secondStarted, secondFinished], timeout: 3)
        XCTAssertEqual(firstResults.get(), [false])
        XCTAssertEqual(secondResults.get(), [true])
        XCTAssertEqual(firstCalls.get(), 0)

        await gate.open()
        await fulfillment(of: [firstResumed], timeout: 3)
        XCTAssertEqual(firstCalls.get(), 0)
        XCTAssertEqual(firstResults.get(), [false])
    }

    func testOverlappingBackgroundRunAndRepeatedTrainerCallbackCompleteOnce() async throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try store.save(recentSnapshot())
        let coordinator = GlucoseForecastMLTrainingCoordinator(
            preparedStore: store, observeLifecycle: false)
        let pendingCallback = LockedValue<(@Sendable (Bool) -> Void)?>(nil)
        let trainingStarted = expectation(description: "first BG run starts")
        let firstFinished = expectation(description: "first BG run finishes")
        let secondFinished = expectation(description: "overlapping run declines")
        let firstResults = LockedValue<[Bool]>([])
        let secondResults = LockedValue<[Bool]>([])

        coordinator.runPreparedBackgroundTraining(dependencies: backgroundDependencies(
            context: context(), train: { _, _, completion in
                pendingCallback.set(completion)
                trainingStarted.fulfill()
                return true
            })) { success in
                firstResults.set(firstResults.get() + [success])
                firstFinished.fulfill()
            }
        await fulfillment(of: [trainingStarted], timeout: 3)
        coordinator.runPreparedBackgroundTraining(dependencies: backgroundDependencies(
            context: context(), train: { _, _, _ in
                XCTFail("overlapping run must not start training")
                return true
            })) { success in
                secondResults.set(secondResults.get() + [success])
                secondFinished.fulfill()
            }
        await fulfillment(of: [secondFinished], timeout: 3)
        let callback = try XCTUnwrap(pendingCallback.get())
        callback(true)
        callback(false)
        await fulfillment(of: [firstFinished], timeout: 3)
        XCTAssertEqual(firstResults.get(), [true])
        XCTAssertEqual(secondResults.get(), [false])
        // A duplicate late callback must not undo the completed weekly cadence.
        let next = store.nextAutomaticAttempt(context: context(), at: Date())
        XCTAssertGreaterThan(next.timeIntervalSinceNow, 6 * 24 * 3600)
    }
}


extension GlucoseForecastMLBackgroundTests {
    func testInterruptedPreparationReleasesItsRetryAcrossRestart() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let source = context()
        let coordinator = GlucoseForecastMLTrainingCoordinator(
            preparedStore: store, observeLifecycle: false)
        let cancellation = try XCTUnwrap(coordinator.beginPreparation(
            context: source, force: false, at: clock))
        XCTAssertTrue(coordinator.recordPreparationAttempt(
            context: source, at: clock, cancellation: cancellation))
        XCTAssertNil(coordinator.beginPreparation(context: source, force: false, at: clock),
            "The preparation still owns its single-run claim")
        let reopenedAt = clock.addingTimeInterval(60)
        XCTAssertEqual(store.nextPreparationDate(context: source, at: reopenedAt),
                       clock.addingTimeInterval(24 * 3600))

        coordinator.cancelForBackground()
        XCTAssertTrue(cancellation.isCancelled)
        coordinator.finishPreparation("interrupted preparation", cancellation: cancellation)
        XCTAssertFalse(coordinator.isPreparing)
        XCTAssertEqual(store.nextPreparationDate(context: source, at: reopenedAt), reopenedAt)
        let retry = try XCTUnwrap(coordinator.beginPreparation(
            context: source, force: false, at: reopenedAt))
        coordinator.finishPreparation("retry eligibility checked", cancellation: retry)

        let restartedStore = self.makeStore(directory: store.directory)
        XCTAssertEqual(restartedStore.nextAutomaticAttempt(context: source, at: reopenedAt), reopenedAt)
        let restartedCoordinator = GlucoseForecastMLTrainingCoordinator(
            preparedStore: restartedStore, observeLifecycle: false)
        let restarted = try XCTUnwrap(restartedCoordinator.beginPreparation(
            context: source, force: false, at: reopenedAt))
        XCTAssertTrue(restartedCoordinator.recordPreparationAttempt(
            context: source, at: reopenedAt, cancellation: restarted))
        XCTAssertEqual(restartedStore.nextPreparationDate(context: source, at: reopenedAt),
                       reopenedAt.addingTimeInterval(24 * 3600))
        restartedCoordinator.finishPreparation("ordinary preparation failure", cancellation: restarted)
    }

    func testCooldownOnlyPreparationProbeDoesNotStartAnotherTwentyFourHourThrottle() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let source = context()
        try store.recordAttempt(context: source, at: clock, completed: false)
        let coordinator = GlucoseForecastMLTrainingCoordinator(
            preparedStore: store, observeLifecycle: false)
        let probeAt = clock.addingTimeInterval(23 * 3600)
        let probe = try XCTUnwrap(coordinator.beginPreparation(
            context: source, force: false, at: probeAt))
        XCTAssertGreaterThan(store.nextPreparationDate(context: source, at: probeAt), probeAt)
        // This is the coordinator's cooldown early return: no historical read starts.
        let due = store.nextPreparationDate(context: source, at: probeAt)
        coordinator.deferPreparation(context: source, until: due, cancellation: probe)
        coordinator.finishPreparation("awaiting existing retry deadline", cancellation: probe)
        XCTAssertEqual(due, clock.addingTimeInterval(24 * 3600))
        XCTAssertNil(coordinator.beginPreparation(context: source, force: false,
            at: due.addingTimeInterval(-1)), "The existing deadline still applies")
        XCTAssertEqual(store.nextPreparationDate(context: source, at: due), due)
        let actualAttempt = try XCTUnwrap(coordinator.beginPreparation(
            context: source, force: false, at: due),
            "A cooldown check at hour 23 must not move eligibility to hour 47")
        XCTAssertTrue(coordinator.recordPreparationAttempt(
            context: source, at: due, cancellation: actualAttempt))
        coordinator.finishPreparation("ordinary preparation failure", cancellation: actualAttempt)
    }

    func testCancellationBeforeAttemptWritePreservesAnEarlierFailure() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let source = context()
        try store.recordAttempt(context: source, at: clock, completed: false)
        let coordinator = GlucoseForecastMLTrainingCoordinator(
            preparedStore: store, observeLifecycle: false)
        let attemptAt = clock.addingTimeInterval(60)
        let cancellation = try XCTUnwrap(coordinator.beginPreparation(
            context: source, force: false, at: attemptAt))
        coordinator.cancelForBackground()
        XCTAssertFalse(coordinator.recordPreparationAttempt(
            context: source, at: attemptAt, cancellation: cancellation),
            "A cancelled claim cannot overwrite the durable attempt marker")
        coordinator.finishPreparation("cancelled before reading", cancellation: cancellation)
        let restarted = self.makeStore(directory: store.directory)
        XCTAssertEqual(restarted.nextPreparationDate(context: source, at: attemptAt),
                       clock.addingTimeInterval(24 * 3600),
            "Cancellation owns no marker here and cannot erase the earlier failure")
    }

    func testFinishedPreparationFailureKeepsItsCooldownAfterBackgrounding() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let source = context()
        let coordinator = GlucoseForecastMLTrainingCoordinator(
            preparedStore: store, observeLifecycle: false)
        let cancellation = try XCTUnwrap(coordinator.beginPreparation(
            context: source, force: false, at: clock))
        XCTAssertTrue(coordinator.recordPreparationAttempt(
            context: source, at: clock, cancellation: cancellation))
        coordinator.finishPreparation("insufficient usable history", cancellation: cancellation)
        coordinator.cancelForBackground()
        let reopenedAt = clock.addingTimeInterval(60)
        let restarted = self.makeStore(directory: store.directory)
        XCTAssertEqual(restarted.nextPreparationDate(context: source, at: reopenedAt),
                       clock.addingTimeInterval(24 * 3600))
        XCTAssertEqual(restarted.nextAutomaticAttempt(context: source, at: reopenedAt),
                       clock.addingTimeInterval(24 * 3600))
        XCTAssertFalse(coordinator.isPreparing)
    }

    func testReadFailureFollowedByCancellationBeforeFinishKeepsItsCooldown() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let source = context()
        let coordinator = GlucoseForecastMLTrainingCoordinator(
            preparedStore: store, observeLifecycle: false)
        let cancellation = try XCTUnwrap(coordinator.beginPreparation(
            context: source, force: false, at: clock))
        XCTAssertTrue(coordinator.recordPreparationAttempt(
            context: source, at: clock, cancellation: cancellation))
        cancellation.recordReadFailure("synthetic historical read failure")
        coordinator.cancelForBackground()
        coordinator.finishPreparation("historical read failed", cancellation: cancellation)
        let reopenedAt = clock.addingTimeInterval(60)
        let restarted = self.makeStore(directory: store.directory)
        XCTAssertEqual(restarted.nextPreparationDate(context: source, at: reopenedAt),
                       clock.addingTimeInterval(24 * 3600),
            "Backgrounding after a real read failure must not turn it into a free retry")
        XCTAssertEqual(cancellation.readFailure, "synthetic historical read failure")
    }

    func testLateCancelledPreparationCallbacksCannotEraseOrReplaceANewerAttempt() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let source = context()
        let coordinator = GlucoseForecastMLTrainingCoordinator(
            preparedStore: store, observeLifecycle: false)
        let old = try XCTUnwrap(coordinator.beginPreparation(
            context: source, force: false, at: clock))
        XCTAssertTrue(coordinator.recordPreparationAttempt(
            context: source, at: clock, cancellation: old))
        coordinator.cancelForBackground()
        coordinator.finishPreparation("old preparation interrupted", cancellation: old)
        let newDate = clock.addingTimeInterval(60)
        let current = try XCTUnwrap(coordinator.beginPreparation(
            context: source, force: false, at: newDate))
        XCTAssertTrue(coordinator.recordPreparationAttempt(
            context: source, at: newDate, cancellation: current))
        let currentStatus = coordinator.statusText

        coordinator.finishPreparation("late old callback", cancellation: old)
        XCTAssertFalse(coordinator.recordPreparationAttempt(
            context: source, at: clock, cancellation: old))
        XCTAssertTrue(coordinator.isPreparing)
        XCTAssertFalse(current.isCancelled)
        XCTAssertEqual(coordinator.statusText, currentStatus)
        XCTAssertEqual(store.nextPreparationDate(context: source, at: newDate),
                       newDate.addingTimeInterval(24 * 3600))
        coordinator.finishPreparation("current preparation failed", cancellation: current)
    }

    func testInterruptedAttemptRemovalPreservesNewerCompletedAndOtherContextRecords() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let source = context()
        let newerDate = clock.addingTimeInterval(60)
        try store.recordAttempt(context: source, at: newerDate, completed: false)
        try store.removeInterruptedAttempt(context: source, at: clock)
        XCTAssertEqual(store.nextPreparationDate(context: source, at: newerDate),
                       newerDate.addingTimeInterval(24 * 3600))

        try store.recordAttempt(context: source, at: clock, completed: true)
        try store.removeInterruptedAttempt(context: source, at: clock)
        XCTAssertEqual(store.nextAutomaticAttempt(context: source, at: newerDate),
                       clock.addingTimeInterval(GlucoseForecastMLChronology.modelAgeLimit))

        let other = context(source: "different-preparation-source")
        try store.recordAttempt(context: other, at: clock, completed: false)
        try store.removeInterruptedAttempt(context: source, at: clock)
        XCTAssertEqual(store.nextPreparationDate(context: other, at: newerDate),
                       clock.addingTimeInterval(24 * 3600))
        try store.removeInterruptedAttempt(context: other, at: clock)
        let restarted = self.makeStore(directory: store.directory)
        XCTAssertEqual(restarted.nextPreparationDate(context: other, at: newerDate), newerDate)
        // Repeated completion of the same interrupted run is harmless.
        try restarted.removeInterruptedAttempt(context: other, at: clock)
        XCTAssertEqual(restarted.nextAutomaticAttempt(context: other, at: newerDate), newerDate)
    }
}


extension GlucoseForecastMLBackgroundTests {
    func testReadySnapshotDefersRepeatedReadsWithoutWritingAnAttemptMarker() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let source = context()
        let prepared = snapshot()
        try store.save(prepared)
        let coordinator = GlucoseForecastMLTrainingCoordinator(
            preparedStore: store, observeLifecycle: false)
        let cancellation = try XCTUnwrap(coordinator.beginPreparation(
            context: source, force: false, at: clock))
        XCTAssertEqual(store.load(context: source, at: clock)?.id, prepared.id)
        let due = clock.addingTimeInterval(24 * 3600)
        coordinator.deferPreparation(context: source, until: due, cancellation: cancellation)
        coordinator.finishPreparation("prepared snapshot ready", cancellation: cancellation)
        XCTAssertNil(coordinator.beginPreparation(context: source, force: false,
            at: clock.addingTimeInterval(15)))
        XCTAssertNil(coordinator.beginPreparation(context: source, force: false,
            at: due.addingTimeInterval(-1)))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            store.directory.appendingPathComponent("automatic-attempt.json").path),
            "Reusing prepared history must not become a durable failed attempt")
        let restarted = self.makeStore(directory: store.directory)
        XCTAssertEqual(restarted.nextPreparationDate(context: source, at: clock), clock)
        XCTAssertEqual(restarted.load(context: source, at: clock)?.id, prepared.id)
        let next = try XCTUnwrap(coordinator.beginPreparation(
            context: source, force: false, at: due))
        coordinator.finishPreparation("snapshot can be checked again", cancellation: next)
    }

    func testStorageFailureFollowedByCancellationKeepsItsDurableCooldown() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let source = context()
        let coordinator = GlucoseForecastMLTrainingCoordinator(
            preparedStore: store, observeLifecycle: false)
        let cancellation = try XCTUnwrap(coordinator.beginPreparation(
            context: source, force: false, at: clock))
        XCTAssertTrue(coordinator.recordPreparationAttempt(
            context: source, at: clock, cancellation: cancellation))
        // A snapshot/storage error has already occurred when the app backgrounds.
        // It has no HealthKit readFailure, so the explicit failure outcome matters.
        XCTAssertNil(cancellation.readFailure)
        coordinator.cancelForBackground()
        coordinator.finishPreparation("prepared history could not be saved",
            cancellation: cancellation, failed: true)
        let reopenedAt = clock.addingTimeInterval(60)
        let restarted = self.makeStore(directory: store.directory)
        XCTAssertEqual(restarted.nextPreparationDate(context: source, at: reopenedAt),
                       clock.addingTimeInterval(24 * 3600))
        XCTAssertEqual(restarted.nextAutomaticAttempt(context: source, at: reopenedAt),
                       clock.addingTimeInterval(24 * 3600))
        XCTAssertFalse(coordinator.isPreparing)
    }
}


extension GlucoseForecastMLBackgroundTests {
    private final class DiscardingDiagnosticDefaults: UserDefaults, @unchecked Sendable {
        override func set(_ value: Any?, forKey defaultName: String) {}
        override func removeObject(forKey defaultName: String) {}
    }

    private func saveFailure(_ snapshot: GlucoseForecastMLPreparedHistory,
                             store: GlucoseForecastMLPreparedHistoryStore,
                             file: StaticString = #filePath, line: UInt = #line) throws
        -> GlucoseForecastMLPreparedHistoryStore.SaveFailure {
        var failure: GlucoseForecastMLPreparedHistoryStore.SaveFailure?
        XCTAssertThrowsError(try store.save(snapshot), file: file, line: line) {
            failure = $0 as? GlucoseForecastMLPreparedHistoryStore.SaveFailure
        }
        return try XCTUnwrap(failure, file: file, line: line)
    }

    func testPreparedSaveEncodingFailurePreservesSnapshotAndReloadsSafeDiagnostic() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let previous = snapshot()
        try store.save(previous)
        let invalid = snapshot(examples: examples(at: clock.addingTimeInterval(-3 * 3600),
                                                  featureValue: .nan))
        let before = Date()
        let failure = try saveFailure(invalid, store: store)
        let diagnostic = failure.diagnostic
        XCTAssertEqual(diagnostic.stage, .encoding)
        XCTAssertNil(diagnostic.encodedBytes)
        XCTAssertEqual(diagnostic.maximumBytes, 128 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(diagnostic.occurredAt, before)
        XCTAssertLessThanOrEqual(diagnostic.occurredAt, Date())
        XCTAssertEqual(store.load(context: context(), at: clock)?.id, previous.id)
        let restarted = makeStore(directory: store.directory)
        XCTAssertEqual(restarted.latestSaveDiagnostic(), diagnostic)
        XCTAssertTrue(diagnostic.summaryText.contains("Seneste gemmefejl:"))
        XCTAssertTrue(diagnostic.summaryText.contains("build "))
        XCTAssertTrue(diagnostic.summaryText.contains("kodning"))
        XCTAssertTrue(diagnostic.summaryText.contains("134217728 bytes"))
    }

    func testPreparedSaveSizeFailureMeasuresTheActualUnchangedProductionLimit() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        // A synthetic context string reaches the real byte guard without creating
        // hundreds of thousands of replay rows or changing the production limit.
        let oversized = snapshot(context: context(source: String(repeating: "x", count: 128 * 1024 * 1024)))
        let failure = try saveFailure(oversized, store: store)
        let diagnostic = failure.diagnostic
        XCTAssertEqual(diagnostic.stage, .sizeCheck)
        XCTAssertGreaterThan(try XCTUnwrap(diagnostic.encodedBytes), 128 * 1024 * 1024)
        XCTAssertEqual(diagnostic.maximumBytes, 128 * 1024 * 1024)
        XCTAssertNil(diagnostic.errorDomain)
        XCTAssertNil(diagnostic.errorCode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("history.json").path))
        let data = try XCTUnwrap(diagnosticDefaults(for: store.directory)
            .data(forKey: GlucoseForecastMLPreparedHistoryStore.diagnosticDefaultsKey))
        XCTAssertLessThan(data.count, 1024)
        XCTAssertEqual(makeStore(directory: store.directory).latestSaveDiagnostic(), diagnostic)
    }

    func testPreparedSaveDirectoryFailureKeepsTechnicalDomainAndAttemptBehavior() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try Data("synthetic directory obstruction".utf8).write(to: store.directory)
        let failure = try saveFailure(snapshot(), store: store)
        XCTAssertEqual(failure.diagnostic.stage, .directory)
        XCTAssertNil(failure.diagnostic.encodedBytes)
        XCTAssertEqual(failure.diagnostic.errorDomain, .cocoa)
        XCTAssertNotNil(failure.diagnostic.errorCode)
        XCTAssertEqual(makeStore(directory: store.directory).latestSaveDiagnostic(), failure.diagnostic)
        XCTAssertThrowsError(try store.recordAttempt(context: context(), at: clock, completed: false)) {
            XCTAssertFalse($0 is GlucoseForecastMLPreparedHistoryStore.SaveFailure,
                           "Automatic-attempt writes retain their existing error behavior")
        }
        XCTAssertEqual(store.latestSaveDiagnostic(), failure.diagnostic)
    }

    func testPreparedSaveAtomicWriteFailureReportsEncodedSizeWithoutReplacingDestination() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let destination = store.directory.appendingPathComponent("history.json", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("synthetic-marker")
        try Data("preserve".utf8).write(to: marker)
        let failure = try saveFailure(snapshot(), store: store)
        XCTAssertEqual(failure.diagnostic.stage, .writing)
        XCTAssertGreaterThan(try XCTUnwrap(failure.diagnostic.encodedBytes), 0)
        XCTAssertEqual(failure.diagnostic.errorDomain, .cocoa)
        XCTAssertNotNil(failure.diagnostic.errorCode)
        XCTAssertEqual(try Data(contentsOf: marker), Data("preserve".utf8))
    }

    func testPreparedSaveDiagnosticExcludesPrivateErrorsAndRejectsInvalidStoredMetadata() throws {
        let store = temporaryStore()
        let defaults = diagnosticDefaults(for: store.directory)
        let privateError = NSError(domain: "private-source-identifier", code: 321,
            userInfo: [NSLocalizedDescriptionKey: "private health value",
                       NSFilePathErrorKey: "/private/patient/file",
                       NSUnderlyingErrorKey: NSError(domain: "private-underlying", code: 7)])
        let diagnostic = GlucoseForecastMLPreparedHistoryStore.SaveDiagnostic(
            stage: .backupExclusion, encodedBytes: 1234, error: privateError, occurredAt: clock)
        XCTAssertEqual(diagnostic.errorDomain, .other)
        XCTAssertEqual(diagnostic.errorCode, 321)
        let data = try JSONEncoder().encode(diagnostic)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("private"))
        XCTAssertFalse(diagnostic.summaryText.contains("private"))
        XCTAssertTrue(diagnostic.summaryText.contains("udelukkelse fra sikkerhedskopi"))
        let key = GlucoseForecastMLPreparedHistoryStore.diagnosticDefaultsKey
        for invalid in [Data("not-json".utf8), Data(repeating: 32, count: 16 * 1024 + 1)] {
            defaults.set(invalid, forKey: key)
            XCTAssertNil(makeStore(directory: store.directory).latestSaveDiagnostic())
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 99
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
        XCTAssertNil(makeStore(directory: store.directory).latestSaveDiagnostic())
        object["schemaVersion"] = 1
        object["appBuild"] = "private untrusted text"
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: key)
        XCTAssertNil(makeStore(directory: store.directory).latestSaveDiagnostic())
    }

    func testPreparedSaveDiagnosticPersistenceFailureDoesNotMaskStorageFailureOrSuccess() throws {
        let initial = temporaryStore()
        defer { try? FileManager.default.removeItem(at: initial.directory) }
        let defaults = try XCTUnwrap(DiscardingDiagnosticDefaults(suiteName:
            "GlucoseForecastMLBackgroundTests." + initial.directory.lastPathComponent))
        let store = makeStore(directory: initial.directory, diagnosticDefaults: defaults)
        let invalid = snapshot(examples: examples(at: clock.addingTimeInterval(-3 * 3600),
                                                  featureValue: .nan))
        let failure = try saveFailure(invalid, store: store)
        XCTAssertEqual(failure.diagnostic.stage, .encoding)
        XCTAssertEqual(store.latestSaveDiagnostic(), failure.diagnostic)
        XCTAssertNil(makeStore(directory: initial.directory, diagnosticDefaults: defaults).latestSaveDiagnostic())
        let valid = snapshot()
        XCTAssertNoThrow(try store.save(valid))
        XCTAssertEqual(store.load(context: context(), at: clock)?.id, valid.id)
        XCTAssertNil(store.latestSaveDiagnostic())
    }

    func testPreparedSaveDiagnosticReadsDoNotWaitForSnapshotLock() throws {
        let initial = temporaryStore()
        defer { try? FileManager.default.removeItem(at: initial.directory) }
        let failure = try saveFailure(snapshot(examples: examples(at: clock.addingTimeInterval(-3 * 3600),
                                                                 featureValue: .nan)), store: initial)
        let requested = expectation(description: "save requests snapshot lock")
        let acquired = expectation(description: "save holds snapshot lock")
        let snapshotLock = GatedLock(requested: requested, acquired: acquired)
        let store = makeStore(directory: initial.directory, snapshotLock: snapshotLock)
        let saved = expectation(description: "save completes")
        let read = expectation(description: "diagnostic reads independently")
        let valid = snapshot()
        defer { snapshotLock.resume() }
        DispatchQueue.global().async {
            do { try store.save(valid) } catch { XCTFail("Synthetic snapshot save failed") }
            saved.fulfill()
        }
        wait(for: [requested, acquired], timeout: 2)
        DispatchQueue.global().async {
            XCTAssertEqual(store.latestSaveDiagnostic(), failure.diagnostic)
            read.fulfill()
        }
        wait(for: [read], timeout: 2)
        snapshotLock.resume()
        wait(for: [saved], timeout: 5)
    }

    func testPreparedSaveDiagnosticSurvivesPreparationLifecycleAndClearsAfterSuccessfulSave() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let failure = try saveFailure(snapshot(examples: examples(at: clock.addingTimeInterval(-3 * 3600),
                                                                 featureValue: .nan)), store: store)
        let coordinator = GlucoseForecastMLTrainingCoordinator(preparedStore: store, observeLifecycle: false)
        XCTAssertEqual(coordinator.saveDiagnosticText, failure.diagnostic.summaryText)
        let token = try XCTUnwrap(coordinator.beginPreparation(context: context(), force: true, at: clock))
        XCTAssertEqual(coordinator.saveDiagnosticText, failure.diagnostic.summaryText)
        coordinator.cancelForBackground()
        coordinator.finishPreparation("synthetic interrupted attempt", cancellation: token)
        XCTAssertEqual(coordinator.saveDiagnosticText, failure.diagnostic.summaryText)
        try store.save(snapshot())
        XCTAssertEqual(coordinator.saveDiagnosticText, "")
        XCTAssertNil(makeStore(directory: store.directory).latestSaveDiagnostic())
        XCTAssertNil(diagnosticDefaults(for: store.directory)
            .data(forKey: GlucoseForecastMLPreparedHistoryStore.diagnosticDefaultsKey))
    }
}
