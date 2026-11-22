# Batch 2: pinned messages, starred messages, media gallery, albums

Approved from a mockup on 2026-11-22. Part of the messaging feature batches (batch 1 shipped in v1.0.31).

## Why
Feature parity with mainstream chat apps, without weakening end-to-end encryption. The family wants to keep important things findable (gate codes, reunion details), browse what's been shared, and see a set of photos as one post.

## Pinned messages (for everyone)
- Long-press → **Pin for everyone** / **Unpin**. Any member can pin or unpin. No admin step.
- At most **3** pins per chat. Pinning a 4th unpins the oldest.
- A **pin bar** under the chat header shows the newest pin ("Pinned message N of M", a snippet, 📌). Tapping it jumps to that message, and the next tap moves to the next older pin, cycling. Little segment bars on the left show which one.
- A small centered line in the timeline, "Bob pinned a message" or "You unpinned a message", tappable to jump. No notification, no unread, doesn't move the chat in the list.
- **Wire:** a new encrypted plaintext kind `{"kind":"pin","target":"<messageId>","pinned":true|false}`, sent `silent` like edits. The server learns nothing new. State: for each target, the latest pin event (by seq) wins. The pinned set is the targets whose latest event is `pinned:true`, newest first, capped at 3 (so the oldest falls off by itself). Deleted targets drop out.
- Older apps: they show the event as "needs a newer version" until they update (phones get it by patch). With 1.0.32's keep-unknown-fields change, it shows properly after updating.

## Starred messages (private to me, synced across my devices)
- Long-press → **Star** / **Unstar**. A small ★ in the message's time row.
- Lists: the **Starred** tab in chat info (this chat), and **Settings → Starred messages** (all chats, newest star first, grouped with the chat name). Tapping jumps to the message.
- **Server:** a new table `starred_messages(user_id, chat_id, message_id, starred_at)`, PK (user_id, message_id). `PUT/DELETE /api/chats/:id/messages/:msgId/star` (members only) → 204 plus a `{type:"stars"}` event to the caller's own sockets. `GET /api/stars` → `{stars:[{chatId,messageId,starredAt}]}`. The server only learns *which message ids* a user starred, like it already knows pins and archives, never content. Leaving a chat or deleting the account removes that user's stars there.
- **Client:** a local `local_stars` table mirrors the server, refreshed on connect and on the `stars` event. Starring updates locally first.

## Media gallery (chat info → Media / Links / Starred)
- **Media:** a 3-column grid of every photo and video in the chat on this device, newest first, with headers "This week", "Earlier this month", then by month ("October", "October 2025" in other years). Videos show their length. Deleted messages are excluded. Media the server expired shows an "Expired" tile. Tapping opens the full-screen viewer, swiping moves through the chat's media.
- **Links:** text messages (and captions) with links, newest first: the link-preview card if there is one, else the URL, with sender and date. Tap opens the link; long-press jumps to the message.
- **Starred:** as above.
- Built entirely from the local database. No server changes.

## Albums
- Photos and videos sent together from the tray share an album id: an optional `"album":"<ULID>"` field in each photo/video body, set when 2 or more are sent.
- Consecutive messages from the same sender with the same album id show as **one bubble**: a grid of up to 4 tiles (1 = full, 2 = side by side, 3 = one big and two small, 4+ = 2×2 with "+N" on the 4th), and the caption (from the last item) under it. Tapping a tile opens the viewer at that item.
- Each item is still its own message underneath. (Builder's call, changed during the build:) long-press on the album acts on the album: reply, pin, star and reactions go on the captioned (last) item; forward and delete apply to every item. Per-tile actions would need the message menu reworked.
- If items of an album end up apart (something arrived in between), each run shows as its own album. Older apps show separate photos.

## Approaches considered
- **Pins** as an encrypted message (chosen) vs server-side chat state. Server-side would be simpler but tells the server which message is important. The encrypted event keeps it private and reuses the edit/delete machinery.
- **Stars** on the server as ids (chosen) vs local-only (doesn't sync, so it fails "on all my devices") vs encrypted self-messages (no self-channel exists today; much more work for little privacy gain over ids).
- **Albums** with an explicit album id (chosen) vs grouping by time and sender. Time grouping would merge photos sent separately a few seconds apart and can't match what the sender meant.

## Left to the builder
Animations, exact tile sizes, empty states ("No photos yet"), the Links row layout.
