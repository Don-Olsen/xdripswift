import CoreData
import HealthKit
import XCTest
@testable import xdrip

/// The query adapter is replaced with synthetic pages. These tests never read or write the
/// device's Health database, and every imported treatment uses an isolated Core Data store.
final class HealthKitTherapyImportTests: XCTestCase {
    private let sourceA = HealthTherapyImportSource(bundleIdentifier: "org.example.therapy.a", name: "Pump A")
    private let sourceB = HealthTherapyImportSource(bundleIdentifier: "org.example.therapy.b", name: "Pump B")

    func testConsistentLocalCutoverHidesOnlyOngoingImportsAndEnglishFooter() throws {
        let suite = "HealthCutoverPresentation-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.isMaster = true
        defaults.therapyDataSourceType = .none
        let cutoff = Date(timeIntervalSince1970: 1_800_000_000)
        let boundary = TreatmentSourceCutover(cutoff: cutoff,
            insulinSourceBundleID: sourceA.bundleIdentifier,
            carbohydrateSourceBundleID: sourceB.bundleIdentifier)
        XCTAssertTrue(TreatmentSourceCutover.persist(boundary, defaults: defaults))
        let model = SettingsViewHealthKitSettingsViewModel(defaults: defaults)
        XCTAssertEqual(model.settingsRows(sectionID: 1).map(\.id), [
            "healthKit.enabledHealthKit", "healthKit.requestWriteAccess",
            "healthKit.exportStatus", "healthKit.localTreatmentCutover"
        ])
        XCTAssertNil(model.sectionFooter())
        XCTAssertTrue(HealthKitLocalCutoverPresentation.isActive(
            policy: defaults.dataFlowPolicy, cutover: boundary, defaults: defaults))
        XCTAssertEqual(HealthKitLocalCutoverPresentation.priorSourceName(sourceA,
            expectedBundleID: boundary.insulinSourceBundleID), "Pump A")
        XCTAssertEqual(HealthKitLocalCutoverPresentation.priorSourceName(sourceA,
            expectedBundleID: boundary.carbohydrateSourceBundleID), sourceB.bundleIdentifier)
        XCTAssertFalse(HealthKitLocalCutoverPresentation.cutoffDescription(cutoff).isEmpty)

        defaults.set(true, forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey)
        XCTAssertEqual(model.settingsRows(sectionID: 1).count, 10)
        XCTAssertNotNil(model.sectionFooter())
        defaults.removeObject(forKey: TreatmentSourceCutover.restoreRequiresSourceSetupKey)
        defaults.therapyDataSourceType = .nightscout
        defaults.nightscoutEnabled = true
        XCTAssertEqual(model.settingsRows(sectionID: 1).count, 10)
        XCTAssertNotNil(model.sectionFooter())
    }

    func testDamagedLocalCutoverLeavesHealthImportControlsVisible() throws {
        let suite = "InvalidHealthCutoverPresentation-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.isMaster = true
        defaults.therapyDataSourceType = .none
        defaults.set(Data("corrupted".utf8), forKey: TreatmentSourceCutover.defaultsKey)
        let model = SettingsViewHealthKitSettingsViewModel(defaults: defaults)
        XCTAssertEqual(model.settingsRows(sectionID: 1).count, 10)
        XCTAssertNotNil(model.sectionFooter())
    }

    private func anchor(_ text: String) -> Data { Data(text.utf8) }

    private func sample(_ kind: HealthTherapyImportKind, source: HealthTherapyImportSource,
                        uuid: UUID = UUID(), quantity: Double = 2,
                        date: Date = Date().addingTimeInterval(-300), endDate: Date? = nil,
                        reason: Int? = HKInsulinDeliveryReason.bolus.rawValue,
                        undetermined: Bool = false, count: Int = 1,
                        externalUUID: String? = nil, syncIdentifier: String? = nil) -> HealthTherapyIncomingSample {
        HealthTherapyIncomingSample(uuid: uuid, kind: kind, source: source,
            startDate: date, endDate: endDate ?? date, quantity: quantity,
            insulinReason: reason, hasUndeterminedDuration: undetermined,
            sampleCount: count, externalUUID: externalUUID, syncIdentifier: syncIdentifier)
    }

    private func page(_ samples: [HealthTherapyIncomingSample] = [],
                      deleted: [UUID] = [], next: String, more: Bool = false) -> HealthTherapyImportPage {
        HealthTherapyImportPage(samples: samples, deletedUUIDs: deleted,
                                nextAnchor: anchor(next), hasMore: more)
    }

