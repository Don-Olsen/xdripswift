//
//  TherapyMetricsSettingsView.swift
//  xdrip
//
//  Created by Paul Plant on 12/8/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import SwiftUI
import UIKit
import UserNotifications

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
    @ObservedObject private var basalScheduler = BasalReminderScheduler.shared
    @State private var profile = PenDoseProfile.load()
    @State private var draft = PenDoseProfileDraft(profile: .load())
    @State private var pizza = PizzaSplitSettings.load()
    @State private var percentageText = String(PizzaSplitSettings.load().percentageNow)
    @State private var reminderText = String(PizzaSplitSettings.load().reminderMinutes)
    @State private var basalReminder = BasalReminderSettings.load()
    @State private var basalReminderTime = Self.timeDate(for: BasalReminderSettings.load().minuteOfDay)
    @State private var basalNotificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var statusMessage: String?
    @FocusState private var fieldIsFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var hasUnconfirmedChanges: Bool { draft.settings != profile.settings }
    private var pizzaInputIsValid: Bool {
        guard let percentage = Int(percentageText), let minutes = Int(reminderText) else { return false }
        return (10...100).contains(percentage) && (15...240).contains(minutes)
    }

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
                Label(profile.isConfirmed && !hasUnconfirmedChanges ? "Profil bekræftet" : "Profilen skal bekræftes",
                      systemImage: profile.isConfirmed && !hasUnconfirmedChanges ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .foregroundStyle(profile.isConfirmed && !hasUnconfirmedChanges ? .green : .orange)
                Text("Tallene er forudfyldt fra dine oplyste mySugr-værdier. Kontrollér dem, før beregneren bruges.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                decimalField("00.00–04.30", text: $draft.ratioNight)
                decimalField("04.30–09.30", text: $draft.ratioMorning)
                decimalField("09.30–24.00", text: $draft.ratioDay)
            } header: {
                Label("Kulhydratfaktor · g/E", systemImage: "fork.knife")
            } footer: {
                Text("Gram kulhydrat pr. enhed insulin. Tidspunkterne følger den lokale tid.")
            }
            Section {
                decimalField("00.00–21.30", text: $draft.targetDay)
                decimalField("21.30–24.00", text: $draft.targetNight)
            } header: {
                Label("Målblodsukker · mmol/L", systemImage: "target")
            }
            Section("Pen og korrektion") {
                decimalField("Korrektionsfaktor · mmol/L pr. E", text: $draft.correction)
                decimalField("Pennens trin · E", text: $draft.step)
                decimalField("Maksimalt forslag · E", text: $draft.maximum)
            }
            Section {
                Button {
                    fieldIsFocused = false
                    guard let settings = draft.settings else {
                        statusMessage = "Kontrollér alle tal og prøv igen."
                        return
                    }
                    profile.settings = settings
                    guard profile.confirm(), profile.persist() else {
                        statusMessage = "Profilen kunne ikke gemmes. Beregneren forbliver utilgængelig."
                        return
                    }
                    NotificationCenter.default.post(name: .penDoseSettingsChanged, object: nil)
                    statusMessage = "Profilen er gemt og bekræftet."
                } label: {
                    Label("Bekræft profil", systemImage: "checkmark.shield")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.settings == nil)
                if draft.settings == nil {
                    Text("Kontrollér alle profilens tal, før du bekræfter.")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } footer: {
                Text("Ved at bekræfte gemmer du tallene som din doseringsprofil. De ændrer ikke prognosens separate indstillinger.")
            }
            Section("🍕 Fed/langsom mad") {
                Toggle("Del forslaget og mind mig om en ny beregning", isOn: $pizza.isEnabled)
                if pizza.isEnabled {
                    decimalField("Andel nu · %", text: $percentageText)
                    decimalField("Påmindelse efter · minutter", text: $reminderText)
                    Button("Gem indstillinger") {
                        fieldIsFocused = false
                        guard let percent = Int(percentageText), let delay = Int(reminderText) else {
                            statusMessage = "Vælg en andel og et antal minutter."
                            return
                        }
                        pizza.percentageNow = percent
                        pizza.reminderMinutes = delay
                        if pizza.persist() {
                            NotificationCenter.default.post(name: .penDoseSettingsChanged, object: nil)
                            statusMessage = "Indstillingerne er gemt."
                        } else {
                            statusMessage = "Andelen skal være 10–100 %, og påmindelsen 15–240 minutter."
                        }
                    }
                    .disabled(!pizzaInputIsValid)
                    if !pizzaInputIsValid {
                        Text("Vælg 10–100 % og 15–240 minutter.")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                Text("Påmindelsen lover ingen restdosis. Den åbner en helt ny beregning med aktuelle data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Påmind mig om basal", isOn: $basalReminder.isEnabled)
                if basalReminder.isEnabled {
                    DatePicker("Klokkeslæt", selection: $basalReminderTime,
                               displayedComponents: .hourAndMinute)
                    if !BasalReminderPermission.isAvailable(basalNotificationStatus) {
                        Text("Notifikationer er ikke tilladt. Aktivér dem i iPhone-indstillinger for at få påmindelsen.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        if basalNotificationStatus == .denied {
                            Button("Åbn iPhone-indstillinger") {
                                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                                UIApplication.shared.open(url)
                            }
                        }
                    }
                    if let issue = basalScheduler.issueMessage {
                        Text(issue).font(.footnote).foregroundStyle(.orange)
                    }
                }
            } header: {
                Text("Basal")
            } footer: {
                Text("Påmindelsen bruger registrerede basaldoser. Den udebliver, når basal er registreret inden for de seneste 12 timer før klokkeslættet.")
            }
            if let statusMessage {
                Section { Text(statusMessage).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Doseringsprofil")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Færdig") { fieldIsFocused = false }
            }
        }
        .onChange(of: pizza.isEnabled) { enabled in
            var changed = pizza
            changed.isEnabled = enabled
            if changed.persist() {
                pizza = changed
                NotificationCenter.default.post(name: .penDoseSettingsChanged, object: nil)
            }
        }
        .onChange(of: basalReminder.isEnabled) { _ in saveBasalReminderSettings() }
        .onChange(of: basalReminderTime) { newTime in
            let components = Calendar.current.dateComponents([.hour, .minute], from: newTime)
            basalReminder.minuteOfDay = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            saveBasalReminderSettings()
        }
        .onAppear(perform: refreshBasalNotificationStatus)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshBasalNotificationStatus()
        }
    }

    private static func timeDate(for minuteOfDay: Int) -> Date {
        let calendar = Calendar.current
        return calendar.date(bySettingHour: minuteOfDay / 60, minute: minuteOfDay % 60,
                             second: 0, of: Date()) ?? Date()
    }

    private func saveBasalReminderSettings() {
        basalReminder.persist()
        BasalReminderScheduler.shared.refresh()
    }

    private func refreshBasalNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async { basalNotificationStatus = settings.authorizationStatus }
        }
    }

    private func decimalField(_ title: String, text: Binding<String>) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                    decimalInput(title, text: text)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(title)
                    Spacer(minLength: 8)
                    decimalInput(title, text: text)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 70, maxWidth: 110)
                }
            }
        }
    }

    private func decimalInput(_ title: String, text: Binding<String>) -> some View {
        TextField("Tal", text: text)
            .keyboardType(.decimalPad)
            .monospacedDigit()
            .focused($fieldIsFocused)
            .accessibilityLabel(title)
    }
}

