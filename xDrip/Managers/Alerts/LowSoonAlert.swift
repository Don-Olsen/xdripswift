import Foundation
import os

/// An engine prediction is advisory. It never substitutes for the existing measured-low alarms.
enum LowSoonAlertPolicy {
    static let currentMinimumMgdl = 3.9 / ConstantsBloodGlucose.mgDlToMmoll
    static let predictedLimitMgdl = 4.4 / ConstantsBloodGlucose.mgDlToMmoll
    static let minimumInterval: TimeInterval = 30 * 60

    struct ValidatedPrediction {
        let currentMgdl: Double
        let predicted30Mgdl: Double
        let activeInsulinUnits: Double
    }

    /// A background result must still belong to the newest saved sensor reading when it is
    /// consumed. This pure gate prevents a delayed worker result from raising a stale warning.
    static func validatedPrediction(from outcome: GlucoseForecastSafetyOutcome,
                                    expectedReferenceDate: Date, expectedSensorID: String?,
                                    expectedGlucoseMgdl: Double,
                                    at now: Date) -> ValidatedPrediction? {
        let result = outcome.result
        guard result.reason == nil,
              result.referenceDate == expectedReferenceDate,
              result.referenceSensorID == expectedSensorID,
              (0...330).contains(now.timeIntervalSince(expectedReferenceDate)),
              let current = outcome.referenceGlucoseMgdl,
              current.isFinite, current > 0, current == expectedGlucoseMgdl,
              let iob = outcome.activeInsulinUnits,
              iob.isFinite, iob >= 0,
              let predicted = result.value(atMinutes: 30), predicted.isFinite else { return nil }
        return ValidatedPrediction(currentMgdl: current, predicted30Mgdl: predicted,
                                   activeInsulinUnits: iob)
    }

    static func condition(currentMgdl: Double, predicted30Mgdl: Double) -> Bool {
        currentMgdl.isFinite && predicted30Mgdl.isFinite &&
            currentMgdl >= currentMinimumMgdl && predicted30Mgdl < predictedLimitMgdl
    }

    static func maySchedule(lastScheduled: Date?, at now: Date) -> Bool {
        guard let lastScheduled else { return true }
        // A backwards clock change must not bypass the thirty-minute cap.
        return now.timeIntervalSince(lastScheduled) >= minimumInterval
    }
}

/// Shared read-only status used when presenting an ML curve near a predicted low.
enum LowSoonAlertState {
    static let lastScheduledDefaultsKey = "lowSoonLastScheduledAt"

    static func isActive(at now: Date = .now, defaults: UserDefaults = .standard) -> Bool {
        guard let last = defaults.object(forKey: lastScheduledDefaultsKey) as? Date else { return false }
        let age = now.timeIntervalSince(last)
        return age >= 0 && age < LowSoonAlertPolicy.minimumInterval
    }
}

/// Prospective local evidence. `warningRequested` proves only that iOS accepted the request;
/// it cannot prove that an alert appeared on the phone or paired Watch.
struct LowSoonEvaluationRecord: Codable, Sendable {
    enum Status: String, Codable, Sendable {
        case unavailable
        case noWarning
        case warningRequested
        case warningSchedulingFailed
        case suppressed
    }

    let referenceDate: Date?
    let computedAt: Date
    let currentMgdl: Double?
    let predicted30Mgdl: Double?
    let iobUnits: Double?
    let sensorID: String?
    let status: Status
    let detail: String?
}

/// Small day-partitioned JSONL journal, separate from the Home-only forecast evidence log.
/// Work is serialized off the main thread and retains only the last 31 UTC days.
// All mutable file operations and reads are serialized on `queue`; its dependencies are fixed
// after construction. This is safe to share across background alert and Statistics workers.
final class LowSoonEvaluationJournal: @unchecked Sendable {
    static let shared = LowSoonEvaluationJournal()

    private let queue = DispatchQueue(label: "low.soon.evaluation.journal", qos: .utility)
    private let directory: URL
    private let fileManager: FileManager
    private let log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryAlertManager)

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.directory = directory ?? fileManager.urls(for: .applicationSupportDirectory,
                                                        in: .userDomainMask)[0]
            .appendingPathComponent("LowSoonEvaluations", isDirectory: true)
    }

    func enqueue(_ record: LowSoonEvaluationRecord) {
        queue.async { [self] in
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent(Self.dayName(for: record.computedAt) + ".jsonl")
                let encoded = try JSONEncoder().encode(record) + Data([0x0A])
                if !fileManager.fileExists(atPath: url.path) {
                    try encoded.write(to: url, options: .atomic)
                    try fileManager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: url.path)
                } else {
                    let handle = try FileHandle(forUpdating: url)
                    defer { try? handle.close() }
                    let size = try handle.seekToEnd()
                    if size > 0 {
                        try handle.seek(toOffset: size - 1)
                        let finalByte = try handle.read(upToCount: 1)
                        try handle.seekToEnd()
                        if finalByte != Data([0x0A]) {
                            // A killed process may leave an unfinished JSONL tail. Keep its
                            // evidence, but separate it from the next valid record.
                            try handle.write(contentsOf: Data([0x0A]))
                        }
                    }
                    try handle.write(contentsOf: encoded)
                }
                try prune(before: record.computedAt.addingTimeInterval(-31 * 24 * 60 * 60))
            } catch {
                // Health values never enter system logs, even if the local evidence file fails.
                trace("Could not persist low-soon evaluation (domain=%{public}@ code=%{public}d)",
                      log: log, category: ConstantsLog.categoryAlertManager, type: .error,
                      (error as NSError).domain, (error as NSError).code)
            }
        }
    }

    func records(from start: Date, to end: Date) async -> [LowSoonEvaluationRecord] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard start <= end,
                      let files = try? fileManager.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: nil)
                else {
                    continuation.resume(returning: [])
                    return
                }
                let decoder = JSONDecoder()
                let records = files.filter { $0.pathExtension == "jsonl" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    .flatMap { url -> [LowSoonEvaluationRecord] in
                        guard let data = try? Data(contentsOf: url) else { return [] }
                        // An interrupted final line is ignored; earlier complete lines survive.
                        return data.split(separator: 0x0A).compactMap { line in
                            try? decoder.decode(LowSoonEvaluationRecord.self, from: Data(line))
                        }
                    }
                    .filter { $0.computedAt >= start && $0.computedAt <= end }
                continuation.resume(returning: records)
            }
        }
    }

    private func prune(before date: Date) throws {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        let cutoff = Self.dayName(for: date)
        for url in files where url.pathExtension == "jsonl" {
            let stem = url.deletingPathExtension().lastPathComponent
            guard stem.count == 8, stem.allSatisfy(\.isNumber), stem < cutoff else { continue }
            try fileManager.removeItem(at: url)
        }
    }

    private static func dayName(for date: Date) -> String {
        let components = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        return String(format: "%04d%02d%02d", components.year ?? 0, components.month ?? 0,
                      components.day ?? 0)
    }
}
