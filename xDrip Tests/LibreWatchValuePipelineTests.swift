import XCTest
import CoreData
import Combine
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

    func testForegroundConnectionHasOneSixtySecondDeadline() throws {
        var progress = LibreWatchRecoveryProgress(sessionID: session.id)
        progress.beginConnection(at: receivedAt, applicationIsActive: true)
        let deadline = try XCTUnwrap(progress.deadline)
        XCTAssertEqual(deadline.phase, .connection)
        XCTAssertEqual(deadline.expiresAt, receivedAt.addingTimeInterval(60))

        XCTAssertEqual(
            LibreWatchLifecyclePolicy.reconnectFallbackAction(
                deadline: deadline.expiresAt,
                now: receivedAt.addingTimeInterval(59),
                applicationIsActive: true,
                extendedRuntimeIsRunning: true,
                ownership: .watch
            ),
            .wait(1)
        )
        XCTAssertEqual(
            LibreWatchLifecyclePolicy.reconnectFallbackAction(
                deadline: deadline.expiresAt,
                now: receivedAt.addingTimeInterval(60),
                applicationIsActive: true,
                extendedRuntimeIsRunning: true,
                ownership: .watch
            ),
            .restartConfirmedSensorScan
        )
    }

    func testLifecycleChangesNeverShortenOrExtendCapturedConnectionDeadline() throws {
        for beganActive in [false, true] {
            var progress = LibreWatchRecoveryProgress(sessionID: session.id)
            progress.beginConnection(at: receivedAt, applicationIsActive: beganActive)
            let deadline = try XCTUnwrap(progress.deadline)
            let duration: TimeInterval = beganActive ? 60 : 90
            XCTAssertEqual(deadline.expiresAt, receivedAt.addingTimeInterval(duration))
            for active in [true, false] {
                for runtime in [true, false] {
                    XCTAssertEqual(LibreWatchLifecyclePolicy.reconnectFallbackAction(
                        deadline: deadline.expiresAt, now: receivedAt.addingTimeInterval(20),
                        applicationIsActive: active, extendedRuntimeIsRunning: runtime, ownership: .watch
                    ), active || runtime ? .wait(duration - 20) : .noAdditionalWork)
                    XCTAssertEqual(recoveryAction(peripheral: .connecting, active: active, runtime: runtime,
                                                  system: true, elapsed: 61, phaseDeadline: deadline, trigger: .scene),
                                   beganActive ? .restartConfirmedSensorScan : .waitForSystemReconnect)
                    XCTAssertEqual(progress.deadline, deadline)
                }
            }
        }
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

    func testLiveTransportRemainsFreshOrderedAndIndependentOfHistory() {
        var live = LibreWatchReadingAcceptancePolicy()
        let reading = historyPayload(at: receivedAt)
        XCTAssertTrue(live.accept(reading, for: session.id, now: receivedAt.addingTimeInterval(1)))
        let older = historyPayload(at: receivedAt.addingTimeInterval(-60), sensorTime: 1_233)
        XCTAssertNil(historyRejection(older, now: receivedAt.addingTimeInterval(300)))
        XCTAssertEqual(live.lastReceivedAt, reading.receivedAt)
        XCTAssertEqual(live.lastSensorTimeInMinutes, reading.sensorTimeInMinutes)
        XCTAssertFalse(live.accept(older, for: session.id, now: receivedAt.addingTimeInterval(300)))
    }

    func testOldInteractiveReadingCannotEnterEitherLiveOrHistoricalPath() {
        let reading = historyPayload(at: receivedAt)
        var live = LibreWatchReadingAcceptancePolicy()
        XCTAssertFalse(live.accept(reading, for: session.id, now: receivedAt.addingTimeInterval(181)))
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            for: reading, transport: .interactiveMessage, session: session, calibration: historyCalibration,
            ownership: .watch, receipt: nil, now: receivedAt.addingTimeInterval(181)
        ), .invalidPayload)
    }

    func testQueuedReadingOlderThanThreeMinutesAndUnderTwelveHoursIsAccepted() {
        XCTAssertNil(historyRejection(historyPayload(at: receivedAt), now: receivedAt.addingTimeInterval(3_600)))
    }

    func testQueuedReadingOlderThanTwelveHoursIsRejected() {
        XCTAssertEqual(historyRejection(historyPayload(at: receivedAt), now: receivedAt.addingTimeInterval(43_201)), .tooOld)
    }

    func testHistoricalReadingsCanArriveOutOfOrderWithoutChangingLiveWatermark() {
        var live = LibreWatchReadingAcceptancePolicy()
        let latest = historyPayload(at: receivedAt.addingTimeInterval(120), sensorTime: 1_236)
        XCTAssertTrue(live.accept(latest, for: session.id, now: latest.receivedAt))
        for minute in [1, -5, 0, -8] {
            let older = historyPayload(at: receivedAt.addingTimeInterval(Double(minute * 60)), sensorTime: UInt16(1_234 + minute))
            XCTAssertNil(historyRejection(older, now: latest.receivedAt))
        }
        XCTAssertEqual(live.lastReceivedAt, latest.receivedAt)
        XCTAssertEqual(live.acceptedPayloadIDs, [latest.id])
    }

    @MainActor
    func testBackfillUsesPersistentPayloadIdentityAndPreservesPhoneCollision() async throws {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = stack.mainManagedObjectContext
        let sensor = Sensor(startDate: session.createdAt, nsManagedObjectContext: context)
        let reading = historyPayload(at: receivedAt)
        let phone = BgReading(timeStamp: receivedAt, sensor: sensor, calibration: nil, rawData: 120,
                              deviceName: nil, nsManagedObjectContext: context)
        phone.calculatedValue = 120
        phone.id = reading.id.uuidString
        XCTAssertTrue(stack.saveChanges())
        let sensorID = sensor.id
        // Drain the existing asynchronous parent save, then reload by the actual payload
        // identity rather than retaining a temporary child-context NSManagedObjectID.
        await stack.privateManagedObjectContext.perform {}
        context.reset()
        let request: NSFetchRequest<BgReading> = BgReading.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", reading.id.uuidString)
        let stored = try XCTUnwrap(context.fetch(request).first)
        XCTAssertFalse(stored.objectID.isTemporaryID)
        XCTAssertTrue(LibreWatchHistoryPolicy.collides(
            payloadID: reading.id.uuidString, measuredAt: receivedAt.addingTimeInterval(-600), sensorID: sensorID,
            existingID: stored.id, existingAt: stored.timeStamp, existingSensorID: stored.sensor?.id
        ))
        XCTAssertTrue(LibreWatchHistoryPolicy.collides(
            payloadID: UUID().uuidString, measuredAt: receivedAt.addingTimeInterval(5), sensorID: stored.sensor!.id,
            existingID: stored.id, existingAt: stored.timeStamp, existingSensorID: stored.sensor?.id
        ))
        XCTAssertEqual(stored.calculatedValue, 120) // the phone's point is not overwritten
        XCTAssertEqual(try context.count(for: BgReading.fetchRequest()), 1)
    }

    func testHistoricalValidationRejectsWrongSessionSensorCalibrationDomainAndValue() {
        let reading = historyPayload(at: receivedAt)
        let wrongSession = payload(raw: 847, previousRaw: 830, domain: .factoryNativeMGDL, sessionID: UUID())
        XCTAssertEqual(historyRejection(wrongSession), .wrongSession)
        let wrongSensor = calibration(type: .factoryCalibrated, slope: 1, intercept: 0, sensorUID: Data(repeating: 9, count: 8))
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            for: reading, transport: .queuedUserInfo, session: session, calibration: wrongSensor,
            ownership: .watch, receipt: nil, now: receivedAt
        ), .wrongSensor)
        XCTAssertEqual(historyRejection(payload(raw: 847, previousRaw: 830, domain: .factoryNativeMGDL, revision: 9)), .wrongCalibration)
        XCTAssertEqual(historyRejection(payload(raw: 847, previousRaw: 830, domain: .xDripRawGlucose)), .wrongCalibration)
        XCTAssertEqual(historyRejection(payload(native: 0, raw: 847, previousRaw: 830, domain: .factoryNativeMGDL)), .invalidValue)
        XCTAssertEqual(historyRejection(payload(version: 1, raw: 847, previousRaw: 830, domain: .factoryNativeMGDL)), .invalidValue)
        XCTAssertEqual(historyRejection(historyPayload(at: receivedAt.addingTimeInterval(60)), now: receivedAt), .invalidTime)
    }

    func testPreCutoffQueuedReadingAcceptedDuringRelease() throws {
        let receipt = try XCTUnwrap(makeReleaseReceipt())
        XCTAssertEqual(receipt.state, .pending)
        XCTAssertNil(historyRejection(historyPayload(at: receivedAt), ownership: .releasingToPhone,
                                      receipt: receipt, now: receivedAt.addingTimeInterval(600)))
    }

    func testPreCutoffQueuedReadingAcceptedAfterCompletedReturnToPhoneAndReload() throws {
        let defaults = isolatedDefaults()
        var receipt = try XCTUnwrap(makeReleaseReceipt())
        receipt.complete()
        LibreWatchSessionStore.saveReleaseReceipt(receipt, defaults: defaults)
        LibreWatchSessionStore.saveOwnership(.iphone, defaults: defaults)
        let restored = try XCTUnwrap(LibreWatchSessionStore.loadReleaseReceipt(defaults: defaults))
        XCTAssertEqual(restored, receipt)
        XCTAssertNil(historyRejection(historyPayload(at: receivedAt),
                                      ownership: LibreWatchSessionStore.loadOwnership(defaults: defaults),
                                      receipt: restored, now: receivedAt.addingTimeInterval(600)))
    }

    func testPostCutoffReadingRejectedInEveryHistoricalOwnershipState() throws {
        var receipt = try XCTUnwrap(makeReleaseReceipt())
        receipt.complete()
        let after = historyPayload(at: receipt.cutoff.addingTimeInterval(1))
        for owner in [LibreWatchOwnership.watch, .releasingToPhone, .iphone] {
            XCTAssertEqual(historyRejection(after, ownership: owner, receipt: receipt,
                                             now: receipt.cutoff.addingTimeInterval(2)), .afterCutoff)
        }
    }

    func testFailedReleaseClearsReceiptAndRestoresConservativeWatchOwner() throws {
        let defaults = isolatedDefaults()
        LibreWatchSessionStore.saveSession(session, defaults: defaults)
        LibreWatchSessionStore.saveReleaseReceipt(try XCTUnwrap(makeReleaseReceipt()), defaults: defaults)
        LibreWatchSessionStore.saveOwnership(.releasingToPhone, defaults: defaults)
        // Same rollback operations as the failed returnSensorToPhone branch; never enable iPhone.
        LibreWatchSessionStore.clearReleaseReceipt(defaults: defaults)
        LibreWatchSessionStore.saveOwnership(.watch, defaults: defaults)
        XCTAssertNil(LibreWatchSessionStore.loadReleaseReceipt(defaults: defaults))
        let decision = LibreWatchPhoneStartupDecision.resolve(
            persistedOwnership: LibreWatchSessionStore.loadOwnership(defaults: defaults),
            persistedSession: LibreWatchSessionStore.loadSession(defaults: defaults),
            activeSensorUID: session.sensorUID, activePatchInfo: session.patchInfo
        )
        XCTAssertTrue(decision.phoneConnectionIsBlocked)
        XCTAssertEqual(decision.ownership, .watch)
    }

    func testReceiptCannotAuthorizeAnotherCalibrationExpiredDataOrUncompletedPhoneReturn() throws {
        let receipt = try XCTUnwrap(makeReleaseReceipt())
        let reading = historyPayload(at: receivedAt)
        XCTAssertEqual(historyRejection(reading, ownership: .iphone, receipt: receipt), .missingReceipt)
        XCTAssertEqual(historyRejection(reading, ownership: .iphone, receipt: nil), .missingReceipt)
        let otherCalibration = calibration(type: .factoryCalibrated, slope: 1, intercept: 1)
        XCTAssertEqual(LibreWatchHistoryPolicy.rejection(
            for: reading, transport: .queuedUserInfo, session: session, calibration: otherCalibration,
            ownership: .releasingToPhone, receipt: receipt, now: receivedAt.addingTimeInterval(600)
        ), .missingReceipt)
        XCTAssertLessThanOrEqual(receipt.expiresAt.timeIntervalSince(receipt.cutoff), 43_200)
        XCTAssertEqual(historyRejection(reading, ownership: .iphone, receipt: receipt,
                                       now: receipt.expiresAt.addingTimeInterval(1)), .tooOld)
    }

    func testSessionChangeClearsReleaseReceiptAndWatchGraphCache() throws {
        let defaults = isolatedDefaults()
        LibreWatchSessionStore.saveSession(session, defaults: defaults)
        LibreWatchSessionStore.saveReleaseReceipt(try XCTUnwrap(makeReleaseReceipt()), defaults: defaults)
        LibreWatchSessionStore.saveHistory([historyPayload(at: receivedAt)], defaults: defaults)
        let newSession = LibreWatchDirectSession(
            sensorUID: session.sensorUID, patchInfo: session.patchInfo, sensorSerialNumber: session.sensorSerialNumber,
            sensorTypeRawValue: session.sensorTypeRawValue, expectedPeripheralName: session.expectedPeripheralName,
            unlockCode: session.unlockCode, unlockCount: session.unlockCount, algorithmParameters: session.algorithmParameters
        )
        LibreWatchSessionStore.saveSession(newSession, defaults: defaults)
        XCTAssertNil(LibreWatchSessionStore.loadReleaseReceipt(defaults: defaults))
        XCTAssertTrue(LibreWatchSessionStore.loadHistory(defaults: defaults).isEmpty)
    }

    func testGraphMergeRetainsWatchOnlyPointsAndPhoneWinsWithoutInterpolation() {
        let phone = [LibreWatchHistoryMerge.Point(date: receivedAt, glucose: 120)]
        let watch = [LibreWatchHistoryMerge.Point(date: receivedAt, glucose: 118),
                     .init(date: receivedAt.addingTimeInterval(-60), glucose: 117),
                     .init(date: receivedAt.addingTimeInterval(-43_201), glucose: 90)]
        let merged = LibreWatchHistoryMerge.merge(phone: phone, watch: watch + watch, now: receivedAt)
        XCTAssertEqual(merged, [phone[0], watch[1]])
        XCTAssertEqual(LibreWatchHistoryMerge.merge(phone: merged, watch: watch, now: receivedAt), merged)
    }

    func testDocumentedOfflineTimelineKeepsEveryActualQueuedPointAndInventsNone() throws {
        let parser = ISO8601DateFormatter()
        let lastPhone = try XCTUnwrap(parser.date(from: "2026-09-02T10:43:59Z"))
        let deliveredAt = try XCTUnwrap(parser.date(from: "2026-09-02T11:43:47Z"))
        // The fixture intentionally has a minute with NO received frame. Never fill that minute.
        let times = (1 ... 57).filter { $0 != 17 }.map { lastPhone.addingTimeInterval(Double($0 * 60)) } +
            [try XCTUnwrap(parser.date(from: "2026-09-02T11:42:00Z")),
             try XCTUnwrap(parser.date(from: "2026-09-02T11:43:01Z"))]
        let queued = times.enumerated().map { historyPayload(at: $0.element, sensorTime: UInt16(1_235 + $0.offset)) }
        var persisted = [UUID: LibreWatchDirectReadingPayload]()
        for reading in Array(queued.reversed()) + queued {
            XCTAssertNil(historyRejection(reading, now: deliveredAt))
            persisted[reading.id] = reading
        }
        XCTAssertEqual(persisted.count, times.count)
        XCTAssertEqual(Set(persisted.values.map(\.receivedAt)), Set(times))
        let graph = LibreWatchHistoryMerge.merge(
            phone: [.init(date: lastPhone, glucose: 100)],
            watch: persisted.values.map { .init(date: $0.receivedAt, glucose: $0.nativeGlucoseMGDL) }, now: deliveredAt
        )
        XCTAssertEqual(graph.count, times.count + 1)
        XCTAssertFalse(graph.contains { $0.date == lastPhone.addingTimeInterval(17 * 60) })
    }

    @MainActor
    func testHistoricalCalibrationDoesNotRefineCalibrationOrChangeCurrentValueAndTrend() throws {
        let stack = CoreDataManager(inMemoryModelName: ConstantsCoreData.modelName)
        let context = stack.mainManagedObjectContext
        let sensor = Sensor(startDate: session.createdAt, nsManagedObjectContext: context)
        let calibration = Calibration(
            timeStamp: receivedAt.addingTimeInterval(-600), sensor: sensor, bg: 100, rawValue: 100,
            adjustedRawValue: 100, sensorConfidence: 1, rawTimeStamp: receivedAt.addingTimeInterval(-600),
            slope: 1.1, intercept: 4, distanceFromEstimate: 0, estimateRawAtTimeOfCalibration: 100,
            slopeConfidence: 1, deviceName: nil, nsManagedObjectContext: context
        )
        let current = BgReading(timeStamp: receivedAt, sensor: sensor, calibration: calibration, rawData: 100,
                                deviceName: nil, nsManagedObjectContext: context)
        current.calculatedValue = 114
        current.calculatedValueSlope = 0.02
        current.calibrationFlag = true
        let calibrators: [Calibrator] = [Libre1Calibrator(), Libre1NonFixedSlopeCalibrator()]
        for calibrator in calibrators {
            var previous = [current]
            var calibrations = [calibration]
            let reading = calibrator.createHistoricalBgReading(
                rawData: 847 * ConstantsBloodGlucose.libreMultiplier, timeStamp: receivedAt.addingTimeInterval(-300),
                sensor: sensor, last3Readings: &previous, lastCalibrationsForActiveSensorInLastXDays: &calibrations,
                firstCalibration: calibration, lastCalibration: calibration, deviceName: nil, nsManagedObjectContext: context
            )
            XCTAssertEqual(reading.calculatedValue, iphoneCalibratedValue(
                input: 847 * ConstantsBloodGlucose.libreMultiplier, slope: 1.1, intercept: 4, divider: 1_000
            ), accuracy: 0.000_001)
            XCTAssertEqual(calibration.slope, 1.1)
            XCTAssertEqual(calibration.intercept, 4)
            XCTAssertEqual(calibration.estimateRawAtTimeOfCalibration, 100)
            XCTAssertEqual(current.calculatedValue, 114)
            XCTAssertEqual(current.calculatedValueSlope, 0.02)
        }
    }

    func testHistoricalNativeLowIsStillARealValidReading() {
        let genuineLow = payload(native: 38, previousNative: 40, raw: 380, previousRaw: 400, domain: .factoryNativeMGDL)
        XCTAssertNil(historyRejection(genuineLow, now: receivedAt.addingTimeInterval(600)))
        XCTAssertEqual(historyCalibration.displayedGlucose(for: genuineLow), 38)
    }

    @MainActor
    func testRecoveryObserverReadsCommittedOwnershipInsteadOfPublishedWillSet() async {
        let fixture = RecoveryOwnershipFixture()
        let delivered = expectation(description: "Ownership committed before recovery reads it")
        let observation = fixture.$ownership.dropFirst().receive(on: DispatchQueue.main).sink { owner in
            XCTAssertEqual(owner, .watch)
            XCTAssertEqual(fixture.ownership, .watch)
            delivered.fulfill()
        }
        fixture.ownership = .watch
        await fulfillment(of: [delivered], timeout: 1)
        withExtendedLifetime(observation) {}
    }

    private final class RecoveryOwnershipFixture {
        @Published var ownership: LibreWatchOwnership = .iphone
    }

    func testRecoveryDecisionForActiveAndInactiveDisconnects() {
        for active in [true, false] {
            XCTAssertEqual(recoveryAction(active: active, system: true), .waitForSystemReconnect)
            XCTAssertEqual(recoveryAction(active: active), .connectConfirmedSensor)
        }
    }

    func testFailedConnectionHasAnEventDrivenScanWithoutRuntime() {
        XCTAssertEqual(recoveryAction(active: false, trigger: .connectionFailed), .scanConfirmedSensor)
        XCTAssertEqual(recoveryAction(active: false, poweredOn: false, trigger: .connectionFailed), .waitForBluetooth)
    }

    func testRecoveryEpisodeAndFixedDeadlineSurviveSuspensionRestorationAndRetries() throws {
        var progress = LibreWatchRecoveryProgress(sessionID: session.id)
        progress.begin(at: receivedAt)
        XCTAssertNil(progress.attemptStartedAt) // scanning/episode start creates no BLE deadline
        progress.beginConnection(at: receivedAt, applicationIsActive: false)
        let deadline = try XCTUnwrap(progress.deadline)
        progress.begin(at: receivedAt.addingTimeInterval(60))
        var restored = try JSONDecoder().decode(LibreWatchRecoveryProgress.self, from: JSONEncoder().encode(progress))
        restored.restoreConnecting(at: receivedAt.addingTimeInterval(400))
        XCTAssertEqual(restored.startedAt, receivedAt)
        XCTAssertEqual(restored.attemptStartedAt, receivedAt)
        XCTAssertEqual(restored.deadline, deadline) // expiration does not grant another 90 seconds
        XCTAssertEqual(recoveryAction(active: true, system: true, elapsed: 15, phaseDeadline: deadline, trigger: .scene), .waitForSystemReconnect)
        XCTAssertEqual(recoveryAction(active: false, system: true, elapsed: 400, phaseDeadline: deadline, trigger: .restoration), .restartConfirmedSensorScan)
        progress.beginConnection(at: receivedAt.addingTimeInterval(400), applicationIsActive: true)
        XCTAssertEqual(progress.startedAt, receivedAt) // whole outage is not hidden by a new attempt
        XCTAssertEqual(progress.attemptStartedAt, receivedAt.addingTimeInterval(400))
        progress.beginSetup(at: receivedAt.addingTimeInterval(405))
        XCTAssertEqual(progress.startedAt, receivedAt)
        progress.receivedPacket(at: receivedAt.addingTimeInterval(410))
        XCTAssertNil(progress.startedAt)
        XCTAssertNil(progress.attemptStartedAt)
        XCTAssertNil(progress.deadline)
    }

    func testRestorationSelectsExactlyOneNextOperationForEachPeripheralState() {
        XCTAssertEqual(recoveryAction(peripheral: .absent, active: false, trigger: .restoration), .scanConfirmedSensor)
        XCTAssertEqual(recoveryAction(peripheral: .disconnected, active: false, trigger: .restoration), .connectConfirmedSensor)
        XCTAssertEqual(recoveryAction(peripheral: .connecting, active: false, system: true, trigger: .restoration), .waitForSystemReconnect)
        XCTAssertEqual(recoveryAction(peripheral: .connected, active: false, trigger: .restoration), .discoverServices)
        XCTAssertEqual(recoveryAction(peripheral: .disconnecting, active: false, trigger: .restoration), .waitForCancellation)
    }

    func testPoweredOnCallbackResumesRecoveryWithoutSceneActivation() {
        XCTAssertEqual(recoveryAction(active: false, poweredOn: false, trigger: .bluetooth), .waitForBluetooth)
        XCTAssertEqual(recoveryAction(active: false, poweredOn: true, trigger: .bluetooth), .connectConfirmedSensor)
    }

    func testManualConnectAndCancellationNeverStartParallelWork() {
        XCTAssertEqual(recoveryAction(manual: true), .waitForConnection)
        XCTAssertEqual(recoveryAction(system: true, scanning: true), .waitForSystemReconnect)
        XCTAssertEqual(recoveryAction(peripheral: .disconnecting, active: false, cancelling: true), .waitForCancellation)
        XCTAssertEqual(recoveryAction(active: false, cancelling: true), .scanConfirmedSensor)
        XCTAssertEqual(recoveryAction(peripheral: .absent, active: false, scanning: true), .scanConfirmedSensor)
    }

    func testTimestampedDisconnectGateRejectsDuplicatesButAllowsNextRealDisconnect() {
        var gate = LibreWatchDisconnectGate()
        let first = receivedAt.addingTimeInterval(5)
        XCTAssertTrue(gate.accept(disconnectedAt: first))
        XCTAssertFalse(gate.accept(disconnectedAt: first))
        XCTAssertFalse(gate.accept(disconnectedAt: first)) // delayed callback from previous connection
        // didConnect may itself have arrived much later; its delivery time is not a cutoff.
        XCTAssertTrue(gate.accept(disconnectedAt: receivedAt.addingTimeInterval(6)))
        XCTAssertTrue(gate.accept(disconnectedAt: receivedAt.addingTimeInterval(15)))
        XCTAssertFalse(LibreWatchDisconnectGate.useLegacyCallback(modernCallbackAvailable: true))
        XCTAssertTrue(LibreWatchDisconnectGate.useLegacyCallback(modernCallbackAvailable: false))
    }

    func testNoDataIsCheckedAtNextCallbackIndependentlyOfDiagnosticStage() {
        XCTAssertEqual(recoveryAction(peripheral: .connected, active: false, notifications: true,
                                      lastActivity: receivedAt, elapsed: 181, trigger: .packet), .restartConfirmedSensorScan)
        XCTAssertEqual(recoveryAction(peripheral: .connected, active: true, notifications: true,
                                      lastActivity: receivedAt, elapsed: 121, trigger: .scene), .restartConfirmedSensorScan)
        // A fresh accepted packet wins over an old reconnect deadline.
        XCTAssertEqual(recoveryAction(peripheral: .connected, notifications: true,
                                      lastActivity: receivedAt.addingTimeInterval(181), elapsed: 181, trigger: .packet), .waitForNotifications)
    }

    func testInactiveTimerDoesNotStartRecoveryOrRepeatedScanning() {
        XCTAssertEqual(recoveryAction(active: false, elapsed: 600, trigger: .timer), .waitForExecution)
        XCTAssertEqual(recoveryAction(peripheral: .absent, active: false, elapsed: 600, trigger: .timer), .waitForExecution)
        XCTAssertEqual(recoveryAction(active: false, runtime: true, system: true, elapsed: 91, trigger: .timer), .restartConfirmedSensorScan)
    }

    func testFreshPartialFrameFinishesBeforeNoDataRecoveryCancelsConnection() {
        XCTAssertEqual(recoveryAction(peripheral: .connected, notifications: true, receivingFrame: true,
                                      lastActivity: receivedAt, elapsed: 181, trigger: .packet), .waitForNotifications)
        XCTAssertEqual(recoveryAction(peripheral: .connected, notifications: true, receivingFrame: false,
                                      lastActivity: receivedAt, elapsed: 185, trigger: .timer), .restartConfirmedSensorScan)
    }

    func testRecoveryStopsForEveryNonWatchOwnerAndInvalidSession() {
        for owner in [LibreWatchOwnership.iphone, .releasingToPhone, .releasingToWatch, .recovery] {
            XCTAssertEqual(recoveryAction(system: true, elapsed: 600, owner: owner), .stopped)
        }
        XCTAssertEqual(recoveryAction(validSession: false), .stopped)
    }

    func testConnectedSetupUsesSixtySecondsOfInactivityNotOldConnectionAge() {
        XCTAssertEqual(recoveryAction(peripheral: .connected, setup: true, elapsed: 13, trigger: .setup), .waitForConnection)
        XCTAssertEqual(recoveryAction(peripheral: .connected, setup: true, elapsed: 1, trigger: .setup), .waitForConnection)
        XCTAssertEqual(recoveryAction(peripheral: .connected, setup: true, elapsed: 60, trigger: .timer), .restartConfirmedSensorScan)
        XCTAssertEqual(recoveryAction(active: false, trigger: .setupFailed), .scanConfirmedSensor)
    }

    func testAcceptedDidConnectDiscardsExpiredConnectionDeadlineBeforeRecoveryEvaluation() throws {
        var progress = LibreWatchRecoveryProgress(sessionID: session.id)
        progress.beginConnection(at: receivedAt, applicationIsActive: true)
        let old = try XCTUnwrap(progress.deadline)
        let connectedAt = receivedAt.addingTimeInterval(91)
        // The peripheral has connected, but its callback/timer were queued during suspension.
        XCTAssertEqual(recoveryAction(peripheral: .connected, elapsed: 91, phaseDeadline: old, trigger: .connected), .discoverServices)
        progress.beginSetup(at: connectedAt)
        XCTAssertNil(progress.attemptStartedAt)
        XCTAssertEqual(progress.deadline?.phase, .setup)
        XCTAssertEqual(progress.deadline?.expiresAt, connectedAt.addingTimeInterval(60))
        XCTAssertEqual(progress.startedAt, receivedAt)
        XCTAssertFalse(timeoutIsCurrent(old, progress: progress, at: connectedAt))
        XCTAssertEqual(recoveryAction(peripheral: .connected, setup: true, elapsed: 104,
                                      phaseDeadline: progress.deadline, trigger: .scene), .waitForConnection)
    }

    func testEachCurrentGATTProgressRefreshesWatchdogAndUnlockEndsSetup() throws {
        var progress = LibreWatchRecoveryProgress(sessionID: session.id)
        progress.beginSetup(at: receivedAt)
        let generation = try XCTUnwrap(progress.setupGeneration)
        for (index, stage) in LibreWatchSetupStage.allCases.enumerated() {
            let old = try XCTUnwrap(progress.deadline)
            let now = receivedAt.addingTimeInterval(Double(index + 1) * 59)
            XCTAssertTrue(progress.recordSetupProgress(after: stage, generation: generation, at: now))
            XCTAssertFalse(timeoutIsCurrent(old, progress: progress, at: old.expiresAt))
            XCTAssertEqual(progress.startedAt, receivedAt)
            if stage == .unlock {
                XCTAssertNil(progress.deadline)
                XCTAssertNil(progress.setupGeneration)
                XCTAssertNil(progress.setupStage)
                XCTAssertEqual(recoveryAction(peripheral: .connected, notifications: true,
                                              lastActivity: now, elapsed: 236, trigger: .setup), .waitForNotifications)
            } else {
                XCTAssertEqual(progress.deadline?.expiresAt, now.addingTimeInterval(60))
                XCTAssertNotEqual(progress.deadline?.token, old.token)
                XCTAssertEqual(progress.setupGeneration, generation)
            }
        }
    }

    func testSuccessfulBoundaryCallbackWinsBeforeTimeoutStartsCancellation() throws {
        var progress = LibreWatchRecoveryProgress(sessionID: session.id)
        progress.beginSetup(at: receivedAt)
        let old = try XCTUnwrap(progress.deadline)
        XCTAssertTrue(timeoutIsCurrent(old, progress: progress, at: old.expiresAt))
        // Serial callback runs first, even at exactly the watchdog deadline.
        XCTAssertTrue(progress.recordSetupProgress(after: .services, generation: progress.setupGeneration, at: old.expiresAt))
        XCTAssertFalse(timeoutIsCurrent(old, progress: progress, at: old.expiresAt))
        XCTAssertEqual(progress.deadline?.expiresAt, old.expiresAt.addingTimeInterval(60))
        XCTAssertEqual(recoveryAction(peripheral: .connected, setup: true, elapsed: 60,
                                      phaseDeadline: progress.deadline, trigger: .timer), .waitForConnection)
    }

    func testTimeoutWhichAlreadyStartedCancellationRejectsLaterSetupProgress() throws {
        var progress = LibreWatchRecoveryProgress(sessionID: session.id)
        progress.beginSetup(at: receivedAt)
        let generation = progress.setupGeneration
        let deadline = try XCTUnwrap(progress.deadline)
        XCTAssertTrue(timeoutIsCurrent(deadline, progress: progress, at: deadline.expiresAt))
        // beginControlledSensorRecovery invalidates the phase before cancelPeripheralConnection.
        progress.invalidatePhase()
        XCTAssertFalse(progress.recordSetupProgress(after: .services, generation: generation, at: deadline.expiresAt))
        XCTAssertNil(progress.deadline)
        XCTAssertEqual(progress.startedAt, receivedAt)
    }

    func testSetupCallbackRequiresCurrentStageAndGeneration() {
        var progress = LibreWatchRecoveryProgress(sessionID: session.id)
        progress.beginSetup(at: receivedAt)
        let generation = progress.setupGeneration
        XCTAssertFalse(progress.recordSetupProgress(after: .notifications, generation: generation, at: receivedAt))
        XCTAssertFalse(progress.recordSetupProgress(after: .services, generation: UUID(), at: receivedAt))
        XCTAssertTrue(progress.recordSetupProgress(after: .services, generation: generation, at: receivedAt))
        XCTAssertFalse(progress.recordSetupProgress(after: .services, generation: generation, at: receivedAt))
        progress.beginSetup(at: receivedAt.addingTimeInterval(1))
        XCTAssertFalse(progress.recordSetupProgress(after: .services, generation: generation, at: receivedAt))
    }

    func testStaleTimersCannotCancelLaterAttemptsSetupOrAcceptedPackets() throws {
        var progress = LibreWatchRecoveryProgress(sessionID: session.id)
        progress.beginConnection(at: receivedAt, applicationIsActive: true)
        let first = try XCTUnwrap(progress.deadline)
        progress.beginConnection(at: receivedAt.addingTimeInterval(60), applicationIsActive: false)
        XCTAssertFalse(timeoutIsCurrent(first, progress: progress, at: receivedAt.addingTimeInterval(200)))
        let second = try XCTUnwrap(progress.deadline)
        progress.beginSetup(at: receivedAt.addingTimeInterval(70))
        XCTAssertFalse(timeoutIsCurrent(second, progress: progress, at: receivedAt.addingTimeInterval(200)))
        let setup = try XCTUnwrap(progress.deadline)
        progress.receivedPacket(at: receivedAt.addingTimeInterval(71))
        XCTAssertFalse(timeoutIsCurrent(setup, progress: progress, at: receivedAt.addingTimeInterval(200)))
        XCTAssertNil(progress.deadline)
        XCTAssertNil(progress.startedAt)
    }

    func testTimeoutRequiresMatchingSessionOwnerPhaseAndUnhealthyNotifications() throws {
        var progress = LibreWatchRecoveryProgress(sessionID: session.id)
        progress.beginConnection(at: receivedAt, applicationIsActive: true)
        let deadline = try XCTUnwrap(progress.deadline)
        XCTAssertFalse(timeoutIsCurrent(deadline, progress: progress, at: receivedAt.addingTimeInterval(59)))
        XCTAssertTrue(timeoutIsCurrent(deadline, progress: progress, at: deadline.expiresAt))
        for owner in [LibreWatchOwnership.iphone, .releasingToWatch, .releasingToPhone, .recovery] {
            XCTAssertFalse(progress.timeoutIsCurrent(deadline, sessionID: session.id, ownership: owner,
                                                    cancelling: false, notificationsReady: false, now: deadline.expiresAt))
        }
        XCTAssertFalse(progress.timeoutIsCurrent(deadline, sessionID: UUID(), ownership: .watch,
                                                cancelling: false, notificationsReady: false, now: deadline.expiresAt))
        XCTAssertFalse(progress.timeoutIsCurrent(deadline, sessionID: session.id, ownership: .watch,
                                                cancelling: true, notificationsReady: false, now: deadline.expiresAt))
        XCTAssertFalse(progress.timeoutIsCurrent(deadline, sessionID: session.id, ownership: .watch,
                                                cancelling: false, notificationsReady: true, now: deadline.expiresAt))
        progress.stop()
        XCTAssertNil(progress.startedAt)
        XCTAssertFalse(timeoutIsCurrent(deadline, progress: progress, at: deadline.expiresAt))
    }

    func testLegacyConnectingMigrationPersistsOneNinetySecondDeadline() throws {
        var progress = try legacyRecoveryProgress(attempt: receivedAt)
        XCTAssertNil(progress.deadline)
        progress.restoreConnecting(at: receivedAt.addingTimeInterval(20))
        let deadline = try XCTUnwrap(progress.deadline)
        XCTAssertEqual(deadline.expiresAt, receivedAt.addingTimeInterval(90))
        var reloaded = try JSONDecoder().decode(LibreWatchRecoveryProgress.self, from: JSONEncoder().encode(progress))
        reloaded.restoreConnecting(at: receivedAt.addingTimeInterval(200))
        XCTAssertEqual(reloaded.deadline, deadline)
        XCTAssertEqual(reloaded.startedAt, receivedAt)
        XCTAssertEqual(recoveryAction(peripheral: .connecting, active: true, system: true, elapsed: 20,
                                      phaseDeadline: reloaded.deadline, trigger: .scene), .waitForSystemReconnect)
        XCTAssertEqual(recoveryAction(peripheral: .connecting, active: true, system: true, elapsed: 90,
                                      phaseDeadline: reloaded.deadline, trigger: .restoration), .restartConfirmedSensorScan)
    }

    func testRestoredConnectingWithoutUsableLegacyTimeGetsOneNinetySecondDeadline() throws {
        for attempt in [nil, receivedAt.addingTimeInterval(1_000)] as [Date?] {
            var progress = try legacyRecoveryProgress(attempt: attempt)
            let now = receivedAt.addingTimeInterval(100)
            progress.restoreConnecting(at: now)
            let deadline = try XCTUnwrap(progress.deadline)
            XCTAssertEqual(deadline.expiresAt, now.addingTimeInterval(90))
            progress.restoreConnecting(at: now.addingTimeInterval(10))
            XCTAssertEqual(progress.deadline, deadline)
        }
    }

    func testRestoredConnectedDiscardsLegacyConnectionAgeAndStartsFreshSetup() throws {
        var progress = try legacyRecoveryProgress(attempt: receivedAt)
        let now = receivedAt.addingTimeInterval(4_000)
        progress.beginSetup(at: now)
        XCTAssertNil(progress.attemptStartedAt)
        XCTAssertEqual(progress.deadline?.phase, .setup)
        XCTAssertEqual(progress.deadline?.expiresAt, now.addingTimeInterval(60))
        XCTAssertEqual(progress.startedAt, receivedAt)
        XCTAssertEqual(recoveryAction(peripheral: .connected, setup: true, elapsed: 4_013,
                                      phaseDeadline: progress.deadline, trigger: .timer), .waitForConnection)
    }

    func testExplicitConnectionAndSetupErrorsDoNotWaitForAnyPhaseDeadline() {
        for trigger in [LibreWatchRecoveryTrigger.connectionFailed, .setupFailed] {
            for active in [false, true] {
                XCTAssertEqual(recoveryAction(active: active, elapsed: 1, trigger: trigger), .scanConfirmedSensor)
                XCTAssertEqual(recoveryAction(peripheral: .connecting, active: active, manual: true,
                                              elapsed: 1, trigger: trigger), .restartConfirmedSensorScan)
                XCTAssertEqual(recoveryAction(peripheral: .connected, active: active, setup: true,
                                              elapsed: 1, trigger: trigger), .restartConfirmedSensorScan)
            }
        }
    }

    func testPassiveDiagnosticDecisionsIgnoreSceneRuntimeTriggerAndEpisodeChanges() {
        for action in [LibreWatchRecoveryAction.waitForConnection, .waitForSystemReconnect, .waitForNotifications, .waitForExecution] {
            var policy = LibreWatchDiagnosticEmissionPolicy()
            XCTAssertTrue(policy.shouldEmit(.recoveryDecision, context: diagnosticContext(action: action)))
            XCTAssertFalse(policy.shouldEmit(.recoveryDecision, context: diagnosticContext(action: action)))
            let changedExecution = LibreWatchDiagnosticContext(
                scene: .background, runtime: .running, central: .poweredOn, peripheral: .connecting,
                stage: .reconnecting, trigger: .runtime, action: action, recoveryStartedAt: receivedAt.addingTimeInterval(600)
            )
            XCTAssertFalse(policy.shouldEmit(.recoveryDecision, context: changedExecution))
            XCTAssertFalse(policy.shouldEmit(.recoveryDecision, context: diagnosticContext(action: action)))
        }
    }

    func testDiagnosticPolicyEmitsMaterialChangesActiveActionsAndExplicitEvents() {
        var policy = LibreWatchDiagnosticEmissionPolicy()
        XCTAssertTrue(policy.shouldEmit(.recoveryDecision, context: diagnosticContext(action: .waitForConnection)))
        XCTAssertTrue(policy.shouldEmit(.recoveryDecision, context: diagnosticContext(action: .waitForSystemReconnect)))
        XCTAssertTrue(policy.shouldEmit(.recoveryDecision, context: diagnosticContext(action: .waitForSystemReconnect, central: .poweredOff)))
        XCTAssertTrue(policy.shouldEmit(.recoveryDecision, context: diagnosticContext(action: .waitForSystemReconnect, central: .poweredOff, peripheral: .connected)))
        XCTAssertTrue(policy.shouldEmit(.recoveryDecision, context: diagnosticContext(action: .waitForSystemReconnect, central: .poweredOff, peripheral: .connected, stage: .receiving)))
        for action in [LibreWatchRecoveryAction.scanConfirmedSensor, .connectConfirmedSensor, .discoverServices, .restartConfirmedSensorScan] {
            for _ in 0 ..< 2 { XCTAssertTrue(policy.shouldEmit(.recoveryDecision, context: diagnosticContext(action: action))) }
        }
        for kind in [LibreWatchDiagnosticEventKind.disconnected, .recoveryStarted, .recoveryFailed, .recoverySucceeded] {
            for _ in 0 ..< 2 { XCTAssertTrue(policy.shouldEmit(kind, context: diagnosticContext(action: .waitForConnection))) }
        }
    }

    private func timeoutIsCurrent(_ deadline: LibreWatchRecoveryDeadline, progress: LibreWatchRecoveryProgress, at date: Date) -> Bool {
        progress.timeoutIsCurrent(deadline, sessionID: session.id, ownership: .watch,
                                  cancelling: false, notificationsReady: false, now: date)
    }

    private func legacyRecoveryProgress(attempt: Date?) throws -> LibreWatchRecoveryProgress {
        var json: [String: Any] = ["sessionID": session.id.uuidString,
                                   "startedAt": receivedAt.timeIntervalSinceReferenceDate,
                                   "lastPacketAt": receivedAt.addingTimeInterval(-60).timeIntervalSinceReferenceDate]
        if let attempt { json["attemptStartedAt"] = attempt.timeIntervalSinceReferenceDate }
        return try JSONDecoder().decode(LibreWatchRecoveryProgress.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func diagnosticContext(action: LibreWatchRecoveryAction, central: LibreWatchCentralState = .poweredOn,
                                   peripheral: LibreWatchPeripheralState = .connecting,
                                   stage: LibreWatchDiagnosticStage = .reconnecting) -> LibreWatchDiagnosticContext {
        LibreWatchDiagnosticContext(scene: .active, runtime: .none, central: central, peripheral: peripheral,
                                    stage: stage, trigger: .scene, action: action, recoveryStartedAt: receivedAt)
    }

    func testDiagnosticFallbackQueuesIdenticalEventAndReceiverDeduplicatesAfterReload() throws {
        let event = LibreWatchDiagnosticEvent(kind: .recoveryStarted, occurredAt: receivedAt)
        let encoded = try JSONEncoder().encode(event)
        let message: [String: Any] = [LibreWatchMessageKey.diagnosticEvent: encoded]
        var queued = [Data]()
        LibreWatchDiagnosticDelivery.send(message, interactively: true, send: { sent, failed in
            XCTAssertEqual(sent[LibreWatchMessageKey.diagnosticEvent] as? Data, encoded)
            failed(NSError(domain: "test", code: 1))
        }, queue: { queued.append($0[LibreWatchMessageKey.diagnosticEvent] as! Data) })
        XCTAssertEqual(queued, [encoded])
        var receipts = LibreWatchDiagnosticReceipts()
        XCTAssertTrue(receipts.accept(event, now: receivedAt))
        var restored = try JSONDecoder().decode(LibreWatchDiagnosticReceipts.self, from: JSONEncoder().encode(receipts))
        XCTAssertFalse(restored.accept(try JSONDecoder().decode(LibreWatchDiagnosticEvent.self, from: queued[0]), now: receivedAt))
        XCTAssertTrue(restored.accept(LibreWatchDiagnosticEvent(kind: .recoveryStarted), now: receivedAt))
    }

    func testUnreachableDiagnosticIsQueuedWithoutInteractiveSend() {
        var count = 0
        LibreWatchDiagnosticDelivery.send([:], interactively: false, send: { _, _ in
            XCTFail("No interactive attempt while unreachable")
        }, queue: { _ in count += 1 })
        XCTAssertEqual(count, 1)
    }

    func testLegacyDiagnosticDecodesWithoutInventingWatchTimeOrIdentity() throws {
        let data = Data(#"{"kind":"disconnected","isReconnecting":true,"errorCode":7}"#.utf8)
        let event = try JSONDecoder().decode(LibreWatchDiagnosticEvent.self, from: data)
        XCTAssertEqual(event.kind, .disconnected)
        XCTAssertNil(event.id)
        XCTAssertNil(event.occurredAt)
        XCTAssertNil(event.context)
        XCTAssertEqual(event.errorCode, 7)
    }

    private func recoveryAction(peripheral: LibreWatchPeripheralState = .disconnected,
                                active: Bool = true, runtime: Bool = false, poweredOn: Bool = true,
                                system: Bool = false, manual: Bool = false, scanning: Bool = false,
                                cancelling: Bool = false, setup: Bool = false, notifications: Bool = false,
                                receivingFrame: Bool = false,
                                lastActivity: Date? = nil, elapsed: TimeInterval = 1,
                                phaseDeadline: LibreWatchRecoveryDeadline? = nil,
                                trigger: LibreWatchRecoveryTrigger = .disconnected,
                                owner: LibreWatchOwnership = .watch, validSession: Bool = true) -> LibreWatchRecoveryAction {
        var progress = LibreWatchRecoveryProgress(sessionID: session.id)
        if setup { progress.beginSetup(at: receivedAt) }
        else if system || manual || peripheral == .connecting {
            progress.beginConnection(at: receivedAt, applicationIsActive: active)
        }
        return LibreWatchRecoveryPolicy.action(
            ownership: owner, validSession: validSession, poweredOn: poweredOn, peripheral: peripheral,
            scanning: scanning, systemReconnecting: system, manualConnecting: manual, cancelling: cancelling,
            setupInProgress: setup, notificationsReady: notifications,
            receivingFrame: receivingFrame,
            deadline: phaseDeadline ?? progress.deadline, lastActivityAt: lastActivity, now: receivedAt.addingTimeInterval(elapsed),
            applicationIsActive: active, extendedRuntimeIsRunning: runtime, trigger: trigger
        )
    }

    private var historyCalibration: LibreWatchCalibrationSnapshot {
        calibration(type: .factoryCalibrated, slope: 1, intercept: 0)
    }

    private func historyPayload(at date: Date, sensorTime: UInt16 = 1_234) -> LibreWatchDirectReadingPayload {
        payload(raw: 847, previousRaw: 830, domain: .factoryNativeMGDL, sensorTime: sensorTime, at: date)
    }

    private func historyRejection(_ reading: LibreWatchDirectReadingPayload, ownership: LibreWatchOwnership = .watch,
                                  receipt: LibreWatchReleaseReceipt? = nil, now: Date? = nil) -> LibreWatchDeliveryOutcome? {
        LibreWatchHistoryPolicy.rejection(for: reading, transport: .queuedUserInfo, session: session,
                                          calibration: historyCalibration, ownership: ownership, receipt: receipt, now: now ?? receivedAt)
    }

    private func makeReleaseReceipt() -> LibreWatchReleaseReceipt? {
        LibreWatchReleaseReceipt(session: session, calibration: historyCalibration,
                                 cutoff: receivedAt.addingTimeInterval(60), now: receivedAt.addingTimeInterval(60))
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
        revision: UInt64 = 10,
        sensorUID: Data? = nil
    ) -> LibreWatchCalibrationSnapshot {
        LibreWatchCalibrationSnapshot(
            activeSensorID: "active-sensor",
            sensorUID: sensorUID ?? session.sensorUID,
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
