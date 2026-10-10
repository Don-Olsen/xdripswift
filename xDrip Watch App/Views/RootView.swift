//
//  RootView.swift
//  xDrip Watch App
//
//  Created by Paul Plant on 21/7/24.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject var watchState: WatchStateModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var libreDirectCollector: LibreWatchDirectCollector

    // save the last selected tab on the Watch so re-opening the app returns to the same page
    @AppStorage("watchAppSelectedPage") private var selectedPage = WatchAppPage.main.rawValue
    @State private var showingBolusCalculator = false
    @State private var showingLibreControls = false

    // keep both main pages on the same chart range so swiping between them only changes whether
    // the AGP background is visible. The chart content should not jump between pages.
    @State private var hoursToShowIndex = ConstantsAppleWatch.hoursToShowDefaultIndex
    
    var body: some View {
        TabView(selection: $selectedPage) {
            // normal main page
            MainView(isVisible: selectedPage == WatchAppPage.main.rawValue, hoursToShowIndex: $hoursToShowIndex)
                .tag(WatchAppPage.main.rawValue)

            // same main page layout, but with the AGP background enabled in the chart
            MainView(showsAGPBackground: true, isVisible: selectedPage == WatchAppPage.agp.rawValue, hoursToShowIndex: $hoursToShowIndex)
                .tag(WatchAppPage.agp.rawValue)

            // large number page
            BigNumberView(libreDirectCollector: libreDirectCollector)
                .tag(WatchAppPage.bigNumber.rawValue)
        }
        .modifier(RootViewTabViewStyleModifier())
        .environmentObject(watchState)
        .toolbar {
            if selectedPage == WatchAppPage.main.rawValue ||
                selectedPage == WatchAppPage.agp.rawValue ||
                selectedPage == WatchAppPage.bigNumber.rawValue {
                ToolbarItem(placement: .topBarLeading) { libreButton }
                ToolbarItem(placement: .topBarTrailing) { calculatorButton }
            }
        }
        .fullScreenCover(isPresented: $showingBolusCalculator) {
            WatchManualTreatmentsView()
                .environmentObject(watchState)
        }
        .fullScreenCover(isPresented: $showingLibreControls) {
            // Reuse the hand-off screen and watchOS' standard close button outside the carousel.
            LibreDirectView(collector: libreDirectCollector)
                .environmentObject(watchState)
        }
        .onAppear {
            if WatchAppPage(rawValue: selectedPage) == nil {
                // Former Libre (3), treatments (4) and other unknown saved pages return to Main.
                selectedPage = WatchAppPage.main.rawValue
            } else if watchState.libreWatchOwnership == .watch {
                selectedPage = WatchAppPage.bigNumber.rawValue
            }
            libreDirectCollector.applicationActivityDidChange(scenePhase.libreWatchApplicationState)
            updatePhoneRefreshVisibility()
        }
        .onChange(of: scenePhase) { newPhase in
            libreDirectCollector.applicationActivityDidChange(newPhase.libreWatchApplicationState)
            if newPhase == .active {
                watchState.refreshLocalAlarmPermission()
                watchState.retryPendingManualTreatments()
            }
            if newPhase == .active, watchState.libreWatchOwnership == .watch {
                selectedPage = WatchAppPage.bigNumber.rawValue
            }
            updatePhoneRefreshVisibility()
        }
        .onChange(of: watchState.libreWatchOwnership) { ownership in
            if ownership == .watch {
                selectedPage = WatchAppPage.bigNumber.rawValue
            }
        }
        .onChange(of: watchState.libreWatchOwnership == .watch && libreDirectCollector.state.stage == .receiving) { connected in
            if connected {
                // The Libre controls now cover the carousel. Reveal Big Number on connection;
                // leave an open bolus calculator and its entered amounts untouched.
                selectedPage = WatchAppPage.bigNumber.rawValue
                showingLibreControls = false
            }
        }
        .onChange(of: selectedPage) { _ in updatePhoneRefreshVisibility() }
        .onChange(of: hoursToShowIndex) { _ in updatePhoneRefreshVisibility() }
        .onDisappear {
            watchState.phoneRefreshVisibilityDidChange(active: false, showsAGP: false,
                hours: ConstantsAppleWatch.hoursToShow[hoursToShowIndex])
        }
    }

    private func updatePhoneRefreshVisibility() {
        watchState.phoneRefreshVisibilityDidChange(active: scenePhase == .active,
            showsAGP: selectedPage == WatchAppPage.agp.rawValue,
            hours: ConstantsAppleWatch.hoursToShow[hoursToShowIndex])
    }

    private var libreButton: some View {
        Button {
            showingLibreControls = true
        } label: {
            Image(systemName: "l.circle.fill")
                .font(.system(size: 24))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Libre – sensorforbindelse")
    }

    private var calculatorButton: some View {
        Button {
            showingBolusCalculator = true
        } label: {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 24))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Bolusberegner")
    }
}

