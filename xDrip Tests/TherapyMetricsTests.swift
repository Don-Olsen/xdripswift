//
//  TherapyMetricsTests.swift
//  xdrip
//
//  Created by Paul Plant on 12/8/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
import SwiftUI
import CoreData
@testable import xdrip

final class TherapyMetricsTests: XCTestCase {
    func testPenProfileDanishDraftPreservesQuarterStepAndPreciseConfirmedValues() {
        var profile = PenDoseProfile.prefilledUnconfirmed
        profile.settings.penStepUnits = 0.25
        profile.settings.targetsMmol[0].value = 6.123456789012345
        profile.settings.targetsMmol[1].value = 7.750000000000001
        profile.settings.correctionMmolPerUnit = 0.12345678901234568
        profile.settings.carbohydrateRatios[1].value = 5.123456789012345
        XCTAssertTrue(profile.confirm())

        let draft = PenDoseProfileDraft(profile: profile)
        XCTAssertEqual(draft.step, "0,25")
        XCTAssertEqual(draft.targetDay, "6,123456789012345")
        XCTAssertEqual(draft.targetNight, "7,750000000000001")
        XCTAssertEqual(draft.correction, "0,12345678901234568")
        XCTAssertEqual(draft.settings, profile.settings,
                       "Opening and confirming without editing must not alter any profile value")
        XCTAssertEqual(draft.settings, profile.confirmedSettings)
    }

    func testPenDoseDanishDisplayAndCopyKeepQuarterUnitsAndUnknownValuesDistinct() {
        XCTAssertEqual(PenDoseDisplayFormatter.insulinInput(0), "0,0")
        XCTAssertEqual(PenDoseDisplayFormatter.insulinInput(2), "2,0")
        XCTAssertEqual(PenDoseDisplayFormatter.insulinInput(0.25), "0,25")
        XCTAssertEqual(PenDoseDisplayFormatter.insulinInput(2.75), "2,75")
        XCTAssertEqual(PenDoseDisplayFormatter.insulin(0.25), "0,25")
        XCTAssertEqual(PenDoseDisplayFormatter.carbs(32.5), "32,5")
        XCTAssertEqual(PenDoseDisplayFormatter.glucose(
            7.2 * PenBolusCalculator.mgdlPerMmol, mgdl: false), "7,2 mmol/L")
        XCTAssertEqual(PenDoseDisplayFormatter.glucose(100, mgdl: true), "100 mg/dL")
        XCTAssertEqual(PenDoseDisplayFormatter.number(.nan, maxDecimals: 3), "—")
        XCTAssertEqual(PenDoseDisplayFormatter.insulinInput(.infinity), "")
    }

