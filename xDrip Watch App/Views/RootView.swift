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

            // One swipe from the large glucose display. Entries are saved on the
            // Watch before delivery and do not depend on current sensor ownership.
            WatchManualTreatmentsView()
                .tag(WatchAppPage.treatments.rawValue)

            // Explicit persistent hand-off between iPhone and direct Watch reception.
            LibreDirectView(collector: libreDirectCollector)
                .tag(WatchAppPage.libreDirect.rawValue)
        }
        .modifier(RootViewTabViewStyleModifier())
        .environmentObject(watchState)
        .onAppear {
            if watchState.libreWatchOwnership == .watch {
                selectedPage = WatchAppPage.bigNumber.rawValue
            } else if WatchAppPage(rawValue: selectedPage) == nil {
                // if a saved tab value from an older build is invalid, fall back to the normal main page
                selectedPage = WatchAppPage.main.rawValue
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
            if newPhase == .active, watchState.libreWatchOwnership == .watch,
               selectedPage != WatchAppPage.treatments.rawValue {
                selectedPage = WatchAppPage.bigNumber.rawValue
            }
            updatePhoneRefreshVisibility()
        }
        .onChange(of: watchState.libreWatchOwnership) { ownership in
            if ownership == .watch {
                selectedPage = WatchAppPage.bigNumber.rawValue
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
    case libreDirect = 3
    case treatments = 4
}

private struct WatchManualTreatmentsView: View {
    @EnvironmentObject private var watchState: WatchStateModel
    @State private var selectedKind: WatchManualTreatmentKind = .insulin
    @State private var showingEntry = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Registrer behandling")
                    .font(.headline)
                treatmentButton("Insulin (U)", symbol: "drop.fill", kind: .insulin)
                treatmentButton("Kulhydrat (g)", symbol: "fork.knife", kind: .carbs)
                deliveryStatus
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 8)
        }
        .sheet(isPresented: $showingEntry) {
            WatchManualTreatmentEntryView(kind: selectedKind)
                .environmentObject(watchState)
        }
        .onAppear { watchState.retryPendingManualTreatments() }
    }

    private func open(_ kind: WatchManualTreatmentKind) {
        selectedKind = kind
        showingEntry = true
    }

    private func treatmentButton(_ title: String, symbol: String, kind: WatchManualTreatmentKind) -> some View {
        Button { open(kind) } label: {
            Label(title, systemImage: symbol)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Registrer \(title)")
    }

    private func treatmentDescription(_ treatment: WatchManualTreatment) -> String {
        "\(treatment.amount.formatted()) \(treatment.kind == .insulin ? "U insulin" : "g kulhydrat")"
    }

    private var pendingStatus: String {
        guard let newest = watchState.pendingManualTreatments.last else { return "" }
        let delivery = watchState.manualTreatmentDeliveryIssue == nil ? "afventer iPhone" : "prøver iPhone igen"
        let count = watchState.pendingManualTreatments.count
        let countText = count > 1 ? " (\(count) i alt)" : ""
        return "\(treatmentDescription(newest)) gemt på uret · \(delivery)\(countText)"
    }

    @ViewBuilder
    private var deliveryStatus: some View {
        if let issue = watchState.manualTreatmentStorageIssue {
            Label(issue, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Registrering fejlede: \(issue)")
        } else if !watchState.pendingManualTreatments.isEmpty {
            Label(pendingStatus, systemImage: "clock")
                .foregroundStyle(.orange)
        } else if let stored = watchState.lastStoredManualTreatment {
            Label("\(treatmentDescription(stored)) gemt på iPhone", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("Ingen afventende registreringer", systemImage: "info.circle")
                .foregroundStyle(.secondary)
        }
    }
}

private struct WatchManualTreatmentEntryView: View {
    @EnvironmentObject private var watchState: WatchStateModel
    @Environment(\.dismiss) private var dismiss
    let kind: WatchManualTreatmentKind
    @State private var amountText = ""
    @State private var showingConfirmation = false
    @State private var saving = false

    private var amount: Double? {
        let cleaned = amountText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        let maximum = kind == .insulin ? 200.0 : 500.0
        guard let value = Double(cleaned), value.isFinite, value > 0, value <= maximum else { return nil }
        return value
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(kind == .insulin ? "Insulin taget" : "Kulhydrat spist")
                    .font(.headline)
                TextField(kind == .insulin ? "Antal U" : "Antal gram", text: $amountText)
                if !amountText.isEmpty && amount == nil {
                    Text(kind == .insulin ? "Angiv over 0 og højst 200 U" : "Angiv over 0 og højst 500 g")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
                Text("Kun registrering · ingen dosisberegning")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let issue = watchState.manualTreatmentStorageIssue {
                    Text(issue).font(.footnote).foregroundStyle(.red)
                }
                Button("Fortsæt") { showingConfirmation = true }
                    .disabled(amount == nil || watchState.manualTreatmentStorageIssue != nil)
            }
            .padding(.horizontal, 8)
        }
        .alert("Bekræft registrering", isPresented: $showingConfirmation) {
            Button("Annuller", role: .cancel) {}
            Button("Gem") {
                guard !saving, let amount else { return }
                saving = true
                if watchState.recordManualTreatment(kind: kind, amount: amount) { dismiss() }
                else { saving = false }
            }
        } message: {
            Text("\(amount?.formatted() ?? "–") \(kind == .insulin ? "U insulin taget" : "g kulhydrat spist") nu?")
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
