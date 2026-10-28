#include <WiFi.h>
#include <PubSubClient.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <DHT.h>

#define LED_PIN 26
#define DHT_PIN 4
#define DHT_TYPE DHT22
#define TEMP_THRESHOLD 30.0 // Batas suhu untuk alarm tugas pengembangan

const char *WIFI_SSID = "NAMA_WIFI";
const char *WIFI_PASS = "PASSWORD_WIFI";
const char *MQTT_HOST = "broker.emqx.io";
const int   MQTT_PORT = 1883;
const char *KELOMPOK  = "kel1";
const char *BLE_NAME  = "ESP32-OIT-KEL1";

#define SERVICE_UUID "12345678-1234-5678-1234-56789abcdef0"
#define LED_UUID     "12345678-1234-5678-1234-56789abcdef1"
#define SENSOR_UUID  "12345678-1234-5678-1234-56789abcdef2"

char tSensor[64], tLed[64], tLedState[64], tStatus[64], tAlarm[64];
DHT dht(DHT_PIN, DHT_TYPE);
WiFiClient wifiClient;
PubSubClient mqtt(wifiClient);
BLECharacteristic *ledChar, *sensorChar;
bool bleConnected = false;
bool ledState = false;
volatile int pendingLed = -1; 
unsigned long lastSend = 0, lastRetry = 0;

void applyLed(bool on) {
  ledState = on;
  digitalWrite(LED_PIN, on ? HIGH : LOW);
  uint8_t v = on ? 1 : 0;
  if (ledChar != nullptr) ledChar->setValue(&v, 1); 
  if (mqtt.connected()) mqtt.publish(tLedState, on ? "ON" : "OFF", true);
  Serial.printf("LED -> %s\n", on ? "ON" : "OFF");
}

class ServerCb: public BLEServerCallbacks {
  void onConnect(BLEServer *s) { bleConnected = true; }
  void onDisconnect(BLEServer *s) {
    bleConnected = false;
    BLEDevice::startAdvertising();
  }
};

class LedCb: public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) {
    auto v = c->getValue();
    if (v.length() > 0) pendingLed = (v[0] == 1 || v[0] == '1') ? 1 : 0;
  }
};

void onMessage(char *topic, byte *payload, unsigned int len) {
  String msg;
  for (unsigned int i = 0; i < len; i++) msg += (char)payload[i];
  msg.trim();
  msg.toUpperCase();
  if (msg == "ON") pendingLed = 1;
  else if (msg == "OFF") pendingLed = 0;
}

void tryMqtt() {
  String id = String("esp32-") + KELOMPOK + "-" + String((uint32_t)ESP.getEfuseMac(), HEX);
  if (mqtt.connect(id.c_str(), NULL, NULL, tStatus, 1, true, "offline")) {
    mqtt.publish(tStatus, "online", true);
    mqtt.subscribe(tLed, 1);
    mqtt.publish(tLedState, ledState ? "ON" : "OFF", true);
    Serial.println("MQTT terhubung");
  } else {
    Serial.printf("MQTT gagal, rc=%d\n", mqtt.state());
  }
}

void setup() {
  Serial.begin(115200);
  pinMode(LED_PIN, OUTPUT);
  dht.begin();

  snprintf(tSensor, sizeof(tSensor), "polnes/oit/%s/sensor", KELOMPOK);
  snprintf(tLed, sizeof(tLed), "polnes/oit/%s/led", KELOMPOK);
  snprintf(tLedState, sizeof(tLedState), "polnes/oit/%s/led/state", KELOMPOK);
  snprintf(tStatus, sizeof(tStatus), "polnes/oit/%s/status", KELOMPOK);
  snprintf(tAlarm, sizeof(tAlarm), "polnes/oit/%s/alarm", KELOMPOK);

  // --- BLE Setup ---
  BLEDevice::init(BLE_NAME);
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCb());
  BLEService *service = server->createService(SERVICE_UUID);
  
  ledChar = service->createCharacteristic(
    LED_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE
  );
  ledChar->setCallbacks(new LedCb());
  
  sensorChar = service->createCharacteristic(
    SENSOR_UUID, BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
  );
  sensorChar->addDescriptor(new BLE2902());
  service->start();
  
  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();

  // --- WiFi & MQTT Setup ---
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  mqtt.setServer(MQTT_HOST, MQTT_PORT);
  mqtt.setCallback(onMessage);
  applyLed(false);
}

void loop() {
  if (WiFi.status() == WL_CONNECTED) {
    if (!mqtt.connected() && millis() - lastRetry > 5000) {
      lastRetry = millis();
      tryMqtt();
    }
    mqtt.loop();
  } else if (millis() - lastRetry > 5000) {
    lastRetry = millis();
    WiFi.reconnect();
  }

  if (pendingLed >= 0) {
    int p = pendingLed;
    pendingLed = -1;
    applyLed(p == 1);
  }

  if (millis() - lastSend >= 3000) {
    lastSend = millis();
    float t = dht.readTemperature();
    float h = dht.readHumidity();

    if (!isnan(t) && !isnan(h)) {
      // Logika Tugas: Alarm Ambang Batas Suhu
      if (t > TEMP_THRESHOLD) {
        applyLed(true); // Nyalakan LED otomatis sebagai peringatan
        if (mqtt.connected()) {
          mqtt.publish(tAlarm, "BAHAYA: Suhu Melampaui Batas Normal!");
        }
      }

      if (bleConnected) {
        char txt[24];
        snprintf(txt, sizeof(txt), "%.1f;%.1f", t, h);
        sensorChar->setValue((uint8_t *)txt, strlen(txt));
        sensorChar->notify();
      }

      if (mqtt.connected()) {
        char js[64];
        snprintf(js, sizeof(js), "{\"suhu\":%.1f,\"hum\":%.1f}", t, h);
        mqtt.publish(tSensor, js);
      }
    }
  }
}