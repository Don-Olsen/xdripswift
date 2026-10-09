// A frozen, device-local training input. Background execution never reads HealthKit
// or carries managed objects between queues. Live measurements and forecasts do
// not wait for this file. Incompatible or stale inputs are never replayed.
import Foundation
import CryptoKit

struct GlucoseForecastMLPreparedHistory: Codable, Sendable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let id: UUID
    let appBuild: String
    let context: GlucoseForecastMLContext
    let preparedAt: Date
    let timeZoneIdentifier: String
    let featureNames: [String]
    let examples: [GlucoseForecastMLReplayExample]

    init(context: GlucoseForecastMLContext, preparedAt: Date,
         examples: [GlucoseForecastMLReplayExample], timeZone: TimeZone = .current) {
        schemaVersion = Self.schemaVersion
        id = UUID()
        appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        self.context = context
        self.preparedAt = preparedAt
        timeZoneIdentifier = timeZone.identifier
        featureNames = GlucoseForecastMLFeatures.featureNames
        self.examples = examples
    }

    func isUsable(context current: GlucoseForecastMLContext, at now: Date) -> Bool {
        guard schemaVersion == Self.schemaVersion, context == current,
              appBuild == (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"),
              context.engineVersion == GlucoseForecastEngine.engineVersion,
              context.featureVersion == GlucoseForecastMLFeatures.featureVersion,
              featureNames == GlucoseForecastMLFeatures.featureNames,
              timeZoneIdentifier == TimeZone.current.identifier,
              preparedAt <= now, now.timeIntervalSince(preparedAt) <= 48 * 3600,
              !examples.isEmpty, examples.count <= 200_000 else { return false }
        let minimum = GlucoseForecastEngine.configuration.minimumGlucoseMgdl
        let maximum = GlucoseForecastEngine.configuration.maximumGlucoseMgdl
        let bounds = minimum...maximum
        guard examples.allSatisfy({ example in
            let row = example.row
            return [30, 60, 120].contains(row.horizonMinutes)
                && row.values.count == featureNames.count && row.values.allSatisfy(\.isFinite)
                && row.engineValue.isFinite && row.glucose.isFinite && bounds.contains(row.glucose)
                && example.targetGlucoseMgdl.isFinite && bounds.contains(example.targetGlucoseMgdl)
                && example.engineTargetGlucoseMgdl.isFinite
                && bounds.contains(row.engineValue)
                && example.engineTrajectoryMgdl.count == 25
                && example.engineTrajectoryMgdl.allSatisfy({ $0.isFinite && bounds.contains($0) })
                && example.engineTrajectoryMgdl[0] == row.glucose
                && example.engineTrajectoryMgdl[row.horizonMinutes / 5] == row.engineValue
                && row.engineValue == example.engineTargetGlucoseMgdl
                && !example.sourceIdentity.isEmpty && row.referenceDate <= preparedAt
                && example.targetDate <= preparedAt
                && abs(example.targetDate.timeIntervalSince(row.referenceDate)
                    - Double(row.horizonMinutes * 60)) <= GlucoseForecastMLReplay.targetTolerance
                && example.bolusUnitsInWindow.isFinite && example.bolusUnitsInWindow >= 0
                && example.carbohydrateGramsInWindow.isFinite && example.carbohydrateGramsInWindow >= 0
        }), GlucoseForecastMLChronology.completeAnchors(examples).count * 3 == examples.count,
              let latest = examples.map({ $0.row.referenceDate }).max(),
              now.timeIntervalSince(latest) <= GlucoseForecastMLChronology.maximumRecentAnchorAge
        else { return false }
        return true
    }
}

