//
//  WatchState.swift
//  xdrip
//
//  Created by Paul Plant on 21/2/24.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//

import Foundation

protocol WatchPayload: Codable {
    var asDictionary: [String: Any]? { get }
}

extension WatchPayload {
    var asDictionary: [String: Any]? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: .allowFragments)).flatMap { $0 as? [String: Any] }
    }
}

/// current status data used to manage watch views
struct WatchStatus: WatchPayload {
    var generatedAt: Double = Date().timeIntervalSince1970
    var isMgDl: Bool = true
    var urgentLowLimitInMgDl: Double = 60
    var lowLimitInMgDl: Double = 80
    var highLimitInMgDl: Double = 170
    var urgentHighLimitInMgDl: Double = 250
    var activeSensorDescription: String?
    var sensorAgeInMinutes: Double = 0
    var sensorMaxAgeInMinutes: Double = 0
    var preferSensorCountdown: Bool = false
    var sensorNoiseStateRawValue: Int?
    var isMaster: Bool = true
    var followerDataSourceTypeRawValue: Int = 0
    var followerBackgroundKeepAliveTypeRawValue: Int = 0
    var followerConnectionStatusRawValue: String?
    var timeStampOfLastFollowerConnection: Double?
    var secondsUntilFollowerDisconnectWarning: Int?
    var timeStampOfLastHeartBeat: Double?
    var secondsUntilHeartBeatDisconnectWarning: Int?
    var keepAliveIsDisabled: Bool = false

    var aidStatus: AIDStatus?
    var libreAlarmSettings: LibreWatchAlarmSettings?
}

/// current BG chart data used to manage watch views
struct WatchBgReadings: WatchPayload {
    var generatedAt: Double = Date().timeIntervalSince1970
    var hoursIncluded: Double = 12
    var bgReadingValues: [Double] = []
    var bgReadingDatesAsDouble: [Double] = []
    var slopeOrdinal: Int = 1
    var deltaValueInUserUnit: Double = 0
}

/// Compact AGP background data for the Watch main chart.
///
/// AGP is generated on iOS because the phone has Core Data access. The Watch only receives
/// minute-of-day percentile points, then maps them locally onto the current chart window.
/// Keeping the payload independent of chart width avoids stale endpoint redraws when the user
/// changes the visible hours.
struct WatchAGP: WatchPayload {
    var generatedAt: Double = Date().timeIntervalSince1970
    var requestID: Double = 0
    var visibleStartDateAsDouble: Double = 0
    var visibleEndDateAsDouble: Double = 0
    var dayCount: Int = 0
    var minuteOfDayValues: [Int] = []
    var p5Values: [Double] = []
    var p25Values: [Double] = []
    var medianValues: [Double] = []
    var p75Values: [Double] = []
    var p95Values: [Double] = []
}

/// Actual alert schedules from iPhone; chart colours are deliberately not inputs.
enum LibreWatchAlarmKind: Int, Codable, CaseIterable {
    case veryLow = 0, low = 1, high = 2, veryHigh = 3, missed = 4

    var snoozeGroup: [Self] {
        switch self {
        case .veryLow, .low: return [.veryLow, .low]
        case .veryHigh, .high: return [.veryHigh, .high]
        case .missed: return [.missed]
        }
    }
}

struct LibreWatchAlarmRule: Codable, Equatable {
    let kind: LibreWatchAlarmKind
    let startMinute: Int
    let value: Double
    let enabled: Bool
    let snoozeMinutes: Int
    let allowsSnooze: Bool
    let soundEnabled: Bool
    let vibrate: Bool
    let title: String
}

struct LibreWatchAlarmSnooze: Codable, Equatable {
    let kind: LibreWatchAlarmKind
    let until: Date
}

struct LibreWatchAlarmAutomaticThrottle: Codable, Equatable {
    let kind: LibreWatchAlarmKind
    let readingID: UUID
    let until: Date
}

struct LibreWatchAlarmSettings: Codable, Equatable {
    let sessionID: UUID
    let sensorIdentity: String
    var revision: UInt64
    var generatedAt: Date
    let isMgDl: Bool
    let rules: [LibreWatchAlarmRule]
    let snoozes: [LibreWatchAlarmSnooze]
    let snoozeAllUntil: Date?

