import Combine
import SwiftUI

struct LibreDirectView: View {
    @EnvironmentObject private var watchState: WatchStateModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var collector: LibreWatchDirectCollector
    @State private var displayDate = Date()

    private let displayTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: watchState.libreWatchOwnership == .watch ? "applewatch.radiowaves.left.and.right" : "iphone")
                    .font(.title2)
                    .foregroundStyle(statusColor)

                Text(Texts_WatchApp.directConnectionTitle(presentation))
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(statusColor)

                if watchState.libreWatchOwnership == .watch,
                   watchState.isShowingDirectLibreReading || collector.state.directReading != nil {
                    let isCurrent = watchState.directLibreReadingIsCurrent(at: displayDate)
                    let isRecovering = collector.state.connectionRecoveryIsInProgress
                    let hasFinalReading = watchState.isShowingDirectLibreReading
                    let showsLiveReading = hasFinalReading && isCurrent && !isRecovering && collector.state.stage == .receiving
                    if !hasFinalReading {
                        Text("WAITING FOR MATCHING CALIBRATION")
                            .font(.caption.bold())
                            .foregroundStyle(Color.orange)
                    }

                    if hasFinalReading {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(watchState.bgValueStringInUserChosenUnit())
                                .font(.system(size: 38, weight: .bold, design: .rounded))
                                .minimumScaleFactor(0.7)
                            if isCurrent {
                                Text(watchState.trendArrow())
                                    .font(.title2.bold())
                            }
                        }
                        .foregroundStyle(showsLiveReading ? Color.primary : Color.orange)
                        Text(watchState.bgUnitString())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if collector.state.directReading != nil {
                        Text("Native sensor: \(collector.nativeGlucoseText(isMgDl: watchState.isMgDl)) \(watchState.bgUnitString())")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if hasFinalReading {
                        Text(Texts_WatchApp.directReadingAge(presentation))
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

                if let storageIssue = watchState.libreWatchStorageIssue {
                    Text(storageIssue)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.orange)
                }

                Text(watchState.localAlarmStatus)
                    .font(.caption2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Tillad Watch-notifikationer") {
                    watchState.requestLocalAlarmPermission()
                }
                .font(.caption2)

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
        .onAppear { displayDate = Date() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { displayDate = Date() }
        }
        .onReceive(displayTimer) { date in
            displayDate = date
            watchState.refreshDirectLibreReadingFreshness(at: date)
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
            Button("Retry confirmation") {
                collector.returnLibreToPhone()
            }
            .disabled(!watchState.phoneIsReachable)

        case .recovery:
            Button("Return to iPhone") {
                collector.returnLibreToPhone()
            }
            .tint(.red)
        }
    }

    private var statusColor: Color {
        presentation.statusColor
    }

    private var presentation: LibreWatchConnectionPresentation {
        watchState.directLibrePresentation(stage: collector.state.stage, at: displayDate)
    }
}

extension LibreWatchConnectionPresentation {
    var statusColor: Color {
        switch emphasis {
        case .neutral: return .primary
        case .healthy: return .green
        case .attention: return .orange
        case .failure: return .red
        }
    }
}

#Preview {
    LibreDirectView(collector: LibreWatchDirectCollector())
        .environmentObject(WatchStateModel())
}
