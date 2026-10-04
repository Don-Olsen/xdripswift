import HealthKit
import XCTest
@testable import xdrip

final class GlucoseForecastMLReplayTests: XCTestCase {
    private let reference = Date(timeIntervalSince1970: 1_800_000_000)
    private let settings = TherapyModelSettings()

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func healthSample(_ minute: Int, value: Double = 120,
                              bundle: String = "com.xdrip.one",
                              insulinReason: Int? = nil) -> GlucoseForecastMLHealthSample {
        let date = reference.addingTimeInterval(Double(minute) * 60)
        return GlucoseForecastMLHealthSample(uuid: UUID(), sourceBundleIdentifier: bundle,
            startDate: date, endDate: date, value: value,
            insulinReason: insulinReason, hasUndeterminedDuration: false, sampleCount: 1)
    }

    private func observation(_ minute: Int, value: Double = 120, sensor: String? = "A",
                             valid: Bool = true, suppressed: Bool = false)
        -> GlucoseForecastGlucoseObservation {
        GlucoseForecastGlucoseObservation(date: reference.addingTimeInterval(Double(minute) * 60),
            glucoseMgdl: value, sensorID: sensor, isValidForDownstream: valid,
            isSuppressedByFiveMinuteCadence: suppressed)
    }

    private func readings(from first: Int = -30, through last: Int = 150, by step: Int = 1,
                          sensor: String = "A") -> [GlucoseForecastGlucoseObservation] {
        stride(from: first, through: last, by: step).map { observation($0, sensor: sensor) }
    }

    private func batch(_ observations: [GlucoseForecastGlucoseObservation],
                       treatments: [TherapyTreatment] = [], minutes: Int = 1,
                       previous: Date? = nil) -> GlucoseForecastMLReplayBatch {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return GlucoseForecastMLReplay.batch(observations: observations, treatments: treatments,
            settings: settings, sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, anchorStart: reference,
            anchorEnd: reference.addingTimeInterval(Double(minutes) * 60),
            previousAnchorDate: previous, calendar: calendar)
    }

    func testSharedSelectorKeepsEveryRawPointAndRejectsAmbiguousSensorHistory() {
        let minuteHistory = (-30...0).map { observation($0) }
        let selected = GlucoseForecastGlucoseSelection.select(minuteHistory, at: reference)
        XCTAssertEqual(selected.count, 31)
        XCTAssertEqual(selected.map(\.date), minuteHistory.map(\.date))
        XCTAssertEqual(GlucoseForecastGlucoseSelection.select(
            minuteHistory + [observation(0, value: 121)], at: reference).count, 0)
        XCTAssertEqual(GlucoseForecastGlucoseSelection.select(
            minuteHistory + [observation(1, sensor: "B", valid: false)],
            at: reference.addingTimeInterval(60)).count, 0)
        XCTAssertEqual(GlucoseForecastGlucoseSelection.select(
            minuteHistory + [observation(0, sensor: nil)], at: reference).count, 0)
    }

    func testOneAndFiveMinuteCadenceSelectDeterministicTenMinuteAnchors() {
        let oneMinute = batch(readings(), minutes: 21)
        let fiveMinute = batch(readings(by: 5), minutes: 21)
        func anchors(_ examples: [GlucoseForecastMLReplayExample]) -> [Int] {
            examples.filter { $0.row.horizonMinutes == 30 }.map {
                Int($0.row.referenceDate.timeIntervalSince(reference) / 60)
            }
        }
        XCTAssertEqual(anchors(oneMinute.examples), [0, 10, 20])
        XCTAssertEqual(anchors(fiveMinute.examples), [0, 10, 20])
        XCTAssertEqual(oneMinute.examples.count, 9)
        XCTAssertEqual(fiveMinute.examples.count, 9)
        XCTAssertEqual(oneMinute.lastAnchorDate, reference.addingTimeInterval(20 * 60))
        XCTAssertEqual(batch(readings(), minutes: 11, previous: reference.addingTimeInterval(-60))
            .examples.first?.row.referenceDate, reference.addingTimeInterval(9 * 60))
    }

