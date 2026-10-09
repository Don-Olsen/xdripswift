import BackgroundTasks
import XCTest
@testable import xdrip

final class GlucoseForecastMLBackgroundSchedulerTests: XCTestCase {
    func testInterruptedRunRetriesSoonerThanAnOrdinaryFailure() {
        let policy = GlucoseForecastMLBackgroundSchedulePolicy.self

        XCTAssertEqual(policy.retryInterval(for: .interrupted), 60 * 60)
        XCTAssertEqual(policy.retryInterval(for: .failed), 24 * 60 * 60)
        XCTAssertEqual(policy.retryInterval(for: .completed),
            GlucoseForecastMLChronology.modelAgeLimit + 1)
        XCTAssertLessThan(policy.retryInterval(for: .interrupted), policy.retryInterval(for: .failed))
    }

    @MainActor func testContextFingerprintChangesWithSourceOrTherapySettings() {
        let settings = TherapyModelSettings()
        let baseline = GlucoseForecastMLContext(sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, settings: settings,
            sourceSignature: "source-a")!
        let changedSource = GlucoseForecastMLContext(sensitivityMgdlPerUnit: 40,
            carbohydrateRatioGramsPerUnit: 10, settings: settings,
            sourceSignature: "source-b")!
        let changedSensitivity = GlucoseForecastMLContext(sensitivityMgdlPerUnit: 41,
            carbohydrateRatioGramsPerUnit: 10, settings: settings,
            sourceSignature: "source-a")!

        let fingerprint = GlucoseForecastMLBackgroundScheduler.fingerprint(for: baseline)
        XCTAssertNotNil(fingerprint)
        XCTAssertEqual(fingerprint, GlucoseForecastMLBackgroundScheduler.fingerprint(for: baseline))
        XCTAssertNotEqual(fingerprint, GlucoseForecastMLBackgroundScheduler.fingerprint(for: changedSource))
        XCTAssertNotEqual(fingerprint, GlucoseForecastMLBackgroundScheduler.fingerprint(for: changedSensitivity))
    }

    func testRepeatedForegroundPreparationKeepsEarlierEligibleDateWithoutBypassingCooldown() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let day: TimeInterval = 24 * 60 * 60
        let policy = GlucoseForecastMLBackgroundSchedulePolicy.self

        XCTAssertEqual(policy.desiredDate(requested: now.addingTimeInterval(7 * day),
            existing: now.addingTimeInterval(6 * day), notBefore: nil),
            now.addingTimeInterval(6 * day))
        XCTAssertEqual(policy.desiredDate(requested: now.addingTimeInterval(5 * day),
            existing: now.addingTimeInterval(7 * day), notBefore: nil),
            now.addingTimeInterval(5 * day))
        XCTAssertEqual(policy.desiredDate(requested: now.addingTimeInterval(5 * day),
            existing: now.addingTimeInterval(3 * day),
            notBefore: now.addingTimeInterval(6 * day)),
            now.addingTimeInterval(6 * day))
    }

    @MainActor func testPendingTaskMustHonorChargerOfflineAndEarliestAllowedDate() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let request = BGProcessingTaskRequest(
            identifier: GlucoseForecastMLBackgroundScheduler.taskIdentifier)
        request.earliestBeginDate = now.addingTimeInterval(2 * 24 * 60 * 60)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = false
        let policy = GlucoseForecastMLBackgroundSchedulePolicy.self

        XCTAssertTrue(policy.canKeepPending(GlucoseForecastMLPendingRequest(request),
            desired: now.addingTimeInterval(3 * 24 * 60 * 60), notBefore: now))
        XCTAssertFalse(policy.canKeepPending(GlucoseForecastMLPendingRequest(request),
            desired: now.addingTimeInterval(3 * 24 * 60 * 60),
            notBefore: now.addingTimeInterval(3 * 24 * 60 * 60)))
        request.requiresNetworkConnectivity = true
        XCTAssertFalse(policy.canKeepPending(GlucoseForecastMLPendingRequest(request),
            desired: now.addingTimeInterval(3 * 24 * 60 * 60), notBefore: now))
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        XCTAssertFalse(policy.canKeepPending(GlucoseForecastMLPendingRequest(request),
            desired: now.addingTimeInterval(3 * 24 * 60 * 60), notBefore: now))
    }
}
