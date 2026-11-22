-- Per-member chat list state (docs/protocol.md "Chats"), each shown only to that member and synced
-- across their devices. Unix ms or null.
--   pinned_at: pinned to the top of the chat list (newest pin first).
--   archived_at: archived then; the chat comes back to the list when a message arrives after it
--     (clients compare; muted chats stay archived).
--   marked_unread: "mark as unread" (1) until they open the chat again.
ALTER TABLE chat_members ADD COLUMN pinned_at INTEGER;
ALTER TABLE chat_members ADD COLUMN archived_at INTEGER;
ALTER TABLE chat_members ADD COLUMN marked_unread INTEGER NOT NULL DEFAULT 0;

-- A group's photo: the R2 object chat-avatars/<chat id>/<avatar_key> (a JPEG), like profile photos.
ALTER TABLE chats ADD COLUMN avatar_key TEXT;

-- When the user's last socket closed (Unix ms): "last seen" for people sharing a family with them.
ALTER TABLE users ADD COLUMN last_seen_at INTEGER;
