import Foundation
import CryptoKit

/// The production request/reply + push boundary. All calls and completions run on main.
/// Dependencies include the actual database builder and WC sender so tests exercise the
/// same coalescing, caching, correlation and acknowledgement path as WatchManager.
final class WatchPhoneRefreshService {
    typealias Payload = [String: Any]
    typealias Reply = (Payload) -> Void
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    struct Query {
        let id: String
        let streams: Set<String>
        let known: [String: String]
        let raw: Payload
        var agpKey: String? {
            guard streams.contains("agp"), let start = raw["visibleStartDate"] as? Double,
                  let end = raw["visibleEndDate"] as? Double, start.isFinite, end.isFinite,
                  end > start, end - start <= 7 * 86400 else { return nil }
            // A scrolling minute is a local projection, not a new AGP dataset.
            let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: end)).timeIntervalSince1970
            return "\(day):\(Int(((end - start) / 60).rounded()))"
        }
    }
    private struct Cached {
        var payload: Payload
        let contentID: String
        var checked: TimeInterval
        var agpKey: String?
    }
    private struct Waiting { let query: Query; let reply: Reply }
    private let now: () -> TimeInterval
    private let wall: () -> Date
    private let schedule: Schedule
    private let build: (Set<String>, Payload, @escaping (Payload) -> Void) -> Void
    private let generation: () -> Payload
    private let sessionScope: () -> String
    private let controlSnapshot: () -> Payload
    private let publishContext: (Payload) -> Bool
    private let sendPush: (Payload, @escaping (Bool, Bool) -> Void) -> Void
    private let event: (String, String) -> Void
    private var cache: [String: Cached] = [:]
    private var versions: [String: UInt64] = [:]
    private var builtVersions: [String: UInt64] = [:]
    private var waiting: [Waiting] = []
    private var pushWanted: Set<String> = []
    private var scheduled = false
    private var building = false
    private var buildID: UUID?
    private var changedDuringBuild = false
    private var pushID: UUID?
    private var pushDeadline: TimeInterval = 0
    private var nextPush: TimeInterval = 0
    private var pushFailures = 0
    private var lastPushed: [String: String] = [:]
    private var legacyPeer = false
    private var lastScope: String?
    private var pendingContext: Payload = [:]
    private var nextContext: TimeInterval = 0
    private var contextFailures = 0
    private var legacyAGPResponse: Payload?

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wall: @escaping () -> Date = Date.init, schedule: @escaping Schedule,
         build: @escaping (Set<String>, Payload, @escaping (Payload) -> Void) -> Void,
         generation: @escaping () -> Payload, sessionScope: @escaping () -> String,
         controlSnapshot: @escaping () -> Payload,
         publishContext: @escaping (Payload) -> Bool,
         sendPush: @escaping (Payload, @escaping (Bool, Bool) -> Void) -> Void,
         event: @escaping (String, String) -> Void = { _, _ in }) {
        self.now = now; self.wall = wall; self.schedule = schedule; self.build = build
        self.generation = generation; self.sessionScope = sessionScope
        self.controlSnapshot = controlSnapshot; self.publishContext = publishContext
        self.sendPush = sendPush; self.event = event
    }

    @discardableResult
    func receive(_ message: Payload, reply: @escaping Reply) -> Bool {
        guard message["requestWatchUpdate"] as? String == "snapshot" else { return false }
        guard message["watchRefreshProtocol"] as? Int == 1,
              let id = message["requestID"] as? String, UUID(uuidString: id) != nil,
              let requested = message["streams"] as? [String], !requested.isEmpty,
              Set(requested).isSubset(of: ["status", "bgReadings", "agp"]) else {
            reply(["success": false, "watchRefreshUnsupported": true]); return true
        }
        guard waiting.count < 16 else {
            reply(["watchRefreshProtocol": 1, "requestID": id, "success": false, "error": "busy"])
            event("statusGraph", "requestRejectedBusy"); return true
        }
        legacyPeer = false
        let query = Query(id: id, streams: Set(requested), known: message["knownContentIDs"] as? [String: String] ?? [:], raw: message)
        if query.streams.contains("agp"), query.agpKey == nil {
            reply(["watchRefreshProtocol": 1, "requestID": id, "success": false, "error": "invalidAGPRange"])
            return true
        }
        waiting.append(Waiting(query: query, reply: reply))
        record(query.streams, "requestReceived")
        enqueue()
        return true
    }

    /// Dirty comes only from actual data/settings notifications, never a remote poll.
    func changed(_ streams: Set<String>) {
        if building { changedDuringBuild = true }
        for stream in streams { versions[stream, default: 0] &+= 1 }
        if streams.contains("bgReadings") { versions["agp", default: 0] &+= 1 }
        pushWanted.formUnion(streams.intersection(["status", "bgReadings"]))
        enqueue()
    }

    func refreshLegacy(_ streams: Set<String>, raw: Payload = [:]) {
        // Old Watches receive one coalesced push, never an extra session transaction.
        if streams.contains("agp") {
            var request = raw
            request["requestWatchUpdate"] = "snapshot"; request["watchRefreshProtocol"] = 1
            request["requestID"] = UUID().uuidString; request["streams"] = ["agp"]
            request["agpRequestID"] = raw["requestID"]
            _ = receive(request) { [weak self] payload in
                guard let self, let agp = payload["agp"] as? Payload else { return }
                // Coalesce overlapping legacy AGP wishes to the newest correlation.
                // The same push gate prevents independent no-reply sends from piling up.
                self.legacyAGPResponse = agp
            }
        }
        legacyPeer = true
        pushWanted.formUnion(streams.intersection(["status", "bgReadings"]))
        enqueue()
    }

    func reachable() {
        // A genuine link return is a new opportunity, not proof of a previous delivery.
        // Legacy has no correlated acknowledgement; a flapping link must not bypass
        // its minimum interval and turn compatibility into a second request storm.
        if !legacyPeer { nextPush = now() }
        nextContext = now()
        pushWanted.formUnion(["status", "bgReadings"])
        enqueue()
    }

    private func enqueue() {
        if scheduled || building { event("statusGraph", "coalesced"); return }
        scheduled = true
        schedule(0.25) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.drain()
        }
    }

    private func drain() {
        guard !building else { return }
        let scope = sessionScope()
        if lastScope != scope {
            cache.removeAll(); builtVersions.removeAll(); lastPushed.removeAll(); lastScope = scope
            pendingContext.removeAll(); contextFailures = 0; nextContext = now()
            legacyAGPResponse = nil
        }
        var streams = waiting.reduce(pushWanted) { $0.union($1.query.streams) }
        streams.formUnion(Set(pendingContext.keys).intersection(["status", "bgReadings"]))
        // A push waiting for its retry does not provoke repeated DB work.
        if waiting.isEmpty, now() < nextPush, pendingContext.isEmpty || now() < nextContext { return }
        guard !streams.isEmpty else { flushContext(); sendPendingPush(); return }
        // Serve the oldest AGP range first. Later requests may require a subsequent
        // calculation, but must not be failed or starved by a newer range.
        let raw = waiting.first(where: { $0.query.streams.contains("agp") })?.query.raw ?? [:]
        let agpKey = waiting.first(where: { $0.query.streams.contains("agp") })?.query.agpKey
        streams = streams.filter { stream in
            guard let value = cache[stream] else { return true }
            return builtVersions[stream] != versions[stream, default: 0] ||
                now() - value.checked >= (stream == "agp" ? 900 : 60) ||
                (stream == "agp" && value.agpKey != agpKey)
        }
        guard !streams.isEmpty else { finish(); return }
        building = true
        changedDuringBuild = false
        let token = UUID(); buildID = token
        let capturedVersions = versions
        schedule(5) { [weak self] in
            guard let self, self.buildID == token else { return }
            self.buildID = nil; self.building = false
            let failed = self.waiting; self.waiting.removeAll()
            for pending in failed {
                pending.reply(["watchRefreshProtocol": 1, "requestID": pending.query.id,
                               "success": false, "error": "buildTimeout"])
            }
            self.nextPush = max(self.nextPush, self.now() + 5)
            self.record(streams, "buildTimeout")
            // The next explicit request/data opportunity can retry; late work is inert.
        }
        build(streams, raw) { [weak self] payload in
            guard let self, self.buildID == token else { return }
            self.buildID = nil
            self.building = false
            // Ownership/sensor may have changed during asynchronous AGP calculation.
            guard self.sessionScope() == scope else { self.enqueue(); return }
            var changed: Set<String> = []
            var failed: Set<String> = []
            for stream in streams {
                guard var body = payload[stream] as? Payload,
                      let fingerprint = Self.contentID(body, scope: scope) else {
                    failed.insert(stream); self.event(stream, "buildFailed"); continue
                }
                if self.cache[stream]?.contentID == fingerprint {
                    self.cache[stream]?.checked = self.now()
                    self.cache[stream]?.agpKey = agpKey
                    self.cache[stream]?.payload["snapshotValidatedAt"] = self.wall().timeIntervalSince1970
                    self.event(stream, "unchangedSuppressed")
                } else {
                    if stream != "agp" { body = WatchPhoneSnapshotStore.attaching(self.generation(), to: body) }
                    body["snapshotContentID"] = fingerprint
                    body["snapshotValidatedAt"] = self.wall().timeIntervalSince1970
                    self.cache[stream] = Cached(payload: body, contentID: fingerprint, checked: self.now(), agpKey: agpKey)
                    changed.insert(stream)
                    self.event(stream, "contentChanged")
                }
                self.builtVersions[stream] = capturedVersions[stream, default: 0]
            }
            if !changed.isEmpty { self.queueContext(self.body(for: changed)) }
            self.finish(failed: failed, attemptedAGPKey: agpKey)
        }
    }

    private func finish(failed: Set<String> = [], attemptedAGPKey: String? = nil) {
        let replies = waiting; waiting.removeAll()
        for pending in replies {
            let missing = pending.query.streams.filter { stream in
                guard let cached = cache[stream] else { return true }
                return stream == "agp" && cached.agpKey != pending.query.agpKey
            }
            let failedRequest = pending.query.streams.contains { stream in
                failed.contains(stream) && (stream != "agp" || pending.query.agpKey == attemptedAGPKey)
            }
            if !missing.isEmpty, !failedRequest {
                // These streams arrived after the current builder started (or ask for
                // another AGP range). Preserve their callbacks for the next batch.
                waiting.append(pending)
                continue
            }
            var result: Payload = ["watchRefreshProtocol": 1, "requestID": pending.query.id,
                                   "success": !failedRequest, "checkedAt": wall().timeIntervalSince1970]
            if failedRequest { result["error"] = "buildFailed" }
            var unchanged: [String] = []; var ids: [String: String] = [:]
            for stream in pending.query.streams {
                guard let cached = cache[stream] else { result["success"] = false; continue }
                if stream == "agp", cached.agpKey != pending.query.agpKey { result["success"] = false; continue }
                ids[stream] = cached.contentID
                if pending.query.known[stream] == cached.contentID { unchanged.append(stream) }
                else {
                    var payload = cached.payload
                    if stream == "agp" {
                        payload["requestID"] = pending.query.raw["agpRequestID"]
                        payload["visibleStartDateAsDouble"] = pending.query.raw["visibleStartDate"]
                        payload["visibleEndDateAsDouble"] = pending.query.raw["visibleEndDate"]
                    }
                    result[stream] = payload
                }
            }
            result["contentIDs"] = ids; result["unchangedStreams"] = unchanged
            // A cached, semantically valid control snapshot does not mint a revision.
            result.merge(controlSnapshot()) { _, new in new }
            pending.reply(result)
            // The solicited reply is the response; do not also send the same snapshot
            // as an unsolicited message. A lost reply is retried by its correlated request.
            if !failedRequest { lastPushed.merge(ids) { _, new in new } }
            record(pending.query.streams, failedRequest ? "replyFailed" : "replyCompleted")
        }
        flushContext()
        sendPendingPush()
        // A genuine mutation during build must not disappear behind a completed request.
        if changedDuringBuild || !waiting.isEmpty {
            changedDuringBuild = false
            enqueue()
        }
    }

    private func queueContext(_ payload: Payload) {
        pendingContext = Self.merging(payload, into: pendingContext)
        flushContext()
    }

    private func flushContext() {
        guard !pendingContext.isEmpty, now() >= nextContext else { return }
        // A retained transport attempt may outlive its original envelope's freshness.
        // Use the most recently checked body without manufacturing a measurement date.
        for stream in ["status", "bgReadings"] where pendingContext[stream] != nil {
            if let cached = cache[stream] { pendingContext[stream] = cached.payload }
        }
        let streams = Set(pendingContext.keys).intersection(["status", "bgReadings", "agp"])
        record(streams, "contextAttempt")
        if publishContext(pendingContext) {
            pendingContext.removeAll(); contextFailures = 0; nextContext = now()
            record(streams, "contextSubmitted")
        } else {
            contextFailures = min(contextFailures + 1, 6)
            nextContext = now() + min(120, 5 * pow(2, Double(contextFailures - 1)))
            record(streams, "contextRetainedAfterFailure")
        }
        // Recheck on real request/data/activation opportunities; this is not a wake timer.
    }

    private func body(for streams: Set<String>) -> Payload {
        var result: Payload = ["watchRefreshProtocol": 1]
        var ids: [String: String] = [:]
        for stream in streams {
            guard let cached = cache[stream] else { continue }
            result[stream] = cached.payload; ids[stream] = cached.contentID
        }
        result["contentIDs"] = ids
        return result
    }

    private func sendPendingPush() {
        guard pushID == nil, now() >= nextPush else { return }
        // A reply can acknowledge the cache built before a concurrent mutation. Its
        // content ID is not proof that the newer dirty generation has been delivered.
        // Keep that demand until the database builder captures the current version.
        let current = pushWanted.filter {
            cache[$0] != nil && builtVersions[$0] == versions[$0, default: 0]
        }
        let streams = current.filter { lastPushed[$0] != cache[$0]?.contentID }
        pushWanted.subtract(current.filter { lastPushed[$0] == cache[$0]?.contentID })
        guard !streams.isEmpty || legacyAGPResponse != nil else { return }
        let id = UUID(); pushID = id; pushDeadline = now() + 8
        var payload = body(for: streams)
        let sentLegacyAGP = legacyAGPResponse
        legacyAGPResponse = nil
        if let sentLegacyAGP {
            payload["agp"] = sentLegacyAGP
            queueContext(["agp": sentLegacyAGP])
        }
        let sentStreams = sentLegacyAGP == nil ? streams : streams.union(["agp"])
        let sentIDs = payload["contentIDs"] as? [String: String] ?? [:]
        payload["watchSnapshotPush"] = 1; payload["pushID"] = id.uuidString
        payload["legacySnapshot"] = legacyPeer
        record(sentStreams, "pushAttempt")
        sendPush(payload) { [weak self] success, unsupported in
            guard let self, self.pushID == id else { return }
            guard self.now() < self.pushDeadline else {
                self.pushID = nil
                if self.legacyAGPResponse == nil { self.legacyAGPResponse = sentLegacyAGP }
                self.failPush("pushTimeout", streams: sentStreams)
                return
            }
            self.pushID = nil
            if unsupported { self.legacyPeer = true }
            if success {
                self.lastPushed.merge(sentIDs) { _, new in new }
                self.pushFailures = 0; self.nextPush = self.now() + (self.legacyPeer ? 60 : 0)
                self.record(sentStreams, self.legacyPeer ? "legacySubmittedUnconfirmed" : "pushAcknowledged")
            } else {
                if self.legacyAGPResponse == nil { self.legacyAGPResponse = sentLegacyAGP }
                self.failPush(unsupported ? "peerUnsupported" : "pushFailed", streams: sentStreams)
            }
            if !self.pushWanted.isEmpty || self.legacyAGPResponse != nil { self.enqueue() }
        }
        schedule(8) { [weak self] in
            guard let self, self.pushID == id, self.now() >= self.pushDeadline else { return }
            self.pushID = nil
            if self.legacyAGPResponse == nil { self.legacyAGPResponse = sentLegacyAGP }
            self.failPush("pushTimeout", streams: sentStreams)
        }
    }

    private func failPush(_ outcome: String, streams: Set<String>) {
        pushFailures = min(pushFailures + 1, 6)
        let delay = min(120, 5 * pow(2, Double(pushFailures - 1)))
        nextPush = now() + (legacyPeer ? max(60, delay) : delay)
        record(streams, outcome)
        // No background wake timer: a later data/activation/reachability opportunity retries.
    }

    private func record(_ streams: Set<String>, _ action: String) {
        for stream in streams { event(stream, action) }
    }

    static func contentID(_ payload: Payload, scope: String) -> String? {
        func semantic(_ value: Any) -> Any {
            if let dictionary = value as? Payload {
                let ignored: Set<String> = ["generatedAt", "sensorAgeInMinutes", "snapshotValidatedAt",
                    "snapshotGeneration", "snapshotContentID", "requestID", "visibleStartDateAsDouble", "visibleEndDateAsDouble"]
                return dictionary.filter { !ignored.contains($0.key) }.mapValues(semantic)
            }
            if let array = value as? [Any] { return array.map(semantic) }
            return value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["scope": scope, "payload": semantic(payload)], options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Both senders use read/merge/write on main. Partial contentIDs must merge too.
    static func merging(_ incoming: Payload, into existing: Payload) -> Payload {
        var result = existing
        result.merge(incoming) { _, new in new }
        if let newIDs = incoming["contentIDs"] as? [String: String] {
            var ids = existing["contentIDs"] as? [String: String] ?? [:]
            ids.merge(newIDs) { _, new in new }; result["contentIDs"] = ids
        }
        return result
    }
}
