import XCTest
@testable import xdrip

/// Exercises the production wire encoder, sender callbacks, receiver correlation and
/// snapshot validator together. The harness replaces only WCSession and the clock.
final class WatchRefreshCoordinatorTests: XCTestCase {
    private final class Harness {
        struct Sent {
            let message: [String: Any]
            let reply: (([String: Any]) -> Void)?
            let failure: (Error) -> Void
        }
        var uptime: TimeInterval = 0
        let wall = Date(timeIntervalSince1970: 1_800_000_000)
        var reachable = true
        var sent: [Sent] = []
        var jobs: [(TimeInterval, () -> Void)] = []
        var events: [(WatchRefreshCoordinator.Stream, String, String?)] = []
        var onSend: ((Sent) -> Void)?
        var displayedReadingDate: Date?
        var appliedStatusLimit: Double?
        let suite = "WatchRefreshCoordinatorTests.\(UUID().uuidString)"
        lazy var defaults = UserDefaults(suiteName: suite)!
        lazy var client = WatchRefreshCoordinator(
            clock: { [unowned self] in uptime },
            schedule: { [unowned self] delay, action in jobs.append((uptime + delay, action)) },
            isReachable: { [unowned self] in reachable },
            send: { [unowned self] message, reply, failure in
                let value = Sent(message: message, reply: reply, failure: failure)
                sent.append(value); onSend?(value)
            },
            consume: { [unowned self] payload in consume(payload) },
            event: { [unowned self] stream, action, reason in events.append((stream, action, reason)) })

        deinit { defaults.removePersistentDomain(forName: suite) }
        func start() { client.setExecutionAvailable(true); advance(0.25) }
        func advance(_ elapsed: TimeInterval) {
            let target = uptime + elapsed
            var count = 0
            while let index = jobs.indices.filter({ jobs[$0].0 <= target }).min(by: { jobs[$0].0 < jobs[$1].0 }) {
                let job = jobs.remove(at: index)
                uptime = job.0
                job.1()
                count += 1
                if count > 10_000 { XCTFail("Scheduling failed to make progress"); break }
            }
            uptime = target
        }
        func consume(_ payload: [String: Any]) -> Set<WatchRefreshCoordinator.Stream> {
            var result: Set<WatchRefreshCoordinator.Stream> = []
            for stream in [WatchRefreshCoordinator.Stream.status, .bgReadings] {
                guard let dictionary = payload[stream.rawValue] as? [String: Any],
                      let snapshotStream = WatchPhoneSnapshotStore.Stream(rawValue: stream.rawValue) else { continue }
                let applied = WatchPhoneSnapshotStore.accept(dictionary, stream: snapshotStream, sessionID: nil,
                        displayedReadingDate: stream == .bgReadings ? displayedReadingDate : nil,
                        at: wall.addingTimeInterval(uptime), defaults: defaults)
                guard applied || WatchPhoneSnapshotStore.isCurrent(dictionary, stream: snapshotStream, sessionID: nil,
                    at: wall.addingTimeInterval(uptime), defaults: defaults) else { continue }
                result.insert(stream)
                guard applied else { continue }
                if stream == .bgReadings, let dates = dictionary["bgReadingDatesAsDouble"] as? [Double], let first = dates.first {
                    displayedReadingDate = Date(timeIntervalSince1970: first)
                }
                if stream == .status { appliedStatusLimit = dictionary["lowLimitInMgDl"] as? Double }
            }
            if payload["agp"] is [String: Any] { result.insert(.agp) }
            return result
        }
        func payload(offset: TimeInterval = 0, lowLimit: Double = 80, identity: String = "a") -> [String: Any] {
            let date = wall.addingTimeInterval(offset)
            let status: [String: Any] = ["generatedAt": date.timeIntervalSince1970, "isMgDl": true,
                "isMaster": true, "keepAliveIsDisabled": false, "sensorAgeInMinutes": 50.0,
                "sensorMaxAgeInMinutes": 20_160.0, "urgentLowLimitInMgDl": 60.0,
                "lowLimitInMgDl": lowLimit, "highLimitInMgDl": 170.0, "urgentHighLimitInMgDl": 250.0]
            let graph: [String: Any] = ["generatedAt": date.timeIntervalSince1970,
                "bgReadingDatesAsDouble": [date.timeIntervalSince1970], "bgReadingValues": [123.0],
                "slopeOrdinal": 2, "deltaValueInUserUnit": 0.0]
            return ["status": WatchPhoneSnapshotStore.attaching(WatchPhoneSnapshotStore.nextGeneration(sessionID: nil, at: date, defaults: defaults), to: status),
                "bgReadings": WatchPhoneSnapshotStore.attaching(WatchPhoneSnapshotStore.nextGeneration(sessionID: nil, at: date, defaults: defaults), to: graph),
                "contentIDs": ["status": "s-\(identity)", "bgReadings": "g-\(identity)"]]
        }
        func respond(_ index: Int, payload: [String: Any]? = nil) {
            var reply = payload ?? self.payload(offset: uptime)
            reply["watchRefreshProtocol"] = 1
            reply["requestID"] = sent[index].message["requestID"]
            sent[index].reply?(reply)
        }
    }

