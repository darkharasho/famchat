# Batch 3 Implementation Plan: polls and files

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Encrypted polls (single or multiple choice, see votes, end poll), then file messages (any type up to 64 MB).

**Architecture:** Polls are a `poll` message plus silent `vote` / `poll_end` events folded per poll, like pins and game moves; no server change. Files are a `file` media message over the existing encrypted blob upload, with a new server media kind `file` (64 MiB).

**Tech Stack:** Cloudflare Workers + Hono + D1 (server, vitest), Flutter + Riverpod + drift (app).

**Spec:** `docs/superpowers/specs/2026-11-22-batch3-polls-files-design.md`

## Ship order
- **PR A (polls, Tasks 1–3):** branch `feat/batch3-polls`. Dart-only: ships by release + phone patch.
- **PR B (files, Tasks 4–6):** branch `feat/batch3-files` from main after PR A merges. Adds native plugins, so it ships as a full release (no patch).

## Global Constraints
- Poll limits: question 1–300 chars, 2–10 options of 1–100 chars, no duplicate options (trimmed, case-insensitive). Receivers drop polls that break them (`FormatException` → `invalid`).
- `vote` and `poll_end` join `changeKinds` (message_changes.dart) and `_changeKinds` (chat_db.dart): silent, not unread, hidden from the timeline, don't move the chat.
- File limit: `mediaKindLimits['file'] = 64 MiB` ciphertext (client and server `KIND_LIMITS`).
- App tests: `flutter test --concurrency=1 <files>` on targeted files (memory pressure). Server: `npx vitest run --maxWorkers=2`.
- Never run `dart format` over files (the repo isn't formatted; it rewrites whole files). `dart analyze` must be clean.

## Review Focus
1. Two devices voting at nearly the same time, and a vote racing the end: every device must show the same totals (fold strictly by seq, own pending events last). (Task 1 tests)
2. Single-choice poll: a vote with several choices counts only its first; `[]` takes the vote back. (Task 1)
3. A `poll_end` from someone other than the creator changes nothing. (Task 1)
4. Votes never notify, never count unread, never show as timeline rows. (Task 1/2 tests)
5. A file's `name` is display-only: path separators and control characters stripped, never used as a path; executables are never opened. (Tasks 4 and 5)
6. Expired files show "No longer available"; a file over 64 MB is refused before staging. (Task 5)

---

### Task 1: Poll wire and fold
**Files:** `app/lib/chat/plaintext.dart` (`PollBody(question, options, {multi, replyTo})` kind `poll`; `VoteBody(target, choices)` kind `vote`; `PollEndBody(target)` kind `poll_end`; constants `maxPollOptions = 10`, `maxPollQuestion = 300`, `maxPollOption = 100`), `app/lib/chat/chat_sync.dart` (`_classify`: votes/ends set `targetId`; `Future<String> sendPoll(chatId, PollBody)`, `Future<String> vote(chatId, pollId, List<int> choices)`, `Future<String> endPoll(chatId, pollId)` via `_enqueueMessage(..., targetId:)`), `app/lib/chat/message_changes.dart` (`changeKinds` += `vote`, `poll_end`), `app/lib/chat/db/chat_db.dart` (`_changeKinds` likewise), new `app/lib/chat/polls.dart` (`PollState { PollBody poll; Map<String,List<int>> votes /* userId → choices */; bool ended; List<int> counts; Set<int> winners; List<int> mine(String me) }` and `Map<String, PollState> pollStates(List<MessageRow> rows)`), `app/lib/chat/providers.dart` (`pollsProvider(chatId)` derived from `messagesProvider`), `docs/protocol.md` (a "Polls" section next to "Games").
**Fold rules:** rows in timeline order (seq, pending last). Skip failed rows and rows whose `targetId` isn't a poll here. `poll_end` counts only from the poll's sender; the first counting end sets `ended`, later votes are ignored. Each vote replaces that sender's choices: drop out-of-range/duplicate indexes, keep only the first on a single-choice poll, `[]` removes the voter. Winners: the options with the top count when ended and that count > 0.
- [ ] Tests (`test/chat/poll_test.dart`): body round-trips and every limit rejects; latest vote wins; `[]` retracts; single-choice keeps first; out-of-range dropped; end by non-creator ignored; votes after the end ignored; winners include ties; pending own vote applies last; failed vote ignored. `chat_db_test`: vote rows aren't unread. `chat_sync_test`: a vote is sent `silent`.
- [ ] Implement, run, commit.

### Task 2: Poll UI
**Files:** new `app/lib/screens/chats/poll_sheet.dart` (`showNewPollSheet(context, chatId)`: question, option fields with ✕, "Add an option" up to 10, switch `Key('poll-multi')` "Allow more than one answer" / "Off means everyone picks one", Send `Key('poll-send')` enabled only when valid), new `app/lib/screens/chats/poll_bubble.dart` (`PollBubble({row, state, me, mine, onVote, onEnd, onSeeVotes})`: question, "Pick one"/"Pick one or more" · "N voted", option rows `Key('poll-option-<i>')` with bar, faces (use the existing avatar widget used for read receipts), count; "Tap to change"/"You picked N"; "See votes" `Key('poll-see-votes')`; "End poll" `Key('poll-end')` for the creator with a confirm dialog; ENDED badge and 🏆 winners), new `showPollVotesSheet` (per option voters, then "Hasn't voted:" current members), `conversation_view.dart` ("+" menu item `(Icons.poll_outlined, 'Poll', …)` in every chat; render `kind == 'poll'` rows with `PollBubble` inside the normal bubble frame so replies, reactions, pin and star work; hide Forward and Edit for polls), `chat_list.dart` (preview "📊 Poll: <question>"), push preview text if notifications build one from the body (`lib/push/…`, search for `'photo' =>`), `search.dart` if it indexes texts (question and options).
- [ ] Widget tests (`test/screens/polls_test.dart`, use `chatTestWidgets`/`pumpChatApp`/`FakeChatBackend`): create a single-choice poll and see it; Bob votes and Alice sees the count and Bob's face; switching a single vote moves it; multi toggles two; See votes lists voters and "Hasn't voted"; only the creator sees End poll and ending shows ENDED and 🏆; a vote doesn't bump unread on the other side; chat list preview.
- [ ] Implement, run, `dart analyze`, commit.

### Task 3: PR A
- [ ] Full review subagent over the diff (Review Focus 1–4), fix findings, run the touched test files, push, open PR, ship (merge → `release.yml` desktop release + phone patch).

---

### Task 4: File wire and server kind
**Files:** `server/src/lib/media.ts` (`KIND_LIMITS` += `["file", 64 * MiB]`), server media test (find the test covering `KIND_LIMITS`/413 and add `file`), `app/lib/media/media_api.dart` (`mediaKindLimits['file']`), `app/lib/chat/plaintext.dart` (`FileBody({mediaKey, key, sha256, name, bytes, mime, replyTo})` kind `file`; `cleanFileName(String)` strips `/ \ :` and control characters, trims, ≤255 chars, falls back to `"file"`; decode cleans the name), `chat_sync.dart` (`_classify`; `mediaKinds` += `file`), `media_service.dart` (`sendFile(chatId, {name, bytes, mime, replyTo})` throws `FileTooLargeException` past the limit; `forwardMedia` handles `FileBody`; a `FileBody.ref` like voice), `docs/protocol.md`.
- [ ] Tests: server `file` accepted at 64 MiB, 413 above; `FileBody` round-trip, bad fields rejected, names cleaned (`../../etc/passwd` → `....etcpasswd` or similar, never containing a separator); `sendFile` stages one blob of kind `file`; too large throws; forward re-encrypts.
- [ ] Implement, run, commit.

### Task 5: File UI and platform glue
**Files:** `app/pubspec.yaml` (add `file_picker` for picking any files and the save dialog, and `open_filex` for opening on Android/iOS; check current versions with context7/pub and that they support every platform we build), new `app/lib/media/files.dart` (`pickFiles()`; `openFile(bytes, name)`: write to a temp dir under a fresh folder, then `open_filex` on phones, `launchUrl(Uri.file(path))` on desktop, a blob download on the web; `saveFile(bytes, name)`; `isRunnable(name)` for the spec's extension list), new `app/lib/screens/chats/file_bubble.dart` (icon tile with extension and type color, name, "size · TYPE", sending progress from `MediaService.progress`, download button / progress, "No longer available" when expired), `conversation_view.dart` ("+" menu `(Icons.attach_file, 'File', …)`; the drop zone sends non-photo/video drops as files and its overlay text becomes "Drop files to send"; long-press adds **Save** for files; tap opens unless `isRunnable`, then it saves), `app/lib/share/share_source.dart` (`SharedMediaType.file` that isn't a photo/video becomes a file to send), `android/app/src/main/AndroidManifest.xml` (SEND and SEND_MULTIPLE for `*/*`), `ios/ShareExtension/Info.plist` (`NSExtensionActivationSupportsFileWithMaxCount` 10), `chat_list.dart` ("📎 <name>"), push preview if applicable, the File provider paths on Android if `open_filex` needs them.
- [ ] Widget tests (`test/screens/files_test.dart`): a sent file shows name, size and type; Bob receives it and sees the download button; expired shows "No longer available"; an `.exe` offers Save but not Open; a 65 MB file shows "Files can be up to 64 MB"; dropping a PDF sends a file; chat list preview. Unit tests for `cleanFileName`, `isRunnable`, share mapping.
- [ ] Implement, run, `dart analyze`, `scripts/shorebird-native-check.sh` is expected to flag native changes (that's why this is a release), commit.

### Task 6: PR B
- [ ] Review subagent (Review Focus 5–6), fix, push, PR, ship as a full release (`release.yml` with a new version tag so phones get a native build; App Store reconcile submits it).
