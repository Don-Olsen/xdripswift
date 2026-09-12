import XCTest
@testable import xdrip

/// Uses the production phone service with its real snapshot generation and context merge.
/// Only the database, WC transport and scheduling clock are substituted; no clinical store.
final class WatchPhoneRefreshServiceTests: XCTestCase {
    private final class Harness {
        typealias Payload = [String: Any]
        struct Build {
            let streams: Set<String>
            let raw: Payload
            let completion: (Payload) -> Void
        }
        struct Push {
            let payload: Payload
            let completion: (Bool, Bool) -> Void
        }
        var uptime: TimeInterval = 0
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        var jobs: [(TimeInterval, () -> Void)] = []
        var builds: [Build] = []
        var pushes: [Push] = []
        var replies: [Payload] = []
        var contextAttempts: [Payload] = []
        var context: Payload = ["libreSession": Data([1, 2]), "libreAlarm": Data([3])]
        var controls: Payload = ["testControlRevision": 7, "testOwner": "watch"]
        var events: [(String, String)] = []
        var automaticBuild = true
        var agpGate: WatchManager.AGPCalculationGate?
        var automaticPush = true
        var contextFailures = 0
        var scope = "phone"
        var value: Double = 120
        var generations = 0
        let suite = "WatchPhoneRefreshServiceTests.\(UUID().uuidString)"
        lazy var defaults = UserDefaults(suiteName: suite)!
        lazy var service = WatchPhoneRefreshService(
            now: { [unowned self] in uptime },
            wall: { [unowned self] in origin.addingTimeInterval(uptime) },
            schedule: { [unowned self] delay, work in jobs.append((uptime + delay, work)) },
            build: { [unowned self] streams, raw, completion in
                if let gate = agpGate, streams.contains("agp") {
                    gate.start(base: payload(streams.subtracting(["agp"])), calculate: { finished in
                        builds.append(Build(streams: streams, raw: raw, completion: { body in
                            finished(body["agp"] as? Payload)
                        }))
                        if automaticBuild { finished(payload(["agp"])["agp"] as? Payload) }
                    }, complete: completion)
                } else {
                    builds.append(Build(streams: streams, raw: raw, completion: completion))
                    if automaticBuild { completion(payload(streams)) }
                }
            },
            generation: { [unowned self] in
                generations += 1
                return WatchPhoneSnapshotStore.nextGeneration(sessionID: nil,
                    at: origin.addingTimeInterval(uptime), defaults: defaults)
            },
            sessionScope: { [unowned self] in scope },
            controlSnapshot: { [unowned self] in controls },
            publishContext: { [unowned self] incoming in
                contextAttempts.append(incoming)
                if contextFailures > 0 { contextFailures -= 1; return false }
                context = WatchPhoneRefreshService.merging(incoming, into: context)
                return true
            },
            sendPush: { [unowned self] payload, completion in
                pushes.append(Push(payload: payload, completion: completion))
                if automaticPush { completion(true, false) }
            },
            event: { [unowned self] stream, action in events.append((stream, action)) })

        deinit { defaults.removePersistentDomain(forName: suite) }

        func advance(_ seconds: TimeInterval) {
            let target = uptime + seconds
            var count = 0
            while let index = jobs.indices.filter({ jobs[$0].0 <= target })
                .min(by: { jobs[$0].0 < jobs[$1].0 }) {
                let job = jobs.remove(at: index)
                uptime = job.0; job.1(); count += 1
                if count > 10_000 { XCTFail("Unbounded scheduling loop"); break }
            }
            uptime = target
        }

        @discardableResult
        func request(_ streams: [String] = ["status", "bgReadings"],
                     known: [String: String] = [:], duration: TimeInterval = 3600,
                     agpRequestID: Double = 1) -> String {
            let id = UUID().uuidString
            let end = origin.timeIntervalSince1970
            let raw: Payload = ["requestWatchUpdate": "snapshot", "watchRefreshProtocol": 1,
                "requestID": id, "streams": streams, "knownContentIDs": known,
                "visibleStartDate": end - duration, "visibleEndDate": end,
                "agpRequestID": agpRequestID]
            XCTAssertTrue(service.receive(raw) { [unowned self] in replies.append($0) })
            return id
        }