    func matches(_ session: LibreWatchDirectSession) -> Bool {
        sessionID == session.id && sensorIdentity == session.redactedIdentity() &&
            revision > 0 && rules.allSatisfy {
                (0..<1440).contains($0.startMinute) && $0.value.isFinite &&
                    (!$0.enabled || $0.value > 0) && $0.snoozeMinutes >= 0
            }
    }

    func sameConfiguration(as other: Self) -> Bool {
        sessionID == other.sessionID && sensorIdentity == other.sensorIdentity &&
            isMgDl == other.isMgDl && rules == other.rules &&
            snoozes == other.snoozes && snoozeAllUntil == other.snoozeAllUntil
    }

    func readinessRevision(notificationsAuthorized: Bool) -> UInt64? {
        notificationsAuthorized || !rules.contains(where: \.enabled) ? revision : nil
    }

    func rule(for kind: LibreWatchAlarmKind, at date: Date, calendar: Calendar = .current) -> LibreWatchAlarmRule? {
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let schedule = rules.filter { $0.kind == kind }.sorted { $0.startMinute < $1.startMinute }
        return schedule.last(where: { $0.startMinute <= minute }) ?? schedule.last
    }
}

struct LibreWatchAlarmDelegation: Codable, Equatable {
    let sessionID: UUID
    let sensorIdentity: String
    let settingsRevision: UInt64
    var enabledKinds: [LibreWatchAlarmKind]? = nil
    /// Keep the acknowledged configuration with its authority. A newer offered revision
    /// may overtake its reply; the Watch can still install this exact committed pair.
    var confirmedSettings: LibreWatchAlarmSettings? = nil

    static func confirmed(for settings: LibreWatchAlarmSettings) -> Self {
        Self(sessionID: settings.sessionID, sensorIdentity: settings.sensorIdentity,
            settingsRevision: settings.revision,
            enabledKinds: LibreWatchAlarmKind.allCases.filter { kind in
                settings.rules.contains { $0.kind == kind && $0.enabled }
            }, confirmedSettings: settings)
    }

    func covers(_ kind: LibreWatchAlarmKind) -> Bool {
        enabledKinds?.contains(kind) == true
    }

    func matches(_ settings: LibreWatchAlarmSettings) -> Bool {
        sessionID == settings.sessionID && sensorIdentity == settings.sensorIdentity &&
            settingsRevision == settings.revision && enabledKinds == Self.confirmed(for: settings).enabledKinds
    }
}

/// Watch-only negotiation state. Persist the active pair atomically; a candidate must not
/// remove the last working alarm configuration while its acknowledgement is in flight.
struct LibreWatchAlarmConfiguration: Codable, Equatable {
    private(set) var settings: LibreWatchAlarmSettings?
    private(set) var delegation: LibreWatchAlarmDelegation?
    private(set) var pendingSettings: LibreWatchAlarmSettings?
    private var authorityRevision: UInt64?

    init(settings: LibreWatchAlarmSettings? = nil, delegation: LibreWatchAlarmDelegation? = nil) {
        self.settings = settings
        self.delegation = delegation
        authorityRevision = delegation?.settingsRevision
    }

    var offeredSettings: LibreWatchAlarmSettings? { pendingSettings ?? settings }

    @discardableResult
    mutating func propose(_ candidate: LibreWatchAlarmSettings, session: LibreWatchDirectSession) -> Bool {
        guard candidate.matches(session) else { return false }
        if settings?.sessionID != candidate.sessionID || settings?.sensorIdentity != candidate.sensorIdentity {
            self = Self(settings: candidate)
            return true
        }
        guard candidate.revision >= (offeredSettings?.revision ?? 0) else { return false }
        if candidate.revision == offeredSettings?.revision {
            return candidate == offeredSettings
        }
        if let settings, delegation?.matches(settings) == true {
            pendingSettings = candidate
        } else {
            settings = candidate
            pendingSettings = nil
        }
        return true
    }

