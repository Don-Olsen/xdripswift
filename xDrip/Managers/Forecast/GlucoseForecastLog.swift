// Local, prospective evidence only. Never feeds glucose storage, alarms or therapy.
import Foundation
import CryptoKit
import os

struct GlucoseForecastLogContext: Sendable {
    let appVersion: String
    let appBuild: String
    let sourceIdentity: String
    let sensorIdentity: String?
    let knownReference: GlucoseForecastSample?
    let computedAt: Date
    let horizonMinutes: Int
    let insulinModel: String?
    let treatmentWindowStart: Date?
    let treatmentWindowEnd: Date?

    init(appVersion: String, appBuild: String, sourceIdentity: String,
         sensorIdentity: String? = nil, knownReference: GlucoseForecastSample? = nil,
         computedAt: Date, horizonMinutes: Int, insulinModel: String? = nil,
         treatmentWindowStart: Date? = nil, treatmentWindowEnd: Date? = nil) {
        self.appVersion = appVersion; self.appBuild = appBuild
        self.sourceIdentity = sourceIdentity; self.sensorIdentity = sensorIdentity
        self.knownReference = knownReference; self.computedAt = computedAt
        self.horizonMinutes = horizonMinutes; self.insulinModel = insulinModel
        self.treatmentWindowStart = treatmentWindowStart; self.treatmentWindowEnd = treatmentWindowEnd
    }
}

/// Value-only snapshot, constructed at completion. File writing never reads defaults,
/// Core Data or mutable forecast state. JSON dates and the fingerprint use UTC.
struct GlucoseForecastLogSnapshot: Codable, Sendable {
    enum RecordType: String, Codable, Sendable { case forecast, unavailable }
    struct Point: Codable, Sendable { let offsetMinutes: Int; let glucoseMgdl: Double }
    struct Sample: Codable, Sendable { let date: Date; let glucoseMgdl: Double; let sensorIdentity: String? }
    struct Treatment: Codable, Sendable {
        let date: Date
        let amount: Double
        let kind: String
        let unit: String
        let carbohydrateDurationMinutes: Double?
    }
    struct Inputs: Codable, Sendable {
        let calculationDate: Date
        let glucose: [Sample]
        let treatments: [Treatment]
    }
    struct Parameters: Codable, Sendable {
        let sensitivityMgdlPerUnit: Double?
        let carbohydrateRatioGramsPerUnit: Double?
        let insulinModel: String?
        let insulinPeakMinutes: Double?
        let insulinDurationMinutes: Double?
        let carbohydrateDurationMinutes: Double?
    }
    struct TreatmentSummary: Codable, Sendable {
        let windowStart: Date?
        let windowEnd: Date?
        let bolusCount: Int?
        let bolusUnits: Double?
        let carbohydrateCount: Int?
        let carbohydrateGrams: Double?
    }
    let schemaVersion: Int
    let engineVersion: String
    let recordType: RecordType
    let appVersion: String
    let appBuild: String
    let sourceIdentity: String
    let sensorIdentity: String?
    let referenceIdentity: String?
    let referenceDate: Date?
    let computedAt: Date
    let horizonMinutes: Int
    let referenceGlucoseMgdl: Double?
    let points: [Point]
    let reason: String?
    let parameters: Parameters
    let constants: GlucoseForecastEngineConfiguration
    let treatmentSummary: TreatmentSummary
    let inputs: Inputs?
    let inputFingerprint: String?

