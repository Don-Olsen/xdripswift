// Shared glucose selection for the live forecast and historical replay.
import Foundation

struct GlucoseForecastGlucoseObservation: Sendable {
    let date: Date
    let glucoseMgdl: Double
    let sensorID: String?
    let isValidForDownstream: Bool
    let isSuppressedByFiveMinuteCadence: Bool
}

enum GlucoseForecastGlucoseSelection {
    static let fetchWindow: TimeInterval = 45 * 60

    /// Mirrors Home's newest visible reading, same-sensor history and duplicate policy.
    /// The caller retains invalid and suppressed rows: a newer sensor must still block
    /// an older one even if its latest reading is not yet usable.
    static func select(_ observations: [GlucoseForecastGlucoseObservation], at now: Date)
        -> [GlucoseForecastSample] {
        let fetched = observations.filter {
            $0.date >= now.addingTimeInterval(-fetchWindow) && $0.date <= now
        }.sorted { $0.date > $1.date }
        guard let latest = fetched.first(where: {
            !$0.isSuppressedByFiveMinuteCadence && $0.isValidForDownstream &&
                $0.glucoseMgdl.isFinite && $0.glucoseMgdl > 0
        }) else { return [] }
        let latestSensorID = latest.sensorID
        let newerRows = fetched.prefix(while: { $0.date > latest.date })
        guard newerRows.allSatisfy({ reading in
            guard let sensorID = latestSensorID, !sensorID.isEmpty else { return false }
            return reading.sensorID == sensorID
        }) else { return [] }
        guard let sensorID = latestSensorID, !sensorID.isEmpty else {
            return [GlucoseForecastSample(date: latest.date, glucoseMgdl: latest.glucoseMgdl)]
        }
        let latestCandidates = fetched.drop(while: { $0.date > latest.date })
            .prefix(while: { $0.date == latest.date })
        guard latestCandidates.allSatisfy({ reading in
            reading.sensorID == sensorID && !reading.isSuppressedByFiveMinuteCadence &&
                reading.isValidForDownstream && reading.glucoseMgdl == latest.glucoseMgdl
        }) else { return [] }
        var byDate = [Date: Double]()
        for reading in fetched where reading.sensorID == sensorID &&
            !reading.isSuppressedByFiveMinuteCadence && reading.isValidForDownstream &&
            reading.glucoseMgdl.isFinite && reading.glucoseMgdl > 0 {
            if let existing = byDate[reading.date], existing != reading.glucoseMgdl { return [] }
            byDate[reading.date] = reading.glucoseMgdl
        }
        return byDate.map { GlucoseForecastSample(date: $0.key, glucoseMgdl: $0.value,
                                                   sensorID: sensorID) }
            .sorted { $0.date < $1.date }
    }
}
