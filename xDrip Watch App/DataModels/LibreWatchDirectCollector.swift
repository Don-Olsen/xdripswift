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
    // A timed-out cancellation is retired from our generation, but retained until Core
    // Bluetooth confirms disconnection. No subsequent connect or phone handoff may race it.
    private var retiredPeripheral: CBPeripheral?
    private var matchedPeripheralName: String?
    private var writeCharacteristic: CBCharacteristic?
    private var receiveCharacteristic: CBCharacteristic?
    private var frameAssembler = Libre2WatchDirectFrameAssembler()
    private var frameLiveness = LibreWatchFrameLiveness()
    private var scanIsPending = false
    private var deliberatelyDisconnecting = false
    private var returnAfterDisconnect: (() -> Void)?
    private var connectionTiming = LibreWatchConnectionTiming()
    private var setupService: CBService?
    private var setupGeneration: UUID?
    private var restoredPeripheral: CBPeripheral?
    private var restorationState: LibreWatchRestorationState?
    private var healthTimer: Timer?
    private var watchStateObservers = Set<AnyCancellable>()
    private var reconnectFallbackWorkItem: DispatchWorkItem?
    private var systemAutoReconnectIsActive = false
    private var applicationState: LibreWatchApplicationState = .background
    private var extendedRuntimeSession: WKExtendedRuntimeSession?
    private var extendedRuntimeIsRunning = false
    private var userInitiatedRuntimeStart = false
    private var pendingLegacyDisconnect: DispatchWorkItem?
    private var disconnectGate = LibreWatchLegacyDisconnectGate()
    private var scanAfterReconnectCancellation = false
    private var recoveryAttemptState = LibreWatchSessionStore.loadRecoveryAttempt()
    private var pendingRecoveryDiagnostic: (trigger: String, startedAt: Date)?
    private var currentReconcileSource: LibreWatchRecoveryReconcileSource = .initialPreparation
    private var lastFrameProgressDiagnosticAt: Date?

    private var applicationIsActive: Bool { applicationState.applicationIsActive }
    private var monotonicNow: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func observedState(of peripheral: CBPeripheral) -> LibreWatchObservedPeripheralState {
        switch peripheral.state {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .connected: return .connected
        case .disconnecting: return .disconnecting
        @unknown default: return .unknown
        }
    }

    private var connectionOptions: [String: Any] {
        [CBConnectPeripheralOptionEnableAutoReconnect: true]
    }

    private var timedRecoveryIsAllowed: Bool {
        LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationState: applicationState,
            extendedRuntimeIsRunning: extendedRuntimeIsRunning,
            ownership: watchState?.libreWatchOwnership ?? .iphone
        )
    }

    private var eventDrivenRecoveryIsAllowed: Bool {
        LibreWatchLifecyclePolicy.eventDrivenRecoveryIsAllowed(
            ownership: watchState?.libreWatchOwnership ?? .iphone
        )
    }

    func prepare(with watchState: WatchStateModel) {
        if self.watchState !== watchState {
            self.watchState = watchState
            watchStateObservers.removeAll()

            watchState.$libreWatchDirectSession
                .dropFirst()
                .sink { [weak self] session in self?.updateSession(session) }
                .store(in: &watchStateObservers)

            watchState.$libreWatchOwnership
                .dropFirst()
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
            resumeDirectReceptionIfOwned()
        }
    }

    func updateSession(_ session: LibreWatchDirectSession?) {
        let previousSensorUID = preparedSession?.sensorUID
        let previousSessionID = preparedSession?.id
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
        if previousSessionID != resolvedSession?.id || previousSensorUID != resolvedSession?.sensorUID {
            cancelReconnectFallback()
            connectionTiming.invalidate()
            invalidateRestoration()
        }
        if let context = recoveryAttemptState.context {
            let contextMatches = resolvedSession.map {
                watchState?.libreWatchOwnership == .watch &&
                    context.sessionID == $0.id &&
                    context.sensorIdentity == $0.redactedIdentity()
            } ?? false
            if !contextMatches {
                invalidateRecoveryAttempt()
            }
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
        state.sessionAvailable(
            resolvedSession,
            preserveRuntimeState: watchState?.libreWatchOwnership == .watch
        )
    }

    func ownershipDidChange(_ ownership: LibreWatchOwnership) {
        switch ownership {
        case .watch:
            reconcileRecoveryState(at: Date(), source: .initialPreparation)
        case .iphone:
            stopExtendedRuntime()
            deliberatelyDisconnecting = true
            scanAfterReconnectCancellation = false
            systemAutoReconnectIsActive = false
            connectionTiming.invalidate()
            invalidateRestoration()
            invalidateRecoveryAttempt()
            returnAfterDisconnect = nil
            cancelReconnectFallback()
            scanIsPending = false
            centralManager?.stopScan()
            if let peripheral = peripheralToRelease() {
                beginCancellation(of: peripheral)
                return
            }
            finishStoppingForPhoneOwnership()
        case .releasingToWatch:
            break
        case .releasingToPhone, .recovery:
            stopExtendedRuntime()
            cancelReconnectFallback()
            connectionTiming.invalidate()
            invalidateRestoration()
            invalidateRecoveryAttempt()
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
            self.reconcileRecoveryState(at: Date(), source: .initialPreparation)
        }
    }

    func resumeDirectReceptionIfOwned(allowsEventDrivenStart: Bool = false) {
        guard watchState?.libreWatchOwnership == .watch,
              preparedSession?.isValid == true,
              !systemAutoReconnectIsActive,
              !scanAfterReconnectCancellation,
              (timedRecoveryIsAllowed || allowsEventDrivenStart)
        else { return }

        if centralManager?.isScanning == true { return }
        if let sensorPeripheral, sensorPeripheral.state != .disconnected {
            return
        }

        deliberatelyDisconnecting = false
        scanIsPending = true
        beginScanningIfPossible(allowsEventDrivenStart: allowsEventDrivenStart)
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
        connectionTiming.invalidate()
        invalidateRestoration()
        scanIsPending = false
        centralManager?.stopScan()
        if let peripheral = peripheralToRelease() {
            returnAfterDisconnect = { [weak self] in self?.completeReturnToPhone() }
            beginCancellation(of: peripheral)
        } else {
            completeReturnToPhone()
        }
    }

    private func completeReturnToPhone() {
        guard let watchState,
              sensorPeripheral == nil || sensorPeripheral?.state == .disconnected,
              releaseRetiredPeripheralIfDisconnected() else { return }
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
        invalidateRecoveryAttempt()
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
        extendedRuntimeIsRunning = false

        guard let session = extendedRuntimeSession else { return }
        extendedRuntimeSession = nil
        if session.state != .invalid {
            session.invalidate()
        }
    }

    private var receivingExecutionBudget: TimeInterval {
        LibreWatchLifecyclePolicy.receivingExecutionBudget(
            applicationState: applicationState,
            extendedRuntimeIsRunning: extendedRuntimeIsRunning
        )
    }

    /// Timers and new fallback scans wait for foreground/runtime execution. Existing Core
    /// Bluetooth work remains intact while Watch owns the sensor and completes via delegates.
    private func reconcileRecoveryState(
        at date: Date,
        source: LibreWatchRecoveryReconcileSource
    ) {
        currentReconcileSource = source
        startExtendedRuntimeIfEligible()
        let executionIsAvailable = timedRecoveryIsAllowed
        let uptime = monotonicNow
        let budgetChanged = connectionTiming.setExecutionAvailable(
            executionIsAvailable,
            at: date,
            monotonicTime: uptime
        )
        if budgetChanged { cancelReconnectFallback() }

        if connectionTiming.phase == .cancelling {
            evaluateCancellation()
            return
        }

        if let sensorPeripheral, !restorationBelongsToCurrentSession(for: sensorPeripheral) {
            normalizeObservedLink(sensorPeripheral, at: date)
        }

        guard watchState?.libreWatchOwnership == .watch
        else {
            if centralManager?.isScanning == true {
                centralManager?.stopScan()
                scanIsPending = false
            }
            cancelReconnectFallback()
            return
        }

        let allowsImmediateBluetoothAction = executionIsAvailable || source.grantsEventDrivenBluetoothAction
        guard allowsImmediateBluetoothAction else {
            cancelReconnectFallback()
            return
        }

        guard !scanAfterReconnectCancellation else { return }

        guard let sensorPeripheral else {
            resumeDirectReceptionIfOwned(allowsEventDrivenStart: source.grantsEventDrivenBluetoothAction)
            return
        }

        switch sensorPeripheral.state {
        case .connected:
            if restorationBelongsToCurrentSession(for: sensorPeripheral) {
                continueRestoredConnectionIfPossible(for: sensorPeripheral)
            } else if connectionTiming.setupInProgress {
                scheduleReconnectFallback(for: sensorPeripheral)
            } else if connectionTiming.phase == .receiving {
                connectionTiming.ensureReceivingBudget(
                    at: date,
                    timeout: receivingExecutionBudget,
                    executionIsAvailable: executionIsAvailable,
                    monotonicTime: uptime
                )
                scheduleReconnectFallback(for: sensorPeripheral)
            } else if connectionTiming.phase != .receiving {
                beginSetup(for: sensorPeripheral)
            }
        case .connecting:
            if restorationBelongsToCurrentSession(for: sensorPeripheral) {
                prepareRestoredConnectionAttemptIfNeeded(
                    for: sensorPeripheral,
                    systemIsReconnecting: true
                )
            }
            scheduleReconnectFallback(for: sensorPeripheral)
        case .disconnected:
            if restorationBelongsToCurrentSession(for: sensorPeripheral) {
                prepareRestoredConnectionAttemptIfNeeded(
                    for: sensorPeripheral,
                    systemIsReconnecting: false
                )
            }
            if systemAutoReconnectIsActive {
                scheduleReconnectFallback(for: sensorPeripheral)
                return
            }
            guard let centralManager, centralManager.state == .poweredOn else { return }
            if connectionTiming.phase == .connection {
                switch connectionTiming.failedConnectionAction(
                    at: date,
                    bluetoothIsPoweredOn: true,
                    monotonicTime: uptime
                ) {
                case .retryConfirmedPeripheral:
                    connect(sensorPeripheral, using: centralManager)
                case .scanConfirmedSensor:
                    scheduleRescan(allowsEventDrivenStart: source.grantsEventDrivenBluetoothAction)
                case .waitForBluetooth:
                    break
                }
            } else {
                connect(sensorPeripheral, using: centralManager)
            }
        case .disconnecting:
            scheduleReconnectFallback(for: sensorPeripheral)
        @unknown default:
            scheduleReconnectFallback(for: sensorPeripheral)
        }
    }

    private func beginScanningIfPossible(allowsEventDrivenStart: Bool = false) {
        guard scanIsPending,
              !scanAfterReconnectCancellation,
              connectionTiming.canStartBluetoothOperation,
              watchState?.libreWatchOwnership == .watch,
              (timedRecoveryIsAllowed || allowsEventDrivenStart),
              let centralManager
        else { return }

        if let sensorPeripheral, sensorPeripheral.state != .disconnected {
            return
        }

        switch centralManager.state {
        case .poweredOn:
            scanIsPending = false
            state.scanning()
            reportBluetoothAction("scan", reason: "exactNFCConfirmedSensor")
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

    private func scheduleRescan(allowsEventDrivenStart: Bool = false) {
        guard !deliberatelyDisconnecting else { return }
        systemAutoReconnectIsActive = false
        clearTransientBluetoothState()
        scanIsPending = true
        guard timedRecoveryIsAllowed || allowsEventDrivenStart else { return }
        if allowsEventDrivenStart {
            beginScanningIfPossible(allowsEventDrivenStart: true)
            return
        }
        let generation = connectionTiming.generation
        let sessionID = preparedSession?.id
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.connectionTiming.generation == generation,
                  self.preparedSession?.id == sessionID,
                  self.scanIsPending else { return }
            self.reconnectFallbackWorkItem = nil
            self.beginScanningIfPossible(allowsEventDrivenStart: allowsEventDrivenStart)
        }
        reconnectFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    func applicationActivityDidChange(_ state: LibreWatchApplicationState) {
        applicationState = state
        let source: LibreWatchRecoveryReconcileSource
        switch state {
        case .active: source = .sceneActivation
        case .inactive: source = .sceneInactive
        case .background: source = .sceneBackground
        }
        currentReconcileSource = source
        reportDiagnostic(.lifecycleChanged, trigger: state.rawValue)
        reconcileRecoveryState(
            at: Date(),
            source: source
        )
        if state == .active {
            evaluateConnectionHealth(at: Date())
        }
    }

    private func connect(_ peripheral: CBPeripheral, using central: CBCentralManager,
                         resetDisconnectGate: Bool = true) {
        guard eventDrivenRecoveryIsAllowed, !deliberatelyDisconnecting,
              !scanAfterReconnectCancellation, identityAndOwnershipAreConfirmed(for: peripheral),
              peripheral.state == .disconnected, releaseRetiredPeripheralIfDisconnected(),
              !systemAutoReconnectIsActive,
              connectionTiming.phase == nil || connectionTiming.phase == .connection
        else { return }
        let now = Date()
        connectionTiming.beginConnection(
            at: now,
            applicationIsActive: applicationIsActive,
            executionIsAvailable: timedRecoveryIsAllowed,
            monotonicTime: monotonicNow
        )
        if restoredPeripheral === peripheral {
            restorationState?.bind(to: connectionTiming.generation)
        }
        if pendingRecoveryDiagnostic != nil {
            beginRecoveryDiagnosticIfNeeded()
        }
        guard connectionTiming.canConnect(at: now, peripheralIsDisconnected: true,
                                          retiredPeripheralIsReleased: true,
                                          monotonicTime: monotonicNow) else {
            scheduleReconnectFallback(for: peripheral)
            return
        }
        if resetDisconnectGate { prepareForExpectedDisconnectCallback() }
        systemAutoReconnectIsActive = false
        scanIsPending = false
        central.stopScan()
        cancelReconnectFallback()
        state.connecting()
        reportBluetoothAction("connect", reason: "confirmedPeripheral")
        central.connect(peripheral, options: connectionOptions)
        scheduleReconnectFallback(for: peripheral)
    }

    @discardableResult
    private func normalizeObservedLink(_ peripheral: CBPeripheral, at date: Date) -> Bool {
        guard identityAndOwnershipAreConfirmed(for: peripheral),
              !deliberatelyDisconnecting, !scanAfterReconnectCancellation,
              connectionTiming.observeLink(
                  connected: peripheral.state == .connected,
                  connecting: peripheral.state == .connecting,
                  hasReceptionState: state.stage == .receiving || receiveCharacteristic != nil || setupService != nil,
                  at: date,
                  applicationIsActive: applicationIsActive,
                  executionIsAvailable: timedRecoveryIsAllowed,
                  monotonicTime: monotonicNow
              )
        else { return false }
        cancelReconnectFallback()
        invalidateRestoration()
        setupService = nil
        setupGeneration = nil
        writeCharacteristic = nil
        receiveCharacteristic = nil
        frameAssembler.reset()
        state.reconnecting(error: nil)
        // An observed .connecting already represents one system/ongoing attempt.
        systemAutoReconnectIsActive = peripheral.state == .connecting
        // A .connecting observation already has a connection generation. A .disconnected or
        // .disconnecting observation keeps its first trigger until an actual attempt/callback
        // establishes the generation, so one immutable diagnostic cannot describe the wrong phase.
        if peripheral.state == .connecting {
            beginRecoveryDiagnosticIfNeeded(trigger: "observedLinkState")
        } else if recoveryAttemptState.context == nil, pendingRecoveryDiagnostic == nil {
            pendingRecoveryDiagnostic = (trigger: "observedLinkState", startedAt: date)
        }
        return true
    }

    private func beginSetup(for peripheral: CBPeripheral) {
        guard identityAndOwnershipAreConfirmed(for: peripheral), peripheral.state == .connected,
              !deliberatelyDisconnecting, !scanAfterReconnectCancellation else { return }
        invalidateRestoration()
        prepareForExpectedDisconnectCallback()
        cancelReconnectFallback()
        connectionTiming.beginSetup(
            at: Date(),
            executionIsAvailable: timedRecoveryIsAllowed,
            monotonicTime: monotonicNow
        )
        setupGeneration = connectionTiming.generation
        systemAutoReconnectIsActive = false
        setupService = nil
        writeCharacteristic = nil
        receiveCharacteristic = nil
        frameAssembler.reset()
        frameLiveness = LibreWatchFrameLiveness()
        state.connecting()
        peripheral.discoverServices([CBUUID(string: Libre2WatchDirectConstants.serviceUUIDString)])
        scheduleReconnectFallback(for: peripheral)
    }

    private func installRestoredConnection(
        _ peripheral: CBPeripheral,
        session: LibreWatchDirectSession
    ) {
        let isSameRestoration = restoredPeripheral === peripheral &&
            restorationState?.generation == connectionTiming.generation &&
            restorationState?.belongsTo(
                sessionID: session.id,
                sensorIdentity: session.redactedIdentity(),
                ownership: watchState?.libreWatchOwnership ?? .iphone
            ) == true
        guard !isSameRestoration else {
            bindRestoredGATTObjects(from: peripheral)
            return
        }

        cancelReconnectFallback()
        connectionTiming.invalidate()
        prepareForExpectedDisconnectCallback()
        restoredPeripheral = peripheral
        restorationState = LibreWatchRestorationState(
            sessionID: session.id,
            sensorIdentity: session.redactedIdentity(),
            generation: connectionTiming.generation
        )
        setupService = nil
        setupGeneration = nil
        writeCharacteristic = nil
        receiveCharacteristic = nil
        frameAssembler.reset()
        frameLiveness = LibreWatchFrameLiveness()
        bindRestoredGATTObjects(from: peripheral)
    }

    private func bindRestoredGATTObjects(from peripheral: CBPeripheral) {
        guard restoredPeripheral === peripheral,
              let service = peripheral.services?.first(where: {
                  $0.uuid == CBUUID(string: Libre2WatchDirectConstants.serviceUUIDString)
              })
        else { return }

        if !LibreWatchRestoredObjectIdentity.isCurrent(service, expected: setupService) {
            setupService = service
            writeCharacteristic = nil
            receiveCharacteristic = nil
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
    }

    private func restorationBelongsToCurrentSession(for peripheral: CBPeripheral) -> Bool {
        guard restoredPeripheral === peripheral, let preparedSession, let restorationState else {
            return false
        }
        return restorationState.generation == connectionTiming.generation &&
            restorationState.belongsTo(
                sessionID: preparedSession.id,
                sensorIdentity: preparedSession.redactedIdentity(),
                ownership: watchState?.libreWatchOwnership ?? .iphone
            )
    }

    private func continueRestoredConnectionIfPossible(for peripheral: CBPeripheral) {
        guard restorationBelongsToCurrentSession(for: peripheral),
              let preparedSession, var restorationState
        else { return }

        bindRestoredGATTObjects(from: peripheral)
        let action = restorationState.nextAction(
            centralIsPoweredOn: centralManager?.state == .poweredOn,
            peripheralState: observedState(of: peripheral),
            hasService: setupService != nil,
            hasWriteCharacteristic: writeCharacteristic != nil,
            hasReceiveCharacteristic: receiveCharacteristic != nil,
            receiveIsNotifying: receiveCharacteristic?.isNotifying == true,
            connectionPhase: connectionTiming.phase,
            currentGeneration: connectionTiming.generation,
            sessionID: preparedSession.id,
            sensorIdentity: preparedSession.redactedIdentity(),
            ownership: watchState?.libreWatchOwnership ?? .iphone,
            cancellationIsActive: deliberatelyDisconnecting || scanAfterReconnectCancellation
        )
        self.restorationState = restorationState

        switch action {
        case .stop:
            invalidateRestoration()
        case .waitForBluetooth:
            cancelReconnectFallback()
        case .waitForConnection, .waitForCurrentOperation:
            scheduleReconnectFallback(for: peripheral)
        case .discoverServices:
            beginRestoredSetup(at: .services, for: peripheral)
            peripheral.discoverServices([
                CBUUID(string: Libre2WatchDirectConstants.serviceUUIDString)
            ])
            scheduleReconnectFallback(for: peripheral)
        case .discoverCharacteristics:
            guard let setupService else { return }
            var missing = [CBUUID]()
            if writeCharacteristic == nil {
                missing.append(CBUUID(string: Libre2WatchDirectConstants.writeCharacteristicUUIDString))
            }
            if receiveCharacteristic == nil {
                missing.append(CBUUID(string: Libre2WatchDirectConstants.receiveCharacteristicUUIDString))
            }
            guard !missing.isEmpty else { return }
            beginRestoredSetup(at: .characteristics, for: peripheral)
            peripheral.discoverCharacteristics(missing, for: setupService)
            scheduleReconnectFallback(for: peripheral)
        case .enableNotifications:
            guard let receiveCharacteristic else { return }
            beginRestoredSetup(at: .notifications, for: peripheral)
            peripheral.setNotifyValue(true, for: receiveCharacteristic)
            scheduleReconnectFallback(for: peripheral)
        case .awaitExistingStream:
            beginRestoredSetup(at: .notifications, for: peripheral)
            scheduleReconnectFallback(for: peripheral)
        case .preserveActiveStream:
            state.notificationsActive()
            scheduleReconnectFallback(for: peripheral)
        }
    }

    private func prepareRestoredConnectionAttemptIfNeeded(
        for peripheral: CBPeripheral,
        systemIsReconnecting: Bool
    ) {
        guard restorationBelongsToCurrentSession(for: peripheral),
              centralManager?.state == .poweredOn,
              connectionTiming.phase != .connection
        else { return }
        cancelReconnectFallback()
        connectionTiming.invalidate()
        setupGeneration = nil
        connectionTiming.beginConnection(
            at: Date(),
            applicationIsActive: applicationIsActive,
            executionIsAvailable: timedRecoveryIsAllowed,
            monotonicTime: monotonicNow
        )
        restorationState?.beginConnectionGeneration(connectionTiming.generation)
        frameAssembler.reset()
        systemAutoReconnectIsActive = systemIsReconnecting
        state.reconnecting(error: nil)
    }

    private func beginRestoredSetup(
        at phase: LibreWatchConnectionTiming.Phase,
        for peripheral: CBPeripheral
    ) {
        guard restorationBelongsToCurrentSession(for: peripheral),
              peripheral.state == .connected,
              centralManager?.state == .poweredOn,
              !deliberatelyDisconnecting, !scanAfterReconnectCancellation
        else { return }
        cancelReconnectFallback()
        systemAutoReconnectIsActive = false
        connectionTiming.beginSetup(
            at: Date(),
            startingAt: phase,
            executionIsAvailable: timedRecoveryIsAllowed,
            monotonicTime: monotonicNow
        )
        setupGeneration = connectionTiming.generation
        state.connecting()
    }

    private func attemptRestoredUnlockAfterEvidenceTimeout(
        for peripheral: CBPeripheral,
        capturedRestorationToken: UUID?
    ) -> Bool {
        guard restorationBelongsToCurrentSession(for: peripheral),
              let preparedSession,
              let receiveCharacteristic,
              receiveCharacteristic.isNotifying,
              let writeCharacteristic,
              var restorationState,
              restorationState.claimUnknownUnlockRecovery(
                  capturedToken: capturedRestorationToken,
                  currentGeneration: connectionTiming.generation,
                  phase: connectionTiming.phase,
                  sessionID: preparedSession.id,
                  sensorIdentity: preparedSession.redactedIdentity(),
                  ownership: watchState?.libreWatchOwnership ?? .iphone,
                  cancellationIsActive: deliberatelyDisconnecting || scanAfterReconnectCancellation
              )
        else { return false }
        self.restorationState = restorationState
        cancelReconnectFallback()
        guard connectionTiming.setupProgress(
            .notifications,
            at: Date(),
            executionIsAvailable: timedRecoveryIsAllowed,
            monotonicTime: monotonicNow
        ) else { return false }
        frameAssembler.reset()
        writeUnlock(to: peripheral, characteristic: writeCharacteristic)
        return true
    }

    private func writeUnlock(to peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        guard identityAndOwnershipAreConfirmed(for: peripheral),
              peripheral.state == .connected,
              connectionTiming.phase == .unlock,
              LibreWatchRestoredObjectIdentity.isCurrent(
                  characteristic,
                  expected: writeCharacteristic
              ),
              var preparedSession
        else { return }
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
            peripheral.writeValue(Data(unlock), for: characteristic, type: .withResponse)
            scheduleReconnectFallback(for: peripheral)
        } catch {
            failAndRescan(.unlockWriteFailed, error: error.localizedDescription)
        }
    }

    private func missingLibreCharacteristics() -> [CBUUID] {
        var missing = [CBUUID]()
        if writeCharacteristic == nil {
            missing.append(CBUUID(string: Libre2WatchDirectConstants.writeCharacteristicUUIDString))
        }
        if receiveCharacteristic == nil {
            missing.append(CBUUID(string: Libre2WatchDirectConstants.receiveCharacteristicUUIDString))
        }
        return missing
    }

    private func continueAfterCharacteristicsAreBound(
        for peripheral: CBPeripheral,
        service: CBService
    ) {
        guard setupCallbackIsCurrent(peripheral, phase: .characteristics),
              LibreWatchRestoredObjectIdentity.isCurrent(service, expected: setupService),
              writeCharacteristic != nil,
              let receiveCharacteristic
        else { return }
        recordSetupProgress(.characteristics)

        if restorationBelongsToCurrentSession(for: peripheral), receiveCharacteristic.isNotifying {
            if var restorationState {
                restorationState.beginAwaitingStreamEvidence()
                self.restorationState = restorationState
            }
            scheduleReconnectFallback(for: peripheral)
            return
        }

        peripheral.setNotifyValue(true, for: receiveCharacteristic)
        scheduleReconnectFallback(for: peripheral)
    }

    private func recordRestoredStreamEvidence(for peripheral: CBPeripheral) {
        guard restorationBelongsToCurrentSession(for: peripheral), var restorationState else {
            return
        }
        restorationState.recordStreamEvidence()
        self.restorationState = restorationState
    }

    private func invalidateRestoration() {
        restoredPeripheral = nil
        restorationState = nil
        setupGeneration = nil
    }

    private func setupCallbackIsCurrent(_ peripheral: CBPeripheral, phase: LibreWatchConnectionTiming.Phase) -> Bool {
        identityAndOwnershipAreConfirmed(for: peripheral) && peripheral.state == .connected &&
            !deliberatelyDisconnecting && !scanAfterReconnectCancellation &&
            setupGeneration == connectionTiming.generation &&
            connectionTiming.acceptsSetup(phase)
    }

    private func recordSetupProgress(_ phase: LibreWatchConnectionTiming.Phase) {
        currentReconcileSource = .gattCallback
        cancelReconnectFallback()
        connectionTiming.setupProgress(
            phase,
            at: Date(),
            executionIsAvailable: timedRecoveryIsAllowed,
            monotonicTime: monotonicNow
        )
    }

    private func scheduleReconnectFallback(for peripheral: CBPeripheral) {
        cancelReconnectFallback()
        guard let deadline = connectionTiming.deadline, let preparedSession else { return }
        let generation = connectionTiming.generation
        let restorationToken = restorationState?.token
        let now = Date()
        let uptime = monotonicNow
        let remainingBudget = connectionTiming.remainingExecutionTime(
            at: now,
            monotonicTime: uptime
        ) ?? 0
        let action = LibreWatchLifecyclePolicy.reconnectFallbackAction(
            deadline: now.addingTimeInterval(remainingBudget),
            now: now,
            applicationIsActive: applicationIsActive,
            extendedRuntimeIsRunning: extendedRuntimeIsRunning,
            ownership: watchState?.libreWatchOwnership ?? .iphone
        )
        let remaining: TimeInterval
        switch action {
        case .noAdditionalWork:
            return
        case .restartConfirmedSensorScan:
            remaining = 0
        case let .wait(delay):
            remaining = delay
        }
        // Always enqueue: a current didConnect/GATT callback already on main wins first.
        let workItem = DispatchWorkItem { [weak self] in
            // Give a Core Bluetooth callback that was already queued on main one final turn.
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.timedRecoveryIsAllowed,
                      !self.deliberatelyDisconnecting,
                      self.preparedSession?.id == preparedSession.id,
                      self.preparedSession?.sensorUID == preparedSession.sensorUID,
                      let currentPeripheral = self.sensorPeripheral,
                      currentPeripheral === peripheral,
                      self.connectionTiming.generation == generation,
                      self.identityAndOwnershipAreConfirmed(for: currentPeripheral),
                      self.connectionTiming.timeoutIsCurrent(
                          deadline, ownership: self.watchState?.libreWatchOwnership ?? .iphone,
                          cancelling: self.scanAfterReconnectCancellation, at: Date(),
                          monotonicTime: self.monotonicNow
                      )
                else { return }
                self.currentReconcileSource = .executionBudgetExpired
                if deadline.phase == .notifications,
                   self.attemptRestoredUnlockAfterEvidenceTimeout(
                       for: currentPeripheral,
                       capturedRestorationToken: restorationToken
                   ) {
                    return
                }
                switch LibreWatchExpiredPhasePolicy.action(
                    phase: deadline.phase,
                    peripheralState: self.observedState(of: currentPeripheral),
                    ownership: self.watchState?.libreWatchOwnership ?? .iphone,
                    cancellationIsActive: self.scanAfterReconnectCancellation
                ) {
                case .beginGATTSetup:
                    if self.restorationBelongsToCurrentSession(for: currentPeripheral) {
                        self.continueRestoredConnectionIfPossible(for: currentPeripheral)
                    } else {
                        self.beginSetup(for: currentPeripheral)
                    }
                case .reconcileObservedLink:
                    // A receiving/setup deadline must not cancel a Core Bluetooth link that
                    // has already moved into a system reconnect state. Normalize that state
                    // and let its own immutable connection phase decide any later timeout.
                    self.reconcileRecoveryState(at: Date(), source: .executionBudgetExpired)
                case .beginControlledRecovery:
                    let isReceivingTimeout = deadline.phase == .receiving
                    self.beginControlledSensorRecovery(
                        for: currentPeripheral,
                        error: isReceivingTimeout
                            ? "No technically valid Libre frame within the active recovery budget; reconnecting"
                            : "Automatic reconnect timed out; returning to the NFC-confirmed sensor scan",
                        trigger: isReceivingTimeout ? "noData" : "phaseDeadline"
                    )
                case .noAdditionalWork:
                    break
                }
            }
        }
        reconnectFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: workItem)
    }

    /// Cancels the one existing connection attempt before returning to the exact-sensor scan.
    private func beginControlledSensorRecovery(for peripheral: CBPeripheral, error: String,
                                               trigger: String = "phaseDeadline") {
        // Timer callers already require active/runtime execution. An explicit invalid-frame
        // callback may cancel its own broken notification stream whenever Watch owns it.
        guard eventDrivenRecoveryIsAllowed,
              !deliberatelyDisconnecting,
              peripheral === sensorPeripheral,
              !scanAfterReconnectCancellation
        else { return }

        beginRecoveryDiagnosticIfNeeded(trigger: trigger)
        cancelReconnectFallback()
        systemAutoReconnectIsActive = false
        scanIsPending = false
        centralManager?.stopScan()
        state.reconnecting(error: error)
        scanAfterReconnectCancellation = true
        beginCancellation(of: peripheral)
    }

    private func finishReconnectCancellationAndScan(allowsEventDrivenStart: Bool = false) {
        guard scanAfterReconnectCancellation, !deliberatelyDisconnecting,
              eventDrivenRecoveryIsAllowed else { return }
        scanAfterReconnectCancellation = false
        clearTransientBluetoothState()
        scanIsPending = true
        beginScanningIfPossible(allowsEventDrivenStart: allowsEventDrivenStart)
    }

    private func releaseRetiredPeripheralIfDisconnected() -> Bool {
        guard let retiredPeripheral else { return true }
        guard retiredPeripheral.state == .disconnected else { return false }
        retiredPeripheral.delegate = nil
        self.retiredPeripheral = nil
        return true
    }

    /// A retirement removes obsolete callbacks, not proof that the radio has disconnected.
    /// Retain that proof requirement when the user asks to return ownership to iPhone.
    private func peripheralToRelease() -> CBPeripheral? {
        if sensorPeripheral == nil, let retiredPeripheral {
            sensorPeripheral = retiredPeripheral
            self.retiredPeripheral = nil
        }
        return sensorPeripheral
    }

    private func beginCancellation(of peripheral: CBPeripheral) {
        guard peripheral === sensorPeripheral else { return }
        cancelReconnectFallback()
        invalidateRestoration()
        connectionTiming.beginCancellation(at: Date())
        systemAutoReconnectIsActive = false
        scanIsPending = false
        centralManager?.stopScan()
        setupService = nil
        setupGeneration = nil
        writeCharacteristic = nil
        receiveCharacteristic = nil
        frameAssembler.reset()
        prepareForExpectedDisconnectCallback()
        reportBluetoothAction("cancel", reason: scanAfterReconnectCancellation
            ? "controlledRecovery"
            : (deliberatelyDisconnecting ? "returnToPhone" : "ownershipStopped"))
        centralManager?.cancelPeripheralConnection(peripheral)
        evaluateCancellation()
    }

    /// The same one-shot work item serves armed execution budgets and bounded cancellation.
    /// Connection/GATT budgets pause outside foreground/runtime; cancellation proof remains wall-clock.
    private func evaluateCancellation(allowsEventDrivenStart: Bool = false) {
        if !allowsEventDrivenStart { currentReconcileSource = .cancellationWatchdog }
        guard connectionTiming.phase == .cancelling,
              let deadline = connectionTiming.deadline,
              let peripheral = sensorPeripheral else { return }
        let outcome = connectionTiming.finishCancellation(
            deadline, ownership: watchState?.libreWatchOwnership ?? .iphone,
            returningToPhone: deliberatelyDisconnecting,
            peripheralIsDisconnected: peripheral.state == .disconnected, at: Date()
        )
        switch outcome {
        case .confirmedDisconnected:
            cancelReconnectFallback()
            if scanAfterReconnectCancellation {
                finishReconnectCancellationAndScan(allowsEventDrivenStart: allowsEventDrivenStart)
            } else if returnAfterDisconnect != nil {
                finishPendingReturnAfterDisconnect()
            } else {
                finishStoppingForPhoneOwnership()
            }
        case .retireForScan:
            cancelReconnectFallback()
            reportRecoveryFailureIfNeeded()
            // One filtered scan may resume without the callback. A discovered sensor can
            // connect only once the retired object's native state confirms disconnection.
            retiredPeripheral = peripheral
            finishReconnectCancellationAndScan(allowsEventDrivenStart: allowsEventDrivenStart)
        case .awaitConfirmedDisconnection:
            cancelReconnectFallback()
            if recoveryAttemptState.context != nil {
                reportRecoveryFailureIfNeeded()
            } else {
                reportDiagnostic(.recoveryFailed, trigger: "returnAwaitingDisconnection")
            }
            state.fail(.ownershipFailed, error: "Waiting for confirmed Watch disconnection; iPhone remains paused")
            // Do not acknowledge ownership release merely because a timer expired.
        case nil:
            guard !connectionTiming.cancellationWatchdogDidFire,
                  reconnectFallbackWorkItem == nil, let preparedSession else { return }
            let generation = connectionTiming.generation
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, self.sensorPeripheral === peripheral,
                      self.preparedSession?.id == preparedSession.id,
                      self.preparedSession?.sensorUID == preparedSession.sensorUID,
                      self.connectionTiming.generation == generation,
                      self.connectionTiming.phase == .cancelling,
                      self.connectionTiming.deadline == deadline else { return }
                self.reconnectFallbackWorkItem = nil
                self.evaluateCancellation()
            }
            reconnectFallbackWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + max(0, deadline.expiresAt.timeIntervalSinceNow), execute: workItem
            )
        }
    }

    private func cancelReconnectFallback() {
        reconnectFallbackWorkItem?.cancel()
        reconnectFallbackWorkItem = nil
    }

    private func prepareForExpectedDisconnectCallback() {
        pendingLegacyDisconnect?.cancel()
        pendingLegacyDisconnect = nil
        lastFrameProgressDiagnosticAt = nil
        disconnectGate.reset()
    }

    private func clearTransientBluetoothState() {
        scanAfterReconnectCancellation = false
        systemAutoReconnectIsActive = false
        cancelReconnectFallback()
        invalidateRestoration()
        pendingLegacyDisconnect?.cancel()
        pendingLegacyDisconnect = nil
        disconnectGate.reset()
        sensorPeripheral?.delegate = nil
        sensorPeripheral = nil
        matchedPeripheralName = nil
        setupService = nil
        setupGeneration = nil
        writeCharacteristic = nil
        receiveCharacteristic = nil
        frameAssembler.reset()
        frameLiveness = LibreWatchFrameLiveness()
        connectionTiming.invalidate()
    }

    private func identityAndOwnershipAreConfirmed(for peripheral: CBPeripheral) -> Bool {
        guard watchState?.libreWatchOwnership == .watch,
              let preparedSession,
              preparedSession.isValid,
              peripheral === sensorPeripheral,
              preparedSession.matches(candidateName: matchedPeripheralName ?? peripheral.name)
        else { return false }
        return true
    }

    private func failAndRescan(_ failure: LibreWatchDirectFailure, error: String?) {
        guard !deliberatelyDisconnecting, !scanAfterReconnectCancellation,
              eventDrivenRecoveryIsAllowed else { return }
        beginRecoveryDiagnosticIfNeeded(trigger: "setupOrBluetoothError")
        cancelReconnectFallback()
        reportRecoveryFailureIfNeeded()
        state.fail(failure, error: error)
        centralManager?.stopScan()
        if let sensorPeripheral, sensorPeripheral.state != .disconnected {
            // Retire setup before cancelling; no late GATT callback or lifecycle event may
            // start fresh setup until the existing cancellation has actually completed.
            scanAfterReconnectCancellation = true
            beginCancellation(of: sensorPeripheral)
        } else {
            scheduleRescan(allowsEventDrivenStart: true)
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

    private func notificationErrorAction(for error: Error) -> LibreWatchNotificationErrorAction {
        guard let bluetoothError = error as? CBError else {
            return .recoverBluetoothLink
        }
        if #available(watchOS 9.0, *) {
            return LibreWatchNotificationErrorPolicy.action(
                isNearBackgroundNotificationLimit:
                    bluetoothError.code == .leGattNearBackgroundNotificationLimit,
                isExceededBackgroundNotificationLimit:
                    bluetoothError.code == .leGattExceededBackgroundNotificationLimit
            )
        }
        return .recoverBluetoothLink
    }

    private func handleDisconnect(
        peripheral: CBPeripheral,
        isReconnecting: Bool,
        disconnectedAt: Date,
        error: Error?
    ) {
        guard peripheral === sensorPeripheral else { return }
        currentReconcileSource = .didDisconnect
        let nsError = error.map { $0 as NSError }

        reportDiagnostic(
            .disconnected, trigger: "didDisconnect", at: disconnectedAt,
            isReconnecting: isReconnecting,
            errorDomain: nsError?.domain,
            errorCode: nsError?.code
        )

        if scanAfterReconnectCancellation {
            evaluateCancellation(allowsEventDrivenStart: true)
            return
        }

        let ownership = watchState?.libreWatchOwnership ?? .iphone
        let action = LibreWatchLifecyclePolicy.disconnectRecoveryAction(
            isDeliberate: deliberatelyDisconnecting,
            systemIsReconnecting: isReconnecting,
            ownership: ownership
        )

        if action == .finishDeliberateDisconnect {
            evaluateCancellation(allowsEventDrivenStart: true)
            return
        }

        invalidateRestoration()
        setupService = nil
        writeCharacteristic = nil
        receiveCharacteristic = nil
        frameAssembler.reset()
        // Keep an already observed connection deadline when the delayed callback arrives.
        if connectionTiming.phase != .connection { connectionTiming.invalidate() }
        state.reconnecting(error: bluetoothErrorDescription(error))

        switch action {
        case .waitForSystemReconnect:
            systemAutoReconnectIsActive = true
            if connectionTiming.phase != .connection {
                connectionTiming.beginConnection(
                    at: disconnectedAt,
                    applicationIsActive: applicationIsActive,
                    executionIsAvailable: timedRecoveryIsAllowed,
                    monotonicTime: monotonicNow
                )
            }
            // Bind the immutable diagnostic context to the generation that owns this
            // Core Bluetooth reconnect, not the idle generation it replaced.
            beginRecoveryDiagnosticIfNeeded()
            scheduleReconnectFallback(for: peripheral)
        case .reconnectManually:
            systemAutoReconnectIsActive = false
            cancelReconnectFallback()
            guard let centralManager,
                  centralManager.state == .poweredOn
            else {
                beginRecoveryDiagnosticIfNeeded()
                scheduleRescan(allowsEventDrivenStart: true)
                return
            }
            // Keep the NFC-confirmed peripheral and reconnect it directly. Scanning is only the
            // fallback if this known connection cannot be restored within the timeout.
            if peripheral.state == .connecting {
                systemAutoReconnectIsActive = true
                if connectionTiming.phase != .connection {
                    connectionTiming.beginConnection(
                        at: disconnectedAt,
                        applicationIsActive: applicationIsActive,
                        executionIsAvailable: timedRecoveryIsAllowed,
                        monotonicTime: monotonicNow
                    )
                }
                beginRecoveryDiagnosticIfNeeded()
            } else {
                // A retry keeps the same phase budget, including an observed missing callback.
                connect(peripheral, using: centralManager, resetDisconnectGate: false)
                beginRecoveryDiagnosticIfNeeded()
            }
            scheduleReconnectFallback(for: peripheral)
        case .noAdditionalWork:
            systemAutoReconnectIsActive = isReconnecting && ownership == .watch
            if systemAutoReconnectIsActive {
                if connectionTiming.phase != .connection {
                    connectionTiming.beginConnection(
                        at: disconnectedAt,
                        applicationIsActive: applicationIsActive,
                        executionIsAvailable: timedRecoveryIsAllowed,
                        monotonicTime: monotonicNow
                    )
                }
            }
            cancelReconnectFallback()
        case .finishDeliberateDisconnect:
            break
        }
    }

    private func reportDiagnostic(
        _ kind: LibreWatchDiagnosticEventKind,
        trigger: String,
        at date: Date = Date(),
        isReconnecting: Bool? = nil,
        errorDomain: String? = nil,
        errorCode: Int? = nil,
        bluetoothAction: String? = nil,
        actionReason: String? = nil,
        runtimeInvalidationReason: Int? = nil,
        runtimeError: String? = nil,
        bluetoothErrorClassification: String? = nil,
        attempt: LibreWatchRecoveryAttemptContext? = nil
    ) {
        let attempt = attempt ?? recoveryAttemptState.context
        let belongsToRecoveryAttempt: Bool
        switch kind {
        case .recoveryStarted, .recoverySucceeded, .recoveryFailed:
            belongsToRecoveryAttempt = true
        case .disconnected, .extendedRuntimeWillExpire, .extendedRuntimeInvalidated,
             .lifecycleChanged, .bluetoothAction, .coreBluetoothCallback,
             .frameProgress, .callbackRejected, .journalRotated:
            belongsToRecoveryAttempt = false
        }
        watchState?.reportLibreWatchDiagnostic(LibreWatchDiagnosticEvent(
            kind: kind, isReconnecting: isReconnecting, errorCode: errorCode,
            watchTimestamp: date,
            trigger: belongsToRecoveryAttempt ? (attempt?.originalTrigger ?? trigger) : trigger,
            applicationIsActive: applicationIsActive,
            extendedRuntimeIsRunning: extendedRuntimeIsRunning,
            peripheralState: sensorPeripheral.map { String(describing: $0.state) },
            connectionPhase: connectionTiming.phase?.rawValue ?? "idle",
            deadlinePhase: connectionTiming.deadline?.phase.rawValue,
            deadlineAt: connectionTiming.deadline?.expiresAt,
            generation: belongsToRecoveryAttempt
                ? (attempt?.generation ?? connectionTiming.generation)
                : connectionTiming.generation,
            attemptID: attempt?.attemptID,
            attemptStartedAt: attempt?.startedAt,
            sessionID: attempt?.sessionID ?? preparedSession?.id,
            sensorIdentity: attempt?.sensorIdentity ?? preparedSession?.redactedIdentity(),
            reconcileSource: currentReconcileSource,
            remainingExecutionBudget: connectionTiming.remainingExecutionTime(
                at: date,
                monotonicTime: monotonicNow
            ),
            runtimeInvalidationReason: runtimeInvalidationReason,
            runtimeError: runtimeError,
            applicationState: applicationState,
            bluetoothAction: bluetoothAction,
            actionReason: actionReason,
            errorDomain: errorDomain,
            technicalFrameAt: frameLiveness.lastValidBLEFrameAt,
            measurementAt: state.directReading?.receivedAt,
            receivingBudgetDeadline: connectionTiming.phase == .receiving
                ? connectionTiming.deadline?.expiresAt
                : nil,
            bluetoothErrorClassification: bluetoothErrorClassification,
            extendedRuntimeState: extendedRuntimeSession.map { String(describing: $0.state) },
            extendedRuntimeStartRequested: userInitiatedRuntimeStart
        ))
    }

    private func reportBluetoothAction(_ action: String, reason: String) {
        reportDiagnostic(
            .bluetoothAction,
            trigger: reason,
            bluetoothAction: action,
            actionReason: reason
        )
    }

    private func reportCoreBluetoothCallback(
        _ callback: String,
        error: Error? = nil,
        isReconnecting: Bool? = nil,
        classification: String? = nil
    ) {
        let nsError = error.map { $0 as NSError }
        reportDiagnostic(
            .coreBluetoothCallback,
            trigger: callback,
            isReconnecting: isReconnecting,
            errorDomain: nsError?.domain,
            errorCode: nsError?.code,
            bluetoothErrorClassification: classification
        )
    }

    private func reportFrameProgress(at date: Date) {
        // Keep the exact technical time on every later diagnostic, but avoid doubling
        // WatchConnectivity traffic for every healthy one-minute Libre frame.
        let interval: TimeInterval = 5 * 60
        guard lastFrameProgressDiagnosticAt.map({ date.timeIntervalSince($0) >= interval }) ?? true
        else { return }
        lastFrameProgressDiagnosticAt = date
        reportDiagnostic(.frameProgress, trigger: "validBLEFrame", at: date)
    }

    private func reportRejectedCallback(_ callback: String, reason: String) {
        reportDiagnostic(
            .callbackRejected,
            trigger: callback,
            actionReason: reason
        )
    }

    private func beginRecoveryDiagnosticIfNeeded(trigger: String = "disconnect") {
        guard let preparedSession else { return }
        guard recoveryAttemptState.context == nil else {
            pendingRecoveryDiagnostic = nil
            return
        }
        let originalTrigger = pendingRecoveryDiagnostic?.trigger ?? trigger
        let startedAt = pendingRecoveryDiagnostic?.startedAt ?? Date()
        let candidate = LibreWatchRecoveryAttemptContext(
            originalTrigger: originalTrigger,
            startedAt: startedAt,
            generation: connectionTiming.generation,
            sessionID: preparedSession.id,
            sensorIdentity: preparedSession.redactedIdentity()
        )
        guard let attempt = recoveryAttemptState.begin(candidate) else { return }
        pendingRecoveryDiagnostic = nil
        LibreWatchSessionStore.saveRecoveryAttempt(recoveryAttemptState)
        reportDiagnostic(.recoveryStarted, trigger: originalTrigger, attempt: attempt)
    }

    private func reportRecoveryFailureIfNeeded() {
        guard let attempt = recoveryAttemptState.reportFailure() else { return }
        LibreWatchSessionStore.saveRecoveryAttempt(recoveryAttemptState)
        reportDiagnostic(.recoveryFailed, trigger: attempt.originalTrigger, attempt: attempt)
    }

    private func reportRecoverySuccessIfNeeded() {
        pendingRecoveryDiagnostic = nil
        guard let attempt = recoveryAttemptState.finishSuccess() else { return }
        LibreWatchSessionStore.saveRecoveryAttempt(recoveryAttemptState)
        reportDiagnostic(.recoverySucceeded, trigger: attempt.originalTrigger, attempt: attempt)
    }

    private func invalidateRecoveryAttempt() {
        pendingRecoveryDiagnostic = nil
        recoveryAttemptState.invalidate()
        LibreWatchSessionStore.saveRecoveryAttempt(recoveryAttemptState)
    }

    private func handleDisconnectOnce(
        peripheral: CBPeripheral,
        isReconnecting: Bool,
        disconnectedAt: Date,
        error: Error?,
        legacyToken: UUID? = nil
    ) {
        guard peripheral === sensorPeripheral, disconnectGate.accept(legacyToken: legacyToken) else { return }
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
        currentReconcileSource = .healthTimer
        watchState?.refreshDirectLibreReadingFreshness(at: date)
        if connectionTiming.phase == .cancelling {
            evaluateCancellation()
            return
        }
        if let sensorPeripheral {
            normalizeObservedLink(sensorPeripheral, at: date)
            if connectionTiming.phase != .receiving {
                reconcileRecoveryState(at: date, source: .healthTimer)
            }
        }

        guard timedRecoveryIsAllowed,
              !deliberatelyDisconnecting, !scanAfterReconnectCancellation,
              let sensorPeripheral,
              sensorPeripheral.state == .connected,
              connectionTiming.phase == .receiving
        else { return }

        // Measurement age remains wall-clock UI state. Technical recovery uses only this
        // cumulative execution budget, which was paused before suspension and resumes here.
        connectionTiming.ensureReceivingBudget(
            at: date,
            timeout: receivingExecutionBudget,
            executionIsAvailable: true,
            monotonicTime: monotonicNow
        )
        scheduleReconnectFallback(for: sensorPeripheral)
    }

    deinit {
        reconnectFallbackWorkItem?.cancel()
        pendingLegacyDisconnect?.cancel()
        healthTimer?.invalidate()
        if let extendedRuntimeSession, extendedRuntimeSession.state != .invalid {
            extendedRuntimeSession.invalidate()
        }
    }
}

