# BLE Describe-Scene Trigger + Status Reporting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the phone app's "Describe Scene" button actually trigger a repeatable camera capture on the ESP32, and surface WiFi/camera/capture status to the phone as a visible (and optionally spoken) debug log, fixing the BLE message-truncation bug that currently causes descriptions to never display or speak.

**Architecture:** The firmware gains a write-only BLE command characteristic that sets a flag picked up by `loop()`, replacing the current one-shot "capture once during setup()" behavior. All phone-bound messages are now tagged (`S:`/`D:`/`E:`) and sent in fixed 20-byte chunks terminated by an empty notify, replacing the previous "single big notify, hope it's under the MTU" approach that silently dropped data. The app's reassembly logic switches from a size-based heuristic to the explicit empty-chunk terminator, and routes messages by tag to either a debug log or the main description panel.

**Tech Stack:** PlatformIO / Arduino framework (ESP32S3, BLE via the Arduino-ESP32 BLE library), Flutter (`flutter_blue_plus`, `flutter_tts`).

**Note on testing:** This is hardware-in-the-loop embedded + BLE code with no existing automated test framework on either side. Steps below substitute "build/compile check" and "manual hardware verification" for the usual "write failing test / make it pass" cycle.

**Note on commits:** Do not run `git commit` for any step in this plan. Leave all changes staged/uncommitted — the user commits manually themselves.

---

### Task 1: Firmware — command characteristic and repeatable trigger flow

**Files:**
- Modify: `src/main.cpp:1-19` (includes/macros/globals)
- Modify: `src/main.cpp:54-65` (BLE callbacks)
- Modify: `src/main.cpp:239-298` (setup/loop)

- [ ] **Step 1: Add the command characteristic UUID and new globals**

Replace lines 12–19:

```cpp
// BLE
#define DEVICE_NAME  "EyEar"
#define SERVICE_UUID "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHAR_UUID    "beb5483e-36e1-4688-b7f5-ea07361b26a8"

BLEServer* pServer = NULL;
BLECharacteristic* pCharacteristic = NULL;
bool deviceConnected = false;
```

with:

```cpp
// BLE
#define DEVICE_NAME       "EyEar"
#define SERVICE_UUID      "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHAR_UUID         "beb5483e-36e1-4688-b7f5-ea07361b26a8"
#define COMMAND_CHAR_UUID "cba1d466-344c-4be3-ab3f-189f80dd7518"

BLEServer* pServer = NULL;
BLECharacteristic* pCharacteristic = NULL;
bool deviceConnected = false;

volatile bool captureRequested = false;
bool wifiReady = false;
bool cameraReady = false;
```

- [ ] **Step 2: Add the command characteristic's write callback**

Replace the `ServerCallbacks` block (lines 54–65):

```cpp
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
```

with:

```cpp
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

class CommandCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* characteristic) {
    captureRequested = true;
    Serial.println("Capture requested via BLE.");
  }
};
```

- [ ] **Step 3: Create the command characteristic in `setup()` and replace the one-shot capture with a polling `loop()`**

Replace everything from `// ========== SETUP ==========` to the end of the file (lines 239–298) with:

```cpp
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

  BLECharacteristic* pCommandChar = pService->createCharacteristic(
    COMMAND_CHAR_UUID,
    BLECharacteristic::PROPERTY_WRITE
  );
  pCommandChar->setCallbacks(new CommandCallbacks());

  pService->start();
  BLEDevice::startAdvertising();
  Serial.println("BLE advertising. Waiting for phone...");

  // Step 2: Wait for phone
  while (!deviceConnected) {
    delay(500);
    Serial.print(".");
  }
  Serial.println();
  sendToPhone("EyEar connected!");

  // Step 3: WiFi
  wifiReady = connectWiFi();
  if (!wifiReady) sendToPhone("WiFi failed. Cannot continue.");
  else sendToPhone("WiFi connected!");

  // Step 4: Camera
  scanSccbBus();
  cameraReady = initCamera();
  if (!cameraReady) sendToPhone("Camera failed.");
  else sendToPhone("Camera ready!");

  if (wifiReady && cameraReady) {
    sendToPhone("Ready. Press Describe Scene to begin.");
  } else {
    sendToPhone("Ready with errors. Some features unavailable.");
  }
}

// ========== LOOP ==========
void loop() {
  if (captureRequested) {
    captureRequested = false;
    if (!wifiReady || !cameraReady) {
      sendToPhone("Cannot describe scene: WiFi/camera not ready.");
    } else {
      String result = captureAndDescribe();
      if (result.length() > 0) sendToPhone(result);
    }
  }
  delay(10);
}
```

- [ ] **Step 4: Build to verify it compiles**

Run: `pio run`
Expected: `[SUCCESS]` — `sendToPhone` and `captureAndDescribe` still use their original single-argument signatures at this point, so this compiles even though message tagging hasn't been added yet.

---

### Task 2: Firmware — tagged/chunked message protocol

