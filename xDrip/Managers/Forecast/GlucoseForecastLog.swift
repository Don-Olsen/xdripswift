// Local, prospective evidence only. Never feeds glucose storage, alarms or therapy.
import Foundation
import CryptoKit
import CoreData
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
    enum RecordType: String, Codable, Sendable { case forecast, unavailable, presentation }
    struct Point: Codable, Sendable { let offsetMinutes: Int; let glucoseMgdl: Double }
    /// Inference output already includes the existing correction clamp. Only the
    /// low-glucose presentation cap separates mlBeforeCapPoints from displayedPoints.
    struct Presentation: Codable, Sendable {
        let modelID: String?
        let mlBeforeCapPoints: [Point]?
        let displayedPoints: [Point]
        let presentedAt: Date?
    }
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
    private(set) var presentation: Presentation?

    static func make(input: GlucoseForecastInput?, result: GlucoseForecastResult,
                     context: GlucoseForecastLogContext,
                     capturesPresentation: Bool = false,
                     mlBeforeCap: GlucoseForecastMLForecast? = nil) throws -> Self {
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
        var presentation: Presentation?
        if capturesPresentation {
            guard valid, let referenceDate else { throw GlucoseForecastLogFailure.invalidSnapshot }
            let displayed = GlucoseForecastMLPresentation.points(in: result)
            func validPoints(_ points: [GlucoseForecastPoint]) -> Bool {
                points.count == result.points.count && points.enumerated().allSatisfy { index, point in
                    point.glucoseMgdl.isFinite &&
                    (config.minimumGlucoseMgdl...config.maximumGlucoseMgdl).contains(point.glucoseMgdl) &&
                    abs(point.date.timeIntervalSince(referenceDate) - Double(index) * config.integrationStepMinutes * 60) < 0.001
                }
            }
            guard validPoints(displayed) else { throw GlucoseForecastLogFailure.invalidSnapshot }
            if let selected = result.mlForecast {
                guard let mlBeforeCap, !selected.modelID.isEmpty,
                      selected.modelID == mlBeforeCap.modelID,
                      validPoints(mlBeforeCap.points),
                      mlBeforeCap.points.first?.glucoseMgdl == result.points.first?.glucoseMgdl,
                      displayed.first?.glucoseMgdl == result.points.first?.glucoseMgdl,
                      zip(mlBeforeCap.points, displayed).enumerated().allSatisfy({ index, pair in
                          pair.1.glucoseMgdl == pair.0.glucoseMgdl ||
                          pair.1.glucoseMgdl == min(pair.0.glucoseMgdl, result.points[index].glucoseMgdl)
                      }) else { throw GlucoseForecastLogFailure.invalidSnapshot }
            } else if mlBeforeCap != nil {
                throw GlucoseForecastLogFailure.invalidSnapshot
            }
            func copies(_ points: [GlucoseForecastPoint]) -> [Point] {
                points.enumerated().map { Point(offsetMinutes: $0.offset * Int(config.integrationStepMinutes),
                    glucoseMgdl: $0.element.glucoseMgdl) }
            }
            presentation = Presentation(modelID: result.mlForecast?.modelID,
                mlBeforeCapPoints: mlBeforeCap.map { copies($0.points) },
                displayedPoints: copies(displayed), presentedAt: nil)
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
        return Self(schemaVersion: capturesPresentation ? 3 : 2, engineVersion: GlucoseForecastEngine.engineVersion,
            recordType: capturesPresentation ? .presentation : (valid ? .forecast : .unavailable),
            appVersion: context.appVersion, appBuild: context.appBuild,
            sourceIdentity: context.sourceIdentity, sensorIdentity: sensorIdentity,
            referenceIdentity: referenceIdentity, referenceDate: referenceDate,
            computedAt: context.computedAt, horizonMinutes: context.horizonMinutes,
            referenceGlucoseMgdl: finite(valid ? result.points.first?.glucoseMgdl : referenceSample?.glucoseMgdl),
            points: valid ? result.points.enumerated().map {
                Point(offsetMinutes: $0.offset * Int(config.integrationStepMinutes), glucoseMgdl: $0.element.glucoseMgdl)
            } : [], reason: valid ? nil : (result.reason?.rawValue ?? "dataUnavailable"),
            parameters: parameters, constants: config, treatmentSummary: summary,
            inputs: inputs, inputFingerprint: fingerprint, presentation: presentation)
    }

    /// A cheap value-copy at the UI boundary. The caller supplies the SAME result
    /// passed through Home's chart/source/freshness gates, never newly read settings.
    func confirmingPresentation(of result: GlucoseForecastResult?, at date: Date) -> Self? {
        guard recordType == .presentation, let presentation, let result,
              result.reason == nil, result.referenceDate == referenceDate,
              result.referenceSensorID == sensorIdentity,
              result.mlForecast?.modelID == presentation.modelID,
              date.timeIntervalSince1970.isFinite, date >= computedAt,
              result.points.count == points.count,
              zip(result.points, points).allSatisfy({ $0.glucoseMgdl == $1.glucoseMgdl }),
              GlucoseForecastMLPresentation.points(in: result).count == presentation.displayedPoints.count,
              zip(GlucoseForecastMLPresentation.points(in: result), presentation.displayedPoints)
                .allSatisfy({ $0.glucoseMgdl == $1.glucoseMgdl &&
                    $0.date == referenceDate?.addingTimeInterval(Double($1.offsetMinutes * 60)) })
        else { return nil }
        var copy = self
        copy.presentation = Presentation(modelID: presentation.modelID,
            mlBeforeCapPoints: presentation.mlBeforeCapPoints,
            displayedPoints: presentation.displayedPoints, presentedAt: date)
        return copy
    }

    private static func digest<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try encoder().encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Each codec owns its formatter; snapshot construction and log IO use different workers.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer(); try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = formatter.date(from: text) else { throw GlucoseForecastLogFailure.invalidSnapshot }
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
        if recordType == .presentation {
            return base + "|" + (presentation?.modelID.map { "model:" + $0 } ?? "engineOnly")
        }
        // Repeated identical failures are retained at most once per ten-minute UTC bucket.
        return base + "|" + (reason ?? "") + "|" + String(Int(computedAt.timeIntervalSince1970 / 600))
    }
}

