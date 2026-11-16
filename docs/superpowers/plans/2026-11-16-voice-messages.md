# Voice Messages Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Family members record voice messages (AAC-LC `.m4a`, up to 10 minutes, with a live waveform), send them end-to-end encrypted through the plan 7 media pipeline, and play them back in a bubble with a scrubbable waveform, one clip at a time, on all six targets.

**Architecture:** A new `voice` plaintext kind carries `{mediaKey, key, sha256, durationMs, waveform, bytes, mime}`; the clip is one encrypted blob (`MediaPurpose.file`) staged with `MediaService.stage` and sent through the outbox, exactly like a photo. Capture and playback sit behind two small interfaces (`VoiceRecorder`, `VoicePlayer`) with `record`/`just_audio` implementations, so a `VoiceRecording` controller (timer, levels, 10-minute cap, permission) and a single app-wide `VoicePlayback` notifier (one player, one clip at a time) are tested with fakes. Files touching `dart:io` live behind a conditional import (`voice_io.dart`).

**Tech Stack:** Flutter 3.50, Riverpod 3, `record` 7.2 (AAC-LC 48 kbps mono 44.1 kHz), `just_audio` 0.10 (+ `just_audio_media_kit` on Linux/Windows), `cross_file` (web blob read), `clock` (fake-time stopwatch). No server change: the server already accepts `kind=voice` up to 8 MiB.

**Spec:** `docs/superpowers/specs/2026-11-15-famchat-design.md` ("Voice messages", "Media storage cap", "Client"). Roadmap row 8. Spike results `docs/spikes/2026-11-platform-spikes.md`. Wire contract extends `docs/protocol.md`.

## Global Constraints

- Voice format: AAC-LC in `.m4a`, `RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 48000, numChannels: 1, sampleRate: 44100)`, mime `audio/mp4`.
- Voice limit 10 minutes (`maxVoiceDuration = Duration(minutes: 10)`), enforced by the client: the recorder auto-stops at the cap and `sendVoice` rejects longer clips. Server byte cap for `voice` stays 8 MiB ciphertext.
- The record button is hidden where `isEncoderSupported(AudioEncoder.aacLc)` is false (Chrome); playback works everywhere.
- Plaintext `voice` kind: `{"kind":"voice","mediaKey","key","sha256","durationMs","waveform","bytes","mime":"audio/mp4"}`; `key`, `sha256` b64url 32 bytes; `waveform` b64url of 0–128 bytes (levels 0–255); `durationMs` 1–900000 on decode (receivers tolerate up to 15 min; senders cap at 10).
- Waveform: 64 peak buckets of the recorder's amplitude stream (sampled every 100 ms), dBFS mapped linearly from −60..0 dB to 0..255.
- `lib/media/` stays Flutter-free except existing exceptions; no `dart:io` outside `lib/voice/voice_io_native.dart`.
- Every audio player dispose is time-boxed (`disposeWithin`, 3 s): a hung native dispose never blocks a test or the UI.
- One build/test process at a time; targeted tests while iterating.

## Review Focus

1. **Microphone denied** (first prompt refused, or blocked in settings) → no recording starts, a snackbar explains, the composer stays usable. Test `denied permission shows the hint and stays idle` (Task 3).
2. **Tapping play on a second voice message while one plays** → the first stops (one player), the second plays. Test `playing another clip stops the first` (Task 3).
3. **Expired voice clip** (evicted while offline, 410) → bubble shows "Voice message expired", play disabled. Test `expired voice shows Voice message expired` (Task 4).
4. **Recording reaches 10 minutes** → it stops itself and sends; the duration sent is exactly the cap, never more. Test `auto-stops at ten minutes` (Task 3).
5. **Native player dispose hangs** (libmpv under xvfb) → the spike fails fast or passes, never hangs; app teardown continues. Test `disposeWithin gives up after the timeout` (Task 1).

---