    static func make(input: GlucoseForecastInput?, result: GlucoseForecastResult,
                     context: GlucoseForecastLogContext) throws -> Self {
        let config = GlucoseForecastEngine.configuration
        let referenceDate = result.referenceDate ?? context.knownReference?.date
        let referenceSample = context.knownReference ?? input?.glucose.last(where: { $0.date == referenceDate })
        let sensorIdentity = context.sensorIdentity ?? result.referenceSensorID ?? referenceSample?.sensorID
        let referenceIdentity = try referenceDate.map {
            try digest([context.sourceIdentity, sensorIdentity ?? "", isoDate($0)])
        }
        let valid = result.reason == nil && !result.points.isEmpty
        if valid {
            guard let input, let referenceDate, referenceIdentity != nil,
                  !context.sourceIdentity.isEmpty,
                  input.horizonMinutes == context.horizonMinutes,
                  result.points.count == context.horizonMinutes / Int(config.integrationStepMinutes) + 1,
                  result.points.enumerated().allSatisfy({ index, point in
                      point.glucoseMgdl.isFinite &&
                      abs(point.date.timeIntervalSince(referenceDate) - Double(index) * config.integrationStepMinutes * 60) < 0.001
                  }) else { throw GlucoseForecastLogFailure.invalidSnapshot }
        }
        // Invalid/unavailable inputs must remain diagnosable as missing fields, not
        // become zero or make JSON serialization fail on NaN/infinity.
        func finite(_ value: Double?) -> Double? { value.flatMap { $0.isFinite ? $0 : nil } }
        let parameters = Parameters(
            sensitivityMgdlPerUnit: finite(input?.sensitivityMgdlPerUnit),
            carbohydrateRatioGramsPerUnit: finite(input?.carbohydrateRatioGramsPerUnit),
            insulinModel: context.insulinModel,
            insulinPeakMinutes: finite(input?.settings.insulinPeak),
            insulinDurationMinutes: finite(input?.settings.insulinDuration),
            carbohydrateDurationMinutes: finite(input?.settings.carbDuration))
        // Mirror only the engine's explicit input selection. Preserve actual sample timing,
        // therapy amounts and duplicate doses, rather than reconstructing them during export.
        let inputs: Inputs? = input.map { value in
            let reference = referenceDate
            let cutoff = reference?.addingTimeInterval(-config.historyWindowMinutes * 60 - config.cadenceToleranceSeconds)
            var samples = [Sample]()
            for sample in value.glucose.sorted(by: { $0.date < $1.date }) where
                sample.date <= value.now && sample.glucoseMgdl.isFinite &&
                (config.minimumGlucoseMgdl...config.maximumGlucoseMgdl).contains(sample.glucoseMgdl) &&
                (cutoff == nil || sample.date >= cutoff!) {
                let copy = Sample(date: sample.date, glucoseMgdl: sample.glucoseMgdl, sensorIdentity: sample.sensorID)
                if samples.last?.date == sample.date { samples[samples.count - 1] = copy }
                else { samples.append(copy) }
            }
            let treatments = value.treatments.filter {
                $0.amount.isFinite && $0.amount > 0 && reference != nil && $0.date <= reference!
            }.map { Treatment(date: $0.date, amount: $0.amount,
                              kind: $0.isIOB ? "bolus" : "carbohydrate",
                              unit: $0.isIOB ? "U" : "g",
                              carbohydrateDurationMinutes: $0.isIOB ? nil :
                                  $0.carbohydrateDuration(or: value.settings.carbDuration)) }
                .sorted { a, b in
                    if a.date != b.date { return a.date < b.date }
                    if a.kind != b.kind { return a.kind < b.kind }
                    return a.amount < b.amount
                }
            return Inputs(calculationDate: value.now, glucose: samples, treatments: treatments)
        }
        let bolus = inputs?.treatments.filter { $0.kind == "bolus" }
        let carbs = inputs?.treatments.filter { $0.kind == "carbohydrate" }
        let summary = TreatmentSummary(windowStart: context.treatmentWindowStart, windowEnd: context.treatmentWindowEnd,
            bolusCount: bolus?.count, bolusUnits: bolus?.reduce(0) { $0 + $1.amount },
            carbohydrateCount: carbs?.count, carbohydrateGrams: carbs?.reduce(0) { $0 + $1.amount })
        struct Fingerprint: Encodable {
            let source: String; let sensor: String?; let horizon: Int
            let inputs: Inputs; let parameters: Parameters; let constants: GlucoseForecastEngineConfiguration
        }
        let fingerprint = try inputs.map { try digest(Fingerprint(source: context.sourceIdentity,
            sensor: sensorIdentity, horizon: context.horizonMinutes, inputs: $0, parameters: parameters, constants: config)) }
        return Self(schemaVersion: 2, engineVersion: GlucoseForecastEngine.engineVersion,
            recordType: valid ? .forecast : .unavailable,
            appVersion: context.appVersion, appBuild: context.appBuild,
            sourceIdentity: context.sourceIdentity, sensorIdentity: sensorIdentity,
            referenceIdentity: referenceIdentity, referenceDate: referenceDate,
            computedAt: context.computedAt, horizonMinutes: context.horizonMinutes,
            referenceGlucoseMgdl: finite(valid ? result.points.first?.glucoseMgdl : referenceSample?.glucoseMgdl),
            points: valid ? result.points.enumerated().map {
                Point(offsetMinutes: $0.offset * Int(config.integrationStepMinutes), glucoseMgdl: $0.element.glucoseMgdl)
            } : [], reason: valid ? nil : (result.reason?.rawValue ?? "dataUnavailable"),
            parameters: parameters, constants: config, treatmentSummary: summary,
            inputs: inputs, inputFingerprint: fingerprint)
    }

