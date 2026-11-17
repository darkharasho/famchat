import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { api, createDirect, createGroup, type TestUser } from "./chat-helpers";
import { newId } from "../src/lib/ids";
import { errorResponse } from "../src/lib/errors";
import { familyPeers, groupFamilyFor, sharingUserIds, shares } from "../src/lib/family";
import { insertFamily, insertUserWithDevice, joinFamily, resetDb } from "./helpers";
import { promotionMessage, promotionMessageV2 } from "../src/lib/reset";
import { sign } from "./reset-helpers";
import { socket, closeSockets } from "./ws-helpers";
import { randomToken, sha256Hex } from "../src/lib/tokens";

beforeEach(resetDb);
afterEach(closeSockets);

const user = (families: { id: number; role?: "admin" | "member" }[]) => insertUserWithDevice({ families });

describe("family visibility", () => {
  it("familyPeers lists live people sharing any family, self included", async () => {
    const f3 = await insertFamily();
    const f4 = await insertFamily();
    const a = await user([{ id: 1 }, { id: f3 }]);
    const b = await user([{ id: 1 }]);
    const c = await user([{ id: f3 }]);
    const d = await user([{ id: f4 }]);
    const e = await user([{ id: 1 }]);
    await env.DB.prepare("UPDATE users SET deleted_at = 1 WHERE id = ?").bind(e.userId).run();
    expect((await familyPeers(env.DB, a.userId)).sort()).toEqual([a.userId, b.userId, c.userId].sort());
    expect(await familyPeers(env.DB, d.userId)).toEqual([d.userId]);
  });

  it("shares is false for a deleted or unshared person", async () => {
    const f3 = await insertFamily();
    const a = await user([{ id: 1 }]);
    const b = await user([{ id: 1 }]);
    const c = await user([{ id: f3 }]);
    const e = await user([{ id: 1 }]);
    expect(await shares(env.DB, a.userId, b.userId)).toBe(true);
    expect(await shares(env.DB, a.userId, c.userId)).toBe(false);
    await env.DB.prepare("UPDATE users SET deleted_at = 1 WHERE id = ?").bind(e.userId).run();
    expect(await shares(env.DB, a.userId, e.userId)).toBe(false);
    expect(await shares(env.DB, e.userId, a.userId)).toBe(false);
  });

  it("groupFamilyFor picks the only family, then family #1, else 400", async () => {
    const f3 = await insertFamily();
    const f4 = await insertFamily();
    const pending = await insertFamily({ status: "pending" });
    const only3 = await user([{ id: f3 }]);
    const both = await user([{ id: 1 }, { id: f3 }]);
    const multi = await user([{ id: f3 }, { id: f4 }]);
    const inPending = await user([{ id: pending }]);
    expect(await groupFamilyFor(env.DB, only3.userId, undefined)).toBe(f3);
    expect(await groupFamilyFor(env.DB, both.userId, undefined)).toBe(1);
    await expect(groupFamilyFor(env.DB, multi.userId, undefined)).rejects.toMatchObject({ code: "invalid_request" });
    expect(await groupFamilyFor(env.DB, multi.userId, f4)).toBe(f4);
    await expect(groupFamilyFor(env.DB, only3.userId, f4)).rejects.toMatchObject({ code: "invalid_request" });
    await expect(groupFamilyFor(env.DB, inPending.userId, pending)).rejects.toMatchObject({ code: "invalid_request" });
    await expect(groupFamilyFor(env.DB, inPending.userId, undefined)).rejects.toMatchObject({ code: "invalid_request" });
    await expect(groupFamilyFor(env.DB, both.userId, "1")).rejects.toMatchObject({ code: "invalid_request" });
  });

  it("sharingUserIds leaves out chat co-members outside your families", async () => {
    const f3 = await insertFamily();
    const a = await user([{ id: 1 }]);
    const b = await user([{ id: 1 }]);
    const c = await user([{ id: f3 }]);
    await env.DB.prepare(
      "INSERT INTO chats (id, kind, title, created_by, created_at, family_id) VALUES ('c1', 'group', 'x', ?, 1, 1)",
    ).bind(a.userId).run();
    for (const u of [a, b, c])
      await env.DB.prepare("INSERT INTO chat_members (chat_id, user_id, joined_at) VALUES ('c1', ?, 1)").bind(u.userId).run();
    expect((await sharingUserIds(env.DB, a.userId)).sort()).toEqual([a.userId, b.userId].sort());
  });
});