    func testV34TreatmentStoreMigratesToV35WithLegacyMealDefaults() throws {
        let bundle = Bundle(for: TreatmentEntry.self)
        let modelDirectory = try XCTUnwrap(bundle.url(
            forResource: ConstantsCoreData.modelName, withExtension: "momd"))
        let oldModel = try XCTUnwrap(NSManagedObjectModel(contentsOf:
            modelDirectory.appendingPathComponent("xdrip v34.mom")))
        let newModel = try XCTUnwrap(NSManagedObjectModel(contentsOf:
            modelDirectory.appendingPathComponent("xdrip v35.mom")))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xdrip-v35-migration-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let oldStore = try oldCoordinator.addPersistentStore(ofType: NSSQLiteStoreType,
            configurationName: nil, at: url, options: nil)
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = oldCoordinator
        let row = NSEntityDescription.insertNewObject(forEntityName: "TreatmentEntry",
            into: oldContext)
        row.setValue(Date(timeIntervalSince1970: 1_800_000_000), forKey: "date")
        row.setValue(20.0, forKey: "value")
        row.setValue(TreatmentType.Carbs.rawValue, forKey: "treatmentType")
        row.setValue(TreatmentEntry.EmptyId, forKey: "id")
        row.setValue(false, forKey: "uploaded")
        try oldContext.save()
        oldContext.reset()
        try oldCoordinator.remove(oldStore)

        let newCoordinator = NSPersistentStoreCoordinator(managedObjectModel: newModel)
        _ = try newCoordinator.addPersistentStore(ofType: NSSQLiteStoreType,
            configurationName: nil, at: url, options: [
                NSMigratePersistentStoresAutomaticallyOption: true,
                NSInferMappingModelAutomaticallyOption: true
            ])
        let newContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        newContext.persistentStoreCoordinator = newCoordinator
        let migrated = try XCTUnwrap(newContext.fetch(TreatmentEntry.fetchRequest()).first)
        XCTAssertEqual(migrated.value, 20)
        XCTAssertNil(migrated.mealKindRaw)
        XCTAssertNil(migrated.carbohydrateDurationMinutes)
        XCTAssertEqual(migrated.effectiveCarbohydrateDurationMinutes, 240)
        XCTAssertTrue(migrated.isConfirmedMeal)
    }
    func testLegacyMealDefaultsToConfirmedNormalAndPlannedMealNeverCounts() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = core.mainManagedObjectContext
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let legacy = TreatmentEntry(date: at.addingTimeInterval(-60), value: 20,
            treatmentType: .Carbs, nightscoutEventType: nil, enteredBy: nil,
            nsManagedObjectContext: context)
        XCTAssertEqual(legacy.mealKind, .normal)
        XCTAssertEqual(legacy.effectiveCarbohydrateDurationMinutes, 240)
        XCTAssertTrue(legacy.isConfirmedMeal)
        let planned = TreatmentEntry(date: at.addingTimeInterval(30 * 60), value: 25,
            treatmentType: .Carbs, nightscoutEventType: nil, enteredBy: nil,
            nsManagedObjectContext: context)
        planned.localTreatmentUUID = UUID().uuidString
        planned.plannedMealStateRaw = TreatmentMealState.planned.rawValue
        planned.mealKindRaw = TreatmentMealKind.slow.rawValue
        planned.carbohydrateDurationMinutes = NSNumber(value: 300)
        let eligible = TherapyMetricsManager.eligibleTreatments([legacy, planned],
            policy: policy(), insulinSource: nil, carbsSource: nil,
            insulinEnabled: false, carbsEnabled: false)
        XCTAssertEqual(eligible.count, 1)
        XCTAssertTrue(eligible[0] === legacy)
        XCTAssertFalse(planned.isConfirmedMeal)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertFalse(TreatmentEntryAccessor(coreDataManager: core)
            .getLatestTreatmentsForNightscout(limit: 20).contains(planned))
    }

    func testStatisticsCountOnlyConsumedCarbohydrates() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = core.mainManagedObjectContext
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        func carbs(_ state: TreatmentMealState?) -> TreatmentEntry {
            let row = TreatmentEntry(date: at, value: 20, treatmentType: .Carbs,
                nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
            row.plannedMealStateRaw = state?.rawValue
            return row
        }
        XCTAssertTrue(StatisticsManager.isConsumedTreatment(carbs(nil)))
        XCTAssertTrue(StatisticsManager.isConsumedTreatment(carbs(.confirmed)))
        XCTAssertFalse(StatisticsManager.isConsumedTreatment(carbs(.planned)))
        XCTAssertFalse(StatisticsManager.isConsumedTreatment(carbs(.cancelled)))
        let insulin = TreatmentEntry(date: at, value: 2, treatmentType: .Insulin,
            nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
        XCTAssertTrue(StatisticsManager.isConsumedTreatment(insulin))
    }

    func testCutoverUsesImportedBeforeAndAppOriginAfterBoundary() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = core.mainManagedObjectContext
        let boundary = Date(timeIntervalSince1970: 1_800_000_000)
        let cutover = TreatmentSourceCutover(cutoff: boundary,
            insulinSourceBundleID: "com.mysugr", carbohydrateSourceBundleID: "com.mysugr")
        func imported(_ date: Date) -> TreatmentEntry {
            let entry = TreatmentEntry(date: date, value: 2, treatmentType: .Insulin,
                nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
            entry.healthKitSampleUUID = UUID().uuidString
            entry.healthKitSourceBundleIdentifier = "com.mysugr"
            return entry
        }
        func local(_ date: Date) -> TreatmentEntry {
            let entry = TreatmentEntry(date: date, value: 3, treatmentType: .Insulin,
                nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: context)
            entry.localTreatmentUUID = UUID().uuidString
            entry.createdAt = boundary
            return entry
        }
        let oldImported = imported(boundary.addingTimeInterval(-60))
        let lateImported = imported(boundary)
        let oldLocal = local(boundary.addingTimeInterval(-60))
        let newLocal = local(boundary)
        let watch = TreatmentEntry(date: boundary, value: 3, treatmentType: .Insulin,
            nightscoutEventType: nil, enteredBy: "xDrip4iOS Watch", nsManagedObjectContext: context)
        watch.watchSourceUUID = UUID().uuidString
        let secondWatch = TreatmentEntry(date: boundary, value: 3, treatmentType: .Insulin,
            nightscoutEventType: nil, enteredBy: "xDrip4iOS Watch", nsManagedObjectContext: context)
        secondWatch.watchSourceUUID = UUID().uuidString
        let watchBasal = TreatmentEntry(date: boundary, value: 12, treatmentType: .BasalInjection,
            nightscoutEventType: nil, enteredBy: "xDrip4iOS Watch", nsManagedObjectContext: context)
        watchBasal.watchSourceUUID = UUID().uuidString
        let selected = TherapyMetricsManager.eligibleTreatments(
            [oldImported, lateImported, oldLocal, newLocal, watch, secondWatch, watchBasal], policy: policy(),
            insulinSource: nil, carbsSource: nil,
            insulinEnabled: false, carbsEnabled: false, cutover: cutover)
        XCTAssertEqual(selected.count, 4)
        XCTAssertTrue(selected.contains { $0 === oldImported })
        XCTAssertTrue(selected.contains { $0 === newLocal })
        XCTAssertTrue(selected.contains { $0 === watch })
        XCTAssertTrue(selected.contains { $0 === secondWatch }, "distinct Watch UUIDs must not deduplicate")
        XCTAssertFalse(selected.contains { $0 === watchBasal })
    }

    func testCutoverRejectsExternalTherapyPolicyInsteadOfMixingLocalAndRemoteMetrics() {
        let cutover = TreatmentSourceCutover(cutoff: Date(timeIntervalSince1970: 1_800_000_000),
            insulinSourceBundleID: "com.mysugr", carbohydrateSourceBundleID: "com.mysugr")
        XCTAssertTrue(TherapyMetricsManager.cutoverPolicyIsConsistent(policy(), cutover: cutover))
        XCTAssertFalse(TherapyMetricsManager.cutoverPolicyIsConsistent(
            policy(therapy: .nightscout), cutover: cutover))
        XCTAssertFalse(TherapyMetricsManager.cutoverPolicyIsConsistent(
            policy(therapy: .careLink), cutover: cutover))
        XCTAssertTrue(TherapyMetricsManager.cutoverPolicyIsConsistent(
            policy(therapy: .nightscout), cutover: nil))
        let suite = "TherapyRestoreGate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey)
        XCTAssertFalse(TherapyMetricsManager.cutoverPolicyIsConsistent(
            policy(), cutover: nil, defaults: defaults))
        XCTAssertFalse(GlucoseForecastDataAdapter.sourceAllowsForecast(
            policy(), defaults: defaults))
        defaults.removeObject(forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey)
        XCTAssertTrue(GlucoseForecastDataAdapter.sourceAllowsForecast(
            policy(), defaults: defaults))
        defaults.set(Data("{invalid json".utf8), forKey: TreatmentSourceCutover.defaultsKey)
        XCTAssertFalse(TherapyMetricsManager.cutoverPolicyIsConsistent(
            policy(), cutover: TreatmentSourceCutover.current(defaults: defaults), defaults: defaults))
        XCTAssertFalse(GlucoseForecastDataAdapter.sourceAllowsForecast(
            policy(), defaults: defaults))
        defaults.removeObject(forKey: TreatmentSourceCutover.defaultsKey)
        XCTAssertTrue(TherapyMetricsManager.cutoverPolicyIsConsistent(
            policy(), cutover: nil, defaults: defaults))
    }

    func testPerMealDurationChangesCOBWithoutChangingBolus() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let start = at.addingTimeInterval(-60 * 60)
        let fast = TherapyTreatment(date: start, amount: 30, isIOB: false,
            carbohydrateDurationMinutes: 30)
        let slow = TherapyTreatment(date: start, amount: 30, isIOB: false,
            carbohydrateDurationMinutes: 300)
        let quick = TherapyMetricsManager.localMetric(entries: [fast], isIOB: false,
            date: at, settings: TherapyModelSettings()).value(at: at)
        let prolonged = TherapyMetricsManager.localMetric(entries: [slow], isIOB: false,
            date: at, settings: TherapyModelSettings()).value(at: at)
        XCTAssertEqual(quick, 0)
        XCTAssertGreaterThan(prolonged ?? 0, 0)
    }
    func testHomeRoutineRefreshAgesLastCompleteTreatmentsWithoutPartialInputs() throws {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let inputs = [TherapyTreatment(date: at.addingTimeInterval(-3600), amount: 100, isIOB: true),
                      TherapyTreatment(date: at.addingTimeInterval(-3600), amount: 500, isIOB: false)]
        let settings = TherapyModelSettings()
        let startingIOB = TherapyMetricsManager.localMetric(entries: inputs, isIOB: true,
            date: at, settings: settings).formatted(isIOB: true, at: at)
        let startingCOB = TherapyMetricsManager.localMetric(entries: inputs, isIOB: false,
            date: at, settings: settings).formatted(isIOB: false, at: at)
        var presentation = RootHomeTherapyRefreshPresentation()
        presentation.record(iob: RootHomeMetricState(title: "IOB", value: startingIOB),
            cob: RootHomeMetricState(title: "COB", value: startingCOB),
            showsIOB: true, showsCOB: true, iobIsLocal: true, cobIsLocal: true,
            treatments: inputs, settings: settings, sourceSignature: "same-source",
            nonHealthRevision: 4, at: at)
        let refresh = HealthTherapyRoutineRefreshState(generation: 1, startedAt: at,
            allEnabledKindsCommitted: false)
        let advanced = at.addingTimeInterval(20)
        let held = try XCTUnwrap(presentation.retained(refresh: refresh, metricsReady: false,
            pendingCommit: nil, sourceSignature: "same-source", nonHealthRevision: 4, at: advanced))
        XCTAssertEqual(held.iob.value, TherapyMetricsManager.localMetric(entries: inputs, isIOB: true,
            date: advanced, settings: settings).formatted(isIOB: true, at: advanced))
        XCTAssertEqual(held.cob.value, TherapyMetricsManager.localMetric(entries: inputs, isIOB: false,
            date: advanced, settings: settings).formatted(isIOB: false, at: advanced))
        XCTAssertNotEqual(held.cob.value, startingCOB, "normal time decay continues from frozen complete inputs")
        XCTAssertEqual(held.calculatedAt, at, "the displayed provenance stays dated to the complete snapshot")
        XCTAssertNil(presentation.retained(refresh: .init(generation: 1, startedAt: at,
            allEnabledKindsCommitted: true), metricsReady: true, pendingCommit: nil,
            sourceSignature: "same-source", nonHealthRevision: 4, at: advanced))
        XCTAssertNil(presentation.retained(refresh: refresh, metricsReady: false,
            pendingCommit: nil, sourceSignature: "changed-source", nonHealthRevision: 4, at: advanced))
    }

    func testManualPendingCommitProofEndsOnWriterFailureAndSuccessfulRetry() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let manager = TherapyMetricsManager()
        manager.configure(coreDataManager: core, externalStatus: { nil })
        let entry = TreatmentEntry(date: Date(), value: 2, treatmentType: .Insulin,
            nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: core.mainManagedObjectContext)
        XCTAssertTrue(core.saveChangesSynchronously())
        entry.value = 3
        try core.mainManagedObjectContext.save()
        let pending = try XCTUnwrap(manager.pendingHomeTreatmentCommitState())
        XCTAssertTrue(manager.hasUncommittedForecastInputChanges)
        XCTAssertNil(manager.pendingHomeTreatmentCommitState(at: pending.startedAt.addingTimeInterval(30)))
        NotificationCenter.default.post(name: .coreDataContextSaveFailed,
                                        object: core.privateManagedObjectContext)
        XCTAssertNil(manager.pendingHomeTreatmentCommitState())
        XCTAssertTrue(manager.hasUncommittedForecastInputChanges,
                      "a failed save remains unavailable to strict therapy calculations")
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertNil(manager.pendingHomeTreatmentCommitState())
        XCTAssertFalse(manager.hasUncommittedForecastInputChanges)
    }

    func testTreatmentMasterPreservesSummaryAndCurvePreferences() throws {
        let defaults = UserDefaults.standard
        let previous = (defaults.showTreatmentsOnChart, defaults.showTherapySummary, defaults.showIOBCOB)
        defer {
            defaults.showTreatmentsOnChart = previous.0
            defaults.showTherapySummary = previous.1
            defaults.showIOBCOB = previous.2
        }
        defaults.showTherapySummary = true
        defaults.showIOBCOB = true
        let layout = SettingsViewHomeScreenSettingsViewModel(rowGroup: .layout)
        let treatments = SettingsViewHomeScreenSettingsViewModel(rowGroup: .treatments)
        for enabled in [false, true] {
            defaults.showTreatmentsOnChart = enabled
            let summary = try XCTUnwrap(layout.settingsRows(sectionID: 0).first { $0.id == "homeScreen.showTherapySummary" })
            XCTAssertTrue(summary.isVisible)
            XCTAssertEqual(summary.isEnabled, enabled)
            let rows = treatments.settingsRows(sectionID: 1)
            let chartChildren = rows.filter { ["homeScreen.showIOBCOB", "homeScreen.renderBasalDownwards"].contains($0.id) }
            XCTAssertEqual(chartChildren.count, 2)
            XCTAssertTrue(chartChildren.allSatisfy { $0.isVisible == enabled })
            XCTAssertTrue(rows.contains { $0.id == "homeScreen.quickCarbohydrateGrams" && $0.isVisible },
                          "Local quick-carbohydrate setup is independent of chart visibility")
            XCTAssertTrue(defaults.showTherapySummary)
            XCTAssertTrue(defaults.showIOBCOB)
        }
    }

    func testPumpCageRequiresSiteChangeButNotFreshDeviceStatus() {
        let model = RootHomeStateModel()
        XCTAssertNil(model.pumpState(deviceStatus: nil, latestSiteChangeDate: nil).cage)
        let pump = model.pumpState(deviceStatus: nil, latestSiteChangeDate: now.addingTimeInterval(-3600),
                                   referenceDate: now, usesRelativeCageTime: false)
        XCTAssertNotNil(pump.cage)
        XCTAssertNotEqual(pump.cage?.value, "-")
    }

    func testLiveActivityMetricsPreferenceIsIndependentOfChartPreference() {
        let suite = "LiveActivityMetricsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(defaults.liveActivityShowIOBCOB)
        defaults.showIOBCOB = false
        XCTAssertTrue(defaults.liveActivityShowIOBCOB)
        defaults.liveActivityShowIOBCOB = false
        defaults.showIOBCOB = true
        XCTAssertFalse(defaults.liveActivityShowIOBCOB)
    }

    func testLiveActivityMetricsVisibilityPreservesStatusAndOldPayloads() throws {
        let status = AIDStatus(condition: .active, style: .loop, statusUpdatedAt: .now,
            lastActivityAt: .now, iob: 1.8, cob: 18, statusTitle: "Looping", staleStatusTitle: "No data")
        var state = XDripWidgetAttributes.ContentState(bgReadingValues: [120], bgReadingDates: [.now],
            isMgDl: true, slopeOrdinal: 4, deltaValueInUserUnit: 0,
            urgentLowLimitInMgDl: 55, lowLimitInMgDl: 70, highLimitInMgDl: 180,
            urgentHighLimitInMgDl: 250, liveActivityType: .large, aidStatus: status)
        XCTAssertTrue(state.showsTherapyMetrics)
        state.showIOBCOB = false
        XCTAssertFalse(state.showsTherapyMetrics)
        XCTAssertNotNil(state.deviceStatusIconImage())
        let encoded = try JSONEncoder().encode(state)
        XCTAssertFalse(try JSONDecoder().decode(XDripWidgetAttributes.ContentState.self, from: encoded).showsTherapyMetrics)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "showIOBCOB")
        let decoded = try JSONDecoder().decode(XDripWidgetAttributes.ContentState.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(decoded.showsTherapyMetrics)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var settings: TherapyModelSettings {
        TherapyModelSettings()
    }
    private func policy(therapy: TherapyDataSourceType = .none, follow: NightscoutFollowType = .none) -> DataFlowPolicy {
        DataFlowPolicy(isMaster: therapy != .careLink, followerDataSource: .careLink,
            therapyDataSourceSelection: therapy, nightscoutEnabled: therapy == .nightscout,
            masterUploadsGlucoseToNightscout: false, followerUploadsGlucoseToNightscout: false,
            nightscoutFollowType: follow)
    }
    private func entry(_ amount: Double, minutesAgo: Double = 0, isIOB: Bool = true) -> TherapyTreatment {
        TherapyTreatment(date: now.addingTimeInterval(-minutesAgo * 60), amount: amount, isIOB: isIOB)
    }
    private func metric(_ entries: [TherapyTreatment]?, isIOB: Bool = true, at date: Date? = nil) -> TherapyMetricState {
        TherapyMetricsManager.localMetric(entries: entries, isIOB: isIOB, date: date ?? now, settings: settings)
    }

    // Values generated by executing the pinned oref0 JS with JavaScriptCore, not the Swift port.
    func testOpenAPSReferenceParity() {
        let reference: [(Double, Double)] = [(0, 1), (15, 0.9788245454057859), (30, 0.9249701856314995),
            (60, 0.7640057035577161), (75, 0.6726398904581075), (120, 0.41057994214803406),
            (180, 0.15879641537283806), (240, 0.032924868796628814), (299, 0.00000741451802288573), (300, 0)]
        for (minutes, expected) in reference {
            XCTAssertEqual(TherapyCalculations.insulinRemaining(units: 1, minutes: minutes, duration: 300, peak: 75), expected, accuracy: 1e-12)
        }
    }

    func testInsulinBoundariesAndContinuousTime() {
        XCTAssertEqual(TherapyCalculations.insulinRemaining(units: 3, minutes: -1, duration: 300, peak: 75), 0)
        XCTAssertEqual(TherapyCalculations.insulinRemaining(units: 3, minutes: 0, duration: 300, peak: 75), 3)
        XCTAssertEqual(TherapyCalculations.insulinRemaining(units: 3, minutes: 301, duration: 300, peak: 75), 0)
        XCTAssertNotEqual(TherapyCalculations.insulinRemaining(units: 3, minutes: 60.1, duration: 300, peak: 75),
                          TherapyCalculations.insulinRemaining(units: 3, minutes: 60.2, duration: 300, peak: 75))
    }

    func testEveryAllowedInsulinCombinationIsBoundedAndMonotonic() {
        for duration in stride(from: 180.0, through: 600, by: 30) {
            for peak in stride(from: 35.0, through: 120, by: 5) where peak * 2 < duration {
                var previous = 1.0
                for minute in stride(from: 0.0, through: duration, by: 0.5) {
                    let remaining = TherapyCalculations.insulinRemaining(units: 1, minutes: minute, duration: duration, peak: peak)
                    XCTAssertTrue(remaining.isFinite)
                    XCTAssertGreaterThanOrEqual(remaining, 0)
                    XCTAssertLessThanOrEqual(remaining, previous + 1e-12)
                    previous = remaining
                }
                XCTAssertEqual(previous, 0)
            }
        }
    }

    func testLoopKitAbsorptionBoundaries() {
        // Pinned PiecewiseLinearAbsorption: rise=.15, fall=.5, scale=2/1.35.
        let reference: [(Double, Double)] = [(-1, 0), (0, 60), (10, 60),
            (37, 53.333333333333336), (100, 22.22222222222222), (190, 0), (250, 0)]
        for (minute, grams) in reference {
            XCTAssertEqual(TherapyCalculations.carbsRemaining(grams: 60, minutes: minute, duration: 180), grams, accuracy: 1e-10)
        }
    }

    func testCarbDurationsAreMonotonicAndScaleWithMealSize() {
        for duration in stride(from: 60.0, through: 480, by: 30) {
            var previous = 10.0
            for minute in stride(from: 0.0, through: duration + 10, by: 1) {
                let remaining = TherapyCalculations.carbsRemaining(grams: 10, minutes: minute, duration: duration)
                XCTAssertLessThanOrEqual(remaining, previous + 1e-12)
                XCTAssertGreaterThanOrEqual(remaining, 0)
                XCTAssertEqual(TherapyCalculations.carbsRemaining(grams: 20, minutes: minute, duration: duration), remaining * 2, accuracy: 1e-12)
                previous = remaining
            }
            XCTAssertEqual(previous, 0)
        }
    }

    func testDefaultInsulinRemainsActiveBeyondFiveHoursAndEndsAtTen() throws {
        XCTAssertTrue(settings.validInsulin)
        for preset in TherapyInsulinPreset.allCases {
            var model = settings
            model.insulinPeak = preset.peak
            let tail = TherapyMetricsManager.localMetric(entries: [entry(2, minutesAgo: 301)],
                isIOB: true, date: now, settings: model)
            XCTAssertGreaterThan(try XCTUnwrap(tail.value(at: now)), 0)
            for elapsed in [600.0, 601.0] {
                let finished = TherapyMetricsManager.localMetric(entries: [entry(2, minutesAgo: elapsed)],
                    isIOB: true, date: now, settings: model)
                XCTAssertEqual(finished.value(at: now), 0)
                XCTAssertTrue(finished.isVisible(at: now))
            }
        }
    }

    func testOverlappingTreatmentsAreSummedWithoutAmountTimeDeduplication() throws {
        let treatments = [entry(2), entry(2), entry(30, isIOB: false), entry(20, isIOB: false)]
        XCTAssertEqual(try XCTUnwrap(metric(treatments).value(at: now)), 4)
        XCTAssertEqual(try XCTUnwrap(metric(treatments, isIOB: false).value(at: now)), 50)
    }

    func testVisibilityIsSharedAndExpiresAtExactly24Hours() throws {
        let treatments = [entry(2, minutesAgo: 1439)]
        XCTAssertEqual(try XCTUnwrap(metric(treatments).value(at: now)), 0)
        XCTAssertEqual(try XCTUnwrap(metric(treatments, isIOB: false).value(at: now)), 0)
        XCTAssertTrue(metric(treatments).isVisible(at: now.addingTimeInterval(59)))
        XCTAssertFalse(metric(treatments).isVisible(at: now.addingTimeInterval(60)))
        XCTAssertEqual(metric(treatments, at: now.addingTimeInterval(60)).reason, .noTreatments)
    }

    func testHistoricalVisibilityBeforeAndAfterTreatmentDoesNotCountItEarly() throws {
        let treatment = entry(2, minutesAgo: 3 * 24 * 60)
        let window = TherapyModelSettings.visibilityInterval
        func historical(_ offset: TimeInterval, isIOB: Bool = true) -> TherapyMetricState {
            TherapyMetricsManager.localMetric(entries: [treatment], isIOB: isIOB,
                date: treatment.date.addingTimeInterval(offset), settings: settings, currentDate: now)
        }
        XCTAssertEqual(historical(-window).reason, .noTreatments)
        let before = treatment.date.addingTimeInterval(-window + 1)
        XCTAssertEqual(try XCTUnwrap(historical(-window + 1).value(at: before)), 0)
        XCTAssertEqual(try XCTUnwrap(historical(-window + 1, isIOB: false).value(at: before)), 0)
        XCTAssertEqual(try XCTUnwrap(historical(0).value(at: treatment.date)), 2)
        XCTAssertEqual(try XCTUnwrap(historical(window - 1).value(at: treatment.date.addingTimeInterval(window - 1))), 0)
        XCTAssertEqual(historical(window).reason, .noTreatments)
    }

    func testRecentTreatmentKeepsBothLocalMetricsVisibleThroughoutHistory() throws {
        let date = now.addingTimeInterval(-10 * TherapyModelSettings.visibilityInterval)
        for isIOB in [true, false] {
            let state = TherapyMetricsManager.localMetric(entries: [], isIOB: isIOB, date: date,
                settings: settings, currentDate: now, recentEntries: [entry(20, isIOB: false)])
            XCTAssertEqual(try XCTUnwrap(state.value(at: date)), 0)
        }
        let failed = TherapyMetricsManager.localMetric(entries: [], isIOB: true, date: date,
            settings: settings, currentDate: now, recentEntries: nil)
        XCTAssertEqual(failed.reason, .readFailed)
    }

    func testUnconfirmedLocalHistoryNeverShowsTheRow() {
        for isIOB in [true, false] {
            for entries: [TherapyTreatment]? in [nil, [], nil, []] {
                let state = metric(entries, isIOB: isIOB)
                XCTAssertFalse(state.isVisible(at: now))
                XCTAssertNil(state.value(at: now))
            }
            let missingRecent = TherapyMetricsManager.localMetric(entries: [], isIOB: isIOB,
                date: now, settings: settings, currentDate: now, recentEntries: nil)
            XCTAssertFalse(missingRecent.isVisible(at: now))
            XCTAssertEqual(missingRecent.reason, .readFailed)
        }
    }

    func testConfirmedLocalWindowStaysVisibleDuringIncompleteReads() {
        let historicalDate = now.addingTimeInterval(-10 * TherapyModelSettings.visibilityInterval)
        for isIOB in [true, false] {
            let loading = TherapyMetricsManager.localMetric(entries: nil, isIOB: isIOB,
                date: historicalDate, settings: settings, currentDate: now,
                recentEntries: [entry(20, isIOB: false)])
            XCTAssertTrue(loading.isVisible(at: historicalDate))
            XCTAssertNil(loading.value(at: historicalDate))
            XCTAssertEqual(loading.reason, .readFailed)
            let loaded = TherapyMetricsManager.localMetric(entries: [], isIOB: isIOB,
                date: historicalDate, settings: settings, currentDate: now,
                recentEntries: [entry(20, isIOB: false)])
            XCTAssertTrue(loaded.isVisible(at: historicalDate))
            XCTAssertEqual(loaded.value(at: historicalDate), 0)
            let missingRecent = TherapyMetricsManager.localMetric(entries: [entry(2)], isIOB: isIOB,
                date: now, settings: settings, currentDate: now, recentEntries: nil)
            XCTAssertTrue(missingRecent.isVisible(at: now))
            XCTAssertNil(missingRecent.value(at: now))
        }
    }

    func testHomeKeepsConfirmedTherapyStripDuringCacheMissWithoutReusingAmount() throws {
        let confirmed = metric([entry(2)])
        let deadline = try XCTUnwrap(confirmed.visibilityDeadline)
        let cacheMiss = metric(nil)
        XCTAssertEqual(cacheMiss.reason, .readFailed)
        XCTAssertFalse(cacheMiss.isVisible(at: now))
        XCTAssertEqual(RootHomeStateModel.retainingConfirmedLocalVisibility(cacheMiss, from: nil, at: now), cacheMiss)

        let waiting = RootHomeStateModel.retainingConfirmedLocalVisibility(cacheMiss, from: confirmed, at: now)
        XCTAssertTrue(waiting.isVisible(at: now))
        XCTAssertNil(waiting.value(at: now))
        XCTAssertNil(waiting.amount)
        XCTAssertEqual(waiting.formatted(isIOB: true, at: now), "- U")

        let loaded = metric([entry(1)])
        XCTAssertEqual(RootHomeStateModel.retainingConfirmedLocalVisibility(loaded, from: waiting, at: now), loaded)
        let expired = RootHomeStateModel.retainingConfirmedLocalVisibility(cacheMiss, from: confirmed, at: deadline)
        XCTAssertFalse(expired.isVisible(at: deadline))
        XCTAssertNil(expired.visibilityDeadline)
    }

    func testHomeShowsRecentConfirmedLocalValueAsLastCalculatedDuringShortRefresh() {
        var presentation = RootHomeLocalMetricPresentation()
        let confirmed = metric([entry(2)])
        let input = RootHomeMetricState(title: "IOB", value: "- U")
        let initial = presentation.display(confirmed, in: input, sourceSignature: "local-a",
            isIOB: true, at: now)
        XCTAssertEqual(initial.value, "2 U")
        XCTAssertNil(initial.lastCalculatedAt)

        let firstRefresh = presentation.display(metric(nil), in: input, sourceSignature: "local-a",
            isIOB: true, at: now.addingTimeInterval(10))
        XCTAssertEqual(firstRefresh.value, "2 U")
        XCTAssertEqual(firstRefresh.lastCalculatedAt, now)
        // Repeated foreground publications must not lose the last confirmed Home value.
        let repeatedRefresh = presentation.display(metric(nil), in: input, sourceSignature: "local-a",
            isIOB: true, at: now.addingTimeInterval(30))
        XCTAssertEqual(repeatedRefresh.value, "2 U")
        XCTAssertEqual(repeatedRefresh.lastCalculatedAt, now)

        let completed = presentation.display(metric([entry(1)]), in: input,
            sourceSignature: "local-a", isIOB: true, at: now.addingTimeInterval(31))
        XCTAssertNotEqual(completed.value, "- U")
        XCTAssertNil(completed.lastCalculatedAt)
        XCTAssertEqual(completed.valueColor, ConstantsAppColors.primaryText)
        XCTAssertNil(metric(nil).value(at: now), "The underlying clinical metric must remain unavailable")
    }

    func testHomeClearsLastCalculatedValuesWhenTreatmentsChangeDuringReadFailure() {
        let model = RootHomeStateModel()
        let initialSignature = model.currentLocalTherapySourceSignature()
        let shared = TherapyMetricsManager.shared
        var iobPresentation = RootHomeLocalMetricPresentation()
        var cobPresentation = RootHomeLocalMetricPresentation()
        let iobInput = RootHomeMetricState(title: "IOB", value: "- U")
        let cobInput = RootHomeMetricState(title: "COB", value: "- g")
        _ = iobPresentation.display(metric([entry(2)]), in: iobInput,
            sourceSignature: initialSignature, isIOB: true, at: now)
        _ = cobPresentation.display(metric([entry(20, isIOB: false)], isIOB: false), in: cobInput,
            sourceSignature: initialSignature, isIOB: false, at: now)

        shared.invalidate(treatmentsChanged: false)
        XCTAssertEqual(model.currentLocalTherapySourceSignature(), initialSignature,
            "A status-only refresh must not discard confirmed treatment amounts")
        let waitingIOB = iobPresentation.display(metric(nil), in: iobInput,
            sourceSignature: initialSignature, isIOB: true, at: now.addingTimeInterval(5))
        XCTAssertEqual(waitingIOB.value, "2 U")
        XCTAssertEqual(waitingIOB.lastCalculatedAt, now)

        shared.invalidate()
        let changedSignature = model.currentLocalTherapySourceSignature()
        XCTAssertNotEqual(changedSignature, initialSignature)
        let staleIOB = iobPresentation.display(metric(nil), in: iobInput,
            sourceSignature: changedSignature, isIOB: true, at: now.addingTimeInterval(10))
        let staleCOB = cobPresentation.display(metric(nil, isIOB: false), in: cobInput,
            sourceSignature: changedSignature, isIOB: false, at: now.addingTimeInterval(10))
        XCTAssertEqual(staleIOB.value, "- U")
        XCTAssertEqual(staleCOB.value, "- g")
        XCTAssertNil(staleIOB.lastCalculatedAt)
        XCTAssertNil(staleCOB.lastCalculatedAt)
        XCTAssertEqual(metric(nil).reason, .readFailed)
    }

    func testHomeDoesNotRetainValueAfterAgeSourceOrDefinitiveInputChange() {
        let input = RootHomeMetricState(title: "COB", value: "- g")
        let confirmed = metric([entry(20, isIOB: false)], isIOB: false)
        let loading = metric(nil, isIOB: false)
        var presentation = RootHomeLocalMetricPresentation()
        _ = presentation.display(confirmed, in: input, sourceSignature: "local-a", isIOB: false, at: now)

        let expired = presentation.display(loading, in: input, sourceSignature: "local-a",
            isIOB: false, at: now.addingTimeInterval(RootHomeLocalMetricPresentation.maximumRetainedAge))
        XCTAssertEqual(expired.value, "- g")
        XCTAssertNil(expired.lastCalculatedAt)

        _ = presentation.display(confirmed, in: input, sourceSignature: "local-a", isIOB: false, at: now)
        let changedSource = presentation.display(loading, in: input, sourceSignature: "local-b",
            isIOB: false, at: now.addingTimeInterval(5))
        XCTAssertEqual(changedSource.value, "- g")

        _ = presentation.display(confirmed, in: input, sourceSignature: "local-a", isIOB: false, at: now)
        let noTreatments = presentation.display(metric([], isIOB: false), in: input,
            sourceSignature: "local-a", isIOB: false, at: now.addingTimeInterval(5))
        XCTAssertEqual(noTreatments.value, "- g")
        let laterReadFailure = presentation.display(loading, in: input,
            sourceSignature: "local-a", isIOB: false, at: now.addingTimeInterval(6))
        XCTAssertNil(laterReadFailure.lastCalculatedAt)
    }

    func testLocalValuesHaveNoApproximationSymbol() {
        XCTAssertEqual(metric([entry(2)]).formatted(isIOB: true, at: now), "2 U")
        XCTAssertEqual(metric([entry(20, isIOB: false)], isIOB: false).formatted(isIOB: false, at: now), "20 g")
        XCTAssertEqual(metric([entry(2, minutesAgo: settings.insulinDuration + 1)]).formatted(isIOB: true, at: now), "0 U")
    }

    func testNoHistoryAndReadFailureAreDifferent() {
        XCTAssertEqual(metric([]).reason, .noTreatments)
        XCTAssertFalse(metric([]).isVisible(at: now))
        XCTAssertEqual(metric(nil).reason, .readFailed)
        XCTAssertNil(metric(nil).value(at: now))
    }

    func testFutureAndInvalidAmountsDoNotEnableVisibility() {
        let treatments = [entry(2, minutesAgo: -1), entry(.nan), entry(.infinity), entry(-2), entry(0)]
        XCTAssertEqual(metric(treatments).reason, .noTreatments)
    }

    func testLocalSnapshotExpiresAt17Minutes() {
        let snapshot = metric([entry(2)])
        XCTAssertNotNil(snapshot.value(at: now.addingTimeInterval(1019)))
        XCTAssertNil(snapshot.value(at: now.addingTimeInterval(1020)))
        XCTAssertTrue(snapshot.isVisible(at: now.addingTimeInterval(1020)))
        XCTAssertNil(snapshot.value(at: now.addingTimeInterval(-61)))
    }

    func testCareLinkIOBAndLocalCOBAreIndependent() throws {
        let external = AIDStatus(condition: .active, style: .careLinkIOB, statusUpdatedAt: now,
            lastActivityAt: now, iob: 1.5, cob: nil, statusTitle: "", staleStatusTitle: "")
        let result = TherapyMetricsManager.resolve(at: now, external: external, policy: policy(therapy: .careLink),
            settings: settings, entries: [entry(10), entry(30, isIOB: false)])
        XCTAssertEqual(result.iob.source, .careLink)
        XCTAssertEqual(try XCTUnwrap(result.iob.value(at: now)), 1.5)
        XCTAssertEqual(result.cob.source, .local)
        XCTAssertEqual(try XCTUnwrap(result.cob.value(at: now)), 30)
    }

    func testExternalOutagesNeverUseLocalFallback() {
        for source in [TherapyDataSourceType.careLink, .nightscout] {
            let result = TherapyMetricsManager.resolve(at: now, external: nil,
                policy: policy(therapy: source, follow: .openAPS), settings: settings,
                entries: [entry(10), entry(30, isIOB: false)])
            XCTAssertNil(result.iob.value(at: now))
            XCTAssertEqual(result.iob.reason, .missingExternalData)
            if source == .nightscout {
                XCTAssertNil(result.cob.value(at: now))
                XCTAssertEqual(result.cob.reason, .missingExternalData)
            }
        }
    }

    func testExternalNegativeAndZeroValuesDoNotRequireTreatments() throws {
        let status = AIDStatus(condition: .active, style: .loop, statusUpdatedAt: now,
            lastActivityAt: now, iob: -0.5, cob: 0, statusTitle: "", staleStatusTitle: "")
        let result = TherapyMetricsManager.resolve(at: now, external: status,
            policy: policy(therapy: .nightscout, follow: .openAPS), settings: settings, entries: [])
        XCTAssertEqual(try XCTUnwrap(result.iob.value(at: now)), -0.5)
        XCTAssertEqual(try XCTUnwrap(result.cob.value(at: now)), 0)
        XCTAssertTrue(result.cob.isVisible(at: now))
        XCTAssertNil(result.iob.value(at: now.addingTimeInterval(1020)))
    }

    func testDefaultSettingsCalculateAutomaticallyAndInvalidCombinationsAreRejected() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let value = TherapyModelSettings(defaults: defaults)
        XCTAssertNotNil(TherapyMetricsManager.localMetric(entries: [entry(2)], isIOB: true, date: now, settings: value).value(at: now))
        XCTAssertEqual(value.insulinDuration, 600)
        XCTAssertEqual(value.insulinPeak, 75)
        XCTAssertEqual(value.carbDuration, 240)
        var invalid = settings
        invalid.insulinDuration = 180
        invalid.insulinPeak = 90
        XCTAssertFalse(invalid.validInsulin)
        XCTAssertEqual(TherapyMetricsManager.localMetric(entries: [entry(2)], isIOB: true, date: now, settings: invalid).reason, .invalidSettings)
    }

    func testLegacyDisabledPreferencesDoNotSuppressAutomaticMetrics() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "calculateLocalIOB")
        defaults.set(false, forKey: "calculateLocalCOB")
        defaults.set(55.0, forKey: "localInsulinPeak")
        defaults.set(300.0, forKey: "localCarbDuration")
        let savedSettings = TherapyModelSettings(defaults: defaults)
        let entries = [entry(2), entry(20, isIOB: false)]
        let local = TherapyMetricsManager.resolve(at: now, external: nil, policy: policy(), settings: savedSettings, entries: entries)
        XCTAssertEqual(local.iob.value(at: now), 2)
        XCTAssertEqual(local.cob.value(at: now), 20)
        XCTAssertEqual(savedSettings.insulinPeak, 55)
        XCTAssertEqual(savedSettings.carbDuration, 300)

        let external = TherapyMetricsManager.resolve(at: now, external: nil,
            policy: policy(therapy: .nightscout, follow: .openAPS), settings: savedSettings, entries: entries)
        XCTAssertEqual(external.iob.reason, .missingExternalData)
        XCTAssertEqual(external.cob.reason, .missingExternalData)
        XCTAssertNil(external.iob.value(at: now))
        XCTAssertNil(external.cob.value(at: now))
        XCTAssertEqual(TherapyModelSettings(defaults: defaults), savedSettings)
    }

    func testSourceSwitchDoesNotMutateLocalPreferences() {
        let result = TherapyMetricsManager.resolve(at: now, external: nil, policy: policy(), settings: settings, entries: [entry(2)])
        XCTAssertEqual(result.iob.source, .local)
        XCTAssertNotNil(result.iob.value(at: now))
        XCTAssertEqual(settings.insulinPeak, 75)
    }

    func testSharedPayloadRoundTripAndLegacyWatchPayload() throws {
        let snapshot = TherapyMetricsSnapshot(iob: metric([entry(2)]), cob: metric([], isIOB: false))
        XCTAssertEqual(try JSONDecoder().decode(TherapyMetricsSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        var status = WatchStatus()
        status.therapyMetrics = snapshot
        let data = try JSONEncoder().encode(status)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "therapyMetrics")
        let legacy = try JSONDecoder().decode(WatchStatus.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.therapyMetrics)
    }

    @MainActor func testStoredInputSelectionExcludesBasalAndDeletedEntriesAndPreservesDuplicates() async throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let manager = TherapyMetricsManager()
        manager.configure(coreDataManager: core, externalStatus: { nil })
        for type in [TreatmentType.Insulin, .Insulin, .Carbs, .BasalInjection, .Basal, .AutomaticBasal] {
            _ = TreatmentEntry(date: now, value: 2, treatmentType: type, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: core.mainManagedObjectContext)
        }
        let deleted = TreatmentEntry(date: now, value: 99, treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: core.mainManagedObjectContext)
        deleted.treatmentdeleted = true
        XCTAssertTrue(core.saveChangesSynchronously())
        let entries = try await readInputs(manager)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(try XCTUnwrap(metric(entries).value(at: now)), 4)
        deleted.treatmentdeleted = false
        XCTAssertTrue(core.saveChangesSynchronously())
        let changed = try await readInputs(manager)
        XCTAssertEqual(changed.count, 4)
        XCTAssertEqual(try XCTUnwrap(metric(changed).value(at: now)), 103)
    }
    func testChartKeepsZeroHistoryAndJumpsAtTreatmentWithoutBridgingHiddenIntervals() {
        let entries = [entry(2, minutesAgo: 60)]
        let start = now.addingTimeInterval(-7200)
        let end = now.addingTimeInterval(86400)
        let result = TherapyMetricsManager.chartSeries(entries: entries, statuses: [], policy: policy(), settings: settings, start: start, end: end)
        XCTAssertFalse(result.cob.isEmpty)
        XCTAssertTrue(result.cob.allSatisfy { $0.amount == 0 })
        XCTAssertEqual(result.iob.first?.date, start)
        XCTAssertEqual(result.iob.first?.amount, 0)
        XCTAssertEqual(result.iob.filter { $0.date == entries[0].date }.map(\.amount), [0, 2])
        XCTAssertEqual(result.iob.last?.amount, 0)
        XCTAssertLessThan(result.iob.last!.date, entries[0].date.addingTimeInterval(86400))
        let second = entry(1)
        let overlapping = TherapyMetricsManager.chartSeries(entries: entries + [second], statuses: [], policy: policy(), settings: settings, start: start, end: end)
        let before = overlapping.iob.last { $0.date < now }
        let after = overlapping.iob.first { $0.date == now }
        XCTAssertEqual(before?.segment, after?.segment)
        let jump = overlapping.iob.filter { $0.date == now }
        XCTAssertEqual(jump.count, 2)
        XCTAssertEqual(jump[1].amount - jump[0].amount, 1, accuracy: 1e-12)
        XCTAssertGreaterThan(jump[0].amount, 0)
        XCTAssertEqual(Set(overlapping.iob.map(\.id)).count, overlapping.iob.count)
    }

    private func status(_ minute: Double, _ iob: Double?, calculatedMinute: Double? = nil) -> NightscoutDeviceStatusSnapshot {
        let date = now.addingTimeInterval(minute * 60)
        return NightscoutDeviceStatusSnapshot(id: "\(minute)", createdAt: date, updatedDate: date, lastCheckedDate: date, lastLoopDate: date, timestamp: calculatedMinute.map { now.addingTimeInterval($0 * 60) }, device: nil, appVersion: nil, activeProfile: nil, iob: iob, cob: nil, eventualBG: nil, currentTarget: nil, isf: nil, insulinReq: nil, bolusVolume: nil, rate: nil, duration: nil, reason: nil, sensitivityRatio: nil, tdd: nil, error: nil, overrideActive: nil, overrideName: nil, overrideMinValue: nil, overrideMaxValue: nil, overrideMultiplier: nil, pumpBatteryPercent: nil, pumpReservoir: nil, pumpIsBolusing: nil, pumpIsSuspended: nil, pumpStatus: nil, pumpStatusTimestamp: nil, pumpManufacturer: nil, pumpModel: nil, uploaderBatteryPercent: nil, uploaderIsCharging: nil)
    }

    func testExternalChartIgnoresIncompleteRowsAndJoinsShortGaps() {
        let records = [status(40, 1), status(5, nil), status(15, 2), status(10, nil), status(5, 0), status(0, -1)]
        let result = TherapyMetricsManager.chartSeries(entries: [entry(99), entry(99, isIOB: false)], statuses: records,
            policy: policy(therapy: .nightscout, follow: .openAPS), settings: settings,
            start: now, end: now.addingTimeInterval(3600))
        XCTAssertEqual(result.iob.map(\.amount), [-1, 0, 2, 1, 1])
        XCTAssertEqual(result.iob[0].segment, result.iob[2].segment)
        XCTAssertEqual(result.iob[2].segment, result.iob[3].segment)
        XCTAssertLessThan(result.iob.last!.date, now.addingTimeInterval(57 * 60))
        XCTAssertEqual(Set(result.iob.map(\.id)).count, result.iob.count)
        XCTAssertTrue(result.cob.isEmpty)

        let clippedStart = now.addingTimeInterval(2.5 * 60)
        let clipped = TherapyMetricsManager.externalChartPoints(statuses: records, isIOB: true,
            start: clippedStart, end: now.addingTimeInterval(20 * 60))
        XCTAssertEqual(clipped.first?.date, clippedStart)
        XCTAssertEqual(clipped.first?.amount, -0.5)
        XCTAssertEqual(clipped.last?.date, now.addingTimeInterval(20 * 60))
        XCTAssertEqual(clipped.last?.amount, 2)

        let expired = TherapyMetricsManager.externalChartPoints(statuses: [status(0, 2)], isIOB: true,
            start: now.addingTimeInterval(17 * 60), end: now.addingTimeInterval(20 * 60))
        XCTAssertTrue(expired.isEmpty)
        let careLink = TherapyMetricsManager.chartSeries(entries: [entry(99), entry(30, isIOB: false)], statuses: [status(0, 2)],
            policy: policy(therapy: .careLink), settings: settings, start: now, end: now.addingTimeInterval(5 * 60))
        XCTAssertTrue(careLink.iob.allSatisfy { $0.amount == 2 })
        XCTAssertEqual(careLink.cob.last?.amount, 30)
        let repeatedCycles = [status(0, 2, calculatedMinute: 0), status(2, 2, calculatedMinute: 0),
            status(5, 1.8, calculatedMinute: 5), status(7, 1.8, calculatedMinute: 5),
            status(10, 1.9, calculatedMinute: 10)]
        let cycles = TherapyMetricsManager.externalChartPoints(statuses: repeatedCycles, isIOB: true,
            start: now, end: now.addingTimeInterval(10 * 60))
        XCTAssertEqual(cycles.map { $0.date.timeIntervalSince(now) / 60 }, [0, 5, 10])
        // Preserve a real increase in net AID IOB, even without a bolus treatment.
        XCTAssertEqual(cycles.map(\.amount), [2, 1.8, 1.9])
        let staleRepeat = TherapyMetricsManager.externalChartPoints(statuses: [status(20, 2, calculatedMinute: 0)],
            isIOB: true, start: now.addingTimeInterval(18 * 60), end: now.addingTimeInterval(25 * 60))
        XCTAssertTrue(staleRepeat.isEmpty)
    }

    func testCombinedPlotPreferenceDefaultsOnAndPreservesExplicitOff() throws {
        let suite = "TherapyToggle-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(defaults.showIOBCOB)
        defaults.showIOBCOB = false
        XCTAssertFalse(defaults.showIOBCOB)
        defaults.showIOBCOB = true
        XCTAssertTrue(defaults.showIOBCOB)
    }

    func testStatusHistoryCacheOnlyFetchesMissingEdgesAndResetsBySourceOrRevision() {
        var cache = TherapyStatusHistoryCache()
        let records = [0.0, 5, 10, 15, 20, 25, 30].map { status($0, $0) }
        var requests: [(Double, Double)] = []
        func load(_ from: Double, _ to: Double, key: String = "trio-1") -> [NightscoutDeviceStatusSnapshot] {
            cache.load(key: key, from: now.addingTimeInterval(from * 60), to: now.addingTimeInterval(to * 60)) { start, end in
                requests.append((start.timeIntervalSince(now) / 60, end.timeIntervalSince(now) / 60))
                return records.filter { $0.createdAt >= start && $0.createdAt <= end }
            }
        }
        XCTAssertEqual(load(10, 20).count, 3)
        XCTAssertEqual(load(12, 18).count, 1)
        XCTAssertEqual(requests.count, 1)
        let expanded = load(5, 25)
        XCTAssertEqual(requests.map { $0.0 }, [10, 5, 20])
        XCTAssertEqual(requests.map { $0.1 }, [20, 10, 25])
        XCTAssertEqual(expanded.count, 5)
        XCTAssertEqual(Set(expanded.map(\.id)).count, 5)
        _ = load(5, 25, key: "carelink-1")
        XCTAssertEqual(requests.count, 4)
        _ = load(5, 25, key: "carelink-2")
        XCTAssertEqual(requests.count, 5)
        XCTAssertTrue(load(100, 110, key: "carelink-2").isEmpty)
        XCTAssertEqual(requests.count, 6)
    }

    func testBufferedTherapyClippingInterpolatesEdgesWithoutBridgingGaps() {
        let points = [TherapyChartPoint(date: now, amount: 4, segment: 0),
            TherapyChartPoint(date: now.addingTimeInterval(600), amount: 2, segment: 0),
            TherapyChartPoint(date: now.addingTimeInterval(1800), amount: 1, segment: 1)]
        let series = TherapyChartSeries(iob: points)
        let clipped = series.clipped(from: now.addingTimeInterval(300), to: now.addingTimeInterval(450))
        XCTAssertEqual(clipped.iob.map(\.amount), [3, 2.5])
        XCTAssertTrue(series.clipped(from: now.addingTimeInterval(900), to: now.addingTimeInterval(1200)).iob.isEmpty)
    }

    func testTreatmentSettingsDisableOnlyExternallyOwnedOptions() throws {
        for source in [policy(), policy(therapy: .careLink), policy(therapy: .nightscout, follow: .openAPS)] {
            for (group, external) in [(TreatmentSettingsViewModel.Group.insulin, source.externalIOBSource), (.carbs, source.externalCOBSource)] {
                let model = TreatmentSettingsViewModel(group: group, policyProvider: { source })
                let row = try XCTUnwrap(model.settingsRows(sectionID: 0).first)
                XCTAssertNil(model.sectionTitle())
                XCTAssertEqual(row.isEnabled, external == nil)
                if external != nil {
                    XCTAssertEqual(row.detail, TherapyTexts.text("automatic"))
                    XCTAssertNil(row.control)
                    XCTAssertNil(model.sectionFooter())
                } else {
                    XCTAssertNotNil(row.control)
                    XCTAssertNotNil(model.sectionFooter())
                }
            }
        }
    }

    func testNamedInsulinAndSimpleCarbSettingsResolveLegacyPreferences() throws {
        let suite = "TherapyPresetTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for preset in TherapyInsulinPreset.allCases {
            defaults.set(preset.peak, forKey: "localInsulinPeak")
            defaults.set(420, forKey: "localInsulinDuration")
            let model = TherapyModelSettings(defaults: defaults)
            XCTAssertEqual(model.insulinPeak, preset.peak)
            XCTAssertEqual(model.insulinDuration, 600)
            XCTAssertTrue(model.validInsulin)
        }
        XCTAssertEqual(TherapyModelSettings.carbDurationChoices, [120, 180, 240, 300, 360, 420, 480])
        for minutes in TherapyModelSettings.carbDurationChoices {
            defaults.set(minutes, forKey: "localCarbDuration")
            let model = TherapyModelSettings(defaults: defaults)
            XCTAssertEqual(model.carbDuration, minutes)
            XCTAssertTrue(model.validCarbs)
        }
        defaults.set(90, forKey: "localCarbDuration")
        XCTAssertEqual(TherapyModelSettings(defaults: defaults).carbDuration, 120)
        defaults.set(290, forKey: "localCarbDuration")
        XCTAssertEqual(TherapyModelSettings(defaults: defaults).carbDuration, 300)
    }

    func testSharedGridDatesRemainClockAnchoredAcrossScrollAndChartRanges() {
        for hours in [3.0, 6, 12, 24] {
            let end = now.addingTimeInterval(123)
            let start = end.addingTimeInterval(-hours * 3600)
            let interval = hours >= 24 ? 4 : hours >= 8 ? 2 : 1
            let dates = ConstantsGlucoseChartSwiftUI.xAxisDates(from: start, to: end, everyHours: interval)
            XCTAssertFalse(dates.isEmpty)
            XCTAssertTrue(dates.allSatisfy { Calendar.current.component(.minute, from: $0) == 0 && Calendar.current.component(.hour, from: $0) % interval == 0 })
            let shifted = ConstantsGlucoseChartSwiftUI.xAxisDates(from: start.addingTimeInterval(1), to: end.addingTimeInterval(1), everyHours: interval)
            XCTAssertEqual(dates, shifted)
        }
    }

    func testIntegratedTherapyScalePreservesRatioAndReducesBothCurves() {
        func point(_ amount: Double) -> TherapyChartPoint { TherapyChartPoint(date: now, amount: amount, segment: 0) }
        for hours in [3.0, 6, 12, 24] {
            let baseline = ConstantsGlucoseChartSwiftUI.minimumChartValueWithBottomSpace(hours: hours)
            XCTAssertEqual(baseline, hours >= 24 ? 0 : -10)
            let scale = TherapyChartScale(series: TherapyChartSeries(iob: [point(15)], cob: [point(70)]), baseline: baseline)
            XCTAssertEqual(scale.glucoseValue(amount: 0, isIOB: true), baseline)
            let expectedMaximum = hours >= 24 ? 70.0 : 67.0
            XCTAssertEqual(scale.glucoseValue(amount: 15, isIOB: true), expectedMaximum, accuracy: 1e-10)
            XCTAssertLessThan(scale.glucoseValue(amount: 70, isIOB: false), expectedMaximum)
            XCTAssertLessThan(scale.glucoseValue(amount: -2, isIOB: true), baseline)
            for units in [1.0, 2, 4] {
                XCTAssertEqual(scale.glucoseValue(amount: units, isIOB: true), scale.glucoseValue(amount: units * 7, isIOB: false), accuracy: 1e-10)
            }
            for series in [TherapyChartSeries(iob: [point(30)], cob: [point(70)]), TherapyChartSeries(iob: [point(15)], cob: [point(140)])] {
                let reduced = TherapyChartScale(series: series, baseline: baseline)
                XCTAssertEqual(reduced.reduction, 2)
                XCTAssertEqual(reduced.glucoseValue(amount: 2, isIOB: true), reduced.glucoseValue(amount: 14, isIOB: false), accuracy: 1e-10)
                XCTAssertLessThanOrEqual(reduced.glucoseValue(amount: series.iob[0].amount, isIOB: true), expectedMaximum)
                XCTAssertLessThanOrEqual(reduced.glucoseValue(amount: series.cob[0].amount, isIOB: false), expectedMaximum)
            }
        }
    }

    @MainActor func testRenderTherapyInsideGlucoseChartWithAndWithoutBasal() throws {
        let start = now.addingTimeInterval(-3600)
        let end = now.addingTimeInterval(4 * 3600)
        let series = TherapyMetricsManager.chartSeries(entries: [entry(4), entry(30, isIOB: false)], statuses: [], policy: policy(), settings: settings, start: start, end: end)
        for width in [320.0, 768.0] {
            for configuration in [(false, false), (true, false), (false, true), (true, true)] {
                let (withBasal, withTherapy) = configuration
                for downwards in [false, true] {
                    var state = GlucoseChartState.empty(startDate: start, endDate: end)
                    state.bgReadingDates = stride(from: start.timeIntervalSince1970, through: end.timeIntervalSince1970, by: 300).map { Date(timeIntervalSince1970: $0) }
                    state.bgReadingValues = state.bgReadingDates.enumerated().map { 110 + 20 * sin(Double($0.offset) / 8) }
                    if withBasal {
                        state.minimumChartValueInMgDl = ConstantsGlucoseChartSwiftUI.minimumChartValueWithBottomSpace(hours: 5)
                        state.treatmentPoints.basalRates = [GlucoseChartPoint(date: start, value: 10, idPrefix: "basal"), GlucoseChartPoint(date: end, value: 10, idPrefix: "basal")]
                        state.treatmentPoints.basalRateFill = state.treatmentPoints.basalRates
                        state.treatmentPoints.scheduledBasalRates = [GlucoseChartPoint(date: start, value: 20, idPrefix: "scheduled"), GlucoseChartPoint(date: end, value: 20, idPrefix: "scheduled")]
                        state.treatmentPoints.automaticBasalPulses = [GlucoseChartBasalPulse(startDate: start.addingTimeInterval(1800), endDate: start.addingTimeInterval(2400), value: 38)]
                    }
                    let content = GlucoseChartView(glucoseChartType: .widgetSystemLarge, bgReadingValues: nil, bgReadingDates: nil,
                        isMgDl: width == 320, urgentLowLimitInMgDl: 55, lowLimitInMgDl: 70, highLimitInMgDl: 180, urgentHighLimitInMgDl: 230,
                        liveActivityType: nil, hoursToShowScalingHours: 5, glucoseCircleDiameterScalingHours: 5,
                        showsTreatments: withBasal, overrideChartHeight: 300, overrideChartWidth: width,
                        highContrast: nil, chartState: state)
                        .mainChartYAxisContext(renderBasalDownwards: downwards).therapyPlots(withTherapy ? series : TherapyChartSeries())
                        .frame(width: width, height: 300).background(Color.black).environment(\.colorScheme, .dark)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 2
                    let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
                    attachment.name = "Integrated therapy \(Int(width))pt basal=\(withBasal) therapy=\(withTherapy) downwards=\(downwards)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
            }
        }
    }

    /// Keep a visual regression fixture for custom-symbol labels, including zero-size note anchors.
    /// Xcode 27 displaced Charts annotations even though the treatment coordinates were unchanged.
    @MainActor func testRenderTreatmentLabelsAtDifferentChartSizes() throws {
        let start = now.addingTimeInterval(-3 * 3600)
        for width in [320.0, 768.0] {
            var state = GlucoseChartState.empty(startDate: start, endDate: now)
            state.bgReadingDates = [start, now]
            state.bgReadingValues = [100, 100]
            for (index, amount) in [5.0, 30, 70].enumerated() {
                let date = start.addingTimeInterval(Double(index + 1) * 2400)
                state.treatmentPoints.carbs.append(GlucoseChartTreatmentPoint(date: date, yValue: 130, treatmentValue: amount, label: "\(Int(amount))", notes: nil, idPrefix: "carb"))
                state.treatmentPoints.boluses.append(GlucoseChartTreatmentPoint(date: date, yValue: 80, treatmentValue: amount / 10, label: "\(amount / 10)", notes: nil, idPrefix: "bolus"))
            }
            state.treatmentPoints.notes = [GlucoseChartTreatmentPoint(date: now.addingTimeInterval(-1200), yValue: 105, treatmentValue: 0, label: "Note", notes: nil, idPrefix: "note")]
            state.treatmentPoints.basalInjections = [GlucoseChartTreatmentPoint(date: start.addingTimeInterval(1200), yValue: 65, treatmentValue: 12, label: "12", notes: nil, idPrefix: "injection")]
            let content = GlucoseChartView(glucoseChartType: .widgetSystemLarge, bgReadingValues: nil, bgReadingDates: nil,
                isMgDl: width == 320, urgentLowLimitInMgDl: 55, lowLimitInMgDl: 70, highLimitInMgDl: 180, urgentHighLimitInMgDl: 230,
                liveActivityType: nil, hoursToShowScalingHours: 3, glucoseCircleDiameterScalingHours: 3,
                showsTreatments: true, overrideChartHeight: 300, overrideChartWidth: width,
                highContrast: nil, chartState: state)
                .frame(width: width, height: 300).background(Color.black).environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
            attachment.name = "Treatment label alignment \(Int(width))pt"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor func testImportedSourceSelectionAndLocallyNamedUploadRoundTrip() async throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let manager = TherapyMetricsManager()
        manager.configure(coreDataManager: core, externalStatus: { nil })
        _ = TreatmentEntry(id: "manual-uploaded", date: now, value: 2, treatmentType: .Insulin, uploaded: true, nightscoutEventType: nil, enteredBy: "My name", nsManagedObjectContext: core.mainManagedObjectContext)
        _ = TreatmentEntry(id: "manual-carelink-name", date: now, value: 1, treatmentType: .Insulin, uploaded: true, nightscoutEventType: nil, enteredBy: "CareLink", nsManagedObjectContext: core.mainManagedObjectContext)
        _ = TreatmentEntry(id: "nightscout", date: now, value: 3, treatmentType: .Insulin, uploaded: true, nightscoutEventType: "Bolus", enteredBy: nil, nsManagedObjectContext: core.mainManagedObjectContext)
        let careLink = TreatmentEntry(id: "carelink", date: now, value: 30, treatmentType: .Carbs, uploaded: true, nightscoutEventType: "Meal Bolus", enteredBy: "CareLink", nsManagedObjectContext: core.mainManagedObjectContext)
        careLink.careLinkSourceIdentifier = "meal-1"
        XCTAssertTrue(core.saveChangesSynchronously())
        let local = try await readInputs(manager, source: .none)
        let nightscout = try await readInputs(manager, source: .nightscout)
        let careLinkInputs = try await readInputs(manager, source: .careLink)
        XCTAssertEqual(local.map(\.amount).sorted(), [1, 2])
        XCTAssertEqual(nightscout.map(\.amount).sorted(), [1, 2, 3])
        XCTAssertEqual(careLinkInputs.map(\.amount).sorted(), [1, 2, 30])
    }

    @MainActor func testPendingWriterChangesAreNotPublishedBeforeStoreSave() async throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let manager = TherapyMetricsManager()
        manager.configure(coreDataManager: core, externalStatus: { nil })
        _ = TreatmentEntry(date: now, value: 2, treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: core.mainManagedObjectContext)
        // Saving the child pushes to the writer, but does not commit to the persistent store.
        try core.mainManagedObjectContext.save()
        let pending = try await readInputs(manager)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(core.saveChangesSynchronously())
        let committed = try await readInputs(manager)
        XCTAssertEqual(committed.count, 1)
    }

    @MainActor func testHomeHidesConfirmedAmountBetweenChildAndStoreTreatmentSaves() async throws {
        let defaults = UserDefaults.standard
        let priorSource = defaults.therapyDataSourceType
        defaults.therapyDataSourceType = .none
        defer { defaults.therapyDataSourceType = priorSource }

        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let manager = TherapyMetricsManager()
        manager.configure(coreDataManager: core, externalStatus: { nil })
        let displayedAt = Date()
        let entry = TreatmentEntry(date: displayedAt.addingTimeInterval(-60), value: 2,
            treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: nil,
            nsManagedObjectContext: core.mainManagedObjectContext)
        XCTAssertTrue(core.saveChangesSynchronously())
        let policy = defaults.dataFlowPolicy
        let modelSettings = self.settings
        let start = displayedAt.addingTimeInterval(-TherapyModelSettings.visibilityInterval)
        func storedInputs() async throws -> [TherapyTreatment] {
            let loaded = await Task.detached {
                manager.treatments(from: start, to: Date(), policy: policy, settings: modelSettings)
            }.value
            return try XCTUnwrap(loaded)
        }

        let initialInputs = try await storedInputs()
        XCTAssertEqual(initialInputs.map(\.amount), [2])
        let confirmed = manager.snapshot(at: displayedAt)
        let confirmedAmount = try XCTUnwrap(confirmed.iob.value(at: displayedAt))
        XCTAssertGreaterThan(confirmedAmount, 0)

        let confirmedRevision = manager.treatmentChangeRevision
        entry.value = 3
        try core.mainManagedObjectContext.save()
        XCTAssertGreaterThan(manager.treatmentChangeRevision, confirmedRevision,
            "The Home presentation must lose its confirmed value as soon as the child saves")
        let pending = manager.snapshot(at: displayedAt)
        XCTAssertEqual(pending.iob.reason, .readFailed)
        XCTAssertNil(pending.iob.value(at: displayedAt))
        manager.invalidate(treatmentsChanged: false)
        XCTAssertEqual(manager.snapshot(at: displayedAt).iob.reason, .readFailed,
            "An unrelated status refresh must not clear a pending treatment commit")
        let pendingInputs = try await storedInputs()
        XCTAssertEqual(pendingInputs.map(\.amount), [2],
            "The worker read still reflects only the committed persistent store")

        XCTAssertTrue(core.saveChangesSynchronously())
        let committedInputs = try await storedInputs()
        XCTAssertEqual(committedInputs.map(\.amount), [3])
        let updated = manager.snapshot(at: displayedAt)
        XCTAssertGreaterThan(try XCTUnwrap(updated.iob.value(at: displayedAt)), confirmedAmount)
    }

    private func readInputs(_ manager: TherapyMetricsManager, source: TherapyDataSourceType = .none) async throws -> [TherapyTreatment] {
        let start = now.addingTimeInterval(-86400), end = now
        let policy = policy(therapy: source), settings = settings
        let result = await Task.detached {
            manager.treatments(from: start, to: end, policy: policy, settings: settings)
        }.value
        return try XCTUnwrap(result)
    }

    @MainActor func testMainThreadColdReadReturnsImmediatelyThenPublishesCachedInputs() async throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let manager = TherapyMetricsManager()
        manager.configure(coreDataManager: core, externalStatus: { nil })
        _ = TreatmentEntry(date: now, value: 2, treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: nil, nsManagedObjectContext: core.mainManagedObjectContext)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertNil(manager.treatments(from: now.addingTimeInterval(-86400), to: now, policy: policy(), settings: settings))
        var loaded: [TherapyTreatment]?
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            loaded = manager.treatments(from: now.addingTimeInterval(-86400), to: now, policy: policy(), settings: settings)
            if loaded != nil { break }
        }
        XCTAssertEqual(loaded?.count, 1)
        manager.invalidate(treatmentsChanged: false)
        let cached = manager.treatments(from: now.addingTimeInterval(-86400), to: now, policy: policy(), settings: settings)
        XCTAssertEqual(cached?.count, 1, "Status-only saves must retain treatment inputs")
        manager.invalidate()
        XCTAssertNil(manager.treatments(from: now.addingTimeInterval(-86400), to: now, policy: policy(), settings: settings))
    }

    func testExternalChartJoinBoundaryAndClippingBeyondFreshness() throws {
        for minutes in [31.999, 32, 33] {
            let points = TherapyMetricsManager.externalChartPoints(statuses: [status(0, -1), status(minutes, 3)],
                isIOB: true, start: now, end: now.addingTimeInterval(minutes * 60))
            XCTAssertEqual(points.first?.segment == points.last?.segment, minutes < 32)
        }
        let clipped = TherapyMetricsManager.externalChartPoints(statuses: [status(0, 1), status(30, 4)],
            isIOB: true, start: now.addingTimeInterval(20 * 60), end: now.addingTimeInterval(30 * 60))
        XCTAssertEqual(try XCTUnwrap(clipped.first?.amount), 3, accuracy: 1e-9)
        XCTAssertEqual(clipped.first?.date, now.addingTimeInterval(20 * 60))
        // No later point: retain the existing freshness expiry, without projecting 32 minutes.
        let isolated = TherapyMetricsManager.externalChartPoints(statuses: [status(0, 1)],
            isIOB: true, start: now.addingTimeInterval(20 * 60), end: now.addingTimeInterval(30 * 60))
        XCTAssertTrue(isolated.isEmpty)
    }

    func testChartCancellationStopsLocalAndExternalSampling() {
        let cancellation = TherapyChartCancellation()
        cancellation.cancel()
        let local = TherapyMetricsManager.chartSeries(entries: [entry(2)], statuses: [], policy: policy(), settings: settings,
            start: now, end: now.addingTimeInterval(86400), isCancelled: { cancellation.isCancelled })
        XCTAssertTrue(local.iob.isEmpty && local.cob.isEmpty)
        let external = TherapyMetricsManager.externalChartPoints(statuses: [status(0, 1), status(5, 2)],
            isIOB: true, start: now, end: now.addingTimeInterval(600), isCancelled: { cancellation.isCancelled })
        XCTAssertTrue(external.isEmpty)
    }

    func testInvalidAmountsCannotBreakCompanionEncoding() throws {
        let huge = Double.greatestFiniteMagnitude
        let local = metric([entry(huge), entry(huge)])
        XCTAssertNil(local.amount)
        XCTAssertEqual(local.reason, .invalidSettings)
        XCTAssertNoThrow(try JSONEncoder().encode(local))
        let status = AIDStatus(condition: .active, style: .loop, statusUpdatedAt: now,
            lastActivityAt: now, iob: .infinity, cob: .nan, statusTitle: "Looping", staleStatusTitle: "No data")
        let external = TherapyMetricsSnapshot.external(status, at: now)
        XCTAssertNil(external.iob.amount)
        XCTAssertNil(external.cob.amount)
        XCTAssertEqual(external.iob.reason, .missingExternalData)
        XCTAssertNoThrow(try JSONEncoder().encode(external))
    }

    func testTreatmentSettingsIgnoreInvalidRowIndices() {
        let model = TreatmentSettingsViewModel(group: .insulin)
        for index in [-1, 1, Int.max] {
            XCTAssertEqual(model.settingsRowText(index: index), "")
            XCTAssertNil(model.detailedText(index: index))
            XCTAssertFalse(model.isEnabled(index: index))
        }
    }

    func testTherapyLocalizationsHaveMatchingKeysAndFormatArguments() throws {
        let languages = ["ar", "da", "de", "el", "en", "es", "fi", "fr", "it", "nl", "pl-PL", "pt", "ru", "sl", "sv", "tr", "uk", "zh"]
        func strings(_ language: String, table: String) throws -> [String: String] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: table, withExtension: "strings", subdirectory: nil, localization: language))
            XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, language + ".lproj")
            let values = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: String])
            return values.filter { $0.key.hasPrefix("therapy.") }
        }
        for table in ["SettingsViews", "Common"] {
            let english = try strings("en", table: table)
            XCTAssertFalse(english.isEmpty)
            for language in languages {
                let translated = try strings(language, table: table)
                XCTAssertEqual(Set(translated.keys), Set(english.keys), "\(language) \(table)")
                for (key, value) in translated {
                    XCTAssertFalse(value.isEmpty, "\(language) \(key)")
                    XCTAssertEqual(value.components(separatedBy: "%@").count,
                                   english[key]?.components(separatedBy: "%@").count, "\(language) \(key)")
                }
            }
        }
    }

    func testCollapsedChartRangesAndUnrepresentableJumpsHaveNoDuplicateIDs() {
        let series = TherapyChartSeries(iob: [TherapyChartPoint(date: now.addingTimeInterval(-60), amount: 2, segment: 0),
                                             TherapyChartPoint(date: now.addingTimeInterval(60), amount: 1, segment: 0)])
        XCTAssertTrue(series.clipped(from: now, to: now).iob.isEmpty)
        let points = TherapyMetricsManager.chartSeries(entries: [entry(2, minutesAgo: 10), entry(Double.leastNonzeroMagnitude)],
            statuses: [], policy: policy(), settings: settings, start: now.addingTimeInterval(-600), end: now).iob
        XCTAssertEqual(Set(points.map(\.id)).count, points.count)
    }

}

