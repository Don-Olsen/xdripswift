//
//  TherapyMetricsSettingsView.swift
//  xdrip
//
//  Created by Paul Plant on 12/8/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import SwiftUI

/// Treatment settings and local-estimate explanations use the existing SettingsViews table.
enum TherapyTexts {
    static func text(_ key: String) -> String { NSLocalizedString("therapy." + key, tableName: "SettingsViews", comment: "") }
}

struct TreatmentSettingsView: View {
    @StateObject private var presenter = SettingsActionPresenter(router: SettingsRouter())

    var body: some View {
        SettingsScreenDestinationView(settingsScreen: TreatmentSettingsViewModel.screen, presenter: presenter)
    }
}

struct TreatmentSettingsViewModel: SettingsNativeSectionProvider {
    enum Group { case insulin, carbs }
    let group: Group
    var policyProvider: () -> DataFlowPolicy = { UserDefaults.standard.dataFlowPolicy }

    static var screen: SettingsScreen {
        SettingsScreen(title: TherapyTexts.text("treatmentSettings"),
                       introduction: { TreatmentSettingsViewModel(group: .insulin).introduction }, onlineHelpTopic: .treatments,
                       providers: { [.insulin, .carbs].map { TreatmentSettingsViewModel(group: $0) } })
    }

    private var policy: DataFlowPolicy { policyProvider() }

    private var introduction: String {
        if let source = policy.externalIOBSource, policy.externalCOBSource == source {
            return String(format: TherapyTexts.text("settingsExternal"), providerName(source))
        } else if let source = policy.externalIOBSource {
            return String(format: TherapyTexts.text("settingsMixed"), providerName(source))
        }
        return TherapyTexts.text("settingsLocal")
    }

    func settingsRows(sectionID: Int) -> [SettingsRow] {
        let isInsulin = group == .insulin
        if (isInsulin ? policy.externalIOBSource : policy.externalCOBSource) != nil {
            return [SettingsRow(id: isInsulin ? "treatments.insulinType" : "treatments.carbDuration",
                title: TherapyTexts.text(isInsulin ? "insulinType" : "carbDuration"),
                detail: TherapyTexts.text("automatic"), accessory: .none, isEnabled: false)]
        }
        var rows: [SettingsRow] = []
        if isInsulin {
            rows.append(SettingsRow(id: "treatments.insulinType", title: TherapyTexts.text("insulinType"),
                accessory: .none, control: .menu(options: {
                    let selected = TherapyModelSettings(defaults: .standard).insulinPeak
                    return TherapyInsulinPreset.allCases.map {
                        SettingsMenuOption(title: $0.rawValue, isSelected: $0.peak == selected)
                    }
                }, selectOption: { index in
                    let presets = TherapyInsulinPreset.allCases
                    guard presets.indices.contains(index) else { return }
                    UserDefaults.standard.set(presets[index].peak, forKey: "localInsulinPeak")
                })))
        }
        else {
            rows.append(SettingsRow(id: "treatments.carbDuration", title: TherapyTexts.text("carbDuration"),
                accessory: .none, control: .menu(options: {
                    let selected = TherapyModelSettings(defaults: .standard).carbDuration
                    return TherapyModelSettings.carbDurationChoices.map {
                        SettingsMenuOption(title: Self.durationText($0), isSelected: $0 == selected)
                    }
                }, selectOption: { index in
                    let durations = TherapyModelSettings.carbDurationChoices
                    guard durations.indices.contains(index) else { return }
                    UserDefaults.standard.set(durations[index], forKey: "localCarbDuration")
                })))
        }
        return rows
    }

    private func providerName(_ source: TherapyMetricSource) -> String {
        source == .careLink ? "CareLink" : policy.nightscoutFollowType.description
    }

    private static func durationText(_ minutes: Double) -> String {
        DateComponentsFormatter.localizedString(from: DateComponents(hour: Int(minutes / 60)), unitsStyle: .full) ?? ""
    }