    func testSharedSixteenFeaturesUseRawSlopesAndTreatmentCurves() throws {
        let samples = (-30...0).map { minute in
            GlucoseForecastSample(date: reference.addingTimeInterval(Double(minute) * 60),
                                  glucoseMgdl: 120 + Double(minute), sensorID: "A")
        }
        let dose = TherapyTreatment(date: reference.addingTimeInterval(-20 * 60), amount: 2, isIOB: true)
        let meal = TherapyTreatment(date: reference.addingTimeInterval(-10 * 60), amount: 15, isIOB: false)
        let input = GlucoseForecastInput(glucose: samples, treatments: [dose, meal],
            settings: settings, sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, horizonMinutes: 60, now: reference)
        let result = GlucoseForecastEngine.predict(input)
        let row = try XCTUnwrap(GlucoseForecastMLFeatures.row(input: input, result: result,
            horizonMinutes: 30))
        XCTAssertEqual(GlucoseForecastMLFeatures.featureNames.count, 16)
        XCTAssertEqual(row.values.count, 16)
        XCTAssertEqual(row.values[0], 120)
        XCTAssertEqual(row.values[1], 1, accuracy: 1e-10)
        XCTAssertEqual(row.values[2], 1, accuracy: 1e-10)
        XCTAssertEqual(row.values[3], row.engineValue - row.glucose, accuracy: 1e-10)
        XCTAssertEqual(row.values[8], 20)
        XCTAssertEqual(row.values[9], 2)
        XCTAssertEqual(row.values[10], 10)
        XCTAssertEqual(row.values[11], 15)
        XCTAssertEqual(row.values[15], 31)
        let currentIOB = TherapyCalculations.insulinRemaining(units: 2, minutes: 20,
            duration: settings.insulinDuration, peak: settings.insulinPeak)
        let futureIOB = TherapyCalculations.insulinRemaining(units: 2, minutes: 50,
            duration: settings.insulinDuration, peak: settings.insulinPeak)
        XCTAssertEqual(row.values[6], currentIOB, accuracy: 1e-10)
        XCTAssertEqual(row.values[4], currentIOB - futureIOB, accuracy: 1e-10)
        XCTAssertEqual(row.values[7], TherapyCalculations.carbsRemaining(grams: 15,
            minutes: 10, duration: settings.carbDuration), accuracy: 1e-10)
    }

    func testFutureTreatmentDoesNotEnterFeaturesAndHistoricalKnownTimeIsUnknown() throws {
        let base = batch(readings(), minutes: 1)
        let futureDose = TherapyTreatment(date: reference.addingTimeInterval(60), amount: 20, isIOB: true)
        let withFuture = batch(readings(), treatments: [futureDose], minutes: 1)
        XCTAssertEqual(base.examples.count, 3)
        XCTAssertEqual(withFuture.examples.count, 3)
        for (original, changed) in zip(base.examples, withFuture.examples) {
            XCTAssertEqual(original.row.values, changed.row.values)
            XCTAssertEqual(original.row.engineValue, changed.row.engineValue)
            XCTAssertEqual(changed.treatmentAvailability, .retrospectiveUnknown)
            XCTAssertEqual(changed.settingsAvailability, .retrospectiveUnknown)
        }
    }