private extension ScenePhase {
    var libreWatchApplicationState: LibreWatchApplicationState {
        switch self {
        case .active: return .active
        case .inactive: return .inactive
        case .background: return .background
        @unknown default: return .background
        }
    }
}

private enum WatchAppPage: Int {
    case main = 0
    case agp = 1
    case bigNumber = 2
}

private struct WatchManualTreatmentsView: View {
    @EnvironmentObject private var watchState: WatchStateModel
    @State private var carbohydrateGrams = 0.0
    @State private var insulinUnits = 0.0
    @State private var mealKindRaw = "normal"
    @State private var visibleNow = Date()
    @State private var showingConfirmation = false
    @State private var confirmedDraft: ConfirmationDraft?
    @State private var copyingSuggestion = false
    @FocusState private var focusedInput: CrownInput?

    private enum CrownInput: Hashable { case carbohydrates, insulin }

    private struct ConfirmationDraft {
        let carbohydrateGrams: Double
        let insulinUnits: Double
        let mealKindRaw: String
        let manualWithoutCurrentSuggestion: Bool
        let safetyReason: String?

        var amountText: String {
            let food = carbohydrateGrams > 0 ? "\(carbohydrateGrams.formatted()) g" : nil
            let insulin = insulinUnits > 0 ? "\(insulinUnits.formatted()) E" : nil
            if let food, let insulin { return "Log \(food) og \(insulin) nu?" }
            return "Log \(food ?? insulin ?? "") nu?"
        }

        var message: String {
            var lines = [amountText]
            if manualWithoutCurrentSuggestion {
                lines.append("Manuel dosis uden aktuelt kontrolleret forslag.")
                if safetyReason == nil { lines.append("Ingen aktuel sikkerhedskontrol fra iPhone.") }
            }
            if let safetyReason, !safetyReason.isEmpty { lines.append(safetyReason) }
            return lines.joined(separator: "\n")
        }
    }

    private var currentSuggestion: Double? {
        watchState.currentWatchPenSuggestion(carbohydrateGrams: carbohydrateGrams,
            mealKindRaw: mealKindRaw, at: Date())
    }

