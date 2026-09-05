//
//  ComplicationSharedUserDefaultsModel.swift
//  xdrip
//
//  Created by Paul Plant on 4/3/24.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//

import Foundation

/// model of the data we'll store in the shared app group to pass from the watch app to the widgets
struct ComplicationSharedUserDefaultsModel: Codable {
    var bgReadingValues: [Double]
    var bgReadingDatesAsDouble: [Double]
    var isMgDl: Bool
    var slopeOrdinal: Int
    var deltaValueInUserUnit: Double?
    var urgentLowLimitInMgDl: Double
    var lowLimitInMgDl: Double
    var highLimitInMgDl: Double
    var urgentHighLimitInMgDl: Double
    var keepAliveIsDisabled: Bool
    /// Absent in older installations. Keep their established phone freshness window.
    var readingSource: ComplicationReadingSource? = nil

    static func decodeStoredData(_ data: Data?) -> Self? {
        guard let data,
              let model = try? JSONDecoder().decode(Self.self, from: data),
              model.bgReadingValues.count == model.bgReadingDatesAsDouble.count,
              model.bgReadingValues.allSatisfy({ $0.isFinite && $0 > 0 }),
              model.bgReadingDatesAsDouble.allSatisfy(\.isFinite)
        else { return nil }
        return model
    }

    var latestReadingDate: Date? {
        bgReadingDatesAsDouble.first.map(Date.init(timeIntervalSince1970:))
    }

    var readingExpiresAt: Date? {
        latestReadingDate?.addingTimeInterval(readingSource == .directLibre ? 3 * 60 : 20 * 60)
    }

    func readingIsCurrent(at date: Date) -> Bool {
        guard !keepAliveIsDisabled, !bgReadingValues.isEmpty,
              let expiresAt = readingExpiresAt
        else { return false }
        return date <= expiresAt
    }

    /// WidgetKit can show the expiry entry even if the Watch app never runs again.
    func timelineDates(startingAt date: Date) -> [Date] {
        guard readingIsCurrent(at: date), let expiresAt = readingExpiresAt else { return [date] }
        return [date, expiresAt.addingTimeInterval(0.001)]
    }
}

enum ComplicationReadingSource: String, Codable {
    case directLibre
    case phone
}
