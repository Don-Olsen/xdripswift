//
//  RootHomeStatusViews.swift
//  xdrip
//
//  Created by Paul Plant on 22/7/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import SwiftUI

private enum RootHomeDisplayStyle {
    static let historicalValueOpacity = 0.7
}

private extension Bool {
    var rootHomeHistoricalValueOpacity: Double {
        self ? RootHomeDisplayStyle.historicalValueOpacity : 1
    }
}

/// Compact pump status displayed beside the current glucose reading.
struct RootHomePumpView: View {
    let state: RootHomePumpState

    static let preferredWidth: CGFloat = 158

    var body: some View {
        VStack(spacing: 0) {
            RootHomeHorizontalMetricView(metric: state.basal, valueOpacity: state.isHistorical.rootHomeHistoricalValueOpacity)
            RootHomeHorizontalMetricView(metric: state.reservoir, valueOpacity: state.isHistorical.rootHomeHistoricalValueOpacity)
            RootHomeHorizontalMetricView(metric: state.battery, valueOpacity: state.isHistorical.rootHomeHistoricalValueOpacity)
            if let cage = state.cage {
                RootHomeHorizontalMetricView(metric: cage, valueOpacity: state.isHistorical.rootHomeHistoricalValueOpacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(width: Self.preferredWidth)
        .frame(maxHeight: .infinity)
        .background(panelBackground(isHistorical: state.isHistorical))
        .clipShape(RoundedRectangle(cornerRadius: ConstantsHomeView.standardCornerRadius, style: .continuous))
    }
}

/// Only an authoritative local treatment boundary can open the pen calculator from Home.
/// Source identity, rather than metric availability, keeps external IOB/COB out of this action.
enum RootHomeCalculatorShortcutPolicy {
    static func isVisible(policy: DataFlowPolicy, cutover: TreatmentSourceCutover?,
                          iobSource: TherapyMetricSource?, cobSource: TherapyMetricSource?,
                          isHistorical: Bool, localInputsComplete: Bool = true,
                          defaults: UserDefaults = .standard) -> Bool {
        guard !isHistorical, localInputsComplete,
              TherapyMetricsManager.doseSourceIsReady(policy, cutover: cutover,
                                                       defaults: defaults) else { return false }
        return (iobSource == nil || iobSource == .local)
            && (cobSource == nil || cobSource == .local)
    }
}

/// Resolves a pending icon action synchronously when Home can present its existing sheet.
/// RootTabStateModel keeps the request until `consume` runs, including across cold starts.
enum RootHomeCalculatorQuickActionPresentation {
    static func open(request: UUID?, isReady: Bool, isAlreadyPresented: Bool,
                     present: () -> Void, consume: (UUID) -> Void) {
        guard let request, isReady else { return }
        if !isAlreadyPresented { present() }
        consume(request)
    }
}

/// Loop status row displayed below the pump and glucose values.
struct RootHomeLoopView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedMetric: Bool?
    @State private var showsMetricDetails = false
    let state: RootHomeLoopState
    let actions: RootHomeActions
    let showsCalculatorShortcut: Bool
    let onBolusCalculator: () -> Void

    init(state: RootHomeLoopState, actions: RootHomeActions,
         showsCalculatorShortcut: Bool = false,
         onBolusCalculator: @escaping () -> Void = {}) {
        self.state = state
        self.actions = actions
        self.showsCalculatorShortcut = showsCalculatorShortcut
        self.onBolusCalculator = onBolusCalculator
    }

    private enum Layout {
        static let statusSymbolSize: CGFloat = 18
        static let inlineMetricWidth: CGFloat = 78
        static let height: CGFloat = 34
        static let calculatorTouchSize: CGFloat = 44
    }

    var body: some View {
        HStack(spacing: 0) {
            if state.showsIOB {
                metricButton(isIOB: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if showsCalculatorShortcut {
                Spacer(minLength: 0)
            }

            if showsCalculatorShortcut {
                Button(action: onBolusCalculator) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(ConstantsAppColors.accent)
                        .frame(width: Layout.calculatorTouchSize,
                               height: Layout.calculatorTouchSize)
                        .contentShape(Rectangle())
                }
                .frame(width: Layout.calculatorTouchSize,
                       height: Layout.calculatorTouchSize)
                .accessibilityLabel("Bolusberegner")
                .accessibilityIdentifier("home.bolusCalculator")
                .layoutPriority(1)
            }

            if state.showsCOB {
                if showsCalculatorShortcut {
                    metricButton(isIOB: false)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    metricButton(isIOB: false)
                        .frame(width: Layout.inlineMetricWidth, alignment: .leading)
                }
            } else if showsCalculatorShortcut {
                Spacer(minLength: 0)
            }

            if state.showsAIDStatus {
                Button(action: actions.showAIDStatus) { loopStatusView }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity)
        // Give the entire hit region its own 44-point layout. The painted strip remains
        // 34 points at ordinary text sizes, so no hit target spills into neighboring rows.
        .frame(height: showsCalculatorShortcut ? Layout.calculatorTouchSize : Layout.height)
        .background {
            RoundedRectangle(cornerRadius: ConstantsHomeView.standardCornerRadius,
                             style: .continuous)
                .fill(panelBackground(isHistorical: state.isHistorical))
                .frame(height: showsCalculatorShortcut && dynamicTypeSize.isAccessibilitySize
                    ? Layout.calculatorTouchSize : Layout.height)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showsMetricDetails) {
            NavigationStack {
                if let isIOB = selectedMetric, let metrics = state.therapyMetrics {
                    TherapyMetricDetailsView(metric: isIOB ? metrics.iob : metrics.cob, isIOB: isIOB)
                }
            }
        }
        .transaction { transaction in
            // Calculation updates replace label text immediately. Threshold colors animate separately.
            transaction.animation = nil
        }
    }

    private func metricButton(isIOB: Bool) -> some View {
        let metric = isIOB ? state.therapyMetrics?.iob : state.therapyMetrics?.cob
        let displayed = isIOB ? state.iob : state.cob
        return Button {
            if metric?.source == .local { selectedMetric = isIOB; showsMetricDetails = true }
            else { actions.showAIDStatus() }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                RootHomeInlineMetricView(metric: displayed, valueOpacity: state.isHistorical.rootHomeHistoricalValueOpacity)
                Text(displayed.lastCalculatedAt.map { Self.lastCalculatedCaption(at: $0) } ?? " ")
                    .font(.system(size: 9))
                    .foregroundStyle(ConstantsAppColors.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .opacity(displayed.lastCalculatedAt == nil ? 0 : 1)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(metric?.accessibilityName(isIOB: isIOB) ?? (isIOB ? "IOB" : "COB"))
        .accessibilityValue(displayed.lastCalculatedAt.map {
            "\(displayed.value), \(Self.lastCalculatedAccessibility(at: $0))"
        } ?? displayed.value)
    }

    private static func lastCalculatedCaption(at date: Date) -> String {
        let format = NSLocalizedString("therapy.lastCalculatedShort", tableName: "Common",
            value: "Last %@", comment: "Compact timestamp for a previous IOB or COB calculation")
        return String(format: format, date.formatted(date: .omitted, time: .shortened))
    }

    private static func lastCalculatedAccessibility(at date: Date) -> String {
        let format = NSLocalizedString("therapy.lastCalculated", tableName: "Common",
            value: "Last calculated at %@", comment: "Previous IOB or COB value while inputs refresh")
        return String(format: format, date.formatted(date: .omitted, time: .shortened))
    }

    private var loopStatusView: some View {
        HStack(spacing: 6) {
            if state.showsUploaderBattery {
                Image(systemName: state.uploaderBatterySystemImage)
                    .font(.system(size: 14))
                    .foregroundStyle(state.uploaderBatteryColor)
                    .opacity(state.isHistorical.rootHomeHistoricalValueOpacity)
            }

            if state.showsActivityIndicator {
                ProgressView()
                    .scaleEffect(0.75)
                    .tint(state.isHistorical ? ConstantsAppColors.secondaryText : ConstantsAppColors.primaryText)
                    .opacity(state.isHistorical.rootHomeHistoricalValueOpacity)
            }

            if state.showsStatusTimeAgo {
                Text(state.statusTimeAgo)
                    .font(.system(size: 16))
                    .foregroundStyle(state.isHistorical ? ConstantsAppColors.secondaryText : ConstantsAppColors.primaryText)
                    .opacity(state.isHistorical.rootHomeHistoricalValueOpacity)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }

            if let statusSymbol = state.statusSymbol {
                AIDStatusSymbolImage(symbol: statusSymbol)
                    .font(.system(size: Layout.statusSymbolSize, weight: .black))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(state.statusColor)
                    .opacity(state.isHistorical.rootHomeHistoricalValueOpacity)
            }
        }
    }
}

private func panelBackground(isHistorical: Bool) -> Color {
    ConstantsAppColors.homePanelBackground.opacity(isHistorical ? 0.3 : 1)
}

/// One compact title and value pair used inside the pump panel.
struct RootHomeInlineMetricView: View {
    let metric: RootHomeMetricState
    var valueOpacity = 1.0

    var body: some View {
        HStack(spacing: 6) {
            Text(metric.title)
                .font(.system(size: 16))
                .foregroundStyle(ConstantsAppColors.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(metric.value)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(metric.valueColor)
                .opacity(valueOpacity)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
    }
}

/// One horizontal title and value pair used by the loop row.
struct RootHomeHorizontalMetricView: View {
    let metric: RootHomeMetricState
    var valueOpacity = 1.0

    var body: some View {
        HStack(spacing: 4) {
            Text(metric.title)
                .font(.system(size: 15))
                .foregroundStyle(ConstantsAppColors.secondaryText)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(metric.value)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(metric.valueColor)
                .opacity(valueOpacity)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxHeight: .infinity)
    }
}
