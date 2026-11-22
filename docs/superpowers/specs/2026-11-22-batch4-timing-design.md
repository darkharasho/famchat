# Batch 4: scheduled send, reminders, disappearing messages

Approved 2026-11-22 ("from read, go"). Part of the messaging feature batches (batch 3, polls and files, shipped in v1.0.35 / v1.0.36).

## Why
Feature parity with mainstream chat apps without weakening end-to-end encryption: the server only ever holds, releases and deletes ciphertext, plus the ids and times it needs to do that.

## Scheduled send
- **Make one:** long-press (desktop: right-click) Send → "Schedule message" → pick a time (presets: In 1 hour, Tonight 8 PM, Tomorrow 9 AM, Monday 9 AM, plus a date and time picker; my call). Text, photos, videos, voice, files, polls and replies can all be scheduled. Up to a year ahead.
- **Server-held:** the sending device encrypts now and the server stores the envelope until the time, so it goes out even if every device of yours is off. At the time the server delivers it exactly like a normal send (new seq, fan-out, push) and acks your devices.
- **Key rotation:** if the chat's key changed meanwhile (a member left, a device was removed), the server can't deliver the old ciphertext (`stale_epoch`). It marks it `needs_resend` and tells your devices; the next one online re-encrypts from the plaintext it keeps locally and delivers it (late, marked "sent late" for you only; my call). If no device of yours has the plaintext (e.g. scheduled on a phone since wiped), another device of yours can decrypt the old envelope with the old epoch key and re-encrypt it.
- **Manage:** a "Scheduled (N)" bar above the composer opens a list: each with its time; Send now, Edit (cancel and reschedule with new content/time) and Delete. Synced across your devices. Media is uploaded when scheduling (counts toward the cap from then).
- Others see nothing until it's delivered.

## Reminders
- **Set:** "Remind me" in any message's actions → the same time picker. A small bell on the message while one is set (only you see it). Tap the bell to change or clear it.
- **Server-held, content-free:** the server stores (user, chat, message id, time). At the time it notifies all your devices: a push to phones ("Reminder" plus, with previews on, the message text decrypted on the device like today's previews), a socket event that desktop and web show as a local notification. Missed while everything was off: shown at next open. Then it's cleared.
- Tapping the notification opens the chat at that message.

## Disappearing messages
- **Setting:** per chat, any member can change it: Off, 24 hours, 7 days, 90 days (in chat info and the chat's menu). A line in the chat says who changed it ("Mom turned on disappearing messages: 7 days"), and the chat header shows a timer icon while it's on.
- **Clock starts at read (user's decision).** Each message sent while it's on carries the chat's timer (stamped by the server at delivery). For each person, their copy disappears that long after they read it (their read position passed it, on any of their devices). Your own messages disappear that long after you sent them. Until someone reads it, it stays for them.
- **Real deletion:** on each device the row, its plaintext, its search entry, its reactions/edits/pins/stars (which were sent in the same chat and carry the timer too) and its cached media are removed. On the server the ciphertext row and its media blobs are deleted once every current member has read it plus the timer, or at the backstop: sent + timer + 30 days, whichever is first (my call: someone who never opens the chat doesn't keep it on the server forever). The server tells online devices when it deletes, so devices that never read it drop it too.
- Turning it off affects only new messages; messages already sent keep their timer. Scheduled messages take the setting at delivery.
- Screenshots and copying aren't blocked (can't be on desktop or web); the setting's description says so.

## Approaches considered
- **Scheduled send held on the server as ciphertext** (chosen) vs held in the client's outbox. Client-held needs a device on at the time; server-held only needs a re-encrypt fallback when the key rotates, which in a family is rare.
- **Reminders pushed by the server** (chosen) vs local scheduled notifications. Local ones need the `timezone` package and per-platform scheduling (none on Linux/web) and don't sync; the server already has push and sockets everywhere, and it learns only an id and a time.
- **Timer from read** (user's decision) vs from send. From read nobody misses a message; the server needs the backstop.
- **One timer for the server** (chosen): a Durable Object alarm on the family hub set to the earliest due scheduled send, reminder or expiry, vs a cron trigger. The hub already serializes sends and fans out; an alarm fires to the second.
- **Timer as a server chat field** (chosen) vs an encrypted change event. The server must know it to delete; like the group title, it's metadata, not content.

## Non-goals
Recurring reminders, reminders for other people, scheduling in chats you aren't in, blocking screenshots, per-message timers, a global "default timer for new chats", disappearing media "view once".

## Compatibility
Dart-only plus server: phones get it by patch, desktop by a desktop release. Older apps ignore the timer and keep their copies until they update; the server still deletes its copy.

## Left to the builder
Exact layout of the picker, the scheduled list and the settings sheet; icons; how the hub alarm batches work; table and column names.
