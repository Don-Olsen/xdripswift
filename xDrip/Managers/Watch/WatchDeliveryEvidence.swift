import Foundation

enum WatchDeliveryEvidenceStream: String, Codable {
    case status, graph, agp, session, reading, receipt, diagnostic
}

enum WatchDeliveryEvidenceStage: String, Codable {
    case decoded, accepted, rejected, localWriteConfirmed, localWriteFailed
    case sendAttempt, phoneReceived, phoneStored, phoneRejected, acknowledgement
    case coalesced, suppressed, transportFailed, transportReceived, alarmReadiness
}

/// Device provenance is captured when the event originates, never supplied by the exporter.
struct WatchDeliveryEvidenceOrigin: Codable, Equatable {
    let device: String
    let installation: UUID
    let process: UUID
    let build: String
    let sourceCommit: String

    static func current(defaults: UserDefaults = .standard, bundle: Bundle = .main) -> Self {
        let key = "watchDeliveryEvidenceInstallationV1"
        let installation = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(installation.uuidString, forKey: key)
        #if os(watchOS)
        let device = "watch"
        #else
        let device = "phone"
        #endif
        return Self(device: device, installation: installation, process: UUID(),
                    build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                    sourceCommit: bundle.object(forInfoDictionaryKey: "XDripSourceCommit") as? String ?? "unknown")
    }
}

/// No glucose values, sensor identity, encryption material or user configuration is copied here.
struct WatchDeliveryEvidenceEvent: Codable, Equatable {
    let sequence: UInt64
    let origin: WatchDeliveryEvidenceOrigin
    let at: Date
    let uptime: TimeInterval
    let stream: WatchDeliveryEvidenceStream
    let stage: WatchDeliveryEvidenceStage
    let payloadID: UUID?
    let sessionID: UUID?
    /// Existing pipeline timestamp: Watch callback reception, not an inferred sensor wall clock.
    let watchReceivedAt: Date?
    let sensorTime: Date?
    let sensorElapsedMinutes: UInt16?
    let outcome: String?
}

struct WatchDeliveryEvidenceSnapshot: Codable {
    let version: Int
    let exportedAt: Date
    let origin: WatchDeliveryEvidenceOrigin
    let firstRetainedAt: Date?
    let lastRetainedAt: Date?
    let maximumAge: TimeInterval
    let maximumEvents: Int
    let maximumBytes: Int
    let rotatedEvents: UInt64
    let writeFailures: UInt64
    let unreadableLines: UInt64
    /// Optional so snapshots exported by earlier phone/Watch versions remain decodable.
    let recoveredLegacyEvents: UInt64?
    let preservedRepairSourceBytes: Int?
    let counterWindowStartedAt: Date
    let transportCounters: [String: UInt64]
    let lastAlarmReadinessEvidence: [String: String]?
    let events: [WatchDeliveryEvidenceEvent]
    let clockNote: String
    let coverageNote: String
}

/// Independent diagnostic journal. Append one bounded line per meaningful delivery stage;
/// never enqueue its failures in the clinical outbox. UI/transport counters stay in RAM and
/// are checkpointed at most once a minute. No timer is created and no execution is requested.
final class WatchDeliveryEvidenceStore {
    static let shared = WatchDeliveryEvidenceStore()
    static let defaultMaximumAge: TimeInterval = 24 * 60 * 60
    static let defaultMaximumEvents = 4096
    static let defaultMaximumBytes = 3 * 1024 * 1024

    struct Limits {
        var age: TimeInterval = WatchDeliveryEvidenceStore.defaultMaximumAge
        var events: Int = WatchDeliveryEvidenceStore.defaultMaximumEvents
        var bytes: Int = WatchDeliveryEvidenceStore.defaultMaximumBytes
    }

    private struct Metadata: Codable {
        var sequence: UInt64 = 0
        var rotated: UInt64 = 0
        var writeFailures: UInt64 = 0
        var unreadable: UInt64 = 0
        var recoveredLegacyEvents: UInt64?
        var preservedRepairSourceBytes: Int?
        var counterWindowStartedAt = Date()
        var counters: [String: UInt64] = [:]
        var alarmReadiness: [String: String]?
    }

    private let queue = DispatchQueue(label: "xdrip.watch.delivery-evidence")
    private let directory: URL
    private let clock: () -> Date
    private let uptime: () -> TimeInterval
    let origin: WatchDeliveryEvidenceOrigin
    private let limits: Limits
    private let append: (Data, URL) throws -> Void
    private let replace: (Data, URL) throws -> Void
    private var metadata: Metadata
    private var records: [(event: WatchDeliveryEvidenceEvent, line: Data)] = []
    private var byteCount = 0
    private var lastCheckpoint: TimeInterval = -.infinity
    private var lastPrune: Date = .distantPast
    private var journalNeedsRepair = false
    private var pendingLegacyRecoveredEvents: UInt64 = 0
    private var journalURL: URL { directory.appendingPathComponent("delivery-events-v1.jsonl") }
    private var repairSourceURL: URL { directory.appendingPathComponent("delivery-events-v1.pre-repair.jsonl") }
    private var metadataURL: URL { directory.appendingPathComponent("delivery-metadata-v1.json") }

