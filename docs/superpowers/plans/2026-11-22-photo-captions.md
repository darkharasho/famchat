# Photo and Video Captions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stage picked/pasted/dropped/shared photos and videos in a tray above the composer, and send the typed text as an encrypted caption on the last one.

**Architecture:** `PhotoBody`/`VideoBody` gain optional `caption`, `replyTo`, `mentions` (inside the E2E plaintext; the server is unchanged). `MessageChanges.textOf` returns a caption for photo/video, so search, chat-list snippets, notifications, edits and the bubble pick it up through the paths text already uses. Staged items live in a per-chat Riverpod provider so the share flow and the conversation view share them.

**Tech Stack:** Flutter, Riverpod, drift, flutter_test.

**Spec:** `docs/superpowers/specs/2026-11-22-photo-captions-design.md`

## Global Constraints

- Caption: trimmed, 1–4000 characters (`validMessageText`); invalid on receipt → treated as no caption, media still shows.
- `mentions` on media: same rules as text (≤ `maxMentions`, strings); invalid → empty.
- Wire field names: `caption`, `replyTo`, `mentions` (documented in `docs/protocol.md` "Messages").
- Tests: `flutter test --concurrency=1` on targeted files only (machine under memory pressure); CI runs the full suite.

## Review Focus

1. The captioned (last) item fails to process (bad image / too-big video) → caption goes out as a plain text, not lost. (Task 2 test)
2. Every staged item fails → caption still sent as text; with no caption, nothing sent and the snackbar explains. (Task 2 test)
3. Send pressed with staged items and an empty field → items send without caption; Enter on desktop does the same. (Task 4 test)
4. Leaving and reopening the chat (or the wide layout rebuilding the view) keeps the tray. (Task 3 provider is per chat, not per widget; Task 4 test)
5. A caption edit from me shows on my other devices and an edit by someone else is ignored. (Task 1 test)

---

### Task 1: Caption on the wire and in MessageChanges

**Files:**
- Modify: `app/lib/chat/plaintext.dart` (PhotoBody, VideoBody)
- Modify: `app/lib/chat/message_changes.dart` (`textOf`, edits on media, `replyTargetOf`, `mentionsOf`)
- Modify: `app/lib/chat/chat_sync.dart:665` (`_mentionsOf` reads media mentions)
- Modify: `app/lib/screens/chats/chat_list.dart:397` (`messageSnippet`: `📷 caption` / `🎥 caption`)
- Modify: `app/lib/push/preview.dart:_previewOf` (same label for notifications)
- Modify: `app/lib/chat/db/chat_db.dart:556` (`searchCandidates` also matches `$.caption` of photo/video)
- Modify: `app/lib/media/media_service.dart` (`forwardMedia` keeps caption, drops replyTo/mentions; `_stageVideo` takes caption fields)
- Modify: `docs/protocol.md` (photo/video fields; edits may target a captioned media message)
- Test: `app/test/chat/plaintext_test.dart`, `app/test/chat/message_changes_test.dart`, `app/test/chat/search_test.dart`, `app/test/push/preview_test.dart` (add cases to existing files; create if missing)

**Interfaces:**
- Produces: `PhotoBody({..., String? caption, String? replyTo, List<String> mentions = const []})`, same three on `VideoBody`. `MessageChanges.textOf(m)` returns the caption (latest edit wins) for `photo`/`video`. `captionKinds = {'photo', 'video'}` in `message_changes.dart`.

- [ ] **Step 1: Write failing tests**
  - `photo caption round-trips`: `Plaintext.decode(PhotoBody(..., caption: 'hi', replyTo: 'X', mentions: ['u']).encode())` has the same three.
  - `bad caption is dropped, photo kept`: JSON with `"caption": 5` and `"caption": ""` decodes to a `PhotoBody` with `caption == null`; `"mentions": "x"` → `mentions` empty.
  - `textOf gives the caption, edits replace it`: photo row with caption `a`, my edit `b` → `textOf == 'b'`, `edited` contains it; an edit by another user → still `a`.
  - `search finds captions`: a photo with caption "beach day" is a hit for "beach".
  - `snippet and push preview`: `messageSnippet` → `'📷 beach day'`; `rowPreviewText` → `'📷 beach day'`; no caption → `'📷 Photo'` (unchanged).
- [ ] **Step 2: Run them, expect failures** — `cd app && flutter test --concurrency=1 test/chat/plaintext_test.dart test/chat/message_changes_test.dart test/chat/search_test.dart test/push/preview_test.dart`
- [ ] **Step 3: Implement.** Parse fields tolerantly (`validMessageText` for caption). In `messageChanges`, apply non-preview edits when `target.kind` is `text` or in `captionKinds`. `textOf`: for `captionKinds` return `_texts[id] ?? _field(m, 'caption')`. Snippet label for media with a caption: the emoji of `mediaLabel` + space + stripped caption on one line.
- [ ] **Step 4: Run tests, expect PASS.**
- [ ] **Step 5: Commit** `Captions: photo and video bodies carry a caption, reply and mentions`

