//
//  GlucoseForecastMLBackgroundScheduler.swift
//  xdrip
//
//  Schedules one charger-only opportunity for local ML training. The system
//  chooses the actual run time; the coordinator owns eligibility and input data.
//

import BackgroundTasks
import CryptoKit
import Foundation
import os

@MainActor final class GlucoseForecastMLBackgroundScheduler {
    static let shared = GlucoseForecastMLBackgroundScheduler()
    static let taskIdentifier = "com.GFZ896KN66.xdripswift.forecast-training"
    static let statusDidChange = Notification.Name("GlucoseForecastMLBackgroundSchedulerStatusDidChange")

    private enum Keys {
        static let desiredDate = "forecastML.background.desiredDate.v1"
        static let nextAllowedDate = "forecastML.background.nextAllowedDate.v1"
        static let inFlightDate = "forecastML.background.inFlightDate.v1"
        static let contextFingerprint = "forecastML.background.contextFingerprint.v1"
    }

    @MainActor private final class Run {
        let task: BGProcessingTask
        let contextFingerprint: String?
        var changedContextDueDate: Date?
        var completed = false

        init(task: BGProcessingTask, contextFingerprint: String?) {
            self.task = task
            self.contextFingerprint = contextFingerprint
        }
    }

    private let logger = Logger(subsystem: "com.GFZ896KN66.xdripswift", category: "ForecastMLBackground")
    private let defaults = UserDefaults.standard
    private var registered = false
    private var reconciling = false
    private var requestRevision = 0
    private var activeRun: Run?
    private(set) var schedulingIssue: String?

    private init() {}

    private var isConfigured: Bool {
        defaults.glucoseForecastHorizonMinutes > 0
            && GlucoseForecastMLTrainingCoordinator.currentContext() != nil
    }

    private func setSchedulingIssue(_ issue: String?) {
        guard schedulingIssue != issue else { return }
        schedulingIssue = issue
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
    }