    func sectionTitle() -> String? { nil }
    func sectionFooter() -> String? {
        let settings = TherapyModelSettings(defaults: .standard)
        switch group {
        case .insulin:
            guard policy.externalIOBSource == nil else { return nil }
            return String(format: TherapyTexts.text("insulinModel"),
                TherapyInsulinPreset.nearest(to: settings.insulinPeak).rawValue,
                Self.durationText(settings.insulinDuration),
                DateComponentsFormatter.localizedString(from: DateComponents(minute: Int(settings.insulinPeak)), unitsStyle: .full) ?? "")
        case .carbs:
            guard policy.externalCOBSource == nil else { return nil }
            let key = settings.carbDuration <= 180 ? "carbFast" : settings.carbDuration <= 360 ? "carbNormal" : "carbLong"
            return TherapyTexts.text(key)
        }
    }
    private func row(at index: Int) -> SettingsRow? {
        let rows = settingsRows(sectionID: 0)
        return rows.indices.contains(index) ? rows[index] : nil
    }
    func settingsRowText(index: Int) -> String { row(at: index)?.title ?? "" }
    func accessoryType(index: Int) -> SettingsAccessory { .none }
    func detailedText(index: Int) -> String? { row(at: index)?.detail }
    func numberOfRows() -> Int { settingsRows(sectionID: 0).count }
    func onRowSelect(index: Int) -> SettingsSelectedRowAction { .nothing }
    func isEnabled(index: Int) -> Bool { row(at: index)?.isEnabled ?? false }
    func completeSettingsViewRefreshNeeded(index: Int) -> Bool { false }
    func storeMessageHandler(messageHandler: @escaping ((String, String) -> Void)) {}
    func storeRowReloadClosure(rowReloadClosure: @escaping ((Int) -> Void)) {}
}

struct TherapyMetricDetailsView: View {
    let metric: TherapyMetricState
    let isIOB: Bool
    var body: some View {
        List {
            Section {
                Text(metric.formatted(isIOB: isIOB, at: metric.referenceDate)).font(.title2)
                Text(TherapyTexts.text("local"))
                Text(metric.referenceDate.formatted(date: .abbreviated, time: .shortened))
                let settings = TherapyModelSettings(defaults: .standard)
                if isIOB {
                    LabeledContent(TherapyTexts.text("insulinType"), value: TherapyInsulinPreset.nearest(to: settings.insulinPeak).rawValue)
                } else {
                    LabeledContent(TherapyTexts.text("carbDuration"), value: DateComponentsFormatter.localizedString(from: DateComponents(hour: Int(settings.carbDuration / 60)), unitsStyle: .full) ?? "")
                }
            }
            Section {
                NavigationLink(TherapyTexts.text("treatmentSettings")) { TreatmentSettingsView() }
                Text(TherapyTexts.text("settingsHelp"))
            }
        }
        .navigationTitle(isIOB ? "IOB" : "COB")
    }
}

/// A suggested dose is unavailable until the user has checked these pen-specific values.
/// They never change the glucose forecast's separate ISF and carbohydrate ratio.
struct PenDoseSettingsView: View {
    @State private var profile = PenDoseProfile.load()
    @State private var draft = PenDoseProfileDraft(profile: .load())
    @State private var pizza = PizzaSplitSettings.load()
    @State private var percentageText = String(PizzaSplitSettings.load().percentageNow)
    @State private var reminderText = String(PizzaSplitSettings.load().reminderMinutes)
    @State private var statusMessage: String?

