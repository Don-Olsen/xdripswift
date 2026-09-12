import Foundation

/// Reusing a control envelope is independent of graph transport/backoff. Real session,
/// unlock, calibration, owner and alarm/delegation changes still advance authority.
final class LibreWatchHandoffSnapshotCache {
    private let defaults: UserDefaults
    private let key = "libreWatchPhoneHandoffContent.v1"
    private(set) var snapshot: LibreWatchHandoffSnapshot?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key) {
            snapshot = try? JSONDecoder().decode(LibreWatchHandoffSnapshot.self, from: data)
        }
    }

    func resolve(session: LibreWatchDirectSession, calibration: LibreWatchCalibrationSnapshot?,
                 ownership: LibreWatchOwnership, settings: LibreWatchAlarmSettings,
                 delegation: LibreWatchAlarmDelegation?, at date: Date = Date()) -> LibreWatchHandoffSnapshot? {
        if let previous = snapshot, previous.isValid,
           previous.session == session, previous.calibration == calibration,
           previous.ownership == ownership, previous.alarmDelegation == delegation,
           previous.alarmSettings?.revision == settings.revision,
           previous.alarmSettings?.sameConfiguration(as: settings) == true {
            return previous
        }
        // Validate the candidate before consuming a monotonic authoritative revision.
        var candidate = LibreWatchHandoffSnapshot(session: session, calibration: calibration,
            ownership: ownership, revision: 1, alarmSettings: settings, alarmDelegation: delegation)
        guard candidate.isValid else { return nil }
        candidate = LibreWatchHandoffSnapshot(session: session, calibration: calibration,
            ownership: ownership, revision: LibreWatchSessionStore.nextHandoffRevision(at: date, defaults: defaults),
            alarmSettings: settings, alarmDelegation: delegation)
        guard let data = try? JSONEncoder().encode(candidate) else { return nil }
        defaults.set(data, forKey: key)
        snapshot = candidate
        return candidate
    }

    func current(session: LibreWatchDirectSession?, calibration: LibreWatchCalibrationSnapshot?,
                 ownership: LibreWatchOwnership, delegation: LibreWatchAlarmDelegation?) -> LibreWatchHandoffSnapshot? {
        guard let snapshot, snapshot.isValid, snapshot.session == session,
              snapshot.calibration == calibration, snapshot.ownership == ownership,
              snapshot.alarmDelegation == delegation else { return nil }
        return snapshot
    }

    static func payload(_ snapshot: LibreWatchHandoffSnapshot) -> [String: Any]? {
        guard snapshot.isValid, let session = try? JSONEncoder().encode(snapshot.session),
              let handoff = try? JSONEncoder().encode(snapshot) else { return nil }
        var payload: [String: Any] = [LibreWatchMessageKey.session: session,
            LibreWatchMessageKey.ownership: snapshot.ownership.rawValue,
            LibreWatchMessageKey.handoffSnapshot: handoff]
        if let calibration = snapshot.calibration {
            payload[LibreWatchMessageKey.calibration] = try? JSONEncoder().encode(calibration)
        }
        if let settings = snapshot.alarmSettings {
            payload[LibreWatchMessageKey.alarmSettings] = try? JSONEncoder().encode(settings)
        }
        return payload
    }
}
