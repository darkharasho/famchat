# Multi-family stage 2: per-family admins and reset trust — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Admin authority becomes per family: v2 admin proofs name a family, each device pins admins per family, and a reset is silently accepted only when a trusted admin of a family shared by the viewer and the reset person signed it.

**Architecture:** The server gains a per-family promote endpoint and authorizes resets by any family admin of the target. The app parses the `families` list `/users` already serves (stage 1), stores pins per family in two new drift tables, and `resolveTrust` computes trusted admins per family. Losing trust follows the server's listing; gaining it needs a proof.

**Tech Stack:** Cloudflare Worker (Hono, D1, vitest), Flutter (drift, riverpod, cryptography).

**Spec:** `docs/superpowers/specs/2026-11-17-multi-family-design.md` ("Admin proofs and reset trust", "Removal and leaving" last bullet, "Compatibility", "Staging" item 2). Stage 1 plan's follow-ups: `docs/superpowers/plans/2026-11-17-multi-family-stage1.md`.

## Global Constraints
- Proof v2 bytes: `ByteWriter/Writer("famchat-admin-v2").str(str(familyId)).str(userId).str(byUserId)`, `familyId` as its decimal string. v1 stays `"famchat-admin-v1" ‖ str(userId) ‖ str(byUserId)` and counts **only for family 1**.
- A family's creator has no proof; a device pins admins on first sight of a family (the families listed on its own user's `/users` entry it hasn't pinned before).
- After first sight a device adds an admin of family F only through a proof that verifies (v2 for F, or v1 when F = 1) under the current trusted key of an admin it already trusts in F (or its own user).
- A device drops a pin as soon as the server stops listing that user as an admin of F. A family the device has seen keeps its pins frozen when the server stops listing it (on my own entry, or my entry missing or former); only never-seen families are trusted on first sight.
- Upgrade: an existing device's pinned admins become family 1's pins and family 1 is marked seen (only if `adminsPinned` meta was set). No new warnings for anyone today.
- Old clients keep working: `isAdmin`/`adminProof` at the top level of `/users` still describe family 1; `POST /admin/users/:id/admin` keeps accepting v1 for family 1; old pairing bundles (per-user `admin` bool) pin into family 1.
- Server never sees message bodies; no change to message crypto.
- vitest with `--maxWorkers=2`; `export PATH=$HOME/development/flutter/bin:$PATH` before Flutter; never `dart format` existing files; regenerate drift with `dart run build_runner build --delete-conflicting-outputs`.
- `docs/protocol.md` is updated in the task that changes the behaviour it documents.

## Review Focus
1. A person in families A and B is reset by an admin of B. A viewer in A only must get the manual "security key changed" banner; a viewer in B gets it accepted silently. (Task 4 test.)
2. An upgraded device in family 1 with pins: after the first refresh on the new code its trusted-admin set and witnessed resets are unchanged — no new banner. (Task 5 test.)
3. An admin who is demoted, removed or turned `former` stops counting immediately, and coming back as admin with no proof does not restore trust. (Task 4 and 5 tests.)
4. Pairing between an old and a new app version in either direction keeps family-1 pins. (Task 5 test.)
5. A hostile server listing a user as admin of a family the device has already seen, with no proof or a proof for another family (v2 for family 2 replayed into family 3, or v1 outside family 1), gains nothing. (Task 4 test.)

---

### Task 1: Server — v2 proofs and per-family promotion

**Files:**
- Modify: `server/src/lib/reset.ts` (add `promotionMessageV2`)
- Create: `server/src/routes/families.ts`; Modify: `server/src/index.ts` (mount at `/families`)
- Modify: `server/src/routes/admin.ts` (compat promote: live-user `EXISTS` in both UPDATEs — stage 1 follow-up)
- Test: `server/test/families.test.ts`, `server/test/reset-vector.test.ts`, `server/test/admin.test.ts`
- Docs: `docs/protocol.md` (admin proofs section and the new endpoint)

**Interfaces:**
- Produces: `promotionMessageV2(familyId: number, userId: string, byUserId: string): Uint8Array`.
- Produces: `POST /families/:id/admins/:userId {sig}` → 204. Caller must be an admin of `:id` and `:id` approved; `sig` must verify as v2 under the caller's identity key, else 400 `invalid_request`; target must be a live member of `:id`, else 404 `not_found`; caller not admin → 403 `forbidden` (use the existing error code the middleware uses for non-admins). Writes `role='admin', admin_by, admin_signer_pub, admin_sig` on the `family_members` row; mirrors to `users.is_admin`/`admin_*` only when `:id` = 1. Calls `sharesChanged(env)` is NOT needed (roles don't change visibility); logs event `admin_promoted` with `payload: {familyId}`.
- Hub: emit nothing new in this stage.

