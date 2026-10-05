import XCTest
@testable import xdrip

final class GlucoseForecastMLTrainerTests: XCTestCase {
    private let utc = Calendar(identifier: .gregorian)

    func testTrainingSessionsAreProtectedAndStaleCleanupPreservesActiveAndUnknownData() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                      isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let store = GlucoseForecastMLModelStore(directory: root)
        let active = try store.prepareTrainingSession()
        let sessionsRoot = root.appendingPathComponent("training-sessions", isDirectory: true)
        let job = active.appendingPathComponent("correction_30", isDirectory: true)
        try GlucoseForecastMLStoragePolicy.secureDirectory(job)
        for directory in [sessionsRoot, active, job] {
            XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup, true)
            #if os(iOS) && !targetEnvironment(simulator)
            let protection = try files.attributesOfItem(atPath: directory.path)[.protectionKey]
            XCTAssertEqual(protection as? FileProtectionType,
                           .completeUntilFirstUserAuthentication)
            #endif
        }
        let stale = sessionsRoot.appendingPathComponent(UUID().uuidString.lowercased(),
                                                        isDirectory: true)
        let unrelated = sessionsRoot.appendingPathComponent("keep-unrelated", isDirectory: true)
        try files.createDirectory(at: stale, withIntermediateDirectories: false)
        try files.createDirectory(at: unrelated, withIntermediateDirectories: false)
        try store.cleanupStaleTrainingSessions()
        XCTAssertTrue(files.fileExists(atPath: active.path))
        XCTAssertFalse(files.fileExists(atPath: stale.path))
        XCTAssertTrue(files.fileExists(atPath: unrelated.path))

        store.finishTrainingSession(active)
        XCTAssertFalse(files.fileExists(atPath: active.path))
        let interrupted = sessionsRoot.appendingPathComponent(UUID().uuidString.lowercased(),
                                                              isDirectory: true)
        try files.createDirectory(at: interrupted, withIntermediateDirectories: false)
        try GlucoseForecastMLModelStore(directory: root).cleanupStaleTrainingSessions()
        XCTAssertFalse(files.fileExists(atPath: interrupted.path))
        XCTAssertTrue(files.fileExists(atPath: unrelated.path))
    }

    func testModelRetentionKeepsActiveLatestVerifiedPreviousAndUnknownDirectories() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                      isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let models = root.appendingPathComponent("models", isDirectory: true)
        try files.createDirectory(at: models, withIntermediateDirectories: true)
        let activeID = UUID().uuidString.lowercased()
        let previousID = UUID().uuidString.lowercased()
        let oldID = UUID().uuidString.lowercased()
        let unknownID = UUID().uuidString.lowercased()
        let stagingID = UUID().uuidString.lowercased()
        for name in [activeID, previousID, oldID, unknownID, stagingID + ".staging"] {
            try files.createDirectory(at: models.appendingPathComponent(name, isDirectory: true),
                                      withIntermediateDirectories: false)
        }
        try Data("{\"modelID\":\"\(activeID)\"}".utf8)
            .write(to: root.appendingPathComponent("active.json"))
        let store = GlucoseForecastMLModelStore(directory: root)
        let dates = [oldID: Date(timeIntervalSince1970: 100),
                     previousID: Date(timeIntervalSince1970: 200)]
        try await store.pruneModelDirectories(activeModelID: activeID) {
            dates[$0.lastPathComponent]
        }
        XCTAssertTrue(files.fileExists(atPath: models.appendingPathComponent(activeID).path))
        XCTAssertTrue(files.fileExists(atPath: models.appendingPathComponent(previousID).path))
        XCTAssertFalse(files.fileExists(atPath: models.appendingPathComponent(oldID).path))
        XCTAssertTrue(files.fileExists(atPath: models.appendingPathComponent(unknownID).path))
        try store.cleanupAbandonedStaging(activeModelID: activeID)
        XCTAssertFalse(files.fileExists(atPath: models.appendingPathComponent(stagingID + ".staging").path))

        // Pointer uncertainty is a hard stop even if a verifier reports a package.
        try Data("{\"modelID\":\"unreadable\"}".utf8)
            .write(to: root.appendingPathComponent("active.json"), options: .atomic)
        try await store.pruneModelDirectories(activeModelID: activeID) { _ in .distantPast }
        XCTAssertTrue(files.fileExists(atPath: models.appendingPathComponent(previousID).path))
        XCTAssertTrue(files.fileExists(atPath: models.appendingPathComponent(unknownID).path))
    }

    func testInstallRetentionKeepsExactFormerActiveModelInsteadOfNewerOrphan() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                      isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let models = root.appendingPathComponent("models", isDirectory: true)
        try files.createDirectory(at: models, withIntermediateDirectories: true)
        let activeID = UUID().uuidString.lowercased()
        let formerActiveID = UUID().uuidString.lowercased()
        let newerOrphanID = UUID().uuidString.lowercased()
        for id in [activeID, formerActiveID, newerOrphanID] {
            try files.createDirectory(at: models.appendingPathComponent(id, isDirectory: true),
                                      withIntermediateDirectories: false)
        }
        try Data("{\"modelID\":\"\(activeID)\"}".utf8)
            .write(to: root.appendingPathComponent("active.json"))
        let dates = [formerActiveID: Date(timeIntervalSince1970: 100),
                     newerOrphanID: Date(timeIntervalSince1970: 200)]
        try await GlucoseForecastMLModelStore(directory: root).pruneModelDirectories(
            activeModelID: activeID, protectedPreviousModelID: formerActiveID) {
                dates[$0.lastPathComponent]
            }
        XCTAssertTrue(files.fileExists(atPath: models.appendingPathComponent(activeID).path))
        XCTAssertTrue(files.fileExists(atPath: models.appendingPathComponent(formerActiveID).path))
        XCTAssertFalse(files.fileExists(atPath: models.appendingPathComponent(newerOrphanID).path))
    }

    #if canImport(CreateML)
    func testFailedCandidateInstallLeavesPreviousActiveModelUntouched() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                     isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let previousID = UUID().uuidString.lowercased()
        let previous = root.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(previousID, isDirectory: true)
        try files.createDirectory(at: previous, withIntermediateDirectories: true)
        let marker = previous.appendingPathComponent("previous-model-marker")
        let markerData = Data("keep previous model".utf8)
        try markerData.write(to: marker)
        let pointer = root.appendingPathComponent("active.json")
        let pointerData = Data("{\"modelID\":\"\(previousID)\"}".utf8)
        try pointerData.write(to: pointer)

        let incomplete = GlucoseForecastMLTrainedCandidate(
            models: [:], metadata: reviewMetadata())
        do {
            _ = try await GlucoseForecastMLModelStore(directory: root).install(incomplete)
            XCTFail("An incomplete training candidate must never replace the active model")
        } catch GlucoseForecastMLTrainingFailure.packageInvalid {
            // A failed training/install attempt must not move the active pointer.
        }
        XCTAssertEqual(try Data(contentsOf: pointer), pointerData)
        XCTAssertEqual(try Data(contentsOf: marker), markerData)
        XCTAssertFalse(files.fileExists(atPath: root.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(incomplete.metadata.modelID, isDirectory: true).path))
    }
    #endif

    func testPriorModelAndDataGenerationCannotBeUsed() async throws {
        let current = reviewMetadata()
        XCTAssertTrue(GlucoseForecastMLModelCompatibility.isUsable(current))

        let oldSchema = reviewMetadata(schemaVersion:
            GlucoseForecastMLModelMetadata.schemaVersion - 1)
        XCTAssertFalse(GlucoseForecastMLModelCompatibility.isUsable(oldSchema))

        let encoded = try JSONEncoder().encode(current.context)
        var contextJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        contextJSON["featureVersion"] = "previous-data-generation"
        let oldContext = try JSONDecoder().decode(GlucoseForecastMLContext.self,
            from: JSONSerialization.data(withJSONObject: contextJSON))
        let oldDataGeneration = reviewMetadata(context: oldContext)
        XCTAssertFalse(GlucoseForecastMLModelCompatibility.isUsable(oldDataGeneration))

        for metadata in [oldSchema, oldDataGeneration] {
            let files = FileManager.default
            let root = files.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            defer { try? files.removeItem(at: root) }
            let package = root.appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(metadata.modelID, isDirectory: true)
            try files.createDirectory(at: package, withIntermediateDirectories: true)
            try JSONEncoder().encode(metadata).write(
                to: package.appendingPathComponent("metadata.json"))
            let priorSession = root.appendingPathComponent("training-sessions", isDirectory: true)
                .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            try files.createDirectory(at: priorSession, withIntermediateDirectories: true)
            try Data("old-checkpoint".utf8).write(
                to: priorSession.appendingPathComponent("checkpoint"))
            try Data("{\"modelID\":\"\(metadata.modelID)\"}".utf8)
                .write(to: root.appendingPathComponent("active.json"))
            let store = GlucoseForecastMLModelStore(directory: root)
            let loaded = await store.loadActive()
            XCTAssertNil(loaded)
            XCTAssertTrue(files.fileExists(atPath: package.path))
            XCTAssertFalse(files.fileExists(atPath: priorSession.path))
            XCTAssertThrowsError(try store.saveReview(metadata))
        }
    }

    func testPriorReviewIsHiddenAfterGenerationChange() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                     isDirectory: true)
        defer { try? files.removeItem(at: root) }
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        let store = GlucoseForecastMLModelStore(directory: root)
        let metadata = reviewMetadata()
        let reviewURL = root.appendingPathComponent("latest-review.json")

        // The previous app saved a bare report with no generation stamp.
        try JSONEncoder().encode(metadata.selfCheck).write(to: reviewURL)
        XCTAssertNil(store.loadReview())

        try store.saveReview(metadata)
        XCTAssertEqual(store.loadReview()?.promoted, true)
        var reviewJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: reviewURL)) as? [String: Any])
        reviewJSON["featureVersion"] = "previous-data-generation"
        try JSONSerialization.data(withJSONObject: reviewJSON).write(to: reviewURL)
        XCTAssertNil(store.loadReview())
    }

    func testTrainingStatusShowsCompletedStepsAndFriendlyResults() {
        let fallback: GlucoseForecastMLStatusPresentation.Localize = { _, value in value }
        XCTAssertEqual(GlucoseForecastMLStatusPresentation.progress(
            .trainingModels(completed: 0, total: 12), localize: fallback),
            "0 of 12 training runs completed")
        XCTAssertEqual(GlucoseForecastMLStatusPresentation.progress(
            .trainingModels(completed: 12, total: 12), localize: fallback),
            "12 of 12 training runs completed")
        XCTAssertEqual(GlucoseForecastMLStatusPresentation.progress(
            .installing, localize: fallback), "Saving and checking the model package…")
        XCTAssertNil(GlucoseForecastMLStatusPresentation.outcome("training", localize: fallback))
        let issue = GlucoseForecastMLTrainingIssue(.calibration,
            horizonMinutes: 60, actual: 9, required: 10,
            unit: .usableDays,
            periodStart: Date(timeIntervalSince1970: 1_700_000_000),
            periodEnd: Date(timeIntervalSince1970: 1_700_086_400))
        XCTAssertEqual(GlucoseForecastMLStatusPresentation.outcome(
            "trainingIssue", issue: issue, localize: fallback), issue.danishMessage)
        XCTAssertEqual(GlucoseForecastMLStatusPresentation.preparationOrPreviousIssue(
            "Ny historiklæsning: 1 af 60", previousIssue: issue),
            "Ny historiklæsning: 1 af 60")
        XCTAssertEqual(GlucoseForecastMLStatusPresentation.preparationOrPreviousIssue(
            "", previousIssue: issue), issue.danishMessage)
        XCTAssertTrue(issue.danishMessage.contains("Kalibrering (+60): 9 af 10 brugbare dage"))
        XCTAssertTrue(issue.danishMessage.contains("2023"))
        XCTAssertEqual(GlucoseForecastMLStatusPresentation.outcome(
            GlucoseForecastMLTrainingFailure.insufficientSelfCheckRows.rawValue,
            localize: fallback),
            "There are not enough usable historical readings to train and check a model yet.")
        XCTAssertEqual(GlucoseForecastMLStatusPresentation.outcome("activated", localize: fallback),
                       "Training finished. The checked model is now active.")
        XCTAssertEqual(GlucoseForecastMLStatusPresentation.maeMmolPerL(18.018018018),
                       1.0, accuracy: 0.001)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let rejected = GlucoseForecastMLSelfCheck(startedAt: date, endedAt: date,
            horizons: [:], activeComparisonWasFair: false, promoted: false,
            rejectionReasons: ["candidateNotBetterThanEngineAt60"],
            retrospectiveUnknownCount: 0)
        XCTAssertEqual(GlucoseForecastMLStatusPresentation.outcome(
            "rejected", report: rejected, localize: fallback),
            "Rejected in self-check: ML was not better than the engine at +60 minutes.")
    }

    func testFairAccuracyUsesIdenticalPairsAndSignedPredictionMinusActual() throws {
        let actual = [100.0, 130.0]
        let engine = try XCTUnwrap(GlucoseForecastMLFairAccuracy.measure(
            predictions: [110, 140], actuals: actual))
        let ml = try XCTUnwrap(GlucoseForecastMLFairAccuracy.measure(
            predictions: [120, 120], actuals: actual))
        let unchanged = try XCTUnwrap(GlucoseForecastMLFairAccuracy.measure(
            predictions: [100, 100], actuals: actual))
        XCTAssertEqual(engine.count, 2)
        XCTAssertEqual(engine.maeMgdl, 10)
        XCTAssertEqual(engine.signedErrorMgdl, 10)
        XCTAssertEqual(ml.maeMgdl, 15)
        XCTAssertEqual(ml.signedErrorMgdl, 5)
        XCTAssertEqual(unchanged.maeMgdl, 15)
        XCTAssertEqual(unchanged.signedErrorMgdl, -15)
        XCTAssertNil(GlucoseForecastMLFairAccuracy.measure(predictions: [100], actuals: actual))
    }

    func testSelfCheckCSVHasOneRowPerAnchorAndKeepsSettingsAndTreatmentTotals() throws {
        let metadata = reviewMetadata()
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let row = GlucoseForecastMLReviewRow(referenceDate: reference,
            sourceIdentity: "sensor:A,\"B", glucoseMgdl: 121,
            engineMgdl: [30: 122, 60: 123, 120: 124],
            mlMgdl: [30: 121.5, 60: 122.5, 120: 123.5],
            actualMgdl: [30: 120, 60: 125, 120: 126],
            actualDate: [30: reference.addingTimeInterval(1800),
                         60: reference.addingTimeInterval(3600),
                         120: reference.addingTimeInterval(7200)],
            iobUnits: 1.25, cobGrams: 12,
            bolusUnitsInWindow: 3, carbohydrateGramsInWindow: 20)
        let data = try XCTUnwrap(GlucoseForecastMLReviewCSV.data([row],
                                                                  context: metadata.context))
        let csv = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count, 2)
        XCTAssertTrue(csv.contains("\"sensor:A,\"\"B\""))
        XCTAssertTrue(csv.contains("121.0,122.0,123.0,124.0,121.5,122.5,123.5"))
        XCTAssertTrue(csv.contains(",1.25,12.0,3.0,20.0\r\n"))
        XCTAssertTrue(csv.contains(metadata.context.engineVersion))
        XCTAssertTrue(csv.contains(metadata.context.featureVersion))

        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                     isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let store = GlucoseForecastMLModelStore(directory: root)
        try store.saveReview(metadata, rows: [row])
        let first = try XCTUnwrap(store.reviewCSVURL())
        XCTAssertEqual(try Data(contentsOf: first), data)
        let next = reviewMetadata()
        try store.saveReview(next, rows: [row])
        XCTAssertFalse(files.fileExists(atPath: first.path))
        XCTAssertNotNil(store.reviewCSVURL())
    }

    func testFailedReviewCommitRemovesNewSensitiveCSVAndDoesNotPruneOldEvidence() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString,
                                                                     isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let store = GlucoseForecastMLModelStore(directory: root)
        let old = reviewMetadata()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func row(_ glucose: Double) -> GlucoseForecastMLReviewRow {
            GlucoseForecastMLReviewRow(referenceDate: date,
                sourceIdentity: "sensor:A", glucoseMgdl: glucose,
                engineMgdl: [30: 120, 60: 120, 120: 120],
                mlMgdl: [30: 120, 60: 120, 120: 120],
                actualMgdl: [30: 120, 60: 120, 120: 120],
                actualDate: [30: date, 60: date, 120: date],
                iobUnits: 0, cobGrams: 0, bolusUnitsInWindow: 0,
                carbohydrateGramsInWindow: 0)
        }
        try store.saveReview(old, rows: [row(120)])
        let oldCSV = try XCTUnwrap(store.reviewCSVURL())
        let oldData = try Data(contentsOf: oldCSV)
        XCTAssertThrowsError(try store.saveReview(old, rows: [row(121)]))
        XCTAssertEqual(try Data(contentsOf: oldCSV), oldData)
        XCTAssertNotNil(store.loadReview())

        // A directory at the review destination blocks the commit *after*
        // writing the new protected CSV. The catch must remove that CSV.
        let reviewURL = root.appendingPathComponent("latest-review.json")
        try files.removeItem(at: reviewURL)
        try files.createDirectory(at: reviewURL, withIntermediateDirectories: false)
        XCTAssertEqual(try files.attributesOfItem(atPath: reviewURL.path)[.type]
            as? FileAttributeType, .typeDirectory)
        let candidate = reviewMetadata()
        XCTAssertThrowsError(try store.saveReview(candidate, rows: [row(130)]))
        XCTAssertFalse(files.fileExists(atPath: root.appendingPathComponent(
            "self-check-\(candidate.modelID).csv").path))
        XCTAssertEqual(try files.attributesOfItem(atPath: reviewURL.path)[.type]
            as? FileAttributeType, .typeDirectory)
        XCTAssertTrue(files.fileExists(atPath: oldCSV.path),
                      "Unrelated previous evidence is not pruned after a failed commit")
        let temporary = try files.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("latest-review-") && $0.hasSuffix(".tmp") }
        XCTAssertTrue(temporary.isEmpty)
    }

    func testCleanLocalLoggingTransitionAcceptsPreviouslySerializedMetadata() throws {
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        let transition = TreatmentSourceCutover(cutoff: cutoff,
            insulinSourceBundleID: "com.example.insulin",
            carbohydrateSourceBundleID: "com.example.carbs")
        let currentPolicy = transitionPolicy(.none, nightscoutEnabled: false)
        let oldPolicy = transitionPolicy(.automatic, nightscoutEnabled: false)
        let old = transitionContext(policy: oldPolicy, transition: transition, old: true)
        let current = transitionContext(policy: currentPolicy, transition: transition, old: false)
        // Decode serialized metadata from an earlier model. This checks the legacy
        // source signature after a restart; package loading of all six model files
        // remains covered by the model-store validation path.
        let oldJSON = try JSONEncoder().encode(reviewMetadata(context: old))
        let persisted = try JSONDecoder().decode(GlucoseForecastMLModelMetadata.self, from: oldJSON)
        XCTAssertEqual(GlucoseForecastMLModelCompatibility.assess(persisted,
            current: current, currentPolicy: currentPolicy, cutover: transition),
            .transitionCompatible(transition))
        XCTAssertNotEqual(persisted.context, current)
        XCTAssertEqual(GlucoseForecastMLModelCompatibility.assess(persisted,
            current: old, currentPolicy: oldPolicy, cutover: nil), .exact)
    }

    func testTransitionRejectsUnverifiedSourcesAndChangedParameters() {
        let transition = TreatmentSourceCutover(cutoff: Date(timeIntervalSince1970: 1_800_000_000),
            insulinSourceBundleID: "com.example.insulin",
            carbohydrateSourceBundleID: "com.example.carbs")
        let currentPolicy = transitionPolicy(.none, nightscoutEnabled: false)
        let oldPolicy = transitionPolicy(.automatic, nightscoutEnabled: false)
        let old = transitionContext(policy: oldPolicy, transition: transition, old: true)
        let current = transitionContext(policy: currentPolicy, transition: transition, old: false)
        let metadata = reviewMetadata(context: old)
        typealias Compatibility = GlucoseForecastMLModelCompatibility
        XCTAssertEqual(Compatibility.assess(metadata, current: current,
            currentPolicy: currentPolicy, cutover: nil), .invalid(.sourceChanged))
        XCTAssertEqual(Compatibility.assess(metadata, current: current,
            currentPolicy: currentPolicy, cutover: transition, restoreRequiresSetup: true),
            .invalid(.sourceSetupIncomplete))
        let wrongID = TreatmentSourceCutover(cutoff: transition.cutoff,
            insulinSourceBundleID: "com.example.other",
            carbohydrateSourceBundleID: transition.carbohydrateSourceBundleID)
        XCTAssertEqual(Compatibility.assess(metadata, current: current,
            currentPolicy: currentPolicy, cutover: wrongID),
            .invalid(.transitionUnverified))
        let changed = GlucoseForecastMLContext(sensitivityMgdlPerUnit: 41,
            carbohydrateRatioGramsPerUnit: 10, settings: TherapyModelSettings(),
            sourceSignature: current.sourceSignature)!
        XCTAssertEqual(Compatibility.assess(metadata, current: changed,
            currentPolicy: currentPolicy, cutover: transition), .invalid(.parametersChanged))
        let malformed = GlucoseForecastMLContext(sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, settings: TherapyModelSettings(),
            sourceSignature: "opaque-source")!
        XCTAssertEqual(Compatibility.assess(metadata, current: malformed,
            currentPolicy: currentPolicy, cutover: transition), .invalid(.malformedSignature))

        let remotePolicy = transitionPolicy(.nightscout, nightscoutEnabled: true)
        let remoteOld = transitionContext(policy: remotePolicy, transition: transition, old: true)
        XCTAssertEqual(Compatibility.assess(reviewMetadata(context: remoteOld), current: current,
            currentPolicy: currentPolicy, cutover: transition), .invalid(.transitionUnverified))
    }

    func testProspectivePairsSurviveRestartAndMissingLedgerFailsClosed() throws {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent(UUID().uuidString,
            isDirectory: true)
        let suiteName = "test.forecast.transition.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            try? files.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let modelID = UUID().uuidString.lowercased()
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        let reference = cutoff.addingTimeInterval(3600)
        let prediction = GlucoseForecastMLTransitionEvidence.Prediction(
            referenceDate: reference, computedAt: reference.addingTimeInterval(15),
            sensorID: "sensor-a", engine60Mgdl: 150, model60Mgdl: 140)
        let first = GlucoseForecastMLTransitionEvidence(directory: directory, defaults: defaults)
        first.capture(prediction, modelID: modelID, cutoff: cutoff, onChange: {})
        if case .awaiting(_, let pairs) = first.status(modelID: modelID, cutoff: cutoff) {
            XCTAssertEqual(pairs, 0)
        } else { XCTFail("Expected pending comparison") }
        let restarted = GlucoseForecastMLTransitionEvidence(directory: directory, defaults: defaults)
        // A different sensor cannot furnish the target, even with an exact timestamp.
        restarted.observe([.init(date: prediction.targetDate, glucoseMgdl: 140,
            sensorID: "sensor-b")], at: prediction.targetDate.addingTimeInterval(180),
            modelID: modelID, cutoff: cutoff, onChange: {})
        restarted.observe([.init(date: prediction.targetDate.addingTimeInterval(30),
            glucoseMgdl: 145, sensorID: "sensor-a")],
            at: prediction.targetDate.addingTimeInterval(240),
            modelID: modelID, cutoff: cutoff, onChange: {})
        if case .awaiting(_, let pairs) = restarted.status(modelID: modelID, cutoff: cutoff) {
            XCTAssertEqual(pairs, 1)
        } else { XCTFail("Expected one paired result after restart") }
        let ledger = try XCTUnwrap(files.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.hasPrefix("transition-") }))
        try files.removeItem(at: ledger)
        let afterLoss = GlucoseForecastMLTransitionEvidence(directory: directory, defaults: defaults)
        if case .unreadable = afterLoss.status(modelID: modelID, cutoff: cutoff) {
            // Loss of the only prospective ledger disables transition inference.
        } else { XCTFail("Missing ledger must not start a fresh comparison") }
    }

    func testProspectiveSevenUsableDaysUsePairedLatestLocalDays() {
        typealias Evidence = GlucoseForecastMLTransitionEvidence
        XCTAssertGreaterThanOrEqual(Evidence.State.minimumPairsPerDay * 7,
            GlucoseForecastMLChronology.minimumSelfCheckRows)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let pairs: [Evidence.Pair] = (0..<8).flatMap { day in
            (0..<Evidence.State.minimumPairsPerDay).map { index in
                let reference = start.addingTimeInterval(Double(day * 86400 + 12 * 3600 + index * 600))
                let prediction = Evidence.Prediction(referenceDate: reference,
                    computedAt: reference.addingTimeInterval(10), sensorID: "sensor-a",
                    engine60Mgdl: 150, model60Mgdl: day == 0 ? 180 : 145)
                return Evidence.Pair(prediction: prediction,
                    actualDate: prediction.targetDate, actualMgdl: 145)
            }
        }
        let result = Evidence.State.evaluate(pairs, timeZoneIdentifier: "UTC")
        XCTAssertEqual(result?.usableDays, 7)
        XCTAssertEqual(result?.pairCount, 7 * Evidence.State.minimumPairsPerDay)
        XCTAssertEqual(result?.modelMAE, 0)
        XCTAssertEqual(result?.engineMAE, 5)
    }

    private func transitionPolicy(_ source: TherapyDataSourceType,
                                  nightscoutEnabled: Bool) -> DataFlowPolicy {
        DataFlowPolicy(isMaster: true, followerDataSource: .nightscout,
            therapyDataSourceSelection: source, nightscoutEnabled: nightscoutEnabled,
            masterUploadsGlucoseToNightscout: false,
            followerUploadsGlucoseToNightscout: false,
            nightscoutFollowType: .none)
    }

    private func transitionContext(policy: DataFlowPolicy,
                                   transition: TreatmentSourceCutover,
                                   old: Bool) -> GlucoseForecastMLContext {
        let settings = TherapyModelSettings()
        let flags = old ? "true" : "false"
        let tail = old ? "cutover:0.0::" :
            "cutover:\(transition.cutoff.timeIntervalSince1970):" +
                "\(transition.insulinSourceBundleID):\(transition.carbohydrateSourceBundleID)"
        let signature = "\(policy)|\(settings)|120|40.0|10.0|" +
            "\(flags):\(transition.insulinSourceBundleID)|" +
            "\(flags):\(transition.carbohydrateSourceBundleID)|\(tail)"
        return GlucoseForecastMLContext(sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, settings: settings,
            sourceSignature: signature)!
    }

    private func reviewMetadata(schemaVersion: Int = GlucoseForecastMLModelMetadata.schemaVersion,
                                context: GlucoseForecastMLContext? = nil)
        -> GlucoseForecastMLModelMetadata {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let context = context ?? GlucoseForecastMLContext(
            sensitivityMgdlPerUnit: 40, carbohydrateRatioGramsPerUnit: 10,
            settings: TherapyModelSettings(), sourceSignature: "test-source")!
        let report = GlucoseForecastMLSelfCheck(
            startedAt: date, endedAt: date, horizons: [:],
            activeComparisonWasFair: false, promoted: true,
            rejectionReasons: [], retrospectiveUnknownCount: 0)
        return GlucoseForecastMLModelMetadata(
            schemaVersion: schemaVersion, modelID: UUID().uuidString.lowercased(),
            trainedAt: date, context: context,
            featureNames: GlucoseForecastMLFeatures.featureNames,
            trainingStart: date, trainingEnd: date,
            calibrationStart: date, calibrationEnd: date,
            usableDayCount: 60, trainingCounts: [:], walkForwardCounts: [:],
            calibrationCounts: [:], selfCheckCounts: [:], calibrations: [:],
            selfCheck: report, retrospectiveUnknownCount: 0)
    }

    private func examples(days: Int = 60, anchorsPerDay: Int = 10) -> [GlucoseForecastMLReplayExample] {
        var calendar = utc
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        return (0..<days).flatMap { day -> [GlucoseForecastMLReplayExample] in
            let date = calendar.date(byAdding: .day, value: day, to: start)!
            return (0..<anchorsPerDay).flatMap { anchor -> [GlucoseForecastMLReplayExample] in
                let reference = date.addingTimeInterval(12 * 3600 + Double(anchor * 10 * 60))
                return [30, 60, 120].map { horizon in
                    let row = GlucoseForecastMLFeatureRow(
                        horizonMinutes: horizon, referenceDate: reference,
                        engineValue: 150, glucose: 145, sensorID: "sensor-a",
                        values: Array(repeating: 1, count: 16))
                    return GlucoseForecastMLReplayExample(
                        row: row, targetDate: reference.addingTimeInterval(Double(horizon * 60)),
                        targetGlucoseMgdl: 155, engineTargetGlucoseMgdl: 150,
                        engineTrajectoryMgdl: Array(repeating: 150, count: 25),
                        sourceIdentity: "sensor:sensor-a",
                        treatmentAvailability: .retrospectiveUnknown,
                        settingsAvailability: .retrospectiveUnknown)
                }
            }
        }
    }

    private func chronologyNow(_ rows: [GlucoseForecastMLReplayExample]) -> Date {
        rows.map { $0.row.referenceDate }.max()!.addingTimeInterval(4 * 3600)
    }

    private func completeAnchor(at reference: Date) -> [GlucoseForecastMLReplayExample] {
        [30, 60, 120].map { horizon in
            let row = GlucoseForecastMLFeatureRow(
                horizonMinutes: horizon, referenceDate: reference,
                engineValue: 150, glucose: 145, sensorID: "sensor-a",
                values: Array(repeating: 1, count: 16))
            return GlucoseForecastMLReplayExample(
                row: row, targetDate: reference.addingTimeInterval(Double(horizon * 60)),
                targetGlucoseMgdl: 155, engineTargetGlucoseMgdl: 150,
                engineTrajectoryMgdl: Array(repeating: 150, count: 25),
                sourceIdentity: "sensor:sensor-a",
                treatmentAvailability: .retrospectiveUnknown,
                settingsAvailability: .retrospectiveUnknown)
        }
    }

    func testChronologyKeepsThreeDisjointPeriodsAndEmbargoesCrossBoundaryTarget() throws {
        var calendar = utc
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var rows = examples()
        let bStart = calendar.date(from: DateComponents(year: 2026, month: 2, day: 2))!
        let crossingReference = bStart.addingTimeInterval(-90 * 60)
        let crossing = GlucoseForecastMLReplayExample(
            row: GlucoseForecastMLFeatureRow(horizonMinutes: 120,
                referenceDate: crossingReference, engineValue: 150, glucose: 145,
                sensorID: "sensor-a", values: Array(repeating: 1, count: 16)),
            targetDate: crossingReference.addingTimeInterval(120 * 60),
            targetGlucoseMgdl: 155, engineTargetGlucoseMgdl: 150,
            engineTrajectoryMgdl: Array(repeating: 150, count: 25),
            sourceIdentity: "sensor:sensor-a", treatmentAvailability: .retrospectiveUnknown,
            settingsAvailability: .retrospectiveUnknown)
        rows.append(crossing)
        let split = try GlucoseForecastMLChronology.split(rows, calendar: calendar,
                                                          now: chronologyNow(rows))
        XCTAssertEqual(split.usableDayCount, 60)
        XCTAssertEqual(split.bStart, bStart)
        for horizon in [30, 60, 120] {
            XCTAssertEqual(split.a[horizon]?.count, 320)
            XCTAssertEqual(split.b[horizon]?.count, 140)
            XCTAssertEqual(split.c[horizon]?.count, 140)
            XCTAssertTrue(split.a[horizon]!.allSatisfy { $0.targetDate < split.bStart })
            XCTAssertTrue(split.b[horizon]!.allSatisfy { $0.targetDate < split.cStart })
        }
        XCTAssertFalse(split.a[120]!.contains { $0.row.referenceDate == crossingReference })
    }

    func testSparseRecentPeriodCannotSelfCheckOrPromote() {
        var calendar = utc
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let cStart = calendar.date(from: DateComponents(year: 2026, month: 2, day: 16))!
        // Keep one +120 example on each of C's 14 days, below the count floor.
        let curtailed = examples().filter { example in
            !(example.row.horizonMinutes == 120 && example.row.referenceDate >=
              cStart
              && !(calendar.component(.hour, from: example.row.referenceDate) == 12
                   && calendar.component(.minute, from: example.row.referenceDate) == 0))
        }
        XCTAssertThrowsError(try GlucoseForecastMLChronology.split(
            curtailed, calendar: calendar, now: chronologyNow(curtailed))) { error in
            let issue = error as? GlucoseForecastMLTrainingIssue
            XCTAssertEqual(issue?.phase, .selfCheck)
            XCTAssertEqual(issue?.horizonMinutes, 30)
            XCTAssertEqual(issue?.actual, 14)
            XCTAssertEqual(issue?.required, 100)
            XCTAssertTrue(issue?.danishMessage.contains("14 af 100 rækker") == true)
        }
    }

    func testLatestFourteenUsableDaysSkipTwoWeekCalendarHole() throws {
        var calendar = utc
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let all = examples(days: 88)
        let withHole = all.filter { example in
            let day = calendar.dateComponents([.day], from: start,
                to: example.row.referenceDate).day!
            return !(60..<74).contains(day)
        }
        let split = try GlucoseForecastMLChronology.split(withHole,
            calendar: calendar, now: chronologyNow(withHole))
        XCTAssertEqual(split.cStart, calendar.date(byAdding: .day, value: 74, to: start))
        XCTAssertEqual(split.bStart, calendar.date(byAdding: .day, value: 46, to: start))
        XCTAssertEqual(split.usableDayCount, 74)
        for horizon in [30, 60, 120] {
            XCTAssertEqual(split.a[horizon]?.count, 460)
            XCTAssertEqual(split.b[horizon]?.count, 140)
            XCTAssertEqual(split.c[horizon]?.count, 140)
        }
    }

    func testFourteenUsableSelfCheckDaysStillNeedOneHundredRows() {
        var calendar = utc
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let all = examples()
        let cStart = calendar.date(from: DateComponents(year: 2026, month: 2, day: 16))!
        let sparseC = all.filter { example in
            let reference = example.row.referenceDate
            guard reference >= cStart else { return true }
            let hour = calendar.component(.hour, from: reference)
            let minute = calendar.component(.minute, from: reference)
            return hour == 12 || (hour == 13 && minute == 0)
        }
        XCTAssertThrowsError(try GlucoseForecastMLChronology.split(sparseC,
            calendar: calendar, now: chronologyNow(sparseC))) { error in
            let issue = error as? GlucoseForecastMLTrainingIssue
            XCTAssertEqual(issue?.phase, .selfCheck)
            XCTAssertEqual(issue?.actual, 98)
            XCTAssertEqual(issue?.required, 100)
            XCTAssertTrue(issue?.danishMessage.contains("98 af 100 rækker") == true)
        }
    }

    func testStaleSelfCheckAndExcessiveCalibrationSpanExplainActualLimits() {
        var calendar = utc
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let all = examples()
        let staleNow = all.map { $0.row.referenceDate }.max()!
            .addingTimeInterval(48 * 3600 + 60)
        XCTAssertThrowsError(try GlucoseForecastMLChronology.split(all,
            calendar: calendar, now: staleNow)) { error in
            let issue = error as? GlucoseForecastMLTrainingIssue
            XCTAssertEqual(issue?.phase, .freshness)
            XCTAssertEqual(issue?.unit, .ageHours)
            XCTAssertEqual(issue?.actual, 49)
            XCTAssertEqual(issue?.required, 48)
            XCTAssertTrue(issue?.danishMessage.contains("49 timer") == true)
        }

        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let longHistory = examples(days: 150).filter { example in
            let day = calendar.dateComponents([.day], from: start,
                to: example.row.referenceDate).day!
            return !(60..<130).contains(day)
        }
        XCTAssertThrowsError(try GlucoseForecastMLChronology.split(longHistory,
            calendar: calendar, now: chronologyNow(longHistory))) { error in
            let issue = error as? GlucoseForecastMLTrainingIssue
            XCTAssertEqual(issue?.phase, .freshness)
            XCTAssertEqual(issue?.unit, .spanDays)
            XCTAssertEqual(issue?.actual, 98)
            XCTAssertEqual(issue?.required, 60)
            XCTAssertTrue(issue?.danishMessage.contains("98 kalenderdage") == true)
        }
    }

    func testDetailedIssueMessagesNamePhaseHorizonFoldAndCounts() {
        let cases: [(GlucoseForecastMLTrainingIssue, String)] = [
            (.init(.history, actual: 58, required: 60, unit: .usableDays),
             "Historik: 58 af 60 brugbare dage"),
            (.init(.training, horizonMinutes: 120, actual: 28, required: 30,
                   unit: .usableDays), "Træning (+120): 28 af 30 brugbare dage"),
            (.init(.walkForward, horizonMinutes: 30, fold: 2,
                   actual: 199, required: 200, unit: .rows),
             "Tidsopdelt træning (+30) · fold 2: 199 af 200 rækker"),
            (.init(.walkForward, horizonMinutes: 60,
                   actual: 99, required: 100, unit: .residuals),
             "Tidsopdelt træning (+60): 99 af 100 residualer"),
            (.init(.calibration, horizonMinutes: 60,
                   actual: 99, required: 100, unit: .calibrationPredictions),
             "Kalibrering (+60): 99 af 100 gyldige kalibreringsprognoser"),
            (.init(.selfCheck, horizonMinutes: 120,
                   actual: 99, required: 100, unit: .rows),
             "Selvtjek (+120): 99 af 100 rækker")
        ]
        for (issue, expected) in cases {
            XCTAssertTrue(issue.danishMessage.hasPrefix(expected), issue.danishMessage)
        }
    }

    func testCorrectionLimitAndUnsafeCenterUseWholeEngineFallback() {
        XCTAssertEqual(GlucoseForecastMLChronology.clampedCorrection(40), 27)
        XCTAssertEqual(GlucoseForecastMLChronology.clampedCorrection(-40), -27)
        XCTAssertEqual(GlucoseForecastMLChronology.finalGlucose(engine: 570, correction: 40), 597)
        XCTAssertNil(GlucoseForecastMLChronology.finalGlucose(engine: 580, correction: 40))
        XCTAssertNil(GlucoseForecastMLChronology.finalGlucose(engine: 30, correction: -40))
        XCTAssertEqual(GlucoseForecastMLChronology.positiveError(-5), 1)
        XCTAssertNil(GlucoseForecastMLChronology.positiveError(.nan))
    }

    func testCalibrationUsesDeterministicNearestRank() {
        XCTAssertEqual(GlucoseForecastMLChronology.percentile80([10, 1, 8, 2, 5]), 8)
        XCTAssertEqual(GlucoseForecastMLChronology.percentile80([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]), 8)
        XCTAssertEqual(GlucoseForecastMLChronology.percentile80([0, 2, 2, 5, 9]), 5)
        XCTAssertEqual(GlucoseForecastMLChronology.percentile80([7]), 7)
        XCTAssertNil(GlucoseForecastMLChronology.percentile80([]))
        XCTAssertNil(GlucoseForecastMLChronology.percentile80([-1, 2]))
        XCTAssertNil(GlucoseForecastMLChronology.percentile80([1, .infinity]))
    }

    func testMedianUsesMiddleValueOrAverageAndRejectsNonfiniteSamples() {
        XCTAssertEqual(GlucoseForecastMLChronology.median([9, 1, 5]), 5)
        XCTAssertEqual(GlucoseForecastMLChronology.median([10, 2, 8, 4]), 6)
        XCTAssertEqual(GlucoseForecastMLChronology.median([3, 3, 3, 3]), 3)
        XCTAssertNil(GlucoseForecastMLChronology.median([]))
        XCTAssertNil(GlucoseForecastMLChronology.median([1, .nan]))
    }

    func testContextMatchesOnlyExactSourceAndTherapySettings() throws {
        let settings = TherapyModelSettings()
        let trained = try XCTUnwrap(GlucoseForecastMLContext(
            sensitivityMgdlPerUnit: 40, carbohydrateRatioGramsPerUnit: 10,
            settings: settings, sourceSignature: "sensor-a|source-a"))
        let liveInput = GlucoseForecastInput(glucose: [], treatments: [], settings: settings,
            sensitivityMgdlPerUnit: 40, carbohydrateRatioGramsPerUnit: 10, horizonMinutes: 120)
        XCTAssertEqual(GlucoseForecastMLContext(input: liveInput,
            sourceSignature: "sensor-a|source-a"), trained)
        XCTAssertEqual(trained.engineVersion, GlucoseForecastEngine.engineVersion)
        XCTAssertEqual(trained.featureVersion, GlucoseForecastMLFeatures.featureVersion)
        XCTAssertNotEqual(GlucoseForecastMLContext(input: liveInput,
            sourceSignature: "sensor-a|source-b"), trained)
        XCTAssertNil(GlucoseForecastMLContext(input: liveInput, sourceSignature: ""))

        var changed = settings
        changed.insulinDuration = 570
        XCTAssertNotEqual(GlucoseForecastMLContext(sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, settings: changed,
            sourceSignature: "sensor-a|source-a"), trained)
        changed = settings
        changed.insulinPeak = 70
        XCTAssertNotEqual(GlucoseForecastMLContext(sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, settings: changed,
            sourceSignature: "sensor-a|source-a"), trained)
        changed = settings
        changed.carbDuration = 300
        XCTAssertNotEqual(GlucoseForecastMLContext(sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, settings: changed,
            sourceSignature: "sensor-a|source-a"), trained)
        XCTAssertNotEqual(GlucoseForecastMLContext(sensitivityMgdlPerUnit: 41,
            carbohydrateRatioGramsPerUnit: 10, settings: settings,
            sourceSignature: "sensor-a|source-a"), trained)
        XCTAssertNotEqual(GlucoseForecastMLContext(sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 11, settings: settings,
            sourceSignature: "sensor-a|source-a"), trained)
        changed = settings
        changed.carbDuration = 61
        XCTAssertNil(GlucoseForecastMLContext(sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, settings: changed,
            sourceSignature: "sensor-a|source-a"))
    }

    func testCurveInterpolatesCorrectionAndBandAtFiveMinutePoints() throws {
        let engine = Array(repeating: 150.0, count: 25)
        let knots = [
            GlucoseForecastMLChronology.Knot(minute: 0, correction: 0, halfWidth: 0),
            .init(minute: 30, correction: 12, halfWidth: 6),
            .init(minute: 60, correction: -6, halfWidth: 12),
            .init(minute: 120, correction: 18, halfWidth: 24)
        ]
        let overlay = try XCTUnwrap(GlucoseForecastMLChronology.assemble(
            engine: engine, knots: knots, horizonMinutes: 120))
        XCTAssertEqual(overlay.central.count, engine.count)
        XCTAssertEqual(overlay.halfWidth.count, engine.count)
        XCTAssertEqual([overlay.central[0], overlay.central[3], overlay.central[6],
                        overlay.central[9], overlay.central[12], overlay.central[18],
                        overlay.central[24]], [150, 156, 162, 153, 144, 156, 168])
        XCTAssertEqual([overlay.halfWidth[0], overlay.halfWidth[3], overlay.halfWidth[6],
                        overlay.halfWidth[9], overlay.halfWidth[12], overlay.halfWidth[18],
                        overlay.halfWidth[24]], [0, 3, 6, 9, 12, 18, 24])
    }

    func testUnsafePointRejectsWholeCurveForEngineFallback() {
        let knots = [
            GlucoseForecastMLChronology.Knot(minute: 0, correction: 0, halfWidth: 0),
            .init(minute: 30, correction: 0, halfWidth: 6),
            .init(minute: 60, correction: 12, halfWidth: 12)
        ]
        var engine = Array(repeating: 150.0, count: 13)
        engine[11] = 598 // +55 minutes: interpolated correction is +10, beyond 600.
        XCTAssertNil(GlucoseForecastMLChronology.assemble(
            engine: engine, knots: knots, horizonMinutes: 60))
        engine[11] = .nan
        XCTAssertNil(GlucoseForecastMLChronology.assemble(
            engine: engine, knots: knots, horizonMinutes: 60))
        engine[11] = 150
        XCTAssertNil(GlucoseForecastMLChronology.assemble(engine: engine,
            knots: [knots[0], .init(minute: 30, correction: 28, halfWidth: 6), knots[2]],
            horizonMinutes: 60))
        XCTAssertNil(GlucoseForecastMLChronology.assemble(engine: engine,
            knots: [knots[0], .init(minute: 30, correction: 0, halfWidth: -1), knots[2]],
            horizonMinutes: 60))
        XCTAssertNil(GlucoseForecastMLChronology.assemble(
            engine: Array(engine.dropLast()), knots: knots, horizonMinutes: 60))
    }

    func testSplitEmbargoesTheTwoMinuteJoinAtBothPeriodBoundaries() throws {
        var calendar = utc
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let base = examples()
        let baseline = try GlucoseForecastMLChronology.split(base, calendar: calendar,
                                                              now: chronologyNow(base))
        let acceptedA = baseline.bStart.addingTimeInterval(-122 * 60 - 1)
        let embargoedA = baseline.bStart.addingTimeInterval(-122 * 60)
        let acceptedB = baseline.cStart.addingTimeInterval(-122 * 60 - 1)
        let embargoedB = baseline.cStart.addingTimeInterval(-122 * 60)
        let additional = [acceptedA, embargoedA, acceptedB, embargoedB]
            .flatMap { completeAnchor(at: $0) }
        let split = try GlucoseForecastMLChronology.split(base + additional,
            calendar: calendar, now: chronologyNow(base))
        for horizon in [30, 60, 120] {
            XCTAssertEqual(split.a[horizon]?.count, baseline.a[horizon]!.count + 1)
            XCTAssertEqual(split.b[horizon]?.count, baseline.b[horizon]!.count + 1)
            XCTAssertEqual(split.c[horizon]?.count, baseline.c[horizon]!.count)
            XCTAssertTrue(split.a[horizon]!.contains { $0.row.referenceDate == acceptedA })
            XCTAssertTrue(split.b[horizon]!.contains { $0.row.referenceDate == acceptedB })
            XCTAssertFalse(split.a[horizon]!.contains { $0.row.referenceDate == embargoedA })
            XCTAssertFalse(split.b[horizon]!.contains { $0.row.referenceDate == embargoedB })
            XCTAssertFalse(split.c[horizon]!.contains { $0.row.referenceDate == embargoedB })
        }
    }
}
