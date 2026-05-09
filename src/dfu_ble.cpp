#include <Arduino.h>
#include <NimBLEDevice.h>
#include <Update.h>

#include "dfu_ble.h"

namespace {

// Nordic Legacy DFU UUIDs used by mobile clients compatible with legacy profile.
constexpr const char* DEVICE_NAME = "ESP32-DFU";
constexpr const char* DFU_SERVICE_UUID = "00001530-1212-EFDE-1523-785FEABCD123";
constexpr const char* DFU_CONTROL_UUID = "00001531-1212-EFDE-1523-785FEABCD123";
constexpr const char* DFU_PACKET_UUID = "00001532-1212-EFDE-1523-785FEABCD123";
constexpr const char* DFU_VERSION_UUID = "00001534-1212-EFDE-1523-785FEABCD123";

constexpr uint8_t OPCODE_START_DFU = 0x01;
constexpr uint8_t OPCODE_INIT_DFU_PARAMS = 0x02;
constexpr uint8_t OPCODE_RECEIVE_FW_IMAGE = 0x03;
constexpr uint8_t OPCODE_VALIDATE = 0x04;
constexpr uint8_t OPCODE_ACTIVATE_N_RESET = 0x05;
constexpr uint8_t OPCODE_RESET = 0x06;
constexpr uint8_t OPCODE_PACKET_RECEIPT_NOTIF_REQ = 0x08;

constexpr uint8_t OPCODE_RESPONSE_CODE = 0x10;
constexpr uint8_t RES_CODE_SUCCESS = 0x01;
constexpr uint8_t RES_CODE_INVALID_STATE = 0x02;
constexpr uint8_t RES_CODE_NOT_SUPPORTED = 0x03;
constexpr uint8_t RES_CODE_OPERATION_FAILED = 0x06;

struct DfuState {
  bool updateBegun = false;
  bool receivingImage = false;
  bool awaitingInitPacket = false;
  bool initPacketReceived = false;
  bool imageWritten = false;
  uint32_t expectedImageSize = 0;
  uint32_t expectedImageCrc32 = 0;
  uint32_t runningImageCrc32 = 0xFFFFFFFF;
  uint32_t receivedImageSize = 0;
  uint16_t packetReceiptInterval = 0;
  uint16_t packetsSinceNotif = 0;
};

DfuState g_dfu;
NimBLECharacteristic* g_controlChr = nullptr;

const char* opcodeToString(uint8_t opcode) {
  switch (opcode) {
    case OPCODE_START_DFU:
      return "START_DFU";
    case OPCODE_INIT_DFU_PARAMS:
      return "INIT_DFU_PARAMS";
    case OPCODE_RECEIVE_FW_IMAGE:
      return "RECEIVE_FW_IMAGE";
    case OPCODE_VALIDATE:
      return "VALIDATE";
    case OPCODE_ACTIVATE_N_RESET:
      return "ACTIVATE_N_RESET";
    case OPCODE_RESET:
      return "RESET";
    case OPCODE_PACKET_RECEIPT_NOTIF_REQ:
      return "PACKET_RECEIPT_NOTIF_REQ";
    default:
      return "UNKNOWN";
  }
}

const char* responseToString(uint8_t status) {
  switch (status) {
    case RES_CODE_SUCCESS:
      return "SUCCESS";
    case RES_CODE_INVALID_STATE:
      return "INVALID_STATE";
    case RES_CODE_NOT_SUPPORTED:
      return "NOT_SUPPORTED";
    case RES_CODE_OPERATION_FAILED:
      return "OPERATION_FAILED";
    default:
      return "UNKNOWN_STATUS";
  }
}

void logReject(const char* context, const char* reason) {
  Serial.print("[DFU][REJECT] ");
  Serial.print(context);
  Serial.print(" -> ");
  Serial.println(reason);
}

void sendResponse(uint8_t requestOpcode, uint8_t status) {
  if (g_controlChr == nullptr) {
    return;
  }

  uint8_t resp[3] = {OPCODE_RESPONSE_CODE, requestOpcode, status};
  g_controlChr->setValue(resp, sizeof(resp));
  g_controlChr->notify();

  Serial.print("[DFU][RESP] opcode=");
  Serial.print(opcodeToString(requestOpcode));
  Serial.print("(0x");
  Serial.print(requestOpcode, HEX);
  Serial.print(") status=");
  Serial.print(responseToString(status));
  Serial.print("(0x");
  Serial.print(status, HEX);
  Serial.println(")");
}

void sendPacketReceiptNotification() {
  if (g_controlChr == nullptr) {
    return;
  }

  uint8_t notif[5];
  notif[0] = 0x11;
  notif[1] = static_cast<uint8_t>(g_dfu.receivedImageSize & 0xFF);
  notif[2] = static_cast<uint8_t>((g_dfu.receivedImageSize >> 8) & 0xFF);
  notif[3] = static_cast<uint8_t>((g_dfu.receivedImageSize >> 16) & 0xFF);
  notif[4] = static_cast<uint8_t>((g_dfu.receivedImageSize >> 24) & 0xFF);
  g_controlChr->setValue(notif, sizeof(notif));
  g_controlChr->notify();
}

uint32_t parseExpectedAppSize(const uint8_t* data, size_t len) {
  if (len >= 13) {
    const size_t appSizeOffset = len - 4;
    return static_cast<uint32_t>(data[appSizeOffset]) |
           (static_cast<uint32_t>(data[appSizeOffset + 1]) << 8) |
           (static_cast<uint32_t>(data[appSizeOffset + 2]) << 16) |
           (static_cast<uint32_t>(data[appSizeOffset + 3]) << 24);
  }

  return UPDATE_SIZE_UNKNOWN;
}

uint32_t crc32Update(uint32_t crc, const uint8_t* data, size_t len) {
  for (size_t i = 0; i < len; ++i) {
    crc ^= data[i];
    for (int bit = 0; bit < 8; ++bit) {
      const bool lsbSet = (crc & 1U) != 0;
      crc >>= 1U;
      if (lsbSet) {
        crc ^= 0xEDB88320U;
      }
    }
  }
  return crc;
}

uint16_t readLe16(const uint8_t* data, size_t offset) {
  return static_cast<uint16_t>(data[offset]) |
         (static_cast<uint16_t>(data[offset + 1]) << 8);
}

uint32_t readLe32(const uint8_t* data, size_t offset) {
  return static_cast<uint32_t>(data[offset]) |
         (static_cast<uint32_t>(data[offset + 1]) << 8) |
         (static_cast<uint32_t>(data[offset + 2]) << 16) |
         (static_cast<uint32_t>(data[offset + 3]) << 24);
}

bool parseInitPacket(const uint8_t* data, size_t len, uint32_t* imageSize, uint32_t* imageCrc) {
  if (len < 8) {
    return false;
  }

  if (len >= 18) {
    const uint16_t softDeviceReqCount = readLe16(data, 8);
    const size_t headerBytes = 10;
    const size_t softDeviceReqBytes = static_cast<size_t>(softDeviceReqCount) * 2;
    const size_t payloadBytes = headerBytes + softDeviceReqBytes + 8;

    if (payloadBytes == len) {
      const size_t tailOffset = len - 8;
      *imageSize = readLe32(data, tailOffset);
      *imageCrc = readLe32(data, tailOffset + 4);
      Serial.print("[DFU][INIT] extended packet len=");
      Serial.print(len);
      Serial.print(" size=");
      Serial.print(*imageSize);
      Serial.print(" crc=0x");
      Serial.println(*imageCrc, HEX);
      return true;
    }
  }

  *imageSize = readLe32(data, 0);
  *imageCrc = readLe32(data, 4);
  Serial.print("[DFU][INIT] compact packet len=");
  Serial.print(len);
  Serial.print(" size=");
  Serial.print(*imageSize);
  Serial.print(" crc=0x");
  Serial.println(*imageCrc, HEX);
  return true;
}

class PacketCallbacks final : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* characteristic) override {
    const std::string value = characteristic->getValue();
    const uint8_t* data = reinterpret_cast<const uint8_t*>(value.data());
    const size_t len = value.size();

