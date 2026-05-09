import CoreBluetooth
import Foundation
import UIKit
import zlib

@MainActor
final class DFUSessionManager: NSObject, ObservableObject {
    struct Settings {
        var packetReceiptNotification: Int = 12
        var preferredMTU: Int = 247
        var scanDurationSeconds: Int = 12
        var autoReconnect: Bool = true
        var keepScreenAwake: Bool = true
    }

    @Published var scanner = BLEScanner()
    @Published var selectedDevice: BLEDevice?
    @Published var selectedFirmwareURL: URL?
    @Published var currentStage: DFUStage = .idle
    @Published var progress: Double = 0
    @Published var stageMessage = L("msg.select_device_file")
    @Published var isRunning = false {
        didSet { applyRuntimeSettings() }
    }
    @Published var settings = Settings() {
        didSet { applyRuntimeSettings() }
    }

    private static let dfuServiceUUID = CBUUID(string: "00001530-1212-EFDE-1523-785FEABCD123")
    private static let dfuControlUUID = CBUUID(string: "00001531-1212-EFDE-1523-785FEABCD123")
    private static let dfuPacketUUID = CBUUID(string: "00001532-1212-EFDE-1523-785FEABCD123")
    private static let restoreIdentifier = "com.pavelmasyukov.esp32dfu.central.restore"

    private enum Opcode {
        static let startDfu: UInt8 = 0x01
        static let initParams: UInt8 = 0x02
        static let receiveFw: UInt8 = 0x03
        static let validate: UInt8 = 0x04
        static let activateAndReset: UInt8 = 0x05
        static let packetReceiptNotifReq: UInt8 = 0x08
        static let responseCode: UInt8 = 0x10
        static let packetReceiptNotif: UInt8 = 0x11
    }

    private enum DFUError: Error {
        case bluetoothUnavailable
        case invalidSelection
        case unableToReadFirmware
        case peripheralNotFound
        case serviceNotFound
        case characteristicsNotFound
        case disconnected
        case timeout
        case badResponse
        case cancelled
    }

    private var centralManager: CBCentralManager!
    private var activePeripheral: CBPeripheral?
    private var controlCharacteristic: CBCharacteristic?
    private var packetCharacteristic: CBCharacteristic?

    private var dfuTask: Task<Void, Never>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var controlResponseContinuation: CheckedContinuation<[UInt8], Error>?
    private var pendingControlResponses: [[UInt8]] = []
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var discoverContinuation: CheckedContinuation<Void, Error>?
    private var scanTargetContinuation: CheckedContinuation<CBPeripheral, Error>?

    private var targetDeviceIdentifier: UUID?
    private var targetFirmwareData = Data()
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 3
    private var isCancelling = false

    override init() {
        super.init()
        scanner.onScanTimeout = { [weak self] in
            guard let self else { return }
            if !self.isRunning {
                self.currentStage = .idle
                self.stageMessage = L("msg.scan_finished_found", self.scanner.devices.count)
            }
        }

        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )

