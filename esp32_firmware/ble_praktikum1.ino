#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <DHT.h>

#define LED_PIN 26
#define DHT_PIN 4
#define DHT_TYPE DHT22 // Ganti DHT11 jika memakai DHT11[cite: 6]

#define SERVICE_UUID "12345678-1234-5678-1234-56789abcdef0"
#define LED_UUID     "12345678-1234-5678-1234-56789abcdef1"
#define SENSOR_UUID  "12345678-1234-5678-1234-56789abcdef2"

DHT dht(DHT_PIN, DHT_TYPE);
BLECharacteristic *sensorChar;
bool deviceConnected = false;
unsigned long lastSend = 0;

class ServerCb: public BLEServerCallbacks {
  void onConnect(BLEServer *s) {
    deviceConnected = true;
    Serial.println("BLE: client terhubung");
  }
  void onDisconnect(BLEServer *s) {
    deviceConnected = false;
    Serial.println("BLE: client terputus");
    BLEDevice::startAdvertising(); // Agar bisa dihubungi lagi[cite: 7]
  }
};

class LedCb: public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) {
    auto v = c->getValue();
    if (v.length() > 0) {
      bool on = (v[0] == 1 || v[0] == '1');
      digitalWrite(LED_PIN, on ? HIGH : LOW);
      Serial.printf("LED -> %s\n", on ? "ON" : "OFF");
    }
  }
};

void setup() {
  Serial.begin(115200);
  pinMode(LED_PIN, OUTPUT);
  dht.begin();

  BLEDevice::init("ESP32-OIT-KEL5");
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCb());

  BLEService *service = server->createService(SERVICE_UUID);

  BLECharacteristic *ledChar = service->createCharacteristic(
    LED_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE
  );
  ledChar->setCallbacks(new LedCb());

  sensorChar = service->createCharacteristic(
    SENSOR_UUID,
    BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  sensorChar->addDescriptor(new BLE2902());

  service->start();

  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();
  Serial.println("BLE advertising: ESP32-OIT-KEL1 siap ditemukan");
}

void loop() {
  if (deviceConnected && millis() - lastSend >= 2000) {
    lastSend = millis();
    float t = dht.readTemperature();
    float h = dht.readHumidity();

    if (!isnan(t) && !isnan(h)) {
      char buf[24];
      snprintf(buf, sizeof(buf), "%.1f;%.1f", t, h);
      sensorChar->setValue((uint8_t *)buf, strlen(buf));
      sensorChar->notify();
      Serial.printf("Notify: %s\n", buf);
    }
  }
}