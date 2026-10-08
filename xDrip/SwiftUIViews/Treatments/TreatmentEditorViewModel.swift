//
//  TreatmentEditorViewModel.swift
//  xdrip
//
//  Created by Paul Plant on 18/6/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation
import CoreData
import OSLog
import UserNotifications

@MainActor final class TreatmentEditorViewModel: ObservableObject {
    // MARK: - public static properties

    /// Permit a small amount of advance entry without allowing accidental future-day treatments.
    nonisolated static let maximumFutureTreatmentInterval: TimeInterval = 60 * 60

    static let supportedTreatmentTypes: [TreatmentType] = [.Insulin, .Carbs, .BgCheck, .Exercise, .BasalInjection, .Note]

    // MARK: - @Published properties

    @Published var selectedType: TreatmentType
    @Published var selectedDate: Date
    @Published var enteredValue: String
    @Published var enteredByValue: String
    @Published var enteredNotesValue: String
    @Published var enteredInsulinDescription: String
    @Published var selectedMealKind: TreatmentMealKind
    @Published var isPlanningNewMeal: Bool
    @Published var alertMessage: TreatmentEditorAlertMessage?
    @Published private(set) var localSaveGateState: PenDoseLogJournal.RecoveryState

    /// Only show the copied-values footer when both fields were prefilled for a new injection.
    let didPrefillBasalInjection: Bool

    // MARK: - private properties