    private static func digest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try encoder().encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer(); try container.encode(isoDate(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(text) else { throw GlucoseForecastLogFailure.invalidSnapshot }
            return date
        }
        return decoder
    }

    static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    /// Valid dedup deliberately excludes settings and computedAt. First finished forecast
    /// wins permanently for this reference, horizon and engine, even across app restarts.
    var deduplicationKey: String {
        let base = [recordType.rawValue, sourceIdentity, sensorIdentity ?? "", referenceIdentity ?? "none",
                    String(horizonMinutes), engineVersion].joined(separator: "|")
        if recordType == .forecast { return base }
        // Repeated identical failures are retained at most once per ten-minute UTC bucket.
        return base + "|" + (reason ?? "") + "|" + String(Int(computedAt.timeIntervalSince1970 / 600))
    }
}

enum GlucoseForecastLogFailure: String, Error { case invalidSnapshot, io, corruptRecord, oversizedRecord }

/// Serial, bounded-memory IO. One daily file is indexed lazily; at most two indexes
/// are kept. A normal minute append never re-reads the previous 400 days.
final class GlucoseForecastLog: @unchecked Sendable {
    static let shared = GlucoseForecastLog(directory: FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("GlucoseForecastLog", isDirectory: true))
    #if os(iOS) || os(watchOS)
    static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication
    #endif
    static let retentionDays = 400
    static let maximumLineBytes = 4 * 1024 * 1024
    private let directory: URL
    private let worker = DispatchQueue(label: "glucose.forecast.log", qos: .utility)
    private let clock: () -> Date
    private let diagnostic: (GlucoseForecastLogFailure) -> Void
    private var indexes = [String: Set<String>]()
    private var indexOrder = [String]()
    private var lastCleanupDay: String?
    private var lastDiagnostic: GlucoseForecastLogFailure?

    init(directory: URL, clock: @escaping () -> Date = Date.init,
         diagnostic: @escaping (GlucoseForecastLogFailure) -> Void = { failure in
             // Only a fixed category: never health data, filesystem paths, raw NSError or record contents.
             Logger(subsystem: "xDrip", category: "ForecastLog").error("Local forecast evidence failure: \(failure.rawValue, privacy: .public)")
         }) {
        self.directory = directory; self.clock = clock; self.diagnostic = diagnostic
    }

    func enqueue(_ snapshot: GlucoseForecastLogSnapshot) {
        worker.async { [self] in
            do { try append(snapshot); lastDiagnostic = nil }
            catch { indexes.removeAll(); indexOrder.removeAll(); report(error as? GlucoseForecastLogFailure ?? .io) }
        }
    }

    func captureFailure() { worker.async { [self] in report(.invalidSnapshot) } }

    /// A separate user-initiated CSV copy. Completion is on main, with no history
    /// accumulation in memory and no transmission by this component.
    func exportCSV(completion: @escaping (Result<URL, Error>) -> Void) {
        worker.async { [self] in
            let exportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("xdrip-forecast-exports", isDirectory: true)
            let destination = exportDirectory.appendingPathComponent("xdrip-forecast-\(UUID().uuidString).csv")
            let outcome: Result<URL, Error>
            do {
                try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
                try protect(exportDirectory, backedUp: false)
                for file in try FileManager.default.contentsOfDirectory(at: exportDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) where file.pathExtension == "csv" && file.lastPathComponent.hasPrefix("xdrip-forecast-") {
                    if let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                       clock().timeIntervalSince(modified) > 24 * 60 * 60 { try FileManager.default.removeItem(at: file) }
                }
                try export(to: destination); outcome = .success(destination)
            }
            catch { report(.io); outcome = .failure(GlucoseForecastLogFailure.io) }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    // Internal synchronization seams for deterministic unit tests only. Production
    // forecast and UI paths exclusively use enqueue/exportCSV above.
    func waitUntilIdle() { worker.sync {} }
    func exportCSVForTesting(to url: URL) throws { try worker.sync { try export(to: url) } }

    private func report(_ failure: GlucoseForecastLogFailure) {
        if failure != lastDiagnostic { diagnostic(failure); lastDiagnostic = failure }
    }

    private static func day(_ date: Date) -> String { String(GlucoseForecastLogSnapshot.isoDate(date).prefix(10)) }
    private static func dayDate(_ name: String) -> Date? {
        guard name.count == 16, name.hasSuffix(".jsonl") else { return nil }
        return GlucoseForecastLogSnapshot.parseDate(String(name.prefix(10)) + "T00:00:00.000Z")
    }
    private func earliestDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: calendar.startOfDay(for: date))!
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try protect(directory, backedUp: true)
        let now = clock(); let today = Self.day(now)
        if lastCleanupDay != today {
            for file in try dailyFiles() {
                if let day = Self.dayDate(file.lastPathComponent), day < earliestDay(now) {
                    try FileManager.default.removeItem(at: file)
                    indexes.removeValue(forKey: file.lastPathComponent)
                    indexOrder.removeAll { $0 == file.lastPathComponent }
                }
            }
            lastCleanupDay = today
        }
    }

