import XCTest
import CoreData
@testable import xdrip

/// Real manager + URLSession + Core Data, with all HTTP confined to an in-memory server.
/// No test submits readings to a real Nightscout or to the app's persistent glucose store.
final class NightscoutHistoryWriteTests: XCTestCase {
    @MainActor private final class Harness {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let server = NightscoutHistoryServer()
        let session: URLSession
        let manager: NightscoutSyncManager
        let sensor: Sensor
        let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 1800)
        private let savedDefaults: [String: Any]

        init() {
            savedDefaults = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier!) ?? [:]
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [NightscoutHistoryURLProtocol.self]
            configuration.timeoutIntervalForRequest = 5
            session = URLSession(configuration: configuration)
            NightscoutHistoryURLProtocol.register(server)
            let defaults = UserDefaults.standard
            defaults.nightscoutUrl = "https://" + server.host
            defaults.nightscoutPort = 0
            defaults.nightscoutAPIKey = "synthetic-test-secret"
            defaults.nightscoutToken = nil
            defaults.nightscoutEnabled = true
            defaults.isMaster = true
            defaults.masterUploadDataToNightscout = true
            defaults.storeFrequentReadingsInNightscout = true
            defaults.timeStampLatestNightscoutUploadedBgReading = .distantPast
            defaults.removeObject(forKey: "nightscoutHistoricalReadings.v1")
            defaults.enableSmoothing = false
            defaults.enableAdjustment = false
            defaults.useFiveMinuteReadings = false
            defaults.postProcessingSourceContextIdentifier = nil
            manager = NightscoutSyncManager(coreDataManager: stack, messageHandler: nil,
                urlSession: session, observesSettings: false)
            sensor = Sensor(startDate: base.addingTimeInterval(-60), nsManagedObjectContext: stack.mainManagedObjectContext)
        }

        func reading(_ index: Int = 0, value: Double = 110) -> BgReading {
            let reading = BgReading(timeStamp: base.addingTimeInterval(Double(index) * 60),
                sensor: sensor, calibration: nil, rawData: value, deviceName: "isolated-test",
                nsManagedObjectContext: stack.mainManagedObjectContext)
            reading.calculatedValue = value
            reading.ageAdjustedRawValue = value
            return reading
        }

        func finish() async {
            await manager.waitForBgReplacements()
            session.invalidateAndCancel()
            NightscoutHistoryURLProtocol.unregister(server)
            UserDefaults.standard.setPersistentDomain(savedDefaults, forName: Bundle.main.bundleIdentifier!)
        }
    }

    @MainActor func testSmoothingUpdatesThirtyValuesWithoutDeletingOrChangingServerIDs() async throws {
        let h = Harness()
        let readings = (0..<30).map { h.reading($0) }
        for reading in readings { h.server.seed(reading.dictionaryRepresentationForNightscoutUpload()) }
        let timestamp = readings[0].timeStamp.toMillisecondsAsInt64()
        h.server.seed(["_id": "calibration", "type": "cal", "date": timestamp])
        h.server.seed(["_id": "manual", "type": "mbg", "date": timestamp])
        readings[0].smoothedValue = NSNumber(value: 125)
        h.manager.replaceBgReadingsInNightscout(bgReadings: readings)
        await h.manager.waitForBgReplacements()
        XCTAssertEqual(h.server.requests.map(\.method), ["POST"])
        let payload = try XCTUnwrap(h.server.requests.first?.entries)
        XCTAssertEqual(payload.count, 30)
        XCTAssertTrue(payload.allSatisfy { $0["_id"] == nil && $0["type"] as? String == "sgv" })
        XCTAssertEqual(payload[0]["sysTime"] as? String, readings[0].timeStamp.ISOStringFromDate())
        XCTAssertEqual(h.server.entries.count, 32)
        XCTAssertEqual(h.server.entry(at: timestamp, type: "sgv")?["_id"] as? String, readings[0].id)
        XCTAssertEqual(h.server.entry(at: timestamp, type: "sgv")?["sgv"] as? Int, 125)
        XCTAssertNotNil(h.server.entry(at: timestamp, type: "cal"))
        XCTAssertNotNil(h.server.entry(at: timestamp, type: "mbg"))
        await h.finish()
    }

    @MainActor func testRepeatedUpsertAndChangedValueUpdateOneRemoteRecord() async {
        let h = Harness()
        let reading = h.reading()
        h.manager.replaceBgReadingsInNightscout(bgReadings: [reading])
        await h.manager.waitForBgReplacements()
        let serverID = h.server.entries.first?["_id"] as? String
        h.manager.replaceBgReadingsInNightscout(bgReadings: [reading])
        await h.manager.waitForBgReplacements()
        reading.calculatedValue = 140
        reading.calculatedValueSlope = 2 / 60
        h.manager.replaceBgReadingsInNightscout(bgReadings: [reading])
        await h.manager.waitForBgReplacements()
        XCTAssertEqual(h.server.entries.count, 1)
        XCTAssertEqual(h.server.entries[0]["_id"] as? String, serverID)
        XCTAssertEqual(h.server.entries[0]["sgv"] as? Int, 140)
        XCTAssertEqual(h.server.entries[0]["direction"] as? String, reading.slopeName)
        XCTAssertTrue(h.server.requests.allSatisfy { $0.method == "POST" })
        await h.finish()
    }

    @MainActor func testNewRevisionQueuedDuringUploadUsesSnapshotsAndCannotBeOvertaken() async {
        let h = Harness()
        let reading = h.reading()
        let started = expectation(description: "first upload")
        h.server.holdNextRequest { started.fulfill() }
        h.manager.replaceBgReadingsInNightscout(bgReadings: [reading])
        await fulfillment(of: [started], timeout: 5)
        reading.calculatedValue = 130
        h.manager.replaceBgReadingsInNightscout(bgReadings: [reading])
        reading.calculatedValue = 150 // Mutation after enqueue must not alter either snapshot.
        XCTAssertEqual(h.server.requests.count, 1)
        h.server.releaseHeld()
        await h.manager.waitForBgReplacements()
        XCTAssertEqual(h.server.requests.compactMap { $0.entries?.first?["sgv"] as? Int }, [110, 130])
        XCTAssertEqual(h.server.entries.first?["sgv"] as? Int, 130)
        await h.finish()
    }

    @MainActor func testLostUploadReplyRetriesWithoutDeletionOrDuplicate() async {
        let h = Harness()
        let reading = h.reading()
        h.server.failNextUploadAfterStoring = true
        h.manager.replaceBgReadingsInNightscout(bgReadings: [reading])
        await h.manager.waitForBgReplacements()
        XCTAssertEqual(UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading, .distantPast)
        XCTAssertEqual(h.server.entries.count, 1)
        h.manager.replaceBgReadingsInNightscout(bgReadings: [reading])
        await h.manager.waitForBgReplacements()
        XCTAssertEqual(h.server.entries.count, 1)
        XCTAssertEqual(h.server.requests.map(\.method), ["POST", "POST"])
        XCTAssertGreaterThan(UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading!, .distantPast)
        await h.finish()
    }

    @MainActor func testFailedChunkStopsLaterChunksAndDoesNotAdvanceCursor() async {
        let h = Harness()
        let readings = (0..<301).map { h.reading($0) }
        h.server.nextStatus = 503
        h.manager.replaceBgReadingsInNightscout(bgReadings: readings)
        await h.manager.waitForBgReplacements()
        XCTAssertEqual(h.server.requests.count, 1)
        XCTAssertEqual(UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading, .distantPast)
        h.manager.replaceBgReadingsInNightscout(bgReadings: readings)
        await h.manager.waitForBgReplacements()
        XCTAssertEqual(h.server.requests.compactMap { $0.entries?.count }, [300, 300, 1])
        XCTAssertEqual(h.server.entries.count, 301)
        await h.finish()
    }

    @MainActor func testDisableUploadWhileWaitingStopsQueuedRevisionAndLaterChunks() async {
        let h = Harness()
        let started = expectation(description: "first chunk")
        h.server.holdNextRequest { started.fulfill() }
        let readings = (0..<301).map { h.reading($0) }
        h.manager.replaceBgReadingsInNightscout(bgReadings: readings)
        await fulfillment(of: [started], timeout: 5)
        h.manager.replaceBgReadingsInNightscout(bgReadings: [readings[0]])
        UserDefaults.standard.masterUploadDataToNightscout = false
        h.server.releaseHeld()
        await h.manager.waitForBgReplacements()
        XCTAssertEqual(h.server.requests.count, 1)
        XCTAssertEqual(UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading, .distantPast)
        await h.finish()
    }

    @MainActor func testDestinationChangeCannotRedirectQueuedDataOrConfirmOldSite() async {
        let h = Harness()
        let started = expectation(description: "original site upload")
        h.server.holdNextRequest { started.fulfill() }
        let reading = h.reading()
        h.manager.replaceBgReadingsInNightscout(bgReadings: [reading])
        await fulfillment(of: [started], timeout: 5)
        h.manager.replaceBgReadingsInNightscout(bgReadings: [reading])
        UserDefaults.standard.nightscoutUrl = "https://another-isolated-site.invalid"
        h.server.releaseHeld()
        await h.manager.waitForBgReplacements()
        XCTAssertEqual(h.server.requests.count, 1)
        XCTAssertEqual(UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading, .distantPast)
        await h.finish()
    }

    @MainActor func testExplicitDeletionKeepsCalibrationsManualAndNeighbouringReadings() async {
        let h = Harness()
        let removed = h.reading(), retained = h.reading(1)
        for reading in [removed, retained] { h.server.seed(reading.dictionaryRepresentationForNightscoutUpload()) }
        let stamp = removed.timeStamp.toMillisecondsAsInt64()
        for type in ["cal", "mbg", "legacy"] { h.server.seed(["type": type, "date": stamp]) }
        h.manager.replaceBgReadingsInNightscout(bgReadings: [retained],
            timeStampsToDelete: [removed.timeStamp, removed.timeStamp, retained.timeStamp], blocksDirectLiveUpload: true)
        await h.manager.waitForBgReplacements()
        XCTAssertEqual(h.server.requests.map(\.method), ["DELETE", "POST"])
        XCTAssertEqual(h.server.requests[0].query.filter { $0.name == "find[date][$in][]" }.count, 1)
        XCTAssertNil(h.server.entry(at: stamp, type: "sgv"))
        XCTAssertEqual(h.server.entries.count, 4)
        XCTAssertNotNil(h.server.entry(at: retained.timeStamp.toMillisecondsAsInt64(), type: "sgv"))
        XCTAssertFalse(h.server.requests.contains { $0.query.contains { $0.name.contains("$gte") || $0.name.contains("$lte") } })
        await h.finish()
    }

    @MainActor func testExactDeletionChunksFiftyTimestampsWithTypeOnEveryRequest() async {
        let h = Harness()
        let stamps = (0..<101).map { h.base.addingTimeInterval(Double($0) * 60) }
        h.manager.replaceBgReadingsInNightscout(bgReadings: [], timeStampsToDelete: stamps)
        await h.manager.waitForBgReplacements()
        XCTAssertEqual(h.server.requests.map { $0.query.filter { $0.name == "find[date][$in][]" }.count }, [50, 50, 1])
        XCTAssertTrue(h.server.requests.allSatisfy { $0.method == "DELETE" && $0.query.contains(URLQueryItem(name: "find[type]", value: "sgv")) })
        await h.finish()
    }

    @MainActor func testZeroOrUnknownDeleteCountNeverTriggersUntypedFallback() async {
        let h = Harness()
        for response in ["{\"n\":0}", "{\"deletedCount\":0}", "{\"result\":{\"n\":0}}", "{}"] {
            h.server.nextDeleteBody = Data(response.utf8)
            h.manager.deleteBgReadingFromNightscout(timeStampOfBgReadingToDelete: h.base)
            await h.manager.waitForBgReplacements()
        }
        XCTAssertEqual(h.server.requests.count, 4)
        XCTAssertTrue(h.server.requests.allSatisfy { $0.query.contains(URLQueryItem(name: "find[type]", value: "sgv")) })
        await h.finish()
    }

    func testDeleteCountFormatsAndUnknownRemainDistinct() throws {
        let decoder = JSONDecoder()
        typealias Response = NightscoutSyncManager.NightscoutDeleteEntriesResponse
        for text in ["{\"n\":7}", "{\"deletedCount\":7}", "{\"result\":{\"n\":7}}"] {
            XCTAssertEqual(try decoder.decode(Response.self, from: Data(text.utf8)).deletedEntriesCount, 7)
        }
        XCTAssertNil(try decoder.decode(Response.self, from: Data("{}".utf8)).deletedEntriesCount)
        XCTAssertThrowsError(try decoder.decode(Response.self, from: Data("{\"n\":\"invalid\"}".utf8)))
    }

    @MainActor func testDeleteFailureDoesNotUploadOrAdvanceAndCanBeRetried() async {
        let h = Harness()
        let reading = h.reading(1)
        h.server.nextStatus = 500
        h.manager.replaceBgReadingsInNightscout(bgReadings: [reading], timeStampsToDelete: [h.base])
        await h.manager.waitForBgReplacements()
        XCTAssertEqual(h.server.requests.map(\.method), ["DELETE"])
        XCTAssertEqual(UserDefaults.standard.timeStampLatestNightscoutUploadedBgReading, .distantPast)
        h.server.nextDeleteBody = Data("not-json".utf8)
        h.manager.replaceBgReadingsInNightscout(bgReadings: [reading], timeStampsToDelete: [h.base])
        await h.manager.waitForBgReplacements()
        XCTAssertEqual(h.server.requests.map(\.method), ["DELETE", "DELETE"])
        h.manager.replaceBgReadingsInNightscout(bgReadings: [reading], timeStampsToDelete: [h.base])
        await h.manager.waitForBgReplacements()
        XCTAssertEqual(h.server.requests.map(\.method), ["DELETE", "DELETE", "DELETE", "POST"])
        await h.finish()
    }

    @MainActor func testDisabledUploadDoesNotSendAnyRequest() async {
        let h = Harness()
        UserDefaults.standard.nightscoutEnabled = false
        h.manager.replaceBgReadingsInNightscout(bgReadings: [h.reading()], timeStampsToDelete: [h.base])
        await h.manager.waitForBgReplacements()
        XCTAssertTrue(h.server.requests.isEmpty)
        await h.finish()
    }

    @MainActor func testExplicitPostProcessingCadenceDeletesOnlySuppressedReadings() async {
        let h = Harness()
        let readings = (0..<12).map { h.reading($0) }
        XCTAssertTrue(h.stack.saveChanges())
        UserDefaults.standard.useFiveMinuteReadings = true
        let processor = BgPostProcessingManager(coreDataManager: h.stack, nightscoutSyncManager: h.manager, healthKitManager: nil)
        _ = processor.processBgReadings(processingStartDateOverride: h.base,
            fiveMinuteReadingsStartTimeStampOverride: h.base, allowHistoricalDownstreamRewrite: true)
        await h.manager.waitForBgReplacements()
        let expected = Set(readings.filter(\.isSuppressedByFiveMinuteCadence).map { String($0.timeStamp.toMillisecondsAsInt64()) })
        let actual = Set(h.server.requests.filter { $0.method == "DELETE" }.flatMap(\.query).filter { $0.name == "find[date][$in][]" }.compactMap(\.value))
        XCTAssertFalse(expected.isEmpty)
        XCTAssertEqual(actual, expected)
        XCTAssertTrue(h.server.requests.contains { $0.method == "POST" })
        await h.finish()
    }

    @MainActor func testPostProcessingWithoutCadenceRebuildNeverDeletes() async {
        let h = Harness()
        _ = (0..<12).map { h.reading($0) }
        XCTAssertTrue(h.stack.saveChanges())
        UserDefaults.standard.enableSmoothing = true
        let processor = BgPostProcessingManager(coreDataManager: h.stack, nightscoutSyncManager: h.manager, healthKitManager: nil)
        _ = processor.processBgReadings(processingStartDateOverride: h.base, allowHistoricalDownstreamRewrite: true)
        await h.manager.waitForBgReplacements()
        XCTAssertFalse(h.server.requests.isEmpty)
        XCTAssertTrue(h.server.requests.allSatisfy { $0.method == "POST" })
        await h.finish()
    }
}