        func payload(_ streams: Set<String>) -> Payload {
            var result: Payload = [:]
            let generated = origin.addingTimeInterval(uptime).timeIntervalSince1970
            if streams.contains("status") {
                result["status"] = ["generatedAt": generated, "isMgDl": true,
                    "isMaster": true, "keepAliveIsDisabled": false,
                    "sensorStartedAt": origin.addingTimeInterval(-3600).timeIntervalSince1970,
                    "sensorAgeInMinutes": 60 + uptime / 60, "sensorMaxAgeInMinutes": 20_160.0,
                    "urgentLowLimitInMgDl": 60.0, "lowLimitInMgDl": 80.0,
                    "highLimitInMgDl": 170.0, "urgentHighLimitInMgDl": 250.0] as Payload
            }
            if streams.contains("bgReadings") {
                result["bgReadings"] = ["generatedAt": generated,
                    "bgReadingDatesAsDouble": [origin.timeIntervalSince1970],
                    "bgReadingValues": [value], "slopeOrdinal": 2,
                    "deltaValueInUserUnit": 0.0] as Payload
            }
            if streams.contains("agp") {
                result["agp"] = ["generatedAt": generated, "requestID": 0.0,
                    "visibleStartDateAsDouble": 0.0, "visibleEndDateAsDouble": 0.0,
                    "dayCount": 7, "minuteOfDayValues": [0], "medianValues": [120.0]] as Payload
            }
            return result
        }

        func completeBuild(_ index: Int) {
            let item = builds[index]
            item.completion(payload(item.streams))
        }
    }

    func testConcurrentRequestsShareOneDatabaseBuildAndReplyWithoutDuplicatePush() {
        let h = Harness()
        for _ in 0..<10 { h.request() }
        h.advance(0.25)
        XCTAssertEqual(h.builds.count, 1)
        XCTAssertEqual(h.builds[0].streams, ["status", "bgReadings"])
        XCTAssertEqual(h.replies.count, 10)
        XCTAssertTrue(h.replies.allSatisfy { $0["success"] as? Bool == true })
        XCTAssertTrue(h.pushes.isEmpty)
        XCTAssertEqual(h.contextAttempts.count, 1)
        XCTAssertEqual(h.events.filter { $0.0 == "status" && $0.1 == "requestReceived" }.count, 10)
        XCTAssertEqual(h.events.filter { $0.0 == "bgReadings" && $0.1 == "requestReceived" }.count, 10)
    }

    func testUnchangedContentRevalidationDoesNotMintGenerationOrRepublish() {
        let h = Harness(); h.request(); h.advance(0.25)
        let ids = h.replies[0]["contentIDs"] as? [String: String] ?? [:]
        let generations = h.generations
        h.advance(61); h.request(known: ids); h.advance(0.25)
        XCTAssertEqual(h.builds.count, 2)
        XCTAssertEqual(h.generations, generations)
        XCTAssertEqual(h.contextAttempts.count, 1)
        XCTAssertEqual(Set(h.replies[1]["unchangedStreams"] as? [String] ?? []), ["status", "bgReadings"])
        XCTAssertEqual(h.replies[1]["testControlRevision"] as? Int, 7)
    }

    func testGeneratedAtAndSensorAgeChangesAloneKeepContentIdentity() {
        let h = Harness()
        let original = h.payload(["status"])["status"] as! [String: Any]
        h.advance(500)
        let later = h.payload(["status"])["status"] as! [String: Any]
        XCTAssertEqual(WatchPhoneRefreshService.contentID(original, scope: h.scope),
            WatchPhoneRefreshService.contentID(later, scope: h.scope))
    }

