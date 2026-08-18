//
//  LibreWatchPassiveScanner.swift
//  xDrip Watch App
//
//  Passive advertisement observation only. This type intentionally has no
//  CBPeripheral delegate and retains no peripheral object or raw identifier.
//

import Combine
import CoreBluetooth
import Foundation

enum LibreWatchBluetoothState: Equatable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn

    init(_ state: CBManagerState) {
        switch state {
        case .unknown:
            self = .unknown
        case .resetting:
            self = .resetting
        case .unsupported:
            self = .unsupported
        case .unauthorized:
            self = .unauthorized
        case .poweredOff:
            self = .poweredOff
        case .poweredOn:
            self = .poweredOn
        @unknown default:
            self = .unknown
        }
    }

    var displayText: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .resetting:
            return "Resetting"
        case .unsupported:
            return "Unsupported"
        case .unauthorized:
            return "Not authorized"
        case .poweredOff:
            return "Off"
        case .poweredOn:
            return "On"
        }
    }
}

final class LibreWatchPassiveScanner: NSObject, ObservableObject {
    @Published private(set) var diagnostic = LibreWatchDiagnosticState()
    @Published private(set) var bluetoothState: LibreWatchBluetoothState = .unknown

    private var timer: Timer?
    private var centralManager: CBCentralManager?

    deinit {
        timer?.invalidate()
        centralManager?.stopScan()
    }

    var canStartScanning: Bool {
        bluetoothState == .poweredOn && !diagnostic.isScanning
    }

    func prepare() {
        guard centralManager == nil else { return }

        centralManager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
    }

    func startScanning() {
        guard canStartScanning, let centralManager else { return }

        var updated = diagnostic
        updated.start(at: Date(), sessionSalt: UInt64.random(in: UInt64.min ... UInt64.max))
        diagnostic = updated

        centralManager.scanForPeripherals(
            withServices: [CBUUID(string: LibreWatchDiagnosticState.serviceUUIDString)],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )

        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.handleTimerTick()
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopScanning() {
        finishScanning(reason: .user)
    }

    func viewDidDisappear() {
        finishScanning(reason: .viewDisappeared)
    }

    private func handleTimerTick() {
        var updated = diagnostic
        let timedOut = updated.updateElapsed(at: Date())
        diagnostic = updated

        if timedOut {
            finishScanning(reason: .timeout)
        }
    }

    private func finishScanning(reason: LibreWatchScanStopReason) {
        guard diagnostic.isScanning else { return }

        centralManager?.stopScan()
        timer?.invalidate()
        timer = nil

        var updated = diagnostic
        updated.stop(at: Date(), reason: reason)
        diagnostic = updated
    }
}

extension LibreWatchPassiveScanner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = LibreWatchBluetoothState(central.state)

        if central.state != .poweredOn, diagnostic.isScanning {
            finishScanning(reason: .bluetoothUnavailable)
        }
    }

    func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData _: [String: Any],
        rssi RSSI: NSNumber
    ) {
        var updated = diagnostic
        updated.recordCandidate(
            rawIdentifier: peripheral.identifier.uuidString,
            rssi: RSSI.intValue,
            seenAt: Date()
        )
        diagnostic = updated
    }
}
