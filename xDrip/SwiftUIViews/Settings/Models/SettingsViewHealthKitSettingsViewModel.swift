//
//  SettingsViewHealthKitSettingsViewModel.swift
//  xdrip
//
//  Created by Johan Degraeve on 23/2/19.
//  Copyright © 2019 Johan Degraeve. All rights reserved.
//

import Foundation
import HealthKit
import os
import SwiftUI
import UIKit

fileprivate enum Setting: Int, CaseIterable {
    /// should we write data to Apple Health?
    case enabledHealthKit = 0
    case importBolusInsulin
    case importCarbohydrates
}

/// A completed local source switch changes the controls, not the historical Health data.
/// Resolve source names only against the identifiers captured at the switch boundary.
enum HealthKitLocalCutoverPresentation {
    static func isActive(policy: DataFlowPolicy, cutover: TreatmentSourceCutover?,
                         defaults: UserDefaults = .standard) -> Bool {
        TherapyMetricsManager.doseSourceIsReady(policy, cutover: cutover, defaults: defaults)
    }

    static func priorSourceName(_ selected: HealthTherapyImportSource?,
                                expectedBundleID: String) -> String {
        guard selected?.bundleIdentifier == expectedBundleID else { return expectedBundleID }
        return selected?.name ?? expectedBundleID
    }

    static func cutoffDescription(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "da_DK")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// conforms to SettingsViewModelProtocol for all healthkit settings in the first sections screen
class SettingsViewHealthKitSettingsViewModel:SettingsViewModelProtocol {
    
    // MARK: - private properties
    
    /// for logging
    private var log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryHealthKitManager)
    private var sectionReloadClosure: (() -> Void)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Native SwiftUI rows
    
    private var hasConsistentLocalCutover: Bool {
        HealthKitLocalCutoverPresentation.isActive(
            policy: defaults.dataFlowPolicy,
            cutover: TreatmentSourceCutover.current(defaults: defaults),
            defaults: defaults)
    }

    func settingsRows(sectionID: Int) -> [SettingsRow] {
        let writeToHealth = nativeSettingsRow(id: "healthKit.enabledHealthKit",
            index: Setting.enabledHealthKit.rawValue, sectionID: sectionID)
        let permissionRequest = SettingsRow(
            id: "healthKit.requestWriteAccess", title: "Giv skriveadgang i Sundhed",
            control: .custom(content: { AnyView(HealthKitPermissionRequestRow()) }))
        let exportStatus = SettingsRow(
            id: "healthKit.exportStatus", title: "Sundhed-status",
            control: .custom(content: { AnyView(HealthKitExportStatusRow()) }))
        let localCutover = SettingsRow(
            id: "healthKit.localTreatmentCutover",
            title: "Log behandlinger i xDrip",
            control: .custom(content: {
                AnyView(HealthTherapyLocalCutoverRow(onCutoverChanged: { [weak self] in
                    self?.sectionReloadClosure?()
                }))
            })
        )
        if hasConsistentLocalCutover {
            return [writeToHealth, permissionRequest, exportStatus, localCutover]
        }
        return [
            writeToHealth,
            permissionRequest,
            exportStatus,
            nativeSettingsRow(id: "healthKit.importBolusInsulin", index: Setting.importBolusInsulin.rawValue, sectionID: sectionID),
            SettingsRow(
                id: "healthKit.insulinSource",
                title: Texts_SettingsView.healthKitInsulinSource,
                control: .custom(content: {
                    AnyView(HealthTherapySourcePicker(kind: .insulin, title: Texts_SettingsView.healthKitInsulinSource))
                }),
                isEnabled: HKHealthStore.isHealthDataAvailable(),
                isVisible: HealthKitTherapyImportManager.shared.isEnabled(.insulin)
            ),
            SettingsRow(
                id: "healthKit.insulinStatus",
                title: Texts_SettingsView.healthKitInsulinStatus,
                control: .custom(content: {
                    AnyView(HealthTherapyImportStatusRow(kind: .insulin, title: Texts_SettingsView.healthKitInsulinStatus))
                })
            ),
            nativeSettingsRow(id: "healthKit.importCarbohydrates", index: Setting.importCarbohydrates.rawValue, sectionID: sectionID),
            SettingsRow(
                id: "healthKit.carbohydrateSource",
                title: Texts_SettingsView.healthKitCarbohydrateSource,
                control: .custom(content: {
                    AnyView(HealthTherapySourcePicker(kind: .carbohydrates, title: Texts_SettingsView.healthKitCarbohydrateSource))
                }),
                isEnabled: HKHealthStore.isHealthDataAvailable(),
                isVisible: HealthKitTherapyImportManager.shared.isEnabled(.carbohydrates)
            ),
            SettingsRow(
                id: "healthKit.carbohydrateStatus",
                title: Texts_SettingsView.healthKitCarbohydrateStatus,
                control: .custom(content: {
                    AnyView(HealthTherapyImportStatusRow(kind: .carbohydrates, title: Texts_SettingsView.healthKitCarbohydrateStatus))
                })
            ),
            localCutover
        ]
    }

