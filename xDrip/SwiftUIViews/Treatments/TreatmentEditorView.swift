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
                Button("Bekræft spist") {
                    if viewModel.confirmPlannedMeal() { onSave() }
                }
            case .cancelMeal:
                Button("Annuller planen", role: .destructive) {
                    if viewModel.cancelPlannedMeal() { onSave() }
                }
            case .deleteWithHealthWarning:
                Button("Slet lokalt", role: .destructive) {
                    if viewModel.deleteTreatment() { onSave() }
                }
            case .none:
                EmptyView()
            }
        } message: {
            switch pendingConfirmation {
            case .confirmMeal:
                Text("Bekræft kun, hvis du faktisk har spist kulhydraterne. Tidspunkt og mængde kan rettes først.")
            case .deleteWithHealthWarning:
                Text("Posten slettes i xDrip. En kopi kan stadig findes i Apple Sundhed og skal i så fald kontrolleres dér.")
            case .cancelMeal, .none:
                Text("Planen tæller ikke som spist og kan annulleres uden behandlingseffekt.")
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

/// A pen-only calculator. It never delivers insulin; Log records only what the user confirms.
struct PenDoseCalculatorScreen: View {
    @StateObject private var viewModel: PenDoseCalculatorViewModel
    let coreDataManager: CoreDataManager
    let onSave: () -> Void
    let onCancel: () -> Void

    init(coreDataManager: CoreDataManager, reminderMealUUID: String? = nil,
         onSave: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.coreDataManager = coreDataManager
        self.onSave = onSave
        self.onCancel = onCancel
        _viewModel = StateObject(wrappedValue: PenDoseCalculatorViewModel(
            coreDataManager: coreDataManager, reminderMealUUID: reminderMealUUID))
    }

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.storageGateState != .ready {
                    Section {
                        Text(viewModel.storageGateState.message).foregroundStyle(.orange)
                        if viewModel.storageGateState == .foundPriorEntry ||
                            viewModel.storageGateState == .noLocalEntryHealthUncertain ||
                            viewModel.storageGateState == .uncertainMutationAfterRestart {
                            Button("Jeg har kontrolleret xDrip og Sundhed") {
                                viewModel.acknowledgePreviouslyFoundTreatment()
                            }
                        }
                    }
                }
                if viewModel.reminderMealUUID != nil {
                    Section {
                        Label("Ny beregning efter måltidet", systemImage: "arrow.clockwise")
                        Text("Kulhydraterne er allerede registreret og indgår kun via aktuelt COB. Der loves ingen restdosis.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Doseringsprofil") {
                    Label(viewModel.profile.isConfirmed ? "Profil bekræftet" : "Bekræft profilen først",
                          systemImage: viewModel.profile.isConfirmed ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(viewModel.profile.isConfirmed ? .green : .orange)
                    NavigationLink("Kontrollér profil og 🍕-indstillinger") {
                        PenDoseSettingsView()
                    }
                }
                Section("Blodsukker") {
                    Picker("Kilde", selection: $viewModel.glucoseChoice) {
                        Text("Aktuel CGM").tag(PenDoseGlucoseChoice.currentCGM)
                        Text("Bekræft gammel CGM").tag(PenDoseGlucoseChoice.confirmStaleCGM)
                        Text("Manuel værdi").tag(PenDoseGlucoseChoice.manual)
                    }
                    if let date = viewModel.latestGlucoseDate {
                        LabeledContent("Seneste CGM", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    if viewModel.glucoseChoice == .confirmStaleCGM {
                        Text("Den gamle måling forbliver gammel. Ændringsleddet sættes til nul.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    if viewModel.glucoseChoice == .manual {
                        LabeledContent(viewModel.glucoseUnitIsMgdl ? "Manuel mg/dL" : "Manuel mmol/L") {
                            TextField("Værdi", text: $viewModel.manualGlucoseText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                        }
                        DatePicker("Målt klokken", selection: $viewModel.manualGlucoseDate,
                                   in: Date().addingTimeInterval(-24 * 60 * 60)...Date(),
                                   displayedComponents: [.date, .hourAndMinute])
                        Text("Gemmes kun som et manuelt beregnerinput. Den bliver ikke en CGM-måling eller alarmværdi.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if viewModel.reminderMealUUID == nil {
                    Section("Kulhydrater") {
                        LabeledContent("Nye kulhydrater · g") {
                            TextField("0", text: $viewModel.carbohydratesText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                        }
                        Picker("Madtype", selection: $viewModel.mealKind) {
                            Text("🍭 Hurtig · 30 min").tag(TreatmentMealKind.fast)
                            Text("🌮 Normal · 240 min").tag(TreatmentMealKind.normal)
                            Text("🍕 Fed/langsom · 300 min").tag(TreatmentMealKind.slow)
                        }
                        Toggle("Planlæg til senere", isOn: $viewModel.isPlannedMeal)
                        if viewModel.isPlannedMeal {
                            DatePicker("Forventet tidspunkt", selection: $viewModel.plannedDate,
                                       in: Date()...Date().addingTimeInterval(60 * 60),
                                       displayedComponents: [.date, .hourAndMinute])
                            Text("Planlagt mad tæller først efter særskilt bekræftelse af, at den er spist.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button {
                        Task { await viewModel.calculate() }
                    } label: {
                        if viewModel.isWorking { ProgressView() }
                        else { Text("Beregn forslag") }
                    }
                    .disabled(viewModel.isWorking)
                    if let message = viewModel.statusMessage {
                        Text(message).foregroundStyle(.orange)
                    }
                }
                if let calculation = viewModel.calculation, viewModel.isReviewCurrent {
                    calculationSection(calculation)
                } else if viewModel.calculation != nil {
                    Section {
                        Text("Input er ændret. Beregn igen, før du logger noget.")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Bolusberegner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Luk", action: onCancel)
                }
            }
        }
        .colorScheme(.dark)
    }

    private func calculationSection(_ calculation: PenDoseCalculation) -> some View {
        Section("Gennemgå beregningen") {
            if let glucose = calculation.glucoseMgdl, let measuredAt = calculation.glucoseMeasuredAt {
                let display = viewModel.glucoseUnitIsMgdl ? glucose : glucose / PenBolusCalculator.mgdlPerMmol
                LabeledContent("Blodsukker", value:
                    "\(display.stringWithoutTrailingZeroes) \(viewModel.glucoseUnitIsMgdl ? "mg/dL" : "mmol/L") · \(measuredAt.formatted(date: .omitted, time: .shortened))")
            }
            if let lines = calculation.lines {
                line("COB + nye kulhydrater", units: lines.carbohydratesUnits)
                line("Korrektion", units: lines.correctionUnits)
                line("20-minutters ændring", units: lines.trendUnits)
                line("Aktiv insulin (fratrukket)", units: -lines.insulinOnBoardUnits)
                line("Sum før grænser og afrunding", units: lines.rawUnits)
            }
            if calculation.trendWasIntentionallyZero {
                Text("Ændringsleddet er 0 ved manuel eller bekræftet gammel værdi.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            safetyText(calculation.safety)
            if let suggested = viewModel.suggestedUnits {
                LabeledContent("Forslag nu", value: "\(suggested.stringWithoutTrailingZeroes) E")
                    .font(.headline)
                if viewModel.mealKind == .slow && PizzaSplitSettings.load().isEnabled &&
                   viewModel.reminderMealUUID == nil {
                    Text("🍕 Andelen nu er \(PizzaSplitSettings.load().percentageNow) %. Påmindelsen giver kun en ny beregning.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text("Intet insulin foreslås på dette grundlag.")
                    .foregroundStyle(.orange)
            }
            LabeledContent("Faktisk taget insulin · E") {
                TextField("0", text: $viewModel.insulinToLogText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 100)
            }
            Text("Du kan rette den faktisk tagne mængde. Appen giver aldrig insulin.")
                .font(.footnote).foregroundStyle(.secondary)
            Button("Log") {
                Task {
                    if await viewModel.logReviewedTreatment() {
                        onSave()
                    }
                }
            }
            .disabled(!viewModel.canLog || viewModel.isWorking)
        }
    }

    private func line(_ title: String, units: Double) -> some View {
        LabeledContent(title, value: "\(units.stringWithoutTrailingZeroes) E")
    }

    @ViewBuilder private func safetyText(_ safety: PenDoseSafetyState?) -> some View {
        switch safety {
        case .checked:
            Text("Prognosetjek gennemført med motoren.").foregroundStyle(.secondary)
        case .eatFirst:
            Text("Spis først: blodsukker under 3,9 mmol/L.").foregroundStyle(.orange)
        case .blockedCurrentLow:
            Text("Insulinforslag blokeret: aktuelt blodsukker under 3,0 mmol/L.")
                .foregroundStyle(.red)
        case .blockedForecastLow:
            Text("Insulinforslag blokeret: motorens prognose går under 3,0 mmol/L.")
                .foregroundStyle(.red)
        case .forecastUnchecked:
            Text("Prognosetjekket kunne ikke køres. Forslaget er ikke prognosekontrolleret.")
                .foregroundStyle(.orange)
        case .eatFirstForecastUnchecked:
            Text("Spis først. Prognosetjekket kunne ikke køres.")
                .foregroundStyle(.orange)
        case nil:
            Text("Kan ikke beregne med det aktuelle grundlag.").foregroundStyle(.orange)
        }
    }
}
