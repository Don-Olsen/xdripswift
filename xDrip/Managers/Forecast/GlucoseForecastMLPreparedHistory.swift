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
    static let maximumEncodedBytes = 128 * 1024 * 1024
    static let diagnosticDefaultsKey = "GlucoseForecastMLPreparedHistory.latestSaveDiagnostic.v1"
    private static let maximumDiagnosticBytes = 16 * 1024

    enum SaveStage: String, Codable, Sendable {
        case directory, encoding, sizeCheck, writing, backupExclusion

        fileprivate var displayName: String {
            switch self {
            case .directory: return "klargøring af mappe"
            case .encoding: return "kodning"
            case .sizeCheck: return "størrelseskontrol"
            case .writing: return "skrivning"
            case .backupExclusion: return "udelukkelse fra sikkerhedskopi"
            }
        }
    }

    enum SaveErrorDomain: String, Codable, Sendable {
        case cocoa = "NSCocoaErrorDomain"
        case posix = "NSPOSIXErrorDomain"
        case osStatus = "NSOSStatusErrorDomain"
        case mach = "NSMachErrorDomain"
        case other
    }

    /// Technical metadata only. Never retain the Error, userInfo, description,
    /// source identity, file path or any part of the training rows.
    struct SaveDiagnostic: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let occurredAt: Date
        let appBuild: String
        let stage: SaveStage
        let encodedBytes: Int?
        let maximumBytes: Int
        let errorDomain: SaveErrorDomain?
        let errorCode: Int?

        init(stage: SaveStage, encodedBytes: Int?, error: Error,
             occurredAt: Date = .now) {
            schemaVersion = 1
            self.occurredAt = occurredAt
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            appBuild = build.flatMap { Self.isValidBuild($0) ? $0 : nil } ?? "unknown"
            self.stage = stage
            self.encodedBytes = encodedBytes
            maximumBytes = GlucoseForecastMLPreparedHistoryStore.maximumEncodedBytes
            if stage == .sizeCheck, let failure = error as? GlucoseForecastMLTrainingFailure,
               failure == .io {
                errorDomain = nil
                errorCode = nil
            } else {
                let details = error as NSError
                errorDomain = SaveErrorDomain(rawValue: details.domain) ?? .other
                errorCode = details.code
            }
        }

        fileprivate var isValid: Bool {
            schemaVersion == 1 && occurredAt.timeIntervalSinceReferenceDate.isFinite
                && Self.isValidBuild(appBuild)
                && maximumBytes == GlucoseForecastMLPreparedHistoryStore.maximumEncodedBytes
                && (encodedBytes.map { $0 >= 0 } ?? true)
        }

        private static func isValidBuild(_ build: String) -> Bool {
            build == "unknown" || (!build.isEmpty && build.count <= 32
                && build.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 })
        }

        var summaryText: String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "da_DK")
            formatter.dateStyle = .short
            formatter.timeStyle = .medium
            var lines = ["Seneste gemmefejl: \(formatter.string(from: occurredAt)) · build \(appBuild)",
                         "Trin: \(stage.displayName)."]
            if let encodedBytes {
                lines.append("Kodet størrelse: \(encodedBytes) bytes. Grænse: \(maximumBytes) bytes (128 MiB).")
            } else {
                lines.append("Kodet størrelse endnu ikke kendt. Grænse: \(maximumBytes) bytes (128 MiB).")
            }
            if let errorDomain, let errorCode {
                let domain = errorDomain == .other ? "andet fejldomæne" : errorDomain.rawValue
                lines.append("Teknisk fejl: \(domain), kode \(errorCode).")
            }
            return lines.joined(separator: "\n")
        }
    }

    struct SaveFailure: Error, Sendable {
        let diagnostic: SaveDiagnostic
    }

    struct AutomaticAttempt: Codable {
        let context: GlucoseForecastMLContext
        let attemptedAt: Date
        let completedAt: Date?
    }
    // Keep each file's operations serialized without making foreground cooldown
    // checks wait for history encoding, decoding or validation.
    private let snapshotLock: NSLock
    private let attemptLock: NSLock
    private let diagnosticLock = NSLock()
    private let diagnosticDefaults: UserDefaults
    private var cachedSaveDiagnostic: SaveDiagnostic?
    let directory: URL
    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory,
                                                   in: .userDomainMask)[0]
        .appendingPathComponent("GlucoseForecastML/prepared", isDirectory: true),
         snapshotLock: NSLock = NSLock(), attemptLock: NSLock = NSLock(),
         diagnosticDefaults: UserDefaults = .standard) {
        self.directory = directory
        self.snapshotLock = snapshotLock
        self.attemptLock = attemptLock
        self.diagnosticDefaults = diagnosticDefaults
        if let data = diagnosticDefaults.data(forKey: Self.diagnosticDefaultsKey),
           data.count <= Self.maximumDiagnosticBytes,
           let diagnostic = try? JSONDecoder().decode(SaveDiagnostic.self, from: data),
           diagnostic.isValid {
            cachedSaveDiagnostic = diagnostic
        }
    }
    private var snapshotURL: URL { directory.appendingPathComponent("history.json") }
    private var attemptURL: URL { directory.appendingPathComponent("automatic-attempt.json") }

    func save(_ snapshot: GlucoseForecastMLPreparedHistory) throws {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        var stage = SaveStage.directory
        var encodedBytes: Int?
        do {
            try write(snapshot, to: snapshotURL) { currentStage, size in
                stage = currentStage
                encodedBytes = size
            }
            publishSaveDiagnostic(nil)
        } catch {
            // Keep cancellation's existing meaning for the coordinator.
            if error is CancellationError { throw error }
            let diagnostic = SaveDiagnostic(stage: stage, encodedBytes: encodedBytes, error: error)
            publishSaveDiagnostic(diagnostic)
            throw SaveFailure(diagnostic: diagnostic)
        }
    }

    /// UI access never waits for history encoding, decoding or the snapshot lock.
    func latestSaveDiagnostic() -> SaveDiagnostic? {
        diagnosticLock.lock(); defer { diagnosticLock.unlock() }
        return cachedSaveDiagnostic
    }

    private func publishSaveDiagnostic(_ diagnostic: SaveDiagnostic?) {
        diagnosticLock.lock()
        cachedSaveDiagnostic = diagnostic
        diagnosticLock.unlock()
        // Best-effort metadata persistence cannot turn a successful save into a
        // failure, or replace the actual storage error. No forced synchronization.
        if let diagnostic {
            if let data = try? JSONEncoder().encode(diagnostic), data.count <= Self.maximumDiagnosticBytes {
                diagnosticDefaults.set(data, forKey: Self.diagnosticDefaultsKey)
            }
        } else {
            diagnosticDefaults.removeObject(forKey: Self.diagnosticDefaultsKey)
        }
    }

    func load(context: GlucoseForecastMLContext, at now: Date) -> GlucoseForecastMLPreparedHistory? {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        guard let snapshot: GlucoseForecastMLPreparedHistory = read(snapshotURL),
              snapshot.isUsable(context: context, at: now) else { return nil }
        return snapshot
    }
    func remove(id: UUID) {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        guard let snapshot: GlucoseForecastMLPreparedHistory = read(snapshotURL),
              snapshot.id == id else { return }
        try? FileManager.default.removeItem(at: snapshotURL)
    }
    func nextAutomaticAttempt(context: GlucoseForecastMLContext, at now: Date) -> Date {
        attemptLock.lock(); defer { attemptLock.unlock() }
        guard let attempt: AutomaticAttempt = read(attemptURL), attempt.context == context else { return now }
        return max(now, attempt.completedAt.map {
            $0.addingTimeInterval(GlucoseForecastMLChronology.modelAgeLimit)
        } ?? attempt.attemptedAt.addingTimeInterval(24 * 3600))
    }
    /// A completed weekly attempt can prepare tomorrow's due input one day early;
    /// failed preparation gets the full durable 24-hour retry delay.
    func nextPreparationDate(context: GlucoseForecastMLContext, at now: Date) -> Date {
        attemptLock.lock(); defer { attemptLock.unlock() }
        guard let attempt: AutomaticAttempt = read(attemptURL), attempt.context == context else { return now }
        return max(now, attempt.completedAt.map {
            $0.addingTimeInterval(GlucoseForecastMLChronology.modelAgeLimit - 24 * 3600)
        } ?? attempt.attemptedAt.addingTimeInterval(24 * 3600))
    }
    func recordAttempt(context: GlucoseForecastMLContext, at date: Date, completed: Bool) throws {
        attemptLock.lock(); defer { attemptLock.unlock() }
        try write(AutomaticAttempt(context: context, attemptedAt: date,
                                   completedAt: completed ? date : nil), to: attemptURL)
    }
    /// Release only the preparation that was interrupted by leaving the foreground.
    /// A failure, newer attempt or completed run keeps its durable retry deadline.
    func removeInterruptedAttempt(context: GlucoseForecastMLContext, at date: Date) throws {
        attemptLock.lock(); defer { attemptLock.unlock() }
        guard let attempt: AutomaticAttempt = read(attemptURL), attempt.context == context,
              attempt.attemptedAt == date, attempt.completedAt == nil else { return }
        try FileManager.default.removeItem(at: attemptURL)
    }

    private func read<T: Decodable>(_ url: URL) -> T? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumEncodedBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    private func write<T: Encodable>(_ value: T, to url: URL,
                                      stage: ((SaveStage, Int?) -> Void)? = nil) throws {
        stage?(.directory, nil)
        try GlucoseForecastMLStoragePolicy.secureDirectory(directory)
        stage?(.encoding, nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        stage?(.sizeCheck, data.count)
        guard data.count <= Self.maximumEncodedBytes else { throw GlucoseForecastMLTrainingFailure.io }
        stage?(.writing, data.count)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        stage?(.backupExclusion, data.count)
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
