import CoreData
import XCTest
@testable import xdrip

final class GlucoseForecastDataAdapterTests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 2_000_000_000)

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
    func append(_ snapshot: GlucoseForecastLogSnapshot) {
        lock.lock(); defer { lock.unlock() }; records.append(snapshot)
    }
}
