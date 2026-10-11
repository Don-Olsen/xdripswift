import XCTest
@testable import xdrip

/// Synthetic calculator/editor flows. No HealthKit access or physical-device claims.
@MainActor final class CarbohydrateAdviceIntegrationTests: XCTestCase {
    @MainActor private final class Fixture {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "CarbohydrateAdviceIntegrationTests." + UUID().uuidString
        let forecastDefaults: UserDefaults
        let evidence: CarbohydrateAdviceJournal
        let saveJournal: PenDoseLogJournal
        let metadata: MealPlanMetadataStore
        let profile: PenDoseProfile
        let keys = [TreatmentSourceCutover.defaultsKey, TreatmentSourceCutover.restoreRequiresSourceSetupKey,
                    "therapyDataSourceType", "nightscoutEnabled", "bloodGlucoseUnitIsMgDl",
                    "healthTherapyImport.v1.insulin.enabled", "healthTherapyImport.v1.carbohydrates.enabled",
                    "timeStampLatestNightscoutSyncRequest", "nightscoutSyncRequired"]
        let previous: [Any?]

        init() throws {
            previous = keys.map { UserDefaults.standard.object(forKey: $0) }
            forecastDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            forecastDefaults.glucoseForecastManualSensitivityMgdlPerUnit = 40
            forecastDefaults.glucoseForecastManualCarbRatioGramsPerUnit = 10
            evidence = CarbohydrateAdviceJournal(directory: directory.appendingPathComponent("evidence"))
            saveJournal = PenDoseLogJournal(directory: directory.appendingPathComponent("journal"))
            metadata = MealPlanMetadataStore(directory: directory.appendingPathComponent("metadata"))
            var confirmed = PenDoseProfile.prefilledUnconfirmed
            XCTAssertTrue(confirmed.confirm()); profile = confirmed
            let defaults = UserDefaults.standard
            defaults.therapyDataSourceType = .none
            defaults.nightscoutEnabled = false
            defaults.bloodGlucoseUnitIsMgDl = true
            defaults.set(false, forKey: "healthTherapyImport.v1.insulin.enabled")
            defaults.set(false, forKey: "healthTherapyImport.v1.carbohydrates.enabled")
            defaults.removeObject(forKey: TreatmentSourceCutover.defaultsKey)
            defaults.removeObject(forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey)
            XCTAssertTrue(TreatmentSourceCutover.persist(.init(cutoff: Date().addingTimeInterval(-86400),
                insulinSourceBundleID: "synthetic.old.insulin", carbohydrateSourceBundleID: "synthetic.old.carbs")))
        }
        func cleanup() {
            evidence.waitUntilIdle()
            for (key, value) in zip(keys, previous) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            forecastDefaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        func calculator(enabled: Bool = true,
                        provider: ((Date, Bool) async -> Result<PenDoseInputSnapshot, PenDoseUnavailableReason>)? = nil)
            -> PenDoseCalculatorViewModel {
            PenDoseCalculatorViewModel(coreDataManager: core, logJournal: saveJournal,
                metadataStore: metadata, profileProvider: { self.profile },
                sourceReadyOverride: { true },
                snapshotProvider: provider ?? { date, _ in Self.snapshot(at: date) },
                automaticallyFillMealDose: true, enablesCarbohydrateAdvice: enabled,
                carbohydrateAdviceJournal: evidence, forecastDefaults: forecastDefaults)
        }
        static func snapshot(at now: Date, glucose: Double = 97,
                             revision: Int = 1, additionalCarbs: Double = 0) -> Result<PenDoseInputSnapshot, PenDoseUnavailableReason> {
            // Existing deterministic engine yields a modest 30-minute fall while
            // remaining within its bounds for the full two-hour safety forecast.
            let samples = stride(from: -30, through: 0, by: 5).map {
                GlucoseForecastSample(date: now.addingTimeInterval(Double($0) * 60),
                                      glucoseMgdl: glucose, sensorID: "synthetic-sensor")
            }
            var treatments = [TherapyTreatment(date: now.addingTimeInterval(-3600), amount: 3.8, isIOB: true)]
            if additionalCarbs > 0 {
                treatments.append(TherapyTreatment(date: now.addingTimeInterval(-60), amount: additionalCarbs,
                    isIOB: false, carbohydrateDurationMinutes: TreatmentMealKind.fast.durationMinutes))
            }
            return PenDoseInputSnapshot.make(capturedAt: now, glucose: samples,
                treatments: treatments,
                therapySettings: TherapyModelSettings(), treatmentRevision: revision,
                sourceSignature: "synthetic-local-source")
        }
        func editor(_ request: CarbohydrateAdviceEditorRequest,
                    saveOverride: (() -> Bool)? = nil) -> TreatmentEditorViewModel {
            TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: nil, initialType: .Carbs,
                quickCarbohydrateGrams: request.grams, localSaveJournal: saveJournal,
                localSaveOverride: saveOverride, mealMetadataStore: metadata,
                carbohydrateAdviceEvidence: request.evidence, carbohydrateAdviceJournal: evidence)
        }
        var treatments: [TreatmentEntry] {
            TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(howOld: nil)
        }
        func records() async throws -> [CarbohydrateAdviceEvidence] {
            try await evidence.records(from: Date().addingTimeInterval(-86400),
                                       to: Date().addingTimeInterval(86400))
        }
    }

