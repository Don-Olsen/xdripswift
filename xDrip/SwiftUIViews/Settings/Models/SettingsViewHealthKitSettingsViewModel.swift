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

/// conforms to SettingsViewModelProtocol for all healthkit settings in the first sections screen
class SettingsViewHealthKitSettingsViewModel:SettingsViewModelProtocol {
    
    // MARK: - private properties
    
    /// for logging
    private var log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryHealthKitManager)
    private var sectionReloadClosure: (() -> Void)?
    
    // MARK: - Native SwiftUI rows
    
    func settingsRows(sectionID: Int) -> [SettingsRow] {
        [
            nativeSettingsRow(id: "healthKit.enabledHealthKit", index: Setting.enabledHealthKit.rawValue, sectionID: sectionID),
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
            )
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
        return HKHealthStore.isHealthDataAvailable()
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
        Texts_SettingsView.healthKitTherapyImportExplanation
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

        // if value change to on, then verify authorization status and if needed ask authorization
        if isOn {
            // if creation of bloodGlucoseType fails, then we result in an inconsistent situation
            if let bloodGlucoseType = HKObjectType.quantityType(forIdentifier: .bloodGlucose) {
                let healthStore = HKHealthStore()
                let authorizationStatus = healthStore.authorizationStatus(for: bloodGlucoseType)
                switch authorizationStatus {
                case .notDetermined:
                    var shareTypes = Set<HKSampleType>()
                    shareTypes.insert(bloodGlucoseType)
                    healthStore.requestAuthorization(toShare: shareTypes, read: nil, completion: { (success: Bool, error: Error?) in
                        UserDefaults.standard.storeReadingsInHealthkitAuthorized = success

                        if let error = error {
                            trace("user did not authorize to store bg readings in  healthkit, error = %{public}@", log: self.log, category: ConstantsLog.categorySettingsViewHealthKitSettingsViewModel, type: .error, error.localizedDescription)
                        }
                    })
                case .sharingDenied:
                    UserDefaults.standard.storeReadingsInHealthkitAuthorized = false
                    // user must have removed the authorization in the healt app - when user tries to enable healthkit , user will not be informed that he should first go back to the healt app and allow upload bgreadings - let's do such info in a later phase, eg with an info button next to the setting
                    trace("user removed authorization to store bgreadings in healthkit", log: log, category: ConstantsLog.categorySettingsViewHealthKitSettingsViewModel, type: .error)
                case .sharingAuthorized:
                    break
                @unknown default:
                    trace("unknown authorizationstatus for healthkit - SettingsViewHealthKitSettingsViewModel", log: log, category: ConstantsLog.categorySettingsViewHealthKitSettingsViewModel, type: .error)
                }
            } else {
                trace("user enabled HealthKit however failed to create bloodGlucoseType", log: log, category: ConstantsLog.categorySettingsViewHealthKitSettingsViewModel, type: .error)
                return
            }
        }

        // set UserDefaults.standard.storeReadingsInHealthkit to isOn
        UserDefaults.standard.storeReadingsInHealthkit = isOn
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
