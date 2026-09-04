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
    private var connectionTiming = LibreWatchConnectionTiming()
    private var setupService: CBService?
    private var healthTimer: Timer?
    private var watchStateObservers = Set<AnyCancellable>()
    private var reconnectFallbackWorkItem: DispatchWorkItem?
    private var systemAutoReconnectIsActive = false
    private var applicationIsActive = false
    private var extendedRuntimeSession: WKExtendedRuntimeSession?
    private var extendedRuntimeIsRunning = false
    private var userInitiatedRuntimeStart = false
    private var pendingLegacyDisconnect: DispatchWorkItem?
    private var disconnectGate = LibreWatchLegacyDisconnectGate()
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
            updateRecoveryActivity()
        case .iphone:
            stopExtendedRuntime()
            deliberatelyDisconnecting = true
            scanAfterReconnectCancellation = false
            systemAutoReconnectIsActive = false
            connectionTiming.invalidate()
            returnAfterDisconnect = nil
            cancelReconnectFallback()
            scanIsPending = false
            centralManager?.stopScan()
            if let sensorPeripheral {
                prepareForExpectedDisconnectCallback()
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
            connectionTiming.invalidate()
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
            self.updateRecoveryActivity()
        }
    }

    func resumeDirectReceptionIfOwned() {
        guard watchState?.libreWatchOwnership == .watch,
              preparedSession?.isValid == true,
              !systemAutoReconnectIsActive,
              !scanAfterReconnectCancellation,
              timedRecoveryIsAllowed
        else { return }

        if centralManager?.isScanning == true { return }
        if let sensorPeripheral, sensorPeripheral.state != .disconnected {
            return
        }

        deliberatelyDisconnecting = false
        scanIsPending = true
        beginScanningIfPossible()
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
        centralManager?.stopScan()
        let mustWaitForDisconnect = sensorPeripheral.map { $0.state != .disconnected } ?? false
        if mustWaitForDisconnect {
            returnAfterDisconnect = { [weak self] in self?.completeReturnToPhone() }
        }
        if let sensorPeripheral {
            systemAutoReconnectIsActive = false
            prepareForExpectedDisconnectCallback()
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
        extendedRuntimeIsRunning = false

        guard let session = extendedRuntimeSession else { return }
        extendedRuntimeSession = nil
        if session.state != .invalid {
            session.invalidate()
        }
    }

    /// Timers and new fallback scans wait for foreground/runtime execution. Existing Core
    /// Bluetooth work remains intact while Watch owns the sensor and completes via delegates.
    private func updateRecoveryActivity() {
        startExtendedRuntimeIfEligible()

        if let sensorPeripheral {
            normalizeObservedLink(sensorPeripheral, at: Date())
        }

        guard timedRecoveryIsAllowed,
              watchState?.libreWatchOwnership == .watch
        else {
            if !eventDrivenRecoveryIsAllowed, centralManager?.isScanning == true {
                centralManager?.stopScan()
                scanIsPending = false
            }
            cancelReconnectFallback()
            return
        }

        guard !scanAfterReconnectCancellation else { return }

        guard let sensorPeripheral else {
            resumeDirectReceptionIfOwned()
            return
        }

        switch sensorPeripheral.state {
        case .connected:
            if connectionTiming.setupInProgress {
                scheduleReconnectFallback(for: sensorPeripheral)
            } else if connectionTiming.phase != .receiving {
                beginSetup(for: sensorPeripheral)
            }
        case .connecting:
            scheduleReconnectFallback(for: sensorPeripheral)
        case .disconnected:
            if systemAutoReconnectIsActive {
                scheduleReconnectFallback(for: sensorPeripheral)
                return
            }
            guard let centralManager, centralManager.state == .poweredOn else { return }
            connect(sensorPeripheral, using: centralManager)
        case .disconnecting:
            scheduleReconnectFallback(for: sensorPeripheral)
        @unknown default:
            scheduleReconnectFallback(for: sensorPeripheral)
        }
    }

    private func beginScanningIfPossible() {
        guard scanIsPending,
              !scanAfterReconnectCancellation,
              connectionTiming.canStartBluetoothOperation,
              watchState?.libreWatchOwnership == .watch,
              timedRecoveryIsAllowed,
              let centralManager
        else { return }

        if let sensorPeripheral, sensorPeripheral.state != .disconnected {
            return
        }

        switch centralManager.state {
        case .poweredOn:
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
        guard timedRecoveryIsAllowed, !deliberatelyDisconnecting else { return }
        systemAutoReconnectIsActive = false
        clearTransientBluetoothState()
        scanIsPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.beginScanningIfPossible()
        }
    }

    func applicationActivityDidChange(isActive: Bool) {
        applicationIsActive = isActive
        updateRecoveryActivity()
        if isActive {
            evaluateConnectionHealth(at: Date())
        }
    }

    private func connect(_ peripheral: CBPeripheral, using central: CBCentralManager,
                         resetDisconnectGate: Bool = true) {
        guard eventDrivenRecoveryIsAllowed, !deliberatelyDisconnecting,
              !scanAfterReconnectCancellation, identityAndOwnershipAreConfirmed(for: peripheral),
              peripheral.state == .disconnected, connectionTiming.canStartBluetoothOperation
        else { return }
        if resetDisconnectGate { prepareForExpectedDisconnectCallback() }
        systemAutoReconnectIsActive = false
        scanIsPending = false
        central.stopScan()
        cancelReconnectFallback()
        connectionTiming.beginConnection(at: Date(), applicationIsActive: applicationIsActive)
        state.connecting()
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
                  at: date, applicationIsActive: applicationIsActive
              )
        else { return false }
        cancelReconnectFallback()
        setupService = nil
        writeCharacteristic = nil
        receiveCharacteristic = nil
        frameAssembler.reset()
        state.reconnecting(error: nil)
        // An observed .connecting already represents one system/ongoing attempt.
        systemAutoReconnectIsActive = peripheral.state == .connecting
        beginRecoveryDiagnosticIfNeeded()
        return true
    }

    private func beginSetup(for peripheral: CBPeripheral) {
        guard identityAndOwnershipAreConfirmed(for: peripheral), peripheral.state == .connected,
              !deliberatelyDisconnecting, !scanAfterReconnectCancellation else { return }
        prepareForExpectedDisconnectCallback()
        cancelReconnectFallback()
        connectionTiming.beginSetup(at: Date())
        systemAutoReconnectIsActive = false
        setupService = nil
        writeCharacteristic = nil
        receiveCharacteristic = nil
        frameAssembler.reset()
        state.connecting()
        peripheral.discoverServices([CBUUID(string: Libre2WatchDirectConstants.serviceUUIDString)])
        scheduleReconnectFallback(for: peripheral)
    }

    private func setupCallbackIsCurrent(_ peripheral: CBPeripheral, phase: LibreWatchConnectionTiming.Phase) -> Bool {
        identityAndOwnershipAreConfirmed(for: peripheral) && peripheral.state == .connected &&
            !deliberatelyDisconnecting && !scanAfterReconnectCancellation &&
            connectionTiming.acceptsSetup(phase)
    }

    private func recordSetupProgress(_ phase: LibreWatchConnectionTiming.Phase) {
        cancelReconnectFallback()
        connectionTiming.setupProgress(phase, at: Date())
    }

    private func scheduleReconnectFallback(for peripheral: CBPeripheral) {
        cancelReconnectFallback()
        guard let deadline = connectionTiming.deadline, let preparedSession else { return }
        let peripheralIdentifier = peripheral.identifier
        let action = LibreWatchLifecyclePolicy.reconnectFallbackAction(
            deadline: deadline.expiresAt,
            now: Date(),
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
            guard let self,
                  self.timedRecoveryIsAllowed,
                  !self.deliberatelyDisconnecting,
                  self.preparedSession?.id == preparedSession.id,
                  self.preparedSession?.sensorUID == preparedSession.sensorUID,
                  let currentPeripheral = self.sensorPeripheral,
                  currentPeripheral.identifier == peripheralIdentifier,
                  self.identityAndOwnershipAreConfirmed(for: currentPeripheral),
                  self.connectionTiming.timeoutIsCurrent(
                      deadline, ownership: self.watchState?.libreWatchOwnership ?? .iphone,
                      cancelling: self.scanAfterReconnectCancellation, at: Date()
                  )
            else { return }
            if deadline.phase == .connection, currentPeripheral.state == .connected {
                self.beginSetup(for: currentPeripheral)
                return
            }
            self.beginControlledSensorRecovery(
                for: currentPeripheral,
                error: "Automatic reconnect timed out; returning to the NFC-confirmed sensor scan"
            )
        }
        reconnectFallbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: workItem)
    }

    /// Cancels the one existing connection attempt before returning to the exact-sensor scan.
    private func beginControlledSensorRecovery(for peripheral: CBPeripheral, error: String) {
        guard timedRecoveryIsAllowed,
              !deliberatelyDisconnecting,
              peripheral === sensorPeripheral,
              !scanAfterReconnectCancellation
        else { return }

        beginRecoveryDiagnosticIfNeeded()
        cancelReconnectFallback()
        connectionTiming.invalidate()
        systemAutoReconnectIsActive = false
        scanIsPending = false
        centralManager?.stopScan()
        state.reconnecting(error: error)
        scanAfterReconnectCancellation = true
        prepareForExpectedDisconnectCallback()
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

    private func prepareForExpectedDisconnectCallback() {
        pendingLegacyDisconnect?.cancel()
        pendingLegacyDisconnect = nil
        disconnectGate.reset()
    }

    private func clearTransientBluetoothState() {
        scanAfterReconnectCancellation = false
        systemAutoReconnectIsActive = false
        cancelReconnectFallback()
        pendingLegacyDisconnect?.cancel()
        pendingLegacyDisconnect = nil
        disconnectGate.reset()
        sensorPeripheral?.delegate = nil
        sensorPeripheral = nil
        matchedPeripheralName = nil
        setupService = nil
        writeCharacteristic = nil
        receiveCharacteristic = nil
        frameAssembler.reset()
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
        cancelReconnectFallback()
        connectionTiming.invalidate()
        reportRecoveryFailureIfNeeded()
        state.fail(failure, error: error)
        centralManager?.stopScan()
        if let sensorPeripheral, sensorPeripheral.state != .disconnected {
            // Retire setup before cancelling; no late GATT callback or lifecycle event may
            // start fresh setup until the existing cancellation has actually completed.
            scanAfterReconnectCancellation = true
            prepareForExpectedDisconnectCallback()
            centralManager?.cancelPeripheralConnection(sensorPeripheral)
            if sensorPeripheral.state == .disconnected {
                finishReconnectCancellationAndScan()
            }
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

        watchState?.reportLibreWatchDiagnostic(LibreWatchDiagnosticEvent(
            kind: .disconnected,
            isReconnecting: isReconnecting,
            errorCode: error.map { ($0 as NSError).code }
        ))

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

        let hadFailure = state.failure != nil

        setupService = nil
        writeCharacteristic = nil
        receiveCharacteristic = nil
        frameAssembler.reset()
        // Keep an already observed connection deadline when the delayed callback arrives.
        if connectionTiming.phase != .connection { connectionTiming.invalidate() }
        state.reconnecting(error: bluetoothErrorDescription(error))

        switch action {
        case .waitForSystemReconnect:
            beginRecoveryDiagnosticIfNeeded()
            systemAutoReconnectIsActive = true
            if connectionTiming.phase != .connection {
                connectionTiming.beginConnection(at: disconnectedAt, applicationIsActive: applicationIsActive)
            }
            scheduleReconnectFallback(for: peripheral)
        case .reconnectManually:
            beginRecoveryDiagnosticIfNeeded()
            systemAutoReconnectIsActive = false
            cancelReconnectFallback()
            guard !hadFailure,
                  let centralManager,
                  centralManager.state == .poweredOn
            else {
                scheduleRescan()
                return
            }
            // Keep the NFC-confirmed peripheral and reconnect it directly. Scanning is only the
            // fallback if this known connection cannot be restored within the timeout.
            if peripheral.state == .connecting {
                systemAutoReconnectIsActive = true
                if connectionTiming.phase != .connection {
                    connectionTiming.beginConnection(at: disconnectedAt, applicationIsActive: applicationIsActive)
                }
            } else {
                // This callback ends the old attempt. The actual new connect gets one new deadline.
                connectionTiming.invalidate()
                connect(peripheral, using: centralManager, resetDisconnectGate: false)
            }
            scheduleReconnectFallback(for: peripheral)
        case .noAdditionalWork:
            systemAutoReconnectIsActive = isReconnecting && ownership == .watch
            if systemAutoReconnectIsActive {
                if connectionTiming.phase != .connection {
                    connectionTiming.beginConnection(at: disconnectedAt, applicationIsActive: applicationIsActive)
                }
            }
            cancelReconnectFallback()
        case .finishDeliberateDisconnect:
            break
        }
    }

    private func beginRecoveryDiagnosticIfNeeded() {
        guard !recoveryDiagnosticIsPending else { return }
        recoveryDiagnosticIsPending = true
        recoveryFailureWasReported = false
        watchState?.reportLibreWatchDiagnostic(LibreWatchDiagnosticEvent(kind: .recoveryStarted))
    }

    private func reportRecoveryFailureIfNeeded() {
        guard recoveryDiagnosticIsPending, !recoveryFailureWasReported else { return }
        recoveryFailureWasReported = true
        watchState?.reportLibreWatchDiagnostic(LibreWatchDiagnosticEvent(kind: .recoveryFailed))
    }

    private func reportRecoverySuccessIfNeeded() {
        guard recoveryDiagnosticIsPending else { return }
        recoveryDiagnosticIsPending = false
        recoveryFailureWasReported = false
        watchState?.reportLibreWatchDiagnostic(LibreWatchDiagnosticEvent(kind: .recoverySucceeded))
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
        watchState?.refreshDirectLibreReadingFreshness(at: date)
        if let sensorPeripheral {
            normalizeObservedLink(sensorPeripheral, at: date)
            if connectionTiming.phase != .receiving {
                updateRecoveryActivity()
            }
        }

        guard let noDataRecoveryDelay = LibreWatchLifecyclePolicy.noDataRecoveryDelay(
            applicationIsActive: applicationIsActive,
            extendedRuntimeIsRunning: extendedRuntimeIsRunning,
            ownership: watchState?.libreWatchOwnership ?? .iphone
        ),
              state.stage == .receiving,
              let sensorPeripheral,
              sensorPeripheral.state == .connected,
              connectionTiming.noDataIsOverdue(
                  lastPacketAt: state.lastPacketAt, at: date, timeout: noDataRecoveryDelay
              )
        else { return }

        let timeoutMinutes = Int(noDataRecoveryDelay / 60)
        beginControlledSensorRecovery(
            for: sensorPeripheral,
            error: "No direct Libre packet received for \(timeoutMinutes) minutes; reconnecting"
        )
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
        updateRecoveryActivity()
    }

    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        guard self.extendedRuntimeSession === extendedRuntimeSession else { return }
        // The system owns expiration. Do not create replacement sessions from the background.
        userInitiatedRuntimeStart = false
    }

    func extendedRuntimeSession(
        _ extendedRuntimeSession: WKExtendedRuntimeSession,
        didInvalidateWith _: WKExtendedRuntimeSessionInvalidationReason,
        error _: Error?
    ) {
        guard self.extendedRuntimeSession === extendedRuntimeSession else { return }
        self.extendedRuntimeSession = nil
        extendedRuntimeIsRunning = false
        userInitiatedRuntimeStart = false
        updateRecoveryActivity()
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

        if central.state == .poweredOn {
            updateRecoveryActivity()
        }
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
            return
        }

        sensorPeripheral = restored
        matchedPeripheralName = restored.name ?? preparedSession.expectedPeripheralName
        restored.delegate = self
        scanIsPending = false
        central.stopScan()

        switch restored.state {
        case .connected:
            beginSetup(for: restored)
            return
        case .connecting:
            systemAutoReconnectIsActive = true
            normalizeObservedLink(restored, at: Date())
            state.reconnecting(error: nil)
        case .disconnected:
            systemAutoReconnectIsActive = false
            state.reconnecting(error: nil)
        case .disconnecting:
            state.reconnecting(error: nil)
        @unknown default:
            state.reconnecting(error: nil)
        }
        updateRecoveryActivity()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard eventDrivenRecoveryIsAllowed,
              watchState?.libreWatchOwnership == .watch,
              !deliberatelyDisconnecting, !scanAfterReconnectCancellation,
              connectionTiming.canStartBluetoothOperation,
              sensorPeripheral == nil || sensorPeripheral?.state == .disconnected,
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
        connect(peripheral, using: central)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === sensorPeripheral else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        prepareForExpectedDisconnectCallback()
        if scanAfterReconnectCancellation || deliberatelyDisconnecting {
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
        guard eventDrivenRecoveryIsAllowed else { return }
        // Accept the connection before consulting any old deadline. GATT gets its own clock.
        beginSetup(for: peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral === sensorPeripheral else { return }
        cancelReconnectFallback()
        connectionTiming.invalidate()
        systemAutoReconnectIsActive = false
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

        if timedRecoveryIsAllowed,
           watchState?.libreWatchOwnership == .watch,
           peripheral === sensorPeripheral {
            state.reconnecting(error: bluetoothErrorDescription(error))
            connect(peripheral, using: central)
            return
        }

        state.reconnecting(error: bluetoothErrorDescription(error))
        scheduleRescan()
    }

    func centralManager(
        _: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        // Keep the fallback on every OS version: availability does not guarantee delivery
        // of the modern callback. Its token is also invalidated by a later didConnect.
        guard peripheral === sensorPeripheral, pendingLegacyDisconnect == nil,
              let token = disconnectGate.scheduleLegacy() else { return }
        let disconnectedAt = Date()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.disconnectGate.pendingToken == token else { return }
            self.pendingLegacyDisconnect = nil
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
        guard setupCallbackIsCurrent(peripheral, phase: .services) else { return }
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
        setupService = service
        peripheral.discoverCharacteristics([
            CBUUID(string: Libre2WatchDirectConstants.writeCharacteristicUUIDString),
            CBUUID(string: Libre2WatchDirectConstants.receiveCharacteristicUUIDString)
        ], for: service)
        scheduleReconnectFallback(for: peripheral)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard setupCallbackIsCurrent(peripheral, phase: .characteristics),
              service === setupService else { return }
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
        recordSetupProgress(.characteristics)
        peripheral.setNotifyValue(true, for: receiveCharacteristic)
        scheduleReconnectFallback(for: peripheral)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == CBUUID(string: Libre2WatchDirectConstants.receiveCharacteristicUUIDString),
              characteristic === receiveCharacteristic,
              setupCallbackIsCurrent(peripheral, phase: .notifications)
        else { return }
        guard error == nil, characteristic.isNotifying else {
            failAndRescan(.notificationSetupFailed, error: error?.localizedDescription)
            return
        }
        recordSetupProgress(.notifications)
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
            scheduleReconnectFallback(for: peripheral)
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
              setupCallbackIsCurrent(peripheral, phase: .unlock)
        else { return }
        if let error {
            failAndRescan(.unlockWriteFailed, error: error.localizedDescription)
        } else {
            recordSetupProgress(.unlock)
            state.notificationsActive()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == CBUUID(string: Libre2WatchDirectConstants.receiveCharacteristicUUIDString),
              characteristic === receiveCharacteristic,
              identityAndOwnershipAreConfirmed(for: peripheral),
              peripheral.state == .connected,
              !deliberatelyDisconnecting, !scanAfterReconnectCancellation
        else { return }
        if let error {
            failAndRescan(.invalidFrame, error: error.localizedDescription)
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
            if watchState?.submitLibreWatchReading(reading) == true {
                cancelReconnectFallback()
                connectionTiming.receivedPacketOrEnabledNotifications(at: now)
                state.recordDirectReading(reading)
                reportRecoverySuccessIfNeeded()
            }
        } catch {
            state.fail(.invalidFrame, error: error.localizedDescription)
        }
    }
}
