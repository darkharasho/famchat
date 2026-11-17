# Multi-family Stage 1 (Data model and visibility) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Families exist in the database (today's family becomes family #1, reviewers become a hidden family). Everything a person sees and every event fan-out is scoped to "shares a family with me". Group chats belong to one family. Direct chats go read-only when the two people share no family. With only family #1 in production, nobody notices a change.

**Architecture:** Migration 0013 adds `families`, `family_members`, `chats.family_id`, `invites.family_id`/`email`, `users.email`/`email_verified_at`/`operator` and a small `chat_leavers` table, then backfills from today's data. A new `server/src/lib/family.ts` holds the visibility rule (`familyPeers`, `shares`, constants for family #1 and the reviewer family). Routes and `FamilyHub` swap every "same side of the reviewer line" check for that rule. The hub caches each user's peer set in memory and drops the cache when membership changes. The app learns `former: true` users and `operator`, shows a read-only footer for direct chats with a former peer, and hides operator-only actions from other admins.

**Tech Stack:** Cloudflare Workers + Hono, D1 (SQLite), Durable Objects (hibernation API), vitest with `@cloudflare/vitest-pool-workers`. Flutter with riverpod, drift and go_router.

**Spec:** `docs/superpowers/specs/2026-11-17-multi-family-design.md`: stage 1 of "Staging", plus the server-only parts of "Account-wide powers". Executors read the spec's "Data", "Visibility rule", "Account-wide powers" and "Compatibility" sections before starting.

## Global Constraints

