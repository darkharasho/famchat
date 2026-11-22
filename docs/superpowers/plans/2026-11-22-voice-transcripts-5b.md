# Voice transcripts 5b (on-device transcription) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The sender's device transcribes its own voice clips with Whisper (through sherpa-onnx) and
sends the text as a `transcript` change, which 5a already shows. Readers can transcribe any clip
locally.

**Architecture:**
- `decodeToPcm` turns an `.m4a` into mono Float32 samples. Darwin and Android use a small local
  plugin, `voice_pcm`. Linux and Windows use media_kit's `NativePlayer` with `ao=pcm` (spiked
  2026-11-22 against the app's bundled libmpv: a 3 s clip decoded in 58 ms).
- `TranscriptModel` downloads and verifies the Whisper files.
- `SherpaTranscriber` runs VAD and Whisper in a background isolate.
- `TranscriptsService` connects these to sending, forwarding and the message menu.
- Local-only transcripts live in a new drift table (schema 14).

**Tech Stack:** Flutter, Riverpod, drift, sherpa_onnx 2.0.3, media_kit 1.2.6, Swift
(AVAudioFile/AVAudioConverter) and Kotlin (MediaExtractor/MediaCodec).

**Spec:** `docs/superpowers/specs/2026-11-22-voice-transcripts-design.md` (5a shipped as 1.0.38).

## Global Constraints

- No audio or transcript text leaves the device except inside the E2E `transcript` change. The model
  download is the only new network traffic.
- Model files are pinned to Hugging Face `csukuangfj/sherpa-onnx-whisper-base` at commit
  `bb53ee204431c90d314c1cc08d28d23e5b7927cc`, from
  `https://huggingface.co/csukuangfj/sherpa-onnx-whisper-base/resolve/<commit>/<file>`:
  - `base-encoder.int8.onnx`: 29120534 bytes, sha256 `0b8fb1304b6109976038efff5ace81720e00386f3ff6b54ee8c75291ca0a1e11`
  - `base-decoder.int8.onnx`: 130672026 bytes, sha256 `9759d217388a01b3a4c7c15533201067b48ae819c4daafc8624e64b9409dc02d`
  - `base-tokens.txt`: 816730 bytes, sha256 `b34b360dbb493e781e479794586d661700670d65564001f23024971d1f2fa126`
- The Silero VAD model is bundled as the asset `assets/models/silero_vad.onnx` (643854 bytes,
  sha256 `9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6`, from sherpa-onnx's
  `asr-models` release). It isn't downloaded.
- Model directory: `<getApplicationSupportDirectory()>/transcripts/whisper-base-bb53ee2/`. Download to
  `<file>.part`, then rename once the SHA-256 matches.
- Copy, as fixed by the spec:
  - Settings section **Voice transcripts**, with the toggle **Transcribe my voice messages** (off by
    default) and **Remove model**.
  - The menu item **Transcribe**.
  - The label **Transcribed on this device**.
- Automatic transcription only when all of these hold: the toggle is on, the model is ready, the clip
  isn't scheduled (`at == null`), and the clip is at most 3 minutes long. Empty text sends nothing.
- On the web: no Settings section and no Transcribe item, and no import of `sherpa_onnx` or `voice_pcm`
  (put them behind `if (dart.library.io)` conditional imports). `flutter build web` must still pass.
- Never run `dart format`. `flutter test --concurrency=1` on the targeted files. `dart analyze` must
  be clean.
- This is native: it ships as a full `v1.0.39` tag release (later than desktop-only 1.0.38), not as a
  patch.

## Review Focus

- **A clip deleted or disappearing while its transcription runs:** don't send the transcript or store
  a local one. Check `messageById` and `isDeleted` again after transcribing. Tests in Tasks 5 and 6.
- **Local transcripts outliving their message:** `purgeMessages` and `deleteMessages` must remove the
  `local_transcripts` rows too, or text from disappearing chats stays on disk. Test in Task 6.
- **Toggling transcripts on with the app killed mid-download:** `.part` files left behind mustn't
  count as ready. A later start resumes or restarts, and the size check catches truncation. Test in
  Task 2.
