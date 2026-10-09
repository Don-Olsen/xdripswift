//
//  GlucoseForecastMLSettingsView.swift
//  xdrip
//
//  Local-only model status and explicit retraining. No model import or upload.
//

import Combine
import SwiftUI

enum GlucoseForecastMLStatusPresentation {
    typealias Localize = (String, String) -> String

    static func maeMmolPerL(_ mgdl: Double) -> Double { mgdl.mgDlToMmol() }

    static func preparationOrPreviousIssue(_ preparation: String,
                                           previousIssue: GlucoseForecastMLTrainingIssue?) -> String? {
        if !preparation.isEmpty { return preparation }
        return previousIssue?.danishMessage
    }

    static func progress(_ progress: GlucoseForecastMLTrainingProgress?,
                         localize: Localize) -> String {
        switch progress {
        case .trainingModels(let completed, let total):
            let format = localize("forecast.mlFitsCompleted", "%1$d of %2$d training runs completed")
            return String(format: format, completed, total)
        case .calibrating:
            return localize("forecast.mlCalibrating", "Calibrating the uncertainty band…")
        case .selfChecking:
            return localize("forecast.mlChecking", "Checking the model on separate historical days…")
        case .installing:
            return localize("forecast.mlInstalling", "Saving and checking the model package…")
        case nil:
            return localize("forecast.mlTraining", "Training locally on this iPhone…")
        }
    }

    static func outcome(_ code: String?, report: GlucoseForecastMLSelfCheck? = nil,
                        issue: GlucoseForecastMLTrainingIssue? = nil,
                        localize: Localize) -> String? {
        guard let code else { return nil }
        if code == "trainingIssue" { return issue?.danishMessage ??
            localize("forecast.mlFailed", "Training could not finish. The forecast engine remains available.") }
        switch code {
        case "activated":
            return localize("forecast.mlActivated", "Training finished. The checked model is now active.")
        case "rejected":
            if let reason = report?.rejectionReasons.first {
                let enginePrefix = "candidateNotBetterThanEngineAt"
                if reason.hasPrefix(enginePrefix),
                   let horizon = Int(reason.dropFirst(enginePrefix.count)) {
                    let message = localize("forecast.mlRejectedEngineAt",
                        "Rejected in self-check: ML was not better than the engine at +%d minutes.")
                    return String(format: message, horizon)
                }
                let activePrefix = "candidateWorseThanActiveAt"
                if reason.hasPrefix(activePrefix),
                   let horizon = Int(reason.dropFirst(activePrefix.count)) {
                    let message = localize("forecast.mlRejectedActiveAt",
                        "Rejected in self-check: ML was worse than the previous model at +%d minutes.")
                    return String(format: message, horizon)
                }
            }
            return localize("forecast.mlRejected", "Training finished, but the model did not pass the historical self-check. The previous forecast remains active.")
        case "backgroundCancelled":
            return "Træningen er sat på pause. Færdige trin bevares; automatisk genoptagelse afventer opladning og køretid fra iOS."
        case GlucoseForecastMLTrainingFailure.insufficientHistory.rawValue,
             GlucoseForecastMLTrainingFailure.insufficientTrainingRows.rawValue,
             GlucoseForecastMLTrainingFailure.insufficientCalibrationRows.rawValue,
             GlucoseForecastMLTrainingFailure.insufficientSelfCheckRows.rawValue,
             GlucoseForecastMLTrainingFailure.insufficientWalkForwardRows.rawValue:
            return localize("forecast.mlNotEnoughHistory", "There are not enough usable historical readings to train and check a model yet.")
        case GlucoseForecastMLTrainingFailure.trainingUnavailable.rawValue:
            return localize("forecast.mlUnavailable", "Local model training is unavailable on this device.")
        case "training":
            return nil
        default:
            return localize("forecast.mlFailed", "Training could not finish. The forecast engine remains available.")
        }
    }
}

struct GlucoseForecastMLSettingsView: View {
    let coreDataManager: CoreDataManager

    @State private var status = GlucoseForecastMLManager.shared.statusSummary
    @State private var metadata = GlucoseForecastMLManager.shared.activeModelMetadata
    @State private var preparationStatus = GlucoseForecastMLTrainingCoordinator.shared.statusText
    @State private var coverageText = GlucoseForecastMLTrainingCoordinator.shared.coverageText
    @State private var isPreparing = GlucoseForecastMLTrainingCoordinator.shared.isPreparing
    @State private var currentContext: GlucoseForecastMLContext?
    @State private var compatibility: GlucoseForecastMLModelCompatibility.Assessment =
        .invalid(.packageUnavailable)
    @State private var transitionStatus: GlucoseForecastMLTransitionEvidence.Status?
    @State private var selfCheckCSVURL: URL?
    @State private var schedulingIssue: String?

    private func t(_ key: String, _ fallback: String) -> String {
        GlucoseForecastTexts.text(key, fallback: fallback)
    }

