# Multiple families, email accounts and operator approval (design)

Agreed in conversation on 2026-11-17. Approach A was chosen.

## Intent
FamChat serves one family today. The owner's wife wants her side of the family on the app. The owner
doesn't want the two sides mixed, but he belongs in both. So a **family** becomes a grouping, like a
super-group. A person can create families, own several and belong to several. People see and message
only those who share at least one family with them.

The app is still meant for close family, not the public. Anyone may create an account, but a **new
family needs the operator's approval** (the owner's, for now). Email gives people an account,
verified with a code, and lets admins invite by address. It does **not** sign in a new phone: a new
phone still joins by pairing, or by an admin reset when every device is lost. If an emailed code
alone could sign in a phone, anyone with access to the inbox could become the person, and
end-to-end encryption would protect nothing.

## Goals
- **Families.** Any signed-in person can request a family. While it waits for the operator's
  approval it can't invite anyone. On approval, the creator becomes its first admin, called the
  "owner" in the UI.
- **Visibility.** You see and can message only people who share at least one family with you. That
  covers the directory, the new-chat picker, @mentions, presence, typing, profile updates, resets
  and account-deleted events. Your wife's relatives never appear for you unless they're also in one
  of your families.
- **One mixed chat list.** There's no family switcher.
  - A **direct chat** belongs to the pair of people, not to a family. There's one per pair, however
    many families they share. It takes new messages while the two share at least one family, and
    becomes read-only history once they share none.
  - A **group chat** belongs to exactly one family. Only that family's members can be added. Group
    info shows the family's name.
- **Roles per family.** Admins invite people, remove them and promote other members to admin. Being
  an admin in one family gives no power in another. Members can leave a family. A family's last
  admin can't leave while other members remain.
- **Removal.** Removing someone from a family takes them out of that family's group chats, which
  rotates the chat keys. Direct chats with people they no longer share any family with become
  read-only. They keep their account and their other families.
- **Resets.** Any admin of a family the person belongs to may reset their account. Each viewer's
  device decides whether to trust a reset:
  - It's accepted silently only if the signer is an admin, trusted by this device, of a family that
    both the viewer and the reset person belong to.
  - Otherwise the viewer gets the existing "security key changed" warning.
  - This way an admin in one family can't silently take over someone's account in another.
- **The admin recovery code** stays per person: one code per account, not one per family.
- **Invites** are always to one family:
  - **By link**, as today. A signed-out person who redeems it creates an account and joins that
    family. A signed-in person who taps it is asked "Join <family>?" and joins with their existing
    account. This replaces today's "You're already signed in" note.
  - **By email.** An admin enters an address. FamChat emails a link to it. If a verified account
    already has that address, the invite also shows up in their app.
- **Email accounts.**
  - Signing up with no invite: name and email, then a 6-digit code emailed to that address. The
    phone makes its keys exactly as it does when redeeming an invite.
  - An account with no family sees no one. It can request a family or wait for an invite.
  - Existing accounts can add and verify an email in Settings, but don't have to.
- **The operator.** This is a site-wide role, separate from family admins. The operator sees the
  pending family requests in Settings and approves or declines them. When a family is approved, its
  creator gets an email and an in-app note. Initially the operator is the owner's account.
- **Existing data.** Today's family becomes family #1:
  - everyone in it becomes a member;
  - today's admins become its admins;
  - every existing group chat belongs to it.
  The reviewer accounts become a **hidden family**, which replaces the special case for reviewers.
  Nobody should notice any change on upgrade.

## Non-goals
- Email or password as a way to sign in on a new phone (see Intent).
- A family switcher, or separate chat lists per family.
- Moving a group chat from one family to another.
- Merging two accounts that one person created.
- Billing, public discovery of families, and anything that makes the app public.
- Per-family themes or avatars. A family has only a name.

## Anti-goals (a failure even if everything else works)
- Anyone ever sees a person they don't share a family with, through any channel: the directory, an
  event, an @mention, a reset banner or a group member list.
- An admin of one family can silently change the identity key of someone who belongs to another
  family, as seen by that other family's members.
- A family is created and used (invites sent, people joined) without the operator's approval.
- The upgrade disturbs today's family: lost chats, re-pairing, or new key-change warnings.