- **Several clips sent quickly:** transcriptions run one at a time, so two 160 MB decoders don't load
  at once on a phone. Test in Task 3 (fake transcriber records concurrency).
- **A transcript over 20 000 characters, or with only whitespace:** truncate to `maxTranscriptLength`
  and trim, and send nothing when it's empty. Test in Task 5.

---

### Task 1: Decode clips to PCM

**Files:**
- Create: `app/packages/voice_pcm/` (Flutter plugin: `pubspec.yaml` with `ios`, `macos` (`sharedDarwinSource: true`) and `android` platforms; `darwin/voice_pcm/Sources/voice_pcm/VoicePcmPlugin.swift` plus `Package.swift` and podspec; `android/src/main/kotlin/dev/famchat/voice_pcm/VoicePcmPlugin.kt`; `lib/voice_pcm.dart`)
- Create: `app/lib/transcripts/pcm.dart` (the `decodeToPcm` dispatch) and `app/lib/transcripts/pcm_desktop.dart` (media_kit)
- Modify: `app/pubspec.yaml` (`voice_pcm: {path: packages/voice_pcm}`, `sherpa_onnx: 2.0.3`, and the asset `assets/models/silero_vad.onnx`)
- Test: `app/test/transcripts/pcm_test.dart`

**Interfaces:**
- Produces:
  - `class Pcm { const Pcm(this.samples, this.sampleRate); final Float32List samples; final int sampleRate; }`
  - `Future<Pcm> decodeToPcm(String m4aPath)` in `lib/transcripts/pcm.dart`: mono output, and 16000 Hz
    where the platform can resample.
  - It throws `PcmException(String)` on failure.
- Platform channel: `MethodChannel('voice_pcm')`, method `decode` with `{path}`, which returns
  `{samples: Float32List, sampleRate: int}`.
  - Darwin: `AVAudioFile` to `AVAudioConverter` with output format float32, 16000 Hz, 1 channel.
  - Android: `MediaExtractor` and `MediaCodec`. Decode to 16-bit PCM, downmix to mono and convert to
    float, keeping the source rate.
  - Do the work off the main thread: a background `DispatchQueue` on darwin, and a thread or executor
    on Android.
- Desktop (Linux/Windows), using the spike recipe:
  - Create a `Player()` and get its `platform as NativePlayer`.
  - `setProperty` these before `open`: `ao=pcm`, `ao-pcm-file=<tmp>.f32`, `ao-pcm-waveheader=no`,
    `audio-samplerate=16000`, `audio-channels=mono`, `audio-format=float`, `untimed=yes` and
    `keep-open=no`.
  - `open(Media(path))`, wait for `stream.completed` to be true (time out after 60 s), then `dispose()`.
  - Read the file as `Float32List`, then delete it.

- [ ] **Step 1: Write the failing tests:**
  - `decodeToPcm uses the voice_pcm channel off the desktop`: set `debugDefaultTargetPlatformOverride = TargetPlatform.android`, mock the channel to return 3 samples at 44100, and expect `Pcm.samples.length == 3` and `sampleRate == 44100`.
  - `a channel error is a PcmException`: the mock throws `PlatformException` → `throwsA(isA<PcmException>())`.
  - `desktop decode via libmpv`: this one is skipped unless the env var `FAMCHAT_LIBMPV` is set.
    - It calls `MediaKit.ensureInitialized(libmpv: env)` and generates no file itself: it uses a
      committed 1 s `test/fixtures/tone.m4a` (440 Hz, made with `ffmpeg -f lavfi -i sine=frequency=440:duration=1 -c:a aac`).
    - Expect `sampleRate == 16000`, a length within 15500–16600, and a peak above 0.05.
