-- Batch 4 (docs/protocol.md "Scheduled messages", "Reminders", "Disappearing messages"). The server
-- holds only ids, times, timers and still-encrypted envelopes. Times are Unix ms; timers are seconds.
-- One FamilyHub alarm fires at the earliest due time across the three kinds of work below.

-- The chat's disappearing-message timer: NULL (off), 86400, 604800 or 7776000. Any member changes
-- it; the last change is recorded (who, when, and the chat's last_seq then) so clients can show a
-- line in the timeline.
ALTER TABLE chats ADD COLUMN disappear_secs INTEGER;
ALTER TABLE chats ADD COLUMN disappear_changed_by TEXT;
ALTER TABLE chats ADD COLUMN disappear_changed_at INTEGER;
ALTER TABLE chats ADD COLUMN disappear_changed_seq INTEGER;

-- Each message carries the chat's timer as it was when the message was stored (NULL: never
-- disappears). delete_at is when the server deletes the row and its media: the backstop
-- (created_at + timer + 30 days) at first, moved earlier to "every current member read it" + timer
-- once that happens. NULL when there is no timer.
ALTER TABLE messages ADD COLUMN disappear_secs INTEGER;
ALTER TABLE messages ADD COLUMN delete_at INTEGER;
-- 1 when the message was delivered from scheduled_messages: then any device of the sender may
-- resend its id and get the original ack (a plain send is idempotent per device).
ALTER TABLE messages ADD COLUMN scheduled INTEGER NOT NULL DEFAULT 0;
CREATE INDEX messages_delete_at ON messages(delete_at) WHERE delete_at IS NOT NULL;

-- Messages a user scheduled, held as ciphertext until deliver_at. id is the message id it will be
-- delivered as. The row is deleted when it is delivered, cancelled or dropped.
--   state: pending (waiting for deliver_at), needs_resend (the chat's epoch moved on: a device of
--     the sender must re-encrypt it and send it), failed (could not be delivered; see protocol.md).
--   next_at: when the hub next tries it (deliver_at, or later after a failure); attempts: failures.
CREATE TABLE scheduled_messages (
  id TEXT PRIMARY KEY,
  chat_id TEXT NOT NULL,
  sender_user_id TEXT NOT NULL,
  sender_device_id TEXT NOT NULL,
  envelope TEXT NOT NULL,
  silent INTEGER NOT NULL DEFAULT 0,
  -- JSON array of user ids, or NULL.
  mentions TEXT,
  deliver_at INTEGER NOT NULL,
  state TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'needs_resend', 'failed')),
  next_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX scheduled_messages_due ON scheduled_messages(state, next_at);
CREATE INDEX scheduled_messages_sender ON scheduled_messages(sender_user_id, deliver_at);

-- A user's reminder about one message: private to them. Deleted when it fires.
CREATE TABLE reminders (
  user_id TEXT NOT NULL,
  chat_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  remind_at INTEGER NOT NULL,
  next_at INTEGER NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, message_id)
);
CREATE INDEX reminders_due ON reminders(next_at);

-- Messages the server deleted because their timer ran out, so a device that was offline learns of
-- them (GET /me/gone). Ids only. Kept 121 days (longest timer + the 30-day backstop + a day).
CREATE TABLE message_tombstones (
  cursor INTEGER PRIMARY KEY AUTOINCREMENT,
  chat_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  message_id TEXT NOT NULL,
  deleted_at INTEGER NOT NULL
);
CREATE INDEX message_tombstones_age ON message_tombstones(deleted_at);