    private func policy(_ therapy: TherapyDataSourceType = .nightscout) -> DataFlowPolicy {
        DataFlowPolicy(isMaster: true, followerDataSource: .careLink,
            therapyDataSourceSelection: therapy, nightscoutEnabled: therapy == .nightscout,
            masterUploadsGlucoseToNightscout: false, followerUploadsGlucoseToNightscout: false,
            nightscoutFollowType: .none)
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: @escaping () -> Bool) {
        let fulfilled = expectation(description: description)
        func poll() {
            if condition() { fulfilled.fulfill() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll) }
        }
        poll()
        wait(for: [fulfilled], timeout: timeout)
        XCTAssertTrue(condition(), description, file: file, line: line)
    }

    private func enable(_ kind: HealthTherapyImportKind, source: HealthTherapyImportSource,
                        fixture: ImportFixture) {
        // Set the same persisted choice that selectSource writes before enabling the type.
        // The switch test below exercises selectSource itself. This ordering gives each test
        // exactly one initial query and makes the deliberate failed-save case deterministic.
        fixture.defaults.set(source.bundleIdentifier,
                             forKey: "healthTherapyImport.v1.\(kind.rawValue).sourceBundleID")
        fixture.defaults.set(source.name,
                             forKey: "healthTherapyImport.v1.\(kind.rawValue).sourceName")
        let authorized = expectation(description: "read request returned")
        fixture.manager.setEnabled(true, kind: kind) { error in
            XCTAssertNil(error)
            authorized.fulfill()
        }
        wait(for: [authorized], timeout: 3)
        fixture.configureOnce()
    }

    private func treatments(in core: CoreDataManager) -> [TreatmentEntry] {
        var entries: [TreatmentEntry] = []
        core.mainManagedObjectContext.performAndWait {
            entries = (try? core.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest())) ?? []
        }
        return entries
    }

    private func ledger(in core: CoreDataManager) -> [HealthKitTherapySample] {
        var records: [HealthKitTherapySample] = []
        core.mainManagedObjectContext.performAndWait {
            records = (try? core.mainManagedObjectContext.fetch(HealthKitTherapySample.fetchRequest())) ?? []
        }
        return records
    }

    func testRoutineRefreshRequiresPreviouslyCompleteSameSourceAndClearsOnUnsafeState() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        fixture.query.setPage(page([sample(.insulin, source: sourceA)], next: "ready"), for: .insulin, after: nil)
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("first complete selected source") { !fixture.manager.status(.insulin).isIncomplete }
        XCTAssertNil(fixture.manager.routineRefreshState())
        fixture.query.holdPage(for: .insulin, after: anchor("ready"))
        fixture.query.emit(.insulin)
        waitUntil("subsequent read held") { fixture.query.anchors(for: .insulin).count >= 2 }
        XCTAssertNotNil(fixture.manager.routineRefreshState())
        XCTAssertTrue(fixture.manager.localInputIsIncomplete(.insulin))
        let prefix = "healthTherapyImport.v1.insulin."
        for (suffix, badValue) in [("error", "read failed" as Any), ("hasAmbiguousSelectedSource", true),
                                   ("observedSelectedSource", false), ("sourceBundleID", sourceB.bundleIdentifier),
                                   ("lastSync", Date().addingTimeInterval(-90000))] {
            let original = fixture.defaults.object(forKey: prefix + suffix)
            fixture.defaults.set(badValue, forKey: prefix + suffix)
            XCTAssertNil(fixture.manager.routineRefreshState(), suffix)
            if let original { fixture.defaults.set(original, forKey: prefix + suffix) }
            else { fixture.defaults.removeObject(forKey: prefix + suffix) }
        }
        XCTAssertNotNil(fixture.manager.routineRefreshState())
        fixture.query.releaseHeldPage(for: .insulin, after: anchor("ready"))
        waitUntil("refresh completed") {
            !fixture.manager.status(.insulin).isIncomplete
                && fixture.manager.routineRefreshState()?.allEnabledKindsCommitted == true
        }
        XCTAssertEqual(fixture.manager.routineRefreshState()?.allEnabledKindsCommitted, true)
    }

    func testRoutineRefreshWaitsForBothKindsAndEveryPageWithoutExtendingItsDeadline() throws {
        let fixture = ImportFixture()
        defer { fixture.close() }
        fixture.query.setPage(page([sample(.insulin, source: sourceA)], next: "i0"),
                              for: .insulin, after: nil)
        fixture.query.setPage(page([sample(.carbohydrates, source: sourceA)], next: "c0"),
                              for: .carbohydrates, after: nil)
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("insulin initial import complete before enabling carbohydrates") {
            fixture.anchor(for: .insulin) == self.anchor("i0") &&
                !fixture.manager.status(.insulin).isIncomplete
        }
        enable(.carbohydrates, source: sourceA, fixture: fixture)
        waitUntil("both initial imports complete") {
            !fixture.manager.status(.insulin).isIncomplete && !fixture.manager.status(.carbohydrates).isIncomplete
        }
        XCTAssertNotNil(fixture.manager.historyStart(.insulin))
        XCTAssertNotNil(fixture.manager.historyStart(.carbohydrates))
        fixture.query.setPage(page([sample(.insulin, source: sourceA)], next: "i1", more: true),
                              for: .insulin, after: anchor("i0"))
        fixture.query.setPage(page([sample(.insulin, source: sourceA)], next: "i2"),
                              for: .insulin, after: anchor("i1"))
        fixture.query.setPage(page([sample(.carbohydrates, source: sourceA)], next: "c1"),
                              for: .carbohydrates, after: anchor("c0"))
        fixture.query.holdPage(for: .insulin, after: anchor("i1"))
        fixture.query.holdPage(for: .carbohydrates, after: anchor("c0"))
        fixture.query.emit(.insulin)
        waitUntil("insulin first page saved and both reads held") {
            fixture.anchor(for: .insulin) == self.anchor("i1") &&
            fixture.query.anchors(for: .insulin).contains(where: { $0 == self.anchor("i1") }) &&
            fixture.query.anchors(for: .carbohydrates).contains(where: { $0 == self.anchor("c0") })
        }
        let first = try XCTUnwrap(fixture.manager.routineRefreshState())
        XCTAssertFalse(first.allEnabledKindsCommitted)
        XCTAssertTrue(fixture.manager.localInputIsIncomplete(.insulin))
        XCTAssertTrue(fixture.manager.localInputIsIncomplete(.carbohydrates))
        fixture.query.emit(.insulin)
        XCTAssertEqual(fixture.manager.routineRefreshState()?.generation, first.generation)
        XCTAssertNil(fixture.manager.routineRefreshState(at: first.startedAt.addingTimeInterval(30)),
                     "a delayed callback cannot extend the first 30-second Home window")
        fixture.query.releaseHeldPage(for: .insulin, after: anchor("i1"))
        waitUntil("insulin final page saved while carbohydrate callback remains held") {
            fixture.anchor(for: .insulin) == self.anchor("i2")
        }
        XCTAssertFalse(try XCTUnwrap(fixture.manager.routineRefreshState()).allEnabledKindsCommitted)
        fixture.query.releaseHeldPage(for: .carbohydrates, after: anchor("c0"))
        waitUntil("both imports complete") {
            fixture.anchor(for: .carbohydrates) == self.anchor("c1") &&
            fixture.manager.routineRefreshState()?.allEnabledKindsCommitted == true
        }
        XCTAssertFalse(fixture.manager.localInputIsIncomplete(.insulin))
        XCTAssertFalse(fixture.manager.localInputIsIncomplete(.carbohydrates))
    }

    func testRoutineRefreshFailureOrSourceChangeRevokesPresentationProof() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        fixture.query.setPage(page([sample(.insulin, source: sourceA)], next: "ready"),
                              for: .insulin, after: nil)
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("complete initial import") { !fixture.manager.status(.insulin).isIncomplete }
        fixture.query.holdPage(for: .insulin, after: anchor("ready"))
        fixture.query.emit(.insulin)
        waitUntil("held routine refresh") { fixture.query.anchors(for: .insulin).count >= 2 }
        XCTAssertNotNil(fixture.manager.routineRefreshState())
        fixture.manager.selectSource(sourceB, kind: .insulin)
        XCTAssertNil(fixture.manager.routineRefreshState())
        fixture.query.releaseHeldPage(for: .insulin, after: anchor("ready"))

        let failed = ImportFixture()
        defer { failed.close() }
        failed.query.setPage(page([sample(.insulin, source: sourceA)], next: "ready"),
                             for: .insulin, after: nil)
        enable(.insulin, source: sourceA, fixture: failed)
        waitUntil("complete prior import") { !failed.manager.status(.insulin).isIncomplete }
        failed.manager.saveImportedPage = { _, completion in completion(false) }
        failed.query.emit(.insulin)
        waitUntil("failed parent save") { failed.manager.status(.insulin).message.contains("storage failed") }
        XCTAssertNil(failed.manager.routineRefreshState())
        XCTAssertTrue(failed.manager.localInputIsIncomplete(.insulin))
    }

    func testHeldNoOpHealthRefreshProducesOnlyExplicitAdapterHintAndRejectsStaleOrPendingInputs() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        fixture.defaults.isMaster = true
        fixture.defaults.therapyDataSourceType = .none
        fixture.defaults.nightscoutEnabled = false
        fixture.defaults.glucoseForecastManualSensitivityMgdlPerUnit = 36
        fixture.defaults.glucoseForecastManualCarbRatioGramsPerUnit = 10
        fixture.query.setPage(page([sample(.insulin, source: sourceA)], next: "ready"), for: .insulin, after: nil)
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("completed initial import") { !fixture.manager.status(.insulin).isIncomplete }
        let now = Date()
        let sensor = Sensor(startDate: now.addingTimeInterval(-3600), nsManagedObjectContext: fixture.core.mainManagedObjectContext)
        let reading = BgReading(timeStamp: now, sensor: sensor, calibration: nil, rawData: 165,
                                deviceName: "Synthetic", nsManagedObjectContext: fixture.core.mainManagedObjectContext)
        reading.calculatedValue = 165
        XCTAssertTrue(fixture.core.saveChangesSynchronously())
        let therapy = TherapyMetricsManager()
        therapy.configure(coreDataManager: fixture.core, externalStatus: { nil })
        let priorRevision = therapy.forecastInputChangeRevision
        let sharedActualRevision = TherapyMetricsManager.shared.forecastInputChangeRevision
        let sharedBroadRevision = TherapyMetricsManager.shared.treatmentChangeRevision
        fixture.query.holdPage(for: .insulin, after: anchor("ready"))
        fixture.query.emit(.insulin)
        waitUntil("no-op import reached held query") { fixture.query.anchors(for: .insulin).count >= 2 }
        XCTAssertEqual(therapy.forecastInputChangeRevision, priorRevision,
                       "Materializing an unchanged source must not look like a treatment mutation")
        XCTAssertEqual(TherapyMetricsManager.shared.forecastInputChangeRevision, sharedActualRevision)
        XCTAssertEqual(TherapyMetricsManager.shared.treatmentChangeRevision, sharedBroadRevision,
                       "An unchanged reread must not rebuild confirmed treatment inputs")
        let adapter = GlucoseForecastDataAdapter(coreDataManager: fixture.core, therapyManager: therapy,
            defaults: fixture.defaults, healthImporter: fixture.manager, logForecast: { _ in })
        let checked = expectation(description: "refresh outcomes checked")
        Task { @MainActor in
            let refreshing = await adapter.forecastForPresentation(horizonMinutes: 60, at: now)
            XCTAssertEqual(refreshing.result.reason, .dataUnavailable)
            XCTAssertTrue(refreshing.result.points.isEmpty)
            let context = RootHomeForecastContext(therapyRevision: priorRevision, horizonMinutes: 60,
                manualSensitivityMgdlPerUnit: 36, manualCarbRatioGramsPerUnit: 10, insulinPeak: 75,
                carbDuration: 240, therapySource: 0, healthTherapySelectionSignature: "selected-source",
                localTherapySourceSignature: "local", adjustmentEnabled: false, smoothingEnabled: false,
                presentationInputSignature: GlucoseForecastDataAdapter.presentationInputSignature(
                    horizonMinutes: 60, defaults: fixture.defaults, importer: fixture.manager))
            let prior = GlucoseForecastResult(points: [.init(date: now, glucoseMgdl: 165),
                .init(date: now.addingTimeInterval(3600), glucoseMgdl: 168)], referenceDate: now,
                reason: nil, parameterSource: .manual, referenceSensorID: sensor.id)
            var presentation = RootHomeForecastPresentationState()
            presentation.accept(.init(result: prior), context: context, requestedAt: now)
            var chart = GlucoseChartState.empty(startDate: now.addingTimeInterval(-10800), endDate: now)
            chart.bgReadingDates = [now]
            chart.bgReadingValues = [165]
            chart.newestBgReadingDate = now
            chart.newestBgReadingSensorID = sensor.id
            chart.newestBgReadingIsValidForDownstream = true
            XCTAssertEqual(presentation.displayableResult(context: context, chartState: chart,
                currentInputsAvailable: false, routineRefresh: fixture.manager.routineRefreshState(),
                at: now.addingTimeInterval(0.5))?.points, prior.points)
            let stale = await adapter.forecastForPresentation(horizonMinutes: 60,
                at: now.addingTimeInterval(GlucoseForecastEngine.maximumGlucoseAge + 1))
            XCTAssertNotNil(stale.result.reason)
            let disabled = await adapter.forecastForPresentation(horizonMinutes: 0, at: now)
            XCTAssertNotNil(disabled.result.reason)
            fixture.defaults.set("read failed", forKey: "healthTherapyImport.v1.insulin.error")
            let failed = await adapter.forecastForPresentation(horizonMinutes: 60, at: now)
            XCTAssertEqual(failed.result.reason, .dataUnavailable)
            fixture.defaults.removeObject(forKey: "healthTherapyImport.v1.insulin.error")
            _ = TreatmentEntry(date: now, value: 1, treatmentType: .Insulin, nightscoutEventType: nil,
                               enteredBy: nil, nsManagedObjectContext: fixture.core.mainManagedObjectContext)
            do { try fixture.core.mainManagedObjectContext.save() }
            catch { XCTFail("Synthetic child save failed: \(error)") }
            let pending = await adapter.forecastForPresentation(horizonMinutes: 60, at: now)
            XCTAssertEqual(pending.result.reason, .dataUnavailable)
            XCTAssertTrue(fixture.core.saveChangesSynchronously())
            checked.fulfill()
        }
        wait(for: [checked], timeout: 5)
        fixture.query.releaseHeldPage(for: .insulin, after: anchor("ready"))
        waitUntil("refresh ended") { !fixture.manager.status(.insulin).isIncomplete }
    }

    func testRoutineRefreshNeverTreatsFailedRetryOrFirstImportAsComplete() {
        for previousFailure in [false, true] {
            let fixture = ImportFixture()
            defer { fixture.close() }
            let prefix = "healthTherapyImport.v1.insulin."
            fixture.defaults.set(true, forKey: prefix + "enabled")
            fixture.defaults.set(sourceA.bundleIdentifier, forKey: prefix + "sourceBundleID")
            fixture.defaults.set(Date(), forKey: prefix + "lastSync")
            fixture.defaults.set(previousFailure, forKey: prefix + "observedSelectedSource")
            if previousFailure { fixture.defaults.set("earlier read failed", forKey: prefix + "error") }
            fixture.query.holdPage(for: .insulin, after: nil)
            fixture.configureOnce()
            waitUntil("incomplete read held") { !fixture.query.anchors(for: .insulin).isEmpty }
            // startSync clears the old error, but the captured proof must still reject its retry.
            XCTAssertNil(fixture.defaults.string(forKey: prefix + "error"))
            XCTAssertNil(fixture.manager.routineRefreshState())
            fixture.query.releaseHeldPage(for: .insulin, after: nil)
            waitUntil("incomplete read finished") { fixture.anchor(for: .insulin) != nil }
        }
    }

    func testClassificationAcceptsOnlyPointBolusAndIndividualCarbEntries() {
        let at = Date().addingTimeInterval(-120)
        XCTAssertEqual(sample(.insulin, source: sourceA, date: at).classification, "bolus")
        XCTAssertTrue(sample(.insulin, source: sourceA, date: at).contributesToTherapy)
        let basal = sample(.insulin, source: sourceA, date: at,
                           reason: HKInsulinDeliveryReason.basal.rawValue)
        XCTAssertEqual(basal.classification, "basal")
        XCTAssertFalse(basal.contributesToTherapy)
        let unknown = sample(.insulin, source: sourceA, date: at, reason: nil)
        XCTAssertEqual(unknown.classification, "unclassifiedInsulin")
        XCTAssertFalse(unknown.contributesToTherapy)
        let interval = sample(.insulin, source: sourceA, date: at,
                              endDate: at.addingTimeInterval(60))
        XCTAssertEqual(interval.classification, "ambiguousInterval")
        XCTAssertFalse(interval.contributesToTherapy)
        XCTAssertFalse(sample(.insulin, source: sourceA, date: at,
                              undetermined: true).contributesToTherapy)
        XCTAssertFalse(sample(.carbohydrates, source: sourceA, date: at,
                              count: 2).contributesToTherapy)
        XCTAssertEqual(sample(.carbohydrates, source: sourceA, quantity: 34,
                              date: at).classification, "carbohydrates")
        for value in [0, -2, Double.nan, Double.infinity] {
            XCTAssertEqual(sample(.carbohydrates, source: sourceA, quantity: value,
                                  date: at).classification, "invalid")
        }
    }

    func testOptInIsOffByDefaultAndEmptyReadDoesNotProveCompleteness() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let manager = fixture.manager
        XCTAssertFalse(manager.isEnabled(.insulin))
        XCTAssertFalse(manager.isEnabled(.carbohydrates))
        XCTAssertEqual(manager.status(.insulin).message, "Import off")
        fixture.query.setPage(page(next: "empty"), for: .insulin, after: nil)
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("first empty Health page completed") {
            fixture.anchor(for: .insulin) == self.anchor("empty")
        }
        XCTAssertTrue(manager.status(.insulin).isIncomplete)
        XCTAssertNotNil(manager.status(.insulin).lastSync)
        XCTAssertTrue(treatments(in: fixture.core).isEmpty)
        XCTAssertNil(fixture.anchor(for: .carbohydrates))
    }

    func testUnavailableAuthorizationLeavesImportOffAndAnchorUnchanged() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        fixture.query.setAuthorizationError(ReadFailure.locked, for: .insulin)
        let returned = expectation(description: "unavailable Health database")
        fixture.manager.setEnabled(true, kind: .insulin) { error in
            XCTAssertNotNil(error)
            returned.fulfill()
        }
        wait(for: [returned], timeout: 3)
        XCTAssertFalse(fixture.manager.isEnabled(.insulin))
        XCTAssertNil(fixture.anchor(for: .insulin))
        XCTAssertTrue(treatments(in: fixture.core).isEmpty)
    }

    func testEnabledImportWaitsForAnExplicitSourceChoice() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let returned = expectation(description: "read dialog returned")
        fixture.manager.setEnabled(true, kind: .insulin) { error in
            XCTAssertNil(error)
            returned.fulfill()
        }
        wait(for: [returned], timeout: 3)
        XCTAssertTrue(fixture.manager.isEnabled(.insulin))
        XCTAssertNil(fixture.manager.selectedSource(.insulin))
        XCTAssertTrue(fixture.manager.localInputIsIncomplete(.insulin))
        XCTAssertNil(fixture.anchor(for: .insulin))
        XCTAssertTrue(fixture.query.anchors(for: .insulin).isEmpty)
    }

    func testInsulinAndCarbsKeepOriginalTimeAndUnitsWithoutBasalOrUnknownIOB() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let recorded = Date().addingTimeInterval(-7200)
        let bolus = sample(.insulin, source: sourceA, quantity: 2.5, date: recorded)
        let basal = sample(.insulin, source: sourceA, quantity: 0.7, date: recorded,
                           reason: HKInsulinDeliveryReason.basal.rawValue)
        let unknown = sample(.insulin, source: sourceA, quantity: 4, date: recorded, reason: nil)
        let carbs = sample(.carbohydrates, source: sourceA, quantity: 42, date: recorded)
        fixture.query.setPage(page([bolus, basal, unknown], next: "i1"), for: .insulin, after: nil)
        fixture.query.setPage(page([carbs], next: "c1"), for: .carbohydrates, after: nil)

        enable(.insulin, source: sourceA, fixture: fixture)
        enable(.carbohydrates, source: sourceA, fixture: fixture)
        waitUntil("both quantities saved before anchors") {
            fixture.anchor(for: .insulin) == self.anchor("i1") &&
            fixture.anchor(for: .carbohydrates) == self.anchor("c1")
        }
        let rows = treatments(in: fixture.core)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.treatmentType == .Insulin })?.value, 2.5)
        XCTAssertEqual(rows.first(where: { $0.treatmentType == .Carbs })?.value, 42)
        XCTAssertTrue(rows.allSatisfy { $0.date == recorded })
        XCTAssertEqual(Set(rows.compactMap(\.healthKitSampleUUID)),
                       Set([bolus.uuid.uuidString, carbs.uuid.uuidString]))
        let records = ledger(in: fixture.core)
        XCTAssertEqual(records.count, 4)
        XCTAssertEqual(Set(records.map(\.classification)),
                       Set(["bolus", "basal", "unclassifiedInsulin", "carbohydrates"]))
    }

    func testRepeatedCallbackAndRestartedAnchorCannotDuplicateAHealthSample() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let first = sample(.insulin, source: sourceA)
        fixture.query.setPage(page([first], next: "a1"), for: .insulin, after: nil)
        fixture.query.setPage(page([first], next: "a2"), for: .insulin, after: anchor("a1"))
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("first sample saved") { fixture.anchor(for: .insulin) == self.anchor("a1") }
        fixture.query.emit(.insulin)
        waitUntil("replayed sample checkpointed") { fixture.anchor(for: .insulin) == self.anchor("a2") }
        XCTAssertEqual(ledger(in: fixture.core).count, 1)
        XCTAssertEqual(treatments(in: fixture.core).count, 1)
        XCTAssertEqual(Array(fixture.query.anchors(for: .insulin).prefix(2)), [nil, anchor("a1")])
    }

    func testDocumentedDeletionOnlyMarksMatchingHealthImportAndReplacementIsNew() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let first = sample(.carbohydrates, source: sourceA, quantity: 20)
        let replacement = sample(.carbohydrates, source: sourceA, quantity: 22)
        fixture.query.setPage(page([first], next: "a1"), for: .carbohydrates, after: nil)
        enable(.carbohydrates, source: sourceA, fixture: fixture)
        waitUntil("first meal saved") { fixture.anchor(for: .carbohydrates) == self.anchor("a1") }
        let manual = TreatmentEntry(date: first.startDate, value: 20, treatmentType: .Carbs,
                                    nightscoutEventType: nil, enteredBy: "Test",
                                    nsManagedObjectContext: fixture.core.mainManagedObjectContext)
        XCTAssertTrue(fixture.core.saveChangesSynchronously())
        // Make the deletion available only after the first checkpoint. An unrelated extra
        // startup callback must not race this two-stage test past its first assertion.
        fixture.query.setPage(page([replacement], deleted: [first.uuid], next: "a2"),
                              for: .carbohydrates, after: anchor("a1"))
        fixture.query.emit(.carbohydrates)
        waitUntil("deletion and replacement checkpointed") {
            fixture.anchor(for: .carbohydrates) == self.anchor("a2")
        }
        let rows = treatments(in: fixture.core)
        XCTAssertEqual(rows.count, 3)
        XCTAssertFalse(manual.treatmentdeleted)
        XCTAssertEqual(rows.first(where: { $0.healthKitSampleUUID == first.uuid.uuidString })?.treatmentdeleted, true)
        XCTAssertEqual(rows.first(where: { $0.healthKitSampleUUID == replacement.uuid.uuidString })?.treatmentdeleted, false)
        XCTAssertEqual(ledger(in: fixture.core).first(where: { $0.uuid == first.uuid.uuidString })?.wasDeletedInHealthKit, true)
    }

    func testSourceChoiceIsBasedOnRealSourceIdentityAndSwitchKeepsProvenance() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let a = sample(.insulin, source: sourceA, quantity: 1.25)
        let b = sample(.insulin, source: sourceB, quantity: 2.75)
        fixture.query.setPage(page([a, b], next: "a1"), for: .insulin, after: nil)
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("both sources recorded") { fixture.anchor(for: .insulin) == self.anchor("a1") }
        XCTAssertEqual(ledger(in: fixture.core).count, 2)
        XCTAssertEqual(treatments(in: fixture.core).compactMap(\.healthKitSourceBundleIdentifier), [sourceA.bundleIdentifier])
        fixture.manager.selectSource(sourceB, kind: .insulin)
        waitUntil("new source materialized") { self.treatments(in: fixture.core).count == 2 }
        XCTAssertEqual(fixture.manager.selectedSource(.insulin)?.bundleIdentifier, sourceB.bundleIdentifier)
        XCTAssertEqual(Set(treatments(in: fixture.core).compactMap(\.healthKitSourceBundleIdentifier)),
                       Set([sourceA.bundleIdentifier, sourceB.bundleIdentifier]))
    }

    func testReadFailureDoesNotMoveAnchorAndCanRetryOnObserverCallback() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        fixture.query.setError(ReadFailure.locked, for: .insulin)
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("locked read reported") { fixture.manager.status(.insulin).message.contains("could not be read") }
        XCTAssertNil(fixture.anchor(for: .insulin))
        XCTAssertTrue(fixture.manager.localInputIsIncomplete(.insulin))
        let dose = sample(.insulin, source: sourceA)
        fixture.query.setError(nil, for: .insulin)
        fixture.query.setPage(page([dose], next: "after-lock"), for: .insulin, after: nil)
        fixture.query.emit(.insulin)
        waitUntil("locked read retried") { fixture.anchor(for: .insulin) == self.anchor("after-lock") }
        XCTAssertEqual(treatments(in: fixture.core).count, 1)
    }

    func testInitialBackfillDrainsPagesAndRetainsBackdatedTimestamps() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let backdated = Date().addingTimeInterval(-7 * 3600)
        let first = sample(.carbohydrates, source: sourceA, quantity: 30, date: backdated)
        let second = sample(.carbohydrates, source: sourceA, quantity: 12,
                            date: Date().addingTimeInterval(-1800))
        fixture.query.setPage(page([first], next: "p1", more: true), for: .carbohydrates, after: nil)
        fixture.query.setPage(page([second], next: "p2"), for: .carbohydrates, after: anchor("p1"))
        enable(.carbohydrates, source: sourceA, fixture: fixture)
        waitUntil("both backfill pages saved") {
            fixture.anchor(for: .carbohydrates) == self.anchor("p2")
        }
        let rows = treatments(in: fixture.core)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.first(where: { $0.healthKitSampleUUID == first.uuid.uuidString })?.date, backdated)
        XCTAssertEqual(rows.first(where: { $0.healthKitSampleUUID == second.uuid.uuidString })?.date, second.startDate)
        XCTAssertEqual(Array(fixture.query.anchors(for: .carbohydrates).prefix(2)), [nil, anchor("p1")])
    }

    func testSuccessfulFirstPageDoesNotClaimCompleteInputsBeforeFinalPage() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let first = sample(.insulin, source: sourceA, quantity: 1)
        let second = sample(.insulin, source: sourceA, quantity: 2)
        fixture.query.setPage(page([first], next: "first", more: true), for: .insulin, after: nil)
        fixture.query.setPage(page([second], next: "last"), for: .insulin, after: anchor("first"))
        fixture.query.holdPage(for: .insulin, after: anchor("first"))
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("first page durable and next page pending") {
            fixture.anchor(for: .insulin) == self.anchor("first") &&
            fixture.query.anchors(for: .insulin).contains(where: { $0 == self.anchor("first") })
        }
        XCTAssertTrue(fixture.manager.localInputIsIncomplete(.insulin))
        XCTAssertTrue(fixture.manager.status(.insulin).message.contains("every page"))
        XCTAssertNil(fixture.manager.status(.insulin).lastSync)
        let reopened = HealthKitTherapyImportManager(query: FakeQuery(), defaults: fixture.defaults)
        XCTAssertTrue(reopened.localInputIsIncomplete(.insulin),
                      "an interrupted multi-page import cannot look complete after restart")
        fixture.query.releaseHeldPage(for: .insulin, after: anchor("first"))
        waitUntil("final page durable") { fixture.anchor(for: .insulin) == self.anchor("last") }
        XCTAssertEqual(treatments(in: fixture.core).count, 2)
        XCTAssertFalse(fixture.manager.localInputIsIncomplete(.insulin))
        XCTAssertNotNil(fixture.manager.status(.insulin).lastSync)
    }

    func testRecentUnclassifiedInsulinKeepsIOBIncompleteUntilDeleted() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let uncertain = sample(.insulin, source: sourceA, quantity: 2, reason: nil)
        fixture.query.setPage(page([uncertain], next: "uncertain"), for: .insulin, after: nil)
        fixture.query.setPage(page(deleted: [uncertain.uuid], next: "deleted"),
                              for: .insulin, after: anchor("uncertain"))
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("unclassified Health entry persisted") {
            fixture.anchor(for: .insulin) == self.anchor("uncertain")
        }
        XCTAssertTrue(fixture.manager.localInputIsIncomplete(.insulin))
        XCTAssertTrue(fixture.manager.status(.insulin).message.contains("unclear dose"))
        XCTAssertTrue(treatments(in: fixture.core).isEmpty)
        let reopened = HealthKitTherapyImportManager(query: FakeQuery(), defaults: fixture.defaults)
        XCTAssertTrue(reopened.localInputIsIncomplete(.insulin))
        fixture.query.emit(.insulin)
        waitUntil("documented deletion persisted") {
            fixture.anchor(for: .insulin) == self.anchor("deleted")
        }
        XCTAssertFalse(fixture.defaults.bool(forKey: "healthTherapyImport.v1.insulin.hasAmbiguousSelectedSource"))
        XCTAssertFalse(fixture.manager.localInputIsIncomplete(.insulin))
    }

    func testOldAmbiguousCarbRecordDoesNotLeavePermanentIncompleteStatus() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let old = Date().addingTimeInterval(-TherapyModelSettings.visibilityInterval - 60)
        let uncertain = sample(.carbohydrates, source: sourceA, quantity: 30,
                               date: old, endDate: old.addingTimeInterval(20))
        fixture.query.setPage(page([uncertain], next: "old"), for: .carbohydrates, after: nil)
        enable(.carbohydrates, source: sourceA, fixture: fixture)
        waitUntil("old ambiguous entry persisted") {
            fixture.anchor(for: .carbohydrates) == self.anchor("old")
        }
        XCTAssertFalse(fixture.defaults.bool(forKey: "healthTherapyImport.v1.carbohydrates.hasAmbiguousSelectedSource"))
        XCTAssertFalse(fixture.manager.localInputIsIncomplete(.carbohydrates))
    }

    func testFailedParentSaveLeavesAnchorBehindAndRetryDoesNotDuplicate() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let dose = sample(.insulin, source: sourceA)
        fixture.query.setPage(page([dose], next: "durable"), for: .insulin, after: nil)
        let saveLock = NSLock()
        var saveCalls = 0
        fixture.manager.saveImportedPage = { core, completion in
            saveLock.lock()
            saveCalls += 1
            let failIncomingPage = saveCalls == 2 // first save is selected-source materialization
            saveLock.unlock()
            if failIncomingPage {
                completion(false)
            } else {
                core.saveChanges(completion: completion)
            }
        }
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("failed save reported") {
            fixture.manager.status(.insulin).message.contains("Local storage failed")
        }
        XCTAssertNil(fixture.anchor(for: .insulin))
        fixture.query.emit(.insulin)
        waitUntil("retry committed") { fixture.anchor(for: .insulin) == self.anchor("durable") }
        XCTAssertEqual(ledger(in: fixture.core).count, 1)
        XCTAssertEqual(treatments(in: fixture.core).count, 1)
    }

    func testRestartReopensStoredTreatmentAndResumesFromDurableAnchor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthKitTherapyRestart.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("therapy.sqlite")
        let suite = "HealthKitTherapyRestart.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dose = sample(.insulin, source: sourceA)
        let firstQuery = FakeQuery()
        firstQuery.setPage(page([dose], next: "saved"), for: .insulin, after: nil)
        let firstCore = try CoreDataManager(testModelName: ConstantsCoreData.modelName,
                                            persistentStoreURL: storeURL)
        var firstManager: HealthKitTherapyImportManager? = HealthKitTherapyImportManager(
            query: firstQuery, defaults: defaults)
        firstManager?.configure(coreDataManager: firstCore)
        defaults.set(sourceA.bundleIdentifier,
                     forKey: "healthTherapyImport.v1.insulin.sourceBundleID")
        defaults.set(sourceA.name, forKey: "healthTherapyImport.v1.insulin.sourceName")
        let authorized = expectation(description: "read request returned")
        firstManager?.setEnabled(true, kind: .insulin) { error in
            XCTAssertNil(error)
            authorized.fulfill()
        }
        wait(for: [authorized], timeout: 3)
        waitUntil("initial SQLite import saved") {
            defaults.data(forKey: "healthTherapyImport.v1.insulin.anchor") == self.anchor("saved")
        }
        XCTAssertEqual(treatments(in: firstCore).count, 1)
        let stopped = expectation(description: "first import disabled before restart")
        firstManager?.setEnabled(false, kind: .insulin) { error in
            XCTAssertNil(error)
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 3)
        weak var oldManager = firstManager
        firstManager = nil
        waitUntil("first import manager released") { oldManager == nil }
        guard oldManager == nil else { return }
        try firstCore.disconnectPersistentStoresForTesting()

        // A new process reads the persisted enabled choice with no old manager alive.
        defaults.set(true, forKey: "healthTherapyImport.v1.insulin.enabled")

        let secondQuery = FakeQuery()
        // Replayed UUID after a process restart must not create a second dose.
        secondQuery.setPage(page([dose], next: "resumed"), for: .insulin,
                            after: anchor("saved"))
        let secondCore = try CoreDataManager(testModelName: ConstantsCoreData.modelName,
                                             persistentStoreURL: storeURL)
        var secondManager: HealthKitTherapyImportManager? = HealthKitTherapyImportManager(
            query: secondQuery, defaults: defaults)
        secondManager?.configure(coreDataManager: secondCore)
        waitUntil("restart query resumed") {
            defaults.data(forKey: "healthTherapyImport.v1.insulin.anchor") == self.anchor("resumed")
        }
        XCTAssertEqual(Array(secondQuery.anchors(for: .insulin).prefix(1)), [anchor("saved")])
        XCTAssertEqual(ledger(in: secondCore).count, 1)
        XCTAssertEqual(treatments(in: secondCore).count, 1)
        let restartedStopped = expectation(description: "restarted import disabled before store removal")
        secondManager?.setEnabled(false, kind: .insulin) { error in
            XCTAssertNil(error)
            restartedStopped.fulfill()
        }
        wait(for: [restartedStopped], timeout: 3)
        weak var restartedManager = secondManager
        secondManager = nil
        waitUntil("restarted import manager released") { restartedManager == nil }
        guard restartedManager == nil else { return }
        try secondCore.disconnectPersistentStoresForTesting()
    }

    func testSourceFilterAndExactOriginIDPrecedencePreserveRealRepeatAndManualEntries() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let date = Date().addingTimeInterval(-120)
        let external = TreatmentEntry(id: "shared-insulin", date: date, value: 2,
            treatmentType: .Insulin, nightscoutEventType: "Bolus", enteredBy: "Upstream",
            nsManagedObjectContext: core.mainManagedObjectContext)
        let matchingHealth = TreatmentEntry(date: date, value: 2,
            treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "Apple Health",
            nsManagedObjectContext: core.mainManagedObjectContext)
        matchingHealth.healthKitSampleUUID = UUID().uuidString
        matchingHealth.healthKitSourceBundleIdentifier = sourceA.bundleIdentifier
        matchingHealth.healthKitExternalUUID = "shared"
        let realRepeat = TreatmentEntry(date: date, value: 2,
            treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "Apple Health",
            nsManagedObjectContext: core.mainManagedObjectContext)
        realRepeat.healthKitSampleUUID = UUID().uuidString
        realRepeat.healthKitSourceBundleIdentifier = sourceA.bundleIdentifier
        realRepeat.healthKitExternalUUID = "distinct"
        let manual = TreatmentEntry(date: date, value: 2,
            treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "Manual",
            nsManagedObjectContext: core.mainManagedObjectContext)
        let carbsSameOrigin = TreatmentEntry(date: date, value: 2,
            treatmentType: .Carbs, nightscoutEventType: nil, enteredBy: "Apple Health",
            nsManagedObjectContext: core.mainManagedObjectContext)
        carbsSameOrigin.healthKitSampleUUID = UUID().uuidString
        carbsSameOrigin.healthKitSourceBundleIdentifier = sourceA.bundleIdentifier
        carbsSameOrigin.healthKitSyncIdentifier = "shared"
        let rows = [external, matchingHealth, realRepeat, manual, carbsSameOrigin]

        let selected = TherapyMetricsManager.eligibleTreatments(rows, policy: policy(),
            insulinSource: sourceA.bundleIdentifier, carbsSource: sourceA.bundleIdentifier,
            insulinEnabled: true, carbsEnabled: true)
        XCTAssertEqual(selected.count, 4)
        XCTAssertTrue(selected.contains(external))
        XCTAssertFalse(selected.contains(matchingHealth))
        XCTAssertTrue(selected.contains(realRepeat), "equal time and amount are not a duplicate")
        XCTAssertTrue(selected.contains(manual))
        XCTAssertTrue(selected.contains(carbsSameOrigin), "a carb ID cannot mask an insulin dose")

        let switched = TherapyMetricsManager.eligibleTreatments(rows, policy: policy(),
            insulinSource: sourceB.bundleIdentifier, carbsSource: sourceB.bundleIdentifier,
            insulinEnabled: true, carbsEnabled: true)
        XCTAssertEqual(switched.count, 2)
        XCTAssertTrue(switched.contains(external))
        XCTAssertTrue(switched.contains(manual))
        let off = TherapyMetricsManager.eligibleTreatments(rows, policy: policy(),
            insulinSource: sourceA.bundleIdentifier, carbsSource: sourceA.bundleIdentifier,
            insulinEnabled: false, carbsEnabled: false)
        XCTAssertEqual(off.count, 2)
    }

    func testHealthImportsNeverEnterNightscoutUploadFetch() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let local = TreatmentEntry(date: Date(), value: 2, treatmentType: .Insulin,
            nightscoutEventType: nil, enteredBy: "Manual",
            nsManagedObjectContext: core.mainManagedObjectContext)
        let health = TreatmentEntry(date: Date(), value: 20, treatmentType: .Carbs,
            nightscoutEventType: nil, enteredBy: "Apple Health",
            nsManagedObjectContext: core.mainManagedObjectContext)
        health.healthKitSampleUUID = UUID().uuidString
        health.healthKitSourceBundleIdentifier = sourceA.bundleIdentifier
        XCTAssertTrue(core.saveChangesSynchronously())
        let uploadRows = TreatmentEntryAccessor(coreDataManager: core)
            .getLatestTreatmentsForNightscout(limit: 10)
        XCTAssertEqual(uploadRows.count, 1)
        XCTAssertTrue(uploadRows.first === local)
    }

    func testSourceCutoverIsDurableAndUsesEventTimeForBackdatedEntries() throws {
        let suite = "TreatmentSourceCutover.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let boundary = Date(timeIntervalSince1970: 1_800_000_000)
        let policy = TreatmentSourceCutover(cutoff: boundary,
            insulinSourceBundleID: "com.mysugr.insulin",
            carbohydrateSourceBundleID: "com.mysugr.carbs")
        XCTAssertTrue(TreatmentSourceCutover.persist(policy, defaults: defaults))
        XCTAssertEqual(TreatmentSourceCutover.current(defaults: defaults), policy)
        XCTAssertFalse(TreatmentSourceCutover.persist(policy, defaults: defaults),
            "a second switch must not silently move the persisted source boundary")
        XCTAssertTrue(policy.permitsImported(eventDate: boundary.addingTimeInterval(-1),
            kind: .insulin, sourceBundleID: "com.mysugr.insulin"))
        XCTAssertFalse(policy.permitsImported(eventDate: boundary,
            kind: .insulin, sourceBundleID: "com.mysugr.insulin"))
        XCTAssertFalse(policy.permitsImported(eventDate: boundary.addingTimeInterval(-1),
            kind: .insulin, sourceBundleID: "com.other"))
        XCTAssertTrue(policy.permitsLocal(eventDate: boundary,
            localTreatmentUUID: UUID().uuidString, watchSourceUUID: nil))
        XCTAssertTrue(policy.permitsLocal(eventDate: boundary,
            localTreatmentUUID: nil, watchSourceUUID: UUID().uuidString))
        XCTAssertFalse(policy.permitsLocal(eventDate: boundary.addingTimeInterval(-1),
            localTreatmentUUID: UUID().uuidString, watchSourceUUID: nil))
        XCTAssertFalse(policy.permitsLocal(eventDate: boundary,
            localTreatmentUUID: nil, watchSourceUUID: nil))
        let restarted = try XCTUnwrap(TreatmentSourceCutover.current(defaults: defaults))
        XCTAssertEqual(restarted.cutoff, boundary)
    }

    func testDamagedCutoverNeverReenablesOldImportOrReportsSuccessfulSwitch() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        fixture.defaults.set(true, forKey: "healthTherapyImport.v1.insulin.enabled")
        for damagedValue in ["not data" as Any, Data("{invalid json".utf8) as Any] {
            fixture.defaults.set(damagedValue, forKey: TreatmentSourceCutover.defaultsKey)
            XCTAssertNil(TreatmentSourceCutover.current(defaults: fixture.defaults))
            XCTAssertTrue(TreatmentSourceCutover.hasInvalidStoredValue(defaults: fixture.defaults))
            XCTAssertFalse(fixture.manager.isEnabled(.insulin))

            let enable = expectation(description: "damaged cutoff rejects import enablement")
            fixture.manager.setEnabled(true, kind: .insulin) { error in
                XCTAssertNotNil(error)
                enable.fulfill()
            }
            wait(for: [enable], timeout: 5)

            let switchAttempt = expectation(description: "damaged cutoff rejects new switch")
            fixture.manager.switchToLocalLogging { error in
                XCTAssertNotNil(error)
                switchAttempt.fulfill()
            }
            wait(for: [switchAttempt], timeout: 5)
        }
        fixture.defaults.removeObject(forKey: TreatmentSourceCutover.defaultsKey)
        XCTAssertFalse(TreatmentSourceCutover.hasInvalidStoredValue(defaults: fixture.defaults))
        XCTAssertTrue(fixture.manager.isEnabled(.insulin))
    }

    func testCutoverWaitsForBothDurableSelectedMySugrReads() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let mySugr = HealthTherapyImportSource(bundleIdentifier: "com.mysugr.therapy", name: "mySugr")
        fixture.query.setPage(page([sample(.insulin, source: mySugr)], next: "i0"),
                              for: .insulin, after: nil)
        fixture.query.setPage(page([sample(.carbohydrates, source: mySugr)], next: "c0"),
                              for: .carbohydrates, after: nil)
        enable(.insulin, source: mySugr, fixture: fixture)
        enable(.carbohydrates, source: mySugr, fixture: fixture)
        waitUntil("both selected mySugr imports complete") {
            !fixture.manager.status(.insulin).isIncomplete &&
                !fixture.manager.status(.carbohydrates).isIncomplete
        }
        fixture.query.holdPage(for: .carbohydrates, after: anchor("c0"))
        let completed = expectation(description: "final mySugr import committed")
        fixture.manager.switchToLocalLogging { error in
            XCTAssertNil(error)
            completed.fulfill()
        }
        waitUntil("final carbohydrate read held") {
            fixture.query.anchors(for: .carbohydrates).contains { $0 == self.anchor("c0") }
        }
        XCTAssertNil(TreatmentSourceCutover.current(defaults: fixture.defaults))
        XCTAssertTrue(fixture.manager.isEnabled(.insulin))
        fixture.query.releaseHeldPage(for: .carbohydrates, after: anchor("c0"))
        wait(for: [completed], timeout: 5)
        XCTAssertNotNil(TreatmentSourceCutover.current(defaults: fixture.defaults))
        XCTAssertFalse(fixture.manager.isEnabled(.insulin))
        XCTAssertFalse(fixture.manager.isEnabled(.carbohydrates))
        XCTAssertEqual(treatments(in: fixture.core).count, 2)
    }

    func testFailedFinalImportDoesNotChangeSourceBoundary() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let mySugr = HealthTherapyImportSource(bundleIdentifier: "com.mysugr.therapy", name: "mySugr")
        fixture.query.setPage(page([sample(.insulin, source: mySugr)], next: "i0"),
                              for: .insulin, after: nil)
        fixture.query.setPage(page([sample(.carbohydrates, source: mySugr)], next: "c0"),
                              for: .carbohydrates, after: nil)
        enable(.insulin, source: mySugr, fixture: fixture)
        enable(.carbohydrates, source: mySugr, fixture: fixture)
        waitUntil("initial mySugr imports durably checkpointed") {
            fixture.anchor(for: .insulin) == self.anchor("i0") &&
                fixture.anchor(for: .carbohydrates) == self.anchor("c0") &&
                fixture.manager.status(.insulin).lastSync != nil &&
                fixture.manager.status(.carbohydrates).lastSync != nil
        }
        XCTAssertEqual(treatments(in: fixture.core).count, 2)
        fixture.query.setError(ReadFailure.locked, for: .insulin)
        let failed = expectation(description: "final read failed")
        fixture.manager.switchToLocalLogging { error in
            XCTAssertNotNil(error)
            failed.fulfill()
        }
        wait(for: [failed], timeout: 5)
        XCTAssertNil(TreatmentSourceCutover.current(defaults: fixture.defaults))
        XCTAssertTrue(fixture.manager.isEnabled(.insulin))
        XCTAssertTrue(fixture.manager.isEnabled(.carbohydrates))
    }

    func testChangingEitherSelectedSourceDuringFinalImportPreventsCutover() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let mySugr = HealthTherapyImportSource(bundleIdentifier: "com.mysugr.therapy", name: "mySugr")
        let other = HealthTherapyImportSource(bundleIdentifier: "com.other.therapy", name: "Other")
        fixture.query.setPage(page([sample(.insulin, source: mySugr)], next: "i0"),
                              for: .insulin, after: nil)
        fixture.query.setPage(page([sample(.carbohydrates, source: mySugr)], next: "c0"),
                              for: .carbohydrates, after: nil)
        enable(.insulin, source: mySugr, fixture: fixture)
        enable(.carbohydrates, source: mySugr, fixture: fixture)
        waitUntil("both sources initially complete") {
            !fixture.manager.status(.insulin).isIncomplete &&
                !fixture.manager.status(.carbohydrates).isIncomplete
        }
        fixture.query.holdPage(for: .carbohydrates, after: anchor("c0"))
        let failed = expectation(description: "source changed during final import")
        fixture.manager.switchToLocalLogging { error in
            XCTAssertNotNil(error)
            failed.fulfill()
        }
        waitUntil("final carbohydrate read held") {
            fixture.query.anchors(for: .carbohydrates).contains { $0 == self.anchor("c0") }
        }
        fixture.manager.selectSource(other, kind: .insulin)
        fixture.query.releaseHeldPage(for: .carbohydrates, after: anchor("c0"))
        wait(for: [failed], timeout: 5)
        XCTAssertNil(TreatmentSourceCutover.current(defaults: fixture.defaults))
        XCTAssertTrue(fixture.manager.isEnabled(.insulin))
    }

    func testOwnHealthWritesAreNeverImportedEvenWhenSelected() {
        let fixture = ImportFixture()
        defer { fixture.close() }
        let own = sample(.insulin, source: sourceA,
            syncIdentifier: HealthLocalTherapyIdentity.syncPrefix + UUID().uuidString)
        fixture.query.setPage(page([own], next: "own"), for: .insulin, after: nil)
        enable(.insulin, source: sourceA, fixture: fixture)
        waitUntil("own sample skipped and anchor advanced") {
            fixture.anchor(for: .insulin) == self.anchor("own")
        }
        XCTAssertTrue(treatments(in: fixture.core).isEmpty)
        XCTAssertTrue(ledger(in: fixture.core).isEmpty)
        XCTAssertTrue(HealthLocalTherapyIdentity.isOwn(sourceBundleID: sourceA.bundleIdentifier,
            syncIdentifier: own.syncIdentifier))
    }

    func testLocalHealthWriteRetryKeepsLocalPostAndStableIdentity() throws {
        let suite = "HealthLocalTherapyWriter.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let policy = TreatmentSourceCutover(cutoff: Date().addingTimeInterval(-3600),
            insulinSourceBundleID: "com.mysugr.insulin",
            carbohydrateSourceBundleID: "com.mysugr.carbs")
        XCTAssertTrue(TreatmentSourceCutover.persist(policy, defaults: defaults))
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let uuid = UUID().uuidString
        let dose = TreatmentEntry(date: Date().addingTimeInterval(-30), value: 2,
            treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "xDrip",
            nsManagedObjectContext: core.mainManagedObjectContext)
        dose.localTreatmentUUID = uuid
        dose.healthKitSyncVersion = NSNumber(value: 1)
        dose.healthKitSyncStateRaw = "pending"
        XCTAssertNil(dose.primitiveValue(forKey: "treatmentdeleted"),
            "new local rows must be writable even when this optional legacy field is nil")
        XCTAssertTrue(core.saveChangesSynchronously())
        let store = FakeWriteStore()
        store.failNext = true
        let writer = HealthKitLocalTherapyWriter(store: store, defaults: defaults)
        writer.configure(coreDataManager: core)
        waitUntil("first Health write attempted") { store.requests.count == 1 }
        XCTAssertEqual(store.requests.first?.syncIdentifier,
            HealthLocalTherapyIdentity.syncPrefix + uuid)
        XCTAssertEqual(store.requests.first?.version, 1)
        var persistedCount = 0
        var persistedSyncState: String?
        core.privateManagedObjectContext.performAndWait {
            let persisted = (try? core.privateManagedObjectContext.fetch(TreatmentEntry.fetchRequest())) ?? []
            persistedCount = persisted.count
            persistedSyncState = persisted.first?.healthKitSyncStateRaw
        }
        XCTAssertEqual(persistedCount, 1)
        XCTAssertEqual(persistedSyncState, "pending",
            "a Health failure must not roll back a local dose")
        writer.retryPending()
        waitUntil("same version retried") { store.requests.count >= 2 }
        XCTAssertEqual(Array(store.requests.prefix(2)), [store.requests[0], store.requests[0]])
        waitUntil("successful write acknowledged") {
            var state: String?
            core.privateManagedObjectContext.performAndWait {
                state = (try? core.privateManagedObjectContext.fetch(TreatmentEntry.fetchRequest()))?.first?.healthKitSyncStateRaw
            }
            return state == "synced"
        }
        dose.value = 3
        dose.healthKitSyncVersion = NSNumber(value: 2)
        dose.healthKitSyncStateRaw = HealthLocalTherapySyncState.pending(version: 2)
        XCTAssertTrue(core.saveChangesSynchronously())
        core.privateManagedObjectContext.performAndWait {
            let stored = (try? core.privateManagedObjectContext.fetch(TreatmentEntry.fetchRequest()))?.first
            XCTAssertEqual(stored?.value, 3)
            XCTAssertEqual(stored?.healthKitSyncVersion?.intValue, 2)
            XCTAssertEqual(stored?.healthKitSyncStateRaw, "pending.2",
                "the edited pending token must survive a stale main-context v1 acknowledgement")
        }
        writer.retryPending()
        waitUntil("edited dose written as higher version") { store.requests.count >= 3 }
        XCTAssertEqual(store.requests[2].syncIdentifier, store.requests[0].syncIdentifier)
        XCTAssertEqual(store.requests[2].version, 2)
        XCTAssertEqual(store.requests[2].amount, 3)
    }

    func testLocalHealthWriteFalseWithoutErrorAndAckFailureRemainPendingWithoutTightRetry() throws {
        let suite = "HealthLocalTherapyWriter.Failures.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(TreatmentSourceCutover.persist(.init(
            cutoff: Date().addingTimeInterval(-3600),
            insulinSourceBundleID: "com.mysugr.insulin",
            carbohydrateSourceBundleID: "com.mysugr.carbs"), defaults: defaults))
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let dose = TreatmentEntry(date: Date().addingTimeInterval(-30), value: 2,
            treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "xDrip",
            nsManagedObjectContext: core.mainManagedObjectContext)
        dose.localTreatmentUUID = UUID().uuidString
        dose.healthKitSyncVersion = NSNumber(value: 1)
        dose.healthKitSyncStateRaw = "pending"
        XCTAssertTrue(core.saveChangesSynchronously())
        let store = FakeWriteStore()
        store.failWithoutErrorNext = true
        let writer = HealthKitLocalTherapyWriter(store: store, defaults: defaults,
            acknowledgementSaver: { _ in throw ReadFailure.locked })
        writer.configure(coreDataManager: core)
        waitUntil("unsuccessful Health callback without NSError") { store.requests.count == 1 }
        let firstPause = expectation(description: "no immediate retry after unsuccessful Health callback")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { firstPause.fulfill() }
        wait(for: [firstPause], timeout: 2)
        XCTAssertEqual(store.requests.count, 1)
        writer.retryPending()
        waitUntil("Health succeeds but local acknowledgement fails") { store.requests.count == 2 }
        let secondPause = expectation(description: "no tight retry after local acknowledgement failure")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { secondPause.fulfill() }
        wait(for: [secondPause], timeout: 2)
        XCTAssertEqual(store.requests.count, 2)
        var state: String?
        core.privateManagedObjectContext.performAndWait {
            state = (try? core.privateManagedObjectContext.fetch(TreatmentEntry.fetchRequest()))?
                .first?.healthKitSyncStateRaw
        }
        XCTAssertEqual(state, "pending")
    }

    func testEditedDoseDuringInFlightHealthWriteKeepsNewerPendingVersion() throws {
        let suite = "HealthLocalTherapyWriter.InFlight.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(TreatmentSourceCutover.persist(.init(
            cutoff: Date().addingTimeInterval(-3600),
            insulinSourceBundleID: "com.mysugr.insulin",
            carbohydrateSourceBundleID: "com.mysugr.carbs"), defaults: defaults))
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let dose = TreatmentEntry(date: Date().addingTimeInterval(-30), value: 2,
            treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "xDrip",
            nsManagedObjectContext: core.mainManagedObjectContext)
        dose.localTreatmentUUID = UUID().uuidString
        dose.healthKitSyncVersion = NSNumber(value: 1)
        dose.healthKitSyncStateRaw = "pending"
        XCTAssertTrue(core.saveChangesSynchronously())
        let store = FakeWriteStore()
        store.holdNext = true
        let writer = HealthKitLocalTherapyWriter(store: store, defaults: defaults)
        writer.configure(coreDataManager: core)
        waitUntil("first Health write held") { store.requests.count == 1 }

        dose.value = 3
        dose.healthKitSyncVersion = NSNumber(value: 2)
        dose.healthKitSyncStateRaw = HealthLocalTherapySyncState.pending(version: 2)
        XCTAssertTrue(core.saveChangesSynchronously())
        store.completeHeld()
        waitUntil("newer edit written after old acknowledgement") { store.requests.count == 2 }
        XCTAssertEqual(store.requests.map(\.version), [1, 2])
        XCTAssertEqual(store.requests[1].amount, 3)
        XCTAssertEqual(store.requests[1].syncIdentifier, store.requests[0].syncIdentifier)
        waitUntil("newer version acknowledged") {
            var version: Int?
            var state: String?
            core.privateManagedObjectContext.performAndWait {
                let row = (try? core.privateManagedObjectContext.fetch(TreatmentEntry.fetchRequest()))?.first
                version = row?.healthKitSyncVersion?.intValue
                state = row?.healthKitSyncStateRaw
            }
            return version == 2 && state == "synced"
        }
    }

    private func persistedSyncState(_ uuid: String, in core: CoreDataManager) -> String? {
        guard let coordinator = core.privateManagedObjectContext.persistentStoreCoordinator else { return nil }
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        var state: String?
        context.performAndWait {
            let request: NSFetchRequest<TreatmentEntry> = TreatmentEntry.fetchRequest()
            request.predicate = NSPredicate(format: "localTreatmentUUID == %@", uuid)
            state = (try? context.fetch(request).first)?.healthKitSyncStateRaw
        }
        return state
    }

    @MainActor func testListAndEditorDeletionRemoveOnlyTheirStableHealthIdentities() throws {
        let suite = "HealthTherapyDeleteUI.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(TreatmentSourceCutover.persist(.init(cutoff: Date().addingTimeInterval(-3600),
            insulinSourceBundleID: "mysugr.insulin", carbohydrateSourceBundleID: "mysugr.carbs"),
            defaults: defaults))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PenDoseLogJournal(directory: directory)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let insulin = TreatmentEntry(date: Date().addingTimeInterval(-120), value: 2,
            treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "xDrip",
            nsManagedObjectContext: core.mainManagedObjectContext)
        insulin.localTreatmentUUID = UUID().uuidString
        insulin.healthKitSyncVersion = NSNumber(value: 1)
        insulin.healthKitSyncStateRaw = "synced"
        let carbs = TreatmentEntry(date: Date().addingTimeInterval(-60), value: 20,
            treatmentType: .Carbs, nightscoutEventType: nil, enteredBy: "xDrip",
            nsManagedObjectContext: core.mainManagedObjectContext)
        carbs.localTreatmentUUID = UUID().uuidString
        carbs.healthKitSyncVersion = NSNumber(value: 2)
        carbs.healthKitSyncStateRaw = "synced"
        XCTAssertTrue(core.saveChangesSynchronously())
        let store = FakeWriteStore()
        let writer = HealthKitLocalTherapyWriter(store: store, defaults: defaults,
            deletionIsVerified: { journal.recoveryState(coreDataManager: $0) == .ready })
        writer.configure(coreDataManager: core)

        let list = TreatmentsViewModel(coreDataManager: core, localSaveJournal: journal)
        XCTAssertTrue(list.deleteTreatment(TreatmentSnapshot(treatmentEntry: insulin)))
        waitUntil("list Health copy removed") {
            store.deletionRequests.count == 1 &&
                self.persistedSyncState(insulin.localTreatmentUUID!, in: core) == HealthLocalTherapySyncState.deleted
        }
        let editor = TreatmentEditorViewModel(coreDataManager: core, treatmentToEdit: carbs,
            localSaveJournal: journal)
        XCTAssertTrue(editor.deleteTreatment())
        waitUntil("editor Health copy removed") {
            store.deletionRequests.count == 2 &&
                self.persistedSyncState(carbs.localTreatmentUUID!, in: core) == HealthLocalTherapySyncState.deleted
        }
        XCTAssertEqual(store.deletionRequests.map(\.syncIdentifier), [
            HealthLocalTherapyIdentity.syncPrefix + insulin.localTreatmentUUID!,
            HealthLocalTherapyIdentity.syncPrefix + carbs.localTreatmentUUID!
        ])
        XCTAssertEqual(store.deletionRequests.map(\.kind), [.insulin, .carbohydrates])
        XCTAssertTrue(insulin.treatmentdeleted)
        XCTAssertTrue(carbs.treatmentdeleted)
        XCTAssertTrue(store.requests.isEmpty, "Deleted treatments must not be exported again")
    }

    @MainActor func testUnverifiedLocalDeletionNeverStartsHealthDeletionEvenAfterLaterStoreSave() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PenDoseLogJournal(directory: directory)
        let entry = TreatmentEntry(date: Date().addingTimeInterval(-60), value: 2,
            treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "xDrip",
            nsManagedObjectContext: core.mainManagedObjectContext)
        entry.localTreatmentUUID = UUID().uuidString
        entry.healthKitSyncVersion = NSNumber(value: 1)
        entry.healthKitSyncStateRaw = "synced"
        XCTAssertTrue(core.saveChangesSynchronously())
        let store = FakeWriteStore()
        let writer = HealthKitLocalTherapyWriter(store: store,
            deletionIsVerified: { journal.recoveryState(coreDataManager: $0) == .ready })
        writer.configure(coreDataManager: core)
        let list = TreatmentsViewModel(coreDataManager: core, localSaveJournal: journal,
            localSaveOverride: {
                try? core.mainManagedObjectContext.save()
                return false
            })
        XCTAssertFalse(list.deleteTreatment(TreatmentSnapshot(treatmentEntry: entry)))
        XCTAssertEqual(journal.recoveryState(coreDataManager: core), .awaitingRestart)
        XCTAssertTrue(core.saveChangesSynchronously(), "A later unrelated save can commit a failed child mutation")
        writer.retryPending()
        let settled = expectation(description: "journal blocks Health deletion")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertTrue(store.deletionRequests.isEmpty)
        XCTAssertEqual(persistedSyncState(entry.localTreatmentUUID!, in: core), "synced")
    }

    @MainActor func testDeletionDuringInFlightWriteCannotRecreateHealthCopy() throws {
        let suite = "HealthTherapyDeleteRace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(TreatmentSourceCutover.persist(.init(cutoff: Date().addingTimeInterval(-3600),
            insulinSourceBundleID: "mysugr.insulin", carbohydrateSourceBundleID: "mysugr.carbs"),
            defaults: defaults))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = PenDoseLogJournal(directory: directory)
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let entry = TreatmentEntry(date: Date().addingTimeInterval(-60), value: 2,
            treatmentType: .Insulin, nightscoutEventType: nil, enteredBy: "xDrip",
            nsManagedObjectContext: core.mainManagedObjectContext)
        entry.localTreatmentUUID = UUID().uuidString
        entry.healthKitSyncVersion = NSNumber(value: 1)
        entry.healthKitSyncStateRaw = "pending"
        XCTAssertTrue(core.saveChangesSynchronously())
        let store = FakeWriteStore()
        store.holdNext = true
        let writer = HealthKitLocalTherapyWriter(store: store, defaults: defaults,
            deletionIsVerified: { journal.recoveryState(coreDataManager: $0) == .ready })
        writer.configure(coreDataManager: core)
        waitUntil("Health write in flight") { store.requests.count == 1 }
        let list = TreatmentsViewModel(coreDataManager: core, localSaveJournal: journal)
        XCTAssertTrue(list.deleteTreatment(TreatmentSnapshot(treatmentEntry: entry)))
        store.completeHeld()
        waitUntil("in-flight write followed by exact deletion") {
            store.deletionRequests.count == 1 &&
                self.persistedSyncState(entry.localTreatmentUUID!, in: core) == HealthLocalTherapySyncState.deleted
        }
        XCTAssertEqual(store.requests.count, 1)
        XCTAssertEqual(store.requests.first?.syncIdentifier, store.deletionRequests.first?.syncIdentifier)
        writer.retryPending()
        writer.retryPending()
        let settled = expectation(description: "repeat triggers do not recreate the copy")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(store.requests.count, 1)
        XCTAssertEqual(store.deletionRequests.count, 1)
    }

    func testHistoricalDeletedRowsRetryAcrossRestartWithoutTouchingOtherOrigins() throws {
        let suite = "HealthTherapyDeleteCleanup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cutoff = Date().addingTimeInterval(-3600)
        XCTAssertTrue(TreatmentSourceCutover.persist(.init(cutoff: cutoff,
            insulinSourceBundleID: "mysugr.insulin", carbohydrateSourceBundleID: "mysugr.carbs"),
            defaults: defaults))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("therapy.sqlite")
        let core = try CoreDataManager(testModelName: ConstantsCoreData.modelName,
            persistentStoreURL: storeURL)
        func row(_ kind: TreatmentType, _ date: Date, deleted: Bool,
                 imported: Bool = false, watch: Bool = false, alreadyRemoved: Bool = false) -> TreatmentEntry {
            let entry = TreatmentEntry(date: date, value: 2, treatmentType: kind,
                nightscoutEventType: nil, enteredBy: "xDrip",
                nsManagedObjectContext: core.mainManagedObjectContext)
            entry.localTreatmentUUID = UUID().uuidString
            entry.healthKitSyncVersion = NSNumber(value: 1)
            entry.healthKitSyncStateRaw = alreadyRemoved ? HealthLocalTherapySyncState.deleted : "synced"
            entry.treatmentdeleted = deleted
            if imported { entry.healthKitSampleUUID = UUID().uuidString }
            if watch { entry.watchSourceUUID = UUID().uuidString }
            return entry
        }
        let oldInsulin = row(.Insulin, cutoff.addingTimeInterval(-7200), deleted: true)
        let oldCarbs = row(.Carbs, cutoff.addingTimeInterval(-3600), deleted: true)
        let insulinUUID = oldInsulin.localTreatmentUUID!
        let carbsUUID = oldCarbs.localTreatmentUUID!
        _ = row(.Insulin, cutoff.addingTimeInterval(-1800), deleted: false)
        _ = row(.Insulin, cutoff.addingTimeInterval(-1700), deleted: true, imported: true)
        _ = row(.Carbs, cutoff.addingTimeInterval(-1600), deleted: true, watch: true)
        _ = row(.Insulin, cutoff.addingTimeInterval(-1500), deleted: true, alreadyRemoved: true)
        XCTAssertTrue(core.saveChangesSynchronously())
        let store = FakeWriteStore()
        store.failNextDeletion = true
        let first = HealthKitLocalTherapyWriter(store: store, defaults: defaults,
            deletionIsVerified: { _ in true })
        first.configure(coreDataManager: core)
        waitUntil("first historical delete fails") { store.deletionRequests.count == 1 }
        XCTAssertEqual(store.deletionRequests.first?.localUUID, insulinUUID)
        XCTAssertEqual(persistedSyncState(insulinUUID, in: core), "synced")
        waitUntil("full pending cleanup count") {
            HealthKitExportStatusStore.shared.snapshot(.insulin).pendingDeletes == 1 &&
                HealthKitExportStatusStore.shared.snapshot(.carbohydrates).pendingDeletes == 1
        }
        try core.disconnectPersistentStoresForTesting()
        let reopened = try CoreDataManager(testModelName: ConstantsCoreData.modelName,
            persistentStoreURL: storeURL)
        let resumed = HealthKitLocalTherapyWriter(store: store, defaults: defaults,
            deletionIsVerified: { _ in true })
        resumed.configure(coreDataManager: reopened)
        waitUntil("all historical deletes confirmed after restart") {
            store.deletionRequests.count == 3 &&
                self.persistedSyncState(insulinUUID, in: reopened) == HealthLocalTherapySyncState.deleted &&
                self.persistedSyncState(carbsUUID, in: reopened) == HealthLocalTherapySyncState.deleted
        }
        XCTAssertEqual(store.deletionRequests.map(\.localUUID), [
            insulinUUID, insulinUUID, carbsUUID
        ])
        resumed.retryPending()
        let settled = expectation(description: "completed cleanup is idempotent")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(store.deletionRequests.count, 3)
        waitUntil("pending counts reach zero") {
            HealthKitExportStatusStore.shared.snapshot(.insulin).pendingDeletes == 0 &&
                HealthKitExportStatusStore.shared.snapshot(.carbohydrates).pendingDeletes == 0
        }
    }

    private final class FakeWriteStore: HealthLocalTherapyWriting {
        private let lock = NSLock()
        private var values: [HealthLocalTherapyWriteRequest] = []
        private var deletedValues: [HealthLocalTherapyDeleteRequest] = []
        private var heldCompletion: ((Bool, Error?) -> Void)?
        private var heldDeletionCompletion: ((Bool, Error?) -> Void)?
        var failNext = false
        var failWithoutErrorNext = false
        var holdNext = false
        var failNextDeletion = false
        var holdNextDeletion = false
        var requests: [HealthLocalTherapyWriteRequest] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
        var deletionRequests: [HealthLocalTherapyDeleteRequest] {
            lock.lock(); defer { lock.unlock() }
            return deletedValues
        }
        func completeHeld() {
            lock.lock()
            let completion = heldCompletion
            heldCompletion = nil
            lock.unlock()
            completion?(true, nil)
        }
        func completeHeldDeletion() {
            lock.lock()
            let completion = heldDeletionCompletion
            heldDeletionCompletion = nil
            lock.unlock()
            completion?(true, nil)
        }
        func save(_ request: HealthLocalTherapyWriteRequest,
                  completion: @escaping (Bool, Error?) -> Void) {
            lock.lock()
            values.append(request)
            if holdNext {
                holdNext = false
                heldCompletion = completion
                lock.unlock()
                return
            }
            let shouldFail = failNext
            failNext = false
            let failWithoutError = failWithoutErrorNext
            failWithoutErrorNext = false
            lock.unlock()
            completion(!shouldFail && !failWithoutError,
                shouldFail ? ReadFailure.locked : nil)
        }
        func delete(_ request: HealthLocalTherapyDeleteRequest,
                    completion: @escaping (Bool, Error?) -> Void) {
            lock.lock()
            deletedValues.append(request)
            if holdNextDeletion {
                holdNextDeletion = false
                heldDeletionCompletion = completion
                lock.unlock()
                return
            }
            let shouldFail = failNextDeletion
            failNextDeletion = false
            lock.unlock()
            completion(!shouldFail, shouldFail ? ReadFailure.locked : nil)
        }
    }

    private enum ReadFailure: Error { case locked }

    private final class ImportFixture {
        let suiteName = "HealthKitTherapyImportTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let query = FakeQuery()
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let manager: HealthKitTherapyImportManager
        private var configured = false

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            manager = HealthKitTherapyImportManager(query: query, defaults: defaults)
        }

        func configureOnce() {
            guard !configured else { return }
            configured = true
            manager.configure(coreDataManager: core)
        }

        func anchor(for kind: HealthTherapyImportKind) -> Data? {
            defaults.data(forKey: "healthTherapyImport.v1.\(kind.rawValue).anchor")
        }

        func close() { defaults.removePersistentDomain(forName: suiteName) }
    }

    private final class FakeQuery: HealthTherapyQuerying {
        private let lock = NSLock()
        private var pages: [String: HealthTherapyImportPage] = [:]
        private var failures: [HealthTherapyImportKind: Error] = [:]
        private var authorizationFailures: [HealthTherapyImportKind: Error] = [:]
        private var observed: [HealthTherapyImportKind: (@escaping () -> Void) -> Void] = [:]
        private var requestedAnchors: [HealthTherapyImportKind: [Data?]] = [:]
        private var heldPages = Set<String>()
        private var pendingDeliveries: [String: () -> Void] = [:]

        private func key(_ kind: HealthTherapyImportKind, _ anchor: Data?) -> String {
            kind.rawValue + ":" + (anchor.flatMap { String(data: $0, encoding: .utf8) } ?? "initial")
        }

        func setPage(_ page: HealthTherapyImportPage, for kind: HealthTherapyImportKind, after anchor: Data?) {
            lock.lock(); defer { lock.unlock() }
            pages[key(kind, anchor)] = page
        }

        func holdPage(for kind: HealthTherapyImportKind, after anchor: Data?) {
            lock.lock(); defer { lock.unlock() }
            heldPages.insert(key(kind, anchor))
        }

        func releaseHeldPage(for kind: HealthTherapyImportKind, after anchor: Data?) {
            lock.lock()
            let key = key(kind, anchor)
            heldPages.remove(key)
            let deliver = pendingDeliveries.removeValue(forKey: key)
            lock.unlock()
            deliver?()
        }

        func setError(_ error: Error?, for kind: HealthTherapyImportKind) {
            lock.lock(); defer { lock.unlock() }
            failures[kind] = error
        }

        func setAuthorizationError(_ error: Error?, for kind: HealthTherapyImportKind) {
            lock.lock(); defer { lock.unlock() }
            authorizationFailures[kind] = error
        }

        func anchors(for kind: HealthTherapyImportKind) -> [Data?] {
            lock.lock(); defer { lock.unlock() }
            return requestedAnchors[kind] ?? []
        }

        func emit(_ kind: HealthTherapyImportKind) {
            lock.lock()
            let callback = observed[kind]
            lock.unlock()
            callback?({})
        }

        func requestReadAuthorization(for kind: HealthTherapyImportKind,
                                      completion: @escaping (Error?) -> Void) {
            lock.lock()
            let failure = authorizationFailures[kind]
            lock.unlock()
            completion(failure)
        }

        func discoverSources(for kind: HealthTherapyImportKind,
                             completion: @escaping ([HealthTherapyImportSource], Error?) -> Void) {
            completion([], nil)
        }

        func page(for kind: HealthTherapyImportKind, since: Date, anchor: Data?, limit: Int,
                  completion: @escaping (Result<HealthTherapyImportPage, Error>) -> Void) {
            lock.lock()
            requestedAnchors[kind, default: []].append(anchor)
            let error = failures[kind]
            let response = pages[key(kind, anchor)]
            let pageKey = key(kind, anchor)
            let isHeld = heldPages.contains(pageKey)
            let delivery = {
                if let error { completion(.failure(error)); return }
                completion(.success(response ?? HealthTherapyImportPage(
                    samples: [], deletedUUIDs: [], nextAnchor: anchor ?? Data("empty".utf8), hasMore: false)))
            }
            if isHeld { pendingDeliveries[pageKey] = delivery }
            lock.unlock()
            if !isHeld { delivery() }
        }

        func observe(_ kind: HealthTherapyImportKind,
                     onChange: @escaping (@escaping () -> Void) -> Void) {
            lock.lock(); defer { lock.unlock() }
            observed[kind] = onChange
        }

        func stopObserving(_ kind: HealthTherapyImportKind) {
            lock.lock(); defer { lock.unlock() }
            observed.removeValue(forKey: kind)
        }
    }
}

