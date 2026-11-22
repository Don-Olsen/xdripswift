import SwiftUI
import UserNotifications

enum PenCartridgeDisplay {
    static func balance(_ remaining: Double?) -> String {
        guard let remaining, remaining.isFinite else { return "Restmængde ukendt" }
        guard remaining >= 0 else { return "Tjek restmængden" }
        return "ca. \(PenDoseDisplayFormatter.insulin(remaining)) E tilbage"
    }

    static func units(_ text: String, minimum: Double) -> Double? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !input.isEmpty, input.allSatisfy({ $0.isNumber || $0 == "." }),
              let units = Double(input), units.isFinite, (minimum...300).contains(units) else { return nil }
        return units
    }
}

/// One explicit cartridge change or allocation edit, shared by the live dose and history.
struct PenCartridgeSplitEditor: View {
    let request: PenCartridgeAllocationRequest
    let onSave: (Double, Bool) -> Bool
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editsOldUnits: Bool
    @State private var oldUnitsText: String
    @State private var startsNewCartridge: Bool
    @State private var saveFailed = false

    init(request: PenCartridgeAllocationRequest, onSave: @escaping (Double, Bool) -> Bool) {
        self.request = request
        self.onSave = onSave
        _oldUnitsText = State(initialValue: request.suggestedOldUnits
            .map(PenDoseDisplayFormatter.insulinInput) ?? "")
        _startsNewCartridge = State(initialValue: request.startsNewCartridge)
    }

