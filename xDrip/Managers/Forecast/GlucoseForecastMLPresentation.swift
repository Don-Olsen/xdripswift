//
//  GlucoseForecastMLPresentation.swift
//  xdrip
//
//  Display-only ML forecast output. These values never become measured glucose.
//

import Foundation

/// The raw pointwise interval is retained so chart clipping cannot change forecast data.
struct GlucoseForecastMLBandPoint: Sendable, Equatable {
    let date: Date
    let lowerMgdl: Double
    let upperMgdl: Double
}

struct GlucoseForecastMLForecast: Sendable {
    let points: [GlucoseForecastPoint]
    let band: [GlucoseForecastMLBandPoint]
    let modelID: String
}

/// Selects one display source while preserving the engine points in the result.
enum GlucoseForecastMLPresentation {
    static func isML(_ result: GlucoseForecastResult) -> Bool {
        result.reason == nil && result.mlForecast != nil
    }

    static func points(in result: GlucoseForecastResult) -> [GlucoseForecastPoint] {
        guard result.reason == nil else { return [] }
        return result.mlForecast?.points ?? result.points
    }

    static func band(in result: GlucoseForecastResult) -> [GlucoseForecastMLBandPoint] {
        guard isML(result) else { return [] }
        return result.mlForecast?.band ?? []
    }

    static func value(atMinutes minutes: Int, in result: GlucoseForecastResult) -> Double? {
        guard let referenceDate = result.referenceDate else { return nil }
        let date = referenceDate.addingTimeInterval(TimeInterval(minutes * 60))
        return points(in: result).first { abs($0.date.timeIntervalSince(date)) < 0.5 }?.glucoseMgdl
    }
}