    private func dailyFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { file in
                guard Self.dayDate(file.lastPathComponent) != nil else { return false }
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values.isRegularFile == true && values.isSymbolicLink != true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func protect(_ url: URL, backedUp: Bool) throws {
        #if os(iOS) || os(watchOS)
        try FileManager.default.setAttributes([.protectionKey: Self.fileProtection],
                                              ofItemAtPath: url.path)
        #endif
        var mutable = url
        var values = URLResourceValues(); values.isExcludedFromBackup = !backedUp
        try mutable.setResourceValues(values)
    }

    private func append(_ snapshot: GlucoseForecastLogSnapshot) throws {
        try prepare()
        // Reference-day partitioning makes valid dedup stable even when computedAt crosses
        // midnight/restarts. Failures with no usable reference are partitioned by attempt day.
        let partitionDate = snapshot.recordType == .forecast ? snapshot.referenceDate ?? snapshot.computedAt : snapshot.computedAt
        guard partitionDate >= earliestDay(clock()) else { return }
        let name = Self.day(partitionDate) + ".jsonl"
        let url = directory.appendingPathComponent(name)
        if indexes[name] == nil {
            var keys = Set<String>()
            if FileManager.default.fileExists(atPath: url.path) {
                try recoverTail(url)
                try readLines(url) { [self] line in
                    do { keys.insert(try GlucoseForecastLogSnapshot.decoder().decode(GlucoseForecastLogSnapshot.self, from: line).deduplicationKey) }
                    catch { report(.corruptRecord) }
                }
            }
            indexes[name] = keys; indexOrder.append(name)
            if indexOrder.count > 2 { indexes.removeValue(forKey: indexOrder.removeFirst()) }
        }
        guard indexes[name]?.contains(snapshot.deduplicationKey) != true else { return }
        var line = try GlucoseForecastLogSnapshot.encoder().encode(snapshot)
        // xDrip has a generic Data.append(integer) overload; an untyped 10 writes
        // all eight bytes of Int. Append exactly one JSON Lines delimiter.
        line.append(contentsOf: [UInt8(10)])
        guard line.count <= Self.maximumLineBytes else { throw GlucoseForecastLogFailure.oversizedRecord }
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw GlucoseForecastLogFailure.io }
        }
        try protect(url, backedUp: true)
        // Recover an interrupted previous write even within the same process after an IO error.
        try recoverTail(url)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: line); try handle.synchronize()
        indexes[name]?.insert(snapshot.deduplicationKey)
    }

    /// Only the unfinished tail can be truncated. All newline-terminated records remain
    /// byte-for-byte, even if a particular old schema cannot be decoded by this version.
    private func recoverTail(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url); defer { try? handle.close() }
        let size = try handle.seekToEnd(); guard size > 0 else { return }
        try handle.seek(toOffset: size - 1)
        if try handle.read(upToCount: 1) == Data([10]) { return }
        var offset = size; var suffix = Data()
        while offset > 0 && suffix.count <= Self.maximumLineBytes {
            let count = min(UInt64(64 * 1024), offset); offset -= count
            try handle.seek(toOffset: offset)
            suffix.insert(contentsOf: try handle.read(upToCount: Int(count)) ?? Data(), at: 0)
            if let index = suffix.lastIndex(of: 10) {
                let tail = suffix.suffix(from: suffix.index(after: index))
                guard !tail.isEmpty else { return }
                if (try? JSONSerialization.jsonObject(with: Data(tail))) != nil {
                    try handle.seekToEnd(); try handle.write(contentsOf: Data([10]))
                } else { try handle.truncate(atOffset: size - UInt64(tail.count)); report(.corruptRecord) }
                return
            }
        }
        guard suffix.count <= Self.maximumLineBytes else { throw GlucoseForecastLogFailure.oversizedRecord }
        if (try? JSONSerialization.jsonObject(with: suffix)) != nil {
            try handle.seekToEnd(); try handle.write(contentsOf: Data([10]))
        } else { try handle.truncate(atOffset: 0); report(.corruptRecord) }
    }

    private func readLines(_ url: URL, body: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var pending = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let end = pending.firstIndex(of: 10) {
                let line = Data(pending[..<end]); pending.removeSubrange(...end)
                if !line.isEmpty { try body(line) }
            }
            guard pending.count <= Self.maximumLineBytes else { throw GlucoseForecastLogFailure.oversizedRecord }
        }
        if !pending.isEmpty {
            // Export can read a complete final JSON record even if its newline was not yet
            // written. Partial data is skipped diagnostically, never merged into prior data.
            if (try? JSONSerialization.jsonObject(with: pending)) != nil {
                try body(pending)
            } else { report(.corruptRecord) }
        }
    }

    private func export(to destination: URL) throws {
        try prepare()
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw GlucoseForecastLogFailure.io }
        try protect(destination, backedUp: false)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data((GlucoseForecastCSV.columns.joined(separator: ",") + "\r\n").utf8))
        do {
            for file in try dailyFiles() {
                try readLines(file) { [self] line in
                    let snapshot: GlucoseForecastLogSnapshot
                    do { snapshot = try GlucoseForecastLogSnapshot.decoder().decode(GlucoseForecastLogSnapshot.self, from: line) }
                    catch { report(.corruptRecord); return }
                    for row in try GlucoseForecastCSV.rows(snapshot) { try handle.write(contentsOf: Data(row.utf8)) }
                }
            }
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}

