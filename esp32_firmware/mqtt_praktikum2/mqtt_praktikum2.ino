#include <WiFi.h>
#include <PubSubClient.h>
#include <DHT.h>

#define LED_PIN 20 // 5
#define DHT_PIN 21 // 4
#define DHT_TYPE DHT11

const char *WIFI_SSID = "POCO F5";
const char *WIFI_PASS = "aldi27ks";
const char *MQTT_HOST = "broker.emqx.io";
const int   MQTT_PORT = 1883;
const char *KELOMPOK  = "kel5";

char tSensor[64], tLed[64], tLedState[64], tStatus[64];
DHT dht(DHT_PIN, DHT_TYPE);
WiFiClient wifiClient;
PubSubClient mqtt(wifiClient);
unsigned long lastSend = 0;

void setLed(bool on) {
  digitalWrite(LED_PIN, on ? HIGH : LOW);
  mqtt.publish(tLedState, on ? "ON" : "OFF", true); // retained[cite: 14]
}

void onMessage(char *topic, byte *payload, unsigned int len) {
  String msg;
  for (unsigned int i = 0; i < len; i++) msg += (char)payload[i];
  msg.trim();
  msg.toUpperCase();
  Serial.printf("Terima [%s]: %s\n", topic, msg.c_str());
  if (msg == "ON") setLed(true);
  else if (msg == "OFF") setLed(false);
}

void connectWifi() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  Serial.print("Menghubungkan WiFi");
  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    Serial.print(".");
  }
  Serial.printf("\nWiFi OK, IP: %s\n", WiFi.localIP().toString().c_str());
}

void connectMqtt() {
  while (!mqtt.connected()) {
    String id = String("esp32-") + KELOMPOK + "-" + String((uint32_t)ESP.getEfuseMac(), HEX);
    Serial.print("Menghubungkan MQTT... ");
    // Last Will: broker mengirim "offline" jika ESP32 terputus tiba-tiba[cite: 15]
    if (mqtt.connect(id.c_str(), NULL, NULL, tStatus, 1, true, "offline")) {
      Serial.println("OK");
      mqtt.publish(tStatus, "online", true);
      mqtt.subscribe(tLed, 1);
    } else {
      Serial.printf("gagal, rc=%d. Ulangi 3 detik lagi\n", mqtt.state());
      delay(3000);
    }
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

  connectWifi();
  mqtt.setServer(MQTT_HOST, MQTT_PORT);
  mqtt.setCallback(onMessage);
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) connectWifi();
  if (!mqtt.connected()) connectMqtt();
  mqtt.loop();

  if (millis() - lastSend >= 3000) {
    lastSend = millis();
    float t = dht.readTemperature();
    float h = dht.readHumidity();

    if (!isnan(t) && !isnan(h)) {
      char buf[64];
      snprintf(buf, sizeof(buf), "{\"suhu\":%.1f, \"hum\":%.1f}", t, h);
      mqtt.publish(tSensor, buf);
      Serial.printf("Publish: %s\n", buf);
    }
  }
}