final class PenBolusCalculatorTests: XCTestCase {
    private var now: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 4,
            hour: 12, minute: 0))!
    }

    private func profile() -> PenDoseProfile {
        var profile = PenDoseProfile.prefilledUnconfirmed
        XCTAssertTrue(profile.confirm(at: now))
        return profile
    }

    private func glucose(_ value: Double = 126, increase: Double = 18)
        -> [GlucoseForecastSample] {
        stride(from: -30, through: 0, by: 5).map { minute in
            GlucoseForecastSample(date: now.addingTimeInterval(Double(minute) * 60),
                glucoseMgdl: value + increase * Double(minute + 20) / 20,
                sensorID: "sensor-a")
        }
    }

    private func snapshot(glucose: [GlucoseForecastSample]? = nil,
                          treatments: [TherapyTreatment] = []) throws -> PenDoseInputSnapshot {
        try PenDoseInputSnapshot.make(capturedAt: now,
            glucose: glucose ?? self.glucose(), treatments: treatments,
            therapySettings: TherapyModelSettings(), treatmentRevision: 4).get()
    }

    func testPrefilledProfileIsUnconfirmedAndEditingInvalidatesConfirmation() throws {
        var profile = PenDoseProfile.prefilledUnconfirmed
        XCTAssertFalse(profile.isConfirmed)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        XCTAssertTrue(profile.persist(defaults: defaults))
        XCTAssertFalse(PenDoseProfile.load(defaults: defaults).isConfirmed)
        XCTAssertTrue(profile.confirm(at: now))
        XCTAssertTrue(profile.isConfirmed)
        XCTAssertTrue(profile.persist(defaults: defaults))
        XCTAssertTrue(PenDoseProfile.load(defaults: defaults).isConfirmed)
        profile.settings.correctionMmolPerUnit = 2
        XCTAssertFalse(profile.isConfirmed)
        defaults.set(Data("bad".utf8), forKey: PenDoseProfile.storageKey)
        XCTAssertFalse(PenDoseProfile.load(defaults: defaults).isConfirmed)
    }

    func testLocalScheduleBoundariesAndDSTUseWallClock() {
        let profile = profile()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        func time(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day,
                hour: hour, minute: minute))!
        }
        XCTAssertEqual(profile.values(at: time(2026, 10, 4, 4, 29), calendar: calendar)?.carbohydrateRatio, 7.5)
        XCTAssertEqual(profile.values(at: time(2026, 10, 4, 4, 30), calendar: calendar)?.carbohydrateRatio, 5)
        XCTAssertEqual(profile.values(at: time(2026, 10, 4, 9, 30), calendar: calendar)?.carbohydrateRatio, 6)
        XCTAssertEqual(profile.values(at: time(2026, 10, 4, 21, 30), calendar: calendar)?.targetMmol, 7.75)
        // Both occurrences of an autumn DST hour resolve to the same wall-clock entry.
        let first = time(2026, 10, 25, 2, 30)
        XCTAssertEqual(profile.values(at: first, calendar: calendar)?.carbohydrateRatio,
            profile.values(at: first.addingTimeInterval(3600), calendar: calendar)?.carbohydrateRatio)
    }

    func testKnownZeroSnapshotAndHandCalculatedFormulaWithTwentyMinuteTrend() throws {
        let snapshot = try snapshot(treatments: [])
        XCTAssertEqual(snapshot.iobUnits, 0)
        XCTAssertEqual(snapshot.cobGrams, 0)
        let calculation = PenBolusCalculator.calculate(snapshot: snapshot,
            profile: profile(), glucose: .currentCGM,
            newCarbs: .unrecorded(grams: 30), safetyForecast: nil, at: now)
        let lines = try XCTUnwrap(calculation.lines)
        XCTAssertEqual(lines.carbohydratesUnits, 5, accuracy: 0.00001)
        let current = try XCTUnwrap(snapshot.glucose.last?.glucoseMgdl)
        let expectedCorrection = (current / PenBolusCalculator.mgdlPerMmol - 6.85) / 1.2
        XCTAssertEqual(lines.correctionUnits, expectedCorrection, accuracy: 0.00001)
        let expectedTrendUnits = (18 / PenBolusCalculator.mgdlPerMmol) / 1.2
        XCTAssertEqual(lines.trendUnits, expectedTrendUnits, accuracy: 0.00001)
        let raw = 5 + expectedCorrection + expectedTrendUnits
        XCTAssertEqual(lines.rawUnits, raw, accuracy: 0.00001)
        XCTAssertEqual(calculation.suggestedUnits, floor(raw / 0.5) * 0.5)
        if case .forecastUnchecked = calculation.safety {} else { XCTFail("needs unchecked warning") }
    }

    func testNoShortSpanExtrapolationAndSensorGapCannotBecomeZeroTrend() throws {
        let short = glucose().filter { $0.date >= now.addingTimeInterval(-5 * 60) }
        XCTAssertNil(PenBolusCalculator.twentyMinuteChange(short, at: now))
        let calculation = PenBolusCalculator.calculate(snapshot: try snapshot(glucose: short),
            profile: profile(), glucose: .currentCGM,
            newCarbs: .alreadyRecorded, safetyForecast: nil, at: now)
        XCTAssertEqual(calculation.unavailableReason, .missingTwentyMinuteTrend)
        XCTAssertNil(calculation.suggestedUnits)
        let crossSensor = glucose().map { sample in
            GlucoseForecastSample(date: sample.date, glucoseMgdl: sample.glucoseMgdl,
                sensorID: sample.date < now.addingTimeInterval(-10 * 60) ? "old" : "new")
        }
        XCTAssertNil(PenBolusCalculator.twentyMinuteChange(crossSensor, at: now))
    }

    func testManualOrConfirmedOldReadingUsesExplicitZeroTrendAndUncheckedForecast() throws {
        let snapshot = try snapshot(glucose: [])
        let manual = PenBolusCalculator.calculate(snapshot: snapshot, profile: profile(),
            glucose: .manual(valueMgdl: 110, measuredAt: now),
            newCarbs: .alreadyRecorded, safetyForecast: nil, at: now)
        XCTAssertTrue(manual.trendWasIntentionallyZero)
        XCTAssertEqual(manual.lines?.trendUnits, 0)
        XCTAssertNotNil(manual.suggestedUnits)
        XCTAssertNil(manual.glucoseSensorID)
        if case .forecastUnchecked = manual.safety {} else { XCTFail("manual requires warning") }
        let old = PenBolusCalculator.calculate(snapshot: snapshot, profile: profile(),
            glucose: .confirmedStale(valueMgdl: 100, measuredAt: now.addingTimeInterval(-3600),
                sensorID: "sensor-a"),
            newCarbs: .alreadyRecorded, safetyForecast: nil, at: now)
        XCTAssertTrue(old.trendWasIntentionallyZero)
        XCTAssertEqual(old.glucoseSensorID, "sensor-a")
        XCTAssertNotNil(old.suggestedUnits)
        let current = PenBolusCalculator.calculate(snapshot: snapshot, profile: profile(),
            glucose: .currentCGM, newCarbs: .alreadyRecorded,
            safetyForecast: nil, at: now)
        XCTAssertEqual(current.unavailableReason, .missingGlucose)
    }

    func testPinnedCGMDoesNotMoveToNewerReadingWithoutTrend() throws {
        let readings = glucose()
        let pinned = readings[2] // Twenty minutes old; newer readings remain in the snapshot.
        let pinnedSensorID = try XCTUnwrap(pinned.sensorID)
        let newer = try XCTUnwrap(readings.last)
        let incompleteTrend = [pinned, newer]
        XCTAssertNil(PenBolusCalculator.twentyMinuteChange(incompleteTrend, at: now))
        let irrelevantForecast = GlucoseForecastResult(points: [
            GlucoseForecastPoint(date: now, glucoseMgdl: pinned.glucoseMgdl),
            GlucoseForecastPoint(date: now.addingTimeInterval(120 * 60), glucoseMgdl: 50)
        ], referenceDate: now, reason: nil, referenceSensorID: pinnedSensorID)
        let calculated = PenBolusCalculator.calculate(snapshot: try snapshot(glucose: incompleteTrend),
            profile: profile(),
            glucose: .confirmedStale(valueMgdl: pinned.glucoseMgdl, measuredAt: pinned.date,
                sensorID: pinnedSensorID),
            newCarbs: .alreadyRecorded, safetyForecast: irrelevantForecast, at: now)
        XCTAssertEqual(calculated.glucoseMgdl, pinned.glucoseMgdl)
        XCTAssertEqual(calculated.glucoseMeasuredAt, pinned.date)
        XCTAssertEqual(calculated.glucoseSensorID, pinned.sensorID)
        XCTAssertNotEqual(calculated.glucoseMgdl, readings.last?.glucoseMgdl)
        XCTAssertTrue(calculated.trendWasIntentionallyZero)
        XCTAssertEqual(calculated.lines?.trendUnits, 0)
        XCTAssertNotNil(calculated.suggestedUnits)
        if case .forecastUnchecked = calculated.safety {} else {
            XCTFail("pinned CGM must not use a forecast safety result")
        }

        // A limited snapshot may no longer contain the explicitly selected
        // sample; a newer same-sensor reading must not replace it implicitly.
        let outsideWindow = PenBolusCalculator.calculate(snapshot: try snapshot(glucose: [newer]),
            profile: profile(),
            glucose: .confirmedStale(valueMgdl: pinned.glucoseMgdl, measuredAt: pinned.date,
                sensorID: pinnedSensorID),
            newCarbs: .alreadyRecorded, safetyForecast: nil, at: now)
        XCTAssertEqual(outsideWindow.glucoseMgdl, pinned.glucoseMgdl)
        XCTAssertEqual(outsideWindow.glucoseMeasuredAt, pinned.date)
        XCTAssertNotNil(outsideWindow.suggestedUnits)
    }

    func testPinnedCGMRejectsChangedSampleOrSensorWithoutFallback() throws {
        let readings = glucose()
        let pinned = readings[2]
        let input = try snapshot(glucose: readings)
        let changedValue = PenBolusCalculator.calculate(snapshot: input, profile: profile(),
            glucose: .confirmedStale(valueMgdl: pinned.glucoseMgdl + 1,
                measuredAt: pinned.date, sensorID: "sensor-a"),
            newCarbs: .alreadyRecorded, safetyForecast: nil, at: now)
        XCTAssertEqual(changedValue.unavailableReason, .invalidGlucose)
        XCTAssertNil(changedValue.suggestedUnits)

        let differentSensor = readings.map { sample in
            GlucoseForecastSample(date: sample.date, glucoseMgdl: sample.glucoseMgdl,
                sensorID: "sensor-b")
        }
        let switched = PenBolusCalculator.calculate(snapshot: try snapshot(glucose: differentSensor),
            profile: profile(),
            glucose: .confirmedStale(valueMgdl: pinned.glucoseMgdl,
                measuredAt: pinned.date, sensorID: "sensor-a"),
            newCarbs: .alreadyRecorded, safetyForecast: nil, at: now)
        XCTAssertEqual(switched.unavailableReason, .invalidGlucose)
        XCTAssertNil(switched.suggestedUnits)

        let emptyID = PenBolusCalculator.calculate(snapshot: input, profile: profile(),
            glucose: .confirmedStale(valueMgdl: pinned.glucoseMgdl,
                measuredAt: pinned.date, sensorID: ""),
            newCarbs: .alreadyRecorded, safetyForecast: nil, at: now)
        XCTAssertEqual(emptyID.unavailableReason, .invalidGlucose)
    }

    func testPinnedLowGlucoseStillBlocksInsulinWithoutForecast() throws {
        let pinnedLow = PenBolusCalculator.calculate(snapshot: try snapshot(glucose: []),
            profile: profile(),
            glucose: .confirmedStale(valueMgdl: 53,
                measuredAt: now.addingTimeInterval(-20 * 60), sensorID: "sensor-a"),
            newCarbs: .unrecorded(grams: 30), safetyForecast: nil, at: now)
        XCTAssertNil(pinnedLow.suggestedUnits)
        if case .blockedCurrentLow = pinnedLow.safety {} else {
            XCTFail("pinning must not bypass the current severe-low guard")
        }
    }

    func testExistingMealIsNotAddedAgainAndDoseFloorsAtCap() throws {
        let carbs = TherapyTreatment(date: now.addingTimeInterval(-5 * 60),
            amount: 60, isIOB: false, carbohydrateDurationMinutes: 240)
        let input = try snapshot(treatments: [carbs])
        let already = PenBolusCalculator.calculate(snapshot: input, profile: profile(),
            glucose: .currentCGM, newCarbs: .alreadyRecorded,
            safetyForecast: nil, at: now)
        let extra = PenBolusCalculator.calculate(snapshot: input, profile: profile(),
            glucose: .currentCGM, newCarbs: .unrecorded(grams: 60),
            safetyForecast: nil, at: now)
        XCTAssertEqual((extra.lines?.carbohydratesUnits ?? 0) - (already.lines?.carbohydratesUnits ?? 0),
            10, accuracy: 0.00001)
        let capped = PenBolusCalculator.calculate(snapshot: input, profile: profile(),
            glucose: .currentCGM, newCarbs: .unrecorded(grams: 500),
            safetyForecast: nil, at: now)
        XCTAssertEqual(capped.suggestedUnits, 25)
    }

    func testBolusAndConsumedCarbohydrateContributeOnlyThroughIOBAndCOB() throws {
        let bolus = TherapyTreatment(date: now.addingTimeInterval(-30 * 60),
            amount: 2, isIOB: true)
        let meal = TherapyTreatment(date: now.addingTimeInterval(-20 * 60),
            amount: 30, isIOB: false, carbohydrateDurationMinutes: 240)
        let input = try snapshot(treatments: [bolus, meal])
        XCTAssertGreaterThan(input.iobUnits, 0)
        XCTAssertGreaterThan(input.cobGrams, 0)
        let calculated = PenBolusCalculator.calculate(snapshot: input, profile: profile(),
            glucose: .currentCGM, newCarbs: .alreadyRecorded,
            safetyForecast: nil, at: now)
        let lines = try XCTUnwrap(calculated.lines)
        XCTAssertEqual(lines.carbohydratesUnits, input.cobGrams / 6, accuracy: 0.00001)
        XCTAssertEqual(lines.insulinOnBoardUnits, input.iobUnits, accuracy: 0.00001)
        XCTAssertEqual(lines.rawUnits, lines.carbohydratesUnits + lines.correctionUnits +
            lines.trendUnits - input.iobUnits, accuracy: 0.00001)
    }

    func testCurrentOrPredictedSevereLowBlocksButMissingForecastDoesNotMasqueradeAsChecked() throws {
        let input = try snapshot()
        let low = PenBolusCalculator.calculate(snapshot: input, profile: profile(),
            glucose: .manual(valueMgdl: 53, measuredAt: now),
            newCarbs: .unrecorded(grams: 30), safetyForecast: nil, at: now)
        XCTAssertNil(low.suggestedUnits)
        if case .blockedCurrentLow = low.safety {} else { XCTFail("current severe low") }
        let points = stride(from: 0, through: 120, by: 5).map { minute in
            GlucoseForecastPoint(date: now.addingTimeInterval(Double(minute) * 60),
                glucoseMgdl: minute == 60 ? 52 : minute == 0 ? 144 : 110)
        }
        let forecast = GlucoseForecastResult(points: points, referenceDate: now,
            reason: nil, referenceSensorID: "sensor-a")
        let predicted = PenBolusCalculator.calculate(snapshot: input, profile: profile(),
            glucose: .currentCGM, newCarbs: .unrecorded(grams: 30),
            safetyForecast: forecast, at: now)
        XCTAssertNil(predicted.suggestedUnits)
        if case .blockedForecastLow = predicted.safety {} else { XCTFail("predicted severe low") }
        let unchecked = PenBolusCalculator.calculate(snapshot: input, profile: profile(),
            glucose: .currentCGM, newCarbs: .unrecorded(grams: 30),
            safetyForecast: GlucoseForecastResult(points: [], referenceDate: now,
                reason: .insufficientHistory), at: now)
        XCTAssertNotNil(unchecked.suggestedUnits)
        if case .forecastUnchecked(.insufficientHistory) = unchecked.safety {} else {
            XCTFail("must identify unchecked forecast")
        }
    }

    func testMLCapNeverChangesEngineAndRetainsBandWidth() throws {
        let points = [GlucoseForecastPoint(date: now, glucoseMgdl: 80),
                      GlucoseForecastPoint(date: now.addingTimeInterval(300), glucoseMgdl: 75)]
        let engine = GlucoseForecastResult(points: points, referenceDate: now, reason: nil)
        let ml = GlucoseForecastMLForecast(points: [
            .init(date: now, glucoseMgdl: 80),
            .init(date: now.addingTimeInterval(300), glucoseMgdl: 90)], band: [
                .init(date: now, lowerMgdl: 75, upperMgdl: 85),
                .init(date: now.addingTimeInterval(300), lowerMgdl: 80, upperMgdl: 100)],
            modelID: "test")
        let capped = try XCTUnwrap(GlucoseForecastMLPresentation.cappedBelowEngine(ml,
            engine: engine, currentGlucoseMgdl: 80, slope15MgdlPerMinute: -1,
            lowSoonActive: false))
        XCTAssertEqual(capped.points[1].glucoseMgdl, 75)
        XCTAssertEqual(capped.band[1].upperMgdl - capped.band[1].lowerMgdl, 20)
        XCTAssertEqual(engine.points[1].glucoseMgdl, 75)
        let unchanged = try XCTUnwrap(GlucoseForecastMLPresentation.cappedBelowEngine(ml,
            engine: engine, currentGlucoseMgdl: 110, slope15MgdlPerMinute: -1,
            lowSoonActive: false))
        XCTAssertEqual(unchanged.points[1].glucoseMgdl, 90)
    }

    func testDoseSnapshotSourceSignatureChangesWhenCutoverOrSourceChanges() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.therapyDataSourceType = .none
        XCTAssertFalse(TherapyMetricsManager.doseSourceIsReady(defaults.dataFlowPolicy,
            cutover: nil, defaults: defaults),
            "without a completed source switch an empty window is not proven zero")
        let initial = GlucoseForecastDataAdapter.presentationInputSignature(
            horizonMinutes: 120, defaults: defaults)
        XCTAssertTrue(TreatmentSourceCutover.persist(.init(cutoff: now,
            insulinSourceBundleID: "mysugr.insulin",
            carbohydrateSourceBundleID: "mysugr.carbs"), defaults: defaults))
        XCTAssertTrue(TherapyMetricsManager.doseSourceIsReady(defaults.dataFlowPolicy,
            cutover: TreatmentSourceCutover.current(defaults: defaults), defaults: defaults))
        let afterCutover = GlucoseForecastDataAdapter.presentationInputSignature(
            horizonMinutes: 120, defaults: defaults)
        XCTAssertNotEqual(initial, afterCutover,
            "a boundary appearing during the dose read must invalidate its snapshot")
        defaults.therapyDataSourceType = .nightscout
        defaults.nightscoutEnabled = true
        let external = GlucoseForecastDataAdapter.presentationInputSignature(
            horizonMinutes: 120, defaults: defaults)
        XCTAssertNotEqual(afterCutover, external,
            "an external source becoming effective during the read must invalidate it")
        XCTAssertFalse(TherapyMetricsManager.doseSourceIsReady(defaults.dataFlowPolicy,
            cutover: TreatmentSourceCutover.current(defaults: defaults), defaults: defaults))
    }

    func testEngineOnlySafetyIgnoresHomeVisibilityAndUnconfirmedPlannedMeal() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.glucoseForecastHorizonMinutes = 0
        defaults.glucoseForecastManualSensitivityMgdlPerUnit = 40
        defaults.glucoseForecastManualCarbRatioGramsPerUnit = 10
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let planned = TreatmentEntry(date: now.addingTimeInterval(15 * 60),
            value: 40, treatmentType: .Carbs, nightscoutEventType: nil,
            enteredBy: nil, nsManagedObjectContext: core.mainManagedObjectContext)
        planned.localTreatmentUUID = UUID().uuidString
        planned.plannedMealStateRaw = TreatmentMealState.planned.rawValue
        let eligible = TherapyMetricsManager.eligibleTreatments([planned],
            policy: defaults.dataFlowPolicy, insulinSource: nil, carbsSource: nil,
            insulinEnabled: false, carbsEnabled: false)
        XCTAssertTrue(eligible.isEmpty)
        let input = try snapshot(treatments: eligible.map {
            TherapyTreatment(date: $0.date, amount: $0.value, isIOB: false)
        })
        let result = PenBolusCalculator.safetyForecast(snapshot: input, at: now,
            defaults: defaults, horizonMinutes: 120)
        XCTAssertNil(result.reason)
        XCTAssertNotNil(result.value(atMinutes: 30))
        XCTAssertNotNil(result.value(atMinutes: 120))
        XCTAssertEqual(defaults.glucoseForecastHorizonMinutes, 0,
            "Home chart setting must not govern the safety engine")
    }
}

