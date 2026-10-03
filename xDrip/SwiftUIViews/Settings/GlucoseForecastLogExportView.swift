import SwiftUI
import UIKit

/// Explicit, local CSV export. Creating the copy is serialized with logging off the main thread.
struct GlucoseForecastLogExportView: View {
    @State private var exportURL: URL?
    @State private var shareItem: ForecastCSVShareItem?
    @State private var failed = false

    var body: some View {
        List {
            if let exportURL {
                Button(GlucoseForecastTexts.text("forecast.shareCSV", fallback: "Share CSV")) {
                    shareItem = ForecastCSVShareItem(url: exportURL)
                }
            } else if failed {
                Text(GlucoseForecastTexts.text("forecast.exportFailed", fallback: "The forecast log could not be exported. The original log is unchanged."))
            } else {
                ProgressView(GlucoseForecastTexts.text("forecast.exportPreparing", fallback: "Preparing CSV…"))
            }
            Text(GlucoseForecastTexts.text("forecast.exportPrivacy", fallback: "This file contains health data and stays on this iPhone until you choose where to share it. Forecasts are logged when Home calculates them, not continuously throughout the day."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(GlucoseForecastTexts.text("forecast.exportLog", fallback: "Export forecast log"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard exportURL == nil, !failed else { return }
            let result: Result<URL, Error> = await withCheckedContinuation { continuation in
                GlucoseForecastLog.shared.exportCSV { continuation.resume(returning: $0) }
            }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let url):
                exportURL = url
                shareItem = ForecastCSVShareItem(url: url)
            case .failure:
                failed = true
            }
        }
        .sheet(item: $shareItem) { item in
            ForecastCSVShareSheet(url: item.url)
        }
    }
}

private struct ForecastCSVShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ForecastCSVShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