    func storeRowReloadClosure(rowReloadClosure: ((Int) -> Void)) {}

    func storeSectionReloadClosure(sectionReloadClosure: @escaping () -> Void) {
        self.sectionReloadClosure = sectionReloadClosure
    }
    
    
    func storeMessageHandler(messageHandler: ((String, String) -> Void)) {}
    
    func completeSettingsViewRefreshNeeded(index: Int) -> Bool {
        return false
    }
    
    func isEnabled(index: Int) -> Bool {
        // if healthkit not available (iPad) then don't enable
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        if let setting = Setting(rawValue: index),
           setting != .enabledHealthKit,
           TreatmentSourceCutover.current() != nil { return false }
        return true
    }
    
    func onRowSelect(index: Int) -> SettingsSelectedRowAction {
        guard let setting = Setting(rawValue: index) else { fatalError("Unexpected Section") }
        
        switch setting {
        case .enabledHealthKit:
            return .nothing
        case .importBolusInsulin, .importCarbohydrates:
            return .nothing
        }
    }
    
    func sectionTitle() -> String? {
        return Texts_SettingsView.sectionTitleHealthKit
    }

    func sectionFooter() -> String? {
        hasConsistentLocalCutover ? nil : Texts_SettingsView.healthKitTherapyImportExplanation
    }
    
    func numberOfRows() -> Int {
        return Setting.allCases.count
    }

    func settingsRowText(index: Int) -> String {
        guard let setting = Setting(rawValue: index) else { fatalError("Unexpected Section") }
        
        switch setting {
        case .enabledHealthKit:
            return Texts_SettingsView.labelHealthKit
        case .importBolusInsulin:
            return Texts_SettingsView.healthKitImportBolusInsulin
        case .importCarbohydrates:
            return Texts_SettingsView.healthKitImportCarbohydrates
        }
    }
    
    func accessoryType(index: Int) -> SettingsAccessory {
        guard let setting = Setting(rawValue: index) else { fatalError("Unexpected Section") }
        
        switch setting {
        case .enabledHealthKit:
            return .none
        case .importBolusInsulin, .importCarbohydrates:
            return .none
        }
    }
    
    func detailedText(index: Int) -> String? {
        guard let setting = Setting(rawValue: index) else { fatalError("Unexpected Section") }
        
        switch setting {
        case .enabledHealthKit:
            return nil
        case .importBolusInsulin, .importCarbohydrates:
            return nil
        }
    }

    func settingsToggle(index: Int) -> SettingsToggleControl? {
        guard let setting = Setting(rawValue: index) else { fatalError("Unexpected Section") }

        switch setting {
        case .enabledHealthKit:
            return SettingsToggleControl(
                isOn: { UserDefaults.standard.storeReadingsInHealthkit },
                setIsOn: { [weak self] isOn in
                    self?.setStoreReadingsInHealthKit(isOn)
                }
            )
        case .importBolusInsulin:
            return therapyImportToggle(for: .insulin)
        case .importCarbohydrates:
            return therapyImportToggle(for: .carbohydrates)
        }
    }

    private func therapyImportToggle(for kind: HealthTherapyImportKind) -> SettingsToggleControl {
        SettingsToggleControl(
            isOn: { HealthKitTherapyImportManager.shared.isEnabled(kind) },
            setIsOn: { [weak self] enabled in
                HealthKitTherapyImportManager.shared.setEnabled(enabled, kind: kind) { error in
                    DispatchQueue.main.async {
                        // The import status row shows errors without retaining the legacy
                        // nonescaping presentation callback beyond this settings refresh.
                        _ = error
                        self?.sectionReloadClosure?()
                    }
                }
            }
        )
    }
    