    @discardableResult
    mutating func confirm(_ candidate: LibreWatchAlarmDelegation?, session: LibreWatchDirectSession) -> Bool {
        guard offeredSettings?.matches(session) == true else { return false }
        guard let candidate else {
            authorityRevision = max(authorityRevision ?? 0, offeredSettings?.revision ?? 0)
            delegation = nil
            if let pendingSettings { settings = pendingSettings; self.pendingSettings = nil }
            return true
        }
        guard candidate.sessionID == session.id, candidate.sensorIdentity == session.redactedIdentity(),
              candidate.settingsRevision >= (authorityRevision ?? delegation?.settingsRevision ?? 0),
              candidate.confirmedSettings.map({ $0.matches(session) && candidate.matches($0) }) ?? true
        else { return false }
        let matchingSettings = [candidate.confirmedSettings, pendingSettings, settings]
            .compactMap { $0 }.first { $0.matches(session) && candidate.matches($0) }
        guard let matchingSettings else { return false }
        settings = matchingSettings
        delegation = candidate
        authorityRevision = candidate.settingsRevision
        if (pendingSettings?.revision ?? 0) <= matchingSettings.revision { pendingSettings = nil }
        return true
    }

    /// Snooze is conservative during negotiation: receiving a later suppression takes
    /// effect immediately; removing it requires confirmation of the new configuration.
    var effectiveSettings: LibreWatchAlarmSettings? {
        guard let settings, let pendingSettings else { return settings }
        return LibreWatchAlarmSettings(sessionID: settings.sessionID, sensorIdentity: settings.sensorIdentity,
            revision: settings.revision, generatedAt: settings.generatedAt, isMgDl: settings.isMgDl,
            rules: settings.rules, snoozes: settings.snoozes + pendingSettings.snoozes,
            snoozeAllUntil: [settings.snoozeAllUntil, pendingSettings.snoozeAllUntil].compactMap { $0 }.max())
    }
}

struct LibreWatchAlarmState: Codable, Equatable {
    var sessionID: UUID?
    var sensorIdentity: String?
    var lastReadingID: UUID?
    var lastReadingAt: Date?
    var snoozes: [LibreWatchAlarmSnooze] = []
    var scheduledMissedID: String?
    var scheduledMissedAt: Date?
    var scheduledMissedConfirmed: Bool?
    var automaticThrottle: LibreWatchAlarmAutomaticThrottle?
    var ownershipStartedAt: Date?

    /// An alarm baseline is not a glucose reading. It survives restart/wrist wakes and
    /// covers a takeover that never produces its first packet without fabricating an ID/value.
    mutating func beginWatchOwnership(at date: Date) {
        if ownershipStartedAt == nil { ownershipStartedAt = date }
    }

    mutating func endWatchOwnership() { ownershipStartedAt = nil }

    var missedReadingBaseline: Date? {
        [lastReadingAt, ownershipStartedAt].compactMap { $0 }.max()
    }

    mutating func use(_ settings: LibreWatchAlarmSettings) {
        guard sessionID != settings.sessionID || sensorIdentity != settings.sensorIdentity else { return }
        self = Self(sessionID: settings.sessionID, sensorIdentity: settings.sensorIdentity)
    }

    func snoozedUntil(_ kind: LibreWatchAlarmKind, settings: LibreWatchAlarmSettings) -> Date {
        (snoozes + settings.snoozes).filter { kind.snoozeGroup.contains($0.kind) }.map(\.until).max() ?? .distantPast
    }

    mutating func snooze(_ kind: LibreWatchAlarmKind, until: Date) {
        // Explicit snooze must invalidate even an equal/shorter automatic expiry.
        automaticThrottle = nil
        for item in kind.snoozeGroup {
            let previous = snoozes.first(where: { $0.kind == item })?.until ?? .distantPast
            snoozes.removeAll { $0.kind == item }
            snoozes.append(LibreWatchAlarmSnooze(kind: item, until: max(previous, until)))
        }
    }

    mutating func recordAutomaticThrottle(_ kind: LibreWatchAlarmKind, readingID: UUID, until: Date) {
        snooze(kind, until: until)
        automaticThrottle = LibreWatchAlarmAutomaticThrottle(kind: kind, readingID: readingID, until: until)
    }

    mutating func acknowledgePhoneSnoozes(_ settings: LibreWatchAlarmSettings) {
        guard sessionID == settings.sessionID, sensorIdentity == settings.sensorIdentity else { return }
        // Once the phone has stored an equal/later expiry it becomes authoritative again.
        // A subsequent explicit phone Unsnooze must not be hidden by an old local overlay.
        snoozes.removeAll { local in
            settings.snoozes.contains { $0.kind == local.kind && $0.until >= local.until }
        }
    }