    func testCalculatorRequestKeepsManualFieldsAndCreatesNoTreatment() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let calculator = fixture.calculator()
        calculator.carbohydratesText = "45"
        calculator.insulinToLogText = "2,5"
        await calculator.calculate()
        let advice = try XCTUnwrap(calculator.currentCarbohydrateAdvice)
        XCTAssertEqual(advice.status, .estimated)
        let request = try XCTUnwrap(calculator.carbohydrateAdviceEditorRequest(at: advice.computedAt))
        XCTAssertGreaterThan(request.grams, 0)
        XCTAssertEqual(request.grams, Double(try XCTUnwrap(advice.grams)))
        XCTAssertEqual(calculator.carbohydratesText, "45")
        XCTAssertEqual(calculator.insulinToLogText, "2,5")
        XCTAssertNil(calculator.confirmationDraft)
        XCTAssertTrue(fixture.treatments.isEmpty)
        let records = try await fixture.records()
        XCTAssertEqual(records.map(\.event), [.assessed])
        XCTAssertEqual(records.first?.sensitivityMgdlPerUnit, 40)
        XCTAssertEqual(records.first?.carbohydrateRatioGramsPerUnit, 10)
    }

    func testOpeningCarbohydrateHelpFreezesAutomaticInsulinWhenLaterCOBChanges() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var afterFood = false
        let calculator = fixture.calculator(provider: { date, _ in
            Fixture.snapshot(at: date, glucose: afterFood ? 140 : 97,
                             revision: afterFood ? 2 : 1, additionalCarbs: afterFood ? 15 : 0)
        })
        calculator.carbohydratesText = "45"
        await calculator.calculate()
        XCTAssertTrue(calculator.usesAutomaticMealDose)
        let before = calculator.insulinToLogText
        let beforeCOB = try XCTUnwrap(calculator.calculationDetails?.curveCOBGrams)
        XCTAssertNotNil(calculator.carbohydrateAdviceEditorRequest())
        XCTAssertEqual(calculator.insulinToLogText, before)
        XCTAssertFalse(calculator.usesAutomaticMealDose,
            "Opening rescue-carbohydrate registration takes this draft out of automatic meal-dose filling")
        afterFood = true
        await calculator.calculate()
        XCTAssertGreaterThan(try XCTUnwrap(calculator.calculationDetails?.curveCOBGrams), beforeCOB)
        XCTAssertNotNil(calculator.suggestedUnits)
        XCTAssertEqual(calculator.insulinToLogText, before,
            "Newly registered rescue COB must not silently become automatically entered insulin")
        XCTAssertEqual(calculator.carbohydratesText, "45")
        XCTAssertTrue(fixture.treatments.isEmpty)
    }

    func testDefaultDisabledWatchCalculatorKeepsExistingCalculationAndWritesNoAdvice() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let calculator = PenDoseCalculatorViewModel(coreDataManager: fixture.core,
            logJournal: fixture.saveJournal, metadataStore: fixture.metadata,
            profileProvider: { fixture.profile }, sourceReadyOverride: { true },
            snapshotProvider: { date, _ in Fixture.snapshot(at: date) },
            carbohydrateAdviceJournal: fixture.evidence, forecastDefaults: fixture.forecastDefaults)
        calculator.carbohydratesText = "20"
        await calculator.calculate()
        XCTAssertNotNil(calculator.calculation)
        XCTAssertNil(calculator.carbohydrateAdvice)
        XCTAssertNil(calculator.currentCarbohydrateAdvice)
        XCTAssertNil(calculator.carbohydrateAdviceEditorRequest())
        XCTAssertTrue(fixture.treatments.isEmpty)
        let records = try await fixture.records()
        XCTAssertTrue(records.isEmpty)
    }

    func testAdviceExpiresAndStopDiscardsContextWithoutClearingEnteredAmounts() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let calculator = fixture.calculator()
        calculator.carbohydratesText = "12"
        calculator.insulinToLogText = "1,5"
        await calculator.calculate()
        let advice = try XCTUnwrap(calculator.currentCarbohydrateAdvice)
        XCTAssertNotNil(calculator.carbohydrateAdviceForDisplay(at: advice.computedAt.addingTimeInterval(29)))
        XCTAssertNil(calculator.carbohydrateAdviceEditorRequest(at: advice.computedAt.addingTimeInterval(31)))
        calculator.stop()
        XCTAssertNil(calculator.carbohydrateAdvice)
        XCTAssertNil(calculator.currentCarbohydrateAdvice)
        XCTAssertNil(calculator.carbohydrateAdviceEditorRequest())
        XCTAssertEqual(calculator.carbohydratesText, "12")
        XCTAssertEqual(calculator.insulinToLogText, "1,5")
    }

    func testSourceOrDraftChangeImmediatelyInvalidatesPreviouslyAvailableRequest() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let calculator = fixture.calculator()
        await calculator.calculate()
        XCTAssertEqual(calculator.currentCarbohydrateAdvice?.status, .estimated)
        calculator.carbohydratesText = "20"
        XCTAssertNil(calculator.currentCarbohydrateAdvice)
        XCTAssertNil(calculator.carbohydrateAdviceEditorRequest())
        await calculator.calculate()
        XCTAssertNotNil(calculator.currentCarbohydrateAdvice)
        UserDefaults.standard.nightscoutEnabled = true
        UserDefaults.standard.therapyDataSourceType = .nightscout
        XCTAssertNil(calculator.currentCarbohydrateAdvice)
        XCTAssertNil(calculator.carbohydrateAdviceEditorRequest())
    }

    func testManualGlucoseAndMissingSnapshotNeverOfferAutomaticCarbohydrates() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let calculator = fixture.calculator()
        calculator.glucoseChoice = .manual
        calculator.manualGlucoseText = "97"
        calculator.manualGlucoseDate = Date().addingTimeInterval(-60)
        await calculator.calculate()
        XCTAssertEqual(calculator.carbohydrateAdvice?.status, .manualGlucose)
        XCTAssertNil(calculator.carbohydrateAdviceEditorRequest())
        let missing = fixture.calculator(provider: { _, _ in .failure(.missingGlucose) })
        missing.insulinToLogText = "2"
        await missing.calculate()
        XCTAssertNil(missing.carbohydrateAdvice)
        XCTAssertNil(missing.carbohydrateAdviceEditorRequest())
        XCTAssertEqual(missing.insulinToLogText, "2")
        XCTAssertTrue(fixture.treatments.isEmpty)
    }

    func testLateOlderSnapshotCannotRestoreAdviceAfterNewerNoRiskCalculation() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var firstContinuation: CheckedContinuation<Void, Never>?
        let entered = expectation(description: "first snapshot suspended")
        var requests = 0
        let calculator = fixture.calculator(provider: { date, _ in
            requests += 1
            if requests == 1 {
                await withCheckedContinuation { continuation in
                    firstContinuation = continuation; entered.fulfill()
                }
                return Fixture.snapshot(at: date, glucose: 97, revision: 1)
            }
            return Fixture.snapshot(at: date, glucose: 140, revision: 2)
        })
        let older = Task { await calculator.calculate() }
        await fulfillment(of: [entered], timeout: 2)
        await calculator.calculate()
        XCTAssertEqual(calculator.currentCarbohydrateAdvice?.status, .noRisk)
        firstContinuation?.resume(); firstContinuation = nil
        await older.value
        XCTAssertEqual(calculator.currentCarbohydrateAdvice?.status, .noRisk)
        XCTAssertNil(calculator.carbohydrateAdviceEditorRequest())
        let records = try await fixture.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.treatmentRevision, 2)
    }

    func testEditorSavesOnlyActualFastCarbohydratesAndThenRecordsVerifiedEvidence() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let calculator = fixture.calculator()
        await calculator.calculate()
        let request = try XCTUnwrap(calculator.carbohydrateAdviceEditorRequest())
        let editor = fixture.editor(request)
        XCTAssertTrue(editor.isCarbohydrateAdviceEntry)
        XCTAssertEqual(editor.selectedType, .Carbs)
        XCTAssertEqual(editor.selectedMealKind, .fast)
        XCTAssertFalse(editor.isPlanningNewMeal)
        XCTAssertTrue(fixture.treatments.isEmpty, "Opening the editor never records consumption")
        editor.enteredValue = "11,5"
        editor.selectedDate = Date().addingTimeInterval(-60)
        let actualTime = editor.selectedDate
        XCTAssertTrue(editor.saveTreatment())
        let entry = try XCTUnwrap(fixture.treatments.first)
        XCTAssertEqual(fixture.treatments.count, 1)
        XCTAssertEqual(entry.treatmentType, .Carbs)
        XCTAssertEqual(entry.mealKind, .fast)
        XCTAssertTrue(entry.isConfirmedMeal)
        XCTAssertEqual(entry.value, 11.5)
        XCTAssertEqual(entry.date, actualTime)
        let records = try await fixture.records()
        let registered = try XCTUnwrap(records.first { $0.event == .registered })
        XCTAssertEqual(registered.treatmentID, entry.localTreatmentUUID)
        XCTAssertEqual(registered.actualCarbohydrateGrams, 11.5)
        XCTAssertEqual(registered.estimatedGrams, request.evidence.estimatedGrams)
        XCTAssertEqual(try XCTUnwrap(registered.treatmentDate).timeIntervalSince(actualTime), 0, accuracy: 0.001)
        XCTAssertFalse(fixture.treatments.contains { $0.treatmentType == .Insulin })
    }

    func testCancelledOrFailedEditorDoesNotClaimRegisteredCarbohydrates() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let calculator = fixture.calculator(); await calculator.calculate()
        let request = try XCTUnwrap(calculator.carbohydrateAdviceEditorRequest())
        _ = fixture.editor(request) // Open and discard: no save action.
        XCTAssertTrue(fixture.treatments.isEmpty)
        let failed = fixture.editor(request, saveOverride: { false })
        XCTAssertFalse(failed.saveTreatment())
        let records = try await fixture.records()
        XCTAssertTrue(records.allSatisfy { $0.event == .assessed })
        XCTAssertNotEqual(failed.localSaveGateState, .ready,
                          "An uncertain treatment store remains protected by its existing journal")
    }

    func testAdviceEditorRejectsTypePlanningAndSourceChangesBeforeAnySave() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let calculator = fixture.calculator(); await calculator.calculate()
        let request = try XCTUnwrap(calculator.carbohydrateAdviceEditorRequest())
        let editor = fixture.editor(request)
        editor.selectedType = .Insulin
        XCTAssertFalse(editor.canSaveTreatment); XCTAssertFalse(editor.saveTreatment())
        editor.selectedType = .Carbs
        editor.selectedMealKind = .slow
        XCTAssertFalse(editor.canSaveTreatment); XCTAssertFalse(editor.saveTreatment())
        editor.selectedMealKind = .fast
        editor.isPlanningNewMeal = true
        editor.selectedDate = Date().addingTimeInterval(900)
        XCTAssertFalse(editor.canSaveTreatment); XCTAssertFalse(editor.saveTreatment())
        editor.isPlanningNewMeal = false
        editor.selectedDate = Date()
        UserDefaults.standard.removeObject(forKey: TreatmentSourceCutover.defaultsKey)
        XCTAssertFalse(editor.canSaveTreatment); XCTAssertFalse(editor.saveTreatment())
        XCTAssertTrue(fixture.treatments.isEmpty)
        let records = try await fixture.records()
        XCTAssertTrue(records.allSatisfy { $0.event == .assessed })
    }
}