enum GlucoseForecastCSV {
    static let columns = ["schema_version", "record_type", "engine_version", "app_version", "app_build",
        "source_identity", "sensor_identity", "reference_identity", "reference_date_utc", "computed_at_utc",
        "horizon_minutes", "reference_glucose_mgdl", "offset_minutes", "prediction_mgdl", "reason",
        "isf_mgdl_per_unit", "carb_ratio_grams_per_unit", "insulin_model", "insulin_peak_minutes",
        "insulin_duration_minutes", "carb_duration_minutes", "treatment_window_start_utc", "treatment_window_end_utc",
        "bolus_count", "bolus_units", "carb_count", "carb_grams", "input_fingerprint", "engine_constants_json"]

    static func rows(_ snapshot: GlucoseForecastLogSnapshot) throws -> [String] {
        func number(_ value: Double?) -> String { value.flatMap { $0.isFinite ? String($0) : nil } ?? "" }
        func integer(_ value: Int?) -> String { value.map(String.init) ?? "" }
        func date(_ value: Date?) -> String { value.map(GlucoseForecastLogSnapshot.isoDate) ?? "" }
        let parameters = snapshot.parameters; let summary = snapshot.treatmentSummary
        let constants = String(decoding: try GlucoseForecastLogSnapshot.encoder().encode(snapshot.constants), as: UTF8.self)
        let points: [GlucoseForecastLogSnapshot.Point?] = snapshot.recordType == .forecast ? snapshot.points.map { Optional($0) } : [nil]
        return points.map { point in
            [String(snapshot.schemaVersion), snapshot.recordType.rawValue, snapshot.engineVersion, snapshot.appVersion,
             snapshot.appBuild, snapshot.sourceIdentity, snapshot.sensorIdentity ?? "", snapshot.referenceIdentity ?? "",
             date(snapshot.referenceDate), date(snapshot.computedAt), String(snapshot.horizonMinutes),
             number(snapshot.referenceGlucoseMgdl), integer(point?.offsetMinutes), number(point?.glucoseMgdl), snapshot.reason ?? "",
             number(parameters.sensitivityMgdlPerUnit), number(parameters.carbohydrateRatioGramsPerUnit), parameters.insulinModel ?? "",
             number(parameters.insulinPeakMinutes), number(parameters.insulinDurationMinutes), number(parameters.carbohydrateDurationMinutes),
             date(summary.windowStart), date(summary.windowEnd), integer(summary.bolusCount), number(summary.bolusUnits),
             integer(summary.carbohydrateCount), number(summary.carbohydrateGrams), snapshot.inputFingerprint ?? "", constants]
                .map(escape).joined(separator: ",") + "\r\n"
        }
    }

    static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
