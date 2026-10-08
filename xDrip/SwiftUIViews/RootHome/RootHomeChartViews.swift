//
//  RootHomeChartViews.swift
//  xdrip
//
//  Created by Paul Plant on 22/7/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import SwiftUI
import Charts

enum RootHomeTherapyChartPublication {
    static func shouldStage(completedRefresh: Bool, hasPriorSeries: Bool,
                            priorTreatmentRevision: Int, currentTreatmentRevision: Int,
                            forecastReadyRevision: Int?, currentForecastRevision: Int) -> Bool {
        completedRefresh && hasPriorSeries && priorTreatmentRevision != currentTreatmentRevision
            && forecastReadyRevision != currentForecastRevision
    }
}

/// Display strings are frozen when the information sheet opens. A new reading cannot
/// mix newer values into the explanation of the estimate the user selected.
struct RootHomeForecastInformation: Identifiable {
    let id = UUID()
    let kind: String
    let unit: String
    let reference: String
    let source: String
    let values: [String]
    let status: String?
    let isML: Bool
    let hasPlannedMeal: Bool
    let isLongHorizon: Bool
}

/// Only this compact control intercepts taps; the surrounding chart keeps its pan gesture.
struct RootHomeForecastBadge: View {
    let information: RootHomeForecastInformation
    let showInformation: () -> Void

    var body: some View {
        Button(action: showInformation) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(information.kind) · \(information.unit)")
                        .fontWeight(.semibold)
                    if let status = information.status {
                        Text(status).foregroundStyle(ConstantsAppColors.secondaryText)
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { forecastValues }
                            VStack(alignment: .leading, spacing: 2) { forecastValues }
                        }
                        .monospacedDigit()
                    }
                    if information.hasPlannedMeal {
                        Text("🍽 " + GlucoseForecastTexts.text("forecast.plannedConditional",
                            fallback: "If eaten · conditional engine estimate"))
                            .foregroundStyle(.orange)
                    }
                }
                Image(systemName: "info.circle")
                    .font(.body)
                    .accessibilityHidden(true)
            }
            .font(.caption2)
            .multilineTextAlignment(.leading)
            .foregroundStyle(Color.cyan)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: 44, alignment: .leading)
            .background(ConstantsAppColors.homePanelBackground.opacity(0.92),
                in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(GlucoseForecastTexts.text("forecast.detailsAction",
            fallback: "Show forecast information"))
        .accessibilityValue(information.reference)
    }

    private var forecastValues: some View {
        ForEach(information.values, id: \.self) { Text($0).fixedSize() }
    }
}