    private final class PairedHarness {
        let watch = Harness()
        var builds: [Set<String>] = []
        var published: [[String: Any]] = []
        var pendingBuild: (([String: Any]) -> Void)?
        var suspendBuilder = false
        var dataIdentity = "initial"
        var lowLimit = 80.0
        var graphTime: TimeInterval = 0
        var controlRequests = 0
        lazy var phone = WatchPhoneRefreshService(
            now: { [unowned self] in watch.uptime },
            wall: { [unowned self] in watch.wall.addingTimeInterval(watch.uptime) },
            schedule: { [unowned self] delay, action in watch.jobs.append((watch.uptime + delay, action)) },
            build: { [unowned self] streams, _, completion in
                builds.append(streams)
                if suspendBuilder { pendingBuild = completion }
                else { completion(makePayload(streams)) }
            },
            generation: { [unowned self] in WatchPhoneSnapshotStore.nextGeneration(sessionID: nil,
                at: watch.wall.addingTimeInterval(watch.uptime), defaults: watch.defaults) },
            sessionScope: { "paired-test-scope" },
            controlSnapshot: { [unowned self] in controlRequests += 1; return ["testControlRevision": 7] },
            publishContext: { [unowned self] payload in published.append(payload); watch.client.receivePush(payload); return true },
            sendPush: { [unowned self] payload, completed in watch.client.receivePush(payload); completed(true, false) })

        init() {
            watch.onSend = { [unowned self] sent in
                guard let reply = sent.reply else { return }
                XCTAssertTrue(phone.receive(sent.message, reply: reply))
            }
        }
        func makePayload(_ streams: Set<String>) -> [String: Any] {
            // Synthetic values only in the isolated test receiver. The phone service
            // supplies transport generation/content identity, as in WatchManager.
            let full = watch.payload(offset: graphTime, lowLimit: lowLimit, identity: dataIdentity)
            var result: [String: Any] = [:]
            for stream in streams {
                if var body = full[stream] as? [String: Any] {
                    body.removeValue(forKey: "snapshotGeneration")
                    body["generatedAt"] = watch.wall.addingTimeInterval(watch.uptime).timeIntervalSince1970
                    result[stream] = body
                } else if stream == "agp" { result[stream] = ["requestID": 1.0, "minuteOfDayValues": [0]] }
            }
            return result
        }
        func start() { watch.client.setExecutionAvailable(true); watch.advance(0.5) }
    }

    func testConcurrentVisibleRequestsEncodeOneCombinedRequestBeforeTransport() {
        let h = Harness()
        h.client.setExecutionAvailable(true)
        for _ in 0..<100 { h.client.request([.status]); h.client.request([.bgReadings]) }
        h.advance(0.25)
        XCTAssertEqual(h.sent.count, 1)
        XCTAssertEqual(h.sent[0].message["streams"] as? [String], ["bgReadings", "status"])
        XCTAssertNotNil(UUID(uuidString: h.sent[0].message["requestID"] as? String ?? ""))
        XCTAssertNotNil(h.sent[0].reply)
    }

    func testRequestsDuringAttemptDoNotStartParallelOrRedundantFollowup() {
        let h = Harness(); h.start()
        for _ in 0..<100 { h.client.request(force: true) }
        h.respond(0)
        h.advance(59)
        XCTAssertEqual(h.sent.count, 1)
        XCTAssertNil(h.client.inFlightRequestID)
    }