    func testTargetUsesNearestValidSameSensorReadingWithEarlierTie() throws {
        let history = readings(through: 0, by: 5)
        let nearby = history + [observation(29, value: 131), observation(31, value: 141),
                                observation(60, value: 150), observation(120, value: 160)]
        let examples = batch(nearby, minutes: 1).examples
        XCTAssertEqual(examples.count, 3)
        XCTAssertEqual(examples[0].row.horizonMinutes, 30)
        XCTAssertEqual(examples[0].targetDate, reference.addingTimeInterval(29 * 60))
        XCTAssertEqual(examples[0].targetGlucoseMgdl, 131)
        XCTAssertEqual(examples[0].engineTrajectoryMgdl.count, 25)
        XCTAssertEqual(examples[0].engineTrajectoryMgdl, examples[1].engineTrajectoryMgdl)
        XCTAssertEqual(examples[1].engineTrajectoryMgdl, examples[2].engineTrajectoryMgdl)
        XCTAssertEqual(batch(history + [observation(30, sensor: "B"), observation(60),
            observation(120)], minutes: 1).examples.count, 0)
        XCTAssertEqual(batch(history + [observation(30), observation(30, value: 121),
            observation(60), observation(120)],
            minutes: 1).examples.count, 0)
    }

    func testMissingOneTargetDropsTheWholeAnchorTriple() {
        let history = readings(through: 0, by: 5)
        XCTAssertTrue(batch(history + [observation(30), observation(60)], minutes: 1)
            .examples.isEmpty)
    }

    func testHealthSourceDiscoveryFreezesEveryXDripBundleAndDetectsCrossBundleConflict() {
        let sources = [
            GlucoseForecastMLHealthSource(bundleIdentifier: "com.xdrip.one", name: "xDrip4iOS"),
            GlucoseForecastMLHealthSource(bundleIdentifier: "com.xdrip.two", name: "XDRIP"),
            GlucoseForecastMLHealthSource(bundleIdentifier: "com.other", name: "Other CGM"),
            GlucoseForecastMLHealthSource(bundleIdentifier: "com.xdrip.one", name: "xDrip old")
        ]
        XCTAssertEqual(GlucoseForecastMLHistoryCoverageRules.matchingGlucoseSources(sources)
            .map(\.bundleIdentifier), ["com.xdrip.one", "com.xdrip.two"])
        let equal = [healthSample(0, bundle: "com.xdrip.one"),
                     healthSample(0, bundle: "com.xdrip.two")]
        XCTAssertTrue(GlucoseForecastMLHistoryCoverageRules.conflictingHealthDates(equal).isEmpty)
        let disagreeing = equal + [healthSample(0, value: 135, bundle: "com.xdrip.two")]
        XCTAssertEqual(GlucoseForecastMLHistoryCoverageRules
            .conflictingHealthDates(disagreeing), [reference])
        let one = GlucoseForecastMLHistoryCoverageRules.normalizedHealthGlucose(
            [healthSample(0), healthSample(0)], sourceBundleIdentifier: "com.xdrip.one")
        XCTAssertEqual(one.observations.count, 1, "Identical HealthKit copies collapse")
        let conflict = GlucoseForecastMLHistoryCoverageRules.normalizedHealthGlucose(
            [healthSample(0), healthSample(0, value: 140)], sourceBundleIdentifier: "com.xdrip.one")
        XCTAssertTrue(conflict.observations.isEmpty)
        XCTAssertEqual(conflict.conflicts, [reference])
    }

    func testHealthSegmentsHaveDistinctSyntheticIDsAndNeverBridgeGlucoseGap() {
        let first = stride(from: -45, through: 0, by: 5).map {
            GlucoseForecastMLHistoryTaggedObservation(observation: observation($0),
                source: .healthKit, sourceBundleIdentifier: "com.xdrip.one")
        }
        let second = stride(from: 10, through: 145, by: 5).map {
            GlucoseForecastMLHistoryTaggedObservation(observation: observation($0),
                source: .healthKit, sourceBundleIdentifier: "com.xdrip.one")
        }
        let segments = GlucoseForecastMLHistoryCoverageRules.segments(first + second, blockedDates: [])
        XCTAssertEqual(segments.count, 2)
        XCTAssertNotEqual(segments[0].0.sensorID, segments[1].0.sensorID)
        XCTAssertTrue(segments[0].0.sensorID.hasPrefix("health-segment:"))
        XCTAssertEqual(Set(segments[0].1.compactMap(\.sensorID)), [segments[0].0.sensorID])
        XCTAssertEqual(Set(segments[1].1.compactMap(\.sensorID)), [segments[1].0.sensorID])
        let crossing = GlucoseForecastMLReplay.batch(observations: segments[0].1 + segments[1].1,
            treatments: [], settings: settings, sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, anchorStart: reference,
            anchorEnd: reference.addingTimeInterval(60), calendar: utcCalendar)
        XCTAssertTrue(crossing.examples.isEmpty,
            "A +30/+60/+120 target across the gap has a different segment ID")
    }