- [ ] **Step 2: Run** `cd app && flutter test --concurrency=1 test/transcripts/pcm_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** the plugin, `pcm.dart` and `pcm_desktop.dart`, and add the deps and the VAD asset (copy it from the sherpa-onnx release and check its sha256 against the one above).
- [ ] **Step 4: Run** the same command. Expected: PASS. Run the libmpv test once locally with `FAMCHAT_LIBMPV=$(ls /run/user/$UID/famchat-libs-*/libmpv.so.1 | head -1)` and `LD_LIBRARY_PATH` set to that directory. Expected: PASS. Run `dart analyze`: clean.
- [ ] **Step 5: Commit** `git add -A app/packages/voice_pcm app/lib/transcripts app/test app/pubspec.* app/assets/models && git commit -m "Transcripts: decode voice clips to PCM"`. Push the branch so CI builds the iOS, macOS, Android, Windows and web jobs early: the native code has no other check. If the ios/macos jobs skip on PRs, run `gh workflow run release.yml --ref <branch> -f platforms=ios,macos -f store_upload=false`.

### Task 2: Model download

**Files:**
- Create: `app/lib/transcripts/model.dart`
- Test: `app/test/transcripts/model_test.dart`

**Interfaces:**
- Produces:
  - `sealed class ModelState`, with `ModelAbsent()`, `ModelDownloading(int received, int total)`,
    `ModelReady(ModelPaths paths)` and `ModelFailed(String message)`.
  - `class ModelPaths { final String encoder, decoder, tokens, vad; }`.
  - `class TranscriptModel extends Notifier<ModelState>`, with methods `Future<void> download()`,
    `void cancel()` and `Future<void> remove()`.
  - `final transcriptModelProvider = NotifierProvider<TranscriptModel, ModelState>(...)`, plus
    `const modelDownloadBytes = 29120534 + 130672026 + 816730;`.
  - The constructor seams are `http.Client` and the base directory (overridable providers
    `modelHttpClientProvider` and `modelDirProvider`).
- `build()` checks for ready: all three files are present with the exact sizes (no hashing on each
  start), and the VAD asset has been copied to `<dir>/silero_vad.onnx`. Otherwise the state is absent.
- `download()` skips files that are already complete. For the rest:
  - it streams each file to `.part`, hashing as it goes, and updates `received`;
  - if the hash matches it renames the file, otherwise it deletes the `.part` and sets
    `ModelFailed('The download was damaged. Try again.')`.
- `cancel()` aborts and deletes the `.part` files. `remove()` deletes the directory and sets the state
  to `ModelAbsent`.

- [ ] **Step 1: Write the failing tests** (`MockClient` from `package:http/testing.dart` serving fake small files; override `modelDirProvider` with a temp dir; inject a test-only file table into `TranscriptModel` through a `modelFilesProvider` override so the fakes have matching sizes and hashes):
  - `absent until every file is there with its size`: an empty dir → `ModelAbsent`. A `.part` left behind → still `ModelAbsent`.
  - `download reports progress, verifies, and is ready`: the states seen include `ModelDownloading` with increasing `received`, and the last state is `ModelReady`.
  - `a bad hash fails and leaves nothing`: `ModelFailed`, with no file or `.part` in the dir.
  - `cancel stops and cleans up`, and `remove deletes the files and goes absent`.
- [ ] **Step 2: Run** `cd app && flutter test --concurrency=1 test/transcripts/model_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** `model.dart` with the pinned table from Global Constraints as `modelFilesProvider`'s default.
- [ ] **Step 4: Run** the same command. Expected: PASS. `dart analyze`: clean.
- [ ] **Step 5: Commit** `git commit -am "Transcripts: model download"` (after `git add app/lib/transcripts/model.dart app/test/transcripts/model_test.dart`).

### Task 3: Transcriber

**Files:**
- Create: `app/lib/transcripts/transcriber.dart` (interface, queue and provider), `app/lib/transcripts/sherpa_transcriber.dart` (io only)
- Test: `app/test/transcripts/transcriber_test.dart`

**Interfaces:**
- Consumes: `decodeToPcm` (Task 1), and `ModelPaths` and `transcriptModelProvider` (Task 2).
- Produces:
  - `class TranscriptResult { const TranscriptResult(this.text, this.lang); final String text; final String? lang; }`.
  - `abstract class Transcriber { Future<TranscriptResult> transcribe(String m4aPath, ModelPaths paths); }`.
  - `class SerialTranscriber implements Transcriber`, which wraps another transcriber and runs one job
    at a time, in order.
  - `final transcriberProvider = Provider<Transcriber>(...)`, which gives
    `SerialTranscriber(SherpaTranscriber())` on io and a throwing stub on web.
