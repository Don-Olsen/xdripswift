//
//  WatchManager.swift
//  xdrip
//
//  Created by Paul Plant on 9/2/24.
//  Copyright © 2024 Johan Degraeve. All rights reserved.
//

import Combine
import CoreData
import Foundation
import OSLog
import UIKit
import WatchConnectivity
import WidgetKit

// WatchConnectivity delegate callbacks can trigger async AGP generation
// mutable watch payloads are still committed back on the main queue
final class WatchManager: NSObject, ObservableObject, @unchecked Sendable {
    // MARK: - private properties

    /// a watch connectivity session instance
    private var session: WCSession

    /// prevents duplicate activate calls while WatchConnectivity is already processing one
    private let sessionActivationLock = NSLock()
    private var sessionActivationRequested = false

    /// a BgReadingsAccessor instance
    private var bgReadingsAccessor: BgReadingsAccessor

    /// a SensorsAccessor instance
    private var sensorsAccessor: SensorsAccessor

    /// Supplies the exact active iPhone calibration used for direct Watch display.
    private var calibrationsAccessor: CalibrationsAccessor

    /// a coreDataManager instance (must be passed from RVC in the initializer)
    private var coreDataManager: CoreDataManager

    /// NightscoutSyncManager instance
    private var nightscoutSyncManager: NightscoutSyncManager

    /// Releases/resumes the exact active Libre transmitter during a Watch hand-off.
    private var bluetoothPeripheralManager: BluetoothPeripheralManager

    private var libreWatchDirectSession: LibreWatchDirectSession?
    private var libreWatchOwnership: LibreWatchOwnership = .iphone
    private var libreWatchCalibrationSnapshot: LibreWatchCalibrationSnapshot?
    private var libreWatchReadingAcceptance = LibreWatchReadingAcceptancePolicy()
    private var libreWatchDiagnosticReceipts = LibreWatchSessionStore.loadDiagnosticReceipts()
    private var libreWatchObservers: [NSObjectProtocol] = []

    /// Statistics manager used to build compact AGP backgrounds for the Watch chart
    private var statisticsManager: StatisticsManager

    /// hold the current watch status model
    private var status = WatchStatus()

    /// hold the current watch BG readings model
    private var bgReadings = WatchBgReadings()

    /// hold the current AGP chart background model
    private var agp = WatchAGP()

    /// keep track of when we last forced a complication update from within the code
    private var lastForcedComplicationUpdateTimeStamp: Date = .distantPast

    /// Sends CareLink connection and pump-status transitions without waiting for the next glucose reading.
    private var careLinkStatusObserver: AnyCancellable?
    private var alarmSnapshotUpdatePending = false
    private let handoffSnapshotCache = LibreWatchHandoffSnapshotCache()
    private var forcedComplicationPending = false
    private var lastSessionSentRevision: UInt64?
    private var lastSessionSendUptime: TimeInterval = -.infinity

    private let agpCalculationGate = AGPCalculationGate()
    private lazy var phoneRefresh = WatchPhoneRefreshService(
        schedule: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
        build: { [weak self] streams, request, complete in
            guard let self else { complete([:]); return }
            var result: [String: Any] = [:]
            if streams.contains("status") {
                self.status = self.currentStatus()
                result["status"] = self.status.asDictionary
                if self.status.libreAlarmSettings?.revision != self.handoffSnapshotCache.snapshot?.alarmSettings?.revision {
                    self.sendLibreWatchSession()
                }
            }
            if streams.contains("bgReadings") {
                self.bgReadings = self.currentBgReadings()
                result["bgReadings"] = self.bgReadings.asDictionary
            }
            guard streams.contains("agp"), let start = request["visibleStartDate"] as? Double,
                  let end = request["visibleEndDate"] as? Double else { complete(result); return }
            let requestID = request["agpRequestID"] as? Double ?? 0
            let started = self.agpCalculationGate.start(base: result, calculate: { finished in
                Task { [weak self] in
                    guard let self else {
                        DispatchQueue.main.async { finished(nil) }
                        return
                    }
                    let agp = await self.currentAGP(requestID: requestID,
                        visibleStartDate: Date(timeIntervalSince1970: start), visibleEndDate: Date(timeIntervalSince1970: end))
                    DispatchQueue.main.async { finished(agp.asDictionary) }
                }
            }, complete: complete)
            if !started {
                WatchDeliveryEvidenceStore.shared.recordTransport(stream: .agp,
                    action: "calculationAlreadyRunning")
            }
        },
        generation: { [weak self] in WatchPhoneSnapshotStore.nextGeneration(sessionID: self?.libreWatchDirectSession?.id) },
        sessionScope: { [weak self] in self?.libreWatchDirectSession?.id.uuidString ?? "phone" },
        controlSnapshot: { [weak self] in
            guard let self, let snapshot = self.handoffSnapshotCache.current(session: self.libreWatchDirectSession,
                calibration: self.libreWatchCalibrationSnapshot, ownership: self.libreWatchOwnership,
                delegation: LibreWatchAlarmStore.delegation()) else { return [:] }
            return LibreWatchHandoffSnapshotCache.payload(snapshot) ?? [:]
        },
        publishContext: { [weak self] in self?.publishPhoneSnapshotContext($0) ?? false },
        sendPush: { [weak self] payload, completion in
            guard let self else { completion(false, false); return }
            self.sendPhoneSnapshotPush(payload, completion: completion)
        },
        event: { stream, outcome in
            let category: WatchDeliveryEvidenceStream = stream == "agp" ? .agp : (stream == "bgReadings" ? .graph : .status)
            WatchDeliveryEvidenceStore.shared.recordTransport(stream: category, action: outcome)
        })

    /// for logging
    private var log = OSLog(subsystem: ConstantsLog.subSystem, category: ConstantsLog.categoryWatchManager)

    // MARK: - intializer

