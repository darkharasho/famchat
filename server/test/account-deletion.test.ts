import { env, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { sha256Hex } from "../src/lib/tokens";
import { addDevice, api, type ChatOut, createDirect, createGroup, insertMessage, type TestUser, wrapsFor } from "./chat-helpers";
import { BASE, insertFamily, insertInvite, insertUserWithDevice, jsonReq, joinFamily, resetDb } from "./helpers";
import { insertMedia, usage } from "./media-helpers";
import { closeSockets, socket } from "./ws-helpers";

beforeEach(resetDb);
afterEach(closeSockets);

const deleteMe = (u: TestUser, body: unknown = { confirm: "delete" }) => api(u.accessToken, "DELETE", "/me", body);
const removeUser = (admin: TestUser, userId: string) => api(admin.accessToken, "DELETE", `/admin/users/${userId}`);

type DirUser = { id: string; name: string; isAdmin: boolean; deleted: boolean; devices: { id: string; name: string; revoked: boolean }[] };
const directory = async (u: TestUser) => (await (await api(u.accessToken, "GET", "/users")).json<{ users: DirUser[] }>()).users;
const getChat = async (u: TestUser, id: string) => (await (await api(u.accessToken, "GET", `/chats/${id}`)).json<{ chat: ChatOut }>()).chat;

/** A family: admin Alice (the operator), members Bob and Carol; a group of all three and a direct Bob–Carol chat. */
async function family() {
  const alice = await insertUserWithDevice({ admin: true, operator: true, name: "Alice" });
  const bob = await insertUserWithDevice({ name: "Bob" });
  const carol = await insertUserWithDevice({ name: "Carol" });
  const group = await createGroup(alice, [bob, carol], "Family");
  const direct = await createDirect(bob, carol);
  return { alice, bob, carol, group, direct };
}

describe("DELETE /api/me", () => {
  it("needs auth", async () => {
    const res = await SELF.fetch(`${BASE}/api/me`, jsonReq("DELETE", { confirm: "delete" }));
    expect(res.status).toBe(401);
  });

  it("needs the explicit confirmation", async () => {
    const { bob } = await family();
    expect((await api(bob.accessToken, "DELETE", "/me")).status).toBe(400);
    for (const body of [{}, { confirm: "yes" }, { confirm: true }]) {
      expect((await deleteMe(bob, body)).status).toBe(400);
    }
    const row = await env.DB.prepare("SELECT name, deleted_at FROM users WHERE id = ?").bind(bob.userId).first();
    expect(row).toEqual({ name: "Bob", deleted_at: null });
  });

  it("deletes the account: profile, devices, chats, messages and media", async () => {
    const { alice, bob, carol, group, direct } = await family();
    const laptop = await addDevice(bob.userId);
    await env.DB.prepare("UPDATE devices SET push_token = 'tok', refresh_hash = 'h' || id WHERE user_id = ?").bind(bob.userId).run();
    const bobMsg = await insertMessage(group.id, bob);
    const bobDirect = await insertMessage(direct.id, bob);
    const carolMsg = await insertMessage(direct.id, carol);
    const bobPhoto = await insertMedia({ chatId: group.id, uploader: bob, bytes: 1000, createdAt: Date.now(), messageId: bobMsg });
    const carolPhoto = await insertMedia({ chatId: direct.id, uploader: carol, bytes: 500, createdAt: Date.now(), messageId: carolMsg });
    expect(await usage()).toBe(1500);

    expect((await deleteMe(bob)).status).toBe(204);

    const user = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(bob.userId).first<Record<string, unknown>>();
    expect(user).toMatchObject({ name: "Deleted user", is_admin: 0, recovery_pub: null, admin_sig: null });
    expect(user?.deleted_at).toBeTypeOf("number");
    const { results: devices } = await env.DB.prepare(
      "SELECT id, name, revoked_at, refresh_hash, prev_refresh_hash, push_token FROM devices WHERE user_id = ?",
    ).bind(bob.userId).all<Record<string, unknown>>();
    expect(devices).toHaveLength(2);
    for (const d of devices) {
      expect(d).toMatchObject({ name: "Deleted device", refresh_hash: null, prev_refresh_hash: null, push_token: null });
      expect(d.revoked_at).toBeTypeOf("number");
    }
    expect(devices.map((d) => d.id).sort()).toEqual([bob.deviceId, laptop].sort());

    // Out of every chat, which moved to a new epoch; the others' messages and media stay.
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM chat_members WHERE user_id = ?").bind(bob.userId).first("n")).toBe(0);
    for (const id of [group.id, direct.id]) {
      const c = await getChat(carol, id);
      expect(c.currentEpoch).toBe(2);
      expect(c.epochReady).toBe(false);
      expect(c.members.map((m) => m.userId)).not.toContain(bob.userId);
    }
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM chat_key_wraps WHERE device_id = ?").bind(bob.deviceId).first("n")).toBe(0);
    const { results: msgs } = await env.DB.prepare("SELECT id FROM messages").all<{ id: string }>();
    expect(msgs.map((m) => m.id)).toEqual([carolMsg]);
    expect(msgs.map((m) => m.id)).not.toContain(bobDirect);
    const { results: media } = await env.DB.prepare("SELECT key FROM media").all<{ key: string }>();
    expect(media.map((m) => m.key)).toEqual([carolPhoto]);
    expect(await env.MEDIA.head(bobPhoto)).toBeNull();
    expect(await env.MEDIA.head(carolPhoto)).not.toBeNull();
    expect(await usage()).toBe(500);

    // Signed out: the old access token and refresh token no longer work.
    expect((await api(bob.accessToken, "GET", "/me")).status).toBe(401);
    // The directory keeps the row (old certificates still verify), anonymized.
    const dir = await directory(alice);
    const b = dir.find((u) => u.id === bob.userId)!;
    expect(b).toMatchObject({ name: "Deleted user", isAdmin: false, deleted: true });
    expect(b.devices.every((d) => d.revoked && d.name === "Deleted device")).toBe(true);
    expect(dir.find((u) => u.id === alice.userId)?.deleted).toBe(false);

    const ev = await env.DB.prepare("SELECT * FROM events WHERE kind = 'account_deleted'").first<Record<string, unknown>>();
    expect(ev).toMatchObject({ user_id: bob.userId, actor_id: bob.userId });
    expect(JSON.parse(ev?.payload as string)).toEqual({ by: "self" });
  });

  it("the remaining members create the next epoch without the deleted user", async () => {
    const { alice, bob, carol, group } = await family();
    await deleteMe(bob);
    const withBob = wrapsFor(group.id, 2, alice.deviceId, [alice.deviceId, carol.deviceId, bob.deviceId]);
    expect((await api(alice.accessToken, "POST", `/chats/${group.id}/epochs`, { epoch: 2, wraps: withBob })).status).toBe(409);
    const wraps = wrapsFor(group.id, 2, alice.deviceId, [alice.deviceId, carol.deviceId]);
    expect((await api(alice.accessToken, "POST", `/chats/${group.id}/epochs`, { epoch: 2, wraps })).status).toBe(201);
  });

  it("notifies members: chat, device revoked, media gone, account deleted", async () => {
    const { alice, bob, carol, group, direct } = await family();
    const msg = await insertMessage(group.id, bob);
    const photo = await insertMedia({ chatId: group.id, uploader: bob, bytes: 10, createdAt: Date.now(), messageId: msg });
    const carolWs = await socket(carol);
    const aliceWs = await socket(alice);
    expect((await deleteMe(bob)).status).toBe(204);
    const chats = [await carolWs.next("chat"), await carolWs.next("chat")].map((e) => e.chatId).sort();
    expect(chats).toEqual([group.id, direct.id].sort());
    expect(await carolWs.next("device")).toEqual({ type: "device", userId: bob.userId, deviceId: bob.deviceId, revoked: true });
    expect(await carolWs.next("media_expired")).toEqual({ type: "media_expired", chatId: group.id, keys: [photo] });
    expect(await carolWs.next("account_deleted")).toEqual({ type: "account_deleted", userId: bob.userId });
    expect(await aliceWs.next("account_deleted")).toEqual({ type: "account_deleted", userId: bob.userId });
  });

  it("closes the deleted user's sockets", async () => {
    const { bob } = await family();
    const t = await (await api(bob.accessToken, "POST", "/ws/ticket")).json<{ ticket: string }>();
    const res = await SELF.fetch(`${BASE}/api/ws?ticket=${encodeURIComponent(t.ticket)}`, { headers: { upgrade: "websocket" } });
    const ws = res.webSocket!;
    const closed = new Promise<number>((resolve) => ws.addEventListener("close", (e) => {
      resolve(e.code);
    }));
    ws.accept();
    await deleteMe(bob);
    expect(await closed).toBe(4001);
  });

  it("stops the invites they made", async () => {
    const { alice, bob } = await family();
    const token = await insertInvite({ name: "Dan" }); // made by the first user, Alice
    await env.DB.prepare("UPDATE users SET is_admin = 1 WHERE id = ?").bind(bob.userId).run();
    await env.DB.prepare("UPDATE family_members SET role = 'admin' WHERE user_id = ? AND family_id = 1").bind(bob.userId).run();
    expect((await deleteMe(alice)).status).toBe(204);
    const expires = await env.DB.prepare("SELECT expires_at FROM invites WHERE token_hash = ?").bind(await sha256Hex(token))
      .first<number>("expires_at");
    expect(expires).toBeLessThanOrEqual(Date.now());
  });

  it("can't be done twice, and a deleted user can't be reset, promoted or added", async () => {
    const { alice, bob, carol, group } = await family();
    const bobId = bob.userId;
    await deleteMe(bob);
    expect((await removeUser(alice, bobId)).status).toBe(404);
    expect((await api(alice.accessToken, "POST", `/admin/users/${bobId}/admin`, { sig: "A".repeat(86) })).status).toBe(400);
    expect(await env.DB.prepare("SELECT is_admin FROM users WHERE id = ?").bind(bobId).first("is_admin")).toBe(0);
    const add = await api(alice.accessToken, "POST", `/chats/${group.id}/members`, { userIds: [bobId], wraps: [] });
    expect(add.status).toBe(400);
    const direct = await api(alice.accessToken, "POST", "/chats", { id: "01J00000000000000000000000", kind: "direct", userId: bobId, wraps: [] });
    expect(direct.status).toBe(400);
  });
});

describe("last admin guard", () => {
  it("the only admin can't delete their account while others are in the family", async () => {
    const { alice } = await family();
    const res = await deleteMe(alice);
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: "last_admin", familyId: 1, familyName: "Family" });
    expect(await env.DB.prepare("SELECT deleted_at FROM users WHERE id = ?").bind(alice.userId).first("deleted_at")).toBeNull();
    expect((await api(alice.accessToken, "GET", "/me")).status).toBe(200);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM events").first("n")).toBe(0);
  });

  it("an admin can go once there is another admin", async () => {
    const { alice, bob } = await family();
    await env.DB.prepare("UPDATE users SET is_admin = 1 WHERE id = ?").bind(bob.userId).run();
    await env.DB.prepare("UPDATE family_members SET role = 'admin' WHERE user_id = ? AND family_id = 1").bind(bob.userId).run();
    expect((await deleteMe(alice)).status).toBe(204);
    expect((await api(bob.accessToken, "GET", "/me")).status).toBe(200);
  });

  it("last_admin is per family and names the family", async () => {
    const a = await insertUserWithDevice({ name: "A", families: [{ id: 1 }] });
    const b = await insertUserWithDevice({ name: "B", families: [{ id: 1 }] });
    const cousins = await insertFamily({ name: "Cousins" });
    expect(cousins).toBe(3);
    await joinFamily(a.userId, cousins, "admin");
    await joinFamily(b.userId, cousins, "member");
    const res = await deleteMe(a);
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: "last_admin", familyId: 3, familyName: "Cousins" });
    // A deleted member doesn't count: once B is gone, A may go.
    expect((await deleteMe(b)).status).toBe(204);
    expect((await deleteMe(a)).status).toBe(204);
  });

  it("a second admin frees the first", async () => {
    const a = await insertUserWithDevice({ name: "A", families: [{ id: 1 }] });
    const b = await insertUserWithDevice({ name: "B", families: [{ id: 1 }] });
    const f = await insertFamily({ name: "Cousins" });
    await joinFamily(a.userId, f, "admin");
    await joinFamily(b.userId, f, "admin");
    expect((await deleteMe(a)).status).toBe(204);
  });

  it("a deleted account stays in its families as a member and is no longer operator", async () => {
    const op = await insertUserWithDevice({ admin: true, operator: true, name: "Op" });
    const f = await insertFamily({ name: "Cousins" });
    await joinFamily(op.userId, f, "admin");
    await env.DB.prepare(
      "UPDATE family_members SET admin_by = ?, admin_signer_pub = 'p', admin_sig = 's' WHERE user_id = ?",
    ).bind(op.userId, op.userId).run();
    expect((await deleteMe(op)).status).toBe(204);
    const rows = (await env.DB.prepare(
      "SELECT family_id, role, admin_by, admin_signer_pub, admin_sig FROM family_members WHERE user_id = ? ORDER BY family_id",
    ).bind(op.userId).all()).results;
    expect(rows).toEqual([
      { family_id: 1, role: "member", admin_by: null, admin_signer_pub: null, admin_sig: null },
      { family_id: f, role: "member", admin_by: null, admin_signer_pub: null, admin_sig: null },
    ]);
    expect(await env.DB.prepare("SELECT operator FROM users WHERE id = ?").bind(op.userId).first("operator")).toBe(0);
  });

  it("the last person in the family can delete their account, and the family can start again", async () => {
    const alice = await insertUserWithDevice({ admin: true, name: "Alice" });
    expect((await deleteMe(alice)).status).toBe(204);
    const res = await SELF.fetch(
      `${BASE}/api/admin/bootstrap`,
      jsonReq("POST", { name: "Alice" }, { authorization: "Bearer test-bootstrap-secret" }),
    );
    expect(res.status).toBe(201);
  });
});

