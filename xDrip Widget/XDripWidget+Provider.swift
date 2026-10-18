//
//  XDripWidget+Provider.swift
//  xDrip Widget Extension
//
//  Created by Paul Plant on 4/3/24.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//

import SwiftUI
import WidgetKit
import Foundation

#if XDRIP_WIDGET_TESTS
@testable import xdrip
#endif

extension XDripWidget {
    struct Provider: TimelineProvider {
        var sharedUserDefaults: UserDefaults? = UserDefaults(suiteName: Bundle.main.appGroupSuiteName)
        var mainAppBundleIdentifier: String = Bundle.main.mainAppBundleIdentifier
        var currentDate: () -> Date = { .now }

        func placeholder(in context: Context) -> Entry {
            .placeholder
        }

        func getSnapshot(in context: Context, completion: @escaping (Entry) -> ()) {
            completion(snapshot(isPreview: context.isPreview))
        }

        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
            completion(timeline(isPreview: context.isPreview))
        }

        func snapshot(isPreview: Bool) -> Entry {
            let date = currentDate()
            return isPreview ? .placeholder(at: date) : Entry(date: date, widgetState: getWidgetStateFromSharedUserDefaults())
        }

        func timeline(isPreview: Bool = false) -> Timeline<Entry> {
            let entry = snapshot(isPreview: isPreview)
            var deadlines: [Date] = []
            if let readingDate = entry.widgetState.bgReadingDate {
                deadlines += [
                    readingDate.addingTimeInterval(ConstantsWidgetExtension.bgReadingDateStaleInMinutes),
                    readingDate.addingTimeInterval(ConstantsWidgetExtension.bgReadingDateVeryStaleInMinutes)
                ]
            }
            if let metrics = entry.widgetState.therapyMetrics {
                deadlines += [metrics.iob.expiresAt, metrics.cob.expiresAt,
                              metrics.iob.visibilityDeadline, metrics.cob.visibilityDeadline].compactMap { $0 }
            }
            // WidgetKit can render these entries ahead of time. Glucose presentation uses
            // its entry date so a quiet sensor still becomes stale and then expires.
            let entries = [entry] + Set(deadlines).sorted().filter { $0 > entry.date }.map {
                Entry(date: $0, widgetState: entry.widgetState)
            }
            return Timeline(entries: entries, policy: .atEnd)
        }
    }
}

// MARK: - Shared storage

extension XDripWidget.Provider {
    func getWidgetStateFromSharedUserDefaults() -> XDripWidget.Entry.WidgetState {
        let keepAliveDisabledMessage = sharedUserDefaults?.string(
            forKey: WidgetSharedUserDefaultsModel.keepAliveDisabledMessageKey(for: mainAppBundleIdentifier)
        ).flatMap { $0.isEmpty ? nil : $0 }
        let emptyState = Entry.WidgetState(followerPatientName: nil,
                                          keepAliveDisabledMessage: keepAliveDisabledMessage)

        guard let encodedLatestReadings = sharedUserDefaults?.data(
            forKey: WidgetSharedUserDefaultsModel.widgetDataKey(for: mainAppBundleIdentifier)
        ), let data = try? JSONDecoder().decode(WidgetSharedUserDefaultsModel.self, from: encodedLatestReadings) else {
            return emptyState
        }

        // An incomplete pair of arrays cannot describe a real chart or current reading.
        guard data.bgReadingValues.count == data.bgReadingDatesAsDouble.count else { return emptyState }
        let bgReadingDates = data.bgReadingDatesAsDouble.map { Date(timeIntervalSince1970: $0) }
        return Entry.WidgetState(bgReadingValues: data.bgReadingValues, bgReadingDates: bgReadingDates,
            isMgDl: data.isMgDl, slopeOrdinal: data.slopeOrdinal, deltaValueInUserUnit: data.deltaValueInUserUnit,
            urgentLowLimitInMgDl: data.urgentLowLimitInMgDl, lowLimitInMgDl: data.lowLimitInMgDl,
            highLimitInMgDl: data.highLimitInMgDl, urgentHighLimitInMgDl: data.urgentHighLimitInMgDl,
            dataSourceDescription: data.dataSourceDescription, followerPatientName: data.followerPatientName,
            keepAliveDisabledMessage: keepAliveDisabledMessage, aidStatus: data.aidStatus,
            therapyMetrics: data.therapyMetrics, allowStandByHighContrast: data.allowStandByHighContrast,
            forceStandByBigNumbers: data.forceStandByBigNumbers)
    }
}
