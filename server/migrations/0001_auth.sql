-- Times are Unix milliseconds.
CREATE TABLE users (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  is_admin INTEGER NOT NULL DEFAULT 0,
  identity_pub TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  name TEXT NOT NULL,
  platform TEXT NOT NULL,
  enc_pub TEXT NOT NULL,
  sign_pub TEXT NOT NULL,
  cert_sig TEXT NOT NULL,
  refresh_hash TEXT UNIQUE,
  push_token TEXT,
  created_at INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  revoked_at INTEGER
);
CREATE INDEX devices_user ON devices(user_id);

CREATE TABLE invites (
  token_hash TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  make_admin INTEGER NOT NULL DEFAULT 0,
  created_by TEXT REFERENCES users(id),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  used_by TEXT,
  used_at INTEGER
);