    private let coreDataManager: CoreDataManager?
    // Keep the main-context object for the lifetime of this editor. Its objectID may change
    // from temporary to permanent while the parent context saves a newly added treatment.
    private let originalTreatment: TreatmentEntry?
    private let initialTreatmentState: TreatmentEditorInitialState?
    private let localSaveJournal: PenDoseLogJournal
    private let mealMetadataStore: MealPlanMetadataStore
    private let localSaveOperation = PenDoseLogOperation()
    private let localSaveStartedAt = Date()
    private let localSaveOverride: (() -> Bool)?
    private var requestedExistingMealState: TreatmentMealState?
    private let log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryApplicationDataTreatments)

    // MARK: - initialization

    init(coreDataManager: CoreDataManager?, treatmentToEdit: TreatmentEntry?, initialType: TreatmentType = .Carbs,
         quickCarbohydrateGrams: Double? = nil, localSaveJournal: PenDoseLogJournal? = nil,
         localSaveOverride: (() -> Bool)? = nil, mealMetadataStore: MealPlanMetadataStore? = nil) {
        let localSaveJournal = localSaveJournal ?? .shared
        self.didPrefillBasalInjection = treatmentToEdit == nil && initialType == .BasalInjection
            && UserDefaults.standard.lastBasalInjectionUnits > 0
            && !UserDefaults.standard.lastBasalInjectionInsulinDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        self.coreDataManager = coreDataManager
        self.localSaveJournal = localSaveJournal
        self.mealMetadataStore = mealMetadataStore ?? .shared
        self.localSaveOverride = localSaveOverride
        self.localSaveGateState = coreDataManager.map { localSaveJournal.recoveryState(coreDataManager: $0) } ?? .ready
        self.originalTreatment = treatmentToEdit
        self.initialTreatmentState = treatmentToEdit.map {
            TreatmentEditorInitialState(
                selectedType: $0.treatmentType,
                selectedDate: $0.date,
                storedValue: $0.value,
                enteredBy: $0.enteredBy,
                notes: $0.notes,
                mealKind: $0.treatmentType == .Carbs ? $0.mealKind : nil,
                mealState: $0.treatmentType == .Carbs ? ($0.plannedMealStateRaw.flatMap(TreatmentMealState.init(rawValue:)) ?? .confirmed) : nil
            )
        }
        self.selectedType = treatmentToEdit?.treatmentType ?? initialType
        self.selectedDate = treatmentToEdit?.date ?? Date()
        self.enteredByValue = treatmentToEdit?.enteredBy ?? ConstantsHomeView.applicationName
        self.enteredNotesValue = treatmentToEdit?.notes ?? ""
        self.selectedMealKind = treatmentToEdit?.treatmentType == .Carbs ? (treatmentToEdit?.mealKind ?? .normal)
            : (quickCarbohydrateGrams == nil ? .normal : .fast)
        self.isPlanningNewMeal = treatmentToEdit?.isPlannedMeal ?? false
        // Editing always uses the saved treatment. Defaults only prefill a new injection draft.
        self.enteredInsulinDescription = treatmentToEdit?.notes ?? (initialType == .BasalInjection ? UserDefaults.standard.lastBasalInjectionInsulinDescription : "")

        if let treatmentToEdit = treatmentToEdit {
            if treatmentToEdit.treatmentType == .Note {
                self.enteredValue = ""
            } else if treatmentToEdit.treatmentType == .BgCheck {
                self.enteredValue = treatmentToEdit.value.mgDlToMmolAndToString(
                    mgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl
                )
            } else {
                self.enteredValue = treatmentToEdit.value.stringWithoutTrailingZeroes
            }
        } else if initialType == .BasalInjection, UserDefaults.standard.lastBasalInjectionUnits > 0 {
            self.enteredValue = String(UserDefaults.standard.lastBasalInjectionUnits)
        } else if initialType == .Carbs, let quickCarbohydrateGrams,
                  quickCarbohydrateGrams.isFinite, quickCarbohydrateGrams > 0 {
            self.enteredValue = quickCarbohydrateGrams.stringWithoutTrailingZeroes
        } else {
            self.enteredValue = ""
        }
    }

    // MARK: - public computed properties

    var isAddMode: Bool {
        originalTreatment == nil
    }

    /// Insulin is recorded as already taken. Only explicitly planned carbs can be future-dated.
    var latestSelectableDate: Date {
        let allowsFuture = selectedType == .Carbs
            ? (isPlanningNewMeal || originalTreatment?.isPlannedMeal == true)
            : ![TreatmentType.BgCheck, .Insulin, .BasalInjection].contains(selectedType)
        return Date().addingTimeInterval(allowsFuture ? Self.maximumFutureTreatmentInterval : 0)
    }

    var isExistingPlannedMeal: Bool { originalTreatment?.isPlannedMeal == true }
    var isExistingCancelledMeal: Bool { originalTreatment?.isCancelledMeal == true }
    var canConfirmWithSelectedDate: Bool {
        isExistingPlannedMeal && selectedDate != originalTreatment?.date && selectedDate <= Date()
    }
    var selectedCarbohydrateDurationMinutes: Double { selectedMealKind.durationMinutes }
    var deletionMayLeaveHealthCopy: Bool {
        guard let originalTreatment else { return false }
        return originalTreatment.localTreatmentUUID != nil &&
            originalTreatment.healthKitSyncVersion != nil &&
            (originalTreatment.treatmentType == .Insulin || originalTreatment.isConfirmedMeal)
    }

    var navigationTitle: String {
        isAddMode ? Texts_TreatmentsView.addTreatmentTitle : Texts_TreatmentsView.editTreatmentTitle
    }

    var unitText: String {
        selectedType.unit()
    }

    var showsNumericValueEditor: Bool {
        selectedType != .Note
    }

    var showsNotesEditor: Bool {
        selectedType == .Note
    }

    var valuePlaceholder: String {
        if selectedType == .BgCheck {
            return Double(0).mgDlToMmolAndToString(mgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl)
        }

        return "0"
    }

    var helperText: String? {
        if selectedType == .Note {
            return normalizedNotesValue() == nil && !enteredNotesValue.isEmpty ? Texts_TreatmentsView.invalidNoteMessage : nil
        }

        if let value = normalizedValue(), value > 0 {
            return nil
        }

        if enteredValue.isEmpty {
            return nil
        }

        return selectedType == .BasalInjection ? Texts_TreatmentsView.invalidBasalInjectionValueMessage : Texts_TreatmentsView.invalidValueMessage
    }

    var canSaveTreatment: Bool {
        if isExistingCancelledMeal || wouldChangeHealthSyncedTreatmentType { return false }
        if (requiresDurableLocalInsert || requiresDurableLocalMutation),
           let coreDataManager,
           localSaveJournal.recoveryState(coreDataManager: coreDataManager) != .ready { return false }
        guard currentInputIsValid else {
            return false
        }

        if isAddMode {
            return true
        }

        return treatmentHasChanges
    }

    // MARK: - public functions

    func validateSelectedDateIfNeeded() {
        let latestDate = latestSelectableDate
        guard selectedDate > latestDate else { return }

        // Also enforce the picker bound for restored drafts and direct save calls.
        selectedDate = latestDate
        if selectedType == .BgCheck {
            alertMessage = TreatmentEditorAlertMessage(
                title: Texts_Common.warning,
                message: Texts_TreatmentsView.cannotStoreFutureBGCheck
            )
        }
    }

    func saveTreatment() -> Bool {
        validateSelectedDateIfNeeded()
        guard currentInputIsValid else { return false }

        guard let coreDataManager = coreDataManager else {
            return false
        }

        // The toolbar and save path share the same requirement. Whitespace is not an insulin type.
        guard selectedType != .BasalInjection || normalizedInsulinDescription() != nil else { return false }

        let normalizedNotesValue = normalizedNotesValue()
        let storedNotesValue = selectedType == .BasalInjection ? normalizedInsulinDescription() : (selectedType == .Note ? normalizedNotesValue : nil)
        let storedNightscoutEventType = selectedType == .Note || selectedType == .BasalInjection ? ConstantsNightscout.noteEventType : nil
        let storedValue: Double

        if selectedType == .Note {
            guard normalizedNotesValue != nil else {
                alertMessage = TreatmentEditorAlertMessage(
                    title: Texts_Common.warning,
                    message: Texts_TreatmentsView.invalidNoteMessage
                )
                return false
            }

            storedValue = 0
        } else {
            guard let value = normalizedValue(), value > 0 else {
                alertMessage = TreatmentEditorAlertMessage(
                    title: Texts_Common.warning,
                    message: Texts_TreatmentsView.invalidValueMessage
                )
                return false
            }

            storedValue = storedValueForCurrentType(value)
        }

        let treatmentToEdit = treatmentToEdit(in: coreDataManager)
        // An edit whose target was deleted or detached must never fall through to insertion.
        guard isAddMode || treatmentToEdit != nil else { return false }
        let changesBasal = selectedType == .BasalInjection ||
            treatmentToEdit?.treatmentType == .BasalInjection
        let now = Date()
        if isAddMode && selectedType == .Carbs {
            let metadata = MealPlanMetadata(mealUUID: localSaveOperation.mealUUID,
                bolusUUID: nil, loggedAt: localSaveStartedAt,
                plannedAt: selectedMealStateForSave == .planned ? selectedDate : nil,
                grams: storedValue,
                pizzaSettings: nil, mealKind: selectedMealKind)
            do { try mealMetadataStore.stage(metadata) }
            catch {
                alertMessage = TreatmentEditorAlertMessage(title: Texts_Common.warning,
                    message: "Måltidsplanens metadata kunne ikke gemmes. Prøv igen.")
                return false
            }
        }
        if requiresDurableLocalInsert {
            localSaveGateState = localSaveJournal.recoveryState(coreDataManager: coreDataManager)
            let intent = PenDoseLogIntent(
                insulinUnits: selectedType == .Insulin ? storedValue : 0,
                carbohydrateGrams: selectedType == .Carbs ? storedValue : 0,
                mealKind: selectedType == .Carbs ? selectedMealKind : nil,
                insulinDate: selectedType == .Insulin ? selectedDate : nil,
                mealDate: selectedType == .Carbs ? selectedDate : nil)
            guard localSaveGateState == .ready,
                  localSaveJournal.begin(localSaveOperation,
                    expectsBolus: selectedType == .Insulin, expectsMeal: selectedType == .Carbs,
                    intent: intent) else {
                localSaveGateState = localSaveJournal.recoveryState(coreDataManager: coreDataManager)
                alertMessage = TreatmentEditorAlertMessage(title: Texts_Common.warning,
                    message: localSaveGateState.message.isEmpty ?
                        "Kan ikke bekræfte lokal lagring. Kontrollér behandlingshistorikken før ny registrering." :
                        localSaveGateState.message)
                return false
            }
        }
        if wouldChangeHealthSyncedTreatmentType {
            alertMessage = TreatmentEditorAlertMessage(
                title: Texts_Common.warning,
                message: "En behandling, der er sendt til Sundhed, kan ikke ændres til en anden type. Opret i stedet en ny registrering."
            )
            return false
        }
        if treatmentToEdit != nil && !treatmentHasChanges { return true }
        if requiresDurableLocalMutation {
            guard let treatmentToEdit,
                  localSaveJournal.beginMutation(treatmentToEdit) else {
                localSaveGateState = localSaveJournal.recoveryState(coreDataManager: coreDataManager)
                alertMessage = TreatmentEditorAlertMessage(title: Texts_Common.warning,
                    message: localSaveGateState.message.isEmpty ?
                        "En tidligere ændring kan ikke afstemmes sikkert. Kontrollér behandlingshistorikken." :
                        localSaveGateState.message)
                return false
            }
        }
        let mealState = selectedType == .Carbs ? selectedMealStateForSave : nil
        var savedTreatment: TreatmentEntry?

        if let treatmentToEdit {
            var treatmentChanged = false

            if treatmentToEdit.value != storedValue {
                treatmentToEdit.value = storedValue
                treatmentChanged = true
            }

            if treatmentToEdit.date != selectedDate {
                treatmentToEdit.date = selectedDate
                treatmentChanged = true
            }

            if treatmentToEdit.treatmentType != selectedType {
                treatmentToEdit.treatmentType = selectedType
                treatmentChanged = true
            }

            if treatmentToEdit.nightscoutEventType != storedNightscoutEventType {
                treatmentToEdit.nightscoutEventType = storedNightscoutEventType
                treatmentChanged = true
            }

            let normalizedEnteredByValue = normalizedEnteredByValue()
            if treatmentToEdit.enteredBy != normalizedEnteredByValue {
                treatmentToEdit.enteredBy = normalizedEnteredByValue
                treatmentChanged = true
            }

            if treatmentToEdit.notes != storedNotesValue {
                treatmentToEdit.notes = storedNotesValue
                treatmentChanged = true
            }

            let mealKindRaw = selectedType == .Carbs ? selectedMealKind.rawValue : nil
            let mealDuration = selectedType == .Carbs ? NSNumber(value: selectedCarbohydrateDurationMinutes) : nil
            let mealStateRaw = mealState?.rawValue
            if treatmentToEdit.mealKindRaw != mealKindRaw ||
                treatmentToEdit.carbohydrateDurationMinutes != mealDuration ||
                treatmentToEdit.plannedMealStateRaw != mealStateRaw {
                treatmentToEdit.mealKindRaw = mealKindRaw
                treatmentToEdit.carbohydrateDurationMinutes = mealDuration
                treatmentToEdit.plannedMealStateRaw = mealStateRaw
                treatmentChanged = true
            }

            if treatmentChanged {
                // A legacy local record gets an identity on its first edit. Imported and Watch
                // records retain their original source identity.
                if treatmentToEdit.localTreatmentUUID == nil,
                   treatmentToEdit.id == TreatmentEntry.EmptyId,
                   !treatmentToEdit.isHealthKitImported, !treatmentToEdit.isWatchLocalOnly {
                    treatmentToEdit.localTreatmentUUID = UUID().uuidString
                }
                if treatmentToEdit.createdAt == nil { treatmentToEdit.createdAt = now }
                treatmentToEdit.modifiedAt = now
                markHealthWritePendingIfNeeded(treatmentToEdit)
                treatmentToEdit.uploaded = false
                let saved = requiresDurableLocalMutation || changesBasal
                    ? (localSaveOverride?() ?? coreDataManager.saveChangesSynchronously())
                    : coreDataManager.saveChanges()
                guard saved, !requiresDurableLocalMutation ||
                    localSaveJournal.completeMutationVerified(coreDataManager: coreDataManager,
                        entry: treatmentToEdit) else {
                    if requiresDurableLocalMutation {
                        localSaveGateState = localSaveJournal.recoveryState(coreDataManager: coreDataManager)
                        alertMessage = TreatmentEditorAlertMessage(title: Texts_Common.warning,
                            message: "Lagringsstatus er usikker. Kontrollér behandlingshistorikken og eventuelt Sundhed. Log ikke samme dosis igen.")
                    }
                    trace("failed to save an edited treatment", log: log, category: ConstantsLog.categoryApplicationDataTreatments, type: .error)
                    return false
                }
                if requiresDurableLocalMutation { localSaveGateState = .ready }

                // A treatment edit is an explicit user-provoked data change. Keep the developer
                // trace useful while attaching only the controlled type and treatment date to the
                // shareable log. Never include the amount, note, entered-by value or server ID.
                trace(
                    "edited %{public}@ treatment at %{public}@",
                    log: log,
                    category: ConstantsLog.categoryApplicationDataTreatments,
                    type: .info,
                    troubleshooting: .standard(.treatment(.edited(
                        kind: TroubleshootingTreatmentKind(selectedType),
                        treatmentAt: selectedDate
                    ))),
                    selectedType.asString(),
                    selectedDate.description
                )
                if mealState != .planned && mealState != .cancelled {
                    setNightscoutSyncRequiredToTrue()
                }
            }
            savedTreatment = treatmentToEdit
        } else {
            let entry = TreatmentEntry(
                date: selectedDate,
                value: storedValue,
                treatmentType: selectedType,
                nightscoutEventType: storedNightscoutEventType,
                enteredBy: normalizedEnteredByValue(),
                notes: storedNotesValue,
                nsManagedObjectContext: coreDataManager.mainManagedObjectContext
            )
            entry.localTreatmentUUID = requiresDurableLocalInsert
                ? (selectedType == .Insulin ? localSaveOperation.bolusUUID : localSaveOperation.mealUUID)
                : UUID().uuidString
            entry.createdAt = now
            entry.modifiedAt = now
            if selectedType == .Carbs {
                entry.mealKindRaw = selectedMealKind.rawValue
                entry.carbohydrateDurationMinutes = NSNumber(value: selectedCarbohydrateDurationMinutes)
                entry.plannedMealStateRaw = mealState?.rawValue
            }
            markHealthWritePendingIfNeeded(entry)

            let saved = requiresDurableLocalInsert || changesBasal
                ? (localSaveOverride?() ?? coreDataManager.saveChangesSynchronously())
                : coreDataManager.saveChanges()
            guard saved, !requiresDurableLocalInsert || localSaveJournal.completeVerified(
                coreDataManager: coreDataManager, operation: localSaveOperation,
                insulinUnits: selectedType == .Insulin ? storedValue : 0,
                carbohydrateGrams: selectedType == .Carbs ? storedValue : 0) else {
                if requiresDurableLocalInsert {
                    localSaveGateState = localSaveJournal.recoveryState(coreDataManager: coreDataManager)
                    alertMessage = TreatmentEditorAlertMessage(title: Texts_Common.warning,
                        message: localSaveGateState.message)
                }
                trace("failed to save a new treatment", log: log, category: ConstantsLog.categoryApplicationDataTreatments, type: .error)
                return false
            }
            if requiresDurableLocalInsert { localSaveGateState = .ready }

            trace(
                "added %{public}@ treatment at %{public}@",
                log: log,
                category: ConstantsLog.categoryApplicationDataTreatments,
                type: .info,
                troubleshooting: .standard(.treatment(.added(
                    kind: TroubleshootingTreatmentKind(selectedType),
                    treatmentAt: selectedDate
                ))),
                selectedType.asString(),
                selectedDate.description
            )
            if mealState != .planned && mealState != .cancelled {
                setNightscoutSyncRequiredToTrue()
            }
            savedTreatment = entry
        }

        if let savedTreatment, let uuid = savedTreatment.localTreatmentUUID {
            if savedTreatment.treatmentType == .Carbs || initialTreatmentState?.selectedType == .Carbs {
                let warning = MealPlanReminderCoordinator.refresh(coreDataManager: coreDataManager,
                    mealUUID: uuid, confirmedAt: mealState == .confirmed ? now : nil,
                    store: mealMetadataStore, onIssue: MealReminderIssueCenter.report)
                if let warning { MealReminderIssueCenter.report(warning) }
            } else if savedTreatment.treatmentType == .Insulin {
                MealPlanReminderCoordinator.refreshLinkedMeals(coreDataManager: coreDataManager,
                    bolusUUID: uuid, store: mealMetadataStore, onIssue: MealReminderIssueCenter.report)
            }
        }
        if changesBasal {
            BasalReminderScheduler.shared.refreshAfterTreatmentChange(
                coreDataManager: coreDataManager,
                savedBasalAt: selectedType == .BasalInjection ? selectedDate : nil)
        }
        requestedExistingMealState = nil

        // Only a successful explicit save updates the next draft. Cancel and failed saves must
        // leave these preferences alone, and editing a bolus must never replace the basal defaults.
        if selectedType == .BasalInjection, let units = Int(exactly: storedValue) {
            UserDefaults.standard.lastBasalInjectionUnits = units
            UserDefaults.standard.lastBasalInjectionInsulinDescription = storedNotesValue ?? ""
        }

        return true
    }

    /// Confirmation is a separate user action. Opening an overdue plan or reaching its time
    /// never changes it into a meal that was actually eaten.
    func confirmPlannedMeal() -> Bool {
        guard canConfirmWithSelectedDate else {
            alertMessage = TreatmentEditorAlertMessage(
                title: Texts_Common.warning,
                message: "Vælg det faktiske spisetidspunkt, eller brug 'Jeg spiser nu'."
            )
            return false
        }
        requestedExistingMealState = .confirmed
        let saved = saveTreatment()
        if !saved { requestedExistingMealState = nil }
        return saved
    }

    func confirmPlannedMealNow() -> Bool {
        guard isExistingPlannedMeal else { return false }
        selectedDate = Date()
        return confirmPlannedMeal()
    }

    func cancelPlannedMeal() -> Bool {
        guard isExistingPlannedMeal else { return false }
        requestedExistingMealState = .cancelled
        let saved = saveTreatment()
        if !saved { requestedExistingMealState = nil }
        return saved
    }

    func deleteTreatment() -> Bool {
        guard let coreDataManager = coreDataManager, let treatmentToEdit = treatmentToEdit(in: coreDataManager) else {
            return false
        }
        let durableMutation = treatmentToEdit.treatmentType == .Insulin ||
            treatmentToEdit.treatmentType == .Carbs
        if durableMutation {
            guard localSaveJournal.beginMutation(treatmentToEdit) else {
                localSaveGateState = localSaveJournal.recoveryState(coreDataManager: coreDataManager)
                alertMessage = TreatmentEditorAlertMessage(title: Texts_Common.warning,
                    message: localSaveGateState.message.isEmpty ?
                        "En tidligere ændring kan ikke afstemmes sikkert." : localSaveGateState.message)
                return false
            }
        }

        treatmentToEdit.treatmentdeleted = true
        treatmentToEdit.uploaded = false
        treatmentToEdit.modifiedAt = Date()

        let saved = durableMutation || treatmentToEdit.treatmentType == .BasalInjection
            ? (localSaveOverride?() ?? coreDataManager.saveChangesSynchronously())
            : coreDataManager.saveChanges()
        guard saved, !durableMutation ||
            localSaveJournal.completeMutationVerified(coreDataManager: coreDataManager,
                entry: treatmentToEdit) else {
            if durableMutation {
                localSaveGateState = localSaveJournal.recoveryState(coreDataManager: coreDataManager)
                alertMessage = TreatmentEditorAlertMessage(title: Texts_Common.warning,
                    message: "Sletningen kunne ikke bekræftes. Kontrollér behandlingshistorikken og eventuelt Sundhed før ny registrering.")
            }
            trace("failed to save a deleted treatment", log: log, category: ConstantsLog.categoryApplicationDataTreatments, type: .error)
            return false
        }
        if durableMutation { localSaveGateState = .ready }
        if durableMutation { HealthKitLocalTherapyWriter.shared.retryPending() }
        if treatmentToEdit.treatmentType == .BasalInjection {
            BasalReminderScheduler.shared.refreshAfterTreatmentChange(coreDataManager: coreDataManager)
        }

        if let uuid = treatmentToEdit.localTreatmentUUID {
            if treatmentToEdit.treatmentType == .Carbs {
                let warning = MealPlanReminderCoordinator.refresh(coreDataManager: coreDataManager,
                    mealUUID: uuid, store: mealMetadataStore, onIssue: MealReminderIssueCenter.report)
                if let warning { MealReminderIssueCenter.report(warning) }
            } else if treatmentToEdit.treatmentType == .Insulin {
                MealPlanReminderCoordinator.refreshLinkedMeals(coreDataManager: coreDataManager,
                    bolusUUID: uuid, store: mealMetadataStore, onIssue: MealReminderIssueCenter.report)
            }
        }

        trace(
            "deleted %{public}@ treatment at %{public}@",
            log: log,
            category: ConstantsLog.categoryApplicationDataTreatments,
            type: .info,
            troubleshooting: .standard(.treatment(.deleted(
                kind: TroubleshootingTreatmentKind(treatmentToEdit.treatmentType),
                treatmentAt: treatmentToEdit.date
            ))),
            treatmentToEdit.treatmentType.asString(),
            treatmentToEdit.date.description
        )
        setNightscoutSyncRequiredToTrue()

        return true
    }

    // MARK: - private functions

    /// New bolus and carbohydrate entries receive a durable operation marker before insertion.
    /// An uncertain parent save must not be retried with another UUID, even after reopening.
    private var requiresDurableLocalInsert: Bool {
        isAddMode && (selectedType == .Insulin || selectedType == .Carbs)
    }

    private var requiresDurableLocalMutation: Bool {
        !isAddMode && (selectedType == .Insulin || selectedType == .Carbs ||
                       originalTreatment?.treatmentType == .Insulin ||
                       originalTreatment?.treatmentType == .Carbs)
    }

    func acknowledgePreviouslyFoundTreatment() {
        guard localSaveGateState == .foundPriorEntry ||
                localSaveGateState == .noLocalEntryHealthUncertain ||
                localSaveGateState == .uncertainMutationAfterRestart else { return }
        let completed = localSaveJournal.complete()
        localSaveGateState = completed ? .ready : .partialOrUnreadable
        if completed { HealthKitLocalTherapyWriter.shared.retryPending() }
    }

    private var wouldChangeHealthSyncedTreatmentType: Bool {
        guard let originalTreatment, originalTreatment.localTreatmentUUID != nil,
              originalTreatment.healthKitSyncVersion != nil || originalTreatment.healthKitSyncStateRaw != nil,
              originalTreatment.treatmentType == .Insulin || originalTreatment.treatmentType == .Carbs else {
            return false
        }
        // A stable Health sync ID cannot safely change between insulin and carbohydrate samples.
        return selectedType != originalTreatment.treatmentType
    }

    private func normalizedValue() -> Double? {
        guard let value = enteredValue.toDouble(), value.isFinite else { return nil }
        // A number pad helps entry, but pasted values still need whole-unit validation.
        if selectedType == .BasalInjection, Int(exactly: value) == nil { return nil }
        return value
    }

    private func normalizedInsulinDescription() -> String? {
        enteredInsulinDescription.trimmingCharacters(in: .whitespacesAndNewlines).toNilIfLength0()
    }

    private func normalizedEnteredByValue() -> String? {
        enteredByValue.toNilIfLength0()
    }

    private func normalizedNotesValue() -> String? {
        let trimmedNotes = enteredNotesValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedNotes.isEmpty ? nil : trimmedNotes
    }

    private func storedValueForCurrentType(_ value: Double) -> Double {
        if selectedType == .BgCheck {
            return value
                .mmolToMgdl(mgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl)
                .bgValueRounded(mgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl)
        }

        return value
    }

    private var currentInputIsValid: Bool {
        guard selectedDate <= latestSelectableDate else { return false }
        if selectedType == .Carbs, isAddMode, isPlanningNewMeal, selectedDate <= Date() { return false }

        if selectedType == .BasalInjection, normalizedInsulinDescription() == nil {
            return false
        }

        if selectedType == .Note {
            return normalizedNotesValue() != nil
        }

        guard let value = normalizedValue() else {
            return false
        }

        return value > 0
    }

    private var treatmentHasChanges: Bool {
        guard let initialTreatmentState else {
            return true
        }

        return currentStoredState() != initialTreatmentState
    }

    private func currentStoredState() -> TreatmentEditorInitialState? {
        let storedNotesValue = selectedType == .BasalInjection ? normalizedInsulinDescription() : (selectedType == .Note ? normalizedNotesValue() : nil)
        let storedValue: Double

        if selectedType == .Note {
            storedValue = 0
        } else {
            guard let value = normalizedValue(), value > 0 else {
                return nil
            }

            storedValue = storedValueForCurrentType(value)
        }

        return TreatmentEditorInitialState(
            selectedType: selectedType,
            selectedDate: selectedDate,
            storedValue: storedValue,
            enteredBy: normalizedEnteredByValue(),
            notes: storedNotesValue,
            mealKind: selectedType == .Carbs ? selectedMealKind : nil,
            mealState: selectedType == .Carbs ? selectedMealStateForSave : nil
        )
    }

    private var selectedMealStateForSave: TreatmentMealState {
        if let requestedExistingMealState { return requestedExistingMealState }
        if originalTreatment?.isCancelledMeal == true { return .cancelled }
        if originalTreatment?.isPlannedMeal == true { return .planned }
        return isPlanningNewMeal ? .planned : .confirmed
    }

    private func markHealthWritePendingIfNeeded(_ entry: TreatmentEntry) {
        guard entry.localTreatmentUUID != nil,
              entry.treatmentType == .Insulin || entry.isConfirmedMeal else { return }
        let nextVersion = max(1, (entry.healthKitSyncVersion?.intValue ?? 0) + 1)
        entry.healthKitSyncVersion = NSNumber(value: nextVersion)
        entry.healthKitSyncStateRaw = HealthLocalTherapySyncState.pending(version: nextVersion)
    }

    private func treatmentToEdit(in coreDataManager: CoreDataManager) -> TreatmentEntry? {
        guard let originalTreatment,
              originalTreatment.managedObjectContext === coreDataManager.mainManagedObjectContext,
              !originalTreatment.isDeleted,
              !originalTreatment.treatmentdeleted else {
            return nil
        }

        return originalTreatment
    }

    private func setNightscoutSyncRequiredToTrue() {
        let latestSyncRequestDate = UserDefaults.standard.timeStampLatestNightscoutSyncRequest ?? Date.distantPast

        if latestSyncRequestDate.timeIntervalSinceNow <
            -ConstantsNightscout.minimiumTimeBetweenTwoTreatmentSyncsInSeconds {
            UserDefaults.standard.timeStampLatestNightscoutSyncRequest = .now
            UserDefaults.standard.nightscoutSyncRequired = true
        }
    }
}

