# BLE Describe-Scene Trigger + Status Reporting

## Problem

The Flutter phone app already has a "Describe Scene" button wired to write to a BLE command characteristic, and logic to reassemble and speak notified text — but pressing the button does nothing, because the ESP32 firmware never creates that characteristic. Separately, the one automatic scene description that *does* run once at boot is never displayed or spoken, because the firmware sends it as a single BLE notify with no chunking guarantee, which silently truncates past the ~20-byte default BLE MTU. The phone's "a chunk shorter than 20 bytes means it's done" heuristic then never fires, so the app hangs waiting.

There is also no visibility into WiFi/camera status from the phone — that information currently only goes to the USB Serial console, making the app useless as a debugging aid while iterating on hardware.

## Message protocol

Every logical message sent from firmware to phone gets a one-letter type prefix before transmission:

- `S:` — routine status/progress (e.g. "Connecting to WiFi...", "Encoding..."). Shown in an on-screen debug log. Spoken via TTS only if the user has enabled the debug-speak toggle.
- `D:` — a successful scene description. Shown in the main description panel. Always spoken via TTS regardless of the debug toggle.
- `E:` — an error/failure (WiFi failed, camera failed, Gemini HTTP error). Shown prominently (distinct styling from `S:`/`D:`) and always spoken via TTS regardless of the debug toggle, so a failure is never silent.

### Chunking and framing

The firmware slices `type + ":" + message` into fixed 20-byte chunks — the guaranteed-safe BLE payload without MTU negotiation — sent as sequential notifications on the existing text characteristic. After the real data, the firmware sends one explicit empty (0-length) notify as an end-of-message marker.

The app's reassembly logic changes from "a chunk shorter than 20 bytes ends the message" (fragile — breaks if a real chunk happens to be exactly 20 bytes) to "an empty chunk ends the message" (unambiguous regardless of chunk sizes).

MTU negotiation (Option C considered and rejected) is not used: it isn't guaranteed to succeed across Android versions/devices, and message sizes here (a few hundred characters at most) don't need it — reliability matters more than packet count for this use case.

## Firmware changes (`src/main.cpp`)

- Add a new BLE characteristic for UUID `cba1d466-344c-4be3-ab3f-189f80dd7518` with `PROPERTY_WRITE`. Its `onWrite` callback only sets `volatile bool captureRequested = true` — no heavy work runs inside the BLE callback itself.
- Track `wifiReady` and `cameraReady` booleans, set during the existing one-time boot sequence (BLE advertise → wait for phone connect → WiFi connect → camera init). Each of these boot steps now also sends `S:`/`E:` status over BLE (not just to Serial):
  - WiFi: `S: Connecting to WiFi...`, then either `S: WiFi connected: <ip>` or `E: WiFi failed (status <code>)`. The full network scan list stays Serial-only (too verbose for the phone's debug log); the phone only needs to know whether the target network was found and whether it connected.
  - Camera: `S: Initializing camera...`, then either `S: Camera ready!` or `E: Camera failed (0x<code>)` after the existing 3 retry attempts.
- Rework `sendToPhone` into a tagged, chunked sender: `sendToPhone(char type, String message)` builds `type + ":" + message`, sends it in 20-byte notify chunks, then sends the empty terminator chunk.
- `loop()` changes from doing nothing to polling `captureRequested`:
  - If not set, nothing happens (idle).
  - If set: clear the flag immediately. If `!wifiReady || !cameraReady`, send `E: Cannot describe scene: WiFi/camera not ready` and stop. Otherwise run the existing `captureAndDescribe()` (its interim announcements — "Capturing image...", "Encoding...", "Asking Gemini..." — become `S:` messages) and send the final result as `D:` (success) or `E:` (capture failure or Gemini HTTP error).
- This makes scene description repeatable indefinitely from the app without rebooting the device.

## App changes (`phone_app/lib/main.dart`)

- `_onChunkReceived` changes its end-of-message check from `bytes.length < 20` to `bytes.isEmpty`.
- On a completed message, parse the leading `S:`/`D:`/`E:` prefix and strip it before routing:
  - `S:` → append to a new debug log (list of strings, newest last), shown in a scrollable panel. Spoken via TTS only if the debug-speak toggle is on.
  - `D:` → set as the main description text, clear the "Analyzing..." state, always spoken via TTS.
  - `E:` → shown with distinct (error) styling, clears the "Analyzing..." state, always spoken via TTS regardless of the debug toggle.
- New UI element: a switch labeled "Speak debug messages", off by default, controlling only whether `S:` messages are spoken (does not affect `D:`/`E:`, which are always spoken).
- New UI element: a scrollable debug log panel showing the `S:`/`E:` history, for visibility while testing hardware changes.

## Error handling

- If WiFi or camera failed during boot, the "Describe Scene" button remains pressable but immediately returns a clear `E:` explanation instead of silently doing nothing or hanging.
- Gemini HTTP failures (e.g. the `404` from a deprecated model) surface as an audible `E:` on the phone instead of being visible only in Serial output.

## Testing

This is a hardware-in-the-loop prototype with no existing automated test suite; verification is manual:

- Press "Describe Scene" repeatedly without rebooting the device — confirm each press produces a fresh description.
- Confirm the debug log fills in with `S:` messages as WiFi/camera/capture steps happen.
- Toggle "Speak debug messages" on/off and confirm it only affects `S:` messages, not `D:`/`E:`.
- Temporarily break WiFi (wrong password) or disconnect the camera to confirm the corresponding `E:` message appears and is spoken even with the debug toggle off.
