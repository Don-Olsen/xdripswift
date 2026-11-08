//
//  QuickActionsManager.swift
//  xdrip
//
//  Created by Samuli Tamminen on 29.4.2022.
//  Copyright © 2022 Johan Degraeve. All rights reserved.
//

import UIKit
import Combine
import OSLog

private let calculatorShortcutLog = OSLog(subsystem: ConstantsLog.subSystem,
    category: ConstantsLog.categoryAppDelegate)

/// This enum defines actions that can be available at app icon's quick actions on iOS home screen
enum QuickActionType: String, Equatable {
    case penCalculator = "penCalculator"
    case silentAlarms = "silentAlarms"
    case speakReadings = "speakReadings"
    case stopSpeakingReadings = "stopSpeakingReadings"
    
    /// Title is displayed in the long-press menu on the iOS home screen
    private var localizedTitle: String {
        switch self {
            case .penCalculator: return Texts_QuickActions.penCalculator
            case .silentAlarms: return Texts_QuickActions.silentAlarms
            case .speakReadings: return Texts_QuickActions.speakReadings
            case .stopSpeakingReadings: return Texts_QuickActions.stopSpeakingReadings
        }
    }
    
    /// Icon is displayed nex to the tile in the long-press menu on the iOS home screen
    func iconSystemName(silenceIsActive: Bool) -> String {
        switch self {
            case .penCalculator: return "plus.circle.fill"
            case .silentAlarms: return silenceIsActive ? "bell.fill" : "bell.slash.fill"
            case .speakReadings: return "speaker.wave.2"
            case .stopSpeakingReadings: return "speaker.slash"
        }
    }
    
    /// Make a UIApplicationShortcutItem from the action
    var shortcutItem: UIApplicationShortcutItem {
        shortcutItem(silenceIsActive: false)
    }

    func shortcutItem(silenceIsActive: Bool) -> UIApplicationShortcutItem {
        UIApplicationShortcutItem(type: rawValue, localizedTitle: localizedTitle,
            localizedSubtitle: nil, icon: .init(systemImageName: iconSystemName(silenceIsActive: silenceIsActive)))
    }
}

@MainActor final class QuickActionsManager: NSObject {
    static let shared = QuickActionsManager()

    private weak var rootStateModel: RootTabStateModel?
    private var pendingCalculatorBeforeRoot = false
    private var rootSubscription: AnyCancellable?
    private var homeSubscription: AnyCancellable?
    private var notifications: [NSObjectProtocol] = []
    private let silenceDefaults: UserDefaults
    private var publishedSilenceIsActive: Bool?

    init(silenceDefaults: UserDefaults = .standard) {
        self.silenceDefaults = silenceDefaults
        super.init()
        
        // add observer for speakReadings to update available quick actions when the setting is changed
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.speakReadings.rawValue, options: .new, context: nil)

