// Local evidence only. This journal never changes therapy, forecasts or app settings.
import Foundation
import os

/// Capture on the calculation/registration path, before crossing the IO queue.
/// A registered event is submitted only after the existing treatment store verifies
/// its save. This journal is evidence, not another treatment store or receipt.
struct CarbohydrateAdviceEvidence: Codable, Equatable, Sendable {
    enum Event: String, Codable, Sendable { case assessed, registered }
    struct Point: Codable, Equatable, Sendable {
        let date: Date
        let glucoseMgdl: Double
    }

    let schemaVersion: Int
    let adviceVersion: String
    let recordID: String
    let event: Event
    let recordedAt: Date
    let referenceDate: Date?
    let engineVersion: String
    let sourceSignature: String?
    let treatmentRevision: Int?
    let glucoseMgdl: Double?
    let predictedMinimumMgdl: Double?
    let predictedMinimumDate: Date?
    let estimatedGrams: Double?
    let status: String
    let sensitivityMgdlPerUnit: Double?
    let carbohydrateRatioGramsPerUnit: Double?
    let fastAbsorptionMinutes: Double?
    let targetMgdl: Double?
    let treatmentID: String?
    let actualCarbohydrateGrams: Double?
    let treatmentDate: Date?
    let forecastPoints: [Point]
    let observedGlucose: [Point]

    init(recordID: String, event: Event, recordedAt: Date, referenceDate: Date? = nil,
         engineVersion: String, sourceSignature: String? = nil, treatmentRevision: Int? = nil,
         glucoseMgdl: Double? = nil, predictedMinimumMgdl: Double? = nil,
         predictedMinimumDate: Date? = nil, estimatedGrams: Double? = nil, status: String,
         sensitivityMgdlPerUnit: Double? = nil, carbohydrateRatioGramsPerUnit: Double? = nil,
         fastAbsorptionMinutes: Double? = nil, targetMgdl: Double? = nil,
         treatmentID: String? = nil, actualCarbohydrateGrams: Double? = nil,
         treatmentDate: Date? = nil, forecastPoints: [Point] = [], observedGlucose: [Point] = [],
         adviceVersion: String = CarbohydrateAdvice.version) {
        schemaVersion = 1
        self.adviceVersion = adviceVersion
        self.recordID = recordID; self.event = event; self.recordedAt = recordedAt
        self.referenceDate = referenceDate; self.engineVersion = engineVersion
        self.sourceSignature = sourceSignature; self.treatmentRevision = treatmentRevision
        self.glucoseMgdl = glucoseMgdl; self.predictedMinimumMgdl = predictedMinimumMgdl
        self.predictedMinimumDate = predictedMinimumDate; self.estimatedGrams = estimatedGrams
        self.status = status; self.sensitivityMgdlPerUnit = sensitivityMgdlPerUnit
        self.carbohydrateRatioGramsPerUnit = carbohydrateRatioGramsPerUnit
        self.fastAbsorptionMinutes = fastAbsorptionMinutes; self.targetMgdl = targetMgdl
        self.treatmentID = treatmentID; self.actualCarbohydrateGrams = actualCarbohydrateGrams
        self.treatmentDate = treatmentDate; self.forecastPoints = forecastPoints
        self.observedGlucose = observedGlucose
    }

    /// Called only after the existing treatment editor verifies the local save.
    /// The assessment stays immutable; the separate event links its exact inputs
    /// to the amount and event time the user actually registered.
    func recordingVerifiedCarbohydrates(id: String, grams: Double, date: Date,
                                        at now: Date) -> CarbohydrateAdviceEvidence {
        Self(recordID: "registered|" + id, event: .registered, recordedAt: now,
             referenceDate: referenceDate, engineVersion: engineVersion,
             sourceSignature: sourceSignature, treatmentRevision: treatmentRevision,
             glucoseMgdl: glucoseMgdl, predictedMinimumMgdl: predictedMinimumMgdl,
             predictedMinimumDate: predictedMinimumDate, estimatedGrams: estimatedGrams,
             status: status, sensitivityMgdlPerUnit: sensitivityMgdlPerUnit,
             carbohydrateRatioGramsPerUnit: carbohydrateRatioGramsPerUnit,
             fastAbsorptionMinutes: fastAbsorptionMinutes, targetMgdl: targetMgdl,
             treatmentID: id, actualCarbohydrateGrams: grams, treatmentDate: date,
             forecastPoints: forecastPoints, observedGlucose: observedGlucose, adviceVersion: adviceVersion)
    }
}

/// Only domain/code may leave the journal as diagnostics. No values, paths,
/// NSError userInfo or encoding-error descriptions are sent to system logs.
struct CarbohydrateAdviceJournalFailure: Error, Equatable, Sendable {
    let domain: String
    let code: Int

    static let invalidRecord = Self(domain: "CarbohydrateAdviceJournal", code: 1)
    static let corruptRecord = Self(domain: "CarbohydrateAdviceJournal", code: 2)
    static let oversizedRecord = Self(domain: "CarbohydrateAdviceJournal", code: 3)