describe("errors and admin checks", () => {
  it("an error's extra fields reach the body", async () => {
    const res = errorResponse("last_admin", { familyId: 1, familyName: "Family" });
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: "last_admin", familyId: 1, familyName: "Family" });
    expect(errorResponse("no_shared_family").status).toBe(403);
  });

  it("requireAdmin follows family #1, not users.is_admin", async () => {
    const f3 = await insertFamily();
    const other = await insertUserWithDevice({ admin: true, families: [{ id: f3, role: "admin" }] });
    expect((await api(other.accessToken, "GET", "/admin/usage")).status).toBe(403);
    const real = await insertUserWithDevice({ admin: true });
    expect((await api(real.accessToken, "GET", "/admin/usage")).status).toBe(200);
  });
});

describe("POST /families/:id/admins/:userId", () => {
  type U = Awaited<ReturnType<typeof insertUserWithDevice>>;
  const promoteV2 = async (by: U, fam: number, target: string, signFam = fam) =>
    api(by.accessToken, "POST", `/families/${fam}/admins/${target}`, {
      sig: await sign(by.keys.identityPriv, promotionMessageV2(signFam, target, by.userId)),
    });
  const row = (fam: number, id: string) =>
    env.DB.prepare("SELECT role, admin_by, admin_signer_pub, admin_sig FROM family_members WHERE family_id = ? AND user_id = ?")
      .bind(fam, id).first<Record<string, unknown>>();

  it("promotes a member of the caller's family with a v2 proof", async () => {
    const f = await insertFamily();
    const admin = await user([{ id: f, role: "admin" }]);
    const dad = await user([{ id: f }]);
    expect((await promoteV2(admin, f, dad.userId)).status).toBe(204);
    const fm = await row(f, dad.userId);
    expect(fm).toMatchObject({ role: "admin", admin_by: admin.userId, admin_signer_pub: admin.keys.identityPub });
    expect(fm?.admin_sig).toBeTruthy();
    expect(await env.DB.prepare("SELECT is_admin FROM users WHERE id = ?").bind(dad.userId).first<number>("is_admin")).toBe(0);
    const ev = await env.DB.prepare("SELECT payload FROM events WHERE kind = 'admin_promoted'").first<{ payload: string }>();
    expect(JSON.parse(ev!.payload)).toMatchObject({ familyId: f });
  });

  it("rejects a v1 proof on the per-family endpoint", async () => {
    const f = await insertFamily();
    const admin = await user([{ id: f, role: "admin" }]);
    const dad = await user([{ id: f }]);
    const res = await api(admin.accessToken, "POST", `/families/${f}/admins/${dad.userId}`, {
      sig: await sign(admin.keys.identityPriv, promotionMessage(dad.userId, admin.userId)),
    });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_request" });
    expect((await row(f, dad.userId))?.role).toBe("member");
  });

  it("rejects a v2 proof signed for another family", async () => {
    const f = await insertFamily();
    const g = await insertFamily();
    const admin = await user([{ id: f, role: "admin" }]);
    const dad = await user([{ id: f }]);
    expect((await promoteV2(admin, f, dad.userId, g)).status).toBe(400);
    expect((await row(f, dad.userId))?.role).toBe("member");
  });

  it("non-admin of the family gets 403", async () => {
    const f = await insertFamily();
    const member = await user([{ id: f }]);
    const dad = await user([{ id: f }]);
    const res = await promoteV2(member, f, dad.userId);
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: "forbidden" });
  });

  it("admin of another family gets 403", async () => {
    const f = await insertFamily();
    const g = await insertFamily();
    const admin = await user([{ id: g, role: "admin" }]);
    const dad = await user([{ id: f }]);
    expect((await promoteV2(admin, f, dad.userId)).status).toBe(403);
    expect((await row(f, dad.userId))?.role).toBe("member");
  });

  it("target outside the family gets 404", async () => {
    const f = await insertFamily();
    const g = await insertFamily();
    const admin = await user([{ id: f, role: "admin" }]);
    const outsider = await user([{ id: g }]);
    const res = await promoteV2(admin, f, outsider.userId);
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "not_found" });
  });

  it("deleted target gets 404", async () => {
    const f = await insertFamily();
    const admin = await user([{ id: f, role: "admin" }]);
    const dad = await user([{ id: f }]);
    await env.DB.prepare("UPDATE users SET deleted_at = 1 WHERE id = ?").bind(dad.userId).run();
    expect((await promoteV2(admin, f, dad.userId)).status).toBe(404);
    expect((await row(f, dad.userId))?.role).toBe("member");
  });

  it("an unapproved family can't promote", async () => {
    const f = await insertFamily({ status: "pending" });
    const admin = await user([{ id: f, role: "admin" }]);
    const dad = await user([{ id: f }]);
    expect((await promoteV2(admin, f, dad.userId)).status).toBe(403);
  });

  it("promotion in family 1 mirrors users.is_admin", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const dad = await user([{ id: 1 }]);
    expect((await promoteV2(admin, 1, dad.userId)).status).toBe(204);
    const fm = await row(1, dad.userId);
    const u = await env.DB.prepare("SELECT is_admin, admin_by, admin_signer_pub, admin_sig FROM users WHERE id = ?")
      .bind(dad.userId).first<Record<string, unknown>>();
    expect(fm?.role).toBe("admin");
    expect(u).toEqual({ is_admin: 1, admin_by: fm?.admin_by, admin_signer_pub: fm?.admin_signer_pub, admin_sig: fm?.admin_sig });
  });
});

