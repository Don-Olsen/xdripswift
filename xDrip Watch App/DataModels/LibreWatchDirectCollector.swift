import Combine
import CoreBluetooth
import Foundation
import WatchKit

/// Maintains the direct Libre connection while Watch owns the sensor.
/// Ownership is explicit and persistent; leaving the view does not stop reception.
final class LibreWatchDirectCollector: NSObject, ObservableObject {
    @Published private(set) var state = LibreWatchDirectState()
    @Published private(set) var bluetoothStateText = "UNKNOWN"

    private weak var watchState: WatchStateModel?
    private var preparedSession: LibreWatchDirectSession?
    private var centralManager: CBCentralManager?
    private var sensorPeripheral: CBPeripheral?
    private var matchedPeripheralName: String?
    private var writeCharacteristic: CBCharacteristic?
    private var receiveCharacteristic: CBCharacteristic?
    private var frameAssembler = Libre2WatchDirectFrameAssembler()
    private var scanIsPending = false
    private var deliberatelyDisconnecting = false
    private var returnAfterDisconnect: (() -> Void)?
    private var dataExpectedSince: Date?
    private var lastFragmentReceivedAt: Date?
    private var healthTimer: Timer?
    private var watchStateObservers = Set<AnyCancellable>()
    private var reconnectFallbackWorkItem: DispatchWorkItem?
    private var systemAutoReconnectIsActive = false
    private var manualConnectIsPending = false
    private var recoveryProgress: LibreWatchRecoveryProgress?
    private var setupInProgress = false
    private var applicationIsActive = false
    private var scene: LibreWatchScene = .unknown
    private var extendedRuntimeSession: WKExtendedRuntimeSession?
    private var extendedRuntimeIsRunning: Bool { extendedRuntimeSession?.state == .running }
    private var userInitiatedRuntimeStart = false
    private var disconnectGate = LibreWatchDisconnectGate()
    private var lastDiagnosticContext: LibreWatchDiagnosticContext?
    private var scanAfterReconnectCancellation = false
    private var recoveryDiagnosticIsPending = false
    private var recoveryFailureWasReported = false

    private var connectionOptions: [String: Any] {
        [CBConnectPeripheralOptionEnableAutoReconnect: true]
    }

