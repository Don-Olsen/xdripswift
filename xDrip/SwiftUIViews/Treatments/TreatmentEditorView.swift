//
//  TreatmentEditorView.swift
//  xdrip
//
//  Created by Paul Plant on 18/6/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation
import SwiftUI

/// Presents treatment type selection for new entries, or opens an existing entry directly.
struct TreatmentEditorContainerView: View {
    let coreDataManager: CoreDataManager
    let editorState: TreatmentEditorState
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            switch editorState {
            case .add:
                List {
                    Section(Texts_TreatmentsView.treatmentType) {
                        ForEach(TreatmentEditorViewModel.supportedTreatmentTypes, id: \.rawValue) { treatmentType in
                            NavigationLink {
                                TreatmentEditorScreen(
                                    coreDataManager: coreDataManager,
                                    treatmentToEdit: nil,
                                    initialType: treatmentType,
                                    onSave: onSave
                                )
                            } label: {
                                HStack(spacing: 12) {
                                    treatmentType.iconView()
                                        .frame(width: 24)
                                        .accessibilityHidden(true)
                                    Text(treatmentType.asString())
                                        .foregroundStyle(ConstantsAppColors.rowTitleText)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .ipadReadableContentWidth(720)
                .navigationTitle(Texts_TreatmentsView.addTreatmentTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(Texts_Common.Cancel, action: onCancel)
                            .foregroundStyle(ConstantsAppColors.toolbarNeutralAction)
                    }
                }
            case .quickCarbs(let grams):
                TreatmentEditorScreen(
                    coreDataManager: coreDataManager,
                    treatmentToEdit: nil,
                    initialType: .Carbs,
                    quickCarbohydrateGrams: grams,
                    onSave: onSave,
                    onCancel: onCancel
                )
            case .basal:
                TreatmentEditorScreen(
                    coreDataManager: coreDataManager,
                    treatmentToEdit: nil,
                    initialType: .BasalInjection,
                    onSave: onSave,
                    onCancel: onCancel
                )
            case .edit(let treatment):
                // A stale or deleted row must not open an empty editor in add mode.
                if let entry = TreatmentEntryAccessor(coreDataManager: coreDataManager)
                    .getTreatment(objectID: treatment.objectID), !entry.isDeleted, !entry.treatmentdeleted {
                    TreatmentEditorScreen(
                        coreDataManager: coreDataManager,
                        treatmentToEdit: entry,
                        onSave: onSave,
                        onCancel: onCancel
                    )
                } else {
                    Text(Texts_TreatmentsView.noTreatmentsToShow)
                        .navigationTitle(Texts_TreatmentsView.editTreatmentTitle)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button(Texts_Common.Cancel, action: onCancel)
                            }
                        }
                }
            }
        }
        .colorScheme(.dark)
    }
}

/// Owns a separate draft for each entry form, so choosing another type starts fresh.
private struct TreatmentEditorScreen: View {
    @StateObject private var viewModel: TreatmentEditorViewModel
    private enum ConfirmationAction { case confirmMeal, cancelMeal, deleteWithHealthWarning }
    @State private var pendingConfirmation: ConfirmationAction?

    let onSave: () -> Void
    let onCancel: (() -> Void)?

