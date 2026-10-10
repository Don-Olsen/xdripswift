//
//  TreatmentsView.swift
//  xdrip
//
//  Created by Paul Plant on 18/6/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation
import SwiftUI
import Combine

/// Owns the treatment list model and presents the add/edit sheet.
struct TreatmentsView: View {
    // MARK: - private properties

    @StateObject private var viewModel: TreatmentsViewModel
    @State private var treatmentEditorState: TreatmentEditorState?
    @State private var showsPenCalculator = false
    @State private var calculatorReminderMealUUID: String?
    @State private var mealNotice: String?
    @State private var basalNotice: String?

    // MARK: - initialization

    init(coreDataManager: CoreDataManager) {
        _viewModel = StateObject(wrappedValue: TreatmentsViewModel(coreDataManager: coreDataManager))
    }

    // MARK: - SwiftUI views

    var body: some View {
        TreatmentsListView(
            viewModel: viewModel,
            onAddTreatment: {
                treatmentEditorState = .add
            },
            onQuickCarbs: { grams in
                treatmentEditorState = .quickCarbs(grams)
            },
            onPenCalculator: {
                calculatorReminderMealUUID = nil
                showsPenCalculator = true
            },
            onSelectTreatment: { treatment in
                treatmentEditorState = .edit(treatment)
            }
        )
        .sheet(item: $treatmentEditorState, onDismiss: openRequestedBasal) { editorState in
            TreatmentEditorContainerView(
                coreDataManager: viewModel.coreDataManager,
                editorState: editorState,
                onSave: {
                    viewModel.reloadTreatments()
                    treatmentEditorState = nil
                },
                onCancel: {
                    treatmentEditorState = nil
                }
            )
        }
        .sheet(isPresented: $showsPenCalculator, onDismiss: {
            calculatorReminderMealUUID = nil
            openRequestedBasal()
        }) {
            PenDoseCalculatorScreen(coreDataManager: viewModel.coreDataManager,
                reminderMealUUID: calculatorReminderMealUUID,
                onSave: {
                    viewModel.reloadTreatments()
                    showsPenCalculator = false
                },
                onCancel: { showsPenCalculator = false })
        }
        .onAppear(perform: openRequestedPlannedMeal)
        .onReceive(NotificationCenter.default.publisher(for: PlannedMealReminder.openRequested)) { _ in
            openRequestedPlannedMeal()
        }
        .onAppear(perform: openRequestedPizzaRecalculation)
        .onReceive(NotificationCenter.default.publisher(for: PizzaSplitReminder.openRequested)) { _ in
            openRequestedPizzaRecalculation()
        }
        .onAppear(perform: openRequestedBasal)
        .onReceive(NotificationCenter.default.publisher(for: BasalReminderScheduler.openRequested)) { _ in
            openRequestedBasal()
        }
        .onReceive(NotificationCenter.default.publisher(for: MealReminderIssueCenter.reported)) { notification in
            mealNotice = notification.object as? String
        }
        .alert("Måltidsplan", isPresented: Binding(
            get: { mealNotice != nil },
            set: { if !$0 { mealNotice = nil } }
        )) {
            Button("OK") { mealNotice = nil }
        } message: {
            Text(mealNotice ?? "")
        }
        .alert("Basal", isPresented: Binding(
            get: { basalNotice != nil },
            set: { if !$0 { basalNotice = nil } }
        )) {
            Button("OK") { basalNotice = nil }
        } message: {
            Text(basalNotice ?? "")
        }
    }

    private func openRequestedPlannedMeal() {
        guard let uuid = PlannedMealReminder.pendingOpenUUID else { return }
        let status = MealPlanReminderCoordinator.status(coreDataManager: viewModel.coreDataManager, uuid: uuid)
        switch status {
        case .planned: break
        case .confirmed: mealNotice = "Måltidet er allerede bekræftet."
        case .cancelled: mealNotice = "Måltidsplanen er annulleret."
        case .deleted: mealNotice = "Måltidsplanen er slettet."
        case .unavailable: mealNotice = "Måltidsstatus kunne ikke læses. Prøv igen i behandlingshistorikken."
        }
        guard case .planned = status else {
            PlannedMealReminder.clearPendingOpenUUID(uuid)
            return
        }
        viewModel.reloadTreatments()
        if let meal = viewModel.plannedMealSnapshot(uuid: uuid) {
            treatmentEditorState = .edit(meal)
        } else {
            mealNotice = "Måltidsplanen kunne ikke åbnes. Kontrollér behandlingshistorikken."
        }
        PlannedMealReminder.clearPendingOpenUUID(uuid)
    }