    private var timedRecoveryIsAllowed: Bool {
        LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: applicationIsActive,
            extendedRuntimeIsRunning: extendedRuntimeIsRunning,
            ownership: watchState?.libreWatchOwnership ?? .iphone
        )
    }

    private var eventDrivenRecoveryIsAllowed: Bool {
        LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(
            ownership: watchState?.libreWatchOwnership ?? .iphone
        ) && preparedSession?.isValid == true && !deliberatelyDisconnecting
    }

    func prepare(with watchState: WatchStateModel) {
        if self.watchState !== watchState {
            self.watchState = watchState
            watchStateObservers.removeAll()

            watchState.$libreWatchDirectSession
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] session in self?.updateSession(session) }
                .store(in: &watchStateObservers)

            watchState.$libreWatchOwnership
                .dropFirst()
                // @Published sends from willSet. Re-read ownership only after it is committed.
                .receive(on: DispatchQueue.main)
                .sink { [weak self] ownership in self?.ownershipDidChange(ownership) }
                .store(in: &watchStateObservers)
        }

        updateSession(watchState.libreWatchDirectSession)
        startHealthMonitoring()

        if centralManager == nil {
            centralManager = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [
                    CBCentralManagerOptionRestoreIdentifierKey: "com.xdrip.watch.libre-direct-central",
                    CBCentralManagerOptionShowPowerAlertKey: true
                ]
            )
        }

        if watchState.libreWatchOwnership == .watch {
            updateRecoveryActivity(trigger: .prepare)
        }
    }

    func updateSession(_ session: LibreWatchDirectSession?) {
        let previousSensorUID = preparedSession?.sensorUID
        var resolvedSession = session

        // A phone context may arrive with an older unlock counter than the Watch has already used.
        // Preserve the highest counter for the same sensor so a context refresh cannot roll it back.
        if var incoming = session,
           let current = preparedSession,
           current.representsSameSensor(as: incoming),
           current.unlockCount > incoming.unlockCount {
            incoming.unlockCount = current.unlockCount
            resolvedSession = incoming
        }

        preparedSession = resolvedSession
        if recoveryProgress?.sessionID != resolvedSession?.id, let resolvedSession {
            let stored = UserDefaults.standard.data(forKey: LibreWatchMessageKey.recoveryProgress)
                .flatMap { try? JSONDecoder().decode(LibreWatchRecoveryProgress.self, from: $0) }
            recoveryProgress = stored?.sessionID == resolvedSession.id
                ? stored : LibreWatchRecoveryProgress(sessionID: resolvedSession.id)
        }
        let sensorChanged: Bool
        if let previousSensorUID, let nextSensorUID = resolvedSession?.sensorUID {
            sensorChanged = previousSensorUID != nextSensorUID
        } else {
            sensorChanged = false
        }

        let watchSessionEnded = resolvedSession == nil
        if LibreWatchLifecyclePolicy.shouldStopExtendedRuntime(
            ownership: watchState?.libreWatchOwnership ?? .iphone,
            sensorChanged: sensorChanged,
            watchSessionEnded: watchSessionEnded
        ) {
            stopExtendedRuntime()
        }

        if sensorChanged, watchState?.libreWatchOwnership == .watch {
            returnLibreToPhone()
            return
        }
        if resolvedSession?.isValid != true {
            ownershipDidChange(.iphone)
        }
        state.sessionAvailable(
            resolvedSession,
            preserveRuntimeState: watchState?.libreWatchOwnership == .watch
        )
    }

    func ownershipDidChange(_ ownership: LibreWatchOwnership) {
        switch ownership {
        case .watch:
            updateRecoveryActivity(trigger: .ownership)
        case .iphone:
            stopExtendedRuntime()
            deliberatelyDisconnecting = true
            scanAfterReconnectCancellation = false
            systemAutoReconnectIsActive = false
            recoveryProgress = preparedSession.map { LibreWatchRecoveryProgress(sessionID: $0.id) }
            persistRecoveryProgress()
            returnAfterDisconnect = nil
            cancelReconnectFallback()
            scanIsPending = false
            centralManager?.stopScan()
            if let sensorPeripheral {
                centralManager?.cancelPeripheralConnection(sensorPeripheral)
                if sensorPeripheral.state != .disconnected {
                    return
                }
            }
            finishStoppingForPhoneOwnership()
        case .releasingToWatch:
            break
        case .releasingToPhone, .recovery:
            stopExtendedRuntime()
            cancelReconnectFallback()
        }
    }

    func takeOverLibre() {
        guard let preparedSession, preparedSession.isValid else {
            state.sessionAvailable(nil)
            return
        }
        guard watchState?.libreWatchOwnership == .iphone else {
            resumeDirectReceptionIfOwned()
            return
        }

        state.beginHandoff()
        watchState?.requestLibreWatchOwnership { [weak self] success, error in
            guard let self else { return }
            guard success, self.watchState?.libreWatchOwnership == .watch else {
                self.userInitiatedRuntimeStart = false
                self.state.fail(
                    error == LibreWatchDirectFailure.phoneUnavailable.rawValue ? .phoneUnavailable : .ownershipFailed,
                    error: error
                )
                return
            }
            self.userInitiatedRuntimeStart = true
            self.startExtendedRuntimeIfEligible()
            self.updateRecoveryActivity(trigger: .ownership)
        }
    }

    func resumeDirectReceptionIfOwned() {
        updateRecoveryActivity(trigger: .ownership)
    }

    func returnLibreToPhone() {
        guard let watchState else { return }
        guard watchState.libreWatchOwnership == .watch else {
            ownershipDidChange(.iphone)
            return
        }
        guard watchState.phoneIsReachable else {
            state.fail(.phoneUnavailable, error: "Bring iPhone nearby before returning the sensor")
            return
        }

        state.beginReturn()
        deliberatelyDisconnecting = true
        scanAfterReconnectCancellation = false
        stopExtendedRuntime()
        cancelReconnectFallback()
        centralManager?.stopScan()
        let mustWaitForDisconnect = sensorPeripheral.map { $0.state != .disconnected } ?? false
        if mustWaitForDisconnect {
            returnAfterDisconnect = { [weak self] in self?.completeReturnToPhone() }
        }
        if let sensorPeripheral {
            systemAutoReconnectIsActive = false
            centralManager?.cancelPeripheralConnection(sensorPeripheral)
        }
        if !mustWaitForDisconnect {
            completeReturnToPhone()
        }
    }

    private func completeReturnToPhone() {
        guard let watchState else { return }
        watchState.releaseLibreWatchOwnership(unlockCounter: preparedSession?.unlockCount) { [weak self] success, error in
            guard let self else { return }
            if success {
                self.clearTransientBluetoothState()
                self.state.returnedToPhone(session: self.preparedSession)
                self.deliberatelyDisconnecting = false
            } else {
                self.deliberatelyDisconnecting = false
                self.state.fail(.ownershipFailed, error: error)
                self.resumeDirectReceptionIfOwned()
            }
        }
    }

    private func finishPendingReturnAfterDisconnect() {
        let completion = returnAfterDisconnect
        returnAfterDisconnect = nil
        completion?()
    }

    private func finishStoppingForPhoneOwnership() {
        clearTransientBluetoothState()
        recoveryDiagnosticIsPending = false
        recoveryFailureWasReported = false
        state.returnedToPhone(session: preparedSession)
        deliberatelyDisconnecting = false
    }

    func nativeGlucoseText(isMgDl: Bool) -> String {
        guard let reading = state.directReading else { return "—" }
        if isMgDl {
            return String(format: "%.0f", reading.nativeGlucoseMGDL)
        }
        return String(format: "%.1f", reading.nativeGlucoseMGDL / ConstantsBloodGlucose.mmollToMgdl)
    }

    private func startExtendedRuntimeIfEligible() {
        guard LibreWatchLifecyclePolicy.shouldStartExtendedRuntime(
            userInitiatedTakeover: userInitiatedRuntimeStart,
            applicationIsActive: applicationIsActive,
            ownership: watchState?.libreWatchOwnership ?? .iphone,
            alreadyHasSession: extendedRuntimeSession != nil
        ) else { return }

        let session = WKExtendedRuntimeSession()
        session.delegate = self
        extendedRuntimeSession = session
        session.start()
    }

    private func stopExtendedRuntime() {
        userInitiatedRuntimeStart = false

        guard let session = extendedRuntimeSession else { return }
        extendedRuntimeSession = nil
        if session.state != .invalid {
            session.invalidate()
        }
    }

    /// Called at real execution opportunities. Exactly one operation is selected; an overdue
    /// cancellation cannot fall through into service discovery or another connect.
    private func updateRecoveryActivity(trigger: LibreWatchRecoveryTrigger = .setup, at now: Date = Date()) {
        startExtendedRuntimeIfEligible()
        let action = LibreWatchRecoveryPolicy.action(
            ownership: watchState?.libreWatchOwnership ?? .iphone,
            validSession: preparedSession?.isValid == true && !deliberatelyDisconnecting,
            poweredOn: centralManager?.state == .poweredOn, peripheral: peripheralState,
            scanning: centralManager?.isScanning == true,
            systemReconnecting: systemAutoReconnectIsActive, manualConnecting: manualConnectIsPending,
            cancelling: scanAfterReconnectCancellation,
            setupInProgress: setupInProgress, notificationsReady: dataExpectedSince != nil,
            receivingFrame: frameAssembler.assembledByteCount > 0 && lastFragmentReceivedAt.map {
                now.timeIntervalSince($0) <= Libre2WatchDirectConstants.maximumFragmentGap
            } == true,
            attemptStartedAt: recoveryProgress?.attemptStartedAt,
            lastActivityAt: [recoveryProgress?.lastPacketAt, dataExpectedSince].compactMap { $0 }.max(),
            now: now, applicationIsActive: applicationIsActive,
            extendedRuntimeIsRunning: extendedRuntimeIsRunning, trigger: trigger
        )
        reportDecision(trigger: trigger, action: action)
        if !timedRecoveryIsAllowed { cancelReconnectFallback() }
        switch action {
        case .stopped:
            cancelReconnectFallback()
            centralManager?.stopScan()
            scanIsPending = false
            if !deliberatelyDisconnecting, let sensorPeripheral, sensorPeripheral.state != .disconnected {
                deliberatelyDisconnecting = true
                centralManager?.cancelPeripheralConnection(sensorPeripheral)
            }
        case .waitForExecution, .waitForNotifications:
            break
        case .waitForBluetooth:
            cancelReconnectFallback()
        case .waitForCancellation:
            // Core Bluetooth owns cancellation. A later callback/lifecycle also rechecks state.
            break
        case .scanConfirmedSensor:
            if centralManager?.isScanning == true { return }
            if scanAfterReconnectCancellation { finishReconnectCancellationAndScan() }
            else {
                clearTransientBluetoothState()
                scanIsPending = true
                beginScanningIfPossible()
            }
        case .connectConfirmedSensor:
            if let sensorPeripheral, let centralManager { connect(sensorPeripheral, using: centralManager) }
        case .discoverServices:
            guard let sensorPeripheral, identityAndOwnershipAreConfirmed(for: sensorPeripheral) else { return }
            recoveryProgress?.begin(at: now)
            persistRecoveryProgress()
            setupInProgress = true
            state.connecting()
            sensorPeripheral.discoverServices([CBUUID(string: Libre2WatchDirectConstants.serviceUUIDString)])
            scheduleReconnectFallback(for: sensorPeripheral)
        case .waitForSystemReconnect, .waitForConnection:
            centralManager?.stopScan()
            if let sensorPeripheral { scheduleReconnectFallback(for: sensorPeripheral) }
        case .restartConfirmedSensorScan:
            if let sensorPeripheral {
                beginControlledSensorRecovery(for: sensorPeripheral, error: "Libre recovery deadline reached; scanning the confirmed sensor", trigger: trigger)
            }
        }
    }

    private func beginScanningIfPossible() {
        guard scanIsPending,
              !scanAfterReconnectCancellation,
              eventDrivenRecoveryIsAllowed,
              let centralManager
        else { return }

        if let sensorPeripheral, sensorPeripheral.state != .disconnected {
            return
        }

        switch centralManager.state {
        case .poweredOn:
            guard !centralManager.isScanning, !systemAutoReconnectIsActive, !manualConnectIsPending else { return }
            scanIsPending = false
            state.scanning()
            centralManager.scanForPeripherals(
                withServices: [CBUUID(string: Libre2WatchDirectConstants.serviceUUIDString)],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        case .poweredOff, .unauthorized, .unsupported:
            state.fail(.bluetoothUnavailable, error: bluetoothStateText)
        case .resetting, .unknown:
            break
        @unknown default:
            state.fail(.bluetoothUnavailable, error: "Unknown Bluetooth state")
        }
    }

    private func scheduleRescan() {
        guard eventDrivenRecoveryIsAllowed else { return }
        systemAutoReconnectIsActive = false
        // This is a callback-driven scan, not a delayed timer which can disappear on suspension.
        updateRecoveryActivity(trigger: .connectionFailed)
    }

    func applicationActivityDidChange(scene: LibreWatchScene) {
        self.scene = scene
        applicationIsActive = scene == .active
        updateRecoveryActivity(trigger: .scene)
        watchState?.refreshDirectLibreReadingFreshness(at: Date())
    }

    private func connect(_ peripheral: CBPeripheral, using central: CBCentralManager) {
        guard eventDrivenRecoveryIsAllowed, !scanAfterReconnectCancellation,
              !systemAutoReconnectIsActive, !manualConnectIsPending, central.state == .poweredOn,
              peripheral.state == .disconnected,
              identityAndOwnershipAreConfirmed(for: peripheral) else { return }
        central.stopScan()
        systemAutoReconnectIsActive = false
        cancelReconnectFallback()
        recoveryProgress?.begin(at: Date())
        persistRecoveryProgress()
        state.connecting()
        manualConnectIsPending = true
        central.connect(peripheral, options: connectionOptions)
        scheduleReconnectFallback(for: peripheral)
    }

    private func scheduleReconnectFallback(for peripheral: CBPeripheral) {
        cancelReconnectFallback()
        guard timedRecoveryIsAllowed, !scanAfterReconnectCancellation else { return }
        recoveryProgress?.begin(at: Date())
        persistRecoveryProgress()
        guard let startedAt = recoveryProgress?.attemptStartedAt else { return }
        let peripheralIdentifier = peripheral.identifier

        switch LibreWatchLifecyclePolicy.reconnectFallbackAction(
            reconnectStartedAt: startedAt,
            now: Date(),
            applicationIsActive: applicationIsActive,
            extendedRuntimeIsRunning: extendedRuntimeIsRunning,
            ownership: watchState?.libreWatchOwnership ?? .iphone
        ) {
        case .noAdditionalWork:
            return
        case .restartConfirmedSensorScan:
            beginControlledSensorRecovery(
                for: peripheral,
                error: "Automatic reconnect timed out; returning to the NFC-confirmed sensor scan", trigger: .timer
            )
        case let .wait(remaining):
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      self.timedRecoveryIsAllowed,
                      !self.deliberatelyDisconnecting,
                      self.recoveryProgress?.attemptStartedAt == startedAt,
                      let currentPeripheral = self.sensorPeripheral,
                      currentPeripheral.identifier == peripheralIdentifier,
                      self.dataExpectedSince == nil
                else { return }

                self.updateRecoveryActivity(trigger: .timer)
            }
            reconnectFallbackWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: workItem)
        }
    }

    /// Cancels the one existing connection attempt before returning to the exact-sensor scan.
    private func beginControlledSensorRecovery(for peripheral: CBPeripheral, error: String, trigger: LibreWatchRecoveryTrigger = .setupFailed) {
        guard eventDrivenRecoveryIsAllowed,
              peripheral === sensorPeripheral,
              !scanAfterReconnectCancellation
        else { return }

        beginRecoveryDiagnosticIfNeeded(trigger: trigger, action: .restartConfirmedSensorScan)
        cancelReconnectFallback()
        systemAutoReconnectIsActive = false
        scanIsPending = false
        centralManager?.stopScan()
        state.reconnecting(error: error)
        scanAfterReconnectCancellation = true
        centralManager?.cancelPeripheralConnection(peripheral)

        if peripheral.state == .disconnected {
            finishReconnectCancellationAndScan()
        }
    }

    private func finishReconnectCancellationAndScan() {
        guard scanAfterReconnectCancellation else { return }
        scanAfterReconnectCancellation = false
        clearTransientBluetoothState()
        scanIsPending = true
        beginScanningIfPossible()
    }

    private func cancelReconnectFallback() {
        reconnectFallbackWorkItem?.cancel()
        reconnectFallbackWorkItem = nil
    }

    private func clearTransientBluetoothState() {
        scanAfterReconnectCancellation = false
        systemAutoReconnectIsActive = false
        manualConnectIsPending = false
        cancelReconnectFallback()
        sensorPeripheral?.delegate = nil
        sensorPeripheral = nil
        matchedPeripheralName = nil
        writeCharacteristic = nil
        receiveCharacteristic = nil
        frameAssembler.reset()
        dataExpectedSince = nil
        setupInProgress = false
    }

    private func identityAndOwnershipAreConfirmed(for peripheral: CBPeripheral) -> Bool {
        guard !deliberatelyDisconnecting, watchState?.libreWatchOwnership == .watch,
              let preparedSession,
              preparedSession.isValid,
              peripheral === sensorPeripheral,
              preparedSession.matches(candidateName: matchedPeripheralName ?? peripheral.name)
        else { return false }
        return true
    }

    private func failAndRescan(_ failure: LibreWatchDirectFailure, error: String?) {
        reportRecoveryFailureIfNeeded()
        state.fail(failure, error: error)
        if let sensorPeripheral {
            reportDecision(trigger: .setupFailed, action: .restartConfirmedSensorScan)
            beginControlledSensorRecovery(for: sensorPeripheral, error: error ?? failure.rawValue)
        } else {
            scheduleRescan()
        }
    }

    private func bluetoothErrorDescription(_ error: Error?) -> String? {
        guard let error else { return nil }
        if let bluetoothError = error as? CBError,
           bluetoothError.code == .peripheralDisconnected {
            return nil
        }
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)"
    }

    private func handleDisconnect(
        peripheral: CBPeripheral,
        isReconnecting: Bool,
        disconnectedAt: Date,
        error: Error?
    ) {
        guard peripheral === sensorPeripheral else { return }

        if peripheral.state == .connected, !scanAfterReconnectCancellation, !deliberatelyDisconnecting {
            // A queued old disconnect can be delivered after Core Bluetooth is connected again.
            // Re-evaluate the current connection, never tear down its fresh subscription.
            reportDiagnostic(.disconnected, trigger: .disconnected, action: .waitForNotifications,
                             occurredAt: disconnectedAt, isReconnecting: isReconnecting, error: error)
            updateRecoveryActivity(trigger: .disconnected)
            return
        }
        manualConnectIsPending = false

        if scanAfterReconnectCancellation {
            finishReconnectCancellationAndScan()
            return
        }

        let ownership = watchState?.libreWatchOwnership ?? .iphone
        let action = LibreWatchLifecyclePolicy.disconnectRecoveryAction(
            isDeliberate: deliberatelyDisconnecting,
            systemIsReconnecting: isReconnecting,
            ownership: ownership
        )

        if action == .finishDeliberateDisconnect {
            cancelReconnectFallback()
            if returnAfterDisconnect != nil {
                finishPendingReturnAfterDisconnect()
            } else {
                finishStoppingForPhoneOwnership()
            }
            return
        }

        writeCharacteristic = nil
        receiveCharacteristic = nil
        frameAssembler.reset()
        dataExpectedSince = nil
        lastFragmentReceivedAt = nil
        setupInProgress = false
        state.reconnecting(error: bluetoothErrorDescription(error))
        recoveryProgress?.begin(at: disconnectedAt)
        persistRecoveryProgress()
        reportDiagnostic(.disconnected, trigger: .disconnected,
                         action: isReconnecting ? .waitForSystemReconnect : .connectConfirmedSensor,
                         occurredAt: disconnectedAt, isReconnecting: isReconnecting, error: error)
        switch action {
        case .waitForSystemReconnect:
            beginRecoveryDiagnosticIfNeeded()
            systemAutoReconnectIsActive = true
            updateRecoveryActivity(trigger: .disconnected)
        case .reconnectManually:
            beginRecoveryDiagnosticIfNeeded()
            systemAutoReconnectIsActive = false
            cancelReconnectFallback()
            updateRecoveryActivity(trigger: .disconnected)
        case .noAdditionalWork:
            systemAutoReconnectIsActive = isReconnecting && ownership == .watch
            cancelReconnectFallback()
        case .finishDeliberateDisconnect:
            break
        }
    }

    private func beginRecoveryDiagnosticIfNeeded(trigger: LibreWatchRecoveryTrigger = .disconnected, action: LibreWatchRecoveryAction = .waitForConnection) {
        recoveryProgress?.begin(at: Date())
        persistRecoveryProgress()
        guard !recoveryDiagnosticIsPending else { return }
        recoveryDiagnosticIsPending = true
        recoveryFailureWasReported = false
        reportDiagnostic(.recoveryStarted, trigger: trigger, action: action)
    }

    private func reportRecoveryFailureIfNeeded() {
        guard recoveryDiagnosticIsPending, !recoveryFailureWasReported else { return }
        recoveryFailureWasReported = true
        reportDiagnostic(.recoveryFailed, trigger: .setupFailed, action: .restartConfirmedSensorScan)
    }

    private func reportRecoverySuccessIfNeeded() {
        guard recoveryDiagnosticIsPending else { return }
        recoveryDiagnosticIsPending = false
        recoveryFailureWasReported = false
        reportDiagnostic(.recoverySucceeded, trigger: .packet, action: .waitForNotifications)
    }

    private func handleDisconnectOnce(
        peripheral: CBPeripheral,
        isReconnecting: Bool,
        disconnectedAt: Date,
        error: Error?
    ) {
        guard peripheral === sensorPeripheral,
              disconnectGate.accept(disconnectedAt: disconnectedAt) else { return }
        handleDisconnect(
            peripheral: peripheral,
            isReconnecting: isReconnecting,
            disconnectedAt: disconnectedAt,
            error: error
        )
    }

    private func startHealthMonitoring() {
        guard healthTimer == nil else { return }

        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.evaluateConnectionHealth(at: Date())
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
    }

    private func evaluateConnectionHealth(at date: Date) {
        watchState?.refreshDirectLibreReadingFreshness(at: date)
        updateRecoveryActivity(trigger: .timer, at: date)
    }

    private var peripheralState: LibreWatchPeripheralState {
        guard let sensorPeripheral else { return .absent }
        switch sensorPeripheral.state {
        case .connected: return .connected
        case .connecting: return .connecting
        case .disconnected: return .disconnected
        case .disconnecting: return .disconnecting
        @unknown default: return .absent
        }
    }

    private func persistRecoveryProgress() {
        guard let recoveryProgress, let data = try? JSONEncoder().encode(recoveryProgress) else { return }
        UserDefaults.standard.set(data, forKey: LibreWatchMessageKey.recoveryProgress)
    }

    private func diagnosticContext(trigger: LibreWatchRecoveryTrigger, action: LibreWatchRecoveryAction) -> LibreWatchDiagnosticContext {
        LibreWatchDiagnosticContext(
            scene: scene,
            runtime: extendedRuntimeIsRunning ? .running : (extendedRuntimeSession == nil ? .none : .starting),
            central: centralState,
            peripheral: peripheralState,
            stage: LibreWatchDiagnosticStage(rawValue: state.stage.rawValue) ?? .unavailable,
            trigger: trigger, action: action, recoveryStartedAt: recoveryProgress?.startedAt
        )
    }

    private var centralState: LibreWatchCentralState {
        guard let centralManager else { return .unknown }
        switch centralManager.state {
        case .poweredOn: return .poweredOn
        case .poweredOff: return .poweredOff
        case .resetting: return .resetting
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }

    private func setupCallbackIsCurrent(_ peripheral: CBPeripheral) -> Bool {
        guard identityAndOwnershipAreConfirmed(for: peripheral), !scanAfterReconnectCancellation else { return false }
        updateRecoveryActivity(trigger: .setup)
        return peripheral === sensorPeripheral && peripheral.state == .connected &&
            setupInProgress && !scanAfterReconnectCancellation
    }

    private func reportDiagnostic(_ kind: LibreWatchDiagnosticEventKind,
                                  trigger: LibreWatchRecoveryTrigger, action: LibreWatchRecoveryAction,
                                  occurredAt: Date = Date(), isReconnecting: Bool? = nil, error: Error? = nil) {
        watchState?.reportLibreWatchDiagnostic(LibreWatchDiagnosticEvent(
            kind: kind, isReconnecting: isReconnecting, errorCode: error.map { ($0 as NSError).code },
            occurredAt: occurredAt, context: diagnosticContext(trigger: trigger, action: action)
        ))
    }

    private func reportDecision(trigger: LibreWatchRecoveryTrigger, action: LibreWatchRecoveryAction) {
        guard watchState?.libreWatchOwnership == .watch else { return }
        let context = diagnosticContext(trigger: trigger, action: action)
        // Do not emit periodic timer/packet noise. Transitions and their causes are sufficient.
        if trigger == .timer || trigger == .packet {
            if action == .waitForExecution || action == .waitForNotifications { return }
            if lastDiagnosticContext?.action == action { return }
        }
        guard context != lastDiagnosticContext else { return }
        lastDiagnosticContext = context
        reportDiagnostic(.recoveryDecision, trigger: trigger, action: action)
    }

    deinit {
        reconnectFallbackWorkItem?.cancel()
        healthTimer?.invalidate()
        if let extendedRuntimeSession, extendedRuntimeSession.state != .invalid {
            extendedRuntimeSession.invalidate()
        }
    }
}

