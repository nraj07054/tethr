# Tethr

**Your Android phone, on your Mac.** Tethr links an Android phone to a macOS app
over your local Wi‑Fi network — no account, no cloud, everything stays on your LAN.

> ⚠️ Work in progress. Built and tested against one Android device (OnePlus /
> Android 14) and macOS 26+. Contributions welcome.

## Features

- **Screen mirroring** — real-time, low-latency stream of the phone's screen into
  a separate, phone-shaped window on the Mac.
- **Remote control** — click and drag on the mirror window to tap and swipe the
  phone; Back / Home / Recents. (Uses an Android accessibility service.)
- **Calls** — synced call history, tap-to-dial from the Mac, caller ID, and a
  floating incoming-call card that appears whether or not the window is open.
- **Messages** — SMS threads synced to the Mac, read and replied to on a real
  keyboard, and new conversations started from there. On a dual-SIM phone each
  reply leaves from the SIM its conversation is on.
- **Notifications** — mirrored to the Mac with the real app name and icon, and
  reply inline through the notification's own reply action.
- **Clipboard** — copy on one device, paste on the other. Password-manager and
  one-time-code copies are deliberately left behind.
- **File transfer** — drag files onto the Mac to send them, or **share to Tethr**
  from any Android app, exactly like sharing to a messaging app.
