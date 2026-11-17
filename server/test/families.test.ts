import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { api } from "./chat-helpers";
import { errorResponse } from "../src/lib/errors";
import { familyPeers, groupFamilyFor, sharingUserIds, shares } from "../src/lib/family";
import { insertFamily, insertUserWithDevice, joinFamily, resetDb } from "./helpers";
import { promotionMessage, promotionMessageV2 } from "../src/lib/reset";
import { sign } from "./reset-helpers";
import { socket, closeSockets } from "./ws-helpers";

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
  type FamilyOut = { id: number; name: string; status: string; role: string; memberCount: number; owner: boolean; createdAt: number };
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