    if (len == 0) {
      logReject("PACKET", "empty write");
      return;
    }

    if (g_dfu.awaitingInitPacket) {
      uint32_t initSize = 0;
      uint32_t initCrc = 0;
      if (!parseInitPacket(data, len, &initSize, &initCrc)) {
        logReject("INIT_PACKET", "unable to parse init payload");
        sendResponse(OPCODE_INIT_DFU_PARAMS, RES_CODE_OPERATION_FAILED);
        return;
      }

      g_dfu.expectedImageSize = initSize;
      g_dfu.expectedImageCrc32 = initCrc;
      g_dfu.initPacketReceived = true;
      g_dfu.awaitingInitPacket = false;
      Serial.print("[DFU][STATE] init packet accepted, expectedSize=");
      Serial.print(g_dfu.expectedImageSize);
      Serial.print(" expectedCrc=0x");
      Serial.println(g_dfu.expectedImageCrc32, HEX);
      return;
    }

    if (!g_dfu.updateBegun || !g_dfu.receivingImage) {
      logReject("PACKET", "data arrived outside RECEIVE_FW_IMAGE stage");
      return;
    }

    const size_t written = Update.write(const_cast<uint8_t*>(data), len);
    if (written != len) {
      Serial.print("[DFU][ERROR] Update.write failed, len=");
      Serial.print(len);
      Serial.print(" written=");
      Serial.print(written);
      Serial.print(" updateError=");
      Serial.println(Update.getError());
      sendResponse(OPCODE_RECEIVE_FW_IMAGE, RES_CODE_OPERATION_FAILED);
      return;
    }