/// The same exact context/rows yield the same key, independent of process restart.
/// Dates and doubles keep their encoded precision; no health values enter logs.
enum GlucoseForecastMLTrainingFingerprint {
    static func value(context: GlucoseForecastMLContext,
                      examples: [GlucoseForecastMLReplayExample]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hasher = SHA256()
        hasher.update(data: Data("glucose-forecast-training-snapshot-v1".utf8))
        func updateLength(_ count: Int) {
            var encoded = UInt64(count).bigEndian
            withUnsafeBytes(of: &encoded) { hasher.update(bufferPointer: $0) }
        }
        let encodedContext = try encoder.encode(context)
        updateLength(encodedContext.count)
        hasher.update(data: encodedContext)
        updateLength(examples.count)
        // Each length-framed row is released before encoding the next one.
        // Annual histories therefore do not need a second whole-history copy
        // merely to verify the persisted training session's identity.
        for example in examples {
            let encoded = try encoder.encode(example)
            updateLength(encoded.count)
            hasher.update(data: encoded)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

final class GlucoseForecastMLPreparedHistoryStore: @unchecked Sendable {
    struct AutomaticAttempt: Codable {
        let context: GlucoseForecastMLContext
        let attemptedAt: Date
        let completedAt: Date?
    }
    private let lock = NSLock()
    let directory: URL
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask)[0]
        .appendingPathComponent("GlucoseForecastML/prepared", isDirectory: true)) {
        self.directory = directory
    }
    private var snapshotURL: URL { directory.appendingPathComponent("history.json") }
    private var attemptURL: URL { directory.appendingPathComponent("automatic-attempt.json") }

    func save(_ snapshot: GlucoseForecastMLPreparedHistory) throws {
        lock.lock(); defer { lock.unlock() }
        try write(snapshot, to: snapshotURL)
    }
    func load(context: GlucoseForecastMLContext, at now: Date) -> GlucoseForecastMLPreparedHistory? {
        lock.lock(); defer { lock.unlock() }
        guard let snapshot: GlucoseForecastMLPreparedHistory = read(snapshotURL),
              snapshot.isUsable(context: context, at: now) else { return nil }
        return snapshot
    }
    func remove(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard let snapshot: GlucoseForecastMLPreparedHistory = read(snapshotURL),
              snapshot.id == id else { return }
        try? FileManager.default.removeItem(at: snapshotURL)
    }
    func nextAutomaticAttempt(context: GlucoseForecastMLContext, at now: Date) -> Date {
        lock.lock(); defer { lock.unlock() }
        guard let attempt: AutomaticAttempt = read(attemptURL), attempt.context == context else { return now }
        return max(now, attempt.completedAt.map {
            $0.addingTimeInterval(GlucoseForecastMLChronology.modelAgeLimit)
        } ?? attempt.attemptedAt.addingTimeInterval(24 * 3600))
    }
    /// A completed weekly attempt can prepare tomorrow's due input one day early;
    /// failed preparation gets the full durable 24-hour retry delay.
    func nextPreparationDate(context: GlucoseForecastMLContext, at now: Date) -> Date {
        lock.lock(); defer { lock.unlock() }
        guard let attempt: AutomaticAttempt = read(attemptURL), attempt.context == context else { return now }
        return max(now, attempt.completedAt.map {
            $0.addingTimeInterval(GlucoseForecastMLChronology.modelAgeLimit - 24 * 3600)
        } ?? attempt.attemptedAt.addingTimeInterval(24 * 3600))
    }
    func recordAttempt(context: GlucoseForecastMLContext, at date: Date, completed: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        try write(AutomaticAttempt(context: context, attemptedAt: date,
                                   completedAt: completed ? date : nil), to: attemptURL)
    }
    private func read<T: Decodable>(_ url: URL) -> T? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 128 * 1024 * 1024,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try GlucoseForecastMLStoragePolicy.secureDirectory(directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 128 * 1024 * 1024 else { throw GlucoseForecastMLTrainingFailure.io }
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        var protectedURL = url
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try protectedURL.setResourceValues(resources)
    }
}

/// A scheduler-granted runtime lease, never a generic foreground override.
final class GlucoseForecastMLBackgroundRun: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
