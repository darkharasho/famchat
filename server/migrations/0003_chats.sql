-- Chats, members, key epochs, wrapped chat keys, messages and WebSocket tickets. Times are Unix ms.
CREATE TABLE chats (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('direct', 'group')),
  title TEXT,
  created_by TEXT NOT NULL REFERENCES users(id),
  -- "<smaller user id>:<larger user id>" for direct chats: at most one per pair.
  direct_key TEXT UNIQUE,
  current_epoch INTEGER NOT NULL DEFAULT 1,
  last_seq INTEGER NOT NULL DEFAULT 0,
  last_message_at INTEGER,
  created_at INTEGER NOT NULL
);

CREATE TABLE chat_members (
  chat_id TEXT NOT NULL REFERENCES chats(id),
  user_id TEXT NOT NULL REFERENCES users(id),
  joined_seq INTEGER NOT NULL DEFAULT 0,
  last_read_seq INTEGER NOT NULL DEFAULT 0,
  joined_at INTEGER NOT NULL,
  PRIMARY KEY (chat_id, user_id)
);
CREATE INDEX chat_members_user ON chat_members(user_id);

-- An epoch exists once a member device has published its key's wraps.
CREATE TABLE chat_epochs (
  chat_id TEXT NOT NULL REFERENCES chats(id),
  epoch INTEGER NOT NULL,
  created_by_device TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (chat_id, epoch)
);

CREATE TABLE chat_key_wraps (
  chat_id TEXT NOT NULL REFERENCES chats(id),
  epoch INTEGER NOT NULL,
  device_id TEXT NOT NULL REFERENCES devices(id),
  wrapper_device_id TEXT NOT NULL,
  sealed TEXT NOT NULL,
  sig TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (chat_id, epoch, device_id)
);
CREATE INDEX chat_key_wraps_device ON chat_key_wraps(device_id);

CREATE TABLE messages (
  chat_id TEXT NOT NULL REFERENCES chats(id),
  seq INTEGER NOT NULL,
  id TEXT NOT NULL UNIQUE,
  sender_user_id TEXT NOT NULL,
  sender_device_id TEXT NOT NULL,
  envelope TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (chat_id, seq)
);

CREATE TABLE ws_tickets (
  hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
