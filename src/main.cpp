#include <Arduino.h>

#include "dfu_ble.h"

void setup() {
  Serial.begin(115200);
  delay(200);
  Serial.println("[DFU][BOOT] firmware start");
  setupDfuBle();
}

void loop() {
  delay(100);
}