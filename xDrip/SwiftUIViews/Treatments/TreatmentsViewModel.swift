//
//  TreatmentsViewModel.swift
//  xdrip
//
//  Created by Paul Plant on 18/6/26.
//  Copyright © 2026 Johan Degraeve. All rights reserved.
//

import Foundation
import SwiftUI
import CoreData
import OSLog

/// Loads treatment snapshots and applies the selected day and persisted filters.
///
/// Core Data objects are converted to value snapshots before publication so the SwiftUI list does
/// not retain managed objects while rows are filtered, edited or deleted.
@MainActor final class TreatmentsViewModel: ObservableObject {
    // MARK: - @Published properties

    @Published private(set) var filteredTreatments: [TreatmentSnapshot] = []
    @Published private(set) var selectedDateDayName = ""
    @Published private(set) var showBasalFilter = UserDefaults.standard.dataFlowPolicy.showsPumpData
    @Published var datePickerReset = UUID()

    @Published private(set) var showSmallBolusTreatments = UserDefaults.standard.showSmallBolusTreatmentsInList
    @Published private(set) var showBolusTreatments = UserDefaults.standard.showBolusTreatmentsInList
    @Published private(set) var showCarbsTreatments = UserDefaults.standard.showCarbsTreatmentsInList
    @Published private(set) var showBasalTreatments = UserDefaults.standard.showBasalTreatmentsInList
    @Published private(set) var showBgCheckTreatments = UserDefaults.standard.showBgCheckTreatmentsInList
    @Published private(set) var showBasalInjectionTreatments = UserDefaults.standard.showBasalInjectionTreatmentsInList
    @Published private(set) var showNoteTreatments = UserDefaults.standard.showNoteTreatmentsInList
    @Published private(set) var selectedDate = Date().toMidnight()
    @Published var deletionFailureMessage: String?

    // MARK: - private properties

