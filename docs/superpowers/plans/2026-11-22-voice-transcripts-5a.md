# Voice transcripts 5a (receive side) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every app understands the new `transcript` change kind: it stores it, shows it under the
voice clip, and finds it in search. Nothing sends transcripts yet.

**Architecture:** `TranscriptBody` is a new change kind, like `EditBody`. It's stored with
`targetId`, kept out of the timeline, the unread count and notifications through `changeKinds`, and
resolved in `messageChanges` (the latest one from the clip's sender wins). `MessageBubble` passes
the text to `VoiceBubble`. Search adds voice rows whose transcript matches.

**Tech Stack:** Flutter, Riverpod and drift (no schema change in 5a).

**Spec:** `docs/superpowers/specs/2026-11-22-voice-transcripts-design.md`

## Global Constraints

- Wire: `{"kind":"transcript", "target":"<voice message id>", "text":"…", "lang":"en"}`. `text` is
  1–20 000 characters, and `lang` is optional (a string of at most 16 characters, otherwise dropped).
- A transcript counts only when the target is a `voice` message from the same sender. The latest one
  wins, and none count once the target is deleted.
- Search hits show as `🎤 <transcript>` (`snippetAround` trims it).
- Dart only: no native or plugin changes, so it ships as a desktop release plus a phone patch.
- Never run `dart format`. `flutter test --concurrency=1` on the targeted files. `dart analyze` must
  be clean.

## Review Focus

- A transcript stored before its clip (sends out of order): `messageChanges` indexes every row
  first, so it must still attach. Test in Task 2.
- A transcript from someone other than the clip's sender, or aimed at a non-voice message: ignored.
  Test in Task 2.
- 20 000 characters with no newlines: the collapsed bubble must stay at 3 lines (`maxLines: 3`,
  ellipsis). Widget test in Task 3.
- A clip deleted after it was transcribed: no transcript, and no search hit. Tests in Tasks 2 and 4.
- An older install with stored `unknown` rows of kind `transcript`: `_reclassifyUnknown` turns them
  into `transcript` rows on update. Test in Task 1.

---

### Task 1: `TranscriptBody` wire kind and storage

**Files:**
- Modify: `app/lib/chat/plaintext.dart` (decode switch near line 135, new class after `PollEndBody`)
- Modify: `app/lib/chat/chat_sync.dart:458-476` (`_classify`)
- Modify: `app/lib/chat/message_changes.dart:9` (`changeKinds`)
- Modify: `app/lib/chat/db/chat_db.dart:764` (`_changeKinds`)
- Test: `app/test/chat/voice_body_test.dart`, `app/test/chat/chat_sync_test.dart`

**Interfaces:**
- Produces: `class TranscriptBody extends Plaintext { const TranscriptBody(String target, String text, {String? lang}); final String target, text; final String? lang; kind == 'transcript' }`, and `const maxTranscriptLength = 20000;` in plaintext.dart.
- `'transcript'` is in `changeKinds` and `ChatDb._changeKinds`, which keeps it out of the timeline,
  unread counts, chat-list last message, local notifications and push (it is sent `silent`).

- [ ] **Step 1: Write the failing tests** in `voice_body_test.dart` (group `transcript`):
  - `decodes target, text and lang`: decoding `{"kind":"transcript","target":"m1","text":"hi","lang":"en"}` gives a `TranscriptBody` with those fields, and `toJson()` round-trips it.
  - `lang is optional; a bad lang is dropped`: no lang → `lang == null`. `"lang": 5` and a 17-character lang → `lang == null`.
  - `rejects empty or missing target or text, and text over 20000`: each case throws `FormatException`. Exactly 20000 characters decodes.
  - In `chat_sync_test.dart`: `a received transcript is stored as a change with its target` (kind `'transcript'`, `targetId == 'm1'`, not counted unread). `an unknown-stored transcript is reclassified` (insert a row with kind `'unknown'` and a transcript body, run the reclassify path the existing unknown-kind test uses, and expect kind `'transcript'` and `targetId` set).
- [ ] **Step 2: Run** `cd app && flutter test --concurrency=1 test/chat/voice_body_test.dart test/chat/chat_sync_test.dart`. Expected: FAIL (no `TranscriptBody`).
- [ ] **Step 3: Implement** the `case 'transcript'` in decode, the class, `TranscriptBody(:final target) => base.copyWith(kind: 'transcript', body: Value(body), targetId: Value(target))` in `_classify`, and add `'transcript'` to both change-kind lists. Doc comment: "The sender's transcript of their voice message [target]; the latest one wins (docs/protocol.md)."
- [ ] **Step 4: Run** the same command. Expected: PASS. Then `cd app && dart analyze`. Expected: no issues. The `_classify` switch is exhaustive, so the analyzer flags any missed case.
- [ ] **Step 5: Commit** `git commit -am "Transcripts: the transcript change kind"`.

### Task 2: Resolve transcripts in `messageChanges`

**Files:**
- Modify: `app/lib/chat/message_changes.dart`
- Test: `app/test/chat/message_changes_test.dart`

**Interfaces:**
- Consumes: `TranscriptBody` (Task 1).
- Produces: `String? MessageChanges.transcriptOf(MessageRow m)`, which returns the text in force,
  or null (not voice, deleted, or none).

- [ ] **Step 1: Write the failing tests:**
  - `a transcript from the clip's sender shows`: voice `v1` from `u1`, then a transcript row targeting `v1` from `u1` with text "hello" → `transcriptOf(v1) == 'hello'`.
  - `the latest transcript wins`: two transcripts in order, "a" then "b" → `'b'`.
  - `a transcript stored before its clip still counts`: the transcript row first in the list → `'hello'`.
  - `others' transcripts and non-voice targets are ignored`: a transcript from `u2` → null. A transcript targeting a text message → `transcriptOf` null, and `textOf` unchanged.
  - `a deleted clip has no transcript`: a delete from `u1` targeting `v1` → null.
- [ ] **Step 2: Run** `cd app && flutter test --concurrency=1 test/chat/message_changes_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** a `_transcripts` map built in the edit and delete loop. Skip failed rows, and use the same target and sender check. Only `target.kind == 'voice'` counts, and a delete clears it. Add it to the `MessageChanges._` constructor.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -am "Transcripts: resolve the transcript in force"`.

### Task 3: Show the transcript under the clip

**Files:**
- Modify: `app/lib/screens/chats/voice_bubble.dart` (new `transcript` parameter)
- Modify: `app/lib/screens/chats/message_bubble.dart:571-575` and its `MessageBubble` constructor (new `String? transcript`)
- Modify: `app/lib/screens/chats/conversation_view.dart:~1564` (pass `transcript: changes.transcriptOf(m)`)
- Test: `app/test/screens/voice_bubble_test.dart` (create, or add to the existing voice bubble widget test if there is one)

**Interfaces:**
- Consumes: `MessageChanges.transcriptOf` (Task 2).
- Produces: `VoiceBubble({..., String? transcript})`. 5b's local transcript passes through the same parameter.

- [ ] **Step 1: Write the failing widget tests:**
  - `shows the transcript under the waveform, three lines collapsed`: with a long transcript (the 20000-character line) the `Text` has `maxLines == 3` and `overflow == TextOverflow.ellipsis`.
  - `tapping the transcript expands it`: after a tap, `maxLines == null`.
  - `no transcript, no text`: there is no transcript `Text` widget (find it by `Key('voice-transcript')`).
- [ ] **Step 2: Run** `cd app && flutter test --concurrency=1 test/screens/voice_bubble_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement** the transcript below the existing waveform row in `VoiceBubble`. Use a `StatefulWidget` wrapper (or a small `_TranscriptText` stateful child) holding `expanded`, the bubble's `ink` colour, `bodyMedium`, `Key('voice-transcript')`, and `SelectionArea`-free plain `Text`. Width-limit it to the bubble's width so long text wraps.
- [ ] **Step 4: Run** the same command. Expected: PASS. Then `dart analyze`. Expected: clean.
- [ ] **Step 5: Commit** `git commit -am "Transcripts: show under the voice clip"`.

### Task 4: Search transcripts

**Files:**
- Modify: `app/lib/chat/db/chat_db.dart:806` (`searchCandidates`)
- Modify: `app/lib/chat/search.dart`
- Test: `app/test/chat/search_test.dart`

**Interfaces:**
- Consumes: `MessageChanges.transcriptOf` (Task 2).
- Produces: `searchMessages` returns voice hits with text `'🎤 <transcript>'`.

- [ ] **Step 1: Write the failing tests:**
  - `finds a voice message by its transcript`: voice `v1` plus a transcript "pick up milk" from its sender. Searching "milk" → one hit on `v1` with text `'🎤 pick up milk'`.
  - `others' transcripts and deleted clips don't match`: a transcript from someone else → no hit. The clip deleted → no hit.
  - `only the latest transcript matches`: "milk" then "bread" → "milk" gives no hit.
- [ ] **Step 2: Run** `cd app && flutter test --concurrency=1 test/chat/search_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** In `searchCandidates`, add `'voice'` to the kind list and an `OR (m.kind = 'voice' AND EXISTS (SELECT 1 FROM local_messages t WHERE t.kind = 'transcript' AND t.target_id = m.id AND t.sender_user_id = m.sender_user_id AND json_extract(t.body, '$.text') LIKE ? ESCAPE '\\'))` branch, with one more pattern variable. In `searchMessages`, use `'🎤 $t'` when `c.transcriptOf(m)` is non-null for a voice row. Update both doc comments.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** `git commit -am "Transcripts: search them"`.

### Task 5: Protocol docs

**Files:**
- Modify: `docs/protocol.md` (after the `edit` line near 131, and under "Voice")

- [ ] **Step 1:** Document the `transcript` kind:
  - its JSON line, the limits and the sender-only, latest-wins rule;
  - that it's a change, sent `silent` with the target's `disappearSecs`, and goes away with the target;
  - that it's produced on the sender's device, never on the server;
  - that a version which doesn't know it stores it as `unknown`.
- [ ] **Step 2: Commit** `git commit -am "Protocol: transcript change kind"`.