- `SherpaTranscriber.transcribe`:
  - It runs `decodeToPcm` on the calling isolate (plugins need the root isolate), then
    `Isolate.run`.
  - Inside the isolate: `initBindings()`, then the VAD. That's `SileroVadModelConfig(model: vad,
    threshold: 0.5, minSilenceDuration: 0.5, minSpeechDuration: 0.25, maxSpeechDuration: 20,
    windowSize: 512)` and `VadModelConfig(sampleRate: 16000, numThreads: 1)`.
  - If the sample rate isn't 16000, resample first with sherpa's `LinearResampler`.
  - For each speech segment, create a stream on one `OfflineRecognizer` with
    `OfflineWhisperModelConfig(encoder, decoder, language: '', task: 'transcribe')`, `tokens` and
    `numThreads: 2`, then decode.
  - Join the segment texts with a space and trim. `lang` is the first segment's `result.lang`, or null
    if it's empty.
  - Free the native objects in a `finally`.

- [ ] **Step 1: Write the failing tests** (`SerialTranscriber` only; the real model stays out of CI):
  - `runs one job at a time, in order`: a fake that tracks in-flight jobs and completes each from a `Completer`. Start 3 jobs and expect the maximum in flight to be 1, with results in call order.
  - `a failing job doesn't block the next`: the first throws, and the second still completes.
- [ ] **Step 2: Run** `cd app && flutter test --concurrency=1 test/transcripts/transcriber_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** both files.
- [ ] **Step 4: Run** the same command. Expected: PASS. Manual check (not committed): with the model downloaded into a temp dir, a throwaway test transcribes `test/fixtures/tone.m4a` without crashing, plus a recorded clip of speech, and the text is sensible. `dart analyze`: clean.
- [ ] **Step 5: Commit** `git commit -m "Transcripts: Whisper transcriber"` (after `git add`).

### Task 4: Settings

**Files:**
- Create: `app/lib/settings/voice_transcripts.dart` (pref key `voice_transcripts`, `SharedPreferencesAsync`, `voiceTranscriptsProvider` as an `AsyncNotifierProvider<…, bool>`, copied from the `close_to_tray.dart` pattern, default false)
- Modify: `app/lib/screens/settings_screen.dart` (a `_VoiceTranscriptsSection`, shown only when `!kIsWeb`)
- Test: `app/test/screens/voice_transcripts_settings_test.dart`

**Interfaces:**
- Consumes: `transcriptModelProvider` and `modelDownloadBytes` (Task 2).
- Produces: `voiceTranscriptsProvider` (bool, whether to transcribe my clips).
- UI:
  - A `SwitchListTile` **Transcribe my voice messages**. Its subtitle depends on the state:
    - absent: "Downloads a 160 MB speech model. Audio never leaves this device."
    - downloading: a `LinearProgressIndicator` plus "Downloading… N of 160 MB" and a **Cancel** button.
    - failed: the message plus **Try again**.
    - ready: "Your voice messages get a written transcript."
  - Turning it on sets the pref and calls `download()` if the model isn't ready.
  - **Remove model** is a `ListTile`, shown when the model is ready. It confirms first, then calls
    `remove()`. It doesn't change the toggle.

- [ ] **Step 1: Write the failing widget tests** (override `transcriptModelProvider` with a fake notifier; `SharedPreferencesAsyncPlatform` fake as existing settings tests do):
  - `toggling on with no model starts the download`: tap the switch, then expect the fake's `download` to have been called once and the pref to be true.
  - `shows progress and cancel while downloading`.
  - `remove model only when ready, and asks first`.
- [ ] **Step 2: Run** `cd app && flutter test --concurrency=1 test/screens/voice_transcripts_settings_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** the setting and the section.
- [ ] **Step 4: Run** the same command. Expected: PASS. `dart analyze`: clean.
- [ ] **Step 5: Commit** `git commit -m "Transcripts: settings"` (after `git add`).

### Task 5: Send transcripts (after sending, and when forwarding)

