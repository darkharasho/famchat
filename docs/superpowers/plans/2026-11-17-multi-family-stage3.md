# Multi-family stage 3: creating and joining families — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** People can start families (approved by the operator), invite to a specific family, join one with their existing account, leave or be removed, and manage roles per family; the app gets Settings → Families, the operator's requests screen, a family picker for new groups, and a "Join <family>?" sheet.

**Architecture:** The server grows `routes/families.ts` (list, create, rename, invites, invite lookup, join, leave/remove, demote) and a new `routes/operator.ts` (requests, approve, decline). Every membership, role or name change sends `{type:"family", familyId}` to the family's members (and to a removed person) and calls `sharesChanged`. The app stores `familyId` on chats and the family ids each user shares with me, keeps a `familiesProvider` refreshed on the `family` event, and replaces the single Family screen with a families list and a per-family screen.

**Tech Stack:** Cloudflare Worker (Hono, D1, vitest), Flutter (riverpod, drift, go_router).

**Spec:** `docs/superpowers/specs/2026-11-17-multi-family-design.md` ("Goals", "Families API", "Removal and leaving", "Account-wide powers", "The app", "Staging" item 3). Stage 2 deferrals carried here: demotion re-trust, the reset query's `hidden` filter, the `replaceFamilyPins` comment.

## Global Constraints
- Family names: trimmed, 1–40 characters (the `name(x, 40)` validator).
- A pending or declined family can't invite, can't be joined, and its admin has no admin power (promote, reset, remove). Only `approved` families count anywhere admin power is checked.
- The hidden reviewer family (`REVIEWER_FAMILY` = 2, `hidden = 1`) never appears in `GET /families`, operator lists, or any family endpoint (treat as `404 not_found`). Reviewers (`c.get("reviewer")`) get `403 forbidden` from every `/families` and `/operator` route.
- Owner = `families.created_by`. Only the owner demotes. The owner can't be demoted or removed, only leave. When the owner leaves or deletes their account, ownership passes to the longest-serving remaining admin (`MIN(joined_at)`, then `user_id`); if none, `created_by` becomes NULL.
- Admins can remove members, not admins. A family's last admin can't leave while other members remain: `409 last_admin` with `familyId` and `familyName` in the body (same shape `DELETE /me` uses).
- Removal/leaving, in one `db.batch`: delete the `family_members` row; for each group chat of that family the person is in, delete their `chat_members` row, bump `current_epoch`, upsert `chat_leavers` — exactly what `DELETE /chats/:id/members/:userId` does. Then `notify(removed person, {type:"removed", chatId})` per chat, `notify(remaining chat members, {type:"chat", chatId})`, the `family` event, `sharesChanged`.
- Family #1 mirrors: a role change in family 1 also updates `users.is_admin` / `admin_by` / `admin_signer_pub` / `admin_sig` (cleared on demote or removal).
- Invites created by `POST /families/:id/invites` have `make_admin = 0`, `family_id = :id`, 7-day TTL (`INVITE_TTL_MS`), and the same `/join#<token>` link. `email` in the body is rejected (`400`) until stage 4.
- Events go through `notify(env, userIds, {type:"family", familyId})`; the app reacts by refetching `GET /families` and `GET /users`. Old clients ignore it.
- Every new route is documented in `docs/protocol.md` in the task that adds it.
- Single-family users never see families outside Settings: no picker, no labels.
- vitest with `--maxWorkers=2`; `export PATH=$HOME/development/flutter/bin:$PATH` before Flutter; never `dart format` existing files; drift: `dart run build_runner build --delete-conflicting-outputs`; one heavy build at a time.

