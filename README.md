# Dogen

**Your Android phone, on your Mac.** Dogen links an Android phone to a macOS app
over your local Wi‑Fi network — no account, no cloud, everything stays on your LAN.

> ⚠️ Work in progress. Built and tested against one Android device (OnePlus /
> Android 14) and macOS 14+. Contributions welcome.

## Features

- **Screen mirroring** — real‑time, low‑latency stream of the phone's screen into
  a separate, phone‑shaped window on the Mac.
- **Remote control** — click and drag on the mirror window to tap and swipe the
  phone; Back / Home / Recents buttons. (Uses an Android accessibility service.)
- **Calls** — synced call history, tap‑to‑dial from the Mac, and an incoming‑call
  banner with answer / reject / end.
- **Contacts** — the phone's contacts, synced to the Mac.
- **Rock‑solid link** — QR pairing, a persistent WebSocket with TCP keepalive, and
  automatic reconnect.

## Getting started (quickstart)

1. **Build & install the Mac app** — see [Mac app](#mac-app-mac) below, then `open Dogen.app`.
2. **Build & install the Android app** — see [Android app](#android-app-android), then launch it on the phone.
3. **Grant phone permissions** when prompted (contacts, call log, phone).
4. **Pair**: the Mac shows a QR code — scan it from the phone's Dogen app. The link
   connects over Wi‑Fi and stays connected in the background.
5. **Use it**:
   - Tap **Mirror Screen** on the phone → a phone‑shaped window opens on the Mac.
     Click/drag on it to control the phone.
   - Calls and contacts appear in the Mac app's sidebar; tap‑to‑dial from there.
6. **For remote control**, enable *Settings → Accessibility → “Dogen — Control from
   Mac”* on the phone (one time).

> Both devices must be on the **same Wi‑Fi network**.

## Repository layout

```
mac/       macOS app — SwiftUI + Network.framework (Swift Package)
android/   Android companion — Kotlin, Jetpack Compose, OkHttp
```

The Mac runs a small HTTP + WebSocket server; the phone connects to it. The QR
code the Mac shows encodes the pairing URL. See `mac/Sources/Dogen/PairingServer.swift`
and `android/app/src/main/java/com/nikhilraj/dogen/ConnectionService.kt`.

## Build & run

### Mac app (`mac/`)
```bash
cd mac
swift build
# Package the built binary into the app bundle:
cp .build/debug/Dogen Dogen.app/Contents/MacOS/Dogen
codesign --force --deep --sign - Dogen.app
open Dogen.app
```
Requires macOS 14+ and a Swift toolchain (Xcode). On first run, allow the
**Local Network** permission so the phone can reach the Mac.

### Android app (`android/`)
```bash
cd android
./gradlew :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```
Grant the requested permissions (contacts, call log, phone). For **remote
control**, enable *Settings → Accessibility → “Dogen — Control from Mac”*.

## Pairing

1. Open Dogen on the Mac — it shows a QR code.
2. Open Dogen on the phone and scan it. The link connects over Wi‑Fi and persists.

## Known limitations

- In‑call **mute / speaker / hold / DTMF** require the app to be Android's default
  dialer, which Dogen intentionally is not — so those are not offered.
- Live **call audio** cannot be routed to the Mac by a third‑party app (Android
  restriction); it stays on the phone.
- Remote control supports taps and swipes, not pinch‑zoom or text entry (yet).

## License

Intended to be open source and free. A license (e.g. MIT) will be added.