    func testRequestForAnotherStreamDuringBuildIsRetainedForFollowup() {
        let h = Harness(); h.automaticBuild = false
        let statusID = h.request(["status"]); h.advance(0.25)
        let graphID = h.request(["bgReadings"])
        h.completeBuild(0)
        XCTAssertEqual(h.replies.count, 1)
        XCTAssertEqual(h.replies[0]["requestID"] as? String, statusID)
        h.advance(0.25)
        XCTAssertEqual(h.builds.count, 2)
        XCTAssertEqual(h.builds[1].streams, ["bgReadings"])
        h.completeBuild(1)
        XCTAssertEqual(h.replies[1]["requestID"] as? String, graphID)
        XCTAssertEqual(h.replies[1]["success"] as? Bool, true)
    }

    func testMissingBuildBodyFailsOnceWithoutRepeatedDatabaseWork() {
        let h = Harness(); h.automaticBuild = false
        h.request(["status"]); h.advance(0.25)
        h.builds[0].completion([:]); h.advance(60)
        XCTAssertEqual(h.replies.count, 1)
        XCTAssertEqual(h.replies[0]["success"] as? Bool, false)
        XCTAssertEqual(h.builds.count, 1)
        h.request(["status"]); h.advance(0.25)
        XCTAssertEqual(h.builds.count, 2)
    }

    func testMissingBuildCallbackTimesOutAndLateCompletionCannotFinishNewBuild() {
        let h = Harness(); h.automaticBuild = false
        h.request(["status"]); h.advance(5.25)
        XCTAssertEqual(h.replies[0]["error"] as? String, "buildTimeout")
        let newID = h.request(["status"]); h.advance(0.25)
        h.completeBuild(0)
        XCTAssertEqual(h.replies.count, 1)
        XCTAssertTrue(h.contextAttempts.isEmpty)
        h.completeBuild(1)
        XCTAssertEqual(h.replies.count, 2)
        XCTAssertEqual(h.replies[1]["requestID"] as? String, newID)
        XCTAssertEqual(h.replies[1]["success"] as? Bool, true)
        h.completeBuild(1)
        XCTAssertEqual(h.replies.count, 2)
    }

    func testDataChangesDuringActivePushProduceOneFollowupAndIgnoreLateCallbacks() {
        let h = Harness(); h.automaticPush = false
        h.service.changed(["bgReadings"]); h.advance(0.25)
        h.value = 125; h.service.changed(["bgReadings"]); h.advance(0.25)
        XCTAssertEqual(h.pushes.count, 1)
        h.pushes[0].completion(true, false); h.advance(0.25)
        XCTAssertEqual(h.pushes.count, 2)
        let graph = h.pushes[1].payload["bgReadings"] as? [String: Any]
        XCTAssertEqual(graph?["bgReadingValues"] as? [Double], [125])
        h.pushes[0].completion(false, false)
        h.pushes[1].completion(true, false); h.advance(8)
        XCTAssertFalse(h.events.contains { $0.1 == "pushTimeout" })
    }

    func testPushFailuresLimitRetriesAndDoNotBlockSolicitedReplyOrControl() {
        let h = Harness(); h.automaticPush = false
        h.service.changed(["bgReadings"]); h.advance(0.25)
        h.pushes[0].completion(false, false)
        for _ in 0..<10 { h.service.changed(["bgReadings"]); h.advance(0.25) }
        XCTAssertEqual(h.pushes.count, 1)
        h.controls = ["testControlRevision": 8, "testOwner": "iphone"]
        h.request(["status"]); h.advance(0.25)
        XCTAssertEqual(h.replies.last?["testControlRevision"] as? Int, 8)
        XCTAssertEqual(h.replies.last?["testOwner"] as? String, "iphone")
        XCTAssertEqual(h.pushes.count, 1)
        h.advance(5); h.service.changed(["bgReadings"]); h.advance(0.25)
        XCTAssertEqual(h.pushes.count, 2)
    }

