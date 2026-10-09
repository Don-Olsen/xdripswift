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

    private func temporaryStore() -> GlucoseForecastMLPreparedHistoryStore {
        GlucoseForecastMLPreparedHistoryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("forecast-prepared-\(UUID().uuidString)", isDirectory: true))
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
        let restartedStore = GlucoseForecastMLPreparedHistoryStore(directory: store.directory)
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
        XCTAssertNil(GlucoseForecastMLPreparedHistoryStore(directory: store.directory)
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

        let restarted = GlucoseForecastMLPreparedHistoryStore(directory: store.directory)
        let oneHourLater = clock.addingTimeInterval(3600)
        XCTAssertEqual(restarted.nextAutomaticAttempt(context: source, at: oneHourLater),
                       clock.addingTimeInterval(24 * 3600))
        let afterRetry = clock.addingTimeInterval(25 * 3600)
        XCTAssertEqual(restarted.nextAutomaticAttempt(context: source, at: afterRetry), afterRetry)

        try restarted.recordAttempt(context: source, at: afterRetry, completed: true)
        let completedRestart = GlucoseForecastMLPreparedHistoryStore(directory: store.directory)
        XCTAssertEqual(completedRestart.nextAutomaticAttempt(
            context: source, at: afterRetry.addingTimeInterval(3600)),
            afterRetry.addingTimeInterval(GlucoseForecastMLChronology.modelAgeLimit))
        XCTAssertEqual(completedRestart.nextAutomaticAttempt(
            context: context(source: "new-source"), at: afterRetry.addingTimeInterval(3600)),
            afterRetry.addingTimeInterval(3600))
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