private struct TreatmentEditorInitialState: Equatable {
    let selectedType: TreatmentType
    let selectedDate: Date
    let storedValue: Double
    let enteredBy: String?
    let notes: String?
    let mealKind: TreatmentMealKind?
    let mealState: TreatmentMealState?
}

struct TreatmentEditorAlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// This is a calculator input only; it is never a CGM reading, treatment or alarm input.
struct ManualDoseGlucoseRecord: Codable, Equatable {
    let valueMgdl: Double
    let measuredAt: Date
    let recordedAt: Date
    let source: String

    init?(valueMgdl: Double, measuredAt: Date, recordedAt: Date = Date()) {
        guard valueMgdl.isFinite, (20...600).contains(valueMgdl),
              measuredAt <= recordedAt, recordedAt.timeIntervalSince(measuredAt) <= 24 * 60 * 60 else {
            return nil
        }
        self.valueMgdl = valueMgdl
        self.measuredAt = measuredAt
        self.recordedAt = recordedAt
        self.source = "manual"
    }
}

/// Serializes the one explicitly entered value in protected, normally backed-up Application Support.
/// Loading it never selects it for a later calculator session.
actor ManualDoseGlucoseStore {
    static let shared = ManualDoseGlucoseStore()
    private let fileManager: FileManager
    private let fileURL: URL

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let root = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = root.appendingPathComponent("PenDose", isDirectory: true)
            .appendingPathComponent("manual-glucose.json")
    }

    func load() -> ManualDoseGlucoseRecord? {
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? JSONDecoder().decode(ManualDoseGlucoseRecord.self, from: data),
              record.source == "manual",
              record.valueMgdl.isFinite, (20...600).contains(record.valueMgdl) else { return nil }
        return record
    }

    @discardableResult
    func save(valueMgdl: Double, measuredAt: Date, now: Date = Date()) throws -> ManualDoseGlucoseRecord {
        guard let record = ManualDoseGlucoseRecord(valueMgdl: valueMgdl, measuredAt: measuredAt, recordedAt: now) else {
            throw ManualDoseGlucoseStoreError.invalidValue
        }
        let folder = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                      ofItemAtPath: folder.path)
        let data = try JSONEncoder().encode(record)
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                      ofItemAtPath: fileURL.path)
        return record
    }
}