**Files:**
- Modify: `src/main.cpp` (`sendToPhone`, `connectWiFi`, `initCamera`, `captureAndDescribe`, `setup`, `loop`)

- [ ] **Step 1: Rewrite `sendToPhone` to tag, chunk, and terminate messages**

Replace the `sendToPhone` function:

```cpp
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
```

- [ ] **Step 2: Tag `connectWiFi`'s status messages**

Replace the `connectWiFi` function:

```cpp
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
```

- [ ] **Step 3: Tag `initCamera`'s status messages**

Replace the `initCamera` function:

```cpp
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
  config.fb_location  = CAMERA_FB_IN_DRAM;
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
```

- [ ] **Step 4: Give `captureAndDescribe` a success out-param and tag its progress messages**

Replace the `captureAndDescribe` function (keep the base64/BLE/camera/HTTP logic identical — only the signature and `sendToPhone` calls change):

```cpp
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
```

- [ ] **Step 5: Update `setup()` and `loop()` for the new tagged calls and success out-param**

Replace `setup()` and `loop()` (from Task 1) with:

```cpp
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

  BLECharacteristic* pCommandChar = pService->createCharacteristic(
    COMMAND_CHAR_UUID,
    BLECharacteristic::PROPERTY_WRITE
  );
  pCommandChar->setCallbacks(new CommandCallbacks());

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
    sendToPhone('S', "Ready. Press Describe Scene to begin.");
  } else {
    sendToPhone('E', "Ready with errors. Some features unavailable.");
  }
}

// ========== LOOP ==========
void loop() {
  if (captureRequested) {
    captureRequested = false;
    if (!wifiReady || !cameraReady) {
      sendToPhone('E', "Cannot describe scene: WiFi/camera not ready.");
    } else {
      bool success = false;
      String result = captureAndDescribe(success);
      sendToPhone(success ? 'D' : 'E', result);
    }
  }
  delay(10);
}
```

- [ ] **Step 6: Build to verify it compiles**

Run: `pio run`
Expected: `[SUCCESS]`

---

### Task 3: Firmware — hardware verification

**Files:** none (verification only)

- [ ] **Step 1: Flash and open Serial Monitor**

Run: `pio run --target upload` then `pio device monitor`

- [ ] **Step 2: Confirm the boot sequence reports tagged status**

Expected Serial output includes lines like `S: Connecting to WiFi...`, `S: WiFi connected: <ip>`, `S: Initializing camera...`, `S: Camera ready!`, `S: Ready. Press Describe Scene to begin.` (the `Serial.println(String(type) + ": " + message)` in `sendToPhone` produces this format).

- [ ] **Step 3: Confirm the trigger is repeatable**

