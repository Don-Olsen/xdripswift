import XCTest
import CoreData
@testable import xdrip

final class LibreWatchValuePipelineTests: XCTestCase {
    private let receivedAt = Date(timeIntervalSince1970: 1_788_333_200)

    override func tearDown() {
        clearPhoneLibreParserCache()
        super.tearDown()
    }

    func testSameDecryptedFrameProducesSameNativeValueOnWatchAndIPhone() throws {
        let frame = decryptedFrame(currentRaw: 847, previousRaw: 830)
        let watchReading = try Libre2WatchDirectAlgorithms.parseDirectReading(
            decryptedData: frame,
            parameters: watchAlgorithmParameters,
            receivedAt: receivedAt
        )

        let phoneReading = phoneParsedValue(frame: frame, parameters: phoneAlgorithmParameters)

        XCTAssertEqual(watchReading.rawGlucose, 847)
        XCTAssertEqual(watchReading.previousRawGlucose, 830)
        XCTAssertEqual(watchReading.nativeGlucoseMGDL, phoneReading, accuracy: 0.000_001)
    }

    func testRawGlucoseTimesLibreMultiplierMatchesNormalIPhoneXDripInput() throws {
        let frame = decryptedFrame(currentRaw: 847, previousRaw: 830)
        let watchReading = try Libre2WatchDirectAlgorithms.parseDirectReading(
            decryptedData: frame,
            parameters: watchAlgorithmParameters,
            receivedAt: receivedAt
        )
        let payload = watchReading.payload(
            sessionID: session.id,
            valueDomain: .xDripRawGlucose,
            calibrationRevision: 10
        )

        let phoneInput = phoneParsedValue(frame: frame, parameters: nil)

        XCTAssertEqual(payload.xDripCalibrationInput, Double(847) * ConstantsBloodGlucose.libreMultiplier)
        XCTAssertEqual(payload.xDripCalibrationInput, phoneInput, accuracy: 0.000_001)
    }

    func testWatchAndIPhoneFinalValuesMatchForFixedAndNonFixedSlope() throws {
        let reading = payload(raw: 900, previousRaw: 875, domain: .xDripRawGlucose)

        for calibrationType in [LibreWatchCalibrationType.fixedSlope, .nonFixedSlope] {
            let snapshot = calibration(
                type: calibrationType,
                slope: 1.08,
                intercept: -7.5
            )
            let iPhoneDivider = calibrationType == .fixedSlope
                ? Libre1Calibrator().rawValueDivider
                : Libre1NonFixedSlopeCalibrator().rawValueDivider
            let expectedIPhoneValue = iphoneCalibratedValue(
                input: reading.xDripCalibrationInput,
                slope: snapshot.slope,
                intercept: snapshot.intercept,
                divider: iPhoneDivider
            )

            XCTAssertEqual(snapshot.rawValueDivider, iPhoneDivider)
            let watchValue = try XCTUnwrap(snapshot.displayedGlucose(for: reading))
            XCTAssertEqual(watchValue, expectedIPhoneValue, accuracy: 0.000_001)
        }
    }

    func testFactoryValueUsesNativeDomainWithoutSecondCalibration() throws {
        let reading = payload(
            native: 112.4,
            previousNative: 110.2,
            raw: 950,
            previousRaw: 930,
            domain: .factoryNativeMGDL
        )
        let snapshot = calibration(type: .factoryCalibrated, slope: 1, intercept: 0)

        let watchValue = try XCTUnwrap(snapshot.displayedGlucose(for: reading))
        XCTAssertEqual(watchValue, 112.4, accuracy: 0.000_001)
        XCTAssertEqual(reading.sourceValue(for: snapshot.requiredValueDomain), 112.4, accuracy: 0.000_001)
        XCTAssertNotEqual(watchValue, reading.xDripCalibrationInput)
    }

    func testNativeFourPointSevenDoesNotBecomeLowWithXDripCalibration() throws {
        let reading = payload(
            native: 4.7 / ConstantsBloodGlucose.mgDlToMmoll,
            previousNative: 82,
            raw: 720,
            previousRaw: 700,
            domain: .xDripRawGlucose
        )
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let iPhoneDivider = Libre1Calibrator().rawValueDivider

        let displayed = try XCTUnwrap(snapshot.displayedGlucose(for: reading))
        XCTAssertEqual(displayed, Double(720) * ConstantsBloodGlucose.libreMultiplier / iPhoneDivider, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(displayed, 40)
        XCTAssertEqual(displayed * ConstantsBloodGlucose.mgDlToMmoll, 4.7, accuracy: 0.02)

        let formerWrongDomainResult = iphoneCalibratedValue(
            input: reading.nativeGlucoseMGDL,
            slope: 1,
            intercept: 0,
            divider: 1_000
        )
        XCTAssertEqual(formerWrongDomainResult, 38)
        XCTAssertNotEqual(displayed, formerWrongDomainResult)
    }

    func testTrendAndDeltaUseSelectedDomainWithoutIntercept() throws {
        let reading = payload(raw: 900, previousRaw: 850, domain: .xDripRawGlucose)
        let snapshot = calibration(type: .nonFixedSlope, slope: 1.2, intercept: 45)
        let sourceDifference = Double(60) * ConstantsBloodGlucose.libreMultiplier

        let expectedTrend = 1.2 * (
            (Double(900 - 850) * ConstantsBloodGlucose.libreMultiplier) / 2
        ) / 1_000
        let expectedDelta = 1.2 * sourceDifference / 1_000

        let watchTrend = try XCTUnwrap(snapshot.displayedTrend(for: reading))
        let watchDelta = try XCTUnwrap(snapshot.displayedDelta(sourceDelta: sourceDifference))
        XCTAssertEqual(watchTrend, expectedTrend, accuracy: 0.000_001)
        XCTAssertEqual(watchDelta, expectedDelta, accuracy: 0.000_001)
        XCTAssertNotEqual(watchTrend, expectedTrend + snapshot.intercept)
        XCTAssertNotEqual(watchDelta, expectedDelta + snapshot.intercept)
    }

    func testOldOrIncompletePayloadCannotProduceOrPersistFalseLow() throws {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let oldVersion = payload(
            version: 1,
            raw: 720,
            previousRaw: 700,
            domain: .xDripRawGlucose
        )
        let incomplete = payload(
            raw: 0,
            previousRaw: 700,
            domain: .xDripRawGlucose
        )

        XCTAssertFalse(oldVersion.isValid(for: snapshot))
        XCTAssertFalse(incomplete.isValid(for: snapshot))
        XCTAssertNil(snapshot.displayedGlucose(for: oldVersion))
        XCTAssertNil(snapshot.displayedGlucose(for: incomplete))

        let legacyJSON = try JSONSerialization.data(withJSONObject: [
            "id": UUID().uuidString,
            "sessionID": session.id.uuidString,
            "glucoseMGDL": 84.7,
            "sensorTimeInMinutes": 1_000,
            "receivedAt": receivedAt.timeIntervalSinceReferenceDate
        ])
        XCTAssertNil(try? JSONDecoder().decode(LibreWatchDirectReadingPayload.self, from: legacyJSON))

        let defaults = isolatedDefaults()
        defaults.set(legacyJSON, forKey: LibreWatchMessageKey.legacyPersistedReading)
        XCTAssertNil(LibreWatchSessionStore.loadReading(defaults: defaults))
        XCTAssertNil(defaults.data(forKey: LibreWatchMessageKey.legacyPersistedReading))
    }

    func testCalibrationAndAlgorithmStayStableAcrossOwnershipCycle() {
        let defaults = isolatedDefaults()
        let snapshot = calibration(type: .nonFixedSlope, slope: 1.17, intercept: -11)
        LibreWatchSessionStore.saveSession(session, defaults: defaults)
        LibreWatchSessionStore.saveCalibration(snapshot, defaults: defaults)

        var ownership = LibreWatchOwnership.iphone
        for next in [
            LibreWatchOwnership.releasingToWatch,
            .watch,
            .watch,
            .releasingToPhone,
            .iphone
        ] {
            XCTAssertTrue(ownership.canTransition(to: next))
            ownership = next
            LibreWatchSessionStore.saveOwnership(ownership, defaults: defaults)
            XCTAssertEqual(LibreWatchSessionStore.loadCalibration(defaults: defaults), snapshot)
            XCTAssertEqual(
                LibreWatchSessionStore.loadCalibration(defaults: defaults)?.requiredValueDomain,
                .xDripRawGlucose
            )
        }
    }

    func testReadingOlderThanThreeMinutesKeepsValueButHidesTrendAndDelta() throws {
        let reading = payload(raw: 900, previousRaw: 875, domain: .xDripRawGlucose)
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let sourceDelta = Double(25) * ConstantsBloodGlucose.libreMultiplier

        let current = try XCTUnwrap(snapshot.presentation(
            for: reading,
            sourceDelta: sourceDelta,
            at: receivedAt.addingTimeInterval(179)
        ))
        let stale = try XCTUnwrap(snapshot.presentation(
            for: reading,
            sourceDelta: sourceDelta,
            at: receivedAt.addingTimeInterval(181)
        ))

        XCTAssertFalse(current.isStale)
        XCTAssertNotNil(current.trendMGDLPerMinute)
        XCTAssertNotNil(current.deltaMGDL)
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.glucoseMGDL, current.glucoseMGDL, accuracy: 0.000_001)
        XCTAssertNil(stale.trendMGDLPerMinute)
        XCTAssertNil(stale.deltaMGDL)
    }

    func testDirectDeltaAcceptsThreeMinuteBoundaryButRejectsLongSuspensionGap() throws {
        let snapshot = calibration(type: .fixedSlope, slope: 1.1, intercept: 20)
        let previous = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: receivedAt
        )
        let boundary = payload(
            raw: 820,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: receivedAt.addingTimeInterval(LibreWatchDirectDeltaPolicy.maximumGap)
        )
        let afterSuspension = payload(
            raw: 830,
            previousRaw: 820,
            domain: .xDripRawGlucose,
            sensorTime: 1_002,
            at: receivedAt.addingTimeInterval(LibreWatchDirectDeltaPolicy.maximumGap + 0.001)
        )

