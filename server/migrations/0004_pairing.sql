-- QR pairing of a new device by an existing device of the same user. Times are Unix ms.
-- The new device starts a session (unauthenticated), an existing device approves it with a signed
-- certificate and an encrypted bundle, and the new device claims it, which creates its device row.
CREATE TABLE pair_sessions (
  id TEXT PRIMARY KEY,
  -- Short lookup code the approving device types or scans (the rest of the typed code is a secret
  -- the server never sees).
  code TEXT NOT NULL UNIQUE,
  -- SHA-256 of the new device's claim secret.
  secret_hash TEXT NOT NULL,
  -- The id the new device's row gets on claim.
  device_id TEXT NOT NULL,
  eph_pub TEXT NOT NULL,
  enc_pub TEXT NOT NULL,
  sign_pub TEXT NOT NULL,
  keys_mac TEXT NOT NULL,
  device_name TEXT NOT NULL,
  platform TEXT NOT NULL,
  client_ip TEXT,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  user_id TEXT,
  approved_by_device TEXT,
  approved_at INTEGER,
  cert_sig TEXT,
  bundle TEXT,
  claimed_at INTEGER,
  cancelled_at INTEGER
);
CREATE INDEX pair_sessions_expires ON pair_sessions(expires_at);
CREATE INDEX pair_sessions_ip ON pair_sessions(client_ip, created_at);