extension LibreWatchDirectCollector: WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        guard self.extendedRuntimeSession === extendedRuntimeSession else { return }
        updateRecoveryActivity(trigger: .runtime)
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        guard self.extendedRuntimeSession === extendedRuntimeSession else { return }
        // The system owns expiration. Do not create replacement sessions from the background.
        userInitiatedRuntimeStart = false
        updateRecoveryActivity(trigger: .runtime)
    }

    func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith _: WKExtendedRuntimeSessionInvalidationReason,
        error _: Error?
    ) {
        guard self.extendedRuntimeSession === extendedRuntimeSession else { return }
        self.extendedRuntimeSession = nil
        userInitiatedRuntimeStart = false
        updateRecoveryActivity(trigger: .runtime)
    }
}

extension LibreWatchDirectCollector: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: bluetoothStateText = "POWERED ON"
        case .poweredOff: bluetoothStateText = "POWERED OFF"
        case .unauthorized: bluetoothStateText = "UNAUTHORIZED"
        case .unsupported: bluetoothStateText = "UNSUPPORTED"
        case .resetting: bluetoothStateText = "RESETTING"
        case .unknown: bluetoothStateText = "UNKNOWN"
        @unknown default: bluetoothStateText = "UNKNOWN"
        }

        if central.state != .poweredOn {
            systemAutoReconnectIsActive = false
            manualConnectIsPending = false
            setupInProgress = false
            dataExpectedSince = nil
            if eventDrivenRecoveryIsAllowed { recoveryProgress?.begin(at: Date()); persistRecoveryProgress() }
        }
        updateRecoveryActivity(trigger: .bluetooth)
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard watchState?.libreWatchOwnership == .watch,
              let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let preparedSession
        else { return }

        let exactMatch = peripherals.first(where: {
            preparedSession.matches(candidateName: $0.name)
        })
        let soleUnnamedPeripheral = peripherals.count == 1 && peripherals[0].name == nil
            ? peripherals[0]
            : nil

        guard let restored = exactMatch ?? soleUnnamedPeripheral else {
            scanIsPending = true
            updateRecoveryActivity(trigger: .restoration)
            return
        }

        sensorPeripheral = restored
        matchedPeripheralName = restored.name ?? preparedSession.expectedPeripheralName
        restored.delegate = self
        scanIsPending = false
        central.stopScan()
        recoveryProgress?.begin(at: Date())
        persistRecoveryProgress()
        setupInProgress = false
        manualConnectIsPending = false

        switch restored.state {
        case .connected:
            state.connecting()
        case .connecting:
            systemAutoReconnectIsActive = true
            state.reconnecting(error: nil)
        case .disconnected:
            systemAutoReconnectIsActive = false
            state.reconnecting(error: nil)
        case .disconnecting:
            state.reconnecting(error: nil)
        @unknown default:
            state.reconnecting(error: nil)
        }
        updateRecoveryActivity(trigger: .restoration)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard eventDrivenRecoveryIsAllowed, !scanAfterReconnectCancellation,
              !systemAutoReconnectIsActive, !manualConnectIsPending,
              sensorPeripheral == nil || sensorPeripheral?.state == .disconnected,
              watchState?.libreWatchOwnership == .watch,
              let preparedSession
        else { return }
        let candidateName = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard preparedSession.matches(candidateName: candidateName) else { return }

        state.candidate(rssi: RSSI.intValue)
        sensorPeripheral = peripheral
        matchedPeripheralName = candidateName
        peripheral.delegate = self
        central.stopScan()
        guard identityAndOwnershipAreConfirmed(for: peripheral) else {
            scheduleRescan()
            return
        }
        recoveryProgress?.beginAttempt(at: Date())
        persistRecoveryProgress()
        connect(peripheral, using: central)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === sensorPeripheral else { return }
        manualConnectIsPending = false
        if scanAfterReconnectCancellation {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        systemAutoReconnectIsActive = false
        scanIsPending = false
        central.stopScan()
        guard identityAndOwnershipAreConfirmed(for: peripheral) else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        state.connecting()
        guard eventDrivenRecoveryIsAllowed else { return }
        recoveryProgress?.begin(at: Date())
        persistRecoveryProgress()
        setupInProgress = false
        updateRecoveryActivity(trigger: .connected)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral === sensorPeripheral else { return }
        systemAutoReconnectIsActive = false
        manualConnectIsPending = false
        if scanAfterReconnectCancellation, peripheral === sensorPeripheral {
            finishReconnectCancellationAndScan()
            return
        }
        if deliberatelyDisconnecting {
            if returnAfterDisconnect != nil {
                finishPendingReturnAfterDisconnect()
            } else {
                finishStoppingForPhoneOwnership()
            }
            return
        }

        recoveryProgress?.begin(at: Date())
        persistRecoveryProgress()
        state.reconnecting(error: bluetoothErrorDescription(error))
        beginRecoveryDiagnosticIfNeeded(trigger: .connectionFailed, action: .scanConfirmedSensor)
        reportDiagnostic(.recoveryFailed, trigger: .connectionFailed, action: .scanConfirmedSensor, error: error)
        scheduleRescan()
    }

    func centralManager(
        _: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        // The modern delegate is authoritative on watchOS 10+ (also our deployment target).
        // A legacy callback has no event timestamp and cannot safely identify a delayed duplicate.
        let modernCallbackAvailable: Bool
        if #available(watchOS 10.0, *) { modernCallbackAvailable = true }
        else { modernCallbackAvailable = false }
        guard LibreWatchDisconnectGate.useLegacyCallback(modernCallbackAvailable: modernCallbackAvailable) else { return }
        handleDisconnectOnce(peripheral: peripheral, isReconnecting: false, disconnectedAt: Date(), error: error)
    }

    @available(watchOS 10.0, *)
    func centralManager(
        _: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        handleDisconnectOnce(
            peripheral: peripheral,
            isReconnecting: isReconnecting,
            disconnectedAt: Date(timeIntervalSinceReferenceDate: timestamp),
            error: error
        )
    }
}