    func testHiddenAGPDoesNotRequestOrComputeProfile() {
        let h = Harness()
        h.client.setAGPRange(start: h.wall.addingTimeInterval(-3600), end: h.wall)
        h.client.request([.agp], force: true)
        h.start()
        XCTAssertEqual(h.sent[0].message["streams"] as? [String], ["bgReadings", "status"])
        XCTAssertFalse((h.sent[0].message["streams"] as? [String] ?? []).contains("agp"))
    }

    func testBecomingVisibleDuringAttemptRetainsAGPDemand() {
        let h = Harness(); h.start()
        h.client.setAGPRange(start: h.wall.addingTimeInterval(-3600), end: h.wall)
        h.client.setVisibleStreams([.status, .bgReadings, .agp])
        h.respond(0)
        h.advance(0.25)
        XCTAssertEqual(h.sent.count, 2)
        XCTAssertEqual(h.sent[1].message["streams"] as? [String], ["agp"])
    }

    func testNoAGPRangeDoesNotSpinOrSendInvalidAGPRequest() {
        let h = Harness()
        h.client.setVisibleStreams([.status, .bgReadings, .agp]); h.start()
        h.respond(0); h.advance(30)
        XCTAssertEqual(h.sent.count, 1)
    }

    func testTransportFreshnessIsIndependentOfOldMeasurementAndRepeatedUIRequests() {
        let h = Harness(); h.start()
        h.respond(0, payload: h.payload(offset: -300))
        let measured = h.displayedReadingDate
        for _ in 0..<25 { h.client.request(); h.advance(2) }
        XCTAssertEqual(h.sent.count, 1)
        XCTAssertEqual(h.displayedReadingDate, measured)
    }

    func testValidUnchangedReplyRefreshesCacheWithoutUpdatingMeasurementOrConsumer() {
        let h = Harness(); h.start(); h.respond(0)
        let original = h.displayedReadingDate
        h.advance(60)
        XCTAssertEqual(h.sent.count, 2)
        h.respond(1, payload: ["contentIDs": ["status": "s-a", "bgReadings": "g-a"],
                              "unchangedStreams": ["status", "bgReadings"]])
        XCTAssertEqual(h.displayedReadingDate, original)
        XCTAssertNil(h.client.inFlightRequestID)
        h.advance(59)
        XCTAssertEqual(h.sent.count, 2)
    }

    func testUnchangedWithoutKnownMatchingIdentityIsNotAccepted() {
        let h = Harness(); h.start()
        h.respond(0, payload: ["contentIDs": ["status": "wrong", "bgReadings": "wrong"], "unchangedStreams": ["status", "bgReadings"]])
        XCTAssertTrue(h.events.contains { $0.1 == "failed" && $0.2 == "incompleteReply" })
        XCTAssertNil(h.displayedReadingDate)
    }

    func testReachabilityLostBeforeSendRetainsDemandWithoutSpin() {
        let h = Harness(); h.client.setExecutionAvailable(true)
        h.reachable = false; h.advance(30)
        XCTAssertTrue(h.sent.isEmpty)
        h.reachable = true; h.client.reachabilityDidChange(); h.advance(0.25)
        XCTAssertEqual(h.sent.count, 1)
    }

    func testReachabilityRaceErrorUsesBoundedRetryAndPreservesErrorClass() {
        let h = Harness(); h.start()
        h.sent[0].failure(NSError(domain: "WCErrorDomain", code: 7007))
        XCTAssertEqual(h.client.nextAllowedAttemptAt, 5.25)
        XCTAssertTrue(h.events.contains { $0.2 == "WCErrorDomain:7007" })
        h.advance(4.9); XCTAssertEqual(h.sent.count, 1)
        h.advance(0.1); XCTAssertEqual(h.sent.count, 2)
        XCTAssertFalse(h.client.usesLegacyCompatibility)
    }

    func testTimeoutWithoutCallbackRecoversWithNewCorrelation() {
        let h = Harness(); h.start()
        let firstID = h.client.inFlightRequestID
        h.advance(8)
        XCTAssertNil(h.client.inFlightRequestID)
        h.advance(5)
        XCTAssertEqual(h.sent.count, 2)
        XCTAssertNotEqual(h.client.inFlightRequestID, firstID)
        XCTAssertFalse(h.client.usesLegacyCompatibility)
    }