    var body: some View {
        NavigationStack {
            Form {
                if request.allowsCartridgeChoice {
                    Section {
                        Picker("Ampul til resten", selection: $startsNewCartridge) {
                            Text("Nuværende ampul").tag(false)
                            Text("Ny ampul").tag(true)
                        }
                    } footer: {
                        Text("Vælg nuværende ampul, hvis du allerede har registreret skiftet.")
                    }
                }
                Section {
                    amountRow("Samlet insulin", value: request.totalUnits)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Fra gammel ampul").font(.subheadline).foregroundStyle(.secondary)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            TextField("Indtast enheder", text: $oldUnitsText)
                                .font(.title2).monospacedDigit()
                                .keyboardType(.decimalPad)
                                .focused($editsOldUnits)
                                .accessibilityLabel("Insulin taget fra gammel ampul, enheder")
                                .accessibilityIdentifier("penCartridge.split.oldUnits")
                            Text("E").foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                    }
                    if let old = validOldUnits {
                        amountRow("Fra ny ampul", value: request.totalUnits - old)
                            .accessibilityIdentifier("penCartridge.split.newUnits")
                    } else {
                        Text("Angiv 0–\(PenDoseDisplayFormatter.insulinInput(request.totalUnits)) E fra den gamle ampul i pennens trin på \(PenDoseDisplayFormatter.insulinInput(request.penStepUnits)) E.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(request.suggestedOldUnits == nil
                         ? "Angiv den mængde, du faktisk tog fra den gamle ampul."
                         : "Kontrollér fordelingen, og ret mængden, hvis du tog noget andet fra den gamle ampul.")
                }
                Section {
                    Button {
                        editsOldUnits = false
                        guard let units = validOldUnits else { return }
                        if onSave(units, startsNewCartridge) { dismiss() }
                        else { saveFailed = true }
                    } label: {
                        Text(startsNewCartridge ? "Bekræft ny ampul og fordeling" : "Gem fordeling")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .multilineTextAlignment(.leading)
                    }
                    .disabled(validOldUnits == nil)
                    .accessibilityIdentifier("penCartridge.split.confirm")
                } footer: {
                    Text(startsNewCartridge
                         ? "Bekræft, når du har sat en ny ampul på 300 E i pennen. Ampulforbruget medregner 2 E til udluftning pr. anvendt ampul."
                         : "Ampulforbruget medregner 2 E til udluftning pr. anvendt ampul.")
                }
                if saveFailed {
                    Section {
                        Text("Fordelingen kunne ikke gemmes. Kontrollér mængderne og den aktuelle ampul, og prøv igen.")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .ipadReadableContentWidth(720)
            .navigationTitle("Fordel dosis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuller") { dismiss() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Færdig") { editsOldUnits = false }
                }
            }
        }
        .colorScheme(.dark)
    }

    private var validOldUnits: Double? {
        guard let units = PenCartridgeDisplay.units(oldUnitsText, minimum: 0),
              request.totalUnits.isFinite, units <= request.totalUnits,
              request.penStepUnits.isFinite, request.penStepUnits > 0 else { return nil }
        let steps = units / request.penStepUnits
        guard abs(steps - steps.rounded()) < 0.000001 else { return nil }
        return units
    }

    private func amountRow(_ title: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text("\(PenDoseDisplayFormatter.insulinInput(value)) E")
                .font(.title2).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// The cartridge is always live, including while glucose history is being browsed.
struct PenCartridgeHomeRow: View {
    let remaining: Double?
    let isLow: Bool
    let isHistorical: Bool
    let baselineID: UUID?
    let openDetails: () -> Void
    let replace: (UUID?) -> Bool
    var splitDuringDose: ((UUID?) -> Bool)? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                balanceButton.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                replaceButton.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 0) {
                balanceButton
                replaceButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: ConstantsHomeView.standardCornerRadius)
            .fill(Color(uiColor: .secondarySystemBackground)))
        .buttonStyle(.plain)
    }

    private var balanceButton: some View {
        Button(action: openDetails) {
            HStack(spacing: 6) {
                if isLow || remaining == nil {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                Text("\(isHistorical ? "Ampul nu" : "Ampul") · \(remaining == nil ? "ukendt" : PenCartridgeDisplay.balance(remaining))")
                    .multilineTextAlignment(.leading)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(isHistorical ? "Ampul nu" : "Ampul") · \(PenCartridgeDisplay.balance(remaining))")
        .accessibilityValue(isLow ? "Lav restmængde" : "")
        .accessibilityHint("Åbner ampuloplysninger")
        .accessibilityIdentifier("home.penCartridge")
    }

    private var replaceButton: some View {
        PenCartridgeReplacementButton(baselineID: baselineID, replace: replace,
                                      splitDuringDose: splitDuringDose)
            .foregroundStyle(ConstantsAppColors.accent)
    }
}

private struct PenCartridgeReplacementButton: View {
    let baselineID: UUID?
    let replace: (UUID?) -> Bool
    var splitDuringDose: ((UUID?) -> Bool)? = nil
    @State private var showsConfirmation = false
    @State private var expectedBaseline: UUID?
    @State private var failed = false

    var body: some View {
        Button {
            expectedBaseline = baselineID
            showsConfirmation = true
        } label: {
            Text("Ny ampul").frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityIdentifier("penCartridge.replace")
        .alert("Ny ampul på 300 E?", isPresented: $showsConfirmation) {
            Button("Annuller", role: .cancel) {}
            if let splitDuringDose {
                Button("Skift under dosis") {
                    failed = !splitDuringDose(expectedBaseline)
                }
            }
            Button("Start ny ampul") {
                failed = !replace(expectedBaseline)
            }
        } message: {
            Text(splitDuringDose == nil
                 ? "Bekræft, når du har sat en ny, fuld ampul i pennen."
                 : "Skifter du midt i en dosis, vælg Skift under dosis. Ellers bekræfter du en ny, fuld ampul på 300 E.")
        }
        .alert("Ampullen kunne ikke skiftes", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Kontrollér den aktuelle restmængde og prøv igen.")
        }
    }
}

struct PenCartridgeDetailView: View {
    @ObservedObject private var monitor = PenCartridgeMonitor.shared
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var focusedField: Field?
    @State private var isVisible = false
    @State private var authorization: UNAuthorizationStatus?
    @State private var startsFull = false
    @State private var remainingText = ""
    @State private var thresholdText = ""
    @State private var editing: Field?
    @State private var editingBaseline: UUID?
    @State private var showsDisableConfirmation = false
    @State private var disablingBaseline: UUID?
    @State private var error: String?

    private enum Field: Hashable { case remaining, threshold }

    var body: some View {
        Form {
            if monitor.isEnabled {
                inventorySection
                alertSection
                Section {
                    Button("Slå ampulsporing fra", role: .destructive) {
                        disablingBaseline = monitor.snapshot.baselineID
                        showsDisableConfirmation = true
                    }
                }
            } else {
                setupSection
            }
            if let error {
                Section { Text(error).foregroundStyle(.orange) }
            }
        }
        .navigationTitle("Ampul")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Færdig") { focusedField = nil }
            }
        }
        .alert("Slå ampulsporing fra?", isPresented: $showsDisableConfirmation) {
            Button("Annuller", role: .cancel) {}
            Button("Slå fra", role: .destructive) {
                guard disablingBaseline == monitor.snapshot.baselineID else {
                    error = "Ampullen er ændret. Kontrollér den før du fortsætter."
                    return
                }
                monitor.setEnabled(false)
                editing = nil
                startsFull = false
                remainingText = ""
                thresholdText = monitor.threshold.map(PenDoseDisplayFormatter.profileInput) ?? ""
                error = nil
            }
        } message: {
            Text("Ampulrækken på Hjem og ampulpåmindelserne bliver slået fra.")
        }
        .onAppear {
            isVisible = true
            if let request = monitor.pendingOpenID { monitor.acknowledgeOpen(id: request) }
            monitor.refresh()
            if !monitor.isEnabled, thresholdText.isEmpty, let threshold = monitor.threshold {
                thresholdText = PenDoseDisplayFormatter.profileInput(threshold)
            }
        }
        .task(id: scenePhase) {
            if scenePhase == .active { await refreshPermission() }
        }
        .onDisappear { isVisible = false }
        .onChange(of: monitor.pendingOpenID) { request in
            if isVisible, let request { monitor.acknowledgeOpen(id: request) }
        }
    }

    private var setupSection: some View {
        Section {
            Picker("Ampul", selection: $startsFull) {
                Text("I brug").tag(false)
                Text("Ny · 300 E").tag(true)
            }
            .pickerStyle(.segmented)
            if !startsFull { amountField("Rest i ampullen · E", text: $remainingText, field: .remaining) }
            amountField("Påmind ved · E", text: $thresholdText, field: .threshold)
            Button("Start ampulsporing") {
                focusedField = nil
                guard let remaining = startingAmount, let threshold = validThreshold,
                      monitor.start(remaining: remaining, threshold: threshold) else {
                    error = "Ampulsporingen kunne ikke startes. Kontrollér tallene og prøv igen."
                    return
                }
                error = nil
            }
            .disabled(startingAmount == nil || validThreshold == nil)
        } header: {
            Text("Hurtigvirkende insulin")
        } footer: {
            Text("Brug én pen. Hver registreret bolus fra iPhone eller Watch trækker dosis og 2 E til udluftning fra ampullen. Aflæs din nuværende ampul (0–300 E), eller vælg en ny, fuld ampul. Vælg din grænse for lav restmængde (1–300 E).")
        }
    }

    private var inventorySection: some View {
        Section {
            Text(PenCartridgeDisplay.balance(monitor.snapshot.remainingUnits))
                .font(.headline)
            if monitor.isLow {
                Label("Lav restmængde", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            }
            if editing == .remaining {
                amountField("Aflæst rest · E", text: $remainingText, field: .remaining)
                editorButtons(enabled: validRemaining != nil)
            } else {
                Button("Ret restmængde") {
                    editingBaseline = monitor.snapshot.baselineID
                    remainingText = ""
                    beginEditing(.remaining)
                }
            }
            PenCartridgeReplacementButton(baselineID: monitor.snapshot.baselineID) { expected in
                guard monitor.isEnabled, monitor.snapshot.baselineID == expected else { return false }
                let replaced = monitor.newCartridge()
                if replaced { editing = nil }
                return replaced
            }
        } header: {
            Text("Hurtigvirkende insulin")
        } footer: {
            Text("Skønnet gælder én pen. Hver registreret bolus fra iPhone eller Watch trækker dosis og 2 E til udluftning fra ampullen. Du kan rette skønnet efter en aflæsning på pennen.")
        }
    }

    private var alertSection: some View {
        Section("Lav restmængde") {
            if editing == .threshold {
                amountField("Påmind ved · E", text: $thresholdText, field: .threshold)
                editorButtons(enabled: validThreshold != nil)
            } else {
                Button {
                    thresholdText = monitor.threshold.map(PenDoseDisplayFormatter.profileInput) ?? ""
                    beginEditing(.threshold)
                } label: {
                    LabeledContent("Påmind ved", value: monitor.threshold.map {
                        "\(PenDoseDisplayFormatter.insulin($0)) E"
                    } ?? "Vælg grænse")
                }
            }
            if let date = monitor.snoozedUntil, date > Date() {
                LabeledContent("Ny påmindelse", value: date.formatted(date: .abbreviated, time: .shortened))
            } else if monitor.canRemindLater {
                Button("Mind mig igen om 1 time") { monitor.remindLater() }
            }
            permissionRow
            if let issue = monitor.issueMessage {
                Text(issue).font(.footnote).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var permissionRow: some View {
        if let authorization {
            if BasalReminderPermission.isAvailable(authorization) {
                LabeledContent("Notifikationer", value: "Tilladt")
            } else if authorization == .notDetermined {
                Button("Tillad notifikationer") {
                    Task {
                        do {
                            _ = try await UNUserNotificationCenter.current()
                                .requestAuthorization(options: [.alert, .sound])
                        } catch {
                            self.error = "Tilladelsen til notifikationer kunne ikke hentes."
                        }
                        await refreshPermission()
                        monitor.refresh()
                    }
                }
            } else {
                LabeledContent("Notifikationer", value: "Slået fra")
                Button("Åbn systemindstillinger") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    private var validRemaining: Double? { PenCartridgeDisplay.units(remainingText, minimum: 0) }
    private var validThreshold: Double? { PenCartridgeDisplay.units(thresholdText, minimum: 1) }
    private var startingAmount: Double? { startsFull ? 300 : validRemaining }

    private func refreshPermission() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func beginEditing(_ field: Field) {
        editing = field
        error = nil
        focusedField = field
    }

    private func amountField(_ label: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            TextField("Indtast antal enheder", text: text)
                .accessibilityLabel(label)
                .keyboardType(.decimalPad)
                .focused($focusedField, equals: field)
        }
    }

    private func editorButtons(enabled: Bool) -> some View {
        HStack {
            Button("Annuller", role: .cancel) {
                editing = nil
                focusedField = nil
                error = nil
            }
            Spacer()
            Button("Gem") {
                switch editing {
                case .remaining:
                    guard let units = validRemaining, editingBaseline == monitor.snapshot.baselineID,
                          monitor.setRemaining(units) else {
                        error = "Restmængden kunne ikke gemmes. Kontrollér ampullen igen."
                        return
                    }
                case .threshold:
                    guard let threshold = validThreshold else { return }
                    monitor.setThreshold(threshold)
                case nil:
                    return
                }
                editing = nil
                focusedField = nil
                error = nil
            }
            .disabled(!enabled)
        }
        .buttonStyle(.borderless)
    }
}