private actor PenDoseSnapshotFeed {
    private var samples: [GlucoseForecastSample]

    init(samples: [GlucoseForecastSample]) { self.samples = samples }

    func replace(with samples: [GlucoseForecastSample]) { self.samples = samples }

    func snapshot(at date: Date) -> Result<PenDoseInputSnapshot, PenDoseUnavailableReason> {
        PenDoseInputSnapshot.make(capturedAt: date, glucose: samples, treatments: [],
            therapySettings: TherapyModelSettings(), treatmentRevision: 1)
    }
}

private actor DelayedPenDoseSnapshotFeed {
    private let samples: [GlucoseForecastSample]
    private var calls = 0
    private var firstRequest: CheckedContinuation<Void, Never>?
    private var enteredWaiter: CheckedContinuation<Void, Never>?

    init(samples: [GlucoseForecastSample]) { self.samples = samples }

    func snapshot(at date: Date) async -> Result<PenDoseInputSnapshot, PenDoseUnavailableReason> {
        calls += 1
        if calls == 1 {
            await withCheckedContinuation { continuation in
                firstRequest = continuation
                enteredWaiter?.resume()
                enteredWaiter = nil
            }
        }
        return PenDoseInputSnapshot.make(capturedAt: date, glucose: samples, treatments: [],
            therapySettings: TherapyModelSettings(), treatmentRevision: 1)
    }

    func waitForFirstRequest() async {
        if calls > 0 { return }
        await withCheckedContinuation { enteredWaiter = $0 }
    }

    func releaseFirstRequest() {
        firstRequest?.resume()
        firstRequest = nil
    }
}

