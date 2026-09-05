//
//  TransmitterReadSuccessManager.swift
//  xdrip
//
//  Created by Paul Plant on 23/9/25.
//  Copyright © 2025 Johan Degraeve. All rights reserved.
//

import Foundation

/// UI‑ready result payload produced by the manager
public struct TransmitterReadSuccessDisplay {
    public let nominalGapInSeconds: Int   // 60 or 300
    public let earliestTimestampInLast24h: Date?
    public let hourlyBuckets: [TransmitterReadSuccessHourlyBucket]

    public let expected24h: Int
    public let actual24h: Int
    public let success24h: Double
    public let calculationBasis: String
    public let deliveryEvidence: String
    public let timelyReceiptCount: Int
    public let delayedReceiptCount: Int
}

public struct TransmitterReadSuccessHourlyBucket: Identifiable {
    public let id: Int
    public let expected: Int
    public let actual: Int
    public let success: Double
}

final class TransmitterReadSuccessManager {

    /// BgReadingsAccessor instance
    private let bgReadingsAccessor:BgReadingsAccessor
    
    private let nowProvider: () -> Date
    private let defaults: UserDefaults
    
    // MARK: - initializer
    
    init(bgReadingsAccessor: BgReadingsAccessor, nowProvider: @escaping () -> Date = { Date() }, defaults: UserDefaults = .standard) {
        self.bgReadingsAccessor = bgReadingsAccessor
        self.nowProvider = nowProvider
        self.defaults = defaults
    }
    
    // MARK: - public functions

    /// Compute reading success for the given sensor and return 24h totals plus hourly buckets.
    /// - Parameters:
    ///   - sensor: Current sensor/session to evaluate.
    ///   - now: Optional override of current time; defaults to `nowProvider()`.
    ///   - cutoff: Optional cutoff date to clamp analysis to readings no earlier than this timestamp.
    /// - Returns: A display model with expected/actual/success for 24h and hourly bucket data.
    func getReadSuccess(forSensor sensor: Sensor, now: Date? = nil, notBefore cutoff: Date? = nil) -> TransmitterReadSuccessDisplay {
        let now = now ?? nowProvider()
        let analysisStartDate = max(cutoff ?? .distantPast, max(
            sensor.startDate,
            now.addingTimeInterval(-24 * 60 * 60)
        ))

        // Do not borrow readings from another sensor to make this session look complete.
        let rawTimestamps = bgReadingsAccessor.getReadingTimestamps(
            fromDate: analysisStartDate,
            toDate: now,
            forSensor: sensor,
            onlyValidated: true
        )
        let allTimestamps = cutoff.map { cutoff in rawTimestamps.filter { $0 >= cutoff } } ?? rawTimestamps

        let contexts = TransmitterReadSuccessEvidence.contexts(defaults: defaults)
        let nominalGapInSeconds = TransmitterReadSuccessContext.acquisitionInterval(for: defaults.cgmTransmitterType) ?? 0
        let counts = TransmitterReadSuccessPolicy.counts(timestamps: allTimestamps, start: analysisStartDate,
            end: now, contexts: contexts, fallbackInterval: nominalGapInSeconds)
        let expected24h = counts.expected
        let actual24h = counts.actual
        let missing24 = max(0, expected24h - actual24h)
        let success24h = flooredPercent(actual: actual24h, expected: expected24h, hasMisses: missing24 > 0)

        let recorded = TransmitterReadSuccessEvidence.receipts(at: now, defaults: defaults).filter {
            $0.sensorID == sensor.id && $0.measuredAt >= analysisStartDate
        }
        let watchRecords = recorded.filter(\.fromWatch)
        let timely = recorded.filter { !$0.historical && $0.storedAt.timeIntervalSince($0.measuredAt) <= 180 }.count
        let delayed = recorded.count - timely
        let evidence = recorded.isEmpty
            ? "Delivery timing unavailable for legacy history. Coverage includes backfill; it does not prove continuous BLE reception."
            : "Phone storage: \(timely) within 3 min, \(delayed) delayed/backfilled (\(watchRecords.count) Watch). Timing known for \(recorded.count) points only; BLE outages and transport delay are separate."
        let basis = nominalGapInSeconds == 0 ? "Acquisition cadence unavailable for this source."
            : "Stored sensor coverage including backfill. Source: \(defaults.cgmTransmitterType?.rawValue ?? "unknown"); acquisition \(nominalGapInSeconds / 60) min. Historical source intervals are retained. The visible 1/5-minute filter does not change expected Libre reception. Pre-upgrade interval history is unavailable."
        let windowStart = now.addingTimeInterval(-24 * 3600)
        let buckets = (0..<24).map { index -> TransmitterReadSuccessHourlyBucket in
            let start = max(analysisStartDate, windowStart.addingTimeInterval(Double(index) * 3600))
            let end = min(now, windowStart.addingTimeInterval(Double(index + 1) * 3600))
            let counts = TransmitterReadSuccessPolicy.counts(timestamps: allTimestamps, start: start,
                end: end, contexts: contexts, fallbackInterval: nominalGapInSeconds)
            return TransmitterReadSuccessHourlyBucket(id: index, expected: counts.expected, actual: counts.actual,
                success: flooredPercent(actual: counts.actual, expected: counts.expected, hasMisses: counts.actual < counts.expected))
        }
        return TransmitterReadSuccessDisplay(
            nominalGapInSeconds: nominalGapInSeconds,
            earliestTimestampInLast24h: analysisStartDate,
            hourlyBuckets: buckets,
            expected24h: expected24h,
            actual24h: actual24h,
            success24h: success24h,
            calculationBasis: basis,
            deliveryEvidence: evidence,
            timelyReceiptCount: timely,
            delayedReceiptCount: delayed
        )
    }
    
    /// Convenience accessor intended for log production. Ensures that at most one result is returned per hour.
    /// - Parameters:
    ///   - sensor: Current sensor/session to evaluate.
    ///   - now: Optional override of current time; defaults to `nowProvider()`.
    ///   - cutoff: Optional cutoff date to clamp analysis.
    /// - Returns: Display model when allowed by throttle, otherwise `nil`.
    func getReadSuccessForLogs(forSensor sensor: Sensor, now: Date? = nil, notBefore cutoff: Date? = nil, timeStampOfLastLogCreated: Date?) -> TransmitterReadSuccessDisplay? {
        let nowInstant = now ?? nowProvider()
        if let last = timeStampOfLastLogCreated, nowInstant.timeIntervalSince(last) < (60 * 60) {
            return nil
        }
        
        return getReadSuccess(forSensor: sensor, now: nowInstant, notBefore: cutoff)
    }
    
    // MARK: - private functions

    private func flooredPercent(actual: Int, expected: Int, hasMisses: Bool) -> Double {
        guard expected > 0 else { return 0 }
        let percentage = floor(Double(actual) * 1000 / Double(expected)) / 10
        return hasMisses ? min(percentage, 99.9) : percentage
    }
}
