-- Videos: a new media kind. SQLite can't change a CHECK constraint, so the table is rebuilt with
-- the same rows. The usage triggers go first (so moving rows doesn't touch the running total) and
-- come back unchanged; media_usage keeps its total.
PRAGMA defer_foreign_keys = true;

DROP TRIGGER media_usage_insert;
DROP TRIGGER media_usage_delete;
DROP TRIGGER media_usage_expire;

CREATE TABLE media_new (
  key TEXT PRIMARY KEY,
  uploader_id TEXT NOT NULL REFERENCES users(id),
  uploader_device_id TEXT NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id),
  -- The message that will reference this blob (client-supplied; groups a blob with its thumbnail).
  message_id TEXT,
  kind TEXT NOT NULL CHECK (kind IN ('photo', 'thumb', 'voice', 'video')),
  bytes INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  -- Set when quota eviction deleted the object.
  expired_at INTEGER
);
INSERT INTO media_new (key, uploader_id, uploader_device_id, chat_id, message_id, kind, bytes, created_at, expired_at)
  SELECT key, uploader_id, uploader_device_id, chat_id, message_id, kind, bytes, created_at, expired_at FROM media;
DROP TABLE media;
ALTER TABLE media_new RENAME TO media;
CREATE INDEX media_live_age ON media(expired_at, created_at);
CREATE INDEX media_message ON media(message_id);

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