**Files:**
- Modify: `app/lib/chat/chat_sync.dart` (`sendTranscript`, next to `editText` at about line 863)
- Create: `app/lib/transcripts/transcripts_service.dart`
- Modify: `app/lib/screens/chats/conversation_view.dart` (`_sendVoice`, around line 745: after `sendVoice` returns, call `afterVoiceSent`)
- Modify: `app/lib/chat/forward.dart` (the `VoiceBody` branch)
- Test: `app/test/transcripts/transcripts_service_test.dart`, `app/test/chat/forward_test.dart` (extend the existing forward tests)

**Interfaces:**
- Consumes: `transcriberProvider` (Task 3), `transcriptModelProvider` (Task 2),
  `voiceTranscriptsProvider` (Task 4), and 5a's `TranscriptBody` and `MessageChanges.transcriptOf`.
- Produces:
  - `Future<String?> ChatSync.sendTranscript(String chatId, String messageId, String text, {String? lang})`:
    - It trims the text and truncates it to `maxTranscriptLength`. Empty text returns null without
      sending.
    - It runs in `_enqueue`, like `attachPreview`.
    - It sends only when `messageById(messageId)` is this user's `voice` message in `chatId` and not
      deleted (check `messageChanges` over `changesTo`). Otherwise it returns null.
    - It uses `_enqueueMessage(chatId, TranscriptBody(messageId, t, lang: lang), targetId: messageId)`.
  - `class TranscriptsService`, with `Future<void> afterVoiceSent(String chatId, String messageId, RecordedVoice v, {required bool scheduled})`:
    - It runs the Global Constraints gate.
    - It writes `v.bytes` to a temp `.m4a` under `getTemporaryDirectory()/voice-transcribe/`, and
      deletes it in a `finally`.
    - It transcribes, then calls `sendTranscript`.
    - Errors are caught and logged with `debugPrint`, never shown to the user.
  - `transcriptsServiceProvider`.
- Forwarding: in `forwardMessage`, after `forwardMedia` returns `id` for a `VoiceBody`, a non-null
  `changes.transcriptOf(message)` gets `await sync.sendTranscript(toChatId, id, t)`. If the original
  body has a `lang`, it is not read here; send `lang: null`.

- [ ] **Step 1: Write the failing tests** (fake `Transcriber`, fake model state `ModelReady`, in-memory `ChatDb` and `ChatSync` as `chat_sync_test.dart` builds them):
  - `sends the transcript after an unscheduled short clip`: after `afterVoiceSent(chat, id, clip(60 s), scheduled: false)` there's one pending `transcript` row targeting `id`, with the fake's text.
  - `nothing when off, not ready, scheduled, over 3 minutes, or silent`: one case each, and none adds a row.
  - `sendTranscript trims, truncates to 20000, and skips others' or deleted clips`.
  - `a clip deleted while transcribing gets no transcript`: the fake transcriber deletes the clip before it returns, and no row is added.
  - In `forward_test.dart`: `forwarding a voice clip copies its transcript` (a pending transcript targets the new id), and `forwarding one without a transcript sends none`.