    init(domain: String, code: Int) { self.domain = domain; self.code = code }
    init(_ error: Error) {
        if let failure = error as? Self { self = failure }
        else { let failure = error as NSError; domain = failure.domain; code = failure.code }
    }
}

/// Best-effort, serialized, value-only evidence. No timers or network operations.
/// Daily JSONL files are streamed once on first use to restore the ID index; normal
/// appends never rescan the previous 400 days. Only IDs/file names remain in memory.
final class CarbohydrateAdviceJournal: @unchecked Sendable {
    static let shared = CarbohydrateAdviceJournal(directory: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CarbohydrateAdviceJournal", isDirectory: true))
    static let retentionDays = 400
    static let maximumLineBytes = 1024 * 1024
    #if os(iOS) || os(watchOS)
    static let fileProtection = FileProtectionType.completeUntilFirstUserAuthentication
    #endif

    private let directory: URL
    private let clock: () -> Date
    private let diagnostic: (CarbohydrateAdviceJournalFailure) -> Void
    private let worker = DispatchQueue(label: "therapy.carbohydrate-advice.evidence", qos: .utility)
    private var recordFiles = [String: String]()
    private var indexLoaded = false
    private var lastCleanupDay: String?
    private var lastFailure: CarbohydrateAdviceJournalFailure?

    init(directory: URL, clock: @escaping () -> Date = Date.init,
         diagnostic: @escaping (CarbohydrateAdviceJournalFailure) -> Void = { failure in
             Logger(subsystem: "xDrip", category: "CarbohydrateAdviceJournal").error(
                 "Local evidence failure: \(failure.domain, privacy: .public) / \(failure.code, privacy: .public)")
         }) {
        self.directory = directory; self.clock = clock; self.diagnostic = diagnostic
    }

    /// Returns immediately. Logging success is never a condition for displaying a
    /// calculation or completing a verified treatment registration.
    func enqueue(_ evidence: CarbohydrateAdviceEvidence) {
        worker.async { [self] in
            do { try append(evidence); lastFailure = nil }
            catch {
                // A failed write may have reached disk. Rebuild before retrying so
                // a complete line cannot be duplicated after an uncertain IO result.
                indexLoaded = false; recordFiles.removeAll()
                report(CarbohydrateAdviceJournalFailure(error))
            }
        }
    }

    /// Explicit local inspection, inclusive from/exclusive to, by evidence time.
    /// IO and decoding run on the journal worker. Failure is not a valid empty log.
    func records(from start: Date, to end: Date) async throws -> [CarbohydrateAdviceEvidence] {
        try await withCheckedThrowingContinuation { continuation in
            worker.async { [self] in
                do {
                    guard start.timeIntervalSince1970.isFinite,
                          end.timeIntervalSince1970.isFinite, start <= end else {
                        throw CarbohydrateAdviceJournalFailure.invalidRecord
                    }
                    try prepare()
                    var result = [CarbohydrateAdviceEvidence]()
                    var seen = Set<String>()
                    for file in try dailyFiles() {
                        guard let day = Self.dayDate(file.lastPathComponent),
                              day < end, day.addingTimeInterval(86400) > start else { continue }
                        try readRecords(file) { record in
                            if record.recordedAt >= start, record.recordedAt < end,
                               seen.insert(record.recordID).inserted { result.append(record) }
                        }
                    }
                    continuation.resume(returning: result.sorted {
                        if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
                        return $0.recordID < $1.recordID
                    })
                } catch {
                    let failure = CarbohydrateAdviceJournalFailure(error)
                    report(failure); continuation.resume(throwing: failure)
                }
            }
        }
    }

    // Deterministic synchronization seam for tests; production callers only enqueue.
    func waitUntilIdle() { worker.sync {} }

    private func report(_ failure: CarbohydrateAdviceJournalFailure) {
        if failure != lastFailure { diagnostic(failure); lastFailure = failure }
    }

    private static func day(_ date: Date) -> String {
        String(GlucoseForecastLogSnapshot.isoDate(date).prefix(10))
    }
    private static func dayDate(_ filename: String) -> Date? {
        guard filename.range(of: #"^\d{4}-\d{2}-\d{2}\.jsonl$"#,
                             options: .regularExpression) != nil else { return nil }
        return GlucoseForecastLogSnapshot.parseDate(String(filename.prefix(10)) + "T00:00:00.000Z")
    }
    private func earliestDay() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(byAdding: .day, value: -(Self.retentionDays - 1),
                             to: calendar.startOfDay(for: clock()))!
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
    private func protect(_ url: URL) throws {
        #if os(iOS) || os(watchOS)
        try FileManager.default.setAttributes([.protectionKey: Self.fileProtection], ofItemAtPath: url.path)
        #endif
        var url = url
        var values = URLResourceValues(); values.isExcludedFromBackup = false
        try url.setResourceValues(values)
    }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try protect(directory)
        let today = Self.day(clock())
        if lastCleanupDay != today {
            let oldest = earliestDay()
            for file in try dailyFiles() {
                guard let date = Self.dayDate(file.lastPathComponent), date < oldest else { continue }
                try FileManager.default.removeItem(at: file)
                recordFiles = recordFiles.filter { $0.value != file.lastPathComponent }
            }
            lastCleanupDay = today
        }
        guard !indexLoaded else { return }
        var index = [String: String]()
        for file in try dailyFiles() {
            try recoverTail(file)
            try readRecords(file) { record in
                if index[record.recordID] == nil { index[record.recordID] = file.lastPathComponent }
            }
        }
        recordFiles = index; indexLoaded = true
    }
    private func append(_ evidence: CarbohydrateAdviceEvidence) throws {
        let dates = [evidence.recordedAt, evidence.referenceDate, evidence.predictedMinimumDate,
                     evidence.treatmentDate].compactMap { $0 }
        let numbers = [evidence.glucoseMgdl, evidence.predictedMinimumMgdl, evidence.estimatedGrams,
                       evidence.sensitivityMgdlPerUnit, evidence.carbohydrateRatioGramsPerUnit,
                       evidence.fastAbsorptionMinutes, evidence.targetMgdl,
                       evidence.actualCarbohydrateGrams].compactMap { $0 }
        let points = evidence.forecastPoints + evidence.observedGlucose
        guard !evidence.recordID.isEmpty,
              dates.allSatisfy({ $0.timeIntervalSince1970.isFinite }), numbers.allSatisfy(\.isFinite),
              points.allSatisfy({ $0.date.timeIntervalSince1970.isFinite && $0.glucoseMgdl.isFinite }) else {
            throw CarbohydrateAdviceJournalFailure.invalidRecord
        }
        try prepare()
        guard evidence.recordedAt >= earliestDay(), recordFiles[evidence.recordID] == nil else { return }
        var line = try GlucoseForecastLogSnapshot.encoder().encode(evidence)
        line.append(contentsOf: [UInt8(10)])
        guard line.count <= Self.maximumLineBytes else { throw CarbohydrateAdviceJournalFailure.oversizedRecord }
        let file = directory.appendingPathComponent(Self.day(evidence.recordedAt) + ".jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw CarbohydrateAdviceJournalFailure(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
            }
        }
        try protect(file)
        try recoverTail(file)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: line); try handle.synchronize()
        recordFiles[evidence.recordID] = file.lastPathComponent
    }

    /// Preserve every completed line, including unknown/corrupt historical records.
    /// Repair only an interrupted last line before the next append.
    private func recoverTail(_ file: URL) throws {
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd(); guard size > 0 else { return }
        try handle.seek(toOffset: size - 1)
        if try handle.read(upToCount: 1) == Data([10]) { return }
        var offset = size
        var suffix = Data()
        while offset > 0 && suffix.count <= Self.maximumLineBytes {
            let length = min(UInt64(64 * 1024), offset); offset -= length
            try handle.seek(toOffset: offset)
            suffix.insert(contentsOf: try handle.read(upToCount: Int(length)) ?? Data(), at: 0)
            if let newline = suffix.lastIndex(of: 10) {
                let tail = Data(suffix.suffix(from: suffix.index(after: newline)))
                guard tail.count <= Self.maximumLineBytes else { throw CarbohydrateAdviceJournalFailure.oversizedRecord }
                if (try? JSONSerialization.jsonObject(with: tail)) != nil {
                    try handle.seekToEnd(); try handle.write(contentsOf: Data([10]))
                } else {
                    try handle.truncate(atOffset: size - UInt64(tail.count)); report(.corruptRecord)
                }
                return
            }
        }
        guard suffix.count <= Self.maximumLineBytes else { throw CarbohydrateAdviceJournalFailure.oversizedRecord }
        if (try? JSONSerialization.jsonObject(with: suffix)) != nil {
            try handle.seekToEnd(); try handle.write(contentsOf: Data([10]))
        } else { try handle.truncate(atOffset: 0); report(.corruptRecord) }
    }
    private func readRecords(_ file: URL, body: (CarbohydrateAdviceEvidence) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let decoder = GlucoseForecastLogSnapshot.decoder()
        func decode(_ data: Data) {
            guard !data.isEmpty else { return }
            guard data.count <= Self.maximumLineBytes,
                  let record = try? decoder.decode(CarbohydrateAdviceEvidence.self, from: data),
                  record.schemaVersion == 1, !record.recordID.isEmpty else {
                report(.corruptRecord); return
            }
            body(record)
        }
        var pending = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            pending.append(chunk)
            while let end = pending.firstIndex(of: 10) {
                decode(Data(pending[..<end])); pending.removeSubrange(...end)
            }
            guard pending.count <= Self.maximumLineBytes else { throw CarbohydrateAdviceJournalFailure.oversizedRecord }
        }
        if !pending.isEmpty { decode(pending) }
    }
}