    func testPushTimeoutRetainsLatestForNextLegalOpportunity() {
        let h = Harness(); h.automaticPush = false
        h.service.changed(["bgReadings"]); h.advance(8.25)
        XCTAssertTrue(h.events.contains { $0.0 == "bgReadings" && $0.1 == "pushTimeout" })
        h.service.reachable(); h.advance(0.25)
        XCTAssertEqual(h.pushes.count, 2)
        h.pushes[0].completion(true, false)
        h.pushes[1].completion(true, false); h.advance(8)
        XCTAssertEqual(h.pushes.count, 2)
    }

    func testFailedContextRetriesUnchangedContentAndPreservesOtherSendersFields() {
        let h = Harness(); h.contextFailures = 1
        h.request(); h.advance(0.25)
        XCTAssertEqual(h.contextAttempts.count, 1)
        h.request(); h.advance(0.25)
        XCTAssertEqual(h.contextAttempts.count, 1)
        h.advance(5); h.request(); h.advance(0.25)
        XCTAssertEqual(h.contextAttempts.count, 2)
        XCTAssertEqual(h.builds.count, 1)
        XCTAssertNotNil(h.context["status"])
        XCTAssertNotNil(h.context["bgReadings"])
        XCTAssertEqual(h.context["libreSession"] as? Data, Data([1, 2]))
        XCTAssertEqual(h.context["libreAlarm"] as? Data, Data([3]))
        XCTAssertEqual((h.context["contentIDs"] as? [String: String])?.count, 2)
    }

    func testLongDeferredContextUsesRevalidatedStatusWithoutNewGeneration() {
        let h = Harness(); h.contextFailures = 1
        h.request(["status"]); h.advance(0.25)
        let generations = h.generations
        h.advance(3600); h.request(["status"]); h.advance(0.25)
        XCTAssertEqual(h.generations, generations)
        let status = h.context["status"] as! [String: Any]
        XCTAssertTrue(WatchPhoneSnapshotStore.isValid(status, stream: .status,
            sessionID: nil, at: h.origin.addingTimeInterval(h.uptime)))
    }

    func testContextFailureCannotReplayPreviousSensorScope() {
        let h = Harness(); h.contextFailures = 1
        h.request(["status"]); h.advance(0.25)
        let oldID = (h.contextAttempts[0]["contentIDs"] as? [String: String])?["status"]
        h.scope = "replacement-session"; h.service.reachable(); h.advance(0.25)
        let newID = (h.contextAttempts.last?["contentIDs"] as? [String: String])?["status"]
        XCTAssertNotEqual(oldID, newID)
        XCTAssertEqual(h.contextAttempts.count, 2)
    }

    func testExplicitLegacyRequestUsesNoReplyCompatibilityOncePerBatch() {
        let h = Harness()
        for _ in 0..<50 {
            h.service.refreshLegacy(["status"]); h.service.refreshLegacy(["bgReadings"])
        }
        h.advance(0.25)
        XCTAssertEqual(h.builds.count, 1)
        XCTAssertEqual(h.pushes.count, 1)
        XCTAssertEqual(h.pushes[0].payload["legacySnapshot"] as? Bool, true)
        XCTAssertTrue(h.events.contains { $0.1 == "legacySubmittedUnconfirmed" })
        h.service.refreshLegacy(["status"]); h.advance(30)
        XCTAssertEqual(h.pushes.count, 1)
    }

    func testLegacyAGPRequestsShareOneBuildAndOnePushWithNewestCorrelation() {
        let h = Harness()
        let end = h.origin.timeIntervalSince1970
        for id in 1...10 {
            h.service.refreshLegacy(["agp"], raw: ["requestID": Double(id),
                "visibleStartDate": end - 3600, "visibleEndDate": end])
        }
        h.advance(0.25)
        XCTAssertEqual(h.builds.count, 1)
        XCTAssertEqual(h.pushes.count, 1)
        XCTAssertEqual((h.pushes[0].payload["agp"] as? [String: Any])?["requestID"] as? Double, 10)
    }