    var body: some View {
        Form {
            if TreatmentSourceCutover.current() == nil ||
                UserDefaults.standard.dataFlowPolicy.therapyDataSource != .none {
                Section {
                    Label("Bolusberegner og “Lavt om lidt” er ikke klar", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Gennemfør først “Log behandlinger i xDrip” med afsluttet Sundhed-synk. Indtil da kan appen ikke sikre ét komplet behandlingsgrundlag.")
                        .font(.footnote)
                }
            }
            Section {
                Label(profile.isConfirmed ? "Profil bekræftet" : "Profilen skal bekræftes",
                      systemImage: profile.isConfirmed ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .foregroundStyle(profile.isConfirmed ? .green : .orange)
                Text("Tallene er forudfyldt fra dine oplyste mySugr-værdier. Kontrollér dem, før beregneren bruges.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Kulhydratfaktor · g/E") {
                decimalField("00.00–04.30", text: $draft.ratioNight)
                decimalField("04.30–09.30", text: $draft.ratioMorning)
                decimalField("09.30–24.00", text: $draft.ratioDay)
            }
            Section("Målblodsukker · mmol/L") {
                decimalField("00.00–21.30", text: $draft.targetDay)
                decimalField("21.30–24.00", text: $draft.targetNight)
            }
            Section("Pen og korrektion") {
                decimalField("Korrektionsfaktor · mmol/L pr. E", text: $draft.correction)
                decimalField("Pennens trin · E", text: $draft.step)
                decimalField("Maksimalt forslag · E", text: $draft.maximum)
                Button("Jeg har kontrolleret og bekræftet profilen") {
                    guard let settings = draft.settings else {
                        statusMessage = "Kontrollér alle tal og prøv igen."
                        return
                    }
                    profile.settings = settings
                    guard profile.confirm(), profile.persist() else {
                        statusMessage = "Profilen kunne ikke gemmes. Beregneren forbliver utilgængelig."
                        return
                    }
                    statusMessage = "Profilen er gemt og bekræftet."
                }
                .disabled(draft.settings == nil)
            }
            Section("🍕 Fed/langsom mad") {
                Toggle("Del forslaget og mind mig om en ny beregning", isOn: $pizza.isEnabled)
                if pizza.isEnabled {
                    decimalField("Andel nu · %", text: $percentageText)
                    decimalField("Påmindelse efter · minutter", text: $reminderText)
                    Button("Gem indstillinger") {
                        guard let percent = Int(percentageText), let delay = Int(reminderText) else {
                            statusMessage = "Vælg en andel og et antal minutter."
                            return
                        }
                        pizza.percentageNow = percent
                        pizza.reminderMinutes = delay
                        if pizza.persist() {
                            statusMessage = "Indstillingerne er gemt."
                        } else {
                            statusMessage = "Andelen skal være 10–100 %, og påmindelsen 15–240 minutter."
                        }
                    }
                }
                Text("Påmindelsen lover ingen restdosis. Den åbner en helt ny beregning med aktuelle data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let statusMessage {
                Section { Text(statusMessage).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Bolusberegner")
        .onChange(of: pizza.isEnabled) { enabled in
            var changed = pizza
            changed.isEnabled = enabled
            if changed.persist() { pizza = changed }
        }
    }

    private func decimalField(_ title: String, text: Binding<String>) -> some View {
        LabeledContent(title) {
            TextField("Tal", text: text)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 85)
        }
    }
}

struct PenDoseProfileDraft {
    var ratioNight: String
    var ratioMorning: String
    var ratioDay: String
    var targetDay: String
    var targetNight: String
    var correction: String
    var step: String
    var maximum: String

    init(profile: PenDoseProfile) {
        let settings = profile.settings
        let fallback = PenDoseProfile.prefilledUnconfirmed.settings
        func scheduled(_ values: [PenDoseProfile.ScheduleValue], minute: Int, fallback: Double) -> Double {
            values.first(where: { $0.startMinute == minute })?.value ?? fallback
        }
        ratioNight = Self.text(scheduled(settings.carbohydrateRatios, minute: 0,
                                        fallback: fallback.carbohydrateRatios[0].value))
        ratioMorning = Self.text(scheduled(settings.carbohydrateRatios, minute: 270,
                                          fallback: fallback.carbohydrateRatios[1].value))
        ratioDay = Self.text(scheduled(settings.carbohydrateRatios, minute: 570,
                                      fallback: fallback.carbohydrateRatios[2].value))
        targetDay = Self.text(scheduled(settings.targetsMmol, minute: 0,
                                       fallback: fallback.targetsMmol[0].value))
        targetNight = Self.text(scheduled(settings.targetsMmol, minute: 1290,
                                         fallback: fallback.targetsMmol[1].value))
        correction = Self.text(settings.correctionMmolPerUnit)
        step = Self.text(settings.penStepUnits)
        maximum = Self.text(settings.maximumSuggestionUnits)
    }

    var settings: PenDoseProfile.Settings? {
        let values = [ratioNight, ratioMorning, ratioDay, targetDay, targetNight,
                      correction, step, maximum].compactMap(Self.number)
        guard values.count == 8 else { return nil }
        let result = PenDoseProfile.Settings(
            carbohydrateRatios: [
                .init(startMinute: 0, value: values[0]),
                .init(startMinute: 270, value: values[1]),
                .init(startMinute: 570, value: values[2])
            ],
            targetsMmol: [
                .init(startMinute: 0, value: values[3]),
                .init(startMinute: 1290, value: values[4])
            ],
            correctionMmolPerUnit: values[5],
            penStepUnits: values[6],
            maximumSuggestionUnits: values[7]
        )
        return result.isValid ? result : nil
    }

    private static func text(_ number: Double) -> String { number.stringWithoutTrailingZeroes }
    private static func number(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite else { return nil }
        return value
    }
}

struct PizzaSplitSettings: Equatable {
    static let enabledKey = "penPizzaSplitEnabled"
    static let percentageKey = "penPizzaSplitPercentageNow"
    static let reminderKey = "penPizzaSplitReminderMinutes"

    var isEnabled: Bool = true
    var percentageNow: Int = 70
    var reminderMinutes: Int = 90

    static func load(defaults: UserDefaults = .standard) -> Self {
        Self(isEnabled: defaults.object(forKey: enabledKey) as? Bool ?? true,
             percentageNow: defaults.object(forKey: percentageKey) as? Int ?? 70,
             reminderMinutes: defaults.object(forKey: reminderKey) as? Int ?? 90)
    }

    @discardableResult
    func persist(defaults: UserDefaults = .standard) -> Bool {
        guard (10...100).contains(percentageNow), (15...240).contains(reminderMinutes) else { return false }
        defaults.set(isEnabled, forKey: Self.enabledKey)
        defaults.set(percentageNow, forKey: Self.percentageKey)
        defaults.set(reminderMinutes, forKey: Self.reminderKey)
        return true
    }
}