- [ ] **Step 1: Failing tests.** In `reset-vector.test.ts` add a fixed v2 vector (generate the signature once with the Dart test key from Task 3's vector, or generate here and copy into Task 3 — the same `{familyId: 1, userId, byUserId, signerPub, sig}` constant must appear in both test files). In `families.test.ts`: `promotes a member of the caller's family with a v2 proof`; `rejects a v1 proof on the per-family endpoint`; `rejects a v2 proof signed for another family`; `non-admin of the family gets 403`; `admin of another family gets 403`; `target outside the family gets 404`; `deleted target gets 404`; `promotion in family 1 mirrors users.is_admin`. In `admin.test.ts`: `compat promote doesn't touch a user deleted between check and write` (simulate by deleting first and asserting 404 or zero rows changed).
- [ ] **Step 2:** `cd server && npx vitest run --maxWorkers=2 test/families.test.ts test/reset-vector.test.ts test/admin.test.ts` — Expected: the new tests FAIL (404 route / missing export).
- [ ] **Step 3:** Implement. Reuse `familyRole` from `lib/family.ts` for the caller check.
- [ ] **Step 4:** Same command — Expected: PASS. Then full suite `npx vitest run --maxWorkers=2` — PASS.
- [ ] **Step 5:** Update `docs/protocol.md`; commit `feat(server): v2 admin proofs and per-family promotion`.

### Task 2: Server — reset authorized by any family admin

**Files:**
- Modify: `server/src/routes/admin.ts` (`POST /admin/users/:id/reset`), `server/src/lib/reset-account.ts` (event payload)
- Test: `server/test/reset.test.ts`
- Docs: `docs/protocol.md` ("Account resets")

**Interfaces:**
- Middleware changes from `requireAdmin` to `requireAnyAdmin`.
- The authorizing family: the lowest `family_id` where the caller has `role='admin'`, the target is a member, and the family is `approved`. None → 404 `not_found` (as today for a target outside family 1).
- Response adds `familyId: number`. The `reset` event row's payload gains `familyId`. `resetAccount` gets an optional `familyId?: number` param it puts in that payload (recovery resets pass nothing).

- [ ] **Step 1: Failing tests:** `an admin of the target's second family can reset them (familyId in response and event)`; `an admin of a family the target isn't in gets 404`; `a member (non-admin) of the target's family gets 403`; `a pending family's admin can't reset its members` (insert family with `status='pending'`); `family-1 admin still resets family-1 members (familyId 1)`.
- [ ] **Step 2:** `npx vitest run --maxWorkers=2 test/reset.test.ts` — Expected: new tests FAIL.
- [ ] **Step 3:** Implement with one query joining `family_members` twice and `families`.
- [ ] **Step 4:** Same command PASS; full suite PASS.
- [ ] **Step 5:** Docs; commit `feat(server): any family admin of the target may reset them`.

### Task 3: App — v2 proof crypto and `families` on the wire

**Files:**
- Modify: `app/lib/crypto/encoding.dart` (`domainAdminV2 = 'famchat-admin-v2'`), `app/lib/crypto/reset.dart`, `app/lib/chat/wire.dart`
- Test: `app/test/crypto/reset_test.dart`, `app/test/chat/wire_test.dart`

**Interfaces:**
- Produces: `Future<Uint8List> signPromotionV2(SimpleKeyPair identity, {required int familyId, required String userId, required String byUserId})` and `Future<bool> verifyPromotionV2({required List<int> signerPub, required int familyId, required String userId, required String byUserId, required List<int> sig})`. v1 functions stay.
- Produces: `class FamilyRoleDto { final int id; final bool admin; final AdminProofDto? adminProof; }` parsed from `{id, role, adminProof}` (`admin` = `role == 'admin'`); `UserDto.families: List<FamilyRoleDto>` (missing → `const []`; bad shape → `FormatException`).

- [ ] **Step 1: Failing tests:** the shared v2 vector from Task 1 verifies with `verifyPromotionV2`, fails with familyId+1 and with v1 verify; sign→verify roundtrip; `UserDto.fromJson` parses `families` with and without a proof, defaults to empty, throws on a non-list.
- [ ] **Step 2:** `cd app && flutter test test/crypto/reset_test.dart test/chat/wire_test.dart` — Expected: FAIL (undefined names).
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Same command PASS.
- [ ] **Step 5:** Commit `feat(app): v2 admin proofs and per-family roles on the wire`.

### Task 4: App — per-family trust resolution

**Files:**
- Modify: `app/lib/chat/resets.dart`
- Test: `app/test/chat/resets_test.dart` (migrate existing tests to the new inputs; keep every existing case)

**Interfaces:**
- Consumes: `FamilyRoleDto`, `verifyPromotionV2` (Task 3).
- `TrustInput` loses `isAdmin`, `pinnedAdmin`, `adminProof`; gains `families: List<FamilyRoleDto>` (what the server lists; for `former` users the directory passes `const []`).
- `resolveTrust(List<TrustInput> users, {required String myUserId, required Map<int, Set<String>> pinned})`. A key present in `pinned` = a family this device has seen; absent = first sight.
- `TrustOutcome.admins: Map<int, Set<String>>` — one entry per family on my own input's `families`.
- Rules:
  - Start: for each family F on my entry: seen → `pinned[F]` ∩ users the server lists as admin of F; first sight → every user the server lists as admin of F.
  - Promotion of `u` in F: `u` listed as admin of F with a proof, `byUserId != u`, proof verifies as v2 for F (or v1 when F == 1), by is me or in `admins[F]`, and `current(by, signerPub)`. Iterated to a fixpoint as today.
  - A reset's admin signer counts when `signer == myUserId`, or some F on the target's `families` has `signer ∈ admins[F]`. Same rule for forward and history counting. Recovery resets unchanged.

- [ ] **Step 1: Failing tests** (new `group('per family')`): `a reset by an admin of a family the viewer and target share is acknowledged`; `a reset by an admin of the target's other family (not shared with the viewer) doesn't count` (not in `acknowledged`, not in `witnessed`, old key not retired — the existing manual banner then comes from the key mismatch); `first sight pins every listed admin of that family only`; `a seen family's unlisted pin is dropped (demoted)`; `a re-listed admin without a proof is not trusted again`; `a v1 proof counts in family 1 only`; `a v2 proof for family 2 doesn't promote in family 3`; `a promotion signed by an admin of another family doesn't count`; `a former target (no families) gets no admin-signed reset counted, recovery still counts`.
- [ ] **Step 2:** `flutter test test/chat/resets_test.dart` — Expected: compile failure / FAIL.
- [ ] **Step 3:** Implement; update the header comment of `resets.dart`.
- [ ] **Step 4:** Same command PASS (old and new cases).
- [ ] **Step 5:** Commit `feat(app): trust admins and resets per family`.

### Task 5: App — per-family pins: storage, upgrade, directory, pairing, promote

**Files:**
- Modify: `app/lib/chat/db/chat_db.dart` (+ regenerate `chat_db.g.dart`), `app/lib/chat/directory.dart`, `app/lib/pairing/bundle.dart`, `app/lib/admin/admin_service.dart`, `app/lib/api/api_client.dart`
- Test: `app/test/chat/chat_db_migration_test.dart`, `app/test/chat/directory_test.dart`, `app/test/pairing/bundle_test.dart`, `app/test/admin/admin_flow_test.dart`; update fakes (`fake_server.dart` etc.) for the new endpoint

**Interfaces:**
- Schema 8: tables `LocalFamilies(id int PK)` (families this device has pinned) and `LocalFamilyAdmins(familyId int, userId text, PK both)`. `ChatDb`: `Future<Map<int, Set<String>>> familyPins()` and `Future<void> replaceFamilyPins(Map<int, Set<String>> pins)` (one transaction; families absent from the map are deleted from both tables).
- Upgrade `from < 8`: create both tables; if meta `adminsPinned` exists, insert family 1 and `(1, id)` for every `local_users.pinned_admin = 1`.
- Directory: pass `families: u.former ? const [] : u.families` and `pinned: await _db.familyPins()`; after resolving, `replaceFamilyPins(t.admins)`; `UserRow.pinnedAdmin` = trusted admin in any family. `adminsPinnedKey` is no longer read by the directory.
- Bundle: `PairBundle` gains `familyAdmins: Map<int, List<String>>?` encoded as `'familyAdmins': {"<id>": [userIds]}`; `TrustedIdentity.admin` keeps being set to "pinned in family 1" for old receivers. `installHandover`: bundle with `familyAdmins` → `replaceFamilyPins` from it; without it but with any `admin != null` → family 1 = users with `admin == true`; neither → leave pins (first sight later).
- Promote: `AdminService.makeAdmin(userId, {int familyId = 1})` signs v2 and calls `ApiClient.promoteInFamily(familyId, userId, sig:)` → `POST /families/:familyId/admins/:userId`.

- [ ] **Step 1: Failing tests:** migration from 7 with pins → family 1 seen with the same users, and without `adminsPinned` → nothing seen; directory: `upgraded device keeps its admins and shows no new banner` (seed schema-7-equivalent pins, a pending reset by a pinned admin already witnessed → no new witnessed row); `leaving a family drops its pins`; `a demoted admin is unpinned`; bundle: roundtrip with `familyAdmins`; `an old bundle's admin flags pin family 1`; `a new bundle still sets admin for family-1 admins`; admin flow: `make admin signs v2 and posts to /families/1/admins/:id`.
- [ ] **Step 2:** `flutter test test/chat test/pairing test/admin` — Expected: FAIL.
- [ ] **Step 3:** Implement; regenerate drift.
- [ ] **Step 4:** `flutter analyze` clean and `flutter test` (whole app suite) PASS.
- [ ] **Step 5:** Commit `feat(app): pin admins per family`.