extension LibreWatchDirectCollector: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard setupCallbackIsCurrent(peripheral) else { return }
        if let error {
            failAndRescan(.serviceNotFound, error: error.localizedDescription)
            return
        }
        guard let service = peripheral.services?.first(where: {
            $0.uuid == CBUUID(string: Libre2WatchDirectConstants.serviceUUIDString)
        }) else {
            failAndRescan(.serviceNotFound, error: nil)
            return
        }

        peripheral.discoverCharacteristics([
            CBUUID(string: Libre2WatchDirectConstants.writeCharacteristicUUIDString),
            CBUUID(string: Libre2WatchDirectConstants.receiveCharacteristicUUIDString)
        ], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard setupCallbackIsCurrent(peripheral) else { return }
        if let error {
            failAndRescan(.characteristicNotFound, error: error.localizedDescription)
            return
        }

        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid.uuidString.uppercased() {
            case Libre2WatchDirectConstants.writeCharacteristicUUIDString:
                writeCharacteristic = characteristic
            case Libre2WatchDirectConstants.receiveCharacteristicUUIDString:
                receiveCharacteristic = characteristic
            default:
                break
            }
        }

        guard writeCharacteristic != nil, let receiveCharacteristic else {
            failAndRescan(.characteristicNotFound, error: nil)
            return
        }
        peripheral.setNotifyValue(true, for: receiveCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == CBUUID(string: Libre2WatchDirectConstants.receiveCharacteristicUUIDString),
              characteristic === receiveCharacteristic,
              setupCallbackIsCurrent(peripheral)
        else { return }
        guard error == nil, characteristic.isNotifying else {
            failAndRescan(.notificationSetupFailed, error: error?.localizedDescription)
            return
        }
        guard var preparedSession, let writeCharacteristic else {
            failAndRescan(.unlockWriteFailed, error: "Session or write channel is unavailable")
            return
        }

        guard preparedSession.unlockCount < UInt16.max else {
            failAndRescan(.unlockWriteFailed, error: "Libre unlock counter is exhausted")
            return
        }
        preparedSession.unlockCount += 1
        self.preparedSession = preparedSession
        state.recordUnlockCounter(preparedSession.unlockCount)
        watchState?.updateLibreWatchUnlockCounter(preparedSession.unlockCount)

        do {
            let unlock = try Libre2WatchDirectAlgorithms.streamingUnlockPayload(
                sensorUID: preparedSession.sensorUID,
                patchInfo: preparedSession.patchInfo,
                enableTime: preparedSession.unlockCode,
                unlockCount: preparedSession.unlockCount
            )
            peripheral.writeValue(Data(unlock), for: writeCharacteristic, type: .withResponse)
        } catch {
            failAndRescan(.unlockWriteFailed, error: error.localizedDescription)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == CBUUID(string: Libre2WatchDirectConstants.writeCharacteristicUUIDString),
              characteristic === writeCharacteristic,
              identityAndOwnershipAreConfirmed(for: peripheral), !scanAfterReconnectCancellation
        else { return }
        if let error {
            failAndRescan(.unlockWriteFailed, error: error.localizedDescription)
        } else {
            cancelReconnectFallback()
            dataExpectedSince = Date()
            setupInProgress = false
            state.notificationsActive()
            updateRecoveryActivity(trigger: .setup)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == CBUUID(string: Libre2WatchDirectConstants.receiveCharacteristicUUIDString),
              characteristic === receiveCharacteristic,
              identityAndOwnershipAreConfirmed(for: peripheral), !scanAfterReconnectCancellation
        else { return }
        // Even an incomplete fragment is a real execution opportunity after suspension.
        defer { updateRecoveryActivity(trigger: .packet) }
        if let error {
            failAndRescan(.invalidFrame, error: error.localizedDescription)
            return
        }
        guard let fragment = characteristic.value, !fragment.isEmpty else { return }
        lastFragmentReceivedAt = Date()

        do {
            guard let frame = try frameAssembler.append(fragment: fragment, at: Date()),
                  let preparedSession
            else { return }
            let now = Date()
            let decrypted = try Libre2WatchDirectAlgorithms.decryptBLE(
                sensorUID: preparedSession.sensorUID,
                data: frame
            )
            let reading = try Libre2WatchDirectAlgorithms.parseDirectReading(
                decryptedData: decrypted,
                parameters: preparedSession.algorithmParameters,
                receivedAt: now
            )
            if watchState?.submitLibreWatchReading(reading) == true {
                state.recordDirectReading(reading)
                reportRecoverySuccessIfNeeded()
                recoveryProgress?.receivedPacket(at: now)
                persistRecoveryProgress()
            }
        } catch {
            state.fail(.invalidFrame, error: error.localizedDescription)
        }
    }
}
