-- Reverse pairing: a signed-in device shows a code (an "offer") that a new device scans or types.
-- The new device's pairing session is then bound to the offer, so only the offering user sees and
-- approves it. Times are Unix ms.
CREATE TABLE pair_offers (
  id TEXT PRIMARY KEY,
  -- Short lookup code the new device sends with its start (the rest of the code it scanned is a
  -- secret the server never sees).
  code TEXT NOT NULL UNIQUE,
  user_id TEXT NOT NULL,
  -- The offering device.
  device_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  -- The pairing session that took the offer (single use).
  session_id TEXT UNIQUE,
  cancelled_at INTEGER
);
CREATE INDEX pair_offers_user ON pair_offers(user_id, created_at);

-- A session started from an offer: only this user may look it up or approve it.
ALTER TABLE pair_sessions ADD COLUMN offer_user_id TEXT;
