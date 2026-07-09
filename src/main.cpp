#include "esp_camera.h"
#include <WiFi.h>
#include <WebServer.h>
#include <HTTPClient.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <ArduinoJson.h>
#include <Wire.h>
#include "secrets.h"

// BLE
#define DEVICE_NAME  "EyEar"
#define SERVICE_UUID "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHAR_UUID    "beb5483e-36e1-4688-b7f5-ea07361b26a8"

BLEServer* pServer = NULL;
BLECharacteristic* pCharacteristic = NULL;
bool deviceConnected = false;

WebServer webServer(80);

bool wifiReady = false;
bool cameraReady = false;

bool wasConnected = false;
unsigned long lastCaptureTime = 0;
const unsigned long CAPTURE_INTERVAL_MS = 60000;
const bool ENABLE_AUTO_CAPTURE = false;

// ========== BASE64 ==========
static const char base64_chars[] =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
  "abcdefghijklmnopqrstuvwxyz"
  "0123456789+/";

String base64_encode(const uint8_t* data, size_t length) {
  String ret;
  int i = 0;
  uint8_t char_array_3[3];
  uint8_t char_array_4[4];
  while (length--) {
    char_array_3[i++] = *(data++);
    if (i == 3) {
      char_array_4[0] = (char_array_3[0] & 0xfc) >> 2;
      char_array_4[1] = ((char_array_3[0] & 0x03) << 4) + ((char_array_3[1] & 0xf0) >> 4);
      char_array_4[2] = ((char_array_3[1] & 0x0f) << 2) + ((char_array_3[2] & 0xc0) >> 6);
      char_array_4[3] = char_array_3[2] & 0x3f;
      for (i = 0; i < 4; i++) ret += base64_chars[char_array_4[i]];
      i = 0;
    }
  }
  if (i) {
    for (int j = i; j < 3; j++) char_array_3[j] = '\0';
    char_array_4[0] = (char_array_3[0] & 0xfc) >> 2;
    char_array_4[1] = ((char_array_3[0] & 0x03) << 4) + ((char_array_3[1] & 0xf0) >> 4);
    char_array_4[2] = ((char_array_3[1] & 0x0f) << 2) + ((char_array_3[2] & 0xc0) >> 6);
    for (int j = 0; j < i + 1; j++) ret += base64_chars[char_array_4[j]];
    while (i++ < 3) ret += '=';
  }
  return ret;
}

// ========== BLE CALLBACKS ==========
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* pServer) {
    deviceConnected = true;
    Serial.println("Phone connected!");
  }
  void onDisconnect(BLEServer* pServer) {
    deviceConnected = false;
    Serial.println("Phone disconnected.");
    BLEDevice::startAdvertising();
  }
};

// ========== SEND VIA BLE ==========
void sendToPhone(char type, String message) {
  Serial.println(String(type) + ": " + message);
  if (!deviceConnected) return;

  String full = String(type) + ":" + message;
  const int chunkSize = 20;
  int len = full.length();
  for (int i = 0; i < len; i += chunkSize) {
    String chunk = full.substring(i, min(len, i + chunkSize));
    pCharacteristic->setValue(chunk.c_str());
    pCharacteristic->notify();
    delay(20);
  }

  // Empty notify marks end of message for the app's reassembly logic.
  pCharacteristic->setValue("");
  pCharacteristic->notify();
  delay(20);
}