    func testLateReplyAndDuplicateErrorCannotFinishOrRollbackNewAttempt() {
        let h = Harness(); h.start()
        h.advance(13)
        let secondID = h.client.inFlightRequestID
        h.respond(0)
        h.sent[0].failure(NSError(domain: "WCErrorDomain", code: 7007))
        XCTAssertEqual(h.client.inFlightRequestID, secondID)
        XCTAssertNil(h.displayedReadingDate)
        h.respond(1)
        let accepted = h.displayedReadingDate
        h.respond(0, payload: h.payload(offset: -100))
        XCTAssertEqual(h.displayedReadingDate, accepted)
    }

    func testReplyRequestIDMustMatchEvenWhenTransportCallbackMatches() {
        let h = Harness(); h.start()
        var reply = h.payload()
        reply["watchRefreshProtocol"] = 1; reply["requestID"] = UUID().uuidString
        h.sent[0].reply?(reply)
        XCTAssertNil(h.displayedReadingDate)
        XCTAssertTrue(h.events.contains { $0.2 == "invalidReply" })
    }

    func testRepeatedFailuresHaveIncreasingCappedWait() {
        let h = Harness(); h.start()
        let waits: [TimeInterval] = [5, 10, 20, 40, 80, 120, 120]
        for wait in waits {
            h.sent.last?.failure(NSError(domain: "WCErrorDomain", code: 7007))
            XCTAssertEqual(h.client.nextAllowedAttemptAt - h.uptime, wait, accuracy: 0.001)
            h.advance(wait)
        }
        XCTAssertEqual(h.sent.count, 8)
    }

    func testInactiveAndSuspendedExecutionDoesNotRunRequestsOrRetries() {
        let h = Harness(); h.start()
        h.client.setExecutionAvailable(false)
        h.advance(3600)
        XCTAssertEqual(h.sent.count, 1)
        h.client.setExecutionAvailable(true)
        h.advance(5)
        XCTAssertEqual(h.sent.count, 2)
    }

    func testExplicitUnsupportedReplyAllowsOneBoundedLegacyFallback() {
        let h = Harness(); h.start()
        h.sent[0].reply?([LibreWatchMessageKey.success: false])
        XCTAssertTrue(h.client.usesLegacyCompatibility)
        XCTAssertEqual(h.sent.count, 3)
        XCTAssertNil(h.sent[1].reply)
        XCTAssertNil(h.sent[2].reply)
        h.client.receivePush(h.payload())
        h.client.request(force: true); h.advance(59)
        XCTAssertEqual(h.sent.count, 3)
        h.advance(1)
        XCTAssertEqual(h.sent.count, 5)
        XCTAssertEqual(h.sent.filter { $0.message["requestWatchUpdate"] as? String == "snapshot" }.count, 1)
    }

    func testLegacyLostReplyRetriesAtMostOncePerMinuteWithoutProbeLoop() {
        let h = Harness(); h.start()
        h.sent[0].reply?([LibreWatchMessageKey.success: false])
        h.advance(59)
        XCTAssertEqual(h.sent.count, 3)
        h.advance(1)
        XCTAssertEqual(h.sent.count, 5)
        XCTAssertTrue(h.sent.dropFirst().allSatisfy { $0.reply == nil })
    }

    func testLegacySeparatePushesCompleteOnlyAfterAllRequestedStreamsArrive() {
        let h = Harness(); h.start()
        h.sent[0].reply?([LibreWatchMessageKey.success: false])
        let payload = h.payload()
        h.client.receivePush(["status": payload["status"]!])
        XCTAssertNotNil(h.client.inFlightRequestID)
        h.client.receivePush(["bgReadings": payload["bgReadings"]!])
        XCTAssertNil(h.client.inFlightRequestID)
    }