## Review Focus
1. A person removed from family B who is also in family A: they keep every family-A chat and direct chats with A people, lose B's groups (epoch bumped), and B-only people's directs become read-only for both. (Task 4 test.)
2. Joining with an existing account via an invite to a family I'm already in: `409 conflict`, and the invite stays unused for someone else. (Task 3 test.)
3. The owner leaves a family with another admin and members: ownership moves to the longest-serving admin, who can now demote; with no other admin and members left → `409 last_admin`. (Task 4 test.)
4. A demoted admin re-listed by the server as admin with their old (still valid) proof is not trusted again on a device that saw the demotion. (Task 11 test.)
5. A signed-in person opening an invite link for a family they're already in, or an expired/used link, sees a clear message, not a crash or a silent no-op. (Task 9 test.)

---

### Task 1: Server — list, create and rename families; the `family` event

**Files:**
- Modify: `server/src/routes/families.ts`, `server/src/lib/family.ts`
- Test: `server/test/families.test.ts`
- Docs: `docs/protocol.md` (new "Families" section)

**Interfaces:**
- Produces in `lib/family.ts`: `familyMemberIds(db, familyId): Promise<string[]>` (live members); `notifyFamily(env, familyId, extra: string[] = []): Promise<void>` (notifies members ∪ extra with `{type:"family", familyId}`); `requireFamilyAdmin(db, userId, familyId): Promise<FamilyInfo>` where `FamilyInfo = {id, name, status, createdBy: string | null}` — throws `not_found` for unknown/hidden, `forbidden` if not admin or not approved.
- `GET /families` → `{families: [{id, name, status, role, memberCount, owner: boolean, createdAt}]}` for the caller's non-hidden families, ordered by id. `memberCount` counts live members.
- `POST /families {name}` → `201 {family: <same shape>}`; inserts `status='pending'`, the caller as `role='admin'` with no proof. At most 3 pending families per creator, else `429 rate_limited`. Logs event `family_requested`.
- `PUT /families/:id {name}` → 204; admin of an approved family or of their own pending one. Calls `notifyFamily`.

- [ ] **Step 1: Failing tests:** `lists only my non-hidden families with role, owner and memberCount`; `creates a pending family with me as its admin`; `a fourth pending request is rate limited`; `reviewers get 403 on /families`; `admin renames an approved family and members get a family event` (use the existing hub/notify spy pattern in the test helpers); `a member can't rename (403)`; `the creator can rename their pending family`; `rename validates 1–40 characters`.
- [ ] **Step 2:** `cd server && npx vitest run --maxWorkers=2 test/families.test.ts` — Expected: new tests FAIL.
- [ ] **Step 3:** Implement. Add a `reviewer` check helper at the top of the router (`families.use(requireAuth, rejectReviewers)`), keeping the existing promote route behind it.
- [ ] **Step 4:** Same command PASS; full suite `npx vitest run --maxWorkers=2` PASS.
- [ ] **Step 5:** Docs; commit `feat(server): list, request and rename families`.

### Task 2: Server — operator approval

**Files:**
- Create: `server/src/routes/operator.ts`; Modify: `server/src/index.ts` (mount `/operator`)
- Test: `server/test/operator.test.ts`
- Docs: `docs/protocol.md`

**Interfaces:**
- `GET /operator/families?status=pending|approved|declined` (default `pending`) → `{families: [{id, name, status, createdAt, decidedAt, creator: {id, name} | null, memberCount}]}`, never hidden ones, newest first.
- `POST /operator/families/:id/approve` and `/decline` → 204; only from `pending` (else `409 conflict`); set `status`, `decided_at`, `decided_by`; log `family_approved` / `family_declined`; `notifyFamily`.
- All behind `requireAuth, requireOperator`.

- [ ] **Step 1: Failing tests:** `operator lists pending requests with creator name`; `non-operator gets 403`; `approve makes the family approved (creator's GET /families shows status approved) and the creator gets a family event`; `decline sets declined and the creator gets a family event`; `approving twice is 409`; `the reviewer family never appears`.
- [ ] **Step 2:** `npx vitest run --maxWorkers=2 test/operator.test.ts` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS; full suite PASS.
- [ ] **Step 5:** Docs; commit `feat(server): operator approves or declines family requests`.

### Task 3: Server — per-family invites, invite lookup, joining with an existing account

