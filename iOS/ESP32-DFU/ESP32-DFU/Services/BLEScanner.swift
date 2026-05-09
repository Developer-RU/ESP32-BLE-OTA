import CoreBluetooth
import Foundation

@MainActor
final class BLEScanner: NSObject, ObservableObject {
    private static let dfuServiceUUID = CBUUID(string: "00001530-1212-EFDE-1523-785FEABCD123")
    private static let defaultScanDuration: TimeInterval = 12

    @Published var devices: [BLEDevice] = []
    @Published var isScanning = false
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var scanSecondsRemaining: Int?

    var onScanTimeout: (() -> Void)?

    private var centralManager: CBCentralManager!
    private var scanTimeoutTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    private var scanDeadline: Date?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScanning() {
        startScanning(duration: BLEScanner.defaultScanDuration)
    }

    func startScanning(duration: TimeInterval) {
        guard centralManager.state == .poweredOn else { return }
        scanTimeoutTask?.cancel()
        countdownTask?.cancel()
        stopScanning()
        devices.removeAll()
        isScanning = true
        scanDeadline = Date().addingTimeInterval(duration)
        scanSecondsRemaining = max(1, Int(ceil(duration)))
        centralManager.scanForPeripherals(
            withServices: [Self.dfuServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        countdownTask = Task { @MainActor in
            while self.isScanning {
                guard let deadline = self.scanDeadline else { break }
                let remaining = max(0, Int(ceil(deadline.timeIntervalSinceNow)))
                self.scanSecondsRemaining = remaining
                if remaining == 0 { break }

                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
            }
        }

        scanTimeoutTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            } catch {
                return
            }

            if self.isScanning {
                self.stopScanning()
                self.onScanTimeout?()
            }
        }
    }

    func stopScanning() {
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        scanDeadline = nil
        scanSecondsRemaining = nil
        isScanning = false
        centralManager.stopScan()
    }

    private func upsertDevice(_ peripheral: CBPeripheral, rssi: NSNumber) {
        let name = peripheral.name ?? ""
        let candidate = BLEDevice(identifier: peripheral.identifier, name: name, rssi: rssi.intValue)
        if let idx = devices.firstIndex(where: { $0.identifier == peripheral.identifier }) {
            devices[idx] = candidate
        } else {
            devices.append(candidate)
        }
        devices.sort { $0.rssi > $1.rssi }
    }
}

extension BLEScanner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            self.bluetoothState = central.state
            if central.state != .poweredOn {
                self.stopScanning()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        Task { @MainActor in
            if let deadline = self.scanDeadline, Date() >= deadline {
                self.stopScanning()
                self.onScanTimeout?()
                return
            }
            self.upsertDevice(peripheral, rssi: RSSI)
        }
    }
}
