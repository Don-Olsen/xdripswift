//
//  GlucoseChartYAxisRetentionTests.swift
//  xdripTests
//
//  Created by Paul Plant on 9/8/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import XCTest
@testable import xdrip

final class GlucoseChartYAxisRetentionTests: XCTestCase {

    private func reloadContext() -> GlucoseChartReloadGeometry.Context {
        .init(isLiveMainChart: true, hoursToShow: 3, forecastHorizonMinutes: 60,
              showsTherapy: true, rendersBasalDownwards: true, resetRevision: 0)
    }

    func testLiveForecastGeometrySurvivesUnavailablePointsAppearanceAndIdleReset() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let start = now.addingTimeInterval(-3 * 3600)
        let points = [GlucoseChartForecastPoint(date: now, glucoseMgdl: 120),
                      GlucoseChartForecastPoint(date: now.addingTimeInterval(3600), glucoseMgdl: 320)]
        let loaded = GlucoseChartReloadGeometry().updated(context: reloadContext(), forecastPoints: points,
            forecastReferenceDate: now, therapySeries: TherapyChartSeries(), start: start, end: now)
        let missing = loaded.updated(context: reloadContext(), forecastPoints: [], forecastReferenceDate: nil,
            therapySeries: TherapyChartSeries(), start: start.addingTimeInterval(20), end: now.addingTimeInterval(20))
        XCTAssertEqual(missing.forecastBounds, loaded.forecastBounds)
        // Appearance and the 10-second idle reset use the retained candidate, never the absent series.
        var axis = GlucoseChartYAxisRetentionState()
        axis.reset(to: try XCTUnwrap(missing.forecastBounds).values.upperBound)
        XCTAssertEqual(axis.effectiveMaximum(for: 200), 320)
        let reappeared = missing.updated(context: reloadContext(), forecastPoints: [], forecastReferenceDate: nil,
            therapySeries: TherapyChartSeries(), start: start.addingTimeInterval(30), end: now.addingTimeInterval(30))
        axis.reset(to: try XCTUnwrap(reappeared.forecastBounds).values.upperBound)
        XCTAssertEqual(axis.effectiveMaximum(for: 200), 320)
        let restored = reappeared.updated(context: reloadContext(), forecastPoints: points,
            forecastReferenceDate: now, therapySeries: TherapyChartSeries(), start: start, end: now)
        XCTAssertEqual(restored, loaded)
        // Geometry is separate from plotted validity: no old points are made visible by retention.
        XCTAssertTrue(GlucoseChartForecastPresentation.visiblePoints([], referenceDate: nil,
            visibleStartDate: start, visibleEndDate: now, isMainChart: true).isEmpty)
    }

    func testForecastGeometryReplacesExtremaImmediatelyWithoutAccumulation() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        let start = now.addingTimeInterval(-3600)
        func update(_ state: GlucoseChartReloadGeometry, _ values: [Double]) -> GlucoseChartReloadGeometry {
            state.updated(context: reloadContext(), forecastPoints: values.map {
                GlucoseChartForecastPoint(date: now, glucoseMgdl: $0)
            }, forecastReferenceDate: now, therapySeries: TherapyChartSeries(), start: start, end: now)
        }
        let initial = update(GlucoseChartReloadGeometry(), [100, 250])
        let expanded = update(initial, [20, 400])
        XCTAssertEqual(try XCTUnwrap(expanded.forecastBounds).values, 20...400)
        var smaller = update(expanded, [110, 180])
        for _ in 0..<100 { smaller = update(smaller, [110, 180]) }
        XCTAssertEqual(try XCTUnwrap(smaller.forecastBounds).values, 110...180)
        XCTAssertEqual(try XCTUnwrap(initial.forecastBounds).values, 100...250)
    }

    func testReloadGeometryResetsOnOffHistoryRangeVisibilityAndExplicitReset() {
        let now = Date(timeIntervalSince1970: 10_000)
        let start = now.addingTimeInterval(-3600)
        let loaded = GlucoseChartReloadGeometry().updated(context: reloadContext(), forecastPoints: [
            GlucoseChartForecastPoint(date: now, glucoseMgdl: 320)
        ], forecastReferenceDate: now,
            therapySeries: TherapyChartSeries(iob: [TherapyChartPoint(date: now, amount: 30, segment: 0)]),
            start: start, end: now)
        var off = reloadContext(); off.forecastHorizonMinutes = 0
        var history = reloadContext(); history.isLiveMainChart = false
        var wider = reloadContext(); wider.hoursToShow = 6
        var reset = reloadContext(); reset.resetRevision = 1
        var hidden = reloadContext(); hidden.showsTherapy = false
        var basal = reloadContext(); basal.rendersBasalDownwards = false
        for context in [off, history, wider, reset, hidden, basal] {
            let cleared = loaded.updated(context: context, forecastPoints: [], forecastReferenceDate: nil,
                therapySeries: TherapyChartSeries(), start: start, end: now)
            XCTAssertNil(cleared.forecastBounds)
            XCTAssertEqual(cleared.therapyReduction, 1)
        }
    }

    func testReloadGeometryExpiresWhenItsAnchorsLeaveTheLiveViewport() {
        let now = Date(timeIntervalSince1970: 10_000)
        let loaded = GlucoseChartReloadGeometry().updated(context: reloadContext(), forecastPoints: [
            GlucoseChartForecastPoint(date: now, glucoseMgdl: 320)
        ], forecastReferenceDate: now,
            therapySeries: TherapyChartSeries(iob: [TherapyChartPoint(date: now, amount: 30, segment: 0)]),
            start: now.addingTimeInterval(-3600), end: now)
        let expired = loaded.updated(context: reloadContext(), forecastPoints: [], forecastReferenceDate: nil,
            therapySeries: TherapyChartSeries(), start: now.addingTimeInterval(1), end: now.addingTimeInterval(3601))
        XCTAssertNil(expired.forecastBounds)
        XCTAssertNil(expired.iobMaximum)
        XCTAssertEqual(expired.therapyReduction, 1)
    }

    func testMissingDominantTherapyCurveDoesNotRescaleTheOtherCurve() {
        let now = Date(timeIntervalSince1970: 10_000)
        let start = now.addingTimeInterval(-3600)
        func point(_ value: Double) -> TherapyChartPoint { .init(date: now, amount: value, segment: 0) }
        for iobDominates in [true, false] {
            let full = TherapyChartSeries(iob: [point(iobDominates ? 30 : 10)], cob: [point(iobDominates ? 35 : 140)])
            let partial = TherapyChartSeries(iob: iobDominates ? [] : full.iob, cob: iobDominates ? full.cob : [])
            let loaded = GlucoseChartReloadGeometry().updated(context: reloadContext(), forecastPoints: [],
                forecastReferenceDate: nil, therapySeries: full, start: start, end: now)
            let missing = loaded.updated(context: reloadContext(), forecastPoints: [], forecastReferenceDate: nil,
                therapySeries: partial, start: start, end: now)
            let before = TherapyChartScale(series: full, baseline: -10, retainedReduction: loaded.therapyReduction)
            let during = TherapyChartScale(series: partial, baseline: -10, retainedReduction: missing.therapyReduction)
            XCTAssertEqual(before.reduction, 2)
            XCTAssertEqual(during.reduction, before.reduction)
            XCTAssertEqual(during.glucoseValue(amount: 7, isIOB: !iobDominates),
                           before.glucoseValue(amount: 7, isIOB: !iobDominates))
            let restored = missing.updated(context: reloadContext(), forecastPoints: [], forecastReferenceDate: nil,
                therapySeries: full, start: start, end: now)
            XCTAssertEqual(restored.therapyReduction, 2)
            // Retention does not populate the missing curve itself.
            XCTAssertTrue(iobDominates ? partial.iob.isEmpty : partial.cob.isEmpty)
        }
    }

    func testTherapyScaleUpdatesFromActualExtremaWithoutAccumulatingOrClipping() {
        let now = Date(timeIntervalSince1970: 10_000)
        func point(_ value: Double) -> TherapyChartPoint { .init(date: now, amount: value, segment: 0) }
        func update(_ geometry: GlucoseChartReloadGeometry, amount: Double) -> GlucoseChartReloadGeometry {
            geometry.updated(context: reloadContext(), forecastPoints: [], forecastReferenceDate: nil,
                therapySeries: TherapyChartSeries(iob: [point(amount)]), start: now.addingTimeInterval(-3600), end: now)
        }
        var geometry = update(GlucoseChartReloadGeometry(), amount: 30)
        for _ in 0..<100 { geometry = update(geometry, amount: 30) }
        XCTAssertEqual(geometry.therapyReduction, 2)
        let expanded = update(geometry, amount: 60)
        XCTAssertEqual(expanded.therapyReduction, 4)
        let scale = TherapyChartScale(series: TherapyChartSeries(iob: [point(60)]), baseline: -10,
                                     retainedReduction: expanded.therapyReduction)
        XCTAssertEqual(scale.glucoseValue(amount: 60, isIOB: true), 67)
        XCTAssertEqual(update(expanded, amount: 15).therapyReduction, 1)
    }

    func testCompactAndHistoricalChartsKeepAdaptiveGeometry() {
        let now = Date(timeIntervalSince1970: 10_000)
        var context = reloadContext(); context.isLiveMainChart = false
        let series = TherapyChartSeries(iob: [TherapyChartPoint(date: now, amount: 30, segment: 0)])
        let geometry = GlucoseChartReloadGeometry().updated(context: context,
            forecastPoints: [GlucoseChartForecastPoint(date: now, glucoseMgdl: 320)], forecastReferenceDate: now,
            therapySeries: series, start: now.addingTimeInterval(-3600), end: now)
        XCTAssertNil(geometry.forecastBounds)
        XCTAssertEqual(geometry.therapyReduction, 1)
        XCTAssertEqual(TherapyChartScale(series: series, baseline: -10).reduction, 2)
        XCTAssertEqual(TherapyChartScale(series: TherapyChartSeries(), baseline: -10).reduction, 1)
    }

    func testHomeTherapyAxisDoesNotDipWhenCurvesArriveAfterGlucose() {
        // Home initially renders cached glucose before the separate IOB/COB request completes.
        let beforeLoad = GlucoseChartTherapyDomain.minimum(
            basalMinimum: 38, therapyBaseline: -10, plottedMinimum: -10,
            hasVisiblePlots: false, reservesSpaceWhileLoading: true
        )
        let afterLoad = GlucoseChartTherapyDomain.minimum(
            basalMinimum: 38, therapyBaseline: -10, plottedMinimum: 4,
            hasVisiblePlots: true, reservesSpaceWhileLoading: true
        )
        XCTAssertEqual(beforeLoad, -10)
        XCTAssertEqual(afterLoad, beforeLoad)

        // Turning off the therapy overlay restores the ordinary glucose domain.
        XCTAssertEqual(GlucoseChartTherapyDomain.minimum(
            basalMinimum: 38, therapyBaseline: -10, plottedMinimum: -10,
            hasVisiblePlots: false, reservesSpaceWhileLoading: false
        ), 38)
        // Genuine values below the reserved floor must remain visible.
        XCTAssertEqual(GlucoseChartTherapyDomain.minimum(
            basalMinimum: 38, therapyBaseline: -10, plottedMinimum: -14,
            hasVisiblePlots: true, reservesSpaceWhileLoading: true
        ), -14)
    }

    func testBasalDirectionPreferenceDefaultsAndPersistence() throws {
        let suite = "BasalDirectionTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(defaults.renderBasalDownwards)
        defaults.renderBasalDownwards = false
        XCTAssertFalse(try XCTUnwrap(UserDefaults(suiteName: suite)).renderBasalDownwards)
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?[UserDefaults.Key.renderBasalDownwards.rawValue] as? Bool, false)
        defaults.removeObject(forKey: UserDefaults.Key.renderBasalDownwards.rawValue)
        XCTAssertTrue(defaults.renderBasalDownwards)
    }

    func testDownwardBasalAnchorsZeroAtTopAndPreservesHeight() {
        let layout = GlucoseChartBasalLayout(cachedBaseline: -10, values: [-10, 14, 38],
                                            rendersDownwards: true, contentTop: 258, chartTop: 258)
        XCTAssertEqual(layout.topSpace, 48)
        XCTAssertEqual(layout.baseline, 306)
        XCTAssertEqual(layout.value(-10), 306)
        XCTAssertEqual(layout.value(14), 282)
        XCTAssertEqual(layout.value(38), 258)
    }

    func testBasalReusesAxisHeadroomWithoutReducingDepth() {
        let spacious = GlucoseChartBasalLayout(cachedBaseline: -10, values: [38],
                                              rendersDownwards: true, contentTop: 138, chartTop: 238)
        XCTAssertEqual(spacious.topSpace, 0)
        XCTAssertEqual(spacious.baseline, 238)
        XCTAssertEqual(spacious.value(38), 190)
        let partial = GlucoseChartBasalLayout(cachedBaseline: -10, values: [38],
                                            rendersDownwards: true, contentTop: 218, chartTop: 238)
        XCTAssertEqual(partial.topSpace, 28)
        XCTAssertEqual(partial.value(38), 218)
        // A short basal does not need the full maximum-rate band above the highest point.
        let short = GlucoseChartBasalLayout(cachedBaseline: -10, values: [10],
                                          rendersDownwards: true, contentTop: 238, chartTop: 238)
        XCTAssertEqual(short.topSpace, 20)
        XCTAssertEqual(short.value(10), 238)
    }

    func testBasalSpaceDependsOnDirectionAndVisibleData() {
        for downwards in [false, true] {
            let empty = GlucoseChartBasalLayout(cachedBaseline: -10, values: [],
                                               rendersDownwards: downwards, contentTop: 258, chartTop: 258)
            XCTAssertEqual(empty.topSpace, 0)
        }
        let upward = GlucoseChartBasalLayout(cachedBaseline: -10, values: [-10, 38],
                                            rendersDownwards: false, contentTop: 258, chartTop: 258)
        XCTAssertEqual(upward.topSpace, 0)
        XCTAssertEqual(upward.baseline, -10)
        XCTAssertEqual(upward.value(38), 38)
        let day = GlucoseChartBasalLayout(cachedBaseline: 0, values: [0, 38],
                                         rendersDownwards: true, contentTop: 258, chartTop: 258)
        XCTAssertEqual(day.topSpace, 38)
        let large = GlucoseChartBasalLayout(cachedBaseline: -10, values: [90],
                                           rendersDownwards: true, contentTop: 258, chartTop: 258)
        XCTAssertEqual(large.topSpace, 100)
        XCTAssertEqual(large.value(90), 258)
    }

    func testCompleteBasalCeilingHoldsUntilResetWithoutAccumulating() {
        var retention = GlucoseChartYAxisRetentionState()
        // Axis context stays at 250 while basal clearance varies with visible glucose.
        func candidate(_ glucose: Double) -> GlucoseChartBasalLayout {
            GlucoseChartBasalLayout(cachedBaseline: -10, values: [38], rendersDownwards: true,
                                   contentTop: glucose + 8, chartTop: 258)
        }
        for glucose in [250.0, 230, 200, 250, 190] {
            let required = candidate(glucose)
            let maximum = 250 + required.topSpace
            retention.retain(maximumInMgDl: maximum)
            let heldTop = retention.effectiveMaximum(for: maximum) + 8
            XCTAssertEqual(heldTop, 306)
            XCTAssertEqual(required.anchored(to: heldTop).value(38), 258)
        }
        let current = candidate(190)
        // Both the idle timer and double tap replace the held ceiling with today's candidate.
        retention.reset(to: 250 + current.topSpace)
        XCTAssertEqual(retention.effectiveMaximum(for: 250), 250)
        for _ in 0..<100 {
            retention.retain(maximumInMgDl: 250 + current.topSpace)
            XCTAssertEqual(retention.effectiveMaximum(for: 250), 250)
        }
        // A newly arriving high point must expand the chart immediately, before publication.
        let higher = candidate(300)
        XCTAssertEqual(retention.effectiveMaximum(for: 250 + higher.topSpace), 348)
    }

    /// A finished load can still have a main-queue delivery pending when the chart disappears.
    @MainActor
    func testCleanupRejectsAlreadyQueuedPublication() async {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let syncManager = NightscoutSyncManager(coreDataManager: coreDataManager, messageHandler: nil)
        let queue = OperationQueue()
        let chart = GlucoseChartStateManager(coreDataManager: coreDataManager, nightscoutSyncManager: syncManager, operationQueue: queue)
        let originalEndDate = chart.state.endDate
        let date = Date(timeIntervalSince1970: 100)
        let finished = DispatchSemaphore(value: 0)

        // An empty range avoids Core Data reads while we briefly hold the main queue to keep
        // delivery pending. The barrier confirms processing has finished, not just started.
        queue.isSuspended = true
        for _ in 0..<2 {
            // Queue both together to cover the coalesced callback as well as a computed result.
            chart.updateState(endDate: date, startDate: date, showTreatments: false) { _ in
                XCTFail("A result from before cleanup must not be delivered")
            }
        }
        queue.addBarrierBlock { finished.signal() }
        queue.isSuspended = false
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        chart.cleanUpMemory()

        // Drain the old delivery before checking that it left the published state untouched.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(chart.state.endDate, originalEndDate)

        // A new lifecycle must still publish normally after the cleanup barrier.
        let updated: GlucoseChartState = await withCheckedContinuation { continuation in
            chart.updateState(endDate: date, startDate: date, showTreatments: false) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(updated.endDate, date)
    }

    /// Reopening the same range must reload storage rather than reuse the discarded cache.
    @MainActor
    func testCleanupResetsCacheBeforeFollowingLoad() async {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let date = Date().addingTimeInterval(-60)
        let treatment = TreatmentEntry(date: date, value: 3, treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "Test", nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
        XCTAssertTrue(coreDataManager.saveChanges())
        let syncManager = NightscoutSyncManager(coreDataManager: coreDataManager, messageHandler: nil)
        let chart = GlucoseChartStateManager(coreDataManager: coreDataManager, nightscoutSyncManager: syncManager)
        let endDate = Date()
        let first: GlucoseChartState = await withCheckedContinuation { continuation in
            chart.updateState(endDate: endDate, startDate: date.addingTimeInterval(-3600), showTreatments: true) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(first.treatmentPoints.boluses.count, 1)

        // Keep the requested dates identical and omit forceReset so only lifecycle cleanup can
        // remove the old snapshot. Submitting immediately also exercises the barrier ordering.
        coreDataManager.mainManagedObjectContext.delete(treatment)
        XCTAssertTrue(coreDataManager.saveChanges())
        chart.cleanUpMemory()
        let reopened: GlucoseChartState = await withCheckedContinuation { continuation in
            chart.updateState(endDate: endDate, startDate: date.addingTimeInterval(-3600), showTreatments: true) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(reopened.treatmentPoints.boluses.isEmpty)
    }

    /// A newer viewport request must not drop a reset requested by a coalesced update.
    @MainActor
    func testCoalescedChartUpdateKeepsForceReset() async {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let date = Date().addingTimeInterval(-60)
        let treatment = TreatmentEntry(date: date, value: 3, treatmentType: .Insulin,
                                       nightscoutEventType: nil, enteredBy: "Test",
                                       nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
        XCTAssertTrue(coreDataManager.saveChanges())
        let syncManager = NightscoutSyncManager(coreDataManager: coreDataManager, messageHandler: nil)
        let queue = OperationQueue()
        let chart = GlucoseChartStateManager(coreDataManager: coreDataManager,
                                             nightscoutSyncManager: syncManager, operationQueue: queue)
        let endDate = Date()
        let startDate = date.addingTimeInterval(-3600)
        let first: GlucoseChartState = await withCheckedContinuation { continuation in
            chart.updateState(endDate: endDate, startDate: startDate, showTreatments: true) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(first.treatmentPoints.boluses.count, 1)

        coreDataManager.mainManagedObjectContext.delete(treatment)
        XCTAssertTrue(coreDataManager.saveChanges())
        queue.isSuspended = true
        chart.updateState(endDate: endDate, startDate: startDate, forceReset: true, showTreatments: true)
        let latest: GlucoseChartState = await withCheckedContinuation { continuation in
            chart.updateState(endDate: endDate, startDate: startDate, showTreatments: true) {
                continuation.resume(returning: $0)
            }
            queue.isSuspended = false
        }
        XCTAssertTrue(latest.treatmentPoints.boluses.isEmpty)
    }

    /// A coalesced refresh must still bring recent treatment changes into the cached range.
    @MainActor
    func testCoalescedChartUpdateKeepsRefreshCachedData() async {
        let coreDataManager = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let syncManager = NightscoutSyncManager(coreDataManager: coreDataManager, messageHandler: nil)
        let queue = OperationQueue()
        let chart = GlucoseChartStateManager(coreDataManager: coreDataManager,
                                             nightscoutSyncManager: syncManager, operationQueue: queue)
        let endDate = Date()
        let startDate = endDate.addingTimeInterval(-3600)
        let first: GlucoseChartState = await withCheckedContinuation { continuation in
            chart.updateState(endDate: endDate, startDate: startDate, showTreatments: true) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(first.treatmentPoints.boluses.isEmpty)

        _ = TreatmentEntry(date: endDate.addingTimeInterval(-60), value: 3,
                           treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "Test",
                           nsManagedObjectContext: coreDataManager.mainManagedObjectContext)
        XCTAssertTrue(coreDataManager.saveChanges())
        queue.isSuspended = true
        chart.updateState(endDate: endDate, startDate: startDate, refreshCachedData: true, showTreatments: true)
        let latest: GlucoseChartState = await withCheckedContinuation { continuation in
            chart.updateState(endDate: endDate, startDate: startDate, showTreatments: true) {
                continuation.resume(returning: $0)
            }
            queue.isSuspended = false
        }
        XCTAssertEqual(latest.treatmentPoints.boluses.count, 1)
    }

    /// Marker rows must never be fetched into the mini cache, including reset and refresh loads.
    @MainActor
    func testMiniChartOmitsMarkerFetchesAndRegularChartRetainsHiddenTreatments() async throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let endDate = Date()
        let startDate = endDate.addingTimeInterval(-3600)
        let date = endDate.addingTimeInterval(-60)
        let reading = BgReading(timeStamp: date, sensor: nil, calibration: nil, rawData: 120,
                                deviceName: "Test", nsManagedObjectContext: core.mainManagedObjectContext)
        reading.calculatedValue = 120
        let sensor = Sensor(startDate: startDate, nsManagedObjectContext: core.mainManagedObjectContext)
        let calibration = Calibration(timeStamp: date, sensor: sensor, bg: 130,
                                      rawValue: 130, adjustedRawValue: 130, sensorConfidence: 1,
                                      rawTimeStamp: date, slope: 1, intercept: 0,
                                      distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: 130,
                                      slopeConfidence: 1, deviceName: "Test",
                                      nsManagedObjectContext: core.mainManagedObjectContext)
        let treatment = TreatmentEntry(date: date, value: 3, treatmentType: .Insulin,
                                       nightscoutEventType: nil, enteredBy: "Test",
                                       nsManagedObjectContext: core.mainManagedObjectContext)
        // Child-context saves may retain temporary IDs after the parent has committed.
        // Promote fixture IDs first so registration checks identify the actual stored rows.
        try core.mainManagedObjectContext.obtainPermanentIDs(for: [reading, sensor, calibration, treatment])
        XCTAssertTrue(core.saveChangesSynchronously())
        let markerIDs = Set([calibration.objectID, treatment.objectID])
        XCTAssertTrue(markerIDs.allSatisfy { !$0.isTemporaryID })
        let sync = NightscoutSyncManager(coreDataManager: core, messageHandler: nil)
        let context = core.privateManagedObjectContext
        // Retain fetched objects so an accessor read remains observable after snapshot mapping.
        // Reset first to remove registrations from saving the fixtures into the parent context.
        context.performAndWait {
            context.reset()
            context.retainsRegisteredObjects = true
            XCTAssertTrue(context.registeredObjects.isEmpty)
        }
        let mini = GlucoseChartStateManager(coreDataManager: core, nightscoutSyncManager: sync,
                                            loadMode: .miniChart)
        for (forceReset, refresh) in [(false, false), (false, true), (true, false)] {
            let state: GlucoseChartState = await withCheckedContinuation { continuation in
                mini.updateState(endDate: endDate, startDate: startDate, forceReset: forceReset,
                                 refreshCachedData: refresh, showTreatments: true) {
                    continuation.resume(returning: $0)
                }
            }
            XCTAssertEqual(state.bgReadingValues, [120])
            XCTAssertTrue(state.calibrationPoints.isEmpty)
            XCTAssertTrue(state.treatmentPoints.boluses.isEmpty)
            context.performAndWait {
                XCTAssertTrue(context.registeredObjects.allSatisfy { !markerIDs.contains($0.objectID) },
                              "The mini load must skip marker fetches, not only hide their output")
            }
        }

        context.performAndWait { context.reset() }
        let regular = GlucoseChartStateManager(coreDataManager: core, nightscoutSyncManager: sync)
        let hidden: GlucoseChartState = await withCheckedContinuation { continuation in
            regular.updateState(endDate: endDate, startDate: startDate, showTreatments: false) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(hidden.calibrationPoints.map(\.value), [130])
        XCTAssertTrue(hidden.treatmentPoints.boluses.isEmpty)
        context.performAndWait {
            XCTAssertTrue(markerIDs.isSubset(of: Set(context.registeredObjects.map(\.objectID))))
        }
        // Turning treatments on must use the full chart's existing cached range without a reset.
        let visible: GlucoseChartState = await withCheckedContinuation { continuation in
            regular.updateState(endDate: endDate, startDate: startDate, showTreatments: true) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(visible.bgReadingValues, [120])
        XCTAssertEqual(visible.calibrationPoints.map(\.value), [130])
        XCTAssertEqual(visible.treatmentPoints.boluses.map(\.treatmentValue), [3])
    }

    /// Both glucose caches remain available for processed rendering, raw peek and source validity.
    @MainActor
    func testMiniChartPreservesOriginalSuppressedRowsAndRefreshesSensorProvenance() async {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let endDate = Date()
        let startDate = endDate.addingTimeInterval(-3600)
        let sensorA = Sensor(startDate: startDate, nsManagedObjectContext: core.mainManagedObjectContext)
        let sensorB = Sensor(startDate: startDate, nsManagedObjectContext: core.mainManagedObjectContext)
        func add(_ secondsAgo: TimeInterval, raw: Double, processed: Double,
                 sensor: Sensor, suppressed: Bool) {
            let reading = BgReading(timeStamp: endDate.addingTimeInterval(-secondsAgo), sensor: sensor,
                                    calibration: nil, rawData: raw, deviceName: "Test",
                                    nsManagedObjectContext: core.mainManagedObjectContext)
            reading.calculatedValue = raw
            reading.smoothedValue = NSNumber(value: processed)
            reading.isSuppressedByFiveMinuteCadence = suppressed
        }
        add(120, raw: 120, processed: 140, sensor: sensorA, suppressed: false)
        add(60, raw: 130, processed: 150, sensor: sensorA, suppressed: true)
        XCTAssertTrue(core.saveChangesSynchronously())
        let sync = NightscoutSyncManager(coreDataManager: core, messageHandler: nil)
        let mini = GlucoseChartStateManager(coreDataManager: core, nightscoutSyncManager: sync,
                                            loadMode: .miniChart)
        let processed: GlucoseChartState = await withCheckedContinuation { continuation in
            mini.updateState(endDate: endDate, startDate: startDate, showTreatments: false) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(processed.bgReadingValues, [140])
        XCTAssertEqual(processed.newestBgReadingDate, endDate.addingTimeInterval(-120))
        XCTAssertTrue(processed.newestBgReadingIsValidForDownstream)
        let original: GlucoseChartState = await withCheckedContinuation { continuation in
            mini.updateState(endDate: endDate, startDate: startDate, showTreatments: false,
                             showOriginalReadingsOnly: true) { continuation.resume(returning: $0) }
        }
        XCTAssertTrue(original.bgReadingValues.isEmpty)
        XCTAssertEqual(original.additionalBgReadingDataSets.first?.bgReadingValues, [120, 130])
        XCTAssertEqual(original.dataStartDate, processed.dataStartDate)

        add(30, raw: 160, processed: 170, sensor: sensorB, suppressed: true)
        XCTAssertTrue(core.saveChangesSynchronously())
        let refreshed: GlucoseChartState = await withCheckedContinuation { continuation in
            mini.updateState(endDate: endDate, startDate: startDate, refreshCachedData: true,
                             showTreatments: false, showOriginalReadingsOnly: true) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(refreshed.additionalBgReadingDataSets.first?.bgReadingValues, [120, 130, 160])
        XCTAssertEqual(refreshed.newestBgReadingDate, processed.newestBgReadingDate)
        XCTAssertFalse(refreshed.newestBgReadingIsValidForDownstream)
        XCTAssertEqual(refreshed.dataStartDate, processed.dataStartDate)
    }

    /// A coalesced reset reloads edits in older cached history, outside the recent-tail refresh.
    @MainActor
    func testMiniChartCoalescedForceResetReloadsHistoricalGlucose() async {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let endDate = Date().addingTimeInterval(-48 * 3600)
        let startDate = endDate.addingTimeInterval(-3600)
        let reading = BgReading(timeStamp: endDate.addingTimeInterval(-60), sensor: nil,
                                calibration: nil, rawData: 120, deviceName: "Test",
                                nsManagedObjectContext: core.mainManagedObjectContext)
        reading.calculatedValue = 120
        XCTAssertTrue(core.saveChangesSynchronously())
        let sync = NightscoutSyncManager(coreDataManager: core, messageHandler: nil)
        let queue = OperationQueue()
        let mini = GlucoseChartStateManager(coreDataManager: core, nightscoutSyncManager: sync,
                                            loadMode: .miniChart, operationQueue: queue)
        let initial: GlucoseChartState = await withCheckedContinuation { continuation in
            mini.updateState(endDate: endDate, startDate: startDate, showTreatments: false) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertEqual(initial.bgReadingValues, [120])
        reading.calculatedValue = 180
        XCTAssertTrue(core.saveChangesSynchronously())
        queue.isSuspended = true
        mini.updateState(endDate: endDate, startDate: startDate, forceReset: true, showTreatments: false)
        let updated: GlucoseChartState = await withCheckedContinuation { continuation in
            mini.updateState(endDate: endDate, startDate: startDate, showTreatments: false) {
                continuation.resume(returning: $0)
            }
            queue.isSuspended = false
        }
        XCTAssertEqual(updated.bgReadingValues, [180])
        XCTAssertEqual(updated.startDate, startDate)
        XCTAssertEqual(updated.endDate, endDate)
    }

    /// The newest mini viewport inherits a skipped refresh for a newly inserted cached reading.
    @MainActor
    func testMiniChartCoalescedRefreshReloadsRecentGlucose() async {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let sync = NightscoutSyncManager(coreDataManager: core, messageHandler: nil)
        let queue = OperationQueue()
        let mini = GlucoseChartStateManager(coreDataManager: core, nightscoutSyncManager: sync,
                                            loadMode: .miniChart, operationQueue: queue)
        let endDate = Date()
        let startDate = endDate.addingTimeInterval(-3600)
        let initial: GlucoseChartState = await withCheckedContinuation { continuation in
            mini.updateState(endDate: endDate, startDate: startDate, showTreatments: false) {
                continuation.resume(returning: $0)
            }
        }
        XCTAssertTrue(initial.bgReadingValues.isEmpty)
        let reading = BgReading(timeStamp: endDate.addingTimeInterval(-60), sensor: nil,
                                calibration: nil, rawData: 125, deviceName: "Test",
                                nsManagedObjectContext: core.mainManagedObjectContext)
        reading.calculatedValue = 125
        XCTAssertTrue(core.saveChangesSynchronously())
        queue.isSuspended = true
        mini.updateState(endDate: endDate, startDate: startDate, refreshCachedData: true,
                         showTreatments: false)
        let updated: GlucoseChartState = await withCheckedContinuation { continuation in
            mini.updateState(endDate: endDate, startDate: startDate, showTreatments: false) {
                continuation.resume(returning: $0)
            }
            queue.isSuspended = false
        }
        XCTAssertEqual(updated.bgReadingValues, [125])
        XCTAssertEqual(updated.dataStartDate, initial.dataStartDate)
    }

    /// Repeated chart updates must not retain the owner through queued closures or old work items.
    @MainActor
    func testDelayedStateReleasesAfterHeavyRescheduling() {
        var state: ChartDelayedState<Int>? = ChartDelayedState(0)
        weak var releasedState = state
        // Exceed the depth seen in the crash while keeping every callback pending during teardown.
        for value in 0..<20_000 { state?.schedule(value, after: 60) }
        state = nil
        XCTAssertNil(releasedState)
    }

    /// Only the latest request may publish, and disappearance cancellation must prevent publication.
    @MainActor
    func testDelayedStateReplacementAndCancellation() async throws {
        let state = ChartDelayedState(0)
        state.schedule(1, after: 0.02)
        state.schedule(2, after: 0)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(state.value, 2)

        state.schedule(3, after: 0.02)
        state.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(state.value, 2)
    }

    func testRetentionExpandsImmediatelyAndDoesNotContract() {
        var state = GlucoseChartYAxisRetentionState()

        state.retain(maximumInMgDl: 200)
        state.retain(maximumInMgDl: 320)
        state.retain(maximumInMgDl: 250)

        XCTAssertEqual(state.effectiveMaximum(for: 250), 320)
    }

    func testResetAllowsContraction() {
        var state = GlucoseChartYAxisRetentionState()

        state.retain(maximumInMgDl: 320)
        state.reset(to: 200)

        XCTAssertEqual(state.effectiveMaximum(for: 200), 200)
    }

    func testRetentionNeverClipsANewHigherMaximumAfterReset() {
        var state = GlucoseChartYAxisRetentionState()

        state.reset(to: 200)

        XCTAssertEqual(state.effectiveMaximum(for: 280), 280)
    }
}