    func testNewerPushCannotBeRolledBackByOlderReplyOrCachedIdentity() {
        let h = Harness(); h.start()
        let old = h.payload(offset: 0, lowLimit: 80, identity: "old")
        h.client.receivePush(h.payload(offset: 0.2, lowLimit: 90, identity: "new"))
        h.respond(0, payload: old)
        XCTAssertEqual(h.appliedStatusLimit, 90)
        XCTAssertEqual(h.displayedReadingDate, h.wall.addingTimeInterval(0.2))
        XCTAssertNil(h.client.inFlightRequestID)
        h.client.request(force: true); h.advance(0.25)
        XCTAssertEqual((h.sent.last?.message["knownContentIDs"] as? [String: String])?["status"], "s-new")
    }

    func testUnsolicitedPushDuringBackoffAppliesImmediatelyWithoutNewRequest() {
        let h = Harness(); h.start()
        h.sent[0].failure(NSError(domain: "WCErrorDomain", code: 7007))
        h.client.receivePush(h.payload(lowLimit: 90))
        XCTAssertEqual(h.appliedStatusLimit, 90)
        XCTAssertNotNil(h.displayedReadingDate)
        XCTAssertEqual(h.sent.count, 1)
    }

    func testSuccessfulReplyFollowedByDuplicateDoesNotApplyAgain() {
        let h = Harness(); h.start(); h.respond(0)
        let receivedCount = h.events.filter { $0.1 == "received" }.count
        h.respond(0, payload: h.payload(offset: 0.2, lowLimit: 90))
        XCTAssertEqual(h.appliedStatusLimit, 80)
        XCTAssertEqual(h.events.filter { $0.1 == "received" }.count, receivedCount)
    }

    func testRealGraphChangeRefreshesVisibleAGPButGeneratedAtAloneDoesNot() {
        let h = Harness()
        h.client.setAGPRange(start: h.wall.addingTimeInterval(-3600), end: h.wall)
        h.client.setVisibleStreams([.status, .bgReadings, .agp]); h.start()
        var first = h.payload()
        first["agp"] = ["requestID": 1.0]
        h.respond(0, payload: first)
        h.client.receivePush(h.payload(offset: 0.1, identity: "a"))
        h.advance(0.25)
        XCTAssertEqual(h.sent.count, 1)
        h.client.receivePush(h.payload(offset: 0.3, identity: "new-data"))
        h.advance(0.25)
        XCTAssertEqual(h.sent.count, 2)
        XCTAssertEqual(h.sent[1].message["streams"] as? [String], ["agp"])
    }

    func testPairedProductionServicesCoalesceViewsBeforeSingleDatabaseBuilderAndReply() {
        let pair = PairedHarness()
        pair.watch.client.setExecutionAvailable(true)
        for _ in 0..<100 { pair.watch.client.request([.status]); pair.watch.client.request([.bgReadings]) }
        pair.watch.advance(0.5)
        XCTAssertEqual(pair.watch.sent.count, 1)
        XCTAssertEqual(pair.builds, [["status", "bgReadings"]])
        XCTAssertEqual(pair.controlRequests, 1)
        XCTAssertNil(pair.watch.client.inFlightRequestID)
        XCTAssertEqual(pair.watch.displayedReadingDate, pair.watch.wall)
    }

    func testPairedProductionRefreshKeepsGenerationContentAndMeasurementForUnchangedDatabase() throws {
        let pair = PairedHarness(); pair.start()
        let first = try XCTUnwrap(WatchPhoneSnapshotStore.stored(.bgReadings, defaults: pair.watch.defaults))
        let firstGeneration = try XCTUnwrap(first["snapshotGeneration"] as? [String: Any])
        let firstRevision = firstGeneration["revision"] as? String
        let measured = pair.watch.displayedReadingDate
        pair.watch.advance(60.5)
        XCTAssertEqual(pair.builds.count, 2)
        XCTAssertEqual(pair.published.count, 1, "Rechecking age alone does not republish unchanged bodies")
        let after = try XCTUnwrap(WatchPhoneSnapshotStore.stored(.bgReadings, defaults: pair.watch.defaults))
        XCTAssertEqual((after["snapshotGeneration"] as? [String: Any])?["revision"] as? String, firstRevision)
        XCTAssertEqual(pair.watch.displayedReadingDate, measured)
        XCTAssertNil(pair.watch.client.inFlightRequestID)
    }

