//
//  GlucoseForecastMLTrainingCoordinator.swift
//  xdrip
//
//  Foreground-triggered, low-priority historical replay. Live forecast and BLE work
//  never wait for this loader or for Create ML training.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

final class GlucoseForecastMLTrainingCoordinator: @unchecked Sendable {
    static let shared = GlucoseForecastMLTrainingCoordinator()
    static let statusDidChange = Notification.Name("GlucoseForecastMLTrainingPreparationDidChange")

    private let lock = NSLock()
    private var isPreparing = false
    private var preparationTask: Task<Void, Never>?
    private var preparationCancellation: GlucoseForecastMLHistoryCancellation?
    private var previousAutomaticAttempt: (context: GlucoseForecastMLContext, date: Date)?
    private var preparationStatus = ""
    private var backgroundObservers: [NSObjectProtocol] = []
    private static let automaticRetryInterval: TimeInterval = 24 * 60 * 60
    private static let stoppedStatus = "History preparation stopped when the app left the foreground."

    private init() {
        #if canImport(UIKit)
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            backgroundObservers.append(NotificationCenter.default.addObserver(forName: name,
                object: nil, queue: nil) { [weak self] _ in self?.cancelForBackground() })
        }
        #endif
    }

    deinit {
        backgroundObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    var statusText: String {
        lock.lock()
        defer { lock.unlock() }
        return preparationStatus
    }

    /// Called only from an active Home forecast or an explicit Settings button.
    /// This work is enqueued independently of the forecast adapter's serial worker.
    func scheduleIfNeeded(coreDataManager: CoreDataManager, policy: DataFlowPolicy,
                          settings: TherapyModelSettings, sensitivity: Double, ratio: Double,
                          sourceSignature: String, force: Bool = false, now: Date = .now) {
        guard GlucoseForecastDataAdapter.sourceAllowsForecast(policy),
              GlucoseForecastDataAdapter.treatmentSourcesAreUnambiguous(policy,
                  healthInsulinEnabled: HealthKitTherapyImportManager.shared.isEnabled(.insulin),
                  healthCarbsEnabled: HealthKitTherapyImportManager.shared.isEnabled(.carbohydrates)),
              !TherapyMetricsManager.shared.hasUncommittedForecastInputChanges,
              !HealthKitTherapyImportManager.shared.localInputIsIncomplete(.insulin),
              !HealthKitTherapyImportManager.shared.localInputIsIncomplete(.carbohydrates),
              let context = GlucoseForecastMLContext(sensitivityMgdlPerUnit: sensitivity,
                  carbohydrateRatioGramsPerUnit: ratio, settings: settings,
                  sourceSignature: sourceSignature) else {
            updateStatus("Training needs complete, unambiguous local forecast inputs.")
            return
        }
        let manager = GlucoseForecastMLManager.shared
        guard force || manager.shouldTrain(context: context, now: now) else { return }
        let cancellation = GlucoseForecastMLHistoryCancellation()
        lock.lock()
        if isPreparing || (!force && previousAutomaticAttempt?.context == context &&
            now.timeIntervalSince(previousAutomaticAttempt!.date) < Self.automaticRetryInterval) {
            lock.unlock()
            return
        }
        isPreparing = true
        preparationCancellation = cancellation
        if !force { previousAutomaticAttempt = (context, now) }
        preparationStatus = "Preparing local history on this iPhone…"
        lock.unlock()
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)

        let loader = GlucoseForecastMLHistoryLoader(coreDataManager: coreDataManager)
        let task = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            guard await Self.appIsActive(), !Task.isCancelled, !cancellation.isCancelled else {
                cancellation.cancel()
                self.finishPreparation(Self.stoppedStatus, cancellation: cancellation)
                return
            }
            // 240 days covers the user's long historical period while bounding memory on phone.
            // The loader reads one day at a time and yields value-only snapshots.
            let examples = await loader.load(days: 240, at: now, policy: policy,
                settings: settings, sensitivityMgdlPerUnit: sensitivity,
                carbohydrateRatioGramsPerUnit: ratio, cancellation: cancellation)
            let foreground = await Self.appIsActive()
            guard foreground, !Task.isCancelled, !cancellation.isCancelled else {
                cancellation.cancel()
                self.finishPreparation(Self.stoppedStatus, cancellation: cancellation)
                return
            }
            if let examples {
                manager.requestTraining(examples: examples, context: context, force: force)
                self.finishPreparation(examples.isEmpty
                    ? "No usable historical examples were found. The engine remains active."
                    : "History prepared; model training runs locally in the background.",
                    cancellation: cancellation)
            } else {
                self.finishPreparation("Historical inputs changed or could not be read. The engine remains active.",
                    cancellation: cancellation)
            }
        }
        lock.lock()
        if preparationCancellation === cancellation, !cancellation.isCancelled {
            preparationTask = task
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }

    func trainNow(coreDataManager: CoreDataManager) {
        let defaults = UserDefaults.standard
        let settings = TherapyModelSettings(defaults: defaults)
        let policy = defaults.dataFlowPolicy
        guard let sensitivity = defaults.glucoseForecastManualSensitivityMgdlPerUnit,
              let ratio = defaults.glucoseForecastManualCarbRatioGramsPerUnit else {
            updateStatus("Set insulin sensitivity and carbohydrate ratio before training.")
            return
        }
        let sourceSignature = GlucoseForecastDataAdapter.presentationInputSignature(
            horizonMinutes: 120, defaults: defaults, importer: .shared)
        scheduleIfNeeded(coreDataManager: coreDataManager, policy: policy,
                         settings: settings, sensitivity: sensitivity, ratio: ratio,
                         sourceSignature: sourceSignature, force: true)
    }

    private static func appIsActive() async -> Bool {
        #if canImport(UIKit)
        return await MainActor.run { UIApplication.shared.applicationState == .active }
        #else
        return true
        #endif
    }

    private func cancelForBackground() {
        lock.lock()
        // A canceled training run must be eligible again on the next foreground
        // use, even if history preparation had already handed off to Create ML.
        previousAutomaticAttempt = nil
        guard isPreparing else { lock.unlock(); return }
        preparationCancellation?.cancel()
        let task = preparationTask
        preparationStatus = Self.stoppedStatus
        lock.unlock()
        task?.cancel()
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
    }

    private func finishPreparation(_ status: String,
                                   cancellation: GlucoseForecastMLHistoryCancellation) {
        lock.lock()
        guard preparationCancellation === cancellation else { lock.unlock(); return }
        isPreparing = false
        preparationTask = nil
        preparationCancellation = nil
        if cancellation.isCancelled { previousAutomaticAttempt = nil }
        preparationStatus = cancellation.isCancelled ? Self.stoppedStatus : status
        lock.unlock()
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
    }

    private func updateStatus(_ status: String) {
        lock.lock()
        preparationStatus = status
        lock.unlock()
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
    }
}