enum ManualDoseGlucoseStoreError: Error {
    case invalidValue
}

enum PenDoseGlucoseChoice: String, CaseIterable {
    case currentCGM
    case confirmStaleCGM
    case manual
}

/// One immutable user registration. The proposal is deliberately absent from this record.
struct PenDoseLogDraft {
    let loggedAt: Date
    let insulinUnits: Double
    let carbohydrateGrams: Double
    let mealKind: TreatmentMealKind
    let plannedDate: Date?
    let operation: PenDoseLogOperation
    let pizzaSettings: PizzaSplitSettings
}

/// Values captured with the calculation; an open explanation never mixes newer inputs in.
struct PenDoseCalculationDetails {
    let calculation: PenDoseCalculation
    let calculatedAt: Date
    let glucoseMgdl: Double?
    let glucoseMeasuredAt: Date?
    let iobUnits: Double
    /// COB actually used by the proposed dose; it never exceeds curve COB.
    let cobGrams: Double
    let curveCOBGrams: Double
    let estimatedCOBGrams: Double?
    let cobFallbackReason: PenCOBFallbackReason?
    let newCarbsGrams: Double
    let carbohydrateRatio: Double
    let targetMmol: Double
    let correctionMmolPerUnit: Double
    let penStepUnits: Double
    let maximumUnits: Double
    let pizzaPercentageNow: Int?
    let pizzaReminderMinutes: Int?
    let suggestedNowUnits: Double?
}

/// UI state for a read-only pen suggestion and an independent local treatment log.
@MainActor final class PenDoseCalculatorViewModel: ObservableObject {
    @Published var carbohydratesText = "" { didSet { scheduleCalculation() } }
    @Published var mealKind: TreatmentMealKind = .normal { didSet { scheduleCalculation() } }
    @Published var isPlannedMeal = false { didSet { scheduleCalculation() } }
    @Published var plannedDate = Date().addingTimeInterval(15 * 60) { didSet { scheduleCalculation() } }
    @Published var glucoseChoice: PenDoseGlucoseChoice = .currentCGM { didSet { scheduleCalculation() } }
    @Published var manualGlucoseText = "" { didSet { scheduleCalculation() } }
    @Published var manualGlucoseDate = Date() { didSet { scheduleCalculation() } }
    @Published var insulinToLogText = ""
    @Published private(set) var calculation: PenDoseCalculation?
    @Published private(set) var calculationDetails: PenDoseCalculationDetails?
    @Published private(set) var latestGlucoseDate: Date?
    @Published private(set) var latestGlucoseValueMgdl: Double?
    @Published private(set) var isCalculating = false
    @Published private(set) var isSaving = false
    @Published private(set) var currentTime = Date()
    @Published private(set) var confirmationDraft: PenDoseLogDraft?
    @Published private(set) var expiredPlan = false
    @Published private(set) var postSaveReminderWarning: String?
    @Published private(set) var storageGateState: PenDoseLogJournal.RecoveryState = .ready
    @Published var statusMessage: String?

    let reminderMealUUID: String?
    private let coreDataManager: CoreDataManager
    private let glucoseStore: ManualDoseGlucoseStore
    private let logJournal: PenDoseLogJournal
    private let metadataStore: MealPlanMetadataStore
    private let profileProvider: () -> PenDoseProfile
    private let sourceReadyOverride: (() -> Bool)?
    private let snapshotProvider: ((Date, Bool) async -> Result<PenDoseInputSnapshot, PenDoseUnavailableReason>)?
    private var calculatedDraftSignature: String?
    private var snapshotAtCalculation: PenDoseInputSnapshot?
    private var calculatedAt: Date?
    private var logOperation: PenDoseLogOperation?
    private var selectedManualRecord: ManualDoseGlucoseRecord?
    private var pinnedCGM: (value: Double, date: Date, sensorID: String)?
    private var latestGlucoseSamples: [GlucoseForecastSample] = []
    private var calculationGeneration = 0
    private var debounceTask: Task<Void, Never>?
    private var isOpen = false

    init(coreDataManager: CoreDataManager, reminderMealUUID: String? = nil,
         glucoseStore: ManualDoseGlucoseStore = .shared,
         logJournal: PenDoseLogJournal? = nil,
         metadataStore: MealPlanMetadataStore? = nil,
         profileProvider: @escaping () -> PenDoseProfile = { PenDoseProfile.load() },
         sourceReadyOverride: (() -> Bool)? = nil,
         snapshotProvider: ((Date, Bool) async -> Result<PenDoseInputSnapshot, PenDoseUnavailableReason>)? = nil) {
        let logJournal = logJournal ?? .shared
        self.coreDataManager = coreDataManager
        self.reminderMealUUID = reminderMealUUID
        self.glucoseStore = glucoseStore
        self.logJournal = logJournal
        self.metadataStore = metadataStore ?? .shared
        self.profileProvider = profileProvider
        self.sourceReadyOverride = sourceReadyOverride
        self.snapshotProvider = snapshotProvider
        self.storageGateState = logJournal.recoveryState(coreDataManager: coreDataManager)
        if storageGateState != .ready { statusMessage = storageGateState.message }
    }

    var profile: PenDoseProfile { profileProvider() }
    var glucoseUnitIsMgdl: Bool { UserDefaults.standard.bloodGlucoseUnitIsMgDl }
    var isReviewCurrent: Bool {
        !isCalculating && calculation?.unavailableReason == nil && calculation != nil &&
            calculatedDraftSignature == draftSignature
    }
    var suggestedUnits: Double? {
        guard isReviewCurrent else { return nil }
        return calculationDetails?.suggestedNowUnits
    }
    var latestGlucoseAgeMinutes: Int? {
        latestGlucoseDate.map { max(0, Int(currentTime.timeIntervalSince($0) / 60)) }
    }
    var displayedGlucoseValueMgdl: Double? {
        glucoseChoice == .confirmStaleCGM ? pinnedCGM?.value : latestGlucoseValueMgdl
    }
    var displayedGlucoseDate: Date? {
        glucoseChoice == .confirmStaleCGM ? pinnedCGM?.date : latestGlucoseDate
    }
    var displayedGlucoseSource: String {
        switch glucoseChoice {
        case .currentCGM: return "CGM"
        case .confirmStaleCGM: return "Valgt CGM · uden trend"
        case .manual: return "Manuel · uden trend"
        }
    }
    var glucoseStatusMessage: String? {
        guard glucoseChoice == .currentCGM else { return nil }
        guard let latest = latestGlucoseSamples.last else { return "Ingen CGM-måling" }
        if currentTime.timeIntervalSince(latest.date) > PenBolusCalculator.freshCGMSeconds {
            return "Seneste måling er \(latestGlucoseAgeMinutes ?? 0) min gammel"
        }
        if PenBolusCalculator.twentyMinuteChange(latestGlucoseSamples, at: latest.date) == nil {
            let from = latest.date.addingTimeInterval(-PenBolusCalculator.trendWindowSeconds)
            let sameSensor = latestGlucoseSamples.filter {
                $0.sensorID == latest.sensorID && $0.date >= from && $0.date <= latest.date
            }
            let span = sameSensor.first.map { latest.date.timeIntervalSince($0.date) } ?? 0
            return span < PenBolusCalculator.minimumTrendSpanSeconds
                ? "Ingen trend – ikke nok CGM-historik endnu"
                : "Ingen trend – huller i CGM de sidste 20 min"
        }
        return nil
    }
    private var localLoggingIsActive: Bool {
        if let sourceReadyOverride { return sourceReadyOverride() }
        let defaults = UserDefaults.standard
        return TherapyMetricsManager.doseSourceIsReady(defaults.dataFlowPolicy,
            cutover: TreatmentSourceCutover.current(defaults: defaults), defaults: defaults)
    }
    var logValidationMessage: String? {
        if isSaving || confirmationDraft != nil { return "Registrerer…" }
        guard storageGateState == .ready,
              logJournal.recoveryState(coreDataManager: coreDataManager) == .ready else {
            return storageGateState.message
        }
        guard localLoggingIsActive else { return "Lokal logning er ikke klar" }
        let settings = profile.settings
        guard settings.isValid else { return "Kontrollér pen-trin og maksimum" }
        guard let units = parsedUnits else { return "Ugyldig insulinmængde" }
        guard units >= 0 else { return "Ugyldig insulinmængde" }
        guard units <= settings.maximumSuggestionUnits else {
            return "Max \(settings.maximumSuggestionUnits) E"
        }
        guard unitsAreOnPenStep(units) else {
            return "Brug \(settings.penStepUnits) E-trin"
        }
        guard let carbs = parsedCarbs else { return "Kulhydrat skal være 0–500 g" }
        guard units > 0 || carbs > 0 else { return "Indtast kulhydrater eller insulin" }
        if isPlannedMeal {
            guard reminderMealUUID == nil, carbs > 0 else { return "Vælg kulhydrater til planen" }
            guard plannedDate > currentTime else { return "Tidspunktet er passeret" }
            guard plannedDate <= currentTime.addingTimeInterval(60 * 60) else {
                return "Vælg højst 60 minutter frem"
            }
        }
        return nil
    }
    var logButtonTitle: String {
        if let reason = logValidationMessage { return reason }
        guard let units = parsedUnits, let carbs = parsedCarbs, units > 0 || carbs > 0 else {
            return "Indtast kulhydrater eller insulin"
        }
        let insulin = units > 0 ? "\(PenDoseDisplayFormatter.insulin(units)) E" : nil
        let food = carbs > 0 && reminderMealUUID == nil
            ? "\(PenDoseDisplayFormatter.carbs(carbs)) g" : nil
        if isPlannedMeal, let food {
            let time = plannedDate.formatted(date: .omitted, time: .shortened)
            return insulin.map { "Log \($0) · planlæg \(food) kl. \(time)" }
                ?? "Planlæg \(food) · kl. \(time)"
        }
        if let insulin, let food { return "Log \(food) og \(insulin)" }
        return "Log \(food ?? insulin ?? "")"
    }
    var canLog: Bool {
        logValidationMessage == nil
    }