private final class NightscoutHistoryServer {
    struct Request {
        let method: String
        let query: [URLQueryItem]
        let entries: [[String: Any]]?
    }
    let host = UUID().uuidString.lowercased() + ".invalid"
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var stored: [[String: Any]] = []
    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }
    var entries: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return stored }
    var nextStatus: Int?
    var nextDeleteBody: Data?
    var failNextUploadAfterStoring = false
    private var onHeld: (() -> Void)?
    private var held: (() -> Void)?

    func holdNextRequest(_ callback: @escaping () -> Void) { lock.lock(); onHeld = callback; lock.unlock() }
    func releaseHeld() { lock.lock(); let action = held; held = nil; lock.unlock(); action?() }
    func seed(_ entry: [String: Any]) { lock.lock(); stored.append(entry); lock.unlock() }
    func entry(at timestamp: Int64, type: String) -> [String: Any]? {
        entries.first { ($0["date"] as? NSNumber)?.int64Value == timestamp && $0["type"] as? String == type }
    }

    func receive(_ request: URLRequest, body: Data?, reply: @escaping (Int, Data?, Error?) -> Void) {
        let entries = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
        let row = Request(method: request.httpMethod ?? "GET", query: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [], entries: entries)
        lock.lock()
        recorded.append(row)
        let status = nextStatus ?? 200
        nextStatus = nil
        var data = Data("[]".utf8)
        var failure: Error?
        if status == 200 && row.method == "POST", let payload = entries {
            // Nightscout v1 storage contract: sysTime + type identifies the upsert;
            // $set without _id preserves an existing server ID and unrelated entry types.
            for entry in payload {
                if let index = stored.firstIndex(where: { $0["sysTime"] as? String == entry["sysTime"] as? String && $0["type"] as? String == entry["type"] as? String }) {
                    stored[index].merge(entry) { _, new in new }
                } else {
                    var new = entry
                    if new["_id"] == nil { new["_id"] = UUID().uuidString }
                    stored.append(new)
                }
            }
            if failNextUploadAfterStoring { failNextUploadAfterStoring = false; failure = URLError(.timedOut) }
        }
        if status == 200 && row.method == "DELETE" {
            let type = row.query.first { $0.name == "find[type]" }?.value
            let timestamps = Set(row.query.filter { $0.name == "find[date][$in][]" }.compactMap(\.value))
            let before = stored.count
            if type == "sgv" && !timestamps.isEmpty {
                stored.removeAll { $0["type"] as? String == type && timestamps.contains(($0["date"] as? NSNumber)?.stringValue ?? "") }
            }
            data = nextDeleteBody ?? Data("{\"deletedCount\":\(before - stored.count)}".utf8)
            nextDeleteBody = nil
        }
        let complete = { reply(status, data, failure) }
        if let callback = onHeld {
            onHeld = nil; held = complete; lock.unlock(); callback()
        } else { lock.unlock(); complete() }
    }
}

private final class NightscoutHistoryURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var servers: [String: NightscoutHistoryServer] = [:]
    static func register(_ server: NightscoutHistoryServer) { lock.lock(); servers[server.host] = server; lock.unlock() }
    static func unregister(_ server: NightscoutHistoryServer) { lock.lock(); servers.removeValue(forKey: server.host); lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let server = Self.servers[request.url?.host ?? ""]; Self.lock.unlock()
        guard let server else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            body = data
        }
        server.receive(request, body: body) { [weak self] status, data, error in
            guard let self else { return }
            if let error { self.client?.urlProtocol(self, didFailWithError: error); return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data ?? Data())
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