    init(
        coreDataManager: CoreDataManager,
        treatmentToEdit: TreatmentEntry?,
        initialType: TreatmentType = .Carbs,
        quickCarbohydrateGrams: Double? = nil,
        onSave: @escaping () -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: TreatmentEditorViewModel(
            coreDataManager: coreDataManager,
            treatmentToEdit: treatmentToEdit,
            initialType: initialType,
            quickCarbohydrateGrams: quickCarbohydrateGrams
        ))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        TreatmentEditorView(
            viewModel: viewModel,
            onDelete: {
                if viewModel.deletionMayLeaveHealthCopy {
                    pendingConfirmation = .deleteWithHealthWarning
                } else if viewModel.deleteTreatment() {
                    onSave()
                }
            },
            onConfirmMeal: { pendingConfirmation = .confirmMeal },
            onCancelMeal: { pendingConfirmation = .cancelMeal }
        )
        .navigationTitle(viewModel.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onCancel = onCancel {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(Texts_Common.Cancel, action: onCancel)
                        .foregroundStyle(ConstantsAppColors.toolbarNeutralAction)
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button(Texts_TreatmentsView.saveTreatment) {
                    if viewModel.saveTreatment() {
                        onSave()
                    }
                }
                .tint(ConstantsAppColors.toolbarAction)
                .disabled(!viewModel.canSaveTreatment)
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: Binding(
            get: { pendingConfirmation != nil },
            set: { if !$0 { pendingConfirmation = nil } }
        ), titleVisibility: .visible) {
            switch pendingConfirmation {
            case .confirmMeal:
                Button("Jeg spiser nu") {
                    if viewModel.confirmPlannedMealNow() { onSave() }
                }
                if viewModel.canConfirmWithSelectedDate {
                    Button("Bekræft valgt tidspunkt") {
                        if viewModel.confirmPlannedMeal() { onSave() }
                    }
                }
                Button("Vælg nyt tidspunkt") { }
            case .cancelMeal:
                Button("Annuller planen", role: .destructive) {
                    if viewModel.cancelPlannedMeal() { onSave() }
                }
            case .deleteWithHealthWarning:
                Button("Slet behandling", role: .destructive) {
                    if viewModel.deleteTreatment() { onSave() }
                }
            case .none:
                EmptyView()
            }
        } message: {
            switch pendingConfirmation {
            case .confirmMeal:
                Text("Bekræft, at maden er spist. Det planlagte tidspunkt er ikke automatisk spisetidspunktet. Ret dato og klokkeslæt ovenfor ved behov.")
            case .deleteWithHealthWarning:
                Text("Behandlingen slettes først i xDrip. En tidligere eksporteret kopi fjernes derefter fra Sundhed, når adgang er tilgængelig. Se status under Apple Health, hvis fjernelsen afventer eller fejler.")
            case .cancelMeal:
                Text("Kun måltidsplanen annulleres. Den registrerede insulin bevares.")
            case .none:
                EmptyView()
            }
        }
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .confirmMeal: return "Har du spist dette måltid?"
        case .cancelMeal: return "Annuller planlagt måltid?"
        case .deleteWithHealthWarning: return "Slet denne behandling?"
        case .none: return "Bekræft handling"
        }
    }
}

/// Native form used to add or edit a treatment.
struct TreatmentEditorView: View {
    // MARK: - private properties

    @ObservedObject var viewModel: TreatmentEditorViewModel

    let onDelete: (() -> Void)?
    var onConfirmMeal: (() -> Void)?
    var onCancelMeal: (() -> Void)?

    // MARK: - SwiftUI views

    var body: some View {
        Form {
            if viewModel.localSaveGateState != .ready {
                Section {
                    Text(viewModel.localSaveGateState.message)
                        .foregroundStyle(.orange)
                    if viewModel.localSaveGateState == .foundPriorEntry ||
                        viewModel.localSaveGateState == .noLocalEntryHealthUncertain ||
                        viewModel.localSaveGateState == .uncertainMutationAfterRestart {
                        Button("Jeg har kontrolleret xDrip og Sundhed") {
                            viewModel.acknowledgePreviouslyFoundTreatment()
                        }
                    }
                }
            }
            Section(footer: editorFooterView()) {
                HStack {
                    Text(Texts_TreatmentsView.type)
                    Spacer()
                    HStack(spacing: 8) {
                        viewModel.selectedType.iconView()
                            .accessibilityHidden(true)
                        Text(viewModel.selectedType.asString())
                            .foregroundStyle(Color(.colorSecondary))
                    }
                }

                DatePicker(selection: $viewModel.selectedDate, in: ...viewModel.latestSelectableDate, displayedComponents: [.date, .hourAndMinute]) {
                    Text(Texts_BgReadings.date)
                        .foregroundStyle(Color(.colorPrimary))
                }
                .foregroundStyle(Color(.colorSecondary))

                if viewModel.showsNumericValueEditor {
                    LabeledContent(Texts_TreatmentsView.value) {
                        HStack(spacing: 6) {
                            TextField(viewModel.valuePlaceholder, text: $viewModel.enteredValue)
                                .keyboardType(viewModel.selectedType == .BasalInjection ? .numberPad : .decimalPad)
                                .multilineTextAlignment(.trailing)
                                .textFieldStyle(.plain)
                                .foregroundStyle(Color(.colorSecondary))
                                .frame(minWidth: 72, maxWidth: 96, alignment: .trailing)

                            Text(viewModel.unitText)
                                .foregroundStyle(Color(.colorTertiary))
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }

                if viewModel.selectedType == .Carbs {
                    Picker("Madtype", selection: $viewModel.selectedMealKind) {
                        Text("🍭 Hurtig · 30 min").tag(TreatmentMealKind.fast)
                        Text("🌮 Normal · 240 min").tag(TreatmentMealKind.normal)
                        Text("🍕 Fed/langsom · 300 min").tag(TreatmentMealKind.slow)
                    }
                    Text("Valgt optagelse: \(Int(viewModel.selectedCarbohydrateDurationMinutes)) minutter")
                        .font(.footnote)
                        .foregroundStyle(Color(.colorSecondary))

                    if viewModel.isAddMode {
                        Toggle("Planlæg til senere", isOn: $viewModel.isPlanningNewMeal)
                        if viewModel.isPlanningNewMeal {
                            Text("Tæller først som spist, når du bekræfter. Planen kan højst ligge 60 minutter fremme.")
                                .font(.footnote)
                                .foregroundStyle(Color(.colorSecondary))
                        }
                    } else if viewModel.isExistingPlannedMeal {
                        Label("Planlagt – endnu ikke spist", systemImage: "clock")
                            .foregroundStyle(.orange)
                    } else if viewModel.isExistingCancelledMeal {
                        Label("Annulleret plan", systemImage: "xmark.circle")
                            .foregroundStyle(Color(.colorSecondary))
                    }
                }

                if viewModel.selectedType == .BasalInjection {
                    LabeledContent(Texts_TreatmentsView.insulinDescription) {
                        TextField(Texts_TreatmentsView.insulinDescriptionPlaceholder, text: $viewModel.enteredInsulinDescription)
                            .multilineTextAlignment(.trailing)
                            .textFieldStyle(.plain)
                            .foregroundStyle(Color(.colorSecondary))
                    }
                }

                if viewModel.showsNotesEditor {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Texts_TreatmentsView.notes)
                        TextEditor(text: $viewModel.enteredNotesValue)
                            .frame(minHeight: 120)
                            .padding(6)
                            .background(ConstantsAppColors.groupedBackground)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(Color(.colorSecondary))
                            .overlay(alignment: .topLeading) {
                                if viewModel.enteredNotesValue.isEmpty {
                                    Text(Texts_TreatmentsView.notePlaceholder)
                                        .foregroundStyle(Color(.placeholderText))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 14)
                                }
                            }
                    }
                }
            }

            Section {
                LabeledContent(Texts_TreatmentsView.enteredBy) {
                    TextField(Texts_Common.unknown, text: $viewModel.enteredByValue)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.plain)
                        .foregroundStyle(Color(.colorSecondary))
                        .frame(minWidth: 120, maxWidth: 220, alignment: .trailing)
                }
            }

