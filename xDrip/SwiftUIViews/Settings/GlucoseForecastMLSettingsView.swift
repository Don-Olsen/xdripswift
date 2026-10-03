//
//  GlucoseForecastMLSettingsView.swift
//  xdrip
//
//  Local-only model status and explicit retraining. No model import or upload.
//

import Combine
import SwiftUI

struct GlucoseForecastMLSettingsView: View {
    let coreDataManager: CoreDataManager

    @State private var status = GlucoseForecastMLManager.shared.statusSummary
    @State private var metadata = GlucoseForecastMLManager.shared.activeModelMetadata
    @State private var preparationStatus = GlucoseForecastMLTrainingCoordinator.shared.statusText
    @State private var currentContext: GlucoseForecastMLContext?

    private func t(_ key: String, _ fallback: String) -> String {
        GlucoseForecastTexts.text(key, fallback: fallback)
    }

    var body: some View {
        Form {
            Section {
                if let metadata {
                    if currentContext.map({ metadata.context == $0 }) == true,
                       metadata.featureNames == GlucoseForecastMLFeatures.featureNames {
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
                if status.isTraining {
                    HStack {
                        ProgressView()
                        Text(t("forecast.mlTraining", "Training locally on this iPhone…"))
                    }
                }
                if !preparationStatus.isEmpty {
                    Text(preparationStatus).foregroundStyle(.secondary)
                }
                if let outcome = status.lastOutcome, !outcome.isEmpty {
                    Text(outcome).foregroundStyle(.secondary)
                }
                Button(t("forecast.mlTrainNow", "Træn nu")) {
                    GlucoseForecastMLTrainingCoordinator.shared.trainNow(coreDataManager: coreDataManager)
                    refresh()
                }
                .disabled(status.isTraining)
            } header: {
                Text(t("forecast.personalML", "Personal forecast model"))
            } footer: {
                Text(t("forecast.mlOnDevice", "Training and models stay on this iPhone. The existing forecast engine remains the fallback. Training never changes measured glucose or alarms."))
            }

            if let selfCheck = status.lastSelfCheck ?? metadata?.selfCheck {
                Section(t("forecast.mlSelfCheck", "Last historical self-check")) {
                    ForEach([30, 60, 120], id: \.self) { horizon in
                        if let metric = selfCheck.horizons[horizon] {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("+\(horizon) min · \(metric.count) \(t("forecast.mlPairs", "pairs"))")
                                    .fontWeight(.semibold)
                                Text("\(t("forecast.mlMAE", "MAE")): \(format(metric.candidateMAE)) / \(format(metric.engineMAE)) mg/dL (ML / \(t("forecast.engineEstimate", "engine")))")
                                Text("\(t("forecast.mlCoverage", "Observed band coverage")): \(format(metric.candidateCoverage * 100)) %")
                            }
                            .font(.footnote)
                        }
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
        preparationStatus = GlucoseForecastMLTrainingCoordinator.shared.statusText
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
        value.isFinite ? String(format: "%.2f", value) : "–"
    }
}