    private var canLog: Bool {
        carbohydrateGrams.isFinite && insulinUnits.isFinite &&
            carbohydrateGrams >= 0 && carbohydrateGrams <= 500 &&
            insulinUnits >= 0 && (carbohydrateGrams > 0 || insulinUnits > 0) &&
            (insulinUnits == 0 || watchState.watchPenProfileSettings?.accepts(insulinUnits) == true) &&
            watchState.manualTreatmentStorageIssue == nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // fullScreenCover already supplies watchOS' close button above this content.
                Text("Bolusberegner")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !watchState.phoneIsReachable {
                    Text("Ikke forbundet med iPhone – logger uden beregning")
                        .font(.footnote).foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 8) {
                    crownInputCard("Kulhydrater", value: carbohydrateGrams, unit: "g", input: .carbohydrates)
                        .contentShape(Rectangle())
                        .focusable(true)
                        .focused($focusedInput, equals: .carbohydrates)
                        .digitalCrownRotation($carbohydrateGrams, from: 0, through: 500, by: 1,
                            sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
                        .onTapGesture { focusedInput = .carbohydrates }
                        .accessibilityHint("Drej Digital Crown for at vælge gram")
                    mealKindPicker
                    if let profile = watchState.watchPenProfileSettings, profile.isValid {
                        crownInputCard("Dosis", value: insulinUnits, unit: "E", input: .insulin)
                            .contentShape(Rectangle())
                            .focusable(true)
                            .focused($focusedInput, equals: .insulin)
                            .digitalCrownRotation($insulinUnits, from: 0,
                                through: profile.maximumUnits, by: profile.penStepUnits,
                                sensitivity: .medium, isContinuous: false, isHapticFeedbackEnabled: true)
                            .onTapGesture { focusedInput = .insulin }
                            .accessibilityHint("Drej Digital Crown i \(profile.penStepUnits.formatted()) E-trin")
                        Text("\(profile.penStepUnits.formatted()) E-trin · maks. \(profile.maximumUnits.formatted()) E")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Pen-trin og maksimum afventer iPhone. Kulhydrater kan stadig logges.")
                            .font(.footnote).foregroundStyle(.orange)
                        if insulinUnits > 0 {
                            Button("Ryd dosis") { insulinUnits = 0 }
                        }
                    }
                    if insulinUnits > 0 && watchState.watchPenProfileSettings?.accepts(insulinUnits) != true {
                        Text("Dosis passer ikke til den synkroniserede penprofil.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Button("Beregn") {
                        watchState.calculateWatchPenDose(carbohydrateGrams: carbohydrateGrams,
                            mealKindRaw: mealKindRaw)
                    }
                    .disabled(watchState.watchPenIsCalculating)
                    if watchState.watchPenIsCalculating { ProgressView("Beregner på iPhone…") }
                    calculationResult
                    Button("Brug forslag") {
                        guard let suggestion = currentSuggestion else { return }
                        if insulinUnits != suggestion {
                            copyingSuggestion = true
                            insulinUnits = suggestion
                        }
                    }
                    .disabled(currentSuggestion == nil)
                }
                .padding(.top, 4)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Button("Log") { prepareConfirmation() }
                        .disabled(!canLog)
                        .buttonStyle(.borderedProminent)
                    deliveryStatus
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .onAppear {
            focusedInput = .carbohydrates
            watchState.retryPendingManualTreatments()
            if !watchState.phoneIsReachable { watchState.requestWatchStateUpdate() }
        }
        .onReceive(watchState.timer) { date in
            visibleNow = date
            watchState.expireWatchPenSuggestionIfNeeded(at: date)
        }
        .onChange(of: carbohydrateGrams) { _ in watchState.invalidateWatchPenCalculation() }
        .onChange(of: mealKindRaw) { _ in watchState.invalidateWatchPenCalculation() }
        .onChange(of: insulinUnits) { _ in
            if copyingSuggestion { copyingSuggestion = false }
            else { watchState.invalidateWatchPenCalculation() }
        }
        .alert("Bekræft registrering", isPresented: $showingConfirmation) {
            Button("Annuller", role: .cancel) { confirmedDraft = nil }
            Button("Log") {
                guard let draft = confirmedDraft else { return }
                _ = watchState.recordWatchBolus(
                    carbohydrateGrams: draft.carbohydrateGrams, insulinUnits: draft.insulinUnits,
                    mealKindRaw: draft.mealKindRaw,
                    manualWithoutCurrentSuggestion: draft.manualWithoutCurrentSuggestion)
                confirmedDraft = nil
            }
        } message: {
            Text(confirmedDraft?.message ?? "")
        }
    }

    private func crownInputCard(_ title: String, value: Double, unit: String, input: CrownInput) -> some View {
        let isFocused = focusedInput == input
        return VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isFocused ? Color.accentColor : .secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.formatted())
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(unit)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(isFocused ? Color.accentColor.opacity(0.16) : Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isFocused ? Color.accentColor : Color.white.opacity(0.12),
                lineWidth: isFocused ? 2 : 1))
        .accessibilityElement(children: .combine)
    }

    private var mealKindPicker: some View {
        HStack(spacing: 4) {
            mealButton("🍭", kind: "fast")
            mealButton("🌮", kind: "normal")
            mealButton("🍕", kind: "slow")
        }
    }

    private func mealButton(_ icon: String, kind: String) -> some View {
        Button(icon) { mealKindRaw = kind }
            .buttonStyle(.bordered)
            .tint(mealKindRaw == kind ? .orange : .gray)
            .accessibilityLabel(kind == "fast" ? "Hurtig mad" : kind == "slow" ? "Langsom mad" : "Normal mad")
    }