    func start() {
        isOpen = true
        scheduleCalculation(debounce: false)
    }

    func stop() {
        isOpen = false
        calculationGeneration &+= 1
        debounceTask?.cancel()
        debounceTask = nil
        isCalculating = false
        pinnedCGM = nil
        glucoseChoice = .currentCGM
    }

    /// Reuse the UI clock to age inputs and refresh the time-dependent IOB, COB and profile.
    func refreshClock(now: Date = .now) {
        let crossedMinute = Int(currentTime.timeIntervalSince1970 / 60) !=
            Int(now.timeIntervalSince1970 / 60)
        let wasFresh = latestGlucoseDate.map {
            currentTime.timeIntervalSince($0) <= PenBolusCalculator.freshCGMSeconds
        } ?? false
        currentTime = now
        if isPlannedMeal && plannedDate <= now { expiredPlan = true }
        let isFresh = latestGlucoseDate.map {
            now.timeIntervalSince($0) <= PenBolusCalculator.freshCGMSeconds
        } ?? false
        if crossedMinute || (wasFresh && !isFresh && glucoseChoice == .currentCGM) {
            scheduleCalculation()
        }
    }

    /// Opening skips the input debounce but still invalidates the copyable suggestion immediately.
    /// A slow older calculation may finish, but only the newest generation can publish it.
    func scheduleCalculation(debounce: Bool = true) {
        guard isOpen else { return }
        calculationGeneration &+= 1
        let generation = calculationGeneration
        calculatedDraftSignature = nil
        isCalculating = true
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(400))
            }
            guard !Task.isCancelled else { return }
            await self?.calculateForGeneration(generation)
        }
    }

    func calculate() async {
        calculationGeneration &+= 1
        debounceTask?.cancel()
        calculatedDraftSignature = nil
        isCalculating = true
        await calculateForGeneration(calculationGeneration)
    }

    private func calculateForGeneration(_ generation: Int) async {
        guard generation == calculationGeneration else { return }
        let signature = draftSignature
        let now = Date()
        storageGateState = logJournal.recoveryState(coreDataManager: coreDataManager)
        guard profile.isConfirmed else {
            clearCalculation("Bekræft først doseringsprofilen i indstillingerne.", generation: generation)
            return
        }
        guard let newCarbs = newCarbsInput() else {
            clearCalculation("Indtast en gyldig mængde kulhydrat.", generation: generation)
            return
        }
        let inputResult: Result<PenDoseInputSnapshot, PenDoseUnavailableReason>
        if let snapshotProvider {
            inputResult = await snapshotProvider(now, glucoseChoice != .currentCGM)
        } else {
            inputResult = await TherapyMetricsManager.shared.penDoseSnapshot(at: now,
                allowMissingGlucose: glucoseChoice != .currentCGM)
        }
        guard generation == calculationGeneration, signature == draftSignature else { return }
        guard case .success(let snapshot) = inputResult else {
            if case .failure(let reason) = inputResult {
                if reason == .missingGlucose {
                    latestGlucoseSamples = []
                    latestGlucoseDate = nil
                    latestGlucoseValueMgdl = nil
                }
                clearCalculation(Self.unavailableText(reason), generation: generation)
            }
            return
        }
        latestGlucoseSamples = snapshot.glucose
        latestGlucoseDate = snapshot.glucose.last?.date
        latestGlucoseValueMgdl = snapshot.glucose.last?.glucoseMgdl
        if glucoseChoice == .confirmStaleCGM, let pinnedCGM,
           let latest = snapshot.glucose.last, latest.date > pinnedCGM.date,
           now.timeIntervalSince(latest.date) <= PenBolusCalculator.freshCGMSeconds,
           PenBolusCalculator.twentyMinuteChange(snapshot.glucose, at: latest.date) != nil {
            self.pinnedCGM = nil
            glucoseChoice = .currentCGM
            return
        }
        guard let glucose = await glucoseInput(snapshot: snapshot, now: now) else {
            clearCalculation("Indtast og vælg en gyldig blodsukkerværdi.", generation: generation)
            return
        }
        guard generation == calculationGeneration, signature == draftSignature else { return }
        let chosenProfile = profile
        let safety = glucoseChoice == .currentCGM
            ? PenBolusCalculator.safetyForecast(snapshot: snapshot, at: now) : nil
        let result = PenBolusCalculator.calculate(snapshot: snapshot, profile: chosenProfile,
            glucose: glucose, newCarbs: newCarbs, safetyForecast: safety, at: now)
        guard generation == calculationGeneration, signature == draftSignature else { return }
        let pizza = PizzaSplitSettings.load()
        let pizzaApplies = pizza.isEnabled && mealKind == .slow && reminderMealUUID == nil &&
            (parsedCarbs ?? 0) > 0
        let suggestionNow = result.suggestedUnits.map { suggestion in
            pizzaApplies ? floor((suggestion * Double(pizza.percentageNow) / 100) /
                chosenProfile.settings.penStepUnits + 1e-10) * chosenProfile.settings.penStepUnits
                : suggestion
        }
        let values = chosenProfile.values(at: now)
        calculation = result
        snapshotAtCalculation = snapshot
        calculatedAt = now
        calculatedDraftSignature = signature
        if let values {
            calculationDetails = PenDoseCalculationDetails(calculation: result, calculatedAt: now,
                glucoseMgdl: result.glucoseMgdl, glucoseMeasuredAt: result.glucoseMeasuredAt,
                iobUnits: snapshot.iobUnits,
                cobGrams: result.cobEvidence?.usedGrams ?? snapshot.cobGrams,
                curveCOBGrams: result.cobEvidence?.curveGrams ?? snapshot.cobGrams,
                estimatedCOBGrams: result.cobEvidence?.estimatedGrams,
                cobFallbackReason: result.cobEvidence?.fallbackReason,
                newCarbsGrams: reminderMealUUID == nil ? (parsedCarbs ?? 0) : 0,
                carbohydrateRatio: values.carbohydrateRatio, targetMmol: values.targetMmol,
                correctionMmolPerUnit: values.correctionMmolPerUnit,
                penStepUnits: chosenProfile.settings.penStepUnits,
                maximumUnits: chosenProfile.settings.maximumSuggestionUnits,
                pizzaPercentageNow: pizzaApplies ? pizza.percentageNow : nil,
                pizzaReminderMinutes: pizzaApplies ? pizza.reminderMinutes : nil,
                suggestedNowUnits: suggestionNow)
        } else {
            calculationDetails = nil
        }
        statusMessage = result.unavailableReason.map(Self.unavailableText)
        isCalculating = false
    }

    /// Copy is explicit. Recalculation never touches the user's dose field.
    func copySuggestion() {
        guard let units = suggestedUnits else { return }
        insulinToLogText = PenDoseDisplayFormatter.insulinInput(units)
    }

    /// Capture the actual quantities once. Returns true only when the red/orange or missing
    /// calculation confirmation must be presented before confirmLog().
    @discardableResult func requestLog() -> Bool {
        guard confirmationDraft == nil, !isSaving, logValidationMessage == nil,
              let units = parsedUnits, let carbs = parsedCarbs else { return false }
        let operation = PenDoseLogOperation()
        logOperation = operation
        confirmationDraft = PenDoseLogDraft(loggedAt: Date(), insulinUnits: units,
            carbohydrateGrams: reminderMealUUID == nil ? carbs : 0,
            mealKind: mealKind, plannedDate: isPlannedMeal ? plannedDate : nil,
            operation: operation, pizzaSettings: PizzaSplitSettings.load())
        let safe: Bool
        if isReviewCurrent, case .checked = calculation?.safety { safe = true }
        else { safe = false }
        requiresLogConfirmation = units > 0 && !safe
        return requiresLogConfirmation
    }

    @Published private(set) var requiresLogConfirmation = false

    func cancelLogConfirmation() {
        guard !isSaving else { return }
        confirmationDraft = nil
        requiresLogConfirmation = false
        logOperation = nil
    }

    /// Uses only the frozen registration; no glucose, IOB, COB or suggestion read occurs here.
    func confirmLog(at now: Date = Date()) async -> Bool {
        guard !isSaving, let draft = confirmationDraft else { return false }
        // A confirmation left open for a long time cannot establish when insulin was taken.
        // Keep the user's fields, but require a new explicit Log action with a new timestamp.
        if now.timeIntervalSince(draft.loggedAt) > 5 * 60 {
            statusMessage = "Bekræftelsen er udløbet. Tryk Log igen med det aktuelle tidspunkt."
            cancelLogConfirmation()
            return false
        }
        guard storageGateState == .ready,
              logJournal.recoveryState(coreDataManager: coreDataManager) == .ready,
              localLoggingIsActive, profile.settings.isValid,
              draft.insulinUnits >= 0,
              draft.insulinUnits <= profile.settings.maximumSuggestionUnits,
              unitsAreOnPenStep(draft.insulinUnits),
              (0...500).contains(draft.carbohydrateGrams),
              draft.insulinUnits > 0 || draft.carbohydrateGrams > 0 else {
            statusMessage = "Registreringen kan ikke gemmes med de aktuelle indstillinger."
            cancelLogConfirmation()
            return false
        }
        if let date = draft.plannedDate,
           date <= now || date > now.addingTimeInterval(60 * 60) {
            expiredPlan = true
            statusMessage = "Tidspunktet er passeret. Vælg, om du spiser nu eller et nyt tidspunkt."
            cancelLogConfirmation()
            return false
        }
        isSaving = true
        defer { isSaving = false }
        let result = PenDoseTreatmentLogger.log(coreDataManager: coreDataManager,
            insulinUnits: draft.insulinUnits, carbohydrateGrams: draft.carbohydrateGrams,
            mealKind: draft.mealKind, plannedDate: draft.plannedDate,
            operation: draft.operation, now: draft.loggedAt, journal: logJournal,
            penSettings: profile.settings,
            pizzaSettings: draft.pizzaSettings,
            metadataStore: metadataStore,
            onReminderIssue: { [weak self] message in
                Task { @MainActor in
                    self?.postSaveReminderWarning = message
                    self?.statusMessage = "Registreret – påmindelsen kunne ikke oprettes"
                    MealReminderIssueCenter.report(message)
                }
            })
        switch result {
        case .success(let receipt):
            confirmationDraft = nil
            requiresLogConfirmation = false
            logOperation = nil
            insulinToLogText = ""
            carbohydratesText = ""
            postSaveReminderWarning = receipt.reminderWarning
            statusMessage = postSaveReminderWarning == nil
                ? "Behandlingen er registreret." : "Registreret – påmindelsen kunne ikke oprettes"
            return true
        case .failure(.invalidInput):
            statusMessage = "Registreringen er ikke gyldig. Kontrollér mængder og spisetid."
            cancelLogConfirmation()
            return false
        case .failure(.metadataFailed):
            statusMessage = "Måltidsplanen kunne ikke sikres. Ingen behandling er registreret."
            cancelLogConfirmation()
            return false
        case .failure(.storageFailed):
            storageGateState = .awaitingRestart
            clearCalculation("Lagring kunne ikke bekræftes. Kontrollér behandlingshistorikken. Denne beregner kan ikke logge igen, før du åbner den på ny.")
            return false
        }
    }

    /// Compatibility entry point for existing callers; the new screen calls requestLog first.
    func logReviewedTreatment() async -> Bool {
        guard !requestLog() else { return false }
        return await confirmLog()
    }

    func selectCurrentCGM() {
        pinnedCGM = nil
        glucoseChoice = .currentCGM
    }

    func selectDisplayedCGMWithoutTrend() {
        guard let latest = latestGlucoseSamples.last,
              let sensorID = latest.sensorID, !sensorID.isEmpty,
              latest.glucoseMgdl.isFinite, (20...600).contains(latest.glucoseMgdl) else { return }
        pinnedCGM = (latest.glucoseMgdl, latest.date, sensorID)
        glucoseChoice = .confirmStaleCGM
    }

    func selectManual() {
        manualGlucoseDate = Date()
        glucoseChoice = .manual
    }

    func shiftPlannedMeal(byMinutes minutes: Int) {
        guard reminderMealUUID == nil else { return }
        let base = isPlannedMeal ? plannedDate : Date()
        let proposed = base.addingTimeInterval(Double(minutes) * 60)
        let now = Date()
        if proposed <= now { isPlannedMeal = false; expiredPlan = false }
        else if proposed <= now.addingTimeInterval(60 * 60) {
            plannedDate = proposed
            isPlannedMeal = true
            expiredPlan = false
        }
    }

    func resolveExpiredPlanEatNow() {
        isPlannedMeal = false
        expiredPlan = false
        statusMessage = nil
    }

    func resolveExpiredPlanNewTime() {
        plannedDate = Date().addingTimeInterval(15 * 60)
        isPlannedMeal = true
        expiredPlan = false
        statusMessage = nil
    }

    func acknowledgePreviouslyFoundTreatment() {
        guard storageGateState == .foundPriorEntry ||
                storageGateState == .noLocalEntryHealthUncertain ||
                storageGateState == .uncertainMutationAfterRestart else { return }
        guard logJournal.complete() else { return }
        storageGateState = .ready
        statusMessage = "Den tidligere registrering blev fundet. Kontrollér historikken før en ny behandling."
    }

    private var parsedCarbs: Double? {
        guard reminderMealUUID == nil else { return 0 }
        let text = carbohydratesText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        if text.isEmpty { return 0 }
        guard let value = Double(text), value.isFinite, (0...500).contains(value) else { return nil }
        return value
    }
    private var parsedUnits: Double? {
        let text = insulinToLogText.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        if text.isEmpty { return 0 }
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }
    private func unitsAreOnPenStep(_ units: Double) -> Bool {
        let step = profile.settings.penStepUnits
        return step > 0 && abs(units / step - (units / step).rounded()) < 0.0001
    }
    private func newCarbsInput() -> PenDoseNewCarbs? {
        guard let grams = parsedCarbs else { return nil }
        return reminderMealUUID == nil
            ? .unrecorded(grams: grams) : .alreadyRecorded
    }
    private var draftSignature: String {
        let profile = profileProvider()
        let pizza = PizzaSplitSettings.load()
        let forecastInputSignature = GlucoseForecastDataAdapter.presentationInputSignature(
            horizonMinutes: 120)
        return [carbohydratesText, mealKind.rawValue, String(isPlannedMeal),
         String(plannedDate.timeIntervalSince1970), glucoseChoice.rawValue,
         manualGlucoseText, String(manualGlucoseDate.timeIntervalSince1970),
         reminderMealUUID ?? "", String(describing: profile.settings),
         String(profile.isConfirmed), String(profile.confirmedAt?.timeIntervalSince1970 ?? 0),
         String(pizza.isEnabled),
         String(pizza.percentageNow), String(pizza.reminderMinutes),
         String(describing: UserDefaults.standard.dataFlowPolicy),
         String(TherapyMetricsManager.shared.treatmentChangeRevision),
         String(TherapyMetricsManager.shared.forecastInputChangeRevision),
         String(TherapyMetricsManager.shared.hasUncommittedForecastInputChanges),
         forecastInputSignature].joined(separator: "|")
    }
    private func glucoseInput(snapshot: PenDoseInputSnapshot, now: Date) async -> PenDoseGlucoseInput? {
        switch glucoseChoice {
        case .currentCGM: return .currentCGM
        case .confirmStaleCGM:
            guard let pinnedCGM else { return nil }
            return .confirmedStale(valueMgdl: pinnedCGM.value,
                measuredAt: pinnedCGM.date, sensorID: pinnedCGM.sensorID)
        case .manual:
            let text = manualGlucoseText.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: ".")
            guard let input = Double(text), input.isFinite else { return nil }
            let mgdl = glucoseUnitIsMgdl ? input : input * PenBolusCalculator.mgdlPerMmol
            if let existing = selectedManualRecord,
               existing.valueMgdl == mgdl, existing.measuredAt == manualGlucoseDate {
                return .manual(valueMgdl: existing.valueMgdl, measuredAt: existing.measuredAt)
            }
            guard let record = try? await glucoseStore.save(valueMgdl: mgdl,
                measuredAt: manualGlucoseDate, now: now) else { return nil }
            selectedManualRecord = record
            return .manual(valueMgdl: record.valueMgdl, measuredAt: record.measuredAt)
        }
    }
    private func clearCalculation(_ message: String, generation: Int? = nil) {
        if let generation, generation != calculationGeneration { return }
        calculation = nil
        calculationDetails = nil
        snapshotAtCalculation = nil
        calculatedDraftSignature = nil
        statusMessage = message
        isCalculating = false
    }
    private static func safetyIdentity(_ state: PenDoseSafetyState?) -> String {
        switch state {
        case .checked: return "checked"
        case .eatFirst: return "eatFirst"
        case .blockedCurrentLow: return "blockedCurrentLow"
        case .blockedForecastLow: return "blockedForecastLow"
        case .forecastUnchecked: return "forecastUnchecked"
        case .eatFirstForecastUnchecked: return "eatFirstForecastUnchecked"
        case nil: return "missing"
        }
    }
    static func reviewInputsMatch(_ old: PenDoseInputSnapshot,
                                  _ fresh: PenDoseInputSnapshot) -> Bool {
        guard old.treatmentRevision == fresh.treatmentRevision,
              old.sourceSignature == fresh.sourceSignature,
              old.glucose == fresh.glucose,
              old.historicalGlucose == fresh.historicalGlucose,
              old.historicalGlucoseIssue == fresh.historicalGlucoseIssue,
              old.therapySettings == fresh.therapySettings,
              old.iobUnits == fresh.iobUnits,
              old.cobGrams == fresh.cobGrams,
              old.treatments.count == fresh.treatments.count else { return false }
        return zip(old.treatments, fresh.treatments).allSatisfy { left, right in
            left.date == right.date && left.amount == right.amount &&
                left.isIOB == right.isIOB &&
                left.carbohydrateDurationMinutes == right.carbohydrateDurationMinutes &&
                left.knownAt == right.knownAt &&
                left.createdAt == right.createdAt &&
                left.modifiedAt == right.modifiedAt &&
                left.isAppLocal == right.isAppLocal &&
                left.isDeletedCurrentRevision == right.isDeletedCurrentRevision &&
                left.stableIdentity == right.stableIdentity
        }
    }
    static func unavailableText(_ reason: PenDoseUnavailableReason) -> String {
        switch reason {
        case .unconfirmedProfile: return "Bekræft først doseringsprofilen."
        case .invalidProfile: return "Doseringsprofilen indeholder ugyldige tal."
        case .incompleteTherapySources:
            return "Kan ikke beregne: gennemfør først skiftet til lokal behandlingslogning, så både insulin og kulhydrater har én sikker kilde."
        case .uncommittedTreatments, .treatmentReadFailed,
             .treatmentChangedDuringRead, .invalidTreatment:
            return "Kan ikke beregne: insulin- eller kulhydratgrundlaget er ufuldstændigt."
        case .invalidGlucose, .missingGlucose: return "Kan ikke beregne: ingen gyldig blodsukkerværdi."
        case .glucoseNeedsConfirmation: return "Målingen er over 15 minutter gammel. Bekræft den eller indtast en manuel værdi."
        case .missingTwentyMinuteTrend: return "Kan ikke beregne: der mangler sammenhængende 20-minutters glukosehistorik."
        case .invalidCarbohydrates: return "Indtast en gyldig kulhydratmængde."
        case .invalidCalculation: return "Kan ikke beregne med de aktuelle oplysninger."
        }
    }

    /// The Watch asks this same view model to calculate without opening a phone screen.
    /// Keep its safety wording and all displayed values tied to the completed calculation.
    static func safetyMessage(_ safety: PenDoseSafetyState) -> String {
        switch safety {
        case .checked: return "Prognose for allerede registrerede behandlinger er beregnet."
        case .eatFirst: return "Spis først. Blodsukkeret er under 3,9 mmol/L."
        case .blockedCurrentLow: return "Intet insulinforslag. Blodsukkeret er under 3,0 mmol/L."
        case .blockedForecastLow: return "Intet insulinforslag. Prognosen går under 3,0 mmol/L."
        case .forecastUnchecked: return "Prognosetjek mangler. Forslaget er ikke prognosekontrolleret."
        case .eatFirstForecastUnchecked: return "Spis først. Prognosetjekket kunne ikke gennemføres."
        }
    }

    func watchResponse(requestID: UUID, profileSignature: String,
                       dataSignature: String) -> WatchPenCalculationResponse {
        let details = calculationDetails
        let safety = calculation?.safety
        let available = calculation?.isAvailable == true && details != nil
        let safetyRaw: String?
        switch safety {
        case .checked: safetyRaw = "checked"
        case .eatFirst: safetyRaw = "eatFirst"
        case .blockedCurrentLow: safetyRaw = "blockedCurrentLow"
        case .blockedForecastLow: safetyRaw = "blockedForecastLow"
        case .forecastUnchecked: safetyRaw = "forecastUnchecked"
        case .eatFirstForecastUnchecked: safetyRaw = "eatFirstForecastUnchecked"
        case nil: safetyRaw = nil
        }
        let measuredAt = details?.glucoseMeasuredAt
        let trend = measuredAt.flatMap {
            PenBolusCalculator.twentyMinuteChange(latestGlucoseSamples, at: $0)
        }
        return WatchPenCalculationResponse(requestID: requestID,
            calculatedAt: calculatedAt ?? Date(),
            suggestedUnits: available ? details?.suggestedNowUnits : nil,
            glucoseMgdl: details?.glucoseMgdl ?? latestGlucoseValueMgdl,
            glucoseMeasuredAt: measuredAt ?? latestGlucoseDate,
            glucoseTrendMgdl: trend,
            iobUnits: details?.iobUnits ?? 0,
            cobGrams: details?.cobGrams ?? 0,
            safetyRaw: safetyRaw,
            safetyReason: safety.map(Self.safetyMessage),
            unavailableReason: available ? nil :
                (statusMessage ?? calculation?.unavailableReason.map(Self.unavailableText) ??
                    "Kan ikke beregne med de aktuelle oplysninger."),
            pizzaNowUnits: available && details?.pizzaPercentageNow != nil
                ? details?.suggestedNowUnits : nil,
            pizzaReminderMinutes: available ? details?.pizzaReminderMinutes : nil,
            profileSignature: profileSignature, dataSignature: dataSignature)
    }
}

