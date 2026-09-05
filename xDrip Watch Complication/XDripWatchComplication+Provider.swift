//
//  XDripWatchComplication+Provider.swift
//  xDrip Watch Complication Extension
//
//  Created by Paul Plant on 28/2/24.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//

import SwiftUI
import WidgetKit
import Foundation

extension XDripWatchComplication {
    struct Provider: TimelineProvider {        
        
        func placeholder(in context: Context) -> Entry {
            .placeholder
        }
        
        func getSnapshot(in context: Context, completion: @escaping (Entry) -> ()) {
            completion(context.isPreview ? .placeholder : makeEntries(at: .now)[0])
        }
        
        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> ()) {
            completion(.init(entries: makeEntries(at: .now), policy: .never))
        }
    }
}


// MARK: - Helpers

extension XDripWatchComplication.Provider {
    func makeEntries(at date: Date) -> [XDripWatchComplication.Entry] {
        let sharedUserDefaults = UserDefaults(suiteName: Bundle.main.appGroupSuiteName)
        let encoded = sharedUserDefaults?.data(forKey: "complicationSharedUserDefaults.\(Bundle.main.mainAppBundleIdentifier)")
        guard let data = ComplicationSharedUserDefaultsModel.decodeStoredData(encoded) else {
            return [Entry(date: date, widgetState: Entry.WidgetState())]
        }

        let bgReadingDates = data.bgReadingDatesAsDouble.map { Date(timeIntervalSince1970: $0) }
        let widgetState = Entry.WidgetState(bgReadingValues: data.bgReadingValues, bgReadingDates: bgReadingDates, isMgDl: data.isMgDl, slopeOrdinal: data.slopeOrdinal, deltaValueInUserUnit: data.deltaValueInUserUnit, urgentLowLimitInMgDl: data.urgentLowLimitInMgDl, lowLimitInMgDl: data.lowLimitInMgDl, highLimitInMgDl: data.highLimitInMgDl, urgentHighLimitInMgDl: data.urgentHighLimitInMgDl, keepAliveIsDisabled: data.keepAliveIsDisabled, readingSource: data.readingSource, readingExpiresAt: data.readingExpiresAt)
        return data.timelineDates(startingAt: date).map { Entry(date: $0, widgetState: widgetState) }
    }
}
