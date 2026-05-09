# ESP32-DFU iOS Client

SwiftUI iPhone application for BLE DFU firmware updates of ESP32 devices using the Legacy DFU profile.

## Implemented

- BLE device discovery and selection
- Firmware file selection (binary image)
- DFU progress tracking
- Stage timeline for the update pipeline
- Cancellation and retry behavior
- Localization and settings screen

## Main Stack

- SwiftUI (UI)
- CoreBluetooth (BLE transport)
- Background restoration for more resilient sessions

## Typical Flow

1. Scan and select target ESP32 DFU device.
2. Select firmware binary file.
3. Start DFU session.
4. Wait for transfer, validation, and activation.
5. Observe completion or error diagnostics.

## Notes

This app is intended as a companion client for the firmware project in the repository root.
For production releases, publish mobile client and firmware as separate versioned artifacts.