    init(
        coreDataManager: CoreDataManager,
        nightscoutSyncManager: NightscoutSyncManager,
        bluetoothPeripheralManager: BluetoothPeripheralManager,
        session: WCSession = .default
    ) {
        // set coreDataManager and bgReadingsAccessor
        self.coreDataManager = coreDataManager
        self.bgReadingsAccessor = BgReadingsAccessor(coreDataManager: coreDataManager)
        self.sensorsAccessor = SensorsAccessor(coreDataManager: coreDataManager)
        self.calibrationsAccessor = CalibrationsAccessor(coreDataManager: coreDataManager)
        self.nightscoutSyncManager = nightscoutSyncManager
        self.bluetoothPeripheralManager = bluetoothPeripheralManager
        self.statisticsManager = StatisticsManager(coreDataManager: coreDataManager)

        self.session = session

        super.init()

        let persistedOwnership = LibreWatchSessionStore.loadOwnership()
        let startupDecision = LibreWatchPhoneStartupDecision.resolve(
            persistedOwnership: persistedOwnership,
            persistedSession: LibreWatchSessionStore.loadSession(),
            activeSensorUID: UserDefaults.standard.libreSensorUID,
            activePatchInfo: UserDefaults.standard.librePatchInfo
        )
        libreWatchDirectSession = startupDecision.session
        libreWatchOwnership = startupDecision.ownership
        libreWatchCalibrationSnapshot = LibreWatchSessionStore.loadCalibration()
        if persistedOwnership != startupDecision.ownership {
            LibreWatchSessionStore.saveOwnership(startupDecision.ownership)
        }
        libreWatchReadingAcceptance.reset(
            for: libreWatchOwnership == .watch ? libreWatchDirectSession?.id : nil
        )
        if startupDecision.phoneConnectionIsBlocked {
            // An interrupted return remains owned by Watch. Its former cutoff must not
            // authorize delayed data after a later, unrelated return.
            cancelLibreWatchReleaseReceipt()
        } else {
            _ = currentLibreWatchReleaseReceipt()
        }

        libreWatchObservers.append(NotificationCenter.default.addObserver(
            forName: .libreWatchDirectSessionPrepared,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let session = notification.object as? LibreWatchDirectSession else { return }
            self?.storeAndSendLibreWatchSession(session)
        })

        libreWatchObservers.append(NotificationCenter.default.addObserver(
            forName: .libreWatchDirectOwnershipForcedToPhone,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.cancelLibreWatchReleaseReceipt()
            self.setLibreWatchOwnership(.iphone)
            self.sendLibreWatchSession()
        })

        libreWatchObservers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.sendLibreWatchSession()
        })

        if let transmitter = bluetoothPeripheralManager.getCGMTransmitter() as? CGMLibre2Transmitter {
            if startupDecision.phoneConnectionIsBlocked, let libreWatchDirectSession {
                transmitter.restoreWatchOwnership(libreWatchDirectSession)
            }
            if let currentSession = transmitter.prepareCurrentSensorForWatch() {
                libreWatchDirectSession = currentSession
            }
        }

        if WCSession.isSupported() {
            session.delegate = self
            activateSessionIfNeeded()
        }

        // add observer to sync to the watch once the device status was updated
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.nightscoutDeviceStatusWasUpdated.rawValue, options: .new, context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: UserDefaults.Key.snoozeAllAlertsUntilDate.rawValue, options: .new, context: nil)
        libreWatchObservers.append(NotificationCenter.default.addObserver(
            forName: .NSManagedObjectContextDidSave, object: coreDataManager.mainManagedObjectContext, queue: .main
        ) { [weak self] notification in
            let changed = [NSInsertedObjectsKey, NSUpdatedObjectsKey, NSDeletedObjectsKey].flatMap {
                Array(notification.userInfo?[$0] as? Set<NSManagedObject> ?? [])
            }
            if changed.contains(where: { ["AlertEntry", "AlertType", "SnoozeParameters"].contains($0.entity.name ?? "") }) {
                self?.scheduleAlarmSettingsUpdate()
            }
        })

        careLinkStatusObserver = CareLinkAccountState.shared.$snapshot
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard UserDefaults.standard.followerDataSourceType == .careLink else { return }
                self?.processWatchUpdate(updateTypes: [.status], forceComplicationUpdate: false)
            }

        processWatchUpdate(updateTypes: [.status, .bgReadings], forceComplicationUpdate: false)
    }

    // MARK: - overriden functions

    /// when one of the observed settings get changed, possible actions to take
    override public func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if let keyPath = keyPath {
            if let keyPathEnum = UserDefaults.Key(rawValue: keyPath) {
                switch keyPathEnum {
                case .snoozeAllAlertsUntilDate:
                    DispatchQueue.main.async { [weak self] in self?.scheduleAlarmSettingsUpdate() }
                case UserDefaults.Key.nightscoutDeviceStatusWasUpdated:
                    // only ejecute if the key was set to true (to avoid a get-set loop)
                    // if so, process the watch state and set it back to false
                    if UserDefaults.standard.nightscoutDeviceStatusWasUpdated {
                        DispatchQueue.main.async { [weak self] in
                            self?.processWatchUpdate(updateTypes: [.status], forceComplicationUpdate: false)
                        }
                        UserDefaults.standard.nightscoutDeviceStatusWasUpdated = false
                    }
                default:
                    break
                }
            }
        }
    }

    // MARK: - private functions

    private enum WatchUpdateType: Hashable {
        case status
        case bgReadings
        case agp
    }

    private func activateSessionIfNeeded() {
        sessionActivationLock.lock()
        let shouldActivate = !sessionActivationRequested
        sessionActivationRequested = true
        sessionActivationLock.unlock()

        if shouldActivate {
            session.activate()
        }
    }

    private func completeSessionActivationRequest() {
        sessionActivationLock.lock()
        sessionActivationRequested = false
        sessionActivationLock.unlock()
    }

    private func processWatchUpdate(updateTypes: Set<WatchUpdateType>, forceComplicationUpdate: Bool) {
        forcedComplicationPending = forcedComplicationPending || forceComplicationUpdate
        phoneRefresh.changed(Set(updateTypes.map { type in
            switch type { case .status: return "status"; case .bgReadings: return "bgReadings"; case .agp: return "agp" }
        }))
    }

    private func currentBgReadings() -> WatchBgReadings {
        // create two simple arrays to send to the watch. One with the bg values in mg/dL and another with the corresponding timestamps
        // this is needed due to the not being able to pass structs that are not codable/hashable
        let hoursOfBgReadingsToSend: Double = 12

        let isMgDl = UserDefaults.standard.bloodGlucoseUnitIsMgDl

        let bgReadingSnapshots = bgReadingsAccessor.getLatestBgReadingSnapshots(limit: nil, fromDate: .now.addingTimeInterval(-3600 * hoursOfBgReadingsToSend), forSensor: nil, ignoreRawData: true, ignoreCalculatedValue: false)

        let slopeOrdinal: Int = !bgReadingSnapshots.isEmpty ? bgReadingSnapshots[0].slopeOrdinal() : 1

        var previousValueInUserUnit = 0.0
        var actualValueInUserUnit = 0.0
        var deltaValueInUserUnit = 0.0

        // add delta if available
        if bgReadingSnapshots.count > 1 {
            previousValueInUserUnit = bgReadingSnapshots[1].finalValue.mgDlToMmol(mgDl: isMgDl)
            actualValueInUserUnit = bgReadingSnapshots[0].finalValue.mgDlToMmol(mgDl: isMgDl)

            // if the values are in mmol/L, then round them to the nearest decimal point in order to get the same precision out of the next operation
            if !isMgDl {
                previousValueInUserUnit = (previousValueInUserUnit * 10).rounded() / 10
                actualValueInUserUnit = (actualValueInUserUnit * 10).rounded() / 10
            }

            deltaValueInUserUnit = actualValueInUserUnit - previousValueInUserUnit
        }

        var bgReadingValues: [Double] = []
        var bgReadingDatesAsDouble: [Double] = []

        for bgReading in bgReadingSnapshots {
            bgReadingValues.append(bgReading.finalValue)
            bgReadingDatesAsDouble.append(bgReading.timeStamp.timeIntervalSince1970)
        }

        return WatchBgReadings(generatedAt: Date().timeIntervalSince1970, hoursIncluded: hoursOfBgReadingsToSend, bgReadingValues: bgReadingValues, bgReadingDatesAsDouble: bgReadingDatesAsDouble, slopeOrdinal: slopeOrdinal, deltaValueInUserUnit: deltaValueInUserUnit)
    }

    private func currentStatus() -> WatchStatus {
        var status = WatchStatus()

        if let session = libreWatchDirectSession {
            status.libreAlarmSettings = AlertManager.makeLibreWatchAlarmSettings(session: session, coreDataManager: coreDataManager)
        }

        status.generatedAt = Date().timeIntervalSince1970
        status.isMgDl = UserDefaults.standard.bloodGlucoseUnitIsMgDl
        status.urgentLowLimitInMgDl = UserDefaults.standard.urgentLowMarkValue
        status.lowLimitInMgDl = UserDefaults.standard.lowMarkValue
        status.highLimitInMgDl = UserDefaults.standard.highMarkValue
        status.urgentHighLimitInMgDl = UserDefaults.standard.urgentHighMarkValue
        status.activeSensorDescription = UserDefaults.standard.activeSensorDescription
        status.preferSensorCountdown = UserDefaults.standard.preferSensorCountdown
        status.isMaster = UserDefaults.standard.isMaster
        status.followerDataSourceTypeRawValue = UserDefaults.standard.followerDataSourceType.rawValue
        status.followerBackgroundKeepAliveTypeRawValue = UserDefaults.standard.followerBackgroundKeepAliveType.rawValue
        status.followerConnectionStatusRawValue = UserDefaults.standard.followerDataSourceType == .careLink
            ? CareLinkAccountState.shared.snapshot.status.rawValue
            : nil
        status.keepAliveIsDisabled = !UserDefaults.standard.isMaster && UserDefaults.standard.followerBackgroundKeepAliveType == .disabled

        if let sensorStartDate = UserDefaults.standard.activeSensorStartDate {
            status.sensorStartedAt = sensorStartDate.timeIntervalSince1970
            let minutes = Calendar.current.dateComponents([.minute], from: sensorStartDate, to: .now).minute ?? 0
            status.sensorAgeInMinutes = Double(minutes)
        } else {
            status.sensorAgeInMinutes = 0
        }

        status.sensorMaxAgeInMinutes = (UserDefaults.standard.activeSensorMaxSensorAgeInDays ?? 0) * 24 * 60

        if status.isMaster,
           UserDefaults.standard.showSensorNoise,
           let activeSensor = sensorsAccessor.fetchActiveSensor(),
           activeSensor.noiseAlgorithmVersion == ConstantsSensorNoise.algorithmVersion,
           let latestReadingAt = activeSensor.noiseLatestReadingAt {
            let readingAge = Date().timeIntervalSince(latestReadingAt)

            if readingAge >= -TimeInterval(minutes: 5),
               readingAge <= ConstantsSensorNoise.rootWarningFreshness {
                let rawSensorNoiseState = SensorNoiseState(rawValue: activeSensor.noiseStateRaw) ?? .collecting
                status.sensorNoiseStateRawValue = Int(
                    ConstantsSensorNoise.displayState(
                        rawState: rawSensorNoiseState,
                        shortTermNoise: activeSensor.shortTermNoise?.doubleValue,
                        longTermNoise: activeSensor.longTermNoise?.doubleValue,
                        sensitivity: UserDefaults.standard.sensorNoiseSensitivity
                    ).rawValue
                )
            }
        }

        // let's set the state values if we're using a heartbeat
        if let timeStampOfLastHeartBeat = UserDefaults.standard.timeStampOfLastHeartBeat?.timeIntervalSince1970, let secondsUntilHeartBeatDisconnectWarning = UserDefaults.standard.secondsUntilHeartBeatDisconnectWarning {
            status.secondsUntilHeartBeatDisconnectWarning = Int(secondsUntilHeartBeatDisconnectWarning)
            status.timeStampOfLastHeartBeat = timeStampOfLastHeartBeat
        }

        // let's set the follower server connection values if we're using follower mode
        if let timeStampOfLastFollowerConnection = UserDefaults.standard.timeStampOfLastFollowerConnection?.timeIntervalSince1970 {
            status.secondsUntilFollowerDisconnectWarning = UserDefaults.standard.followerDataSourceType.secondsUntilFollowerDisconnectWarning
            status.timeStampOfLastFollowerConnection = timeStampOfLastFollowerConnection
        }

        // CareLink has no Nightscout device-status record, so both sources are normalized before
        // crossing the Watch boundary rather than making the Watch understand either protocol.
        if UserDefaults.standard.dataFlowPolicy.importsTherapyFromCareLink {
            status.aidStatus = CareLinkAccountState.shared.snapshot.aidStatus
        } else if !UserDefaults.standard.dataFlowPolicy.showsAIDData {
            status.aidStatus = nil
        } else if UserDefaults.standard.nightscoutEnabled, UserDefaults.standard.nightscoutUrl != nil, nightscoutSyncManager.deviceStatus.createdAt != .distantPast {
            status.aidStatus = nightscoutSyncManager.deviceStatus.aidStatus
        } else {
            status.aidStatus = nil
        }

        return status
    }

    private func scheduleAlarmSettingsUpdate() {
        guard !alarmSnapshotUpdatePending else { return }
        alarmSnapshotUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.alarmSnapshotUpdatePending = false
            self.sendLibreWatchSession()
        }
    }

    /// The statistics continuation is backed by an OperationQueue and is not Task-cancellable.
    /// A transport timeout must not create more queued statistics work. This gate keeps
    /// exactly one physical calculation until its real callback, with no pending work list.
    /// A busy AGP request still returns its status/graph immediately and is retryable.
    final class AGPCalculationGate {
        private var active: UUID?

        @discardableResult
        func start(base: [String: Any],
                   calculate: (@escaping ([String: Any]?) -> Void) -> Void,
                   complete: @escaping ([String: Any]) -> Void) -> Bool {
            guard active == nil else { complete(base); return false }
            let token = UUID()
            active = token
            calculate { [weak self] agp in
                guard let self, self.active == token else { return }
                self.active = nil
                var result = base
                if let agp { result["agp"] = agp }
                complete(result)
            }
            return true
        }
    }

    private func currentAGP(requestID: Double, visibleStartDate: Date, visibleEndDate: Date) async -> WatchAGP {
        guard visibleStartDate < visibleEndDate else {
            return WatchAGP(generatedAt: Date().timeIntervalSince1970, requestID: requestID, visibleStartDateAsDouble: visibleStartDate.timeIntervalSince1970, visibleEndDateAsDouble: visibleEndDate.timeIntervalSince1970)
        }

        // use the same AGP calculation as the iOS landscape comparison chart
        // for the Watch app, keep the baseline focused on recent days and only send the compact
        // minute-of-day profile. The Watch maps that profile onto its current chart window locally.
        let baseline = await statisticsManager.landscapeBaseline(referenceDate: visibleEndDate, daysBack: ConstantsGlucoseChartSwiftUI.agpDaysBackWatchApp)
        let agpPoints = GlucoseReportAGPDisplayPoints.smoothedDisplayPoints(from: baseline.agpPoints)

        return WatchAGP(
            generatedAt: Date().timeIntervalSince1970,
            requestID: requestID,
            visibleStartDateAsDouble: visibleStartDate.timeIntervalSince1970,
            visibleEndDateAsDouble: visibleEndDate.timeIntervalSince1970,
            dayCount: baseline.dayCount,
            minuteOfDayValues: agpPoints.map(\.minuteOfDay),
            p5Values: agpPoints.map(\.p5MgDl),
            p25Values: agpPoints.map(\.p25MgDl),
            medianValues: agpPoints.map(\.medianMgDl),
            p75Values: agpPoints.map(\.p75MgDl),
            p95Values: agpPoints.map(\.p95MgDl)
        )
    }

    private func publishPhoneSnapshotContext(_ incoming: [String: Any]) -> Bool {
        guard session.activationState == .activated else { activateSessionIfNeeded(); return false }
        guard session.isPaired, session.isWatchAppInstalled else { return false }
        let context = WatchPhoneRefreshService.merging(incoming, into: session.applicationContext)
        do { try session.updateApplicationContext(context) }
        catch {
            WatchDeliveryEvidenceStore.shared.recordTransport(stream: .status, action: "contextFailed",
                outcome: WatchDeliveryEvidenceStore.errorClass(error))
            trace("Could not replace Watch state context: %{public}@", log: log,
                category: ConstantsLog.categoryWatchManager, type: .error, error.localizedDescription)
            return false
        }
        if !session.isReachable,
           (session.isComplicationEnabled && lastForcedComplicationUpdateTimeStamp < Date().addingTimeInterval(-Double(UserDefaults.standard.forceComplicationUpdateInMinutes * 60))) || forcedComplicationPending {
            session.transferCurrentComplicationUserInfo(incoming)
            lastForcedComplicationUpdateTimeStamp = Date()
            forcedComplicationPending = false
            WatchDeliveryEvidenceStore.shared.recordTransport(stream: .status, action: "complicationSubmitted")
        }
        return true
    }

    private func sendPhoneSnapshotPush(_ payload: [String: Any], completion: @escaping (Bool, Bool) -> Void) {
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled,
              session.isReachable else {
            WatchDeliveryEvidenceStore.shared.recordTransport(stream: .status, action: "pushUnavailable")
            completion(false, false); return
        }
        trace("sending foreground watch update", log: log, category: ConstantsLog.categoryWatchManager, type: .debug)
        let failure: (Error) -> Void = { [weak self] error in
            WatchDeliveryEvidenceStore.shared.recordTransport(stream: .status, action: "sendFailed",
                outcome: WatchDeliveryEvidenceStore.errorClass(error))
            guard let self else { return }
            trace("error sending watch update, error = %{public}@", log: self.log,
                category: ConstantsLog.categoryWatchManager, type: .error,
                troubleshooting: .detailed(.integration(name: .watchStatus, activity: .failed)), error.localizedDescription)
            DispatchQueue.main.async { completion(false, false) }
        }
        if payload["legacySnapshot"] as? Bool == true {
            session.sendMessage(payload, replyHandler: nil, errorHandler: failure)
            completion(true, false) // Submission only; evidence explicitly says unconfirmed.
        } else {
            session.sendMessage(payload, replyHandler: { reply in
                DispatchQueue.main.async {
                    let matched = reply["watchSnapshotPush"] as? Int == 1 &&
                        reply["pushID"] as? String == payload["pushID"] as? String &&
                        reply["success"] as? Bool == true
                    completion(matched, reply["watchSnapshotPush"] == nil && reply["success"] as? Bool == false)
                }
            }, errorHandler: failure)
        }
    }

    private func setLibreWatchOwnership(_ ownership: LibreWatchOwnership) {
        let previousOwnership = libreWatchOwnership
        let ownershipChanged = ownership != libreWatchOwnership
        libreWatchOwnership = ownership
        LibreWatchSessionStore.saveOwnership(ownership)
        if ownership == .iphone, LibreWatchAlarmStore.delegation() != nil {
            LibreWatchAlarmStore.save(nil as LibreWatchAlarmDelegation?)
            NotificationCenter.default.post(name: .libreWatchAlarmDelegationChanged, object: nil)
        }
        if ownershipChanged {
            trace(
                "Libre Watch ownership changed: %{public}@ -> %{public}@ sensor=%{public}@",
                log: log,
                category: ConstantsLog.categoryWatchManager,
                type: .info,
                previousOwnership.rawValue,
                ownership.rawValue,
                libreWatchDirectSession?.redactedIdentity() ?? "Libre-none"
            )
            libreWatchReadingAcceptance.reset(
                for: ownership == .watch ? libreWatchDirectSession?.id : nil
            )
        }
    }

    private func currentLibreWatchReleaseReceipt(
        at date: Date = Date()
    ) -> LibreWatchReleaseReceipt? {
        guard let receipt = LibreWatchSessionStore.loadReleaseReceipt() else { return nil }
        guard receipt.expiresAt > date else {
            LibreWatchSessionStore.clearReleaseReceipt()
            logLibreWatchDelivery(.receiptExpired)
            return nil
        }
        guard let currentSession = libreWatchDirectSession,
              receipt.sessionID == currentSession.id,
              receipt.sensorUID == currentSession.sensorUID,
              receipt.patchInfo == currentSession.patchInfo
        else {
            cancelLibreWatchReleaseReceipt()
            return nil
        }
        return receipt
    }

    private func cancelLibreWatchReleaseReceipt() {
        guard LibreWatchSessionStore.loadReleaseReceipt() != nil else { return }
        LibreWatchSessionStore.clearReleaseReceipt()
        logLibreWatchDelivery(.receiptCancelled)
    }

    private func logLibreWatchDelivery(_ outcome: LibreWatchDeliveryOutcome) {
        trace(
            "Watch Libre delivery state: %{public}@ sensor=%{public}@",
            log: log,
            category: ConstantsLog.categoryWatchManager,
            type: .info,
            outcome.rawValue,
            libreWatchDirectSession?.redactedIdentity() ?? "Libre-none"
        )
    }

    private func storeAndSendLibreWatchSession(_ preparedSession: LibreWatchDirectSession) {
        guard preparedSession.isValid else { return }

        let sessionChanged = libreWatchDirectSession?.id != preparedSession.id ||
            libreWatchDirectSession?.representsSameSensor(as: preparedSession) == false

        if let existing = libreWatchDirectSession,
           !existing.representsSameSensor(as: preparedSession),
           libreWatchOwnership == .watch {
            (bluetoothPeripheralManager.getCGMTransmitter() as? CGMLibre2Transmitter)?
                .forceReturnSensorToPhone()
            setLibreWatchOwnership(.iphone)
        }

        if sessionChanged {
            cancelLibreWatchReleaseReceipt()
        }
        libreWatchDirectSession = preparedSession
        LibreWatchSessionStore.saveSession(preparedSession)
        if sessionChanged {
            libreWatchReadingAcceptance.reset(
                for: libreWatchOwnership == .watch ? preparedSession.id : nil
            )
        }
        sendLibreWatchSession()
    }

    private func libreWatchSessionPayload() -> [String: Any]? {
        guard let libreWatchDirectSession,
              libreWatchDirectSession.isValid
        else { return nil }

        refreshLibreWatchCalibrationSnapshot(for: libreWatchDirectSession)
        let alarmSettings = AlertManager.makeLibreWatchAlarmSettings(session: libreWatchDirectSession, coreDataManager: coreDataManager)
        guard let snapshot = handoffSnapshotCache.resolve(session: libreWatchDirectSession,
            calibration: libreWatchCalibrationSnapshot, ownership: libreWatchOwnership,
            settings: alarmSettings, delegation: LibreWatchAlarmStore.delegation()) else { return nil }
        return LibreWatchHandoffSnapshotCache.payload(snapshot)
    }

    private func sendLibreWatchSession(payload existingPayload: [String: Any]? = nil) {
        guard session.activationState == .activated,
              let payload = existingPayload ?? libreWatchSessionPayload()
        else { return }
        let context = WatchPhoneRefreshService.merging(payload, into: session.applicationContext)
        if !NSDictionary(dictionary: context).isEqual(to: session.applicationContext) {
            do { try session.updateApplicationContext(context) }
            catch {
                WatchDeliveryEvidenceStore.shared.recordTransport(stream: .session, action: "contextFailed",
                    outcome: WatchDeliveryEvidenceStore.errorClass(error))
                trace("Could not replace Libre Watch session context: %{public}@", log: log,
                    category: ConstantsLog.categoryWatchManager, type: .error, error.localizedDescription)
            }
        }
        let revision = handoffSnapshotCache.snapshot?.revision
        let uptime = ProcessInfo.processInfo.systemUptime
        // Real authority changes bypass this duplicate-only guard and all graph backoff.
        guard revision != lastSessionSentRevision || uptime - lastSessionSendUptime >= 60 else {
            WatchDeliveryEvidenceStore.shared.recordTransport(stream: .session, action: "unchangedSuppressed")
            return
        }
        if session.isReachable {
            lastSessionSentRevision = revision; lastSessionSendUptime = uptime
            WatchDeliveryEvidenceStore.shared.recordTransport(stream: .session, action: "sendAttempt")
            session.sendMessage(payload, replyHandler: nil, errorHandler: { [weak self] error in
                guard let self else { return }
                WatchDeliveryEvidenceStore.shared.recordTransport(stream: .session, action: "sendFailed",
                    outcome: WatchDeliveryEvidenceStore.errorClass(error))
                trace("Could not send Libre Watch session: %{public}@", log: self.log, category: ConstantsLog.categoryWatchManager, type: .error, error.localizedDescription)
            })
        }
    }

    private func refreshLibreWatchCalibrationSnapshot(for directSession: LibreWatchDirectSession) {
        guard let activeSensor = sensorsAccessor.fetchActiveSensor(),
              let transmitter = bluetoothPeripheralManager.getCGMTransmitter() as? CGMLibre2Transmitter
        else {
            libreWatchCalibrationSnapshot = nil
            LibreWatchSessionStore.clearCalibration()
            return
        }

        let calibrationType: LibreWatchCalibrationType
        let slope: Double
        let intercept: Double
        let rawValueDivider: Double
        let calibratedAt: Date

        if transmitter.isWebOOPEnabled() {
            calibrationType = .factoryCalibrated
            slope = 1
            intercept = 0
            rawValueDivider = 1
            calibratedAt = directSession.createdAt
        } else {
            guard let calibration = calibrationsAccessor.lastCalibrationForActiveSensor(withActivesensor: activeSensor) else {
                libreWatchCalibrationSnapshot = nil
                LibreWatchSessionStore.clearCalibration()
                return
            }
            calibrationType = transmitter.isNonFixedSlopeEnabled() ? .nonFixedSlope : .fixedSlope
            slope = calibration.slope
            intercept = calibration.intercept
            rawValueDivider = 1_000
            calibratedAt = calibration.timeStamp
        }

        let draft = LibreWatchCalibrationSnapshot(
            activeSensorID: activeSensor.id,
            sensorUID: directSession.sensorUID,
            sensorSerialNumber: directSession.sensorSerialNumber,
            watchSessionID: directSession.id,
            calibrationType: calibrationType,
            slope: slope,
            intercept: intercept,
            rawValueDivider: rawValueDivider,
            calibratedAt: calibratedAt,
            revision: 1
        )

        let previous = LibreWatchSessionStore.loadCalibration()
        if let previous, previous.hasSameCalibration(as: draft) {
            libreWatchCalibrationSnapshot = previous
            return
        }

        let clockRevision = UInt64(max(1, Date().timeIntervalSince1970 * 1_000))
        let previousRevision = previous?.revision ?? 0
        let nextRevision = max(clockRevision, previousRevision == UInt64.max ? previousRevision : previousRevision + 1)
        let snapshot = LibreWatchCalibrationSnapshot(
            activeSensorID: draft.activeSensorID,
            sensorUID: draft.sensorUID,
            sensorSerialNumber: draft.sensorSerialNumber,
            watchSessionID: draft.watchSessionID,
            calibrationType: draft.calibrationType,
            slope: draft.slope,
            intercept: draft.intercept,
            rawValueDivider: draft.rawValueDivider,
            calibratedAt: draft.calibratedAt,
            revision: nextRevision
        )
        libreWatchCalibrationSnapshot = snapshot
        LibreWatchSessionStore.saveCalibration(snapshot)
    }

    @discardableResult
    private func handleLibreWatchMessage(
        _ message: [String: Any],
        transport: LibreWatchReadingTransport,
        reply: (([String: Any]) -> Void)?
    ) -> Bool {
        guard let rawCommand = message[LibreWatchMessageKey.command] as? String,
              let command = LibreWatchCommand(rawValue: rawCommand)
        else { return false }

        guard let idString = message[LibreWatchMessageKey.sessionID] as? String,
              let sessionID = UUID(uuidString: idString)
        else {
            reply?([
                LibreWatchMessageKey.success: false,
                LibreWatchMessageKey.error: "No matching Libre Watch session"
            ])
            return true
        }

        let interactiveReply = reply
        let itemID = (message[LibreWatchMessageKey.deliveryItemID] as? String).flatMap(UUID.init(uuidString:))
        let evidenceStream: WatchDeliveryEvidenceStream = command == .submitReading ? .reading : (command == .reportDiagnostic ? .diagnostic : .session)
        WatchDeliveryEvidenceStore.shared.recordTransport(stream: evidenceStream, action: "receivedEnvelope",
            outcome: transport == .queuedUserInfo ? "queuedUserInfo" : "interactive")
        if command == .submitReading {
            WatchDeliveryEvidenceStore.shared.record(stage: .transportReceived, payloadID: itemID,
                sessionID: sessionID, outcome: "unvalidatedEnvelope")
        }
        // WCSession delegates arrive on a private queue. Keep all mutable hand-off, calibration,
        // acceptance and UserDefaults state in the manager's existing main isolation domain.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let reply: (([String: Any]) -> Void)? = { response in
                if let interactiveReply {
                    WatchDeliveryEvidenceStore.shared.recordTransport(stream: .receipt,
                        action: "replySubmitted", outcome: response[LibreWatchMessageKey.durableReceipt] as? Bool == true
                            ? "durable" : "responseOnly")
                    interactiveReply(response)
                }
                if transport == .queuedUserInfo, let itemID {
                    self.sendLibreWatchDeliveryReceipt(itemID: itemID, sessionID: sessionID, response: response)
                }
            }
            let fail: (String, LibreWatchDeliveryOutcome?) -> Void = { reason, outcome in
                if command == .submitReading {
                    WatchDeliveryEvidenceStore.shared.record(stage: .phoneRejected, payloadID: itemID,
                        sessionID: sessionID, outcome: outcome?.rawValue ?? "unknown")
                }
                var response: [String: Any] = [
                    LibreWatchMessageKey.success: false,
                    LibreWatchMessageKey.error: reason,
                    LibreWatchMessageKey.ownership: self.libreWatchOwnership.rawValue
                ]
                if let outcome {
                    response[LibreWatchMessageKey.deliveryOutcome] = outcome.rawValue
                }
                reply?(response)
            }

            if command == .reportDiagnostic {
                self.receiveLibreWatchDiagnostic(message, sessionID: sessionID, reply: reply)
                return
            }
            guard var preparedSession = self.libreWatchDirectSession,
                  preparedSession.id == sessionID,
                  preparedSession.isValid
            else {
                fail("No matching Libre Watch session", .wrongSession)
                return
            }

            switch command {
        case .acknowledgeSession:
            if [.watch, .releasingToPhone].contains(self.libreWatchOwnership),
               let data = message[LibreWatchMessageKey.alarmState] as? Data,
               let state = try? JSONDecoder().decode(LibreWatchAlarmState.self, from: data) {
                AlertManager.applyLibreWatchAlarmState(state, session: preparedSession, coreDataManager: self.coreDataManager)
            }
            let alarmSettings = AlertManager.makeLibreWatchAlarmSettings(session: preparedSession, coreDataManager: self.coreDataManager)
            if self.libreWatchOwnership == .watch,
               let rawRevision = message[LibreWatchMessageKey.alarmSettingsRevision] as? String,
               UInt64(rawRevision) == alarmSettings.revision {
                AlertManager.setLibreWatchAlarmDelegation(
                    readyRevision: message[LibreWatchMessageKey.alarmsReady] as? Bool == true ? alarmSettings.revision : nil,
                    settings: alarmSettings)
            }
            var response: [String: Any] = [
                LibreWatchMessageKey.success: true,
                LibreWatchMessageKey.ownership: self.libreWatchOwnership.rawValue,
                LibreWatchMessageKey.alarmsReady: LibreWatchAlarmStore.delegation()?.matches(alarmSettings) == true
            ]
            response[LibreWatchMessageKey.alarmSettings] = try? JSONEncoder().encode(alarmSettings)
            if let delegation = LibreWatchAlarmStore.delegation() {
                response[LibreWatchMessageKey.alarmDelegation] = try? JSONEncoder().encode(delegation)
            }
            reply?(response)

        case .requestOwnership:
            self.refreshLibreWatchCalibrationSnapshot(for: preparedSession)
            guard transport == .interactiveMessage,
                  self.libreWatchOwnership == .iphone,
                  self.libreWatchCalibrationSnapshot?.matches(session: preparedSession) == true,
                  let transmitter = self.bluetoothPeripheralManager.getCGMTransmitter() as? CGMLibre2Transmitter,
                  transmitter.canReleaseSensorToWatch(preparedSession)
            else {
                fail("iPhone could not release this Libre sensor", .wrongOwnership)
                return
            }

            self.cancelLibreWatchReleaseReceipt()
            self.setLibreWatchOwnership(.releasingToWatch)
            transmitter.releaseSensorToWatch(preparedSession) { [weak self] released in
                guard let self else { return }
                guard released,
                      self.libreWatchDirectSession?.id == preparedSession.id,
                      self.libreWatchDirectSession?.sensorUID == preparedSession.sensorUID,
                      let releasedSession = transmitter.prepareCurrentSensorForWatch(),
                      releasedSession.id == preparedSession.id
                else {
                    _ = transmitter.returnSensorToPhone(sessionID: preparedSession.id)
                    self.setLibreWatchOwnership(.iphone)
                    self.sendLibreWatchSession()
                    fail("iPhone could not release this Libre sensor session", .wrongSession)
                    return
                }
                // Capture after the final phone BLE callback has released the peripheral.
                // Its unlock counter can have advanced since the original NFC preparation.
                self.libreWatchDirectSession = releasedSession
                let alarmSettings = AlertManager.makeLibreWatchAlarmSettings(session: releasedSession, coreDataManager: self.coreDataManager)
                let readyRevision = (message[LibreWatchMessageKey.alarmSettingsRevision] as? String).flatMap(UInt64.init)
                AlertManager.setLibreWatchAlarmDelegation(
                    readyRevision: message[LibreWatchMessageKey.alarmsReady] as? Bool == true ? readyRevision : nil,
                    settings: alarmSettings)
                self.setLibreWatchOwnership(.watch)
                guard var response = self.libreWatchSessionPayload() else {
                    _ = transmitter.returnSensorToPhone(sessionID: releasedSession.id)
                    self.setLibreWatchOwnership(.iphone)
                    fail("Current Libre calibration is unavailable after release", .wrongCalibration)
                    return
                }
                self.sendLibreWatchSession(payload: response)
                response[LibreWatchMessageKey.success] = true
                reply?(response)
            }

        case .releaseOwnership:
            guard transport == .interactiveMessage else {
                fail("Libre ownership release requires interactive delivery", .invalidPayload)
                return
            }
            if self.libreWatchOwnership == .iphone,
               let receipt = self.currentLibreWatchReleaseReceipt(),
               receipt.state == .completed {
                var response = self.libreWatchSessionPayload() ?? [:]
                response[LibreWatchMessageKey.success] = true
                response[LibreWatchMessageKey.ownership] = LibreWatchOwnership.iphone.rawValue
                reply?(response)
                return
            }

            self.refreshLibreWatchCalibrationSnapshot(for: preparedSession)
            let cutoff = (message[LibreWatchMessageKey.releaseCutoff] as? Double)
                .map { Date(timeIntervalSince1970: $0) }
            guard self.libreWatchOwnership == .watch,
                  let cutoff,
                  let calibration = self.libreWatchCalibrationSnapshot,
                  var receipt = LibreWatchReleaseReceipt(
                    session: preparedSession,
                    calibration: calibration,
                    cutoff: cutoff
                  )
            else {
                fail("Invalid Libre release session or cutoff", .invalidPayload)
                return
            }

            _ = self.updateLibreWatchUnlockCounter(from: message, session: &preparedSession)
            if let data = message[LibreWatchMessageKey.alarmState] as? Data,
               let state = try? JSONDecoder().decode(LibreWatchAlarmState.self, from: data) {
                AlertManager.applyLibreWatchAlarmState(state, session: preparedSession, coreDataManager: self.coreDataManager)
            }
            LibreWatchSessionStore.saveReleaseReceipt(receipt)
            self.logLibreWatchDelivery(.receiptCreated)
            self.setLibreWatchOwnership(.releasingToPhone)
            guard let transmitter = self.bluetoothPeripheralManager.getCGMTransmitter() as? CGMLibre2Transmitter,
                  transmitter.returnSensorToPhone(sessionID: sessionID)
            else {
                self.cancelLibreWatchReleaseReceipt()
                self.setLibreWatchOwnership(.watch)
                self.sendLibreWatchSession()
                fail("iPhone could not restore this Libre sensor", .wrongOwnership)
                return
            }
            receipt.complete()
            LibreWatchSessionStore.saveReleaseReceipt(receipt)
            self.logLibreWatchDelivery(.receiptCompleted)
            self.setLibreWatchOwnership(.iphone)
            var response = self.libreWatchSessionPayload() ?? [:]
            self.sendLibreWatchSession(payload: response)
            response[LibreWatchMessageKey.success] = true
            response[LibreWatchMessageKey.ownership] = self.libreWatchOwnership.rawValue
            reply?(response)

        case .updateUnlockCounter:
            guard self.updateLibreWatchUnlockCounter(from: message, session: &preparedSession) else {
                fail("Invalid or stale Libre unlock counter", .invalidPayload)
                return
            }
            reply?([
                LibreWatchMessageKey.success: true,
                LibreWatchMessageKey.ownership: self.libreWatchOwnership.rawValue
            ])

        case .submitReading:
            guard let data = message[LibreWatchMessageKey.reading] as? Data,
                  let reading = try? JSONDecoder().decode(LibreWatchDirectReadingPayload.self, from: data),
                  reading.sessionID == sessionID,
                  itemID == nil || itemID == reading.id
            else {
                fail("Invalid Libre reading", .invalidPayload)
                return
            }

            WatchDeliveryEvidenceStore.shared.recordReading(.phoneReceived, reading: reading,
                outcome: transport == .queuedUserInfo ? "queuedUserInfo" : "interactive")

            // Re-read every mutable hand-off dependency immediately before either the live or
            // historical pipeline. A delayed WatchConnectivity message must not cross a sensor
            // or calibration session; ownership is checked separately for its transport mode.
            guard let currentSession = self.libreWatchDirectSession,
                  currentSession.id == sessionID,
                  currentSession.isValid
            else {
                fail("Libre Watch session changed before delivery", .wrongSession)
                return
            }

            self.refreshLibreWatchCalibrationSnapshot(for: currentSession)
            guard let calibrationSnapshot = self.libreWatchCalibrationSnapshot,
                  calibrationSnapshot.matches(session: currentSession),
                  reading.isValid(for: calibrationSnapshot),
                  calibrationSnapshot.displayedGlucose(for: reading) != nil,
                  let transmitter = self.bluetoothPeripheralManager.getCGMTransmitter() as? CGMLibre2Transmitter
            else {
                fail("Invalid Libre reading context", .invalidPayload)
                return
            }

            let receivedAt = Date()
            let transportAge = receivedAt.timeIntervalSince(reading.receivedAt)
            var candidateAcceptance = self.libreWatchReadingAcceptance
            if transport == .queuedUserInfo {
                // A fresh queued fallback is still clinically live. This occurs when an
                // interactive send fails or the activated phone is temporarily unreachable.
                if LibreWatchQueuedReadingRoutingPolicy.route(
                    transportAge: transportAge,
                    ownership: self.libreWatchOwnership
                ) == .attemptLiveAcceptance,
                   candidateAcceptance.accept(
                    reading,
                    for: currentSession.id,
                    now: receivedAt
                   ) {
                    let outcome = transmitter.receiveReadingFromWatch(
                        reading,
                        calibrationSnapshot: calibrationSnapshot
                    )
                    self.confirmLibreWatchReading(outcome, reading: reading, transmitter: transmitter, reply: reply)
                    return
                }

                let receipt = self.currentLibreWatchReleaseReceipt()
                let outcome: LibreWatchDeliveryOutcome
                if let rejection = LibreWatchHistoryPolicy.rejection(
                    reading: reading,
                    transport: transport,
                    session: currentSession,
                    calibration: calibrationSnapshot,
                    ownership: self.libreWatchOwnership,
                    receipt: receipt,
                    now: receivedAt
                ) {
                    outcome = rejection
                } else {
                    outcome = transmitter.receiveHistoricalReadingFromWatch(
                        reading,
                        session: currentSession,
                        calibrationSnapshot: calibrationSnapshot,
                        releaseReceipt: receipt,
                        now: receivedAt
                    )
                }
                self.confirmLibreWatchReading(outcome, reading: reading, transmitter: transmitter, reply: reply)
                return
            }

            guard self.libreWatchOwnership == .watch else {
                fail("Watch is not the owner of this Libre session", .wrongOwnership)
                return
            }
            if transportAge < 0 || transportAge > LibreWatchReadingAcceptancePolicy.maximumTransportAge {
                fail("Libre reading is too old for interactive delivery", .tooOld)
                return
            }
            guard candidateAcceptance.accept(
                reading,
                for: currentSession.id,
                now: receivedAt
            ) else {
                if transmitter.watchReadingIsStored(reading.id, sensorID: calibrationSnapshot.activeSensorID) {
                    self.confirmLibreWatchReading(.duplicate, reading: reading, transmitter: transmitter, reply: reply)
                } else {
                    fail("Libre reading is out of live order; queued history may fill the gap", .outOfOrder)
                }
                return
            }

            let outcome = transmitter.receiveReadingFromWatch(
                reading,
                calibrationSnapshot: calibrationSnapshot
            )
            self.confirmLibreWatchReading(outcome, reading: reading, transmitter: transmitter, reply: reply)

        case .reportDiagnostic:
            break // The diagnostics-only path is handled before active sensor validation.
            }
        }

        return true
    }

    private func receiveLibreWatchDiagnostic(
        _ message: [String: Any], sessionID: UUID, reply: (([String: Any]) -> Void)?
    ) {
        let fail: (String, LibreWatchDeliveryOutcome?) -> Void = { reason, outcome in
            reply?([
                LibreWatchMessageKey.success: false,
                LibreWatchMessageKey.error: reason,
                LibreWatchMessageKey.deliveryOutcome: outcome?.rawValue ?? LibreWatchDeliveryOutcome.invalidPayload.rawValue
            ])
        }
        guard let data = message[LibreWatchMessageKey.diagnosticEvent] as? Data,
              let event = try? JSONDecoder().decode(LibreWatchDiagnosticEvent.self, from: data)
        else {
            fail("Invalid Libre Watch diagnostic", .invalidPayload)
            return
        }

        let itemID = (message[LibreWatchMessageKey.deliveryItemID] as? String).flatMap(UUID.init(uuidString:))
        guard (event.sessionID == nil || event.sessionID == sessionID),
              itemID == nil || itemID == event.eventID
        else {
            fail("Libre Watch diagnostic context mismatch", .wrongSession)
            return
        }
        // Older builds recorded receipt IDs before exporting the full event. That ledger
        // is not proof of durable journal storage. Always use the export store's stable-ID
        // deduplication, including upgrade/replayed events already present in that ledger.
        let receiptTime = Date()
        TroubleshootingLogStore.shared.recordWatchDiagnostic(
            TroubleshootingWatchDiagnostic(event), receivedAt: receiptTime
        ) { [weak self] stored in
            if stored {
                // This compatibility ledger is not the durable receipt authority.
                // Keep its main-thread ownership without delaying the storage reply on UI work.
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    _ = self.libreWatchDiagnosticReceipts.accept(event.eventID)
                    LibreWatchSessionStore.saveDiagnosticReceipts(self.libreWatchDiagnosticReceipts)
                }
            }
            var response: [String: Any] = [
                LibreWatchMessageKey.success: stored,
                LibreWatchMessageKey.durableReceipt: stored
            ]
            if !stored { response[LibreWatchMessageKey.deliveryOutcome] = LibreWatchDeliveryOutcome.collectorUnavailable.rawValue }
            reply?(response)
        }
        // The typed journal export above is the sole consumer-facing BLE fact. Do not also
        // turn Watch-Libre recovery into generic phone Bluetooth or phone-to-Watch sharing.
        // Receipt time remains the trace timestamp; queued Watch events carry their origin time.
        var context = [
                "watchTime=\(event.watchTimestamp.map { ISO8601DateFormatter().string(from: $0) } ?? "n/a")",
                "receiptTime=\(ISO8601DateFormatter().string(from: receiptTime))",
                "trigger=\(event.trigger ?? "n/a")",
                "attempt=\(event.attemptID?.uuidString ?? "n/a")",
                "attemptStarted=\(event.attemptStartedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "n/a")",
                "source=\(event.reconcileSource?.rawValue ?? "n/a")",
                "scene=\(event.applicationState?.rawValue ?? "n/a")",
                "sceneActive=\(event.applicationIsActive.map { String($0) } ?? "n/a")",
                "runtime=\(event.extendedRuntimeIsRunning.map { String($0) } ?? "n/a")",
                "runtimeState=\(event.extendedRuntimeState ?? "none")",
                "runtimeStartRequested=\(event.extendedRuntimeStartRequested.map { String($0) } ?? "n/a")",
                "app=\(event.appVersion ?? "n/a") (\(event.appBuild ?? "n/a"))",
                "watchOS=\(event.watchOSVersion ?? "n/a")",
                "process=\(event.processID?.uuidString ?? "n/a")",
                "central=\(event.centralInstanceID?.uuidString ?? "n/a")",
                "connection=\(event.connectionInstanceID?.uuidString ?? "n/a")",
                "sequence=\(event.sequenceNumber.map { String($0) } ?? "n/a")",
                "peripheral=\(event.peripheralState ?? "n/a")",
                "phase=\(event.connectionPhase ?? "n/a")",
                "deadlinePhase=\(event.deadlinePhase ?? "none")",
                "deadline=\(event.deadlineAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")",
                "remainingBudget=\(event.remainingExecutionBudget.map { String(format: "%.1f", $0) } ?? "none")",
                "receivingDeadline=\(event.receivingBudgetDeadline.map { ISO8601DateFormatter().string(from: $0) } ?? "none")",
                "technicalFrame=\(event.technicalFrameAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")",
                "measurement=\(event.measurementAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none")",
                "action=\(event.bluetoothAction ?? "none")",
                "reason=\(event.actionReason ?? "none")",
                "reconnectSource=\(event.reconnectObservationSource?.rawValue ?? "none")",
                "errorDomain=\(event.errorDomain ?? "none")",
                "errorClass=\(event.bluetoothErrorClassification ?? "none")",
                "journalDropped=\(event.journalDroppedCount.map { String($0) } ?? "0")",
                "generation=\(event.generation?.uuidString ?? "n/a")",
                "runtimeReason=\(event.runtimeInvalidationReason.map { String($0) } ?? "none")",
                "runtimeError=\(event.runtimeError ?? "none")"
        ].joined(separator: " ")
        if let returnAttempt = event.returnAttempt {
            context += " " + returnAttempt.summary { ISO8601DateFormatter().string(from: $0) }
        }
        trace(
                "Watch Libre diagnostic: event=%{public}@ sensor=%{public}@ isReconnecting=%{public}@ errorCode=%{public}@ %{public}@",
                log: self.log,
                category: ConstantsLog.categoryWatchManager,
                type: event.kind == .recoveryFailed ? .error : .info,
            event.kind.rawValue,
            event.sessionID?.uuidString ?? "legacy-session",
            event.isReconnecting.map { String($0) } ?? "n/a",
            event.errorCode.map { String($0) } ?? "none",
            context
        )
    }

    private func confirmLibreWatchReading(
        _ outcome: LibreWatchDeliveryOutcome,
        reading: LibreWatchDirectReadingPayload,
        transmitter: CGMLibre2Transmitter,
        reply: (([String: Any]) -> Void)?
    ) {
        let persistedOutcome = outcome == .liveAccepted || outcome == .historicalInserted || outcome == .duplicate
        let complete: (Bool) -> Void = { [weak self] stored in
            guard let self else { return }
            let finalOutcome = persistedOutcome && !stored ? LibreWatchDeliveryOutcome.historyNotInserted : outcome
            WatchDeliveryEvidencePipeline.phoneStorage(stored && persistedOutcome,
                outcome: finalOutcome, reading: reading)
            if stored, outcome == .liveAccepted,
               self.libreWatchOwnership == .watch,
               self.libreWatchDirectSession?.id == reading.sessionID {
                // A newer save may have completed first. accept() cannot roll its watermark back.
                _ = self.libreWatchReadingAcceptance.accept(reading, for: reading.sessionID, now: Date())
            }
            trace("Watch Libre storage result: %{public}@ payload=%{public}@", log: self.log,
                  category: ConstantsLog.categoryWatchManager,
                  type: stored ? .info : .error, finalOutcome.rawValue, reading.id.uuidString)
            reply?([
                LibreWatchMessageKey.success: persistedOutcome && stored,
                LibreWatchMessageKey.durableReceipt: persistedOutcome && stored,
                LibreWatchMessageKey.deliveryOutcome: finalOutcome.rawValue,
                LibreWatchMessageKey.ownership: self.libreWatchOwnership.rawValue
            ])
        }
        if persistedOutcome {
            transmitter.confirmReadingStorage(completion: complete)
        } else {
            complete(false)
        }
    }

    private func sendLibreWatchDeliveryReceipt(itemID: UUID, sessionID: UUID, response: [String: Any]) {
        guard session.activationState == .activated else { return }
        WatchDeliveryEvidenceStore.shared.recordTransport(stream: .receipt, action: "sendAttempt")
        var receipt = response
        receipt[LibreWatchMessageKey.deliveryReceiptID] = itemID.uuidString
        receipt[LibreWatchMessageKey.sessionID] = sessionID.uuidString
        if session.isReachable {
            session.sendMessage(receipt, replyHandler: nil) { [weak self] error in
                WatchDeliveryEvidenceStore.shared.recordTransport(stream: .receipt, action: "sendFailed",
                    outcome: WatchDeliveryEvidenceStore.errorClass(error))
                DispatchQueue.main.async {
                    guard let self, self.session.activationState == .activated else { return }
                    self.session.transferUserInfo(receipt)
                    WatchDeliveryEvidenceStore.shared.recordTransport(stream: .receipt, action: "queuedSubmitted")
                }
            }
        } else {
            session.transferUserInfo(receipt)
            WatchDeliveryEvidenceStore.shared.recordTransport(stream: .receipt, action: "queuedSubmitted")
        }
    }

    @discardableResult
    private func updateLibreWatchUnlockCounter(
        from message: [String: Any],
        session preparedSession: inout LibreWatchDirectSession
    ) -> Bool {
        guard let counter = message[LibreWatchMessageKey.unlockCounter] as? Int,
              counter >= 0,
              counter <= Int(UInt16.max),
              UserDefaults.standard.libreSensorUID == preparedSession.sensorUID,
              UserDefaults.standard.librePatchInfo == preparedSession.patchInfo
        else { return false }

        preparedSession.unlockCount = LibreWatchUnlockCounterPolicy.highest(
            incoming: UInt16(counter),
            session: preparedSession,
            storedSession: LibreWatchSessionStore.loadSession(),
            activeSensorUID: UserDefaults.standard.libreSensorUID,
            activePatchInfo: UserDefaults.standard.librePatchInfo,
            activeCounter: UserDefaults.standard.libreActiveSensorUnlockCount
        )
        libreWatchDirectSession = preparedSession
        UserDefaults.standard.libreActiveSensorUnlockCount = preparedSession.unlockCount
        LibreWatchSessionStore.saveSession(preparedSession)
        return true
    }

    // MARK: - Public functions

    func updateWatchApp(forceComplicationUpdate: Bool) {
        processWatchUpdate(updateTypes: [.status, .bgReadings], forceComplicationUpdate: forceComplicationUpdate)
    }

    /// Sends a newly created or changed iPhone calibration to the active Watch session.
    func publishLibreWatchCalibration() {
        if Thread.isMainThread {
            sendLibreWatchSession()
        } else {
            DispatchQueue.main.async { [weak self] in self?.sendLibreWatchSession() }
        }
    }

    deinit {
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.snoozeAllAlertsUntilDate.rawValue)
        UserDefaults.standard.removeObserver(self, forKeyPath: UserDefaults.Key.nightscoutDeviceStatusWasUpdated.rawValue)
        libreWatchObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

