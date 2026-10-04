//
//  GlucoseForecastMLTrainingCoordinator.swift
//  xdrip
//
//  Foreground-triggered, low-priority historical replay. Live forecast and BLE work
//  never wait for this loader or for Create ML training.
//

import Foundation
import HealthKit
#if canImport(UIKit)
import UIKit
#endif

final class GlucoseForecastMLTrainingCoordinator: @unchecked Sendable {
    static let shared = GlucoseForecastMLTrainingCoordinator()
    static let statusDidChange = Notification.Name("GlucoseForecastMLTrainingPreparationDidChange")

    private let lock = NSLock()
    private var preparationInProgress = false
    private var preparationTask: Task<Void, Never>?
    private var preparationCancellation: GlucoseForecastMLHistoryCancellation?
    private var previousAutomaticAttempt: (context: GlucoseForecastMLContext, date: Date)?
    private var preparationStatus = ""
    private var preparationCoverage = ""
    private var backgroundObservers: [NSObjectProtocol] = []
    private static let automaticRetryInterval: TimeInterval = 24 * 60 * 60
    private static let stoppedStatus = "Historiklæsningen blev stoppet, da appen blev forladt."

    private init() {
        #if canImport(UIKit)
        // The first Health read authorization sheet may temporarily make the
        // app inactive without sending it to the background. Keep that user-
        // initiated training attempt alive until the app actually leaves.
        for name in [UIApplication.didEnterBackgroundNotification] {
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

    var isPreparing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return preparationInProgress
    }

    var coverageText: String {
        lock.lock()
        defer { lock.unlock() }
        return preparationCoverage
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
            updateStatus("Træning kræver fuldstændige og entydige behandlingskilder.")
            return
        }
        let manager = GlucoseForecastMLManager.shared
        guard force || manager.shouldTrain(context: context, now: now) else { return }
        let cancellation = GlucoseForecastMLHistoryCancellation()
        lock.lock()
        if preparationInProgress || (!force && previousAutomaticAttempt?.context == context &&
            now.timeIntervalSince(previousAutomaticAttempt!.date) < Self.automaticRetryInterval) {
            lock.unlock()
            return
        }
        preparationInProgress = true
        preparationCancellation = cancellation
        if !force { previousAutomaticAttempt = (context, now) }
        preparationStatus = "Henter historik (0 af 365 dage)… Hold appen åben, mens den træner."
        preparationCoverage = ""
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
            // A successful HealthKit authorization request does not reveal whether
            // read access was granted. Empty results are handled as missing data;
            // the history loader applies the same coverage rules to local fallback.
            await Self.requestBloodGlucoseReadAccessIfAvailable()
            guard await Self.waitForActiveAfterAuthorization(cancellation: cancellation),
                  !Task.isCancelled, !cancellation.isCancelled else {
                cancellation.cancel()
                self.finishPreparation(Self.stoppedStatus, cancellation: cancellation)
                return
            }
            let result = await loader.load(days: 365, at: now, policy: policy,
                settings: settings, sensitivityMgdlPerUnit: sensitivity,
                carbohydrateRatioGramsPerUnit: ratio, cancellation: cancellation,
                progress: { [weak self] completed, total in
                    self?.updatePreparationStatus(
                        "Henter historik (\(completed) af \(total) dage)… Hold appen åben, mens den træner.",
                        cancellation: cancellation)
                })
            let foreground = await Self.appIsActive()
            guard foreground, !Task.isCancelled, !cancellation.isCancelled else {
                cancellation.cancel()
                self.finishPreparation(Self.stoppedStatus, cancellation: cancellation)
                return
            }
            if let result {
                self.updateCoverage(result.coverage, cancellation: cancellation)
                if result.coverage.usableDays < GlucoseForecastMLChronology.minimumUsableDays {
                    self.finishPreparation(
                        "Ikke nok brugbare data: \(result.coverage.usableDays) af 60 brugbare dage. Prognosemotoren bruges fortsat.",
                        cancellation: cancellation)
                } else {
                    manager.requestTraining(examples: result.examples, context: context, force: force)
                    self.finishPreparation(manager.statusSummary.isTraining ? "" :
                        "Modeltræningen kunne ikke startes nu. Prognosemotoren bruges fortsat.",
                        cancellation: cancellation)
                }
            } else {
                self.finishPreparation("Historikken kunne ikke læses sikkert. Prognosemotoren bruges fortsat.",
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
            updateStatus("Angiv insulinfølsomhed og kulhydratfaktor før træning.")
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

    /// HealthKit may invoke its authorization callback while its system sheet
    /// still has the app in `.inactive`. Wait only for that one foreground
    /// transition; ordinary backgrounding still cancels the attempt.
    private static func waitForActiveAfterAuthorization(
        cancellation: GlucoseForecastMLHistoryCancellation) async -> Bool {
        #if canImport(UIKit)
        for _ in 0..<300 {
            if Task.isCancelled || cancellation.isCancelled { return false }
            let state = await MainActor.run { UIApplication.shared.applicationState }
            if state == .active { return true }
            if state == .background { return false }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
        #else
        return true
        #endif
    }

    private static func requestBloodGlucoseReadAccessIfAvailable() async {
        guard HKHealthStore.isHealthDataAvailable(),
              let glucose = HKObjectType.quantityType(forIdentifier: .bloodGlucose) else { return }
        let store = HKHealthStore()
        // HealthKit deliberately does not disclose read authorization. The
        // completion only tells us that the request was processed, not whether
        // samples are readable. Never treat it as proof of permission.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                store.requestAuthorization(toShare: [], read: [glucose]) { _, _ in
                    continuation.resume()
                }
            }
        }
    }

    private func cancelForBackground() {
        lock.lock()
        // A canceled training run must be eligible again on the next foreground
        // use, even if history preparation had already handed off to Create ML.
        previousAutomaticAttempt = nil
        guard preparationInProgress else { lock.unlock(); return }
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
        preparationInProgress = false
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
        preparationCoverage = ""
        lock.unlock()
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
    }

    private func updatePreparationStatus(_ status: String,
                                         cancellation: GlucoseForecastMLHistoryCancellation) {
        lock.lock()
        guard preparationInProgress, preparationCancellation === cancellation,
              !cancellation.isCancelled else { lock.unlock(); return }
        preparationStatus = status
        lock.unlock()
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
    }

    private func updateCoverage(_ coverage: GlucoseForecastMLHistoryCoverage,
                                cancellation: GlucoseForecastMLHistoryCancellation) {
        lock.lock()
        guard preparationInProgress, preparationCancellation === cancellation,
              !cancellation.isCancelled else { lock.unlock(); return }
        let counts = coverage.exampleCountsByHorizon
        preparationCoverage = "\(coverage.usableDays) brugbare dage · +30: \(counts[30, default: 0]) · +60: \(counts[60, default: 0]) · +120: \(counts[120, default: 0]) eksempler"
        lock.unlock()
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
    }
}