### Task 1: Time-boxed audio dispose and the Linux spike hang

**Files:** Modify `app/lib/audio_init.dart`, `app/lib/spikes/audio_spike.dart`, `app/integration_test/spikes_test.dart`, `.github/workflows/app.yml`; test `app/test/audio_init_test.dart`.

**Interfaces (Produces):** `Future<void> disposeWithin(Future<void> Function() dispose, {Duration timeout = const Duration(seconds: 3)})` in `audio_init.dart` — never throws, returns after `timeout` at the latest.

- [ ] Failing tests: `disposeWithin gives up after the timeout` (a never-completing dispose returns under fake time after 3 s), `disposeWithin swallows errors`.
- [ ] Implement; `_play` and `probeRecorder`/`recordAndPlay` dispose through it; `playFixture` wraps the whole play in `.timeout(30 s)`; spike tests get `timeout: Timeout(Duration(seconds: 60))`.
- [ ] CI Linux step: run the integration test under `timeout --kill-after=30s 600` and retry once on failure (a native hang that Dart timers can't break is killed, not waited out for 20 min).
- [ ] Run `flutter test test/audio_init_test.dart test/audio_spike_test.dart`; commit.

### Task 2: Voice kind, waveform and previews

**Files:** Create `app/lib/voice/waveform.dart`; modify `app/lib/chat/plaintext.dart`, `app/lib/chat/chat_sync.dart` (`_decrypt` case), `app/lib/screens/chats/chat_list.dart` (preview), `docs/protocol.md`; tests `app/test/voice/waveform_test.dart`, `app/test/chat/plaintext_test.dart` (new), `app/test/chat/chat_sync_test.dart`, `app/test/screens/chat_list_test.dart`.

**Interfaces (Produces):**
- `const maxVoiceDuration = Duration(minutes: 10)`; `const waveformBuckets = 64`.
- `double levelFromDb(double dbfs)` (−60..0 → 0..1, clamped; NaN/−inf → 0).
- `List<int> downsampleWaveform(List<double> levels, {int buckets = waveformBuckets})` → `min(levels.length, …)`-free: exactly `buckets` peaks (0–255) when `levels` is non-empty, `[]` when empty; bucket `i` = max of `levels[i*n~/b .. max((i+1)*n~/b, i*n~/b+1))`.
- `class VoiceBody extends Plaintext {mediaKey, key, sha256, durationMs, waveform (List<int>), bytes, mime='audio/mp4'}` with `MediaRef get ref` extension in `media_service.dart` (`purpose: file`).
- Message kind `voice` in the chat DB; chat list preview `🎤 Voice message` (with `You: `).

- [ ] Failing tests: downsampling (empty, fewer samples than buckets, exact peaks, clamps), `levelFromDb`; VoiceBody round trip, rejects bad mediaKey / short key / durationMs 0 or > 900000 / waveform > 128 bytes / non-int waveform; ChatSync stores an incoming voice as kind `voice`; preview text.
- [ ] Implement; protocol.md documents the kind; commit.

### Task 3: Recording, sending and playback engine

**Files:** Create `app/lib/voice/voice_recorder.dart` (interface + `RecordVoiceRecorder`), `app/lib/voice/voice_player.dart` (interface + `JustVoicePlayer`), `app/lib/voice/voice_io.dart` (+ `_native.dart`, `_web.dart`), `app/lib/voice/recording.dart` (`VoiceRecording` controller), `app/lib/voice/playback.dart` (`VoicePlayback` notifier), `app/lib/voice/providers.dart`; modify `app/lib/media/media_service.dart` (`sendVoice`), `app/pubspec.yaml` (`clock`, `cross_file`); tests `app/test/voice/recording_test.dart`, `app/test/voice/playback_test.dart`, `app/test/media/media_service_test.dart`, `app/test/support/fake_voice.dart`.

**Interfaces (Produces):**
- `abstract interface class VoiceRecorder { Future<bool> supported(); Future<bool> permission(); Future<void> start(); Stream<double> levels(); Future<Uint8List?> stop(); Future<void> cancel(); Future<void> dispose(); }` (levels 0–1, every 100 ms).
- `class RecordedVoice {Uint8List bytes; Duration duration; List<int> waveform;}`.
- `class VoiceRecording extends ChangeNotifier` — `status` (`idle|starting|recording|denied|failed`), `elapsed`, `recentLevels`, `Future<void> start()`, `Future<RecordedVoice?> finish()`, `Future<void> cancel()`, `onAutoStop` callback with the finished clip at `maxVoiceDuration`. Elapsed uses `clock.stopwatch()`; a 100 ms ticker notifies.
- `MediaService.sendVoice(String chatId, RecordedVoice v) → Future<String>`; throws `ArgumentError` for empty bytes, duration ≤ 0 or > `maxVoiceDuration`, or too large.
- `abstract interface class VoicePlayer { Future<Duration?> load(String id, Uint8List bytes); Future<void> play(); Future<void> pause(); Future<void> seek(Duration d); Stream<Duration> get position; Stream<bool> get playing; Stream<void> get completed; Future<void> dispose(); }`.
- `VoicePlayback` (Riverpod `Notifier<PlaybackState>`): `PlaybackState {String? messageId; bool loading, playing; Duration position; Duration? duration; Object? error}`; `toggle(String messageId, Future<Uint8List?> Function() bytes)`, `seek(String messageId, double fraction, Future<Uint8List?> Function() bytes)`, `stop()`. One lazily made `VoicePlayer`, disposed with `disposeWithin`.
- Providers: `voiceRecorderFactoryProvider`, `voicePlayerFactoryProvider`, `voiceRecordingSupportedProvider` (FutureProvider<bool>), `voicePlaybackProvider`.

- [ ] Failing tests (fakes): `records and finishes with a 64-bucket waveform and the elapsed duration`, `cancel discards`, `denied permission shows the hint and stays idle`, `auto-stops at ten minutes` (duration == 10:00), `sendVoice stages one voice blob and queues a voice message`, `sendVoice rejects over ten minutes`, `playing another clip stops the first`, `completion resets to the start`, `null bytes (expired) leaves it stopped`, `dispose is time-boxed`.
- [ ] Implement; commit.

### Task 4: Composer record bar and voice bubble

**Files:** Create `app/lib/screens/chats/voice_bubble.dart`, `app/lib/screens/chats/record_bar.dart`; modify `conversation_view.dart`, `message_bubble.dart`; tests `app/test/screens/voice_test.dart`, `app/test/support/chat_harness.dart` (voice overrides).

**Decisions:** tap-to-start, then send (✓) or discard (🗑) — works with a mouse and a screen reader; the mic button replaces Send while the composer is empty, hidden when recording isn't supported. Bubble: play/pause, waveform bars (played part in primary colour), tap/drag on the waveform seeks, `m:ss` (position while current, else total), upload ring on own pending clips, expired and error states.

- [ ] Failing widget tests: `mic shows when the composer is empty and send when it has text`, `no mic where AAC recording isn't supported`, `recording shows the timer and sends a voice message`, `discard sends nothing`, `incoming voice plays and pauses`, `scrubbing seeks`, `expired voice shows Voice message expired`, `voice messages can be reacted to`.
- [ ] Implement; check iOS/macOS usage strings, macOS `audio-input` in Debug and Release entitlements, Android `RECORD_AUDIO` (all already present from plan 2); commit.

### Task 5: Finish

- [ ] Full `flutter analyze` + `flutter test`; one `flutter build web --release`.
- [ ] Fresh Opus whole-branch review (foreground); fix Critical/Important with TDD.
- [ ] `git fetch && git merge origin/main`, re-run tests, push, PR, CI green.
