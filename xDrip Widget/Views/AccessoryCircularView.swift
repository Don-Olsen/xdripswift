//
//  AccessoryCircularView.swift
//  xDrip Widget Extension
//
//  Created by Paul Plant on 4/3/24.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//

import Foundation
import SwiftUI
import WidgetKit

extension XDripWidget.EntryView {
    var accessoryCircularView: some View {
        ZStack {
            AccessoryWidgetBackground()
                .cornerRadius(8)
            
            let gauge = entry.widgetState.gaugeModel(at: entry.date)
            if let value = gauge.value {
                Gauge(value: value, in: gauge.minValue...gauge.maxValue) {
                    Text("Not shown")
                } currentValueLabel: {
                    Text(entry.widgetState.bgValueStringInUserChosenUnit(at: entry.date))
                        .font(.system(size: 20)).bold()
                        .minimumScaleFactor(0.2)
                        .lineLimit(1)
                } minimumValueLabel: {
                    Text(gauge.minValue.mgDlToMmolAndToString(mgDl: entry.widgetState.isMgDl))
                        .font(.system(size: 8))
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.2)
                } maximumValueLabel: {
                    Text(gauge.maxValue.mgDlToMmolAndToString(mgDl: entry.widgetState.isMgDl))
                        .font(.system(size: 8))
                        .foregroundStyle(.primary)
                        .minimumScaleFactor(0.2)
                }
                .gaugeStyle(.accessoryCircular)
                .tint(gauge.gaugeGradient)
            } else {
                Text(entry.widgetState.bgValueStringInUserChosenUnit(at: entry.date))
                    .font(.system(size: 20)).bold()
                    .foregroundStyle(.tertiary)
            }
        }
        .widgetBackground(backgroundView: Color.black)
    }
}