    func glucoseNotificationIsCurrent(
        readingID: UUID, rule: LibreWatchAlarmRule, submittedSettings: LibreWatchAlarmSettings,
        currentSettings: LibreWatchAlarmSettings?, delegation: LibreWatchAlarmDelegation?,
        watchOwnsSensor: Bool, notificationsAuthorized: Bool, now: Date
    ) -> Bool {
        guard watchOwnsSensor, notificationsAuthorized,
              let currentSettings, currentSettings == submittedSettings,
              delegation?.matches(currentSettings) == true,
              sessionID == currentSettings.sessionID, sensorIdentity == currentSettings.sensorIdentity,
              lastReadingID == readingID, let lastReadingAt, now.timeIntervalSince(lastReadingAt) <= 180,
              (currentSettings.snoozeAllUntil ?? .distantPast) <= now,
              snoozedUntil(rule.kind, settings: currentSettings) <= now,
              currentSettings.rule(for: rule.kind, at: now) == rule
        else { return false }
        return rule.enabled
    }

    /// Do not re-alert a confirmed, already-due notification simply because the user dismissed
    /// it. Recover a crash between persisting intent and OS acceptance, or a missing future item.
    func shouldRestoreMissingMissedNotification(at now: Date) -> Bool {
        scheduledMissedID != nil &&
            (scheduledMissedConfirmed != true || (scheduledMissedAt ?? .distantPast) > now)
    }

    func notificationMayBePresented(
        kind: LibreWatchAlarmKind, notificationSessionID: String, notificationReadingID: UUID?,
        settings: LibreWatchAlarmSettings?, delegation: LibreWatchAlarmDelegation?,
        watchOwnsSensor: Bool, notificationsAuthorized: Bool, at date: Date,
        notificationMissedBaseline: Date? = nil
    ) -> Bool {
        guard watchOwnsSensor, notificationsAuthorized, let settings,
              notificationSessionID == settings.sessionID.uuidString,
              sessionID == settings.sessionID, sensorIdentity == settings.sensorIdentity,
              delegation?.matches(settings) == true,
              (settings.snoozeAllUntil ?? .distantPast) <= date,
              settings.rule(for: kind, at: date)?.enabled == true
        else { return false }
        if kind == .missed {
            // New first-packet watchdogs carry a baseline, never a fabricated reading ID.
            if let notificationMissedBaseline {
                guard notificationMissedBaseline == missedReadingBaseline else { return false }
            } else {
                guard let notificationReadingID, notificationReadingID == lastReadingID else { return false }
            }
        } else {
            guard let notificationReadingID, notificationReadingID == lastReadingID else { return false }
        }
        if kind != .missed {
            guard let lastReadingAt, date.timeIntervalSince(lastReadingAt) <= 180 else { return false }
        }
        let snoozeExpiry = snoozedUntil(kind, settings: settings)
        if snoozeExpiry > date {
            guard let automaticThrottle, kind.snoozeGroup.contains(automaticThrottle.kind),
                  automaticThrottle.readingID == notificationReadingID,
                  automaticThrottle.until == snoozeExpiry
            else { return false }
        }
        // Missing-reading alarms deliberately retain the old measurement timestamp.
        // Only this exact glucose notification may pass its own automatic throttle.
        return true
    }

    /// Called only for an accepted *new direct* reading, never for graph/backfill updates.
    mutating func accept(
        id: UUID, measuredAt: Date, glucose: Double,
        settings: LibreWatchAlarmSettings, delegation: LibreWatchAlarmDelegation?,
        watchOwnsSensor: Bool, now: Date, calendar: Calendar = .current
    ) -> LibreWatchAlarmRule? {
        guard watchOwnsSensor, delegation?.matches(settings) == true,
              sessionID == settings.sessionID, sensorIdentity == settings.sensorIdentity,
              glucose.isFinite, glucose > 0,
              measuredAt <= now.addingTimeInterval(20), now.timeIntervalSince(measuredAt) <= 180,
              lastReadingID != id, measuredAt > (lastReadingAt ?? .distantPast)
        else { return nil }
        lastReadingID = id
        lastReadingAt = measuredAt
        guard (settings.snoozeAllUntil ?? .distantPast) <= now else { return nil }

        for kind: LibreWatchAlarmKind in [.veryLow, .low, .veryHigh, .high] {
            guard snoozedUntil(kind, settings: settings) <= now,
                  let rule = settings.rule(for: kind, at: now, calendar: calendar), rule.enabled
            else { continue }
            let value = glucose.bgValueRounded(mgDl: settings.isMgDl)
            let threshold = rule.value.bgValueRounded(mgDl: settings.isMgDl)
            let needed = kind == .veryLow || kind == .low ? value < threshold : value > threshold
            if needed { return rule }
        }
        return nil
    }