    func testUnchangedAGPAtDifferentRangeUpdatesCacheKeyWithoutSpin() {
        let h = Harness(); h.request(["agp"], duration: 3600); h.advance(0.25)
        h.request(["agp"], duration: 7200, agpRequestID: 42); h.advance(0.25)
        XCTAssertEqual(h.builds.count, 2)
        XCTAssertEqual(h.replies.count, 2)
        XCTAssertEqual(h.replies[1]["success"] as? Bool, true)
        XCTAssertEqual((h.replies[1]["agp"] as? [String: Any])?["requestID"] as? Double, 42)
        h.request(["agp"], duration: 7200); h.advance(30)
        XCTAssertEqual(h.builds.count, 2)
    }

    func testDifferentAGPRangesArrivingDuringBuildAreServedInOrder() {
        let h = Harness(); h.automaticBuild = false
        let first = h.request(["agp"], duration: 3600); h.advance(0.25)
        let second = h.request(["agp"], duration: 7200)
        h.completeBuild(0); h.advance(0.25)
        XCTAssertEqual(h.replies[0]["requestID"] as? String, first)
        XCTAssertEqual(h.builds.count, 2)
        h.completeBuild(1)
        XCTAssertEqual(h.replies[1]["requestID"] as? String, second)
        XCTAssertEqual(h.replies[1]["success"] as? Bool, true)
    }

    func testInvalidRequestIsBoundedAndDoesNotInvokeDatabase() {
        let h = Harness()
        let id = UUID().uuidString
        XCTAssertTrue(h.service.receive(["requestWatchUpdate": "snapshot", "watchRefreshProtocol": 1,
            "requestID": id, "streams": ["agp"], "visibleStartDate": 10.0, "visibleEndDate": 9.0]) {
                h.replies.append($0)
            })
        h.advance(20)
        XCTAssertTrue(h.builds.isEmpty)
        XCTAssertEqual(h.replies[0]["requestID"] as? String, id)
        XCTAssertEqual(h.replies[0]["error"] as? String, "invalidAGPRange")
    }

    func testPhysicalAGPCalculationSurvivesTransportTimeoutWithoutAdditionalQueuedWork() {
        let h = Harness(); h.agpGate = WatchManager.AGPCalculationGate(); h.automaticBuild = false
        h.request(["agp", "status"]); h.advance(5.25)
        XCTAssertEqual(h.replies[0]["error"] as? String, "buildTimeout")
        for _ in 0..<20 { h.request(["agp", "status"]); h.advance(0.25) }
        XCTAssertEqual(h.builds.count, 1, "Transport retries must not enqueue further statistics operations")
        XCTAssertTrue(h.replies.dropFirst().allSatisfy { $0["status"] != nil || $0["unchangedStreams"] != nil })
        XCTAssertTrue(h.replies.dropFirst().allSatisfy { $0["success"] as? Bool == false })
        h.request(["status"]); h.advance(0.25)
        XCTAssertEqual(h.replies.last?["success"] as? Bool, true)
    }

    func testPhysicalAGPCompletionReleasesGateButCannotApplyTimedOutResult() {
        let h = Harness(); h.agpGate = WatchManager.AGPCalculationGate(); h.automaticBuild = false
        h.request(["agp"]); h.advance(5.25)
        h.completeBuild(0)
        XCTAssertEqual(h.replies.count, 1)
        XCTAssertTrue(h.contextAttempts.isEmpty)
        h.request(["agp"]); h.advance(0.25)
        XCTAssertEqual(h.builds.count, 2)
        h.completeBuild(0) // Duplicate completion cannot release the newer physical calculation.
        h.request(["status"])
        h.completeBuild(1); h.advance(0.25)
        XCTAssertEqual(h.replies[1]["success"] as? Bool, true)
        XCTAssertEqual(h.replies[1]["agp"] is [String: Any], true)
    }