struct PenDoseLogReceipt {
    let confirmedMealUUID: String?
    let reminderWarning: String?
}

enum PenDoseLogError: Error { case invalidInput, storageFailed, metadataFailed }

/// Stable IDs for one reviewed Log action, retained across an uncertain save result.
struct PenDoseLogOperation: Codable, Equatable {
    let bolusUUID: String
    let mealUUID: String
    init(bolusUUID: String = UUID().uuidString, mealUUID: String = UUID().uuidString) {
        self.bolusUUID = bolusUUID
        self.mealUUID = mealUUID
    }
}

/// Values bound to a journal identity before any treatment is written. An uncertain attempt
/// cannot later reuse its UUIDs for another amount, meal kind or treatment time.
struct PenDoseLogIntent: Codable, Equatable {
    let insulinUnits: Double
    let carbohydrateGrams: Double
    let mealKindRaw: String?
    let insulinDate: Date?
    let mealDate: Date?

    init(insulinUnits: Double, carbohydrateGrams: Double, mealKind: TreatmentMealKind?,
         insulinDate: Date?, mealDate: Date?) {
        self.insulinUnits = insulinUnits
        self.carbohydrateGrams = carbohydrateGrams
        self.mealKindRaw = carbohydrateGrams > 0 ? mealKind?.rawValue : nil
        self.insulinDate = insulinUnits > 0 ? insulinDate : nil
        self.mealDate = carbohydrateGrams > 0 ? mealDate : nil
    }
}

