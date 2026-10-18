import CoreData
import XCTest
@testable import xdrip

final class GlucoseForecastDataAdapterTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 2_000_000_000)

    @MainActor func testForecastInputRevisionIgnoresNoOpRefreshButTracksPendingAndCommittedTreatments() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let manager = TherapyMetricsManager()
        manager.configure(coreDataManager: core, externalStatus: { nil })
        let original = manager.forecastInputChangeRevision
        let broadRevision = manager.treatmentChangeRevision
        manager.invalidate(treatmentsChanged: false)
        manager.invalidate() // Health import materialization/status cache invalidation.
        XCTAssertEqual(manager.forecastInputChangeRevision, original)
        XCTAssertGreaterThan(manager.treatmentChangeRevision, broadRevision)
        _ = TreatmentEntry(date: Date(), value: 1, treatmentType: .Insulin,
            nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: core.mainManagedObjectContext)
        try core.mainManagedObjectContext.save()
        XCTAssertTrue(manager.hasUncommittedTreatmentChanges)
        XCTAssertGreaterThan(manager.forecastInputChangeRevision, original)
        let pending = manager.forecastInputChangeRevision
        manager.invalidate()
        XCTAssertEqual(manager.forecastInputChangeRevision, pending)
        XCTAssertTrue(manager.hasUncommittedTreatmentChanges)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertFalse(manager.hasUncommittedTreatmentChanges)
        XCTAssertGreaterThan(manager.forecastInputChangeRevision, pending)
        let committed = manager.forecastInputChangeRevision
        manager.invalidate(forecastInputsInvalidated: true)
        XCTAssertGreaterThan(manager.forecastInputChangeRevision, committed)
        let beforeStoreChange = manager.forecastInputChangeRevision
        manager.configure(coreDataManager: CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName),
                          externalStatus: { nil })
        XCTAssertGreaterThan(manager.forecastInputChangeRevision, beforeStoreChange)
    }

    @MainActor func testForecastInputRevisionTracksImportChildBeforeParentSave() async throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let manager = TherapyMetricsManager()
        manager.configure(coreDataManager: core, externalStatus: { nil })
        let original = manager.forecastInputChangeRevision
        let child = core.privateChildManagedObjectContext()
        try await child.perform {
            _ = TreatmentEntry(date: Date(), value: 1, treatmentType: .Insulin,
                nightscoutEventType: nil, enteredBy: "Synthetic import", nsManagedObjectContext: child)
            try child.save()
        }
        XCTAssertGreaterThan(manager.forecastInputChangeRevision, original)
        XCTAssertTrue(manager.hasUncommittedForecastInputChanges)
        let imported = manager.forecastInputChangeRevision
        manager.invalidate()
        XCTAssertTrue(manager.hasUncommittedForecastInputChanges,
                      "A cache/status invalidation cannot certify the pending imported treatment")
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertGreaterThan(manager.forecastInputChangeRevision, imported)
        XCTAssertFalse(manager.hasUncommittedForecastInputChanges)
    }

    @MainActor func testOlderWriterCommitCannotConfirmNewerImportChild() async throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let manager = TherapyMetricsManager()
        manager.configure(coreDataManager: core, externalStatus: { nil })
        _ = TreatmentEntry(date: Date(), value: 1, treatmentType: .Insulin,
            nightscoutEventType: nil, enteredBy: "A", nsManagedObjectContext: core.mainManagedObjectContext)
        try core.mainManagedObjectContext.save() // A is forwarded, but the writer has not saved it.
        let child = core.privateChildManagedObjectContext()
        try await child.perform {
            _ = TreatmentEntry(date: Date(), value: 2, treatmentType: .Insulin,
                nightscoutEventType: nil, enteredBy: "B", nsManagedObjectContext: child)
            try child.save() // B has reached main only, after A was forwarded.
        }
        XCTAssertTrue(manager.hasUncommittedForecastInputChanges)
        try await core.privateManagedObjectContext.perform {
            try core.privateManagedObjectContext.save() // This commit contains A, not B.
        }
        XCTAssertFalse(manager.hasUncommittedTreatmentChanges,
                       "The existing snapshot pending behavior remains unchanged")
        XCTAssertTrue(manager.hasUncommittedForecastInputChanges,
                      "A's writer commit must not confirm the still-unforwarded B treatment")
        manager.invalidate(committedTreatmentSave: true)
        XCTAssertTrue(manager.hasUncommittedForecastInputChanges,
                      "A cache invalidation is not writer-generation acknowledgement")
        XCTAssertTrue(core.saveChangesSynchronously()) // Forward and commit B.
        XCTAssertFalse(manager.hasUncommittedForecastInputChanges)
    }

    func testForecastWriterAcknowledgesOnlyGenerationCapturedAtWillSave() {
        var state = ForecastInputCommitState()
        state.mainDidSave() // A
        state.writerWillSave()
        state.childDidSave() // B arrives while writer A is in flight.
        state.mainDidSave() // Even forwarding B later cannot change writer A's snapshot.
        state.writerDidSaveTreatments()
        XCTAssertTrue(state.hasPendingChanges)
        state.writerDidSaveTreatments() // A repeated/unsupported acknowledgement cannot clear B.
        XCTAssertTrue(state.hasPendingChanges)
        state.writerWillSave()
        XCTAssertTrue(state.hasPendingChanges, "Starting a writer save does not prove success")
        state.writerDidSaveTreatments()
        XCTAssertFalse(state.hasPendingChanges)
    }

    func testForecastRequiresUserConfirmedSensitivityAndCarbohydrateRatio() throws {
        XCTAssertThrowsError(try GlucoseForecastDataAdapter.manualParameters(
            sensitivity: nil, ratio: 12).get()) { error in
            XCTAssertEqual(error as? GlucoseForecastUnavailableReason, .missingProfile)
        }
        for pair in [(0.0, 12.0), (45.0, -1.0), (Double.nan, 10.0), (40.0, Double.infinity)] {
            XCTAssertThrowsError(try GlucoseForecastDataAdapter.manualParameters(
                sensitivity: pair.0, ratio: pair.1).get()) { error in
                XCTAssertEqual(error as? GlucoseForecastUnavailableReason, .invalidProfile)
            }
        }
        let valid = try GlucoseForecastDataAdapter.manualParameters(sensitivity: 54, ratio: 11).get()
        XCTAssertEqual(valid.sensitivity, 54)
        XCTAssertEqual(valid.ratio, 11)
    }

    func testExternalStatusOwnershipCannotFallBackToLocalTreatmentHistory() {
        func policy(_ therapy: TherapyDataSourceType, follow: NightscoutFollowType,
                    master: Bool = true) -> DataFlowPolicy {
            DataFlowPolicy(isMaster: master, followerDataSource: .careLink,
                           therapyDataSourceSelection: therapy,
                           nightscoutEnabled: therapy == .nightscout,
                           masterUploadsGlucoseToNightscout: false,
                           followerUploadsGlucoseToNightscout: false,
                           nightscoutFollowType: follow)
        }
        XCTAssertTrue(GlucoseForecastDataAdapter.sourceAllowsForecast(policy(.none, follow: .none)))
        XCTAssertTrue(GlucoseForecastDataAdapter.sourceAllowsForecast(policy(.nightscout, follow: .none)))
        XCTAssertFalse(GlucoseForecastDataAdapter.sourceAllowsForecast(policy(.nightscout, follow: .loop)))
        XCTAssertFalse(GlucoseForecastDataAdapter.sourceAllowsForecast(policy(.careLink, follow: .none, master: false)))
    }

    func testBucketedTreatmentFetchCannotIncludeFutureOrOutOfWindowEntries() {
        let start = referenceDate.addingTimeInterval(-600 * 60)
        let old = TherapyTreatment(date: start.addingTimeInterval(-1), amount: 1, isIOB: true)
        let bolus = TherapyTreatment(date: referenceDate.addingTimeInterval(-60), amount: 2, isIOB: true)
        let meal = TherapyTreatment(date: referenceDate, amount: 25, isIOB: false)
        let future = TherapyTreatment(date: referenceDate.addingTimeInterval(60), amount: 3, isIOB: true)
        let result = GlucoseForecastDataAdapter.treatmentsKnownAtReference(
            [old, bolus, meal, future], from: start, referenceDate: referenceDate)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.map(\.date), [bolus.date, meal.date])
    }

    @MainActor func testGlucoseHistoryUsesDownstreamValidSameSourceFinalValues() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let sensorA = Sensor(startDate: referenceDate.addingTimeInterval(-3600),
                             nsManagedObjectContext: core.mainManagedObjectContext)
        let sensorB = Sensor(startDate: referenceDate.addingTimeInterval(-1800),
                             nsManagedObjectContext: core.mainManagedObjectContext)
        func add(_ minutesAgo: Double, value: Double, sensor: Sensor?,
                 suppressed: Bool = false) {
            let reading = BgReading(timeStamp: referenceDate.addingTimeInterval(-minutesAgo * 60),
                                    sensor: sensor, calibration: nil, rawData: value,
                                    deviceName: "Libre 2 Plus", nsManagedObjectContext: core.mainManagedObjectContext)
            reading.calculatedValue = value
            reading.isSuppressedByFiveMinuteCadence = suppressed
        }
        add(5, value: 100, sensor: sensorA)
        add(4, value: 101, sensor: sensorA, suppressed: true)
        add(3, value: 0, sensor: sensorA)
        add(2, value: 96, sensor: sensorB)
        add(0, value: 110, sensor: sensorA)
        XCTAssertTrue(core.saveChangesSynchronously())
        let adapter = GlucoseForecastDataAdapter(coreDataManager: core)
        let samples = adapter.recentGlucose(at: referenceDate)
        XCTAssertEqual(samples?.map(\.glucoseMgdl), [100, 110])
        XCTAssertEqual(samples?.map(\.date), [referenceDate.addingTimeInterval(-300), referenceDate])
        add(-1, value: 111, sensor: nil)
        XCTAssertTrue(core.saveChangesSynchronously())
        let unidentified = adapter.recentGlucose(at: referenceDate.addingTimeInterval(60))
        XCTAssertEqual(unidentified?.count, 1)
        XCTAssertEqual(unidentified?.last?.glucoseMgdl, 111)
        add(-2, value: 0, sensor: sensorB)
        XCTAssertTrue(core.saveChangesSynchronously())
        let invalidNewest = adapter.recentGlucose(at: referenceDate.addingTimeInterval(120))
        XCTAssertTrue(invalidNewest?.isEmpty == true)
    }

    @MainActor func testNewerHiddenAndInvalidSameSensorRowsKeepFreshVisibleReading() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let sensor = Sensor(startDate: referenceDate.addingTimeInterval(-3600),
                            nsManagedObjectContext: core.mainManagedObjectContext)
        func add(_ date: Date, value: Double, suppressed: Bool = false) {
            let reading = BgReading(timeStamp: date, sensor: sensor, calibration: nil,
                                    rawData: value, deviceName: "Libre 2 Plus",
                                    nsManagedObjectContext: core.mainManagedObjectContext)
            reading.calculatedValue = value
            reading.isSuppressedByFiveMinuteCadence = suppressed
        }
        for minute in stride(from: -30, through: 0, by: 5) {
            add(referenceDate.addingTimeInterval(Double(minute * 60)), value: 110)
        }
        for minute in 1...4 {
            add(referenceDate.addingTimeInterval(Double(minute * 60)),
                value: 111, suppressed: true)
        }
        add(referenceDate.addingTimeInterval(4.5 * 60), value: 0)
        XCTAssertTrue(core.saveChangesSynchronously())
        let samples = GlucoseForecastDataAdapter(coreDataManager: core)
            .recentGlucose(at: referenceDate.addingTimeInterval(4.5 * 60))
        XCTAssertEqual(samples?.count, 7)
        XCTAssertEqual(samples?.last?.date, referenceDate)
        XCTAssertEqual(samples?.last?.sensorID, sensor.id)
        let homeReading = BgReadingsAccessor(coreDataManager: core)
            .get2LatestBgReadings(minimumTimeIntervalInMinutes: 1).first
        XCTAssertEqual(samples?.last?.date, homeReading?.timeStamp)
        XCTAssertTrue(RootHomeForecastFreshness.isCurrent(
            referenceDate: referenceDate, at: referenceDate.addingTimeInterval(4.5 * 60)))
    }

    @MainActor func testNewerInvalidDifferentOrUnknownSensorNeverReusesOldHistory() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let sensorA = Sensor(startDate: referenceDate.addingTimeInterval(-3600),
                             nsManagedObjectContext: core.mainManagedObjectContext)
        let sensorB = Sensor(startDate: referenceDate.addingTimeInterval(-1800),
                             nsManagedObjectContext: core.mainManagedObjectContext)
        func add(_ seconds: TimeInterval, value: Double, sensor: Sensor?) {
            let reading = BgReading(timeStamp: referenceDate.addingTimeInterval(seconds),
                                    sensor: sensor, calibration: nil, rawData: value,
                                    deviceName: "Libre 2 Plus",
                                    nsManagedObjectContext: core.mainManagedObjectContext)
            reading.calculatedValue = value
        }
        add(0, value: 110, sensor: sensorA)
        add(60, value: 0, sensor: sensorB)
        XCTAssertTrue(core.saveChangesSynchronously())
        let adapter = GlucoseForecastDataAdapter(coreDataManager: core)
        XCTAssertTrue(adapter.recentGlucose(at: referenceDate.addingTimeInterval(60))?.isEmpty == true)
        add(120, value: 0, sensor: nil)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertTrue(adapter.recentGlucose(at: referenceDate.addingTimeInterval(120))?.isEmpty == true)
    }

    @MainActor func testDuplicateLatestTimeCannotChooseArbitrarySensorOrValue() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let sensorA = Sensor(startDate: referenceDate.addingTimeInterval(-3600),
                             nsManagedObjectContext: core.mainManagedObjectContext)
        let sensorB = Sensor(startDate: referenceDate.addingTimeInterval(-1800),
                             nsManagedObjectContext: core.mainManagedObjectContext)
        func add(_ value: Double, sensor: Sensor) {
            let reading = BgReading(timeStamp: referenceDate, sensor: sensor, calibration: nil,
                                    rawData: value, deviceName: "Libre 2 Plus",
                                    nsManagedObjectContext: core.mainManagedObjectContext)
            reading.calculatedValue = value
        }
        add(110, sensor: sensorA)
        add(111, sensor: sensorB)
        XCTAssertTrue(core.saveChangesSynchronously())
        let adapter = GlucoseForecastDataAdapter(coreDataManager: core)
        XCTAssertTrue(adapter.recentGlucose(at: referenceDate)?.isEmpty == true)
    }

    @MainActor func testInvalidPeerAtVisibleAnchorStillBlocksAmbiguousPrediction() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let sensor = Sensor(startDate: referenceDate.addingTimeInterval(-3600),
                            nsManagedObjectContext: core.mainManagedObjectContext)
        func add(_ seconds: TimeInterval, value: Double, suppressed: Bool = false) {
            let reading = BgReading(timeStamp: referenceDate.addingTimeInterval(seconds),
                                    sensor: sensor, calibration: nil, rawData: value,
                                    deviceName: "Libre 2 Plus",
                                    nsManagedObjectContext: core.mainManagedObjectContext)
            reading.calculatedValue = value
            reading.isSuppressedByFiveMinuteCadence = suppressed
        }
        add(0, value: 110)
        add(0, value: 0)
        add(60, value: 111, suppressed: true)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertTrue(GlucoseForecastDataAdapter(coreDataManager: core)
            .recentGlucose(at: referenceDate.addingTimeInterval(60))?.isEmpty == true)
    }

    func testSimultaneousNightscoutAndHealthKitTreatmentImportsAreAmbiguous() {
        let nightscout = DataFlowPolicy(isMaster: true, followerDataSource: .careLink,
                                         therapyDataSourceSelection: .nightscout,
                                         nightscoutEnabled: true,
                                         masterUploadsGlucoseToNightscout: false,
                                         followerUploadsGlucoseToNightscout: false,
                                         nightscoutFollowType: .none)
        XCTAssertFalse(GlucoseForecastDataAdapter.treatmentSourcesAreUnambiguous(
            nightscout, healthInsulinEnabled: true, healthCarbsEnabled: false))
        XCTAssertFalse(GlucoseForecastDataAdapter.treatmentSourcesAreUnambiguous(
            nightscout, healthInsulinEnabled: false, healthCarbsEnabled: true))
        XCTAssertTrue(GlucoseForecastDataAdapter.treatmentSourcesAreUnambiguous(
            nightscout, healthInsulinEnabled: false, healthCarbsEnabled: false))
        let local = DataFlowPolicy(isMaster: true, followerDataSource: .careLink,
                                   therapyDataSourceSelection: .none,
                                   nightscoutEnabled: false,
                                   masterUploadsGlucoseToNightscout: false,
                                   followerUploadsGlucoseToNightscout: false,
                                   nightscoutFollowType: .none)
        XCTAssertTrue(GlucoseForecastDataAdapter.treatmentSourcesAreUnambiguous(
            local, healthInsulinEnabled: true, healthCarbsEnabled: true))
    }

    func testNewlyRecordedTreatmentAfterReadingMustWaitForNextCGM() {
        let before = TherapyTreatment(date: referenceDate.addingTimeInterval(-60), amount: 1, isIOB: true)
        let later = TherapyTreatment(date: referenceDate.addingTimeInterval(120), amount: 2, isIOB: true)
        let future = TherapyTreatment(date: referenceDate.addingTimeInterval(600), amount: 10, isIOB: false)
        XCTAssertTrue(GlucoseForecastDataAdapter.hasTreatmentAfterReading(
            [before, later, future], referenceDate: referenceDate,
            calculationDate: referenceDate.addingTimeInterval(180)))
        XCTAssertFalse(GlucoseForecastDataAdapter.hasTreatmentAfterReading(
            [before, later, future], referenceDate: referenceDate.addingTimeInterval(180),
            calculationDate: referenceDate.addingTimeInterval(240)))
        XCTAssertFalse(GlucoseForecastDataAdapter.hasTreatmentAfterReading(
            [before, later, future], referenceDate: referenceDate,
            calculationDate: referenceDate.addingTimeInterval(60)))
    }
    @MainActor func testLoggingDoesNotTurnDisabledFeatureIntoFailedAttempt() async {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let captured = ForecastAdapterLogCapture()
        let adapter = GlucoseForecastDataAdapter(coreDataManager: core, logForecast: captured.append)
        let result = await adapter.forecast(horizonMinutes: 0)
        XCTAssertEqual(result.reason, .dataUnavailable)
        XCTAssertEqual(captured.count, 0)
        let invalid = await adapter.forecast(horizonMinutes: 35)
        XCTAssertEqual(invalid.reason, .invalidHorizon)
        XCTAssertNil(invalid.referenceDate)
        XCTAssertEqual(captured.count, 1)
    }

    @MainActor func testCancelledQueuedPresentationSkipsReadsAndLogThenLiveRequestStillCalculates() async throws {
        let fixture = try makeCancellationFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let queued = expectation(description: "Presentation is queued behind existing work")
        let completed = expectation(description: "Cancelled continuation resumes")
        let releaseWorker = DispatchSemaphore(value: 0)
        defer { releaseWorker.signal() }
        let worker = DispatchQueue(label: "test.forecast.queued-cancellation")
        worker.async { XCTAssertEqual(releaseWorker.wait(timeout: .now() + 5), .success) }
        let probe = ForecastAdapterCancellationProbe()
        let captured = ForecastAdapterLogCapture()
        let adapter = GlucoseForecastDataAdapter(coreDataManager: fixture.core,
            therapyManager: fixture.therapy, defaults: fixture.defaults,
            healthImporter: fixture.importer, logForecast: captured.append,
            enqueuePresentation: { work in
                worker.async(execute: work)
                if probe.didEnqueue() == 1 { queued.fulfill() }
            }, presentationGlucoseFetch: { context, request in
                probe.didRead()
                return try context.fetch(request)
            })
        let date = referenceDate
        let task = Task {
            probe.store(await adapter.forecastForPresentation(horizonMinutes: 60, at: date))
            completed.fulfill()
        }
        defer { task.cancel() }
        await fulfillment(of: [queued], timeout: 3)
        task.cancel()
        releaseWorker.signal()
        await fulfillment(of: [completed], timeout: 3)
        let cancelled = try XCTUnwrap(probe.outcome)
        XCTAssertEqual(cancelled.result.reason, .dataUnavailable)
        XCTAssertTrue(cancelled.result.points.isEmpty)
        XCTAssertNil(cancelled.conditionalPlannedPoints)
        XCTAssertNil(cancelled.logSnapshot)
        XCTAssertEqual(probe.readCount, 0, "Cancelled queued work must never enter Core Data")
        XCTAssertEqual(captured.count, 0, "Cancellation is not prospective failure evidence")

        let live = await adapter.forecastForPresentation(horizonMinutes: 60, at: date)
        let expected = GlucoseForecastEngine.predict(GlucoseForecastInput(
            glucose: try XCTUnwrap(adapter.recentGlucose(at: date)), treatments: [],
            settings: TherapyModelSettings(defaults: fixture.defaults),
            sensitivityMgdlPerUnit: 36, carbohydrateRatioGramsPerUnit: 10,
            horizonMinutes: 60, now: date))
        XCTAssertNil(live.result.reason)
        XCTAssertEqual(live.result.points, expected.points)
        XCTAssertEqual(probe.readCount, 1)
        XCTAssertEqual(captured.count, 1)
        let cached = await adapter.forecastForPresentation(horizonMinutes: 60, at: date)
        XCTAssertEqual(cached.result.points, live.result.points)
        XCTAssertEqual(captured.count, 1, "A completed request keeps the existing log/cache behavior")
    }

    @MainActor func testCancellationDuringGlucoseReadDiscardsSuccessfulAndFailedReadsWithoutLogging() async throws {
        for failRead in [false, true] {
            let fixture = try makeCancellationFixture()
            defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
            let reading = expectation(description: "Glucose fetch has started")
            let completed = expectation(description: "In-flight cancelled continuation resumes")
            let releaseRead = DispatchSemaphore(value: 0)
            defer { releaseRead.signal() }
            let probe = ForecastAdapterCancellationProbe()
            let captured = ForecastAdapterLogCapture()
            let adapter = GlucoseForecastDataAdapter(coreDataManager: fixture.core,
                therapyManager: fixture.therapy, defaults: fixture.defaults,
                healthImporter: fixture.importer, logForecast: captured.append,
                presentationGlucoseFetch: { context, request in
                    probe.didRead()
                    reading.fulfill()
                    XCTAssertEqual(releaseRead.wait(timeout: .now() + 5), .success)
                    if failRead { throw ForecastAdapterSyntheticReadError.unavailable }
                    return try context.fetch(request)
                })
            let date = referenceDate
            let task = Task {
                probe.store(await adapter.forecastForPresentation(horizonMinutes: 60, at: date))
                completed.fulfill()
            }
            defer { task.cancel() }
            await fulfillment(of: [reading], timeout: 3)
            task.cancel()
            releaseRead.signal()
            await fulfillment(of: [completed], timeout: 3)
            let cancelled = try XCTUnwrap(probe.outcome)
            XCTAssertEqual(cancelled.result.reason, .dataUnavailable)
            XCTAssertTrue(cancelled.result.points.isEmpty)
            XCTAssertNil(cancelled.result.referenceDate)
            XCTAssertNil(cancelled.result.mlForecast)
            XCTAssertNil(cancelled.conditionalPlannedPoints)
            XCTAssertNil(cancelled.logSnapshot)
            XCTAssertEqual(probe.readCount, 1)
            XCTAssertEqual(captured.count, 0,
                "Neither a successful nor failed read may log a cancelled request")
        }
    }

    @MainActor func testAlreadyCancelledPresentationDoesNotQueueOrLogInvalidInput() async throws {
        let fixture = try makeCancellationFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let captured = ForecastAdapterLogCapture()
        let adapter = GlucoseForecastDataAdapter(coreDataManager: fixture.core,
            therapyManager: fixture.therapy, defaults: fixture.defaults,
            healthImporter: fixture.importer, logForecast: captured.append,
            enqueuePresentation: { _ in XCTFail("An already cancelled request must not queue work") })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await adapter.forecastForPresentation(horizonMinutes: 35)
        }
        let cancelled = await task.value
        XCTAssertEqual(cancelled.result.reason, .dataUnavailable)
        XCTAssertTrue(cancelled.result.points.isEmpty)
        XCTAssertEqual(captured.count, 0)
    }

    @MainActor func testPresentationEvidenceCapturesMLOncePerCallEvenWhenEngineCacheIsReused() async throws {
        for horizon in [60, 120] {
            let fixture = try makeCancellationFixture()
            defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
            fixture.defaults.set(referenceDate, forKey: LowSoonAlertState.lastScheduledDefaultsKey)
            let inference = ForecastAdapterMLCapture()
            let captured = ForecastAdapterLogCapture()
            let adapter = GlucoseForecastDataAdapter(coreDataManager: fixture.core,
                therapyManager: fixture.therapy, defaults: fixture.defaults,
                healthImporter: fixture.importer, logForecast: captured.append,
                mlInference: { input, engine, source in
                    let call = inference.record(input, source: source)
                    return ForecastAdapterMLCapture.forecast(engine, modelID: "synthetic-model-\(call)")
                })
            let first = await adapter.forecastForPresentation(horizonMinutes: horizon, at: referenceDate)
            let cached = await adapter.forecastForPresentation(horizonMinutes: horizon, at: referenceDate)
            XCTAssertNil(first.result.reason)
            XCTAssertNil(cached.result.reason)
            XCTAssertEqual(inference.count, 2, "Evidence capture must not request an extra ML inference")
            XCTAssertEqual(captured.count, 1, "A cache hit retains the existing one-time engine baseline")
            XCTAssertEqual(captured.snapshots.first?.recordType, .forecast)
            XCTAssertNil(captured.snapshots.first?.presentation)
            XCTAssertEqual(first.result.points, cached.result.points)
            for (index, outcome) in [first, cached].enumerated() {
                let snapshot = try XCTUnwrap(outcome.logSnapshot)
                let presentation = try XCTUnwrap(snapshot.presentation)
                XCTAssertEqual(snapshot.recordType, .presentation)
                XCTAssertEqual(snapshot.horizonMinutes, horizon)
                XCTAssertEqual(presentation.modelID, "synthetic-model-\(index + 1)")
                XCTAssertNil(presentation.presentedAt)
                XCTAssertEqual(snapshot.points.map(\.glucoseMgdl), outcome.result.points.map(\.glucoseMgdl))
                XCTAssertEqual(presentation.displayedPoints.map(\.glucoseMgdl),
                    GlucoseForecastMLPresentation.points(in: outcome.result).map(\.glucoseMgdl))
                XCTAssertEqual(presentation.mlBeforeCapPoints?.first?.glucoseMgdl, 140)
                XCTAssertEqual(presentation.mlBeforeCapPoints?.last?.glucoseMgdl, 165)
                XCTAssertEqual(presentation.displayedPoints.last?.glucoseMgdl, 140)
                XCTAssertEqual(snapshot.inputs?.glucose.count, 7)
                XCTAssertEqual(snapshot.inputs?.treatments.count, 0)
                XCTAssertEqual(snapshot.parameters.sensitivityMgdlPerUnit, 36)
                XCTAssertNotNil(snapshot.confirmingPresentation(of: outcome.result,
                    at: snapshot.computedAt.addingTimeInterval(1)))
            }
            XCTAssertEqual(inference.sources.count, 2)
            XCTAssertEqual(Set(inference.sources).count, 1)
            XCTAssertEqual(inference.inputs.map(\.horizonMinutes), [horizon, horizon])
            XCTAssertEqual(inference.inputs.map(\.now), [referenceDate, referenceDate])
        }
    }

    @MainActor func testQueuedSettingsChangeKeepsFrozenInputsAndEngineFallbackEvidence() async throws {
        let fixture = try makeCancellationFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        _ = TreatmentEntry(date: referenceDate.addingTimeInterval(-300), value: 1,
            treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "Synthetic",
            nsManagedObjectContext: fixture.core.mainManagedObjectContext)
        XCTAssertTrue(fixture.core.saveChangesSynchronously())
        let originalSettings = TherapyModelSettings(defaults: fixture.defaults)
        let queued = expectation(description: "Settings were captured before queued work")
        let releaseWorker = DispatchSemaphore(value: 0)
        defer { releaseWorker.signal() }
        let worker = DispatchQueue(label: "test.forecast.frozen-evidence")
        worker.async { XCTAssertEqual(releaseWorker.wait(timeout: .now() + 5), .success) }
        let captured = ForecastAdapterLogCapture()
        let inference = ForecastAdapterMLCapture()
        let adapter = GlucoseForecastDataAdapter(coreDataManager: fixture.core,
            therapyManager: fixture.therapy, defaults: fixture.defaults,
            healthImporter: fixture.importer, logForecast: captured.append,
            enqueuePresentation: { work in worker.async(execute: work); queued.fulfill() },
            mlInference: { input, result, source in
                inference.record(input, source: source)
                return ForecastAdapterMLCapture.forecast(result)
            })
        let date = referenceDate
        let task = Task { await adapter.forecastForPresentation(horizonMinutes: 60, at: date) }
        defer { task.cancel() }
        await fulfillment(of: [queued], timeout: 3)
        fixture.defaults.glucoseForecastManualSensitivityMgdlPerUnit = 72
        fixture.defaults.glucoseForecastManualCarbRatioGramsPerUnit = 15
        releaseWorker.signal()
        let outcome = await task.value
        XCTAssertNil(outcome.result.reason)
        XCTAssertNil(outcome.result.mlForecast, "The changed source signature prevents selecting a different-settings model")
        XCTAssertEqual(inference.count, 0)
        let snapshot = try XCTUnwrap(outcome.logSnapshot)
        let evidence = try XCTUnwrap(snapshot.presentation)
        XCTAssertEqual(snapshot.parameters.sensitivityMgdlPerUnit, 36)
        XCTAssertEqual(snapshot.parameters.carbohydrateRatioGramsPerUnit, 10)
        XCTAssertEqual(snapshot.inputs?.calculationDate, referenceDate)
        XCTAssertEqual(snapshot.inputs?.treatments.count, 1)
        XCTAssertEqual(snapshot.inputs?.treatments.first?.amount, 1)
        XCTAssertNil(evidence.modelID)
        XCTAssertNil(evidence.mlBeforeCapPoints)
        XCTAssertEqual(evidence.displayedPoints.map(\.glucoseMgdl), outcome.result.points.map(\.glucoseMgdl))
        let expected = GlucoseForecastEngine.predict(GlucoseForecastInput(
            glucose: try XCTUnwrap(adapter.recentGlucose(at: date)),
            treatments: [TherapyTreatment(date: date.addingTimeInterval(-300), amount: 1, isIOB: true)],
            settings: originalSettings, sensitivityMgdlPerUnit: 36,
            carbohydrateRatioGramsPerUnit: 10, horizonMinutes: 60, now: date))
        XCTAssertEqual(outcome.result.points, expected.points)
        let bytes = try GlucoseForecastLogSnapshot.encoder().encode(snapshot)
        fixture.defaults.glucoseForecastManualSensitivityMgdlPerUnit = 90
        XCTAssertEqual(try GlucoseForecastLogSnapshot.encoder().encode(snapshot), bytes)
        XCTAssertNotNil(snapshot.confirmingPresentation(of: outcome.result, at: snapshot.computedAt.addingTimeInterval(1)))
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.snapshots.first?.parameters.sensitivityMgdlPerUnit, 36)
    }

    @MainActor func testUnavailableOrRejectedMLLeavesNoRawMLInEngineFallbackEvidence() async throws {
        for invalidKind in ["unavailable", "count", "date"] {
            let fixture = try makeCancellationFixture()
            defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
            let captured = ForecastAdapterLogCapture()
            let inference = ForecastAdapterMLCapture()
            let adapter = GlucoseForecastDataAdapter(coreDataManager: fixture.core,
                therapyManager: fixture.therapy, defaults: fixture.defaults,
                healthImporter: fixture.importer, logForecast: captured.append,
                mlInference: { input, result, source in
                    inference.record(input, source: source)
                    guard invalidKind != "unavailable" else { return nil }
                    let candidate = ForecastAdapterMLCapture.forecast(result)
                    var points = candidate.points
                    if invalidKind == "count" { points.removeLast() }
                    else { points[1] = .init(date: points[1].date.addingTimeInterval(1), glucoseMgdl: points[1].glucoseMgdl) }
                    return .init(points: points, band: candidate.band, modelID: candidate.modelID)
                })
            let outcome = await adapter.forecastForPresentation(horizonMinutes: 60, at: referenceDate)
            XCTAssertNil(outcome.result.reason)
            XCTAssertNil(outcome.result.mlForecast)
            XCTAssertEqual(inference.count, 1)
            XCTAssertEqual(captured.count, 1)
            let snapshot = try XCTUnwrap(outcome.logSnapshot)
            let evidence = try XCTUnwrap(snapshot.presentation)
            XCTAssertNil(evidence.modelID)
            XCTAssertNil(evidence.mlBeforeCapPoints, "An ML candidate rejected by presentation safety was never displayed")
            XCTAssertEqual(evidence.displayedPoints.map(\.glucoseMgdl), outcome.result.points.map(\.glucoseMgdl))
            XCTAssertEqual(outcome.result.points.map(\.glucoseMgdl), Array(repeating: 140, count: 13))
            XCTAssertEqual(snapshot.recordType, .presentation)
        }
    }

    @MainActor func testCancellationDuringInferenceReturnsNoPresentationEvidenceAndLiveCacheCanRetry() async throws {
        let fixture = try makeCancellationFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let entered = expectation(description: "ML inference entered")
        let releaseInference = DispatchSemaphore(value: 0)
        defer { releaseInference.signal() }
        let captured = ForecastAdapterLogCapture()
        let inference = ForecastAdapterMLCapture()
        let adapter = GlucoseForecastDataAdapter(coreDataManager: fixture.core,
            therapyManager: fixture.therapy, defaults: fixture.defaults,
            healthImporter: fixture.importer, logForecast: captured.append,
            mlInference: { input, result, source in
                if inference.record(input, source: source) == 1 {
                    entered.fulfill()
                    XCTAssertEqual(releaseInference.wait(timeout: .now() + 5), .success)
                }
                return ForecastAdapterMLCapture.forecast(result)
            })
        let date = referenceDate
        let task = Task { await adapter.forecastForPresentation(horizonMinutes: 60, at: date) }
        defer { task.cancel() }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel()
        releaseInference.signal()
        let cancelled = await task.value
        XCTAssertEqual(cancelled.result.reason, .dataUnavailable)
        XCTAssertTrue(cancelled.result.points.isEmpty)
        XCTAssertNil(cancelled.result.mlForecast)
        XCTAssertNil(cancelled.logSnapshot)
        XCTAssertNil(cancelled.conditionalPlannedPoints)
        XCTAssertEqual(inference.count, 1)
        XCTAssertEqual(captured.count, 1, "The engine baseline completed before inference began")
        XCTAssertTrue(captured.snapshots.allSatisfy { $0.recordType == .forecast && $0.presentation == nil })
        let live = await adapter.forecastForPresentation(horizonMinutes: 60, at: date)
        XCTAssertNil(live.result.reason)
        XCTAssertNotNil(live.logSnapshot)
        XCTAssertEqual(live.logSnapshot?.presentation?.modelID, "synthetic-model")
        XCTAssertEqual(inference.count, 2)
        XCTAssertEqual(captured.count, 1, "Retry reuses the completed engine cache without a second baseline")
    }

    @MainActor private func makeCancellationFixture() throws -> (
        suite: String, defaults: UserDefaults, core: CoreDataManager,
        therapy: TherapyMetricsManager, importer: HealthKitTherapyImportManager
    ) {
        let suite = "ForecastAdapterCancellation-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.isMaster = true
        defaults.therapyDataSourceType = .none
        defaults.nightscoutEnabled = false
        defaults.glucoseForecastManualSensitivityMgdlPerUnit = 36
        defaults.glucoseForecastManualCarbRatioGramsPerUnit = 10
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let sensor = Sensor(startDate: referenceDate.addingTimeInterval(-3600),
                            nsManagedObjectContext: core.mainManagedObjectContext)
        for minute in stride(from: -30, through: 0, by: 5) {
            let reading = BgReading(timeStamp: referenceDate.addingTimeInterval(Double(minute * 60)),
                sensor: sensor, calibration: nil, rawData: 140,
                deviceName: "Synthetic", nsManagedObjectContext: core.mainManagedObjectContext)
            reading.calculatedValue = 140
        }
        XCTAssertTrue(core.saveChangesSynchronously())
        let therapy = TherapyMetricsManager()
        therapy.configure(coreDataManager: core, externalStatus: { nil })
        let importer = HealthKitTherapyImportManager(query: ForecastAdapterNoHealthQuery(), defaults: defaults)
        return (suite, defaults, core, therapy, importer)
    }

    @MainActor func testCompletedCalculationLogsOncePerCacheAndSettingsStillRefreshUI() async throws {
        let suite = "ForecastAdapterLogging-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.isMaster = true
        defaults.therapyDataSourceType = .none
        defaults.nightscoutEnabled = false
        defaults.glucoseForecastManualSensitivityMgdlPerUnit = 36
        defaults.glucoseForecastManualCarbRatioGramsPerUnit = 10
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 60) * 60)
        let sensor = Sensor(startDate: date.addingTimeInterval(-3600),
                            nsManagedObjectContext: core.mainManagedObjectContext)
        for minute in stride(from: -30, through: 0, by: 5) {
            let reading = BgReading(timeStamp: date.addingTimeInterval(Double(minute * 60)),
                                    sensor: sensor, calibration: nil, rawData: 140,
                                    deviceName: "Synthetic", nsManagedObjectContext: core.mainManagedObjectContext)
            reading.calculatedValue = 140
        }
        _ = TreatmentEntry(date: date.addingTimeInterval(-300), value: 1,
                           treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "Synthetic",
                           nsManagedObjectContext: core.mainManagedObjectContext)
        XCTAssertTrue(core.saveChangesSynchronously())
        let therapy = TherapyMetricsManager()
        therapy.configure(coreDataManager: core, externalStatus: { nil })
        let captured = ForecastAdapterLogCapture()
        let adapter = GlucoseForecastDataAdapter(coreDataManager: core, therapyManager: therapy,
                                                defaults: defaults, logForecast: captured.append)
        let first = await adapter.forecast(horizonMinutes: 60, at: date)
        XCTAssertNil(first.reason)
        XCTAssertEqual(captured.count, 1)
        let cached = await adapter.forecast(horizonMinutes: 60, at: date)
        XCTAssertEqual(cached.points, first.points)
        XCTAssertEqual(captured.count, 1)
        defaults.glucoseForecastManualSensitivityMgdlPerUnit = 45
        let changed = await adapter.forecast(horizonMinutes: 60, at: date)
        XCTAssertNil(changed.reason)
        XCTAssertNotEqual(changed.points, first.points)
        // The store independently preserves the first valid record. It must not freeze the UI.
        XCTAssertEqual(captured.count, 2)
    }

}


