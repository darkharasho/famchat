# Batch 4 Implementation Plan: scheduled send, reminders, disappearing messages

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Server-held encrypted scheduled sends, server-pushed reminders, and per-chat disappearing messages whose clock starts when each person reads.

**Architecture:** One Durable Object alarm on the family hub (`FamilyHub`) fires at the earliest due item across three D1 tables (scheduled sends, reminders, message expiries). Scheduled sends are stored envelopes delivered through the same path as `handleSend`. Reminders are (user, chat, message, time) rows that push and emit a socket event. Disappearing timers are a chat field stamped onto each message at delivery; the server deletes a message (and its media) when every member has read it plus the timer, or at the backstop; clients delete their own copies at their read time plus the timer.

**Tech Stack:** Cloudflare Workers + Hono + D1 + Durable Objects (server, vitest), Flutter + Riverpod + drift (app).

**Spec:** `docs/superpowers/specs/2026-11-22-batch4-timing-design.md`

**Branch:** `feat/batch4-timing`, one PR. Dart-only on the app side (no new plugins): ships by merge (server deploy) then `release.yml -f desktop_release=<next>` (desktop + phone patch).

## Global Constraints
- The server never sees plaintext. New server state is ids, times, timers and envelopes only.
- Timer values: `null` (off), 86400, 604800, 7776000 seconds. Backstop: `sent_at + timer + 30 days`.
- Schedule horizon: at most 366 days ahead, at least 1 minute.
- Existing protocol rules hold: idempotent message ids, `stale_epoch` handling, seq holes tolerated, silent change events.
- Migrations follow the existing numbering (next is 0019); `scripts/deploy.sh` applies them before deploy.
- App tests: `flutter test --concurrency=1 <files>` on targeted files only. Server: `npx vitest run --maxWorkers=2`.
- Never run `dart format`. `dart analyze` and the server typecheck must be clean.
- Document every new frame, route and field in `docs/protocol.md`.

## Review Focus
1. A scheduled send whose epoch rotated is never lost and never delivered twice (idempotent on its message id), whichever device re-sends.
2. The hub alarm always re-arms for the next due item after any insert, delete or fire, and a failing item doesn't block the rest.
3. Disappearing: a message is deleted on the server only when every *current* member's read position passed it plus the timer, or at the backstop; its media blobs go too; clients purge row, search, change rows, pins/stars and media cache.
4. A device that was offline for the whole timer still drops expired messages when it comes back (own read pointer + timer; server-deleted rows reported on sync).
5. Reminders and scheduled lists are visible only to their owner; no endpoint leaks another user's.

---

### Task 1: Server
**Files:** new migration `server/migrations/0019_timing.sql` (`chats.disappear_secs INTEGER NULL`; `messages.disappear_secs`, `messages.delete_at`, `messages.all_read_at` or equivalent; `scheduled_messages(id, chat_id, sender_id, sender_device_id, envelope, silent, mentions, deliver_at, state, created_at)`; `reminders(user_id, chat_id, message_id, remind_at, PRIMARY KEY(user_id, message_id))`), `server/src/hub.ts` (alarm handler; delivery shared with `handleSend`; `schedule`/`unschedule` frames or REST; on read moves, set `delete_at` for messages now read by every current member), the chats routes (`PATCH /chats/:id {disappearSecs}` with a `chat` event and a system line the way title changes are shown), reminder routes (`PUT/DELETE /chats/:id/messages/:mid/reminder`, `GET /me/reminders`), scheduled routes (`GET /me/scheduled`, cancel, send now), push for reminders (`push/consumer.ts`, `fcm.ts`: a reminder push, previews on → envelope attached like messages), deletion of expired messages and their media (R2 + `media` rows by `message_id`) with a `{type:"gone", chatId, ids}` frame to online members, and the sync path reporting server-deleted ids if needed.
- [ ] Tests (vitest): scheduling stores and delivers at the time (fake alarm/clock) with a new seq, ack and fan-out; cancel/send-now; stale epoch → `needs_resend` event, a re-send with the same id delivers once; alarm re-arms to the earliest of all three tables; reminders fire once to all the user's devices, are private to the user; disappearing stamp at delivery; delete after all read + timer; backstop; media deleted; `gone` frame; turning it off doesn't change sent messages; non-members are refused everywhere.
- [ ] Implement, run, typecheck, document in protocol.md, commit.

### Task 2: App: disappearing messages
**Files:** `chat_sync.dart` and the chat db (store `disappearSecs` per message and per chat; compute each row's expiry: own → sent + timer, others → my read time + timer, recording my read time when my read position passes it; an expiry sweeper (timer to the next expiry, on start and on resume) that purges rows, search entries, change rows targeting them, pins/stars, media cache; handle `gone`), chat info / chat menu setting sheet (Off / 24 hours / 7 days / 90 days, with the "screenshots aren't blocked" note), the system line and the header timer icon.
- [ ] Tests: expiry computed from my read time; own messages from send; offline-then-back purge; `gone` purge; search no longer finds it; media cache dropped; setting sheet changes it and shows the line.
- [ ] Implement, run, analyze, commit.

### Task 3: App: scheduled send
**Files:** shared `app/lib/screens/chats/time_picker_sheet.dart` (presets + custom date/time; reused by reminders), composer long-press / right-click on Send → "Schedule message", `chat_sync.dart` (`schedule(chatId, body, at)`: stage media now, encrypt, send the schedule frame; keep the plaintext locally; on `needs_resend` re-encrypt and resubmit with the same id; send now / cancel / edit), a "Scheduled (N)" bar and list sheet, sync of the list across your devices (`GET /me/scheduled`, decrypting envelopes for display).
- [ ] Tests: schedule a text and a photo, see them in the list, cancel, send now, edit; delivery at the time arrives as a normal message; `needs_resend` re-encrypts once.
- [ ] Implement, run, analyze, commit.

### Task 4: App: reminders
**Files:** message action "Remind me" (time picker), the bell on messages with a reminder, `chat_sync.dart` (set/clear, `GET /me/reminders`, the reminder socket event), notifications on every platform (phones from the push; desktop/web via the existing local notifier on the socket event; missed reminders shown at next open), tap opens the chat at the message, push preview text.
- [ ] Tests: set and clear, bell shows only for me, firing shows a notification and clears, tapping opens the message.
- [ ] Implement, run, analyze, commit.

### Task 5: PR
- [ ] Review subagent over the whole diff (Review Focus 1–5), fix findings, run touched tests, push, PR with CI, merge, ship (`release.yml -f desktop_release=<next>`).
