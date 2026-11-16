import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { addDevice, api, createGroup, fakeWrap, type WrapJson } from "./chat-helpers";
import { insertUserWithDevice, resetDb } from "./helpers";

beforeEach(resetDb);

describe("GET /api/keys/wraps", () => {
  it("returns only wraps for my device", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    const other = await createGroup(a, [await insertUserWithDevice()]);
    const res = await api(b.accessToken, "GET", "/keys/wraps");
    expect(res.status).toBe(200);
    const { wraps } = await res.json<{ wraps: WrapJson[] }>();
    expect(wraps).toHaveLength(1);
    expect(wraps[0]).toMatchObject({ chatId: chat.id, epoch: 1, recipientDeviceId: b.deviceId, wrapperDeviceId: a.deviceId });
    const filtered = await (await api(a.accessToken, "GET", `/keys/wraps?chatId=${other.id}`)).json<{ wraps: WrapJson[] }>();
    expect(filtered.wraps.map((w) => w.chatId)).toEqual([other.id]);
  });

  it("hides wraps of chats I left", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    await api(b.accessToken, "DELETE", `/chats/${chat.id}/members/${b.userId}`);
    expect((await (await api(b.accessToken, "GET", "/keys/wraps")).json<{ wraps: WrapJson[] }>()).wraps).toEqual([]);
  });
});

describe("PUT /api/keys/wraps and GET /api/keys/missing", () => {
  it("repairs wraps for a member's new device; first wrap wins", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    const b2 = await addDevice(b.userId);
    const missing = await (await api(a.accessToken, "GET", "/keys/missing")).json<{ missing: unknown[] }>();
    expect(missing.missing).toEqual([{ chatId: chat.id, epoch: 1, deviceId: b2 }]);
    const w = fakeWrap(chat.id, 1, b2, a.deviceId);
    const res = await api(a.accessToken, "PUT", "/keys/wraps", { wraps: [w] });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ added: 1 });
    const again = await api(b.accessToken, "PUT", "/keys/wraps", { wraps: [fakeWrap(chat.id, 1, b2, b.deviceId)] });
    expect(await again.json()).toEqual({ added: 0 });
    const row = await env.DB.prepare("SELECT sealed FROM chat_key_wraps WHERE device_id = ?").bind(b2).first<string>("sealed");
    expect(row).toBe(w.sealed);
    expect((await (await api(a.accessToken, "GET", "/keys/missing")).json<{ missing: unknown[] }>()).missing).toEqual([]);
  });

  it("refuses a wrap for a non-member device", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    expect((await api(a.accessToken, "PUT", "/keys/wraps", { wraps: [fakeWrap(chat.id, 1, c.deviceId, a.deviceId)] })).status).toBe(400);
  });

  it("refuses a wrapper other than the caller, unknown epochs and non-members", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const c = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    const b2 = await addDevice(b.userId);
    expect((await api(a.accessToken, "PUT", "/keys/wraps", { wraps: [fakeWrap(chat.id, 1, b2, b.deviceId)] })).status).toBe(400);
    expect((await api(a.accessToken, "PUT", "/keys/wraps", { wraps: [fakeWrap(chat.id, 2, b2, a.deviceId)] })).status).toBe(400);
    expect((await api(c.accessToken, "PUT", "/keys/wraps", { wraps: [fakeWrap(chat.id, 1, b2, c.deviceId)] })).status).toBe(400);
    expect((await api(a.accessToken, "PUT", "/keys/wraps", { wraps: [] })).status).toBe(400);
  });

  it("missing only lists epochs I hold", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    const chat = await createGroup(a, [b]);
    const b2 = await addDevice(b.userId);
    // Device b2 has no wraps, so it can't repair anything for anyone.
    await env.DB.prepare("DELETE FROM chat_key_wraps WHERE device_id = ?").bind(a.deviceId).run();
    const asA = await (await api(a.accessToken, "GET", "/keys/missing")).json<{ missing: unknown[] }>();
    expect(asA.missing).toEqual([]);
    const asB = await (await api(b.accessToken, "GET", "/keys/missing")).json<{ missing: { deviceId: string }[] }>();
    expect(asB.missing.map((m) => m.deviceId).sort()).toEqual([a.deviceId, b2].sort());
    void chat;
  });
});
