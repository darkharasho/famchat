# Platform spikes, November 2026

Plan: `docs/superpowers/plans/2026-11-16-app-skeleton-spikes.md`. These are the results of the plan 2 spikes:
the Flutter app ran its crypto, database, WebSocket and audio checks on all six targets.

## How it was run

- **CI** (`.github/workflows/app.yml`, PR #1) runs `integration_test/spikes_test.dart` on GitHub-hosted runners.
  Each check prints a line of the form `SPIKE <name> <platform> <result>`:
  - Linux desktop runs under xvfb with a PulseAudio null sink.
  - Web runs in headless Chrome through `flutter drive`, with autoplay allowed.
  - Windows and macOS desktop.
  - iOS runs on a simulator.
  - Android runs on an API 34 x86_64 emulator, in profile mode (see "Android crypto timing").
- **Locally** (Fedora Atomic, Flutter 3.50) the same tests ran on Linux desktop and in headless Chrome for Testing 157,
  plus the manual record check below.
- The WebSocket check talks to `tool/echo_server.dart` on the same machine. On Android that's the host at `10.0.2.2`.

## Results

| Platform | Crypto, 100 envelopes (limit 2 s) | Database reopen | WebSocket (text, 64 KB, binary) | AAC `.m4a` playback | Recorder: AAC | Recorder: Opus | Manual "record 3 s" |
|---|---|---|---|---|---|---|---|
| Linux | 552 ms | ok | ok, 14 ms | ok, 2000 ms | yes | yes | AAC ok (see below) |
| Web (Chrome) | 236 ms | ok | ok, 47 ms | ok, 2000 ms | **no** | yes (WebM) | AAC fails; Opus ok |
| Windows | 980 ms | ok | ok, 32 ms | ok, 2023 ms | yes | **no** | on device, plan 4/12 |
| macOS | 226 ms | ok | ok, 32 ms | ok, 1975 ms | yes | yes | on device, plan 4/12 |
| iOS (simulator) | 466 ms | ok | ok, 87 ms | ok, 1975 ms | yes | yes | on device, plan 4/12 |
| Android (emulator, profile) | 597 ms | ok | ok, 13 ms | ok, 2000 ms | yes | yes | on device, plan 4/12 |

Notes:
- **Crypto:** each of the 100 iterations encrypts and signs a 1 KB envelope, then verifies and decrypts it.
  The unit-test version (`test/crypto_spike_test.dart`) took 520 ms on the Dart VM and 623–668 ms in Chrome
  (`flutter test --platform chrome`). Ed25519, X25519 and XChaCha20 run in pure Dart everywhere:
  `cryptography_flutter` only hands Ed25519 and X25519 to the OS on Apple platforms, and our message sizes
  are below its 10 KB threshold for background ciphers. The server accepted a device certificate made by
  the Dart code (`server/test/lib.test.ts`, "accepts Dart-generated cert").
- **Recorder** columns show `AudioRecorder.isEncoderSupported`. Microphone permission was granted on the
  desktop runners and not on the CI simulator or emulator. The permission prompt itself gets checked on
  real devices.
- **Playback** uses `just_audio`, with `just_audio_media_kit` (libmpv) on Linux and Windows. Apple platforms report 1975 ms, which is within the 1.8–2.2 s
  bound (likely AAC encoder priming); `reachedEnd` was true everywhere.

### Android crypto timing

The first CI run used `flutter test integration_test`, which is a debug (JIT) build, and took **65 223 ms**
for 100 envelopes on the emulator. KVM acceleration was on. The same Dart code takes under 1 s on every other
target. Users run AOT release builds, so the Android job now uses `flutter drive --profile`. That run took **597 ms**.
Low-end physical phones get checked when the first builds are installed (plan 4/12).

### Manual "record 3 s"

- **Linux desktop:** recorded 3 s with the app's settings (AAC-LC, 48 kbps, mono, 44.1 kHz). `ffprobe`
  shows a valid MP4 with an `aac` LC stream, 1 channel, 44 100 Hz, 48.5 kbps, 2.90 s long. Opus recording
  produced a valid `.ogg`. Playing the recording back wasn't checked locally, because this machine has no
  libmpv. CI's Linux job plays the same format.
- **Chrome** (headless, fake microphone): AAC fails at `start` with "Encoder AudioEncoder.aacLc not
  supported". Opus records to a blob, which `record_web` writes as `audio/webm; codecs=opus`.
- **Phones, Mac and Windows:** checked on real devices when the first builds are installed (plans 4 and 12).

## Voice format decision

The rule from the plan:

> AAC-LC `.m4a` if every platform can play it and every platform whose recorder supports AAC records it.
> Platforms that can't record AAC record Opus `.ogg` only if all six can play Opus; otherwise transcoding
> is out of scope and those platforms ship playback-only voice in v1.

- AAC `.m4a` played to the end on all six platforms, and all five recorders that support AAC recorded it.
  **Voice messages are AAC-LC `.m4a`, about 48 kbps, mono.**
- Chrome can't record AAC. Its Opus output is WebM, not Ogg, and AVFoundation on iOS and macOS doesn't play
  WebM. Windows can't even record Opus, so Opus fails the "all six" test. **Browsers that can't record AAC
  are playback-only for voice in v1.** The app checks `isEncoderSupported(AudioEncoder.aacLc)` at runtime,
  so a browser whose MediaRecorder accepts `audio/mp4;codecs=mp4a` (what `record_web` asks for; Safari is
  expected to, untested) still gets the record button.
  Firefox wasn't tested; it falls under the same runtime check.

## Follow-ups

- Plan 8 (voice): hide the record button where `isEncoderSupported(aacLc)` is false, and show a short
  "Recording isn't available in this browser" hint.
- Plans 4 and 12: on real devices, check the microphone permission prompt and record-then-play, and
  measure crypto speed on a low-end Android phone.
- Linux packaging (plan 12): the AppImage has to bundle libmpv, or declare it as a dependency, for playback.
