//
//  DirectSensorTestView.swift
//  xDrip Watch App
//

import SwiftUI

struct DirectSensorTestView: View {
    @EnvironmentObject private var watchState: WatchStateModel
    @StateObject private var collector = LibreWatchDirectCollector()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Direct Sensor Test")
                    .font(.headline)

                Text("Experimental test sensor only — do not use for treatment decisions.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                Text(collector.state.stage.displayText)
                    .font(.headline)
                    .foregroundStyle(stageColor)
                    .fixedSize(horizontal: false, vertical: true)

                if collector.state.canDisplayDirectFromSensor {
                    Text("DIRECT FROM SENSOR")
                        .font(.headline)
                        .foregroundStyle(.green)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(collector.directGlucoseText(isMgDl: watchState.isMgDl))
                            .font(.title2)
                            .bold()
                        Text(collector.state.directReading?.trendSymbol ?? "")
                            .font(.title2)
                    }
                }

                diagnosticRow(label: "Detail", value: collector.state.detailText)
                diagnosticRow(label: "Bluetooth", value: collector.bluetoothStateText)
                diagnosticRow(label: "Ownership", value: watchState.libreWatchTestOwnership.rawValue)
                diagnosticRow(label: "Elapsed", value: collector.state.elapsedText)
                diagnosticRow(label: "Test sensor", value: collector.state.redactedSensorIdentity ?? "NO TEST SESSION")
                diagnosticRow(label: "RSSI", value: rssiText)
                diagnosticRow(label: "Fragments / bytes", value: "\(collector.state.fragmentCount) / \(collector.state.assembledByteCount)")
                diagnosticRow(label: "Complete frames", value: String(collector.state.completeFrameCount))
                diagnosticRow(label: "Last packet length", value: String(collector.state.lastPacketLength))
                diagnosticRow(label: "Last direct packet", value: packetTimeText)
                diagnosticRow(label: "Unlock counter", value: collector.state.unlockCounter.map { String($0) } ?? "—")

                if let error = collector.state.lastBluetoothError {
                    diagnosticRow(label: "CoreBluetooth", value: error)
                }

                Button("Start Direct Test") {
                    collector.startDirectTest()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)

                Button("Stop Direct Test / Return Control") {
                    collector.stopDirectTest()
                }
                .tint(.red)
                .disabled(!collector.state.isRunning)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
        .onAppear {
            collector.prepare(with: watchState)
        }
        .onChange(of: watchState.libreWatchTestSession) { session in
            collector.updateSession(session)
        }
        .onDisappear {
            collector.viewDidDisappear()
        }
    }

    private var canStart: Bool {
        watchState.libreWatchTestSession?.isValid == true &&
            watchState.libreWatchTestOwnership == .iphone &&
            !collector.state.isRunning
    }

    private var stageColor: Color {
        if collector.state.canDisplayDirectFromSensor { return .green }
        if collector.state.failure != nil { return .red }
        return .primary
    }

    private var rssiText: String {
        guard let rssi = collector.state.lastRSSI else { return "—" }
        return "\(rssi) dBm"
    }

    private var packetTimeText: String {
        guard let date = collector.state.lastPacketAt else { return "—" }
        return date.formatted(date: .omitted, time: .standard)
    }

    @ViewBuilder
    private func diagnosticRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .lineLimit(3)
                .minimumScaleFactor(0.7)
        }
    }
}

#Preview {
    DirectSensorTestView()
        .environmentObject(WatchStateModel())
}
