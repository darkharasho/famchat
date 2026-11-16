-- Admin & recovery (plan 10). Times are Unix ms.

-- Audit log: resets, recoveries, promotions, device adds and revocations.
CREATE TABLE events (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  -- Whom it's about, and who did it (null when no signed-in user did: a pairing claim, a recovery).
  user_id TEXT,
  actor_id TEXT,
  payload TEXT NOT NULL DEFAULT '{}',
  created_at INTEGER NOT NULL
);
CREATE INDEX events_created ON events(created_at);

-- Signed account resets. Every row keeps the identity key it retired, so the family directory
-- carries each user's key history as statements clients can verify.
CREATE TABLE resets (
  -- Client-made ULID; part of the signed statement.
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  signer_user_id TEXT NOT NULL REFERENCES users(id),
  signer_kind TEXT NOT NULL CHECK (signer_kind IN ('admin', 'recovery')),
  -- The key that signed: the admin's identity key, or the user's recovery key.
  signer_pub TEXT NOT NULL,
  -- Recovery only: the old identity key's signature over the recovery key.
  recovery_sig TEXT,
  old_identity_pub TEXT NOT NULL,
  -- One-time key whose holder may claim the reset with a new identity key.
  claim_pub TEXT NOT NULL,
  -- The signed time.
  created_at INTEGER NOT NULL,
  sig TEXT NOT NULL,
  new_identity_pub TEXT,
  claim_sig TEXT,
  completed_at INTEGER
);
CREATE INDEX resets_user ON resets(user_id, created_at);

-- A reset invite signs in an existing user instead of creating one.
ALTER TABLE invites ADD COLUMN user_id TEXT REFERENCES users(id);
ALTER TABLE invites ADD COLUMN reset_id TEXT REFERENCES resets(id);

-- Admin recovery key (public half of a key derived from a printed code) and the identity key's
-- signature over it. Cleared when used.
ALTER TABLE users ADD COLUMN recovery_pub TEXT;
ALTER TABLE users ADD COLUMN recovery_sig TEXT;
CREATE UNIQUE INDEX users_recovery_pub ON users(recovery_pub);