@MainActor final class PenDoseCalculatorViewModelTests: XCTestCase {
    private func confirmedProfile() -> PenDoseProfile {
        var result = PenDoseProfile.prefilledUnconfirmed
        XCTAssertTrue(result.confirm())
        return result
    }

    private func sample(_ minutesAgo: Double, value: Double,
                        sensorID: String = "sensor-a", at now: Date) -> GlucoseForecastSample {
        GlucoseForecastSample(date: now.addingTimeInterval(-minutesAgo * 60),
            glucoseMgdl: value, sensorID: sensorID)
    }

    func testExplicitCGMPinSurvivesNewReadingWithoutTrendAndResetsAfterValidTrend() async throws {
        let now = Date()
        let initial = sample(5, value: 120, at: now)
        let feed = PenDoseSnapshotFeed(samples: [initial])
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let profile = confirmedProfile()
        let viewModel = PenDoseCalculatorViewModel(coreDataManager: core,
            profileProvider: { profile }, sourceReadyOverride: { true },
            snapshotProvider: { date, _ in await feed.snapshot(at: date) })
        await viewModel.calculate()
        XCTAssertEqual(viewModel.calculation?.unavailableReason, .missingTwentyMinuteTrend)

        viewModel.selectDisplayedCGMWithoutTrend()
        await viewModel.calculate()
        XCTAssertEqual(viewModel.glucoseChoice, .confirmStaleCGM)
        XCTAssertEqual(viewModel.calculation?.glucoseMgdl, initial.glucoseMgdl)
        XCTAssertEqual(viewModel.calculation?.glucoseMeasuredAt, initial.date)
        XCTAssertEqual(viewModel.calculation?.glucoseSensorID, initial.sensorID)
        XCTAssertTrue(viewModel.calculation?.trendWasIntentionallyZero == true)

        let newWithoutTrend = sample(1, value: 145, at: now)
        await feed.replace(with: [initial, newWithoutTrend])
        await viewModel.calculate()
        XCTAssertEqual(viewModel.glucoseChoice, .confirmStaleCGM)
        XCTAssertEqual(viewModel.displayedGlucoseValueMgdl, initial.glucoseMgdl)
        XCTAssertEqual(viewModel.displayedGlucoseDate, initial.date)
        XCTAssertEqual(viewModel.calculation?.glucoseMgdl, initial.glucoseMgdl)

        let continuous = [21.0, 16, 11, 6, 1].map { minutes in
            sample(minutes, value: 145 - minutes, at: now)
        }
        await feed.replace(with: continuous)
        await viewModel.calculate()
        XCTAssertEqual(viewModel.glucoseChoice, .currentCGM)
        await viewModel.calculate()
        XCTAssertEqual(viewModel.calculation?.glucoseMgdl, continuous.last?.glucoseMgdl)
        XCTAssertFalse(viewModel.calculation?.trendWasIntentionallyZero ?? true)
    }