    init(directory: URL? = nil, origin: WatchDeliveryEvidenceOrigin = .current(),
         clock: @escaping () -> Date = Date.init,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         limits: Limits = Limits(),
         append: ((Data, URL) throws -> Void)? = nil,
         replace: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.directory = directory ?? Self.defaultDirectory
        self.origin = origin
        self.clock = clock
        self.uptime = uptime
        self.limits = limits
        self.replace = replace
        self.append = append ?? { data, url in
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url, options: .atomic)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }
        metadata = Metadata(counterWindowStartedAt: clock())
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: metadataURL),
           let saved = try? JSONDecoder().decode(Metadata.self, from: data) { metadata = saved }
        load()
    }

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("WatchDeliveryEvidence", isDirectory: true)
    }

    @discardableResult
    func record(stage: WatchDeliveryEvidenceStage, payloadID: UUID? = nil, sessionID: UUID? = nil,
                measuredAt: Date? = nil, sensorTime: Date? = nil, sensorElapsedMinutes: UInt16? = nil,
                outcome: String? = nil, stream: WatchDeliveryEvidenceStream = .reading) -> Bool {
        queue.sync {
            let now = clock()
            if journalNeedsRepair {
                guard rewrite(records) else { return false }
                journalNeedsRepair = false
            }
            if now.timeIntervalSince(lastPrune) >= 300 { prune(at: now) }
            metadata.sequence &+= 1
            let event = WatchDeliveryEvidenceEvent(sequence: metadata.sequence, origin: origin,
                at: now, uptime: uptime(), stream: stream, stage: stage, payloadID: payloadID,
                sessionID: sessionID, watchReceivedAt: measuredAt, sensorTime: sensorTime,
                sensorElapsedMinutes: sensorElapsedMinutes, outcome: Self.safeLabel(outcome))
            if stage == .alarmReadiness, let value = Self.safeLabel(outcome),
               let component = value.split(separator: ":").first {
                var readiness = metadata.alarmReadiness ?? [:]
                if readiness.count < 16 || readiness[String(component)] != nil { readiness[String(component)] = value }
                metadata.alarmReadiness = readiness
            }
            guard var line = try? JSONEncoder().encode(event) else { metadata.writeFailures &+= 1; return false }
            // The iPhone Data extension has a generic integer overload: an untyped literal
            // writes an eight-byte Int (LF followed by seven NULs), not one delimiter byte.
            line.append(UInt8(0x0a))
            guard line.count <= limits.bytes else { metadata.writeFailures &+= 1; return false }
            // Remove a quarter when full: bounded amortized compaction, not a full rewrite per event.
            if records.count >= limits.events || byteCount + line.count > limits.bytes {
                compactForCapacity(incomingBytes: line.count)
            }
            guard records.count < limits.events, byteCount + line.count <= limits.bytes else {
                metadata.writeFailures &+= 1
                return false
            }
            do {
                try append(line, journalURL)
                records.append((event, line))
                byteCount += line.count
                checkpointIfDue()
                return true
            } catch {
                metadata.writeFailures &+= 1
                // A write can fail after a partial line. Repair only this independent journal
                // before its next append, so a later valid event cannot join truncated JSON.
                journalNeedsRepair = true
                return false
            }
        }
    }

    @discardableResult
    func recordReading(_ stage: WatchDeliveryEvidenceStage, reading: LibreWatchDirectReadingPayload,
                       outcome: String? = nil, stream: WatchDeliveryEvidenceStream = .reading) -> Bool {
        record(stage: stage, payloadID: reading.id, sessionID: reading.sessionID,
               measuredAt: reading.receivedAt, sensorElapsedMinutes: reading.sensorTimeInMinutes,
               outcome: outcome, stream: stream)
    }

    /// Counts callbacks/attempts, never claims a radio packet count. Labels are controlled tokens.
    func recordTransport(stream: WatchDeliveryEvidenceStream, action: String, outcome: String? = nil) {
        queue.sync {
            let key = [stream.rawValue, Self.safeLabel(action) ?? "unknown", Self.safeLabel(outcome) ?? "none"].joined(separator: ".")
            // Bound accidental high-cardinality labels; raw NSError descriptions must not be passed.
            let boundedKey = metadata.counters[key] != nil || metadata.counters.count < 160 ? key : "overflow"
            metadata.counters[boundedKey, default: 0] &+= 1
            checkpointIfDue()
        }
    }

    func snapshot() -> WatchDeliveryEvidenceSnapshot {
        queue.sync {
            let now = clock()
            prune(at: now)
            checkpoint(force: true)
            let visible = records.filter { $0.event.at >= now.addingTimeInterval(-limits.age) }
            return WatchDeliveryEvidenceSnapshot(version: 1, exportedAt: now, origin: origin,
                firstRetainedAt: visible.first?.event.at, lastRetainedAt: visible.last?.event.at,
                maximumAge: limits.age, maximumEvents: limits.events, maximumBytes: limits.bytes,
                rotatedEvents: metadata.rotated, writeFailures: metadata.writeFailures,
                unreadableLines: metadata.unreadable, recoveredLegacyEvents: metadata.recoveredLegacyEvents ?? 0,
                preservedRepairSourceBytes: metadata.preservedRepairSourceBytes,
                counterWindowStartedAt: metadata.counterWindowStartedAt,
                transportCounters: metadata.counters, lastAlarmReadinessEvidence: metadata.alarmReadiness, events: visible.map(\.event),
                clockNote: "at is origin device wall clock; uptime is monotonic within origin.process only. Cross-device clock offset is unknown. watchReceivedAt is the existing Watch reception timestamp. sensorTime is unknown when absent; elapsed sensor minutes are not a wall-clock timestamp.",
                coverageNote: "Only retained successfully appended events are included. Rotation is diagnostic retention, not lost glucose. Counters may omit the final 60 seconds after abrupt termination. No events from before this instrumentation are reconstructed. An event's localWriteConfirmed refers to the existing atomic outbox save, not this journal. recoveredLegacyEvents counts valid existing JSON events successfully rewritten without the known old delimiter padding; historical unreadableLines is not reduced. Before repair, the first bounded raw source is retained locally as delivery-events-v1.pre-repair.jsonl, not included in this export. Later damaged raw sources are not archived; unreadable lines remain counted.")
        }
    }

    func snapshotData() throws -> Data { try JSONEncoder().encode(snapshot()) }

    func exportFile(requestID: UUID) throws -> URL {
        let url = directory.appendingPathComponent("watch-evidence-\(requestID.uuidString).json")
        try replace(snapshotData(), url)
        return url
    }

    static func errorClass(_ error: Error) -> String {
        let error = error as NSError
        return "\(safeLabel(error.domain) ?? "unknown")_\(error.code)"
    }

    private static func safeLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_.:-="))
        return String(String.UnicodeScalarView(value.unicodeScalars.filter { allowed.contains($0) })).prefix(128).description
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let data: Data
        do {
            let size = try journalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= max(limits.bytes * 2, 16_384) else {
                metadata.unreadable &+= 1; journalNeedsRepair = true
                return
            }
            data = try Data(contentsOf: journalURL)
        } catch {
            metadata.unreadable &+= 1; journalNeedsRepair = true
            return
        }
        let parts = data.split(separator: 0x0a, omittingEmptySubsequences: false)
        // The released iPhone writer encoded Int(10) in little endian. Recover only its
        // exact seven NUL bytes after an observed LF, never arbitrary embedded corruption.
        let legacyPadding = Data(repeating: 0, count: 7)
        for (index, part) in parts.enumerated() where !part.isEmpty {
            let hasLegacyPadding = index > 0 && part.starts(with: legacyPadding)
            let cleaned = hasLegacyPadding ? Data(part.dropFirst(7)) : Data(part)
            if hasLegacyPadding {
                journalNeedsRepair = true
                // A complete old final delimiter leaves a seven-byte trailing fragment.
                if cleaned.isEmpty && index == parts.count - 1 { continue }
            }
            guard let event = try? JSONDecoder().decode(WatchDeliveryEvidenceEvent.self, from: cleaned) else {
                metadata.unreadable &+= 1; journalNeedsRepair = true; continue
            }
            if hasLegacyPadding {
                pendingLegacyRecoveredEvents &+= 1
            }
            var line = cleaned; line.append(UInt8(0x0a))
            records.append((event, line)); byteCount += line.count
            metadata.sequence = max(metadata.sequence, event.sequence)
        }
        if !data.isEmpty && data.last != 0x0a { journalNeedsRepair = true }
        if journalNeedsRepair, rewrite(records) { journalNeedsRepair = false }
        prune(at: clock())
        if records.count > limits.events || byteCount > limits.bytes { compactForCapacity(incomingBytes: 0) }
    }

    private func prune(at date: Date) {
        lastPrune = date
        let retained = records.filter { $0.event.at >= date.addingTimeInterval(-limits.age) }
        if retained.count != records.count { rewrite(retained) }
    }

    private func compactForCapacity(incomingBytes: Int) {
        var retained = records
        var size = byteCount
        let targetCount = max(0, limits.events * 3 / 4)
        let targetBytes = max(0, limits.bytes * 3 / 4 - incomingBytes)
        while !retained.isEmpty && (retained.count > targetCount || size > targetBytes) {
            size -= retained.removeFirst().line.count
        }
        rewrite(retained)
    }

    @discardableResult
    private func rewrite(_ retained: [(event: WatchDeliveryEvidenceEvent, line: Data)]) -> Bool {
        do {
            if journalNeedsRepair { try preserveFirstRepairSource() }
            let data = retained.reduce(into: Data()) { $0.append($1.line) }
            try replace(data, journalURL)
            // Do not persist a successful migration count while source preservation or
            // replacement is still failing; another process may need to retry that source.
            metadata.recoveredLegacyEvents = (metadata.recoveredLegacyEvents ?? 0) &+ pendingLegacyRecoveredEvents
            pendingLegacyRecoveredEvents = 0
            metadata.rotated &+= UInt64(records.count - retained.count)
            records = retained; byteCount = data.count
            journalNeedsRepair = false
            checkpoint(force: true)
            return true
        } catch { metadata.writeFailures &+= 1; return false }
    }

    /// One bounded original, not another journal. If preservation fails, do not destroy
    /// the damaged source or append to it. This failure never touches the clinical outbox.
    private func preserveFirstRepairSource() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        let size = try journalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= max(limits.bytes * 2, 16_384) else { throw CocoaError(.fileReadTooLarge) }
        if !FileManager.default.fileExists(atPath: repairSourceURL.path) {
            try replace(Data(contentsOf: journalURL), repairSourceURL)
        }
        metadata.preservedRepairSourceBytes = try repairSourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
    }

    private func checkpointIfDue() { checkpoint(force: uptime() - lastCheckpoint >= 60) }
    private func checkpoint(force: Bool) {
        guard force else { return }
        lastCheckpoint = uptime()
        do { try replace(JSONEncoder().encode(metadata), metadataURL) }
        catch { metadata.writeFailures &+= 1 }
    }
}

