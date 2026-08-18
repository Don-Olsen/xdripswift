import CoreBluetooth
import Combine
import Foundation

/// Foreground-only Libre 2 Plus hardware-test collector.
///
/// The sole `connect` and `writeValue` paths are both guarded by an explicit
/// user-started test, Watch ownership, and the NFC-prepared sensor identity.
final class LibreWatchDirectCollector: NSObject, ObservableObject {
    @Published private(set) var state = LibreWatchDirectState()
    @Published private(set) var bluetoothStateText = "UNKNOWN"

    private weak var watchState: WatchStateModel?
    private var preparedSession: LibreWatchTestSession?
    private var centralManager: CBCentralManager?
    private var testPeripheral: CBPeripheral?
    private var matchedPeripheralName: String?
    private var writeCharacteristic: CBCharacteristic?
    private var receiveCharacteristic: CBCharacteristic?
    private var frameAssembler = Libre2DirectFrameAssembler()
    private var timer: Timer?
    private var noDataDeadline: Date?
    private var testIsActive = false
    private var pendingScanStart = false
    private var isStopping = false

    func prepare(with watchState: WatchStateModel) {
        self.watchState = watchState
        updateSession(watchState.libreWatchTestSession)
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: .main)
        }
    }

    func updateSession(_ session: LibreWatchTestSession?) {
        preparedSession = session
        guard !testIsActive else { return }
        state.sessionAvailable(session)
    }

    func startDirectTest() {
        guard !testIsActive,
              let preparedSession,
              preparedSession.isValid,
              let watchState
        else {
            state.sessionAvailable(nil)
            return
        }

        testIsActive = true
        isStopping = false
        pendingScanStart = true
        frameAssembler.reset()
        state.start(at: Date())
        startTimer()

        watchState.requestLibreWatchTestOwnership { [weak self] success, error in
            guard let self, self.testIsActive else { return }
            guard success, watchState.libreWatchTestOwnership == .watch else {
                self.fail(.ownershipFailed, error: error)
                return
            }
            self.preparedSession = watchState.libreWatchTestSession ?? preparedSession
            self.beginScanningIfPossible()
        }
    }

    func stopDirectTest() {
        guard testIsActive || state.stage == .failed else {
            state.stop()
            return
        }
        isStopping = true
        testIsActive = false
        pendingScanStart = false
        timer?.invalidate()
        timer = nil
        noDataDeadline = nil
        centralManager?.stopScan()
        if let testPeripheral {
            centralManager?.cancelPeripheralConnection(testPeripheral)
        }

        let counter = preparedSession?.unlockCount
        releasePhoneOwnershipIfNeeded(counter: counter) { [weak self] in
            guard let self else { return }
            self.clearTransientBluetoothState()
            self.state.stop()
            self.isStopping = false
        }
    }

    func viewDidDisappear() {
        if testIsActive || watchState?.libreWatchTestOwnership == .watch {
            stopDirectTest()
        }
    }

    func directGlucoseText(isMgDl: Bool) -> String {
        guard state.canDisplayDirectFromSensor,
              let reading = state.directReading
        else { return "—" }
        if isMgDl {
            return String(format: "%.0f mg/dL", reading.glucoseMGDL)
        }
        return String(format: "%.1f mmol/L", reading.glucoseMGDL / 18.0182)
    }

    private func beginScanningIfPossible() {
        guard testIsActive, pendingScanStart, let centralManager else { return }
        switch centralManager.state {
        case .poweredOn:
            pendingScanStart = false
            state.transition(to: .scanning, detail: "Scanning only for FDE3 advertisements")
            centralManager.scanForPeripherals(
                withServices: [CBUUID(string: Libre2DirectConstants.serviceUUIDString)],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        case .poweredOff:
            fail(.connectionFailed, error: "Apple Watch Bluetooth is powered off")
        case .unauthorized:
            fail(.connectionFailed, error: "Apple Watch Bluetooth access is not authorized")
        case .unsupported:
            fail(.connectionFailed, error: "Apple Watch Bluetooth is unsupported")
        case .resetting, .unknown:
            state.transition(to: .releasingToWatch, detail: "Waiting for Apple Watch Bluetooth")
        @unknown default:
            fail(.connectionFailed, error: "Unknown Apple Watch Bluetooth state")
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.testIsActive else { return }
            let now = Date()
            if self.state.updateElapsed(at: now) {
                let failure: LibreWatchDirectFailure = self.testPeripheral == nil
                    ? .noMatchingTestSensor
                    : .noDataReceived
                self.fail(failure, error: "Five-minute foreground test ended")
            } else if let noDataDeadline = self.noDataDeadline,
                      now >= noDataDeadline,
                      self.state.fragmentCount == 0 {
                self.fail(.noDataReceived, error: "No F002 notification arrived after unlock")
            }
        }
    }

    private func fail(_ failure: LibreWatchDirectFailure, error: String?) {
        guard testIsActive || state.stage != .failed else { return }
        testIsActive = false
        pendingScanStart = false
        timer?.invalidate()
        timer = nil
        noDataDeadline = nil
        centralManager?.stopScan()
        if let testPeripheral {
            centralManager?.cancelPeripheralConnection(testPeripheral)
        }
        state.fail(failure, error: error)
        releasePhoneOwnershipIfNeeded(counter: preparedSession?.unlockCount) { [weak self] in
            self?.clearTransientBluetoothState()
        }
    }

    private func releasePhoneOwnershipIfNeeded(
        counter: UInt16?,
        completion: @escaping () -> Void
    ) {
        guard let watchState,
              watchState.libreWatchTestOwnership == .watch ||
                watchState.libreWatchTestOwnership == .releasingToPhone
        else {
            completion()
            return
        }
        watchState.releaseLibreWatchTestOwnership(unlockCounter: counter) { _, _ in
            completion()
        }
    }

    private func clearTransientBluetoothState() {
        testPeripheral?.delegate = nil
        testPeripheral = nil
        matchedPeripheralName = nil
        writeCharacteristic = nil
        receiveCharacteristic = nil
        frameAssembler.reset()
    }

    private func identityAndOwnershipAreConfirmed(for peripheral: CBPeripheral) -> Bool {
        guard testIsActive,
              watchState?.libreWatchTestOwnership == .watch,
              let preparedSession,
              preparedSession.isValid,
              peripheral === testPeripheral,
              preparedSession.matches(candidateName: matchedPeripheralName)
        else { return false }
        return true
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
        beginScanningIfPossible()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard testIsActive, let preparedSession else { return }
        let candidateName = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let identityMatched = preparedSession.matches(candidateName: candidateName)
        state.recordCandidate(rssi: RSSI.intValue, identityMatched: identityMatched)
        guard identityMatched else { return }

        // This is the only path that retains and connects a peripheral. It is
        // unreachable until the exact NFC identity and Watch ownership match.
        testPeripheral = peripheral
        matchedPeripheralName = candidateName
        peripheral.delegate = self
        central.stopScan()
        guard identityAndOwnershipAreConfirmed(for: peripheral) else {
            fail(.identityMismatch, error: nil)
            return
        }
        state.transition(to: .connecting, detail: "Connecting to NFC-prepared test sensor")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard identityAndOwnershipAreConfirmed(for: peripheral) else {
            central.cancelPeripheralConnection(peripheral)
            fail(.identityMismatch, error: nil)
            return
        }
        state.transition(to: .connected, detail: "Prepared test sensor connected")
        state.transition(to: .discoveringServices, detail: "Discovering FDE3 only")
        peripheral.discoverServices([CBUUID(string: Libre2DirectConstants.serviceUUIDString)])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        fail(.connectionFailed, error: error?.localizedDescription)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard !isStopping, testIsActive else { return }
        fail(.connectionFailed, error: error?.localizedDescription ?? "Test sensor disconnected")
    }
}