    g_dfu.receivedImageSize += static_cast<uint32_t>(written);
    g_dfu.runningImageCrc32 = crc32Update(g_dfu.runningImageCrc32, data, written);
    g_dfu.imageWritten = true;

    if (g_dfu.packetReceiptInterval > 0) {
      g_dfu.packetsSinceNotif++;
      if (g_dfu.packetsSinceNotif >= g_dfu.packetReceiptInterval) {
        g_dfu.packetsSinceNotif = 0;
        sendPacketReceiptNotification();
        Serial.print("[DFU][PRN] bytesReceived=");
        Serial.println(g_dfu.receivedImageSize);
      }
    }
  }
};

class ControlCallbacks final : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* characteristic) override {
    const std::string value = characteristic->getValue();
    const uint8_t* data = reinterpret_cast<const uint8_t*>(value.data());
    const size_t len = value.size();

    if (len == 0) {
      logReject("CONTROL", "empty control write");
      return;
    }

    const uint8_t opcode = data[0];
    Serial.print("[DFU][CTRL] opcode=");
    Serial.print(opcodeToString(opcode));
    Serial.print("(0x");
    Serial.print(opcode, HEX);
    Serial.print(") len=");
    Serial.println(len);

    switch (opcode) {
      case OPCODE_START_DFU: {
        if (g_dfu.updateBegun) {
          Serial.println("[DFU][STATE] previous update session aborted by new START_DFU");
          Update.abort();
        }

        g_dfu.expectedImageSize = parseExpectedAppSize(data, len);
        g_dfu.receivedImageSize = 0;
        g_dfu.receivingImage = false;
        g_dfu.awaitingInitPacket = false;
        g_dfu.initPacketReceived = false;
        g_dfu.imageWritten = false;
        g_dfu.expectedImageCrc32 = 0;
        g_dfu.runningImageCrc32 = 0xFFFFFFFF;
        g_dfu.packetsSinceNotif = 0;

        Serial.print("[DFU][STATE] START_DFU expectedImageSize=");
        Serial.println(g_dfu.expectedImageSize);

        if (!Update.begin(g_dfu.expectedImageSize)) {
          g_dfu.updateBegun = false;
          Serial.print("[DFU][ERROR] Update.begin failed, updateError=");
          Serial.println(Update.getError());
          sendResponse(OPCODE_START_DFU, RES_CODE_OPERATION_FAILED);
          return;
        }

        g_dfu.updateBegun = true;
        sendResponse(OPCODE_START_DFU, RES_CODE_SUCCESS);
        break;
      }

      case OPCODE_INIT_DFU_PARAMS: {
        if (!g_dfu.updateBegun) {
          logReject("INIT_DFU_PARAMS", "session not started");
          sendResponse(OPCODE_INIT_DFU_PARAMS, RES_CODE_INVALID_STATE);
          return;
        }

        if (len < 2) {
          logReject("INIT_DFU_PARAMS", "missing mode byte");
          sendResponse(OPCODE_INIT_DFU_PARAMS, RES_CODE_NOT_SUPPORTED);
          return;
        }

        const uint8_t mode = data[1];
        if (mode == 0x00) {
          g_dfu.awaitingInitPacket = true;
          g_dfu.initPacketReceived = false;
          Serial.println("[DFU][STATE] expecting init packet data in PACKET char");
          sendResponse(OPCODE_INIT_DFU_PARAMS, RES_CODE_SUCCESS);
        } else if (mode == 0x01) {
          if (!g_dfu.initPacketReceived) {
            logReject("INIT_DFU_PARAMS", "INIT complete requested before init packet write");
            sendResponse(OPCODE_INIT_DFU_PARAMS, RES_CODE_INVALID_STATE);
            return;
          }
          g_dfu.awaitingInitPacket = false;
          Serial.println("[DFU][STATE] init phase completed");
          sendResponse(OPCODE_INIT_DFU_PARAMS, RES_CODE_SUCCESS);
        } else {
          logReject("INIT_DFU_PARAMS", "unsupported mode");
          sendResponse(OPCODE_INIT_DFU_PARAMS, RES_CODE_NOT_SUPPORTED);
        }
        break;
      }

      case OPCODE_RECEIVE_FW_IMAGE: {
        if (!g_dfu.updateBegun) {
          logReject("RECEIVE_FW_IMAGE", "session not started");
          sendResponse(OPCODE_RECEIVE_FW_IMAGE, RES_CODE_INVALID_STATE);
          return;
        }
        g_dfu.receivingImage = true;
        Serial.println("[DFU][STATE] firmware data transfer started");
        sendResponse(OPCODE_RECEIVE_FW_IMAGE, RES_CODE_SUCCESS);
        break;
      }

      case OPCODE_PACKET_RECEIPT_NOTIF_REQ: {
        if (len < 3) {
          logReject("PACKET_RECEIPT_NOTIF_REQ", "payload too short");
          sendResponse(OPCODE_PACKET_RECEIPT_NOTIF_REQ, RES_CODE_NOT_SUPPORTED);
          return;
        }

        g_dfu.packetReceiptInterval =
            static_cast<uint16_t>(data[1]) | (static_cast<uint16_t>(data[2]) << 8);
        g_dfu.packetsSinceNotif = 0;
        Serial.print("[DFU][STATE] PRN interval=");
        Serial.println(g_dfu.packetReceiptInterval);
        sendResponse(OPCODE_PACKET_RECEIPT_NOTIF_REQ, RES_CODE_SUCCESS);
        break;
      }

      case OPCODE_VALIDATE: {
        if (!g_dfu.updateBegun || !g_dfu.imageWritten) {
          logReject("VALIDATE", "no active image buffer");
          sendResponse(OPCODE_VALIDATE, RES_CODE_INVALID_STATE);
          return;
        }

        if (!g_dfu.initPacketReceived) {
          logReject("VALIDATE", "init packet missing");
          sendResponse(OPCODE_VALIDATE, RES_CODE_INVALID_STATE);
          return;
        }

        if (g_dfu.expectedImageSize != UPDATE_SIZE_UNKNOWN &&
            g_dfu.expectedImageSize != g_dfu.receivedImageSize) {
          Serial.print("[DFU][REJECT] VALIDATE -> size mismatch expected=");
          Serial.print(g_dfu.expectedImageSize);
          Serial.print(" actual=");
          Serial.println(g_dfu.receivedImageSize);
          sendResponse(OPCODE_VALIDATE, RES_CODE_OPERATION_FAILED);
          return;
        }

        const uint32_t finalCrc = ~g_dfu.runningImageCrc32;
        if (g_dfu.expectedImageCrc32 != 0 && g_dfu.expectedImageCrc32 != finalCrc) {
          Serial.print("[DFU][REJECT] VALIDATE -> crc mismatch expected=0x");
          Serial.print(g_dfu.expectedImageCrc32, HEX);
          Serial.print(" actual=0x");
          Serial.println(finalCrc, HEX);
          sendResponse(OPCODE_VALIDATE, RES_CODE_OPERATION_FAILED);
          return;
        }

        Serial.print("[DFU][STATE] VALIDATE ok size=");
        Serial.print(g_dfu.receivedImageSize);
        Serial.print(" crc=0x");
        Serial.println(finalCrc, HEX);

        g_dfu.receivingImage = false;
        if (!Update.end(true)) {
          Serial.print("[DFU][ERROR] Update.end failed, updateError=");
          Serial.println(Update.getError());
          sendResponse(OPCODE_VALIDATE, RES_CODE_OPERATION_FAILED);
          return;
        }

        g_dfu.updateBegun = false;
        Serial.println("[DFU][STATE] image committed to OTA partition");
        sendResponse(OPCODE_VALIDATE, RES_CODE_SUCCESS);
        break;
      }

      case OPCODE_ACTIVATE_N_RESET: {
        Serial.println("[DFU][STATE] activate and reset requested");
        sendResponse(OPCODE_ACTIVATE_N_RESET, RES_CODE_SUCCESS);
        delay(200);
        ESP.restart();
        break;
      }

      case OPCODE_RESET: {
        Serial.println("[DFU][STATE] reset requested");
        sendResponse(OPCODE_RESET, RES_CODE_SUCCESS);
        delay(200);
        ESP.restart();
        break;
      }

      default:
        logReject("CONTROL", "unknown opcode");
        sendResponse(opcode, RES_CODE_NOT_SUPPORTED);
        break;
    }
  }
};