struct RootHomeForecastInformationView: View {
    let information: RootHomeForecastInformation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(information.kind).font(.headline).foregroundStyle(.cyan)
                        if !information.reference.isEmpty {
                            Text(information.reference).foregroundStyle(.secondary)
                        }
                    }
                    if let status = information.status {
                        Text(status)
                    }
                    if !information.values.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(GlucoseForecastTexts.text("forecast.futureValues",
                                fallback: "Estimated values")).font(.headline)
                            ForEach(information.values, id: \.self) {
                                Text("\($0) \(information.unit)").monospacedDigit()
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(GlucoseForecastTexts.text("forecast.parametersLabel",
                            fallback: "Calculation inputs")).font(.headline)
                        Text(information.source)
                        Text(GlucoseForecastTexts.text("forecast.noNewTreatments",
                            fallback: "The estimate assumes no new meals or treatments."))
                    }
                    if information.isML {
                        Text(GlucoseForecastTexts.text("forecast.pointwise80Explanation",
                            fallback: "The band targets 80% coverage at +30, +60 and +120 min. This applies at each time, not to the whole curve, and does not guarantee protection from low glucose."))
                        Text(GlucoseForecastTexts.text("forecast.pointwise80Target",
                            fallback: "80% target at +30/+60/+120 min; intermediate widths are interpolated"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if information.isLongHorizon {
                        Text("+120 min · " + GlucoseForecastTexts.uncertain)
                            .foregroundStyle(.secondary)
                    }
                    if information.hasPlannedMeal {
                        Text("🍽 " + GlucoseForecastTexts.text("forecast.plannedConditional",
                            fallback: "If eaten · conditional engine estimate"))
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(GlucoseForecastTexts.text("forecast.detailsTitle",
                fallback: "About the forecast"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Texts_Common.dismiss) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Main interactive chart with loading state and the reading shown at the panned end date.
struct RootHomeMainChartView: View {
    @AppStorage(UserDefaults.Key.targetMarkValue.rawValue) private var targetValueInMgDl = 0.0
    @Binding var selectedRange: RootHomeChartRange
    let showsTreatments: Bool
    var allowsTherapyCharts = true
    let chartState: GlucoseChartState
    let forecastResult: GlucoseForecastResult?
    /// Display-only hypothetical meal curve, independent of the real/ML forecast.
    let conditionalPlannedForecastPoints: [GlucoseForecastPoint]?
    let forecastHorizonMinutes: Int
    var forecastIsUpdating = false
    let routineTherapyRefresh: HealthTherapyRoutineRefreshState?
    let pendingTherapyCommit: HomeTreatmentCommitDisplayState?
    let forecastReadyTherapyRevision: Int?
    let therapySourceSignature: String
    let nonHealthTreatmentRevision: Int
    let isLoading: Bool
    let scrollCoordinator: GlucoseChartScrollCoordinator
    let yAxisResetRevision: Int
    let updateChartStateIfNeeded: () -> Void
    let finishChartScroll: (_ forceReset: Bool, _ showsLoading: Bool) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var rangeOverlay = ChartDelayedState(false)
    @State private var hasUpdatedRangeDuringPinch = false
    @AppStorage("showIOBCOB") private var showIOBCOB = UserDefaults.standard.showIOBCOB
    @AppStorage(UserDefaults.Key.renderBasalDownwards.rawValue) private var renderBasalDownwards = true
    @State private var therapySeries = TherapyChartSeries()
    @State private var therapyRevision = 0
    @State private var completeTherapySeries: TherapyChartSeries?
    @State private var completeTherapySourceSignature = ""
    @State private var completeTherapyRangeSignature = ""
    @State private var completeNonHealthTreatmentRevision = 0
    @State private var completeTreatmentRevision = 0
    @State private var heldRefreshGeneration: Int?
    @State private var stagedTherapySeries: TherapyChartSeries?
    @State private var stagedForecastRevision: Int?
    @State private var stagedTreatmentRevision: Int?
    @State private var forecastInformation: RootHomeForecastInformation?
    // Hide curves immediately and cancel pending chart work when Treatments is off.
    private var displayedTherapySeries: TherapyChartSeries {
        guard completeTherapySourceSignature == therapySourceSignature,
              completeTherapyRangeSignature == therapyRangeSignature else {
            return TherapyChartSeries()
        }
        if pendingTherapyCommit != nil, let completeTherapySeries { return completeTherapySeries }
        guard completeNonHealthTreatmentRevision == nonHealthTreatmentRevision else {
            return TherapyChartSeries()
        }
        if routineTherapyRefresh == nil,
           (TherapyMetricsManager.shared.hasUncommittedForecastInputChanges
            || HealthKitTherapyImportManager.shared.localInputIsIncomplete(.insulin)
            || HealthKitTherapyImportManager.shared.localInputIsIncomplete(.carbohydrates)
            || completeTreatmentRevision != TherapyMetricsManager.shared.treatmentChangeRevision) {
            return TherapyChartSeries()
        }
        guard routineTherapyRefresh != nil,
              heldRefreshGeneration == nil || heldRefreshGeneration == routineTherapyRefresh?.generation,
              let completeTherapySeries else { return therapySeries }
        return completeTherapySeries
    }
    private var hasIOB: Bool { showsTreatments && allowsTherapyCharts && showIOBCOB && !displayedTherapySeries.iob.isEmpty }
    private var hasCOB: Bool { showsTreatments && allowsTherapyCharts && showIOBCOB && !displayedTherapySeries.cob.isEmpty }
    private var displayedForecastPoints: [GlucoseForecastPoint] {
        forecastResult.map { GlucoseForecastMLPresentation.points(in: $0) } ?? []
    }
    private var displayedForecastBand: [GlucoseForecastMLBandPoint] {
        forecastResult.map { GlucoseForecastMLPresentation.band(in: $0) } ?? []
    }
    private var isMLForecast: Bool {
        forecastResult.map(GlucoseForecastMLPresentation.isML) ?? false
    }
    // Reuse the glucose cache's buffered coverage, rounded outward so tiny pans do
    // not dispatch another fetch and rebuild for each visible-range change.
    private var therapyStart: Date { Date(timeIntervalSince1970: floor(chartState.dataStartDate.timeIntervalSince1970 / 3600) * 3600) }
    private var therapyEnd: Date { Date(timeIntervalSince1970: ceil(chartState.dataEndDate.timeIntervalSince1970 / 3600) * 3600) }
    private var therapyRangeSignature: String { "\(therapyStart.timeIntervalSince1970)|\(therapyEnd.timeIntervalSince1970)" }
    private var seriesKey: String { scenePhase != .active ? "inactive" : "\(therapyStart)-\(therapyEnd)-\(showIOBCOB)-\(showsTreatments)-\(allowsTherapyCharts)-\(therapyRevision)-\(floor(Date().timeIntervalSince1970 / 60))" }

    private enum Layout {
        static let rangeOverlayTopInset: CGFloat = 8
        static let rangeOverlayHorizontalPadding: CGFloat = 10
        static let rangeOverlayVerticalPadding: CGFloat = 5
        static let rangeOverlayFontSize: CGFloat = 16
        static let rangeOverlayMinimumWidth: CGFloat = 70
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                GlucoseChartView(
                    glucoseChartType: .widgetSystemLarge,
                    bgReadingValues: nil,
                    bgReadingDates: nil,
                    isMgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl,
                    urgentLowLimitInMgDl: UserDefaults.standard.urgentLowMarkValue,
                    lowLimitInMgDl: UserDefaults.standard.lowMarkValue,
                    highLimitInMgDl: UserDefaults.standard.highMarkValue,
                    urgentHighLimitInMgDl: UserDefaults.standard.urgentHighMarkValue,
                    targetValueInMgDl: targetValueInMgDl,
                    liveActivityType: nil,
                    hoursToShowScalingHours: selectedRange.rawValue,
                    glucoseCircleDiameterScalingHours: selectedRange.glucoseCircleDiameterScalingHours,
                    showsTreatments: showsTreatments,
                    overrideChartHeight: geometry.size.height,
                    overrideChartWidth: geometry.size.width,
                    highContrast: nil,
                    chartState: chartState
                )
                .mainChartYAxisContext(
                    resetRevision: yAxisResetRevision, renderBasalDownwards: renderBasalDownwards,
                    isLiveViewport: scrollCoordinator.isShowingCurrentTimeRange
                )
                .therapyPlots(
                    TherapyChartSeries(iob: hasIOB ? displayedTherapySeries.iob : [],
                                       cob: hasCOB ? displayedTherapySeries.cob : []),
                    reservesDomainWhileLoading: showsTreatments && allowsTherapyCharts && showIOBCOB
                )
                .forecastPlot(
                    displayedForecastPoints.map {
                        GlucoseChartForecastPoint(date: $0.date, glucoseMgdl: $0.glucoseMgdl)
                    },
                    bandPoints: displayedForecastBand.map {
                        GlucoseChartForecastBandPoint(date: $0.date, lowerMgdl: $0.lowerMgdl,
                                                      upperMgdl: $0.upperMgdl)
                    },
                    isML: isMLForecast,
                    from: forecastResult?.reason == nil ? forecastResult?.referenceDate : nil,
                    horizonMinutes: forecastHorizonMinutes
                )
                .conditionalPlannedMealPlot(
                    conditionalPlannedForecastPoints?.map {
                        GlucoseChartForecastPoint(date: $0.date, glucoseMgdl: $0.glucoseMgdl)
                    } ?? []
                )
                .transaction { transaction in
                    transaction.animation = nil
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            scrollCoordinator.updateVisibleRange(value: value, chartWidth: geometry.size.width)
                            updateChartStateIfNeeded()
                        }
                        .onEnded { value in
                            scrollCoordinator.finishUpdatingVisibleRange(value: value, chartWidth: geometry.size.width)
                            finishChartScroll(false, false)
                        }
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded {
                    scrollCoordinator.resetToNow()
                    finishChartScroll(true, true)
                })
                .simultaneousGesture(
                    MagnificationGesture()
                        .onChanged(updateRange)
                        .onEnded { _ in
                            hasUpdatedRangeDuringPinch = false
                        }
                )
                .clipped()

                if forecastHorizonMinutes != 0 {
                    forecastBadge
                        .frame(maxWidth: max(0, geometry.size.width - 55), alignment: .leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.leading, 7)
                        .padding(.top, 5)
                }

                if rangeOverlay.value {
                    HStack(spacing: 4) {
                        Text("\(Int(selectedRange.rawValue))")
                            .fontWeight(.semibold)
                            .monospacedDigit()
                        Text(Texts_Common.hours)
                    }
                    .font(.system(size: Layout.rangeOverlayFontSize))
                    .foregroundStyle(ConstantsAppColors.secondaryText)
                    .frame(minWidth: Layout.rangeOverlayMinimumWidth)
                    .padding(.horizontal, Layout.rangeOverlayHorizontalPadding)
                    .padding(.vertical, Layout.rangeOverlayVerticalPadding)
                    .background(
                        ConstantsAppColors.homePanelBackground,
                        in: RoundedRectangle(cornerRadius: ConstantsHomeView.standardCornerRadius, style: .continuous)
                    )
                    .padding(.top, Layout.rangeOverlayTopInset)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                }

                if isLoading {
                    ProgressView()
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .task(id: seriesKey) {
            guard scenePhase == .active else { return }
            guard showsTreatments && allowsTherapyCharts && showIOBCOB else {
                therapySeries = TherapyChartSeries()
                completeTherapySeries = nil
                return
            }
            if let refresh = routineTherapyRefresh, !refresh.allEnabledKindsCommitted,
               completeTherapySeries != nil,
               completeTherapySourceSignature == therapySourceSignature,
               completeTherapyRangeSignature == therapyRangeSignature,
               completeNonHealthTreatmentRevision == nonHealthTreatmentRevision {
                return
            }
            if pendingTherapyCommit != nil, completeTherapySeries != nil,
               completeTherapySourceSignature == therapySourceSignature,
               completeTherapyRangeSignature == therapyRangeSignature { return }
            let result = await TherapyMetricsManager.shared.chartForHome(from: therapyStart, to: therapyEnd)
            guard !Task.isCancelled else { return }
            guard result.inputsComplete else {
                if HealthKitTherapyImportManager.shared.routineRefreshState() == nil {
                    therapySeries = TherapyChartSeries()
                    completeTherapySeries = nil
                }
                return
            }
            guard HealthKitTherapyImportManager.shared.routineRefreshState()?.allEnabledKindsCommitted != false else { return }
            let currentForecastRevision = TherapyMetricsManager.shared.forecastInputChangeRevision
            let currentTreatmentRevision = TherapyMetricsManager.shared.treatmentChangeRevision
            if RootHomeTherapyChartPublication.shouldStage(
                completedRefresh: HealthKitTherapyImportManager.shared.routineRefreshState()?.allEnabledKindsCommitted == true,
                hasPriorSeries: completeTherapySeries != nil,
                priorTreatmentRevision: completeTreatmentRevision,
                currentTreatmentRevision: currentTreatmentRevision,
                forecastReadyRevision: forecastReadyTherapyRevision,
                currentForecastRevision: currentForecastRevision) {
                stagedTherapySeries = result.series
                stagedForecastRevision = currentForecastRevision
                stagedTreatmentRevision = currentTreatmentRevision
                return
            }
            therapySeries = result.series
            completeTherapySeries = result.series
            completeTherapySourceSignature = therapySourceSignature
            completeTherapyRangeSignature = therapyRangeSignature
            completeNonHealthTreatmentRevision = nonHealthTreatmentRevision
            completeTreatmentRevision = TherapyMetricsManager.shared.treatmentChangeRevision
            heldRefreshGeneration = nil
            stagedTherapySeries = nil
            stagedForecastRevision = nil
            stagedTreatmentRevision = nil
        }
        .onChange(of: forecastReadyTherapyRevision) { readyRevision in
            guard let readyRevision,
                  readyRevision == stagedForecastRevision,
                  stagedTreatmentRevision == TherapyMetricsManager.shared.treatmentChangeRevision,
                  let stagedTherapySeries else { return }
            guard HealthKitTherapyImportManager.shared.routineRefreshState() != nil else {
                self.stagedTherapySeries = nil
                stagedForecastRevision = nil
                stagedTreatmentRevision = nil
                therapyRevision &+= 1
                return
            }
            therapySeries = stagedTherapySeries
            completeTherapySeries = stagedTherapySeries
            completeTherapySourceSignature = therapySourceSignature
            completeTherapyRangeSignature = therapyRangeSignature
            completeNonHealthTreatmentRevision = nonHealthTreatmentRevision
            completeTreatmentRevision = TherapyMetricsManager.shared.treatmentChangeRevision
            heldRefreshGeneration = nil
            self.stagedTherapySeries = nil
            stagedForecastRevision = nil
            stagedTreatmentRevision = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: TherapyMetricsManager.changed)) { notification in
            if scenePhase == .active && (notification.userInfo?["statusOnly"] as? Bool != true
                || TherapyMetricsManager.shared.hasUncommittedForecastInputChanges
                    && TherapyMetricsManager.shared.pendingHomeTreatmentCommitState() == nil
                    && HealthKitTherapyImportManager.shared.routineRefreshState() == nil) {
                therapyRevision &+= 1
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: HealthKitTherapyImportManager.statusDidChange)) { _ in
            guard scenePhase == .active else { return }
            if let refresh = HealthKitTherapyImportManager.shared.routineRefreshState() {
                if let heldRefreshGeneration, heldRefreshGeneration != refresh.generation {
                    completeTherapySeries = nil
                } else if heldRefreshGeneration == nil {
                    heldRefreshGeneration = refresh.generation
                }
                if refresh.allEnabledKindsCommitted,
                   completeTreatmentRevision != TherapyMetricsManager.shared.treatmentChangeRevision {
                    therapyRevision &+= 1
                }
            } else if HealthKitTherapyImportManager.shared.localInputIsIncomplete(.insulin)
                        || HealthKitTherapyImportManager.shared.localInputIsIncomplete(.carbohydrates) {
                therapySeries = TherapyChartSeries()
                completeTherapySeries = nil
                heldRefreshGeneration = nil
            }
        }
        .onDisappear {
            rangeOverlay.cancel()
        }
        .sheet(item: $forecastInformation) { information in
            RootHomeForecastInformationView(information: information)
        }
    }

    private var forecastBadge: some View {
        let information = currentForecastInformation
        return RootHomeForecastBadge(information: information) {
            forecastInformation = information
        }
    }

    private var currentForecastInformation: RootHomeForecastInformation {
        let result = forecastResult
        let available = result?.reason == nil && result != nil
        let status: String? = !available
            ? result?.reason.map(GlucoseForecastTexts.unavailable) ?? GlucoseForecastTexts.calculating
            : forecastIsUpdating
                ? GlucoseForecastTexts.text("forecast.updating", fallback: "Updating…") : nil
        let horizons = forecastHorizonMinutes == 120 ? [30, 60, 120] : [30, 60]
        return RootHomeForecastInformation(
            kind: available ? forecastKind : GlucoseForecastTexts.estimate,
            unit: forecastUnit,
            reference: result?.referenceDate.map(GlucoseForecastTexts.basedOnReading) ?? "",
            source: forecastSource(result?.parameterSource),
            values: available && !forecastIsUpdating ? result.map { result in
                horizons.map { "+\($0) \(forecastValue(at: $0, from: result))" }
            } ?? [] : [],
            status: status, isML: isMLForecast,
            hasPlannedMeal: conditionalPlannedForecastPoints?.isEmpty == false,
            isLongHorizon: forecastHorizonMinutes == 120)
    }

    private var forecastKind: String {
        isMLForecast
            ? GlucoseForecastTexts.text("forecast.mlEstimate", fallback: "ML estimate")
            : GlucoseForecastTexts.text("forecast.engineEstimate", fallback: "Engine estimate")
    }

    private var forecastUnit: String {
        UserDefaults.standard.bloodGlucoseUnitIsMgDl ? Texts_Common.mgdl : Texts_Common.mmol
    }

    private func forecastValue(at minutes: Int, from result: GlucoseForecastResult) -> String {
        guard let value = GlucoseForecastMLPresentation.value(atMinutes: minutes, in: result),
              value.isFinite else { return "–" }
        return RootHomeNumberFormatting.glucose(value, isMgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl)
    }

    private func forecastSource(_ source: GlucoseForecastParameterSource?) -> String {
        switch source {
        case .manual:
            return GlucoseForecastTexts.manualSourceShort
        case .nightscoutProfile:
            return GlucoseForecastTexts.profileSourceShort
        case nil:
            return GlucoseForecastTexts.text("forecast.sourceUnknown", fallback: "Source unavailable")
        }
    }

    private func updateRange(magnification: CGFloat) {
        guard !hasUpdatedRangeDuringPinch else { return }

        let threshold = ConstantsHomeView.mainChartZoomMagnificationThreshold
        let newRange: RootHomeChartRange?

        // One pinch changes one range step as soon as it crosses the deliberate threshold.
        if magnification >= 1 + threshold {
            newRange = selectedRange.nextShorterRange
        } else if magnification <= 1 - threshold {
            newRange = selectedRange.nextLongerRange
        } else {
            newRange = nil
        }

        guard let newRange else { return }

        hasUpdatedRangeDuringPinch = true
        selectedRange = newRange
        showRangeOverlay()
    }

    private func showRangeOverlay() {
        rangeOverlay.cancel()

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            rangeOverlay.value = true
        }

        // The owner schedules a value change without retaining this view and its old work item.
        rangeOverlay.schedule(
            false,
            after: ConstantsHomeView.mainChartZoomOverlayVisibleDuration,
            animation: .easeOut(duration: ConstantsHomeView.mainChartZoomOverlayFadeDuration)
        )
    }
}

/// Historical overview chart and the active main-chart window.
struct RootHomeMiniChartView: View {
    @AppStorage(UserDefaults.Key.targetMarkValue.rawValue) private var targetValueInMgDl = 0.0
    let miniChartHoursToShow: Double
    let chartState: GlucoseChartState
    let scrollCoordinator: GlucoseChartScrollCoordinator
    let updateChartStateIfNeeded: () -> Void
    let finishChartScroll: () -> Void
    let cycleMiniChartHoursToShow: () -> Void

    /// `nil` until a new drag is classified. The result is then held for the whole gesture because
    /// the active window moves away from its original touch point during a valid drag.
    @State private var activeWindowDragIsEnabled: Bool?

    private enum Layout {
        static let chartHeight: CGFloat = 60
    }

    var body: some View {
        GeometryReader { geometry in
            let overviewStartDate = chartState.startDate
            let edgeInsetTimeInterval = overviewEdgeInsetTimeInterval(chartWidth: geometry.size.width)
            let renderedOverviewEndDate = chartState.endDate.addingTimeInterval(edgeInsetTimeInterval)

            ZStack(alignment: .leading) {
                GlucoseChartView(
                    glucoseChartType: .miniChart,
                    bgReadingValues: nil,
                    bgReadingDates: nil,
                    isMgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl,
                    urgentLowLimitInMgDl: UserDefaults.standard.urgentLowMarkValue,
                    lowLimitInMgDl: UserDefaults.standard.lowMarkValue,
                    highLimitInMgDl: UserDefaults.standard.highMarkValue,
                    urgentHighLimitInMgDl: UserDefaults.standard.urgentHighMarkValue,
                    targetValueInMgDl: targetValueInMgDl,
                    liveActivityType: nil,
                    hoursToShowScalingHours: miniChartHoursToShow,
                    glucoseCircleDiameterScalingHours: miniChartHoursToShow,
                    overrideChartHeight: geometry.size.height,
                    overrideChartWidth: geometry.size.width,
                    highContrast: nil,
                    chartState: chartState
                )
                .transaction { transaction in
                    transaction.animation = nil
                }
                .contentShape(Rectangle())
                // Treat the fixed mini-chart as a scrubber: moving its active window updates the shared
                // coordinator and therefore the main chart, while the overview data stays stationary.
                .gesture(
                    DragGesture(minimumDistance: 5)
                        .onChanged { value in
                            if activeWindowDragIsEnabled == nil {
                                activeWindowDragIsEnabled = activeWindowContains(
                                    xPosition: value.startLocation.x,
                                    chartWidth: geometry.size.width,
                                    overviewStartDate: overviewStartDate,
                                    overviewEndDate: renderedOverviewEndDate
                                )
                            }

                            guard activeWindowDragIsEnabled == true else { return }

                            scrollCoordinator.updateVisibleRangeFromOverview(
                                value: value,
                                overviewStartDate: overviewStartDate,
                                overviewEndDate: renderedOverviewEndDate,
                                leadingEdgeInsetTimeInterval: edgeInsetTimeInterval,
                                chartWidth: geometry.size.width
                            )
                            updateChartStateIfNeeded()
                        }
                        .onEnded { value in
                            let shouldFinishDrag = activeWindowDragIsEnabled ?? activeWindowContains(
                                xPosition: value.startLocation.x,
                                chartWidth: geometry.size.width,
                                overviewStartDate: overviewStartDate,
                                overviewEndDate: renderedOverviewEndDate
                            )
                            activeWindowDragIsEnabled = nil

                            guard shouldFinishDrag else { return }

                            scrollCoordinator.finishUpdatingVisibleRangeFromOverview(
                                value: value,
                                overviewStartDate: overviewStartDate,
                                overviewEndDate: renderedOverviewEndDate,
                                leadingEdgeInsetTimeInterval: edgeInsetTimeInterval,
                                chartWidth: geometry.size.width
                            )
                            finishChartScroll()
                        }
                )
                .simultaneousGesture(TapGesture(count: 2).onEnded(cycleMiniChartHoursToShow))
                .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
        }
        .frame(height: Layout.chartHeight)
    }

    /// Converts the active window's dates into the same extended coordinate space used to render
    /// the mini-chart, so only touches that begin within the visible window can move it.
    private func activeWindowContains(
        xPosition: CGFloat,
        chartWidth: CGFloat,
        overviewStartDate: Date,
        overviewEndDate: Date
    ) -> Bool {
        guard chartWidth > 0,
              let activeWindowStartDate = chartState.overlayWindowStartDate,
              let activeWindowEndDate = chartState.overlayWindowEndDate,
              activeWindowStartDate < activeWindowEndDate else {
            return false
        }

        let overviewTimeInterval = overviewEndDate.timeIntervalSince(overviewStartDate)
        let visibleActiveStartDate = max(activeWindowStartDate, overviewStartDate)
        let visibleActiveEndDate = min(activeWindowEndDate, overviewEndDate)

        guard overviewTimeInterval > 0, visibleActiveStartDate < visibleActiveEndDate else { return false }

        let activeStartX = CGFloat(visibleActiveStartDate.timeIntervalSince(overviewStartDate) / overviewTimeInterval) * chartWidth
        let activeEndX = CGFloat(visibleActiveEndDate.timeIntervalSince(overviewStartDate) / overviewTimeInterval) * chartWidth

        return xPosition >= activeStartX && xPosition <= activeEndX
    }

    /// Uses one time-equivalent inset for both rounded corners without changing chart data. The
    /// trailing span protects the `now` edge. The overview-only clamp protects the leading edge.
    private func overviewEdgeInsetTimeInterval(chartWidth: CGFloat) -> TimeInterval {
        let visibleTimeInterval = chartState.endDate.timeIntervalSince(chartState.startDate)
        return ConstantsGlucoseChartSwiftUI.miniChartEdgeInsetTimeInterval(
            visibleTimeInterval: visibleTimeInterval,
            chartWidth: chartWidth
        )
    }
}
