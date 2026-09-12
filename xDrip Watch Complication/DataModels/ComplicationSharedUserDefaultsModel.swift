//
//  ComplicationSharedUserDefaultsModel.swift
//  xdrip
//
//  Created by Paul Plant on 4/3/24.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//

import CoreFoundation
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
        latestReadingDate.map { (readingSource ?? .phone).expiresAt(measuredAt: $0) }
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

    // Measurement provenance, not the current Bluetooth owner, determines freshness.
    func expiresAt(measuredAt date: Date) -> Date {
        date.addingTimeInterval(self == .directLibre ? 3 * 60 : 20 * 60)
    }

    func isCurrent(measuredAt: Date, at date: Date) -> Bool {
        measuredAt <= date.addingTimeInterval(20) && date <= expiresAt(measuredAt: measuredAt)
    }
}

/// Separate BG/status snapshots share a phone-installation sequence, never a handoff revision.
/// Persist the accepted payload itself so its ordering watermark and restored display agree.
enum WatchPhoneSnapshotStore {
    enum Stream: String, CaseIterable { case bgReadings, status }
    private static let receivedKey = "watchPhoneSnapshots.v1"
    private static let producerKey = "watchPhoneSnapshotProducer.v1"
    private static let generationKey = "snapshotGeneration"

    private struct Generation {
        let installationID: UUID
        let installationStartedAt: Double
        let sessionID: UUID?
        let revision: UInt64

        init?(_ dictionary: [String: Any]) {
            guard let installation = dictionary["installationID"] as? String,
                  let installationID = UUID(uuidString: installation),
                  let startedAt = WatchPhoneSnapshotStore.number(dictionary["installationStartedAt"]), startedAt > 0,
                  let session = dictionary["sessionID"] as? String,
                  session.isEmpty || UUID(uuidString: session) != nil,
                  let revisionString = dictionary["revision"] as? String,
                  let revision = UInt64(revisionString), revision > 0
            else { return nil }
            self.installationID = installationID
            installationStartedAt = startedAt
            sessionID = UUID(uuidString: session)
            self.revision = revision
        }
    }

    /// Called when the data is generated, not when an old cached payload is retransmitted.
    static func nextGeneration(sessionID: UUID?, at date: Date = Date(), defaults: UserDefaults = .standard) -> [String: Any] {
        let previous = defaults.dictionary(forKey: producerKey).flatMap(Generation.init)
            .flatMap { $0.revision < UInt64.max ? $0 : nil }
        let generation: [String: Any] = [
            "installationID": previous?.installationID.uuidString ?? UUID().uuidString,
            "installationStartedAt": previous?.installationStartedAt ?? date.timeIntervalSince1970,
            "sessionID": sessionID?.uuidString ?? "",
            "revision": String((previous?.revision ?? 0) + 1)
        ]
        defaults.set(generation, forKey: producerKey)
        return generation
    }

    static func attaching(_ generation: [String: Any], to payload: [String: Any]) -> [String: Any] {
        var payload = payload
        payload[generationKey] = generation
        return payload
    }

    static func stored(_ stream: Stream, defaults: UserDefaults = .standard) -> [String: Any]? {
        let saved = savedPayloads(defaults: defaults)
        guard let payload = saved[stream.rawValue] as? [String: Any] else { return nil }
        let generation = (payload[generationKey] as? [String: Any]).flatMap(Generation.init)
        for other in Stream.allCases {
            guard let otherPayload = saved[other.rawValue] as? [String: Any],
                  let otherGeneration = (otherPayload[generationKey] as? [String: Any]).flatMap(Generation.init)
            else { continue }
            guard let generation else { return nil }
            if generation.installationID != otherGeneration.installationID,
               generation.installationStartedAt <= otherGeneration.installationStartedAt { return nil }
        }
        return payload
    }