extension Notification.Name {
    static let penDoseSettingsChanged = Notification.Name("xdrip.penDose.settingsChanged")
}

/// Danish display only. Parsing and calculator precision remain independent of presentation.
enum PenDoseDisplayFormatter {
    static func insulin(_ value: Double) -> String { number(value, maxDecimals: 3) }
    static func carbs(_ value: Double) -> String { number(value, maxDecimals: 3) }

    /// Preserve every valid profile value when opening and saving without an edit.
    static func profileInput(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        return value.formatted(.number.locale(Locale(identifier: "da_DK"))
            .precision(.fractionLength(0...17)).grouping(.never))
    }

    static func insulinInput(_ value: Double) -> String {
        guard value.isFinite else { return "" }
        let text = number(value, maxDecimals: 15)
        return text.contains(",") ? text : text + ",0"
    }

    static func glucose(_ valueMgdl: Double, mgdl: Bool) -> String {
        let value = mgdl ? valueMgdl : valueMgdl / PenBolusCalculator.mgdlPerMmol
        return "\(number(value, maxDecimals: mgdl ? 0 : 1)) \(mgdl ? "mg/dL" : "mmol/L")"
    }

    static func number(_ value: Double, maxDecimals: Int) -> String {
        guard value.isFinite else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "da_DK")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = max(0, maxDecimals)
        return formatter.string(from: NSNumber(value: value)) ?? "—"
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

    private static func text(_ number: Double) -> String {
        PenDoseDisplayFormatter.profileInput(number)
    }
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
