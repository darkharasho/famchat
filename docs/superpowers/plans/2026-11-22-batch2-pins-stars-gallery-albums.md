# Batch 2 Implementation Plan: pins, stars, gallery, albums

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pinned messages for everyone, private synced stars, a per-chat media/links/starred screen, and album bubbles.

**Architecture:** Pins are a new encrypted change kind (`pin`) folded by `MessageChanges` like edits. Stars are server-side ids per user (D1 table + REST + a `stars` socket event) mirrored into a local drift table. Albums are an optional `album` id on photo/video bodies that the timeline groups into one entry. The gallery reads the local DB only.

**Tech Stack:** Cloudflare Workers + Hono + D1 (server, vitest), Flutter + Riverpod + drift (app).

**Spec:** `docs/superpowers/specs/2026-11-22-batch2-pins-stars-gallery-albums-design.md`

## Global Constraints
- Max pins per chat: `maxPins = 3`. Pin events are `silent`, not unread, don't move `lastMessageAt`.
- Album id: a ULID, only set when ≥ 2 items are sent together.
- Server: vitest `--maxWorkers=2`. App: `flutter test --concurrency=1` on targeted files (memory pressure); CI runs everything.
- drift `schemaVersion` 10 → 11, with a migration test like `chat_db_migration_test.dart`'s 9 → 10.

## Review Focus
1. Two people pin at nearly the same time: every device must agree on the same pins (fold strictly by seq, pending own events last). (Task 2 test)
2. Pinning a 4th message: the oldest drops off the bar on every device, no extra event. (Task 2 test)
3. A pinned or starred message is deleted: it leaves the pin bar and the starred lists. (Tasks 2 and 6 tests)
4. Starring while offline: the ★ shows at once and reaches the server on reconnect; a failed star is rolled back. (Task 3 test)
5. An album interrupted by another message shows as two albums, and the caption stays on the run holding the last item. (Task 5 test)

---

### Task 1: Server stars
**Files:** Create `server/migrations/0017_starred_messages.sql`, `server/test/stars.test.ts`. Modify `server/src/routes/chats.ts`, a new `server/src/routes/stars.ts` mounted at `/api/stars` (or in `me.ts`, following how `/api/users` is mounted), `server/src/lib/chatdb.ts:leaveGroupStmts`, `server/src/lib/delete-account.ts`, `docs/protocol.md`.
**Interfaces (produces):** `PUT|DELETE /api/chats/:id/messages/:messageId/star` → 204 (404 when not a member or no such message in that chat; idempotent); `GET /api/stars` → `{stars:[{chatId,messageId,starredAt}]}` newest first, only chats the caller is still in; socket `{type:"stars"}` to the caller's own sockets on change.
- [ ] Tests: star/unstar/list; idempotent; non-member 404; message from another chat 404; the event reaches only my sockets; leaving a group drops my stars there; account deletion drops them.
- [ ] Implement, run `npx vitest run --maxWorkers=2 test/stars.test.ts`, commit.

### Task 2: Pin events and album field on the wire
**Files:** `app/lib/chat/plaintext.dart` (`PinBody(target, pinned)`, kind `pin`; `album` on `Captioned` media), `app/lib/chat/message_changes.dart` (`changeKinds` += `pin`; `MessageChanges.pinned` → `List<String>` newest first ≤ `maxPins`; `pinEvents` for the timeline lines), `app/lib/chat/db/chat_db.dart` (`_changeKinds` += `pin`), `app/lib/chat/chat_sync.dart` (`_classify` for `PinBody` sets `targetId`; `Future<String> pin(String chatId, String messageId, bool pinned)`), `docs/protocol.md`.
**Interfaces (produces):** `PinBody`, `maxPins`, `MessageChanges.pinned`, `MessageChanges.pinEvents` (`List<MessageRow>` of pin rows that count), `ChatSync.pin`.
- [ ] Tests (`test/chat/message_changes_test.dart`): pin then unpin; 4 pins keep the newest 3; anyone's pin counts; a deleted target drops out; a failed pin row doesn't count; album round-trips and bad album ids drop.
- [ ] Implement, run, commit.

### Task 3: Stars on the client
**Files:** `app/lib/chat/wire.dart` (`ChatApi.star(chatId, messageId, bool)`, `ChatApi.stars()` → `List<StarDto>`), `http_chat_api.dart`, `test/support/fake_chat_backend.dart`, `app/lib/chat/db/chat_db.dart` (`LocalStars(messageId PK, chatId, starredAt)`, schema 11; `watchStars({String? chatId})`, `setStar`, `replaceStars`), `app/lib/chat/chat_sync.dart` (`star(chatId, messageId, bool)`: local first, then API, roll back on a 4xx; refresh on connect and on `{type:"stars"}`), `app/lib/chat/providers.dart` (`starsProvider(String? chatId)`).
- [ ] Tests: star syncs to a second device of the same user; failed star rolls back; migration 10 → 11.
- [ ] Implement, run, commit.

### Task 4: Conversation UI for pins and stars
**Files:** `app/lib/screens/chats/message_bubble.dart` (`MessageAction.pin`, `.star`; labels "Pin for everyone"/"Unpin", "Star"/"Unstar"; `starred` flag → ★ `Key('star-<id>')` in the time row), new `app/lib/screens/chats/pin_bar.dart` (`PinBar({required List<MessageRow> pins, required MessageChanges changes, required void Function(String id) onJump})`, `Key('pin-bar')`, "Pinned message N of M"), `app/lib/screens/chats/timeline.dart` (`PinNoteEntry`), `conversation_view.dart`.
- [ ] Widget tests (`test/screens/pins_stars_test.dart`): pinning shows the bar and a "You pinned a message" line; tapping the bar jumps and steps; Bob's pin shows on Alice's side; unpin removes it; star shows ★ and appears in the chat's Starred tab.
- [ ] Implement, run, commit.

### Task 5: Albums
**Files:** `app/lib/media/send_media.dart` (one `newUlid()` album id when `items.length >= 2`, passed to each `sendPhoto`/`sendVideo` via `album:`), `media_service.dart`, `timeline.dart` (`AlbumEntry(List<MessageRow> items)`: consecutive rows, same sender, same album id, none deleted), new `app/lib/screens/chats/album_bubble.dart` (grid layouts 1/2/3/4+ with "+N", caption from the last item, tap opens the media pager at that item, long-press gives that item's actions).
- [ ] Tests: `timeline_test` grouping incl. an interrupted album; `send_media_test` album ids; widget test that 5 photos show 4 tiles and "+1" with the caption under them.
- [ ] Implement, run, commit.

### Task 6: Media, links and starred screens
**Files:** new `app/lib/screens/chats/chat_media_screen.dart` (route `chats/:id/media`, tabs Media / Links / Starred, keys `media-tab`, `links-tab`, `starred-tab`), new `app/lib/screens/starred_screen.dart` (route `/settings/starred`), new `app/lib/screens/chats/media_pager.dart` (`showMediaPager(context, List<MessageRow> items, int index)`: a PageView of `PhotoViewer`/`VideoViewer`), `chat_db.dart` (`watchMedia(chatId)`, `watchLinks(chatId)`), `group_info_screen.dart` (row "Media, links and starred"), `settings_screen.dart` (row "Starred messages"), `router.dart`.
- [ ] Widget tests (`test/screens/chat_media_test.dart`): grid newest first with month headers; deleted excluded; Links lists a link with its preview title; Starred lists starred, tap jumps (`/chats/<id>?m=<msg>`); settings Starred lists across chats.
- [ ] Implement, run, commit.