    let coreDataManager: CoreDataManager
    private let treatmentEntryAccessor: TreatmentEntryAccessor
    private let localSaveJournal: PenDoseLogJournal
    private let therapyMetricsManager: TherapyMetricsManager
    private let localSaveOverride: (() -> Bool)?
    private let log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryApplicationDataTreatments)

    private var allTreatments: [TreatmentSnapshot] = []
    private var didInitializeView = false
    private var loadedTreatmentRevision: Int?
    private var lastSettings = ListSettings()

    /// Only preferences read by this list may trigger a reload. Glucose/export timestamps and
    /// unrelated defaults are frequent; observing them must not fetch history or reconcile files.
    private struct ListSettings: Equatable {
        let filters: [Bool]
        let smallBolusThreshold: Double
        let usesMgDl: Bool
        let quickCarbs: Double?
        let sourcePolicy: [Bool]
        let insulinSource: String?
        let carbsSource: String?
        let importsInsulin: Bool
        let importsCarbs: Bool
        let cutover: TreatmentSourceCutover?
        let invalidCutover: Bool

        init() {
            let defaults = UserDefaults.standard
            let policy = defaults.dataFlowPolicy
            let importer = HealthKitTherapyImportManager.shared
            filters = [defaults.showSmallBolusTreatmentsInList, defaults.showBolusTreatmentsInList,
                defaults.showCarbsTreatmentsInList, defaults.showBasalTreatmentsInList,
                defaults.showBgCheckTreatmentsInList, defaults.showBasalInjectionTreatmentsInList,
                defaults.showNoteTreatmentsInList]
            smallBolusThreshold = defaults.smallBolusTreatmentThreshold
            usesMgDl = defaults.bloodGlucoseUnitIsMgDl
            quickCarbs = defaults.quickCarbohydrateGrams
            sourcePolicy = [policy.importsTherapyFromCareLink, policy.importsTreatmentsFromNightscout,
                            policy.showsPumpData]
            insulinSource = importer.selectedSource(.insulin)?.bundleIdentifier
            carbsSource = importer.selectedSource(.carbohydrates)?.bundleIdentifier
            importsInsulin = importer.isEnabled(.insulin)
            importsCarbs = importer.isEnabled(.carbohydrates)
            cutover = TreatmentSourceCutover.current()
            invalidCutover = TreatmentSourceCutover.hasInvalidStoredValue()
        }
    }

    // MARK: - initialization

    init(coreDataManager: CoreDataManager, localSaveJournal: PenDoseLogJournal? = nil,
         localSaveOverride: (() -> Bool)? = nil,
         therapyMetricsManager: TherapyMetricsManager = .shared) {
        self.coreDataManager = coreDataManager
        self.treatmentEntryAccessor = TreatmentEntryAccessor(coreDataManager: coreDataManager)
        self.localSaveJournal = localSaveJournal ?? .shared
        self.localSaveOverride = localSaveOverride
        self.therapyMetricsManager = therapyMetricsManager

        updateDayName()
    }

    // MARK: - public functions

    /// Performs the first load, or refreshes the existing model when the tab becomes visible again.
    func initializeViewIfNeeded() {
        if didInitializeView {
            reloadTreatments()
            return
        }

        didInitializeView = true
        reloadTreatments()
    }

    /// Reloads the treatment history and reapplies the current filters.
    func reloadTreatments() {
        lastSettings = ListSettings()
        loadedTreatmentRevision = therapyMetricsManager.treatmentChangeRevision
        syncFilterSettingsFromUserDefaults()

        let fetched = treatmentEntryAccessor.getLatestTreatments(howOld: nil)
        let importer = HealthKitTherapyImportManager.shared
        let cutover = TreatmentSourceCutover.current()
        // Match the source, cutover and origin-dedup rules used by live IOB/COB. Turning the
        // Health importer off at cutover must not hide the already imported mySugr history.
        let eligibleActualIDs = Set(TherapyMetricsManager.eligibleTreatments(
            fetched.filter { !$0.treatmentdeleted && ($0.treatmentType == .Insulin || $0.treatmentType == .Carbs) },
            policy: UserDefaults.standard.dataFlowPolicy,
            insulinSource: importer.selectedSource(.insulin)?.bundleIdentifier,
            carbsSource: importer.selectedSource(.carbohydrates)?.bundleIdentifier,
            insulinEnabled: importer.isEnabled(.insulin),
            carbsEnabled: importer.isEnabled(.carbohydrates),
            cutover: cutover
        ).map(\.objectID))
        let treatments = fetched.filter { entry in
            guard !entry.treatmentdeleted else { return false }
            if entry.treatmentType == .Insulin || entry.treatmentType == .Carbs {
                if entry.isPlannedMeal || entry.isCancelledMeal {
                    // A plan stays visible for editing/history, but is never counted as eaten.
                    guard entry.isAppLocalTreatment else { return false }
                    guard let cutover else { return true }
                    return cutover.permitsLocal(eventDate: entry.date,
                        localTreatmentUUID: entry.localTreatmentUUID,
                        watchSourceUUID: entry.watchSourceUUID)
                }
                return eligibleActualIDs.contains(entry.objectID)
            }
            guard entry.isHealthKitImported else { return true }
            let kind: HealthTherapyImportKind = entry.treatmentType == .Insulin ? .insulin : .carbohydrates
            return importer.isEnabled(kind) &&
                entry.healthKitSourceBundleIdentifier == importer.selectedSource(kind)?.bundleIdentifier
        }.sorted(by: { $0.date > $1.date })

        // Rows and edit routes retain object IDs rather than managed objects. Make those IDs
        // permanent before publication, even when the asynchronous parent save is still pending.
        let temporaryTreatments = treatments.filter { $0.objectID.isTemporaryID }
        do {
            if !temporaryTreatments.isEmpty {
                try coreDataManager.mainManagedObjectContext.obtainPermanentIDs(for: temporaryTreatments)
            }
        } catch {
            trace("failed to obtain permanent treatment IDs", log: log, category: ConstantsLog.categoryApplicationDataTreatments, type: .error)
            return
        }

        allTreatments = treatments.map { TreatmentSnapshot(treatmentEntry: $0) }

        applyFilters()
        MealPlanReminderCoordinator.reconcile(coreDataManager: coreDataManager,
            journal: localSaveJournal, onIssue: MealReminderIssueCenter.report)
    }

    func plannedMealSnapshot(uuid: String) -> TreatmentSnapshot? {
        allTreatments.first { $0.localTreatmentUUID == uuid && $0.isPlannedMeal }
    }

    func handleUserDefaultsDidChange() {
        guard ListSettings() != lastSettings else { return }
        reloadTreatments()
    }

    /// Data changes must not depend on an incidental defaults write. Ignore glucose-only/status
    /// notifications and wait for the existing durable treatment commit before refreshing rows.
    func handleTherapyMetricsChanged() {
        guard let loadedTreatmentRevision,
              loadedTreatmentRevision != therapyMetricsManager.treatmentChangeRevision,
              !therapyMetricsManager.hasUncommittedTreatmentChanges else { return }
        reloadTreatments()
    }

    func selectedDateChanged(_ newDate: Date) {
        selectedDate = min(newDate, Date()).toMidnight()
        updateDayName()
        applyFilters()
        datePickerReset = UUID()
    }

    func toggleSmallBolusFilter() {
        guard showBolusTreatments else {
            return
        }

        UserDefaults.standard.showSmallBolusTreatmentsInList.toggle()
        showSmallBolusTreatments = UserDefaults.standard.showSmallBolusTreatmentsInList
        applyFilters()
    }

    func toggleBolusFilter() {
        UserDefaults.standard.showBolusTreatmentsInList.toggle()
        showBolusTreatments = UserDefaults.standard.showBolusTreatmentsInList
        applyFilters()
    }

    func toggleCarbsFilter() {
        UserDefaults.standard.showCarbsTreatmentsInList.toggle()
        showCarbsTreatments = UserDefaults.standard.showCarbsTreatmentsInList
        applyFilters()
    }

    func toggleBasalFilter() {
        UserDefaults.standard.showBasalTreatmentsInList.toggle()
        showBasalTreatments = UserDefaults.standard.showBasalTreatmentsInList
        applyFilters()
    }

    func toggleBgCheckFilter() {
        UserDefaults.standard.showBgCheckTreatmentsInList.toggle()
        showBgCheckTreatments = UserDefaults.standard.showBgCheckTreatmentsInList
        applyFilters()
    }

    func toggleBasalInjectionFilter() {
        UserDefaults.standard.showBasalInjectionTreatmentsInList.toggle()
        showBasalInjectionTreatments = UserDefaults.standard.showBasalInjectionTreatmentsInList
        applyFilters()
    }

    func toggleNoteFilter() {
        UserDefaults.standard.showNoteTreatmentsInList.toggle()
        showNoteTreatments = UserDefaults.standard.showNoteTreatmentsInList
        applyFilters()
    }

    @discardableResult
    func deleteTreatment(_ treatment: TreatmentSnapshot) -> Bool {
        guard let treatmentEntry = treatmentEntryAccessor.getTreatment(objectID: treatment.objectID) else {
            deletionFailureMessage = "Behandlingen kunne ikke findes. Genåbn historikken før ny registrering."
            return false
        }
        let durableMutation = treatmentEntry.treatmentType == .Insulin ||
            treatmentEntry.treatmentType == .Carbs
        if durableMutation && !localSaveJournal.beginMutation(treatmentEntry) {
            let state = localSaveJournal.recoveryState(coreDataManager: coreDataManager)
            deletionFailureMessage = state.message.isEmpty ?
                "En tidligere ændring kan ikke afstemmes sikkert. Kontrollér behandlingshistorikken." :
                state.message
            return false
        }

        treatmentEntry.treatmentdeleted = true
        treatmentEntry.uploaded = false
        treatmentEntry.modifiedAt = Date()

        let requiresPersistentSave = durableMutation || treatmentEntry.treatmentType == .BasalInjection
        let saved = requiresPersistentSave ? (localSaveOverride?() ?? coreDataManager.saveChangesSynchronously()) :
            coreDataManager.saveChanges()
        guard saved, !durableMutation ||
            localSaveJournal.completeMutationVerified(coreDataManager: coreDataManager,
                entry: treatmentEntry) else {
            deletionFailureMessage = "Sletningen kunne ikke bekræftes. Kontrollér behandlingshistorikken og eventuelt Sundhed før ny registrering."
            trace("failed to save a deleted treatment", log: log, category: ConstantsLog.categoryApplicationDataTreatments, type: .error)
            return false
        }
        deletionFailureMessage = nil
        if durableMutation { HealthKitLocalTherapyWriter.shared.retryPending() }
        if treatmentEntry.treatmentType == .BasalInjection {
            BasalReminderScheduler.shared.refreshAfterTreatmentChange(coreDataManager: coreDataManager)
        }
        if let uuid = treatmentEntry.localTreatmentUUID {
            if treatmentEntry.treatmentType == .Carbs {
                let warning = MealPlanReminderCoordinator.refresh(coreDataManager: coreDataManager,
                    mealUUID: uuid, onIssue: MealReminderIssueCenter.report)
                if let warning { MealReminderIssueCenter.report(warning) }
            } else if treatmentEntry.treatmentType == .Insulin {
                MealPlanReminderCoordinator.refreshLinkedMeals(coreDataManager: coreDataManager,
                    bolusUUID: uuid, onIssue: MealReminderIssueCenter.report)
            }
        }

        // Swipe deletion and editor deletion use the same typed fact. Emit it only after the local
        // save succeeds, and keep all treatment values, notes and identifiers in private app data.
        trace(
            "deleted treatment %{public}@ at %{public}@",
            log: log,
            category: ConstantsLog.categoryApplicationDataTreatments,
            type: .info,
            troubleshooting: .standard(.treatment(.deleted(
                kind: TroubleshootingTreatmentKind(treatmentEntry.treatmentType),
                treatmentAt: treatmentEntry.date
            ))),
            treatmentEntry.treatmentType.asString(),
            treatmentEntry.date.description
        )
        setNightscoutSyncRequiredToTrue()
        reloadTreatments()
        return true
    }

    // MARK: - private functions

    private func syncFilterSettingsFromUserDefaults() {
        showSmallBolusTreatments = UserDefaults.standard.showSmallBolusTreatmentsInList
        showBolusTreatments = UserDefaults.standard.showBolusTreatmentsInList
        showCarbsTreatments = UserDefaults.standard.showCarbsTreatmentsInList
        showBasalTreatments = UserDefaults.standard.showBasalTreatmentsInList
        showBgCheckTreatments = UserDefaults.standard.showBgCheckTreatmentsInList
        showBasalInjectionTreatments = UserDefaults.standard.showBasalInjectionTreatmentsInList
        showNoteTreatments = UserDefaults.standard.showNoteTreatmentsInList
        showBasalFilter = UserDefaults.standard.dataFlowPolicy.showsPumpData
    }

    private func applyFilters() {
        let selectedMidnight = selectedDate.toMidnight()

        filteredTreatments = allTreatments.filter { treatment in
            Calendar.current.compare(treatment.date, to: selectedMidnight, toGranularity: .day) == .orderedSame ||
                (treatment.isPlannedMeal && Calendar.current.isDateInToday(selectedDate))
        }

        if !showBolusTreatments {
            filteredTreatments.removeAll(where: { $0.treatmentType == .Insulin })
        } else if !showSmallBolusTreatments {
            filteredTreatments.removeAll {
                $0.treatmentType == .Insulin && $0.rawValue < UserDefaults.standard.smallBolusTreatmentThreshold
            }
        }

        if !showCarbsTreatments {
            filteredTreatments.removeAll(where: { $0.treatmentType == .Carbs })
        }

        if !showBasalTreatments {
            filteredTreatments.removeAll(where: { $0.treatmentType == .Basal || $0.treatmentType == .AutomaticBasal })
        }

        if !showBgCheckTreatments {
            filteredTreatments.removeAll(where: { $0.treatmentType == .BgCheck })
        }

        // Injection visibility is independent of both general Notes and pump basal rates.
        if !showBasalInjectionTreatments {
            filteredTreatments.removeAll(where: { $0.treatmentType == .BasalInjection })
        }

        if !showNoteTreatments {
            filteredTreatments.removeAll(where: { $0.treatmentType == .Note })
        }
    }

    private func updateDayName() {
        let dateFormatter = DateFormatter()

        dateFormatter.dateFormat = "EEEE"

        selectedDateDayName = dateFormatter.string(from: selectedDate).capitalized
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

enum TreatmentEditorState: Identifiable {
    case add
    case basal
    case quickCarbs(Double)
    case edit(TreatmentSnapshot)

    var id: String {
        switch self {
        case .add:
            return "add"
        case .basal:
            return "basal"
        case .quickCarbs:
            return "quickCarbs"
        case .edit(let treatment):
            return treatment.objectID.uriRepresentation().absoluteString
        }
    }
}

/// Immutable treatment data used by list rows and the treatment editor route.
struct TreatmentSnapshot: Hashable {
    let objectID: NSManagedObjectID
    let date: Date
    let treatmentType: TreatmentType
    let rawValue: Double
    let valueSecondary: Double
    let enteredBy: String?
    let notes: String?
    let isHealthKitImported: Bool
    let localTreatmentUUID: String?
    let isPlannedMeal: Bool
    let isCancelledMeal: Bool
    let mealKind: TreatmentMealKind
    let deletionMayLeaveHealthCopy: Bool

    init(treatmentEntry: TreatmentEntry) {
        objectID = treatmentEntry.objectID
        date = treatmentEntry.date
        treatmentType = treatmentEntry.treatmentType
        rawValue = treatmentEntry.value
        valueSecondary = treatmentEntry.valueSecondary
        enteredBy = treatmentEntry.enteredBy
        notes = treatmentEntry.notes
        isHealthKitImported = treatmentEntry.isHealthKitImported
        localTreatmentUUID = treatmentEntry.localTreatmentUUID
        isPlannedMeal = treatmentEntry.isPlannedMeal
        isCancelledMeal = treatmentEntry.isCancelledMeal
        mealKind = treatmentEntry.mealKind
        deletionMayLeaveHealthCopy = treatmentEntry.localTreatmentUUID != nil &&
            treatmentEntry.healthKitSyncVersion != nil &&
            (treatmentEntry.treatmentType == .Insulin || treatmentEntry.isConfirmedMeal)
    }

    var isEditable: Bool {
        // Health-sourced values are corrected in their source app and arrive as a documented
        // HealthKit deletion/new sample. Editing a copy would silently break provenance.
        if isHealthKitImported { return false }
        switch treatmentType {
        case .Insulin, .BasalInjection, .Carbs, .Exercise, .BgCheck, .Note:
            return true
        default:
            return false
        }
    }

    var iconSystemName: String {
        treatmentType.iconSystemName
    }

    var iconSize: CGFloat {
        if isSmallBolus {
            return GlucoseChartTreatmentStyle.treatmentIconSize * GlucoseChartTreatmentStyle.smallBolusScale
        }

        if treatmentType == .BgCheck {
            return 15
        }

        if treatmentType == .Note {
            return 14
        }

        return 13
    }

    var typeText: String {
        if treatmentType == .Carbs {
            let mealSymbol: String
            switch mealKind {
            case .fast: mealSymbol = "🍭"
            case .normal: mealSymbol = "🌮"
            case .slow: mealSymbol = "🍕"
            }
            if isPlannedMeal { return "\(mealSymbol) Planlagt" }
            if isCancelledMeal { return "\(mealSymbol) Annulleret" }
            return "\(mealSymbol) \(treatmentType.asString())"
        }
        return treatmentType.asString()
    }

    var timeString: String {
        date.toStringInUserLocale(timeStyle: .short, dateStyle: .none)
    }

    var valueText: String? {
        switch treatmentType {
        case .BgCheck:
            return rawValue.mgDlToMmolAndToString(mgDl: UserDefaults.standard.bloodGlucoseUnitIsMgDl)
        case .SiteChange, .SensorStart, .PumpBatteryChange, .Note:
            return nil
        default:
            return (round(rawValue * 100) / 100).stringWithoutTrailingZeroes
        }
    }

    var unitText: String? {
        switch treatmentType {
        case .SiteChange, .SensorStart, .PumpBatteryChange, .Note:
            return nil
        default:
            return treatmentType.unit()
        }
    }

    var secondaryText: String? {
        if isHealthKitImported { return enteredBy }
        if treatmentType == .Basal {
            return "\(Int(valueSecondary))\(Texts_Common.minuteshort)"
        }

        if treatmentType == .Note {
            return notes
        }

        return nil
    }

    var primaryTextColor: Color {
        if date > Date() {
            return Color(.colorTertiary)
        }

        return Color(.colorPrimary)
    }

    private var isSmallBolus: Bool {
        treatmentType == .Insulin && rawValue < UserDefaults.standard.smallBolusTreatmentThreshold
    }
}

/// Shared symbols and colors for treatment rows and type selection.
extension TreatmentType {
    /// Use native symbols consistently in rows and the add/edit flow.
    func iconView(size: Double = GlucoseChartTreatmentStyle.treatmentIconSize) -> some View {
        Image(systemName: iconSystemName)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(iconColor)
    }

    var iconSystemName: String {
        switch self {
        case .Insulin:
            return GlucoseChartTreatmentStyle.bolusSymbol
        case .BasalInjection:
            return GlucoseChartTreatmentStyle.basalInjectionSymbol
        case .Carbs:
            return GlucoseChartTreatmentStyle.carbsSymbol
        case .Exercise:
            return "figure.run"
        case .BgCheck:
            return GlucoseChartTreatmentStyle.bgCheckSymbol
        case .Basal, .AutomaticBasal:
            return "chart.bar.fill"
        case .SiteChange:
            return "cross.vial.fill"
        case .SensorStart:
            return "sensor.tag.radiowaves.forward.fill"
        case .PumpBatteryChange:
            // Match the existing battery fallback because the percent-suffixed symbol requires iOS 17.
            if #available(iOS 17.0, *) {
                return "battery.100percent"
            }
            return "minus.plus.batteryblock.fill"
        case .Note:
            return GlucoseChartTreatmentStyle.noteSymbol
        }
    }

    var iconColor: Color {
        let baseColor: Color

        switch self {
        case .Insulin:
            baseColor = ConstantsGlucoseChart.bolusTreatmentColor
        case .BasalInjection:
            baseColor = ConstantsGlucoseChart.basalInjectionTreatmentColor
        case .Carbs:
            baseColor = ConstantsGlucoseChart.carbsTreatmentColor
        case .Exercise:
            baseColor = Color(red: 0.7, green: 0.25, blue: 0.85)
        case .BgCheck:
            baseColor = ConstantsGlucoseChart.bgCheckTreatmentColorInner
        case .Basal, .AutomaticBasal:
            baseColor = ConstantsGlucoseChart.basalTreatmentColor
        case .SiteChange, .SensorStart, .PumpBatteryChange:
            baseColor = .yellow
        case .Note:
            baseColor = ConstantsGlucoseChart.noteTreatmentColor
        }

        return baseColor
    }

}
