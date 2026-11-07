# VoxLibre for iOS

A native **Swift / SwiftUI / CoreBluetooth** port of [VoxLibre](https://github.com/elvisoliveira/voxlibre) —
the independent, offline companion for the Vocci smart ring (`Timon`, Nordic nRF5340). It connects to a
ring that is **already bound to your Vocci account**, authenticates locally, shows telemetry, lists /
downloads / plays / deletes recordings and shows the raw BLE protocol — with no cloud calls at runtime.

> [!WARNING]
> **Pairing a ring needs credentials minted by Vocci's servers** (`BIND KEY` + `USER ID`). This app does not
> pair a ring and does not bypass that; you enter the values you obtained for *your* ring in Settings.
> This is an interoperability project for a device you own. Not affiliated with Vocci.

> [!IMPORTANT]
> **Status: not yet run.** This port was written without access to Xcode, an iPhone or a ring. The protocol
> logic is verified against the original Java (see [Verification](#verification)); the CoreBluetooth transport,
> the Opus decoding and the SwiftUI screens have never been executed. Read [Unverified assumptions](#unverified-assumptions)
> before you rely on it.

## Build

Requires macOS with Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
cd voxlibre-ios
xcodegen generate          # creates VoxLibre.xcodeproj (git-ignored)
open VoxLibre.xcodeproj    # pick your Team under Signing & Capabilities, run on a real iPhone
```

The Simulator has no Bluetooth, so use a device. A free personal Apple ID team is enough to sideload
(the signature lasts 7 days). Minimum iOS: 16.

Run the unit tests (no simulator needed):

```bash
cd voxlibre-ios
swift test
```

## Setup (in the app)

Open **Settings** (gear icon, top right):

| Field | What it is |
|---|---|
| **Ring** | pick your ring from the Bluetooth scan (wake it and keep it close; it must not be held by another phone/app) |
| **BIND KEY** | the 32-char per-ring secret, from the official app / your account |
| **USER ID** | your account id (`user_…`) |
| **Ring MAC** *(optional)* | only if authentication fails — see below |

BIND KEY and USER ID are stored in the iOS **Keychain** (this device only). Then tap **Connect**.

## Features (same as the Android app)

- **Ring tab** — authenticated status, device info (model / SN / firmware / hardware), telemetry
  (battery, voltage, RSSI, storage), button events, 0x26 gesture monitor, and an optional
  *single click → play/pause* toggle.
- **Recordings tab** — unified list of on-ring + downloaded clips (persisted index, works offline),
  download, play (raw Opus decoded on device), delete from ring / phone. Downloaded `.opus` files are
  also visible in the iOS **Files** app (Documents folder).
- **Logs tab** — real-time TX/RX of the BLE protocol with an "unmapped interactions only" filter,
  share/clear.

## How it maps from Android

| Android | iOS |
|---|---|
| `NordicTransport` (Nordic Android-BLE-Library) | `App/BLETransport.swift` (CoreBluetooth, serialized write queue, notification chaining) |
| `RingProtocol` | `Sources/VoxLibreCore/RingSession.swift` + `RingCrypto.swift`, `Frame.swift`, `Telemetry.swift` |
| `RingLibrary` | `Sources/VoxLibreCore/RingLibrary.swift` |
| `RingGestures` | `Sources/VoxLibreCore/RingGestures.swift` |
| `RingConfig` (SharedPreferences) | `Sources/VoxLibreCore/RingConfig.swift` (+ `App/Storage.swift`: UserDefaults / Keychain) |
| `OpusAudio` (MediaCodec → WAV → MediaPlayer) | `App/OpusAudio.swift` (Core Audio Opus via `AVAudioConverter` → WAV cache → `AVAudioPlayer`) |
| `RingEngine` + `RingViewModel` | `App/RingEngine.swift` (`ObservableObject`) |
| `MainActivity.kt` (Compose) | `App/Views/*` (SwiftUI, same dark/lime look) |

`Sources/VoxLibreCore` is plain Foundation + CryptoKit code behind small protocols (`RingLink`, `Scheduler`,
`KeyValueStore`, `FileStore`), so it is unit-tested on its own. The same files are compiled directly into the
app target (see `project.yml`), which is why nothing there needs `public`.

## Where iOS forced a different design

- **No MAC addresses, no "bonded devices" list.** iOS hides Bluetooth addresses and never lists paired
  devices to apps. The ring is chosen from a scan and remembered by its per-phone peripheral UUID.
- **The handshake needs the MAC.** The HMAC content is `<fwid>_<sn>_<mac>_<nonce>`. On iOS the MAC is read
  from the ring's own `0x80` device-info frame (it sends it byte-reversed; the Android code already parses
  that frame for SN/FWID and notes the reversed MAC). A manual override exists for the case where this
  assumption is wrong.
- **MTU cannot be requested** (Android asked for 247). iOS negotiates its own, so a long frame could arrive
  split across notifications. `FrameAssembler` stitches those back together; frames that arrive whole are
  passed through untouched.
- **No system-wide media key.** Android injects `KEYCODE_MEDIA_PLAY_PAUSE`; iOS has no public equivalent.
  "Single click → play/pause" therefore pauses/resumes the app's own recording player.
- **Background.** `bluetooth-central` and `audio` background modes are enabled, so an established
  connection survives backgrounding and playback continues with the screen locked. There is no Bluetooth
  state restoration: if iOS terminates the app, reconnect manually.

## Deliberate fixes over the Android original

- `downloading` is reset on disconnect (Android left it set, which wedged the library after a link drop
  mid-download until the app was restarted).
- The automatic `.json` duration prefetch tries each file once per connection (an unparsable file was
  re-queued by every refresh, forever).
- Fallback duration for local files is computed from the `.opus` packet count (60 ms each) instead of from
  the WAV size.
- Malformed frames can't crash: `Frame.data` clamps a bogus length where Java would zero-pad or throw, and
  a one-byte `0x01` auth reply is treated as an ordinary ack instead of throwing `StringIndexOutOfBounds`.
- Secrets in the Keychain instead of plain preferences; Logs tab stays visible while disconnected (the
  interesting failures happen before "authenticated").

## Verification

`tools/RefVectors.java` contains the pure functions of the original (`enc`, `hmacHex`, the app-response
construction, `sendRead`/`sendDelete` payloads, `parseDeviceInfo`, the `0xf2`/`0x14` decoders, the WAV
header), copied verbatim, and prints their output for fixed inputs. That output is
`Tests/VoxLibreCoreTests/Vectors.swift`; the Swift tests assert **byte-identical** results, including a full
simulated handshake (proto → device info → user id → challenge → app response → accepted) and sequence-number
wrap-around. Gesture timing, library reconciliation, downloads, offline index and disconnect behaviour are
covered with a virtual-time scheduler.

**What has and has not been run:** the vectors were generated by actually running the Java. The Swift sources
and tests were *not* compiled or executed (no Swift toolchain was available). First thing to do on a Mac:
`swift test`. Expect to fix a few compile nits.

## Unverified assumptions

1. **MAC from the `0x80` frame equals the address the Android app uses.** If auth fails (`verifyRing=false`
   in the Logs, or no `APP-AUTH ACCEPTED`), compare "MAC(from ring)" in the log with the ring's address on an
   Android phone and set the override.
2. **Does the ring require a BLE-level bond?** Android relies on the system bond made by the official app.
   On iOS a bond is created by the system the first time an encrypted characteristic is touched. If the ring
   is still bound to another phone it may refuse a second central — unbind/reset it first.
3. **Opus decoding via Core Audio** (`kAudioFormatOpus`, 60 ms packets, one packet per `convert` call) is the
   one piece with no Android-equivalent certainty. If it fails ("decode failed" in the log), the fallback is
   to decode with libopus (e.g. a Swift package wrapping it) behind `OpusDecoder.decode(packets:)`, which is
   the only function to replace.
4. **Does the ring advertise its service UUID?** The scan lists every named device and marks the ones that
   advertise the Vocci service with a seal; if none is marked, pick by name.

## License

The upstream project ships without a license file, so no license is granted here either. Ask the upstream
author before publishing or redistributing this port.