    private func openRequestedPizzaRecalculation() {
        guard let uuid = PizzaSplitReminder.pendingOpenUUID else { return }
        defer { PizzaSplitReminder.clearPendingOpenUUID(uuid) }
        let meal = TreatmentEntryAccessor(coreDataManager: viewModel.coreDataManager)
            .getLatestTreatments(howOld: 4 * 60 * 60)
            .first { $0.localTreatmentUUID == uuid && $0.isConfirmedMeal &&
                !$0.treatmentdeleted && $0.mealKind == .slow }
        guard meal != nil else { return }
        calculatorReminderMealUUID = uuid
        showsPenCalculator = true
    }

    private func openRequestedBasal() {
        guard BasalReminderScheduler.hasPendingOpen,
              treatmentEditorState == nil, !showsPenCalculator else { return }
        guard BasalReminderScheduler.prepareDraftPrefill(coreDataManager: viewModel.coreDataManager) else {
            basalNotice = "Seneste registrerede basal kunne ikke læses. Prøv igen."
            return
        }
        guard BasalReminderScheduler.consumePendingOpen() else { return }
        treatmentEditorState = .basal
    }
}

/// Displays treatments for one day with the persisted treatment filters.
struct TreatmentsListView: View {
    // MARK: - private properties

    @ObservedObject var viewModel: TreatmentsViewModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showScrollToTopButton = false
    @State private var pendingLocalDeletion: TreatmentSnapshot?
    private let topScrollAnchorID = "treatmentsTop"
    private let scrollToTopButtonThresholdIndex = 4

    let onAddTreatment: () -> Void
    let onQuickCarbs: (Double) -> Void
    let onPenCalculator: () -> Void
    let onSelectTreatment: (TreatmentSnapshot) -> Void

    // MARK: - SwiftUI views

    var body: some View {
        ScrollViewReader { scrollProxy in
            ZStack(alignment: .bottomTrailing) {
                GeometryReader { geometry in
                    if IPadLayoutClass.resolve(
                        isPad: UIDevice.current.userInterfaceIdiom == .pad,
                        width: geometry.size.width,
                        usesAccessibilityText: dynamicTypeSize.isAccessibilitySize
                    ) != .compact {
                        ipadContent
                    } else {
                        phoneContent
                    }
                }
                .background(Color(.systemGroupedBackground).ignoresSafeArea())

                if showScrollToTopButton {
                    Button {
                        withAnimation {
                            if let firstTreatment = viewModel.filteredTreatments.first {
                                scrollProxy.scrollTo(firstTreatment.objectID, anchor: .top)
                            } else {
                                scrollProxy.scrollTo(topScrollAnchorID, anchor: .top)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.yellow)
                            .frame(width: 48, height: 48)
                            .background(Color(.secondarySystemGroupedBackground), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: showScrollToTopButton)
            .navigationTitle(Texts_TreatmentsView.treatmentsTitle)
            .navigationBarTitleDisplayMode(.large)
            .colorScheme(.dark)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    OnlineHelpButton(topic: .treatments)

                    NavigationLink {
                        PenDoseSettingsView()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Bolusberegnerens profil og indstillinger")

                    Button(action: onAddTreatment) {
                        Image(systemName: "plus")
                    }
                    .tint(ConstantsAppColors.toolbarAction)
                }
            }
            .onAppear {
                viewModel.initializeViewIfNeeded()
            }
            .onReceive(Publishers.MergeMany([
                UIApplication.didBecomeActiveNotification,
                UIApplication.significantTimeChangeNotification,
                .NSCalendarDayChanged,
                .NSSystemTimeZoneDidChange
            ].map { NotificationCenter.default.publisher(for: $0) }).receive(on: RunLoop.main)) { _ in
                viewModel.handleCurrentDayChanged()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)
            ) { _ in
                viewModel.handleUserDefaultsDidChange()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: TherapyMetricsManager.changed).receive(on: RunLoop.main)
            ) { _ in
                viewModel.handleTherapyMetricsChanged()
            }
        }
    }

    private var phoneContent: some View {
        VStack(spacing: 8) {
            controlsCard
                .padding(.horizontal, 16)
                .padding(.top, 8)

            quickCarbohydrateButton
                .padding(.horizontal, 16)

            penCalculatorButton
                .padding(.horizontal, 16)

            treatmentList(horizontalPadding: 16)
        }
    }

    private var ipadContent: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 16) {
                controlsCard
                quickCarbohydrateButton
                penCalculatorButton

                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        viewModel.selectedDateDayName,
                        systemImage: "calendar"
                    )
                    .font(.headline)

