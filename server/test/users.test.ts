import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { api, addDevice, createDirect, createGroup } from "./chat-helpers";
import { BASE, insertFamily, insertUserWithDevice, joinFamily, resetDb } from "./helpers";

beforeEach(resetDb);

type UserOut = {
  id: string;
  name: string;
  isAdmin: boolean;
  identityPub: string;
  adminProof: { byUserId: string | null; signerPub: string; sig: string } | null;
  deleted: boolean;
  former: boolean;
  families: { id: number; role: string; adminProof: unknown }[];
  resets: unknown[];
  devices: { id: string; name: string; platform: string; encPub: string; signPub: string; certSig: string; revoked: boolean }[];
};

const dir = async (u: { accessToken: string }) =>
  (await (await api(u.accessToken, "GET", "/users")).json<{ users: UserOut[] }>()).users;

describe("GET /api/users", () => {
  it("lists every user with devices", async () => {
    const a = await insertUserWithDevice({ name: "Mom", admin: true });
    const b = await insertUserWithDevice({ name: "Kid" });
    const old = await addDevice(b.userId);
    await env.DB.prepare("UPDATE devices SET revoked_at = 5 WHERE id = ?").bind(old).run();
    const res = await api(a.accessToken, "GET", "/users");
    expect(res.status).toBe(200);
    const { users } = await res.json<{ users: UserOut[] }>();
    expect(users.map((u) => u.name).sort()).toEqual(["Kid", "Mom"]);
    const kid = users.find((u) => u.id === b.userId)!;
    expect(kid.isAdmin).toBe(false);
    expect(kid.identityPub).toBe(b.keys.identityPub);
    const live = kid.devices.find((d) => d.id === b.deviceId)!;
    expect(live).toEqual({
      id: b.deviceId, name: "Phone", platform: "android",
      encPub: b.keys.encPub, signPub: b.keys.signPub, certSig: b.keys.certSig, revoked: false,
    });
    expect(kid.devices.find((d) => d.id === old)!.revoked).toBe(true);
    expect(users.find((u) => u.id === a.userId)!.isAdmin).toBe(true);
  });

  it("lists only the caller and people sharing a family with them", async () => {
    const f3 = await insertFamily();
    const a = await insertUserWithDevice({ name: "A", families: [{ id: 1 }] });
    const b = await insertUserWithDevice({ name: "B", families: [{ id: 1 }] });
    const c = await insertUserWithDevice({ name: "C", families: [{ id: f3 }] });
    expect((await dir(a)).map((u) => u.name).sort()).toEqual(["A", "B"]);
    expect((await dir(c)).map((u) => u.name)).toEqual(["C"]);
  });

  it("a deleted account is still listed to its family", async () => {
    const f3 = await insertFamily();
    const a = await insertUserWithDevice({ name: "A", families: [{ id: 1 }] });
    const gone = await insertUserWithDevice({ name: "Gone", families: [{ id: 1 }] });
    const c = await insertUserWithDevice({ name: "C", families: [{ id: f3 }] });
    await env.DB.prepare("UPDATE users SET deleted_at = 5 WHERE id = ?").bind(gone.userId).run();
    expect((await dir(a)).find((u) => u.id === gone.userId)!.deleted).toBe(true);
    expect((await dir(c)).map((u) => u.id)).toEqual([c.userId]);
  });

  it("families lists only the families shared with the caller", async () => {
    const f3 = await insertFamily();
    const f4 = await insertFamily();
    const a = await insertUserWithDevice({ families: [{ id: 1 }, { id: f3, role: "admin" }] });
    const b = await insertUserWithDevice({ families: [{ id: 1 }, { id: f3 }] });
    const c = await insertUserWithDevice({ families: [{ id: f3 }, { id: f4 }] });
    const users = await dir(a);
    expect(users.find((u) => u.id === c.userId)!.families).toEqual([{ id: f3, role: "member", adminProof: null }]);
    expect(users.find((u) => u.id === b.userId)!.families.map((f) => f.id).sort()).toEqual([1, f3].sort());
    const mine = users.find((u) => u.id === a.userId)!.families;
    expect(mine.map((f) => f.id).sort()).toEqual([1, f3].sort());
    expect(mine.find((f) => f.id === f3)!.role).toBe("admin");
    expect(JSON.stringify(users)).not.toContain(`"id":${f4}`);
  });

  it("isAdmin and adminProof describe family #1, and only to family #1", async () => {
    const f3 = await insertFamily();
    const boss = await insertUserWithDevice({ admin: true, families: [{ id: 1, role: "admin" }, { id: f3 }] });
    await env.DB.prepare(
      "UPDATE family_members SET admin_by = ?, admin_signer_pub = 'sp', admin_sig = 'sg' WHERE user_id = ? AND family_id = 1",
    ).bind(boss.userId, boss.userId).run();
    const mate = await insertUserWithDevice({ families: [{ id: 1 }] });
    const outsider = await insertUserWithDevice({ families: [{ id: f3 }] });
    const seenByMate = (await dir(mate)).find((u) => u.id === boss.userId)!;
    expect(seenByMate.isAdmin).toBe(true);
    expect(seenByMate.adminProof).toEqual({ byUserId: boss.userId, signerPub: "sp", sig: "sg" });
    expect(seenByMate.families.find((f) => f.id === 1)).toEqual({
      id: 1, role: "admin", adminProof: { byUserId: boss.userId, signerPub: "sp", sig: "sg" },
    });
    const seenByOutsider = (await dir(outsider)).find((u) => u.id === boss.userId)!;
    expect(seenByOutsider.isAdmin).toBe(false);
    expect(seenByOutsider.adminProof).toBeNull();
    expect(seenByOutsider.families).toEqual([{ id: f3, role: "member", adminProof: null }]);
  });

  it("people sharing only a chat come back as former", async () => {
    const f3 = await insertFamily();
    const a = await insertUserWithDevice({ name: "A", families: [{ id: 1 }, { id: f3 }] });
    const b = await insertUserWithDevice({ name: "B", families: [{ id: f3 }] });
    await createDirect(a, b);
    expect((await dir(a)).find((u) => u.id === b.userId)!.former).toBe(false);
    await env.DB.prepare("DELETE FROM family_members WHERE user_id = ?").bind(b.userId).run();
    await joinFamily(b.userId, await insertFamily());
    for (const [viewer, other] of [[a, b], [b, a]] as const) {
      const seen = (await dir(viewer)).find((u) => u.id === other.userId)!;
      expect(seen).toMatchObject({ former: true, isAdmin: false, adminProof: null, families: [] });
      expect(seen.devices).toHaveLength(1);
      expect(seen.resets).toEqual([]);
    }
    const self = (await dir(a)).find((u) => u.id === a.userId)!;
    expect(self.former).toBe(false);
  });

  it("a group leaver outside your families is former", async () => {
    const a = await insertUserWithDevice({ name: "A" });
    const b = await insertUserWithDevice({ name: "B" });
    const chat = await createGroup(a, [b]);
    await env.DB.prepare("DELETE FROM chat_members WHERE chat_id = ? AND user_id = ?").bind(chat.id, b.userId).run();
    await env.DB.prepare("INSERT INTO chat_leavers (chat_id, user_id, left_at) VALUES (?, ?, 1)").bind(chat.id, b.userId).run();
    await env.DB.prepare("DELETE FROM family_members WHERE user_id = ?").bind(b.userId).run();
    const seen = (await dir(a)).find((u) => u.id === b.userId)!;
    expect(seen.former).toBe(true);
    expect(seen.families).toEqual([]);
    // Never a stranger: someone who left a chat of someone else's stays hidden.
    const c = await insertUserWithDevice({ name: "C", families: [{ id: await insertFamily() }] });
    expect((await dir(c)).map((u) => u.id)).toEqual([c.userId]);
  });

  it("requires auth", async () => {
    expect((await SELF.fetch(`${BASE}/api/users`)).status).toBe(401);
  });
});