class ServerCallbacks final : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* server) override {
    (void)server;
    Serial.println("[DFU][BLE] client connected");
  }

  void onDisconnect(NimBLEServer* server) override {
    (void)server;
    Serial.println("[DFU][BLE] client disconnected, advertising restarted");
    NimBLEDevice::startAdvertising();
    g_dfu.receivingImage = false;
    g_dfu.awaitingInitPacket = false;
    g_dfu.packetsSinceNotif = 0;
  }
};

}  // namespace

void setupDfuBle() {
  NimBLEDevice::init(DEVICE_NAME);
  NimBLEDevice::setMTU(247);
  Serial.print("[DFU][BOOT] BLE DFU init, device=");
  Serial.println(DEVICE_NAME);

  NimBLEServer* server = NimBLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  NimBLEService* service = server->createService(DFU_SERVICE_UUID);

  g_controlChr = service->createCharacteristic(
      DFU_CONTROL_UUID,
      NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::NOTIFY);
  g_controlChr->setCallbacks(new ControlCallbacks());

  NimBLECharacteristic* packetChr = service->createCharacteristic(
      DFU_PACKET_UUID,
      NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  packetChr->setCallbacks(new PacketCallbacks());

  NimBLECharacteristic* versionChr = service->createCharacteristic(
      DFU_VERSION_UUID,
      NIMBLE_PROPERTY::READ);
  const uint8_t version[2] = {0x08, 0x00};
  versionChr->setValue(version, sizeof(version));

  service->start();
  Serial.println("[DFU][BOOT] DFU service started");

  NimBLEAdvertising* advertising = NimBLEDevice::getAdvertising();
  advertising->addServiceUUID(DFU_SERVICE_UUID);
  advertising->setScanResponse(true);
  advertising->start();
  Serial.println("[DFU][BOOT] advertising started");
}
