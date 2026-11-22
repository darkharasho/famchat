# Batch 5: voice transcripts (on-device)

## Intent

Voice messages get their words written underneath, so family members can read a clip when they
can't listen, skim it, and find it in search. The user chose on-device transcription (2026-11-21):
audio and text never leave a device except inside the end-to-end encrypted message. Workers AI, the
OS cloud recognizers and the browser Web Speech API (Chrome sends audio to Google) are all out.

## Goals

- The sender's device transcribes each voice clip it sends and attaches the text, encrypted, to the
  message. Everyone in the chat sees it under the clip and can search it.
- The same transcription quality on iOS, Android, macOS, Windows and Linux.
- A reader can transcribe a clip that came without a transcript (from the web, an old app, or a
  sender with transcripts off) on their own device. That text stays on that device.

## Non-goals

- Live captions while recording, or transcripts on the web (no model there; web shows received ones).
- Editing a transcript, translation, and transcripts of video soundtracks.

## Anti-goals

- Anything that sends audio or transcript text to the server or a third party in the clear.
- Holding up the voice message itself: the clip sends exactly as today, and the transcript follows.
- Downloading about 160 MB without the person asking for it.

## Approaches

1. **OS recognizers** (SFSpeechRecognizer, Android on-device SpeechRecognizer): no download, but only
   Apple platforms work well. Android works only patchily, Windows and Linux not at all.
2. **Bundled Whisper through sherpa-onnx** (chosen; user said "your call" 2026-11-22): it's the
   official k2-fsa package, with prebuilt native libraries for all five native platforms and samples
   fed in from Dart. The cost is a one-time model download and a full native release.
3. **whisper.cpp packages** (`whisper_ggml` and similar): smaller models (about 57 MB), but they depend
   on ffmpeg_kit to read audio, which doesn't cover Windows or Linux. They're also less maintained.

## Design

### Wire format

A new change kind, sent by the clip's sender after the clip:
`{"kind":"transcript", "target":"<voice message id>", "text":"…", "lang":"en"}`.
- `text` is 1–20 000 characters and `lang` is optional (Whisper's detected language).
- It counts only when the target is a `voice` message from the same sender, and the latest one wins.
- Like edits, it carries the target's `disappearSecs`, goes away with the target, and isn't pushed as
  a notification. Old clients show unknown kinds as unsupported, so the receive side ships first (below).

### Model

- Whisper **base** multilingual, sherpa-onnx int8 export: encoder 29 MB, decoder 131 MB, tokens 0.8 MB.
  The Silero VAD model (about 2 MB) splits long clips into speech segments of 30 s or less, since
  Whisper's window is 30 s.
- Downloaded from the `csukuangfj/sherpa-onnx-whisper-base` Hugging Face repo, pinned to a commit,
  with every file's SHA-256 checked. It's kept in app support storage (not cache).
- The only network traffic is the model download, which reveals nothing about any message.

### Decoding clips to 16 kHz mono PCM

A small local plugin (`app/packages/voice_pcm`) turns an `.m4a` file into Float32 samples:
- **iOS/macOS:** AVAudioFile and AVAudioConverter (shared darwin source).
- **Android:** MediaExtractor and MediaCodec.
- **Windows/Linux:** the libmpv the app already ships for playback (`ao=pcm`, `untimed`, 16 kHz mono).
  libmpv is used directly over FFI or through media_kit's NativePlayer; that choice is the builder's,
  after a spike on Linux.

Transcription runs in a background isolate. Sherpa's resampler is a fallback if the decoder returns a
different sample rate.

### Settings

A **Voice transcripts** section, hidden on the web:
- A toggle, **Transcribe my voice messages**, off by default. Turning it on starts the download and
  shows its size and progress, with cancel.
- **Remove model**, to free the space. Turning the toggle off keeps the model unless removed.

### Sending

When a voice message is sent with transcripts on and the model ready:
- The app transcribes the clip from the bytes it already has (a temp file in the voice cache dir,
  deleted afterwards), then sends the `transcript` change.
- Silence (empty text) sends nothing.
- If the app quits before the transcript is done, it's simply lost. A reader can still transcribe locally.

### Reading

- The voice bubble shows the transcript under the waveform, three lines collapsed with a tap to expand.
- While the sender's transcript is pending nothing shows. The receiver has no way to know one is coming.
- On any voice message without a transcript, the message menu has **Transcribe**:
  - If the model isn't installed, it offers the download first, using the same flow as Settings.
  - The result is stored locally only, in a new drift table or column (schema 14), and labelled
    "Transcribed on this device".
  - A transcript sent later by the sender replaces it.
- Search matches transcripts, with hits shown as `🎤 <snippet>`.
- Push previews stay "🎤 Voice message".

### Shipping in two steps

- **5a (Dart-only, desktop release plus phone patch):** parse, store and show the `transcript` kind;
  search; protocol docs. Every app, including the iPhone App Store build, learns the kind before
  anyone sends one.
- **5b (native, full release):** sherpa_onnx, the voice_pcm plugin, model download, Settings, sending,
  local Transcribe.

## Calls made after the builder check (mine, 2026-11-22)

- **Gate for 5b:** release order only, no server or version gate. 5a goes out days before 5b. Desktops
  auto-update and phones take the patch on next launch. A device that never updates sees an
  "unsupported" row per transcript. That's acceptable for one family, and a gate isn't worth its cost.
- **Scheduled voice clips:** no automatic transcript, so nothing leaks before `deliverAt`. Readers, and
  the sender after delivery, can use Transcribe.
- **Sender taps Transcribe on their own clip:** the result is sent to the chat as a `transcript`
  change, since it's the sender's words and only the sender's transcript counts. On anyone else's
  clip it stays local.
- **Forwarding:** if the original has a shared transcript, the forwarder's device sends a copy as a
  `transcript` for the new message. Otherwise nothing is sent, and the forwarder's device does no
  automatic transcription.
- **Long clips:** automatic transcription only for clips up to 3 minutes. Longer clips get Transcribe
  in the menu, which follows the rules above. Work happens while the app is running. If it's killed,
  the transcript is lost, as stated above.

## Left to the builder

- Whether Windows and Linux use FFI or NativePlayer for decoding, and the exact UI copy.
- Where the local transcript is stored, and the isolate plumbing.
- Test seams: a fake transcriber in tests. Real-model tests stay out of CI.
