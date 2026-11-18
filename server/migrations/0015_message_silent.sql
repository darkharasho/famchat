-- Whether a message was sent `silent` (reactions, edits, deletes; docs/protocol.md "Push"). Silent
-- messages aren't unread, so the app-icon badge a push carries leaves them out. The badge count
-- reads messages by (chat_id, seq), which the primary key already indexes. Rows from before this
-- migration count as 0 (the server can't tell), so a badge may overcount old unread changes until
-- those chats are read.
ALTER TABLE messages ADD COLUMN silent INTEGER NOT NULL DEFAULT 0;
