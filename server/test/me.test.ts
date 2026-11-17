import { createExecutionContext, env, SELF } from "cloudflare:test";
import { app } from "../src/index";
import { beforeEach, describe, expect, it } from "vitest";
import { BASE, insertUserWithDevice, resetDb } from "./helpers";

const me = (token?: string) =>
  SELF.fetch(`${BASE}/api/me`, { headers: token ? { authorization: `Bearer ${token}` } : {} });

beforeEach(resetDb);

describe("GET /api/me", () => {
  it("returns own profile", async () => {
    const u = await insertUserWithDevice({ admin: true, name: "Mom" });
    const res = await me(u.accessToken);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ userId: u.userId, deviceId: u.deviceId, name: "Mom", isAdmin: true, recoveryCodeSet: false, reviewer: false, gifKey: null });
  });

  it("hands out the KLIPY app key when the server has one (the app calls KLIPY itself)", async () => {
    const u = await insertUserWithDevice();
    const res = await app.fetch(
      new Request(`${BASE}/api/me`, { headers: { authorization: `Bearer ${u.accessToken}` } }),
      { ...env, KLIPY_APP_KEY: "klipy-key" },
      createExecutionContext(),
    );
    expect((await res.json<{ gifKey: string | null }>()).gifKey).toBe("klipy-key");
  });

  it("reads isAdmin from the database, not the token", async () => {
    const u = await insertUserWithDevice({ name: "Dad" });
    await env.DB.prepare("UPDATE users SET is_admin = 1 WHERE id = ?").bind(u.userId).run();
    expect((await (await me(u.accessToken)).json<{ isAdmin: boolean }>()).isAdmin).toBe(true);
  });

  it("requires auth", async () => {
    expect((await me()).status).toBe(401);
  });

  it("revoked device is rejected", async () => {
    const u = await insertUserWithDevice();
    await env.DB.prepare("UPDATE devices SET revoked_at = 1 WHERE id = ?").bind(u.deviceId).run();
    expect((await me(u.accessToken)).status).toBe(401);
  });
});