        for name in [UserDefaults.didChangeNotification, UIApplication.didBecomeActiveNotification,
                     HealthKitTherapyImportManager.statusDidChange, TherapyMetricsManager.changed,
                     SelectiveAlarmSilence.changed] {
            // Delivery on a main OperationQueue can synchronously wait for the main thread.
            // UserDefaults can post from a worker while main is waiting on that worker.
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) {
                [weak self] _ in
                Task { @MainActor [weak self] in self?.updateAvailableQuickActions() }
            })
        }
      
        // Refresh initial state
        updateAvailableQuickActions()
    }

    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.speakReadings.rawValue)
        notifications.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// The SwiftUI root may be created after a cold-start shortcut reaches the scene delegate.
    /// Store that one request until the existing root navigation state can own it.
    func attachRoot(_ model: RootTabStateModel) {
        rootStateModel = model
        if pendingCalculatorBeforeRoot {
            pendingCalculatorBeforeRoot = false
            model.requestPenCalculatorQuickAction()
        }
        rootSubscription = model.$dependencies.sink { [weak self] dependencies in
            self?.homeSubscription = dependencies?.rootHomeStateModel.$state.sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateAvailableQuickActions() }
            }
            DispatchQueue.main.async { self?.updateAvailableQuickActions() }
        }
        updateAvailableQuickActions()
    }

    /// Scene activation can follow the shortcut callback after SwiftUI's first
    /// render. Republish the pending delivery without creating a second request.
    func reactivatePendingCalculatorQuickAction() {
        guard let rootStateModel,
              rootStateModel.penCalculatorQuickActionRequest != nil else { return }
        rootStateModel.reactivatePenCalculatorQuickAction()
        trace("calculator shortcut reactivated with scene", log: calculatorShortcutLog,
            category: ConstantsLog.categoryAppDelegate, type: .info)
    }

    static func availableActions(calculatorVisible: Bool, speakReadings: Bool) -> [QuickActionType] {
        (calculatorVisible ? [.penCalculator] : [])
            + [.silentAlarms, speakReadings ? .stopSpeakingReadings : .speakReadings]
    }

    private func calculatorSourceIsValid() -> Bool {
        TherapyMetricsManager.doseSourceIsReady(UserDefaults.standard.dataFlowPolicy,
            cutover: TreatmentSourceCutover.current())
    }

    private func calculatorIsVisible() -> Bool {
        guard let dependencies = rootStateModel?.dependencies else { return false }
        let loop = dependencies.rootHomeStateModel.state.loop
        return RootHomeCalculatorShortcutPolicy.isVisible(
            policy: UserDefaults.standard.dataFlowPolicy,
            cutover: TreatmentSourceCutover.current(),
            iobSource: loop.therapyMetrics?.iob.source,
            cobSource: loop.therapyMetrics?.cob.source,
            isHistorical: loop.isHistorical,
            localInputsComplete: !TherapyMetricsManager.shared.hasUncommittedForecastInputChanges
                && !HealthKitTherapyImportManager.shared.localInputIsIncomplete(.insulin)
                && !HealthKitTherapyImportManager.shared.localInputIsIncomplete(.carbohydrates))
    }
    
    /// Refresh available quick actions
    func updateAvailableQuickActions() {
        let actions = Self.availableActions(calculatorVisible: calculatorIsVisible(),
                                            speakReadings: UserDefaults.standard.speakReadings)
        let silenceIsActive = SelectiveAlarmSilence.isActive(defaults: silenceDefaults)
        guard UIApplication.shared.shortcutItems?.map(\.type) != actions.map(\.rawValue)
                || publishedSilenceIsActive != silenceIsActive else { return }
        UIApplication.shared.shortcutItems = actions.map { $0.shortcutItem(silenceIsActive: silenceIsActive) }
        publishedSilenceIsActive = silenceIsActive
    }
    
    /// Perform the necessary action when user selects a quick action
    @discardableResult func handleQuickAction(_ actionType: QuickActionType) -> Bool {
        switch actionType {
            case .penCalculator:
                // A stale icon item cannot bypass source ownership. During a cold start the
                // dependencies may not exist yet; Home rechecks source ownership before presenting.
                guard calculatorSourceIsValid() else {
                    trace("calculator shortcut rejected: local source unavailable",
                        log: calculatorShortcutLog, category: ConstantsLog.categoryAppDelegate, type: .info)
                    updateAvailableQuickActions()
                    return false
                }
                if let rootStateModel {
                    rootStateModel.requestPenCalculatorQuickAction()
                } else {
                    pendingCalculatorBeforeRoot = true
                }
                trace("calculator shortcut queued", log: calculatorShortcutLog,
                    category: ConstantsLog.categoryAppDelegate, type: .info)
            case .silentAlarms:
                // Persist immediately, including a cold start before Home or its dependencies exist.
                // The label remains Lydløs; a second explicit tap ends this pause only.
                SelectiveAlarmSilence.toggle(defaults: silenceDefaults)
            case .speakReadings:
                UserDefaults.standard.speakReadings = true
            case .stopSpeakingReadings:
                UserDefaults.standard.speakReadings = false
        }
        
        // Refresh actions to represent current state
        updateAvailableQuickActions()
        return true
    }
    
    // MARK: - observe function
    
    // update available quick actions when the related setting is changed from elsewhere
    nonisolated override public func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        guard let keyPath = keyPath,
              let keyPathEnum = UserDefaults.Key(rawValue: keyPath)
        else { return }
        
        switch keyPathEnum {
            case UserDefaults.Key.speakReadings:
                // Defaults can be changed off-main. Update UIKit on main without blocking the writer.
                DispatchQueue.main.async { [weak self] in
                    self?.updateAvailableQuickActions()
                }
                
            default:
                break
        }
    }
}
