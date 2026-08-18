//
//  DirectSensorTestView.swift
//  xDrip Watch App
//

import SwiftUI

struct DirectSensorTestView: View {
    @StateObject private var scanner = LibreWatchPassiveScanner()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Direct Sensor Test")
                    .font(.headline)

                Text("Diagnostic only — no glucose data")
                    .font(.caption)
                    .foregroundStyle(.orange)

                diagnosticRow(label: "Bluetooth", value: scanner.bluetoothState.displayText)
                diagnosticRow(label: "Status", value: scanner.diagnostic.scanStatusText)
                diagnosticRow(label: "Elapsed", value: scanner.diagnostic.elapsedText)
                    .monospacedDigit()
                diagnosticRow(label: "Observations", value: String(scanner.diagnostic.observationCount))
                diagnosticRow(label: "Last RSSI", value: lastRSSIText)
                diagnosticRow(label: "Last seen", value: lastSeenText)
                diagnosticRow(label: "Candidate ID", value: scanner.diagnostic.redactedCandidateIdentifier ?? "—")

                Text(scanner.diagnostic.resultText)
                    .font(.caption)
                    .foregroundColor(scanner.diagnostic.observationCount > 0 ? .green : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Start scanning") {
                    scanner.startScanning()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!scanner.canStartScanning)

                Button("Stop scanning") {
                    scanner.stopScanning()
                }
                .tint(.red)
                .disabled(!scanner.diagnostic.isScanning)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .onAppear {
            scanner.prepare()
        }
        .onDisappear {
            scanner.viewDidDisappear()
        }
    }

    private var lastRSSIText: String {
        guard let lastRSSI = scanner.diagnostic.lastRSSI else { return "—" }
        return "\(lastRSSI) dBm"
    }

    private var lastSeenText: String {
        guard let lastSeen = scanner.diagnostic.lastSeen else { return "—" }
        return lastSeen.formatted(date: .omitted, time: .standard)
    }

    @ViewBuilder
    private func diagnosticRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
    }
}

#Preview {
    DirectSensorTestView()
}
