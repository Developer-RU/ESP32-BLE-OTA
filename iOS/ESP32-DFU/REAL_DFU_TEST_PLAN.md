# Real DFU Test Plan (ESP32 + iOS)

## Goal

Validate stable and repeatable BLE DFU updates from iOS app to ESP32 firmware target.

## Preconditions

- ESP32 is flashed with BLE DFU firmware.
- iOS app has Bluetooth permissions granted.
- Known-good firmware binary is available.
- Device battery and phone battery are above safe thresholds.

## Test Cases

1. Happy path update
- Discover device
- Select valid firmware
- Complete update to 100%
- Verify reboot and new firmware behavior

2. Wrong file handling
- Select invalid/non-firmware file
- Verify graceful error handling and no crash

3. Interrupted transfer
- Move out of BLE range during transfer
- Verify timeout/failure handling and ability to retry

4. Cancellation
- Start update and cancel mid-transfer
- Verify progress reset and consistent state recovery

5. Reconnect and retry
- After failure, reconnect and rerun update
- Verify successful completion

6. Multiple sequential updates
- Run several updates in a row
- Verify no memory growth symptoms and stable behavior

## Pass Criteria

- No app crashes
- Deterministic stage transitions
- Correct success/failure reporting
- Firmware boots after successful update

## Logging Recommendations

- Capture serial logs from ESP32
- Capture iOS debug logs for BLE and DFU states
- Keep timestamps for correlation of events