/// A protected write-ahead gate. A failed parent save may leave child objects in memory;
/// reopening the calculator in the same process must never create a second dose.
@MainActor final class PenDoseLogJournal {
    private struct PersistedTreatment {
        let localTreatmentUUID: String?
        let treatmentType: TreatmentType
        let treatmentdeleted: Bool
        let value: Double
    }
    enum RecoveryState: Equatable {
        case ready
        case awaitingRestart
        case foundPriorEntry
        case noLocalEntryHealthUncertain
        case partialOrUnreadable
        case uncertainMutationAfterRestart

        var message: String {
            switch self {
            case .ready: return ""
            case .awaitingRestart:
                return "En tidligere lagring er usikker. Luk og genåbn appen, og kontrollér behandlingshistorikken før ny logning."
            case .foundPriorEntry:
                return "En tidligere registrering blev fundet. Kontrollér den i behandlingshistorikken før ny logning."
            case .noLocalEntryHealthUncertain:
                return "Ingen lokal registrering blev fundet, men Sundhed kan have modtaget en kopi. Kontrollér både xDrip og Sundhed før ny logning."
            case .partialOrUnreadable:
                return "Tidligere lagring kan ikke afstemmes sikkert. Log ikke samme dosis igen; kontrollér behandlingshistorikken."
            case .uncertainMutationAfterRestart:
                return "En ændring af insulin eller kulhydrater kunne ikke bekræftes. Kontrollér behandlingshistorikken og eventuelt Sundhed før ny registrering."
            }
        }
    }
    private struct Pending: Codable {
        let operation: PenDoseLogOperation
        let expectsBolus: Bool
        let expectsMeal: Bool
        let processToken: String
        let intent: PenDoseLogIntent?
    }
    private struct PendingMutation: Codable {
        let objectURI: String
        let processToken: String
    }
    private struct MutationSnapshot: Equatable {
        let date: Date
        let value: Double
        let type: TreatmentType
        let deleted: Bool
        let localUUID: String?
        let createdAt: Date?
        let modifiedAt: Date?
        let mealKind: String?
        let mealDuration: Double?
        let mealState: String?
        let healthSyncVersion: Int?
        let note: String?
        let enteredBy: String?
        let nightscoutEventType: String?

        init(_ entry: TreatmentEntry) {
            date = entry.date
            value = entry.value
            type = entry.treatmentType
            deleted = entry.treatmentdeleted
            localUUID = entry.localTreatmentUUID
            createdAt = entry.createdAt
            modifiedAt = entry.modifiedAt
            mealKind = entry.mealKindRaw
            mealDuration = entry.carbohydrateDurationMinutes?.doubleValue
            mealState = entry.plannedMealStateRaw
            healthSyncVersion = entry.healthKitSyncVersion?.intValue
            note = entry.notes
            enteredBy = entry.enteredBy
            nightscoutEventType = entry.nightscoutEventType
        }
    }
    static let shared = PenDoseLogJournal()
    private static let currentProcessToken = UUID().uuidString
    private let fileManager: FileManager
    private let fileURL: URL
    private let mutationFileURL: URL
    private let processToken: String

    init(directory: URL? = nil, fileManager: FileManager = .default,
         processToken: String? = nil) {
        self.fileManager = fileManager
        self.processToken = processToken ?? Self.currentProcessToken
        let root = directory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.fileURL = root.appendingPathComponent("PenDose", isDirectory: true)
            .appendingPathComponent("pending-log.json")
        self.mutationFileURL = root.appendingPathComponent("PenDose", isDirectory: true)
            .appendingPathComponent("pending-mutation.json")
    }

    func begin(_ operation: PenDoseLogOperation, expectsBolus: Bool, expectsMeal: Bool,
               intent: PenDoseLogIntent? = nil) -> Bool {
        guard !fileManager.fileExists(atPath: mutationFileURL.path) else { return false }
        if fileManager.fileExists(atPath: fileURL.path) {
            guard let pending = try? readPending() else { return false }
            return pending.operation == operation && pending.expectsBolus == expectsBolus &&
                pending.expectsMeal == expectsMeal && pending.intent == intent &&
                pending.processToken == processToken
        }
        let pending = Pending(operation: operation, expectsBolus: expectsBolus,
                              expectsMeal: expectsMeal, processToken: processToken, intent: intent)
        do {
            let folder = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: folder.path)
            try JSONEncoder().encode(pending).write(to: fileURL, options: .atomic)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: fileURL.path)
            let handle = try FileHandle(forWritingTo: fileURL)
            handle.synchronizeFile()
            try handle.close()
            return true
        } catch {
            try? fileManager.removeItem(at: fileURL)
            return false
        }
    }

    /// Write before changing an existing dose. A failed parent save can otherwise be committed
    /// by an unrelated later save after the editor has reported failure.
    func beginMutation(_ entry: TreatmentEntry) -> Bool {
        if entry.objectID.isTemporaryID {
            guard let context = entry.managedObjectContext else { return false }
            do { try context.obtainPermanentIDs(for: [entry]) }
            catch { return false }
        }
        guard !entry.objectID.isTemporaryID,
              !fileManager.fileExists(atPath: fileURL.path),
              !fileManager.fileExists(atPath: mutationFileURL.path) else { return false }
        let pending = PendingMutation(objectURI: entry.objectID.uriRepresentation().absoluteString,
                                      processToken: processToken)
        do {
            let folder = mutationFileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: folder.path)
            try JSONEncoder().encode(pending).write(to: mutationFileURL, options: .atomic)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: mutationFileURL.path)
            let handle = try FileHandle(forWritingTo: mutationFileURL)
            handle.synchronizeFile()
            try handle.close()
            return true
        } catch {
            try? fileManager.removeItem(at: mutationFileURL)
            return false
        }
    }

    /// Check the persistent store in a fresh context; a child-context save alone is not proof.
    func completeMutationVerified(coreDataManager: CoreDataManager,
                                  entry: TreatmentEntry) -> Bool {
        guard let pending = try? JSONDecoder().decode(PendingMutation.self,
                from: Data(contentsOf: mutationFileURL)),
              pending.processToken == processToken,
              pending.objectURI == entry.objectID.uriRepresentation().absoluteString,
              let coordinator = coreDataManager.privateManagedObjectContext.persistentStoreCoordinator,
              let url = URL(string: pending.objectURI),
              let objectID = coordinator.managedObjectID(forURIRepresentation: url) else { return false }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        var persisted: MutationSnapshot?
        context.performAndWait {
            if let stored = try? context.existingObject(with: objectID) as? TreatmentEntry {
                persisted = MutationSnapshot(stored)
            }
        }
        guard persisted == MutationSnapshot(entry) else { return false }
        do { try fileManager.removeItem(at: mutationFileURL); return true }
        catch { return false }
    }

    @discardableResult
    func complete() -> Bool {
        for url in [fileURL, mutationFileURL] where fileManager.fileExists(atPath: url.path) {
            do { try fileManager.removeItem(at: url) }
            catch { return false }
        }
        return true
    }

    func recoveryState(coreDataManager: CoreDataManager) -> RecoveryState {
        if fileManager.fileExists(atPath: mutationFileURL.path) {
            guard let pending = try? JSONDecoder().decode(PendingMutation.self,
                    from: Data(contentsOf: mutationFileURL)) else { return .partialOrUnreadable }
            return pending.processToken == processToken ? .awaitingRestart : .uncertainMutationAfterRestart
        }
        guard fileManager.fileExists(atPath: fileURL.path) else { return .ready }
        guard let pending = try? readPending() else { return .partialOrUnreadable }
        if pending.processToken == processToken { return .awaitingRestart }
        let found = persistedEntries(coreDataManager: coreDataManager, operation: pending.operation)
        guard let found else { return .partialOrUnreadable }
        let bolusCount = found.filter {
            $0.localTreatmentUUID == pending.operation.bolusUUID &&
                $0.treatmentType == .Insulin && !$0.treatmentdeleted
        }.count
        let mealCount = found.filter {
            $0.localTreatmentUUID == pending.operation.mealUUID &&
                $0.treatmentType == .Carbs && !$0.treatmentdeleted
        }.count
        let count = bolusCount + mealCount
        let expected = (pending.expectsBolus ? 1 : 0) + (pending.expectsMeal ? 1 : 0)
        if count == 0 {
            // A Health write may have seen a child-context save before the parent failed.
            // A missing local row is not proof that no Health sample was delivered.
            return .noLocalEntryHealthUncertain
        }
        return found.count == expected && count == expected &&
            bolusCount == (pending.expectsBolus ? 1 : 0) &&
            mealCount == (pending.expectsMeal ? 1 : 0) ? .foundPriorEntry : .partialOrUnreadable
    }

    /// A successful context save is not enough: inspect the persistent store in a fresh
    /// context before removing the write-ahead marker or reporting a completed treatment.
    func completeVerified(coreDataManager: CoreDataManager, operation: PenDoseLogOperation,
                          insulinUnits: Double, carbohydrateGrams: Double) -> Bool {
        guard let found = persistedEntries(coreDataManager: coreDataManager, operation: operation) else {
            return false
        }
        let bolus = found.filter { $0.localTreatmentUUID == operation.bolusUUID }
        let meal = found.filter { $0.localTreatmentUUID == operation.mealUUID }
        guard bolus.count == (insulinUnits > 0 ? 1 : 0),
              meal.count == (carbohydrateGrams > 0 ? 1 : 0),
              found.count == bolus.count + meal.count,
              bolus.allSatisfy({ $0.treatmentType == .Insulin && !$0.treatmentdeleted && $0.value == insulinUnits }),
              meal.allSatisfy({ $0.treatmentType == .Carbs && !$0.treatmentdeleted && $0.value == carbohydrateGrams }) else {
            return false
        }
        return complete()
    }

    private func persistedEntries(coreDataManager: CoreDataManager,
                                  operation: PenDoseLogOperation) -> [PersistedTreatment]? {
        guard let coordinator = coreDataManager.privateManagedObjectContext.persistentStoreCoordinator else {
            return nil
        }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        var found: [PersistedTreatment]?
        context.performAndWait {
            let request: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
            request.predicate = NSPredicate(format: "localTreatmentUUID IN %@",
                [operation.bolusUUID, operation.mealUUID])
            found = try? context.fetch(request).map {
                PersistedTreatment(localTreatmentUUID: $0.localTreatmentUUID,
                    treatmentType: $0.treatmentType, treatmentdeleted: $0.treatmentdeleted,
                    value: $0.value)
            }
        }
        return found
    }

    private func readPending() throws -> Pending {
        try JSONDecoder().decode(Pending.self, from: Data(contentsOf: fileURL))
    }
}