    private var calculationResult: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let issue = watchState.watchPenCalculationIssue {
                Text(issue).font(.footnote).foregroundStyle(.orange)
            }
            if let result = watchState.watchPenCalculation {
                if let suggestion = currentSuggestion {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Anbefalet")
                            .font(.caption2.weight(.semibold))
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(suggestion.formatted())
                                .font(.system(size: 28, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                            Text("E").font(.body.weight(.semibold))
                        }
                    }
                    .foregroundStyle(.green)
                    .accessibilityElement(children: .combine)
                }
                // A blocked low-glucose calculation still has a real snapshot.
                // Other unavailable results carry placeholder 0 values for IOB/COB.
                if result.unavailableReason == nil ||
                    (result.safetyRaw != nil && result.glucoseMeasuredAt != nil) {
                    if let glucose = result.glucoseMgdl, let measuredAt = result.glucoseMeasuredAt {
                        let shown = watchState.isMgDl ? glucose : glucose / 18.01559
                        Text("BG \(shown.formatted())\(trendArrow(result.glucoseTrendMgdl)) · \(max(0, Int(visibleNow.timeIntervalSince(measuredAt) / 60))) min")
                    }
                    Text("IOB \(result.iobUnits.formatted()) E · COB \(result.cobGrams.formatted()) g")
                }
                if result.unavailableReason == nil,
                   let nowUnits = result.pizzaNowUnits,
                   let minutes = result.pizzaReminderMinutes {
                    Text("Nu \(nowUnits.formatted()) E · beregn igen om \(minutes) min")
                }
                if let reason = result.unavailableReason {
                    Text(reason).foregroundStyle(.orange)
                }
                if let safety = result.safetyRaw {
                    Text(safetyTitle(safety))
                        .foregroundStyle(safety == "checked" ? .green : .orange)
                }
                if let reason = result.safetyReason, !reason.isEmpty {
                    Text(reason).foregroundStyle(.orange)
                }
            }
        }
        .font(.footnote)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func trendArrow(_ twentyMinuteChange: Double?) -> String {
        guard let change = twentyMinuteChange else { return "" }
        if change >= 60 { return " ↑↑" }
        if change >= 20 { return " ↑" }
        if change >= 5 { return " ↗" }
        if change <= -60 { return " ↓↓" }
        if change <= -20 { return " ↓" }
        if change <= -5 { return " ↘" }
        return " →"
    }

    private func safetyTitle(_ raw: String) -> String {
        switch raw {
        case "checked": return "Sikkerhed kontrolleret"
        case "eatFirst", "eatFirstForecastUnchecked": return "Spis først"
        case "blockedCurrentLow", "blockedForecastLow": return "Beregning blokeret af lavt blodsukker"
        case "forecastUnchecked": return "Prognosen kunne ikke kontrolleres"
        default: return "Sikkerhedsstatus: \(raw)"
        }
    }

    private func prepareConfirmation() {
        guard canLog else { return }
        let matchingCheckedSuggestion = watchState.watchPenCalculation?.safetyRaw == "checked" &&
            currentSuggestion.map { abs($0 - insulinUnits) < 0.0001 } == true
        confirmedDraft = ConfirmationDraft(carbohydrateGrams: carbohydrateGrams,
            insulinUnits: insulinUnits, mealKindRaw: mealKindRaw,
            manualWithoutCurrentSuggestion: insulinUnits > 0 && !matchingCheckedSuggestion,
            safetyReason: watchState.watchPenCalculation?.safetyReason)
        showingConfirmation = true
    }

    @ViewBuilder private var deliveryStatus: some View {
        if let issue = watchState.bolusStorageIssue ?? watchState.manualTreatmentStorageIssue {
            Label(issue, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Registrering fejlede: \(issue)")
        } else if !watchState.pendingBolusOperations.isEmpty {
            Label(watchState.bolusDeliveryIssue ?? "Gemt på uret – afventer iPhone", systemImage: "clock")
                .foregroundStyle(.orange)
        } else if watchState.lastStoredBolusOperation != nil {
            Label("Logget på iPhone", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        if !watchState.pendingManualTreatments.isEmpty {
            Label("Tidligere behandlinger afventer iPhone", systemImage: "clock")
                .foregroundStyle(.orange)
        }
    }
}

#if os(watchOS)
struct RootViewTabViewStyleModifier: ViewModifier {
    
    func body(content: Content) -> some View {
        content.tabViewStyle(.carousel)
    }
}
#else
struct RootViewTabViewStyleModifier: ViewModifier {
    
    func body(content: Content) -> some View {
        content.tabViewStyle(.page)
    }
}
#endif

#Preview {
    RootView(libreDirectCollector: LibreWatchDirectCollector())
        .environmentObject(WatchStateModel())
}
