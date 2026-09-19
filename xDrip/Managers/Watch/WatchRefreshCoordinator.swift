import Foundation

/// The status/graph push acknowledgement used by both WCSession adapters. This is
/// separate from glucose-storage receipts. Protocol 1 accepts the 4260/4261 Watch's
/// success field and emits both names so a 4261 phone can understand a newer Watch.
/// Compatibility never bypasses the protocol/UUID/stream checks for a positive ACK.
enum WatchSnapshotPushContract {
    typealias Payload = [String: Any]
    struct Outcome {
        let acknowledged: Bool
        let unsupported: Bool
    }

    static func reply(to message: Payload, consume: WatchRefreshCoordinator.Consumer) -> Payload {
        var reply: Payload = ["success": false, LibreWatchMessageKey.success: false]
        if let version = message["watchSnapshotPush"] { reply["watchSnapshotPush"] = version }
        if let id = message["pushID"] as? String { reply["pushID"] = id }
        guard message["watchSnapshotPush"] as? Int == 1,
              let id = message["pushID"] as? String, UUID(uuidString: id) != nil else { return reply }
        let requested = streams(in: message)
        guard !requested.isEmpty else { return reply }
        // The consumer validates/persists synchronously before we acknowledge it.
        let accepted = consume(message).intersection(requested)
        let success = requested.isSubset(of: accepted)
        reply["success"] = success
        reply[LibreWatchMessageKey.success] = success
        reply["acceptedStreams"] = accepted.map(\.rawValue).sorted()
        reply["rejectedOrSupersededStreams"] = requested.subtracting(accepted).map(\.rawValue).sorted()
        return reply
    }

    static func outcome(for reply: Payload, sent message: Payload) -> Outcome {
        let rejected = Outcome(acknowledged: false, unsupported: false)
        guard message["watchSnapshotPush"] as? Int == 1,
              let id = message["pushID"] as? String, UUID(uuidString: id) != nil,
              !streams(in: message).isEmpty else { return rejected }
        // Older Watches explicitly reject the unsupported reply-handler overload.
        // Only that uncorrelated negative response enables the service's existing
        // rate-limited legacy mode; malformed modern replies must not downgrade it.
        if reply["watchSnapshotPush"] == nil, reply["pushID"] == nil, success(in: reply) == false {
            return Outcome(acknowledged: false, unsupported: true)
        }
        guard reply["watchSnapshotPush"] as? Int == 1, reply["pushID"] as? String == id,
              success(in: reply) == true,
              let accepted = reply["acceptedStreams"] as? [String],
              streams(in: message).map(\.rawValue).allSatisfy(accepted.contains),
              Set(accepted).isSubset(of: Set(WatchRefreshCoordinator.Stream.allCases.map(\.rawValue))) else { return rejected }
        return Outcome(acknowledged: true, unsupported: false)
    }

    private static func streams(in message: Payload) -> Set<WatchRefreshCoordinator.Stream> {
        Set(WatchRefreshCoordinator.Stream.allCases.filter { message[$0.rawValue] != nil })
    }

    private static func success(in reply: Payload) -> Bool? {
        let current = reply["success"] as? Bool
        let previous = reply[LibreWatchMessageKey.success] as? Bool
        if reply["success"] != nil && current == nil { return nil }
        if reply[LibreWatchMessageKey.success] != nil && previous == nil { return nil }
        if let current, let previous, current != previous { return nil }
        return current ?? previous
    }
}

/// The production request/reply boundary shared by every Watch page. All methods and
/// callbacks run on the owner's serial queue (the main queue in WatchStateModel).
/// Scheduled work only runs during an existing foreground execution opportunity;
/// none of these deadlines requests or extends watchOS background execution.
final class WatchRefreshCoordinator {
    enum Stream: String, CaseIterable, Hashable { case status, bgReadings, agp }
    struct Configuration {
        var coalescingDelay: TimeInterval = 0.25
        var timeout: TimeInterval = 8
        var statusLifetime: TimeInterval = 60
        var graphLifetime: TimeInterval = 60
        var agpLifetime: TimeInterval = 15 * 60
        var initialRetry: TimeInterval = 5
        var maximumRetry: TimeInterval = 120
        var legacyMinimumInterval: TimeInterval = 60
    }
    typealias Sender = ([String: Any], (([String: Any]) -> Void)?, @escaping (Error) -> Void) -> Void
    typealias Consumer = ([String: Any]) -> Set<Stream>