extension LibreWatchDirectCollector: WKExtendedRuntimeSessionDelegate {
    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        guard self.extendedRuntimeSession === extendedRuntimeSession else { return }
        extendedRuntimeIsRunning = true
        reconcileRecoveryState(at: Date(), source: .extendedRuntimeStarted)
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        guard self.extendedRuntimeSession === extendedRuntimeSession else { return }
        // The system owns expiration. Do not create replacement sessions from the background.
        userInitiatedRuntimeStart = false
        currentReconcileSource = .extendedRuntimeWillExpire
        reportDiagnostic(.extendedRuntimeWillExpire, trigger: "extendedRuntimeWillExpire")
    }

    func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason,
        error: Error?
    ) {
        guard self.extendedRuntimeSession === extendedRuntimeSession else { return }
        self.extendedRuntimeSession = nil
        extendedRuntimeIsRunning = false
        userInitiatedRuntimeStart = false
        currentReconcileSource = .extendedRuntimeInvalidated
        reportDiagnostic(
            .extendedRuntimeInvalidated,
            trigger: "extendedRuntimeInvalidated",
            runtimeInvalidationReason: reason.rawValue,
            runtimeError: error?.localizedDescription
        )
        reconcileRecoveryState(at: Date(), source: .extendedRuntimeInvalidated)
    }
}