    /// Must run before application(_:didFinishLaunchingWithOptions:) returns.
    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier,
                                                      using: .main) { [weak self] task in
            Task { @MainActor [weak self] in self?.handle(task) }
        }
        guard registered else {
            logger.error("Could not register the forecast ML background task")
            setSchedulingIssue("Automatisk træning kunne ikke registreres til baggrundskørsel.")
            return
        }
        setSchedulingIssue(nil)

        // A process killed during training cannot leave a permanently missing job.
        if defaults.object(forKey: Keys.inFlightDate) != nil {
            defaults.removeObject(forKey: Keys.inFlightDate)
            let retry = Date().addingTimeInterval(
                GlucoseForecastMLBackgroundSchedulePolicy.retryInterval(for: .interrupted))
            defaults.set(retry, forKey: Keys.nextAllowedDate)
            defaults.set(retry, forKey: Keys.desiredDate)
            requestRevision &+= 1
        }
        reconcilePendingRequest()
    }

    /// Keeps an existing earlier request when foreground preparation repeats.
    /// The persisted date also repairs a request the system has removed on a later launch.
    func schedule(earliestBeginDate: Date, context: GlucoseForecastMLContext? = nil) {
        guard earliestBeginDate.timeIntervalSinceReferenceDate.isFinite else { return }
        if let context, let fingerprint = Self.fingerprint(for: context) {
            let previous = defaults.string(forKey: Keys.contextFingerprint)
            if previous != fingerprint {
                defaults.set(fingerprint, forKey: Keys.contextFingerprint)
                if let activeRun {
                    // A running task owns its lease; queue only the latest context
                    // for after it completes instead of launching parallel work.
                    activeRun.changedContextDueDate = fingerprint == activeRun.contextFingerprint
                        ? nil : earliestBeginDate
                    return
                }
                defaults.removeObject(forKey: Keys.nextAllowedDate)
                defaults.removeObject(forKey: Keys.desiredDate)
            } else if let activeRun {
                if let queuedDate = activeRun.changedContextDueDate {
                    activeRun.changedContextDueDate = min(queuedDate, earliestBeginDate)
                }
                return
            }
        }
        guard activeRun == nil else { return }
        let desired = GlucoseForecastMLBackgroundSchedulePolicy.desiredDate(
            requested: earliestBeginDate,
            existing: defaults.object(forKey: Keys.desiredDate) as? Date,
            notBefore: defaults.object(forKey: Keys.nextAllowedDate) as? Date)
        if defaults.object(forKey: Keys.desiredDate) as? Date != desired {
            defaults.set(desired, forKey: Keys.desiredDate)
            requestRevision &+= 1
        }
        reconcilePendingRequest()
    }

    /// Disabling forecasting removes its own queued work, without touching
    /// unrelated system jobs or an active run's crash-recovery marker.
    func cancelPendingTraining() {
        defaults.removeObject(forKey: Keys.desiredDate)
        defaults.removeObject(forKey: Keys.nextAllowedDate)
        if activeRun == nil {
            defaults.removeObject(forKey: Keys.inFlightDate)
        } else {
            GlucoseForecastMLTrainingCoordinator.shared.cancelBackgroundTraining()
        }
        requestRevision &+= 1
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
    }

    private func reconcilePendingRequest() {
        guard isConfigured else {
            cancelPendingTraining()
            return
        }
        guard registered, !reconciling,
              defaults.object(forKey: Keys.desiredDate) is Date else { return }
        reconciling = true
        let revision = requestRevision
        BGTaskScheduler.shared.getPendingTaskRequests { [weak self] pending in
            let pendingRequests = pending.compactMap { request in
                (request as? BGProcessingTaskRequest).map(GlucoseForecastMLPendingRequest.init)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reconciling = false
                guard self.isConfigured else {
                    self.cancelPendingTraining()
                    return
                }
                guard revision == self.requestRevision else {
                    self.reconcilePendingRequest()
                    return
                }
                guard let desired = self.defaults.object(forKey: Keys.desiredDate) as? Date else { return }
                if let existing = pendingRequests.first(where: { $0.identifier == Self.taskIdentifier }),
                   GlucoseForecastMLBackgroundSchedulePolicy.canKeepPending(
                    existing, desired: desired,
                    notBefore: self.defaults.object(forKey: Keys.nextAllowedDate) as? Date) {
                    self.setSchedulingIssue(nil)
                    return
                }

                let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
                request.requiresExternalPower = true
                request.requiresNetworkConnectivity = false
                request.earliestBeginDate = max(desired, Date())
                do {
                    // Re-submitting this identifier replaces its previous pending request.
                    try BGTaskScheduler.shared.submit(request)
                    self.setSchedulingIssue(nil)
                } catch {
                    let failure = error as NSError
                    self.logger.error("Could not schedule forecast ML background task: \(failure.domain, privacy: .public) code \(failure.code)")
                    self.setSchedulingIssue("Automatisk træning kunne ikke planlægges i baggrunden (\(failure.domain): \(failure.code)).")
                }
            }
        }
    }

    private func handle(_ task: BGTask) {
        guard isConfigured else {
            task.setTaskCompleted(success: true)
            cancelPendingTraining()
            return
        }
        guard let task = task as? BGProcessingTask, activeRun == nil else {
            task.setTaskCompleted(success: false)
            return
        }
        let run = Run(task: task, contextFingerprint: defaults.string(forKey: Keys.contextFingerprint))
        activeRun = run
        task.expirationHandler = { [weak self, weak run] in
            Task { @MainActor [weak self, weak run] in
                guard let self, let run, self.activeRun === run, !run.completed else { return }
                GlucoseForecastMLTrainingCoordinator.shared.cancelBackgroundTraining()
                self.finish(run, outcome: .interrupted)
            }
        }
        defaults.set(Date(), forKey: Keys.inFlightDate)
        // Submit the next retry before doing work so an interrupted process does
        // not silently lose its only future opportunity.
        defaults.set(Date().addingTimeInterval(
            GlucoseForecastMLBackgroundSchedulePolicy.retryInterval(for: .interrupted)),
            forKey: Keys.desiredDate)
        requestRevision &+= 1
        reconcilePendingRequest()

        GlucoseForecastMLTrainingCoordinator.shared.runPreparedBackgroundTraining { [weak self, weak run] success in
            Task { @MainActor [weak self, weak run] in
                guard let self, let run else { return }
                self.finish(run, outcome: success ? .completed : .failed)
            }
        }
    }

    private func finish(_ run: Run, outcome: GlucoseForecastMLBackgroundRunOutcome) {
        guard activeRun === run, !run.completed else { return }
        run.completed = true
        activeRun = nil
        run.task.expirationHandler = nil
        defaults.removeObject(forKey: Keys.inFlightDate)
        run.task.setTaskCompleted(success: outcome == .completed)

        guard isConfigured else {
            cancelPendingTraining()
            return
        }

        if let changedContextDueDate = run.changedContextDueDate {
            defaults.removeObject(forKey: Keys.nextAllowedDate)
            defaults.set(changedContextDueDate, forKey: Keys.desiredDate)
        } else {
            let now = Date()
            let next = outcome == .completed
                ? max(GlucoseForecastMLTrainingCoordinator.shared.nextAutomaticTrainingDate()
                    ?? now.addingTimeInterval(
                        GlucoseForecastMLBackgroundSchedulePolicy.retryInterval(for: .completed)),
                    now.addingTimeInterval(1))
                : now.addingTimeInterval(
                    GlucoseForecastMLBackgroundSchedulePolicy.retryInterval(for: outcome))
            defaults.set(next, forKey: Keys.nextAllowedDate)
            defaults.set(next, forKey: Keys.desiredDate)
        }
        requestRevision &+= 1
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        reconcilePendingRequest()
    }

    static func fingerprint(for context: GlucoseForecastMLContext) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(context) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum GlucoseForecastMLBackgroundRunOutcome {
    case completed
    case failed
    case interrupted
}