With the existing (unmodified) phone app connected — its `_triggerCapture()` already writes to the command characteristic — press "Describe Scene" two or three times in a row without rebooting the device. Expected: each press logs a fresh `S: Capturing image...` → `S: Encoding...` → `S: Asking Gemini...` → `D: <description>` (or `E: ...` on failure) sequence in Serial. (The app itself will not display these correctly yet — that's Task 4–6 — this step only confirms the firmware side triggers repeatedly.)

---

### Task 4: App — tagged message reassembly and routing

**Files:**
- Modify: `phone_app/lib/main.dart:34-48` (state fields)
- Modify: `phone_app/lib/main.dart:116-126` (`_onChunkReceived`)

- [ ] **Step 1: Add debug-log and error-state fields**

In `_HomePageState`, after the existing `String _buffer = '';` field, add:

```dart
  bool _speakDebug = false;
  bool _isError = false;
  final List<String> _debugLog = [];
```

- [ ] **Step 2: Replace the chunk-reassembly and add message routing**

Replace the `_onChunkReceived` method:

```dart
  // ESP32 sends "<type>:<message>" tagged and chunked to 20 bytes,
  // followed by an empty notify marking the end of the message.
  void _onChunkReceived(List<int> bytes) {
    if (bytes.isEmpty) {
      final full = _buffer.trim();
      _buffer = '';
      _routeMessage(full);
      return;
    }
    _buffer += utf8.decode(bytes, allowMalformed: true);
  }

  void _routeMessage(String full) {
    if (full.length < 2) return;
    final type = full[0];
    final content = full.substring(2);
    switch (type) {
      case 'D':
        setState(() {
          _analyzing = false;
          _isError = false;
          _message = content;
        });
        _tts.speak(content);
        break;
      case 'E':
        setState(() {
          _analyzing = false;
          _isError = true;
          _message = content;
          _debugLog.add(content);
        });
        _tts.speak(content);
        break;
      case 'S':
      default:
        setState(() {
          _debugLog.add(content);
        });
        if (_speakDebug) _tts.speak(content);
        break;
    }
  }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd phone_app && flutter analyze`
Expected: no errors (warnings about unrelated existing code are fine).

---

### Task 5: App — debug log UI and error styling

**Files:**
- Modify: `phone_app/lib/main.dart:145-239` (`build` method)

- [ ] **Step 1: Add the debug-speak switch and debug log panel, and style errors**

Replace the entire `build` method:

```dart
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('eyEar'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status indicator
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _connected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                      size: 28,
                      color: _connected ? Colors.greenAccent : Colors.grey,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      _connected ? 'Connected to EyEar' : 'Not connected',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),

            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Speak debug messages'),
              value: _speakDebug,
              onChanged: (v) => setState(() => _speakDebug = v),
            ),

            // Message display
            Expanded(
              flex: 3,
              child: Card(
                color: _isError ? Colors.red.shade900 : null,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _isError ? 'Error' : 'Scene Description',
                        style: const TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: SingleChildScrollView(
                          child: Text(_message, style: const TextStyle(fontSize: 17, height: 1.6)),
                        ),
                      ),
                      if (_connected && _message.length > 30)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton.icon(
                            onPressed: () => _tts.speak(_message),
                            icon: const Icon(Icons.volume_up, size: 18),
                            label: const Text('Read aloud'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            // Debug log
            Expanded(
              flex: 2,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Debug Log', style: TextStyle(fontSize: 13, color: Colors.grey)),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ListView.builder(
                          reverse: true,
                          itemCount: _debugLog.length,
                          itemBuilder: (context, index) {
                            final entry = _debugLog[_debugLog.length - 1 - index];
                            return Text(entry, style: const TextStyle(fontSize: 13));
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Connect / Disconnect
            FilledButton.icon(
              onPressed: _scanning ? null : (_connected ? _disconnect : _connect),
              icon: _scanning
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(_connected ? Icons.bluetooth_disabled : Icons.bluetooth),
              label: Text(_scanning ? 'Scanning...' : (_connected ? 'Disconnect' : 'Connect to EyEar')),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: _connected ? Colors.redAccent : null,
              ),
            ),

            const SizedBox(height: 12),

            // Describe scene
            FilledButton.icon(
              onPressed: (_connected && !_analyzing) ? _triggerCapture : null,
              icon: _analyzing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.camera_alt),
              label: Text(_analyzing ? 'Analyzing...' : 'Describe Scene'),
              style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            ),
          ],
        ),
      ),
    );
  }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd phone_app && flutter analyze`
Expected: no errors.

---

### Task 6: End-to-end hardware verification

**Files:** none (verification only)

- [ ] **Step 1: Flash the firmware and launch the app**

Run: `pio run --target upload` (project root), then `pio device monitor` in one terminal, and `cd phone_app && flutter run -d <device-id>` in another. Reconnect via the app's "Connect to EyEar" button.

- [ ] **Step 2: Verify the debug log fills in during boot**

Expected: as soon as connected, the app's Debug Log panel shows entries like "Connecting to WiFi...", "WiFi connected: ...", "Initializing camera...", "Camera ready!", "Ready. Press Describe Scene to begin." — untagged (prefix stripped) plain text.

- [ ] **Step 3: Verify repeatable scene description**

Press "Describe Scene". Expected: button shows "Analyzing...", Debug Log gains "Capturing image...", "Encoding...", "Asking Gemini..." entries, then the Scene Description panel populates and is read aloud automatically. Press the button again (no reboot) — expected: it works again, producing a new description.

- [ ] **Step 4: Verify the debug-speak toggle**

With "Speak debug messages" off (default), confirm the app stays silent during the "Capturing image..." etc. steps and only speaks the final description. Turn it on, press "Describe Scene" again, and confirm the intermediate status messages are now also spoken.

- [ ] **Step 5: Verify error reporting**

Temporarily change `WIFI_PASSWORD` in `src/secrets.h` to an incorrect value, reflash, reconnect, and confirm an `E:`-sourced message ("WiFi failed (status ...)") appears in red/error styling in the description panel and is spoken aloud even with the debug toggle off. Revert `secrets.h` back to the correct password and reflash afterward.

- [ ] **Step 6: If messages never complete (stuck on "Analyzing..." or debug log never updates), apply the empty-notify fallback**

This means the BLE stack isn't transmitting the 0-length notify used as the end-of-message marker. Switch to a 1-byte sentinel instead:

In `src/main.cpp`, in `sendToPhone`, replace:

```cpp
  // Empty notify marks end of message for the app's reassembly logic.
  pCharacteristic->setValue("");
  pCharacteristic->notify();
  delay(20);
```

with:

```cpp
  // 1-byte sentinel (0x01) marks end of message for the app's reassembly logic.
  uint8_t terminator = 0x01;
  pCharacteristic->setValue(&terminator, 1);
  pCharacteristic->notify();
  delay(20);
```

In `phone_app/lib/main.dart`, in `_onChunkReceived`, replace:

```dart
    if (bytes.isEmpty) {
```

with:

```dart
    if (bytes.length == 1 && bytes[0] == 0x01) {
```

Rebuild and reflash both sides, then repeat Steps 2–5.