/// Concrete adapters are shared by production submit/save callbacks and deterministic tests.
/// These observe existing outcomes; they never accept, acknowledge or remove a reading themselves.
enum WatchDeliveryEvidencePipeline {
    static func stream(for item: LibreWatchOutboxItem) -> WatchDeliveryEvidenceStream {
        if item.reading != nil { return .reading }
        return item.command == .reportDiagnostic ? .diagnostic : .session
    }

    static func rejection(of reading: LibreWatchDirectReadingPayload,
                          policy: LibreWatchReadingAcceptancePolicy, at date: Date) -> String {
        if !reading.isValid(at: date) { return "invalidPayload" }
        if date.timeIntervalSince(reading.receivedAt) > LibreWatchReadingAcceptancePolicy.maximumTransportAge { return "tooOld" }
        if policy.acceptedPayloadIDs.contains(reading.id) { return "duplicatePayloadID" }
        if policy.lastSensorTimeInMinutes.map({ reading.sensorTimeInMinutes <= $0 }) == true { return "nonIncreasingSensorMinute" }
        if policy.lastReceivedAt.map({ reading.receivedAt <= $0 }) == true { return "nonIncreasingWatchReception" }
        return "acceptanceRejected"
    }

    static func localWrite(_ succeeded: Bool, item: LibreWatchOutboxItem,
                           failureReason: String = "atomicOutboxWriteFailed",
                           store: WatchDeliveryEvidenceStore = .shared) {
        guard let reading = item.reading else { return }
        store.recordReading(succeeded ? .localWriteConfirmed : .localWriteFailed, reading: reading,
                            outcome: succeeded ? "atomicOutboxSaved" : failureReason)
    }

    static func phoneStorage(_ stored: Bool, outcome: LibreWatchDeliveryOutcome,
                             reading: LibreWatchDirectReadingPayload,
                             store: WatchDeliveryEvidenceStore = .shared) {
        store.recordReading(stored ? .phoneStored : .phoneRejected, reading: reading, outcome: outcome.rawValue)
    }

    static func acknowledgement(reading: LibreWatchDirectReadingPayload, success: Bool,
                                durable: Bool, outcome: String?, store: WatchDeliveryEvidenceStore = .shared) {
        store.recordReading(.acknowledgement, reading: reading,
            outcome: "success=\(success):durable=\(durable):\(outcome ?? "unknown")", stream: .receipt)
        store.recordTransport(stream: .receipt, action: "received", outcome: outcome)
    }
}