    private struct Attempt {
        let id: String
        let streams: Set<Stream>
        let startedAt: TimeInterval
        let contentIDs: [String: String]
        var received: Set<Stream> = []
    }
    private enum Peer { case unknown, current, legacy }
    private let configuration: Configuration
    private let clock: () -> TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let isReachable: () -> Bool
    private let sender: Sender
    private let consume: Consumer
    private let event: (Stream, String, String?) -> Void
    private var peer = Peer.unknown
    private var active = false
    private var visibleStreams: Set<Stream> = [.status, .bgReadings]
    private var requested: Set<Stream> = []
    private var forced: Set<Stream> = []
    private var attempt: Attempt?
    private var scheduledToken = UUID()
    private var failureCount = 0
    private var agpFailureCount = 0
    private var contentIDs: [String: String] = [:]
    private var lastReceived: [Stream: TimeInterval] = [:]
    private var agpRange: (start: Date, end: Date)?
    private var agpSequence: Double = 0
    private var lastLegacyAttempt: TimeInterval?

    private(set) var lastAttemptAt: TimeInterval?
    private(set) var nextAllowedAttemptAt: TimeInterval = 0
    private(set) var agpNextAllowedAttemptAt: TimeInterval = 0
    var inFlightRequestID: String? { attempt?.id }
    var usesLegacyCompatibility: Bool { peer == .legacy }
    var latestAGPRequestID: Double { agpSequence }

    init(configuration: Configuration = Configuration(),
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         isReachable: @escaping () -> Bool,
         send: @escaping Sender,
         consume: @escaping Consumer,
         event: @escaping (Stream, String, String?) -> Void = { _, _, _ in }) {
        self.configuration = configuration
        self.clock = clock
        self.schedule = schedule
        self.isReachable = isReachable
        sender = send
        self.consume = consume
        self.event = event
    }

    func setExecutionAvailable(_ available: Bool) {
        active = available
        scheduledToken = UUID()
        guard available else { return }
        requested.formUnion(visibleStreams)
        if let attempt, clock() - attempt.startedAt >= configuration.timeout {
            fail(id: attempt.id, reason: "timeout")
        }
        enqueue()
    }

    func setVisibleStreams(_ streams: Set<Stream>) {
        visibleStreams = streams
        requested.formIntersection(streams)
        forced.formIntersection(streams)
        request(streams)
    }

    func setAGPRange(start: Date, end: Date) {
        guard start < end else { return }
        agpRange = (start, end)
        if visibleStreams.contains(.agp) { request([.agp]) }
    }

    /// View requests share the active attempt; they never use sensor age as an input.
    func request(_ streams: Set<Stream>? = nil, force: Bool = false) {
        let wanted = (streams ?? visibleStreams).intersection(visibleStreams)
        for stream in wanted {
            if attempt?.streams.contains(stream) == true || requested.contains(stream) {
                event(stream, "coalesced", nil)
            }
        }
        let notInFlight = wanted.subtracting(attempt?.streams ?? [])
        requested.formUnion(notInFlight)
        if force { forced.formUnion(notInFlight) }
        enqueue()
    }

    func reachabilityDidChange() {
        if let attempt, clock() - attempt.startedAt >= configuration.timeout {
            fail(id: attempt.id, reason: "timeout")
        }
        requested.formUnion(visibleStreams.subtracting(attempt?.streams ?? []))
        enqueue()
    }

    /// Real unsolicited pushes retain independent generation/measurement validation in
    /// the consumer. Receiving one cannot complete an unrelated modern request.
    @discardableResult
    func receivePush(_ payload: [String: Any]) -> Set<Stream> {
        var deliverable = payload
        if peer != .legacy, payload[Stream.agp.rawValue] != nil {
            // Modern AGP is returned only through its correlated request. An old
            // application context has no request UUID and cannot replace that profile.
            deliverable.removeValue(forKey: Stream.agp.rawValue)
            event(.agp, "suppressed", "requiresCorrelatedReply")
        }
        let accepted = consume(deliverable)
        observe(accepted, payload: payload)
        for stream in Stream.allCases where payload[stream.rawValue] != nil && !accepted.contains(stream) {
            event(stream, "suppressed", "rejectedOrSuperseded")
        }
        if peer == .legacy, var current = attempt {
            current.received.formUnion(accepted)
            attempt = current
            if current.streams.isSubset(of: current.received) { finish(id: current.id) }
        }
        enqueue()
        return accepted
    }