- Vitest always runs with `--maxWorkers=2` (`cd server && npx vitest run --maxWorkers=2 <files>`).
- Flutter commands need `export PATH=$HOME/development/flutter/bin:$PATH` first. Never run `dart format` on existing files.
- Every commit message ends with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Anti-goal: the upgrade must be invisible to today's family. That means no lost chats, no re-pairing, no new key-change warnings, the same directory, the same admins and the same `isAdmin` values.
- Anti-goal: nobody ever sees a person they don't share a family with, through the directory, an event, an @mention, a reset or a member list.
- `users.is_admin` and `users.reviewer` stay and are **written** in sync (mirrors of family #1 admin and reviewer-family membership). New permission and visibility code never **reads** them. Existing reads that only feed the access token's `adm` claim (auth.ts, pairing.ts) stay as they are.
- The media cap stays at 8 GiB, and reviewers keep their own 256 MiB cap.
- `docs/protocol.md` is updated in the same task as the behaviour it describes.
- Group `familyId` is a JSON integer. Status codes follow `docs/protocol.md`: 400 `invalid_request` for a bad body, 403 `no_shared_family` for direct chat create, 409 `last_admin`.
- Out of scope (later stages): v2 admin proofs, per-family pinning, the Families API, `family`/`invite` events, email, Settings → Families, the family picker, family names in group info, and owner transfer.

## Decisions the spec left open

1. **Family ids are integers. Family #1 is `id = 1`; the hidden reviewer family is `id = 2`.** The migration creates both even on an empty database (family #1 has `created_by = NULL` until bootstrap). Code uses `FAMILY_ONE = 1` and `REVIEWER_FAMILY = 2` from `lib/family.ts`. `families.created_by` is nullable for that reason.
2. **Deleted accounts keep their `family_members` rows** (demoted to `member`, proof cleared), and the migration adds deleted non-reviewer users to family #1 as members. The spec's migration step 2 says "non-deleted". It is widened so the directory keeps listing "Deleted user" entries to the same people as today (anti-goal: no visible change). Every rule that counts, notifies or messages people filters `users.deleted_at IS NULL`.
3. **`former` users** are computed as the caller's chat co-members plus people in `chat_leavers` for the caller's chats, minus the caller's family peers. `chat_leavers(chat_id, user_id, left_at)` is written when someone leaves or is removed from a group. The migration backfills it once from `messages.sender_user_id` of non-members. The other way, scanning `messages` on every `GET /users`, would cost too many D1 row reads.
4. **Former entries** have the normal user shape with `isAdmin: false`, `adminProof: null`, `families: []` and `former: true`. Every other entry has `former: false`.
5. **`isAdmin`/`adminProof` in `/users`** describe family #1 and are given only when the caller is also in family #1. Otherwise they're `false`/`null`, so family #1's roles never leak to outsiders. `/me.isAdmin` means admin of family #1.
6. **`families` arrays include the hidden reviewer family** for reviewers looking at reviewers. Only reviewers can see it.
7. **Hub cache:** `FamilyHub` keeps `Map<userId, Set<peerId>>` in memory. It loads a user's set from D1 on that user's connect, or lazily for an event's subject. A new RPC `sharesChanged()` clears the whole map; the Worker calls it after any membership change in stage 1 (invite redeem of any kind, account deletion). Stage 3's `family` event will call the same RPC. The cache is lost on hibernation, which is fine because it reloads lazily.
8. **Sending in a direct chat is checked against D1, not the cache.** It's one query, done only for directs. A direct chat whose peer **deleted their account** keeps today's behaviour: there's no live peer in `chat_members`, so the send is allowed and no footer shows. A WebSocket `send` that fails the rule gets `{type:"error", id, error:"no_shared_family"}`.
9. **`device` events** (`sharingUserIds`) now go to chat co-members who are also family peers ("former" people get no events from you). `read` and `chat`/`keys`/`removed`/`msg` still follow chat membership. `typing` goes to chat members ∩ the sender's peers.
10. **Legacy admin routes during stage 1.** `requireAdmin` means "admin of family #1". It guards `POST /admin/invites` (always family #1), `POST /admin/users/:id/reset` (target must be a live member of family #1), `POST /admin/users/:id/admin` (writes the v1 proof into family #1's `family_members` row and mirrors `users.is_admin`/`admin_*`) and `GET /admin/usage`. `POST /admin/recovery-key` and the recovery redeem accept an admin of **any** non-hidden family. These routes are operator-only: `POST|DELETE /admin/reviewer-invite`, `GET /admin/reviewers` and `DELETE /admin/users/:id`.
11. **Operator lifecycle.** The migration marks the earliest live non-reviewer admin with `admin_by IS NULL` as operator, falling back to the earliest live admin, and makes them family #1's `created_by`. Redeeming a bootstrap invite (`created_by IS NULL`) on an empty database sets `operator = 1` and fills family #1's `created_by`. Deleting the operator's account clears the flag. No successor is chosen automatically (set by hand in D1; noted in protocol.md). `POST /admin/bootstrap` gives 409 `already_bootstrapped` while family #1 has a live member or a live operator exists.
12. **`last_admin` body** names the family: `409 {error:"last_admin", familyId, familyName}`. `ApiError` gains an optional `extra` object that is merged into the JSON body.
13. **Group creation family must be `approved`** and the caller and everyone in `userIds` must be live members. Anything else gives 400 `invalid_request`. Without `familyId` the server uses the caller's only family. If the caller has several, it uses family #1 when the caller is in it; otherwise it answers 400 (spec "Compatibility").
14. **`ChatOut` gains `familyId: number | null`.** The app ignores it in stage 1.
15. **The app's read-only footer** shows for a direct chat whose other member's local user row has `former == true`. Copy: "You're no longer in a family together". A `no_shared_family` send error marks the message failed and refreshes the directory, so the footer appears.
16. **`/me` gains `operator: boolean`.** The app shows "Remove from family" (which calls `DELETE /admin/users/:id`) and the reviewer section only when `me.operator` is true. In the app's test fakes, `operator` defaults to the value of `admin`.

## Review Focus

1. **Production-shaped data through the migration.** Deleted users, a reviewer row with `is_admin = 1`, an admin with a proof, a reset invite (`user_id` set) and a reviewer-created group must all land as decisions 1, 2 and 11 say. Today's admins must keep their proofs, so no warnings appear. (Task 1, `migration.test.ts`.)
2. **An old client creating a group without `familyId`.** In family #1 plus another family, the group goes to family #1. In two families without #1 the server answers 400. A lone reviewer's "note to self" still works. (Task 6.)
3. **A user joins while others are connected.** Existing sockets must get the newcomer's presence without reconnecting, which tests that `sharesChanged()` is called on redeem. (Task 5.)
4. **A direct chat with a peer who deleted their account** still sends as today, with no footer and no `no_shared_family`. (Task 6 server, Task 10 app.)
5. **Deleted users** are still listed to their family (`deleted: true`). They get no presence and don't count toward `last_admin`. (Tasks 4, 5, 7.)

---

## File Structure

Server:
- Create `server/migrations/0013_families.sql`: schema plus backfill. The backfill sits after a line `-- @data` so the migration test can replay it.
- Create `server/src/lib/family.ts`, which absorbs today's `sharingUserIds`: constants, the peers/shares SQL, the role helpers, the group family choice and the hub-cache poke.
- Modify `server/src/middleware/auth.ts`, `server/src/env.ts`, `server/src/lib/errors.ts`, `server/src/index.ts`.
- Modify routes: `users.ts`, `me.ts`, `admin.ts`, `auth.ts`, `chats.ts`, `ws.ts`, `media.ts`. Modify libs: `chatdb.ts`, `delete-account.ts`, `reset-account.ts`.
- Modify `server/src/hub.ts` (peer cache, scoped presence/typing, direct-send rule, `sharesChanged`).
- Tests: modify `server/test/helpers.ts`. Create `server/test/migration.test.ts` and `server/test/families.test.ts`. Extend `users`, `hub`, `chats`, `members`, `admin`, `account-deletion`, `reviewer` and `recovery` tests.

App:
- `app/lib/chat/wire.dart`, `app/lib/chat/db/chat_db.dart` (+ `.g.dart`), `app/lib/chat/directory.dart`, `app/lib/chat/chat_sync.dart`.
- `app/lib/screens/chats/conversation_view.dart`, `app/lib/screens/chats/new_chat_screen.dart`, `app/lib/screens/family_screen.dart`.
- `app/lib/api/models.dart`, `app/lib/api/api_client.dart`.
- Fakes: `app/test/support/fake_chat_backend.dart`, `app/test/support/fake_server.dart`, `app/test/support/app_harness.dart`.

Docs: `docs/protocol.md`.

---

### Task 1: Migration 0013 and test fixtures

**Files:**
- Create: `server/migrations/0013_families.sql`
- Modify: `server/test/helpers.ts` (`resetDb`, `insertUserWithDevice`, `insertInvite`; new `insertFamily`, `joinFamily`)
- Test: `server/test/migration.test.ts`

**Interfaces:**
- Produces (schema):
  - `families(id INTEGER PRIMARY KEY, name TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 40), created_by TEXT REFERENCES users(id), status TEXT NOT NULL CHECK(status IN ('pending','approved','declined')), hidden INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL, decided_at INTEGER, decided_by TEXT REFERENCES users(id))`
  - `family_members(family_id INTEGER NOT NULL REFERENCES families(id), user_id TEXT NOT NULL REFERENCES users(id), role TEXT NOT NULL CHECK(role IN ('admin','member')), admin_by TEXT REFERENCES users(id), admin_signer_pub TEXT, admin_sig TEXT, joined_at INTEGER NOT NULL, PRIMARY KEY(family_id, user_id))` with index `family_members_user(user_id, family_id)`
  - `chats.family_id INTEGER REFERENCES families(id)` with index `chats_family(family_id)`
  - `invites.family_id INTEGER REFERENCES families(id)` and `invites.email TEXT`
  - `users.email TEXT`, `users.email_verified_at INTEGER` and `users.operator INTEGER NOT NULL DEFAULT 0`, with unique partial index `users_verified_email ON users(email) WHERE email_verified_at IS NOT NULL`
  - `chat_leavers(chat_id TEXT NOT NULL REFERENCES chats(id), user_id TEXT NOT NULL REFERENCES users(id), left_at INTEGER, PRIMARY KEY(chat_id, user_id))`
- Produces (test helpers in `server/test/helpers.ts`):
  - `insertUserWithDevice(opts: { admin?: boolean; name?: string; reviewer?: boolean; operator?: boolean; families?: { id: number; role?: "admin" | "member" }[] })`. Defaults: a reviewer joins `[{id: 2}]`; anyone else joins `[{id: 1, role: admin ? "admin" : "member"}]`. `families: []` means no family. It mirrors `is_admin`/`reviewer` as today and sets `operator`.
  - `insertFamily(opts?: { name?: string; status?: "pending" | "approved" | "declined"; hidden?: boolean; createdBy?: string }): Promise<number>` (default name "Other", status approved).
  - `joinFamily(userId: string, familyId: number, role: "admin" | "member" = "member"): Promise<void>`.
  - `insertInvite` sets `family_id = 1`.

- [ ] **Step 1: Write the failing migration test** `server/test/migration.test.ts`. It imports `sql from "../migrations/0013_families.sql?raw"`, takes the text after the `-- @data` line, splits it on `;\n` and runs the non-empty statements with `env.DB.batch`. Before replaying, the test runs `DELETE FROM family_members; UPDATE chats SET family_id = NULL; UPDATE invites SET family_id = NULL; DELETE FROM families` and inserts legacy rows with raw SQL (`users` with `is_admin`/`reviewer`/`deleted_at`/`admin_by`, `chats`, `invites`, `messages`). Tests:
  - `it("today's family becomes family #1 with the same admins and proofs")`: family 1 is `{name:"Family", status:"approved", hidden:0}`. Every non-reviewer user (deleted included) has a row. Live `is_admin=1` users have `role='admin'` with `admin_by/admin_signer_pub/admin_sig` copied. A deleted former admin has `role='member'`.
  - `it("reviewers become the hidden family #2")`: family 2 has `hidden=1, status='approved'`. Reviewer users are `member`, including a reviewer row with `is_admin=1`.
  - `it("the bootstrapped admin becomes operator and owner")`: of two live admins, the one with `admin_by IS NULL` gets `operator=1` and becomes `families(1).created_by`. Others stay at 0.
  - `it("groups and invites get their family")`: a group by a family user goes to 1, a group by a reviewer to 2, directs stay NULL. A normal invite goes to 1, a reviewer invite to 2, a reset invite (`user_id` set) stays NULL.
  - `it("past group senders become leavers")`: a sender of a message in a group they're no longer a member of gets a `chat_leavers` row. Current members get none.
  - `it("an empty database gets family #1 without an owner and the reviewer family")`: run `resetDb` then the data part, and assert both families exist with `created_by` NULL.
- [ ] **Step 2: Run it and check it fails.** Run `cd server && npx vitest run --maxWorkers=2 test/migration.test.ts`. Expected: FAIL (no such table `families` / the import is missing).
- [ ] **Step 3: Write `server/migrations/0013_families.sql`.** Schema statements come first, then the `-- @data` line, then these data statements in order. Timestamps use `CAST(strftime('%s','now') AS INTEGER) * 1000`. Use `INSERT OR IGNORE` for the two family rows so a replay on an empty database is safe.
  1. Mark the operator: the `UPDATE users SET operator = 1 WHERE id = (SELECT id FROM users WHERE is_admin = 1 AND reviewer = 0 AND deleted_at IS NULL ORDER BY admin_by IS NOT NULL, created_at, id LIMIT 1)`.
  2. Insert family 1 (`'Family'`, `created_by` = the operator's id or NULL, approved, hidden 0) and family 2 (`'Reviewers'`, NULL, approved, hidden 1).
  3. Members of family 1: `SELECT 1, id, CASE WHEN is_admin = 1 AND deleted_at IS NULL THEN 'admin' ELSE 'member' END, <admin_* only when admin>, created_at FROM users WHERE reviewer = 0`.
  4. Members of family 2: reviewer users as `member`.
  5. `UPDATE chats SET family_id = CASE WHEN created_by IN (SELECT id FROM users WHERE reviewer = 1) THEN 2 ELSE 1 END WHERE kind = 'group'`.
  6. `UPDATE invites SET family_id = CASE WHEN reviewer = 1 THEN 2 ELSE 1 END WHERE user_id IS NULL`.
  7. `INSERT OR IGNORE INTO chat_leavers SELECT DISTINCT m.chat_id, m.sender_user_id, NULL FROM messages m JOIN chats c ON c.id = m.chat_id AND c.kind = 'group' WHERE NOT EXISTS (SELECT 1 FROM chat_members x WHERE x.chat_id = m.chat_id AND x.user_id = m.sender_user_id)`.

  Header comment: wrangler applies one migration file atomically, and `users.is_admin`/`users.reviewer` are now mirrors.
- [ ] **Step 4: Update `server/test/helpers.ts`.** `resetDb` must respect foreign keys. Delete `chat_leavers` with the chat tables, then `family_members`, then `DELETE FROM families WHERE id > 2` and `UPDATE families SET created_by = NULL, decided_by = NULL`, all before `DELETE FROM users`. Add the helpers listed in Interfaces. `insertInvite` binds `family_id = 1`.
- [ ] **Step 5: Run the migration test and then the whole suite.** Run `cd server && npx vitest run --maxWorkers=2`. Expected: all PASS (no product code reads the new tables yet).
- [ ] **Step 6: Commit.**
```bash
git add server/migrations/0013_families.sql server/test/helpers.ts server/test/migration.test.ts
git commit -m "feat(server): families schema, migration 0013 and test fixtures"
```

### Task 2: Family library, middleware and error codes

**Files:**
- Modify: `server/src/lib/family.ts`, `server/src/middleware/auth.ts`, `server/src/env.ts`, `server/src/lib/errors.ts`, `server/src/index.ts`
- Test: `server/test/families.test.ts` (new)

**Interfaces:**
- Produces (`server/src/lib/family.ts`):
  - `export const FAMILY_ONE = 1; export const REVIEWER_FAMILY = 2;`
  - `export const PEERS_SQL`: one `?` (the user id) that selects `user_id` of every **live** user sharing a family with that user, the user included. `export const DIRECTORY_PEERS_SQL` is the same without the live filter (it includes deleted accounts).
  - `familyPeers(db: D1Database, userId: string): Promise<string[]>`: live peers including self.
  - `shares(db: D1Database, a: string, b: string): Promise<boolean>`: true when both are live and share a family.
  - `familyRole(db: D1Database, userId: string, familyId: number): Promise<"admin" | "member" | null>`
  - `isAnyAdmin(db: D1Database, userId: string): Promise<boolean>`: admin of any non-hidden family.
  - `groupFamilyFor(db: D1Database, userId: string, requested: unknown): Promise<number>`: decision 13; throws `ApiError("invalid_request")`.
  - `sharingUserIds(db, userId)` keeps its signature but returns only chat co-members who are also in `familyPeers` (decision 9), the user included.
  - `sharesChanged(env: Env): Promise<void>`: calls `hubStub(env).sharesChanged()` and never throws (it logs, like `notify`). The hub RPC itself arrives in Task 5; until then this calls a method that Task 5 adds, so add a no-op `async sharesChanged() {}` on `FamilyHub` in this task.
- Produces (`AppVars`): `operator: boolean` next to `reviewer: boolean`. `requireAuth` derives `reviewer` from membership in `REVIEWER_FAMILY` and `operator` from `users.operator`, in its existing single query (joined).
- Produces (middleware): `requireAdmin` means `familyRole(user, FAMILY_ONE) === "admin"`. New `requireAnyAdmin` uses `isAnyAdmin`. New `requireOperator` uses `c.get("operator")`. Each throws `forbidden`.
- Produces (`errors.ts`): `ErrorCode` gains `"no_shared_family"` → 403. `class ApiError { constructor(code: ErrorCode, readonly extra?: Record<string, unknown>) }`. `errorResponse(code, extra?)` merges `extra` into `{error: code}`. `index.ts` `onError` passes `err.extra`.

- [ ] **Step 1: Write failing tests** in `server/test/families.test.ts`:
  - `it("familyPeers lists live people sharing any family, self included")`: A in 1 and 3, B in 1, C in 3, D only in 4, E deleted in 1. `familyPeers(A)` is exactly `{A, B, C}`, `familyPeers(D)` is `[D]`.
  - `it("shares is false for a deleted or unshared person")`
  - `it("groupFamilyFor picks the only family, then family #1, else 400")`: in {3} it returns 3; in {1,3} it returns 1; in {3,4} it throws `invalid_request`; given an explicit `4` while the user is not in 4, it throws; a pending family throws; requested `"1"` (a string) throws.
  - `it("sharingUserIds leaves out chat co-members outside your families")`
  - `it("an error's extra fields reach the body")`: `errorResponse("last_admin", {familyId: 1, familyName: "Family"})` has status 409 and body `{error:"last_admin", familyId:1, familyName:"Family"}`.
  - `it("requireAdmin follows family #1, not users.is_admin")`: a user with `is_admin=1` but `families: [{id: 3, role: "admin"}]` gets 403 on `GET /admin/usage`. A family #1 admin gets 200.
- [ ] **Step 2: Run them and check they fail.** Run `cd server && npx vitest run --maxWorkers=2 test/families.test.ts`. Expected: FAIL (the exports are missing).
- [ ] **Step 3: Implement the exports above.** `PEERS_SQL` is `SELECT DISTINCT b.user_id FROM family_members a JOIN family_members b ON b.family_id = a.family_id JOIN users u ON u.id = b.user_id AND u.deleted_at IS NULL WHERE a.user_id = ?`. The caller must also be live for `shares`.
- [ ] **Step 4: Run the new tests and the full suite.** Run `cd server && npx vitest run --maxWorkers=2 && npm run typecheck`. Expected: PASS. Existing admin tests pass because the fixtures put admins in family #1.
- [ ] **Step 5: Commit.** Message: `feat(server): family visibility helpers, operator and family-scoped admin checks`.

### Task 3: Joining writes family membership; bootstrap and invites per family

**Files:**
- Modify: `server/src/routes/auth.ts` (invite redeem, `redeemReviewer`, recovery redeem condition), `server/src/routes/admin.ts` (`createInvite`, `/bootstrap`, `/reviewer-invite`, `/users/:id/admin`)
- Test: `server/test/admin.test.ts`, `server/test/auth.test.ts`, `server/test/reviewer.test.ts`

**Interfaces:**
- Consumes: `FAMILY_ONE`, `REVIEWER_FAMILY` and `sharesChanged(env)` from Task 2.
- Produces: rows in `family_members` for every new account. `invites.family_id` is set for every non-reset invite.

- [ ] **Step 1: Write failing tests.**
  - admin.test `it("redeeming the bootstrap invite makes the operator and owner of family #1")`: after bootstrap and redeem, `users.operator = 1`, `family_members(1, user).role = 'admin'` and `families(1).created_by = user`.
  - admin.test `it("bootstrap is refused while family #1 has a live member or an operator exists")`: an operator with `families: []` gets 409 `already_bootstrapped`. A reviewer-only database still allows bootstrap (keep the existing "bootstrap counts only the family" test green).
  - auth.test `it("a normal invite joins its family as member, or admin when make_admin")`: check the `family_members` row and `invites.family_id = 1` for an invite from `POST /admin/invites`.
  - reviewer.test `it("a reviewer redeem joins the hidden family")`: a `family_members(2, r)` row exists, there's no row in family 1, and `invites.family_id = 2` for the reviewer invite.
  - admin.test `it("promotion writes the proof into family #1")`: after `POST /admin/users/:id/admin`, `family_members(1, target)` has `role='admin'` and the same `admin_by/admin_signer_pub/admin_sig`, and `users.is_admin = 1` is mirrored. Promoting a user who is not in family #1 → 404.
- [ ] **Step 2: Run them and check they fail.** Run `cd server && npx vitest run --maxWorkers=2 test/admin.test.ts test/auth.test.ts test/reviewer.test.ts`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.** Add these to each redeem's existing batch, guarded the same way as the user insert:
  - The `family_members` insert: `SELECT family_id, ?, CASE make_admin WHEN 1 THEN 'admin' ELSE 'member' END, ... FROM invites WHERE token_hash = ? AND used_by = ?`.
  - For bootstrap invites (`created_by IS NULL`), `UPDATE users SET operator = 1 WHERE id = ? AND NOT EXISTS (SELECT 1 FROM users WHERE operator = 1 AND deleted_at IS NULL)` and the `families` `created_by` fill (decision 11).

  Change the redeem's bootstrap guard and `createInvite`'s guard from "no live non-reviewer user" to "no live member of family #1 and no live operator". `createInvite` and the reviewer invite insert `family_id`. Call `sharesChanged(c.env)` after every successful redeem, the reviewer redeem included. The recovery redeem lookup (`recovery_pub = ? AND is_admin = 1`) becomes "and is an admin of any non-hidden family". Promotion updates `family_members` for family #1 and mirrors `users`. It's guarded on the target being a live member of family #1.
- [ ] **Step 4: Run the server suite.** Run `cd server && npx vitest run --maxWorkers=2 && npm run typecheck`. Expected: PASS.
- [ ] **Step 5: Update docs/protocol.md.** In "Auth and devices", say that admin routes check family #1 admin in `family_members` (not `users.is_admin`). Update the bootstrap and operator rule (decision 11). Note that redeeming joins the invite's family.
- [ ] **Step 6: Commit.** Message: `feat(server): invites and redeems join a family; bootstrap makes the operator`.

### Task 4: Scoped directory, avatars and /me

**Files:**
- Modify: `server/src/routes/users.ts`, `server/src/routes/me.ts` (`GET /`)
- Test: `server/test/users.test.ts`, `server/test/avatar.test.ts`, `server/test/me.test.ts`

**Interfaces:**
- Consumes: `DIRECTORY_PEERS_SQL`, `FAMILY_ONE` and `chat_leavers`.
- Produces: each `GET /users` entry is `{id, name, isAdmin, identityPub, adminProof, devices, resets, deleted, avatarKey, families: {id: number, role: "admin"|"member", adminProof: {byUserId, signerPub, sig} | null}[], former: boolean}`. `/me` gains `operator: boolean`, and its `isAdmin` comes from family #1's `family_members`.

- [ ] **Step 1: Write failing tests** in users.test.ts. Use `insertFamily`/`joinFamily` and `createDirect`/`createGroup` while people still share a family, then remove a `family_members` row with raw SQL to make them "former".
  - `it("lists only the caller and people sharing a family with them")`: A in {1}, B in {1}, C in {3} only. A sees {A, B}; C sees {C}.
  - `it("a deleted account is still listed to its family")`: `deleted: true`. It's not listed to anyone outside the family.
  - `it("families lists only the families shared with the caller")`: A in {1, 3} as admin of 3, B in {1, 3}, C in {3, 4}. A's view of C is `families: [{id: 3, role: "member", adminProof: null}]` and never mentions 4. A's view of A lists both of A's families.
  - `it("isAdmin and adminProof describe family #1, and only to family #1")`: a family #1 admin seen by a member of family 3 only (sharing 3) has `isAdmin: false, adminProof: null`.
  - `it("people sharing only a chat come back as former")`: A and B had a direct chat, then B leaves every family A is in. A's view of B has `former: true, isAdmin: false, adminProof: null, families: []`, plus devices and resets. B's view of A is the same.
  - `it("a group leaver outside your families is former")`: covered by a `chat_leavers` row, after `DELETE /chats/:id/members/:me` (Task 6 writes these rows; seed the row by hand here).
  - avatar.test `it("only people in your directory can fetch your photo")`: an unrelated user gets 404. A former person gets 200.
  - me.test `it("reports operator and family #1 admin")`
  - Update "lists every user with devices" so it still passes with the new fields.
- [ ] **Step 2: Run them and check they fail.** Run `cd server && npx vitest run --maxWorkers=2 test/users.test.ts test/avatar.test.ts test/me.test.ts`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement `GET /users` as one `db.batch`.**
  - The caller's family rows.
  - All `family_members` rows of those families.
  - `FORMER_SQL`: co-members of the caller's chats ∪ `chat_leavers` of the caller's chats, `EXCEPT` `DIRECTORY_PEERS_SQL`.
  - `users`, `devices` and `resets` for `id IN (DIRECTORY_PEERS_SQL) OR id IN (FORMER_SQL)`, ordered as today.

  Build `families` per user from the member rows. Restrict it to families the caller is in, and give adminProof only for admins with a proof. The avatar route checks the same id set. Drop `c.get("reviewer")` use here, since reviewer isolation now falls out of the rule.
- [ ] **Step 4: Run the suite.** Run `cd server && npx vitest run --maxWorkers=2`. Expected: PASS, including every "directory isolation" test in reviewer.test.ts unchanged.
- [ ] **Step 5: Update docs/protocol.md "Directory".** Document the scope rule, the `families` and `former` fields and decisions 4 and 5. In "Profile", say who can fetch an avatar.
- [ ] **Step 6: Commit.** Message: `feat(server): GET /users lists only shared families plus former chat partners`.

### Task 5: Hub fan-out scoped to family peers

**Files:**
- Modify: `server/src/hub.ts`, `server/src/routes/ws.ts`, `server/src/routes/me.ts` (`sameSide`), `server/src/lib/delete-account.ts` (the `account_deleted` recipients and `sharesChanged`), `server/src/lib/reset-account.ts` (`notifyReset`)
- Test: `server/test/hub.test.ts`, `server/test/reviewer.test.ts` ("events don't cross over"), `server/test/families.test.ts`

**Interfaces:**
- Consumes: `familyPeers` and `sharesChanged` from Task 2.
- Produces: `FamilyHub.sharesChanged(): Promise<void>` (RPC: clears the cache) and the private `peersOf(userId: string): Promise<Set<string>>`. `Att` becomes `{userId, deviceId, at}`; an old attachment's `rv` is ignored. `onlineUserIds(exclude?: WebSocket, viewer?: string): Promise<string[]>`. With `viewer`, the list is only the viewer's peers. `goneOffline`/`prune` become async (callers await them).

- [ ] **Step 1: Write failing tests** (hub.test.ts, new `describe("family scope")`):
  - `it("hello and presence reach only people sharing a family")`: A in {1}, B in {1}, C in {3}. C's hello doesn't contain A. A gets no presence for C (use `none("presence")` after C connects). B gets A's presence.
  - `it("a newcomer's presence reaches connected people without reconnecting")` (Review Focus 3): A is connected; then `redeemNewDevice()` creates B in family 1 and B connects. A gets `presence {userId: B, online: true}`.
  - `it("typing in a shared direct chat stops when the two share no family")`: create a direct while both are in family 3, then delete one `family_members` row and call `env.HUB.get(env.HUB.idFromName("family")).sharesChanged()`. The other socket gets `none("typing")`.
  - `it("profile, reset and account_deleted go only to family peers")`: renaming C (family 3) sends `profile` to C's own other socket but not to A (family 1). Do the same for a deletion via `DELETE /me`.
  - `it("device events skip former chat partners")`
- [ ] **Step 2: Run them and check they fail.** Run `cd server && npx vitest run --maxWorkers=2 test/hub.test.ts`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.**
  - Hub `fetch` awaits `peersOf(userId)` before sending hello.
  - Presence goes to sockets whose `att.userId` is in `peersOf(subject)`.
  - `handleTyping` sends to members ∩ `peersOf(sender)`.
  - Remove `sendAll`'s side parameter and the `x-famchat-side` header in `ws.ts`.
  - Replace `sameSide` in `me.ts`, the `account_deleted` query in `delete-account.ts` and `notifyReset`'s query with `familyPeers`.
  - `deleteAccount` calls `sharesChanged(env)` after its batch.
- [ ] **Step 4: Run the suite.** Run `cd server && npx vitest run --maxWorkers=2`. Expected: PASS, including reviewer.test "presence and the hello list stay on each side" and "account_deleted reaches only the deleted user's side" unchanged.
- [ ] **Step 5: Update docs/protocol.md "WebSocket → Hub → client".** Say that presence, hello, typing, profile, reset and account_deleted go only to people sharing a family, and `device` only to chat partners who share one.
- [ ] **Step 6: Commit.** Message: `feat(server): hub presence and events reach only family peers`.

### Task 6: Chats belong to families; direct chats need a shared family

**Files:**
- Modify: `server/src/routes/chats.ts`, `server/src/lib/chatdb.ts` (`CHAT_SELECT`, `ChatOut.familyId`), `server/src/hub.ts` (`handleSend` rule)
- Test: `server/test/chats.test.ts`, `server/test/members.test.ts`, `server/test/hub.test.ts`, `server/test/reviewer.test.ts`

**Interfaces:**
- Consumes: `groupFamilyFor`, `shares` and `REVIEWER_FAMILY` from Task 2.
- Produces: `ChatOut.familyId: number | null`. `POST /chats` group bodies accept an optional `familyId: number`. The WebSocket error code is `no_shared_family`. Leaving or removal writes `chat_leavers`.

- [ ] **Step 1: Write failing tests.**
  - chats.test `it("a group without familyId goes to the caller's only family")`: `chat.familyId === 1` for family #1 users. For a reviewer it's `2`. A lone reviewer's note to self still gets 201.
  - chats.test `it("an old client in several families gets family #1, or 400 without it")` (Review Focus 2).
  - chats.test `it("every group member must be a live member of the group's family")`: `familyId: 3` with a member who is only in 1 → 400. A pending family → 400. Being a non-member of the family → 400.
  - chats.test `it("a direct chat needs a shared family")`: no shared family → 403 `{error:"no_shared_family"}`. A deleted or unknown user → 400 as today. An existing pair is returned 200 even after they stop sharing (history stays reachable).
  - members.test `it("group adds are limited to the group's family")`: adding someone outside `chat.familyId` → 400.
  - members.test `it("leaving a group records a leaver")`: a `chat_leavers` row exists after `DELETE /chats/:id/members/:id`.
  - hub.test `it("a send to a direct chat with no shared family is refused")`: `{type:"error", id, error:"no_shared_family"}` and no message row.
  - hub.test `it("a direct chat whose peer deleted their account still takes sends")` (Review Focus 4): ack as today.
  - reviewer.test: change the two "can't start chats with ..." tests to expect 403 `no_shared_family`. The group-add test stays 400.
- [ ] **Step 2: Run them and check they fail.** Run `cd server && npx vitest run --maxWorkers=2 test/chats.test.ts test/members.test.ts test/hub.test.ts test/reviewer.test.ts`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.**
  - Delete `sameSide` from chats.ts.
  - Group create: `const familyId = await groupFamilyFor(db, me, body.familyId)`. Then count the live `family_members` of `familyId` among `others`. If the count isn't `others.length`, answer 400. Insert `family_id`.
  - Direct create: after the dedupe, a live other user is required (else 400). Then `if (!(await shares(db, me, other))) throw new ApiError("no_shared_family")`.
  - Member add: the same family count against `chat.familyId`.
  - Leave/remove: add `INSERT OR REPLACE INTO chat_leavers (chat_id, user_id, left_at) VALUES (?, ?, ?)` to the batch.
  - In `handleSend`, extend the membership query with `c.kind` and a `may_send` flag. `may_send` is true for groups, for a direct with no other member left, or when the other member is live and shares a family with the sender (EXISTS over `family_members` joined to itself). If it's false, send `no_shared_family`.
- [ ] **Step 4: Run the suite.** Run `cd server && npx vitest run --maxWorkers=2 && npm run typecheck`. Expected: PASS.
- [ ] **Step 5: Update docs/protocol.md.** In "Chats": `familyId` in, `familyId` out, the default family rule and the direct-chat rule. In "`send` rules": `no_shared_family`.
- [ ] **Step 6: Commit.** Message: `feat(server): group chats belong to a family; direct chats need a shared one`.

### Task 7: Account-wide powers

**Files:**
- Modify: `server/src/routes/admin.ts` (route guards, reset target check), `server/src/lib/delete-account.ts` (per-family `last_admin`, membership on deletion, operator flag)
- Test: `server/test/account-deletion.test.ts`, `server/test/reviewer.test.ts`, `server/test/recovery.test.ts`, `server/test/reset.test.ts`

**Interfaces:**
- Consumes: `requireOperator`, `requireAnyAdmin`, `FAMILY_ONE` and `ApiError` `extra` from Task 2.
- Produces: `deleteAccount(env, userId, actorId, now?)` keeps its signature. It throws `new ApiError("last_admin", {familyId, familyName})`.

- [ ] **Step 1: Write failing tests.**
  - account-deletion `it("only the operator deletes someone else's account")`: a family #1 admin who isn't operator → 403. The operator → 204.
  - account-deletion `it("last_admin is per family and names the family")`: A is the only admin of family 3 ("Cousins"), which has a live member B. `DELETE /me` → 409 `{error:"last_admin", familyId: 3, familyName: "Cousins"}`. Once B is deleted (or a second admin is added), A can go. Deleted members don't count (Review Focus 5).
  - account-deletion `it("a deleted account stays in its families as a member and is no longer operator")`: `family_members` rows remain with `role='member'` and NULL proof columns, and `operator = 0`.
  - reviewer.test: the setup's Alice becomes `operator: true`. Add `it("reviewer endpoints are operator-only")`: a family #1 admin who isn't operator gets 403 on all three. Keep "admins remove reviewers with DELETE /admin/users/:id" with Alice as operator.
  - recovery.test `it("an admin of any family can register a recovery key")`: an admin of family 3 only → 204. A plain member → 403.
  - reset.test `it("an admin reset needs the target in family #1")`: a target only in family 3 → 404.
- [ ] **Step 2: Run them and check they fail.** Run `cd server && npx vitest run --maxWorkers=2 test/account-deletion.test.ts test/reviewer.test.ts test/recovery.test.ts test/reset.test.ts`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement.**
  - Swap the guards per decision 10.
  - In `deleteAccount`, replace the users-only last-admin condition in the first statement with: `NOT EXISTS (family f where the user is admin AND no other live admin of f AND some other live member of f)`.
  - Add the guarded statements `UPDATE family_members SET role = 'member', admin_by = NULL, admin_signer_pub = NULL, admin_sig = NULL WHERE user_id = ?` and `operator = 0` in the users update.
  - On guard failure (the user is live), look up the first offending family and throw with `extra`.
  - The reset route's target query requires a live `family_members` row in `FAMILY_ONE` instead of `reviewer = 0`.
- [ ] **Step 4: Run the suite.** Run `cd server && npx vitest run --maxWorkers=2`. Expected: PASS. Fix existing tests that used a non-operator admin to delete accounts by giving that admin `operator: true`.
- [ ] **Step 5: Update docs/protocol.md.** In "Deleting an account", cover operator-only removal and the `last_admin` body. In "Reviewer accounts", say the endpoints are operator-only. Add an "Operator" paragraph under Auth (decision 11). Cover the recovery key rule.
- [ ] **Step 6: Commit.** Message: `feat(server): operator-only account removal and reviewer admin; last_admin per family`.

### Task 8: Retire the reviewer special case

**Files:**
- Modify: `server/src/routes/media.ts` (reviewer cap query), `server/src/routes/admin.ts` (`GET /admin/reviewers` list), `server/src/routes/auth.ts` (`redeemReviewer` retry lookup), any remaining reads
- Test: `server/test/reviewer.test.ts`

**Interfaces:**
- Consumes: `REVIEWER_FAMILY`.
- Produces: no reads of `users.reviewer` remain in `server/src`. Writes of the mirror stay (`redeemReviewer`, the test fixture).

- [ ] **Step 1: Write a failing test.** In reviewer.test, add `it("the reviewer family, not the users.reviewer flag, decides")`. Insert a user with `reviewer: false` but `families: [{id: 2}]`. They're listed in `GET /admin/reviewers`, they count toward `REVIEWER_MEDIA_CAP` when uploading, and they see only reviewers. A row with `reviewer = 1` but `families: [{id: 1}]` is treated as family.
- [ ] **Step 2: Run it and check it fails.** Run `cd server && npx vitest run --maxWorkers=2 test/reviewer.test.ts`. Expected: FAIL on the reviewers list and the media cap.
- [ ] **Step 3: Replace the remaining reads.**
  - The media cap: `uploader_id IN (SELECT user_id FROM family_members WHERE family_id = 2)`.
  - The reviewers list: join `family_members` on family 2.
  - The `redeemReviewer` retry: the same join.

  Then run `grep -rn "reviewer = \|\.reviewer\b\|u.reviewer\|is_admin = 1" server/src`. The only hits left should be mirror writes, `invites.reviewer` and token-claim reads.
- [ ] **Step 4: Run the full suite and the typecheck.** Run `cd server && npx vitest run --maxWorkers=2 && npm run typecheck`. Expected: PASS. The only reviewer.test changes overall are Task 6's status codes and Task 7's operator setup.
- [ ] **Step 5: Update docs/protocol.md "Reviewer accounts".** Reviewers are the hidden family #2; the isolation rules are the family rule; the media cap is unchanged.
- [ ] **Step 6: Commit.** Message: `refactor(server): reviewers are the hidden family; drop the side special case`.

### Task 9: App learns `former` users

**Files:**
- Modify: `app/lib/chat/wire.dart` (`UserDto.former`), `app/lib/chat/db/chat_db.dart` (`LocalUsers.former`, schemaVersion 7) and regenerate `chat_db.g.dart`, `app/lib/chat/directory.dart`, `app/test/support/fake_chat_backend.dart`
- Test: `app/test/chat/wire_test.dart`, `app/test/chat/chat_db_migration_test.dart`, `app/test/chat/directory_test.dart`

**Interfaces:**
- Produces: `UserDto.former` (bool, default false, parsed from `j['former'] == true`); `LocalUsers.former` (`BoolColumn`, nullable, like `deleted`); `UserRow.former` (`bool?`). Also `FakeChatBackend.markFormer(String userId, [bool former = true])`, which makes the fake's `users()` report it. A former entry also gets `isAdmin: false` and no adminProof, as the server does.

- [ ] **Step 1: Write failing tests.**
  - wire_test `former is read and defaults to false`.
  - chat_db_migration_test `schema 6 to 7: users get a former flag`: drop `former`, set `user_version = 6`, reopen, and check that existing rows read `former` null. Also add `ALTER TABLE local_users DROP COLUMN former` to the earlier migration tests' setup lists so they still start from their old schema.
  - directory_test `a former user is stored as former and never pinned as admin`.
- [ ] **Step 2: Run them and check they fail.** Run `export PATH=$HOME/development/flutter/bin:$PATH && cd app && flutter test test/chat/wire_test.dart test/chat/chat_db_migration_test.dart test/chat/directory_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** Add the column and the `if (from < 7) await m.addColumn(localUsers, localUsers.former);` migration step. Regenerate with `dart run build_runner build --delete-conflicting-outputs`. `directory.dart` passes `former: u.former` into `putUser`, and its `TrustInput` uses `isAdmin: u.isAdmin && !u.former`.
- [ ] **Step 4: Run the app tests.** Run `flutter test`. Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat(app): directory keeps former chat partners`.

### Task 10: Read-only direct chats and pickers without former people

**Files:**
- Modify: `app/lib/screens/chats/conversation_view.dart`, `app/lib/screens/chats/new_chat_screen.dart`, `app/lib/screens/family_screen.dart`, `app/lib/chat/chat_sync.dart`
- Test: `app/test/screens/conversation_test.dart`, `app/test/screens/new_chat_test.dart`, `app/test/screens/family_screen_test.dart`, `app/test/chat/chat_sync_test.dart`

**Interfaces:**
- Consumes: `UserRow.former` and `FakeChatBackend.markFormer` from Task 9.
- Produces: a footer widget with `Key('no-shared-family')` and the text "You're no longer in a family together", which replaces the whole composer area (preview, banners, composer, emoji panel).

- [ ] **Step 1: Write failing tests.**
  - conversation_test `a direct chat with a former peer shows the read-only footer instead of the composer`: call `backend.markFormer(bob.userId)` before `open`. Then `find.byKey(Key('no-shared-family'))` finds one widget, `find.byKey(Key('composer'))` finds nothing, and the text matches exactly.
  - conversation_test `a direct chat with a deleted peer keeps the composer` (Review Focus 4): call `backend.markDeleted(bob.userId)`; the composer is shown and there's no footer.
  - conversation_test `a group with a former member keeps the composer`.
  - new_chat_test `former people are not offered`.
  - family_screen_test `former people are not listed as family`.
  - chat_sync_test `no_shared_family fails the send and refreshes the directory`: the message state is `failed` and `GET /users` is called again.
- [ ] **Step 2: Run them and check they fail.** Run `flutter test test/screens/conversation_test.dart test/screens/new_chat_test.dart test/screens/family_screen_test.dart test/chat/chat_sync_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - In the conversation, compute `readOnly` from `otherMember(chat, members, me)` and that user's row having `former == true`. If it's true, render the footer in place of the composer `Column`.
  - Add `&& u.former != true` to the new-chat filter and the family screen filter.
  - In `chat_sync`'s error switch, add `case 'no_shared_family':` to set the state to failed and call the directory refresh used for `profile` events.
- [ ] **Step 4: Run the app tests.** Run `flutter test`. Expected: PASS.
- [ ] **Step 5: Commit.** Message: `feat(app): read-only footer for direct chats with no shared family`.

### Task 11: Operator-only actions in the app

**Files:**
- Modify: `app/lib/api/models.dart` (`Me.operator`), `app/lib/api/api_client.dart` (`me()` parse), `app/lib/screens/family_screen.dart`, `app/test/support/fake_server.dart`, `app/test/support/app_harness.dart`
- Test: `app/test/screens/family_screen_test.dart`, `app/test/api/api_client_test.dart`

**Interfaces:**
- Produces: `Me.operator` (bool, default false, parsed from `j['operator'] == true`); `FakeUser.operator`; `FakeServer.addUser(..., bool? operator)`, which defaults to `admin`; `signInDirectly(tester, server, {String name, bool admin, bool? operator})`, where `operator` defaults to `admin`.

- [ ] **Step 1: Write failing tests.**
  - api_client_test `me() reads operator`.
  - family_screen_test `an admin who is not the operator sees no Remove action and no reviewer section`: sign in with `admin: true, operator: false`. The `family-menu-<id>` menu has "Reset account" and "Make admin" but no "Remove from family", and `create-reviewer-invite` is absent.
  - family_screen_test `the operator sees Remove and the reviewer section` (the existing tests, now with an explicit operator).
- [ ] **Step 2: Run them and check they fail.** Run `flutter test test/screens/family_screen_test.dart test/api/api_client_test.dart`. Expected: FAIL.
- [ ] **Step 3: Implement.** Parse `operator`. In the family screen, show the `'remove'` menu item and `_ReviewerSection` only when `ref.watch(meProvider).value?.operator == true`. The fake server's `/me` returns `operator`, and its `DELETE /admin/users/:id` and reviewer routes give 403 for non-operators, as the server does.
- [ ] **Step 4: Run all app tests and analyze.** Run `flutter test && flutter analyze`. Expected: PASS with no new analyzer issues.
- [ ] **Step 5: Final server check.** Run `cd server && npx vitest run --maxWorkers=2 && npm run typecheck`. Expected: PASS.
- [ ] **Step 6: Commit.** Message: `feat(app): operator-only remove and reviewer controls`.

---

## Follow-ups carried from stage 1 execution

Must be handled before the stage that makes `former` reachable (leaving or removing a family, stage 3):
- Share and forward pickers still offer read-only direct chats; reactions, edits and delete-for-everyone in a read-only chat fail with `no_shared_family`. Hide them.
- Shortcode overlay and the "preparing" bar can show above the read-only footer; in-flight compose state isn't cleared when a peer turns former.
- Later joiners of a group see its past leavers as `former` (name, devices, avatar). Decide whether that's acceptable across families.

Stage 2 (per-family admins and pinning):
- When a user flips to `former`, the app clears their stored `pinnedAdmin`; a first admin without a proof can't be re-pinned on rejoin. Per-family pinning must handle rejoin.

Stage 4 (email):
- `users_verified_email` is case-sensitive; lowercase addresses before storing.

Small hardening, any time:
- `sharesChanged()` failures are logged and swallowed; consider one retry.
- Admin promotion checks liveness before its batch; add a live-user `EXISTS` to both UPDATEs.
- Group POST idempotent retry resolves the family before the existing-id check.
- `GET /users` devices/resets subqueries filter through `users` with an OR; filter `user_id` directly before families grow.
- Test gaps: operator-pick ordering/fallback, `requireAnyAdmin`/`requireOperator` directly, sole admin of two families, pinned→former and former→not-former flips.
- Deploy runs migrations before the Worker; don't redeem invites during a deploy (an old-Worker redeem would create a user with no family).