**Files:**
- Modify: `server/src/routes/families.ts`, `server/src/routes/admin.ts` (`createInvite` takes a `familyId`)
- Test: `server/test/families.test.ts`, `server/test/auth.test.ts`
- Docs: `docs/protocol.md`

**Interfaces:**
- `createInvite(env, name, makeAdmin, createdBy, familyId = FAMILY_ONE)`; `POST /admin/invites` unchanged (family 1).
- `POST /families/:id/invites {name}` → `201 {inviteToken, inviteUrl, expiresAt}` via `requireFamilyAdmin`.
- `POST /families/invite-lookup {inviteToken}` → `{familyId, familyName, invitedName, alreadyMember: boolean}` for a usable family invite (unused, unexpired, not revoked, `user_id IS NULL`, `reviewer = 0`, approved non-hidden family); otherwise `410 invite_invalid`.
- `POST /families/:id/join {inviteToken}` → `200 {family: <GET /families shape>}`. Claims the invite (`used_by = me`) and inserts `family_members (role 'member')` in one batch, conditional on the invite matching `:id` and being usable and me not already a member. Already a member → `409 conflict` with the invite untouched. Unusable → `410 invite_invalid`. Logs `family_joined`; `notifyFamily`; `sharesChanged`.
- Signed-out redeem (`POST /auth/invite/redeem`) of a family-N invite must reject a non-approved family (`410`).

- [ ] **Step 1: Failing tests:** `family admin creates an invite for their family`; `member gets 403`; `pending family's admin gets 403`; `email in the invite body is 400`; `lookup returns family name and alreadyMember`; `lookup of a used, expired, reset or reviewer invite is 410`; `join adds me as member, uses the invite, and both sides now see each other in /users`; `joining a family I'm in is 409 and the invite stays usable`; `join with a token for another family is 410`; `signed-out redeem of a family-3 invite joins family 3 only`.
- [ ] **Step 2:** `npx vitest run --maxWorkers=2 test/families.test.ts test/auth.test.ts` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS; full suite PASS.
- [ ] **Step 5:** Docs; commit `feat(server): invites per family, and joining with an existing account`.

### Task 4: Server — leaving, removing, demoting and ownership

**Files:**
- Modify: `server/src/routes/families.ts`, `server/src/lib/family.ts`, `server/src/lib/delete-account.ts`, `server/src/routes/admin.ts` (reset query: add `AND f.hidden = 0`)
- Test: `server/test/families.test.ts`, `server/test/account-deletion.test.ts`, `server/test/reset.test.ts`
- Docs: `docs/protocol.md` ("Families", "Deleting an account")

