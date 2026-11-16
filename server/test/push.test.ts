import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { BASE, insertUserWithDevice, jsonReq, resetDb } from "./helpers";

const auth = (t: string) => ({ authorization: `Bearer ${t}` });
const setToken = (t: string, token: unknown) =>
  SELF.fetch(`${BASE}/api/devices/me/push`, jsonReq("PUT", { token }, auth(t)));
const tokenOf = async (deviceId: string) =>
  (await env.DB.prepare("SELECT push_token FROM devices WHERE id = ?").bind(deviceId).first<{ push_token: string | null }>())
    ?.push_token ?? null;

beforeEach(resetDb);

describe("PUT /api/devices/me/push", () => {
  it("stores, replaces and clears this device's token", async () => {
    const a = await insertUserWithDevice();
    expect((await setToken(a.accessToken, "tok-1")).status).toBe(204);
    expect(await tokenOf(a.deviceId)).toBe("tok-1");
    expect((await setToken(a.accessToken, "tok-2")).status).toBe(204);
    expect(await tokenOf(a.deviceId)).toBe("tok-2");
    expect((await setToken(a.accessToken, null)).status).toBe(204);
    expect(await tokenOf(a.deviceId)).toBeNull();
  });

  it("moves a token that another device row had", async () => {
    const a = await insertUserWithDevice();
    const b = await insertUserWithDevice();
    await setToken(a.accessToken, "shared");
    await setToken(b.accessToken, "shared");
    expect(await tokenOf(a.deviceId)).toBeNull();
    expect(await tokenOf(b.deviceId)).toBe("shared");
  });

  it("rejects bad bodies", async () => {
    const a = await insertUserWithDevice();
    for (const bad of [42, "", "x".repeat(4097), { t: 1 }]) {
      expect((await setToken(a.accessToken, bad)).status).toBe(400);
    }
    const res = await SELF.fetch(`${BASE}/api/devices/me/push`, { method: "PUT", headers: auth(a.accessToken), body: "nope" });
    expect(res.status).toBe(400);
  });

  it("requires auth", async () => {
    const res = await SELF.fetch(`${BASE}/api/devices/me/push`, jsonReq("PUT", { token: "x" }));
    expect(res.status).toBe(401);
  });
});