    func testOlderAsyncCalculationCannotOverwriteNewerChangedDraft() async throws {
        let now = Date()
        let readings = [21.0, 16, 11, 6, 1].map { minutes in
            sample(minutes, value: 140 - minutes, at: now)
        }
        let feed = DelayedPenDoseSnapshotFeed(samples: readings)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let profile = confirmedProfile()
        let viewModel = PenDoseCalculatorViewModel(coreDataManager: core,
            profileProvider: { profile }, sourceReadyOverride: { true },
            snapshotProvider: { date, _ in await feed.snapshot(at: date) })
        viewModel.carbohydratesText = "10"
        let older = Task { await viewModel.calculate() }
        await feed.waitForFirstRequest()
        viewModel.carbohydratesText = "20"
        await viewModel.calculate()
        XCTAssertEqual(viewModel.calculationDetails?.newCarbsGrams, 20)
        await feed.releaseFirstRequest()
        await older.value
        XCTAssertEqual(viewModel.calculationDetails?.newCarbsGrams, 20)
        XCTAssertFalse(viewModel.isCalculating)
    }

    func testClockMinuteBoundaryInvalidatesSuggestionWithoutNewSensorEvent() async throws {
        let now = Date()
        let feed = PenDoseSnapshotFeed(samples: [sample(5, value: 120, at: now)])
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let profile = confirmedProfile()
        let viewModel = PenDoseCalculatorViewModel(coreDataManager: core,
            profileProvider: { profile }, sourceReadyOverride: { true },
            snapshotProvider: { date, _ in await feed.snapshot(at: date) })
        viewModel.start()
        await viewModel.calculate()
        viewModel.selectDisplayedCGMWithoutTrend()
        await viewModel.calculate()
        XCTAssertTrue(viewModel.isReviewCurrent)
        viewModel.refreshClock(now: now.addingTimeInterval(65))
        XCTAssertTrue(viewModel.isCalculating,
            "The existing 15-second clock must invalidate a dose at the next minute boundary")
        XCTAssertFalse(viewModel.isReviewCurrent)
        viewModel.stop()
    }
}
