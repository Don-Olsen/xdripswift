import SwiftUI
import UIKit

/// Explicit local evaluation export; both CSVs are prepared off the main thread.
struct GlucoseForecastLogExportView: View {
    let coreDataManager: CoreDataManager
    @State private var exported: ForecastEvaluationExport?
    @State private var shareItem: ForecastCSVShareItem?
    @State private var failed = false

    var body: some View {
        List {
            if let exported {
                Button("Del prognoser og målinger") {
                    shareItem = ForecastCSVShareItem(urls: exported.urls)
                }
                Text(exported.coverageSummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if failed {
                Text("Eksporten kunne ikke færdiggøres. Prognoselog og målinger er uændrede. Prøv igen ved at åbne siden på ny.")
            } else {
                ProgressView(GlucoseForecastTexts.text("forecast.exportPreparing", fallback: "Preparing CSV…"))
            }
            Text("Filerne indeholder helbredsdata og bliver på denne iPhone, indtil du vælger at dele dem. Prognoser gemmes, når Home beregner dem, ikke løbende hele døgnet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(GlucoseForecastTexts.text("forecast.exportLog", fallback: "Export forecast log"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard exported == nil, !failed else { return }
            let result: Result<ForecastEvaluationExport, Error> = await withCheckedContinuation { continuation in
                GlucoseForecastLog.shared.exportEvaluation(coreDataManager: coreDataManager) {
                    continuation.resume(returning: $0)
                }
            }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let result):
                exported = result
                shareItem = ForecastCSVShareItem(urls: result.urls)
            case .failure:
                failed = true
            }
        }
        .sheet(item: $shareItem) { item in
            ForecastCSVShareSheet(urls: item.urls)
        }
    }
}

private struct ForecastCSVShareItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct ForecastCSVShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