describe("GET/POST/PUT /families", () => {
  type FamilyOut = { id: number; name: string; status: string; role: string; memberCount: number; owner: boolean; ownerId: string | null; createdAt: number };
  const list = async (u: { accessToken: string }) =>
    (await (await api(u.accessToken, "GET", "/families")).json<{ families: FamilyOut[] }>()).families;

  it("lists only my non-hidden families with role, owner and memberCount", async () => {
    const me = await user([{ id: 1 }]);
    const f = await insertFamily({ name: "Cousins", status: "pending", createdBy: me.userId });
    await joinFamily(me.userId, f, "admin");
    const other = await insertFamily({ name: "Elsewhere" });
    const hidden = await insertFamily({ name: "Secret", hidden: true });
    await joinFamily(me.userId, hidden);
    const peer = await user([{ id: f }]);
    const gone = await user([{ id: f }]);
    await env.DB.prepare("UPDATE users SET deleted_at = 1 WHERE id = ?").bind(gone.userId).run();
    await user([{ id: other }]);
    const fams = await list(me);
    expect(fams.map((x) => x.id)).toEqual([1, f]);
    expect(fams[0]).toMatchObject({ name: "Family", status: "approved", role: "member", owner: false });
    expect(fams[1]).toMatchObject({ name: "Cousins", status: "pending", role: "admin", memberCount: 2, owner: true });
    expect(typeof fams[1].createdAt).toBe("number");
    expect(fams[1].ownerId).toBe(me.userId);
    const first = await env.DB.prepare("SELECT created_by FROM families WHERE id = 1").first<string | null>("created_by");
    expect(fams[0].ownerId).toBe(first);
    await env.DB.prepare("UPDATE families SET created_by = NULL WHERE id = ?").bind(f).run();
    expect((await list(me))[1]).toMatchObject({ owner: false, ownerId: null });
    expect(peer.userId).toBeTruthy();
  });

  it("creates a pending family with me as its admin", async () => {
    const me = await user([{ id: 1 }]);
    const res = await api(me.accessToken, "POST", "/families", { name: "  Cousins  " });
    expect(res.status).toBe(201);
    const { family } = await res.json<{ family: FamilyOut }>();
    expect(family).toMatchObject({ name: "Cousins", status: "pending", role: "admin", memberCount: 1, owner: true });
    const row = await env.DB.prepare("SELECT created_by, status, hidden FROM families WHERE id = ?")
      .bind(family.id).first<Record<string, unknown>>();
    expect(row).toEqual({ created_by: me.userId, status: "pending", hidden: 0 });
    const m = await env.DB.prepare("SELECT role, admin_by, admin_sig FROM family_members WHERE family_id = ? AND user_id = ?")
      .bind(family.id, me.userId).first<Record<string, unknown>>();
    expect(m).toEqual({ role: "admin", admin_by: null, admin_sig: null });
    expect(await env.DB.prepare("SELECT 1 AS n FROM events WHERE kind = 'family_requested'").first()).not.toBeNull();
    expect((await api(me.accessToken, "POST", "/families", { name: "" })).status).toBe(400);
  });

  it("a fourth pending request is rate limited", async () => {
    const me = await user([{ id: 1 }]);
    for (const n of ["A", "B", "C"]) expect((await api(me.accessToken, "POST", "/families", { name: n })).status).toBe(201);
    const res = await api(me.accessToken, "POST", "/families", { name: "D" });
    expect(res.status).toBe(429);
    expect(await res.json()).toEqual({ error: "rate_limited" });
    const other = await user([{ id: 1 }]);
    expect((await api(other.accessToken, "POST", "/families", { name: "E" })).status).toBe(201);
  });

  it("reviewers get 403 on /families", async () => {
    const rev = await insertUserWithDevice({ reviewer: true });
    expect((await api(rev.accessToken, "GET", "/families")).status).toBe(403);
    expect((await api(rev.accessToken, "POST", "/families", { name: "X" })).status).toBe(403);
    expect((await api(rev.accessToken, "PUT", "/families/2", { name: "X" })).status).toBe(403);
  });

  it("admin renames an approved family and members get a family event", async () => {
    const f = await insertFamily({ name: "Old" });
    const admin = await user([{ id: f, role: "admin" }]);
    const member = await user([{ id: f }]);
    const outsider = await user([{ id: 1 }]);
    const sm = await socket(member);
    const so = await socket(outsider);
    expect((await api(admin.accessToken, "PUT", `/families/${f}`, { name: " New " })).status).toBe(204);
    expect(await env.DB.prepare("SELECT name FROM families WHERE id = ?").bind(f).first("name")).toBe("New");
    expect(await sm.next("family")).toEqual({ type: "family", familyId: f });
    await so.none("family");
  });

  it("a member can't rename (403)", async () => {
    const f = await insertFamily({ name: "Old" });
    const member = await user([{ id: f }]);
    const res = await api(member.accessToken, "PUT", `/families/${f}`, { name: "New" });
    expect(res.status).toBe(403);
    expect(await env.DB.prepare("SELECT name FROM families WHERE id = ?").bind(f).first("name")).toBe("Old");
  });

  it("an unknown or hidden family is 404", async () => {
    const hidden = await insertFamily({ hidden: true });
    const me = await user([{ id: 1 }]);
    expect((await api(me.accessToken, "PUT", "/families/9999", { name: "N" })).status).toBe(404);
    expect((await api(me.accessToken, "PUT", `/families/${hidden}`, { name: "N" })).status).toBe(404);
    expect((await api(me.accessToken, "PUT", "/families/abc", { name: "N" })).status).toBe(404);
  });

  it("the creator can rename their pending family", async () => {
    const me = await user([{ id: 1 }]);
    const f = (await (await api(me.accessToken, "POST", "/families", { name: "Old" })).json<{ family: FamilyOut }>()).family.id;
    expect((await api(me.accessToken, "PUT", `/families/${f}`, { name: "New" })).status).toBe(204);
    expect((await list(me)).find((x) => x.id === f)?.name).toBe("New");
  });

  it("a non-creator admin of a pending family can't rename it", async () => {
    const creator = await user([{ id: 1 }]);
    const f = await insertFamily({ status: "pending", createdBy: creator.userId });
    const other = await user([{ id: f, role: "admin" }]);
    expect((await api(other.accessToken, "PUT", `/families/${f}`, { name: "New" })).status).toBe(403);
  });

  it("rename validates 1–40 characters", async () => {
    const f = await insertFamily({ name: "Old" });
    const admin = await user([{ id: f, role: "admin" }]);
    for (const n of ["", "   ", "x".repeat(41), 5, undefined]) {
      expect((await api(admin.accessToken, "PUT", `/families/${f}`, { name: n })).status, String(n)).toBe(400);
    }
    expect((await api(admin.accessToken, "PUT", `/families/${f}`, { name: "x".repeat(40) })).status).toBe(204);
  });
});