                    Text("\(viewModel.filteredTreatments.count) \(Texts_TreatmentsView.treatmentsTitle.lowercased())")
                        .font(.subheadline)
                        .foregroundStyle(Color(.colorSecondary))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                Spacer()
            }
            .frame(width: 310)

            treatmentList(horizontalPadding: 0)
                .frame(maxWidth: 920)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var controlsCard: some View {
        TreatmentsControlsCard(viewModel: viewModel)
            .id(topScrollAnchorID)
            .onAppear { showScrollToTopButton = false }
    }

    private var quickCarbohydrateButton: some View {
        let amount = UserDefaults.standard.quickCarbohydrateGrams
        return Button {
            if let amount { onQuickCarbs(amount) }
        } label: {
            HStack {
                Text("🍭 Hurtige kulhydrater")
                Spacer()
                Text(amount.map { "\(GlucoseForecastSettingsInput.displayNumber($0)) g" } ?? "Indstil antal gram")
                    .foregroundStyle(Color(.colorSecondary))
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(amount == nil)
        .accessibilityHint(amount == nil ? "Vælg først antal gram under Hjemskærm-indstillinger" : "Åbner en forudfyldt registrering, som du kan kontrollere før gemning")
    }

    private var penCalculatorButton: some View {
        Button(action: onPenCalculator) {
            HStack {
                Label("Bolusberegner", systemImage: "function")
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color(.colorSecondary))
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func treatmentList(horizontalPadding: CGFloat) -> some View {
        List {
            if !viewModel.filteredTreatments.isEmpty {
                ForEach(Array(viewModel.filteredTreatments.enumerated()), id: \.element.objectID) { index, treatment in
                    treatmentRow(for: treatment)
                        .id(treatment.objectID)
                        .onAppear {
                            if index == 0 {
                                showScrollToTopButton = false
                            } else if index >= scrollToTopButtonThresholdIndex {
                                showScrollToTopButton = true
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !treatment.isHealthKitImported {
                                Button(role: .destructive) {
                                    if treatment.deletionMayLeaveHealthCopy {
                                        pendingLocalDeletion = treatment
                                    } else {
                                        viewModel.deleteTreatment(treatment)
                                    }
                                } label: {
                                    Label(Texts_Common.delete, systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        }
                }
                .listRowBackground(Color(.secondarySystemGroupedBackground))
            } else {
                Text(Texts_TreatmentsView.noTreatmentsToShow)
                    .foregroundStyle(Color(.colorSecondary))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .padding(.horizontal, horizontalPadding)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .confirmationDialog("Slet denne behandling?", isPresented: Binding(
            get: { pendingLocalDeletion != nil },
            set: { if !$0 { pendingLocalDeletion = nil } }
        ), titleVisibility: .visible) {
            Button("Slet behandling", role: .destructive) {
                if let pendingLocalDeletion { viewModel.deleteTreatment(pendingLocalDeletion) }
                pendingLocalDeletion = nil
            }
        } message: {
            Text("Behandlingen slettes først i xDrip. En tidligere eksporteret kopi fjernes derefter fra Sundhed, når adgang er tilgængelig. Se status under Apple Health, hvis fjernelsen afventer eller fejler.")
        }
        .alert("Lagring usikker", isPresented: Binding(
            get: { viewModel.deletionFailureMessage != nil },
            set: { if !$0 { viewModel.deletionFailureMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.deletionFailureMessage = nil }
        } message: {
            Text(viewModel.deletionFailureMessage ?? "Kontrollér behandlingshistorikken.")
        }
    }

    @ViewBuilder private func treatmentRow(for treatment: TreatmentSnapshot) -> some View {
        if treatment.isEditable {
            Button {
                onSelectTreatment(treatment)
            } label: {
                TreatmentRowView(treatment: treatment)
            }
            .buttonStyle(.plain)
        } else {
            TreatmentRowView(treatment: treatment)
        }
    }
}

/// Persistent top controls for date selection and treatment filters.
private struct TreatmentsControlsCard: View {
    @ObservedObject var viewModel: TreatmentsViewModel

    var body: some View {
        VStack(spacing: 0) {
            DatePicker(selection: Binding(get: {
                viewModel.selectedDate
            }, set: { newDate in
                viewModel.selectedDateChanged(newDate)
            }), in: ...latestSelectableDate, displayedComponents: .date) {
                HStack {
                    Text(Texts_BgReadings.date)
                    Spacer()
                    Text(viewModel.selectedDateDayName)
                        .foregroundStyle(Color(.colorSecondary))
                }
            }
            .id(viewModel.datePickerReset)
            .tint(ConstantsAppColors.navigationTint)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()
                .overlay(Color(.separator))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: TreatmentFilterLayout.spacing) {
                    TreatmentFilterChip(
                        systemImage: GlucoseChartTreatmentStyle.bolusSymbol,
                        tintColor: ConstantsGlucoseChart.bolusTreatmentColor,
                        isSelected: viewModel.showBolusTreatments
                    ) {
                        viewModel.toggleBolusFilter()
                    }

                    TreatmentFilterChip(
                        systemImage: GlucoseChartTreatmentStyle.bolusSymbol,
                        tintColor: ConstantsGlucoseChart.bolusTreatmentColor,
                        isSelected: viewModel.showSmallBolusTreatments,
                        isEnabled: viewModel.showBolusTreatments,
                        symbolScale: .medium,
                        symbolFont: .system(size: TreatmentFilterLayout.symbolSize * GlucoseChartTreatmentStyle.smallBolusScale, weight: .regular)
                    ) {
                        viewModel.toggleSmallBolusFilter()
                    }

                    TreatmentFilterChip(
                        systemImage: GlucoseChartTreatmentStyle.carbsSymbol,
                        tintColor: ConstantsGlucoseChart.carbsTreatmentColor,
                        isSelected: viewModel.showCarbsTreatments
                    ) {
                        viewModel.toggleCarbsFilter()
                    }

                    TreatmentFilterChip(
                        systemImage: GlucoseChartTreatmentStyle.bgCheckSymbol,
                        tintColor: ConstantsGlucoseChart.bgCheckTreatmentColorInner,
                        isSelected: viewModel.showBgCheckTreatments
                    ) {
                        viewModel.toggleBgCheckFilter()
                    }

                    TreatmentFilterChip(
                        systemImage: GlucoseChartTreatmentStyle.noteSymbol,
                        tintColor: ConstantsGlucoseChart.noteTreatmentColor,
                        isSelected: viewModel.showNoteTreatments
                    ) {
                        viewModel.toggleNoteFilter()
                    }

                    TreatmentFilterChip(
                        systemImage: TreatmentType.BasalInjection.iconSystemName,
                        tintColor: ConstantsGlucoseChart.basalInjectionTreatmentColor,
                        isSelected: viewModel.showBasalInjectionTreatments
                    ) {
                        viewModel.toggleBasalInjectionFilter()
                    }
                    .accessibilityLabel(Texts_TreatmentsView.basalInjection)

                    if viewModel.showBasalFilter {
                        TreatmentFilterChip(
                            systemImage: "chart.bar.fill",
                            tintColor: ConstantsGlucoseChart.basalTreatmentColor,
                            isSelected: viewModel.showBasalTreatments
                        ) {
                            viewModel.toggleBasalFilter()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    /// Last selectable timestamp for the date-only picker.
    /// This keeps tomorrow disabled without making today's selected value invalid by a few milliseconds.
    private var latestSelectableDate: Date {
        Calendar.current.date(byAdding: DateComponents(day: 1, second: -1), to: Date().toMidnight()) ?? Date()
    }
}

/// One treatment row using the same symbols and units as the glucose chart.
private struct TreatmentRowView: View {
    let treatment: TreatmentSnapshot

    var body: some View {
        HStack(spacing: 12) {
            // Keep equal gaps around the symbol without hidden padding from a fixed time width.
            HStack(spacing: 8) {
                Text(treatment.timeString)
                    .font(.body)
                    .foregroundStyle(treatment.primaryTextColor)
                    .fixedSize(horizontal: true, vertical: false)

                treatment.treatmentType.iconView(size: treatment.iconSize)
                    .opacity(treatment.date > Date() ? 0.5 : 1)
                    .frame(width: 16)

                treatmentTitleView
                    .lineLimit(treatment.treatmentType == .Note ? 2 : 1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .layoutPriority(1)

            if let valueText = treatment.valueText, let unitText = treatment.unitText {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(valueText)
                        .foregroundStyle(Color(.colorSecondary))

                    Text(unitText)
                        .foregroundStyle(Color(.colorTertiary))
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            if treatment.isEditable {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.colorTertiary))
            }
        }
    }

    private var treatmentTitleView: Text {
        var title = Text(treatment.typeText)
            .foregroundColor(Color(.colorPrimary))

        if let secondaryText = treatment.secondaryText {
            let separator = treatment.treatmentType == .Note ? ": " : " "
            title = title + Text(separator + secondaryText) // swiftlint:disable:this shorthand_operator
                .font(.subheadline)
                .foregroundColor(Color(.colorTertiary))
        }

        return title
    }
}

/// Filter sizing for the horizontally scrolling treatment controls.
private enum TreatmentFilterLayout {
    static let diameter: CGFloat = 36
    static let symbolSize: CGFloat = 16
    static let spacing: CGFloat = 6
    static let tapWidth: CGFloat = 40
}

/// Compact circular button used to enable or disable one treatment category.
private struct TreatmentFilterChip: View {
    let systemImage: String
    let tintColor: Color
    let isSelected: Bool
    let isEnabled: Bool
    let symbolScale: Image.Scale
    let symbolFont: Font?
    let action: () -> Void

    init(
        systemImage: String,
        tintColor: Color,
        isSelected: Bool,
        isEnabled: Bool = true,
        symbolScale: Image.Scale = .medium,
        symbolFont: Font? = nil,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.tintColor = tintColor
        self.isSelected = isSelected
        self.isEnabled = isEnabled
        self.symbolScale = symbolScale
        self.symbolFont = symbolFont
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: displayAsSelected ? systemImage : systemImage.replacingOccurrences(of: ".fill", with: ""))
                    .font(symbolFont ?? .system(size: TreatmentFilterLayout.symbolSize))
                    .imageScale(symbolScale)
                    .frame(width: TreatmentFilterLayout.diameter, height: TreatmentFilterLayout.diameter)
                    .background(chipBackgroundColor)
                    .foregroundStyle(chipForegroundColor)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(chipBorderColor.opacity(isEnabled || isSelected ? 1.0 : 0.6), lineWidth: 1)
                    )

                if displayAsSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.black, .green)
                        .offset(x: 2, y: 2)
                }
            }
            // Keep extra tappable space around each circle.
            .frame(width: TreatmentFilterLayout.tapWidth, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var displayAsSelected: Bool {
        isEnabled && isSelected
    }

    private var chipBackgroundColor: Color {
        if displayAsSelected {
            return tintColor.opacity(0.22)
        }

        return Color(white: 0.14)
    }

    private var chipForegroundColor: Color {
        if displayAsSelected {
            return tintColor
        }

        return Color(.colorSecondary)
    }

    private var chipBorderColor: Color {
        if displayAsSelected {
            return tintColor
        }

        return Color(.colorSecondary)
    }
}