extension LibreWatchDirectCollector: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard identityAndOwnershipAreConfirmed(for: peripheral) else {
            fail(.identityMismatch, error: nil)
            return
        }
        if let error {
            fail(.serviceNotFound, error: error.localizedDescription)
            return
        }
        guard let service = peripheral.services?.first(where: {
            $0.uuid == CBUUID(string: Libre2DirectConstants.serviceUUIDString)
        }) else {
            fail(.serviceNotFound, error: nil)
            return
        }
        state.transition(to: .serviceFound, detail: "FDE3 service found")
        state.transition(to: .discoveringCharacteristics, detail: "Discovering F001 and F002 only")
        peripheral.discoverCharacteristics([
            CBUUID(string: Libre2DirectConstants.writeCharacteristicUUIDString),
            CBUUID(string: Libre2DirectConstants.receiveCharacteristicUUIDString)
        ], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard identityAndOwnershipAreConfirmed(for: peripheral) else {
            fail(.identityMismatch, error: nil)
            return
        }
        if let error {
            fail(.receiveCharacteristicNotFound, error: error.localizedDescription)
            return
        }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == CBUUID(string: Libre2DirectConstants.writeCharacteristicUUIDString) {
                writeCharacteristic = characteristic
            } else if characteristic.uuid == CBUUID(string: Libre2DirectConstants.receiveCharacteristicUUIDString) {
                receiveCharacteristic = characteristic
            }
        }
        guard writeCharacteristic != nil else {
            fail(.writeCharacteristicNotFound, error: nil)
            return
        }
        guard let receiveCharacteristic else {
            fail(.receiveCharacteristicNotFound, error: nil)
            return
        }
        state.transition(to: .characteristicsFound, detail: "F001 and F002 found")
        state.transition(to: .enablingNotifications, detail: "Enabling F002 notifications")
        peripheral.setNotifyValue(true, for: receiveCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == CBUUID(string: Libre2DirectConstants.receiveCharacteristicUUIDString),
              identityAndOwnershipAreConfirmed(for: peripheral)
        else { return }
        guard error == nil, characteristic.isNotifying else {
            fail(.notificationSetupFailed, error: error?.localizedDescription)
            return
        }
        state.transition(to: .notificationsEnabled, detail: "F002 notifications active")

        guard var preparedSession,
              let writeCharacteristic,
              identityAndOwnershipAreConfirmed(for: peripheral)
        else {
            fail(.unlockWriteFailed, error: "Session or F001 became unavailable")
            return
        }
        preparedSession.unlockCount &+= 1
        self.preparedSession = preparedSession
        state.recordUnlockCounter(preparedSession.unlockCount)
        watchState?.updateLibreWatchTestUnlockCounter(preparedSession.unlockCount)
        let unlock = Data(Libre2DirectAlgorithms.streamingUnlockPayload(
            sensorUID: preparedSession.sensorUID,
            patchInfo: preparedSession.patchInfo,
            enableTime: preparedSession.unlockCode,
            unlockCount: preparedSession.unlockCount
        ))
        state.transition(to: .sendingUnlock, detail: "Writing proven streaming unlock to F001")
        peripheral.writeValue(unlock, for: writeCharacteristic, type: .withResponse)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == CBUUID(string: Libre2DirectConstants.writeCharacteristicUUIDString),
              identityAndOwnershipAreConfirmed(for: peripheral)
        else { return }
        if let error {
            fail(.unlockWriteFailed, error: error.localizedDescription)
            return
        }
        state.transition(to: .unlockSent, detail: "Streaming unlock written to F001")
        noDataDeadline = Date().addingTimeInterval(90)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == CBUUID(string: Libre2DirectConstants.receiveCharacteristicUUIDString),
              identityAndOwnershipAreConfirmed(for: peripheral)
        else { return }
        if let error {
            fail(.noDataReceived, error: error.localizedDescription)
            return
        }
        guard let fragment = characteristic.value, !fragment.isEmpty else { return }
        let now = Date()
        noDataDeadline = nil
        do {
            let completeFrame = try frameAssembler.append(fragment: fragment, at: now)
            state.recordFragment(
                length: fragment.count,
                fragmentCount: frameAssembler.fragmentCount,
                assembledByteCount: frameAssembler.assembledByteCount,
                at: now
            )
            guard let completeFrame else { return }
            state.recordCompleteFrame(count: frameAssembler.completeFrameCount, at: now)
            state.transition(to: .decrypting, detail: "Decrypting 46-byte Libre frame")
            guard let preparedSession else {
                fail(.decryptionFailed, error: "Test session disappeared")
                return
            }
            let decrypted = try Libre2DirectAlgorithms.decryptBLE(
                sensorUID: preparedSession.sensorUID,
                data: completeFrame
            )
            state.transition(to: .decrypted, detail: "Libre frame decrypted and CRC verified")
            state.transition(to: .parsing, detail: "Applying NFC-derived Libre calibration")
            let reading = try Libre2DirectAlgorithms.parseDirectReading(
                decryptedData: decrypted,
                parameters: preparedSession.algorithmParameters,
                receivedAt: now
            )
            state.recordDirectReading(reading)
        } catch let error as Libre2DirectAlgorithmError {
            switch error {
            case .badEncryptedFrameLength, .badDecryptedFrameLength:
                fail(.badFrameLength, error: error.localizedDescription)
            case .crcMismatch, .invalidSensorUID, .invalidPatchInfo:
                fail(.decryptionFailed, error: error.localizedDescription)
            case .invalidGlucose:
                fail(.parsingFailed, error: error.localizedDescription)
            }
        } catch {
            fail(.parsingFailed, error: error.localizedDescription)
        }
    }
}