describe("family invites and joining", () => {
  type FamilyOut = { id: number; name: string; status: string; role: string; memberCount: number; owner: boolean };
  const famInvite = async (
    familyId: number,
    o: { name?: string; createdBy?: string | null; expiresAt?: number; used?: boolean; revoked?: boolean; reviewer?: boolean; userId?: string } = {},
  ) => {
    const token = randomToken();
    const now = Date.now();
    await env.DB.prepare(
      `INSERT INTO invites (token_hash, name, make_admin, created_by, created_at, expires_at, family_id, used_by, used_at, revoked_at, reviewer, user_id)
       VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    ).bind(
      await sha256Hex(token), o.name ?? "Auntie", o.createdBy ?? null, now, o.expiresAt ?? now + 86_400_000, familyId,
      o.used ? "someone" : null, o.used ? now : null, o.revoked ? now : null, o.reviewer ? 1 : 0, o.userId ?? null,
    ).run();
    return token;
  };
  const used = (token: string) =>
    sha256Hex(token).then((h) => env.DB.prepare("SELECT used_by FROM invites WHERE token_hash = ?").bind(h).first<string | null>("used_by"));

  it("family admin creates an invite for their family", async () => {
    const f = await insertFamily();
    const admin = await user([{ id: f, role: "admin" }]);
    const res = await api(admin.accessToken, "POST", `/families/${f}/invites`, { name: "Auntie" });
    expect(res.status).toBe(201);
    const body = await res.json<{ inviteToken: string; inviteUrl: string; expiresAt: number }>();
    expect(body.inviteUrl).toBe(`${env.APP_ORIGIN}/join#${body.inviteToken}`);
    expect(body.expiresAt).toBeGreaterThan(Date.now() + 6 * 86_400_000);
    const row = await env.DB.prepare("SELECT family_id, make_admin, created_by, name FROM invites WHERE token_hash = ?")
      .bind(await sha256Hex(body.inviteToken)).first<Record<string, unknown>>();
    expect(row).toEqual({ family_id: f, make_admin: 0, created_by: admin.userId, name: "Auntie" });
  });

  it("member gets 403", async () => {
    const f = await insertFamily();
    const member = await user([{ id: f }]);
    expect((await api(member.accessToken, "POST", `/families/${f}/invites`, { name: "A" })).status).toBe(403);
  });

  it("pending family's admin gets 403", async () => {
    const f = await insertFamily({ status: "pending" });
    const admin = await user([{ id: f, role: "admin" }]);
    expect((await api(admin.accessToken, "POST", `/families/${f}/invites`, { name: "A" })).status).toBe(403);
  });

  it("email in the invite body is 400", async () => {
    const f = await insertFamily();
    const admin = await user([{ id: f, role: "admin" }]);
    expect((await api(admin.accessToken, "POST", `/families/${f}/invites`, { name: "A", email: "a@b.c" })).status).toBe(400);
  });

  it("lookup returns family name and alreadyMember", async () => {
    const f = await insertFamily({ name: "Cousins" });
    const t = await famInvite(f, { name: "Pat" });
    const outsider = await user([{ id: 1 }]);
    const insider = await user([{ id: f }]);
    const look = (u: { accessToken: string }) => api(u.accessToken, "POST", "/families/invite-lookup", { inviteToken: t });
    expect(await (await look(outsider)).json()).toEqual({ familyId: f, familyName: "Cousins", invitedName: "Pat", alreadyMember: false });
    expect(await (await look(insider)).json()).toEqual({ familyId: f, familyName: "Cousins", invitedName: "Pat", alreadyMember: true });
  });

  it("lookup of a used, expired, reset or reviewer invite is 410", async () => {
    const f = await insertFamily();
    const me = await user([{ id: 1 }]);
    const bad = [
      await famInvite(f, { used: true }),
      await famInvite(f, { expiresAt: Date.now() - 1 }),
      await famInvite(f, { revoked: true }),
      await famInvite(f, { userId: me.userId }),
      await famInvite(f, { reviewer: true }),
      await famInvite(await insertFamily({ status: "pending" })),
      await famInvite(await insertFamily({ hidden: true })),
      "nonsense-token",
    ];
    for (const t of bad) {
      const res = await api(me.accessToken, "POST", "/families/invite-lookup", { inviteToken: t });
      expect(res.status).toBe(410);
      expect(await res.json()).toEqual({ error: "invite_invalid" });
    }
  });

  it("join adds me as member, uses the invite, and both sides now see each other in /users", async () => {
    const f = await insertFamily({ name: "Cousins" });
    const other = await user([{ id: f }]);
    const me = await user([{ id: 1 }]);
    const t = await famInvite(f);
    const sm = await socket(other);
    const res = await api(me.accessToken, "POST", `/families/${f}/join`, { inviteToken: t });
    expect(res.status).toBe(200);
    const { family } = await res.json<{ family: FamilyOut }>();
    expect(family).toMatchObject({ id: f, name: "Cousins", status: "approved", role: "member", memberCount: 2, owner: false });
    expect(await used(t)).toBe(me.userId);
    expect(await sm.next("family")).toEqual({ type: "family", familyId: f });
    const ids = async (u: { accessToken: string }) =>
      (await (await api(u.accessToken, "GET", "/users")).json<{ users: { id: string }[] }>()).users.map((x) => x.id);
    expect(await ids(me)).toContain(other.userId);
    expect(await ids(other)).toContain(me.userId);
    expect(await env.DB.prepare("SELECT 1 AS n FROM events WHERE kind = 'family_joined' AND user_id = ?").bind(me.userId).first()).not.toBeNull();
  });

  it("joining a family I'm in is 409 and the invite stays usable", async () => {
    const f = await insertFamily();
    const me = await user([{ id: f }]);
    const t = await famInvite(f);
    const res = await api(me.accessToken, "POST", `/families/${f}/join`, { inviteToken: t });
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: "conflict" });
    expect(await used(t)).toBeNull();
  });

  it("join with a token for another family is 410", async () => {
    const f = await insertFamily();
    const g = await insertFamily();
    const me = await user([{ id: 1 }]);
    const t = await famInvite(g);
    const res = await api(me.accessToken, "POST", `/families/${f}/join`, { inviteToken: t });
    expect(res.status).toBe(410);
    expect(await used(t)).toBeNull();
    expect(await env.DB.prepare("SELECT 1 AS n FROM family_members WHERE user_id = ? AND family_id IN (?, ?)").bind(me.userId, f, g).first()).toBeNull();
  });
});