    func testAGPGateFailureReleasesWithoutInventingProfile() {
        let gate = WatchManager.AGPCalculationGate()
        var callback: (([String: Any]?) -> Void)?
        var result: [String: Any]?
        XCTAssertTrue(gate.start(base: ["status": ["v": 1]], calculate: { callback = $0 }, complete: { result = $0 }))
        callback?(nil)
        XCTAssertNotNil(result?["status"])
        XCTAssertNil(result?["agp"])
        XCTAssertTrue(gate.start(base: [:], calculate: { $0(["medianValues": [120.0]]) }, complete: { result = $0 }))
        XCTAssertNotNil(result?["agp"])
    }

    func testAGPGateDuplicateCallbackCannotReleaseNewerCalculation() {
        let gate = WatchManager.AGPCalculationGate()
        var callbacks: [([String: Any]?) -> Void] = []
        var completed = 0
        XCTAssertTrue(gate.start(base: [:], calculate: { callbacks.append($0) }, complete: { _ in completed += 1 }))
        callbacks[0](["dayCount": 7])
        XCTAssertTrue(gate.start(base: [:], calculate: { callbacks.append($0) }, complete: { _ in completed += 1 }))
        callbacks[0](nil)
        var busyBase: [String: Any]?
        XCTAssertFalse(gate.start(base: ["status": ["v": 2]], calculate: { _ in XCTFail("Second calculation started") },
            complete: { busyBase = $0 }))
        XCTAssertNotNil(busyBase?["status"])
        XCTAssertEqual(completed, 1)
        callbacks[1](nil)
        XCTAssertEqual(completed, 2)
    }

    func testContextContentIDsMergeAlongsideControlFields() {
        let merged = WatchPhoneRefreshService.merging(
            ["bgReadings": ["v": 2], "contentIDs": ["bgReadings": "new-graph"]],
            into: ["status": ["v": 1], "contentIDs": ["status": "old-status"],
                   "libreHandoff": Data([4]), "libreCalibration": Data([5])])
        XCTAssertEqual(merged["contentIDs"] as? [String: String],
            ["status": "old-status", "bgReadings": "new-graph"])
        XCTAssertEqual(merged["libreHandoff"] as? Data, Data([4]))
        XCTAssertEqual(merged["libreCalibration"] as? Data, Data([5]))
    }

    func testLegacyReachabilityFlapsRespectMinimumIntervalAfterSuccessAndFailure() {
        for succeeded in [true, false] {
            let h = Harness(); h.automaticPush = false
            h.service.refreshLegacy(["status"]); h.advance(0.25)
            XCTAssertEqual(h.pushes.count, 1)
            h.pushes[0].completion(succeeded, false)
            h.value = 140; h.service.changed(["bgReadings"])
            for _ in 0..<10 { h.service.reachable(); h.advance(1) }
            XCTAssertEqual(h.pushes.count, 1, "Reachability cannot reset the legacy minimum interval")
            h.advance(50); h.service.reachable(); h.advance(0.25)
            XCTAssertEqual(h.pushes.count, 2)
        }
    }

    func testLatePushCallbackCannotAcknowledgeAfterSuspendedTimeoutScheduler() {
        let h = Harness(); h.automaticPush = false
        h.service.changed(["status", "bgReadings"]); h.advance(0.25)
        XCTAssertEqual(h.pushes.count, 1)
        // Simulate suspension: monotonic time advances before scheduled work resumes.
        h.uptime += 9
        h.pushes[0].completion(true, false)
        XCTAssertTrue(h.events.contains { $0.1 == "pushTimeout" })
        XCTAssertFalse(h.events.contains { $0.1 == "pushAcknowledged" })
        h.jobs.removeAll()
        h.service.reachable(); h.advance(0.25)
        XCTAssertEqual(h.pushes.count, 2, "A late ACK must not mark the old content as delivered")
    }
}
