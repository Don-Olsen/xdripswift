import Combine
import CoreBluetooth
import Foundation

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

    func prepare(with watchState: WatchStateModel) {
        self.watchState = watchState
        updateSession(watchState.libreWatchDirectSession)

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
        let sensorChanged = preparedSession?.sensorUID != session?.sensorUID
        preparedSession = session
        if sensorChanged, watchState?.libreWatchOwnership == .watch {
            returnLibreToPhone()
            return
        }
        state.sessionAvailable(session)
    }

    func ownershipDidChange(_ ownership: LibreWatchOwnership) {
        switch ownership {
        case .watch:
            resumeDirectReceptionIfOwned()
        case .iphone:
            deliberatelyDisconnecting = true
            returnAfterDisconnect = nil
            stopBluetooth()
            clearTransientBluetoothState()
            state.returnedToPhone(session: preparedSession)
            deliberatelyDisconnecting = false
        case .releasingToWatch, .releasingToPhone, .recovery:
            break
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
                self.state.fail(
                    error == LibreWatchDirectFailure.phoneUnavailable.rawValue ? .phoneUnavailable : .ownershipFailed,
                    error: error
                )
                return
            }
            self.resumeDirectReceptionIfOwned()
        }
    }

    func resumeDirectReceptionIfOwned() {
        guard watchState?.libreWatchOwnership == .watch,
              preparedSession?.isValid == true
        else { return }

        if centralManager?.isScanning == true { return }
        if let sensorPeripheral,
           sensorPeripheral.state == .connected || sensorPeripheral.state == .connecting {
            return
        }

        deliberatelyDisconnecting = false
        scanIsPending = true
        beginScanningIfPossible()
    }

    func returnLibreToPhone() {
        guard let watchState else { return }
        guard watchState.libreWatchOwnership == .watch else {
            stopBluetooth()
            state.returnedToPhone(session: preparedSession)
            return
        }
        guard watchState.phoneIsReachable else {
            state.fail(.phoneUnavailable, error: "Bring iPhone nearby before returning the sensor")
            return
        }

        state.beginReturn()
        deliberatelyDisconnecting = true
        centralManager?.stopScan()
        let mustWaitForDisconnect = sensorPeripheral.map { $0.state != .disconnected } ?? false
        if mustWaitForDisconnect, let sensorPeripheral {
            returnAfterDisconnect = { [weak self] in self?.completeReturnToPhone() }
            centralManager?.cancelPeripheralConnection(sensorPeripheral)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.finishPendingReturnAfterDisconnect()
            }
        } else {
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

    func directGlucoseText(isMgDl: Bool) -> String {
        guard let reading = state.directReading else { return "—" }
        if isMgDl {
            return String(format: "%.0f", reading.glucoseMGDL)
        }
        return String(format: "%.1f", reading.glucoseMGDL / 18.0182)
    }

    private func beginScanningIfPossible() {
        guard scanIsPending,
              watchState?.libreWatchOwnership == .watch,
              let centralManager
        else { return }

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
        guard watchState?.libreWatchOwnership == .watch, !deliberatelyDisconnecting else { return }
        clearTransientBluetoothState()
        scanIsPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.beginScanningIfPossible()
        }
    }

    private func stopBluetooth() {
        scanIsPending = false
        centralManager?.stopScan()
        if let sensorPeripheral, sensorPeripheral.state != .disconnected {
            centralManager?.cancelPeripheralConnection(sensorPeripheral)
        }
    }

    private func clearTransientBluetoothState() {
        sensorPeripheral?.delegate = nil
        sensorPeripheral = nil
        matchedPeripheralName = nil
        writeCharacteristic = nil
        receiveCharacteristic = nil
        frameAssembler.reset()
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

        if central.state == .poweredOn, watchState?.libreWatchOwnership == .watch {
            scanIsPending = true
            beginScanningIfPossible()
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard watchState?.libreWatchOwnership == .watch,
              let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let preparedSession,
              let restored = peripherals.first(where: { preparedSession.matches(candidateName: $0.name) })
        else { return }

        sensorPeripheral = restored
        matchedPeripheralName = restored.name
        restored.delegate = self

        switch restored.state {
        case .connected:
            state.connecting()
            restored.discoverServices([CBUUID(string: Libre2WatchDirectConstants.serviceUUIDString)])
        case .connecting:
            state.connecting()
        case .disconnected:
            state.connecting()
            central.connect(restored, options: nil)
        case .disconnecting:
            scheduleRescan()
        @unknown default:
            scheduleRescan()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard watchState?.libreWatchOwnership == .watch, let preparedSession else { return }
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
        state.connecting()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard identityAndOwnershipAreConfirmed(for: peripheral) else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        state.connecting()
        peripheral.discoverServices([CBUUID(string: Libre2WatchDirectConstants.serviceUUIDString)])
    }

    func centralManager(
        _: CBCentralManager,
        didFailToConnect _: CBPeripheral,
        error: Error?
    ) {
        state.fail(.connectionFailed, error: error?.localizedDescription)
        scheduleRescan()
    }

    func centralManager(
        _: CBCentralManager,
        didDisconnectPeripheral _: CBPeripheral,
        error: Error?
    ) {
        if deliberatelyDisconnecting {
            finishPendingReturnAfterDisconnect()
            return
        }
        if let error {
            state.fail(.connectionFailed, error: error.localizedDescription)
        }
        scheduleRescan()
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
            state.recordDirectReading(reading)
            watchState?.submitLibreWatchReading(reading.payload(sessionID: preparedSession.id))
        } catch {
            state.fail(.invalidFrame, error: error.localizedDescription)
        }
    }
}
