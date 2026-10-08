//
//  BigNumberView.swift
//  xDrip Watch App
//
//  Created by Paul Plant on 21/7/24.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//

import SwiftUI

#if canImport(WatchKit)
import WatchKit
#elseif canImport(UIKit)
import UIKit
#endif

struct BigNumberView: View {
    @EnvironmentObject var watchState: WatchStateModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var libreDirectCollector: LibreWatchDirectCollector
    @State private var displayDate = Date()

    private let displayTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    
    let isSmallScreen = {
        #if canImport(WatchKit)
        return WKInterfaceDevice.current().screenBounds.size.width < ConstantsAppleWatch.pixelWidthLimitForSmallScreen
        #elseif canImport(UIKit)
        return UIScreen.main.bounds.size.width < ConstantsAppleWatch.pixelWidthLimitForSmallScreen
        #else
        return false
        #endif
    }()
    
    let originalGaugeOpacityValue = 0.8
    let animatedGaugeOpacityValue = 1.0
    @State private var gaugeOpacityValue = 0.8
    
    private var directPresentation: LibreWatchConnectionPresentation {
        watchState.directLibrePresentation(stage: libreDirectCollector.state.stage, at: displayDate)
    }
    
    var body: some View {
        let showsDirectReading = watchState.libreWatchOwnership == .watch
        let directReadingIsStale = showsDirectReading && directPresentation.reading == .stale
        let awaitsFirstDirectReading = showsDirectReading && directPresentation.reading == .waiting

        VStack(alignment: .center ,spacing: 0) {
            if directReadingIsStale {
                Label("Ikke aktuel", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: isSmallScreen ? 12 : 14, weight: .bold))
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }

            Text(awaitsFirstDirectReading ? (watchState.isMgDl ? "---" : "-.-") : watchState.bgValueStringInUserChosenUnit())
                .font(.system(size: directReadingIsStale ? (isSmallScreen ? 72 : 84) : (isSmallScreen ? 100 : 120)))
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(directReadingIsStale ? Color.secondary : watchState.bgTextColor())
                .padding(.top, directReadingIsStale ? 0 : (isSmallScreen ? -15 : -20))
                .padding(.trailing, 10)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .onTapGesture(count: 2) {
                    watchState.updateBigNumberViewDate = Date()
                    watchState.requestWatchStateUpdate()
                }

            if directReadingIsStale {
                Text("\(Texts_WatchApp.directReadingAge(directPresentation)) · \(watchState.bgUnitString())")
                    .font(.system(size: isSmallScreen ? 13 : 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.top, 2)
            }
            
            if !showsDirectReading || directPresentation.reading == .current {
                HStack(alignment: .center, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(watchState.deltaChangeStringInUserChosenUnit())
                            .font(.system(size: isSmallScreen ? 20 : 22, weight: .medium))
                            .monospacedDigit()
                            .lineLimit(1)

                        Text(watchState.bgUnitString())
                            .font(.system(size: isSmallScreen ? 13 : 15))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Text("\(watchState.trendArrow())")
                        .font(.system(size: isSmallScreen ? 34 : 38)).fontWeight(.semibold)
                        .foregroundStyle(.colorPrimary)
                        .minimumScaleFactor(0.5)
                }
                .padding(.top, -20)
                .padding(.bottom, 10)
            }
            
            if !directReadingIsStale && !awaitsFirstDirectReading {
                VStack(alignment: .center, spacing: 1) {
                    Gauge(value: watchState.bgValueInMgDl() ?? watchState.gaugeModel().nilValue, in: watchState.gaugeModel().minValue...watchState.gaugeModel().maxValue) {
                        // empty. No need for any labels or descriptions
                    }
                    .tint(watchState.gaugeModel().gaugeGradient)
                    .gaugeStyle(.accessoryLinear)
                    .opacity(gaugeOpacityValue)
                    .scaleEffect(0.8)
                    .animation(.easeOut(duration: 0.3), value: gaugeOpacityValue)
                    .onChange(of: watchState.bgValueStringInUserChosenUnit()) { oldState, newState in
                        animateGaugeOpacityValue()
                    }
                    .onChange(of: watchState.updateBigNumberViewDate) { oldState, newState in
                        animateGaugeOpacityValue()
                    }
                }
            }
            
            if showsDirectReading {
                VStack(spacing: 2) {
                    if !directReadingIsStale {
                        Text(Texts_WatchApp.directReadingAge(directPresentation))
                            .font(.system(size: isSmallScreen ? 13 : 15))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(Texts_WatchApp.directConnectionTitle(directPresentation))
                        .font(.system(size: isSmallScreen ? 12 : 14, weight: .semibold))
                        .foregroundStyle(directPresentation.statusColor)
                        .lineLimit(2)
                }
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .padding(.top, directReadingIsStale ? 4 : 8)
                .accessibilityElement(children: .contain)
            } else {
                HStack(alignment: .center, spacing: 3) {
                    Image(systemName: ConstantsAppleWatch.requestingDataIconSFSymbolName)
                        .font(.system(size: ConstantsAppleWatch.requestingDataIconFontSize, weight: .heavy))
                        .foregroundStyle(watchState.requestingDataIconColor)
                        .padding(.top, 4)
                        .padding(.trailing, 2)

                    Text(watchState.lastUpdatedMinsAgoString(at: displayDate))
                        .font(.system(size: isSmallScreen ? 16 : 18))
                        .monospacedDigit()
                        .foregroundStyle(watchState.lastUpdatedTimeColor())
                }
                .padding(.top, 15)
                .padding(.bottom, -20)
            }
        }
        .safeAreaInset(edge: .top, spacing: 2) {
            if watchState.libreWatchOwnership == .watch,
               let warning = watchState.localAlarmReadinessWarning {
                Text(warning)
                    .font(.system(size: isSmallScreen ? 11 : 12, weight: .semibold))
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .accessibilityLabel("Alarmadvarsel: \(warning)")
            }
        }
        .onAppear {
            displayDate = Date()
            watchState.refreshDirectLibreReadingFreshness(at: displayDate)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                displayDate = Date()
                watchState.refreshDirectLibreReadingFreshness(at: displayDate)
            }
        }
        .onReceive(displayTimer) {
            displayDate = $0
            watchState.refreshDirectLibreReadingFreshness(at: $0)
        }
    }
    