describe("leaving, removing and demoting", () => {
  const remove = (by: TestUser, fam: number, target: string) => api(by.accessToken, "DELETE", `/families/${fam}/members/${target}`);
  const demote = (by: TestUser, fam: number, target: string) => api(by.accessToken, "DELETE", `/families/${fam}/admins/${target}`);
  const roleOf = (fam: number, id: string) =>
    env.DB.prepare("SELECT role FROM family_members WHERE family_id = ? AND user_id = ?").bind(fam, id).first<string>("role");
  const owner = (fam: number) => env.DB.prepare("SELECT created_by FROM families WHERE id = ?").bind(fam).first<string | null>("created_by");
  const epoch = (chatId: string) => env.DB.prepare("SELECT current_epoch FROM chats WHERE id = ?").bind(chatId).first<number>("current_epoch");
  const inChat = async (chatId: string, id: string) =>
    (await env.DB.prepare("SELECT 1 AS n FROM chat_members WHERE chat_id = ? AND user_id = ?").bind(chatId, id).first()) !== null;

  it("member leaves: out of the family's groups (epoch bumped, chat_leavers row), family event to the rest", async () => {
    const f = await insertFamily({ name: "Cousins" });
    const admin = await user([{ id: f, role: "admin" }]);
    const kid = await user([{ id: f }]);
    const other = await user([{ id: f }]);
    const group = await createGroup(admin, [kid, other], "Cousins");
    const sk = await socket(kid);
    const so = await socket(other);
    expect((await remove(kid, f, kid.userId)).status).toBe(204);
    expect(await roleOf(f, kid.userId)).toBeNull();
    expect(await inChat(group.id, kid.userId)).toBe(false);
    expect(await epoch(group.id)).toBe(2);
    expect(await env.DB.prepare("SELECT 1 AS n FROM chat_leavers WHERE chat_id = ? AND user_id = ?").bind(group.id, kid.userId).first()).not.toBeNull();
    expect(await sk.next("removed")).toEqual({ type: "removed", chatId: group.id });
    expect(await so.next("chat")).toEqual({ type: "chat", chatId: group.id });
    expect(await so.next("family")).toEqual({ type: "family", familyId: f });
    expect(await sk.next("family")).toEqual({ type: "family", familyId: f });
  });

  it("admin removes a member who is also in another family: other family's chats untouched, direct with a B-only person becomes no_shared_family on send", async () => {
    const a = await insertFamily({ name: "A" });
    const b = await insertFamily({ name: "B" });
    const adminB = await user([{ id: b, role: "admin" }]);
    const both = await user([{ id: a }, { id: b }]);
    const aPeer = await user([{ id: a }]);
    const bOnly = await user([{ id: b }]);
    const groupA = await createGroup(aPeer, [both], "A group", []);
    await env.DB.prepare("UPDATE chats SET family_id = ? WHERE id = ?").bind(a, groupA.id).run();
    const groupB = await createGroup(adminB, [both, bOnly], "B group");
    await env.DB.prepare("UPDATE chats SET family_id = ? WHERE id = ?").bind(b, groupB.id).run();
    const direct = await createDirect(both, bOnly);
    expect((await remove(adminB, b, both.userId)).status).toBe(204);
    expect(await inChat(groupB.id, both.userId)).toBe(false);
    expect(await epoch(groupB.id)).toBe(2);
    expect(await inChat(groupA.id, both.userId)).toBe(true);
    expect(await epoch(groupA.id)).toBe(1);
    expect(await roleOf(a, both.userId)).toBe("member");
    expect(await inChat(direct.id, both.userId)).toBe(true);
    const ws = await socket(bOnly);
    const id = newId();
    ws.send({ type: "send", id, chatId: direct.id, envelope: { v: 1, epoch: 1, nonce: "AA", ct: "AA", sig: "AA" } });
    expect(await ws.next("error")).toEqual({ type: "error", id, error: "no_shared_family" });
  });

  it("admin can't remove another admin (403)", async () => {
    const f = await insertFamily();
    const a = await user([{ id: f, role: "admin" }]);
    const b = await user([{ id: f, role: "admin" }]);
    expect((await remove(a, f, b.userId)).status).toBe(403);
    expect(await roleOf(f, b.userId)).toBe("admin");
  });

  it("member can't remove anyone (403)", async () => {
    const f = await insertFamily();
    await user([{ id: f, role: "admin" }]);
    const m = await user([{ id: f }]);
    const n = await user([{ id: f }]);
    expect((await remove(m, f, n.userId)).status).toBe(403);
    expect(await roleOf(f, n.userId)).toBe("member");
  });

  it("admin removing someone outside the family gets 404; a hidden family is 404", async () => {
    const f = await insertFamily();
    const a = await user([{ id: f, role: "admin" }]);
    const out = await user([{ id: 1 }]);
    expect((await remove(a, f, out.userId)).status).toBe(404);
    expect((await remove(a, 2, a.userId)).status).toBe(404);
  });

  it("last admin can't leave while others remain (409 last_admin with familyName)", async () => {
    const f = await insertFamily({ name: "Cousins" });
    const a = await user([{ id: f, role: "admin" }]);
    await user([{ id: f }]);
    const res = await remove(a, f, a.userId);
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: "last_admin", familyId: f, familyName: "Cousins" });
    expect(await roleOf(f, a.userId)).toBe("admin");
  });

  it("sole member leaves a declined family", async () => {
    const me = await user([{ id: 1 }]);
    const f = await insertFamily({ status: "declined", createdBy: me.userId });
    await joinFamily(me.userId, f, "admin");
    expect((await remove(me, f, me.userId)).status).toBe(204);
    expect(await roleOf(f, me.userId)).toBeNull();
    expect(await owner(f)).toBeNull();
    const fams = (await (await api(me.accessToken, "GET", "/families")).json<{ families: { id: number }[] }>()).families;
    expect(fams.map((x) => x.id)).toEqual([1]);
  });

  it("owner leaves: ownership passes to the longest-serving admin", async () => {
    const o = await user([{ id: 1 }]);
    const f = await insertFamily({ createdBy: o.userId });
    await joinFamily(o.userId, f, "admin");
    const later = await user([{ id: f, role: "admin" }]);
    const earlier = await user([{ id: f, role: "admin" }]);
    await user([{ id: f }]);
    await env.DB.prepare("UPDATE family_members SET joined_at = 100 WHERE user_id = ?").bind(earlier.userId).run();
    await env.DB.prepare("UPDATE family_members SET joined_at = 200 WHERE user_id = ?").bind(later.userId).run();
    expect((await remove(o, f, o.userId)).status).toBe(204);
    expect(await owner(f)).toBe(earlier.userId);
  });

  it("an admin can't remove the owner (403)", async () => {
    const o = await user([{ id: 1 }]);
    const f = await insertFamily({ createdBy: o.userId });
    await joinFamily(o.userId, f, "member");
    const a = await user([{ id: f, role: "admin" }]);
    expect((await remove(a, f, o.userId)).status).toBe(403);
  });

  it("removal from family 1 clears the users admin mirror", async () => {
    const op = await insertUserWithDevice({ admin: true, operator: true });
    await env.DB.prepare("UPDATE families SET created_by = ? WHERE id = 1").bind(op.userId).run();
    const other = await insertUserWithDevice({ admin: true });
    expect((await remove(other, 1, other.userId)).status).toBe(204);
    expect(await env.DB.prepare("SELECT is_admin FROM users WHERE id = ?").bind(other.userId).first("is_admin")).toBe(0);
  });

  it("owner demotes an admin; family-1 demotion clears users.is_admin", async () => {
    const f = await insertFamily();
    const o = await user([{ id: f, role: "admin" }]);
    await env.DB.prepare("UPDATE families SET created_by = ? WHERE id = ?").bind(o.userId, f).run();
    const a = await user([{ id: f, role: "admin" }]);
    await env.DB.prepare("UPDATE family_members SET admin_by = ?, admin_signer_pub = 'p', admin_sig = 's' WHERE user_id = ?").bind(o.userId, a.userId).run();
    const sa = await socket(a);
    expect((await demote(o, f, a.userId)).status).toBe(204);
    expect(await env.DB.prepare("SELECT role, admin_by, admin_signer_pub, admin_sig FROM family_members WHERE family_id = ? AND user_id = ?")
      .bind(f, a.userId).first()).toEqual({ role: "member", admin_by: null, admin_signer_pub: null, admin_sig: null });
    expect(await sa.next("family")).toEqual({ type: "family", familyId: f });

    const op = await insertUserWithDevice({ admin: true, operator: true });
    await env.DB.prepare("UPDATE families SET created_by = ? WHERE id = 1").bind(op.userId).run();
    const dad = await insertUserWithDevice({ admin: true });
    await env.DB.prepare("UPDATE users SET admin_by = ?, admin_signer_pub = 'p', admin_sig = 's' WHERE id = ?").bind(op.userId, dad.userId).run();
    expect((await demote(op, 1, dad.userId)).status).toBe(204);
    expect(await env.DB.prepare("SELECT is_admin, admin_by, admin_signer_pub, admin_sig FROM users WHERE id = ?").bind(dad.userId).first())
      .toEqual({ is_admin: 0, admin_by: null, admin_signer_pub: null, admin_sig: null });
    expect(await roleOf(1, dad.userId)).toBe("member");
  });

  it("non-owner admin can't demote (403)", async () => {
    const f = await insertFamily();
    const o = await user([{ id: f, role: "admin" }]);
    await env.DB.prepare("UPDATE families SET created_by = ? WHERE id = ?").bind(o.userId, f).run();
    const a = await user([{ id: f, role: "admin" }]);
    const b = await user([{ id: f, role: "admin" }]);
    expect((await demote(a, f, b.userId)).status).toBe(403);
    expect(await roleOf(f, b.userId)).toBe("admin");
  });

  it("owner can't be demoted (403)", async () => {
    const f = await insertFamily();
    const o = await user([{ id: f, role: "admin" }]);
    await env.DB.prepare("UPDATE families SET created_by = ? WHERE id = ?").bind(o.userId, f).run();
    expect((await demote(o, f, o.userId)).status).toBe(403);
    expect(await roleOf(f, o.userId)).toBe("admin");
  });

  it("demoting a plain member or an outsider is 404", async () => {
    const f = await insertFamily();
    const o = await user([{ id: f, role: "admin" }]);
    await env.DB.prepare("UPDATE families SET created_by = ? WHERE id = ?").bind(o.userId, f).run();
    const m = await user([{ id: f }]);
    const out = await user([{ id: 1 }]);
    expect((await demote(o, f, m.userId)).status).toBe(404);
    expect((await demote(o, f, out.userId)).status).toBe(404);
  });
});
