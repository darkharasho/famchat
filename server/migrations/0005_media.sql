-- Encrypted media in R2 (key = R2 object key, a client-chosen ULID) and the family's running total.
-- Numbered 0005: 0004 is left for plan 6, which was written in parallel.
CREATE TABLE media (
  key TEXT PRIMARY KEY,
  uploader_id TEXT NOT NULL REFERENCES users(id),
  uploader_device_id TEXT NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id),
  -- The message that will reference this blob (client-supplied; groups a photo with its thumbnail).
  message_id TEXT,
  kind TEXT NOT NULL CHECK (kind IN ('photo', 'thumb', 'voice')),
  bytes INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  -- Set when quota eviction deleted the object.
  expired_at INTEGER
);
CREATE INDEX media_live_age ON media(expired_at, created_at);
CREATE INDEX media_message ON media(message_id);

-- One row: bytes of live (unexpired) media. Kept by the triggers below.
CREATE TABLE media_usage (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  bytes INTEGER NOT NULL
);
INSERT INTO media_usage (id, bytes) VALUES (1, 0);

CREATE TRIGGER media_usage_insert AFTER INSERT ON media WHEN NEW.expired_at IS NULL
BEGIN
  UPDATE media_usage SET bytes = bytes + NEW.bytes WHERE id = 1;
END;

-- An upload's row is reserved before its object is stored and deleted if storing fails.
CREATE TRIGGER media_usage_delete AFTER DELETE ON media WHEN OLD.expired_at IS NULL
BEGIN
  UPDATE media_usage SET bytes = bytes - OLD.bytes WHERE id = 1;
END;

CREATE TRIGGER media_usage_expire AFTER UPDATE OF expired_at ON media
  WHEN OLD.expired_at IS NULL AND NEW.expired_at IS NOT NULL
BEGIN
  UPDATE media_usage SET bytes = bytes - NEW.bytes WHERE id = 1;
END;