    /// One system-scheduled deadline; no background timer is needed to detect missing readings.
    func nextMissedAlarm(
        settings: LibreWatchAlarmSettings, delegation: LibreWatchAlarmDelegation?,
        watchOwnsSensor: Bool, now: Date, calendar: Calendar = .current
    ) -> (date: Date, rule: LibreWatchAlarmRule)? {
        guard watchOwnsSensor, delegation?.matches(settings) == true,
              sessionID == settings.sessionID, sensorIdentity == settings.sensorIdentity,
              let baseline = missedReadingBaseline
        else { return nil }
        let rules = settings.rules.filter { $0.kind == .missed }.sorted { $0.startMinute < $1.startMinute }
        guard !rules.isEmpty else { return nil }
        let startOfDay = calendar.startOfDay(for: now)
        for day in 0...1 {
            guard let dayStart = calendar.date(byAdding: .day, value: day, to: startOfDay),
                  let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)
            else { continue }
            for (index, rule) in rules.enumerated() where rule.enabled {
                let start = calendar.date(byAdding: .minute, value: rule.startMinute, to: dayStart)!
                let end = index + 1 < rules.count
                    ? calendar.date(byAdding: .minute, value: rules[index + 1].startMinute, to: dayStart)!
                    : nextDay
                let due = [now, start, baseline.addingTimeInterval(rule.value * 60),
                           snoozedUntil(.missed, settings: settings), settings.snoozeAllUntil ?? .distantPast].max()!
                if due < end { return (due, rule) }
            }
        }
        return nil
    }
}

enum LibreWatchAlarmStore {
    private static let settingsKey = "libreWatchAlarmSettings.v1"
    private static let stateKey = "libreWatchAlarmState.v1"
    private static let delegationKey = "libreWatchAlarmDelegation.v1"
    private static let configurationKey = "libreWatchAlarmConfiguration.v1"

    static func configuration(defaults: UserDefaults = .standard) -> LibreWatchAlarmConfiguration {
        decode(LibreWatchAlarmConfiguration.self, key: configurationKey, defaults: defaults) ??
            LibreWatchAlarmConfiguration(settings: settings(defaults: defaults), delegation: delegation(defaults: defaults))
    }

    static func save(_ configuration: LibreWatchAlarmConfiguration, defaults: UserDefaults = .standard) {
        encode(configuration, key: configurationKey, defaults: defaults)
    }

    static func settings(defaults: UserDefaults = .standard) -> LibreWatchAlarmSettings? {
        decode(LibreWatchAlarmSettings.self, key: settingsKey, defaults: defaults)
    }
    static func state(defaults: UserDefaults = .standard) -> LibreWatchAlarmState {
        decode(LibreWatchAlarmState.self, key: stateKey, defaults: defaults) ?? LibreWatchAlarmState()
    }
    static func delegation(defaults: UserDefaults = .standard) -> LibreWatchAlarmDelegation? {
        decode(LibreWatchAlarmDelegation.self, key: delegationKey, defaults: defaults)
    }
    static func save(_ settings: LibreWatchAlarmSettings, defaults: UserDefaults = .standard) {
        encode(settings, key: settingsKey, defaults: defaults)
    }
    static func save(_ state: LibreWatchAlarmState, defaults: UserDefaults = .standard) {
        encode(state, key: stateKey, defaults: defaults)
    }
    static func save(_ delegation: LibreWatchAlarmDelegation?, defaults: UserDefaults = .standard) {
        if let delegation { encode(delegation, key: delegationKey, defaults: defaults) }
        else { defaults.removeObject(forKey: delegationKey) }
    }
    static func clearSession(defaults: UserDefaults = .standard) {
        [settingsKey, stateKey, delegationKey, configurationKey].forEach { defaults.removeObject(forKey: $0) }
    }
    private static func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
    private static func encode<T: Encodable>(_ value: T, key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

extension Notification.Name {
    static let libreWatchAlarmDelegationChanged = Notification.Name("libreWatchAlarmDelegationChanged")
}
