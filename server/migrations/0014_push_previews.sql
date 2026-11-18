-- Per-device opt-in for notification message previews (docs/protocol.md "Push"): a device with 1 gets
-- the encrypted envelope in its push and decrypts a preview on-device. Reset to 0 with the token.
ALTER TABLE devices ADD COLUMN push_previews INTEGER NOT NULL DEFAULT 0;