    var body: some View {
        Form {
            Section {
                if let metadata {
                    switch compatibility {
                    case .exact:
                        LabeledContent(t("forecast.mlCompatible", "Model matches current settings"),
                                       value: metadata.trainedAt.formatted())
                    case .transitionCompatible:
                        LabeledContent(t("forecast.mlTransitionCompatible",
                            "Previous model is compatible with local treatment logging"),
                            value: metadata.trainedAt.formatted())
                        switch transitionStatus {
                        case .awaiting(let days, let pairs):
                            Text(String(format: t("forecast.mlTransitionAwaiting",
                                "Comparing the model with the engine: %d of 7 usable days, %d paired +60-minute results. The model remains available."),
                                days, pairs))
                                .foregroundStyle(.secondary)
                        case .passed(let result):
                            Text(String(format: t("forecast.mlTransitionPassed",
                                "The prior model passed the local +60-minute comparison on %d paired results."),
                                result.pairCount))
                                .foregroundStyle(.secondary)
                        case .disabled, .unreadable, .none:
                            Text(t("forecast.mlTransitionUnavailable",
                                "The engine is used because the model comparison is unavailable."))
                                .foregroundStyle(.secondary)
                        }
                    case .invalid(let reason):
                        LabeledContent(t("forecast.mlIncompatible", "Saved model does not match current settings"),
                                       value: metadata.trainedAt.formatted())
                        Text(invalidReasonText(reason))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(t("forecast.mlUsableDays", "Usable data days"), value: "\(metadata.usableDayCount)")
                    LabeledContent(t("forecast.mlModelID", "Model ID"), value: metadata.modelID)
                } else {
                    Text(t("forecast.mlEngineFallback", "The forecast engine is active until a personal model passes every self-check."))
                }
                if status.isTraining || isPreparing {
                    HStack {
                        ProgressView()
                        Text(status.isTraining
                             ? GlucoseForecastMLStatusPresentation.progress(status.progress, localize: t)
                             : preparationStatus)
                    }
                    Text("Historik forberedes under almindelig brug. Automatisk træning kan derefter køre under opladning. Ved Træn nu: hold appen åben.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let message = GlucoseForecastMLStatusPresentation.preparationOrPreviousIssue(
                    preparationStatus,
                    previousIssue: status.lastOutcome == "trainingIssue" ? status.lastIssue : nil) {
                    Text(message).foregroundStyle(.secondary)
                } else if let outcome = GlucoseForecastMLStatusPresentation.outcome(
                    status.lastOutcome, report: status.lastSelfCheck,
                    issue: status.lastIssue, localize: t) {
                    Text(outcome).foregroundStyle(.secondary)
                }
                if !coverageText.isEmpty {
                    Text(coverageText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let schedulingIssue {
                    Text(schedulingIssue).foregroundStyle(.orange)
                }
                Text("Automatisk træning forsøges cirka én gang om ugen under opladning. iOS vælger tidspunktet og kan afbryde arbejdet; færdige trin gemmes til genoptagelse.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(t("forecast.mlTrainNow", "Træn nu")) {
                    GlucoseForecastMLTrainingCoordinator.shared.trainNow(coreDataManager: coreDataManager)
                    refresh()
                }
                .disabled(status.isTraining || isPreparing)
                Text(t("forecast.mlHealthReadExplanation",
                       "When personal training first starts, iOS may ask for read access to glucose in Health. Available historical readings are used locally on this iPhone for training. You can change access in Health."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text(t("forecast.personalML", "Personal forecast model"))
            } footer: {
                Text(t("forecast.mlOnDevice", "Training and models stay on this iPhone. The existing forecast engine remains the fallback. Training never changes measured glucose or alarms."))
            }

            if let selfCheck = status.lastSelfCheck ?? metadata?.selfCheck {
                Section(t("forecast.mlSelfCheck", "Last historical self-check")) {
                    Text("Referenceperiode: \(selfCheck.startedAt.formatted(date: .abbreviated, time: .omitted))–\((selfCheck.referenceEndAt ?? selfCheck.endedAt).formatted(date: .abbreviated, time: .omitted))")
                        .font(.footnote)
                    ForEach([30, 60, 120], id: \.self) { horizon in
                        if let metric = selfCheck.horizons[horizon] {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("+\(horizon) min · \(metric.count) fælles eksempler")
                                    .fontWeight(.semibold)
                                Text("MAE mmol/L · motor \(format(GlucoseForecastMLStatusPresentation.maeMmolPerL(metric.engineMAE))) · ML \(format(GlucoseForecastMLStatusPresentation.maeMmolPerL(metric.candidateMAE)))" +
                                     (metric.unchangedMAE.map { " · uændret \(format(GlucoseForecastMLStatusPresentation.maeMmolPerL($0)))" } ?? ""))
                                if let engineBias = metric.engineBias,
                                   let unchangedBias = metric.unchangedBias {
                                    Text("Signeret fejl mmol/L (prognose − faktisk) · motor \(format(GlucoseForecastMLStatusPresentation.maeMmolPerL(engineBias))) · ML \(format(GlucoseForecastMLStatusPresentation.maeMmolPerL(metric.candidateBias))) · uændret \(format(GlucoseForecastMLStatusPresentation.maeMmolPerL(unchangedBias)))")
                                }
                                if let unchangedMAE = metric.unchangedMAE {
                                    Text("ML-forbedring mod uændret: \(format(GlucoseForecastMLStatusPresentation.maeMmolPerL(unchangedMAE - metric.candidateMAE))) mmol/L")
                                }
                                Text("\(t("forecast.mlCoverage", "Observed band coverage")): \(format(metric.candidateCoverage * 100)) %")
                            }
                            .font(.footnote)
                        }
                    }
                    if let selfCheckCSVURL {
                        ShareLink(item: selfCheckCSVURL) {
                            Label("Del selvtjekkets eksempler (CSV)", systemImage: "square.and.arrow.up")
                        }
                        Text("Filen indeholder helbredsdata og deles kun, når du vælger en modtager.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Text(t("forecast.mlRetrospective", "Historical treatment import times and past settings are not always known. The self-check is retrospective, not a guarantee of future accuracy. The band targets 80% at +30/+60/+120 minutes; intermediate widths are interpolated."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(t("forecast.personalML", "Personal forecast model"))
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: GlucoseForecastMLManager.modelDidChange)
            .receive(on: DispatchQueue.main)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: GlucoseForecastMLManager.statusDidChange)
            .receive(on: DispatchQueue.main)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: GlucoseForecastMLTrainingCoordinator.statusDidChange)
            .receive(on: DispatchQueue.main)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: HealthKitTherapyImportManager.statusDidChange)
            .receive(on: DispatchQueue.main)) { _ in refresh() }
    }

    @MainActor private func refresh() {
        schedulingIssue = GlucoseForecastMLBackgroundScheduler.shared.schedulingIssue
        status = GlucoseForecastMLManager.shared.statusSummary
        metadata = GlucoseForecastMLManager.shared.activeModelMetadata
        selfCheckCSVURL = GlucoseForecastMLManager.shared.selfCheckCSVURL
        preparationStatus = GlucoseForecastMLTrainingCoordinator.shared.statusText
        coverageText = GlucoseForecastMLTrainingCoordinator.shared.coverageText
        isPreparing = GlucoseForecastMLTrainingCoordinator.shared.isPreparing
        let defaults = UserDefaults.standard
        if let sensitivity = defaults.glucoseForecastManualSensitivityMgdlPerUnit,
           let ratio = defaults.glucoseForecastManualCarbRatioGramsPerUnit {
            currentContext = GlucoseForecastMLContext(
                sensitivityMgdlPerUnit: sensitivity,
                carbohydrateRatioGramsPerUnit: ratio,
                settings: TherapyModelSettings(defaults: defaults),
                sourceSignature: GlucoseForecastDataAdapter.presentationInputSignature(
                    horizonMinutes: 120, defaults: defaults, importer: .shared))
        } else {
            currentContext = nil
        }
        compatibility = GlucoseForecastMLManager.shared.compatibility(current: currentContext)
        transitionStatus = GlucoseForecastMLManager.shared.transitionStatus(current: currentContext)
    }

    private func invalidReasonText(_ reason: GlucoseForecastMLModelCompatibility.InvalidReason) -> String {
        switch reason {
        case .packageUnavailable:
            return t("forecast.mlReasonPackage", "The saved model package is unavailable. The engine is used.")
        case .generationChanged:
            return t("forecast.mlReasonGeneration", "The forecast engine or model format changed. The engine is used.")
        case .parametersChanged:
            return t("forecast.mlReasonParameters", "Personal therapy settings changed. The engine is used until a matching model passes self-check.")
        case .sourceChanged:
            return t("forecast.mlReasonSource", "The treatment source changed. The engine is used.")
        case .malformedSignature:
            return t("forecast.mlReasonSignature", "The saved source description cannot be verified. The engine is used.")
        case .transitionUnverified:
            return t("forecast.mlReasonTransition", "The earlier treatment-source transition cannot be verified. The engine is used.")
        case .sourceSetupIncomplete:
            return t("forecast.mlReasonSetup", "Treatment sources still need setup. The engine is used.")
        case .prospectiveWorse:
            return t("forecast.mlReasonWorse", "After seven usable days, the earlier model performed worse than the engine at +60 minutes and was disabled. The engine is used.")
        case .evidenceUnreadable:
            return t("forecast.mlReasonEvidence", "The local model comparison cannot be read. The engine is used to avoid an unverified model.")
        }
    }

    private func format(_ value: Double) -> String {
        value.isFinite ? value.formatted(.number.precision(.fractionLength(2))) : "–"
    }
}