    func animateGaugeOpacityValue(){
        gaugeOpacityValue = animatedGaugeOpacityValue
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.3){
            gaugeOpacityValue = originalGaugeOpacityValue
        }
    }
}

struct BigNumberView_Previews: PreviewProvider {
    static func bgDateArray() -> [Date] {
        let endDate = Date()
        let startDate = endDate.addingTimeInterval(-3600 * 12)
        var currentDate = startDate
        
        var dateArray: [Date] = []
        
        while currentDate < endDate {
            dateArray.append(currentDate)
            currentDate = currentDate.addingTimeInterval(60 * 5)
        }
        
        return dateArray
    }
    
    static func bgValueArray() -> [Double] {
        var bgValueArray:[Double] = Array(repeating: 0, count: 144)
        var currentValue: Double = 120
        var increaseValues: Bool = true
        
        for index in bgValueArray.indices {
            let randomValue = Double(Int.random(in: -10..<30))
            
            if currentValue < 70 {
                increaseValues = true
                bgValueArray[index] = currentValue + abs(randomValue)
            } else if currentValue > 180 {
                increaseValues = false
                bgValueArray[index] = currentValue - abs(randomValue)
            } else {
                bgValueArray[index] = currentValue + (increaseValues ? randomValue : -randomValue)
            }
            currentValue = bgValueArray[index]
        }
        return bgValueArray
    }
    
    static var previews: some View {
        let watchState = WatchStateModel()
        
        watchState.bgReadingValues = bgValueArray()
        watchState.bgReadingDates = bgDateArray()
        watchState.isMgDl = true
        watchState.slopeOrdinal = 5
        watchState.deltaValueInUserUnit = -2
        watchState.urgentLowLimitInMgDl = 60
        watchState.lowLimitInMgDl = 80
        watchState.highLimitInMgDl = 180
        watchState.urgentHighLimitInMgDl = 240
        watchState.updatedDate = Date().addingTimeInterval(-120)
        watchState.activeSensorDescription = "Data Source"
        watchState.sensorAgeInMinutes = Double(Int.random(in: 1..<14400))
        watchState.sensorMaxAgeInMinutes = 14400
        
        return Group {
            BigNumberView(libreDirectCollector: LibreWatchDirectCollector())
        }.environmentObject(watchState)
    }
}