private final class ForecastAdapterLogCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [GlucoseForecastLogSnapshot] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return records.count }
    var snapshots: [GlucoseForecastLogSnapshot] { lock.lock(); defer { lock.unlock() }; return records }
    func append(_ snapshot: GlucoseForecastLogSnapshot) {
        lock.lock(); defer { lock.unlock() }; records.append(snapshot)
    }
}

private enum ForecastAdapterSyntheticReadError: Error { case unavailable }

private final class ForecastAdapterCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var enqueued = 0
    private var reads = 0
    private var result: GlucoseForecastPresentationOutcome?

    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var outcome: GlucoseForecastPresentationOutcome? { lock.lock(); defer { lock.unlock() }; return result }
    func didEnqueue() -> Int {
        lock.lock(); defer { lock.unlock() }
        enqueued += 1
        return enqueued
    }
    func didRead() { lock.lock(); defer { lock.unlock() }; reads += 1 }
    func store(_ outcome: GlucoseForecastPresentationOutcome) {
        lock.lock(); defer { lock.unlock() }; result = outcome
    }
}

private final class ForecastAdapterNoHealthQuery: HealthTherapyQuerying {
    func requestReadAuthorization(for kind: HealthTherapyImportKind,
                                  completion: @escaping (Error?) -> Void) {
        XCTFail("Synthetic presentation tests must not request Health authorization")
        completion(ForecastAdapterSyntheticReadError.unavailable)
    }
    func discoverSources(for kind: HealthTherapyImportKind,
                         completion: @escaping ([HealthTherapyImportSource], Error?) -> Void) {
        XCTFail("Synthetic presentation tests must not read Health sources")
        completion([], ForecastAdapterSyntheticReadError.unavailable)
    }
    func page(for kind: HealthTherapyImportKind, since: Date, anchor: Data?, limit: Int,
              completion: @escaping (Result<HealthTherapyImportPage, Error>) -> Void) {
        XCTFail("Synthetic presentation tests must not read Health samples")
        completion(.failure(ForecastAdapterSyntheticReadError.unavailable))
    }
    func observe(_ kind: HealthTherapyImportKind,
                 onChange: @escaping (@escaping () -> Void) -> Void) {
        XCTFail("Synthetic presentation tests must not observe Health")
    }
}


private final class ForecastAdapterMLCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedInputs = [GlucoseForecastInput]()
    private var recordedSources = [String]()
    var count: Int { lock.lock(); defer { lock.unlock() }; return recordedInputs.count }
    var inputs: [GlucoseForecastInput] { lock.lock(); defer { lock.unlock() }; return recordedInputs }
    var sources: [String] { lock.lock(); defer { lock.unlock() }; return recordedSources }
    @discardableResult func record(_ input: GlucoseForecastInput, source: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        recordedInputs.append(input); recordedSources.append(source)
        return recordedInputs.count
    }
    static func forecast(_ engine: GlucoseForecastResult, modelID: String = "synthetic-model") -> GlucoseForecastMLForecast {
        let points = engine.points.enumerated().map { index, point in
            GlucoseForecastPoint(date: point.date, glucoseMgdl: point.glucoseMgdl + (index == 0 ? 0 : 25))
        }
        return .init(points: points, band: points.map {
            .init(date: $0.date, lowerMgdl: $0.glucoseMgdl - 10, upperMgdl: $0.glucoseMgdl + 10)
        }, modelID: modelID)
    }
}