    private func setStoreReadingsInHealthKit(_ isOn: Bool) {
        trace("storeReadingsInHealthkit changed by user to %{public}@", log: log, category: ConstantsLog.categorySettingsViewHealthKitSettingsViewModel, type: .info, isOn.description)

        // Request the complete iPhone type set. Completion is not evidence of consent;
        // check glucose sharing separately and leave existing read flows independent.
        if isOn {
            HealthKitPhoneAuthorizationCenter.shared.request { _, error in
                UserDefaults.standard.storeReadingsInHealthkitAuthorized =
                    HealthKitPhoneAuthorizationCenter.shared.sharingStatus(for: .glucose) == .sharingAuthorized
                if let error {
                    HealthKitExportStatusStore.shared.recordFailure(kind: .glucose,
                        operation: "tilladelse", error: error)
                }
            }
        }

        // set UserDefaults.standard.storeReadingsInHealthkit to isOn
        UserDefaults.standard.storeReadingsInHealthkit = isOn
    }
}

private struct HealthKitPermissionRequestRow: View {
    @State private var isRequesting = false
    @State private var expectedDialog: HKAuthorizationRequestStatus?
    @State private var requestError: NSError?
    @State private var revision = 0

    private var availability: Bool { HKHealthStore.isHealthDataAvailable() }
    private var missingAccess: Bool {
        _ = revision
        return HealthKitExportKind.allCases.contains {
            HealthKitPhoneAuthorizationCenter.shared.sharingStatus(for: $0) != .sharingAuthorized
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                guard !isRequesting else { return }
                isRequesting = true
                requestError = nil
                HealthKitPhoneAuthorizationCenter.shared.request { _, error in
                    isRequesting = false
                    requestError = error as NSError?
                    refresh()
                }
            } label: {
                Label("Giv skriveadgang i Sundhed", systemImage: "heart.text.square")
            }
            .disabled(isRequesting || !availability)

            if !availability {
                Text("HealthKit er ikke tilgængeligt på denne enhed.")
            } else {
                Text(dialogDescription)
                if missingAccess {
                    Text("Hvis skriveadgang stadig mangler, åbn Sundhed og kontrollér xDrips adgang til Blodsukker, Insulinadministration og Kulhydrater. Appen kan ikke fremtvinge en ny iOS-dialog eller ændre tilladelserne for dig.")
                }
            }
            if let requestError {
                Text("Tilladelsesanmodning: \(requestError.domain)/\(requestError.code)")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .healthKitPhoneAuthorizationDidChange)) { _ in refresh() }
    }

    private var dialogDescription: String {
        switch expectedDialog {
        case .shouldRequest: "HealthKit forventer en tilladelsesdialog ved næste anmodning. Det siger ikke, hvilke typer der bliver godkendt."
        case .unnecessary: "HealthKit forventer ingen ny dialog. Se den faktiske skriveadgang nedenfor."
        case .unknown, nil: "HealthKit kunne ikke afklare, om der vises en dialog. Se den faktiske skriveadgang nedenfor."
        @unknown default: "HealthKits dialogstatus er ukendt. Se den faktiske skriveadgang nedenfor."
        }
    }

    private func refresh() {
        revision += 1
        guard availability else { expectedDialog = nil; return }
        HealthKitPhoneAuthorizationCenter.shared.requestStatus { status, error in
            expectedDialog = status
            if let error { requestError = error as NSError }
        }
    }
}