enum GlucoseForecastLogFailure: String, Error { case invalidSnapshot, io, corruptRecord, oversizedRecord }

/// An explicit local export. No destination is selected and nothing is transmitted here.
struct ForecastEvaluationExport: Sendable {
    let urls: [URL]
    let coverageSummary: String
}

/// Keeps only one bounding interval per sensor, never the forecast or glucose history.
private struct ForecastEvaluationCoverage {
    struct Interval {
        var start: Date
        var end: Date
        mutating func include(_ other: Self) {
            start = min(start, other.start); end = max(end, other.end)
        }
    }
    var intervals = [String: Interval]()
    var forecastRecords = 0
    var unavailableRecords = 0
    var unidentifiedForecastRecords = 0
    var corruptForecastRecords = 0
    var exportedRows = 0
    var invalidRows = 0
    var unidentifiedRows = 0
    var unrelatedRows = 0
    var actualIntervals = [String: Interval]()
    var actualCounts = [String: Int]()

    var interval: Interval? {
        intervals.values.reduce(nil as Interval?) { result, next in
            guard var result else { return next }
            result.include(next); return result
        }
    }

    mutating func include(_ snapshot: GlucoseForecastLogSnapshot, through cutoff: Date) {
        guard snapshot.recordType != .unavailable, snapshot.reason == nil,
              let reference = snapshot.referenceDate,
              reference.timeIntervalSince1970.isFinite else {
            unavailableRecords += 1; return
        }
        let offsets = snapshot.points.filter {
            $0.offsetMinutes >= 0 && $0.offsetMinutes <= snapshot.horizonMinutes &&
                $0.glucoseMgdl.isFinite && (20...600).contains($0.glucoseMgdl)
        }.map(\.offsetMinutes)
        guard let first = offsets.min(), let last = offsets.max() else {
            unavailableRecords += 1; return
        }
        forecastRecords += 1
        guard let sensor = snapshot.sensorIdentity, !sensor.isEmpty,
              snapshot.sourceIdentity == "sensor:" + sensor else {
            unidentifiedForecastRecords += 1; return
        }
        // Include all exported point offsets (also zero), plus the evaluator's matching
        // tolerance. Never manufacture follow-up beyond this export's fixed clock time.
        let range = Interval(start: reference.addingTimeInterval(Double(first) * 60 - 150),
            end: min(cutoff, reference.addingTimeInterval(Double(last) * 60 + 150)))
        guard range.start <= range.end else { return }
        if var previous = intervals[sensor] { previous.include(range); intervals[sensor] = previous }
        else { intervals[sensor] = range }
    }

