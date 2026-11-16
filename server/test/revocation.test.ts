import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { addDevice, api, type ChatOut, createDirect, createGroup, fakeWrap, type WrapJson } from "./chat-helpers";
import { insertUserWithDevice, resetDb } from "./helpers";
import { closeSockets, socket } from "./ws-helpers";

beforeEach(resetDb);
afterEach(closeSockets);

const getChat = async (token: string, id: string) =>
  (await (await api(token, "GET", `/chats/${id}`)).json<{ chat: ChatOut }>()).chat;

describe("DELETE /api/devices/:id rotates chat keys", () => {
  it("revocation bumps every chat of the user", async () => {
    const alice = await insertUserWithDevice({ name: "Alice" });
    const bob = await insertUserWithDevice({ name: "Bob" });
    const carol = await insertUserWithDevice({ name: "Carol" });
    const direct = await createDirect(alice, bob);
    const laptop = await addDevice(alice.userId);
    const group = await createGroup(alice, [bob, carol], "Family", [laptop]);
    const others = await createGroup(bob, [carol], "Not Alice");

    expect((await api(alice.accessToken, "DELETE", `/devices/${laptop}`)).status).toBe(204);

    for (const id of [direct.id, group.id]) {
      const c = await getChat(alice.accessToken, id);
      expect(c.currentEpoch).toBe(2);
      expect(c.epochReady).toBe(false);
    }
    const untouched = await getChat(bob.accessToken, others.id);
    expect(untouched.currentEpoch).toBe(1);
    expect(untouched.epochReady).toBe(true);
  });

  it("revocation notifies members with chat and device events", async () => {
    const alice = await insertUserWithDevice({ name: "Alice" });
    const bob = await insertUserWithDevice({ name: "Bob" });
    const direct = await createDirect(alice, bob);
    const laptop = await addDevice(alice.userId);
    const bobWs = await socket(bob);
    await api(alice.accessToken, "DELETE", `/devices/${laptop}`);
    expect(await bobWs.next("chat")).toEqual({ type: "chat", chatId: direct.id });
    expect(await bobWs.next("device")).toEqual({ type: "device", userId: alice.userId, deviceId: laptop, revoked: true });
  });

  it("revoking twice bumps once", async () => {
    const alice = await insertUserWithDevice();
    const bob = await insertUserWithDevice();
    const direct = await createDirect(alice, bob);
    const laptop = await addDevice(alice.userId);
    await api(alice.accessToken, "DELETE", `/devices/${laptop}`);
    expect((await api(alice.accessToken, "DELETE", `/devices/${laptop}`)).status).toBe(404);
    expect((await getChat(alice.accessToken, direct.id)).currentEpoch).toBe(2);
  });

  it("the next epoch is created without the revoked device", async () => {
    const alice = await insertUserWithDevice();
    const bob = await insertUserWithDevice();
    const direct = await createDirect(alice, bob);
    const laptop = await addDevice(alice.userId);
    await api(alice.accessToken, "DELETE", `/devices/${laptop}`);
    const withLaptop = [alice.deviceId, bob.deviceId, laptop].map((d) => fakeWrap(direct.id, 2, d, bob.deviceId));
    expect((await api(bob.accessToken, "POST", `/chats/${direct.id}/epochs`, { epoch: 2, wraps: withLaptop })).status).toBe(409);
    const wraps = [alice.deviceId, bob.deviceId].map((d) => fakeWrap(direct.id, 2, d, bob.deviceId));
    expect((await api(bob.accessToken, "POST", `/chats/${direct.id}/epochs`, { epoch: 2, wraps })).status).toBe(201);
  });
});

describe("wraps made by a revoked device", () => {
  async function setup() {
    const alice = await insertUserWithDevice({ name: "Alice" });
    const bob = await insertUserWithDevice({ name: "Bob" });
    const laptop = await addDevice(alice.userId);
    const group = await createGroup(alice, [bob], "Family", [laptop]);
    // Bob's tablet got its epoch-1 wrap from Alice's laptop (repair), which is then revoked.
    const tablet = await addDevice(bob.userId);
    const w = fakeWrap(group.id, 1, tablet, laptop);
    await env.DB.prepare(
      `INSERT INTO chat_key_wraps (chat_id, epoch, device_id, wrapper_device_id, sealed, sig, created_at) VALUES (?, ?, ?, ?, ?, ?, 1)`,
    ).bind(w.chatId, w.epoch, w.recipientDeviceId, w.wrapperDeviceId, w.sealed, w.sig).run();
    await env.DB.prepare("UPDATE devices SET revoked_at = 1 WHERE id = ?").bind(laptop).run();
    return { alice, bob, laptop, group, tablet };
  }

  it("missing lists devices whose wrap came from a revoked device", async () => {
    const { alice, group, tablet } = await setup();
    const { missing } = await (await api(alice.accessToken, "GET", "/keys/missing")).json<{ missing: unknown[] }>();
    expect(missing).toContainEqual({ chatId: group.id, epoch: 1, deviceId: tablet });
  });

  it("PUT replaces a wrap made by a revoked device", async () => {
    const { alice, group, tablet } = await setup();
    const repl: WrapJson = fakeWrap(group.id, 1, tablet, alice.deviceId);
    const res = await api(alice.accessToken, "PUT", "/keys/wraps", { wraps: [repl] });
    expect(await res.json()).toEqual({ added: 1 });
    const row = await env.DB.prepare("SELECT wrapper_device_id FROM chat_key_wraps WHERE chat_id = ? AND epoch = 1 AND device_id = ?")
      .bind(group.id, tablet).first<string>("wrapper_device_id");
    expect(row).toBe(alice.deviceId);
  });
});
