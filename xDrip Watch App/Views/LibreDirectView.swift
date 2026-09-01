import Combine
import SwiftUI

struct LibreDirectView: View {
    @EnvironmentObject private var watchState: WatchStateModel
    @ObservedObject var collector: LibreWatchDirectCollector
    @State private var displayDate = Date()

    private let displayTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

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
                    let isCurrent = collector.state.directReadingIsCurrent(at: displayDate)
                    let isRecovering = collector.state.connectionRecoveryIsInProgress
                    let showsLiveReading = isCurrent && !isRecovering && collector.state.stage == .receiving
                    let readingStatus: String = {
                        if !isCurrent { return "STALE LAST DIRECT READING" }
                        if isRecovering { return "RECONNECTING — LAST DIRECT READING" }
                        if collector.state.stage != .receiving { return "LAST DIRECT READING" }
                        return "DIRECT FROM SENSOR"
                    }()

                    Text(readingStatus)
                        .font(.caption.bold())
                        .foregroundStyle(showsLiveReading ? Color.green : Color.orange)

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(collector.directGlucoseText(isMgDl: watchState.isMgDl))
                            .font(.system(size: 38, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.7)
                        Text(reading.trendSymbol)
                            .font(.title2.bold())
                    }
                    .foregroundStyle(showsLiveReading ? Color.primary : Color.orange)
                    Text(watchState.isMgDl ? "mg/dL" : "mmol/L")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let ageText = collector.state.directReadingAgeText(at: displayDate) {
                        Text("Last direct reading: \(ageText)")
                            .font(.caption2)
                            .foregroundStyle(showsLiveReading ? Color.secondary : Color.orange)
                    }
                }

                Text(collector.state.detailText)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                if let error = collector.state.lastBluetoothError {
                    Text(error)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(collector.state.connectionRecoveryIsInProgress ? .orange : .red)
                }

                controls

                if let identity = collector.state.redactedSensorIdentity {
                    Text(identity)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }

                Text("Experimental — do not use for treatment decisions")
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.orange)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 5)
        }
        .navigationTitle("Libre")
        .onReceive(displayTimer) { date in
            displayDate = date
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
        if collector.state.connectionRecoveryIsInProgress { return .orange }
        if watchState.libreWatchOwnership == .watch { return .green }
        return .primary
    }
}

#Preview {
    LibreDirectView(collector: LibreWatchDirectCollector())
        .environmentObject(WatchStateModel())
}