// ========== WIFI ==========
bool connectWiFi() {
  WiFi.mode(WIFI_STA);

  Serial.println("Scanning for SSID '" + String(WIFI_SSID) + "'...");
  int n = WiFi.scanNetworks();
  bool found = false;
  for (int i = 0; i < n; i++) {
    Serial.println("  seen: " + WiFi.SSID(i) + "  (RSSI " + String(WiFi.RSSI(i)) + ", ch " + String(WiFi.channel(i)) + ")");
    if (WiFi.SSID(i) == String(WIFI_SSID)) found = true;
  }
  sendToPhone('S', found ? "Target network found." : "Target network NOT found.");

  sendToPhone('S', "Connecting to WiFi...");
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  int attempts = 0;
  while (WiFi.status() != WL_CONNECTED && attempts < 20) {
    delay(500);
    Serial.print(".");
    attempts++;
  }
  Serial.println();
  if (WiFi.status() == WL_CONNECTED) {
    sendToPhone('S', "WiFi connected: " + WiFi.localIP().toString());
    return true;
  }
  sendToPhone('E', "WiFi failed (status " + String(WiFi.status()) + ")");
  return false;
}

// ========== CAMERA ==========
void scanSccbBus() {
  Wire.begin(40, 39); // SIOD, SIOC
  Serial.println("Scanning I2C/SCCB bus on SDA=40, SCL=39...");
  int found = 0;
  for (uint8_t addr = 1; addr < 127; addr++) {
    Wire.beginTransmission(addr);
    if (Wire.endTransmission() == 0) {
      Serial.println("  device at 0x" + String(addr, HEX));
      found++;
    }
  }
  if (found == 0) Serial.println("  no devices found on bus.");
  Wire.end();
}

bool initCamera() {
  sendToPhone('S', "Initializing camera...");
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer   = LEDC_TIMER_0;
  config.pin_d0       = 15;
  config.pin_d1       = 17;
  config.pin_d2       = 18;
  config.pin_d3       = 16;
  config.pin_d4       = 14;
  config.pin_d5       = 12;
  config.pin_d6       = 11;
  config.pin_d7       = 48;
  config.pin_xclk     = 10;
  config.pin_pclk     = 13;
  config.pin_vsync    = 38;
  config.pin_href     = 47;
  config.pin_sscb_sda = 40;
  config.pin_sscb_scl = 39;
  config.pin_pwdn     = -1;
  config.pin_reset    = -1;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;
  config.frame_size   = FRAMESIZE_QVGA;
  config.jpeg_quality = 12;
  config.fb_count     = 1;
  config.fb_location  = CAMERA_FB_IN_PSRAM;
  config.grab_mode    = CAMERA_GRAB_LATEST;

  esp_err_t err = ESP_FAIL;
  for (int i = 0; i < 3; i++) {
    err = esp_camera_init(&config);
    if (err == ESP_OK) {
      sendToPhone('S', "Camera ready!");
      return true;
    }
    Serial.println("Camera attempt " + String(i + 1) + " failed: 0x" + String(err, HEX));
    esp_camera_deinit();
    delay(300);
  }
  sendToPhone('E', "Camera failed (0x" + String(err, HEX) + ")");
  return false;
}

// ========== CAMERA PREVIEW WEB PAGE ==========
void handleRoot() {
  String html =
    "<html><body style='background:#000;margin:0'>"
    "<img id='shot' src='/capture' style='width:100%'>"
    "<script>"
    "setInterval(function(){"
    "document.getElementById('shot').src='/capture?t='+Date.now();"
    "},2000);"
    "</script></body></html>";
  webServer.send(200, "text/html", html);
}

void handleCapture() {
  camera_fb_t* fb = esp_camera_fb_get();
  if (!fb) {
    webServer.send(503, "text/plain", "Capture failed");
    return;
  }
  WiFiClient client = webServer.client();
  String header = "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: " + String(fb->len) + "\r\nConnection: close\r\n\r\n";
  client.print(header);
  client.write(fb->buf, fb->len);
  esp_camera_fb_return(fb);
}