describe("DELETE /api/admin/users/:id", () => {
  it("is admin only", async () => {
    const { bob, carol } = await family();
    const res = await removeUser(bob, carol.userId);
    expect(res.status).toBe(403);
    expect(await env.DB.prepare("SELECT deleted_at FROM users WHERE id = ?").bind(carol.userId).first("deleted_at")).toBeNull();
  });

  it("only the operator deletes someone else's account", async () => {
    const { alice, carol } = await family();
    const dave = await insertUserWithDevice({ admin: true, name: "Dave" });
    expect((await removeUser(dave, carol.userId)).status).toBe(403);
    expect(await env.DB.prepare("SELECT deleted_at FROM users WHERE id = ?").bind(carol.userId).first("deleted_at")).toBeNull();
    expect((await removeUser(alice, carol.userId)).status).toBe(204);
  });

  it("needs auth", async () => {
    const { carol } = await family();
    expect((await SELF.fetch(`${BASE}/api/admin/users/${carol.userId}`, { method: "DELETE" })).status).toBe(401);
  });

  it("not yourself, not someone unknown", async () => {
    const { alice } = await family();
    expect((await removeUser(alice, alice.userId)).status).toBe(400);
    expect((await removeUser(alice, "01J00000000000000000000000")).status).toBe(404);
  });

  it("removes a member the same way", async () => {
    const { alice, bob, carol, group } = await family();
    const msg = await insertMessage(group.id, carol);
    const photo = await insertMedia({ chatId: group.id, uploader: carol, bytes: 10, createdAt: Date.now(), messageId: msg });
    const bobWs = await socket(bob);
    expect((await removeUser(alice, carol.userId)).status).toBe(204);
    expect((await api(carol.accessToken, "GET", "/me")).status).toBe(401);
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM messages WHERE sender_user_id = ?").bind(carol.userId).first("n")).toBe(0);
    expect(await env.MEDIA.head(photo)).toBeNull();
    expect((await getChat(bob, group.id)).members.map((m) => m.userId).sort()).toEqual([alice.userId, bob.userId].sort());
    expect(await bobWs.next("account_deleted")).toEqual({ type: "account_deleted", userId: carol.userId });
    const ev = await env.DB.prepare("SELECT * FROM events WHERE kind = 'account_deleted'").first<Record<string, unknown>>();
    expect(ev).toMatchObject({ user_id: carol.userId, actor_id: alice.userId });
    expect(JSON.parse(ev?.payload as string)).toEqual({ by: "admin" });
  });

  it("can remove another admin", async () => {
    const { alice, bob } = await family();
    await env.DB.prepare("UPDATE users SET is_admin = 1 WHERE id = ?").bind(bob.userId).run();
    expect((await removeUser(alice, bob.userId)).status).toBe(204);
    expect((await directory(alice)).find((u) => u.id === bob.userId)).toMatchObject({ isAdmin: false, deleted: true });
  });
});