### Task 2: Sending with a caption

**Files:**
- Modify: `app/lib/media/media_service.dart` (`sendPhoto`, `sendVideo` take `{String? caption, String? replyTo, List<String> mentions}`)
- Modify: `app/lib/media/send_media.dart` (`sendMedia` gains `{String? caption, String? replyTo, List<String> mentions, ChatSync? sync}`)
- Test: `app/test/media/media_service_test.dart`, `app/test/media/send_media_test.dart`

**Interfaces:**
- Consumes: Task 1 bodies.
- Produces: `sendMedia(media, videos, chatId, items, {caption, replyTo, mentions, onStart, onEnd}) → SendReport`; the caption, reply and mentions go on the last item that sends. `SendReport.captionSentAsText` (bool).

- [ ] **Step 1: Failing tests:** `caption goes on the last item only`; `last item fails → caption on the previous one that sent`; `all fail → caption sent as a TextBody with the reply and mentions`, `report.captionSentAsText` true.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Process items first in order, then attach caption to the last success; if none succeeded and the caption is non-empty, `media.sync.sendText(...)`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `Captions: send the typed text with the last photo or video`

### Task 3: Staged media tray

**Files:**
- Create: `app/lib/media/staged_media.dart` — `stagedMediaProvider` (`NotifierProvider.family<StagedMedia, List<PickedMedia>, String /*chatId*/>`, methods `add(List<PickedMedia>)`, `removeAt(int)`, `clear()`), kept alive for the app run.
- Create: `app/lib/screens/chats/staged_tray.dart` — `StagedTray({required List<PickedMedia> items, required ValueChanged<int> onRemove, required VoidCallback onAdd})`: horizontal list of 64×64 rounded thumbnails (photo bytes; video → dark tile with play icon), ✕ per item (`Key('staged-remove-$i')`), dashed + (`Key('staged-add')`), hint `'N item(s) · your message goes with them'`.
- Test: `app/test/screens/staged_tray_test.dart`

- [ ] **Step 1: Failing widget test:** 2 photos + 1 video render 3 tiles, hint says "3 items", tapping ✕ on index 1 calls `onRemove(1)`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `Captions: a tray of staged photos and videos`

### Task 4: Conversation view stages instead of sending

**Files:**
- Modify: `app/lib/screens/chats/conversation_view.dart` — picker, drop, paste and keyboard-inserted content call `_stage(items)` (adds to `stagedMediaProvider(chatId)`); remove `_confirmPaste` dialog; tray shown above the reply banner when non-empty and not editing/recording; Send button shows (not the mic) while items are staged; `_send` with staged items calls `sendMedia(..., caption: text, replyTo, mentions: mentionsIn(text, _people))`, then clears tray, field and reply; Enter sends with an empty field when staged.
- Modify: `onEdit` at `conversation_view.dart:1304` — allowed for my `photo`/`video` that has a caption.
- Modify: `app/lib/screens/chats/message_bubble.dart` — photo/video content: caption below the media via `LinkText(shownText, mentions: mentionNames, markdown: true)` in `EdgeInsets.fromLTRB(8, 6, 8, 2)`; `_copyText` includes captions.
- Modify: `app/test/screens/paste_media_test.dart` (paste now stages) and any test that expects an immediate send after picking.
- Test: `app/test/screens/photo_caption_test.dart`

- [ ] **Step 1: Failing widget tests:**
  - `picking stages; Send sends both with the caption on the last`: after picking 2 photos nothing is in the outbox; type "beach @Bob", Send → two photo rows, second has caption "beach @Bob" and mentions [bob]; tray gone; field empty.
  - `✕ removes a staged item` → one photo sent.
  - `Send with an empty field sends the photos without caption`; on desktop, Enter does too.
  - `the caption shows under the photo and can be edited`.
  - `staged items survive leaving and reopening the chat`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run new + paste tests, expect PASS.**
- [ ] **Step 5: Commit** `Captions: stage photos above the composer and send them with your message`

### Task 5: Shares open the chat with media staged

**Files:**
- Modify: `app/lib/screens/share_screen.dart:_sendTo` — instead of `sendMedia`, `ref.read(stagedMediaProvider(chatId).notifier).add(share.media)` before navigating.
- Test: existing share screen test (`app/test/screens/share_screen_test.dart`) updated: sharing a photo to a chat stages it; nothing sent until Send.

- [ ] **Step 1: Update the test, run, expect FAIL.**
- [ ] **Step 2: Implement.**
- [ ] **Step 3: Run, expect PASS.**
- [ ] **Step 4: Commit** `Captions: shared photos wait in the chat for a caption`
