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
    private var healthTimer: Timer?
    private var watchStateObservers = Set<AnyCancellable>()
    private var reconnectFallbackWorkItem: DispatchWorkItem?
    private var systemAutoReconnectIsActive = false
    private var reconnectStartedAt: Date?
    private var applicationIsActive = false
    private var extendedRuntimeSession: WKExtendedRuntimeSession?
    private var extendedRuntimeIsRunning = false
    private var userInitiatedRuntimeStart = false
    private var pendingLegacyDisconnect: DispatchWorkItem?
    private var disconnectHandledForCurrentConnection = false
    private var scanAfterReconnectCancellation = false

    private var connectionOptions: [String: Any] {
        [CBConnectPeripheralOptionEnableAutoReconnect: true]
    }

    private var recoveryIsAllowed: Bool {
        LibreWatchLifecyclePolicy.recoveryIsAllowed(
            applicationIsActive: applicationIsActive,
            extendedRuntimeIsRunning: extendedRuntimeIsRunning,
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
            reconnectStartedAt = nil
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
              recoveryIsAllowed
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

    /// Centralizes whether recovery work may run. Lowering the wrist is harmless while the
    /// user-started extended runtime session is actually running; otherwise recovery waits for
    /// the app to become active again.
    private func updateRecoveryActivity() {
        startExtendedRuntimeIfEligible()

        guard recoveryIsAllowed,
              watchState?.libreWatchOwnership == .watch
        else {
            if centralManager?.isScanning == true {
                centralManager?.stopScan()
                scanIsPending = watchState?.libreWatchOwnership == .watch
            }
            cancelReconnectFallback()
            return
        }

        guard !scanAfterReconnectCancellation else { return }

        guard let sensorPeripheral else {
            resumeDirectReceptionIfOwned()
            return
        }

        if systemAutoReconnectIsActive {
            scheduleReconnectFallback(for: sensorPeripheral)
            return
        }

        switch sensorPeripheral.state {
        case .connected:
            guard state.stage != .receiving else { return }
            reconnectStartedAt = reconnectStartedAt ?? Date()
            state.connecting()
            scheduleReconnectFallback(for: sensorPeripheral)
            sensorPeripheral.discoverServices([
                CBUUID(string: Libre2WatchDirectConstants.serviceUUIDString)
            ])
        case .connecting:
            scheduleReconnectFallback(for: sensorPeripheral)
        case .disconnected:
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
              watchState?.libreWatchOwnership == .watch,
              recoveryIsAllowed,
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
        guard recoveryIsAllowed, !deliberatelyDisconnecting else { return }
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

    private func connect(_ peripheral: CBPeripheral, using central: CBCentralManager) {
        guard recoveryIsAllowed, !scanAfterReconnectCancellation else { return }
        pendingLegacyDisconnect?.cancel()
        pendingLegacyDisconnect = nil
        disconnectHandledForCurrentConnection = false
        systemAutoReconnectIsActive = false
        cancelReconnectFallback()
        reconnectStartedAt = reconnectStartedAt ?? Date()
        state.connecting()
        central.connect(peripheral, options: connectionOptions)
        scheduleReconnectFallback(for: peripheral)
    }

    private func scheduleReconnectFallback(for peripheral: CBPeripheral) {
        cancelReconnectFallback()
        let startedAt = reconnectStartedAt ?? Date()
        reconnectStartedAt = startedAt
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
                error: "Automatic reconnect timed out; returning to the NFC-confirmed sensor scan"
            )
        case let .wait(remaining):
            let workItem = DispatchWorkItem { [weak self] in
                guard let self,
                      self.recoveryIsAllowed,
                      !self.deliberatelyDisconnecting,
                      self.reconnectStartedAt == startedAt,
                      let currentPeripheral = self.sensorPeripheral,
                      currentPeripheral.identifier == peripheralIdentifier,
                      self.state.stage != .receiving
                else { return }

                self.beginControlledSensorRecovery(
                    for: currentPeripheral,
                    error: "Automatic reconnect timed out; returning to the NFC-confirmed sensor scan"
                )
            }
            reconnectFallbackWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: workItem)
        }
    }

    /// Cancels the one existing connection attempt before returning to the exact-sensor scan.
    private func beginControlledSensorRecovery(for peripheral: CBPeripheral, error: String) {
        guard recoveryIsAllowed,
              !deliberatelyDisconnecting,
              peripheral === sensorPeripheral,
              !scanAfterReconnectCancellation
        else { return }

        cancelReconnectFallback()
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
        disconnectHandledForCurrentConnection = false
    }

    private func clearTransientBluetoothState() {
        scanAfterReconnectCancellation = false
        systemAutoReconnectIsActive = false
        cancelReconnectFallback()
        pendingLegacyDisconnect?.cancel()
        pendingLegacyDisconnect = nil
        disconnectHandledForCurrentConnection = false
        sensorPeripheral?.delegate = nil
        sensorPeripheral = nil
        matchedPeripheralName = nil
        writeCharacteristic = nil
        receiveCharacteristic = nil
        frameAssembler.reset()
        dataExpectedSince = nil
        reconnectStartedAt = nil
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
        state.fail(failure, error: error)
        centralManager?.stopScan()
        if let sensorPeripheral, sensorPeripheral.state != .disconnected {
            centralManager?.cancelPeripheralConnection(sensorPeripheral)
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

        if scanAfterReconnectCancellation {
            finishReconnectCancellationAndScan()
            return
        }

        let ownership = watchState?.libreWatchOwnership ?? .iphone
        let action = LibreWatchLifecyclePolicy.disconnectRecoveryAction(
            isDeliberate: deliberatelyDisconnecting,
            systemIsReconnecting: isReconnecting,
            recoveryIsAllowed: recoveryIsAllowed,
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

        writeCharacteristic = nil
        receiveCharacteristic = nil
        frameAssembler.reset()
        dataExpectedSince = nil
        state.reconnecting(error: bluetoothErrorDescription(error))

        switch action {
        case .waitForSystemReconnect:
            systemAutoReconnectIsActive = true
            reconnectStartedAt = disconnectedAt
            scheduleReconnectFallback(for: peripheral)
        case .reconnectManually:
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
            reconnectStartedAt = disconnectedAt
            centralManager.connect(peripheral, options: connectionOptions)
            scheduleReconnectFallback(for: peripheral)
        case .noAdditionalWork:
            systemAutoReconnectIsActive = isReconnecting && ownership == .watch
            if systemAutoReconnectIsActive {
                reconnectStartedAt = disconnectedAt
            }
            cancelReconnectFallback()
        case .finishDeliberateDisconnect:
            break
        }
    }

    private func handleDisconnectOnce(
        peripheral: CBPeripheral,
        isReconnecting: Bool,
        disconnectedAt: Date,
        error: Error?
    ) {
        guard !disconnectHandledForCurrentConnection else { return }
        disconnectHandledForCurrentConnection = true
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

        // After reconnecting, dataExpectedSince is newer than the previous packet. Always use
        // the newest activity marker so an old reading cannot cancel a healthy new connection.
        let lastActivity = [state.lastPacketAt, dataExpectedSince]
            .compactMap { $0 }
            .max()

        guard let noDataRecoveryDelay = LibreWatchLifecyclePolicy.noDataRecoveryDelay(
            applicationIsActive: applicationIsActive,
            extendedRuntimeIsRunning: extendedRuntimeIsRunning,
            ownership: watchState?.libreWatchOwnership ?? .iphone
        ),
              state.stage == .receiving,
              let sensorPeripheral,
              sensorPeripheral.state == .connected,
              let lastActivity,
              date.timeIntervalSince(lastActivity) >= noDataRecoveryDelay
        else { return }

        dataExpectedSince = nil
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
            reconnectStartedAt = Date()
            state.connecting()
        case .connecting:
            systemAutoReconnectIsActive = true
            reconnectStartedAt = Date()
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
        guard recoveryIsAllowed,
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
        connect(peripheral, using: central)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        pendingLegacyDisconnect?.cancel()
        pendingLegacyDisconnect = nil
        disconnectHandledForCurrentConnection = false
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
        guard recoveryIsAllowed else { return }
        reconnectStartedAt = reconnectStartedAt ?? Date()
        scheduleReconnectFallback(for: peripheral)
        peripheral.discoverServices([CBUUID(string: Libre2WatchDirectConstants.serviceUUIDString)])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
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

        if recoveryIsAllowed,
           watchState?.libreWatchOwnership == .watch,
           peripheral === sensorPeripheral {
            systemAutoReconnectIsActive = false
            reconnectStartedAt = reconnectStartedAt ?? Date()
            state.reconnecting(error: bluetoothErrorDescription(error))
            central.connect(peripheral, options: connectionOptions)
            scheduleReconnectFallback(for: peripheral)
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
        // Older systems only call this delegate. Delay it by one run-loop turn so the modern
        // isReconnecting callback wins if an SDK/runtime happens to deliver both forms.
        pendingLegacyDisconnect?.cancel()
        let disconnectedAt = Date()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingLegacyDisconnect = nil
            self.handleDisconnectOnce(
                peripheral: peripheral,
                isReconnecting: false,
                disconnectedAt: disconnectedAt,
                error: error
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
        guard identityAndOwnershipAreConfirmed(for: peripheral) else { return }
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
        guard identityAndOwnershipAreConfirmed(for: peripheral) else { return }
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
              identityAndOwnershipAreConfirmed(for: peripheral)
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
              identityAndOwnershipAreConfirmed(for: peripheral)
        else { return }
        if let error {
            failAndRescan(.unlockWriteFailed, error: error.localizedDescription)
        } else {
            reconnectStartedAt = nil
            cancelReconnectFallback()
            dataExpectedSince = Date()
            state.notificationsActive()
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == CBUUID(string: Libre2WatchDirectConstants.receiveCharacteristicUUIDString),
              identityAndOwnershipAreConfirmed(for: peripheral)
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
                state.recordDirectReading(reading)
            }
        } catch {
            state.fail(.invalidFrame, error: error.localizedDescription)
        }
    }
}
