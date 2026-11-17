-- Per-member chat mute (docs/protocol.md "Chats"): no pushes for that member until the time passes.
-- Null means not muted. Unix ms.
ALTER TABLE chat_members ADD COLUMN muted_until INTEGER;
