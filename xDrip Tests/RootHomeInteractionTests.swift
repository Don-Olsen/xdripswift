//
//  RootHomeInteractionTests.swift
//  xdripTests
//
//  Created by Paul Plant on 9/8/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Combine
import CoreData
import SwiftUI
import XCTest
@testable import xdrip

final class RootHomeInteractionTests: XCTestCase {

    @MainActor
    func testForecastBadgeWrapsValuesAndRetainsTouchHeightAtLargeText() {
        let info = forecastVisualInformation()
        let regular = UIHostingController(rootView: RootHomeForecastBadge(
            information: info, showInformation: {}).frame(maxWidth: 265)
            .environment(\.dynamicTypeSize, .large))
        let accessible = UIHostingController(rootView: RootHomeForecastBadge(
            information: info, showInformation: {}).frame(maxWidth: 265)
            .environment(\.dynamicTypeSize, .accessibility3))
        let regularSize = regular.sizeThatFits(in: CGSize(width: 265, height: 600))
        let accessibleSize = accessible.sizeThatFits(in: CGSize(width: 265, height: 600))
        XCTAssertGreaterThanOrEqual(regularSize.height, 44)
        XCTAssertLessThanOrEqual(regularSize.width, 265)
        XCTAssertLessThanOrEqual(accessibleSize.width, 265)
        XCTAssertGreaterThan(accessibleSize.height, regularSize.height,
            "Large text must wrap rather than shrink or cut off the forecast values")
    }