        applyRuntimeSettings()
    }

    func selectDevice(_ device: BLEDevice) {
        selectedDevice = device
    }

    func selectFirmware(url: URL) {
        selectedFirmwareURL = url
    }

    func startScan() {
        currentStage = .scanning
        stageMessage = L("msg.scan_in_progress", settings.scanDurationSeconds)
        scanner.startScanning(duration: TimeInterval(settings.scanDurationSeconds))
    }

    func stopScan() {
        scanner.stopScanning()
        if !isRunning {
            currentStage = .idle
            stageMessage = DFUStage.idle.details
        }
    }

    func refreshLocalization() {
        if isRunning {
            if currentStage == .scanning {
                stageMessage = L("msg.scan_in_progress", settings.scanDurationSeconds)
            } else {
                stageMessage = currentStage.details
            }
            return
        }

        switch currentStage {
        case .idle:
            stageMessage = L("msg.select_device_file")
        case .failed:
            stageMessage = currentStage.details
        default:
            stageMessage = currentStage.details
        }
    }

    func startDFU() {
        guard !isRunning else { return }
        guard let selectedDevice,
              let selectedFirmwareURL else {
            currentStage = .failed
            stageMessage = L("msg.need_device_and_firmware")
            return
        }

        guard centralManager.state == .poweredOn else {
            currentStage = .failed
            stageMessage = L("msg.bluetooth_unavailable")
            return
        }

        do {
            targetFirmwareData = try readFirmwareData(from: selectedFirmwareURL)
            if targetFirmwareData.isEmpty {
                throw DFUError.unableToReadFirmware
            }
        } catch {
            currentStage = .failed
            stageMessage = L("msg.unable_open_firmware", error.localizedDescription)
            return
        }

        targetDeviceIdentifier = selectedDevice.identifier

        isRunning = true
        progress = 0
        reconnectAttempts = 0
        isCancelling = false

        dfuTask = Task {
            await runDfuWorkflow()
        }
    }

    func cancelDFU() {
        isCancelling = true
        dfuTask?.cancel()
        dfuTask = nil
        disconnectCurrentPeripheral()
        resumePendingWith(error: DFUError.cancelled)
        isRunning = false
        progress = 0
        currentStage = .failed
        stageMessage = L("msg.cancelled")
    }

    private func runDfuWorkflow() async {
        do {
            try await performDfuSequence()
            currentStage = .completed
            stageMessage = DFUStage.completed.details
            progress = 1
            isRunning = false
            disconnectCurrentPeripheral()
        } catch {
            guard !Task.isCancelled, !isCancelling else { return }

            if settings.autoReconnect, reconnectAttempts < maxReconnectAttempts {
                reconnectAttempts += 1
                currentStage = .connecting
                stageMessage = L("msg.ble_retry", reconnectAttempts, maxReconnectAttempts)
                progress = 0.03
                disconnectCurrentPeripheral()
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }

                if !Task.isCancelled {
                    await runDfuWorkflow()
                }
                return
            }

            currentStage = .failed
            stageMessage = L("msg.dfu_error", error.localizedDescription)
            isRunning = false
            disconnectCurrentPeripheral()
        }
    }

    private func performDfuSequence() async throws {
        guard let target = targetDeviceIdentifier, !targetFirmwareData.isEmpty else {
            throw DFUError.invalidSelection
        }

        try Task.checkCancellation()
        currentStage = .connecting
        stageMessage = DFUStage.connecting.details
        progress = 0.05

        let peripheral = try await findPeripheral(for: target)
        try await connect(peripheral)
        try await discoverDfuCharacteristics(peripheral)

        try await setNotifyOnControlCharacteristic()

        currentStage = .bootloaderUpload
        stageMessage = DFUStage.bootloaderUpload.details
        progress = 0.18

        try await writeControl([Opcode.packetReceiptNotifReq, UInt8(settings.packetReceiptNotification & 0xFF), UInt8((settings.packetReceiptNotification >> 8) & 0xFF)])
        _ = try await waitForResponse(to: Opcode.packetReceiptNotifReq)

        let appSize = UInt32(targetFirmwareData.count)
        var startCommand: [UInt8] = [Opcode.startDfu, 0x04]
        startCommand += [0, 0, 0, 0] // SoftDevice size
        startCommand += [0, 0, 0, 0] // Bootloader size
        startCommand += littleEndianBytes(of: appSize)
        try await writeControl(startCommand)
        _ = try await waitForResponse(to: Opcode.startDfu)

        currentStage = .initPacket
        stageMessage = DFUStage.initPacket.details
        progress = 0.28

        try await writeControl([Opcode.initParams, 0x00])
        _ = try await waitForResponse(to: Opcode.initParams)

        try await writePacket(buildInitPacket(for: targetFirmwareData))

        try await writeControl([Opcode.initParams, 0x01])
        _ = try await waitForResponse(to: Opcode.initParams)

        currentStage = .firmwareUpload
        stageMessage = DFUStage.firmwareUpload.details
        progress = 0.30

        try await writeControl([Opcode.receiveFw])
        _ = try await waitForResponse(to: Opcode.receiveFw)

        try await uploadFirmware()

        currentStage = .validating
        stageMessage = DFUStage.validating.details
        progress = 0.9
        try await writeControl([Opcode.validate])
        _ = try await waitForResponse(to: Opcode.validate)

        currentStage = .activating
        stageMessage = DFUStage.activating.details
        progress = 0.97
        try await writeControl([Opcode.activateAndReset])
    }

    private func findPeripheral(for identifier: UUID) async throws -> CBPeripheral {
        let known = centralManager.retrievePeripherals(withIdentifiers: [identifier])
        if let p = known.first {
            return p
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CBPeripheral, Error>) in
            scanTargetContinuation = continuation
            centralManager.scanForPeripherals(withServices: [Self.dfuServiceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    private func connect(_ peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            activePeripheral = peripheral
            peripheral.delegate = self
            centralManager.connect(peripheral, options: nil)
        }
    }

    private func discoverDfuCharacteristics(_ peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            discoverContinuation = continuation
            peripheral.discoverServices([Self.dfuServiceUUID])
        }
    }

    private func setNotifyOnControlCharacteristic() async throws {
        guard let peripheral = activePeripheral, let controlCharacteristic else {
            throw DFUError.characteristicsNotFound
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeContinuation = continuation
            peripheral.setNotifyValue(true, for: controlCharacteristic)
        }
    }

    private func writeControl(_ bytes: [UInt8]) async throws {
        guard let peripheral = activePeripheral, let controlCharacteristic else {
            throw DFUError.characteristicsNotFound
        }
        try await write(Data(bytes), on: controlCharacteristic, peripheral: peripheral)
    }

    private func writePacket(_ data: Data) async throws {
        guard let peripheral = activePeripheral, let packetCharacteristic else {
            throw DFUError.characteristicsNotFound
        }
        try await write(data, on: packetCharacteristic, peripheral: peripheral)
    }

    private func write(_ data: Data, on characteristic: CBCharacteristic, peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeContinuation = continuation
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    private func waitForResponse(to opcode: UInt8) async throws -> [UInt8] {
        try await withThrowingTimeout(seconds: 8) {
            if let buffered = self.dequeueMatchingResponse(for: opcode) {
                return buffered
            }

            let bytes = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
                self.controlResponseContinuation = continuation
            }

            guard bytes.count >= 3, bytes[0] == Opcode.responseCode, bytes[1] == opcode else {
                throw DFUError.badResponse
            }

            guard bytes[2] == 0x01 else {
                throw DFUError.badResponse
            }

            return bytes
        }
    }

    private func uploadFirmware() async throws {
        let bytes = [UInt8](targetFirmwareData)
        guard !bytes.isEmpty else {
            throw DFUError.invalidSelection
        }

        let chunkSize = max(20, min(180, settings.preferredMTU - 3))
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let end = min(offset + chunkSize, bytes.count)
            let chunk = Data(bytes[offset..<end])
            try await writePacket(chunk)
            offset = end
            progress = 0.30 + (0.48 * (Double(offset) / Double(bytes.count)))
        }
    }

    private func disconnectCurrentPeripheral() {
        if let activePeripheral, activePeripheral.state == .connected || activePeripheral.state == .connecting {
            centralManager.cancelPeripheralConnection(activePeripheral)
        }
        activePeripheral = nil
        controlCharacteristic = nil
        packetCharacteristic = nil
    }

    private func resumePendingWith(error: Error) {
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        discoverContinuation?.resume(throwing: error)
        discoverContinuation = nil
        writeContinuation?.resume(throwing: error)
        writeContinuation = nil
        controlResponseContinuation?.resume(throwing: error)
        controlResponseContinuation = nil
        pendingControlResponses.removeAll()
        scanTargetContinuation?.resume(throwing: error)
        scanTargetContinuation = nil
    }

    private func dequeueMatchingResponse(for opcode: UInt8) -> [UInt8]? {
        guard let index = pendingControlResponses.firstIndex(where: {
            $0.count >= 3 && $0[0] == Opcode.responseCode && $0[1] == opcode
        }) else {
            return nil
        }

        return pendingControlResponses.remove(at: index)
    }

    private func littleEndianBytes(of value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ]
    }

    private func littleEndianBytes16(of value: UInt16) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF)
        ]
    }

    private func buildInitPacket(for data: Data) -> Data {
        var crc = crc32(0, nil, 0)
        data.withUnsafeBytes { ptr in
            if let base = ptr.bindMemory(to: Bytef.self).baseAddress {
                crc = crc32(crc, base, uInt(data.count))
            }
        }

        let deviceType: UInt16 = 0x0052
        let deviceRevision: UInt16 = 0x0001
        let applicationVersion: UInt32 = 0x00010000
        let softDeviceReq: [UInt16] = [0x0000]

        var payload = Data()
        payload.append(contentsOf: littleEndianBytes16(of: deviceType))
        payload.append(contentsOf: littleEndianBytes16(of: deviceRevision))
        payload.append(contentsOf: littleEndianBytes(of: applicationVersion))
        payload.append(contentsOf: littleEndianBytes16(of: UInt16(softDeviceReq.count)))
        for req in softDeviceReq {
            payload.append(contentsOf: littleEndianBytes16(of: req))
        }
        payload.append(contentsOf: littleEndianBytes(of: UInt32(data.count)))
        payload.append(contentsOf: littleEndianBytes(of: UInt32(truncatingIfNeeded: crc)))
        return payload
    }

    private func readFirmwareData(from url: URL) throws -> Data {
        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if FileManager.default.isUbiquitousItem(at: url) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }

        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func withThrowingTimeout<T>(seconds: TimeInterval, operation: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DFUError.timeout
            }

            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }

    private func applyRuntimeSettings() {
        UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake && isRunning
    }
}