## Constraints
- The server never sees message bodies; end-to-end encryption is unchanged. Family names, member
  lists and emails are server-visible metadata, like user names today.
- The project's CLAUDE.md lists "public sign-up" as out of scope. The owner has now asked for
  email sign-up gated by family approval, so the plan updates CLAUDE.md to say that.
- There's one Cloudflare deployment and one `FamilyHub` Durable Object, with one socket per
  device (approach A).
- The global media cap stays at 8 GiB, plus the reviewers' 256 MiB cap.
- Email is sent with Cloudflare Email Service's sending binding from `famchat.dev`. That zone
  already runs Email Routing for support@.
- Old app versions keep working against the new server until they update. The server can't tell
  old clients from new ones, and doesn't try: they get the same scoped `/users` and events as new
  clients, plus the few defaults in "Compatibility".

## Approaches
- **A. One hub; families live in the database (chosen).**
  - New `families` and `family_members` tables; `chats.family_id` is set on group chats.
  - Every fan-out that today goes to "everyone on my side" goes to "everyone who shares a family
    with the subject".
  - Admin proofs name a family.
  - Devices keep one socket, which makes the mixed chat list natural and a shared direct chat
    simply one chat.
  - It generalizes the existing reviewer "side" split.
- **B. One hub per family.** The separation is stronger, but a device in two families needs two
  sockets. A direct chat between two people who share two families has no natural home. Merging
  two streams into one chat list is a large client rewrite. Rejected: too much cost for little gain.
- **C. A separate deployment per family.** There'd be no shared account, so nobody could be in both
  families. Rejected.

## Decisions

### Data
- `families(id, name 1–40, created_by, status 'pending'|'approved'|'declined', hidden 0|1,
  created_at, decided_at, decided_by)`.
- `family_members(family_id, user_id, role 'admin'|'member', admin_by, admin_signer_pub, admin_sig,
  joined_at)`, with primary key `(family_id, user_id)`.
- `chats.family_id`: NOT NULL for groups, NULL for directs.
- `invites.family_id`; `invites.email`, NULL for link invites.
- `users.email`, unique among verified addresses; `users.email_verified_at`; `users.operator 0|1`.
- `email_codes(email, purpose 'signup'|'verify', code_hash, attempts, expires_at)`.
- The migration does these, in one transaction:
  1. Creates family #1, named "Family" and renameable by its admins, with `status = 'approved'`.
  2. Adds every non-reviewer, non-deleted user to it. Users with `is_admin` become admins; their
     existing proofs are carried over as *legacy proofs* (below).
  3. Creates the hidden reviewer family and adds the reviewer users to it.
  4. Sets `family_id` on every group to family #1, or to the reviewer family if its creator is a
     reviewer.
  5. Marks the bootstrapped admin, the one with no `admin_by`, as operator.
- `users.is_admin` and `users.reviewer` stay for compatibility. They're derived from family #1 and
  the reviewer family respectively, and new code doesn't read them.

### Visibility rule
- `shares(a, b)` means users a and b have at least one `family_members` row with the same
  `family_id`.
- `GET /users` returns the caller and everyone they share a family with.
- Each user in the response carries the families they share with the caller:
  `families: [{id, role, adminProof}]`. A person's other families are never listed.
- **People you used to share a family with.** If you share a chat with someone, including a
  read-only direct chat or a group they've left, `/users` still lists them, marked
  `former: true`. The listing carries only what history needs: name, photo, identity key, devices
  and resets. That lets a newly paired or reset device verify and show old messages.
  - They get no presence, typing, `profile` or other events from you.
  - They're never offered in pickers.
  - They don't count for reset trust.
  - **Why this doesn't break the visibility anti-goal:** the two already saw each other while they
    shared a family.
  - *My call.*
- The hub keeps a per-user set of "people I share a family with". It loads that set from D1 when a
  socket connects and refreshes it on a `family` event.
- Presence, typing, `profile`, `reset` and `account_deleted` go only to sockets of users in the
  subject's set.
- Chat events still follow chat membership.