// MARK: - conform to WCSessionDelegate protocol

extension WatchManager: WCSessionDelegate {
    func sessionDidBecomeInactive(_: WCSession) {}

    func sessionDidDeactivate(_: WCSession) {
        session = WCSession.default
        session.delegate = self
        activateSessionIfNeeded()
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        completeSessionActivationRequest()

        if let error {
            trace("watch session activation failed, error = %{public}@", log: log, category: ConstantsLog.categoryWatchManager, type: .error, troubleshooting: .detailed(.integration(name: .watchConnectivity, activity: .failed)), error.localizedDescription)
            return
        }

        guard activationState == .activated else { return }

        // send the update that was deferred while the session was activating
        DispatchQueue.main.async { [weak self] in
            self?.processWatchUpdate(updateTypes: [.status, .bgReadings], forceComplicationUpdate: false)
            self?.sendLibreWatchSession()
        }
    }

    // process any received messages from the watch app
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if handleLibreWatchMessage(message, transport: .interactiveMessage, reply: nil) { return }
        if let kind = message["requestWatchUpdate"] as? String {
            DispatchQueue.main.async {
                switch kind {
                case "status": self.phoneRefresh.refreshLegacy(["status"])
                case "bgReadings": self.phoneRefresh.refreshLegacy(["bgReadings"])
                case "agp": self.phoneRefresh.refreshLegacy(["agp"], raw: message)
                default: break
                }
            }
        }
    }

    func session(
        _: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        if handleLibreWatchMessage(message, transport: .interactiveMessage, reply: replyHandler) { return }
        DispatchQueue.main.async {
            if self.phoneRefresh.receive(message, reply: replyHandler) { return }
            replyHandler([LibreWatchMessageKey.success: false, "watchRefreshUnsupported": true])
        }
    }

    func session(_: WCSession, didReceive file: WCSessionFile) {
        // WC deletes its temporary URL on return: copy/validate synchronously first.
        _ = WatchDeliveryEvidenceTransfer.shared.receive(fileURL: file.fileURL, metadata: file.metadata)
    }

    func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        _ = handleLibreWatchMessage(userInfo, transport: .queuedUserInfo, reply: nil)
    }

    func session(_: WCSession, didReceiveMessageData _: Data) {}

    func sessionReachabilityDidChange(_ session: WCSession) {
        if session.isReachable {
            DispatchQueue.main.async {
                self.phoneRefresh.reachable()
                self.sendLibreWatchSession()
            }
        }
    }
}