- **Contacts** — the phone's address book, synced to the Mac.
- **Encrypted, local, no account** — nothing leaves your network and there is no
  server in the middle. See [Security](#security).

## Install

Grab the two files from the [latest release][releases] — no compiler needed.

[releases]: https://github.com/nraj07054/tethr/releases/latest

| | Needs |
|---|---|
| **Mac** | macOS 26 (Tahoe) or later, Apple silicon |
| **Phone** | Android 14 or later |

### Mac

> **Needs macOS 26 (Tahoe) or later, on Apple silicon.** Homebrew refuses to
> install on anything earlier, and a downloaded copy will not open. Check under
> the Apple menu > About This Mac. The published build is `arm64` only, so an
> Intel Mac needs to build from source. So does macOS 14 or 15, with the
> platform floor in `mac/Package.swift` lowered back to `.macOS(.v14)`.

**Download it** — paste this into Terminal:

```sh
curl -L -o /tmp/Tethr.zip https://github.com/nraj07054/tethr/releases/latest/download/Tethr-macOS.zip
unzip -q -o /tmp/Tethr.zip -d /Applications && open /Applications/Tethr.app
```

**Or Homebrew**, if you would rather `brew upgrade` handled it — two commands,
because Homebrew quarantines what it installs and no longer offers a way to opt
out:

```sh
brew install --cask nraj07054/tethr/tethr
xattr -dr com.apple.quarantine /Applications/Tethr.app
```

Skip that second line and macOS refuses to open the app. See below for why.

Then allow **Local Network** access when asked — the phone reaches the Mac over
your LAN and the link cannot work without it.

<details>
<summary>Why not just download it in the browser?</summary>

You can, but macOS will refuse to open it — *"Apple could not verify 'Tethr' is
free of malware..."*, or on older versions *"Tethr is damaged and can't be
opened."* Nothing is damaged. Tethr is signed ad-hoc rather than notarised by
Apple, because notarisation requires a paid Apple Developer account this project
does not have, and those are the only messages macOS has for it.

What triggers them is the `com.apple.quarantine` attribute. Browsers set it on
anything they download, and so does Homebrew — it tags every cask, and as of
Homebrew 6 the `--no-quarantine` opt-out is gone, so the tag has to be cleared
afterwards. `curl` never sets it, which is why that route needs nothing extra.

However you got here, clearing the tag once is the fix:

```sh
xattr -dr com.apple.quarantine /Applications/Tethr.app
```

This does not weaken anything else — Gatekeeper still checks the signature, and
the app is still sandboxed by the same rules as any other. If you would rather
not take that on trust, build from source instead: it is one command, and the
result is identical.
</details>

### Android

Open this link **on the phone** — it always points at the newest release:

**[⬇ Download Tethr-android.apk][apk]**

[apk]: https://github.com/nraj07054/tethr/releases/latest/download/Tethr-android.apk

1. Chrome warns that this type of file can harm your device. It says that about
   every APK, signed or not. Tap **Download anyway** (or **Keep**).
2. Open it from the download notification, or Files > Downloads. Android asks
   whether Chrome may install unknown apps; allow it, and Play Protect may ask
   to scan first. Both are expected for an app installed outside the Play Store.
3. Open Tethr and grant the permissions it asks for. Each one buys a feature and
   nothing works silently without it:

   | Permission | What it enables |
   |---|---|
   | Contacts, Call log, Phone | Contacts, call history, caller ID, dialling |
   | SMS | Reading and sending texts from the Mac |
   | Notification access | Mirroring notifications and replying from the Mac |
   | Accessibility (*Tethr — Control from Mac*) | Tapping and swiping the mirrored screen |
   | Display over other apps | Reading the clipboard while Tethr is in the background |
   | Battery: unrestricted | Stops Android pausing the link to save power |

Already have the phone plugged into the Mac with USB debugging on? Skip the
browser entirely:

```sh
adb install -r Tethr-android.apk
```

### Pair

The Mac shows a QR code on first launch. Open Tethr on the phone, scan it, and
the two are linked. Pairing is once — after that the phone reconnects on its own,
including after a reboot with the app closed.

> Both devices need to be on the **same network**, but that need not be a router:
>
> | Link | Set up | Mirroring |
> |---|---|---|
> | Wi-Fi router | Both devices on the same network | Full speed |
> | **Phone hotspot** | Turn on the phone's hotspot, join it from the Mac | Full speed |
> | **USB tethering** | Plug in USB, enable USB tethering | Full speed, no radio |
> | Bluetooth PAN | Pair, then *Connect to Network* on the Mac | Too slow — calls/contacts only |
>
> Switching between them needs no re-pair; the phone sweeps the Mac's known
> addresses and remembers whichever answers.

## Security

Tethr has no account, no server and no cloud. The two devices talk directly.

- **Pairing** happens once, by QR. After that the shared secret never crosses the
  wire again: each connection proves knowledge of it with an HMAC-SHA256
  challenge over two fresh nonces, so a recorded handshake is useless later.
- **Everything after the handshake is encrypted** with AES-256-GCM. Keys are
  derived per connection (HKDF-SHA256 over both nonces), each direction has its
  own, and frames carry a counter that makes replays fail. Contacts, call log,
  notification text, clipboard, files and screen frames are all sealed — none of
  it is readable by anyone else on the network.
- **Unlinking is authenticated.** Unpairing on the Mac signs a revocation the
  phone verifies before acting, so nobody on the network can unpair your phone by
  sending a packet.
- **The clipboard filter** skips anything the source app marked sensitive — what
  password managers set — plus bare one-time codes.
- **Received files** are written to a temporary file and only moved into place
  once complete, with names sanitised and sizes capped.

Found something wrong with any of this? Please open an issue.

## Repository layout

```
mac/       macOS app — SwiftUI + Network.framework (Swift Package)
android/   Android companion — Kotlin, Jetpack Compose, OkHttp
```

The Mac runs a small HTTP + WebSocket server; the phone connects to it. The QR
code the Mac shows encodes the pairing URL. See `mac/Sources/Tethr/PairingServer.swift`
and `android/app/src/main/java/com/nikhilraj/tethr/ConnectionService.kt`.

## Build from source

Contributors and anyone who would rather compile. One command does each end:

```sh
make install-mac       # build Tethr.app and install it to /Applications
make install-android   # build the APK and install it on a connected phone
make test              # wire-format tests for the encrypted session
```

Or without make: `scripts/build-mac.sh`, `scripts/install-mac.sh`,
`scripts/install-android.sh`.

**Requirements** — macOS 26+ with a Swift toolchain (Xcode) for the Mac app;
JDK 17 and the Android SDK for the phone app. `android/local.properties` is
generated locally and deliberately not committed.

Swift Package Manager builds a bare executable rather than an app bundle, so
`scripts/build-mac.sh` assembles `Tethr.app` around it — copying the binary and
its resource bundle into the `Info.plist`/icon skeleton kept in the repo, then
ad-hoc signing it. macOS will not launch an unsigned bundle at all.

### Releasing

Tagging a commit builds both ends and attaches them to a GitHub release:

```sh
git tag v1.0.0 && git push origin v1.0.0
```

To publish a properly signed APK rather than a debuggable one, add these repository
secrets — the workflow falls back to a debug build (and says so) without them:
`KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`.

## Known limitations

- In‑call **mute / speaker / hold / DTMF** require the app to be Android's default
  dialer, which Tethr intentionally is not — so those are not offered.
- Live **call audio** cannot be routed to the Mac by a third‑party app (Android
  restriction); it stays on the phone.
- Remote control supports taps and swipes, not pinch‑zoom or text entry (yet).
- Messages covers **SMS only**. MMS lives in a different provider with its own
  attachment table, and a picture message would arrive as an empty bubble, so
  those conversations are left out rather than shown blank.
- Reading SMS needs `READ_SMS`, which Google Play grants only to a phone's
  default SMS handler. Tethr is sideloaded, so it can hold the permission — but
  that is also why Tethr can never be published on the Play Store.

## Contributing

Issues and pull requests are welcome. Tethr has been built and tested against a
single Android device (OnePlus, Android 14+) and macOS 26+, so reports from other
hardware are genuinely useful — especially OEM skins that handle background
services differently.

If you touch the wire format, run `make test`: those tests pin the encrypted
frame layout against the Mac's Swift implementation, and the two ends stop
talking to each other if they drift apart.

## Support

Tethr is free and MIT licensed, and it stays that way. If it saved you some time
and you would like to say thanks, you can [sponsor the project][sponsor] — or use
the **Sponsor** button at the top of this repository.

[sponsor]: https://github.com/sponsors/nraj07054

Entirely optional, and it buys nothing: no priority support, no private builds,
no features behind a paywall. Bug reports from hardware I cannot test on are
worth more than money.

## License

[MIT](LICENSE) © Nikhil Raj Barnwal