### Families API (new)
- `GET /families`: your families, each with `{id, name, status, role, memberCount}`.
- `POST /families {name}`: creates a pending family.
- `PUT /families/:id {name}`: admin only.
- `POST /families/:id/invites {name, email?}`: admin only, and the family must be approved. Returns
  the invite link; if an email is given, it also sends the email.
- `POST /families/:id/join {inviteToken}`: joins with your existing account.
- `DELETE /families/:id/members/:userId`: leaving (yourself) or removing someone (admin only).
- `POST /families/:id/admins/:userId {sig}`: promotes a member to admin.
- `GET /operator/families?status=pending`, `POST /operator/families/:id/approve`,
  `POST /operator/families/:id/decline`: operator only.
- WebSocket: `{type:"family", familyId}` goes to every member when a family's membership, roles or
  name change. On it: `GET /families` and `GET /users`.
- `POST /chats` (group) takes a `familyId`. Every user in `userIds` and the caller must be members of
  it, otherwise 400.
- `POST /chats` (direct) and `send` to a direct chat need `shares(a, b)`. Otherwise
  `403 no_shared_family`; the client shows a read-only footer instead of the composer.

### Admin proofs and reset trust (security)
- A new proof: `"famchat-admin-v2" ‖ str(familyId) ‖ str(userId) ‖ str(byUserId)`, signed by the
  promoting admin's identity key.
