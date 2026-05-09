# ESP32 BLE Legacy DFU Template

Production-ready ESP32 firmware template for OTA updates over **Bluetooth Low Energy (BLE)** using the **Nordic Legacy DFU profile**.

This repository focuses on the ESP32 firmware side.
The companion iOS app is maintained as a separate app/repository and is only included here as a development reference under `iOS/ESP32-DFU`.

## What This Template Provides

- BLE DFU service compatible with Nordic Legacy DFU UUID set.
- Dual-slot OTA partition layout for safer updates.
- Firmware streaming through DFU Packet characteristic.
- Pre-commit validation by image size and CRC32 before activation.
- Packet Receipt Notification (PRN) support.
- Verbose serial diagnostics for protocol-level debugging.
- Clean modular structure for long-term maintainability.

## BLE Stack Overview

- BLE library: `NimBLE-Arduino`
- Role: GATT server on ESP32
- Service UUID: `00001530-1212-EFDE-1523-785FEABCD123`
- Characteristics:
  - Control Point (`1531`): command/response path
  - Packet (`1532`): firmware and init payload stream
  - Version (`1534`): DFU protocol version information

### Supported Legacy DFU Opcodes

- `0x01` Start DFU
- `0x02` Init DFU Parameters
- `0x03` Receive Firmware Image
- `0x04` Validate
- `0x05` Activate and Reset
- `0x06` Reset
- `0x08` Packet Receipt Notification Request

### Validation Logic

Before finalizing an update, firmware validates:

- expected image size (if provided)
- expected CRC32 (if provided in init packet)

Only after validation passes, `Update.end(true)` is called and new image is committed.

## Project Structure

- `platformio.ini` — PlatformIO environment and dependencies.
- `partitions_ota.csv` — OTA partition table with `otadata`, `app0`, `app1`, `spiffs`, `coredump`.
- `src/main.cpp` — firmware entrypoint (`setup()` / `loop()`).
- `src/dfu_ble.h` — DFU module public interface.
- `src/dfu_ble.cpp` — DFU BLE protocol implementation and OTA flow.

## OTA Partition Strategy

Template uses dual app slots:

- active app runs from one slot
- incoming firmware is written to the inactive slot
- boot metadata in `otadata` switches active slot only after successful validation

This minimizes risk of bricking during interrupted updates.

## Requirements

- ESP32 board supported by `espressif32` PlatformIO platform
- PlatformIO Core (CLI or VS Code extension)
- BLE DFU client (mobile app or custom client implementing Legacy DFU flow)

## Quick Start

1. Clone repository.
2. Open the folder in VS Code with PlatformIO extension.
3. Build firmware:

```bash
pio run
```

4. Flash firmware:

```bash
pio run -t upload
```

5. Open serial monitor:

```bash
pio device monitor
```

## Typical Update Flow (Client Side)

1. Connect to ESP32 DFU peripheral.
2. `Start DFU` with expected app size.
3. `Init DFU Params` start, send init payload, then complete init.
4. `Receive FW Image`, stream binary in chunks.
5. `Validate` and confirm success response.
6. `Activate and Reset`.

## Example Integrations

- iOS app (SwiftUI + CoreBluetooth) acting as Legacy DFU client.
- Android app with BLE GATT write/notify implementation.
- Desktop updater script using BLE library and custom opcode sequence.

## Naming and Style Conventions

- Keep protocol constants explicit and close to implementation.
- Use structured serial prefixes (`[DFU][STATE]`, `[DFU][ERROR]`) for fast log filtering.
- Keep `main.cpp` minimal; place protocol logic in dedicated modules.
- Prefer deterministic state transitions over implicit side effects.

## Troubleshooting

- Build fails for missing deps:
  - run `pio pkg update`
- Device not visible in scanner:
  - verify BLE advertising started in serial log
- Validate fails:
  - check expected size/CRC in init packet versus transmitted image
- OTA boot issues:
  - confirm partition table is exactly `partitions_ota.csv`

## Security Notes

This template implements protocol-level integrity checks (size and CRC32), but does not include cryptographic signature verification by default.
For production deployments, add signed artifacts and authenticity checks in bootloader or app-level policy.

## Separate Mobile App Publication

For releases, publish the mobile DFU client as a separate app/repository with its own versioning, signing, and release notes.
Keep this repository focused on firmware template quality and embedded protocol behavior.

## License

Add your preferred license before publishing (for example, MIT or Apache-2.0).