/// Manual Watch entries are kept through phone restarts and transport retries, while their
/// local-only provenance prevents an unrelated Nightscout sync from exporting them.
final class WatchManualTreatmentTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    func testEnvelopeRequiresMatchingIDAndValidPositiveAmountAndTime() throws {
        let id = UUID()
        let now = at.addingTimeInterval(10)
        let good = WatchManualTreatment(id: id, recordedAt: at, kind: .insulin, amount: 1.25)
        let envelope: [String: Any] = [
            WatchManualTreatmentMessageKey.treatmentID: id.uuidString,
            WatchManualTreatmentMessageKey.treatment: try JSONEncoder().encode(good)
        ]
        XCTAssertEqual(WatchManualTreatmentStore.decode(envelope, at: now), good)
        var wrongID = envelope
        wrongID[WatchManualTreatmentMessageKey.treatmentID] = UUID().uuidString
        XCTAssertNil(WatchManualTreatmentStore.decode(wrongID, at: now))

        for amount in [0, -1, Double.nan, Double.infinity, 200.1] {
            let entry = WatchManualTreatment(id: id, recordedAt: at, kind: .insulin, amount: amount)
            XCTAssertFalse(entry.isValid(at: now), "insulin \(amount)")
        }
        XCTAssertTrue(WatchManualTreatment(id: id, recordedAt: at, kind: .insulin, amount: 200).isValid(at: now))
        XCTAssertFalse(WatchManualTreatment(id: id, recordedAt: at, kind: .carbs, amount: 500.1).isValid(at: now))
        XCTAssertTrue(WatchManualTreatment(id: id, recordedAt: at, kind: .carbs, amount: 500).isValid(at: now))
        XCTAssertFalse(WatchManualTreatment(id: id, recordedAt: now.addingTimeInterval(3601),
                                            kind: .carbs, amount: 10).isValid(at: now))
    }

    func testLostReceiptRetryAfterPhoneRestartDoesNotDuplicateTreatment() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchManualTreatmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("treatments.sqlite")
        let first = WatchManualTreatment(id: UUID(), recordedAt: at, kind: .insulin, amount: 2.5)
        let sameValueDifferentID = WatchManualTreatment(id: UUID(), recordedAt: at, kind: .insulin, amount: 2.5)

        let phone = try CoreDataManager(testModelName: ConstantsCoreData.modelName, persistentStoreURL: storeURL)
        let firstReceipt = expectation(description: "phone committed the first entry")
        WatchManualTreatmentStore.save(first, coreDataManager: phone, at: at.addingTimeInterval(1)) { outcome in
            XCTAssertEqual(outcome, .stored)
            firstReceipt.fulfill()
        }
        wait(for: [firstReceipt], timeout: 5)
        try phone.disconnectPersistentStoresForTesting()

        let restartedPhone = try CoreDataManager(testModelName: ConstantsCoreData.modelName, persistentStoreURL: storeURL)
        let retryReceipt = expectation(description: "retry after lost receipt is deduplicated")
        WatchManualTreatmentStore.save(first, coreDataManager: restartedPhone, at: at.addingTimeInterval(2)) { outcome in
            XCTAssertEqual(outcome, .alreadyStored)
            retryReceipt.fulfill()
        }
        wait(for: [retryReceipt], timeout: 5)
        let distinctReceipt = expectation(description: "same value with a new UUID is a distinct entry")
        WatchManualTreatmentStore.save(sameValueDifferentID, coreDataManager: restartedPhone,
                                       at: at.addingTimeInterval(2)) { outcome in
            XCTAssertEqual(outcome, .stored)
            distinctReceipt.fulfill()
        }
        wait(for: [distinctReceipt], timeout: 5)

        let context = restartedPhone.mainManagedObjectContext
        context.performAndWait {
            let rows = (try? context.fetch(TreatmentEntry.fetchRequest())) ?? []
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(Set(rows.compactMap(\.watchSourceUUID)), Set([first.id.uuidString, sameValueDifferentID.id.uuidString]))
            XCTAssertTrue(rows.allSatisfy { $0.treatmentType == .Insulin && $0.value == 2.5 && $0.isWatchLocalOnly })
            XCTAssertEqual(rows.first { $0.watchSourceUUID == first.id.uuidString }?.createdAt,
                at.addingTimeInterval(1), "retry must preserve the first iPhone receipt time")
            XCTAssertEqual(rows.first { $0.watchSourceUUID == first.id.uuidString }?.modifiedAt,
                at.addingTimeInterval(1))
        }
        try restartedPhone.disconnectPersistentStoresForTesting()
    }

    func testWatchEntriesStayVisibleLocallyButNeverEnterNightscoutUploadSelection() {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = core.mainManagedObjectContext
        let watch = TreatmentEntry(date: at, value: 12, treatmentType: .Carbs,
            nightscoutEventType: nil, enteredBy: "xDrip4iOS Watch", nsManagedObjectContext: context)
        watch.watchSourceUUID = UUID().uuidString
        let manual = TreatmentEntry(date: at.addingTimeInterval(-60), value: 15, treatmentType: .Carbs,
            nightscoutEventType: nil, enteredBy: "Manual", nsManagedObjectContext: context)
        XCTAssertTrue(core.saveChangesSynchronously())
        XCTAssertEqual(TreatmentEntryAccessor(coreDataManager: core).getLatestTreatments(limit: 10).count, 2)
        let uploadRows = TreatmentEntryAccessor(coreDataManager: core).getLatestTreatmentsForNightscout(limit: 1)
        XCTAssertEqual(uploadRows.count, 1)
        XCTAssertTrue(uploadRows[0] === manual)
    }

    @MainActor
    func testBackupRetainsDistinctWatchIDsAndRestoreRemainsIdempotent() async throws {
        let source = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let ids = [UUID().uuidString, UUID().uuidString]
        for id in ids {
            let row = TreatmentEntry(date: at, value: 3, treatmentType: .Insulin,
                nightscoutEventType: nil, enteredBy: "xDrip4iOS Watch",
                nsManagedObjectContext: source.mainManagedObjectContext)
            row.watchSourceUUID = id
        }
        XCTAssertTrue(source.saveChangesSynchronously())
        let exporter = BackupService(coreDataManager: source)
        let archive = try await exporter.createBackup(options: BackupOptions(
            includesSettings: false, includesAccounts: false, includesBgReadings: false, includesTreatments: true
        ))
        defer { try? FileManager.default.removeItem(at: archive.url) }
        let inspection = try exporter.inspectBackup(at: archive.url)
        XCTAssertEqual(Set(inspection.payload.treatments.compactMap(\.watchSourceUUID)), Set(ids))

        let destination = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let importer = BackupService(coreDataManager: destination)
        _ = try await importer.restore(inspection: inspection, mode: .keepCurrent,
                                       restoresSettings: false, restoredAccountCategories: [])
        _ = try await importer.restore(inspection: inspection, mode: .keepCurrent,
                                       restoresSettings: false, restoredAccountCategories: [])
        let rows = try destination.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.compactMap(\.watchSourceUUID)), Set(ids))
    }

    func testV33TreatmentStoreMigratesToV34WithoutChangingExistingRows() throws {
        let modelDirectory = try XCTUnwrap(Bundle.main.url(forResource: ConstantsCoreData.modelName, withExtension: "momd"))
        let v33 = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("xdrip v33.mom")))
        let v34 = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("xdrip v34.mom")))
        XCTAssertNoThrow(try NSMappingModel.inferredMappingModel(forSourceModel: v33, destinationModel: v34))
        XCTAssertNil(v33.entitiesByName["TreatmentEntry"]?.attributesByName["watchSourceUUID"])
        XCTAssertTrue(try XCTUnwrap(v34.entitiesByName["TreatmentEntry"]?.attributesByName["watchSourceUUID"]).isOptional)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchTreatmentMigration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("legacy.sqlite")
        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: v33)
        let oldStore = try oldCoordinator.addPersistentStore(ofType: NSSQLiteStoreType,
            configurationName: nil, at: url)
        let oldContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = oldCoordinator
        try oldContext.performAndWait {
            let row = NSEntityDescription.insertNewObject(forEntityName: "TreatmentEntry", into: oldContext)
            row.setValue(at, forKey: "date")
            row.setValue(3.5, forKey: "value")
            row.setValue(TreatmentType.Insulin.rawValue, forKey: "treatmentType")
            row.setValue("", forKey: "id")
            try oldContext.save()
            oldContext.reset()
        }
        try oldCoordinator.remove(oldStore)

        let migrated = try CoreDataManager(testModelName: ConstantsCoreData.modelName, persistentStoreURL: url)
        let rows = try migrated.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].value, 3.5)
        XCTAssertNil(rows[0].watchSourceUUID)
        try migrated.disconnectPersistentStoresForTesting()
    }
}