    private func lifetime(_ stream: Stream) -> TimeInterval {
        switch stream {
        case .status: return configuration.statusLifetime
        case .bgReadings: return configuration.graphLifetime
        case .agp: return configuration.agpLifetime
        }
    }

    private func due(_ stream: Stream) -> Bool {
        forced.contains(stream) || lastReceived[stream].map { clock() - $0 >= lifetime(stream) } != false
    }

    private func allowedAt(_ stream: Stream) -> TimeInterval {
        stream == .agp ? max(nextAllowedAttemptAt, agpNextAllowedAttemptAt) : nextAllowedAttemptAt
    }

    private func enqueue() {
        guard active else { return }
        let token = UUID()
        scheduledToken = token
        let delay: TimeInterval
        if let attempt {
            delay = max(0, attempt.startedAt + configuration.timeout - clock())
        } else {
            let pending = requested.filter { due($0) && ($0 != .agp || agpRange != nil) }
            if !pending.isEmpty, !isReachable() { return }
            let retry = pending.map { allowedAt($0) }.min()
            let expiry = visibleStreams.filter { !due($0) }.compactMap { stream in
                lastReceived[stream].map { $0 + lifetime(stream) }
            }.min()
            // An AGP-only retry cannot postpone the next status/graph cache expiry.
            guard let next = [retry, expiry].compactMap({ $0 }).min() else { return }
            delay = max(configuration.coalescingDelay, next - clock())
        }
        schedule(delay) { [weak self] in
            guard let self, self.active, self.scheduledToken == token else { return }
            if let attempt = self.attempt {
                self.fail(id: attempt.id, reason: "timeout")
            } else {
                self.requested.formUnion(self.visibleStreams)
                self.startIfPossible()
            }
        }
    }

    private func startIfPossible() {
        guard active, attempt == nil, isReachable(), clock() >= nextAllowedAttemptAt else { enqueue(); return }
        var streams = requested.filter { due($0) && clock() >= allowedAt($0) }
        for stream in requested where !due(stream) { event(stream, "suppressed", "fresh") }
        if agpRange == nil { streams.remove(.agp) }
        requested.subtract(streams)
        guard !streams.isEmpty else { enqueue(); return }
        let current = Attempt(id: UUID().uuidString, streams: streams, startedAt: clock(), contentIDs: contentIDs)
        attempt = current
        lastAttemptAt = clock()
        forced.subtract(streams)
        if streams.contains(.agp) { agpSequence += 1 }
        for stream in streams { event(stream, "attempt", peer == .legacy ? "legacy" : "requestReply") }
        enqueue() // Arm before send: test transports may call back synchronously.
        if peer == .legacy {
            sendLegacy(current)
        } else {
            var message: [String: Any] = ["requestWatchUpdate": "snapshot", "watchRefreshProtocol": 1,
                "requestID": current.id, "streams": streams.map(\.rawValue).sorted(), "knownContentIDs": contentIDs]
            if streams.contains(.agp) { addAGPRange(to: &message) }
            sender(message, { [weak self] reply in self?.receiveReply(reply, id: current.id) },
                   { [weak self] error in self?.fail(id: current.id, reason: Self.errorClass(error)) })
        }
    }

    private func addAGPRange(to message: inout [String: Any]) {
        if let range = agpRange {
            message["visibleStartDate"] = range.start.timeIntervalSince1970
            message["visibleEndDate"] = range.end.timeIntervalSince1970
            message["agpRequestID"] = agpSequence
        }
    }