private struct HealthKitExportStatusRow: View {
    @State private var revision = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !HKHealthStore.isHealthDataAvailable() {
                Text("HealthKit er ikke tilgængeligt på denne enhed; eksport og sletning kan ikke udføres her.")
                    .foregroundStyle(.orange)
            }
            ForEach(HealthKitExportKind.allCases, id: \.self) { kind in
                let status = HealthKitExportStatusStore.shared.snapshot(kind)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(kind)).font(.subheadline.weight(.semibold))
                    Text("Skriveadgang: \(accessDescription(kind))")
                    Text("Senest bekræftede skrivning: \(dateDescription(status.lastConfirmedWrite))")
                    Text("Ventende skrivninger: \(status.pendingWrites.map(String.init) ?? "ukendt")")
                    Text("Ventende sletninger: \(status.pendingDeletes.map(String.init) ?? "ikke registreret")")
                    Text("Seneste registrerede fejl: \(errorDescription(status))")
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .onAppear {
            revision += 1
            HealthKitManager.active?.refreshGlucosePendingStatus(force: true)
            HealthKitLocalTherapyWriter.shared.refreshPendingCounts()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in revision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .healthKitPhoneAuthorizationDidChange)) { _ in revision += 1 }
        .onReceive(NotificationCenter.default.publisher(for: .healthKitExportStatusDidChange)) { _ in revision += 1 }
    }

    private func title(_ kind: HealthKitExportKind) -> String {
        switch kind {
        case .glucose: "Blodsukker"
        case .insulin: "Insulin"
        case .carbohydrates: "Kulhydrater"
        }
    }

    private func accessDescription(_ kind: HealthKitExportKind) -> String {
        _ = revision
        return switch HealthKitPhoneAuthorizationCenter.shared.sharingStatus(for: kind) {
        case .sharingAuthorized: "tilladt"
        case .sharingDenied: "nægtet"
        case .notDetermined: "ikke spurgt"
        case nil: "ikke tilgængelig"
        @unknown default: "ukendt"
        }
    }

    private func dateDescription(_ date: Date?) -> String {
        guard let date else { return "ikke registreret" }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }

    private func errorDescription(_ status: HealthKitExportStatus) -> String {
        guard let operation = status.lastErrorOperation,
              let domain = status.lastErrorDomain,
              let code = status.lastErrorCode else { return "ikke registreret" }
        return "\(operation), \(domain)/\(code)"
    }
}

private struct HealthTherapyLocalCutoverRow: View {
    let onCutoverChanged: () -> Void
    @State private var switching = false
    @State private var message: String?
    @State private var cutover = TreatmentSourceCutover.current()
    @AppStorage("therapyRestoreRequiresSourceSetup") private var restoreRequiresSourceSetup = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if restoreRequiresSourceSetup {
                Text("Gendannede behandlinger mangler kildeopsætning. Vælg og aktivér mySugr som både insulin- og kulhydratkilde i Sundhed, og gennemfør derefter skiftet til lokal registrering igen. Behandlingsberegninger er utilgængelige indtil da.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let cutover,
               HealthKitLocalCutoverPresentation.isActive(
                policy: UserDefaults.standard.dataFlowPolicy, cutover: cutover) {
                let insulin = HealthKitLocalCutoverPresentation.priorSourceName(
                    HealthKitTherapyImportManager.shared.selectedSource(.insulin),
                    expectedBundleID: cutover.insulinSourceBundleID)
                let carbohydrate = HealthKitLocalCutoverPresentation.priorSourceName(
                    HealthKitTherapyImportManager.shared.selectedSource(.carbohydrates),
                    expectedBundleID: cutover.carbohydrateSourceBundleID)
                Text("Lokal registrering siden \(HealthKitLocalCutoverPresentation.cutoffDescription(cutover.cutoff)).")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Tidligere kilde · insulin: \(insulin) · kulhydrater: \(carbohydrate).")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Behandlinger fra før skiftet vises kun, hvis de findes og kan læses.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if cutover != nil {
                Text("Kildeopsætningen er ufuldstændig. Kontroller behandlingskilden før brug.")
                    .font(.footnote).foregroundStyle(.orange)
            } else {
                let insulinSource = HealthKitTherapyImportManager.shared.selectedSource(.insulin)
                let carbohydrateSource = HealthKitTherapyImportManager.shared.selectedSource(.carbohydrates)
                Text("Insulin: \(insulinSource?.name ?? "Ingen kilde") (\(insulinSource?.bundleIdentifier ?? "–"))")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Kulhydrater: \(carbohydrateSource?.name ?? "Ingen kilde") (\(carbohydrateSource?.bundleIdentifier ?? "–"))")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(switching ? "Afslutter import…" : "Skift til lokal registrering") {
                    switching = true
                    message = nil
                    HealthKitTherapyImportManager.shared.switchToLocalLogging { error in
                        switching = false
                        cutover = TreatmentSourceCutover.current()
                        if error == nil { onCutoverChanged() }
                        if error != nil {
                            message = "Skiftet blev ikke gennemført. Vælg og aktivér mySugr som både insulin- og kulhydratkilde, og prøv igen. Intet er ændret."
                        }
                    }
                }
                .disabled(switching || !HKHealthStore.isHealthDataAvailable() ||
                    insulinSource?.isMySugr != true || carbohydrateSource?.isMySugr != true)
                Text("Vælg mySugr for begge typer. Når begge sidste Sundhed-læsninger er gemt, bliver xDrip primær behandlingskilde, og den eksterne IOB/COB-kilde slås fra. Glukose og Nightscout-upload ændres ikke.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Sletter du senere en behandling i xDrip, kan en allerede skrevet kopi blive i Sundhed. xDrip læser ikke sin egen kopi tilbage.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: HealthKitTherapyImportManager.statusDidChange)) { _ in
            cutover = TreatmentSourceCutover.current()
        }
    }
}

/// A source is offered only when HealthKit reports actual data-producing sources for this type.
/// The choice is persisted by the import manager, so normal new entries require no further prompts.
private struct HealthTherapySourcePicker: View {
    let kind: HealthTherapyImportKind
    let title: String

