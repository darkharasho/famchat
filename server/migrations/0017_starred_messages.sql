-- Messages a user starred (docs/protocol.md "Starred messages"): private to them, synced across their
-- devices. The server only learns which message ids, never their content. Unix ms.
CREATE TABLE starred_messages (
  user_id TEXT NOT NULL,
  chat_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  starred_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, message_id)
);
CREATE INDEX starred_messages_user ON starred_messages (user_id, starred_at);