            if let onDelete = onDelete, !viewModel.isAddMode {
                if viewModel.isExistingPlannedMeal {
                    Section {
                        Button("Bekræft spist", action: { onConfirmMeal?() })
                        Button("Annuller plan", role: .destructive, action: { onCancelMeal?() })
                    } footer: {
                        Text("Mængde og tidspunkt ovenfor kan rettes inden bekræftelse.")
                    }
                }
                Section {
                    Button(role: .destructive, action: onDelete) {
                        Text(Texts_TreatmentsView.deleteTreatment)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .colorScheme(.dark)
        .ipadReadableContentWidth(720)
        .alert(item: $viewModel.alertMessage) { message in
            Alert(
                title: Text(message.title),
                message: Text(message.message),
                dismissButton: .default(Text(Texts_Common.Ok))
            )
        }
        .onAppear {
            viewModel.validateSelectedDateIfNeeded()
        }
        .onChange(of: viewModel.selectedType) { _ in
            viewModel.validateSelectedDateIfNeeded()
        }
        .onChange(of: viewModel.selectedDate) { _ in
            viewModel.validateSelectedDateIfNeeded()
        }
        .onChange(of: viewModel.isPlanningNewMeal) { _ in
            viewModel.validateSelectedDateIfNeeded()
        }
    }

    @ViewBuilder private func editorFooterView() -> some View {
        if viewModel.selectedType == .BasalInjection, viewModel.didPrefillBasalInjection {
            Text(Texts_TreatmentsView.basalInjectionCopiedFooter)
        }

        if let helperText = viewModel.helperText {
            Text(helperText)
                .foregroundStyle(Color(.systemRed))
        }
    }
}

/// A pen-only calculator. Suggestions are copied explicitly; Log records the user's entry.
/// Read-only wording for the calculation's COB evidence. Home keeps showing curve COB.
enum PenDoseCOBPresentation {
    static func proposalText(_ evidence: PenCOBEvidence) -> String {
        let used = PenDoseDisplayFormatter.carbs(evidence.usedGrams)
        if evidence.estimatedGrams != nil {
            return "COB i regnestykket: \(used) g · højst kurve-COB efter CGM-estimat"
        }
        let reason = evidence.fallbackReason.map { " (\(fallbackText($0)))" } ?? ""
        return "COB i regnestykket: \(used) g · kurve\(reason)"
    }

    static func fallbackText(_ reason: PenCOBFallbackReason) -> String {
        switch reason {
        case .noCurrentMeal: return "intet aktivt måltid"
        case .manualOrUntrendedGlucose: return "ingen gyldig CGM-trend"
        case .missingHistory: return "manglende glukosehistorik"
        case .incompleteTreatmentHistory: return "ufuldstændig behandlingshistorik"
        case .changedInputs: return "ændrede beregningsdata"
        case .historicalProfileUnknown: return "ukendt tidligere profil"
        case .missingTreatmentIdentity: return "manglende behandlingsidentitet"
        case .duplicateTreatmentIdentity: return "tvetydig behandlingsidentitet"
        case .sensorMismatch: return "sensor skiftet"
        case .historyGap: return "hul i glukosehistorikken"
        case .invalidHistory: return "ugyldig glukosehistorik"
        case .oscillatingSignal: return "svingende signal uden sikker optagelse"
        case .insufficientIntervals: return "for få sammenhængende målinger"
        }
    }
}

struct PenDoseCalculatorScreen: View {
    @StateObject private var viewModel: PenDoseCalculatorViewModel
    @State private var information: PenDoseInformationSnapshot?
    @State private var showsLogConfirmation = false
    @State private var showsReminderWarning = false
    @State private var didSetInitialFocus = false
    @FocusState private var focusedField: InputField?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let coreDataManager: CoreDataManager
    let onSave: () -> Void
    let onCancel: () -> Void

    private enum InputField: Hashable { case carbohydrates, insulin, glucose }

    init(coreDataManager: CoreDataManager, reminderMealUUID: String? = nil,
         onSave: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.coreDataManager = coreDataManager
        self.onSave = onSave
        self.onCancel = onCancel
        _viewModel = StateObject(wrappedValue: PenDoseCalculatorViewModel(
            coreDataManager: coreDataManager, reminderMealUUID: reminderMealUUID,
            automaticallyFillMealDose: true))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    storageStatus
                    glucoseCard
                    if viewModel.reminderMealUUID == nil {
                        mealCard
                    } else {
                        card {
                            Label("Ny beregning efter måltidet", systemImage: "arrow.clockwise")
                                .font(.headline)
                            Text("Maden er allerede logget og indgår via aktuelt COB. Påmindelsen lover ingen restdosis.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    insulinCard
                    calculationStatus
                }
                .padding()
                .disabled(viewModel.isSaving)
            }
            .background(Color(.systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { logBar }
            .navigationTitle("Bolusberegner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Luk", action: onCancel).disabled(viewModel.isSaving)
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    NavigationLink {
                        PenDoseSettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Doseringsprofil")
                    .disabled(viewModel.isSaving)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Færdig") { focusedField = nil }
                }
            }
            .sheet(item: $information) { snapshot in
                PenDoseInformationView(snapshot: snapshot)
            }
            .alert(logConfirmationTitle, isPresented: Binding(
                get: { showsLogConfirmation && viewModel.confirmationDraft != nil },
                set: { showsLogConfirmation = $0 }
            )) {
                Button("Annuller", role: .cancel) { viewModel.cancelLogConfirmation() }
                Button("Log alligevel") { saveConfirmedDraft() }
            } message: {
                if let draft = viewModel.confirmationDraft {
                    Text("Registrér kun insulin, du faktisk har taget. \(draft.plannedDate.map { "Du planlægger samtidig \(PenDoseDisplayFormatter.carbs(draft.carbohydrateGrams)) g kulhydrat til \($0.formatted(date: .omitted, time: .shortened))." } ?? "")")
                }
            }
            .onAppear { viewModel.start() }
            .onDisappear { viewModel.stop() }
            .task {
                guard !didSetInitialFocus else { return }
                didSetInitialFocus = true
                await Task.yield()
                focusedField = viewModel.reminderMealUUID == nil ? .carbohydrates : .insulin
            }
            .onReceive(NotificationCenter.default.publisher(for: TherapyMetricsManager.changed)) { _ in
                viewModel.scheduleCalculation()
            }
            .onReceive(NotificationCenter.default.publisher(for: .penDoseSettingsChanged)) { _ in
                viewModel.scheduleCalculation()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                viewModel.scheduleCalculation()
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name(
                ConstantsNotifications.NotificationIdentifierForBgPostProcessing.bgPostProcessingDidUpdate))) { _ in
                viewModel.scheduleCalculation()
            }
            .task {
                // Keep the visible age and fixed meal deadline current while this sheet is open.
                // A view-owned task survives ordinary SwiftUI redraws and is cancelled on close.
                viewModel.refreshClock()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    guard !Task.isCancelled else { break }
                    viewModel.refreshClock()
                }
            }
        }
        .colorScheme(.dark)
    }

    @ViewBuilder private var storageStatus: some View {
        if viewModel.storageGateState != .ready {
            card {
                Label(viewModel.storageGateState.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if viewModel.storageGateState == .foundPriorEntry ||
                    viewModel.storageGateState == .noLocalEntryHealthUncertain ||
                    viewModel.storageGateState == .uncertainMutationAfterRestart {
                    Button("Jeg har kontrolleret xDrip og Sundhed") {
                        viewModel.acknowledgePreviouslyFoundTreatment()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var glucoseCard: some View {
        card {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { metricChips }
                VStack(alignment: .leading, spacing: 6) { metricChips }
            }

            if viewModel.glucoseChoice == .manual {
                input("Blodsukker", unit: viewModel.glucoseUnitIsMgdl ? "mg/dL" : "mmol/L",
                      text: $viewModel.manualGlucoseText, field: .glucose)
                DatePicker("Målt kl.", selection: $viewModel.manualGlucoseDate,
                           in: Date().addingTimeInterval(-24 * 60 * 60)...Date(),
                           displayedComponents: [.date, .hourAndMinute])
                Text("Manuel · uden trend").font(.footnote).foregroundStyle(.orange)
            }

            if let message = viewModel.glucoseStatusMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).foregroundStyle(.orange)
            }
            if viewModel.glucoseChoice == .currentCGM,
               let displayedGlucose = viewModel.displayedGlucoseValueMgdl,
               viewModel.glucoseStatusMessage != nil {
                let displayedValue = PenDoseDisplayFormatter.glucose(displayedGlucose,
                    mgdl: viewModel.glucoseUnitIsMgdl)
                let fallbackTitle = viewModel.glucoseStatusMessage?.hasPrefix("Seneste måling") == true
                    ? "Brug \(displayedValue)" : "Brug uden trend"
                Button(fallbackTitle) {
                    focusedField = nil
                    viewModel.selectDisplayedCGMWithoutTrend()
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Fastholder målingens værdi, tidspunkt og sensor. Beregner uden trend.")
            }
            if viewModel.glucoseChoice == .confirmStaleCGM {
                Text("Valgt CGM · uden trend. Målt \(viewModel.displayedGlucoseDate?.formatted(date: .omitted, time: .shortened) ?? "—").")
                    .font(.footnote).foregroundStyle(.orange)
            }
            HStack {
                if viewModel.glucoseChoice != .currentCGM {
                    Button("Brug CGM") { viewModel.selectCurrentCGM() }
                }
                if viewModel.glucoseChoice != .manual {
                    Button("Indtast selv") {
                        viewModel.selectManual()
                        focusedField = .glucose
                    }
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var mealCard: some View {
        card {
            input("Kulhydrater", unit: "g", text: $viewModel.carbohydratesText, field: .carbohydrates)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 150 : 95))],
                      spacing: 8) {
                chip("🍭 Hurtig", selected: viewModel.mealKind == .fast) { viewModel.mealKind = .fast }
                chip("🌮 Normal", selected: viewModel.mealKind == .normal) { viewModel.mealKind = .normal }
                chip("🍕 Langsom", selected: viewModel.mealKind == .slow) { viewModel.mealKind = .slow }
            }
            Text("Optagelsestid · \(Int(viewModel.mealKind.durationMinutes)) min")
                .font(.footnote).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    Text("Spiser")
                    Spacer(minLength: 0)
                    mealTimingControls
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Spiser")
                    HStack(spacing: 10) { mealTimingControls }
                }
            }
            if viewModel.isPlannedMeal {
                if viewModel.expiredPlan {
                    Label("Spisetiden er passeret", systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                    ViewThatFits(in: .horizontal) {
                        HStack { expiredPlanActions }
                        VStack(alignment: .leading) { expiredPlanActions }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text("Kl. \(viewModel.plannedDate.formatted(date: .omitted, time: .shortened)). Maden tæller først, når du bekræfter, at den er spist.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var expiredPlanActions: some View {
        Button("Spis nu") { viewModel.resolveExpiredPlanEatNow() }
        Button("Vælg ny tid") { viewModel.resolveExpiredPlanNewTime() }
    }

    @ViewBuilder private var mealTimingControls: some View {
        Button { viewModel.shiftPlannedMeal(byMinutes: -5) } label: {
            Image(systemName: "minus").frame(minWidth: 24, minHeight: 24)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Spisetid fem minutter tidligere")
        Text(viewModel.isPlannedMeal
             ? "Om \(max(0, Int((viewModel.plannedDate.timeIntervalSince(viewModel.currentTime) / 60).rounded()))) min"
             : "Nu")
            .font(.subheadline.weight(.medium)).monospacedDigit()
        Button { viewModel.shiftPlannedMeal(byMinutes: 5) } label: {
            Image(systemName: "plus").frame(minWidth: 24, minHeight: 24)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Spisetid fem minutter senere")
    }

    private var insulinCard: some View {
        card {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Insulin").font(.headline)
                    Spacer()
                    recommendation
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Insulin").font(.headline)
                    recommendation
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("0,0", text: $viewModel.insulinToLogText)
                    .keyboardType(.decimalPad).font(.largeTitle.weight(.semibold))
                    .monospacedDigit().focused($focusedField, equals: .insulin)
                    .accessibilityLabel("Insulin, enheder")
                Text("E").font(.title3).foregroundStyle(.secondary)
            }
            if viewModel.isReviewCurrent,
               let evidence = viewModel.calculation?.cobEvidence {
                Text(PenDoseCOBPresentation.proposalText(evidence))
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if viewModel.usesAutomaticMealDose {
                Text("Forslaget udfyldes automatisk. Du kan rette mængden før Log.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("Log kun insulin, du faktisk har taget. Appen giver aldrig insulin.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var recommendation: some View {
        HStack(spacing: 6) {
            Text("Anbefalet").font(.subheadline).foregroundStyle(.secondary)
            Button {
                viewModel.copySuggestion()
                focusedField = .insulin
            } label: {
                if viewModel.isCalculating {
                    ProgressView().accessibilityLabel("Beregner forslag")
                } else if suggestionIsBlocked {
                    Text("0,0 E · blokeret").foregroundStyle(.red)
                } else if let suggestion = viewModel.suggestedUnits {
                    Text("\(PenDoseDisplayFormatter.insulinInput(suggestion)) E").monospacedDigit()
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .disabled(viewModel.suggestedUnits == nil || !viewModel.isReviewCurrent || suggestionIsBlocked)
            .accessibilityLabel("Kopiér anbefalet insulin")
            .accessibilityHint("Kopierer forslaget til insulin. Du kan ændre mængden før Log.")
            Button {
                focusedField = nil
                if let details = viewModel.calculationDetails {
                    information = PenDoseInformationSnapshot(details: details,
                        glucoseUnitIsMgdl: viewModel.glucoseUnitIsMgdl)
                }
            } label: { Image(systemName: "info.circle") }
            .disabled(viewModel.calculationDetails == nil)
            .accessibilityLabel("Se beregningens grundlag")
        }
    }

    private var suggestionIsBlocked: Bool {
        guard viewModel.isReviewCurrent else { return false }
        switch viewModel.calculation?.safety {
        case .blockedCurrentLow, .blockedForecastLow: return true
        default: return false
        }
    }

    @ViewBuilder private var metricChips: some View {
        let details = viewModel.isReviewCurrent ? viewModel.calculationDetails : nil
        let measuredAt = viewModel.glucoseChoice == .manual
            ? viewModel.manualGlucoseDate : viewModel.displayedGlucoseDate
        let age = measuredAt.map {
            "\(max(0, Int(viewModel.currentTime.timeIntervalSince($0) / 60)))m"
        } ?? "—"
        let source = viewModel.glucoseChoice == .manual ? "Manuel" :
            viewModel.glucoseChoice == .confirmStaleCGM ? "Valgt CGM" : "CGM"
        let trendUnits = details?.calculation.lines?.trendUnits
        let trend = viewModel.glucoseChoice != .currentCGM || trendUnits == nil ||
            viewModel.glucoseStatusMessage != nil ? "—" : (trendUnits! > 0 ? "↑" : trendUnits! < 0 ? "↓" : "→")
        let glucose = viewModel.glucoseChoice == .manual
            ? details?.glucoseMgdl : viewModel.displayedGlucoseValueMgdl
        let value = glucose.map { PenDoseDisplayFormatter.glucose($0, mgdl: viewModel.glucoseUnitIsMgdl) } ?? "—"
        metricChip("\(value) \(trend) · \(age)")
            .accessibilityLabel("\(source), \(value), \(age), ændring \(trend)")
        metricChip("IOB \(details.map { PenDoseDisplayFormatter.insulin($0.iobUnits) } ?? "—") E")
        metricChip("COB-kurve \(details.map { PenDoseDisplayFormatter.carbs($0.curveCOBGrams) } ?? "—") g")
    }

    private func metricChip(_ text: String) -> some View {
        Text(text).font(.caption).monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color(.tertiarySystemGroupedBackground), in: Capsule())
    }

    @ViewBuilder private var calculationStatus: some View {
        if !viewModel.profile.isConfirmed {
            card {
                Label("Bekræft din doseringsprofil", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                NavigationLink("Kontrollér profil") { PenDoseSettingsView() }
                    .buttonStyle(.bordered)
            }
        } else if let message = viewModel.statusMessage {
            card {
                Label(message, systemImage: statusIcon)
                    .foregroundStyle(statusColor)
                retryButton
            }
        } else if let calculation = viewModel.calculation, viewModel.isReviewCurrent,
                  let safety = calculation.safety {
            if case .checked = safety {
                EmptyView()
            } else {
                card {
                    Label(safetyMessage(safety), systemImage: statusIcon)
                        .foregroundStyle(statusColor)
                    if case .forecastUnchecked = safety { retryButton }
                    if case .eatFirstForecastUnchecked = safety { retryButton }
                }
            }
        }
    }

    private var logConfirmationTitle: String {
        guard let draft = viewModel.confirmationDraft else { return "Log insulin alligevel?" }
        return "Log \(PenDoseDisplayFormatter.insulinInput(draft.insulinUnits)) E alligevel?"
    }

    private var retryButton: some View {
        Button("Prøv igen") {
            focusedField = nil
            Task { await viewModel.calculate() }
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.isCalculating || viewModel.isSaving)
    }

    private var statusColor: Color {
        switch viewModel.calculation?.safety {
        case .blockedCurrentLow, .blockedForecastLow: return .red
        case .checked: return viewModel.statusMessage == nil ? .secondary : .orange
        default: return .orange
        }
    }

    private var statusIcon: String {
        if case .checked = viewModel.calculation?.safety, viewModel.statusMessage == nil {
            return "checkmark.shield"
        }
        return "exclamationmark.triangle.fill"
    }

    private func safetyMessage(_ safety: PenDoseSafetyState) -> String {
        PenDoseCalculatorViewModel.safetyMessage(safety)
    }

    private var logBar: some View {
        VStack(spacing: 8) {
            if let message = viewModel.logValidationMessage {
                Text(message).font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                focusedField = nil
                showsLogConfirmation = viewModel.requestLog()
                if !showsLogConfirmation, viewModel.confirmationDraft != nil {
                    saveConfirmedDraft()
                }
            } label: {
                HStack(spacing: 10) {
                    if viewModel.isSaving { ProgressView().tint(.white) }
                    Text(viewModel.logButtonTitle).font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canLog || viewModel.isSaving)
        }
        .padding(.horizontal).padding(.vertical, 12)
        .background(.bar)
        .alert("Behandlingen er gemt", isPresented: $showsReminderWarning) {
            Button("OK", action: onSave)
        } message: {
            Text(viewModel.postSaveReminderWarning ?? "Påmindelsen kunne ikke oprettes.")
        }
    }

    private func saveConfirmedDraft() {
        Task {
            if await viewModel.confirmLog() {
                if viewModel.postSaveReminderWarning != nil {
                    showsReminderWarning = true
                } else {
                    onSave()
                }
            }
        }
    }

    private func input(_ title: String, unit: String, text: Binding<String>, field: InputField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                TextField("0", text: text)
                    .keyboardType(.decimalPad)
                    .font(.largeTitle.weight(.semibold))
                    .monospacedDigit()
                    .focused($focusedField, equals: field)
                    .accessibilityLabel("\(title), \(unit)")
                Text(unit).font(.title3).foregroundStyle(.secondary)
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10).padding(.vertical, 10)
                .background(selected ? Color.accentColor.opacity(0.24) : Color(.tertiarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

/// A copy made at sheet presentation, independent of subsequent readings, drafts and settings.
private struct PenDoseInformationSnapshot: Identifiable {
    let id = UUID()
    let details: PenDoseCalculationDetails
    let glucoseUnitIsMgdl: Bool
}

private struct PenDoseInformationView: View {
    let snapshot: PenDoseInformationSnapshot
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Beregnet \(snapshot.details.calculatedAt.formatted(date: .abbreviated, time: .shortened))")
                    Text("Dette er et fast øjebliksbillede af beregningen. Nye målinger og ændrede felter opdaterer ikke dette ark.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Grundlag") {
                    if let glucose = snapshot.details.glucoseMgdl {
                        detail("Blodsukker", PenDoseDisplayFormatter.glucose(
                            glucose, mgdl: snapshot.glucoseUnitIsMgdl))
                    }
                    if let measuredAt = snapshot.details.glucoseMeasuredAt {
                        detail("Målt", measuredAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    detail("Aktiv insulin · IOB", "\(PenDoseDisplayFormatter.insulin(snapshot.details.iobUnits)) E")
                    detail("COB fra kurve · som på Home", "\(PenDoseDisplayFormatter.carbs(snapshot.details.curveCOBGrams)) g")
                    if let estimated = snapshot.details.estimatedCOBGrams {
                        detail("CGM-estimeret COB · ikke målt", "\(PenDoseDisplayFormatter.carbs(estimated)) g")
                    }
                    detail("COB brugt i regnestykket", "\(PenDoseDisplayFormatter.carbs(snapshot.details.cobGrams)) g")
                    if let reason = snapshot.details.cobFallbackReason {
                        Text("CGM-estimatet blev ikke brugt: \(PenDoseCOBPresentation.fallbackText(reason)). Kurve-COB blev brugt.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Home viser fortsat COB fra behandlingskurven. CGM-estimatet er kun et usikkert alternativ i dette dosisforslag.")
                        .font(.footnote).foregroundStyle(.secondary)
                    detail("Nye kulhydrater i regnestykket", "\(PenDoseDisplayFormatter.carbs(snapshot.details.newCarbsGrams)) g")
                }
                Section("Profil ved beregningen") {
                    detail("Kulhydratfaktor", "\(PenDoseDisplayFormatter.profileInput(snapshot.details.carbohydrateRatio)) g/E")
                    detail("Målblodsukker", "\(glucoseNumber(snapshot.details.targetMmol)) \(glucoseUnit)")
                    detail("Korrektionsfaktor", "\(glucoseNumber(snapshot.details.correctionMmolPerUnit)) \(glucoseUnit) pr. E")
                    detail("Pennens trin", "\(PenDoseDisplayFormatter.profileInput(snapshot.details.penStepUnits)) E")
                    detail("Maksimalt forslag", "\(PenDoseDisplayFormatter.profileInput(snapshot.details.maximumUnits)) E")
                }
                if let lines = snapshot.details.calculation.lines {
                    Section("Regnestykke") {
                        detail("Kulhydratregning",
                               "(\(PenDoseDisplayFormatter.carbs(snapshot.details.cobGrams)) + \(PenDoseDisplayFormatter.carbs(snapshot.details.newCarbsGrams))) g ÷ \(PenDoseDisplayFormatter.number(snapshot.details.carbohydrateRatio, maxDecimals: 3)) g/E")
                        dose("COB + nye kulhydrater", lines.carbohydratesUnits)
                        if let glucose = snapshot.details.glucoseMgdl {
                            detail("Korrektionsregning",
                                   "(\(glucoseNumber(glucose / PenBolusCalculator.mgdlPerMmol)) − \(glucoseNumber(snapshot.details.targetMmol))) \(glucoseUnit) ÷ \(glucoseNumber(snapshot.details.correctionMmolPerUnit)) \(glucoseUnit)/E")
                        }
                        dose("Korrektion", lines.correctionUnits)
                        detail("Ændringsregning",
                               "\(glucoseNumber(lines.trendUnits * snapshot.details.correctionMmolPerUnit)) \(glucoseUnit) ÷ \(glucoseNumber(snapshot.details.correctionMmolPerUnit)) \(glucoseUnit)/E")
                        dose("20-minutters ændring", lines.trendUnits)
                        dose("Aktiv insulin, fratrukket", -lines.insulinOnBoardUnits)
                        dose("Sum før grænser og afrunding", lines.rawUnits)
                        if let suggestion = snapshot.details.calculation.suggestedUnits {
                            dose("Efter grænser og nedrunding", suggestion)
                        }
                        if snapshot.details.calculation.trendWasIntentionallyZero {
                            Text("Ændringsleddet er 0 ved manuelt eller bekræftet gammelt blodsukker.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Text("Forslaget begrænses til 0–maksimum og rundes ned til pennens trin.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let percentage = snapshot.details.pizzaPercentageNow {
                    Section("🍕 Fordeling") {
                        detail("Andel nu", "\(percentage) %")
                        if let minutes = snapshot.details.pizzaReminderMinutes {
                            detail("Ny beregning efter", "\(minutes) min")
                        }
                        Text("Påmindelsen lover ingen restdosis.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Resultat") {
                    if let suggestion = snapshot.details.suggestedNowUnits {
                        dose("Forslag nu", suggestion)
                    } else {
                        Text("Intet insulinforslag på dette grundlag.")
                    }
                    if let minimum = snapshot.details.calculation.forecastMinimumMgdl {
                        detail("Laveste prognoseværdi", PenDoseDisplayFormatter.glucose(
                            minimum, mgdl: snapshot.glucoseUnitIsMgdl))
                    }
                    Text("Viste mellemregninger er afrundede. Dosis afrundes ned til dit pen-trin. Prognosetjekket bygger på allerede registrerede behandlinger og simulerer ikke den nye dosis. Appen giver aldrig insulin.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Beregning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Færdig") { dismiss() } }
            }
        }
        .colorScheme(.dark)
    }

    private func dose(_ title: String, _ units: Double) -> some View {
        detail(title, "\(PenDoseDisplayFormatter.number(units, maxDecimals: 3)) E")
    }

    private var glucoseUnit: String { snapshot.glucoseUnitIsMgdl ? "mg/dL" : "mmol/L" }

    private func glucoseNumber(_ mmol: Double) -> String {
        PenDoseDisplayFormatter.profileInput(
            snapshot.glucoseUnitIsMgdl ? mmol * PenBolusCalculator.mgdlPerMmol : mmol)
    }

    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