/// Copies the system's pending request into a Sendable value before crossing actors.
struct GlucoseForecastMLPendingRequest: Sendable {
    let identifier: String
    let earliestBeginDate: Date?
    let requiresExternalPower: Bool
    let requiresNetworkConnectivity: Bool

    init(_ request: BGProcessingTaskRequest) {
        identifier = request.identifier
        earliestBeginDate = request.earliestBeginDate
        requiresExternalPower = request.requiresExternalPower
        requiresNetworkConnectivity = request.requiresNetworkConnectivity
    }
}

/// Pure request policy shared by the app scheduler and its regression tests.
enum GlucoseForecastMLBackgroundSchedulePolicy {
    static let interruptedRetryInterval: TimeInterval = 60 * 60
    static let failedRetryInterval: TimeInterval = 24 * 60 * 60

    static func retryInterval(for outcome: GlucoseForecastMLBackgroundRunOutcome) -> TimeInterval {
        switch outcome {
        case .completed: return GlucoseForecastMLChronology.modelAgeLimit + 1
        case .failed: return failedRetryInterval
        case .interrupted: return interruptedRetryInterval
        }
    }

    static func desiredDate(requested: Date, existing: Date?, notBefore: Date?) -> Date {
        let permitted = max(requested, notBefore ?? .distantPast)
        return min(permitted, existing.map { max($0, notBefore ?? .distantPast) } ?? .distantFuture)
    }

    static func canKeepPending(_ pending: GlucoseForecastMLPendingRequest,
                               desired: Date, notBefore: Date?) -> Bool {
        let date = pending.earliestBeginDate ?? .distantPast
        return pending.requiresExternalPower && !pending.requiresNetworkConnectivity
            && date >= (notBefore ?? .distantPast) && date <= desired
    }
}