final class WatchBasalTreatmentTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_800_000_000)

    private func envelope(_ treatment: WatchManualTreatment) throws -> [String: Any] {
        [WatchManualTreatmentMessageKey.treatmentID: treatment.id.uuidString,
         WatchManualTreatmentMessageKey.treatment: try JSONEncoder().encode(treatment)]
    }

    private func queueURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchBasalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("WatchManualTreatments.v1.json")
    }

    func testBasalUsesWholePositiveUnitsAndInsulinMaximumOnBothDevices() throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        for amount in [1.0, 20, 200] {
            let basal = WatchManualTreatment(id: UUID(), recordedAt: at, kind: .basalInjection, amount: amount)
            XCTAssertTrue(basal.isValid(at: at))
            XCTAssertEqual(WatchManualTreatmentStore.decode(try envelope(basal), at: at), basal)
        }
        for amount in [0.0, -1, 0.5, 20.5, 200.1, 201, Double.nan, .infinity, -.infinity] {
            let invalid = WatchManualTreatment(id: UUID(), recordedAt: at, kind: .basalInjection, amount: amount)
            XCTAssertFalse(invalid.isValid(at: at))
            // Phone validation must also reject callers that bypass wire decoding.
            var outcome: WatchManualTreatmentStore.Outcome?
            WatchManualTreatmentStore.save(invalid, coreDataManager: core, at: at) { outcome = $0 }
            XCTAssertEqual(outcome, .invalid)
            if amount.isFinite {
                XCTAssertNil(WatchManualTreatmentStore.decode(try envelope(invalid), at: at))
            }
        }
        XCTAssertTrue(WatchManualTreatmentKind.insulin.isValidAmount(1.25))
        XCTAssertEqual(try core.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest()).count, 0)
    }

    func testBasalLostReceiptAndRestartUseUUIDWithoutCollapsingSeparateInjections() throws {
        let storeURL = try queueURL().deletingLastPathComponent().appendingPathComponent("treatments.sqlite")
        let first = WatchManualTreatment(id: UUID(), recordedAt: at, kind: .basalInjection, amount: 20)
        let second = WatchManualTreatment(id: UUID(), recordedAt: at, kind: .basalInjection, amount: 20)
        let watchQueue = try queueURL()
        try WatchManualTreatmentQueue.persist([first, second], to: watchQueue)
        let phone = try CoreDataManager(testModelName: ConstantsCoreData.modelName, persistentStoreURL: storeURL)
        let saved = expectation(description: "durable basal saved")
        WatchManualTreatmentStore.save(first, coreDataManager: phone, at: at) { outcome in
            XCTAssertEqual(outcome, .stored)
            saved.fulfill()
        }
        wait(for: [saved], timeout: 5)
        try phone.disconnectPersistentStoresForTesting()
        let restartedPhone = try CoreDataManager(testModelName: ConstantsCoreData.modelName, persistentStoreURL: storeURL)
        let restartedWatch = try WatchManualTreatmentQueue.load(from: watchQueue)
        XCTAssertEqual(restartedWatch, [first, second])
        for treatment in restartedWatch {
            let delivered = expectation(description: "basal delivery \(treatment.id)")
            WatchManualTreatmentStore.save(treatment, coreDataManager: restartedPhone, at: at) { outcome in
                XCTAssertEqual(outcome, treatment.id == first.id ? .alreadyStored : .stored)
                delivered.fulfill()
            }
            wait(for: [delivered], timeout: 5)
        }
        let rows = try restartedPhone.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.compactMap(\.watchSourceUUID)), Set([first.id.uuidString, second.id.uuidString]))
        for row in rows {
            XCTAssertEqual(row.treatmentType, .BasalInjection)
            XCTAssertEqual(row.value, 20)
            XCTAssertEqual(row.date, at)
            XCTAssertEqual(row.enteredBy, "xDrip4iOS Watch")
            XCTAssertTrue(row.isWatchLocalOnly)
            XCTAssertFalse(row.isHealthKitImported)
        }
        XCTAssertTrue(TreatmentEntryAccessor(coreDataManager: restartedPhone)
            .getLatestTreatmentsForNightscout(limit: 10).isEmpty)
        let receipt = try XCTUnwrap(WatchManualTreatmentReceipt([
            WatchManualTreatmentMessageKey.treatmentID: first.id.uuidString,
            WatchManualTreatmentMessageKey.stored: true]))
        let remaining = WatchManualTreatmentQueue.applying(receipt, to: restartedWatch)
        try WatchManualTreatmentQueue.persist(remaining, to: watchQueue)
        XCTAssertEqual(try WatchManualTreatmentQueue.load(from: watchQueue), [second])
        // A replayed receipt cannot delete another injection at the same time and amount.
        XCTAssertEqual(WatchManualTreatmentQueue.applying(receipt, to: remaining), [second])
        try restartedPhone.disconnectPersistentStoresForTesting()
    }

    @MainActor
    func testStoredWatchBasalIsExcludedFromTherapyMetricsAndForecastInputs() async throws {
        let core = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let basal = WatchManualTreatment(id: UUID(), recordedAt: at, kind: .basalInjection, amount: 20)
        let outcome: WatchManualTreatmentStore.Outcome = await withCheckedContinuation { continuation in
            WatchManualTreatmentStore.save(basal, coreDataManager: core, at: at) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(outcome, .stored)
        let manager = TherapyMetricsManager()
        manager.configure(coreDataManager: core, externalStatus: { nil })
        let policy = DataFlowPolicy(isMaster: true, followerDataSource: .careLink,
            therapyDataSourceSelection: .none, nightscoutEnabled: false,
            masterUploadsGlucoseToNightscout: false, followerUploadsGlucoseToNightscout: false,
            nightscoutFollowType: .none)
        let settings = TherapyModelSettings()
        let start = at.addingTimeInterval(-600 * 60)
        let reference = at
        let fetched: [TherapyTreatment]? = await withCheckedContinuation { continuation in
            // Match the adapter's queue boundary. The configured manager owns its Core Data
            // queue/cache locks; policy is immutable for this one awaited fixture read.
            DispatchQueue.global().async(execute: DispatchWorkItem {
                continuation.resume(returning: manager.treatments(from: start, to: reference,
                    policy: policy, settings: settings))
            })
        }
        let entries = try XCTUnwrap(fetched)
        XCTAssertTrue(entries.isEmpty)
        // A basal-only window must retain the existing no-bolus/no-carb presentation,
        // not make IOB/COB visible or fabricate a numerical zero.
        for isIOB in [true, false] {
            let metric = TherapyMetricsManager.localMetric(entries: entries, isIOB: isIOB,
                date: at, settings: settings)
            XCTAssertEqual(metric.reason, .noTreatments)
            XCTAssertNil(metric.amount)
            XCTAssertNil(metric.value(at: at))
            XCTAssertFalse(metric.isVisible(at: at))
        }
        let forecastInputs = GlucoseForecastDataAdapter.treatmentsKnownAtReference(entries,
            from: start, referenceDate: at)
        XCTAssertTrue(forecastInputs.isEmpty)
        let samples = stride(from: -30, through: 0, by: 5).map {
            GlucoseForecastSample(date: at.addingTimeInterval(Double($0 * 60)), glucoseMgdl: 100)
        }
        let result = GlucoseForecastEngine.predict(GlucoseForecastInput(glucose: samples,
            treatments: forecastInputs, settings: settings, sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, horizonMinutes: 120, now: at))
        XCTAssertNil(result.reason)
        XCTAssertTrue(result.points.allSatisfy { abs($0.glucoseMgdl - 100) < 1e-9 })
    }

    func testUnknownIncomingTypeIsRejectedWithoutFalseStoredReceipt() throws {
        let known = WatchManualTreatment(id: UUID(), recordedAt: at, kind: .insulin, amount: 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(known)) as? [String: Any])
        object["kind"] = "futureMedication"
        let message: [String: Any] = [
            WatchManualTreatmentMessageKey.treatmentID: known.id.uuidString,
            WatchManualTreatmentMessageKey.treatment: try JSONSerialization.data(withJSONObject: object)]
        XCTAssertNil(WatchManualTreatmentStore.decode(message, at: at))
        XCTAssertEqual(WatchManualTreatmentStore.rejectionReason(message), "unsupportedTreatmentKind")
        let rejected = try XCTUnwrap(WatchManualTreatmentReceipt([
            WatchManualTreatmentMessageKey.treatmentID: known.id.uuidString,
            WatchManualTreatmentMessageKey.stored: false,
            WatchManualTreatmentMessageKey.error: WatchManualTreatmentStore.rejectionReason(message)]))
        XCTAssertFalse(rejected.stored)
        XCTAssertTrue(rejected.failureMessage.contains("opdatér begge apps"))
        XCTAssertTrue(rejected.failureMessage.contains("bevaret"))
        XCTAssertEqual(WatchManualTreatmentQueue.applying(rejected, to: [known]), [known])
        XCTAssertNil(WatchManualTreatmentReceipt([WatchManualTreatmentMessageKey.stored: true]))
    }

    /// Mirror the published pre-basal wire model: an older iPhone cannot decode basal and
    /// replies stored=false/invalidTreatment. The new Watch keeps the original UUID/payload.
    func testNewWatchBasalWithOldPhoneFormatIsVisibleFailureAndDurableRetry() throws {
        enum LegacyKind: String, Codable { case insulin, carbs }
        struct LegacyEntry: Codable {
            let id: UUID
            let recordedAt: Date
            let kind: LegacyKind
            let amount: Double
        }
        let basal = WatchManualTreatment(id: UUID(), recordedAt: at, kind: .basalInjection, amount: 20)
        XCTAssertThrowsError(try JSONDecoder().decode(LegacyEntry.self, from: JSONEncoder().encode(basal)))
        let oldFailure = try XCTUnwrap(WatchManualTreatmentReceipt([
            WatchManualTreatmentMessageKey.treatmentID: basal.id.uuidString,
            WatchManualTreatmentMessageKey.stored: false,
            WatchManualTreatmentMessageKey.error: "invalidTreatment"]))
        XCTAssertTrue(oldFailure.failureMessage.contains("opdatér begge apps"))
        let url = try queueURL()
        try WatchManualTreatmentQueue.persist([basal], to: url)
        let before = try Data(contentsOf: url)
        XCTAssertEqual(WatchManualTreatmentQueue.applying(oldFailure, to: [basal]), [basal])
        XCTAssertEqual(try WatchManualTreatmentQueue.load(from: url), [basal])
        XCTAssertEqual(try Data(contentsOf: url), before)
        for kind in [LegacyKind.insulin, .carbs] {
            let old = LegacyEntry(id: UUID(), recordedAt: at, kind: kind, amount: 2.5)
            let new = try JSONDecoder().decode(WatchManualTreatment.self, from: JSONEncoder().encode(old))
            XCTAssertEqual(new.kind.rawValue, kind.rawValue)
            XCTAssertEqual(new.amount, 2.5)
            let roundTrip = try JSONDecoder().decode(LegacyEntry.self, from: JSONEncoder().encode(new))
            XCTAssertEqual(roundTrip.kind, old.kind)
            XCTAssertEqual(roundTrip.id, old.id)
        }
    }

    func testFutureOrCorruptQueueCannotBeOverwrittenOrCleared() throws {
        let known = WatchManualTreatment(id: UUID(), recordedAt: at, kind: .carbs, amount: 10)
        var future = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(known)) as? [String: Any])
        future["kind"] = "futureMedication"
        let knownObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(known))
        for data in [try JSONSerialization.data(withJSONObject: [knownObject, future]), Data("[{".utf8)] {
            let url = try queueURL()
            try data.write(to: url)
            XCTAssertThrowsError(try WatchManualTreatmentQueue.load(from: url))
            XCTAssertThrowsError(try WatchManualTreatmentQueue.persist([], to: url))
            XCTAssertThrowsError(try WatchManualTreatmentQueue.persist([known], to: url))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    func testKindLabelsAndUnitsKeepBasalAndBolusDistinct() {
        XCTAssertEqual(WatchManualTreatmentKind.insulin.title, "Bolus (hurtigtvirkende)")
        XCTAssertEqual(WatchManualTreatmentKind.basalInjection.title, "Basal (langtidsvirkende)")
        XCTAssertEqual(WatchManualTreatmentKind.carbs.unit, "g")
        for kind in [WatchManualTreatmentKind.insulin, .basalInjection] {
            XCTAssertEqual(kind.unit, "U")
            let entry = WatchManualTreatment(id: UUID(), recordedAt: at, kind: kind, amount: 20)
            XCTAssertTrue(entry.displayDescription.contains(kind == .insulin ? "bolus" : "basal"))
            XCTAssertTrue(entry.displayDescription.contains("20"))
        }
    }

    @MainActor
    func testBasalBackupRestorePreservesTypeLocalOnlyAndDistinctUUIDs() async throws {
        let source = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let ids = [UUID().uuidString, UUID().uuidString]
        for id in ids {
            let row = TreatmentEntry(date: at, value: 20, treatmentType: .BasalInjection,
                nightscoutEventType: nil, enteredBy: "xDrip4iOS Watch",
                nsManagedObjectContext: source.mainManagedObjectContext)
            row.watchSourceUUID = id
        }
        XCTAssertTrue(source.saveChangesSynchronously())
        let exporter = BackupService(coreDataManager: source)
        let archive = try await exporter.createBackup(options: BackupOptions(
            includesSettings: false, includesAccounts: false, includesBgReadings: false, includesTreatments: true))
        defer { try? FileManager.default.removeItem(at: archive.url) }
        let inspection = try exporter.inspectBackup(at: archive.url)
        let destination = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let importer = BackupService(coreDataManager: destination)
        for _ in 0..<2 {
            _ = try await importer.restore(inspection: inspection, mode: .keepCurrent,
                restoresSettings: false, restoredAccountCategories: [])
        }
        let rows = try destination.mainManagedObjectContext.fetch(TreatmentEntry.fetchRequest())
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.compactMap(\.watchSourceUUID)), Set(ids))
        XCTAssertTrue(rows.allSatisfy { $0.treatmentType == .BasalInjection && $0.value == 20 && $0.isWatchLocalOnly })
        XCTAssertTrue(TreatmentEntryAccessor(coreDataManager: destination)
            .getLatestTreatmentsForNightscout(limit: 10).isEmpty)
    }
}