    func testHealthSourceSwitchIsSegmentBoundary() {
        let first = (-45...0).map {
            GlucoseForecastMLHistoryTaggedObservation(observation: observation($0),
                source: .healthKit, sourceBundleIdentifier: "com.xdrip.one")
        }
        let second = (1...150).map {
            GlucoseForecastMLHistoryTaggedObservation(observation: observation($0),
                source: .healthKit, sourceBundleIdentifier: "com.xdrip.two")
        }
        let segments = GlucoseForecastMLHistoryCoverageRules.segments(first + second, blockedDates: [])
        XCTAssertEqual(segments.count, 2)
        XCTAssertNotEqual(segments[0].0.sensorID, segments[1].0.sensorID)
        XCTAssertEqual(segments.map { $0.0.sourceBundleIdentifier },
                       ["com.xdrip.one", "com.xdrip.two"])
    }

    func testSelectedTreatmentDayAndFollowingWindowMustHaveEvidence() {
        let calendar = utcCalendar
        let day = calendar.startOfDay(for: reference)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: day)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: day)!
        let evidence = GlucoseForecastMLTherapyEvidence(sourceDays: [yesterday, tomorrow],
            ambiguousDays: [], historyStart: nil, requiresSelectedSource: true)
        XCTAssertFalse(evidence.covers(from: day, to: day.addingTimeInterval(3600),
                                        calendar: calendar, usingLocalImport: false))
        XCTAssertFalse(evidence.covers(from: day.addingTimeInterval(-3600),
                                        to: day.addingTimeInterval(3600),
                                        calendar: calendar, usingLocalImport: false),
                       "An empty day contaminates later treatment windows")
        let covered = GlucoseForecastMLTherapyEvidence(sourceDays: [yesterday, day, tomorrow],
            ambiguousDays: [], historyStart: nil, requiresSelectedSource: true)
        XCTAssertTrue(covered.covers(from: day.addingTimeInterval(-3600),
                                      to: day.addingTimeInterval(3600),
                                      calendar: calendar, usingLocalImport: false))
        let ambiguous = GlucoseForecastMLTherapyEvidence(sourceDays: [yesterday, day],
            ambiguousDays: [day], historyStart: nil, requiresSelectedSource: true)
        XCTAssertFalse(ambiguous.covers(from: yesterday, to: day, calendar: calendar,
                                        usingLocalImport: false))
        let noImport = GlucoseForecastMLTherapyEvidence(sourceDays: [], ambiguousDays: [],
            historyStart: nil, requiresSelectedSource: false)
        XCTAssertFalse(noImport.covers(from: day, to: day, calendar: calendar,
                                       usingLocalImport: true),
                       "Missing local insulin or carbohydrate must not become zero")
    }

    func testLocalFallbackRespectsEachHealthImportHistoryStart() {
        let calendar = utcCalendar
        let day = calendar.startOfDay(for: reference)
        let evidence = GlucoseForecastMLTherapyEvidence(sourceDays: [day],
            ambiguousDays: [], historyStart: day.addingTimeInterval(2 * 3600),
            requiresSelectedSource: true)
        XCTAssertFalse(evidence.covers(from: day.addingTimeInterval(3600),
                                        to: day.addingTimeInterval(12 * 3600),
                                        calendar: calendar, usingLocalImport: true))
        XCTAssertTrue(evidence.covers(from: day.addingTimeInterval(2 * 3600),
                                       to: day.addingTimeInterval(12 * 3600),
                                       calendar: calendar, usingLocalImport: true))
        XCTAssertTrue(evidence.covers(from: day.addingTimeInterval(3600),
                                       to: day.addingTimeInterval(12 * 3600),
                                       calendar: calendar, usingLocalImport: false))
    }

    func testHealthInsulinRequiresExplicitPointBolus() {
        let bolus = healthSample(0, value: 2,
            insulinReason: HKInsulinDeliveryReason.bolus.rawValue)
        let basal = healthSample(0, value: 2,
            insulinReason: HKInsulinDeliveryReason.basal.rawValue)
        let unclassified = healthSample(0, value: 2)
        XCTAssertEqual(bolus.treatment(kind: .insulin)?.amount, 2)
        XCTAssertNil(basal.treatment(kind: .insulin))
        XCTAssertNil(unclassified.treatment(kind: .insulin))
        XCTAssertTrue(basal.isUnambiguous(kind: .insulin))
        XCTAssertFalse(unclassified.isUnambiguous(kind: .insulin))
        XCTAssertEqual(healthSample(0, value: 20).treatment(kind: .carbohydrates)?.amount, 20)
    }

    @MainActor func testEmptyHealthTherapyFallsBackOnlyToCoveredLocalHistory() async throws {
        for (historyHoursBeforeAnchor, expectsFallback) in [(11.0, true), (1.0, false)] {
            let suite = "MLHistoryFallback.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let selectedTherapyBundle = "com.example.selected.therapy"
            for kind in HealthTherapyImportKind.allCases {
                let prefix = "healthTherapyImport.v1.\(kind.rawValue)."
                defaults.set(true, forKey: prefix + "enabled")
                defaults.set(selectedTherapyBundle, forKey: prefix + "sourceBundleID")
                defaults.set("Selected source", forKey: prefix + "sourceName")
                defaults.set(Date(), forKey: prefix + "lastSync")
                defaults.set(true, forKey: prefix + "observedSelectedSource")
                defaults.set(reference.addingTimeInterval(-historyHoursBeforeAnchor * 3600),
                             forKey: prefix + "historyStart")
            }
            let importer = HealthKitTherapyImportManager(query: NoopTherapyQuery(), defaults: defaults)
            let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
            let sensor = Sensor(startDate: reference.addingTimeInterval(-24 * 3600),
                                nsManagedObjectContext: core.mainManagedObjectContext)
            for minute in stride(from: -45, through: 120, by: 5) {
                let date = reference.addingTimeInterval(Double(minute) * 60)
                let reading = BgReading(timeStamp: date, sensor: sensor, calibration: nil,
                    rawData: 120, deviceName: "Libre 2 Plus",
                    nsManagedObjectContext: core.mainManagedObjectContext)
                reading.calculatedValue = 120
            }
            for date in [reference.addingTimeInterval(-9 * 3600),
                         reference.addingTimeInterval(-7 * 3600)] {
                let bolus = TreatmentEntry(date: date, value: 1, treatmentType: .Insulin,
                    nightscoutEventType: nil, enteredBy: "Apple Health",
                    nsManagedObjectContext: core.mainManagedObjectContext)
                bolus.healthKitSampleUUID = UUID().uuidString
                bolus.healthKitSourceBundleIdentifier = selectedTherapyBundle
                let meal = TreatmentEntry(date: date, value: 10, treatmentType: .Carbs,
                    nightscoutEventType: nil, enteredBy: "Apple Health",
                    nsManagedObjectContext: core.mainManagedObjectContext)
                meal.healthKitSampleUUID = UUID().uuidString
                meal.healthKitSourceBundleIdentifier = selectedTherapyBundle
            }
            XCTAssertTrue(core.saveChangesSynchronously())
            let manager = TherapyMetricsManager()
            manager.configure(coreDataManager: core, externalStatus: { nil })
            let query = FakeHistoryHealthQuery(glucoseSamples:
                stride(from: -45, through: 120, by: 5).map {
                    healthSample($0, bundle: "com.xdrip.glucose")
                })
            let loader = GlucoseForecastMLHistoryLoader(coreDataManager: core,
                therapyManager: manager, healthImporter: importer, healthQuery: query)
            let policy = DataFlowPolicy(isMaster: true, followerDataSource: .careLink,
                therapyDataSourceSelection: .none, nightscoutEnabled: false,
                masterUploadsGlucoseToNightscout: false,
                followerUploadsGlucoseToNightscout: false,
                nightscoutFollowType: .none)
            let result = await loader.load(days: 2,
                at: reference.addingTimeInterval(121 * 60), policy: policy,
                settings: settings, sensitivityMgdlPerUnit: 40,
                carbohydrateRatioGramsPerUnit: 10, calendar: utcCalendar)
            let loaded = try XCTUnwrap(result)
            XCTAssertEqual(loaded.coverage.completedDays, 2)
            XCTAssertEqual(loaded.coverage.healthKitDays, 0)
            if expectsFallback {
                XCTAssertEqual(loaded.examples.count, 3)
                XCTAssertEqual(loaded.coverage.localFallbackDays, 1)
                XCTAssertEqual(loaded.coverage.usableDays, 1)
            } else {
                XCTAssertTrue(loaded.examples.isEmpty)
                XCTAssertEqual(loaded.coverage.localFallbackDays, 0)
                XCTAssertEqual(loaded.coverage.usableDays, 0)
            }
        }
    }

    private enum FakeReadError: Error { case unavailable }

    private final class FakeHistoryHealthQuery: GlucoseForecastMLHealthQuerying {
        let glucoseSamples: [GlucoseForecastMLHealthSample]

        init(glucoseSamples: [GlucoseForecastMLHealthSample]) {
            self.glucoseSamples = glucoseSamples
        }

        func sources(for kind: GlucoseForecastMLHealthKind,
                     completion: @escaping (Result<[GlucoseForecastMLHealthSource], Error>) -> Void)
            -> GlucoseForecastMLHealthQueryTicket {
            completion(.success([GlucoseForecastMLHealthSource(
                bundleIdentifier: "com.xdrip.glucose", name: "xDrip4iOS")]))
            return GlucoseForecastMLHealthQueryTicket()
        }

        func samples(for kind: GlucoseForecastMLHealthKind, from start: Date, to end: Date,
                     sourceBundleIdentifier: String,
                     completion: @escaping (Result<[GlucoseForecastMLHealthSample], Error>) -> Void)
            -> GlucoseForecastMLHealthQueryTicket {
            completion(.success(kind == .glucose ? glucoseSamples.filter {
                $0.startDate >= start && $0.startDate <= end &&
                    $0.sourceBundleIdentifier == sourceBundleIdentifier
            } : []))
            return GlucoseForecastMLHealthQueryTicket()
        }
    }

    private final class NoopTherapyQuery: HealthTherapyQuerying {
        func requestReadAuthorization(for kind: HealthTherapyImportKind,
                                      completion: @escaping (Error?) -> Void) { completion(nil) }
        func discoverSources(for kind: HealthTherapyImportKind,
                             completion: @escaping ([HealthTherapyImportSource], Error?) -> Void) {
            completion([], nil)
        }
        func page(for kind: HealthTherapyImportKind, since: Date, anchor: Data?, limit: Int,
                  completion: @escaping (Result<HealthTherapyImportPage, Error>) -> Void) {
            completion(.failure(FakeReadError.unavailable))
        }
        func observe(_ kind: HealthTherapyImportKind,
                     onChange: @escaping (@escaping () -> Void) -> Void) {}
    }
}
