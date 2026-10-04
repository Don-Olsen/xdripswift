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
    /// In a falling low or during an active warning, the displayed ML centre never
    /// exceeds the unchanged engine at any point. Translate the interval with the
    /// centre so its original uncertainty width is retained.
    static func cappedBelowEngine(_ ml: GlucoseForecastMLForecast,
                                  engine: GlucoseForecastResult,
                                  currentGlucoseMgdl: Double?, slope15MgdlPerMinute: Double?,
                                  lowSoonActive: Bool) -> GlucoseForecastMLForecast? {
        guard engine.reason == nil, ml.points.count == engine.points.count,
              ml.band.count == ml.points.count,
              zip(ml.points, engine.points).allSatisfy({ $0.0.date == $0.1.date }),
              zip(ml.band, ml.points).allSatisfy({ $0.0.date == $0.1.date }) else { return nil }
        let lowAndFalling = (currentGlucoseMgdl ?? .infinity) < 5 * PenBolusCalculator.mgdlPerMmol &&
            (slope15MgdlPerMinute ?? 0) < 0
        guard lowSoonActive || lowAndFalling else { return ml }
        var points = [GlucoseForecastPoint]()
        var band = [GlucoseForecastMLBandPoint]()
        for index in ml.points.indices {
            let original = ml.points[index]
            let lowered = min(original.glucoseMgdl, engine.points[index].glucoseMgdl)
            let shift = lowered - original.glucoseMgdl
            guard lowered.isFinite, shift.isFinite,
                  ml.band[index].lowerMgdl.isFinite,
                  ml.band[index].upperMgdl.isFinite else { return nil }
            points.append(.init(date: original.date, glucoseMgdl: lowered))
            band.append(.init(date: original.date,
                lowerMgdl: ml.band[index].lowerMgdl + shift,
                upperMgdl: ml.band[index].upperMgdl + shift))
        }
        return GlucoseForecastMLForecast(points: points, band: band, modelID: ml.modelID)
    }

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
