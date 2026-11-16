-- Account deletion (DELETE /api/me, DELETE /api/admin/users/:id). Times are Unix ms.
-- Numbered 0008: 0007 is left for the pairing-offers branch, written in parallel.
--
-- A deleted user's row stays (devices, chats, resets and events reference it, and the directory
-- keeps listing it so old device certificates and reset history still verify), but its name is
-- replaced, its admin and recovery data cleared, and deleted_at set.
ALTER TABLE users ADD COLUMN deleted_at INTEGER;
