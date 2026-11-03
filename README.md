# eyEar

ESP32S3-based wearable camera that describes scenes aloud via a paired phone app.

- `firmware/` — PlatformIO firmware (Seeed XIAO ESP32S3 Sense)
- `phone_app/` — Flutter companion app (BLE client + text-to-speech)

## First-time setup

Secrets are gitignored. Copy the examples and fill in your values:
- `firmware/src/secrets.example.h` → `firmware/src/secrets.h` (WiFi + Gemini key)
- `phone_app/lib/secrets.example.dart` → `phone_app/lib/secrets.dart` (Gemini key)

## Firmware (PlatformIO)

Run from `firmware/` (where `platformio.ini` lives). In VS Code, open the `firmware/` folder so the PlatformIO extension finds the project.

| Command | What it does |
|---|---|
| `pio run` | Build the firmware without uploading |
| `pio run --target upload` | Build and flash to the connected board |
| `pio device monitor` | Open the Serial Monitor (115200 baud) |
| `pio run --target upload && pio device monitor` | Flash, then immediately watch Serial output |

Notes:
- Close the Serial Monitor before uploading — PlatformIO can't flash while something else holds the COM port ("port busy" error).
- If upload fails right after a reset, unplug/replug the USB-C cable — the XIAO's native USB can re-enumerate the COM port.

## Phone app (Flutter)

Run from `phone_app/`.

| Command | What it does |
|---|---|
| `flutter devices` | List connected phones/emulators — confirm your phone shows up before running |
| `flutter run` | Build, install, and launch on the first available device |
| `flutter run -d <device-id>` | Launch on a specific device (use the ID from `flutter devices`) |
| `flutter pub get` | Install/update Dart package dependencies (after editing `pubspec.yaml`) |
| `flutter clean` | Wipe build artifacts — use if a build is behaving strangely |
| `flutter test` | Run the tests (checks the Cortex scenario bank loads correctly) |

While `flutter run` is active, keyboard shortcuts in that terminal:
- `r` — hot reload (fast, keeps app state)
- `R` — hot restart (slower, resets app state)
- `q` — quit and stop the app

Requires the phone connected via USB with Developer Options → USB debugging enabled (Android), or a trusted device connection (iOS).

## Typical workflow after changing both firmware and app

1. `cd firmware && pio run --target upload` — flash the new firmware
2. `pio device monitor` — watch Serial output to confirm boot/WiFi/camera status
3. In a separate terminal, `cd phone_app && flutter run -d <device-id>` — reinstall and launch the app
4. Reconnect via the app's "Connect to EyEar" button (BLE connections don't survive a firmware reboot)
