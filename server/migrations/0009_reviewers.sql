-- Reviewer accounts (docs/protocol.md "Reviewer accounts"): app-store reviewers sign in through a
-- reusable invite and live in a sandbox of their own, walled off from the family.

-- A reviewer account sees only other reviewer accounts, and the family never sees it.
ALTER TABLE users ADD COLUMN reviewer INTEGER NOT NULL DEFAULT 0;

-- A reviewer invite can be redeemed any number of times (used_by stays null) until it is revoked.
-- Its raw token is kept, so admins can show and copy the link again later; it only ever opens the
-- reviewer sandbox. Normal invites keep only the hash.
ALTER TABLE invites ADD COLUMN reviewer INTEGER NOT NULL DEFAULT 0;
ALTER TABLE invites ADD COLUMN token TEXT;
ALTER TABLE invites ADD COLUMN revoked_at INTEGER;