    @State private var sources: [HealthTherapyImportSource] = []
    @State private var selectedSource: HealthTherapyImportSource?
    @State private var isLoading = false
    @State private var discoveryError: String?

    private let manager = HealthKitTherapyImportManager.shared

    private var displayedSource: String {
        selectedSource?.name ?? Texts_SettingsView.healthKitChooseSource
    }

    var body: some View {
        Menu {
            if isLoading {
                Button(Texts_SettingsView.healthKitFindingSources) {}
                    .disabled(true)
            } else if sources.isEmpty {
                Button(discoveryError ?? Texts_SettingsView.healthKitNoSources) {}
                    .disabled(true)
            } else {
                ForEach(sources, id: \.bundleIdentifier) { source in
                    Button {
                        manager.selectSource(source, kind: kind)
                        selectedSource = source
                    } label: {
                        if source.bundleIdentifier == selectedSource?.bundleIdentifier {
                            Label("\(source.name) (\(source.bundleIdentifier))", systemImage: "checkmark")
                        } else {
                            Text("\(source.name) (\(source.bundleIdentifier))")
                        }
                    }
                    .accessibilityLabel("\(source.name), \(source.bundleIdentifier)")
                }
            }

            Button {
                loadSources()
            } label: {
                Label(Texts_SettingsView.healthKitRefreshSources, systemImage: "arrow.clockwise")
            }
        } label: {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 8)
                Text(displayedSource)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityValue(displayedSource)
        .accessibilityHint(Texts_SettingsView.healthKitSourceHint)
        .onAppear {
            selectedSource = manager.selectedSource(kind)
            loadSources()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("HealthKitTherapyImportStatusDidChange"))) { _ in
            selectedSource = manager.selectedSource(kind)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            loadSources()
        }
    }

    private func loadSources() {
        guard !isLoading else { return }
        isLoading = true
        discoveryError = nil
        manager.discoveredSources(kind) { sources, error in
            DispatchQueue.main.async {
                self.sources = sources.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                self.discoveryError = error?.localizedDescription
                self.selectedSource = self.manager.selectedSource(self.kind)
                self.isLoading = false
            }
        }
    }
}

private struct HealthTherapyImportStatusRow: View {
    let kind: HealthTherapyImportKind
    let title: String

    @State private var status: HealthTherapyImportStatus
    @State private var enabled: Bool

    init(kind: HealthTherapyImportKind, title: String) {
        self.kind = kind
        self.title = title
        _status = State(initialValue: HealthKitTherapyImportManager.shared.status(kind))
        _enabled = State(initialValue: HealthKitTherapyImportManager.shared.isEnabled(kind))
    }

    private var lastSyncText: String {
        guard let lastSync = status.lastSync else {
            return Texts_SettingsView.healthKitNeverSynced
        }
        return String(format: Texts_SettingsView.healthKitLastSyncFormat,
                      DateFormatter.localizedString(from: lastSync, dateStyle: .medium, timeStyle: .short))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.isIncomplete ? "exclamationmark.triangle" : "clock.arrow.circlepath")
                .foregroundStyle(status.isIncomplete ? Color.orange : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(enabled ? status.message : Texts_SettingsView.healthKitImportDisabled)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(lastSyncText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(enabled ? status.message : Texts_SettingsView.healthKitImportDisabled). \(lastSyncText)")
        .onAppear {
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("HealthKitTherapyImportStatusDidChange"))) { _ in
            refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        enabled = HealthKitTherapyImportManager.shared.isEnabled(kind)
        status = HealthKitTherapyImportManager.shared.status(kind)
    }
}