    private static func savedPayloads(defaults: UserDefaults) -> [String: Any] {
        guard let data = defaults.data(forKey: receivedKey),
              let payloads = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return payloads
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    /// Validation is shared by restoration and live delivery. No missing glucose is invented.
    /// Only committed phone ownership may opt into a nil sender session after reinstall;
    /// this never authorizes a different nonnil sensor session or changes ownership.
    static func isValid(_ payload: [String: Any], stream: Stream, sessionID: UUID?,
                        allowUnscopedPhoneSession: Bool = false, at now: Date = Date()) -> Bool {
        guard let generatedAt = number(payload["generatedAt"]),
              generatedAt > 0,
              let validatedAt = number(payload["snapshotValidatedAt"] ?? payload["generatedAt"]),
              validatedAt >= generatedAt,
              validatedAt > now.addingTimeInterval(-60 * 60).timeIntervalSince1970,
              validatedAt <= now.addingTimeInterval(20).timeIntervalSince1970
        else { return false }
        if let rawGeneration = payload[generationKey] {
            guard let dictionary = rawGeneration as? [String: Any],
                  let generation = Generation(dictionary),
                  generation.sessionID == sessionID || (allowUnscopedPhoneSession && generation.sessionID == nil),
                  generation.installationStartedAt <= generatedAt + 20
            else { return false }
        }
        switch stream {
        case .bgReadings:
            guard let dates = payload["bgReadingDatesAsDouble"] as? [Double],
                  let values = payload["bgReadingValues"] as? [Double],
                  !dates.isEmpty, dates.count == values.count,
                  (payload["bgReadingValues"] as? [Any])?.allSatisfy({ number($0) != nil }) == true,
                  (payload["bgReadingDatesAsDouble"] as? [Any])?.allSatisfy({ number($0) != nil }) == true,
                  values.allSatisfy({ $0.isFinite && $0 >= 0 }),
                  dates.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= now.addingTimeInterval(20).timeIntervalSince1970 }),
                  zip(dates, dates.dropFirst()).allSatisfy({ $0.0 >= $0.1 }),
                  dates[0] > now.addingTimeInterval(-60 * 60).timeIntervalSince1970,
                  let slope = payload["slopeOrdinal"] as? Int, (0...7).contains(slope),
                  number(payload["slopeOrdinal"]) == Double(slope),
                  number(payload["deltaValueInUserUnit"]) != nil
            else { return false }
        case .status:
            let limitKeys = ["urgentLowLimitInMgDl", "lowLimitInMgDl", "highLimitInMgDl", "urgentHighLimitInMgDl"]
            let limits = limitKeys.compactMap { number(payload[$0]) }
            // These chart settings are independently editable on iPhone. Validate their
            // numeric transport, not a new ordering rule that could block all status.
            guard limits.count == limitKeys.count,
                  payload["isMgDl"] is Bool, payload["isMaster"] is Bool,
                  payload["keepAliveIsDisabled"] is Bool,
                  let age = number(payload["sensorAgeInMinutes"]), age >= 0,
                  let maxAge = number(payload["sensorMaxAgeInMinutes"]), maxAge >= 0
            else { return false }
        }
        return true
    }

    @discardableResult
    static func accept(_ payload: [String: Any], stream: Stream, sessionID: UUID?,
                       displayedReadingDate: Date? = nil, allowUnscopedPhoneSession: Bool = false,
                       at now: Date = Date(),
                       defaults: UserDefaults = .standard) -> Bool {
        guard isValid(payload, stream: stream, sessionID: sessionID,
                      allowUnscopedPhoneSession: allowUnscopedPhoneSession, at: now),
              let generatedAt = payload["generatedAt"] as? Double
        else { return false }
        let generation = (payload[generationKey] as? [String: Any]).flatMap(Generation.init)
        var saved = savedPayloads(defaults: defaults)
        // Once either stream has upgraded, queued pre-upgrade dictionaries cannot roll it back.
        for other in Stream.allCases {
            guard let previous = saved[other.rawValue] as? [String: Any],
                  let oldGeneration = (previous[generationKey] as? [String: Any]).flatMap(Generation.init)
            else { continue }
            guard let generation else { return false }
            if generation.installationID != oldGeneration.installationID {
                guard generation.installationStartedAt > oldGeneration.installationStartedAt,
                      generatedAt > (previous["generatedAt"] as? Double ?? 0)
                else { return false }
            }
        }
        if let previous = saved[stream.rawValue] as? [String: Any] {
            let oldGeneration = (previous[generationKey] as? [String: Any]).flatMap(Generation.init)
            if let generation, let oldGeneration, generation.installationID == oldGeneration.installationID {
                if generation.revision == oldGeneration.revision {
                    // Revalidation of exactly the same content is not a new generation.
                    // It never advances the actual glucose timestamp or changes authority.
                    guard let contentID = payload["snapshotContentID"] as? String,
                          contentID == previous["snapshotContentID"] as? String,
                          let checked = number(payload["snapshotValidatedAt"]),
                          checked > (number(previous["snapshotValidatedAt"]) ?? 0),
                          sameSnapshotContent(payload, previous) else { return false }
                } else if generation.revision < oldGeneration.revision { return false }
            } else {
                guard generatedAt > (previous["generatedAt"] as? Double ?? 0) else { return false }
            }
            if stream == .bgReadings,
               let oldLatest = (previous["bgReadingDatesAsDouble"] as? [Double])?.first,
               let latest = (payload["bgReadingDatesAsDouble"] as? [Double])?.first,
               latest < oldLatest { return false }
        }
        if stream == .bgReadings, let displayedReadingDate,
           let latest = (payload["bgReadingDatesAsDouble"] as? [Double])?.first,
           latest < displayedReadingDate.timeIntervalSince1970 { return false }
        saved[stream.rawValue] = payload
        guard let data = try? JSONSerialization.data(withJSONObject: saved) else { return false }
        defaults.set(data, forKey: receivedKey)
        return true
    }

    /// A context may arrive before its matching push/reply. Acknowledge that already
    /// validated content without writing it again or treating receipt as a new reading.
    static func isCurrent(_ payload: [String: Any], stream: Stream, sessionID: UUID?,
                          allowUnscopedPhoneSession: Bool = false, at now: Date = Date(),
                          defaults: UserDefaults = .standard) -> Bool {
        guard isValid(payload, stream: stream, sessionID: sessionID,
                      allowUnscopedPhoneSession: allowUnscopedPhoneSession, at: now),
              let saved = stored(stream, defaults: defaults) else { return false }
        return sameSnapshotContent(payload, saved)
    }

    private static func sameSnapshotContent(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        func content(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                return dictionary.filter { !["generatedAt", "snapshotValidatedAt", "sensorAgeInMinutes"].contains($0.key) }
                    .mapValues(content)
            }
            if let array = value as? [Any] { return array.map(content) }
            return value
        }
        guard let left = content(lhs) as? [String: Any], let right = content(rhs) as? [String: Any] else { return false }
        return NSDictionary(dictionary: left).isEqual(to: right)
    }
}