    private func receiveReply(_ reply: [String: Any], id: String) {
        guard let current = attempt, current.id == id else {
            event(.status, "suppressed", "lateOrDuplicateReply")
            return
        }
        guard clock() - current.startedAt < configuration.timeout else {
            // The app may have suspended before the scheduled timeout could execute.
            // A delayed callback cannot extend its own deadline on resumption.
            fail(id: id, reason: "timeout")
            return
        }
        // 4259 explicitly replies { success:false } to this unsupported overload.
        // Never downgrade because a reachable check races, a callback is missing, or
        // an arbitrary modern response is malformed. One bounded legacy mode per run.
        if peer == .unknown, reply["watchRefreshProtocol"] == nil,
           reply[LibreWatchMessageKey.success] as? Bool == false {
            peer = .legacy
            for stream in current.streams { event(stream, "compatibility", "unsupported") }
            sendLegacy(current)
            return
        }
        guard reply["watchRefreshProtocol"] as? Int == 1,
              reply["requestID"] as? String == id else { fail(id: id, reason: "invalidReply"); return }
        peer = .current
        var accepted = consume(reply)
        let returnedIDs = reply["contentIDs"] as? [String: String] ?? [:]
        for key in reply["unchangedStreams"] as? [String] ?? [] {
            guard let stream = Stream(rawValue: key), current.streams.contains(stream),
                  let known = current.contentIDs[key], returnedIDs[key] == known,
                  contentIDs[key] == known else { continue }
            accepted.insert(stream)
        }
        observe(accepted, payload: reply)
        // A newer validated push can supersede this reply while it was being built.
        // Treat that stream as delivered; do not replace the push's cached identity.
        let newerPush = current.streams.filter { stream in
            guard let receivedAt = lastReceived[stream] else { return false }
            return receivedAt >= current.startedAt && contentIDs[stream.rawValue] != current.contentIDs[stream.rawValue]
        }
        accepted.formUnion(newerPush)
        if accepted.contains(.agp) { agpFailureCount = 0; agpNextAllowedAttemptAt = clock() }
        if current.streams.isSubset(of: accepted) { finish(id: id) }
        else { fail(id: id, reason: "incompleteReply", retrying: current.streams.subtracting(accepted)) }
    }

    private func sendLegacy(_ current: Attempt) {
        if let previous = lastLegacyAttempt, clock() - previous < configuration.legacyMinimumInterval {
            fail(id: current.id, reason: "legacyRateLimit")
            return
        }
        lastLegacyAttempt = clock()
        nextAllowedAttemptAt = max(nextAllowedAttemptAt, clock() + configuration.legacyMinimumInterval)
        for stream in current.streams.sorted(by: { $0.rawValue < $1.rawValue }) {
            var message: [String: Any] = ["requestWatchUpdate": stream.rawValue]
            if stream == .agp { addAGPRange(to: &message); message["requestID"] = agpSequence }
            sender(message, nil, { [weak self] error in self?.fail(id: current.id, reason: Self.errorClass(error)) })
        }
    }

    private func observe(_ streams: Set<Stream>, payload: [String: Any]) {
        let identities = payload["contentIDs"] as? [String: String] ?? [:]
        if streams.contains(.bgReadings), !streams.contains(.agp), visibleStreams.contains(.agp),
           let previous = contentIDs[Stream.bgReadings.rawValue],
           let incoming = identities[Stream.bgReadings.rawValue], previous != incoming {
            // A visible AGP profile may need new statistics after a real data change.
            // Changing a clock/transport revision cannot invalidate this content key.
            requested.insert(.agp)
            forced.insert(.agp)
        }
        for stream in streams {
            lastReceived[stream] = clock()
            if let identity = identities[stream.rawValue] { contentIDs[stream.rawValue] = identity }
            event(stream, "received", "validated")
        }
    }

    private func finish(id: String) {
        guard attempt?.id == id else { return }
        attempt = nil
        failureCount = 0
        if peer != .legacy { nextAllowedAttemptAt = clock() }
        enqueue()
    }

    private func fail(id: String, reason: String, retrying missing: Set<Stream>? = nil) {
        guard let current = attempt, current.id == id else { return }
        attempt = nil
        let failed = missing ?? current.streams
        requested.formUnion(failed.intersection(visibleStreams))
        if failed == [.agp], peer != .legacy {
            agpFailureCount = min(agpFailureCount + 1, 10)
            let delay = min(configuration.maximumRetry, configuration.initialRetry * pow(2, Double(agpFailureCount - 1)))
            agpNextAllowedAttemptAt = clock() + delay
            // A valid partial reply proves status/graph transport succeeded. Their next
            // expiry/manual refresh remains independent of a busy statistics calculation.
            if missing != nil { failureCount = 0; nextAllowedAttemptAt = clock() }
        } else {
            failureCount = min(failureCount + 1, 10)
            let delay = min(configuration.maximumRetry, configuration.initialRetry * pow(2, Double(failureCount - 1)))
            nextAllowedAttemptAt = max(nextAllowedAttemptAt, clock() + delay)
            if peer == .legacy { nextAllowedAttemptAt = max(nextAllowedAttemptAt, (lastLegacyAttempt ?? clock()) + configuration.legacyMinimumInterval) }
        }
        for stream in failed { event(stream, "failed", reason) }
        enqueue()
    }

    private static func errorClass(_ error: Error) -> String {
        let error = error as NSError
        // Domain/code are diagnostic evidence; localized text may contain peer details.
        return "\(error.domain):\(error.code)"
    }
}