- [ ] **Step 2: Run** `cd app && flutter test --concurrency=1 test/transcripts/transcripts_service_test.dart test/chat/forward_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement**, wiring `afterVoiceSent` in `_sendVoice` with `unawaited(...)` so the clip send isn't held up, passing `scheduled: _scheduleAt != null`.
- [ ] **Step 4: Run** the same command. Expected: PASS. `dart analyze`: clean.
- [ ] **Step 5: Commit** `git commit -am "Transcripts: send after voice messages and forwards"` (add the new files first).

### Task 6: Transcribe from the menu, and local transcripts

**Files:**
- Modify: `app/lib/chat/db/chat_db.dart`:
  - a new table `LocalTranscripts` (`messageId` text primary key, `chatId`, `body` text, `createdAt`
    int) and `schemaVersion` 14 with `if (from < 14) await m.createTable(localTranscripts);`;
  - `Stream<Map<String, String>> watchLocalTranscripts(String chatId)` and
    `Future<void> putLocalTranscript(...)`;
  - delete the rows in `purgeMessages` and `deleteMessages`;
  - one more `OR (m.kind = 'voice' AND EXISTS (SELECT 1 FROM local_transcripts l WHERE l.message_id = m.id AND l.body LIKE ? ESCAPE '\\'))` in `searchCandidates`.
- Modify: `app/lib/chat/search.dart` (pass a local-transcript lookup: `db.localTranscriptOf(id)`. The shared transcript wins over the local one.)
- Modify: `app/lib/transcripts/transcripts_service.dart`: `Future<void> transcribeMessage(MessageRow m)`
- Modify: `app/lib/screens/chats/message_bubble.dart` (`MessageAction.transcribe` with `(Icons.subtitles_outlined, 'Transcribe')`, an `onTranscribe` callback, and a `bool localTranscript` passed to `VoiceBubble`)
- Modify: `app/lib/screens/chats/voice_bubble.dart` (`localTranscript` shows "Transcribed on this device" in `labelSmall` under the text, and `transcribing` shows "Transcribing…")
- Modify: `app/lib/screens/chats/conversation_view.dart` (watch the local transcripts, show `changes.transcriptOf(m) ?? local[m.id]`, and offer `onTranscribe` when the message is voice, `!kIsWeb`, has no transcript of either kind, and the clip hasn't expired)
- Test: `app/test/chat/local_transcripts_test.dart`, `app/test/transcripts/transcripts_service_test.dart`, `app/test/screens/voice_transcript_test.dart`

**Interfaces:**
- Consumes: Tasks 2, 3 and 5.
- `transcribeMessage(m)`:
  - If the model isn't ready, the caller (conversation_view) first shows a dialog: "Transcribing needs
    a 160 MB speech model, downloaded once. Audio never leaves this device." with **Download** and
    **Cancel**. **Download** calls `download()` and waits for `ModelReady`, or stops on
    failure or cancel.
  - It then loads the clip with `MediaService.load(ref)`, writes a temp file, and transcribes.
  - It checks again that the message exists and isn't deleted.
  - If it's my clip, it calls `sendTranscript`. Otherwise it calls `putLocalTranscript`.
  - It exposes `ValueListenable<Set<String>> transcribing` (message ids) for the bubble's
    "Transcribing…".

- [ ] **Step 1: Write the failing tests:**
  - `migrates 13 → 14 with an empty local_transcripts table`: use the existing migration test pattern in `test/chat/` (search for `schemaVersion` or `from < 13` tests). If there isn't one, open a v13 database file made by the current code and reopen it.
  - `purging or deleting a message removes its local transcript`.
  - `search finds a local transcript, and the shared one wins`.
  - In the service: `others' clips are stored locally; my clip is sent`, and `a clip deleted while transcribing stores nothing`.
  - In the widget: `a local transcript shows "Transcribed on this device"`.
- [ ] **Step 2: Run** `cd app && flutter test --concurrency=1 test/chat/local_transcripts_test.dart test/transcripts/transcripts_service_test.dart test/screens/voice_transcript_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement**, then run `cd app && dart run build_runner build --delete-conflicting-outputs` for drift.
- [ ] **Step 4: Run** the same tests plus `test/chat/search_test.dart test/chat/chat_db_test.dart`. Expected: PASS. `dart analyze`: clean.
- [ ] **Step 5: Commit** `git commit -am "Transcripts: transcribe from the menu, local transcripts"` (add new files first).

### Task 7: Docs, CI check and release

**Files:**
- Modify: `docs/protocol.md` (the transcript section: the sender's device makes it with Whisper base, and readers' local transcripts never go on the wire)

- [ ] **Step 1:** Update the docs, then commit.
- [ ] **Step 2:** Run `cd app && flutter build linux --release` once locally (the system load allows only one build). Then confirm the PR's CI jobs (android, linux, windows and web) are green, plus the ios/macos build from Task 1 rerun on the final commit.
- [ ] **Step 3:** Review, then open the PR, wait for CI, merge, and push the tag `v1.0.39` on main. That is a full release: native plugins and an asset. Show the `sai_watch_github_run` card and confirm it's green.