extension DFUSessionManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state != .poweredOn, self.isRunning {
                self.resumePendingWith(error: DFUError.bluetoothUnavailable)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    willRestoreState dict: [String: Any]) {
        Task { @MainActor in
            guard self.isRunning else { return }
            if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
               let restored = peripherals.first {
                self.activePeripheral = restored
                restored.delegate = self
                self.centralManager.connect(restored, options: nil)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        Task { @MainActor in
            guard let target = self.targetDeviceIdentifier,
                  peripheral.identifier == target else {
                return
            }
            central.stopScan()
            self.scanTargetContinuation?.resume(returning: peripheral)
            self.scanTargetContinuation = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.connectContinuation?.resume(returning: ())
            self.connectContinuation = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.connectContinuation?.resume(throwing: error ?? DFUError.disconnected)
            self.connectContinuation = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            guard self.activePeripheral?.identifier == peripheral.identifier else { return }
            if self.isRunning && !self.isCancelling {
                self.resumePendingWith(error: error ?? DFUError.disconnected)
            }
        }
    }
}

extension DFUSessionManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                self.discoverContinuation?.resume(throwing: error)
                self.discoverContinuation = nil
                return
            }

            guard let service = peripheral.services?.first(where: { $0.uuid == Self.dfuServiceUUID }) else {
                self.discoverContinuation?.resume(throwing: DFUError.serviceNotFound)
                self.discoverContinuation = nil
                return
            }

            peripheral.discoverCharacteristics([Self.dfuControlUUID, Self.dfuPacketUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                self.discoverContinuation?.resume(throwing: error)
                self.discoverContinuation = nil
                return
            }

            guard let characteristics = service.characteristics else {
                self.discoverContinuation?.resume(throwing: DFUError.characteristicsNotFound)
                self.discoverContinuation = nil
                return
            }

            self.controlCharacteristic = characteristics.first(where: { $0.uuid == Self.dfuControlUUID })
            self.packetCharacteristic = characteristics.first(where: { $0.uuid == Self.dfuPacketUUID })

            guard self.controlCharacteristic != nil, self.packetCharacteristic != nil else {
                self.discoverContinuation?.resume(throwing: DFUError.characteristicsNotFound)
                self.discoverContinuation = nil
                return
            }

            self.discoverContinuation?.resume(returning: ())
            self.discoverContinuation = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                self.writeContinuation?.resume(throwing: error)
                self.writeContinuation = nil
                return
            }

            self.writeContinuation?.resume(returning: ())
            self.writeContinuation = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                self.writeContinuation?.resume(throwing: error)
                self.writeContinuation = nil
                return
            }

            self.writeContinuation?.resume(returning: ())
            self.writeContinuation = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                self.controlResponseContinuation?.resume(throwing: error)
                self.controlResponseContinuation = nil
                return
            }

            guard characteristic.uuid == Self.dfuControlUUID,
                  let value = characteristic.value,
                  !value.isEmpty else {
                return
            }

            let bytes = [UInt8](value)
            if bytes.first == Opcode.packetReceiptNotif {
                return
            }

            if let continuation = self.controlResponseContinuation {
                continuation.resume(returning: bytes)
                self.controlResponseContinuation = nil
            } else {
                self.pendingControlResponses.append(bytes)
            }
        }
    }
}