extension LibreWatchDirectCollector: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        currentReconcileSource = .centralStateUpdate
        switch central.state {
        case .poweredOn: bluetoothStateText = "POWERED ON"
        case .poweredOff: bluetoothStateText = "POWERED OFF"
        case .unauthorized: bluetoothStateText = "UNAUTHORIZED"
        case .unsupported: bluetoothStateText = "UNSUPPORTED"
        case .resetting: bluetoothStateText = "RESETTING"
        case .unknown: bluetoothStateText = "UNKNOWN"
        @unknown default: bluetoothStateText = "UNKNOWN"
        }
        reportCoreBluetoothCallback("centralState:\(bluetoothStateText)")

        if central.state == .poweredOn || connectionTiming.phase == .cancelling {
            reconcileRecoveryState(at: Date(), source: .centralStateUpdate)
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        currentReconcileSource = .stateRestoration
        reportCoreBluetoothCallback("willRestoreState")
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
            return
        }

        sensorPeripheral = restored
        matchedPeripheralName = restored.name ?? preparedSession.expectedPeripheralName
        restored.delegate = self
        scanIsPending = false
        central.stopScan()
        installRestoredConnection(restored, session: preparedSession)

        switch restored.state {
        case .connected:
            continueRestoredConnectionIfPossible(for: restored)
            return
        case .connecting:
            systemAutoReconnectIsActive = true
            prepareRestoredConnectionAttemptIfNeeded(
                for: restored,
                systemIsReconnecting: true
            )
            state.reconnecting(error: nil)
        case .disconnected:
            systemAutoReconnectIsActive = false
            prepareRestoredConnectionAttemptIfNeeded(
                for: restored,
                systemIsReconnecting: false
            )
            state.reconnecting(error: nil)
        case .disconnecting:
            state.reconnecting(error: nil)
        @unknown default:
            state.reconnecting(error: nil)
        }
        reconcileRecoveryState(at: Date(), source: .stateRestoration)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard releaseRetiredPeripheralIfDisconnected() else { return }
        guard eventDrivenRecoveryIsAllowed,
              watchState?.libreWatchOwnership == .watch,
              !deliberatelyDisconnecting, !scanAfterReconnectCancellation,
              connectionTiming.canStartBluetoothOperation,
              sensorPeripheral == nil || sensorPeripheral?.state == .disconnected,
              let preparedSession
        else { return }
        let candidateName = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard preparedSession.matches(candidateName: candidateName) else { return }

        reportCoreBluetoothCallback("didDiscoverConfirmedSensor")
        state.candidate(rssi: RSSI.intValue)
        sensorPeripheral = peripheral
        matchedPeripheralName = candidateName
        peripheral.delegate = self
        central.stopScan()
        guard identityAndOwnershipAreConfirmed(for: peripheral) else {
            scheduleRescan(allowsEventDrivenStart: true)
            return
        }
        connect(peripheral, using: central)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        currentReconcileSource = .didConnect
        reportCoreBluetoothCallback("didConnect")
        guard peripheral === sensorPeripheral else {
            reportRejectedCallback("didConnect", reason: "notCurrentPeripheral")
            reportBluetoothAction("cancel", reason: "unexpectedPeripheralConnected")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        prepareForExpectedDisconnectCallback()
        if scanAfterReconnectCancellation || deliberatelyDisconnecting {
            reportBluetoothAction("cancel", reason: "connectionArrivedDuringCancellation")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        systemAutoReconnectIsActive = false
        scanIsPending = false
        central.stopScan()
        guard identityAndOwnershipAreConfirmed(for: peripheral) else {
            reportBluetoothAction("cancel", reason: "connectionIdentityOrOwnershipMismatch")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard eventDrivenRecoveryIsAllowed else { return }
        // Accept the connection before consulting any old deadline. GATT gets its own clock.
        if restorationBelongsToCurrentSession(for: peripheral) {
            continueRestoredConnectionIfPossible(for: peripheral)
        } else {
            beginSetup(for: peripheral)
        }
        if pendingRecoveryDiagnostic != nil {
            beginRecoveryDiagnosticIfNeeded()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        currentReconcileSource = .didFailToConnect
        reportCoreBluetoothCallback("didFailToConnect", error: error)
        if peripheral === retiredPeripheral {
            _ = releaseRetiredPeripheralIfDisconnected()
            return
        }
        guard peripheral === sensorPeripheral else {
            reportRejectedCallback("didFailToConnect", reason: "notCurrentPeripheral")
            return
        }
        if scanAfterReconnectCancellation || deliberatelyDisconnecting {
            evaluateCancellation(allowsEventDrivenStart: true)
            return
        }
        // Ignore callbacks belonging to retired setup/receiving phases or an ongoing newer attempt.
        guard connectionTiming.phase == .connection, peripheral.state == .disconnected,
              identityAndOwnershipAreConfirmed(for: peripheral) else { return }
        beginRecoveryDiagnosticIfNeeded(trigger: "didFailToConnect")
        systemAutoReconnectIsActive = false
        cancelReconnectFallback()

        state.reconnecting(error: bluetoothErrorDescription(error))
        guard eventDrivenRecoveryIsAllowed,
              watchState?.libreWatchOwnership == .watch,
              peripheral === sensorPeripheral
        else { return }

        // A delegate callback is one bounded execution opportunity even without scene/runtime
        // timer access. An exhausted generation cannot silently wait forever: because this
        // callback confirms the old peripheral is disconnected, retire it and start one exact-
        // sensor scan. A powered-off central has its explicit future poweredOn callback instead.
        switch connectionTiming.failedConnectionAction(
            at: Date(),
            bluetoothIsPoweredOn: central.state == .poweredOn,
            monotonicTime: monotonicNow
        ) {
        case .retryConfirmedPeripheral:
            connect(peripheral, using: central)
        case .scanConfirmedSensor:
            scheduleRescan(allowsEventDrivenStart: true)
        case .waitForBluetooth:
            break
        }
    }

    func centralManager(
        _: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        // Keep the fallback on every OS version: availability does not guarantee delivery
        // of the modern callback. Its token is also invalidated by a later didConnect.
        if peripheral === retiredPeripheral {
            _ = releaseRetiredPeripheralIfDisconnected()
            return
        }
        guard peripheral === sensorPeripheral, pendingLegacyDisconnect == nil,
              let token = disconnectGate.scheduleLegacy() else { return }
        let disconnectedAt = Date()
        let generation = connectionTiming.generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.disconnectGate.pendingToken == token else { return }
            self.pendingLegacyDisconnect = nil
            guard self.disconnectGate.legacyIsCurrent(
                token, scheduledGeneration: generation,
                currentGeneration: self.connectionTiming.generation,
                peripheralIsDisconnectedOrDisconnecting: peripheral.state == .disconnected || peripheral.state == .disconnecting
            ) else {
                self.disconnectGate.cancelLegacy()
                return
            }
            self.handleDisconnectOnce(
                peripheral: peripheral,
                isReconnecting: false,
                disconnectedAt: disconnectedAt,
                error: error,
                legacyToken: token
            )
        }
        pendingLegacyDisconnect = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    @available(watchOS 10.0, *)
    func centralManager(
        _: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        timestamp: CFAbsoluteTime,
        isReconnecting: Bool,
        error: Error?
    ) {
        if peripheral === retiredPeripheral {
            _ = releaseRetiredPeripheralIfDisconnected()
            return
        }
        guard peripheral === sensorPeripheral else { return }
        pendingLegacyDisconnect?.cancel()
        pendingLegacyDisconnect = nil
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
        currentReconcileSource = .gattCallback
        reportCoreBluetoothCallback("didDiscoverServices", error: error)
        guard setupCallbackIsCurrent(peripheral, phase: .services) else {
            reportRejectedCallback("didDiscoverServices", reason: "staleSetupGenerationOrPhase")
            return
        }
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

        recordSetupProgress(.services)
        if !LibreWatchRestoredObjectIdentity.isCurrent(service, expected: setupService) {
            setupService = service
            writeCharacteristic = nil
            receiveCharacteristic = nil
        }
        bindRestoredGATTObjects(from: peripheral)
        let missing = missingLibreCharacteristics()
        if missing.isEmpty {
            continueAfterCharacteristicsAreBound(for: peripheral, service: service)
            return
        }
        peripheral.discoverCharacteristics(missing, for: service)
        scheduleReconnectFallback(for: peripheral)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        currentReconcileSource = .gattCallback
        reportCoreBluetoothCallback("didDiscoverCharacteristics", error: error)
        guard setupCallbackIsCurrent(peripheral, phase: .characteristics),
              LibreWatchRestoredObjectIdentity.isCurrent(service, expected: setupService) else {
            reportRejectedCallback("didDiscoverCharacteristics", reason: "staleSetupGenerationOrService")
            return
        }
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

        guard writeCharacteristic != nil, receiveCharacteristic != nil else {
            failAndRescan(.characteristicNotFound, error: nil)
            return
        }
        continueAfterCharacteristicsAreBound(for: peripheral, service: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        currentReconcileSource = .gattCallback
        reportCoreBluetoothCallback("didUpdateNotificationState", error: error)
        guard characteristic.uuid == CBUUID(string: Libre2WatchDirectConstants.receiveCharacteristicUUIDString),
              LibreWatchRestoredObjectIdentity.isCurrent(
                  characteristic,
                  expected: receiveCharacteristic
              ),
              setupCallbackIsCurrent(peripheral, phase: .notifications)
        else {
            reportRejectedCallback("didUpdateNotificationState", reason: "staleCharacteristicOrSetupPhase")
            return
        }
        guard error == nil, characteristic.isNotifying else {
            failAndRescan(.notificationSetupFailed, error: error?.localizedDescription)
            return
        }
        recordSetupProgress(.notifications)
        if var restorationState {
            restorationState.markUnlockRequested()
            self.restorationState = restorationState
        }
        guard let writeCharacteristic else {
            failAndRescan(.unlockWriteFailed, error: "Session or write channel is unavailable")
            return
        }
        writeUnlock(to: peripheral, characteristic: writeCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        currentReconcileSource = .gattCallback
        reportCoreBluetoothCallback("didWriteUnlock", error: error)
        guard characteristic.uuid == CBUUID(string: Libre2WatchDirectConstants.writeCharacteristicUUIDString),
              LibreWatchRestoredObjectIdentity.isCurrent(
                  characteristic,
                  expected: writeCharacteristic
              ),
              setupCallbackIsCurrent(peripheral, phase: .unlock)
        else {
            reportRejectedCallback("didWriteUnlock", reason: "staleCharacteristicOrSetupPhase")
            return
        }
        if let error {
            failAndRescan(.unlockWriteFailed, error: error.localizedDescription)
        } else {
            recordSetupProgress(.unlock)
            setupGeneration = nil
            connectionTiming.recordReceivingProgress(
                at: Date(),
                timeout: receivingExecutionBudget,
                executionIsAvailable: timedRecoveryIsAllowed,
                monotonicTime: monotonicNow
            )
            state.notificationsActive()
            scheduleReconnectFallback(for: peripheral)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        currentReconcileSource = .bleNotification
        guard characteristic.uuid == CBUUID(string: Libre2WatchDirectConstants.receiveCharacteristicUUIDString),
              LibreWatchRestoredObjectIdentity.isCurrent(
                  characteristic,
                  expected: receiveCharacteristic
              ),
              identityAndOwnershipAreConfirmed(for: peripheral),
              peripheral.state == .connected,
              !deliberatelyDisconnecting, !scanAfterReconnectCancellation
        else {
            if characteristic.uuid == CBUUID(string: Libre2WatchDirectConstants.receiveCharacteristicUUIDString) {
                reportRejectedCallback("didUpdateValue", reason: "staleCharacteristicGenerationOrOwnership")
            }
            return
        }
        if let error {
            let errorAction = notificationErrorAction(for: error)
            reportCoreBluetoothCallback(
                "didUpdateValue",
                error: error,
                classification: errorAction.diagnosticName
            )
            switch errorAction {
            case .preserveConnectionNearBackgroundLimit:
                // This is a watchOS background-delivery budget warning, not corrupt Libre data.
                state.notificationsActive()
            case .preserveConnectionExceededBackgroundLimit:
                // The system may stop background deliveries until user interaction. Keep the
                // subscription/link intact; foreground execution-budget recovery remains finite.
                state.notificationsActive()
            case .recoverBluetoothLink:
                failAndRescan(.connectionFailed, error: bluetoothErrorDescription(error))
            }
            return
        }
        guard let fragment = characteristic.value, !fragment.isEmpty else { return }

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
            // BLE liveness is a property of the technically valid Libre frame, not of later
            // clinical ordering/deduplication. Refresh it before the payload acceptance gate.
            frameLiveness.validFrame(at: now)
            recordRestoredStreamEvidence(for: peripheral)
            setupGeneration = nil
            cancelReconnectFallback()
            connectionTiming.receivedPacketOrEnabledNotifications(at: now)
            connectionTiming.recordReceivingProgress(
                at: now,
                timeout: receivingExecutionBudget,
                executionIsAvailable: timedRecoveryIsAllowed,
                monotonicTime: monotonicNow
            )
            state.notificationsActive()
            reportRecoverySuccessIfNeeded()
            reportFrameProgress(at: now)
            let wasAccepted = watchState?.submitLibreWatchReading(reading) == true
            scheduleReconnectFallback(for: peripheral)
            if wasAccepted {
                state.recordDirectReading(reading)
            }
        } catch {
            frameAssembler.reset()
            state.fail(.invalidFrame, error: error.localizedDescription)
            if frameLiveness.invalidFrame() {
                beginControlledSensorRecovery(
                    for: peripheral, error: "Three consecutive invalid Libre frames; reconnecting",
                    trigger: "invalidFrames"
                )
            }
        }
    }
}