// ========== CAPTURE + GEMINI ==========
String captureAndDescribe(bool &success) {
  success = false;
  sendToPhone('S', "Capturing image...");

  camera_fb_t* fb = esp_camera_fb_get();
  if (!fb) {
    return "Capture failed.";
  }
  Serial.printf("Image: %d bytes\n", fb->len);

  sendToPhone('S', "Encoding...");
  String base64Image = base64_encode(fb->buf, fb->len);
  esp_camera_fb_return(fb);

  sendToPhone('S', "Asking Gemini...");

  String url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=";
  url += GEMINI_API_KEY;

  String payload = "{\"contents\":[{\"parts\":[";
  payload += "{\"text\":\"You are a navigation assistant for a blind person wearing a camera. ";
  payload += "Describe what you see in 1-2 short sentences. ";
  payload += "Use clock positions for directions (12 o'clock = straight ahead, 3 o'clock = right, 9 o'clock = left). ";
  payload += "Estimate distances in feet or steps. ";
  payload += "Prioritize obstacles and hazards. ";
  payload += "Give a clear action such as step left, move right, or safe to proceed. ";
  payload += "If there is text or signage visible, read it. ";
  payload += "Start directly with the description, no preamble.\"},";
  payload += "{\"inline_data\":{\"mime_type\":\"image/jpeg\",\"data\":\"";
  payload += base64Image;
  payload += "\"}}]}]}";

  HTTPClient http;
  http.begin(url);
  http.addHeader("Content-Type", "application/json");
  http.setTimeout(20000);

  int httpCode = http.POST(payload);
  String description = "";

  if (httpCode == 200) {
    String response = http.getString();
    DynamicJsonDocument doc(4096);
    DeserializationError error = deserializeJson(doc, response);
    if (!error) {
      description = doc["candidates"][0]["content"]["parts"][0]["text"].as<String>();
      description.trim();
      Serial.println("Gemini: " + description);
      success = true;
    } else {
      Serial.println("JSON error: " + String(error.c_str()));
      description = "Could not parse AI response.";
    }
  } else {
    Serial.println("HTTP error: " + String(httpCode));
    Serial.println(http.getString());
    description = "AI request failed. Code: " + String(httpCode);
  }

  http.end();
  return description;
}

// ========== SETUP ==========
void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("EyEar booting...");

  // Step 1: BLE
  BLEDevice::init(DEVICE_NAME);
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());
  BLEService* pService = pServer->createService(SERVICE_UUID);

  pCharacteristic = pService->createCharacteristic(
    CHAR_UUID,
    BLECharacteristic::PROPERTY_READ |
    BLECharacteristic::PROPERTY_NOTIFY
  );
  pCharacteristic->addDescriptor(new BLE2902());
  pCharacteristic->setValue("EyEar Ready");

  pService->start();
  BLEDevice::startAdvertising();
  Serial.println("BLE advertising. Waiting for phone...");

  // Step 2: Wait for phone
  while (!deviceConnected) {
    delay(500);
    Serial.print(".");
  }
  Serial.println();
  sendToPhone('S', "EyEar connected!");

  // Step 3: WiFi
  wifiReady = connectWiFi();

  // Step 4: Camera
  scanSccbBus();
  cameraReady = initCamera();

  if (wifiReady && cameraReady) {
    webServer.on("/", handleRoot);
    webServer.on("/capture", handleCapture);
    webServer.begin();
    sendToPhone('S', "Preview: http://" + WiFi.localIP().toString() + "/");
    sendToPhone('S', "Ready.");
  } else {
    sendToPhone('E', "Ready with errors. Some features unavailable.");
  }
}

// ========== LOOP ==========
void loop() {
  if (wifiReady && cameraReady) {
    webServer.handleClient();
  }

  if (ENABLE_AUTO_CAPTURE && deviceConnected && wifiReady && cameraReady) {
    bool justConnected = !wasConnected;
    if (justConnected || millis() - lastCaptureTime >= CAPTURE_INTERVAL_MS) {
      lastCaptureTime = millis();
      bool success = false;
      String result = captureAndDescribe(success);
      sendToPhone(success ? 'D' : 'E', result);
    }
  }
  wasConnected = deviceConnected;
  delay(10);
}