    mutating func recordActual(sensor: String, date: Date) {
        exportedRows += 1; actualCounts[sensor, default: 0] += 1
        let range = Interval(start: date, end: date)
        if var previous = actualIntervals[sensor] { previous.include(range); actualIntervals[sensor] = previous }
        else { actualIntervals[sensor] = range }
    }

    func summary() -> String {
        "Eksporterede glukoserækker: \(exportedRows). " +
        "Udeladt: ugyldige glukoserækker: \(invalidRows). " +
        "Udeladt: manglende sensor-ID: \(unidentifiedRows). " +
        "Udeladt: uden matchende prognoseidentitet/periode: \(unrelatedRows). " +
        "Oversprungne ulæselige prognoseposter: \(corruptForecastRecords). " +
        "Dækningen kan have huller; se coverage.txt. Der er ikke beregnet en præcisionsscore."
    }

    func report(exportedAt: Date, formatter: ISO8601DateFormatter) -> String {
        func span(_ range: Interval?) -> String {
            guard let range else { return "Ingen" }
            return formatter.string(from: range.start) + " til " + formatter.string(from: range.end)
        }
        var lines = [
            "Lokal prognose- og glukoseeksport",
            "Eksporttid (UTC): \(formatter.string(from: exportedAt))",
            "Prognosernes afledte måleperiode (UTC, inklusive ±150 sekunder, højst eksporttid): \(span(interval))",
            "Gyldige prognose-/visningsposter: \(forecastRecords)",
            "Utilgængelige prognoseposter uden måleperiode: \(unavailableRecords)",
            "Prognoseposter uden matchende kilde-/sensoridentitet: \(unidentifiedForecastRecords)",
            "Oversprungne ulæselige prognoseposter: \(corruptForecastRecords)",
            "Eksporterede glukoserækker: \(exportedRows)",
            "Udeladt: ugyldige glukoserækker: \(invalidRows)",
            "Udeladt: manglende sensor-ID: \(unidentifiedRows)",
            "Udeladt: uden matchende prognoseidentitet/periode: \(unrelatedRows)",
            "",
            "Dækning pr. sensor (antal rækker og første/sidste måling; ingen garanti for ubrudt dækning):"
        ]
        for sensor in intervals.keys.sorted() {
            // Quote unusual sensor IDs consistently with their CSV representation.
            lines.append("Sensor \(GlucoseForecastCSV.escape(sensor)): \(actualCounts[sensor, default: 0]) rækker; " +
                "ønsket \(span(intervals[sensor])); målinger \(span(actualIntervals[sensor]))")
        }
        lines += ["", "Begrænsninger:",
            "Kun allerede gemte glukosemålinger i et fast databasesnapshot er med. Ventende ugemte ændringer og senere målinger indgår ikke. Eksporten ændrer ikke databasen.",
            "Glukose er den gemte finalValue i mg/dL: udglattet værdi, ellers justeret værdi, ellers beregnet værdi. Det er ikke en ny rå eller uafhængig reference-måling.",
            "Kun downstream-gyldige, endelige værdier mellem 20 og 600 mg/dL med kendt sensor-ID eksporteres. Målinger skjult af visningens femminuttersregel kan være med. Udeladte rækker tælles i den samlede afledte måleperiode.",
            "Sensor-ID kopieres fra hver måling. source_identity er sensor: efterfulgt af samme ID. Der tildeles aldrig en sensor til en måling uden identitet.",
            "Dubletter og modstridende gyldige værdier bevares. Analyseværktøjet tæller dubletter og udelukker konflikter på samme kilde/sensor/tid; eksportens rækkeantal er derfor ikke antal analyserbare par.",
            "Prognoseloggen opbevares i op til 400 UTC-dage. Glukosehistorikkens valgte opbevaring (7/30/90/180/365 dage), oprydning, gendannelse og manglende sensor-ID kan give kortere dækning. Manglende historik rekonstrueres ikke, og ingen opbevaringsindstilling ændres.",
            "Første og sidste måling beviser ikke fuld dækning. Home-prognoser er ikke døgnkontinuerlige. Nyeste prognoser kan stadig mangle fremtidige målinger. Der udføres ingen interpolation eller sammenkobling på tværs af sensorer.",
            "Filerne indeholder helbredsdata. De forbliver lokale, indtil du selv vælger en destination i delingsarket.",
            "Lokal analyse: python3 -B scripts/evaluate-glucose-forecast.py --forecast-csv forecast.csv --glucose-csv actual-glucose.csv --output-json forecast-report.json"
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}

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

    /// Writes all three files before returning any shareable URL. The log worker freezes
    /// the forecast stream; a separate pinned Core Data context reads committed actuals.
    func exportEvaluation(coreDataManager: CoreDataManager,
                          completion: @escaping (Result<ForecastEvaluationExport, Error>) -> Void) {
        let parent = coreDataManager.privateManagedObjectContext
        worker.async { [self] in
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("xdrip-forecast-evaluation-exports", isDirectory: true)
            let outcome: Result<ForecastEvaluationExport, Error>
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try protect(root, backedUp: false)
                try pruneEvaluationExports(in: root)
                let destination = root.appendingPathComponent("evaluation-\(UUID().uuidString)", isDirectory: true)
                outcome = .success(try exportEvaluation(parent: parent, to: destination, pageSize: 500))
            } catch {
                report(.io); outcome = .failure(GlucoseForecastLogFailure.io)
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    private func pruneEvaluationExports(in root: URL) throws {
        for file in try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]) {
            guard file.lastPathComponent.hasPrefix("evaluation-") ||
                    file.lastPathComponent.hasPrefix(".pending-") else { continue }
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true, values.isSymbolicLink != true,
               let modified = values.contentModificationDate,
               clock().timeIntervalSince(modified) > 24 * 60 * 60 {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    private func exportEvaluation(parent: NSManagedObjectContext, to destination: URL,
                                  pageSize: Int,
                                  pageRead: ((Int, NSManagedObjectContext) throws -> Void)? = nil) throws -> ForecastEvaluationExport {
        guard pageSize > 0, !FileManager.default.fileExists(atPath: destination.path) else {
            throw GlucoseForecastLogFailure.io
        }
        let exportedAt = clock()
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: staging) } }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        try protect(staging, backedUp: false)
        var coverage = ForecastEvaluationCoverage()
        try export(to: staging.appendingPathComponent("forecast.csv"),
            snapshotExported: { coverage.include($0, through: exportedAt) },
            corruptRecord: { coverage.corruptForecastRecords += 1 })
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        try exportActualGlucose(parent: parent, to: staging.appendingPathComponent("actual-glucose.csv"),
            coverage: &coverage, formatter: formatter, pageSize: pageSize, pageRead: pageRead)
        let report = staging.appendingPathComponent("coverage.txt")
        try Data(coverage.report(exportedAt: exportedAt, formatter: formatter).utf8).write(to: report, options: .atomic)
        try protect(report, backedUp: false)
        try FileManager.default.moveItem(at: staging, to: destination)
        completed = true
        return ForecastEvaluationExport(urls: ["forecast.csv", "actual-glucose.csv", "coverage.txt"].map {
            destination.appendingPathComponent($0)
        }, coverageSummary: coverage.summary())
    }

    private func exportActualGlucose(parent: NSManagedObjectContext, to destination: URL,
                                    coverage: inout ForecastEvaluationCoverage,
                                    formatter: ISO8601DateFormatter, pageSize: Int,
                                    pageRead: ((Int, NSManagedObjectContext) throws -> Void)?) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw GlucoseForecastLogFailure.io
        }
        try protect(destination, backedUp: false)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("date_utc,glucose_mgdl,source_identity,sensor_identity\r\n".utf8))
        if let interval = coverage.interval {
            var coordinator: NSPersistentStoreCoordinator?
            parent.performAndWait { coordinator = parent.persistentStoreCoordinator }
            guard let coordinator, !coordinator.persistentStores.isEmpty,
                  coordinator.persistentStores.allSatisfy({ $0.type == NSSQLiteStoreType }) else {
                throw GlucoseForecastLogFailure.io
            }
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = coordinator
            context.undoManager = nil
            try context.performAndWait {
                defer { context.reset(); try? context.setQueryGenerationFrom(nil) }
                try context.setQueryGenerationFrom(.current)
                let request: NSFetchRequest<BgReading> = BgReading.fetchRequest()
                request.predicate = NSPredicate(format: "timeStamp >= %@ AND timeStamp <= %@",
                    interval.start as NSDate, interval.end as NSDate)
                request.sortDescriptors = [NSSortDescriptor(key: #keyPath(BgReading.timeStamp), ascending: true),
                    NSSortDescriptor(key: #keyPath(BgReading.id), ascending: true)]
                request.includesPendingChanges = false
                request.relationshipKeyPathsForPrefetching = ["sensor"]
                request.fetchLimit = pageSize
                // Resolve .current to an actual generation before any page hook or concurrent
                // writer. reset() can advance a context, so reapply THIS token after each page.
                let countRequest = BgReading.fetchRequest()
                countRequest.predicate = request.predicate
                countRequest.includesPendingChanges = false
                let count = try context.count(for: countRequest)
                guard let generation = context.queryGenerationToken else { throw GlucoseForecastLogFailure.io }
                var offset = 0
                while offset < count {
                    try autoreleasepool {
                        try context.setQueryGenerationFrom(generation)
                        try pageRead?(offset / pageSize, context)
                        request.fetchOffset = offset
                        let readings = try context.fetch(request)
                        guard !readings.isEmpty else { throw GlucoseForecastLogFailure.io }
                        for reading in readings {
                            let value = reading.finalValue
                            guard reading.isValidForDownstream, value.isFinite, (20...600).contains(value) else {
                                coverage.invalidRows += 1; continue
                            }
                            guard let sensor = reading.sensor?.id, !sensor.isEmpty else {
                                coverage.unidentifiedRows += 1; continue
                            }
                            guard let range = coverage.intervals[sensor],
                                  reading.timeStamp >= range.start, reading.timeStamp <= range.end else {
                                coverage.unrelatedRows += 1; continue
                            }
                            let fields = [formatter.string(from: reading.timeStamp), String(value), "sensor:" + sensor, sensor]
                            let row = fields.map(GlucoseForecastCSV.escape).joined(separator: ",") + "\r\n"
                            try handle.write(contentsOf: Data(row.utf8))
                            coverage.recordActual(sensor: sensor, date: reading.timeStamp)
                        }
                        offset += readings.count
                        context.reset()
                    }
                }
            }
        }
        try handle.synchronize()
    }

    // Internal synchronization seams for deterministic unit tests only. Production
    // forecast and UI paths exclusively use the asynchronous APIs above.
    func waitUntilIdle() { worker.sync {} }
    func exportCSVForTesting(to url: URL) throws { try worker.sync { try export(to: url) } }
    func exportEvaluationForTesting(coreDataManager: CoreDataManager, to destination: URL,
                                    pageSize: Int = 500,
                                    pageRead: ((Int, NSManagedObjectContext) throws -> Void)? = nil) throws -> ForecastEvaluationExport {
        let parent = coreDataManager.privateManagedObjectContext
        return try worker.sync {
            try exportEvaluation(parent: parent, to: destination, pageSize: pageSize, pageRead: pageRead)
        }
    }

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
        if snapshot.recordType == .presentation, snapshot.presentation?.presentedAt == nil {
            throw GlucoseForecastLogFailure.invalidSnapshot
        }
        try prepare()
        // Reference-day partitioning makes valid dedup stable even when computedAt crosses
        // midnight/restarts. Failures with no usable reference are partitioned by attempt day.
        let partitionDate = snapshot.recordType != .unavailable ? snapshot.referenceDate ?? snapshot.computedAt : snapshot.computedAt
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

    private func readLines(_ url: URL, corruptRecord: (() -> Void)? = nil, body: (Data) throws -> Void) throws {
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
            } else { report(.corruptRecord); corruptRecord?() }
        }
    }

    private func export(to destination: URL,
                        snapshotExported: ((GlucoseForecastLogSnapshot) -> Void)? = nil,
                        corruptRecord: (() -> Void)? = nil) throws {
        try prepare()
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw GlucoseForecastLogFailure.io }
        try protect(destination, backedUp: false)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data((GlucoseForecastCSV.columns.joined(separator: ",") + "\r\n").utf8))
        do {
            for file in try dailyFiles() {
                try readLines(file, corruptRecord: corruptRecord) { [self] line in
                    let snapshot: GlucoseForecastLogSnapshot
                    do { snapshot = try GlucoseForecastLogSnapshot.decoder().decode(GlucoseForecastLogSnapshot.self, from: line) }
                    catch { report(.corruptRecord); corruptRecord?(); return }
                    for row in try GlucoseForecastCSV.rows(snapshot) { try handle.write(contentsOf: Data(row.utf8)) }
                    snapshotExported?(snapshot)
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
        "bolus_count", "bolus_units", "carb_count", "carb_grams", "input_fingerprint", "engine_constants_json",
        "model_id", "ml_prediction_mgdl", "displayed_prediction_mgdl", "low_glucose_cap_applied", "presented_at_utc"]

    static func rows(_ snapshot: GlucoseForecastLogSnapshot) throws -> [String] {
        func number(_ value: Double?) -> String { value.flatMap { $0.isFinite ? String($0) : nil } ?? "" }
        func integer(_ value: Int?) -> String { value.map(String.init) ?? "" }
        func date(_ value: Date?) -> String { value.map(GlucoseForecastLogSnapshot.isoDate) ?? "" }
        if snapshot.recordType == .presentation, snapshot.presentation?.presentedAt == nil {
            throw GlucoseForecastLogFailure.invalidSnapshot
        }
        let parameters = snapshot.parameters; let summary = snapshot.treatmentSummary
        let constants = String(decoding: try GlucoseForecastLogSnapshot.encoder().encode(snapshot.constants), as: UTF8.self)
        // Only offset and prediction vary between a snapshot's rows. Format and escape
        // the shared cells once, including the four UTC dates and constants JSON.
        let prefix = [String(snapshot.schemaVersion), snapshot.recordType.rawValue, snapshot.engineVersion, snapshot.appVersion,
            snapshot.appBuild, snapshot.sourceIdentity, snapshot.sensorIdentity ?? "", snapshot.referenceIdentity ?? "",
            date(snapshot.referenceDate), date(snapshot.computedAt), String(snapshot.horizonMinutes),
            number(snapshot.referenceGlucoseMgdl)].map(escape).joined(separator: ",")
        let suffix = [snapshot.reason ?? "", number(parameters.sensitivityMgdlPerUnit),
            number(parameters.carbohydrateRatioGramsPerUnit), parameters.insulinModel ?? "",
            number(parameters.insulinPeakMinutes), number(parameters.insulinDurationMinutes), number(parameters.carbohydrateDurationMinutes),
            date(summary.windowStart), date(summary.windowEnd), integer(summary.bolusCount), number(summary.bolusUnits),
            integer(summary.carbohydrateCount), number(summary.carbohydrateGrams), snapshot.inputFingerprint ?? "", constants]
            .map(escape).joined(separator: ",")
        let points: [GlucoseForecastLogSnapshot.Point?] = snapshot.recordType != .unavailable ? snapshot.points.map { Optional($0) } : [nil]
        return points.map { point in
            let presentation = snapshot.presentation
            let raw = presentation?.mlBeforeCapPoints?.first { $0.offsetMinutes == point?.offsetMinutes }?.glucoseMgdl
            let displayed = presentation?.displayedPoints.first { $0.offsetMinutes == point?.offsetMinutes }?.glucoseMgdl
            let cap = raw.flatMap { raw in displayed.map { $0 != raw ? "true" : "false" } } ?? ""
            let extra = [presentation?.modelID ?? "", number(raw), number(displayed), cap,
                date(presentation?.presentedAt)].map(escape).joined(separator: ",")
            return prefix + "," + escape(integer(point?.offsetMinutes)) + "," + escape(number(point?.glucoseMgdl)) + "," + suffix + "," + extra + "\r\n"
        }
    }

    static func escape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