        XCTAssertEqual(
            try XCTUnwrap(LibreWatchDirectDeltaPolicy.sourceDelta(
                current: boundary,
                previous: previous,
                calibration: snapshot
            )),
            boundary.xDripCalibrationInput - previous.xDripCalibrationInput,
            accuracy: 0.000_001
        )
        XCTAssertNil(LibreWatchDirectDeltaPolicy.sourceDelta(
            current: afterSuspension,
            previous: previous,
            calibration: snapshot
        ))
    }

    func testDirectDeltaRejectsWrongSessionDomainRevisionAndSensorOrder() {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0, revision: 10)
        let previous = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: receivedAt,
            revision: 10
        )
        let wrongSession = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: receivedAt.addingTimeInterval(60),
            sessionID: UUID()
        )
        let wrongDomain = payload(
            raw: 810,
            previousRaw: 800,
            domain: .factoryNativeMGDL,
            sensorTime: 1_001,
            at: receivedAt.addingTimeInterval(60)
        )
        let wrongRevision = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: receivedAt.addingTimeInterval(60),
            revision: 9
        )
        let nonIncreasingSensorTime = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: receivedAt.addingTimeInterval(60)
        )

        for current in [wrongSession, wrongDomain, wrongRevision, nonIncreasingSensorTime] {
            XCTAssertNil(LibreWatchDirectDeltaPolicy.sourceDelta(
                current: current,
                previous: previous,
                calibration: snapshot
            ))
        }
    }

    func testFortyEightMinuteGapFromNinePointSevenToSixPointSevenHasNoDeltaButKeepsTrend() throws {
        let snapshot = calibration(type: .factoryCalibrated, slope: 1, intercept: 0)
        let previous = payload(
            native: 9.7 * ConstantsBloodGlucose.mmollToMgdl,
            previousNative: 9.6 * ConstantsBloodGlucose.mmollToMgdl,
            raw: 900,
            previousRaw: 890,
            domain: .factoryNativeMGDL,
            sensorTime: 1_000,
            at: receivedAt
        )
        let current = payload(
            native: 6.7 * ConstantsBloodGlucose.mmollToMgdl,
            previousNative: 6.6 * ConstantsBloodGlucose.mmollToMgdl,
            raw: 700,
            previousRaw: 690,
            domain: .factoryNativeMGDL,
            sensorTime: 1_048,
            at: receivedAt.addingTimeInterval(48 * 60)
        )

        let sourceDelta = LibreWatchDirectDeltaPolicy.sourceDelta(
            current: current,
            previous: previous,
            calibration: snapshot
        )
        let presentation = try XCTUnwrap(snapshot.presentation(
            for: current,
            sourceDelta: sourceDelta,
            at: current.receivedAt.addingTimeInterval(1)
        ))

        XCTAssertNil(sourceDelta)
        XCTAssertNil(presentation.deltaMGDL)
        XCTAssertNotNil(presentation.trendMGDLPerMinute)
    }

    func testActiveApplicationAllowsRecoveryWithoutExtendedRuntime() {
        XCTAssertTrue(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: true,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.shouldStartExtendedRuntime(
            userInitiatedTakeover: true,
            applicationIsActive: true,
            ownership: .watch,
            alreadyHasSession: false
        ))
    }

    func testInactiveApplicationAllowsRecoveryWhileExtendedRuntimeIsRunning() {
        XCTAssertTrue(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: false,
            extendedRuntimeIsRunning: true,
            ownership: .watch
        ))
    }

    func testInactiveWatchOwnerPreservesCoreBluetoothWithoutStartingTimedRecovery() {
        XCTAssertFalse(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: false,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(
            ownership: .watch
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.shouldStartExtendedRuntime(
            userInitiatedTakeover: false,
            applicationIsActive: true,
            ownership: .watch,
            alreadyHasSession: false
        ))
    }

    func testSystemAutoReconnectDoesNotStartParallelManualConnection() {
        let action = LibreWatchLifecyclePolicy.disconnectRecoveryAction(
            isDeliberate: false,
            systemIsReconnecting: true,
            ownership: .watch
        )

        XCTAssertEqual(action, .waitForSystemReconnect)
        XCTAssertNotEqual(action, .reconnectManually)
    }

    func testLongInactivePeriodPreservesEventDrivenRecoveryAfterForegroundRefresh() {
        XCTAssertFalse(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: false,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: true,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(
            ownership: .watch
        ))
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.disconnectRecoveryAction(
                isDeliberate: false,
                systemIsReconnecting: true,
                ownership: .watch
            ),
            .waitForSystemReconnect
        )
    }

    func testInactiveWatchOwnerAllowsOnlyOneManualConnectPerDisconnectDelivery() {
        let action = LibreWatchLifecyclePolicy.disconnectRecoveryAction(
            isDeliberate: false,
            systemIsReconnecting: false,
            ownership: .watch
        )
        var disconnectWasHandled = false
        var manualConnectCount = 0

        for _ in 0 ..< 2 {
            guard LibreWatchLifecyclePolicy.shouldHandleDisconnect(
                alreadyHandled: disconnectWasHandled
            ) else { continue }
            disconnectWasHandled = true
            if action == .reconnectManually {
                manualConnectCount += 1
            }
        }

        XCTAssertEqual(action, .reconnectManually)
        XCTAssertEqual(manualConnectCount, 1)
    }

    func testSuspendedWatchOwnerStartsNoFallbackTimerOrScanLoop() {
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.reconnectFallbackAction(
                deadline: receivedAt.addingTimeInterval(90),
                now: receivedAt.addingTimeInterval(300),
                applicationIsActive: false,
                extendedRuntimeIsRunning: false,
                ownership: .watch
            ),
            .noAdditionalWork
        )
        XCTAssertNil(LibreWatchLifecyclePolicy.noDataRecoveryDelay(
            applicationIsActive: false,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
    }

    func testReceivingSuspensionResumesBudgetWithoutImmediateBluetoothAction() throws {
        var timing = LibreWatchConnectionTiming()
        let firstFrameAt = receivedAt
        timing.receivedPacketOrEnabledNotifications(at: firstFrameAt)
        timing.recordReceivingProgress(
            at: firstFrameAt,
            timeout: 120,
            executionIsAvailable: true,
            monotonicTime: 1_000
        )
        let generation = timing.generation
        let beforeSuspension = try XCTUnwrap(timing.deadline)

        let suspendedAt = firstFrameAt.addingTimeInterval(30)
        XCTAssertTrue(timing.setExecutionAvailable(
            false,
            at: suspendedAt,
            monotonicTime: 1_030
        ))
        XCTAssertNil(timing.deadline)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(
                at: suspendedAt,
                monotonicTime: 1_030
            )),
            90,
            accuracy: 0.000_001
        )

        // Several wall-clock minutes without execution do not consume the paused allowance.
        let resumedAt = suspendedAt.addingTimeInterval(20 * 60)
        XCTAssertTrue(timing.setExecutionAvailable(
            true,
            at: resumedAt,
            monotonicTime: 2_500
        ))
        let resumed = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(timing.generation, generation)
        XCTAssertEqual(resumed.expiresAt, resumedAt.addingTimeInterval(90))
        XCTAssertFalse(timing.timeoutIsCurrent(
            beforeSuspension,
            ownership: .watch,
            cancelling: false,
            at: resumedAt,
            monotonicTime: 2_500
        ))
        XCTAssertFalse(timing.timeoutIsCurrent(
            resumed,
            ownership: .watch,
            cancelling: false,
            at: resumedAt,
            monotonicTime: 2_500
        ))
        let timeoutIsDue = timing.timeoutIsCurrent(
            resumed,
            ownership: .watch,
            cancelling: false,
            at: resumedAt,
            monotonicTime: 2_500
        )
        let recordedBluetoothActions: [LibreWatchExpiredPhaseAction] = timeoutIsDue
            ? [LibreWatchExpiredPhasePolicy.action(
                phase: timing.phase,
                peripheralState: .connected,
                ownership: .watch,
                cancellationIsActive: false
            )]
            : []
        XCTAssertTrue(recordedBluetoothActions.isEmpty) // no cancel, scan, or connect
    }

    func testValidFrameAfterResumeInvalidatesOldTimerBeforeDownstreamDecision() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        timing.recordReceivingProgress(
            at: receivedAt,
            timeout: 120,
            executionIsAvailable: true,
            monotonicTime: 100
        )
        XCTAssertTrue(timing.setExecutionAvailable(
            false,
            at: receivedAt.addingTimeInterval(20),
            monotonicTime: 120
        ))
        let resumedAt = receivedAt.addingTimeInterval(900)
        XCTAssertTrue(timing.setExecutionAvailable(
            true,
            at: resumedAt,
            monotonicTime: 900
        ))
        let resumeTimer = try XCTUnwrap(timing.deadline)

        var liveness = LibreWatchFrameLiveness()
        let frameAt = resumedAt.addingTimeInterval(61)
        let accepted = LibreWatchValidFramePolicy.record(
            liveness: &liveness,
            at: frameAt
        ) { _ in
            timing.receivedPacketOrEnabledNotifications(at: frameAt)
            timing.recordReceivingProgress(
                at: frameAt,
                timeout: 120,
                executionIsAvailable: true,
                monotonicTime: 961
            )
            return false // duplicate/out-of-order clinical payload
        }

        XCTAssertFalse(accepted)
        XCTAssertEqual(liveness.lastValidBLEFrameAt, frameAt)
        XCTAssertEqual(timing.dataExpectedSince, frameAt)
        XCTAssertFalse(timing.timeoutIsCurrent(
            resumeTimer,
            ownership: .watch,
            cancelling: false,
            at: resumeTimer.expiresAt,
            monotonicTime: try XCTUnwrap(resumeTimer.monotonicExpiresAt)
        ))
        XCTAssertNotEqual(timing.deadline?.token, resumeTimer.token)
    }

    func testReceivingBudgetExpiresOnceAndStillRequiresConfirmedCancellation() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        timing.recordReceivingProgress(
            at: receivedAt,
            timeout: 120,
            executionIsAvailable: true,
            monotonicTime: 1_000
        )
        let deadline = try XCTUnwrap(timing.deadline)
        let expiryUptime = try XCTUnwrap(deadline.monotonicExpiresAt)
        XCTAssertTrue(timing.timeoutIsCurrent(
            deadline,
            ownership: .watch,
            cancelling: false,
            at: deadline.expiresAt,
            monotonicTime: expiryUptime
        ))
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: timing.phase,
                peripheralState: .connected,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .beginControlledRecovery
        )

        timing.beginCancellation(at: deadline.expiresAt)
        XCTAssertFalse(timing.timeoutIsCurrent(
            deadline,
            ownership: .watch,
            cancelling: true,
            at: deadline.expiresAt,
            monotonicTime: expiryUptime
        ))
        XCTAssertFalse(timing.canStartBluetoothOperation)
        let cancellation = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(timing.finishCancellation(
            cancellation,
            ownership: .watch,
            returningToPhone: false,
            peripheralIsDisconnected: true,
            at: deadline.expiresAt.addingTimeInterval(1)
        ), .confirmedDisconnected)
        XCTAssertTrue(timing.canStartBluetoothOperation)
    }

    func testReceivingLifecycleChurnCannotRefillFiniteExecutionBudget() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        timing.recordReceivingProgress(
            at: receivedAt,
            timeout: 120,
            executionIsAvailable: true,
            monotonicTime: 0
        )
        let generation = timing.generation
        var wallTime = receivedAt
        var uptime: TimeInterval = 0

        for (cycle, consumed) in [30.0, 20.0, 20.0].enumerated() {
            wallTime = wallTime.addingTimeInterval(consumed)
            uptime += consumed
            XCTAssertTrue(timing.setExecutionAvailable(
                false,
                at: wallTime,
                monotonicTime: uptime
            ))
            wallTime = wallTime.addingTimeInterval(10_000)
            let remaining = try XCTUnwrap(timing.remainingExecutionTime(
                at: wallTime,
                monotonicTime: uptime
            ))
            XCTAssertEqual(remaining, 90 - TimeInterval(cycle * 20), accuracy: 0.000_001)
            XCTAssertFalse(timing.setExecutionAvailable(
                false,
                at: wallTime,
                monotonicTime: uptime
            ))
            XCTAssertTrue(timing.setExecutionAvailable(
                true,
                at: wallTime,
                monotonicTime: uptime
            ))
        }

        XCTAssertEqual(timing.generation, generation)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(
                at: wallTime.addingTimeInterval(20),
                monotonicTime: 90
            )),
            30,
            accuracy: 0.000_001
        )
    }

    func testInactiveAndBackgroundRemainDistinctWithoutClaimingTimerExecution() {
        XCTAssertTrue(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationState: .active,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationState: .inactive,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationState: .background,
            extendedRuntimeIsRunning: false,
            ownership: .watch
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationState: .inactive,
            extendedRuntimeIsRunning: true,
            ownership: .watch
        ))
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.receivingExecutionBudget(
                applicationState: .active,
                extendedRuntimeIsRunning: false
            ),
            120
        )
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.receivingExecutionBudget(
                applicationState: .background,
                extendedRuntimeIsRunning: true
            ),
            180
        )
    }

    func testExpiredReceivingTimerReconcilesSystemReconnectInsteadOfCancellingIt() {
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .receiving,
                peripheralState: .connecting,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .reconcileObservedLink
        )
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .notifications,
                peripheralState: .disconnected,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .reconcileObservedLink
        )
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .connection,
                peripheralState: .connected,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .beginGATTSetup
        )
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .connection,
                peripheralState: .connecting,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .beginControlledRecovery
        )
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .connection,
                peripheralState: .disconnected,
                ownership: .watch,
                cancellationIsActive: false
            ),
            .beginControlledRecovery,
            "an expired system reconnect must not reschedule the same zero-second deadline"
        )
        XCTAssertEqual(
            LibreWatchExpiredPhasePolicy.action(
                phase: .receiving,
                peripheralState: .connected,
                ownership: .iphone,
                cancellationIsActive: false
            ),
            .noAdditionalWork
        )
    }

    func testConnectionBudgetsStartWithSixtyForegroundOrNinetyRuntimeSeconds() throws {
        for (active, duration) in [(true, 60.0), (false, 90.0)] {
            var timing = LibreWatchConnectionTiming()
            timing.beginConnection(
                at: receivedAt,
                applicationIsActive: active,
                executionIsAvailable: true
            )
            let deadline = try XCTUnwrap(timing.deadline)
            XCTAssertEqual(deadline.expiresAt, receivedAt.addingTimeInterval(duration))
            XCTAssertEqual(
                try XCTUnwrap(timing.remainingExecutionTime(at: receivedAt)),
                duration,
                accuracy: 0.000_001
            )
            XCTAssertFalse(timing.timeoutIsCurrent(
                deadline, ownership: .watch, cancelling: false,
                at: receivedAt.addingTimeInterval(duration - 1)
            ))
            XCTAssertTrue(timing.timeoutIsCurrent(
                deadline, ownership: .watch, cancelling: false, at: deadline.expiresAt
            ))
        }
    }

    func testEighteenMinuteTwentyNineSecondSuspensionPreservesRemainingExecutionBudget() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(
            at: receivedAt,
            applicationIsActive: true,
            executionIsAvailable: true
        )
        let prePause = try XCTUnwrap(timing.deadline)
        let pausedAt = receivedAt.addingTimeInterval(12)

        XCTAssertTrue(timing.setExecutionAvailable(false, at: pausedAt))
        XCTAssertNil(timing.deadline)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: pausedAt)),
            48,
            accuracy: 0.000_001
        )
        XCTAssertFalse(timing.timeoutIsCurrent(
            prePause,
            ownership: .watch,
            cancelling: false,
            at: pausedAt.addingTimeInterval(18 * 60 + 29)
        ))

        let resumedAt = pausedAt.addingTimeInterval(18 * 60 + 29)
        XCTAssertTrue(timing.setExecutionAvailable(true, at: resumedAt))
        let resumed = try XCTUnwrap(timing.deadline)
        XCTAssertNotEqual(resumed.token, prePause.token)
        XCTAssertEqual(resumed.expiresAt, resumedAt.addingTimeInterval(48))
        XCTAssertFalse(timing.timeoutIsCurrent(
            resumed,
            ownership: .watch,
            cancelling: false,
            at: resumedAt.addingTimeInterval(47.999)
        ))
        XCTAssertTrue(timing.timeoutIsCurrent(
            resumed,
            ownership: .watch,
            cancelling: false,
            at: resumed.expiresAt
        ))
    }

    func testDocumentedBackgroundConnectingEpisodeStartsPausedAndDoesNotCancelOnWake() throws {
        var timing = LibreWatchConnectionTiming()
        let observedConnectingAt = receivedAt
        timing.beginConnection(
            at: observedConnectingAt,
            applicationIsActive: false,
            executionIsAvailable: false
        )
        let generation = timing.generation

        XCTAssertNil(timing.deadline)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: observedConnectingAt)),
            90,
            accuracy: 0.000_001
        )

        let foregroundWake = observedConnectingAt.addingTimeInterval(3 * 60 * 60)
        XCTAssertTrue(timing.setExecutionAvailable(true, at: foregroundWake))
        let armed = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(timing.generation, generation)
        XCTAssertEqual(armed.expiresAt, foregroundWake.addingTimeInterval(90))
        XCTAssertFalse(timing.timeoutIsCurrent(
            armed,
            ownership: .watch,
            cancelling: false,
            at: foregroundWake
        ))
    }

    func testOnlyCoreBluetoothCallbacksGrantEventDrivenBluetoothActions() {
        let callbackSources: [LibreWatchRecoveryReconcileSource] = [
            .centralStateUpdate,
            .stateRestoration,
            .didConnect,
            .didFailToConnect,
            .didDisconnect,
            .gattCallback,
            .bleNotification
        ]
        let lifecycleAndTimerSources: [LibreWatchRecoveryReconcileSource] = [
            .initialPreparation,
            .sceneActivation,
            .sceneDeactivation,
            .sceneInactive,
            .sceneBackground,
            .extendedRuntimeStarted,
            .extendedRuntimeWillExpire,
            .extendedRuntimeInvalidated,
            .healthTimer,
            .executionBudgetExpired,
            .cancellationWatchdog
        ]

        for source in callbackSources {
            XCTAssertTrue(source.grantsEventDrivenBluetoothAction, "Expected callback source: \(source)")
        }
        for source in lifecycleAndTimerSources {
            XCTAssertFalse(source.grantsEventDrivenBluetoothAction, "Expected passive source: \(source)")
        }
    }

    func testRepeatedWakeTransitionsDoNotRefillOrMoveActiveBudget() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(
            at: receivedAt,
            applicationIsActive: false,
            executionIsAvailable: true
        )
        let generation = timing.generation
        let pausedAt = receivedAt.addingTimeInterval(20)
        XCTAssertTrue(timing.setExecutionAvailable(false, at: pausedAt))
        XCTAssertFalse(timing.setExecutionAvailable(false, at: pausedAt.addingTimeInterval(300)))
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: pausedAt.addingTimeInterval(300))),
            70,
            accuracy: 0.000_001
        )

        let resumedAt = pausedAt.addingTimeInterval(600)
        XCTAssertTrue(timing.setExecutionAvailable(true, at: resumedAt))
        let activeDeadline = try XCTUnwrap(timing.deadline)
        XCTAssertFalse(timing.setExecutionAvailable(true, at: resumedAt.addingTimeInterval(10)))
        XCTAssertEqual(timing.deadline, activeDeadline)
        XCTAssertEqual(timing.generation, generation)

        let secondPause = resumedAt.addingTimeInterval(25)
        XCTAssertTrue(timing.setExecutionAvailable(false, at: secondPause))
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: secondPause)),
            45,
            accuracy: 0.000_001
        )
    }

    func testPrePauseTimerIsStaleEvenWhenPauseAndResumeShareTimestamp() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(
            at: receivedAt,
            applicationIsActive: true,
            executionIsAvailable: true
        )
        let old = try XCTUnwrap(timing.deadline)
        let transitionAt = receivedAt.addingTimeInterval(10)
        XCTAssertTrue(timing.setExecutionAvailable(false, at: transitionAt))
        XCTAssertTrue(timing.setExecutionAvailable(true, at: transitionAt))
        let current = try XCTUnwrap(timing.deadline)

        XCTAssertNotEqual(old.token, current.token)
        XCTAssertEqual(current.expiresAt, old.expiresAt)
        XCTAssertFalse(timing.timeoutIsCurrent(
            old,
            ownership: .watch,
            cancelling: false,
            at: old.expiresAt
        ))
        XCTAssertTrue(timing.timeoutIsCurrent(
            current,
            ownership: .watch,
            cancelling: false,
            at: current.expiresAt
        ))
    }

    func testLegacyDisconnectWithoutModernCallbackIsHandled() throws {
        var gate = LibreWatchLegacyDisconnectGate()
        let pending = try XCTUnwrap(gate.scheduleLegacy())
        XCTAssertTrue(gate.accept(legacyToken: pending))
        XCTAssertTrue(gate.handled)
        XCTAssertNil(gate.pendingToken)
    }

    func testModernDisconnectCancelsPendingLegacyFallback() throws {
        var gate = LibreWatchLegacyDisconnectGate()
        let pending = try XCTUnwrap(gate.scheduleLegacy())
        XCTAssertTrue(gate.accept())
        XCTAssertNil(gate.pendingToken)
        XCTAssertFalse(gate.accept(legacyToken: pending))
    }

    func testBothDisconnectCallbacksProduceOnlyOneRecoveryInEitherOrder() throws {
        for modernFirst in [true, false] {
            var gate = LibreWatchLegacyDisconnectGate()
            let pending = try XCTUnwrap(gate.scheduleLegacy())
            let deliveries: [UUID?] = modernFirst ? [nil, pending] : [pending, nil]
            var handledCount = 0
            for token in deliveries {
                if gate.accept(legacyToken: token) { handledCount += 1 }
            }
            XCTAssertEqual(handledCount, 1)
            XCTAssertNil(gate.scheduleLegacy())
        }
    }

    func testDidConnectCancelsOldLegacyCallbackButAllowsTheNextRealDisconnect() throws {
        var gate = LibreWatchLegacyDisconnectGate()
        let old = try XCTUnwrap(gate.scheduleLegacy())
        gate.reset() // Accepted didConnect.
        let next = try XCTUnwrap(gate.scheduleLegacy())
        XCTAssertFalse(gate.accept(legacyToken: old))
        XCTAssertEqual(gate.pendingToken, next)
        XCTAssertTrue(gate.accept(legacyToken: next))
    }

    func testReceivingThenObservedConnectingWithoutAnyDisconnectCreatesOneDeadline() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        // The real failure: receiving with no disconnect callback and NO pre-created deadline.
        XCTAssertEqual(timing.phase, .receiving)
        XCTAssertNil(timing.deadline)
        let observedAt = receivedAt.addingTimeInterval(93)
        XCTAssertTrue(timing.observeLink(
            connected: false, connecting: true, hasReceptionState: true,
            at: observedAt, applicationIsActive: true
        ))
        let deadline = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(deadline.expiresAt, observedAt.addingTimeInterval(60))
        XCTAssertEqual(timing.phase, .connection)
        XCTAssertNil(timing.dataExpectedSince)
        XCTAssertFalse(timing.setupInProgress)
        XCTAssertFalse(timing.canStartBluetoothOperation)
        for seconds in [1.0, 20.0, 80.0] {
            XCTAssertFalse(timing.observeLink(
                connected: false, connecting: true, hasReceptionState: false,
                at: observedAt.addingTimeInterval(seconds), applicationIsActive: false
            ))
            XCTAssertEqual(timing.deadline, deadline)
        }
    }

    func testDisconnectedOrDisconnectingObservationClearsOldSetupOnlyOnce() {
        var timing = LibreWatchConnectionTiming()
        timing.beginSetup(at: receivedAt)
        XCTAssertTrue(timing.observeLink(
            connected: false, connecting: false, hasReceptionState: true,
            at: receivedAt.addingTimeInterval(5), applicationIsActive: false
        ))
        XCTAssertNil(timing.deadline)
        XCTAssertNil(timing.dataExpectedSince)
        XCTAssertFalse(timing.setupInProgress)
        XCTAssertFalse(timing.observeLink(
            connected: false, connecting: false, hasReceptionState: false,
            at: receivedAt.addingTimeInterval(6), applicationIsActive: true
        ))
    }

    func testDidConnectEndsConnectionTimeoutAndStartsFreshGATTIndependentOfOldPacket() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        timing.observeLink(
            connected: false, connecting: true, hasReceptionState: true,
            at: receivedAt.addingTimeInterval(93), applicationIsActive: true
        )
        let oldConnection = try XCTUnwrap(timing.deadline)
        let connectedAt = receivedAt.addingTimeInterval(600)
        timing.beginSetup(at: connectedAt) // didConnect wins before queued timeout cancellation.
        let setup = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(setup.expiresAt, connectedAt.addingTimeInterval(60))
        XCTAssertFalse(timing.timeoutIsCurrent(
            oldConnection, ownership: .watch, cancelling: false, at: connectedAt
        ))
        XCTAssertFalse(timing.timeoutIsCurrent(
            setup, ownership: .watch, cancelling: false, at: connectedAt.addingTimeInterval(13)
        ))
        XCTAssertFalse(timing.noDataIsOverdue(
            lastPacketAt: receivedAt, at: connectedAt.addingTimeInterval(13), timeout: 120
        ))
    }

    func testEveryGATTProgressRefreshesWatchdogAndUnlockStartsFreshNoDataGrace() throws {
        var timing = LibreWatchConnectionTiming()
        let connectedAt = receivedAt.addingTimeInterval(600)
        timing.beginSetup(at: connectedAt)
        let stages: [LibreWatchConnectionTiming.Phase] = [.services, .characteristics, .notifications, .unlock]
        var progressAt = connectedAt
        for stage in stages {
            let old = try XCTUnwrap(timing.deadline)
            progressAt = progressAt.addingTimeInterval(59)
            XCTAssertTrue(timing.setupProgress(stage, at: progressAt))
            XCTAssertFalse(timing.timeoutIsCurrent(
                old, ownership: .watch, cancelling: false, at: old.expiresAt
            ))
            if stage != .unlock {
                XCTAssertEqual(timing.deadline?.expiresAt, progressAt.addingTimeInterval(60))
            }
        }
        XCTAssertNil(timing.deadline)
        XCTAssertFalse(timing.setupInProgress)
        XCTAssertEqual(timing.phase, .receiving)
        XCTAssertEqual(timing.dataExpectedSince, progressAt)
        for limit in [120.0, 180.0] {
            XCTAssertFalse(timing.noDataIsOverdue(
                lastPacketAt: receivedAt, at: progressAt.addingTimeInterval(limit - 1), timeout: limit
            ))
            XCTAssertTrue(timing.noDataIsOverdue(
                lastPacketAt: receivedAt, at: progressAt.addingTimeInterval(limit), timeout: limit
            ))
        }
    }

    func testGATTProgressAtDeadlineWinsUnlessCancellationAlreadyStarted() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginSetup(at: receivedAt)
        let old = try XCTUnwrap(timing.deadline)
        XCTAssertTrue(timing.setupProgress(.services, at: old.expiresAt))
        XCTAssertFalse(timing.timeoutIsCurrent(
            old, ownership: .watch, cancelling: false, at: old.expiresAt
        ))
        let current = try XCTUnwrap(timing.deadline)
        XCTAssertTrue(timing.timeoutIsCurrent(
            current, ownership: .watch, cancelling: false, at: current.expiresAt
        ))
        timing.invalidate() // Controlled cancellation has begun on the serial main queue.
        XCTAssertFalse(timing.setupProgress(.characteristics, at: current.expiresAt))
        XCTAssertNil(timing.deadline)
    }

    func testPausedGATTCallbacksAdvanceAndReceiveFreshPausedBudgets() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginSetup(at: receivedAt, executionIsAvailable: false)
        XCTAssertEqual(timing.phase, .services)
        XCTAssertNil(timing.deadline)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: receivedAt)),
            60,
            accuracy: 0.000_001
        )

        let servicesAt = receivedAt.addingTimeInterval(600)
        XCTAssertTrue(timing.setupProgress(
            .services,
            at: servicesAt,
            executionIsAvailable: false
        ))
        XCTAssertEqual(timing.phase, .characteristics)
        XCTAssertNil(timing.deadline)
        XCTAssertEqual(
            try XCTUnwrap(timing.remainingExecutionTime(at: servicesAt)),
            60,
            accuracy: 0.000_001
        )

        XCTAssertTrue(timing.setExecutionAvailable(true, at: servicesAt))
        let characteristicsDeadline = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(characteristicsDeadline.expiresAt, servicesAt.addingTimeInterval(60))

        XCTAssertTrue(timing.setupProgress(
            .characteristics,
            at: characteristicsDeadline.expiresAt,
            executionIsAvailable: true
        ))
        XCTAssertEqual(timing.phase, .notifications)
        XCTAssertFalse(timing.timeoutIsCurrent(
            characteristicsDeadline,
            ownership: .watch,
            cancelling: false,
            at: characteristicsDeadline.expiresAt
        ))
        XCTAssertEqual(
            timing.deadline?.expiresAt,
            characteristicsDeadline.expiresAt.addingTimeInterval(60)
        )
    }

    func testStaleTimersCannotCancelNewAttemptSetupOrHealthyNotifications() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(at: receivedAt, applicationIsActive: true)
        let oldAttempt = try XCTUnwrap(timing.deadline)
        timing.invalidate() // An explicitly retired generation permits a new attempt.
        timing.beginConnection(at: receivedAt.addingTimeInterval(1), applicationIsActive: false)
        let currentAttempt = try XCTUnwrap(timing.deadline)
        XCTAssertNotEqual(oldAttempt.token, currentAttempt.token)
        XCTAssertFalse(timing.timeoutIsCurrent(
            oldAttempt, ownership: .watch, cancelling: false, at: oldAttempt.expiresAt
        ))
        timing.beginSetup(at: receivedAt.addingTimeInterval(2))
        let setup = try XCTUnwrap(timing.deadline)
        timing.receivedPacketOrEnabledNotifications(at: receivedAt.addingTimeInterval(3))
        for retired in [oldAttempt, currentAttempt, setup] {
            XCTAssertFalse(timing.timeoutIsCurrent(
                retired, ownership: .watch, cancelling: false, at: receivedAt.addingTimeInterval(300)
            ))
        }
    }

    func testReturnToPhoneInvalidatesAllWatchTimingAndPreventsFurtherRecovery() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginSetup(at: receivedAt)
        let old = try XCTUnwrap(timing.deadline)
        timing.invalidate()
        XCTAssertNil(timing.phase)
        XCTAssertNil(timing.dataExpectedSince)
        XCTAssertFalse(timing.setupProgress(.services, at: old.expiresAt))
        XCTAssertFalse(timing.timeoutIsCurrent(
            old, ownership: .iphone, cancelling: false, at: old.expiresAt
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(ownership: .iphone))
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.reconnectFallbackAction(
                deadline: old.expiresAt, now: old.expiresAt,
                applicationIsActive: true,
                extendedRuntimeIsRunning: true,
                ownership: .iphone
            ),
            .noAdditionalWork
        )
    }

    func testAnExistingConnectionOrSetupNeverStartsParallelScanOrConnect() {
        var timing = LibreWatchConnectionTiming()
        XCTAssertTrue(timing.canStartBluetoothOperation)
        timing.beginConnection(at: receivedAt, applicationIsActive: true)
        XCTAssertFalse(timing.canStartBluetoothOperation)
        timing.beginSetup(at: receivedAt.addingTimeInterval(10))
        XCTAssertFalse(timing.canStartBluetoothOperation)
        timing.receivedPacketOrEnabledNotifications(at: receivedAt.addingTimeInterval(15))
        XCTAssertFalse(timing.canStartBluetoothOperation)
        timing.invalidate() // Only the retired attempt releases the gate for filtered scanning.
        XCTAssertTrue(timing.canStartBluetoothOperation)
    }

    func testForegroundAndRuntimeNoDataRecoveryKeepTheirOwnLimits() {
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.noDataRecoveryDelay(
                applicationIsActive: true,
                extendedRuntimeIsRunning: true,
                ownership: .watch
            ),
            2 * 60
        )
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.noDataRecoveryDelay(
                applicationIsActive: false,
                extendedRuntimeIsRunning: true,
                ownership: .watch
            ),
            3 * 60
        )
    }

    func testRepeatedConnectionFailuresDoNotRefillBudgetOrChangeGeneration() throws {
        for activeAtStart in [true, false] {
            var timing = LibreWatchConnectionTiming()
            timing.beginConnection(
                at: receivedAt,
                applicationIsActive: activeAtStart,
                executionIsAvailable: true
            )
            let original = try XCTUnwrap(timing.deadline)
            let generation = timing.generation
            // didFailToConnect retries use the same beginConnection entry point, without
            // invalidating timing. No callback silently refills the phase budget.
            for seconds in [1.0, 15.0, 30.0, 59.0] {
                timing.beginConnection(at: receivedAt.addingTimeInterval(seconds),
                                       applicationIsActive: !activeAtStart,
                                       executionIsAvailable: true)
                XCTAssertEqual(timing.deadline, original)
                XCTAssertEqual(timing.generation, generation)
                let duration = activeAtStart ? 60.0 : 90.0
                XCTAssertEqual(
                    try XCTUnwrap(timing.remainingExecutionTime(
                        at: receivedAt.addingTimeInterval(seconds)
                    )),
                    duration - seconds,
                    accuracy: 0.000_001
                )
                XCTAssertTrue(timing.canConnect(at: receivedAt.addingTimeInterval(seconds),
                                                peripheralIsDisconnected: true,
                                                retiredPeripheralIsReleased: true))
            }
        }
    }

    func testRetryCannotRenewAnExhaustedExecutionBudget() throws {
        for activeAtStart in [true, false] {
            var timing = LibreWatchConnectionTiming()
            timing.beginConnection(
                at: receivedAt,
                applicationIsActive: activeAtStart,
                executionIsAvailable: true
            )
            let original = try XCTUnwrap(timing.deadline)
            XCTAssertEqual(
                timing.failedConnectionAction(
                    at: original.expiresAt.addingTimeInterval(-0.001),
                    bluetoothIsPoweredOn: true
                ),
                .retryConfirmedPeripheral
            )
            for delay in [0.0, 60.0, 600.0] {
                let now = original.expiresAt.addingTimeInterval(delay)
                timing.beginConnection(
                    at: now,
                    applicationIsActive: !activeAtStart,
                    executionIsAvailable: true
                )
                XCTAssertEqual(timing.deadline, original)
                XCTAssertFalse(timing.canConnect(at: now, peripheralIsDisconnected: true,
                                                 retiredPeripheralIsReleased: true))
                XCTAssertTrue(timing.timeoutIsCurrent(
                    original, ownership: .watch, cancelling: false, at: now
                ))
                XCTAssertEqual(
                    timing.failedConnectionAction(at: now, bluetoothIsPoweredOn: true),
                    .scanConfirmedSensor
                )
                XCTAssertEqual(
                    timing.failedConnectionAction(at: now, bluetoothIsPoweredOn: false),
                    .waitForBluetooth
                )
            }
        }
    }

    func testMissingCancelCallbackRetiresForOneFilteredScanAtWatchdogDeadline() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginConnection(at: receivedAt, applicationIsActive: true)
        timing.beginCancellation(at: receivedAt.addingTimeInterval(60))
        let cancellation = try XCTUnwrap(timing.deadline)
        XCTAssertEqual(cancellation.expiresAt, receivedAt.addingTimeInterval(65))
        XCTAssertNil(timing.finishCancellation(
            cancellation, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: false, at: cancellation.expiresAt.addingTimeInterval(-1)
        ))
        XCTAssertFalse(timing.canStartBluetoothOperation)
        XCTAssertEqual(timing.finishCancellation(
            cancellation, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: false, at: cancellation.expiresAt
        ), .retireForScan)
        XCTAssertTrue(timing.canStartBluetoothOperation)
        XCTAssertNil(timing.finishCancellation(
            cancellation, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: false, at: cancellation.expiresAt.addingTimeInterval(30)
        ))
    }

    func testCancellationProofRemainsWallClockAndIgnoresExecutionPauses() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginCancellation(at: receivedAt)
        let cancellation = try XCTUnwrap(timing.deadline)

        XCTAssertFalse(timing.setExecutionAvailable(false, at: receivedAt.addingTimeInterval(1)))
        XCTAssertFalse(timing.setExecutionAvailable(true, at: receivedAt.addingTimeInterval(120)))
        XCTAssertEqual(timing.deadline, cancellation)
        XCTAssertNil(timing.finishCancellation(
            cancellation,
            ownership: .watch,
            returningToPhone: false,
            peripheralIsDisconnected: false,
            at: cancellation.expiresAt.addingTimeInterval(-0.001)
        ))
        XCTAssertEqual(timing.finishCancellation(
            cancellation,
            ownership: .watch,
            returningToPhone: false,
            peripheralIsDisconnected: false,
            at: cancellation.expiresAt
        ), .retireForScan)
    }

    func testOldCancellationWatchdogCannotAffectNewConnectionOrSetup() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginCancellation(at: receivedAt)
        let old = try XCTUnwrap(timing.deadline)
        let retiredGeneration = timing.generation
        XCTAssertEqual(timing.finishCancellation(
            old, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: true, at: receivedAt.addingTimeInterval(1)
        ), .confirmedDisconnected)
        timing.beginConnection(at: receivedAt.addingTimeInterval(2), applicationIsActive: true)
        let connection = timing.deadline
        XCTAssertNotEqual(timing.generation, retiredGeneration)
        XCTAssertNil(timing.finishCancellation(
            old, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: false, at: old.expiresAt
        ))
        XCTAssertEqual(timing.deadline, connection)
        timing.beginSetup(at: receivedAt.addingTimeInterval(3))
        let setup = timing.deadline
        XCTAssertNil(timing.finishCancellation(
            old, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: false, at: old.expiresAt
        ))
        XCTAssertEqual(timing.deadline, setup)
    }

    func testConfirmedCancellationWithoutDelegateCallbackCompletesOnlyOnce() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginCancellation(at: receivedAt)
        let deadline = try XCTUnwrap(timing.deadline)
        // A lifecycle/watchdog observation of native .disconnected is also confirmation.
        XCTAssertEqual(timing.finishCancellation(
            deadline, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: true, at: receivedAt.addingTimeInterval(1)
        ), .confirmedDisconnected)
        XCTAssertNil(timing.finishCancellation(
            deadline, ownership: .watch, returningToPhone: false,
            peripheralIsDisconnected: true, at: deadline.expiresAt
        ))
    }

    func testReturnToPhoneTimeoutNeverSubstitutesForConfirmedDisconnection() throws {
        for ownership in [LibreWatchOwnership.watch, .iphone] {
            var timing = LibreWatchConnectionTiming()
            timing.receivedPacketOrEnabledNotifications(at: receivedAt)
            timing.beginCancellation(at: receivedAt)
            let deadline = try XCTUnwrap(timing.deadline)
            XCTAssertEqual(timing.finishCancellation(
                deadline, ownership: ownership, returningToPhone: true,
                peripheralIsDisconnected: false, at: deadline.expiresAt
            ), .awaitConfirmedDisconnection)
            XCTAssertTrue(timing.cancellationWatchdogDidFire)
            XCTAssertFalse(timing.canStartBluetoothOperation)
            XCTAssertNil(timing.finishCancellation(
                deadline, ownership: ownership, returningToPhone: true,
                peripheralIsDisconnected: false, at: deadline.expiresAt.addingTimeInterval(30)
            ))
            XCTAssertEqual(timing.finishCancellation(
                deadline, ownership: ownership, returningToPhone: true,
                peripheralIsDisconnected: true, at: deadline.expiresAt.addingTimeInterval(31)
            ), .confirmedDisconnected)
            XCTAssertFalse(LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(ownership: .iphone))
        }
    }

    func testCancellationAndRetiredPeripheralPreventParallelConnect() throws {
        var timing = LibreWatchConnectionTiming()
        timing.beginCancellation(at: receivedAt)
        let cancellation = timing.deadline
        timing.beginConnection(at: receivedAt, applicationIsActive: true)
        timing.beginSetup(at: receivedAt)
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        XCTAssertFalse(timing.observeLink(
            connected: false, connecting: true, hasReceptionState: true,
            at: receivedAt, applicationIsActive: true
        ))
        XCTAssertEqual(timing.phase, .cancelling)
        XCTAssertEqual(timing.deadline, cancellation)
        XCTAssertFalse(timing.canStartBluetoothOperation)
        timing.invalidate()
        timing.beginConnection(at: receivedAt, applicationIsActive: true)
        XCTAssertFalse(timing.canConnect(at: receivedAt, peripheralIsDisconnected: true,
                                         retiredPeripheralIsReleased: false))
        XCTAssertFalse(timing.canConnect(at: receivedAt, peripheralIsDisconnected: false,
                                         retiredPeripheralIsReleased: true))
        XCTAssertTrue(timing.canConnect(at: receivedAt, peripheralIsDisconnected: true,
                                        retiredPeripheralIsReleased: true))
    }

    func testInvalidFrameKeepsTechnicalNoDataMonitoringAndResetsAssembly() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        var liveness = LibreWatchFrameLiveness()
        var assembler = Libre2WatchDirectFrameAssembler()
        XCTAssertThrowsError(try assembler.append(
            fragment: Data(repeating: 0, count: Libre2WatchDirectConstants.encryptedFrameLength + 1),
            at: receivedAt.addingTimeInterval(60)
        ))
        assembler.reset() // Same catch path as the collector; UI failure does not alter timing.
        XCTAssertFalse(liveness.invalidFrame())
        XCTAssertEqual(assembler.assembledByteCount, 0)
        XCTAssertEqual(timing.phase, .receiving)
        XCTAssertEqual(timing.dataExpectedSince, receivedAt)
        XCTAssertTrue(timing.noDataIsOverdue(
            lastPacketAt: receivedAt, at: receivedAt.addingTimeInterval(120), timeout: 120
        ))
        XCTAssertNil(try assembler.append(
            fragment: Data(repeating: 0, count: 20), at: receivedAt.addingTimeInterval(121)
        ))
        XCTAssertEqual(assembler.assembledByteCount, 20)
    }

    func testValidFrameRecordsTechnicalLivenessAndResetsInvalidFrameCounter() {
        var liveness = LibreWatchFrameLiveness()
        let reading = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            at: receivedAt
        )
        var deliveryAcceptance = LibreWatchReadingAcceptancePolicy()
        XCTAssertTrue(deliveryAcceptance.accept(
            reading,
            for: session.id,
            now: receivedAt.addingTimeInterval(1)
        ))
        XCTAssertFalse(deliveryAcceptance.accept(
            reading,
            for: session.id,
            now: receivedAt.addingTimeInterval(2)
        ))
        XCTAssertFalse(liveness.invalidFrame())
        XCTAssertFalse(liveness.invalidFrame())
        XCTAssertEqual(liveness.consecutiveInvalidFrames, 2)
        let validFrameAt = receivedAt.addingTimeInterval(45)
        var livenessWasVisibleBeforeDownstreamRejection = false
        let downstreamAccepted = LibreWatchValidFramePolicy.record(
            liveness: &liveness,
            at: validFrameAt
        ) { recordedLiveness in
            livenessWasVisibleBeforeDownstreamRejection =
                recordedLiveness.lastValidBLEFrameAt == validFrameAt
            return false
        }
        XCTAssertFalse(downstreamAccepted)
        XCTAssertTrue(livenessWasVisibleBeforeDownstreamRejection)
        XCTAssertEqual(liveness.consecutiveInvalidFrames, 0)
        XCTAssertFalse(liveness.recoveryRequested)
        XCTAssertEqual(liveness.lastValidBLEFrameAt, validFrameAt)
        XCTAssertFalse(liveness.invalidFrame())
        XCTAssertEqual(liveness.consecutiveInvalidFrames, 1)
    }

    func testThreeConsecutiveInvalidFramesRequestExactlyOneRecovery() {
        var liveness = LibreWatchFrameLiveness()
        let requests = (0 ..< 10).map { _ in liveness.invalidFrame() }
        XCTAssertEqual(LibreWatchFrameLiveness.invalidFrameLimit, 3)
        XCTAssertEqual(Array(requests.prefix(3)), [false, false, true])
        XCTAssertEqual(requests.filter { $0 }.count, 1)
        XCTAssertEqual(liveness.consecutiveInvalidFrames, 3)
    }

    func testDelayedLegacyDisconnectMustMatchGenerationAndDisconnectedState() throws {
        var timing = LibreWatchConnectionTiming()
        timing.receivedPacketOrEnabledNotifications(at: receivedAt)
        let oldGeneration = timing.generation
        var gate = LibreWatchLegacyDisconnectGate()
        let token = try XCTUnwrap(gate.scheduleLegacy())
        XCTAssertTrue(gate.legacyIsCurrent(
            token, scheduledGeneration: oldGeneration, currentGeneration: timing.generation,
            peripheralIsDisconnectedOrDisconnecting: true
        ))
        XCTAssertFalse(gate.legacyIsCurrent(
            token, scheduledGeneration: oldGeneration, currentGeneration: timing.generation,
            peripheralIsDisconnectedOrDisconnecting: false
        ))
        timing.invalidate()
        timing.beginConnection(at: receivedAt.addingTimeInterval(1), applicationIsActive: true)
        XCTAssertFalse(gate.legacyIsCurrent(
            token, scheduledGeneration: oldGeneration, currentGeneration: timing.generation,
            peripheralIsDisconnectedOrDisconnecting: true
        ))
        gate.cancelLegacy()
        XCTAssertFalse(gate.accept(legacyToken: token))
    }

    func testModernCallbackAndDidConnectInvalidateDelayedLegacyWork() throws {
        for didConnectFirst in [true, false] {
            var gate = LibreWatchLegacyDisconnectGate()
            let token = try XCTUnwrap(gate.scheduleLegacy())
            let generation = UUID()
            if didConnectFirst {
                gate.reset()
            } else {
                XCTAssertTrue(gate.accept())
            }
            XCTAssertFalse(gate.legacyIsCurrent(
                token, scheduledGeneration: generation, currentGeneration: generation,
                peripheralIsDisconnectedOrDisconnecting: true
            ))
            XCTAssertFalse(gate.accept(legacyToken: token))
        }
    }

    func testLegacyDiagnosticEventsStillDecodeWithoutNewContext() throws {
        let data = Data(#"{"kind":"disconnected","isReconnecting":true,"errorCode":7}"#.utf8)
        let event = try JSONDecoder().decode(LibreWatchDiagnosticEvent.self, from: data)
        XCTAssertNil(event.eventID)
        XCTAssertEqual(event.kind, .disconnected)
        XCTAssertEqual(event.isReconnecting, true)
        XCTAssertEqual(event.errorCode, 7)
        XCTAssertNil(event.watchTimestamp)
        XCTAssertNil(event.trigger)
        XCTAssertNil(event.generation)
        XCTAssertNil(event.deadlineAt)
        XCTAssertNil(event.attemptID)
        XCTAssertNil(event.attemptStartedAt)
        XCTAssertNil(event.sessionID)
        XCTAssertNil(event.sensorIdentity)
        XCTAssertNil(event.reconcileSource)
        XCTAssertNil(event.remainingExecutionBudget)
        XCTAssertNil(event.runtimeInvalidationReason)
        XCTAssertNil(event.runtimeError)
        XCTAssertNil(event.applicationState)
        XCTAssertNil(event.sequenceNumber)
        XCTAssertNil(event.bluetoothErrorClassification)
        XCTAssertNil(event.extendedRuntimeState)
        XCTAssertNil(event.extendedRuntimeStartRequested)
    }

    func testBackgroundNotificationQuotaErrorsNeverCountAsInvalidFramesOrStartRecovery() {
        let quotaActions: [LibreWatchNotificationErrorAction] = [
            LibreWatchNotificationErrorPolicy.action(
                isNearBackgroundNotificationLimit: true,
                isExceededBackgroundNotificationLimit: false
            ),
            LibreWatchNotificationErrorPolicy.action(
                isNearBackgroundNotificationLimit: false,
                isExceededBackgroundNotificationLimit: true
            )
        ]
        var liveness = LibreWatchFrameLiveness()
        var recoveryCount = 0

        for action in quotaActions {
            switch action {
            case .recoverBluetoothLink:
                if liveness.invalidFrame() { recoveryCount += 1 }
            case .preserveConnectionNearBackgroundLimit,
                 .preserveConnectionExceededBackgroundLimit:
                break
            }
        }

        XCTAssertEqual(quotaActions.map(\.diagnosticName), [
            "backgroundBudgetNear",
            "backgroundBudgetExceeded"
        ])
        XCTAssertEqual(liveness.consecutiveInvalidFrames, 0)
        XCTAssertEqual(recoveryCount, 0)
        XCTAssertEqual(
            LibreWatchNotificationErrorPolicy.action(
                isNearBackgroundNotificationLimit: false,
                isExceededBackgroundNotificationLimit: false
            ),
            .recoverBluetoothLink
        )
    }

    func testDiagnosticJournalPersistsOriginalOrderAndPendingDeliveryAcrossRestart() throws {
        let defaults = isolatedDefaults()
        let firstID = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "A2000000-0000-0000-0000-000000000002")!
        let first = LibreWatchDiagnosticEvent(
            eventID: firstID,
            kind: .lifecycleChanged,
            watchTimestamp: receivedAt,
            trigger: "background",
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            applicationState: .background
        )
        let second = LibreWatchDiagnosticEvent(
            eventID: secondID,
            kind: .coreBluetoothCallback,
            watchTimestamp: receivedAt.addingTimeInterval(5),
            trigger: "didConnect",
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            applicationState: .active
        )
        var journal = LibreWatchDiagnosticJournal()

        let firstResult = journal.append(first, at: receivedAt.addingTimeInterval(1))
        let secondResult = journal.append(second, at: receivedAt.addingTimeInterval(6))
        XCTAssertTrue(firstResult.inserted)
        XCTAssertTrue(secondResult.inserted)
        XCTAssertEqual(firstResult.event.sequenceNumber, 1)
        XCTAssertEqual(secondResult.event.sequenceNumber, 2)
        XCTAssertFalse(journal.append(first, at: receivedAt.addingTimeInterval(7)).inserted)

        LibreWatchSessionStore.saveDiagnosticJournal(
            journal,
            defaults: defaults,
            at: receivedAt.addingTimeInterval(7)
        )
        var restored = LibreWatchSessionStore.loadDiagnosticJournal(
            defaults: defaults,
            at: receivedAt.addingTimeInterval(8)
        )
        XCTAssertEqual(
            restored.pendingEvents(for: session.id).compactMap(\.eventID),
            [firstID, secondID]
        )
        XCTAssertTrue(restored.pendingEvents(for: UUID()).isEmpty)
        restored.markHandedToWatchConnectivity(
            eventID: firstID,
            at: receivedAt.addingTimeInterval(10)
        )
        LibreWatchSessionStore.saveDiagnosticJournal(
            restored,
            defaults: defaults,
            at: receivedAt.addingTimeInterval(11)
        )
        let deliveredState = LibreWatchSessionStore.loadDiagnosticJournal(
            defaults: defaults,
            at: receivedAt.addingTimeInterval(12)
        )
        XCTAssertEqual(
            deliveredState.pendingEvents(for: session.id).compactMap(\.eventID),
            [secondID]
        )
        XCTAssertEqual(deliveredState.entries.first?.event.watchTimestamp, receivedAt)
    }

    func testDiagnosticJournalIsBoundedAndRecordsDroppedEntriesWithoutRecursiveEvents() throws {
        var journal = LibreWatchDiagnosticJournal()
        let start = receivedAt
        for index in 0 ..< 300 {
            _ = journal.append(LibreWatchDiagnosticEvent(
                kind: .coreBluetoothCallback,
                watchTimestamp: start.addingTimeInterval(TimeInterval(index)),
                trigger: "centralState:poweredOn",
                sessionID: session.id,
                sensorIdentity: session.redactedIdentity(),
                applicationState: .active,
                actionReason: String(repeating: "x", count: 2_000)
            ), at: start.addingTimeInterval(TimeInterval(index)))
        }

        let encoded = try JSONEncoder().encode(journal)
        XCTAssertLessThanOrEqual(journal.entries.count, LibreWatchDiagnosticJournal.maximumEntries)
        XCTAssertLessThanOrEqual(encoded.count, LibreWatchDiagnosticJournal.maximumEncodedBytes)
        XCTAssertGreaterThan(journal.droppedCount, 0)
        XCTAssertTrue(journal.entries.allSatisfy { $0.event.actionReason?.count == 513 })
        XCTAssertEqual(
            journal.entries.compactMap { $0.event.sequenceNumber },
            journal.entries.compactMap { $0.event.sequenceNumber }.sorted()
        )
        XCTAssertFalse(journal.entries.contains { $0.event.kind == .journalRotated })
    }

    func testDiagnosticJournalAssignsStableIDAndExpiresByLocalRecordTime() throws {
        var journal = LibreWatchDiagnosticJournal()
        let event = LibreWatchDiagnosticEvent(
            eventID: nil,
            kind: .callbackRejected,
            watchTimestamp: receivedAt.addingTimeInterval(365 * 24 * 60 * 60),
            trigger: "staleSetupGeneration",
            sessionID: session.id
        )
        let result = journal.append(event, at: receivedAt)
        let generatedID = try XCTUnwrap(result.event.eventID)
        XCTAssertEqual(journal.entries.first?.event.eventID, generatedID)

        journal.prune(at: receivedAt.addingTimeInterval(
            LibreWatchDiagnosticJournal.maximumAge + 0.001
        ))
        XCTAssertTrue(journal.entries.isEmpty)
        XCTAssertGreaterThan(journal.droppedCount, 0)
    }

    func testQueuedDiagnosticPreservesWatchTimestampAndPhaseContext() throws {
        let eventID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let attemptID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let event = LibreWatchDiagnosticEvent(
            eventID: eventID, kind: .recoveryStarted,
            watchTimestamp: receivedAt, trigger: "invalidFrames",
            applicationIsActive: false, extendedRuntimeIsRunning: true,
            peripheralState: "connected", connectionPhase: "cancelling",
            deadlinePhase: "cancelling", deadlineAt: receivedAt.addingTimeInterval(5),
            generation: UUID(), attemptID: attemptID,
            attemptStartedAt: receivedAt.addingTimeInterval(-30),
            sessionID: session.id, sensorIdentity: session.redactedIdentity(),
            reconcileSource: .gattCallback, remainingExecutionBudget: 42
        )
        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(
            LibreWatchDiagnosticEvent.self, from: encoded
        )
        XCTAssertEqual(decoded, event)
        XCTAssertEqual(decoded.eventID, eventID)
        XCTAssertEqual(decoded.attemptID, attemptID)
        XCTAssertEqual(decoded.remainingExecutionBudget, 42)
        XCTAssertEqual(decoded.watchTimestamp, receivedAt) // Not the later iPhone receipt time.

        // A fallback delivery must persist the exact snapshot, not reconstruct it later.
        let item = LibreWatchOutboxItem.command(
            .reportDiagnostic,
            sessionID: session.id,
            diagnosticEvent: encoded,
            id: eventID,
            createdAt: receivedAt.addingTimeInterval(60)
        )
        let queuedEvent = try JSONDecoder().decode(
            LibreWatchDiagnosticEvent.self,
            from: try XCTUnwrap(item.diagnosticEvent)
        )
        XCTAssertEqual(queuedEvent, event)
    }

    func testRecoveryAttemptRetainsImmutableContextUntilSuccessOrInvalidation() throws {
        let original = LibreWatchRecoveryAttemptContext(
            attemptID: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            originalTrigger: "disconnect",
            startedAt: receivedAt,
            generation: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity()
        )
        let later = LibreWatchRecoveryAttemptContext(
            originalTrigger: "sceneActivation",
            startedAt: receivedAt.addingTimeInterval(600),
            generation: UUID(),
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity()
        )
        var state = LibreWatchRecoveryAttemptState()

        XCTAssertEqual(state.begin(original), original)
        XCTAssertNil(state.begin(later))
        XCTAssertEqual(state.context, original)
        XCTAssertEqual(state.reportFailure(), original)
        XCTAssertNil(state.reportFailure())
        XCTAssertEqual(state.context?.startedAt, receivedAt)

        let defaults = isolatedDefaults()
        LibreWatchSessionStore.saveRecoveryAttempt(state, defaults: defaults)
        var restored = LibreWatchSessionStore.loadRecoveryAttempt(defaults: defaults)
        XCTAssertEqual(restored, state)
        XCTAssertNil(restored.reportFailure()) // The one failure report survives restoration too.
        XCTAssertEqual(restored.finishSuccess(), original)
        LibreWatchSessionStore.saveRecoveryAttempt(restored, defaults: defaults)
        XCTAssertNil(LibreWatchSessionStore.loadRecoveryAttempt(defaults: defaults).context)
        XCTAssertNil(defaults.data(forKey: LibreWatchMessageKey.persistedRecoveryAttempt))
    }

    func testDiagnosticReceiptDeduplicatesStableEventIDAndAcceptsLegacyEvents() {
        let eventID = UUID(uuidString: "50000000-0000-0000-0000-000000000005")!
        var ledger = LibreWatchDiagnosticReceiptLedger()

        XCTAssertTrue(ledger.accept(eventID, at: receivedAt))
        XCTAssertFalse(ledger.accept(eventID, at: receivedAt.addingTimeInterval(1)))
        XCTAssertTrue(ledger.accept(nil, at: receivedAt.addingTimeInterval(2)))
        XCTAssertTrue(ledger.accept(nil, at: receivedAt.addingTimeInterval(3)))
        XCTAssertEqual(ledger.receipts[eventID], receivedAt)

        ledger.prune(at: receivedAt.addingTimeInterval(LibreWatchDiagnosticReceiptLedger.maximumAge))
        XCTAssertNotNil(ledger.receipts[eventID])
        ledger.prune(at: receivedAt.addingTimeInterval(
            LibreWatchDiagnosticReceiptLedger.maximumAge + 0.001
        ))
        XCTAssertNil(ledger.receipts[eventID])
    }

    func testConnectivityDeliveryPolicyCoversActivationAndReachability() {
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.action(
                sessionIsActivated: false,
                phoneIsReachable: false
            ),
            .activateAndQueue
        )
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.action(
                sessionIsActivated: false,
                phoneIsReachable: true
            ),
            .activateAndQueue
        )
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.action(
                sessionIsActivated: true,
                phoneIsReachable: false
            ),
            .transferUserInfo
        )
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.action(
                sessionIsActivated: true,
                phoneIsReachable: true
            ),
            .sendMessage
        )
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.actionAfterSendError(
                sessionIsActivated: true
            ),
            .transferUserInfo
        )
        XCTAssertEqual(
            LibreWatchConnectivityDeliveryPolicy.actionAfterSendError(
                sessionIsActivated: false
            ),
            .activateAndQueue
        )
        XCTAssertTrue(
            LibreWatchConnectivityDeliveryPolicy.shouldRetryReadingAsQueued(
                after: .wrongOwnership
            )
        )
        XCTAssertTrue(
            LibreWatchConnectivityDeliveryPolicy.shouldRetryReadingAsQueued(
                after: .tooOld
            )
        )
        XCTAssertFalse(
            LibreWatchConnectivityDeliveryPolicy.shouldRetryReadingAsQueued(
                after: .wrongSession
            )
        )
        XCTAssertFalse(
            LibreWatchConnectivityDeliveryPolicy.shouldRetryReadingAsQueued(
                after: .duplicate
            )
        )
    }

    func testHistoricalProcessingModeCannotDriveCurrentValueOrLiveAlerts() {
        let live = LibreWatchGlucoseProcessingMode.live
        XCTAssertTrue(live.permitsCurrentValueAndLiveSideEffects)
        XCTAssertEqual(
            live.routing,
            LibreWatchGlucoseProcessingRouting(
                updatesCurrentValue: true,
                resetsMissedReadingState: true,
                triggersAlerts: true,
                exportsToIntegrations: true
            )
        )

        let historical = LibreWatchGlucoseProcessingMode.historicalBackfill
        XCTAssertFalse(historical.permitsCurrentValueAndLiveSideEffects)
        XCTAssertFalse(historical.routing.updatesCurrentValue)
        XCTAssertFalse(historical.routing.resetsMissedReadingState)
        XCTAssertFalse(historical.routing.triggersAlerts)
        XCTAssertFalse(historical.routing.exportsToIntegrations)
    }

    func testOutboxDeduplicatesOrdersPersistsAndAcknowledgesByStableID() throws {
        let now = Date()
        let older = payload(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
            raw: 790,
            previousRaw: 780,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-60)
        )
        let newer = payload(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000007")!,
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: now
        )
        let commandID = UUID(uuidString: "80000000-0000-0000-0000-000000000008")!
        let command = LibreWatchOutboxItem.command(
            .updateUnlockCounter,
            sessionID: session.id,
            unlockCounter: 9,
            id: commandID,
            createdAt: now.addingTimeInterval(-120)
        )
        var outbox = LibreWatchConnectivityOutbox()

        outbox.enqueue(.reading(newer), now: now)
        outbox.enqueue(command, now: now)
        outbox.enqueue(.reading(older), now: now)
        outbox.enqueue(.reading(older), now: now)
        XCTAssertEqual(outbox.items.map(\.id), [commandID, older.id, newer.id])
        XCTAssertEqual(outbox.next?.id, commandID)

        let defaults = isolatedDefaults()
        LibreWatchSessionStore.saveOutbox(outbox, defaults: defaults)
        var restored = LibreWatchSessionStore.loadOutbox(defaults: defaults)
        XCTAssertEqual(restored, outbox)
        restored.remove(id: newer.id)
        XCTAssertEqual(restored.items.map(\.id), [commandID, older.id])
        XCTAssertNotNil(restored.items.first(where: { $0.id == older.id }))
        XCTAssertNotNil(restored.items.first(where: { $0.id == commandID }))
    }

    func testOutboxCapacityTrimsOldestPayloadRegardlessOfKind() {
        let now = receivedAt.addingTimeInterval(1_000)
        var outbox = LibreWatchConnectivityOutbox()
        for offset in 0 ..< LibreWatchConnectivityOutbox.maximumItems {
            outbox.enqueue(.command(
                .reportDiagnostic,
                sessionID: session.id,
                diagnosticEvent: Data([UInt8(offset & 0xFF)]),
                createdAt: now.addingTimeInterval(TimeInterval(offset))
            ), now: now)
        }
        let reading = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_500,
            at: now.addingTimeInterval(TimeInterval(LibreWatchConnectivityOutbox.maximumItems))
        )

        outbox.enqueue(.reading(reading), now: now)

        XCTAssertEqual(outbox.items.count, LibreWatchConnectivityOutbox.maximumItems)
        XCTAssertEqual(outbox.items.last?.id, reading.id)
        XCTAssertTrue(outbox.items.contains(where: { $0.id == reading.id }))
    }

    func testOutboxPrunesStrictlyAfterSixtyMinutesAndRetainsOnlyActiveSession() {
        let active = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            at: receivedAt
        )
        let otherSessionID = UUID(uuidString: "90000000-0000-0000-0000-000000000009")!
        let other = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_235,
            at: receivedAt.addingTimeInterval(1),
            sessionID: otherSessionID
        )
        var outbox = LibreWatchConnectivityOutbox()
        outbox.enqueue(.reading(active), now: receivedAt.addingTimeInterval(1))
        outbox.enqueue(.reading(other), now: receivedAt.addingTimeInterval(1))

        outbox.prune(at: receivedAt.addingTimeInterval(LibreWatchConnectivityOutbox.maximumAge))
        XCTAssertEqual(Set(outbox.items.map(\.id)), Set([active.id, other.id]))
        outbox.retain(sessionID: session.id)
        XCTAssertEqual(outbox.items.map(\.id), [active.id])

        outbox.prune(at: receivedAt.addingTimeInterval(
            LibreWatchConnectivityOutbox.maximumAge + 0.001
        ))
        XCTAssertTrue(outbox.items.isEmpty)
    }

    func testReadingAcceptanceRejectsDuplicateStaleAndOutOfOrderPayloads() {
        let firstID = UUID()
        let first = payload(
            id: firstID,
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: receivedAt
        )
        var acceptance = LibreWatchReadingAcceptancePolicy()

        XCTAssertTrue(acceptance.accept(first, for: session.id, now: receivedAt.addingTimeInterval(1)))
        XCTAssertFalse(acceptance.accept(first, for: session.id, now: receivedAt.addingTimeInterval(2)))

        let lowerSensorTime = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 999,
            at: receivedAt.addingTimeInterval(60)
        )
        XCTAssertFalse(acceptance.accept(
            lowerSensorTime,
            for: session.id,
            now: receivedAt.addingTimeInterval(61)
        ))

        let olderTimestamp = payload(
            raw: 820,
            previousRaw: 810,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: receivedAt
        )
        XCTAssertFalse(acceptance.accept(
            olderTimestamp,
            for: session.id,
            now: receivedAt.addingTimeInterval(62)
        ))

        let staleTransport = payload(
            raw: 830,
            previousRaw: 820,
            domain: .xDripRawGlucose,
            sensorTime: 1_002,
            at: receivedAt.addingTimeInterval(120)
        )
        XCTAssertFalse(acceptance.accept(
            staleTransport,
            for: session.id,
            now: receivedAt.addingTimeInterval(301)
        ))
    }

    func testLiveTransportKeepsThreeMinuteBoundary() {
        let now = receivedAt.addingTimeInterval(600)
        let exactBoundary = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-LibreWatchReadingAcceptancePolicy.maximumTransportAge)
        )
        let pastBoundary = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: now.addingTimeInterval(-LibreWatchReadingAcceptancePolicy.maximumTransportAge - 0.001)
        )
        var exactAcceptance = LibreWatchReadingAcceptancePolicy()
        var staleAcceptance = LibreWatchReadingAcceptancePolicy()

        XCTAssertTrue(exactAcceptance.accept(exactBoundary, for: session.id, now: now))
        XCTAssertFalse(staleAcceptance.accept(pastBoundary, for: session.id, now: now))
    }

    func testQueuedHistoryUsesReceiverTransportAndSixtyMinuteBoundary() {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let now = receivedAt.addingTimeInterval(4_000)
        let exactBoundary = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-LibreWatchHistoryPolicy.maximumAge)
        )
        let pastBoundary = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: now.addingTimeInterval(-LibreWatchHistoryPolicy.maximumAge - 0.001)
        )
        let future = payload(
            raw: 820,
            previousRaw: 810,
            domain: .xDripRawGlucose,
            sensorTime: 1_002,
            at: now.addingTimeInterval(1)
        )

        XCTAssertNil(LibreWatchHistoryPolicy.rejection(
            reading: exactBoundary,
            transport: .queuedUserInfo,
            session: session,
            calibration: snapshot,
            ownership: .watch,
            now: now
        ))
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: exactBoundary,
            transport: .interactiveMessage,
            session: session,
            calibration: snapshot,
            ownership: .watch,
            now: now
        ), .invalidPayload)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: pastBoundary,
            transport: .queuedUserInfo,
            session: session,
            calibration: snapshot,
            ownership: .watch,
            now: now
        ), .tooOld)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: future,
            transport: .queuedUserInfo,
            session: session,
            calibration: snapshot,
            ownership: .watch,
            now: now
        ), .tooOld)
    }

    func testFreshQueuedFallbackUsesLiveRouteBeforeHistoricalBackfill() {
        XCTAssertEqual(
            LibreWatchQueuedReadingRoutingPolicy.route(
                transportAge: LibreWatchReadingAcceptancePolicy.maximumTransportAge,
                ownership: .watch
            ),
            .attemptLiveAcceptance
        )
        XCTAssertEqual(
            LibreWatchQueuedReadingRoutingPolicy.route(
                transportAge: LibreWatchReadingAcceptancePolicy.maximumTransportAge + 0.001,
                ownership: .watch
            ),
            .historicalBackfill
        )
        XCTAssertEqual(
            LibreWatchQueuedReadingRoutingPolicy.route(transportAge: 30, ownership: .iphone),
            .historicalBackfill
        )
    }

    func testReleaseReceiptAllowsOnlyPreCutoffQueuedHistoryAcrossPhoneReturn() throws {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let cutoff = receivedAt.addingTimeInterval(600)
        var receipt = try XCTUnwrap(LibreWatchReleaseReceipt(
            session: session,
            calibration: snapshot,
            cutoff: cutoff,
            now: cutoff
        ))
        let before = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: cutoff.addingTimeInterval(-60)
        )
        let after = payload(
            raw: 810,
            previousRaw: 800,
            domain: .xDripRawGlucose,
            sensorTime: 1_001,
            at: cutoff.addingTimeInterval(1)
        )

        XCTAssertNil(LibreWatchHistoryPolicy.rejection(
            reading: before, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .releasingToPhone,
            receipt: receipt, now: cutoff.addingTimeInterval(10)
        ))
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: before, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .iphone,
            receipt: receipt, now: cutoff.addingTimeInterval(10)
        ), .missingReceipt)

        receipt.complete()
        XCTAssertNil(LibreWatchHistoryPolicy.rejection(
            reading: before, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .iphone,
            receipt: receipt, now: cutoff.addingTimeInterval(10)
        ))
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: after, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .iphone,
            receipt: receipt, now: cutoff.addingTimeInterval(10)
        ), .afterCutoff)
    }

    func testReleaseReceiptIsPersistedAndCannotCrossSessionOrCalibration() throws {
        let defaults = isolatedDefaults()
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let cutoff = receivedAt.addingTimeInterval(600)
        var receipt = try XCTUnwrap(LibreWatchReleaseReceipt(
            session: session,
            calibration: snapshot,
            cutoff: cutoff,
            now: cutoff
        ))
        receipt.complete()
        LibreWatchSessionStore.saveSession(session, defaults: defaults)
        LibreWatchSessionStore.saveReleaseReceipt(receipt, defaults: defaults)
        XCTAssertEqual(LibreWatchSessionStore.loadReleaseReceipt(defaults: defaults), receipt)

        let changedCalibration = calibration(type: .fixedSlope, slope: 1.1, intercept: 0)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: payload(
                raw: 800,
                previousRaw: 790,
                domain: .xDripRawGlucose,
                sensorTime: 1_000,
                at: cutoff.addingTimeInterval(-60)
            ),
            transport: .queuedUserInfo,
            session: session,
            calibration: changedCalibration,
            ownership: .iphone,
            receipt: receipt,
            now: cutoff.addingTimeInterval(10)
        ), .missingReceipt)

        let replacementSession = LibreWatchDirectSession(
            sensorUID: session.sensorUID,
            patchInfo: session.patchInfo,
            sensorSerialNumber: session.sensorSerialNumber,
            sensorTypeRawValue: session.sensorTypeRawValue,
            expectedPeripheralName: session.expectedPeripheralName,
            unlockCode: session.unlockCode,
            unlockCount: session.unlockCount,
            algorithmParameters: session.algorithmParameters
        )
        LibreWatchSessionStore.saveSession(replacementSession, defaults: defaults)
        XCTAssertNil(LibreWatchSessionStore.loadReleaseReceipt(defaults: defaults))
    }

    func testFailedReleaseClearsReceiptAndRestoresConservativeWatchOwner() throws {
        let defaults = isolatedDefaults()
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let cutoff = receivedAt.addingTimeInterval(600)
        let receipt = try XCTUnwrap(LibreWatchReleaseReceipt(
            session: session,
            calibration: snapshot,
            cutoff: cutoff,
            now: cutoff
        ))
        LibreWatchSessionStore.saveSession(session, defaults: defaults)
        LibreWatchSessionStore.saveReleaseReceipt(receipt, defaults: defaults)
        LibreWatchSessionStore.saveOwnership(.releasingToPhone, defaults: defaults)

        // Mirrors the failed returnSensorToPhone branch: never enable iPhone when
        // the physical release was not completed.
        LibreWatchSessionStore.clearReleaseReceipt(defaults: defaults)
        LibreWatchSessionStore.saveOwnership(.watch, defaults: defaults)

        XCTAssertNil(LibreWatchSessionStore.loadReleaseReceipt(defaults: defaults))
        let startup = LibreWatchPhoneStartupDecision.resolve(
            persistedOwnership: LibreWatchSessionStore.loadOwnership(defaults: defaults),
            persistedSession: LibreWatchSessionStore.loadSession(defaults: defaults),
            activeSensorUID: session.sensorUID,
            activePatchInfo: session.patchInfo
        )
        XCTAssertTrue(startup.phoneConnectionIsBlocked)
        XCTAssertEqual(startup.ownership, .watch)
    }

    func testExpiredReceiptCannotAuthorizeQueuedHistoryAfterReturn() throws {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let cutoff = receivedAt.addingTimeInterval(600)
        var receipt = try XCTUnwrap(LibreWatchReleaseReceipt(
            session: session,
            calibration: snapshot,
            cutoff: cutoff,
            now: cutoff
        ))
        receipt.complete()
        let reading = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: cutoff.addingTimeInterval(-60)
        )
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: reading,
            transport: .queuedUserInfo,
            session: session,
            calibration: snapshot,
            ownership: .iphone,
            receipt: receipt,
            now: receipt.expiresAt.addingTimeInterval(0.001)
        ), .tooOld)
    }

    @MainActor
    func testBackfillUsesPersistentPayloadIdentityAndPreservesPhoneCollision() async throws {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = stack.mainManagedObjectContext
        let sensor = Sensor(startDate: session.createdAt, nsManagedObjectContext: context)
        let reading = payload(
            raw: 847,
            previousRaw: 830,
            domain: .factoryNativeMGDL,
            sensorTime: 1_234,
            at: receivedAt
        )
        let phone = BgReading(
            timeStamp: receivedAt,
            sensor: sensor,
            calibration: nil,
            rawData: 120,
            deviceName: nil,
            nsManagedObjectContext: context
        )
        phone.calculatedValue = 120
        phone.id = reading.id.uuidString
        XCTAssertTrue(stack.saveChanges())

        let sensorID = sensor.id
        await stack.privateManagedObjectContext.perform {}
        context.reset()
        let request: NSFetchRequest<BgReading> = BgReading.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", reading.id.uuidString)
        let stored = try XCTUnwrap(context.fetch(request).first)

        XCTAssertFalse(stored.objectID.isTemporaryID)
        XCTAssertTrue(LibreWatchHistoryPolicy.collides(
            payloadID: reading.id.uuidString,
            measuredAt: receivedAt.addingTimeInterval(-600),
            sensorID: sensorID,
            existingID: stored.id,
            existingAt: stored.timeStamp,
            existingSensorID: stored.sensor?.id
        ))
        XCTAssertTrue(LibreWatchHistoryPolicy.collides(
            payloadID: UUID().uuidString,
            measuredAt: receivedAt.addingTimeInterval(5),
            sensorID: sensorID,
            existingID: stored.id,
            existingAt: stored.timeStamp,
            existingSensorID: stored.sensor?.id
        ))
        XCTAssertFalse(LibreWatchHistoryPolicy.collides(
            payloadID: reading.id.uuidString,
            measuredAt: receivedAt,
            sensorID: "another-sensor",
            existingID: stored.id,
            existingAt: stored.timeStamp,
            existingSensorID: stored.sensor?.id
        ))
        XCTAssertEqual(stored.calculatedValue, 120)
        XCTAssertEqual(try context.count(for: BgReading.fetchRequest()), 1)
    }

    @MainActor
    func testHistoricalCalibrationDoesNotRefineCalibrationOrChangeCurrentValueAndTrend() throws {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = stack.mainManagedObjectContext
        let sensor = Sensor(startDate: session.createdAt, nsManagedObjectContext: context)
        let calibration = Calibration(
            timeStamp: receivedAt.addingTimeInterval(-600),
            sensor: sensor,
            bg: 100,
            rawValue: 100,
            adjustedRawValue: 100,
            sensorConfidence: 1,
            rawTimeStamp: receivedAt.addingTimeInterval(-600),
            slope: 1.1,
            intercept: 4,
            distanceFromEstimate: 0,
            estimateRawAtTimeOfCalibration: 100,
            slopeConfidence: 1,
            deviceName: nil,
            nsManagedObjectContext: context
        )
        let current = BgReading(
            timeStamp: receivedAt,
            sensor: sensor,
            calibration: calibration,
            rawData: 100,
            deviceName: nil,
            nsManagedObjectContext: context
        )
        current.calculatedValue = 114
        current.calculatedValueSlope = 0.02
        current.calibrationFlag = true

        let calibrators: [Calibrator] = [Libre1Calibrator(), Libre1NonFixedSlopeCalibrator()]
        for calibrator in calibrators {
            var previous = [current]
            var calibrations = [calibration]
            let reading = calibrator.createHistoricalBgReading(
                rawData: 847 * ConstantsBloodGlucose.libreMultiplier,
                timeStamp: receivedAt.addingTimeInterval(-300),
                sensor: sensor,
                last3Readings: &previous,
                lastCalibrationsForActiveSensorInLastXDays: &calibrations,
                firstCalibration: calibration,
                lastCalibration: calibration,
                deviceName: nil,
                nsManagedObjectContext: context
            )
            XCTAssertEqual(
                reading.calculatedValue,
                iphoneCalibratedValue(
                    input: 847 * ConstantsBloodGlucose.libreMultiplier,
                    slope: 1.1,
                    intercept: 4,
                    divider: 1_000
                ),
                accuracy: 0.000_001
            )
            XCTAssertEqual(calibration.slope, 1.1)
            XCTAssertEqual(calibration.intercept, 4)
            XCTAssertEqual(calibration.estimateRawAtTimeOfCalibration, 100)
            XCTAssertEqual(current.calculatedValue, 114)
            XCTAssertEqual(current.calculatedValueSlope, 0.02)
        }
    }

    func testHistoricalOutOfOrderEligibilityDoesNotMoveLiveWatermark() {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let now = receivedAt.addingTimeInterval(3_600)
        let live = payload(
            raw: 900,
            previousRaw: 890,
            domain: .xDripRawGlucose,
            sensorTime: 2_000,
            at: now
        )
        let historicalNewer = payload(
            raw: 850,
            previousRaw: 840,
            domain: .xDripRawGlucose,
            sensorTime: 1_500,
            at: now.addingTimeInterval(-600)
        )
        let historicalOlder = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-1_800)
        )
        var liveAcceptance = LibreWatchReadingAcceptancePolicy()
        XCTAssertTrue(liveAcceptance.accept(live, for: session.id, now: now))

        for reading in [historicalNewer, historicalOlder] {
            XCTAssertNil(LibreWatchHistoryPolicy.rejection(
                reading: reading,
                transport: .queuedUserInfo,
                session: session,
                calibration: snapshot,
                ownership: .watch,
                now: now
            ))
        }
        XCTAssertEqual(liveAcceptance.lastSensorTimeInMinutes, live.sensorTimeInMinutes)
        XCTAssertEqual(liveAcceptance.lastReceivedAt, live.receivedAt)
        XCTAssertTrue(liveAcceptance.accept(
            payload(
                raw: 910,
                previousRaw: 900,
                domain: .xDripRawGlucose,
                sensorTime: 2_001,
                at: now.addingTimeInterval(60)
            ),
            for: session.id,
            now: now.addingTimeInterval(60)
        ))
    }

    func testQueuedHistoryRejectsOwnershipSessionCalibrationAndValueMismatches() {
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)
        let now = receivedAt.addingTimeInterval(600)
        let valid = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-300)
        )
        let wrongSession = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-300),
            sessionID: UUID()
        )
        let wrongRevision = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-300),
            revision: snapshot.revision - 1
        )
        let invalidValue = payload(
            native: 0,
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-300)
        )
        let zeroID = payload(
            id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: now.addingTimeInterval(-300)
        )
        let beforeSession = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: session.createdAt.addingTimeInterval(-1)
        )
        let zeroSensorTime = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 0,
            at: now.addingTimeInterval(-300)
        )

        XCTAssertNil(LibreWatchHistoryPolicy.rejection(
            reading: valid, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .watch, now: now
        ))
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: valid, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .iphone, now: now
        ), .missingReceipt)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: wrongSession, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .watch, now: now
        ), .wrongSession)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: wrongRevision, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .watch, now: now
        ), .wrongCalibration)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            reading: invalidValue, transport: .queuedUserInfo, session: session,
            calibration: snapshot, ownership: .watch, now: now
        ), .invalidPayload)
        for invalid in [zeroID, beforeSession, zeroSensorTime] {
            XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
                reading: invalid, transport: .queuedUserInfo, session: session,
                calibration: snapshot, ownership: .watch, now: now
            ), .invalidPayload)
        }
    }

    func testReadingAcceptanceAllowsFreshLowThenNextNormalReading() throws {
        let snapshot = calibration(type: .factoryCalibrated, slope: 1, intercept: 0)
        let low = payload(
            native: 38,
            previousNative: 45,
            raw: 1,
            previousRaw: 2,
            domain: .factoryNativeMGDL,
            sensorTime: 1_000,
            at: receivedAt
        )
        let normal = payload(
            native: 90,
            previousNative: 85,
            raw: 900,
            previousRaw: 850,
            domain: .factoryNativeMGDL,
            sensorTime: 1_001,
            at: receivedAt.addingTimeInterval(60)
        )
        var acceptance = LibreWatchReadingAcceptancePolicy()

        XCTAssertEqual(try XCTUnwrap(snapshot.displayedGlucose(for: low)), 38)
        XCTAssertTrue(acceptance.accept(low, for: session.id, now: receivedAt.addingTimeInterval(1)))
        XCTAssertTrue(acceptance.accept(
            normal,
            for: session.id,
            now: receivedAt.addingTimeInterval(61)
        ))
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.displayedGlucose(for: normal)), 38)
    }

    func testInternalCalibrationMarkerIsNotAClinicalLowButCompletedThirtyNineIsValid() {
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: 92,
                rawData: 92,
                ageAdjustedRawValue: 0,
                finalValue: 92,
                calibrationUsesErrorSentinel: false
            ),
            .valid
        )
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: 38,
                rawData: 0.12,
                ageAdjustedRawValue: 0.12,
                finalValue: 38,
                calibrationUsesErrorSentinel: true
            ),
            .internalCalibrationError
        )
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: 39,
                rawData: 11.7,
                ageAdjustedRawValue: 11.7,
                finalValue: 39,
                calibrationUsesErrorSentinel: true
            ),
            .valid
        )
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: 95,
                rawData: 95,
                ageAdjustedRawValue: 0,
                finalValue: 95,
                calibrationUsesErrorSentinel: false
            ),
            .valid
        )
    }

    func testFreshNativeThirtyEightRemainsAValidPhysiologicalLow() {
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: 38,
                rawData: 38,
                ageAdjustedRawValue: 0,
                finalValue: 38,
                calibrationUsesErrorSentinel: false
            ),
            .valid
        )
    }

    func testTwoUncalibratedRawReadingsRequestInitialCalibrationExactlyOnce() {
        var gate = InitialCalibrationRequestGate()

        XCTAssertFalse(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: false,
            validRawReadingCount: 2,
            initialCalibrationIsRequired: true
        ))
        XCTAssertFalse(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: true,
            validRawReadingCount: 1,
            initialCalibrationIsRequired: true
        ))
        XCTAssertTrue(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: true,
            validRawReadingCount: 2,
            initialCalibrationIsRequired: true
        ))
        XCTAssertFalse(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: true,
            validRawReadingCount: 3,
            initialCalibrationIsRequired: true
        ))
        XCTAssertEqual(gate.requestedSensorID, "sensor-a")
    }

    func testUncalibratedRawReadingsRemainUnavailableToDownstreamConsumers() {
        let readings = [
            (rawValue: 82.0, calculatedValue: 0.0),
            (rawValue: 84.0, calculatedValue: 0.0)
        ]
        var gate = InitialCalibrationRequestGate()

        XCTAssertTrue(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: true,
            validRawReadingCount: readings.count,
            initialCalibrationIsRequired: true
        ))

        let downstreamReadings = readings.filter {
            BgReadingDownstreamPolicy.validity(
                calculatedValue: $0.calculatedValue,
                rawData: $0.rawValue,
                ageAdjustedRawValue: $0.rawValue,
                finalValue: $0.calculatedValue,
                calibrationUsesErrorSentinel: true
            ) == .valid
        }

        XCTAssertTrue(downstreamReadings.isEmpty)
    }

    func testCompletedReadingResumesDownstreamAfterInitialCalibration() {
        var gate = InitialCalibrationRequestGate()
        let completed = (rawValue: 84.0, calculatedValue: 91.0)

        XCTAssertFalse(gate.shouldRequest(
            for: "sensor-a",
            newRawReadingStored: true,
            validRawReadingCount: 2,
            initialCalibrationIsRequired: false
        ))
        XCTAssertEqual(
            BgReadingDownstreamPolicy.validity(
                calculatedValue: completed.calculatedValue,
                rawData: completed.rawValue,
                ageAdjustedRawValue: completed.rawValue,
                finalValue: completed.calculatedValue,
                calibrationUsesErrorSentinel: true
            ),
            .valid
        )
    }

    func testWatchRejectsFailedXDripCalculationInsteadOfDisplayingFalseLow() {
        let failed = payload(
            native: 84,
            previousNative: 83,
            raw: 1,
            previousRaw: 1,
            domain: .xDripRawGlucose
        )
        let completedLow = payload(
            native: 84,
            previousNative: 83,
            raw: 100,
            previousRaw: 100,
            domain: .xDripRawGlucose
        )
        let snapshot = calibration(type: .fixedSlope, slope: 1, intercept: 0)

        XCTAssertNil(snapshot.displayedGlucose(for: failed))
        XCTAssertEqual(snapshot.displayedGlucose(for: completedLow), 39)
    }

    func testHealthKitUploadStateSerializesConcurrentStoreRequestsWithoutSkippingFailures() {
        let first = receivedAt
        let second = receivedAt.addingTimeInterval(60)
        var state = HealthKitUploadState(latestStoredTimeStamp: receivedAt.addingTimeInterval(-60))

        XCTAssertTrue(state.begin(timeStamp: first, now: receivedAt))
        XCTAssertFalse(state.begin(timeStamp: second, now: receivedAt))
        XCTAssertFalse(state.beginReplacement(timeStamp: first))
        XCTAssertTrue(state.beginReplacement(timeStamp: second))
        XCTAssertTrue(state.isInFlight(timeStamp: second))
        state.finishReplacement(timeStamp: second)
        XCTAssertEqual(
            state.finish(timeStamp: second, succeeded: true, now: receivedAt),
            .ignored
        )

        let retryAt = receivedAt.addingTimeInterval(30)
        XCTAssertEqual(
            state.finish(timeStamp: first, succeeded: false, now: receivedAt),
            .retry(retryAt)
        )
        XCTAssertEqual(state.latestStoredTimeStamp, receivedAt.addingTimeInterval(-60))
        XCTAssertFalse(state.begin(timeStamp: first, now: retryAt.addingTimeInterval(-1)))
        XCTAssertTrue(state.begin(timeStamp: first, now: retryAt))
        XCTAssertEqual(
            state.finish(timeStamp: first, succeeded: true, now: retryAt),
            .stored(first)
        )
        XCTAssertTrue(state.begin(timeStamp: second, now: retryAt))
        XCTAssertEqual(
            state.finish(timeStamp: second, succeeded: true, now: retryAt),
            .stored(second)
        )
        state.synchronizeLatestStoredTimeStamp(first)
        XCTAssertEqual(state.latestStoredTimeStamp, second)
    }

    func testColdLaunchWithMatchingWatchOwnerBlocksPhoneBeforeBluetoothStarts() {
        let decision = LibreWatchPhoneStartupDecision.resolve(
            persistedOwnership: .watch,
            persistedSession: session,
            activeSensorUID: session.sensorUID,
            activePatchInfo: session.patchInfo
        )

        XCTAssertEqual(decision.ownership, .watch)
        XCTAssertTrue(decision.phoneConnectionIsBlocked)
        XCTAssertEqual(decision.session?.id, session.id)
    }

    func testCompletedReturnToIPhoneAllowsNormalPhoneConnection() {
        let decision = LibreWatchPhoneStartupDecision.resolve(
            persistedOwnership: .iphone,
            persistedSession: session,
            activeSensorUID: session.sensorUID,
            activePatchInfo: session.patchInfo
        )

        XCTAssertEqual(decision.ownership, .iphone)
        XCTAssertFalse(decision.phoneConnectionIsBlocked)
    }

    func testInterruptedHandoffsStayWithWatchAndSensorChangeCannotCreateDualOwnership() {
        for interrupted in [
            LibreWatchOwnership.releasingToWatch,
            .releasingToPhone,
            .recovery
        ] {
            let decision = LibreWatchPhoneStartupDecision.resolve(
                persistedOwnership: interrupted,
                persistedSession: session,
                activeSensorUID: session.sensorUID,
                activePatchInfo: session.patchInfo
            )
            XCTAssertEqual(decision.ownership, .watch)
            XCTAssertTrue(decision.phoneConnectionIsBlocked)
        }

        let changedSensor = LibreWatchPhoneStartupDecision.resolve(
            persistedOwnership: .watch,
            persistedSession: session,
            activeSensorUID: Data(repeating: 9, count: 8),
            activePatchInfo: session.patchInfo
        )
        XCTAssertEqual(changedSensor.ownership, .iphone)
        XCTAssertFalse(changedSensor.phoneConnectionIsBlocked)
    }

    func testReadingAcceptanceResetsForNewOwnershipSession() {
        let first = payload(
            raw: 800,
            previousRaw: 790,
            domain: .xDripRawGlucose,
            sensorTime: 1_000,
            at: receivedAt
        )
        var acceptance = LibreWatchReadingAcceptancePolicy()
        XCTAssertTrue(acceptance.accept(first, for: session.id, now: receivedAt.addingTimeInterval(1)))

        acceptance.reset(for: session.id)
        XCTAssertTrue(acceptance.accept(first, for: session.id, now: receivedAt.addingTimeInterval(2)))

        acceptance.reset()
        XCTAssertNil(acceptance.sessionID)
        XCTAssertNil(acceptance.lastSensorTimeInMinutes)
        XCTAssertNil(acceptance.lastReceivedAt)
    }

    func testReturningOwnershipToIPhoneStopsRuntimeAndRecovery() {
        XCTAssertTrue(LibreWatchLifecyclePolicy.shouldStopExtendedRuntime(
            ownership: .releasingToPhone
        ))
        XCTAssertTrue(LibreWatchLifecyclePolicy.shouldStopExtendedRuntime(
            ownership: .iphone
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: true,
            extendedRuntimeIsRunning: true,
            ownership: .iphone
        ))
        XCTAssertFalse(LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(
            ownership: .iphone
        ))
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.disconnectRecoveryAction(
                isDeliberate: false,
                systemIsReconnecting: false,
                ownership: .iphone
            ),
            .noAdditionalWork
        )
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.disconnectRecoveryAction(
                isDeliberate: true,
                systemIsReconnecting: false,
                ownership: .watch
            ),
            .finishDeliberateDisconnect
        )
    }

    private var watchAlgorithmParameters: LibreWatchAlgorithmParameters {
        LibreWatchAlgorithmParameters(
            slopeSlope: 0,
            slopeOffset: 0,
            offsetSlope: 0.1,
            offsetOffset: 0,
            extraSlope: 1,
            extraOffset: 0,
            sensorSerialNumber: "TEST-SENSOR"
        )
    }

    private var phoneAlgorithmParameters: Libre1DerivedAlgorithmParameters {
        Libre1DerivedAlgorithmParameters(
            slope_slope: watchAlgorithmParameters.slopeSlope,
            slope_offset: watchAlgorithmParameters.slopeOffset,
            offset_slope: watchAlgorithmParameters.offsetSlope,
            offset_offset: watchAlgorithmParameters.offsetOffset,
            isValidForFooterWithReverseCRCs: 0,
            extraSlope: watchAlgorithmParameters.extraSlope,
            extraOffset: watchAlgorithmParameters.extraOffset,
            sensorSerialNumber: watchAlgorithmParameters.sensorSerialNumber
        )
    }

    private var session: LibreWatchDirectSession {
        LibreWatchDirectSession(
            id: UUID(uuidString: "A0B1C2D3-E4F5-4678-9123-456789ABCDEF")!,
            createdAt: receivedAt.addingTimeInterval(-3_600),
            sensorUID: Data([1, 2, 3, 4, 5, 6, 7, 8]),
            patchInfo: Data([0, 1, 2, 3, 4, 5]),
            sensorSerialNumber: "TEST-SENSOR",
            sensorTypeRawValue: "7F",
            expectedPeripheralName: "AABBCCDDEEFF",
            unlockCode: 1_000,
            unlockCount: 4,
            algorithmParameters: watchAlgorithmParameters
        )
    }

    private func calibration(
        type: LibreWatchCalibrationType,
        slope: Double,
        intercept: Double,
        revision: UInt64 = 10
    ) -> LibreWatchCalibrationSnapshot {
        LibreWatchCalibrationSnapshot(
            activeSensorID: "active-sensor",
            sensorUID: session.sensorUID,
            sensorSerialNumber: session.sensorSerialNumber,
            watchSessionID: session.id,
            calibrationType: type,
            slope: slope,
            intercept: intercept,
            rawValueDivider: type.usesXDripCalibration ? 1_000 : 1,
            calibratedAt: receivedAt.addingTimeInterval(-600),
            revision: revision
        )
    }

    private func payload(
        version: Int = LibreWatchDirectReadingPayload.currentVersion,
        id: UUID = UUID(),
        native: Double = 84.7,
        previousNative: Double = 82.9,
        raw: UInt16,
        previousRaw: UInt16,
        domain: LibreWatchValueDomain,
        sensorTime: UInt16 = 1_234,
        at timestamp: Date? = nil,
        sessionID: UUID? = nil,
        revision: UInt64 = 10
    ) -> LibreWatchDirectReadingPayload {
        LibreWatchDirectReadingPayload(
            version: version,
            id: id,
            sessionID: sessionID ?? session.id,
            valueDomain: domain,
            nativeGlucoseMGDL: native,
            previousNativeGlucoseMGDL: previousNative,
            rawGlucose: raw,
            previousRawGlucose: previousRaw,
            sensorTimeInMinutes: sensorTime,
            receivedAt: timestamp ?? receivedAt,
            calibrationRevision: revision
        )
    }

    private func iphoneCalibratedValue(
        input: Double,
        slope: Double,
        intercept: Double,
        divider: Double
    ) -> Double {
        let calculated = slope * (input / divider) + intercept
        if calculated < 10 { return 38 }
        return min(400, max(39, calculated))
    }

    private func phoneParsedValue(
        frame: Data,
        parameters: Libre1DerivedAlgorithmParameters?
    ) -> Double {
        clearPhoneLibreParserCache()
        defer { clearPhoneLibreParserCache() }
        return Libre2BLEUtilities.parseBLEData(
            frame,
            libre1DerivedAlgorithmParameters: parameters
        ).bleGlucose.first!.glucoseLevelRaw
    }

    private func decryptedFrame(currentRaw: Int, previousRaw: Int) -> Data {
        var frame = Data(repeating: 0, count: Libre2WatchDirectConstants.decryptedFrameLength)
        for sampleIndex in 0 ..< 7 {
            let raw = max(1, currentRaw - sampleIndex * (currentRaw - previousRaw))
            setBits(raw, in: &frame, byteOffset: sampleIndex * 4, bitOffset: 0, bitCount: 14)
            setBits(2_000, in: &frame, byteOffset: sampleIndex * 4, bitOffset: 14, bitCount: 12)
        }
        frame[40] = 0xD2
        frame[41] = 0x04
        return frame
    }

    private func setBits(
        _ value: Int,
        in data: inout Data,
        byteOffset: Int,
        bitOffset: Int,
        bitCount: Int
    ) {
        for index in 0 ..< bitCount {
            let absoluteBit = byteOffset * 8 + bitOffset + index
            let byteIndex = absoluteBit / 8
            let bitMask = UInt8(1 << (absoluteBit % 8))
            if (value & (1 << index)) != 0 {
                data[byteIndex] |= bitMask
            } else {
                data[byteIndex] &= ~bitMask
            }
        }
    }

    private func clearPhoneLibreParserCache() {
        UserDefaults.standard.previousRawGlucoseValues = nil
        UserDefaults.standard.previousRawTemperatureValues = nil
        UserDefaults.standard.previousTemperatureAdjustmentValues = nil
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "LibreWatchValuePipelineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
