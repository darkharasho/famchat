-- Multi-family stage 1: families become a real table. Today's family becomes family #1 and the
-- reviewer sandbox becomes the hidden family #2. Times are Unix ms.
--
-- wrangler applies one migration file atomically. users.is_admin and users.reviewer stay as
-- mirrors of the family roles / family #2 membership; the new tables are the source of truth.
-- The data statements after the data marker line below are replayed by test/migration.test.ts, so they
-- are separated by a semicolon at the end of a line and contain no other line-ending semicolons.

CREATE TABLE families (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL CHECK (length(name) BETWEEN 1 AND 40),
  created_by TEXT REFERENCES users(id),
  status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'declined')),
  hidden INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  decided_at INTEGER,
  decided_by TEXT REFERENCES users(id)
);

CREATE TABLE family_members (
  family_id INTEGER NOT NULL REFERENCES families(id),
  user_id TEXT NOT NULL REFERENCES users(id),
  role TEXT NOT NULL CHECK (role IN ('admin', 'member')),
  -- The signed promotion proof, as on users (a member has none).
  admin_by TEXT REFERENCES users(id),
  admin_signer_pub TEXT,
  admin_sig TEXT,
  joined_at INTEGER NOT NULL,
  PRIMARY KEY (family_id, user_id)
);
CREATE INDEX family_members_user ON family_members(user_id, family_id);

ALTER TABLE chats ADD COLUMN family_id INTEGER REFERENCES families(id);
CREATE INDEX chats_family ON chats(family_id);

ALTER TABLE invites ADD COLUMN family_id INTEGER REFERENCES families(id);
ALTER TABLE invites ADD COLUMN email TEXT;

ALTER TABLE users ADD COLUMN email TEXT;
ALTER TABLE users ADD COLUMN email_verified_at INTEGER;
ALTER TABLE users ADD COLUMN operator INTEGER NOT NULL DEFAULT 0;
CREATE UNIQUE INDEX users_verified_email ON users(email) WHERE email_verified_at IS NOT NULL;

-- Users who left a group (or were removed) but sent messages there, so their messages still resolve.
CREATE TABLE chat_leavers (
  chat_id TEXT NOT NULL REFERENCES chats(id),
  user_id TEXT NOT NULL REFERENCES users(id),
  left_at INTEGER,
  PRIMARY KEY (chat_id, user_id)
);

-- @data
UPDATE users SET operator = 1 WHERE id = (SELECT id FROM users WHERE is_admin = 1 AND reviewer = 0 AND deleted_at IS NULL ORDER BY admin_by IS NOT NULL, created_at, id LIMIT 1);
INSERT OR IGNORE INTO families (id, name, created_by, status, hidden, created_at) VALUES (1, 'Family', (SELECT id FROM users WHERE operator = 1), 'approved', 0, CAST(strftime('%s','now') AS INTEGER) * 1000), (2, 'Reviewers', NULL, 'approved', 1, CAST(strftime('%s','now') AS INTEGER) * 1000);
INSERT OR IGNORE INTO family_members (family_id, user_id, role, admin_by, admin_signer_pub, admin_sig, joined_at) SELECT 1, id, CASE WHEN is_admin = 1 AND deleted_at IS NULL THEN 'admin' ELSE 'member' END, CASE WHEN is_admin = 1 AND deleted_at IS NULL THEN admin_by END, CASE WHEN is_admin = 1 AND deleted_at IS NULL THEN admin_signer_pub END, CASE WHEN is_admin = 1 AND deleted_at IS NULL THEN admin_sig END, created_at FROM users WHERE reviewer = 0;
INSERT OR IGNORE INTO family_members (family_id, user_id, role, joined_at) SELECT 2, id, 'member', created_at FROM users WHERE reviewer = 1;
UPDATE chats SET family_id = CASE WHEN created_by IN (SELECT id FROM users WHERE reviewer = 1) THEN 2 ELSE 1 END WHERE kind = 'group';
UPDATE invites SET family_id = CASE WHEN reviewer = 1 THEN 2 ELSE 1 END WHERE user_id IS NULL;
INSERT OR IGNORE INTO chat_leavers (chat_id, user_id, left_at) SELECT DISTINCT m.chat_id, m.sender_user_id, NULL FROM messages m JOIN chats c ON c.id = m.chat_id AND c.kind = 'group' WHERE NOT EXISTS (SELECT 1 FROM chat_members x WHERE x.chat_id = m.chat_id AND x.user_id = m.sender_user_id);
