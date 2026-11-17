import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { api } from "./chat-helpers";
import { errorResponse } from "../src/lib/errors";
import { familyPeers, groupFamilyFor, sharingUserIds, shares } from "../src/lib/family";
import { insertFamily, insertUserWithDevice, resetDb } from "./helpers";

beforeEach(resetDb);

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
