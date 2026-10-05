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
    static let historicalReadIdentifiers: [HKQuantityTypeIdentifier] = [
        .bloodGlucose, .insulinDelivery, .dietaryCarbohydrates
    ]

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
        if TreatmentSourceCutover.hasInvalidStoredValue() {
            let importer = HealthKitTherapyImportManager.shared
            updateStatus("Historisk kildeovergang: ugyldig; dato og kilde-id'er kan ikke læses. " +
                "Løbende import: insulin \(importer.isEnabled(.insulin) ? "til" : "fra"), " +
                "kulhydrat \(importer.isEnabled(.carbohydrates) ? "til" : "fra"). " +
                "Behandlingsforespørgsler: 0 udført, sprunget over pga. ugyldig overgang. " +
                "Træning er stoppet uden at ændre behandlinger.")
            return
        }
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
            if let authorizationFailure = await Self.requestHistoricalReadAccessIfAvailable() {
                cancellation.recordReadFailure(authorizationFailure)
                self.finishPreparation("Historiklæsning stoppet: \(authorizationFailure). " +
                    "Prognosemotoren bruges fortsat.", cancellation: cancellation)
                return
            }
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
                let reason = cancellation.readFailure.map { "Historiklæsning stoppet: \($0)." }
                    ?? "Historikken kunne ikke læses sikkert."
                self.finishPreparation("\(reason) Prognosemotoren bruges fortsat.",
                    cancellation: cancellation, diagnostic: cancellation.readDiagnostic)
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

    private static func requestHistoricalReadAccessIfAvailable() async -> String? {
        let types = historicalReadIdentifiers.compactMap {
            HKObjectType.quantityType(forIdentifier: $0)
        }
        guard HKHealthStore.isHealthDataAvailable(),
              types.count == historicalReadIdentifiers.count
        else { return "Sundhed-historik er ikke tilgængelig på denne enhed" }
        let store = HKHealthStore()
        let readTypes = Set(types.map { $0 as HKObjectType })
        // HealthKit deliberately does not disclose read authorization. The
        // completion only tells us that the request was processed, not whether
        // samples are readable. Never treat it as proof of permission.
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.main.async {
                store.requestAuthorization(toShare: [],
                    read: readTypes) { completed, error in
                    if let error {
                        let details = error as NSError
                        continuation.resume(returning:
                            "Sundhed-tilladelsesanmodning: \(details.domain)/\(details.code)")
                    } else {
                        continuation.resume(returning: completed ? nil :
                            "Sundhed-tilladelsesanmodning blev ikke gennemført")
                    }
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
                                   cancellation: GlucoseForecastMLHistoryCancellation,
                                   diagnostic: String? = nil) {
        lock.lock()
        guard preparationCancellation === cancellation else { lock.unlock(); return }
        preparationInProgress = false
        preparationTask = nil
        preparationCancellation = nil
        if cancellation.isCancelled { previousAutomaticAttempt = nil }
        preparationStatus = cancellation.isCancelled ? Self.stoppedStatus : status
        if let diagnostic { preparationCoverage = diagnostic }
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
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "da_DK")
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        func spanText(_ span: GlucoseForecastMLHistoryReadSpan) -> String {
            guard let first = span.firstDate, let last = span.lastDate else { return "0 poster" }
            return "\(span.count) poster (\(formatter.string(from: first))–\(formatter.string(from: last)))"
        }
        var lines = [
            "\(coverage.usableDays) brugbare dage · Sundhed: \(coverage.healthKitDays) · app: \(coverage.localFallbackDays)",
            "Kandidatdage før kildevalg: Sundhed \(coverage.healthCandidateDays) · app \(coverage.localCandidateDays)",
            "+30: \(counts[30, default: 0]) · +60: \(counts[60, default: 0]) · +120: \(counts[120, default: 0]) eksempler",
            "Sundhed-tidspunkter: \(coverage.mergedHealthGlucoseTimestamps) samlet fra kopier · \(coverage.discardedHealthGlucoseTimestamps) kasseret ved konflikt",
            "Ønsket: \(formatter.string(from: coverage.requestedStart))–\(formatter.string(from: coverage.requestedEnd)) · læst \(coverage.completedDays) af \(coverage.requestedDays) dage"
        ]
        if coverage.cutoverState == .valid, let cutoff = coverage.cutoverDate {
            formatter.timeStyle = .short
            lines.append("Kildeovergang: gyldig \(formatter.string(from: cutoff)) · insulin \(coverage.cutoverInsulinSourceBundleID ?? "ukendt") · kulhydrat \(coverage.cutoverCarbohydrateSourceBundleID ?? "ukendt")")
            formatter.timeStyle = .none
        } else {
            lines.append("Kildeovergang: \(coverage.cutoverState == .invalid ? "ugyldig" : "mangler")")
        }
        func queryText(_ evidence: GlucoseForecastMLTreatmentQueryEvidence) -> String {
            let reason: String
            switch evidence.skipReason {
            case .importDisabledWithoutCutover:
                reason = " · springes over: løbende import fra og ingen gyldig overgang"
            case .missingSelectedSource:
                reason = " · springes over: intet valgt kilde-id"
            case nil:
                reason = ""
            }
            let bundles = evidence.returnedSourceCounts.keys.sorted().map {
                "\($0): \(evidence.returnedSourceCounts[$0, default: 0])"
            }.joined(separator: ", ")
            return "løbende import \(evidence.effectiveImportEnabled ? "til" : "fra") · " +
                "forespørgsler \(evidence.executedQueries) startet / \(evidence.skippedQueries) sprunget over\(reason) · " +
                "HK-adapter rå \(evidence.returnedCount) [\(bundles.isEmpty ? "ingen kilde" : bundles)] · " +
                "frasorteret: kilde \(evidence.sourceExcludedCount), tid \(evidence.dateExcludedCount), " +
                "overgang \(evidence.cutoffExcludedCount), ugyldig \(evidence.invalidExcludedCount), " +
                "dublet \(evidence.duplicateExcludedCount), ikke-konverterbar \(evidence.unconvertedCount) · " +
                "efter kilde og tid \(evidence.sourceMatchedCount) · godkendt \(evidence.acceptedCount)"
        }
        func discoveredSources(_ values: [GlucoseForecastMLHealthSource], selected: String?) -> String {
            guard !values.isEmpty else { return "ingen synlige kilder" }
            return values.sorted { $0.bundleIdentifier < $1.bundleIdentifier }.map {
                "\($0.name) [\($0.bundleIdentifier)]\($0.bundleIdentifier == selected ? " (eksakt match)" : "")"
            }.joined(separator: ", ")
        }
        func noAcceptedRows(_ label: String,
                            evidence: GlucoseForecastMLTreatmentQueryEvidence,
                            selected: String?) -> String? {
            guard evidence.executedQueries > 0, evidence.acceptedCount == 0 else { return nil }
            if evidence.returnedCount == 0 {
                return "Ingen læsbar \(label)historik fra \(selected ?? "valgt kilde") i perioden. " +
                    "Et tomt Sundhed-svar skelner ikke mellem manglende poster og manglende læseadgang. " +
                    "Kontrollér appens læseadgang i Sundhed."
            }
            if evidence.sourceMatchedCount == 0 {
                return "Sundhed returnerede \(label)poster, men ingen matchede det gemte kilde-id " +
                    "\(selected ?? "ukendt"). Ingen anden kilde blev valgt automatisk."
            }
            return "Sundhed returnerede \(label)poster fra den valgte kilde, men ingen bestod " +
                "tid, kildeovergang og validering; se frasorteringstallene ovenfor."
        }
        if coverage.healthGlucoseByBundle.isEmpty {
            lines.append("Sundhed glukose: ingen læsbare xDrip-kilder fundet")
        } else {
            for bundle in coverage.healthGlucoseByBundle.keys.sorted() {
                if let span = coverage.healthGlucoseByBundle[bundle] {
                    lines.append("Sundhed glukose (\(bundle)): \(spanText(span))")
                }
            }
        }
        lines.append("App glukose: \(spanText(coverage.localGlucoseRead))")
        lines.append("Sundhed insulin (\(coverage.insulinSourceBundleID ?? "ingen kilde")): \(spanText(coverage.healthInsulinRead)) · \(coverage.acceptedHealthInsulinCount) gyldige bolusposter")
        lines.append("Insulinkilder fundet: \(discoveredSources(coverage.discoveredInsulinSources, selected: coverage.insulinSourceBundleID))")
        lines.append("Insulinlæsning: \(queryText(coverage.insulinQuery))")
        lines.append("Sundhed kulhydrat (\(coverage.carbohydrateSourceBundleID ?? "ingen kilde")): \(spanText(coverage.healthCarbohydrateRead)) · \(coverage.acceptedHealthCarbohydrateCount) gyldige poster")
        lines.append("Kulhydratkilder fundet: \(discoveredSources(coverage.discoveredCarbohydrateSources, selected: coverage.carbohydrateSourceBundleID))")
        lines.append("Kulhydratlæsning: \(queryText(coverage.carbohydrateQuery))")
        if let message = noAcceptedRows("insulin", evidence: coverage.insulinQuery,
                                        selected: coverage.insulinSourceBundleID) {
            lines.append(message + (coverage.insulinQuery.returnedCount == 0 ?
                " (Insulinlevering)" : ""))
        }
        if let message = noAcceptedRows("kulhydrat", evidence: coverage.carbohydrateQuery,
                                        selected: coverage.carbohydrateSourceBundleID) {
            lines.append(message + (coverage.carbohydrateQuery.returnedCount == 0 ?
                " (Kulhydrater)" : ""))
        }
        lines.append("App-database insulin/kulhydrat: \(spanText(coverage.localInsulinRead)) / \(spanText(coverage.localCarbohydrateRead))")
        lines.append("Dage uden påvist behandlingsdækning: insulin \(coverage.unknownInsulinDays) · kulhydrat \(coverage.unknownCarbohydrateDays)")
        if let median = coverage.healthLocalAbsoluteDifferenceMedianMgdl,
           let p95 = coverage.healthLocalAbsoluteDifferenceP95Mgdl {
            let numberLocale = Locale(identifier: "da_DK")
            let medianText = median.formatted(.number.precision(.fractionLength(2)).locale(numberLocale))
            let p95Text = p95.formatted(.number.precision(.fractionLength(2)).locale(numberLocale))
            lines.append("Sundhed/app finalValue (\(coverage.healthLocalComparisonCount) fælles tidspunkter): median \(medianText), 95-percentil \(p95Text) mg/dL forskel")
        }
        preparationCoverage = lines.joined(separator: "\n")
        lock.unlock()
        NotificationCenter.default.post(name: Self.statusDidChange, object: nil)
    }
}
