import CoreData
import XCTest
@testable import xdrip

final class HighSoonSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func profile(confirmed: Bool = true) -> PenDoseProfile {
        let settings = PenDoseProfile.Settings(
            carbohydrateRatios: [.init(startMinute: 0, value: 10)],
            targetsMmol: [.init(startMinute: 0, value: 6.5)],
            correctionMmolPerUnit: 1.2, penStepUnits: 0.5, maximumSuggestionUnits: 25)
        return PenDoseProfile(settings: settings,
            confirmedSettings: confirmed ? settings : nil,
            confirmedAt: confirmed ? now.addingTimeInterval(-48 * 60 * 60) : nil)
    }

    private func samples(current: Double = 180, slope: Double = 0.5,
                         firstMinute: Int = -30) -> [GlucoseForecastSample] {
        stride(from: firstMinute, through: 0, by: 5).map { minute in
            GlucoseForecastSample(date: now.addingTimeInterval(Double(minute) * 60),
                glucoseMgdl: current + Double(minute) * slope, sensorID: "synthetic-sensor")
        }
    }

    private func snapshot(current: Double = 180, slope: Double = 0.5,
                          firstMinute: Int = -30, treatments: [TherapyTreatment] = [],
                          revision: Int = 7, signature: String = "synthetic-source") throws
        -> PenDoseInputSnapshot {
        try PenDoseInputSnapshot.make(capturedAt: now,
            glucose: samples(current: current, slope: slope, firstMinute: firstMinute),
            treatments: treatments, therapySettings: TherapyModelSettings(),
            treatmentRevision: revision, sourceSignature: signature).get()
    }

    private func outcome(_ snapshot: PenDoseInputSnapshot,
                         profile: PenDoseProfile? = nil, sensitivity: Double? = 40,
                         forecastRevision: Int = 9) -> GlucoseForecastSafetyOutcome {
        GlucoseForecastDataAdapter.engineOnlyOutcome(snapshot: snapshot, at: now,
            sensitivityMgdlPerUnit: sensitivity, carbohydrateRatioGramsPerUnit: 10,
            highAdvisoryProfile: profile, forecastInputChangeRevision: forecastRevision)
    }

    func testOptionalHighContextPreservesOriginalEngineOutcome() throws {
        let input = try snapshot()
        let original = PenBolusCalculator.safetyForecast(snapshot: input, at: now,
            sensitivityMgdlPerUnit: 40, carbohydrateRatioGramsPerUnit: 10, horizonMinutes: 60)
        let lowOnly = outcome(input)
        let shared = outcome(input, profile: profile())
        XCTAssertNil(lowOnly.highAdvisory)
        XCTAssertEqual(lowOnly.result.points, original.points)
        XCTAssertEqual(shared.result.points, original.points)
        XCTAssertEqual(shared.result.referenceDate, original.referenceDate)
        XCTAssertEqual(shared.result.referenceSensorID, original.referenceSensorID)
        XCTAssertEqual(shared.result.reason, original.reason)
        XCTAssertEqual(shared.referenceGlucoseMgdl, lowOnly.referenceGlucoseMgdl)
        XCTAssertEqual(shared.activeInsulinUnits, lowOnly.activeInsulinUnits)
        XCTAssertEqual(shared.slope15MgdlPerMinute, lowOnly.slope15MgdlPerMinute)
        let context = try XCTUnwrap(shared.highAdvisory)
        XCTAssertEqual(context.capturedAt, input.capturedAt)
        XCTAssertEqual(context.treatmentRevision, input.treatmentRevision)
        XCTAssertEqual(context.forecastInputChangeRevision, 9)
        XCTAssertEqual(context.sourceSignature, input.sourceSignature)
        XCTAssertEqual(context.profile, profile())
        XCTAssertNotNil(context.safetyForecast.value(atMinutes: 120))
        XCTAssertEqual(Array(context.safetyForecast.points.prefix(shared.result.points.count)),
                       shared.result.points)
    }

    func testSharedSnapshotMatchesCalculatorWithExistingMealsAndNoNewCarbs() throws {
        let input = try snapshot(treatments: [
            TherapyTreatment(date: now.addingTimeInterval(-60 * 60), amount: 1, isIOB: true),
            TherapyTreatment(date: now.addingTimeInterval(-30 * 60), amount: 30, isIOB: false,
                carbohydrateDurationMinutes: 120)
        ])
        let shared = outcome(input, profile: profile())
        let context = try XCTUnwrap(shared.highAdvisory)
        let expected = PenBolusCalculator.calculate(snapshot: input, profile: profile(),
            glucose: .currentCGM, newCarbs: .unrecorded(grams: 0),
            safetyForecast: context.safetyForecast, at: now)
        let lines = try XCTUnwrap(context.calculation.lines)
        let expectedLines = try XCTUnwrap(expected.lines)
        XCTAssertGreaterThan(input.iobUnits, 0)
        XCTAssertGreaterThan(input.cobGrams, 0)
        XCTAssertEqual(lines.carbohydratesUnits, expectedLines.carbohydratesUnits)
        XCTAssertEqual(lines.carbohydratesUnits, input.cobGrams / 10, accuracy: 1e-10)
        XCTAssertEqual(lines.correctionUnits, expectedLines.correctionUnits)
        XCTAssertEqual(lines.trendUnits, expectedLines.trendUnits)
        XCTAssertEqual(lines.insulinOnBoardUnits, input.iobUnits)
        XCTAssertEqual(lines.rawUnits, expectedLines.rawUnits)
        XCTAssertEqual(context.calculation.suggestedUnits, expected.suggestedUnits)
        XCTAssertEqual(context.calculation.glucoseMgdl, input.glucose.last?.glucoseMgdl)
        XCTAssertEqual(context.calculation.glucoseMeasuredAt, input.glucose.last?.date)
        XCTAssertEqual(context.calculation.glucoseSensorID, input.glucose.last?.sensorID)
        XCTAssertFalse(context.calculation.trendWasIntentionallyZero)
        if case .checked? = context.calculation.safety {} else { XCTFail("Expected the full safety check") }
    }

    func testKnownZeroTreatmentSnapshotKeepsPositiveCheckedCorrection() throws {
        let input = try snapshot()
        let context = try XCTUnwrap(outcome(input, profile: profile()).highAdvisory)
        XCTAssertEqual(input.iobUnits, 0)
        XCTAssertEqual(input.cobGrams, 0)
        XCTAssertEqual(context.calculation.lines?.carbohydratesUnits, 0)
        XCTAssertEqual(context.calculation.lines?.insulinOnBoardUnits, 0)
        XCTAssertGreaterThan(try XCTUnwrap(context.calculation.suggestedUnits), 0)
        if case .checked? = context.calculation.safety {} else { XCTFail("Known zero remains checked") }
    }

    func testActiveInsulinCanCoverPositiveGlucoseCorrection() throws {
        let input = try snapshot(slope: 0, treatments: [
            TherapyTreatment(date: now, amount: 10, isIOB: true)
        ])
        let context = try XCTUnwrap(outcome(input, profile: profile(), sensitivity: 10).highAdvisory)
        XCTAssertGreaterThan(try XCTUnwrap(context.calculation.lines?.correctionUnits), 0)
        XCTAssertEqual(context.calculation.lines?.insulinOnBoardUnits, 10)
        XCTAssertEqual(context.calculation.suggestedUnits, 0)
        if case .checked? = context.calculation.safety {} else { XCTFail("Insulin-covered correction stays checked zero") }
    }

    func testUnconfirmedProfileNeverProducesCorrectionButPreservesLowForecast() throws {
        let input = try snapshot()
        let shared = outcome(input, profile: profile(confirmed: false))
        XCTAssertEqual(shared.result.points, outcome(input).result.points)
        let context = try XCTUnwrap(shared.highAdvisory)
        XCTAssertEqual(context.calculation.unavailableReason, .unconfirmedProfile)
        XCTAssertNil(context.calculation.suggestedUnits)
    }

    func testMissingTwentyMinuteTrendDoesNotBecomeAnAutomaticZeroTrend() throws {
        let context = try XCTUnwrap(outcome(try snapshot(firstMinute: -10),
            profile: profile()).highAdvisory)
        XCTAssertEqual(context.calculation.unavailableReason, .missingTwentyMinuteTrend)
        XCTAssertNil(context.calculation.suggestedUnits)
    }

    func testMissingForecastParametersDoNotMasqueradeAsChecked() throws {
        let shared = outcome(try snapshot(), profile: profile(), sensitivity: nil)
        XCTAssertEqual(shared.result.reason, .missingProfile)
        let context = try XCTUnwrap(shared.highAdvisory)
        XCTAssertEqual(context.safetyForecast.reason, .missingProfile)
        if case .forecastUnchecked(.missingProfile)? = context.calculation.safety {} else {
            XCTFail("A numerical correction must retain its unavailable safety evidence")
        }
    }

    func testLaterOutOfRangeForecastCannotSuppressExistingFirstHourLowWarning() throws {
        let input = try snapshot(current: 95, slope: 0, treatments: [
            TherapyTreatment(date: now, amount: 6.5, isIOB: true)
        ])
        let shared = outcome(input, profile: profile())
        XCTAssertNil(shared.result.reason)
        XCTAssertEqual(shared.result.points, outcome(input).result.points)
        let low = try XCTUnwrap(LowSoonAlertPolicy.validatedPrediction(from: shared,
            expectedReferenceDate: now, expectedSensorID: "synthetic-sensor",
            expectedGlucoseMgdl: 95, at: now))
        XCTAssertTrue(LowSoonAlertPolicy.condition(currentMgdl: low.currentMgdl,
                                                   minimumMgdl: low.minimumMgdl))
        let context = try XCTUnwrap(shared.highAdvisory)
        XCTAssertEqual(context.safetyForecast.reason, .outOfRange)
        XCTAssertTrue(context.safetyForecast.points.isEmpty)
        if case .forecastUnchecked(.outOfRange)? = context.calculation.safety {} else {
            XCTFail("The longer correction safety check must remain unavailable")
        }
    }

    func testCurrentInputGuardAcceptsOnlyThirtySecondNonFutureSnapshot() throws {
        let fixture = try Fixture(now: now, profile: profile())
        defer { fixture.close() }
        let context = try fixture.context(at: now)
        XCTAssertTrue(fixture.adapter.highAdvisoryInputsAreCurrent(context, at: now))
        XCTAssertTrue(fixture.adapter.highAdvisoryInputsAreCurrent(context, at: now.addingTimeInterval(30)))
        XCTAssertFalse(fixture.adapter.highAdvisoryInputsAreCurrent(context, at: now.addingTimeInterval(30.001)))
        XCTAssertFalse(fixture.adapter.highAdvisoryInputsAreCurrent(context, at: now.addingTimeInterval(-0.001)))
        XCTAssertFalse(fixture.adapter.highAdvisoryInputsAreCurrent(context,
            at: Date(timeIntervalSinceReferenceDate: .nan)))
    }

    func testCurrentInputGuardRejectsBothTreatmentAndForecastRevisions() throws {
        let fixture = try Fixture(now: now, profile: profile())
        defer { fixture.close() }
        let initial = try fixture.context(at: now)
        fixture.therapy.invalidate(treatmentsChanged: true)
        XCTAssertFalse(fixture.adapter.highAdvisoryInputsAreCurrent(initial, at: now))
        let afterTreatment = try fixture.context(at: now)
        XCTAssertTrue(fixture.adapter.highAdvisoryInputsAreCurrent(afterTreatment, at: now))
        fixture.therapy.invalidate(treatmentsChanged: false, forecastInputsInvalidated: true)
        XCTAssertEqual(afterTreatment.treatmentRevision, fixture.therapy.treatmentChangeRevision)
        XCTAssertFalse(fixture.adapter.highAdvisoryInputsAreCurrent(afterTreatment, at: now))
    }

    func testCurrentInputGuardRejectsChangedProfileParametersAndSourceOwnership() throws {
        let fixture = try Fixture(now: now, profile: profile())
        defer { fixture.close() }
        let context = try fixture.context(at: now)
        var changed = profile()
        changed.settings.penStepUnits = 0.25
        XCTAssertTrue(changed.persist(defaults: fixture.defaults))
        XCTAssertFalse(fixture.adapter.highAdvisoryInputsAreCurrent(context, at: now))
        XCTAssertTrue(profile().persist(defaults: fixture.defaults))
        XCTAssertTrue(fixture.adapter.highAdvisoryInputsAreCurrent(context, at: now))
        fixture.defaults.glucoseForecastManualSensitivityMgdlPerUnit = 41
        XCTAssertFalse(fixture.adapter.highAdvisoryInputsAreCurrent(context, at: now))
        fixture.defaults.glucoseForecastManualSensitivityMgdlPerUnit = 40
        fixture.defaults.therapyDataSourceType = .nightscout
        fixture.defaults.nightscoutEnabled = true
        XCTAssertFalse(fixture.adapter.highAdvisoryInputsAreCurrent(context, at: now))
    }

    func testCurrentInputGuardRejectsIncompleteImportedTherapyAndMissingCutover() throws {
        let fixture = try Fixture(now: now, profile: profile())
        defer { fixture.close() }
        let context = try fixture.context(at: now)
        fixture.defaults.removeObject(forKey: TreatmentSourceCutover.defaultsKey)
        fixture.defaults.set(true, forKey: "healthTherapyImport.v1.insulin.enabled")
        XCTAssertTrue(fixture.importer.localInputIsIncomplete(.insulin))
        XCTAssertFalse(fixture.adapter.highAdvisoryInputsAreCurrent(context, at: now))
        fixture.defaults.set(false, forKey: "healthTherapyImport.v1.insulin.enabled")
        XCTAssertFalse(fixture.importer.localInputIsIncomplete(.insulin))
        XCTAssertFalse(fixture.adapter.highAdvisoryInputsAreCurrent(context, at: now))
    }

    @MainActor func testCurrentInputGuardRejectsUncommittedParentStoreChanges() throws {
        let fixture = try Fixture(now: now, profile: profile())
        defer { fixture.close() }
        fixture.therapy.configure(coreDataManager: fixture.core, externalStatus: { nil })
        _ = TreatmentEntry(date: now, value: 1, treatmentType: .Insulin,
            nightscoutEventType: nil, enteredBy: nil,
            nsManagedObjectContext: fixture.core.mainManagedObjectContext)
        try fixture.core.mainManagedObjectContext.save()
        XCTAssertTrue(fixture.therapy.hasUncommittedForecastInputChanges)
        // Use matching current revisions to prove the pending-save gate independently.
        let context = try fixture.context(at: now)
        XCTAssertEqual(context.treatmentRevision, fixture.therapy.treatmentChangeRevision)
        XCTAssertEqual(context.forecastInputChangeRevision, fixture.therapy.forecastInputChangeRevision)
        XCTAssertFalse(fixture.adapter.highAdvisoryInputsAreCurrent(context, at: now))
        fixture.core.mainManagedObjectContext.reset()
        fixture.core.privateManagedObjectContext.performAndWait {
            fixture.core.privateManagedObjectContext.reset()
        }
    }

    private final class Fixture {
        let suite = "HighSoonSnapshotTests." + UUID().uuidString
        let defaults: UserDefaults
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let therapy = TherapyMetricsManager()
        let importer: HealthKitTherapyImportManager
        let adapter: GlucoseForecastDataAdapter

        init(now: Date, profile: PenDoseProfile) throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defaults.therapyDataSourceType = .none
            defaults.glucoseForecastManualSensitivityMgdlPerUnit = 40
            defaults.glucoseForecastManualCarbRatioGramsPerUnit = 10
            XCTAssertTrue(profile.persist(defaults: defaults))
            XCTAssertTrue(TreatmentSourceCutover.persist(.init(cutoff: now.addingTimeInterval(-24 * 60 * 60),
                insulinSourceBundleID: "synthetic-insulin", carbohydrateSourceBundleID: "synthetic-carbs"),
                defaults: defaults))
            importer = HealthKitTherapyImportManager(query: UnusedQuery(), defaults: defaults)
            adapter = GlucoseForecastDataAdapter(coreDataManager: core, therapyManager: therapy,
                defaults: defaults, healthImporter: importer, logForecast: { _ in
                    XCTFail("Safety assembly must not log a Home forecast")
                })
        }

        func context(at now: Date) throws -> HighSoonAdvisoryContext {
            let signature = GlucoseForecastDataAdapter.presentationInputSignature(horizonMinutes: 120,
                defaults: defaults, importer: importer)
            let samples = stride(from: -30, through: 0, by: 5).map { minute in
                GlucoseForecastSample(date: now.addingTimeInterval(Double(minute) * 60),
                    glucoseMgdl: 180 + Double(minute) * 0.5, sensorID: "synthetic-sensor")
            }
            let snapshot = try PenDoseInputSnapshot.make(capturedAt: now, glucose: samples,
                treatments: [], therapySettings: TherapyModelSettings(defaults: defaults),
                treatmentRevision: therapy.treatmentChangeRevision, sourceSignature: signature).get()
            return try XCTUnwrap(GlucoseForecastDataAdapter.engineOnlyOutcome(snapshot: snapshot, at: now,
                sensitivityMgdlPerUnit: defaults.glucoseForecastManualSensitivityMgdlPerUnit,
                carbohydrateRatioGramsPerUnit: defaults.glucoseForecastManualCarbRatioGramsPerUnit,
                highAdvisoryProfile: PenDoseProfile.load(defaults: defaults),
                forecastInputChangeRevision: therapy.forecastInputChangeRevision).highAdvisory)
        }

        func close() { defaults.removePersistentDomain(forName: suite) }
    }

    private final class UnusedQuery: HealthTherapyQuerying {
        func requestReadAuthorization(for kind: HealthTherapyImportKind,
                                      completion: @escaping (Error?) -> Void) {
            XCTFail("Read-only advisory must not request Health authorization")
        }
        func discoverSources(for kind: HealthTherapyImportKind,
                             completion: @escaping ([HealthTherapyImportSource], Error?) -> Void) {
            XCTFail("Read-only advisory must not discover Health sources")
        }
        func page(for kind: HealthTherapyImportKind, since: Date, anchor: Data?, limit: Int,
                  completion: @escaping (Result<HealthTherapyImportPage, Error>) -> Void) {
            XCTFail("Read-only advisory must not query live Health data")
        }
        func observe(_ kind: HealthTherapyImportKind,
                     onChange: @escaping (@escaping () -> Void) -> Void) {
            XCTFail("Read-only advisory must not start Health observers")
        }
    }
}