/// Writes only the locally reviewed entries. The existing treatment pipeline observes the
/// durable Core Data save; this code does not initiate any upload or direct HealthKit call.
@MainActor enum PenDoseTreatmentLogger {
    static func log(coreDataManager: CoreDataManager, insulinUnits: Double,
                    carbohydrateGrams: Double, mealKind: TreatmentMealKind,
                    plannedDate: Date?, operation: PenDoseLogOperation = .init(),
                    now: Date = .now, journal: PenDoseLogJournal? = nil,
                    penSettings: PenDoseProfile.Settings? = nil,
                    frozenPenStepUnits: Double? = nil,
                    frozenMaximumUnits: Double? = nil,
                    enteredBy: String = ConstantsHomeView.applicationName,
                    manualWithoutCurrentSuggestion: Bool = false,
                    pizzaSettings: PizzaSplitSettings = .load(),
                    metadataStore: MealPlanMetadataStore? = nil,
                    onReminderIssue: ((String) -> Void)? = nil,
                    saveOverride: (() -> Bool)? = nil)
        -> Result<PenDoseLogReceipt, PenDoseLogError> {
        let journal = journal ?? .shared
        let metadataStore = metadataStore ?? .shared
        let settings = penSettings ?? PenDoseProfile.load().settings
        let step = frozenPenStepUnits ?? settings.penStepUnits
        let maximum = frozenMaximumUnits ?? settings.maximumSuggestionUnits
        let insulinIsValid: Bool
        if insulinUnits == 0 {
            // Food has no pen dose; it remains loggable when pen settings are unavailable.
            insulinIsValid = true
        } else {
            let penSettingsValid = (frozenPenStepUnits != nil && frozenMaximumUnits != nil)
                ? (step.isFinite && (0.1...1).contains(step) &&
                   maximum.isFinite && (1...25).contains(maximum))
                : settings.isValid
            if penSettingsValid, insulinUnits.isFinite,
               (0...maximum).contains(insulinUnits) {
                let penSteps = insulinUnits / step
                insulinIsValid = penSteps.isFinite &&
                    abs(penSteps - penSteps.rounded()) < 1e-8
            } else {
                insulinIsValid = false
            }
        }
        guard insulinUnits.isFinite, carbohydrateGrams.isFinite,
              insulinIsValid,
              (0...500).contains(carbohydrateGrams),
              insulinUnits > 0 || carbohydrateGrams > 0 else { return .failure(.invalidInput) }
        if let plannedDate {
            guard carbohydrateGrams > 0, plannedDate > now,
                  plannedDate <= now.addingTimeInterval(60 * 60) else { return .failure(.invalidInput) }
        }
        if carbohydrateGrams > 0 {
            let metadata = MealPlanMetadata(mealUUID: operation.mealUUID,
                bolusUUID: insulinUnits > 0 ? operation.bolusUUID : nil,
                loggedAt: now, plannedAt: plannedDate,
                grams: carbohydrateGrams,
                pizzaSettings: pizzaSettings, mealKind: mealKind)
            do { try metadataStore.stage(metadata) }
            catch MealPlanMetadataStore.StoreError.conflictingOperation { return .failure(.invalidInput) }
            catch { return .failure(.metadataFailed) }
        }
        let intent = PenDoseLogIntent(insulinUnits: insulinUnits,
            carbohydrateGrams: carbohydrateGrams,
            mealKind: carbohydrateGrams > 0 ? mealKind : nil,
            insulinDate: insulinUnits > 0 ? now : nil,
            mealDate: carbohydrateGrams > 0 ? (plannedDate ?? now) : nil)
        guard journal.begin(operation, expectsBolus: insulinUnits > 0,
                            expectsMeal: carbohydrateGrams > 0, intent: intent) else {
            return .failure(.storageFailed)
        }
        let context = coreDataManager.mainManagedObjectContext
        let existing = TreatmentEntryAccessor(coreDataManager: coreDataManager)
            .getLatestTreatments(howOld: nil)
        let priorBolus = existing.first { $0.localTreatmentUUID == operation.bolusUUID }
        let priorMeal = existing.first { $0.localTreatmentUUID == operation.mealUUID }
        guard priorBolus == nil || (insulinUnits > 0 && priorBolus?.treatmentType == .Insulin &&
                  priorBolus?.value == insulinUnits && priorBolus?.date == now &&
                  priorBolus?.treatmentdeleted == false),
              priorMeal == nil || (carbohydrateGrams > 0 && priorMeal?.treatmentType == .Carbs &&
                  priorMeal?.value == carbohydrateGrams && priorMeal?.date == (plannedDate ?? now) &&
                  priorMeal?.mealKind == mealKind && priorMeal?.treatmentdeleted == false) else {
            return .failure(.invalidInput)
        }
        if insulinUnits > 0 && priorBolus == nil {
            let bolus = TreatmentEntry(date: now, value: insulinUnits,
                treatmentType: .Insulin, nightscoutEventType: nil,
                enteredBy: enteredBy,
                nsManagedObjectContext: context)
            bolus.localTreatmentUUID = operation.bolusUUID
            if manualWithoutCurrentSuggestion {
                bolus.notes = "Manuelt logget uden aktuelt kontrolleret forslag"
            }
            bolus.createdAt = now
            bolus.modifiedAt = now
            bolus.healthKitSyncVersion = NSNumber(value: 1)
            bolus.healthKitSyncStateRaw = HealthLocalTherapySyncState.pending(version: 1)
        }
        if carbohydrateGrams > 0 && priorMeal == nil {
            let meal = TreatmentEntry(date: plannedDate ?? now, value: carbohydrateGrams,
                treatmentType: .Carbs, nightscoutEventType: nil,
                enteredBy: enteredBy,
                nsManagedObjectContext: context)
            meal.localTreatmentUUID = operation.mealUUID
            meal.createdAt = now
            meal.modifiedAt = now
            meal.mealKindRaw = mealKind.rawValue
            meal.carbohydrateDurationMinutes = NSNumber(value: mealKind.durationMinutes)
            meal.plannedMealStateRaw = plannedDate == nil
                ? TreatmentMealState.confirmed.rawValue : TreatmentMealState.planned.rawValue
            if plannedDate == nil {
                meal.healthKitSyncVersion = NSNumber(value: 1)
                meal.healthKitSyncStateRaw = HealthLocalTherapySyncState.pending(version: 1)
            }
        }
        guard saveOverride?() ?? coreDataManager.saveChangesSynchronously(),
              journal.completeVerified(coreDataManager: coreDataManager, operation: operation,
                insulinUnits: insulinUnits, carbohydrateGrams: carbohydrateGrams) else {
            return .failure(.storageFailed)
        }
        let reminderWarning = carbohydrateGrams > 0 ? MealPlanReminderCoordinator.refresh(
            coreDataManager: coreDataManager, mealUUID: operation.mealUUID,
            confirmedAt: plannedDate == nil ? now : nil, now: now,
            store: metadataStore, onIssue: onReminderIssue) : nil
        return .success(PenDoseLogReceipt(confirmedMealUUID:
            plannedDate == nil && carbohydrateGrams > 0 ? operation.mealUUID : nil,
            reminderWarning: reminderWarning))
    }
}
