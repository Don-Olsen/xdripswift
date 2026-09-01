import SwiftUI

struct LibreDirectView: View {
    @EnvironmentObject private var watchState: WatchStateModel
    @ObservedObject var collector: LibreWatchDirectCollector

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: watchState.libreWatchOwnership == .watch ? "applewatch.radiowaves.left.and.right" : "iphone")
                    .font(.title2)
                    .foregroundStyle(statusColor)

                Text(collector.state.stage.displayText)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(statusColor)

                if let reading = collector.state.directReading,
                   watchState.libreWatchOwnership == .watch {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(collector.directGlucoseText(isMgDl: watchState.isMgDl))
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.7)
                        Text(reading.trendSymbol)
                            .font(.title2.bold())
                    }
                    Text(watchState.isMgDl ? "mg/dL" : "mmol/L")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(collector.state.detailText)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                if let error = collector.state.lastBluetoothError {
                    Text(error)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.red)
                }

                controls

                if let identity = collector.state.redactedSensorIdentity {
                    Text(identity)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 5)
        }
        .navigationTitle("Libre")
        .onAppear {
            collector.prepare(with: watchState)
        }
        .onChange(of: watchState.libreWatchDirectSession) { session in
            collector.updateSession(session)
        }
        .onChange(of: watchState.libreWatchOwnership) { ownership in
            collector.ownershipDidChange(ownership)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch watchState.libreWatchOwnership {
        case .iphone:
            Button("Watch takes Libre") {
                collector.takeOverLibre()
            }
            .buttonStyle(.borderedProminent)
            .disabled(watchState.libreWatchDirectSession?.isValid != true)

        case .watch:
            if collector.state.stage == .failed {
                Button("Reconnect") {
                    collector.resumeDirectReceptionIfOwned()
                }
                .buttonStyle(.borderedProminent)
            }

            Button("Return to iPhone") {
                collector.returnLibreToPhone()
            }
            .tint(.red)

        case .releasingToWatch:
            ProgressView("Releasing iPhone")

        case .releasingToPhone:
            ProgressView("Restoring iPhone")

        case .recovery:
            Button("Return to iPhone") {
                collector.returnLibreToPhone()
            }
            .tint(.red)
        }
    }

    private var statusColor: Color {
        if collector.state.failure != nil { return .red }
        if watchState.libreWatchOwnership == .watch { return .green }
        return .primary
    }
}

#Preview {
    LibreDirectView(collector: LibreWatchDirectCollector())
        .environmentObject(WatchStateModel())
}
