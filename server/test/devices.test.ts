import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { newId } from "../src/lib/ids";
import { BASE, makeKeys, redeemNewDevice, resetDb } from "./helpers";

const auth = (t: string) => ({ authorization: `Bearer ${t}` });
const list = (t: string) => SELF.fetch(`${BASE}/api/devices`, { headers: auth(t) });
const revoke = (t: string, id: string) => SELF.fetch(`${BASE}/api/devices/${id}`, { method: "DELETE", headers: auth(t) });

async function addDevice(userId: string, name = "Laptop") {
  const k = await makeKeys();
  const id = newId();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, name, platform, enc_pub, sign_pub, cert_sig, refresh_hash, push_token, created_at, last_seen)
     VALUES (?, ?, ?, 'linux', ?, ?, ?, ?, 'push-tok', 1, 2)`,
  ).bind(id, userId, name, k.encPub, k.signPub, k.certSig, `hash-${id}`).run();
  return id;
}

type DeviceOut = { id: string; name: string; platform: string; createdAt: number; lastSeen: number; current: boolean };

beforeEach(resetDb);

describe("GET /api/devices", () => {
  it("lists own devices only", async () => {
    const a = await redeemNewDevice({ name: "A" });
    const second = await addDevice(a.userId);
    const b = await redeemNewDevice({ name: "B" });
    const res = await list(a.accessToken);
    expect(res.status).toBe(200);
    const { devices } = await res.json<{ devices: DeviceOut[] }>();
    expect(devices.map((d) => d.id).sort()).toEqual([a.deviceId, second].sort());
    expect(devices.filter((d) => d.current).map((d) => d.id)).toEqual([a.deviceId]);
    expect(devices.find((d) => d.id === second)).toEqual({
      id: second, name: "Laptop", platform: "linux", createdAt: 1, lastSeen: 2, current: false,
    });
    expect(devices.some((d) => d.id === b.deviceId)).toBe(false);
  });

  it("requires auth", async () => {
    expect((await SELF.fetch(`${BASE}/api/devices`)).status).toBe(401);
  });
});

describe("DELETE /api/devices/:id", () => {
  it("revokes another own device", async () => {
    const a = await redeemNewDevice();
    const second = await addDevice(a.userId);
    expect((await revoke(a.accessToken, second)).status).toBe(204);
    const { devices } = await (await list(a.accessToken)).json<{ devices: DeviceOut[] }>();
    expect(devices.map((d) => d.id)).toEqual([a.deviceId]);
    const row = await env.DB.prepare("SELECT revoked_at, refresh_hash, push_token FROM devices WHERE id = ?")
      .bind(second).first<Record<string, unknown>>();
    expect(row?.revoked_at).toBeGreaterThan(0);
    expect(row?.refresh_hash).toBeNull();
    expect(row?.push_token).toBeNull();
  });

  it("revoked device access token rejected", async () => {
    const a = await redeemNewDevice();
    expect((await revoke(a.accessToken, a.deviceId)).status).toBe(204);
    expect((await list(a.accessToken)).status).toBe(401);
  });

  it("another user's device -> 404 and untouched", async () => {
    const a = await redeemNewDevice();
    const b = await redeemNewDevice();
    const res = await revoke(a.accessToken, b.deviceId);
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "not_found" });
    expect((await list(b.accessToken)).status).toBe(200);
  });

  it("unknown or already revoked id -> 404", async () => {
    const a = await redeemNewDevice();
    const second = await addDevice(a.userId);
    expect((await revoke(a.accessToken, "nope")).status).toBe(404);
    await revoke(a.accessToken, second);
    expect((await revoke(a.accessToken, second)).status).toBe(404);
  });
});