    func testPairedProductionNewDataDuringBuildRemainsDirtyAndIsDelivered() {
        let pair = PairedHarness(); pair.suspendBuilder = true; pair.start()
        let first = pair.makePayload(["status", "bgReadings"])
        pair.lowLimit = 90; pair.graphTime = 0.2
        pair.phone.changed(["status", "bgReadings"])
        pair.suspendBuilder = false
        pair.pendingBuild?(first); pair.pendingBuild = nil
        pair.watch.advance(0.5)
        XCTAssertEqual(pair.builds.count, 2)
        XCTAssertEqual(pair.watch.appliedStatusLimit, 90)
        XCTAssertEqual(pair.watch.displayedReadingDate, pair.watch.wall.addingTimeInterval(0.2))
        XCTAssertNil(pair.watch.client.inFlightRequestID)
    }

    func testPairedProductionActualPushPassesWatchRequestBackoffImmediately() {
        let pair = PairedHarness(); pair.start()
        pair.watch.onSend = { $0.failure(NSError(domain: "WCErrorDomain", code: 7007)) }
        pair.watch.client.request(force: true); pair.watch.advance(0.25)
        XCTAssertGreaterThan(pair.watch.client.nextAllowedAttemptAt, pair.watch.uptime)
        pair.lowLimit = 95; pair.graphTime = 0.5
        pair.phone.changed(["status", "bgReadings"]); pair.watch.advance(0.25)
        XCTAssertEqual(pair.watch.appliedStatusLimit, 95)
        XCTAssertEqual(pair.watch.displayedReadingDate, pair.watch.wall.addingTimeInterval(0.5))
    }

    func testModernAGPContextCannotReplaceCorrelatedProfile() {
        let h = Harness()
        h.client.setAGPRange(start: h.wall.addingTimeInterval(-3600), end: h.wall)
        h.client.setVisibleStreams([.status, .bgReadings, .agp]); h.start()
        XCTAssertFalse(h.client.receivePush(["agp": ["requestID": 1.0]]).contains(.agp))
        var reply = h.payload(); reply["agp"] = ["requestID": 1.0]
        h.respond(0, payload: reply)
        XCTAssertNil(h.client.inFlightRequestID)
        XCTAssertFalse(h.client.receivePush(["watchRefreshProtocol": 1, "agp": ["requestID": 1.0]]).contains(.agp))
    }

    func testContextBeforeIdenticalPushIsAcknowledgedWithoutNewMeasurementOrWrite() throws {
        let pair = PairedHarness(); pair.start()
        let context = try XCTUnwrap(pair.published.first)
        let before = pair.watch.displayedReadingDate
        let saved = try XCTUnwrap(WatchPhoneSnapshotStore.stored(.bgReadings, defaults: pair.watch.defaults))
        let repeated = pair.watch.client.receivePush(context)
        XCTAssertEqual(repeated, [.status, .bgReadings])
        XCTAssertEqual(pair.watch.displayedReadingDate, before)
        let after = try XCTUnwrap(WatchPhoneSnapshotStore.stored(.bgReadings, defaults: pair.watch.defaults))
        XCTAssertEqual((saved["snapshotGeneration"] as? [String: Any])?["revision"] as? String,
                       (after["snapshotGeneration"] as? [String: Any])?["revision"] as? String)
    }

    func testMalformedSameIdentityAndGenerationCannotBeAcknowledgedAsCurrent() throws {
        let pair = PairedHarness(); pair.start()
        var context = try XCTUnwrap(pair.published.first)
        var graph = try XCTUnwrap(context["bgReadings"] as? [String: Any])
        graph["bgReadingValues"] = [Double.nan]
        context["bgReadings"] = graph
        let accepted = pair.watch.client.receivePush(context)
        XCTAssertTrue(accepted.contains(.status))
        XCTAssertFalse(accepted.contains(.bgReadings))
        XCTAssertEqual(pair.watch.displayedReadingDate, pair.watch.wall)
    }

    func testCallbackAfterSuspensionCannotExtendExpiredAttemptDeadline() {
        let h = Harness(); h.start()
        h.client.setExecutionAvailable(false); h.advance(20)
        h.respond(0)
        XCTAssertNil(h.displayedReadingDate)
        XCTAssertNil(h.client.inFlightRequestID)
        XCTAssertTrue(h.events.contains { $0.1 == "failed" && $0.2 == "timeout" })
        XCTAssertEqual(h.sent.count, 1)
    }
}