    /// Synthetic presentation fixtures only; no user measurements or model are loaded.
    @MainActor
    func testRenderCompactForecastAtNormalAndAccessibleTextSizes() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let start = now.addingTimeInterval(-3 * 3600)
        for (width, textSize, isMgDl) in [(320.0, DynamicTypeSize.large, false),
                                        (320.0, .accessibility3, false),
                                        (430.0, .large, true)] {
            var state = GlucoseChartState.empty(startDate: start, endDate: now)
            state.bgReadingDates = (0...180).map { start.addingTimeInterval(Double($0) * 60) }
            state.bgReadingValues = (0...180).map { 118 + 10 * sin(Double($0) / 30) }
            state.treatmentPoints.carbs = [.init(date: now.addingTimeInterval(-3600),
                yValue: 145, treatmentValue: 30, label: "30", notes: nil, idPrefix: "synthetic-carbs")]
            state.treatmentPoints.boluses = [.init(date: now.addingTimeInterval(-3300),
                yValue: 90, treatmentValue: 2.5, label: "2,5", notes: nil, idPrefix: "synthetic-bolus")]
            let points = (0...24).map { index in
                GlucoseChartForecastPoint(date: now.addingTimeInterval(Double(index) * 300),
                    glucoseMgdl: 115 + Double(index) * 0.7)
            }
            let band = points.enumerated().map { index, point in
                GlucoseChartForecastBandPoint(date: point.date,
                    lowerMgdl: point.glucoseMgdl - Double(index) * 2,
                    upperMgdl: point.glucoseMgdl + Double(index) * 2)
            }
            let chart = GlucoseChartView(glucoseChartType: .widgetSystemLarge,
                bgReadingValues: nil, bgReadingDates: nil, isMgDl: isMgDl,
                urgentLowLimitInMgDl: 55, lowLimitInMgDl: 70, highLimitInMgDl: 180,
                urgentHighLimitInMgDl: 230, liveActivityType: nil,
                hoursToShowScalingHours: 3, glucoseCircleDiameterScalingHours: 3,
                showsTreatments: true, overrideChartHeight: 360, overrideChartWidth: width,
                highContrast: nil, chartState: state)
                .mainChartYAxisContext(resetRevision: 0, renderBasalDownwards: true, isLiveViewport: true)
                .forecastPlot(points, bandPoints: band, isML: true, from: now, horizonMinutes: 120)
            let information = forecastVisualInformation(isMgDl: isMgDl)
            let content = ZStack(alignment: .topLeading) {
                chart
                RootHomeForecastBadge(information: information, showInformation: {})
                    .frame(maxWidth: width - 55, alignment: .leading).padding(7)
            }
            .frame(width: width, height: 360).background(Color.black)
            .environment(\.colorScheme, .dark).environment(\.dynamicTypeSize, textSize)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
            attachment.name = "Synthetic Home forecast \(Int(width))pt \(textSize) \(isMgDl ? "mgdl" : "mmol")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        // NavigationStack contains UIKit views that ImageRenderer cannot capture.
        // Mount the real information view in an active simulator scene instead.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 680)
        let appeared = expectation(description: "Forecast information appears in simulator")
        let information = RootHomeForecastInformationView(information: forecastVisualInformation())
            .environment(\.colorScheme, .dark)
            .onAppear { appeared.fulfill() }
        let controller = UIHostingController(rootView: information)
        controller.overrideUserInterfaceStyle = .dark
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousWindow?.makeKey()
        }
        await fulfillment(of: [appeared], timeout: 2)
        try await Task.sleep(nanoseconds: 150_000_000)
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            XCTAssertTrue(controller.view.drawHierarchy(in: controller.view.bounds,
                afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Synthetic forecast information"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func forecastVisualInformation(isMgDl: Bool = false) -> RootHomeForecastInformation {
        RootHomeForecastInformation(kind: "ML-estimat", unit: isMgDl ? "mg/dL" : "mmol/L",
            reference: "Fra måling kl. 14.00", source: "Manuelt angivet ISF og kulhydratfaktor",
            values: isMgDl ? ["+30 125", "+60 129", "+120 138"] : ["+30 6,9", "+60 7,2", "+120 7,7"],
            status: nil, isML: true, hasPlannedMeal: false, isLongHorizon: true)
    }

    @MainActor
    func testClockPublishesOnlyWhenItsDisplayedMinuteChanges() throws {
        let model = RootHomeStateModel()
        let minute = try XCTUnwrap(Calendar.current.dateInterval(of: .minute,
            for: Date(timeIntervalSince1970: 1_800_000_000))?.start)
        var publications: [String] = []
        let observation = model.$state.dropFirst().sink { state in
            XCTAssertTrue(Thread.isMainThread)
            publications.append(state.controls.clockText)
        }
        defer { observation.cancel() }

        model.updateClock(now: minute)
        for second in 1..<60 {
            model.updateClock(now: minute.addingTimeInterval(Double(second)))
        }
        XCTAssertEqual(publications, [minute.formatted(date: .omitted, time: .shortened)],
            "Second ticks within the displayed minute must not republish all Home state")

        let nextMinute = minute.addingTimeInterval(60)
        model.updateClock(now: nextMinute)
        model.updateClock(now: nextMinute.addingTimeInterval(1))
        XCTAssertEqual(publications, [minute, nextMinute].map {
            $0.formatted(date: .omitted, time: .shortened)
        })
        XCTAssertEqual(model.state.controls.clockText, publications.last)
    }

    @MainActor
    func testBackgroundClockCallsCompareOnMainWithoutDuplicatePublications() async throws {
        let model = RootHomeStateModel()
        let minute = try XCTUnwrap(Calendar.current.dateInterval(of: .minute,
            for: Date(timeIntervalSince1970: 1_800_000_000))?.start)
        var publications: [String] = []
        let observation = model.$state.dropFirst().sink { state in
            XCTAssertTrue(Thread.isMainThread, "The comparison and publication belong on main")
            publications.append(state.controls.clockText)
        }
        defer { observation.cancel() }

        for date in [minute, minute.addingTimeInterval(60)] {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    for second in 0..<5 {
                        model.updateClock(now: date.addingTimeInterval(Double(second)))
                    }
                    // FIFO barrier after all production main-queue updates, without a sleep.
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
        }
        XCTAssertEqual(publications, [minute, minute.addingTimeInterval(60)].map {
            $0.formatted(date: .omitted, time: .shortened)
        }, "Queued background calls for the same displayed text must publish once")
    }

    @MainActor
    func testHostedHiddenMiniChartDoesNotQueueHomeRefreshRequests() async throws {
        let harness = try HostedHomeCalculatorHarness(controlsMiniChart: true)
        defer { harness.finish() }
        let queue = try XCTUnwrap(harness.miniChartQueue)
        XCTAssertTrue(queue.isSuspended)
        await harness.mount(in: self)
        XCTAssertFalse(harness.homeState.state.visibility.showsMiniChart)
        XCTAssertEqual(queue.operationCount, 0, "Hidden Home must skip its initial overview load")

        harness.homeState.invalidateCharts()
        harness.homeState.resetChartsToNow()
        UserDefaults.standard.miniChartHoursToShow = ConstantsGlucoseChart.miniChartHoursToShow2
        NotificationCenter.default.post(name: .nightscoutFollowerGapFillDidMergeHistory, object: nil)
        await harness.renderPendingChanges()
        harness.inputs.scenePhase = .inactive
        await harness.renderPendingChanges()
        harness.inputs.scenePhase = .active
        await harness.renderPendingChanges()
        XCTAssertEqual(queue.operationCount, 0,
            "Data, range, historical merge and foreground callbacks must not load a hidden overview")
    }

    @MainActor
    func testHostedMiniChartReappearanceReloadsEditedAndDeletedHistoricalGlucose() async throws {
        let harness = try HostedHomeCalculatorHarness(controlsMiniChart: true)
        defer { harness.finish() }
        let queue = try XCTUnwrap(harness.miniChartQueue)
        let chart = try XCTUnwrap(harness.miniChart)
        let historicalDate = Date().addingTimeInterval(-.hours(12))
        let deletedDate = historicalDate.addingTimeInterval(-3600)
        let reading = BgReading(timeStamp: historicalDate, sensor: nil, calibration: nil,
            rawData: 110, deviceName: "Home overview test",
            nsManagedObjectContext: harness.core.mainManagedObjectContext)
        reading.calculatedValue = 110
        let deletedReading = BgReading(timeStamp: deletedDate, sensor: nil, calibration: nil,
            rawData: 95, deviceName: "Home overview test",
            nsManagedObjectContext: harness.core.mainManagedObjectContext)
        deletedReading.calculatedValue = 95
        XCTAssertTrue(harness.core.saveChangesSynchronously())
        harness.setMiniChartVisibility(true)
        let loaded = expectation(description: "Visible Home loads its real overview cache")
        let initialObservation = chart.$state.first { state in
            zip(state.bgReadingDates, state.bgReadingValues).contains {
                $0.0 == historicalDate && $0.1 == 110
            }
        }.sink { _ in loaded.fulfill() }
        defer { initialObservation.cancel() }
        queue.isSuspended = false
        await harness.mount(in: self)
        await fulfillment(of: [loaded], timeout: 2)
        await harness.renderPendingChanges()
        XCTAssertTrue(chart.state.bgReadingDates.contains(deletedDate))

        // Both hiding mechanisms must reopen immediately. The point is older than the
        // manager's six-hour refresh tail, so a normal recent-data refresh cannot fix it.
        for (index, hideWithClockMode) in [false, true].enumerated() {
            queue.isSuspended = true
            harness.setMiniChartVisibility(hideWithClockMode, clockMode: hideWithClockMode)
            await harness.renderPendingChanges()
            XCTAssertFalse(harness.homeState.state.visibility.showsMiniChart)
            XCTAssertEqual(queue.operationCount, 0)

            let editedValue = Double(190 + index * 50)
            reading.calculatedValue = editedValue
            if hideWithClockMode {
                harness.core.mainManagedObjectContext.delete(deletedReading)
            }
            XCTAssertTrue(harness.core.saveChangesSynchronously())
            UserDefaults.standard.miniChartHoursToShow = hideWithClockMode
                ? ConstantsGlucoseChart.miniChartHoursToShow1 : ConstantsGlucoseChart.miniChartHoursToShow2
            harness.homeState.invalidateCharts()
            NotificationCenter.default.post(name: .nightscoutFollowerGapFillDidMergeHistory, object: nil)
            await harness.renderPendingChanges()
            XCTAssertEqual(queue.operationCount, 0, "Hidden invalidations must not enqueue cache work")
            let oldIndex = try XCTUnwrap(chart.state.bgReadingDates.firstIndex(of: historicalDate))
            XCTAssertNotEqual(chart.state.bgReadingValues[oldIndex], editedValue)

            let refreshed = expectation(description: "Reappearing overview reloads persistent history")
            let observation = chart.$state.first { state in
                zip(state.bgReadingDates, state.bgReadingValues).contains {
                    $0.0 == historicalDate && $0.1 == editedValue
                } && (!hideWithClockMode || !state.bgReadingDates.contains(deletedDate))
            }.sink { _ in refreshed.fulfill() }
            defer { observation.cancel() }
            harness.setMiniChartVisibility(true)
            await harness.renderPendingChanges()
            XCTAssertTrue(harness.homeState.state.visibility.showsMiniChart)
            XCTAssertGreaterThan(queue.operationCount, 0,
                "The visibility callback must use its new value and load without the 15-second timer")
            queue.isSuspended = false
            await fulfillment(of: [refreshed], timeout: 2)
            let expectedHours = UserDefaults.standard.miniChartHoursToShow
            XCTAssertEqual(chart.state.endDate.timeIntervalSince(chart.state.startDate),
                .hours(expectedHours), accuracy: 0.01)
            if hideWithClockMode { XCTAssertFalse(chart.state.bgReadingDates.contains(deletedDate)) }
            await harness.renderPendingChanges()
        }
    }


    @MainActor
    func testHostedIconRequestBeforeHomeMountPresentsTheRealCalculator() async throws {
        let harness = try HostedHomeCalculatorHarness()
        defer { harness.finish() }
        let appeared = expectation(description: "Cold pending request shows the real calculator")
        harness.onConsumption = { _ in appeared.fulfill() }
        let request = try harness.requestFromIcon()
        XCTAssertNil(harness.host)
        XCTAssertEqual(harness.root.penCalculatorQuickActionRequest, request)

        await harness.mount(in: self)
        await fulfillment(of: [appeared], timeout: 2)
        XCTAssertNotNil(harness.host?.presentedViewController)
        XCTAssertEqual(harness.consumedRequests, [request])
        XCTAssertNil(harness.root.penCalculatorQuickActionRequest)
    }

    @MainActor
    func testHostedCalculatorDismissalDoesNotReopenOrCreateTreatment() async throws {
        let harness = try HostedHomeCalculatorHarness()
        defer { harness.finish() }
        await harness.mount(in: self)
        let appeared = expectation(description: "Calculator appears before dismissal")
        harness.onConsumption = { _ in appeared.fulfill() }
        let request = try harness.requestFromIcon()
        await fulfillment(of: [appeared], timeout: 2)
        let sheet = try XCTUnwrap(harness.host?.presentedViewController)
        XCTAssertNil(harness.root.penCalculatorQuickActionRequest)

        let dismissed = expectation(description: "Actual calculator presentation finishes dismissing")
        sheet.dismiss(animated: false) { dismissed.fulfill() }
        await fulfillment(of: [dismissed], timeout: 2)
        await harness.renderPendingChanges()
        XCTAssertNil(harness.host?.presentedViewController)
        XCTAssertNil(harness.root.penCalculatorQuickActionRequest)
        XCTAssertEqual(harness.consumedRequests, [request])
        XCTAssertTrue(try harness.core.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest()).isEmpty)
        XCTAssertFalse(harness.core.mainManagedObjectContext.hasChanges)

        // A later icon tap must open a new sheet. This also proves dismissal reset
        // Home's presentation binding instead of leaving an invisible requested sheet.
        let reopened = expectation(description: "A separate later icon tap opens a new calculator")
        harness.onConsumption = { _ in reopened.fulfill() }
        let nextRequest = try harness.requestFromIcon()
        XCTAssertNotEqual(nextRequest, request)
        await fulfillment(of: [reopened], timeout: 2)
        XCTAssertNotNil(harness.host?.presentedViewController)
        XCTAssertFalse(harness.host?.presentedViewController === sheet)
        XCTAssertEqual(harness.consumedRequests, [request, nextRequest])
        XCTAssertNil(harness.root.penCalculatorQuickActionRequest)
        XCTAssertTrue(try harness.core.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest()).isEmpty)
        XCTAssertFalse(harness.core.mainManagedObjectContext.hasChanges)
    }

    @MainActor
    func testHostedIconRequestPresentsRealCalculatorAfterHomeIsMounted() async throws {
        let harness = try HostedHomeCalculatorHarness()
        defer { harness.finish() }
        await harness.mount(in: self)
        XCTAssertNil(harness.host?.presentedViewController)

        let appeared = expectation(description: "Home's real calculator sheet appeared")
        harness.onConsumption = { _ in appeared.fulfill() }
        let request = try harness.requestFromIcon()
        XCTAssertEqual(harness.root.penCalculatorQuickActionRequest, request)

        // This must be the mounted Home's SwiftUI change handler, without a second tap,
        // a therapy notification, or the 15-second chart refresh rescuing the request.
        await fulfillment(of: [appeared], timeout: 2)
        XCTAssertNotNil(harness.host?.presentedViewController)
        XCTAssertEqual(harness.consumedRequests, [request])
        XCTAssertNil(harness.root.penCalculatorQuickActionRequest)
    }

    @MainActor
    func testHostedIconRequestPresentsWhenSceneBecomesActive() async throws {
        let harness = try HostedHomeCalculatorHarness(scenePhase: .inactive)
        defer { harness.finish() }
        await harness.mount(in: self)
        let request = try harness.requestFromIcon()
        await harness.renderPendingChanges()
        XCTAssertNil(harness.host?.presentedViewController)
        XCTAssertEqual(harness.root.penCalculatorQuickActionRequest, request)

        let appeared = expectation(description: "Pending calculator appeared after scene activation")
        harness.onConsumption = { _ in appeared.fulfill() }
        // The scene delegate may publish the delivery before SwiftUI's environment has
        // changed. Readiness must use the later active snapshot, not the old closure.
        harness.quickActions.reactivatePendingCalculatorQuickAction()
        await harness.renderPendingChanges()
        XCTAssertNil(harness.host?.presentedViewController)
        harness.inputs.scenePhase = .active

        await fulfillment(of: [appeared], timeout: 2)
        XCTAssertNotNil(harness.host?.presentedViewController)
        XCTAssertEqual(harness.consumedRequests, [request])
        XCTAssertNil(harness.root.penCalculatorQuickActionRequest)
    }

    @MainActor
    func testHostedIconRequestPresentsWhenHomePresentationBecomesAllowed() async throws {
        let harness = try HostedHomeCalculatorHarness(allowsPresentation: false)
        defer { harness.finish() }
        await harness.mount(in: self)
        let request = try harness.requestFromIcon()
        await harness.renderPendingChanges()
        XCTAssertNil(harness.host?.presentedViewController)
        XCTAssertEqual(harness.root.penCalculatorQuickActionRequest, request)

        let appeared = expectation(description: "Pending calculator appeared after presentation gate opened")
        harness.onConsumption = { _ in appeared.fulfill() }
        harness.inputs.allowsPresentation = true

        await fulfillment(of: [appeared], timeout: 2)
        XCTAssertNotNil(harness.host?.presentedViewController)
        XCTAssertEqual(harness.consumedRequests, [request])
        XCTAssertNil(harness.root.penCalculatorQuickActionRequest)
    }

    @MainActor
    func testHostedRepeatedIconRequestsReuseTheActualVisibleCalculator() async throws {
        let harness = try HostedHomeCalculatorHarness()
        defer { harness.finish() }
        await harness.mount(in: self)
        let appeared = expectation(description: "Repeated icon taps show one calculator")
        harness.onConsumption = { _ in appeared.fulfill() }
        let firstRequest = try harness.requestFromIcon()
        XCTAssertEqual(try harness.requestFromIcon(), firstRequest)
        XCTAssertEqual(try harness.requestFromIcon(), firstRequest)
        await fulfillment(of: [appeared], timeout: 2)
        let sheet = try XCTUnwrap(harness.host?.presentedViewController)
        XCTAssertEqual(harness.consumedRequests, [firstRequest])
        XCTAssertNil(harness.root.penCalculatorQuickActionRequest)

        let reused = expectation(description: "New icon request consumes against the already visible sheet")
        harness.onConsumption = { _ in reused.fulfill() }
        let nextRequest = try harness.requestFromIcon()
        XCTAssertNotEqual(nextRequest, firstRequest)
        await fulfillment(of: [reused], timeout: 2)
        XCTAssertTrue(harness.host?.presentedViewController === sheet)
        XCTAssertNil(sheet.presentedViewController, "The icon must not stack a second sheet")
        XCTAssertEqual(harness.consumedRequests, [firstRequest, nextRequest])
        XCTAssertNil(harness.root.penCalculatorQuickActionRequest)
    }

    @MainActor func testIconCalculatorActionIsFirstAndSpeakingActionStillSwitches() {
        XCTAssertEqual(QuickActionsManager.availableActions(calculatorVisible: true,
            speakReadings: false), [.penCalculator, .speakReadings])
        XCTAssertEqual(QuickActionsManager.availableActions(calculatorVisible: true,
            speakReadings: true), [.penCalculator, .stopSpeakingReadings])
        XCTAssertEqual(QuickActionsManager.availableActions(calculatorVisible: false,
            speakReadings: false), [.speakReadings])
        XCTAssertNotNil(QuickActionType.penCalculator.shortcutItem.icon)
    }

    @MainActor func testIconCalculatorRequestSurvivesStartupAndCoalescesRepeatedTaps() {
        let root = RootTabStateModel()
        XCTAssertNil(root.dependencies)
        root.requestPenCalculatorQuickAction()
        let first = root.penCalculatorQuickActionRequest
        XCTAssertNotNil(first)
        root.requestPenCalculatorQuickAction()
        XCTAssertEqual(root.penCalculatorQuickActionRequest, first)
        root.consumePenCalculatorQuickAction(UUID())
        XCTAssertEqual(root.penCalculatorQuickActionRequest, first)
        root.consumePenCalculatorQuickAction(first!)
        XCTAssertNil(root.penCalculatorQuickActionRequest)
    }

    @MainActor func testRepeatedIconTapPublishesDeliveryEvenWithSamePendingRequest() throws {
        let root = RootTabStateModel()
        var observedRevisions: [Int] = []
        let observation = root.$penCalculatorQuickActionDeliveryRevision
            .sink { observedRevisions.append($0) }
        defer { observation.cancel() }

        root.requestPenCalculatorQuickAction()
        let first = try XCTUnwrap(root.penCalculatorQuickActionRequest)
        root.requestPenCalculatorQuickAction()
        root.requestPenCalculatorQuickAction()

        XCTAssertEqual(root.penCalculatorQuickActionRequest, first,
            "Repeated icon taps must not stack distinct calculator sheets")
        XCTAssertEqual(observedRevisions, [0, 1, 2, 3],
            "A second tap must wake navigation even while the pending UUID is unchanged")

        root.consumePenCalculatorQuickAction(UUID())
        XCTAssertEqual(root.penCalculatorQuickActionRequest, first)
        root.consumePenCalculatorQuickAction(first)
        XCTAssertNil(root.penCalculatorQuickActionRequest)
        root.reactivatePenCalculatorQuickAction()
        XCTAssertEqual(observedRevisions, [0, 1, 2, 3],
            "There is nothing to reactivate after the visible sheet consumes the request")
    }

    @MainActor func testSceneReactivationRetriesPendingIconRequestWithoutReplacingIt() throws {
        let root = RootTabStateModel()
        let manager = QuickActionsManager()
        manager.attachRoot(root)
        root.requestPenCalculatorQuickAction()
        let request = try XCTUnwrap(root.penCalculatorQuickActionRequest)
        let firstRevision = root.penCalculatorQuickActionDeliveryRevision

        manager.reactivatePendingCalculatorQuickAction()

        XCTAssertEqual(root.penCalculatorQuickActionRequest, request)
        XCTAssertGreaterThan(root.penCalculatorQuickActionDeliveryRevision, firstRevision,
            "Scene activation must retry a request whose sheet has not appeared")
    }

    @MainActor func testIconActionHandlerRoutesRepeatedTapsToOneExistingCalculatorSheet() throws {
        let defaults = UserDefaults.standard
        let keys = [UserDefaults.Key.isMaster.rawValue,
                    UserDefaults.Key.therapyDataSourceType.rawValue,
                    UserDefaults.Key.nightscoutEnabled.rawValue,
                    TreatmentSourceCutover.defaultsKey,
                    TreatmentSourceCutover.restoreRequiresSourceSetupKey]
        let original = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in original {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            QuickActionsManager.shared.updateAvailableQuickActions()
        }
        defaults.isMaster = true
        defaults.therapyDataSourceType = .none
        defaults.nightscoutEnabled = false
        defaults.set(false, forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey)
        let boundary = TreatmentSourceCutover(cutoff: Date(),
            insulinSourceBundleID: "insulin.source", carbohydrateSourceBundleID: "carb.source")
        defaults.set(try JSONEncoder().encode(boundary), forKey: TreatmentSourceCutover.defaultsKey)

        let root = RootTabStateModel()
        let manager = QuickActionsManager()
        manager.attachRoot(root)
        XCTAssertNil(root.dependencies)
        XCTAssertTrue(manager.handleQuickAction(.penCalculator))
        let request = try XCTUnwrap(root.penCalculatorQuickActionRequest)
        XCTAssertTrue(manager.handleQuickAction(.penCalculator))
        XCTAssertEqual(root.penCalculatorQuickActionRequest, request)

        var presentations = 0
        RootHomeCalculatorQuickActionPresentation.open(request: root.penCalculatorQuickActionRequest,
            isReady: RootHomeCalculatorQuickActionPresentation.isReady(
                policy: defaults.dataFlowPolicy, cutover: TreatmentSourceCutover.current(),
                sceneIsActive: true, allowsPresentation: true,
                showsExpandedChart: false, usesNightLayout: false),
            isAlreadyPresented: false, isVisible: false, present: { presentations += 1 },
            consume: { root.consumePenCalculatorQuickAction($0) })
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(root.penCalculatorQuickActionRequest, request)
        RootHomeCalculatorQuickActionPresentation.open(request: root.penCalculatorQuickActionRequest,
            isReady: true, isAlreadyPresented: true, isVisible: true,
            present: { presentations += 1 },
            consume: { root.consumePenCalculatorQuickAction($0) })
        XCTAssertEqual(presentations, 1)
        XCTAssertNil(root.penCalculatorQuickActionRequest)
        XCTAssertNil(root.dependencies, "Opening the shortcut must not start treatment services")
    }

    @MainActor func testIconCalculatorWarmStartPresentsSynchronouslyThenConsumesWhenVisible() throws {
        let root = RootTabStateModel()
        root.requestPenCalculatorQuickAction()
        let request = try XCTUnwrap(root.penCalculatorQuickActionRequest)
        var presentations = 0

        RootHomeCalculatorQuickActionPresentation.open(
            request: root.penCalculatorQuickActionRequest, isReady: true,
            isAlreadyPresented: false, isVisible: false,
            present: { presentations += 1 },
            consume: { root.consumePenCalculatorQuickAction($0) })

        // Request the sheet immediately, but retain the action until SwiftUI shows it.
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(root.penCalculatorQuickActionRequest, request)

        RootHomeCalculatorQuickActionPresentation.open(
            request: root.penCalculatorQuickActionRequest, isReady: true,
            isAlreadyPresented: true, isVisible: true,
            present: { presentations += 1 },
            consume: { root.consumePenCalculatorQuickAction($0) })
        XCTAssertEqual(presentations, 1)
        XCTAssertNil(root.penCalculatorQuickActionRequest)
    }

    @MainActor func testIconCalculatorColdStartKeepsRequestUntilHomeBecomesReady() throws {
        let root = RootTabStateModel()
        root.requestPenCalculatorQuickAction()
        let request = try XCTUnwrap(root.penCalculatorQuickActionRequest)
        var presentations = 0

        RootHomeCalculatorQuickActionPresentation.open(
            request: root.penCalculatorQuickActionRequest, isReady: false,
            isAlreadyPresented: false, isVisible: false,
            present: { presentations += 1 },
            consume: { root.consumePenCalculatorQuickAction($0) })
        XCTAssertEqual(root.penCalculatorQuickActionRequest, request)
        XCTAssertEqual(presentations, 0)

        RootHomeCalculatorQuickActionPresentation.open(
            request: root.penCalculatorQuickActionRequest, isReady: true,
            isAlreadyPresented: false, isVisible: false,
            present: { presentations += 1 },
            consume: { root.consumePenCalculatorQuickAction($0) })
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(root.penCalculatorQuickActionRequest, request)

        RootHomeCalculatorQuickActionPresentation.open(
            request: root.penCalculatorQuickActionRequest, isReady: true,
            isAlreadyPresented: true, isVisible: true,
            present: { presentations += 1 },
            consume: { root.consumePenCalculatorQuickAction($0) })
        XCTAssertEqual(presentations, 1)
        XCTAssertNil(root.penCalculatorQuickActionRequest)
    }

    @MainActor func testIconCalculatorRepeatedTapsPresentOneSheet() throws {
        let root = RootTabStateModel()
        root.requestPenCalculatorQuickAction()
        let request = try XCTUnwrap(root.penCalculatorQuickActionRequest)
        root.requestPenCalculatorQuickAction()
        XCTAssertEqual(root.penCalculatorQuickActionRequest, request)
        var presentations = 0

        RootHomeCalculatorQuickActionPresentation.open(
            request: root.penCalculatorQuickActionRequest, isReady: true,
            isAlreadyPresented: false, isVisible: false,
            present: { presentations += 1 },
            consume: { root.consumePenCalculatorQuickAction($0) })
        root.requestPenCalculatorQuickAction()
        XCTAssertEqual(root.penCalculatorQuickActionRequest, request)
        RootHomeCalculatorQuickActionPresentation.open(
            request: root.penCalculatorQuickActionRequest, isReady: true,
            isAlreadyPresented: true, isVisible: false,
            present: { presentations += 1 },
            consume: { root.consumePenCalculatorQuickAction($0) })
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(root.penCalculatorQuickActionRequest, request)

        RootHomeCalculatorQuickActionPresentation.open(
            request: root.penCalculatorQuickActionRequest, isReady: true,
            isAlreadyPresented: true, isVisible: true,
            present: { presentations += 1 },
            consume: { root.consumePenCalculatorQuickAction($0) })
        XCTAssertEqual(presentations, 1)
        XCTAssertNil(root.penCalculatorQuickActionRequest)
    }

    @MainActor func testIconCalculatorRequestedSheetRemainsPendingUntilVisible() {
        let request = UUID()
        var presentations = 0
        var consumed: [UUID] = []

        RootHomeCalculatorQuickActionPresentation.open(
            request: request, isReady: true, isAlreadyPresented: true, isVisible: false,
            present: { presentations += 1 }, consume: { consumed.append($0) })
        XCTAssertEqual(presentations, 0)
        XCTAssertTrue(consumed.isEmpty)

        RootHomeCalculatorQuickActionPresentation.open(
            request: request, isReady: true, isAlreadyPresented: true, isVisible: true,
            present: { presentations += 1 }, consume: { consumed.append($0) })
        XCTAssertEqual(presentations, 0)
        XCTAssertEqual(consumed, [request])
    }

    @MainActor func testIconCalculatorAlreadyOpenConsumesRequestWithoutPresentingAgain() {
        let request = UUID()
        var presentations = 0
        var consumed: [UUID] = []

        RootHomeCalculatorQuickActionPresentation.open(
            request: request, isReady: false, isAlreadyPresented: true, isVisible: true,
            present: { presentations += 1 }, consume: { consumed.append($0) })

        XCTAssertEqual(presentations, 0)
        XCTAssertEqual(consumed, [request])
    }

    @MainActor func testIconCalculatorDuringSheetDismissalWaitsForActualDismissal() {
        let request = UUID()
        var presentations = 0
        var consumed: [UUID] = []

        RootHomeCalculatorQuickActionPresentation.open(
            request: request, isReady: true, isAlreadyPresented: false, isVisible: true,
            present: { presentations += 1 }, consume: { consumed.append($0) })
        XCTAssertEqual(presentations, 0)
        XCTAssertTrue(consumed.isEmpty)

        RootHomeCalculatorQuickActionPresentation.open(
            request: request, isReady: true, isAlreadyPresented: false, isVisible: false,
            present: { presentations += 1 }, consume: { consumed.append($0) })
        XCTAssertEqual(presentations, 1)
        XCTAssertTrue(consumed.isEmpty)
    }

    @MainActor func testIconCalculatorWithoutRequestDoesNotPresent() {
        var presentations = 0
        var consumptions = 0

        RootHomeCalculatorQuickActionPresentation.open(
            request: nil, isReady: true, isAlreadyPresented: false, isVisible: false,
            present: { presentations += 1 }, consume: { _ in consumptions += 1 })

        XCTAssertEqual(presentations, 0)
        XCTAssertEqual(consumptions, 0)
    }

    @MainActor func testIconActionDefaultsNotificationDoesNotWaitForMainThread() {
        _ = QuickActionsManager.shared
        let posted = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification,
                object: UserDefaults.standard)
            posted.signal()
        }
        // Main may synchronously wait on a worker for forecast evidence. A main-queue
        // NotificationCenter observer would make that worker wait back on main.
        XCTAssertEqual(posted.wait(timeout: .now() + 1), .success)
    }

    func testForecastPreferenceDefaultsTo60AndSupportsOffAnd120() throws {
        let suite = "ForecastPresentationTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(defaults.glucoseForecastHorizonMinutes, 60)
        defaults.glucoseForecastHorizonMinutes = 0
        XCTAssertEqual(try XCTUnwrap(UserDefaults(suiteName: suite)).glucoseForecastHorizonMinutes, 0)
        defaults.glucoseForecastHorizonMinutes = 120
        XCTAssertEqual(try XCTUnwrap(UserDefaults(suiteName: suite)).glucoseForecastHorizonMinutes, 120)
        defaults.glucoseForecastHorizonMinutes = 75
        XCTAssertEqual(defaults.glucoseForecastHorizonMinutes, 60)
    }

    func testForecastManualSensitivityConvertsUnitsAndNeverTreatsZeroAsMissing() throws {
        let suite = "ForecastSettingsTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(defaults.glucoseForecastManualSensitivityMgdlPerUnit)
        XCTAssertNil(GlucoseForecastSettingsInput.positiveNumber(""))
        XCTAssertNil(GlucoseForecastSettingsInput.positiveNumber("0"))
        XCTAssertNotNil(GlucoseForecastSettingsInput.validationMessage("0"))
        XCTAssertEqual(GlucoseForecastSettingsInput.sensitivityMgdl("50", isMgDl: true), 50)
        let converted = try XCTUnwrap(GlucoseForecastSettingsInput.sensitivityMgdl("2,8", isMgDl: false))
        XCTAssertEqual(converted, 2.8.mmolToMgdl(), accuracy: 0.001)
        defaults.glucoseForecastManualSensitivityMgdlPerUnit = converted
        XCTAssertEqual(try XCTUnwrap(defaults.glucoseForecastManualSensitivityMgdlPerUnit), converted)
        defaults.glucoseForecastManualSensitivityMgdlPerUnit = 0
        XCTAssertNil(defaults.glucoseForecastManualSensitivityMgdlPerUnit)
        defaults.glucoseForecastManualCarbRatioGramsPerUnit = 10
        XCTAssertEqual(defaults.glucoseForecastManualCarbRatioGramsPerUnit, 10)
        defaults.glucoseForecastManualCarbRatioGramsPerUnit = nil
        XCTAssertNil(defaults.glucoseForecastManualCarbRatioGramsPerUnit)
    }

    func testForecastFutureDomainIsPresentationOnlyAndHiddenInHistoricalWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let measured = GlucoseChartState.empty(startDate: now.addingTimeInterval(-3 * 3600), endDate: now)
        let sixtyMinutePoints = stride(from: 0, through: 60, by: 5).map {
            GlucoseChartForecastPoint(date: now.addingTimeInterval(Double($0) * 60), glucoseMgdl: 110)
        }
        let live = GlucoseChartForecastPresentation.visiblePoints(
            sixtyMinutePoints, referenceDate: now,
            visibleStartDate: measured.startDate, visibleEndDate: measured.endDate,
            isMainChart: true
        )
        XCTAssertEqual(live.count, 13)
        XCTAssertEqual(GlucoseChartForecastPresentation.endDate(visibleEndDate: now, horizonMinutes: 60,
                                                               isMainChart: true), now.addingTimeInterval(60 * 60))
        XCTAssertEqual(GlucoseChartForecastPresentation.endDate(visibleEndDate: now, horizonMinutes: 0,
                                                               isMainChart: true), now)
        XCTAssertTrue(GlucoseChartForecastPresentation.visiblePoints(
            sixtyMinutePoints, referenceDate: now,
            visibleStartDate: now.addingTimeInterval(-4 * 3600),
            visibleEndDate: now.addingTimeInterval(-2 * 3600), isMainChart: true
        ).isEmpty)
        XCTAssertTrue(GlucoseChartForecastPresentation.visiblePoints(
            sixtyMinutePoints, referenceDate: now,
            visibleStartDate: measured.startDate, visibleEndDate: measured.endDate,
            isMainChart: false
        ).isEmpty)
        XCTAssertTrue(measured.bgReadingValues.isEmpty)
        XCTAssertTrue(measured.bgReadingDates.isEmpty)
    }

    func testMLPresentationSelectsCentralLineAndPreservesEngineFallback() throws {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let future = reference.addingTimeInterval(30 * 60)
        let enginePoints = [GlucoseForecastPoint(date: reference, glucoseMgdl: 110),
                            GlucoseForecastPoint(date: future, glucoseMgdl: 120)]
        let mlPoints = [GlucoseForecastPoint(date: reference, glucoseMgdl: 110),
                        GlucoseForecastPoint(date: future, glucoseMgdl: 135)]
        let rawBand = [GlucoseForecastMLBandPoint(date: future, lowerMgdl: -15, upperMgdl: 710)]
        let ml = GlucoseForecastMLForecast(points: mlPoints, band: rawBand, modelID: "test-model")
        let result = GlucoseForecastResult(points: enginePoints, referenceDate: reference,
                                           reason: nil, mlForecast: ml)
        XCTAssertTrue(GlucoseForecastMLPresentation.isML(result))
        XCTAssertEqual(GlucoseForecastMLPresentation.points(in: result), mlPoints)
        XCTAssertEqual(GlucoseForecastMLPresentation.band(in: result), rawBand)
        XCTAssertEqual(GlucoseForecastMLPresentation.value(atMinutes: 30, in: result), 135)
        XCTAssertEqual(result.points, enginePoints)
        XCTAssertEqual(result.value(atMinutes: 30), 120)
        XCTAssertEqual(try XCTUnwrap(result.mlForecast).band, rawBand)

        let fallback = GlucoseForecastResult(points: enginePoints, referenceDate: reference,
                                             reason: nil)
        XCTAssertFalse(GlucoseForecastMLPresentation.isML(fallback))
        XCTAssertEqual(GlucoseForecastMLPresentation.points(in: fallback), enginePoints)
        XCTAssertTrue(GlucoseForecastMLPresentation.band(in: fallback).isEmpty)
        XCTAssertEqual(GlucoseForecastMLPresentation.value(atMinutes: 30, in: fallback), 120)

        let unavailable = GlucoseForecastResult(points: enginePoints, referenceDate: reference,
                                                reason: .dataUnavailable, mlForecast: ml)
        XCTAssertFalse(GlucoseForecastMLPresentation.isML(unavailable))
        XCTAssertTrue(GlucoseForecastMLPresentation.points(in: unavailable).isEmpty)
        XCTAssertTrue(GlucoseForecastMLPresentation.band(in: unavailable).isEmpty)
    }

    func testMLBandIsVisibleOnlyInLiveMainChartAndClippedWithoutChangingRawBounds() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let point = GlucoseChartForecastBandPoint(date: reference.addingTimeInterval(30 * 60),
                                                   lowerMgdl: -15, upperMgdl: 710)
        let invalid = GlucoseChartForecastBandPoint(date: reference.addingTimeInterval(60 * 60),
                                                     lowerMgdl: 200, upperMgdl: 100)
        let start = reference.addingTimeInterval(-3 * 3600)
        let visible = GlucoseChartForecastPresentation.visibleBandPoints([point, invalid],
            referenceDate: reference, visibleStartDate: start, visibleEndDate: reference,
            isMainChart: true)
        XCTAssertEqual(visible, [point])
        XCTAssertEqual(GlucoseChartForecastPresentation.clippedBand(point, to: -20...700), 20...600)
        XCTAssertEqual(GlucoseChartForecastPresentation.clippedBand(point, to: 70...240), 70...240)
        XCTAssertEqual(point.lowerMgdl, -15)
        XCTAssertEqual(point.upperMgdl, 710)
        XCTAssertNil(GlucoseChartForecastPresentation.clippedBand(invalid, to: 70...240))
        XCTAssertTrue(GlucoseChartForecastPresentation.visibleBandPoints([point],
            referenceDate: reference, visibleStartDate: start, visibleEndDate: reference,
            isMainChart: false).isEmpty)
        XCTAssertTrue(GlucoseChartForecastPresentation.visibleBandPoints([point],
            referenceDate: reference, visibleStartDate: reference.addingTimeInterval(-4 * 3600),
            visibleEndDate: reference.addingTimeInterval(-2 * 3600), isMainChart: true).isEmpty)
    }

    func testForecastTimeDomainRemainsStableAcrossLoadingAndUnavailableResults() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reference = now.addingTimeInterval(-30)
        let start = now.addingTimeInterval(-3 * 3600)
        for horizon in [60, 120] {
            var context = forecastContext()
            context.horizonMinutes = horizon
            let valid = GlucoseForecastResult(
                points: stride(from: 0, through: horizon, by: 5).map {
                    GlucoseForecastPoint(date: reference.addingTimeInterval(Double($0) * 60), glucoseMgdl: 110)
                },
                referenceDate: reference, reason: nil, parameterSource: .manual,
                referenceSensorID: "sensor-a"
            )
            let unavailable = GlucoseForecastResult(points: [], referenceDate: reference, reason: .dataUnavailable)
            let results: [GlucoseForecastResult?] = [nil, valid, unavailable, valid]
            var chart = GlucoseChartState.empty(startDate: start, endDate: now)
            chart.newestBgReadingDate = reference
            chart.newestBgReadingSensorID = "sensor-a"
            chart.newestBgReadingIsValidForDownstream = true
            let expectedDomain = start ... now.addingTimeInterval(Double(horizon) * 60)
            var pointCounts: [Int] = []
            for result in results {
                let completed = result.map { RootHomeCompletedForecast(result: $0, context: context) }
                let displayable = RootHomeForecastFreshness.displayableResult(completed, context: context,
                    chartState: chart, at: now)
                let points = displayable?.reason == nil ? displayable?.points.map {
                    GlucoseChartForecastPoint(date: $0.date, glucoseMgdl: $0.glucoseMgdl)
                } ?? [] : []
                let visible = GlucoseChartForecastPresentation.visiblePoints(points,
                    referenceDate: displayable?.reason == nil ? displayable?.referenceDate : nil,
                    visibleStartDate: start, visibleEndDate: now, isMainChart: true)
                pointCounts.append(visible.count)
                let domain = start ... GlucoseChartForecastPresentation.endDate(visibleEndDate: now,
                    horizonMinutes: context.horizonMinutes, isMainChart: true)
                XCTAssertEqual(domain, expectedDomain)
            }
            // Geometry remains steady while safety gates still remove the unavailable estimate.
            XCTAssertEqual(pointCounts, [0, horizon / 5 + 1, 0, horizon / 5 + 1])
            XCTAssertTrue(chart.bgReadingValues.isEmpty)
            XCTAssertTrue(chart.bgReadingDates.isEmpty)
        }
    }

    func testForecastTimeDomainDoesNotReserveSpaceWhenOffHistoricalOrNotMainChart() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let historicalEnd = now.addingTimeInterval(-2 * 3600)
        // Home passes zero for both the disabled preference and a historical chart window.
        XCTAssertEqual(GlucoseChartForecastPresentation.endDate(visibleEndDate: now,
            horizonMinutes: 0, isMainChart: true), now)
        XCTAssertEqual(GlucoseChartForecastPresentation.endDate(visibleEndDate: historicalEnd,
            horizonMinutes: 0, isMainChart: true), historicalEnd)
        for horizon in [60, 120] {
            XCTAssertEqual(GlucoseChartForecastPresentation.endDate(visibleEndDate: now,
                horizonMinutes: horizon, isMainChart: false), now)
        }
    }

    private func refreshForecastFixture(at now: Date) -> (RootHomeForecastContext, GlucoseForecastResult,
                                                         GlucoseChartState) {
        var context = forecastContext()
        context.presentationInputSignature = "unchanged-inputs"
        let referenceDate = now.addingTimeInterval(-30)
        let valid = GlucoseForecastResult(points: [
            GlucoseForecastPoint(date: referenceDate, glucoseMgdl: 165),
            GlucoseForecastPoint(date: referenceDate.addingTimeInterval(3600), glucoseMgdl: 168)
        ], referenceDate: referenceDate, reason: nil, parameterSource: .manual, referenceSensorID: "sensor-a")
        var chart = GlucoseChartState.empty(startDate: now.addingTimeInterval(-10800), endDate: now)
        chart.bgReadingDates = [referenceDate]
        chart.bgReadingValues = [165]
        chart.newestBgReadingDate = referenceDate
        chart.newestBgReadingSensorID = "sensor-a"
        chart.newestBgReadingIsValidForDownstream = true
        return (context, valid, chart)
    }

    func testRoutineForecastRetainsExactDatedPointsOnlyInsideThirtySecondWindow() {
        let now = Date()
        let (context, valid, chart) = refreshForecastFixture(at: now)
        var presentation = RootHomeForecastPresentationState()
        presentation.accept(.init(result: valid), context: context, requestedAt: now)
        XCTAssertNil(presentation.displayableResult(context: context, chartState: chart,
            currentInputsAvailable: false, at: now))
        let routine = HealthTherapyRoutineRefreshState(generation: 1, startedAt: now,
            allEnabledKindsCommitted: false)
        var changed = context
        changed.therapyRevision += 1
        XCTAssertEqual(presentation.displayableResult(context: context, chartState: chart,
            currentInputsAvailable: false, routineRefresh: routine,
            at: now.addingTimeInterval(29))?.points,
            valid.points)
        XCTAssertEqual(presentation.displayableResult(context: changed, chartState: chart,
            currentInputsAvailable: false, routineRefresh: routine,
            at: now.addingTimeInterval(29))?.points, valid.points)
        XCTAssertNil(presentation.displayableResult(context: changed, chartState: chart,
            currentInputsAvailable: false, at: now.addingTimeInterval(30)))
    }

    func testRoutineForecastNeverRetainsColdStartFailuresOrChangedSettings() {
        let now = Date()
        let (context, valid, chart) = refreshForecastFixture(at: now)
        let routine = HealthTherapyRoutineRefreshState(generation: 1, startedAt: now,
            allEnabledKindsCommitted: false)
        var empty = RootHomeForecastPresentationState()
        XCTAssertNil(empty.displayableResult(context: context, chartState: chart,
            currentInputsAvailable: false, routineRefresh: routine, at: now))
        var presentation = RootHomeForecastPresentationState()
        presentation.accept(.init(result: valid), context: context, requestedAt: now)
        var changed = context
        changed.presentationInputSignature = "different-source-or-settings"
        XCTAssertNil(presentation.displayableResult(context: changed, chartState: chart,
            currentInputsAvailable: false, routineRefresh: routine, at: now))
        XCTAssertNil(presentation.displayableResult(context: context, chartState: chart,
            currentInputsAvailable: false, routineRefresh: routine,
            nonHealthTreatmentUnchanged: false, at: now))
        for reason in [GlucoseForecastUnavailableReason.dataUnavailable, .awaitingNextReading,
                       .missingGlucose, .staleGlucose, .ambiguousTreatmentSources, .invalidSettings] {
            var presentation = RootHomeForecastPresentationState()
            presentation.accept(.init(result: .init(points: [], referenceDate: nil, reason: reason)),
                                context: context, requestedAt: now.addingTimeInterval(0.1))
            XCTAssertEqual(presentation.displayableResult(context: context, chartState: chart,
                currentInputsAvailable: false, routineRefresh: routine,
                at: now.addingTimeInterval(0.2))?.reason, reason)
        }
    }

    func testRoutineForecastHidesWhenChartTailOrReferenceChangesDuringHeldRead() {
        let now = Date()
        let (context, valid, chart) = refreshForecastFixture(at: now)
        let routine = HealthTherapyRoutineRefreshState(generation: 1, startedAt: now,
            allEnabledKindsCommitted: false)
        var presentation = RootHomeForecastPresentationState()
        presentation.accept(.init(result: valid), context: context, requestedAt: now)
        var changed = context
        changed.therapyRevision += 1
        for invalidChart in [0, 1, 2, 3, 4] {
            var changedChart = chart
            if invalidChart == 0 { changedChart.newestBgReadingSensorID = "sensor-b" }
            if invalidChart == 1 { changedChart.newestBgReadingDate = chart.newestBgReadingDate?.addingTimeInterval(60) }
            if invalidChart == 2 { changedChart.newestBgReadingIsValidForDownstream = false }
            if invalidChart == 3 { changedChart.bgReadingValues = [166] }
            if invalidChart == 4 { changedChart.newestBgReadingDate = chart.newestBgReadingDate?.addingTimeInterval(-60) }
            XCTAssertNil(presentation.displayableResult(context: changed, chartState: changedChart,
                currentInputsAvailable: false, routineRefresh: routine, at: now))
        }
    }

    func testJointCommitHidesOldForecastUntilDelayedReplacementIsReady() {
        let now = Date()
        let (context, valid, chart) = refreshForecastFixture(at: now)
        var presentation = RootHomeForecastPresentationState()
        presentation.accept(.init(result: valid), context: context, requestedAt: now)
        var changed = context
        changed.therapyRevision += 1
        let completedRead = HealthTherapyRoutineRefreshState(generation: 1, startedAt: now,
            allEnabledKindsCommitted: true)
        XCTAssertNil(presentation.displayableResult(context: changed, chartState: chart,
            currentInputsAvailable: true, routineRefresh: completedRead, at: now))
        let replacement = GlucoseForecastResult(points: valid.points, referenceDate: valid.referenceDate,
            reason: nil, parameterSource: .manual, referenceSensorID: "sensor-a")
        presentation.accept(.init(result: replacement), context: changed, requestedAt: now)
        XCTAssertEqual(presentation.displayableResult(context: changed, chartState: chart,
            currentInputsAvailable: true, routineRefresh: completedRead, at: now)?.points,
            replacement.points)
    }

    func testChangedTherapyCurvesWaitForMatchingForecastPublication() {
        XCTAssertTrue(RootHomeTherapyChartPublication.shouldStage(
            completedRefresh: true, hasPriorSeries: true,
            priorTreatmentRevision: 4, currentTreatmentRevision: 5,
            forecastReadyRevision: 10, currentForecastRevision: 11),
            "a delayed forecast keeps the prior complete curves visible")
        XCTAssertFalse(RootHomeTherapyChartPublication.shouldStage(
            completedRefresh: true, hasPriorSeries: true,
            priorTreatmentRevision: 4, currentTreatmentRevision: 5,
            forecastReadyRevision: 11, currentForecastRevision: 11),
            "only the result for this treatment revision publishes the new curves")
        XCTAssertFalse(RootHomeTherapyChartPublication.shouldStage(
            completedRefresh: true, hasPriorSeries: true,
            priorTreatmentRevision: 4, currentTreatmentRevision: 4,
            forecastReadyRevision: 10, currentForecastRevision: 11),
            "an unchanged reread does not rebuild or stage the chart")
    }

    func testPendingCommitHoldsOnlyUntilCommitFailureOrTimeout() {
        let now = Date()
        let (context, valid, chart) = refreshForecastFixture(at: now)
        var presentation = RootHomeForecastPresentationState()
        presentation.accept(.init(result: valid), context: context, requestedAt: now)
        var changed = context
        changed.therapyRevision += 1
        let pending = HomeTreatmentCommitDisplayState(generation: 3, startedAt: now)
        XCTAssertEqual(presentation.displayableResult(context: changed, chartState: chart,
            currentInputsAvailable: false, pendingCommit: pending, at: now)?.points, valid.points)
        XCTAssertNil(presentation.displayableResult(context: changed, chartState: chart,
            currentInputsAvailable: false, at: now.addingTimeInterval(30)))
    }

    func testForecastPresentationExpiresWithoutAnotherSensorReading() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let result = GlucoseForecastResult(
            points: [GlucoseForecastPoint(date: reference.addingTimeInterval(60 * 60), glucoseMgdl: 120)],
            referenceDate: reference, reason: nil, parameterSource: .manual
        )
        XCTAssertTrue(RootHomeForecastFreshness.isCurrent(referenceDate: reference,
                                                           at: reference.addingTimeInterval(5 * 60)))
        XCTAssertTrue(RootHomeForecastFreshness.isCurrent(referenceDate: reference,
                                                           at: reference.addingTimeInterval(GlucoseForecastEngine.maximumGlucoseAge)))
        XCTAssertFalse(RootHomeForecastFreshness.isCurrent(referenceDate: reference,
                                                            at: reference.addingTimeInterval(GlucoseForecastEngine.maximumGlucoseAge + 1)))
        XCTAssertFalse(RootHomeForecastFreshness.isCurrent(referenceDate: reference,
                                                            at: reference.addingTimeInterval(-1)))
        XCTAssertEqual(RootHomeForecastFreshness.presentationResult(result,
                        at: reference.addingTimeInterval(GlucoseForecastEngine.maximumGlucoseAge + 1)).reason,
                       .staleGlucose)
        XCTAssertTrue(RootHomeForecastFreshness.presentationResult(result,
                      at: reference.addingTimeInterval(GlucoseForecastEngine.maximumGlucoseAge + 1)).points.isEmpty)
        XCTAssertEqual(RootHomeForecastFreshness.presentationResult(result,
                        at: reference.addingTimeInterval(5 * 60)).points.count, 1)
    }

    func testForecastRemainsVisibleDuringCompatibleChartRefreshButNotAfterUnsafeReading() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let context = forecastContext()
        let result = GlucoseForecastResult(
            points: [GlucoseForecastPoint(date: reference.addingTimeInterval(60), glucoseMgdl: 120)],
            referenceDate: reference, reason: nil, parameterSource: .manual,
            referenceSensorID: "sensor-a"
        )
        let completed = RootHomeCompletedForecast(result: result, context: context)
        var chart = GlucoseChartState.empty(startDate: reference.addingTimeInterval(-3600), endDate: reference)
        chart.newestBgReadingDate = reference.addingTimeInterval(60)
        chart.newestBgReadingSensorID = "sensor-a"
        chart.newestBgReadingIsValidForDownstream = true

        XCTAssertEqual(RootHomeForecastFreshness.displayableResult(completed, context: context,
                       chartState: chart, at: reference.addingTimeInterval(65))?.points.count, 1)
        chart.newestBgReadingDate = reference.addingTimeInterval(75)
        XCTAssertEqual(RootHomeForecastFreshness.displayableResult(completed, context: context,
                       chartState: chart, at: reference.addingTimeInterval(75))?.points.count, 1)
        chart.newestBgReadingDate = reference.addingTimeInterval(76)
        XCTAssertNil(RootHomeForecastFreshness.displayableResult(completed, context: context,
                     chartState: chart, at: reference.addingTimeInterval(76)))
        chart.newestBgReadingDate = reference.addingTimeInterval(-60)
        XCTAssertNil(RootHomeForecastFreshness.displayableResult(completed, context: context,
                     chartState: chart, at: reference.addingTimeInterval(1)))

        chart.newestBgReadingDate = reference
        chart.newestBgReadingSensorID = "sensor-b"
        XCTAssertNil(RootHomeForecastFreshness.displayableResult(completed, context: context,
                     chartState: chart, at: reference.addingTimeInterval(30)))
        chart.newestBgReadingSensorID = "sensor-a"
        chart.newestBgReadingIsValidForDownstream = false
        XCTAssertNil(RootHomeForecastFreshness.displayableResult(completed, context: context,
                     chartState: chart, at: reference.addingTimeInterval(30)))

        chart.newestBgReadingIsValidForDownstream = true
        chart.newestBgReadingSensorID = nil
        chart.newestBgReadingDate = reference.addingTimeInterval(1)
        XCTAssertEqual(RootHomeForecastFreshness.displayableResult(completed, context: context,
                       chartState: chart, at: reference.addingTimeInterval(30))?.points.count, 1)
        chart.newestBgReadingDate = reference.addingTimeInterval(2)
        XCTAssertNil(RootHomeForecastFreshness.displayableResult(completed, context: context,
                     chartState: chart, at: reference.addingTimeInterval(30)))

        chart.newestBgReadingDate = reference
        chart.newestBgReadingSensorID = "sensor-a"
        let expired = RootHomeForecastFreshness.displayableResult(completed, context: context,
                      chartState: chart, at: reference.addingTimeInterval(GlucoseForecastEngine.maximumGlucoseAge + 1))
        XCTAssertEqual(expired?.reason, .staleGlucose)
        XCTAssertTrue(expired?.points.isEmpty == true)
    }

    func testForecastContextChangeHidesCompletedEstimateWhileReplacementLoads() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let context = forecastContext()
        let result = GlucoseForecastResult(
            points: [GlucoseForecastPoint(date: reference.addingTimeInterval(60), glucoseMgdl: 120)],
            referenceDate: reference, reason: nil, parameterSource: .manual,
            referenceSensorID: "sensor-a"
        )
        let completed = RootHomeCompletedForecast(result: result, context: context)
        var chart = GlucoseChartState.empty(startDate: reference.addingTimeInterval(-3600), endDate: reference)
        chart.newestBgReadingDate = reference
        chart.newestBgReadingSensorID = "sensor-a"
        chart.newestBgReadingIsValidForDownstream = true
        let now = reference.addingTimeInterval(30)

        XCTAssertNotNil(RootHomeForecastFreshness.displayableResult(completed, context: context,
                        chartState: chart, at: now))
        var changed = context
        changed.therapyRevision += 1
        XCTAssertNil(RootHomeForecastFreshness.displayableResult(completed, context: changed,
                     chartState: chart, at: now))
        changed = context
        changed.manualSensitivityMgdlPerUnit += 1
        XCTAssertNil(RootHomeForecastFreshness.displayableResult(completed, context: changed,
                     chartState: chart, at: now))
        changed = context
        changed.localTherapySourceSignature = "different-source"
        XCTAssertNil(RootHomeForecastFreshness.displayableResult(completed, context: changed,
                     chartState: chart, at: now))
        changed = context
        changed.horizonMinutes = 120
        XCTAssertNil(RootHomeForecastFreshness.displayableResult(completed, context: changed,
                     chartState: chart, at: now))
    }

    func testPlannedMealWhatIfDisappearsAtTreatmentStateChange() {
        let reference = Date(timeIntervalSince1970: 1_800_000_000)
        let context = forecastContext()
        let result = GlucoseForecastResult(
            points: [GlucoseForecastPoint(date: reference, glucoseMgdl: 120)],
            referenceDate: reference, reason: nil, parameterSource: .manual
        )
        let conditional = [GlucoseForecastPoint(date: reference.addingTimeInterval(30 * 60), glucoseMgdl: 145)]
        let completed = RootHomeCompletedForecast(result: result, context: context,
                                                  conditionalPlannedPoints: conditional)
        XCTAssertTrue(RootHomePlannedMealPresentation.mayDisplay(
            completed: completed, currentContext: context,
            currentResult: result, hasPendingTreatmentCommit: false))
        XCTAssertFalse(RootHomePlannedMealPresentation.mayDisplay(
            completed: completed, currentContext: context,
            currentResult: result, hasPendingTreatmentCommit: true),
            "Confirmation/edit/cancellation must hide the old hypothetical curve during commit")
        var changed = context
        changed.therapyRevision += 1
        XCTAssertFalse(RootHomePlannedMealPresentation.mayDisplay(
            completed: completed, currentContext: changed,
            currentResult: result, hasPendingTreatmentCommit: false),
            "The old planned UUID/state is no longer valid after a treatment revision")
        let newerReading = GlucoseForecastResult(
            points: [GlucoseForecastPoint(date: reference.addingTimeInterval(60), glucoseMgdl: 121)],
            referenceDate: reference.addingTimeInterval(60), reason: nil, parameterSource: .manual
        )
        XCTAssertFalse(RootHomePlannedMealPresentation.mayDisplay(
            completed: completed, currentContext: context,
            currentResult: newerReading, hasPendingTreatmentCommit: false))
    }

    @MainActor func testSuppressedNewSensorInvalidatesVisibleForecastProvenance() async {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let now = Date()
        let sensorA = Sensor(startDate: now.addingTimeInterval(-3600),
                             nsManagedObjectContext: core.mainManagedObjectContext)
        let sensorB = Sensor(startDate: now.addingTimeInterval(-1800),
                             nsManagedObjectContext: core.mainManagedObjectContext)
        func add(_ secondsAgo: TimeInterval, sensor: Sensor, suppressed: Bool) {
            let reading = BgReading(timeStamp: now.addingTimeInterval(-secondsAgo), sensor: sensor,
                                    calibration: nil, rawData: 110, deviceName: "Libre 2 Plus",
                                    nsManagedObjectContext: core.mainManagedObjectContext)
            reading.calculatedValue = 110
            reading.isSuppressedByFiveMinuteCadence = suppressed
        }
        add(120, sensor: sensorA, suppressed: false)
        add(60, sensor: sensorA, suppressed: true)
        XCTAssertTrue(core.saveChangesSynchronously())
        let sync = NightscoutSyncManager(coreDataManager: core, messageHandler: nil)
        let chart = GlucoseChartStateManager(coreDataManager: core, nightscoutSyncManager: sync)
        func reload() async -> GlucoseChartState {
            await withCheckedContinuation { continuation in
                chart.updateState(endDate: now.addingTimeInterval(1),
                                  startDate: now.addingTimeInterval(-3600), forceReset: true,
                                  showTreatments: false) { continuation.resume(returning: $0) }
            }
        }
        let sameSensor = await reload()
        XCTAssertEqual(sameSensor.newestBgReadingDate, now.addingTimeInterval(-120))
        XCTAssertTrue(sameSensor.newestBgReadingIsValidForDownstream)

        add(30, sensor: sensorB, suppressed: true)
        XCTAssertTrue(core.saveChangesSynchronously())
        let changedSensor = await reload()
        XCTAssertEqual(changedSensor.newestBgReadingDate, now.addingTimeInterval(-120))
        XCTAssertFalse(changedSensor.newestBgReadingIsValidForDownstream)
    }

    private func forecastContext() -> RootHomeForecastContext {
        RootHomeForecastContext(
            therapyRevision: 1,
            horizonMinutes: 60,
            manualSensitivityMgdlPerUnit: 50,
            manualCarbRatioGramsPerUnit: 10,
            insulinPeak: 75,
            carbDuration: 240,
            therapySource: 0,
            healthTherapySelectionSignature: "local",
            localTherapySourceSignature: "local-therapy",
            adjustmentEnabled: false,
            smoothingEnabled: false
        )
    }

    func testLiveChartDoesNotBecomeHistoricalWhileAppIsSuspended() {
        let openedAt = Date()
        let coordinator = GlucoseChartScrollCoordinator(
            endDate: openedAt, visibleTimeInterval: .hours(3)
        )
        let resumedAt = openedAt.addingTimeInterval(5 * 60)

        XCTAssertTrue(coordinator.isShowingCurrentTimeRange(at: resumedAt))
        XCTAssertTrue(coordinator.refreshCurrentTimeRangeIfNeeded(at: resumedAt))
        XCTAssertEqual(coordinator.endDate, resumedAt)
    }

    func testHistoricalChartWindowRemainsHistoricalUntilReset() {
        let now = Date()
        let selectedDate = now.addingTimeInterval(-5 * 60)
        let coordinator = GlucoseChartScrollCoordinator(
            endDate: selectedDate, visibleTimeInterval: .hours(3)
        )

        XCTAssertFalse(coordinator.isShowingCurrentTimeRange(at: now))
        XCTAssertFalse(coordinator.refreshCurrentTimeRangeIfNeeded(at: now))
        XCTAssertEqual(coordinator.endDate, selectedDate)
        coordinator.resetToNow()
        XCTAssertTrue(coordinator.isShowingCurrentTimeRange)
    }

    func testPenProposalLabelsCGMCOBAsEstimateAndFallbackAsCurve() {
        let estimated = PenCOBEvidence(curveGrams: 12, estimatedGrams: 5,
            usedGrams: 5, fallbackReason: nil)
        let estimateText = PenDoseCOBPresentation.proposalText(estimated)
        XCTAssertTrue(estimateText.contains("CGM-estimat"))
        XCTAssertTrue(estimateText.contains("\(PenDoseDisplayFormatter.carbs(5)) g"))
        XCTAssertFalse(estimateText.contains("\(PenDoseDisplayFormatter.carbs(12)) g"))

        let fallback = PenCOBEvidence(curveGrams: 12, estimatedGrams: nil,
            usedGrams: 12, fallbackReason: .historyGap)
        let fallbackText = PenDoseCOBPresentation.proposalText(fallback)
        XCTAssertTrue(fallbackText.contains("kurve"))
        XCTAssertTrue(fallbackText.contains("hul i glukosehistorikken"))
        XCTAssertFalse(fallbackText.contains("CGM-estimeret"))
    }

    func testHomeCalculatorShortcutRequiresConsistentLocalOwnerAndLocalMetricSources() throws {
        let suite = "HomeCalculatorShortcut-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = DataFlowPolicy(isMaster: true, followerDataSource: .careLink,
            therapyDataSourceSelection: .none, nightscoutEnabled: true,
            masterUploadsGlucoseToNightscout: false,
            followerUploadsGlucoseToNightscout: false, nightscoutFollowType: .none)
        let remote = DataFlowPolicy(isMaster: true, followerDataSource: .careLink,
            therapyDataSourceSelection: .nightscout, nightscoutEnabled: true,
            masterUploadsGlucoseToNightscout: false,
            followerUploadsGlucoseToNightscout: false, nightscoutFollowType: .none)
        let boundary = TreatmentSourceCutover(cutoff: Date(),
            insulinSourceBundleID: "insulin.source", carbohydrateSourceBundleID: "carb.source")
        func visible(_ policy: DataFlowPolicy, _ iob: TherapyMetricSource? = nil,
                     _ cob: TherapyMetricSource? = nil, historical: Bool = false,
                     localInputsComplete: Bool = true,
                     cutover: TreatmentSourceCutover? = boundary) -> Bool {
            RootHomeCalculatorShortcutPolicy.isVisible(policy: policy, cutover: cutover,
                iobSource: iob, cobSource: cob, isHistorical: historical,
                localInputsComplete: localInputsComplete, defaults: defaults)
        }
        XCTAssertTrue(visible(local), "No CGM or metric value must not hide local calculator")
        XCTAssertTrue(visible(local, .local, .local))
        XCTAssertFalse(visible(local, .nightscout, .local), "Unavailable external IOB still blocks")
        XCTAssertFalse(visible(local, .local, .careLink), "Unavailable external COB still blocks")
        XCTAssertFalse(visible(remote, .local, .local))
        XCTAssertFalse(visible(local, .local, .local, historical: true))
        XCTAssertFalse(visible(local, localInputsComplete: false))
        XCTAssertFalse(visible(local, cutover: nil))
        defaults.set(true, forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey)
        XCTAssertFalse(visible(local))
        defaults.removeObject(forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey)
        defaults.set(Data("corrupted".utf8), forKey: TreatmentSourceCutover.defaultsKey)
        XCTAssertFalse(visible(local))
    }

    @MainActor
    func testIconCalculatorOpensWithoutWaitingForHomeMetricVisibility() throws {
        let suite = "IconCalculatorReadiness-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = DataFlowPolicy(isMaster: true, followerDataSource: .careLink,
            therapyDataSourceSelection: .none, nightscoutEnabled: true,
            masterUploadsGlucoseToNightscout: false,
            followerUploadsGlucoseToNightscout: false, nightscoutFollowType: .none)
        let boundary = TreatmentSourceCutover(cutoff: Date(),
            insulinSourceBundleID: "insulin.source", carbohydrateSourceBundleID: "carb.source")

        // A foreground refresh can temporarily hide Home's button while its metric inputs
        // are incomplete. The calculator's own dose snapshot still rejects incomplete data.
        XCTAssertFalse(RootHomeCalculatorShortcutPolicy.isVisible(policy: local,
            cutover: boundary, iobSource: nil, cobSource: nil,
            isHistorical: false, localInputsComplete: false, defaults: defaults))
        let ready = RootHomeCalculatorQuickActionPresentation.isReady(policy: local,
            cutover: boundary, sceneIsActive: true, allowsPresentation: true,
            showsExpandedChart: false, usesNightLayout: false, defaults: defaults)
        XCTAssertTrue(ready)

        let root = RootTabStateModel()
        root.requestPenCalculatorQuickAction()
        root.requestPenCalculatorQuickAction()
        var presentations = 0
        RootHomeCalculatorQuickActionPresentation.open(request: root.penCalculatorQuickActionRequest,
            isReady: ready, isAlreadyPresented: false, isVisible: false,
            present: { presentations += 1 }, consume: { root.consumePenCalculatorQuickAction($0) })
        XCTAssertEqual(presentations, 1)
        XCTAssertNotNil(root.penCalculatorQuickActionRequest)
        RootHomeCalculatorQuickActionPresentation.open(request: root.penCalculatorQuickActionRequest,
            isReady: ready, isAlreadyPresented: true, isVisible: true,
            present: { presentations += 1 }, consume: { root.consumePenCalculatorQuickAction($0) })
        XCTAssertNil(root.penCalculatorQuickActionRequest)

        // A repeated icon tap must leave the existing sheet and its inputs alone.
        root.requestPenCalculatorQuickAction()
        RootHomeCalculatorQuickActionPresentation.open(request: root.penCalculatorQuickActionRequest,
            isReady: ready, isAlreadyPresented: true, isVisible: true,
            present: { presentations += 1 }, consume: { root.consumePenCalculatorQuickAction($0) })
        XCTAssertEqual(presentations, 1)
        XCTAssertNil(root.penCalculatorQuickActionRequest)
    }

    @MainActor
    func testIconCalculatorWaitsOnlyForSourceAndPresentationReadiness() throws {
        let suite = "IconCalculatorGates-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = DataFlowPolicy(isMaster: true, followerDataSource: .careLink,
            therapyDataSourceSelection: .none, nightscoutEnabled: true,
            masterUploadsGlucoseToNightscout: false,
            followerUploadsGlucoseToNightscout: false, nightscoutFollowType: .none)
        let remote = DataFlowPolicy(isMaster: true, followerDataSource: .careLink,
            therapyDataSourceSelection: .nightscout, nightscoutEnabled: true,
            masterUploadsGlucoseToNightscout: false,
            followerUploadsGlucoseToNightscout: false, nightscoutFollowType: .none)
        let boundary = TreatmentSourceCutover(cutoff: Date(),
            insulinSourceBundleID: "insulin.source", carbohydrateSourceBundleID: "carb.source")
        func ready(_ policy: DataFlowPolicy = local, cutover: TreatmentSourceCutover? = boundary,
                   active: Bool = true, allows: Bool = true, expanded: Bool = false,
                   night: Bool = false) -> Bool {
            RootHomeCalculatorQuickActionPresentation.isReady(policy: policy, cutover: cutover,
                sceneIsActive: active, allowsPresentation: allows,
                showsExpandedChart: expanded, usesNightLayout: night, defaults: defaults)
        }
        XCTAssertFalse(ready(remote))
        XCTAssertFalse(ready(cutover: nil))
        XCTAssertFalse(ready(active: false))
        XCTAssertFalse(ready(allows: false))
        XCTAssertFalse(ready(expanded: true))
        XCTAssertFalse(ready(night: true))

        // A cold-start request remains pending until the scene is active and can present.
        let root = RootTabStateModel()
        root.requestPenCalculatorQuickAction()
        let request = try XCTUnwrap(root.penCalculatorQuickActionRequest)
        var presentations = 0
        RootHomeCalculatorQuickActionPresentation.open(request: request,
            isReady: ready(active: false), isAlreadyPresented: false, isVisible: false,
            present: { presentations += 1 }, consume: { root.consumePenCalculatorQuickAction($0) })
        XCTAssertEqual(root.penCalculatorQuickActionRequest, request)
        RootHomeCalculatorQuickActionPresentation.open(request: root.penCalculatorQuickActionRequest,
            isReady: ready(), isAlreadyPresented: false, isVisible: false,
            present: { presentations += 1 }, consume: { root.consumePenCalculatorQuickAction($0) })
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(root.penCalculatorQuickActionRequest, request)
        RootHomeCalculatorQuickActionPresentation.open(request: root.penCalculatorQuickActionRequest,
            isReady: ready(), isAlreadyPresented: true, isVisible: true,
            present: { presentations += 1 }, consume: { root.consumePenCalculatorQuickAction($0) })
        XCTAssertEqual(presentations, 1)
        XCTAssertNil(root.penCalculatorQuickActionRequest)
    }

    @MainActor
    func testHomeCalculatorShortcutReservesFullTouchHeightAtAllTextSizes() {
        var state = RootHomeLoopState()
        state.showsIOB = true
        state.showsCOB = true
        let host = UIHostingController(rootView: RootHomeLoopView(state: state,
            actions: RootHomeActions(), showsCalculatorShortcut: true))
        XCTAssertEqual(host.sizeThatFits(in: CGSize(width: 320, height: 240)).height,
            44, accuracy: 0.5)
        let accessibleHost = UIHostingController(rootView: RootHomeLoopView(
            state: state, actions: RootHomeActions(), showsCalculatorShortcut: true)
            .environment(\.dynamicTypeSize, .accessibility3))
        XCTAssertGreaterThanOrEqual(accessibleHost.sizeThatFits(in:
            CGSize(width: 320, height: 240)).height, 44)
    }

    @MainActor
    func testTherapyStripKeepsCompactHeightWhenHomeHasExtraVerticalSpace() {
        let host = UIHostingController(rootView: RootHomeLoopView(
            state: RootHomeLoopState(), actions: RootHomeActions()
        ))

        let size = host.sizeThatFits(in: CGSize(width: 320, height: 240))

        XCTAssertEqual(size.height, 34, accuracy: 0.5)
    }

    @MainActor
    func testLastCalculatedTherapyCaptionDoesNotResizeChartStrip() {
        var state = RootHomeLoopState()
        let calculatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        state.iob = RootHomeMetricState(title: "IOB", value: "1.2 U",
            lastCalculatedAt: calculatedAt)
        state.cob = RootHomeMetricState(title: "COB", value: "12 g",
            lastCalculatedAt: calculatedAt)
        let host = UIHostingController(rootView: RootHomeLoopView(state: state,
            actions: RootHomeActions()))

        XCTAssertEqual(host.sizeThatFits(in: CGSize(width: 320, height: 240)).height,
            34, accuracy: 0.5)
    }

    func testIPadLayoutClassRespondsToWindowWidth() {
        XCTAssertEqual(IPadLayoutClass.resolve(isPad: false, width: 1_366, usesAccessibilityText: false), .compact)
        XCTAssertEqual(IPadLayoutClass.resolve(isPad: true, width: 500, usesAccessibilityText: false), .compact)
        XCTAssertEqual(IPadLayoutClass.resolve(isPad: true, width: 744, usesAccessibilityText: false), .regular)
        XCTAssertEqual(IPadLayoutClass.resolve(isPad: true, width: 1_024, usesAccessibilityText: false), .wide)
    }

    func testIPadLayoutClassUsesCompactCompositionForAccessibilityText() {
        XCTAssertEqual(IPadLayoutClass.resolve(isPad: true, width: 1_366, usesAccessibilityText: true), .compact)
    }

    func testIPadOrientationPolicyAllowsAllTabsToRotate() {
        XCTAssertEqual(
            RootOrientationPolicy.supportedOrientations(isPad: true, isHome: false, allowsHomeRotation: false),
            .all
        )
        XCTAssertEqual(
            RootOrientationPolicy.supportedOrientations(isPad: false, isHome: false, allowsHomeRotation: true),
            .portrait
        )
    }

    func testChartRangesStepShorterWithoutWrapping() {
        XCTAssertNil(RootHomeChartRange.threeHours.nextShorterRange)
        XCTAssertEqual(RootHomeChartRange.fiveHours.nextShorterRange, .threeHours)
        XCTAssertEqual(RootHomeChartRange.eightHours.nextShorterRange, .fiveHours)
        XCTAssertEqual(RootHomeChartRange.twelveHours.nextShorterRange, .eightHours)
        XCTAssertEqual(RootHomeChartRange.twentyFourHours.nextShorterRange, .twelveHours)
    }

    func testChartRangesStepLongerWithoutWrapping() {
        XCTAssertEqual(RootHomeChartRange.threeHours.nextLongerRange, .fiveHours)
        XCTAssertEqual(RootHomeChartRange.fiveHours.nextLongerRange, .eightHours)
        XCTAssertEqual(RootHomeChartRange.eightHours.nextLongerRange, .twelveHours)
        XCTAssertEqual(RootHomeChartRange.twelveHours.nextLongerRange, .twentyFourHours)
        XCTAssertNil(RootHomeChartRange.twentyFourHours.nextLongerRange)
    }

    func testStatisticsPeriodOptionsUseFullLocalizedLabels() {
        XCTAssertEqual(RootHomeStatisticsPeriod.options, [0, 1, 7, 30, 90])
        XCTAssertEqual(RootHomeStatisticsPeriod.title(for: 0), Texts_Common.today)
        XCTAssertEqual(RootHomeStatisticsPeriod.title(for: 1), "1 \(Texts_Common.day)")
        XCTAssertEqual(RootHomeStatisticsPeriod.title(for: 7), "7 \(Texts_Common.days)")
        XCTAssertEqual(RootHomeStatisticsPeriod.title(for: 30), "30 \(Texts_Common.days)")
        XCTAssertEqual(RootHomeStatisticsPeriod.title(for: 90), "90 \(Texts_Common.days)")
    }

    func testCareLinkSensorIndicatorUsesHomeLifetimeThresholds() {
        let expired = ConstantsHomeView.careLinkSensorIndicator(remainingMinutes: 0)
        let urgent = ConstantsHomeView.careLinkSensorIndicator(
            remainingMinutes: Int(ConstantsHomeView.sensorProgressViewUrgentInMinutes)
        )
        let warning = ConstantsHomeView.careLinkSensorIndicator(
            remainingMinutes: Int(ConstantsHomeView.sensorProgressViewWarningInMinutes)
        )
        let normal = ConstantsHomeView.careLinkSensorIndicator(
            remainingMinutes: Int(ConstantsHomeView.sensorProgressViewWarningInMinutes) + 1
        )

        XCTAssertEqual(expired.systemImage, "sensor.tag.radiowaves.forward.fill")
        XCTAssertEqual(urgent.systemImage, expired.systemImage)
        XCTAssertEqual(warning.systemImage, expired.systemImage)
        XCTAssertEqual(normal.systemImage, expired.systemImage)
        XCTAssertEqual(expired.color, ConstantsAppColors.sensorExpired)
        XCTAssertEqual(urgent.color, ConstantsAppColors.sensorUrgent)
        XCTAssertEqual(warning.color, ConstantsAppColors.sensorWarning)
        XCTAssertEqual(normal.color, .green)
    }

    func testBatteryIndicatorMatchesLoopStatusBuckets() {
        XCTAssertNil(ConstantsHomeView.batteryIndicator(percent: nil))
        XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 10)?.color, ConstantsAppColors.urgent)
        XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 11)?.color, ConstantsAppColors.warning)
        XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 26)?.color, ConstantsAppColors.secondaryText)
        XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 66)?.color, ConstantsAppColors.secondaryText)
        XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 91)?.color, ConstantsAppColors.secondaryText)

        if #available(iOS 17.0, *) {
            XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 10)?.systemImage, "battery.0percent")
            XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 11)?.systemImage, "battery.25percent")
            XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 26)?.systemImage, "battery.50percent")
            XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 66)?.systemImage, "battery.75percent")
            XCTAssertEqual(ConstantsHomeView.batteryIndicator(percent: 91)?.systemImage, "battery.100percent")
        }
    }

    @MainActor
    func testHistoricalCacheCompletionDoesNotChaseNowEvenWithEmptyHistory() async throws {
        let driver = HistoricalCacheDriver()
        let cache = driver.makeCache()
        cache.prepare(around: driver.now.addingTimeInterval(-300), visibleTimeInterval: .hours(3))

        // Exercise the original failure path: the buffered end is capped at "now", and time
        // advances while the real Core Data fetch is outstanding. No new request is made.
        driver.now.addTimeInterval(1)
        try driver.runNextLoad()
        await drainHistoricalCacheCompletions()

        XCTAssertEqual(cache.revision, 1)
        XCTAssertEqual(driver.clockReads, 1)
        XCTAssertEqual(driver.pendingLoads.count, 0, "Completion must not enqueue a newer tail")
        driver.now.addTimeInterval(.hours(24))
        await drainHistoricalCacheCompletions()
        XCTAssertEqual(cache.revision, 1)
        XCTAssertEqual(driver.pendingLoads.count, 0)
    }

    @MainActor
    func testHistoricalCacheCoalescesRequestsAndFinishesBothEdgesWithoutMovingNow() async throws {
        let driver = HistoricalCacheDriver()
        let cache = driver.makeCache()
        let center = driver.now.addingTimeInterval(-300)
        cache.prepare(around: center, visibleTimeInterval: .hours(3))
        // Only the latest pending request matters; it expands both ends of the first load.
        driver.now.addTimeInterval(10)
        cache.prepare(around: center, visibleTimeInterval: .hours(5))
        driver.now.addTimeInterval(10)
        cache.prepare(around: center, visibleTimeInterval: .hours(6))
        XCTAssertEqual(driver.pendingLoads.count, 1)

        for expectedRevision in 1 ... 3 {
            driver.now.addTimeInterval(60)
            try driver.runNextLoad()
            await drainHistoricalCacheCompletions()
            XCTAssertEqual(cache.revision, expectedRevision)
            XCTAssertEqual(driver.pendingLoads.count, expectedRevision < 3 ? 1 : 0)
        }
        XCTAssertEqual(driver.clockReads, 3, "Only external requests may read the clock")
    }

    @MainActor
    func testHistoricalCacheLaterExplicitRequestCanLoadNewStatusAndSiteChange() async throws {
        let driver = HistoricalCacheDriver()
        let initialNow = driver.now
        let center = initialNow.addingTimeInterval(-300)
        let oldSite = center.addingTimeInterval(-.hours(24))
        try driver.storeSiteChange(at: oldSite)
        try await driver.storeStatus(at: center, reservoir: 80)
        let cache = driver.makeCache()
        cache.prepare(around: center, visibleTimeInterval: .hours(3))
        try driver.runNextLoad()
        await drainHistoricalCacheCompletions()
        XCTAssertEqual(cache.selection(at: center).deviceStatus?.pumpReservoir, 80)
        XCTAssertEqual(cache.selection(at: center).siteChangeDate, oldSite)

        driver.now.addTimeInterval(60)
        let newSite = initialNow.addingTimeInterval(30)
        try driver.storeSiteChange(at: newSite)
        try await driver.storeStatus(at: driver.now, reservoir: 79)
        XCTAssertEqual(driver.pendingLoads.count, 0, "Database changes alone do not start a loop")
        cache.prepare(around: center, visibleTimeInterval: .hours(3))
        driver.now.addTimeInterval(10)
        try driver.runNextLoad()
        await drainHistoricalCacheCompletions()

        let selection = cache.selection(at: initialNow.addingTimeInterval(60))
        XCTAssertEqual(selection.deviceStatus?.pumpReservoir, 79)
        XCTAssertEqual(selection.siteChangeDate, newSite)
        XCTAssertEqual(cache.selection(at: center).deviceStatus?.pumpReservoir, 80)
        XCTAssertEqual(cache.revision, 2)
        XCTAssertEqual(driver.pendingLoads.count, 0)
    }

    @MainActor
    func testHistoricalCacheNavigationBackAndForwardPreservesStoredSelections() async throws {
        let driver = HistoricalCacheDriver()
        let earlier = driver.now.addingTimeInterval(-.hours(8))
        let later = driver.now.addingTimeInterval(-.hours(1))
        try await driver.storeStatus(at: earlier, reservoir: 90)
        try await driver.storeStatus(at: later, reservoir: 80)
        let cache = driver.makeCache()

        for (index, point) in [(later, 80.0), (earlier, 90.0), (later, 80.0)].enumerated() {
            cache.prepare(around: point.0, visibleTimeInterval: .hours(3))
            try driver.runNextLoad()
            await drainHistoricalCacheCompletions()
            XCTAssertEqual(cache.selection(at: point.0).deviceStatus?.pumpReservoir, point.1)
            XCTAssertEqual(cache.revision, index + 1)
            XCTAssertEqual(driver.pendingLoads.count, 0)
        }
    }

    @MainActor
    func testHistoricalCacheCoveredHistoricalRangeDoesNotReloadAsClockAdvances() async throws {
        let driver = HistoricalCacheDriver()
        let cache = driver.makeCache()
        let center = driver.now.addingTimeInterval(-.hours(8))
        cache.prepare(around: center, visibleTimeInterval: .hours(3))
        try driver.runNextLoad()
        await drainHistoricalCacheCompletions()

        driver.now.addTimeInterval(.hours(1))
        cache.prepare(around: center, visibleTimeInterval: .hours(3))
        // A smaller, nested request is covered too, including a negative chart interval.
        cache.prepare(around: center, visibleTimeInterval: -.hours(1))
        XCTAssertEqual(cache.revision, 1)
        XCTAssertEqual(driver.pendingLoads.count, 0)
    }

    @MainActor
    func testHistoricalCacheResetRejectsQueuedCompletionWithoutDisturbingNewLoad() async throws {
        let driver = HistoricalCacheDriver()
        let cache = driver.makeCache()
        let oldCenter = driver.now.addingTimeInterval(-.hours(8))
        let newCenter = driver.now.addingTimeInterval(-300)
        try await driver.storeStatus(at: newCenter, reservoir: 70)
        cache.prepare(around: oldCenter, visibleTimeInterval: .hours(3))
        try driver.runNextLoad() // Real fetch finished; its main-queue completion has not run.
        cache.reset()
        cache.prepare(around: newCenter, visibleTimeInterval: .hours(3))
        await drainHistoricalCacheCompletions()

        XCTAssertEqual(cache.revision, 1, "The old completion must not publish")
        XCTAssertEqual(driver.pendingLoads.count, 1)
        cache.prepare(around: newCenter, visibleTimeInterval: .hours(3))
        XCTAssertEqual(driver.pendingLoads.count, 1, "The new load must still be marked in-flight")
        driver.now.addTimeInterval(60)
        try driver.runNextLoad()
        await drainHistoricalCacheCompletions()
        XCTAssertEqual(cache.revision, 2)
        XCTAssertEqual(driver.pendingLoads.count, 0)
        XCTAssertEqual(cache.selection(at: newCenter).deviceStatus?.pumpReservoir, 70)
    }

    @MainActor
    func testHistoricalCacheBackfillResetReloadsSameRangeFromPersistentHistory() async throws {
        let driver = HistoricalCacheDriver()
        let center = driver.now.addingTimeInterval(-.hours(8))
        let cache = driver.makeCache()
        cache.prepare(around: center, visibleTimeInterval: .hours(3))
        try driver.runNextLoad()
        await drainHistoricalCacheCompletions()
        XCTAssertNil(cache.selection(at: center).deviceStatus)

        // Use the same reset/prepare sequence as RootHomeView's historical-data notifications.
        let site = center.addingTimeInterval(-60)
        try driver.storeSiteChange(at: site)
        try await driver.storeStatus(at: center, reservoir: 60)
        cache.reset()
        cache.prepare(around: center, visibleTimeInterval: .hours(3))
        try driver.runNextLoad()
        await drainHistoricalCacheCompletions()
        XCTAssertEqual(cache.selection(at: center).deviceStatus?.pumpReservoir, 60)
        XCTAssertEqual(cache.selection(at: center).siteChangeDate, site)
        XCTAssertEqual(cache.revision, 3)
        XCTAssertEqual(driver.pendingLoads.count, 0)
    }

    @MainActor
    func testHistoricalCacheCleanupInvalidatesOutstandingLoadWithoutStartingAnother() async throws {
        let driver = HistoricalCacheDriver()
        let cache = driver.makeCache()
        cache.prepare(around: driver.now.addingTimeInterval(-300), visibleTimeInterval: .hours(3))
        // The test scheduler deliberately delivers even cancelled work to exercise generation
        // rejection, as with a real OperationQueue job already running when cleanup occurs.
        cache.cleanUpMemory()
        try driver.runNextLoad()
        await drainHistoricalCacheCompletions()
        XCTAssertEqual(cache.revision, 1)
        XCTAssertEqual(driver.pendingLoads.count, 0)
    }

    @MainActor
    private func drainHistoricalCacheCompletions() async {
        // FIFO barrier after the production DispatchQueue.main.async completion, not a sleep.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

/// Drives the actual Home view and its real PenDoseCalculatorScreen sheet through SwiftUI.
/// Only source data, scene environment, and the enclosing navigation gate are controlled.
@MainActor
private final class HostedHomeCalculatorHarness {
    let root = RootTabStateModel()
    let quickActions = QuickActionsManager()
    let inputs: HostedHomeCalculatorInputs
    let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
    let homeState = RootHomeStateModel()
    let sensorHealth: SensorHealthIssueManager
    let nightscout: NightscoutSyncManager
    let miniChartQueue: OperationQueue?
    let miniChart: GlucoseChartStateManager?
    private(set) var consumedRequests: [UUID] = []
    var onConsumption: ((UUID) -> Void)?
    private(set) var host: UIViewController?
    private var window: UIWindow?
    private weak var previousKeyWindow: UIWindow?
    private let savedDefaults: [(String, Any?)]
    private let sensorDefaults: UserDefaults
    private let sensorSuite = "HostedHomeCalculator.\(UUID().uuidString)"

    init(scenePhase: ScenePhase = .active, allowsPresentation: Bool = true,
         controlsMiniChart: Bool = false) throws {
        inputs = HostedHomeCalculatorInputs(scenePhase: scenePhase,
                                            allowsPresentation: allowsPresentation)
        let defaults = UserDefaults.standard
        let keys = [UserDefaults.Key.isMaster.rawValue,
                    UserDefaults.Key.therapyDataSourceType.rawValue,
                    UserDefaults.Key.nightscoutEnabled.rawValue,
                    UserDefaults.Key.glucoseForecastHorizonMinutes.rawValue,
                    UserDefaults.Key.showMiniChart.rawValue,
                    UserDefaults.Key.miniChartHoursToShow.rawValue,
                    TreatmentSourceCutover.defaultsKey,
                    TreatmentSourceCutover.restoreRequiresSourceSetupKey]
        savedDefaults = keys.map { ($0, defaults.object(forKey: $0)) }
        sensorDefaults = UserDefaults(suiteName: sensorSuite)!
        sensorHealth = SensorHealthIssueManager(userDefaults: sensorDefaults)
        nightscout = NightscoutSyncManager(coreDataManager: core, messageHandler: nil,
                                           observesSettings: false)
        if controlsMiniChart {
            let queue = OperationQueue()
            queue.isSuspended = true
            miniChartQueue = queue
            miniChart = GlucoseChartStateManager(coreDataManager: core,
                nightscoutSyncManager: nightscout, operationQueue: queue)
        } else {
            miniChartQueue = nil
            miniChart = nil
        }
        // The real test-host app also observes standard defaults. Disable its remote
        // source before changing ownership, then restore that switch last at teardown.
        defaults.nightscoutEnabled = false
        defaults.isMaster = true
        defaults.therapyDataSourceType = .none
        defaults.set(0, forKey: UserDefaults.Key.glucoseForecastHorizonMinutes.rawValue)
        defaults.set(false, forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey)
        let boundary = TreatmentSourceCutover(cutoff: Date(),
            insulinSourceBundleID: "hosted.test.insulin", carbohydrateSourceBundleID: "hosted.test.carbs")
        defaults.set(try JSONEncoder().encode(boundary), forKey: TreatmentSourceCutover.defaultsKey)
        quickActions.attachRoot(root)
        if controlsMiniChart {
            defaults.miniChartHoursToShow = ConstantsGlucoseChart.miniChartHoursToShow1
            setMiniChartVisibility(false)
        }
    }

    func setMiniChartVisibility(_ visible: Bool, clockMode: Bool = false) {
        UserDefaults.standard.showMiniChart = visible
        homeState.refresh(activeSensor: nil, isScreenLocked: clockMode,
            usesScreenLockNightLayout: clockMode)
    }

    func mount(in test: XCTestCase) async {
        let appeared = XCTestExpectation(description: "Actual Home is mounted in its host window")
        let content = HostedHomeCalculatorContent(harness: self, onAppear: { appeared.fulfill() })
        let controller = UIHostingController(rootView: content)
        host = controller
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
        } else {
            XCTFail("Hosted presentation regression requires the XCTest app's active UIWindowScene")
            return
        }
        window?.rootViewController = controller
        window?.makeKeyAndVisible()
        await test.fulfillment(of: [appeared], timeout: 2)
        await renderPendingChanges()
        XCTAssertEqual(UIApplication.shared.applicationState, .active)
    }

    func renderPendingChanges() async {
        // Yield across a display pass; do not call a presentation helper or post a
        // notification. In particular, drain Home's initial onAppear task before a tap.
        try? await Task.sleep(nanoseconds: 150_000_000)
    }

    func requestFromIcon() throws -> UUID {
        XCTAssertTrue(quickActions.handleQuickAction(.penCalculator))
        return try XCTUnwrap(root.penCalculatorQuickActionRequest)
    }

    func consume(_ request: UUID) {
        consumedRequests.append(request)
        root.consumePenCalculatorQuickAction(request)
        onConsumption?(request)
    }

    func finish() {
        miniChartQueue?.isSuspended = false
        onConsumption = nil
        if let request = root.penCalculatorQuickActionRequest {
            root.consumePenCalculatorQuickAction(request)
        }
        host?.dismiss(animated: false)
        window?.isHidden = true
        window?.rootViewController = nil
        host = nil
        window = nil
        previousKeyWindow?.makeKey()
        let nightscoutKey = UserDefaults.Key.nightscoutEnabled.rawValue
        let restoreOrder = savedDefaults.filter { $0.0 != nightscoutKey }
            + savedDefaults.filter { $0.0 == nightscoutKey }
        for (key, value) in restoreOrder {
            if let value { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        sensorDefaults.removePersistentDomain(forName: sensorSuite)
        QuickActionsManager.shared.updateAvailableQuickActions()
    }
}

@MainActor
private final class HostedHomeCalculatorInputs: ObservableObject {
    @Published var scenePhase: ScenePhase
    @Published var allowsPresentation: Bool

    init(scenePhase: ScenePhase, allowsPresentation: Bool) {
        self.scenePhase = scenePhase
        self.allowsPresentation = allowsPresentation
    }
}

@MainActor
private struct HostedHomeCalculatorContent: View {
    let harness: HostedHomeCalculatorHarness
    @ObservedObject private var root: RootTabStateModel
    @ObservedObject private var inputs: HostedHomeCalculatorInputs
    let onAppear: () -> Void

    init(harness: HostedHomeCalculatorHarness, onAppear: @escaping () -> Void) {
        self.harness = harness
        self.root = harness.root
        self.inputs = harness.inputs
        self.onAppear = onAppear
    }

    var body: some View {
        RootHomeView(stateModel: harness.homeState,
            sensorHealthIssueManager: harness.sensorHealth,
            coreDataManager: harness.core,
            nightscoutSyncManager: harness.nightscout,
            actions: RootHomeActions(),
            penCalculatorQuickActionRequest: root.penCalculatorQuickActionRequest,
            penCalculatorQuickActionDeliveryRevision: root.penCalculatorQuickActionDeliveryRevision,
            allowsCalculatorQuickAction: inputs.allowsPresentation,
            consumeCalculatorQuickAction: harness.consume,
            miniChartStateManager: harness.miniChart)
            .environment(\.scenePhase, inputs.scenePhase)
            .onAppear(perform: onAppear)
    }
}

/// Controls only clock/execution order. Queries, range selection, merging, invalidation and
/// main-queue completion all use RootHomeHistoricalDataCache and the real in-memory Core Data store.
@MainActor
private final class HistoricalCacheDriver {
    let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var clockReads = 0
    var pendingLoads = [() -> Void]()

    func makeCache() -> RootHomeHistoricalDataCache {
        RootHomeHistoricalDataCache(
            coreDataManager: stack,
            now: {
                self.clockReads += 1
                return self.now
            },
            scheduleLoad: { self.pendingLoads.append($0) }
        )
    }

    func runNextLoad() throws {
        XCTAssertEqual(pendingLoads.count, 1, "No parallel cache loads")
        let load = try XCTUnwrap(pendingLoads.first)
        pendingLoads.removeFirst()
        load()
    }

    func storeStatus(at date: Date, reservoir: Double) async throws {
        var status = NightscoutDeviceStatus()
        status.id = "cache-test-\(date.timeIntervalSince1970)"
        status.createdAt = date
        status.updatedDate = date
        status.lastCheckedDate = date
        status.lastLoopDate = date
        status.pumpReservoir = reservoir
        let saved = await NightscoutDeviceStatusAccessor(coreDataManager: stack).upsert(status)
        XCTAssertTrue(saved)
    }

    func storeSiteChange(at date: Date) throws {
        let context = stack.privateManagedObjectContext
        try context.performAndWait {
            _ = TreatmentEntry(
                date: date, value: 0, treatmentType: .SiteChange,
                nightscoutEventType: "Site Change", enteredBy: nil,
                nsManagedObjectContext: context
            )
            try context.save()
        }
    }
}

final class RootHomeStatisticsEasterEggTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }

    private func date(_ month: Int, _ day: Int, hour: Int = 16, minute: Int = 0, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func easterEgg(_ date: Date, days: Int = 0, low: Double = 0, inRange: Double = 100,
                            high: Double = 0, enabled: Bool = true) -> RootHomeStatisticsEasterEgg? {
        RootHomeStatisticsEasterEggPolicy.easterEgg(low: low, inRange: inRange, high: high,
            days: days, now: date, calendar: calendar, enabled: enabled)
    }

    func testRequiresExactInRangeData() {
        let now = date(9, 10)
        XCTAssertEqual(easterEgg(now), .sunglasses)
        XCTAssertNil(easterEgg(now, low: 0.1, inRange: 99.9))
        XCTAssertNil(easterEgg(now, inRange: 99.9, high: 0.1))
        XCTAssertNil(easterEgg(now, inRange: 0))
        XCTAssertNil(easterEgg(now, inRange: .nan))
        XCTAssertNil(easterEgg(now, enabled: false))
    }

    func testTodayThresholdAndMidnight() {
        XCTAssertNil(easterEgg(date(9, 10, hour: 15, minute: 59)))
        XCTAssertEqual(easterEgg(date(9, 10)), .sunglasses)
        XCTAssertEqual(easterEgg(date(9, 10, hour: 23, minute: 59)), .sunglasses)
        XCTAssertNil(easterEgg(date(9, 11, hour: 0)))
        for days in [1, 7, 30, 90] {
            XCTAssertEqual(easterEgg(date(9, 10, hour: 0), days: days), .sunglasses)
        }
    }

    func testSeasonalDatesAndAdjacentDays() {
        for (month, day, expected) in [
            (1, 1, RootHomeStatisticsEasterEgg.newYear),
            (1, 2, .sunglasses),
            (10, 30, .sunglasses), (10, 31, .halloween), (11, 1, .sunglasses),
            (12, 22, .sunglasses), (12, 23, .christmas), (12, 31, .christmas)
        ] {
            XCTAssertEqual(easterEgg(date(month, day)), expected)
            XCTAssertNil(easterEgg(date(month, day, hour: 15)))
            XCTAssertEqual(easterEgg(date(month, day, hour: 0), days: 7), expected)
        }
        XCTAssertEqual(easterEgg(date(1, 1, year: 2027), days: 7), .newYear)
    }

    func testThresholdUsesWallClockAcrossDaylightSavingChanges() {
        for (month, day) in [(3, 29), (10, 25)] {
            XCTAssertNil(easterEgg(date(month, day, hour: 15, minute: 59)))
            XCTAssertEqual(easterEgg(date(month, day)), .sunglasses)
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertNil(RootHomeStatisticsEasterEggPolicy.easterEgg(low: 0, inRange: 100, high: 0,
            days: 0, now: date(9, 10), calendar: utc))
    }

    func testLoadingClearsEasterEggAndTimeRefreshDoesNotRestoreIt() {
        let model = RootHomeStateModel()
        model.updateStatistics(StatisticsManager.Statistics(lowStatisticValue: 0, highStatisticValue: 0,
            inRangeStatisticValue: 100, averageStatisticValue: 100, gmiPercentage: 5,
            cVStatisticValue: 0, lowLimitForTIR: 70, highLimitForTIR: 180, numberOfDaysUsed: 1))
        model.updateStatisticsEasterEgg(days: 0, now: date(9, 10), calendar: calendar)
        XCTAssertEqual(model.state.statistics.easterEgg, .sunglasses)
        model.setStatisticsLoading()
        XCTAssertNil(model.state.statistics.easterEgg)
        model.updateStatisticsEasterEgg(days: 0, now: date(9, 10), calendar: calendar)
        XCTAssertNil(model.state.statistics.easterEgg)
    }

    func testTimeRefreshHandlesForegroundReturnAndSeasonChange() {
        let model = RootHomeStateModel()
        model.updateStatistics(StatisticsManager.Statistics(lowStatisticValue: 0, highStatisticValue: 0,
            inRangeStatisticValue: 100, averageStatisticValue: 100, gmiPercentage: 5,
            cVStatisticValue: 0, lowLimitForTIR: 70, highLimitForTIR: 180, numberOfDaysUsed: 1))
        model.updateStatisticsEasterEgg(days: 0, now: date(9, 10, hour: 15), calendar: calendar)
        XCTAssertNil(model.state.statistics.easterEgg)
        model.updateStatisticsEasterEgg(days: 0, now: date(9, 10), calendar: calendar)
        XCTAssertEqual(model.state.statistics.easterEgg, .sunglasses)
        model.updateStatisticsEasterEgg(days: 0, now: date(9, 11, hour: 0), calendar: calendar)
        XCTAssertNil(model.state.statistics.easterEgg)
        model.updateStatisticsEasterEgg(days: 7, now: date(12, 31), calendar: calendar)
        XCTAssertEqual(model.state.statistics.easterEgg, .christmas)
        model.updateStatisticsEasterEgg(days: 7, now: date(1, 1, hour: 0, year: 2027), calendar: calendar)
        XCTAssertEqual(model.state.statistics.easterEgg, .newYear)
    }

    func testRequestContextRejectsChangedPeriodRangeDayAndTimeZone() {
        func context(days: Int = 0, range: Int = 0, low: Double = 70, high: Double = 180,
                     now: Date, calendar: Calendar) -> RootHomeStatisticsContext {
            RootHomeStatisticsContext(days: days, range: range, lowLimit: low, highLimit: high,
                isMgDl: true, now: now, calendar: calendar)
        }
        let now = date(9, 10)
        let original = context(now: now, calendar: calendar)
        XCTAssertEqual(original, context(now: date(9, 10, hour: 23), calendar: calendar))
        XCTAssertNotEqual(original, context(now: date(9, 11, hour: 0), calendar: calendar))
        XCTAssertNotEqual(original, context(days: 7, now: now, calendar: calendar))
        XCTAssertNotEqual(original, context(range: 1, now: now, calendar: calendar))
        XCTAssertNotEqual(original, context(high: 140, now: now, calendar: calendar))
        XCTAssertNotEqual(original, context(low: 80, now: now, calendar: calendar))
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertNotEqual(original, context(now: now, calendar: utc))
        XCTAssertEqual(context(days: 7, now: now, calendar: calendar),
                       context(days: 7, now: date(9, 11), calendar: calendar))
    }
}


final class RootHomeNumberFormattingTests: XCTestCase {
    func testHomeGlucoseAndDeltaKeepUnitPrecisionAndLocale() {
        let danish = Locale(identifier: "da_DK")
        let english = Locale(identifier: "en_US")
        let glucose = 7.2.mmolToMgdl()
        XCTAssertEqual(RootHomeNumberFormatting.glucose(glucose, isMgDl: false, locale: danish), "7,2")
        XCTAssertEqual(RootHomeNumberFormatting.glucose(glucose, isMgDl: false, locale: english), "7.2")
        XCTAssertEqual(RootHomeNumberFormatting.glucose(130.2, isMgDl: true, locale: danish), "130")
        XCTAssertEqual(RootHomeNumberFormatting.glucoseText("+0.1", isMgDl: false, locale: danish), "+0,1")
        XCTAssertEqual(RootHomeNumberFormatting.glucoseText("+0.0", isMgDl: false, locale: danish), "+0,0")
        XCTAssertEqual(RootHomeNumberFormatting.glucoseText("+2", isMgDl: true, locale: danish), "+2")
        XCTAssertEqual(RootHomeNumberFormatting.number(2.75, maximumFractionDigits: 2, locale: danish), "2,75")
        XCTAssertEqual(RootHomeNumberFormatting.number(2, maximumFractionDigits: 2, locale: english), "2")
    }

    func testHomeFormattingPreservesClinicalAndUnavailableMarkers() {
        for text in ["HIGH", "LOW", "ERR", "???", "?SN", "?RF", "??0", "NaN", "inf"] {
            XCTAssertEqual(RootHomeNumberFormatting.glucoseText(text, isMgDl: false,
                locale: Locale(identifier: "da_DK")), text)
        }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var metric = TherapyMetricState(amount: 0, source: .local, referenceDate: date,
            expiresAt: date.addingTimeInterval(60), visibilityDeadline: date.addingTimeInterval(600))
        XCTAssertEqual(RootHomeNumberFormatting.therapyMetric(metric, isIOB: true, at: date),
            "0 \(Texts_HomeView.insulinUnit)")
        metric.reason = .readFailed
        XCTAssertEqual(RootHomeNumberFormatting.therapyMetric(metric, isIOB: true, at: date),
            "- \(Texts_HomeView.insulinUnit)", "Unknown must remain distinct from a valid zero")
        XCTAssertEqual(metric.formatted(isIOB: true, at: date), "- U",
            "Home formatting must not alter the shared therapy payload representation")
    }

    func testDanishHomeResourcesProvideConsistentAgeStatisticsAndInsulinUnits() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "da", ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        func text(_ key: String, table: String) -> String {
            bundle.localizedString(forKey: key, value: nil, table: table)
        }
        XCTAssertEqual(text("ago", table: "HomeView"), "siden")
        XCTAssertEqual(text("common_minutes", table: "Common"), "min")
        XCTAssertEqual(text("common_dismiss", table: "Common"), "Luk")
        XCTAssertEqual(text("common_statistics_low", table: "Common"), "Lavt")
        XCTAssertEqual(text("common_statistics_high", table: "Common"), "Højt")
        XCTAssertEqual(text("common_statistics_inRange", table: "Common"), "I målområdet")
        XCTAssertEqual(text("common_statistics_average", table: "Common"), "Gennemsnit")
        XCTAssertEqual(text("home_insulinUnit", table: "HomeView"), "E")
    }
}
