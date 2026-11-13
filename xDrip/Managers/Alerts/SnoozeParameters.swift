import Foundation

extension SnoozeParameters {
    
    // MARK: public functions
    
    /// store snoozeperiod in minutes, snoozetimestamp = now,
    public func snooze(snoozePeriodInMinutes:Int) {
        self.snoozePeriodInMinutes = Int16(snoozePeriodInMinutes)
        snoozeTimeStamp = Date()
    }
    

    /// reset snooze, ie not snoozed
    public func unSnooze() {
        snoozePeriodInMinutes = 0
        snoozeTimeStamp = nil
    }
    
    /// checks if snoozed and snoozetimestamp and if current time still within the period, then returns true
    /// - returns:
    ///     - isSnoozed : is the alert snoozed
    ///     - remainingSeconds : if the alert is snoozed, then this says how many seconds remaining
    public func getSnoozeValue() -> (isSnoozed:Bool, remainingSeconds:Int?) {
        if let snoozeTimeStamp = snoozeTimeStamp, snoozePeriodInMinutes > 0 {
            if Date(timeInterval: TimeInterval(Double(snoozePeriodInMinutes) * 60.0), since: snoozeTimeStamp) < Date() {
                // snooze attributes are set, however they are expired
                unSnooze() // set attributes to nil
                return (false, nil)
            } else {
                // alert is still snoozed, calculate remaining seconds
                return (true, Int((snoozeTimeStamp.toMillisecondsAsDouble() + Double(snoozePeriodInMinutes) * 60.0 * 1000.0 - Date().toMillisecondsAsDouble())/1000.0))
            }
        } else {
            return (false, nil)
        }
    }
}


/// Selective silence has its own expiry so ending it cannot erase an independent snooze.
/// One defaults record commits expiry and callback identity together; no timer is required.
enum SelectiveAlarmSilence {
    static let stateKey = "selectiveAlarmSilence.v1"
    static let durationKey = "selectiveAlarmSilence.durationMinutes"
    static let changed = Notification.Name("xdrip.selectiveAlarmSilence.changed")
    static let defaultDurationMinutes = 60
    static var durationChoices: [Int] { ConstantsAlerts.snoozeValueMinutes.filter { $0 <= 120 } }

    static let kinds: Set<AlertKind> = [.high, .veryhigh, .fastrise, .fastdrop, .calibration,
        .batterylow, .dexcomG5BatteryLow, .dexcomG7BatteryLow, .phonebatterylow, .notlooping]

    static var notificationIdentifiers: [String] {
        kinds.sorted { $0.rawValue < $1.rawValue }.map { $0.notificationIdentifier() }
            + [HighSoonAdvisoryPolicy.notificationIdentifier]
    }

    static func durationMinutes(defaults: UserDefaults = .standard) -> Int {
        let value = defaults.integer(forKey: durationKey)
        return durationChoices.contains(value) ? value : defaultDurationMinutes
    }

    static func until(defaults: UserDefaults = .standard) -> Date? {
        guard let date = defaults.dictionary(forKey: stateKey)?["until"] as? Date,
              date.timeIntervalSince1970.isFinite else { return nil }
        return date
    }

    static func revision(defaults: UserDefaults = .standard) -> String? {
        defaults.dictionary(forKey: stateKey)?["revision"] as? String
    }

    static func isActive(at now: Date = .now, defaults: UserDefaults = .standard) -> Bool {
        until(defaults: defaults).map { $0 > now } ?? false
    }

    static func suppresses(_ kind: AlertKind, at now: Date = .now,
                           defaults: UserDefaults = .standard) -> Bool {
        kinds.contains(kind) && isActive(at: now, defaults: defaults)
    }

    @MainActor static func toggle(at now: Date = .now, defaults: UserDefaults = .standard) {
        let expiry = isActive(at: now, defaults: defaults) ? nil
            : now.addingTimeInterval(Double(durationMinutes(defaults: defaults)) * 60)
        store(until: expiry, changedAt: now, defaults: defaults)
    }

    /// An explicit high snooze starts or extends the pause; it never toggles an active pause off.
    @MainActor static func start(until expiry: Date, at now: Date = .now,
                                 defaults: UserDefaults = .standard) {
        guard now.timeIntervalSince1970.isFinite, expiry.timeIntervalSince1970.isFinite,
              expiry > now, expiry.timeIntervalSince(now) <= 7 * 24 * 60 * 60 else { return }
        store(until: max(until(defaults: defaults) ?? .distantPast, expiry),
              changedAt: now, defaults: defaults)
    }

    /// Only the explicit Watch action marker can start this pause. Automatic alarm throttles
    /// also travel in Watch state, but are not user actions. Preserve the original deadline.
    @MainActor static func applyWatchSnooze(_ request: LibreWatchUserHighSnooze,
                                           at now: Date = .now, defaults: UserDefaults = .standard) {
        let record = defaults.dictionary(forKey: stateKey) ?? [:]
        guard request.hasValidInterval, now.timeIntervalSince1970.isFinite,
              request.requestedAt <= now, request.until > now,
              record["watchRequestID"] as? String != request.id.uuidString,
              request.requestedAt > (record["changedAt"] as? Date ?? .distantPast) else { return }
        store(until: max(until(defaults: defaults) ?? .distantPast, request.until),
              changedAt: request.requestedAt, watchRequestID: request.id, defaults: defaults)
    }

    @MainActor static func end(at now: Date = .now, defaults: UserDefaults = .standard) {
        store(until: nil, changedAt: now, defaults: defaults)
    }

    @MainActor private static func store(until: Date?, changedAt: Date,
                                         watchRequestID: UUID? = nil, defaults: UserDefaults) {
        // Retain the last accepted Watch action even after End or an icon toggle. Re-delivery
        // must not restart a pause, and older Watch actions cannot override a newer local choice.
        var record = defaults.dictionary(forKey: stateKey) ?? [:]
        record["revision"] = UUID().uuidString
        record["changedAt"] = changedAt
        if let watchRequestID { record["watchRequestID"] = watchRequestID.uuidString }
        if let until { record["until"] = until } else { record.removeValue(forKey: "until") }
        defaults.set(record, forKey: stateKey)
        NotificationCenter.default.post(name: changed, object: defaults)
        if defaults === UserDefaults.standard { defaults.updateSnoozeStatus.toggle() }
    }
}
