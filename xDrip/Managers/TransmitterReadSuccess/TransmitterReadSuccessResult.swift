//
//  TransmitterReadSuccessResult.swift
//  xdrip
//
//  Created by Paul Plant on 23/9/25.
//  Copyright © 2025 Johan Degraeve. All rights reserved.
//

import Foundation

/// model to return the transmitter read success results
public struct TransmitterReadSuccessResult {
    public let earliestTimestamp: Date?
    public let latestTimestamp: Date?
    public let distinctTimestampsCount: Int
}

/// Acquisition cadence is configuration, never a conclusion drawn from missing readings.
/// The visible five-minute filter does not change Libre's physical one-minute stream.
struct TransmitterReadSuccessContext: Codable, Equatable {
    let effectiveAt: Date
    let source: String
    let interval: Int
    let visibleInterval: Int

    static func acquisitionInterval(for source: CGMTransmitterType?) -> Int? {
        switch source {
        case .Libre2: return 60
        case .dexcom, .dexcomG7: return 300
        case .medtrumTouchCareNano: return 120
        // Bridge delivery is configurable/adaptive. Do not infer an undocumented
        // historical acquisition interval from its outages or its trend backfill.
        case .miaomiao, .Bubble, .none: return nil
        }
    }
}

struct TransmitterReadSuccessReceipt: Codable {
    let id: String
    let sensorID: String
    let measuredAt: Date
    let storedAt: Date
    let fromWatch: Bool
    let historical: Bool
}

/// Bounded local measurement/receipt evidence. Old installs have coverage, but no invented
/// delivery timestamps. This is diagnostic metadata, not a second glucose database.
enum TransmitterReadSuccessEvidence {
    private static let contextKey = "transmitterReadSuccess.contexts.v1"
    private static let receiptKey = "transmitterReadSuccess.receipts.v1"

    static func contexts(defaults: UserDefaults = .standard) -> [TransmitterReadSuccessContext] {
        guard let data = defaults.data(forKey: contextKey) else { return [] }
        return (try? JSONDecoder().decode([TransmitterReadSuccessContext].self, from: data)) ?? []
    }

    static func recordConfiguration(source: CGMTransmitterType?, visibleFiveMinutes: Bool,
                                    at now: Date = Date(), defaults: UserDefaults = .standard) {
        let sourceName = source?.rawValue ?? "unknown"
        let interval = TransmitterReadSuccessContext.acquisitionInterval(for: source) ?? 0
        var records = contexts(defaults: defaults)
        let visible = visibleFiveMinutes ? 300 : interval
        if let last = records.last, last.source == sourceName,
           last.interval == interval, last.visibleInterval == visible { return }
        records.append(.init(effectiveAt: now, source: sourceName, interval: interval, visibleInterval: visible))
        let cutoff = now.addingTimeInterval(-24 * 3600)
        // Retain the predecessor as the context at the window's left edge.
        let predecessor = records.last(where: { $0.effectiveAt < cutoff })
        records = records.filter { $0.effectiveAt >= cutoff }
        if let predecessor { records.insert(predecessor, at: 0) }
        if let data = try? JSONEncoder().encode(Array(records.suffix(128))) { defaults.set(data, forKey: contextKey) }
    }

    static func receipts(at now: Date = Date(), defaults: UserDefaults = .standard) -> [TransmitterReadSuccessReceipt] {
        guard let data = defaults.data(forKey: receiptKey),
              let records = try? JSONDecoder().decode([TransmitterReadSuccessReceipt].self, from: data) else { return [] }
        return records.filter { $0.measuredAt >= now.addingTimeInterval(-24 * 3600) && $0.measuredAt <= now }
    }

    static func record(_ receipt: TransmitterReadSuccessReceipt, defaults: UserDefaults = .standard) {
        var records = receipts(at: receipt.storedAt, defaults: defaults)
        guard !records.contains(where: { $0.id == receipt.id && $0.sensorID == receipt.sensorID }) else { return }
        records.append(receipt)
        if let data = try? JSONEncoder().encode(Array(records.suffix(4_000))) { defaults.set(data, forKey: receiptKey) }
    }
}

enum TransmitterReadSuccessPolicy {
    struct Counts: Equatable { let expected: Int; let actual: Int }

    /// Each configuration segment contributes its actual acquisition cadence. A backfilled
    /// timestamp fills its original slot; neither backfill nor outages changes the denominator.
    static func counts(timestamps: [Date], start: Date, end: Date,
                       contexts: [TransmitterReadSuccessContext], fallbackInterval: Int) -> Counts {
        guard end > start else { return Counts(expected: 0, actual: 0) }
        let ordered = contexts.sorted { $0.effectiveAt < $1.effectiveAt }
        var interval = ordered.last(where: { $0.effectiveAt <= start })?.interval ?? fallbackInterval
        var segmentStart = start
        var expected = 0
        var actual = 0
        func appendSegment(until segmentEnd: Date) {
            guard interval > 0, segmentEnd > segmentStart else { return }
            let slots = Int(ceil(segmentEnd.timeIntervalSince(segmentStart) / Double(interval)))
            let samples = timestamps.filter { $0 >= segmentStart && $0 < segmentEnd }
            // Cadence stays configured. Only the phase is estimated, using a circular mean
            // so 59/60-second boundary jitter cannot count two consecutive samples as one.
            let angles = samples.suffix(120).map { $0.timeIntervalSince1970 / Double(interval) * 2 * Double.pi }
            let phase = atan2(angles.reduce(0) { $0 + sin($1) }, angles.reduce(0) { $0 + cos($1) }) / (2 * Double.pi) * Double(interval)
            let occupied = Set(samples.map {
                Int(floor(($0.timeIntervalSince1970 - phase) / Double(interval) + 0.5))
            })
            expected += slots
            actual += min(slots, occupied.count)
        }
        for context in ordered where context.effectiveAt > start && context.effectiveAt < end {
            guard context.interval != interval else { continue }
            appendSegment(until: context.effectiveAt)
            segmentStart = context.effectiveAt
            interval = context.interval
        }
        appendSegment(until: end)
        return Counts(expected: expected, actual: actual)
    }
}