- A family's creator has no proof. The device pins them on first use (TOFU, below).
- Legacy v1 proofs (`famchat-admin-v1 ‖ str(userId) ‖ str(byUserId)`) count only for family #1.
- **Pinning moves from per-app to per-family.**
  - The first time a device sees a family, it pins the admins the server lists for it. That's
    family creation, or joining it, for its own user. A device that joins later pins the list
    current at that time.
  - After that, it adds only admins whose v2 proof (or v1 proof, in family #1) verifies under an
    admin it already trusts in that family.
  - A family the device has seen keeps its pins frozen when the server stops listing it (the user
    left, or the server omits it). Frozen pins don't count, and they are the starting point if the
    family is listed again. Only never-seen families are trusted on first sight, so the server
    can't force a fresh first sight.
  - A paired device takes its pins from the approving device's handover bundle.
  - On upgrade, a device converts its existing pinned-admin list into family #1's pins, so no new
    warnings appear.
- **Reset acceptance**, run on the viewer's device: the existing rules, except that "trusted admin"
  now means "trusted admin of a family that both this device's user and the reset person belong to,
  as the device currently sees it". A reset that fails this test gets the existing manual "security
  key changed" banner.
- **Server checks:** `POST /admin/users/:id/reset` is allowed when the caller is an admin of any
  family the target belongs to. The response and audit event record which family authorized it.

### Removal and leaving
- Removing a member, or a member leaving, runs in one transaction:
  1. delete the `family_members` row;
  2. remove the person from every group chat of that family, rotating each chat to the next epoch
     exactly as an existing removal does;
  3. emit `family`, plus `chat`/`removed` per group.
- Direct chats are left alone. They become read-only on their own when `shares` turns false.
- Removing someone is admin only, and admins can't remove another admin. That needs demoting first,
  which the creator can do.
- **My call:** demoting is only the owner's power, so two admins can't remove each other.
  - API: `DELETE /families/:id/admins/:userId`.
  - The owner is the family's creator. If the creator leaves or deletes their account, ownership
    passes to the longest-serving remaining admin. Family #1's owner is the bootstrapped admin.
  - The owner can't be demoted or removed, only leave.
- **Losing trust follows the server; gaining it needs a proof.** A device stops trusting an admin
  as soon as the server no longer lists them as an admin of that family: demoted, removed, left or
  deleted. Becoming trusted again needs a fresh signed proof.
  - **Why this is safe:** a lying server can only make a device trust less, which surfaces as
    warnings. It can never make a device trust more.
  - *My call.*

### Account-wide powers (my calls)
- **Deleting someone else's account** (`DELETE /admin/users/:id`) becomes **operator-only**. A
  family admin removes people from their family and can't delete an account that also belongs to
  other families.
- `DELETE /me` gives `409 last_admin` if you're the only admin of a family that still has other
  members. The message names the family. Promote someone or remove the others first.
- `POST /admin/bootstrap` is retired once the migration has created an operator. On an empty
  database it makes the first account the operator, plus owner of an approved family #1.
- **Admin recovery code:** an admin of any family can set one, as today's admins can. A recovery
  only proves the person still holds their own old key, so it gives no power over anyone else.
  That makes it safe for any family's admin.
- **Reviewer family:** the reviewer-invite and reviewer-list endpoints become operator-only.
  - Reviewers don't see Settings → Families and can't start a family or sign up with email.
  - The hidden family never appears in the operator's family lists or requests.
  - Reviewers keep their 256 MiB media cap.

### Email
- **Sending:** Cloudflare Email Service's `send_email` binding, from `FamChat <no-reply@famchat.dev>`.
  Emails are plain text plus a minimal HTML version, and are sent only for:
  - verification codes;
  - invites;
  - a family approved or declined.
- **Codes:** 6 digits, valid for 10 minutes, at most 5 tries, stored only as a hash.
- **Rate limits:** at most 5 sends per address per hour and 20 per IP per hour, the latter with the
  existing rate-limit helper.
- **Sign-up:**
  1. `POST /auth/email/start {email}` emails a code. It always answers 202, so it doesn't reveal
     whether the address has an account.
  2. `POST /auth/email/signup {email, code, name, identityPub, encPub, signPub, certSig, deviceName,
     platform}` returns the same tokens body as an invite redeem.
- If the address already belongs to an account, sign-up fails with `409 email_in_use`. The app then
  says "This email already has an account. Sign in by pairing with one of your devices, or ask a
  family admin to reset your account."
- **Existing users:**
  1. `POST /me/email {email}` emails a code;
  2. `POST /me/email/verify {code}` saves the address;
  3. `DELETE /me/email` removes it.
- **Email invites:** the email contains the `/join#<token>` link, which opens the app through the
  app links already built. If an account with that verified email exists, its devices also get
  `{type:"invite"}` and Settings → Families shows "Join <family>?".
- Email addresses are visible to the operator and to the person themselves, nobody else.

### The app
- **Settings → Families:** your families. Each one shows its members, your role, the invite button
  (admins), rename, leave and remove. A pending family shows "Waiting for approval". There's a
  "Start a family" button.
- **Operator only:** Settings → Family requests, with approve and decline.
- **New group:** if you're in more than one family, you pick the family first, and the member picker
  lists only that family. With one family the step is skipped, so single-family users never see
  families anywhere except Settings.
- **New direct chat:** everyone you share a family with, in one list, labelled by family when you have
  more than one.
- **Group info:** the family's name.
- **Direct chat with nobody shared:** a "You're no longer in a family together" footer in place of
  the composer.
- **Join screen:** with no invite, "Create account with email" sits next to "Pair with another
  device" and "I have an invite".
- **Signed-in person taps an invite link:** a "Join <family>?" sheet.

### Compatibility
- Old clients don't send `familyId` on a new group. The server then uses the caller's only family. If
  the caller has several, it uses family #1 when the caller is in it, otherwise it returns 400.
- `isAdmin` in `/me` and `/users` means "admin of family #1", so old clients' reset trust keeps
  working inside family #1.
- Old clients ignore the new `family` and `invite` events.

## Staging
Each stage ships on its own and is releasable.

1. **Data model and visibility.** Migration, scoped `/users` and hub fan-out, `chats.family_id`,
   group creation within one family, the read-only rule for direct chats. With only family #1
   existing, users see no change.
2. **Per-family admins and reset trust.** v2 proofs, per-family pinning with the upgrade conversion,
   reset authorization and acceptance.
3. **Creating and joining families.** Families API, operator approval, link invites per family,
   joining with an existing account, Settings → Families, the family picker on new group, the
   read-only footer.
4. **Email.** Sending binding, codes, sign-up, adding an email in Settings, email invites, approval
   emails.

## Left to the builder
- Exact wording of screens and emails, and the email layout.
- Table indexes, and how the hub caches the "people I share a family with" sets.
- Test layout and how stages split into PRs.
- The HTTP status codes not named above, following `docs/protocol.md`'s conventions.
- `docs/protocol.md` is updated alongside each stage.
