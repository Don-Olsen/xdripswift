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
            return localize("forecast.mlStopped", "Training stopped when the app left the foreground. You can try again.")
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
    @State private var selfCheckCSVURL: URL?

    private func t(_ key: String, _ fallback: String) -> String {
        GlucoseForecastTexts.text(key, fallback: fallback)
    }

    var body: some View {
        Form {
            Section {
                if let metadata {
                    if currentContext.map({ metadata.context == $0 }) == true,
                       GlucoseForecastMLModelCompatibility.isUsable(metadata) {
                        LabeledContent(t("forecast.mlCompatible", "Model matches current settings"),
                                       value: metadata.trainedAt.formatted())
                    } else {
                        LabeledContent(t("forecast.mlIncompatible", "Saved model does not match current settings"),
                                       value: metadata.trainedAt.formatted())
                        Text(t("forecast.mlIncompatibleFallback",
                               "The forecast engine is used until a model for the current settings and treatment sources passes self-check."))
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
                    Text(t("forecast.mlKeepOpen", "Keep the app open until training and the self-check finish."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if status.lastOutcome == "trainingIssue", let issue = status.lastIssue {
                    Text(issue.danishMessage).foregroundStyle(.secondary)
                } else if !preparationStatus.isEmpty {
                    Text(preparationStatus).foregroundStyle(.secondary)
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

    private func refresh() {
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
    }

    private func format(_ value: Double) -> String {
        value.isFinite ? value.formatted(.number.precision(.fractionLength(2))) : "–"
    }
}