**Interfaces:**
- Produces `removeFromFamily(env, familyId, userId): Promise<void>` in `lib/family.ts` implementing the Global Constraints removal batch plus ownership transfer and family-1 mirror.
- `DELETE /families/:id/members/:userId` → 204. Self: allowed for any member of a non-hidden family (pending/declined included — that's how a creator dismisses a declined request); last admin with others left → `409 last_admin`. Others: caller must be an admin of the approved family; target admin or owner → `403`; target not a member → `404`.
- `DELETE /families/:id/admins/:userId` → 204; caller must be the owner; target must be an admin and not the owner. Sets `role='member'`, clears proof columns (family-1 mirror). `notifyFamily`.
- `deleteAccount` transfers ownership of every family the user owns before removing them.

- [ ] **Step 1: Failing tests:** `member leaves: out of the family's groups (epoch bumped, chat_leavers row), family event to the rest`; `admin removes a member who is also in another family: other family's chats untouched, direct with a B-only person becomes no_shared_family on send`; `admin can't remove another admin (403)`; `member can't remove anyone (403)`; `last admin can't leave while others remain (409 last_admin with familyName)`; `sole member leaves a declined family`; `owner leaves: ownership passes to the longest-serving admin`; `owner demotes an admin; family-1 demotion clears users.is_admin`; `non-owner admin can't demote (403)`; `owner can't be demoted (403)`; `deleting the owner's account transfers ownership`; in `reset.test.ts`: `an admin of the hidden family can't reset` (set `role='admin'` on a reviewer row directly).
- [ ] **Step 2:** `npx vitest run --maxWorkers=2 test/families.test.ts test/account-deletion.test.ts test/reset.test.ts` — FAIL.
- [ ] **Step 3:** Implement; reuse the chat removal SQL from `routes/chats.ts` (extract a helper there if it keeps both callers identical).
- [ ] **Step 4:** PASS; full suite PASS.
- [ ] **Step 5:** Docs; commit `feat(server): leave, remove and demote within a family`.

### Task 5: App — families on the client: API, storage, provider, events

**Files:**
- Modify: `app/lib/api/api_client.dart`, `app/lib/api/models.dart`, `app/lib/chat/wire.dart`, `app/lib/chat/db/chat_db.dart` (schema 9), `app/lib/chat/directory.dart`, `app/lib/chat/chat_sync.dart`, `app/lib/chat/providers.dart`
- Test: `app/test/api/api_client_test.dart` (or the existing API test file), `app/test/chat/chat_db_migration_test.dart`, `app/test/chat/directory_test.dart`, `app/test/chat/chat_sync_test.dart`

**Interfaces:**
- Models: `Family {int id; String name; String status; bool admin; bool owner; int memberCount}`; `FamilyRequest {int id; String name; String status; DateTime createdAt; String? creatorName; int memberCount}`; `InviteLookup {int familyId; String familyName; String invitedName; bool alreadyMember}`.
- `ApiClient`: `families()`, `createFamily(name)`, `renameFamily(id, name)`, `createFamilyInvite(id, name) → Invite`, `lookupInvite(token) → InviteLookup`, `joinFamily(id, token) → Family`, `leaveOrRemove(id, userId)`, `demote(id, userId)`, `operatorFamilies({status = 'pending'})`, `approveFamily(id)`, `declineFamily(id)`. `ApiException.code` carries `last_admin`, `conflict`, `invite_invalid`.
- Drift schema 9: `LocalChats.familyId` (nullable int, from `ChatDto.familyId`); `LocalUsers.familyIds` (text JSON list, default `'[]'`, from the user's `families` ids — empty for former users). Migration adds both columns.
- `familiesProvider`: `AsyncNotifier<List<Family>>`; `refresh()` refetches. `chat_sync` handles `{type:"family"}` by refreshing the directory (`/users`) and `ref.invalidate(familiesProvider)` via a callback it is given (follow how `profile` events reach providers today).
- `myFamiliesProvider`: approved families only (for pickers).

- [ ] **Step 1: Failing tests:** API client parses each endpoint's JSON (one test per method family: list/create, lookup/join, operator) and maps `409 last_admin`; migration 8→9 keeps rows and adds defaults; directory stores `familyIds` per user and clears them for former users; chat sync stores `familyId` for groups; a `family` event triggers a directory refresh and the families callback.
- [ ] **Step 2:** `cd app && flutter test <the files above>` — FAIL.
- [ ] **Step 3:** Implement; regenerate drift.
- [ ] **Step 4:** PASS; `flutter analyze` clean.
- [ ] **Step 5:** Commit `feat(app): families API, storage and the family event`.

### Task 6: App — Settings → Families and starting a family

**Files:**
- Create: `app/lib/screens/families_screen.dart`
- Modify: `app/lib/screens/settings_screen.dart`, `app/lib/router.dart`
- Test: `app/test/screens/families_screen_test.dart`, `app/test/screens/settings_screen_test.dart`

**Interfaces:**
- Route `/settings/families` → `FamiliesScreen`; `/settings/families/:id` → `FamilyScreen(familyId)` (Task 7).
- Settings: a "Families" group shown to every non-reviewer: tile `Key('settings-families')` "Families" with subtitle = the family names joined by ", " (or "Start or join a family" when none). The old admin-only "Family" group goes; "Media storage" moves into family 1's screen (Task 7).
- `FamiliesScreen`: one tile per family (name; subtitle "Owner"/"Admin"/"Member" · "N people", or "Waiting for approval" / "Declined"); "Start a family" button opens a dialog (name, 1–40) → `createFamily` → snackbar "Request sent. You'll be told when it's approved." A declined family's tile offers "Dismiss" (`leaveOrRemove(id, me)`).
- When a family I created moves from pending to approved (seen on a provider refresh), show a snackbar "<name> was approved" (the in-app note). Implement in `familiesProvider` by diffing the previous value and exposing a stream/listener the shell listens to.

- [ ] **Step 1: Failing tests:** families list renders the three statuses; start-a-family dialog validates and calls the API; declined family can be dismissed; Settings shows the Families tile with names; a pending→approved refresh shows the approval snackbar.
- [ ] **Step 2:** `flutter test test/screens/families_screen_test.dart test/screens/settings_screen_test.dart` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS; analyze clean.
- [ ] **Step 5:** Commit `feat(app): Settings → Families and family requests`.

### Task 7: App — one family's screen

**Files:**
- Modify: `app/lib/screens/family_screen.dart` (becomes per-family: `FamilyScreen({required int familyId})`), `app/lib/screens/invite_screen.dart` (takes `familyId`), `app/lib/chat/...admin service` (`makeAdmin(userId, familyId)` signs v2 via `promoteInFamily`), `app/lib/router.dart`
- Test: `app/test/screens/family_screen_test.dart`, `app/test/screens/invite_screen_test.dart`

**Interfaces:**
- Members = users whose `familyIds` contain the id (not deleted, not former), plus me. Each tile: role ("Owner", "Admin", or nothing). Menu, by my role: admin → "Reset account", "Remove from <family>" (members only), "Make admin" (members); owner → also "Remove admin" on admins. Operator keeps "Delete account" (existing `removeUser`).
- App bar: rename (admins; dialog) and a "Leave <family>" overflow item for everyone; `last_admin` shows "You're the last admin. Make someone else an admin first."
- Admin-only sections stay: invite (`/settings/families/:id/invite`), recovery-code card and "second admin" card (any admin), "Media storage" (family 1 admins only).
- The reviewer section moves to Task 8's operator screen.
- Pending family: only the name, "Waiting for approval", rename and leave.

- [ ] **Step 1: Failing tests:** members of family 2 only are listed on family 2's screen; member sees no admin actions; admin removes a member (calls `leaveOrRemove(2, id)`); owner demotes an admin; make admin calls `promoteInFamily(2, …)` with a v2 signature; leaving as last admin shows the message; invite screen posts to `/families/2/invites`; storage only on family 1.
- [ ] **Step 2:** `flutter test test/screens/family_screen_test.dart test/screens/invite_screen_test.dart` — FAIL.
- [ ] **Step 3:** Implement; update existing tests that opened `/settings/family`.
- [ ] **Step 4:** PASS; analyze clean.
- [ ] **Step 5:** Commit `feat(app): manage one family: members, roles, invites, leaving`.

### Task 8: App — the operator's screen

**Files:**
- Create: `app/lib/screens/operator_screen.dart`; Modify: `settings_screen.dart`, `router.dart`, `family_screen.dart` (move `_ReviewerSection` out)
- Test: `app/test/screens/operator_screen_test.dart`

**Interfaces:**
- Route `/settings/operator`; Settings tile `Key('settings-operator')` "Family requests" (subtitle "N waiting" or "None waiting"), operator only.
- Screen: pending requests (name, creator, date) with Approve / Decline (confirm dialog for decline); below, the App review section moved from the family screen.

- [ ] **Step 1: Failing tests:** lists pending requests; approve calls the API and removes the row; decline confirms first; non-operator Settings has no tile; reviewer section renders here.
- [ ] **Step 2:** `flutter test test/screens/operator_screen_test.dart` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS; analyze clean.
- [ ] **Step 5:** Commit `feat(app): operator screen for family requests`.

### Task 9: App — signed-in person opens an invite link

**Files:**
- Modify: `app/lib/session/app_links.dart`; Create: `app/lib/screens/join_family_sheet.dart`
- Test: `app/test/session/app_links_test.dart`

**Interfaces:**
- For a signed-in, non-reviewer session, a `/join#<token>` link (not `review.`) calls `lookupInvite`; then a bottom sheet "Join <familyName>?" with "Join" / "Not now". Join → `joinFamily` → snackbar "You joined <familyName>" and `familiesProvider` refresh. `alreadyMember` → snackbar "You're already in <familyName>". `invite_invalid` → "This invite link has expired or was already used." Replaces "You're already signed in." Reviewer sessions keep that old snackbar.

- [ ] **Step 1: Failing tests:** sheet shows the family name and joining calls the API; already-member message; invalid-link message; reviewer session still gets "You're already signed in."
- [ ] **Step 2:** `flutter test test/session/app_links_test.dart` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS; analyze clean.
- [ ] **Step 5:** Commit `feat(app): join a family from an invite link while signed in`.

### Task 10: App — family picker for new groups, family labels, group info

**Files:**
- Modify: `app/lib/screens/chats/new_chat_screen.dart`, `app/lib/chat/http_chat_api.dart` (create group sends `familyId`), `app/lib/screens/chats/group_info_screen.dart`
- Test: `app/test/screens/new_chat_test.dart` (or the existing new-chat test file), `app/test/screens/group_info_test.dart`

**Interfaces:**
- New group with ≥2 approved families: first a family step (list of family names); the member picker then lists only users whose `familyIds` contain it; `createGroup(..., familyId)`. With one family: no step, `familyId` of that family is sent.
- New direct chat with ≥2 families: each person's subtitle is the shared family names, joined by ", ".
- Adding members to a group (`addTo`) lists only that chat's family's members.
- Group info shows "Family: <name>" when I'm in ≥2 families (single-family users see nothing new).

- [ ] **Step 1: Failing tests:** two families → picker step then filtered members, and the request carries `familyId`; one family → no step; direct list labels with two families and none with one; add-members filtered by the chat's family; group info shows the family name only for multi-family users.
- [ ] **Step 2:** `flutter test <files>` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS; analyze clean.
- [ ] **Step 5:** Commit `feat(app): pick the family for a new group; label people by family`.

### Task 11: App — demoted admins need a fresh proof

**Files:**
- Modify: `app/lib/chat/db/chat_db.dart` (schema 9 table `LocalRevokedProofs(familyId, userId, sig)`, PK all three; `replaceFamilyPins` doc comment: "for the pairing handover only"), `app/lib/chat/resets.dart` / `directory.dart` (trust resolution)
- Test: `app/test/chat/directory_test.dart`, `app/test/chat/chat_db_migration_test.dart`

**Interfaces:**
- When a refresh drops a pinned admin of a family still listed on my entry, record that admin's last seen `adminProof.sig` (if any) in `LocalRevokedProofs`. A proof whose `(familyId, userId, sig)` is revoked never re-adds that admin. Ed25519 is deterministic, so a re-promotion by the same signer yields the same sig and stays untrusted on this device (fails safe: banners only) — record as a ruling.
- Same schema version 9 as Task 5 (both ship together); add the table in the same 8→9 migration step.

- [ ] **Step 1: Failing tests:** `a demoted admin re-listed with the old proof stays untrusted`; `a different admin's fresh proof for the same person re-trusts them`; migration creates the table.
- [ ] **Step 2:** `flutter test test/chat/directory_test.dart test/chat/chat_db_migration_test.dart` — FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS; full app suite `flutter test -j 2` PASS; analyze clean.
- [ ] **Step 5:** Docs (`docs/protocol.md` trust section); commit `fix(app): a demoted admin isn't re-trusted with their old proof`.
