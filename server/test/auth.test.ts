import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { sha256Hex, verifyAccessToken } from "../src/lib/tokens";
import { BASE, insertInvite, insertUserWithDevice, jsonReq, makeKeys, redeemBody, resetDb } from "./helpers";

const redeem = (body: unknown) => SELF.fetch(`${BASE}/api/auth/invite/redeem`, jsonReq("POST", body));
const count = (table: string) => env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table}`).first<number>("n");

beforeEach(resetDb);

describe("POST /api/auth/invite/redeem", () => {
  it("creates user and device", async () => {
    const token = await insertInvite({ name: "Mom" });
    const keys = await makeKeys();
    const res = await redeem(await redeemBody(token, keys));
    expect(res.status).toBe(201);
    const body = await res.json<{ userId: string; deviceId: string; isAdmin: boolean; accessToken: string; refreshToken: string }>();
    expect(body.isAdmin).toBe(false);
    expect(await verifyAccessToken(env, body.accessToken)).toEqual({ sub: body.userId, dev: body.deviceId, adm: false });

    const user = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(body.userId).first<Record<string, unknown>>();
    expect(user).toMatchObject({ name: "Mom", is_admin: 0, identity_pub: keys.identityPub });
    const dev = await env.DB.prepare("SELECT * FROM devices WHERE id = ?").bind(body.deviceId).first<Record<string, unknown>>();
    expect(dev).toMatchObject({
      user_id: body.userId, name: "Pixel", platform: "android",
      enc_pub: keys.encPub, sign_pub: keys.signPub, cert_sig: keys.certSig,
      refresh_hash: await sha256Hex(body.refreshToken), revoked_at: null,
    });
    const inv = await env.DB.prepare("SELECT used_by FROM invites").first<string>("used_by");
    expect(inv).toBe(body.userId);
  });

  it("admin invite makes an admin", async () => {
    const token = await insertInvite({ admin: true });
    const body = await (await redeem(await redeemBody(token))).json<{ userId: string; isAdmin: boolean }>();
    expect(body.isAdmin).toBe(true);
    const adm = await env.DB.prepare("SELECT is_admin FROM users WHERE id = ?").bind(body.userId).first<number>("is_admin");
    expect(adm).toBe(1);
  });

  it("a normal invite joins its family as member, or admin when make_admin", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const make = async (name: string) =>
      (await (await SELF.fetch(`${BASE}/api/admin/invites`, jsonReq("POST", { name }, { authorization: `Bearer ${admin.accessToken}` }))).json<{ inviteToken: string }>()).inviteToken;
    const role = (id: string) => env.DB.prepare("SELECT role FROM family_members WHERE family_id = 1 AND user_id = ?").bind(id).first<string>("role");
    const t = await make("Kid");
    const { userId } = await (await redeem(await redeemBody(t))).json<{ userId: string }>();
    expect(await role(userId)).toBe("member");
    expect(await env.DB.prepare("SELECT family_id FROM invites WHERE token_hash = ?").bind(await sha256Hex(t)).first<number>("family_id")).toBe(1);
    const t2 = await insertInvite({ admin: true });
    const b2 = await (await redeem(await redeemBody(t2))).json<{ userId: string }>();
    expect(await role(b2.userId)).toBe("admin");
  });

  it("redeem twice -> 410 and one user", async () => {
    const token = await insertInvite();
    expect((await redeem(await redeemBody(token))).status).toBe(201);
    const second = await redeem(await redeemBody(token));
    expect(second.status).toBe(410);
    expect(await second.json()).toEqual({ error: "invite_invalid" });
    expect(await count("users")).toBe(1);
  });

  it("concurrent redeems -> exactly one succeeds", async () => {
    const token = await insertInvite();
    const [a, b] = await Promise.all([redeem(await redeemBody(token)), redeem(await redeemBody(token))]);
    expect([a.status, b.status].sort()).toEqual([201, 410]);
    expect(await count("users")).toBe(1);
    expect(await count("devices")).toBe(1);
  });

  it("expired invite -> 410", async () => {
    const token = await insertInvite({ expiresAt: Date.now() - 1000 });
    expect((await redeem(await redeemBody(token))).status).toBe(410);
    expect(await count("users")).toBe(0);
  });

  it("unknown token -> 410", async () => {
    expect((await redeem(await redeemBody("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))).status).toBe(410);
  });

  it("bad cert does not burn invite", async () => {
    const token = await insertInvite();
    const bad = await redeemBody(token);
    const other = await makeKeys();
    const res = await redeem({ ...bad, certSig: other.certSig });
    expect(res.status).toBe(400);
    expect(await res.json()).toEqual({ error: "invalid_request" });
    expect(await count("users")).toBe(0);
    expect((await redeem(await redeemBody(token))).status).toBe(201);
  });

  it("wrong-length key -> 400 and invite kept", async () => {
    const token = await insertInvite();
    const body = await redeemBody(token);
    expect((await redeem({ ...body, encPub: body.encPub.slice(0, 40) })).status).toBe(400);
    expect((await redeem(await redeemBody(token))).status).toBe(201);
  });

  it("invalid platform or device name -> 400", async () => {
    const token = await insertInvite();
    const body = await redeemBody(token);
    expect((await redeem({ ...body, platform: "amiga" })).status).toBe(400);
    expect((await redeem({ ...body, deviceName: "" })).status).toBe(400);
    expect((await redeem({ ...body, deviceName: "x".repeat(61) })).status).toBe(400);
    expect((await redeem({ ...body, token: undefined })).status).toBe(400);
  });

  it("non-JSON body -> 400", async () => {
    const res = await SELF.fetch(`${BASE}/api/auth/invite/redeem`, { method: "POST", body: "nope" });
    expect(res.status).toBe(400);
  });
});

import { redeemNewDevice } from "./helpers";

const refresh = (body: unknown) => SELF.fetch(`${BASE}/api/auth/refresh`, jsonReq("POST", body));

describe("POST /api/auth/refresh", () => {
  it("returns a new pair and rotates the hash", async () => {
    const d = await redeemNewDevice({ admin: true });
    const res = await refresh({ refreshToken: d.refreshToken });
    expect(res.status).toBe(200);
    const body = await res.json<{ accessToken: string; refreshToken: string }>();
    expect(body.refreshToken).not.toBe(d.refreshToken);
    expect(await verifyAccessToken(env, body.accessToken)).toEqual({ sub: d.userId, dev: d.deviceId, adm: true });
    const hash = await env.DB.prepare("SELECT refresh_hash FROM devices WHERE id = ?").bind(d.deviceId).first<string>("refresh_hash");
    expect(hash).toBe(await sha256Hex(body.refreshToken));
  });

  it("updates last_seen", async () => {
    const d = await redeemNewDevice();
    await env.DB.prepare("UPDATE devices SET last_seen = 0 WHERE id = ?").bind(d.deviceId).run();
    await refresh({ refreshToken: d.refreshToken });
    const seen = await env.DB.prepare("SELECT last_seen FROM devices WHERE id = ?").bind(d.deviceId).first<number>("last_seen");
    expect(seen).toBeGreaterThan(0);
  });

  it("old token retried within grace -> new pair (lost response)", async () => {
    const d = await redeemNewDevice();
    expect((await refresh({ refreshToken: d.refreshToken })).status).toBe(200); // response "lost"
    const retry = await refresh({ refreshToken: d.refreshToken });
    expect(retry.status).toBe(200);
    const pair = await retry.json<{ refreshToken: string }>();
    expect((await refresh({ refreshToken: pair.refreshToken })).status).toBe(200);
  });

  it("old token reused after grace -> 401 and device revoked", async () => {
    const d = await redeemNewDevice();
    const first = await (await refresh({ refreshToken: d.refreshToken })).json<{ refreshToken: string }>();
    await env.DB.prepare("UPDATE devices SET refreshed_at = ? WHERE id = ?").bind(Date.now() - 120_000, d.deviceId).run();
    const reused = await refresh({ refreshToken: d.refreshToken });
    expect(reused.status).toBe(401);
    expect(await reused.json()).toEqual({ error: "unauthorized" });
    expect((await refresh({ refreshToken: first.refreshToken })).status).toBe(401);
    const revoked = await env.DB.prepare("SELECT revoked_at FROM devices WHERE id = ?").bind(d.deviceId).first<number>("revoked_at");
    expect(revoked).toBeGreaterThan(0);
  });

  it("grace retry does not extend the window", async () => {
    const d = await redeemNewDevice();
    await refresh({ refreshToken: d.refreshToken });
    const t = Date.now() - 50_000;
    await env.DB.prepare("UPDATE devices SET refreshed_at = ? WHERE id = ?").bind(t, d.deviceId).run();
    expect((await refresh({ refreshToken: d.refreshToken })).status).toBe(200);
    const after = await env.DB.prepare("SELECT refreshed_at FROM devices WHERE id = ?").bind(d.deviceId).first<number>("refreshed_at");
    expect(after).toBe(t);
  });

  it("revoked device -> 401", async () => {
    const d = await redeemNewDevice();
    await env.DB.prepare("UPDATE devices SET revoked_at = 1 WHERE id = ?").bind(d.deviceId).run();
    expect((await refresh({ refreshToken: d.refreshToken })).status).toBe(401);
  });

  it("unknown token -> 401; missing body -> 400", async () => {
    expect((await refresh({ refreshToken: "nope" })).status).toBe(401);
    expect((await refresh({})).status).toBe(400);
  });
});

import { app } from "../src/index";
import { createExecutionContext } from "cloudflare:test";

describe("redeem robustness", () => {
  it("retry with same keys within 10 min re-issues tokens for the same device", async () => {
    const token = await insertInvite();
    const keys = await makeKeys();
    const first = await (await redeem(await redeemBody(token, keys))).json<{ userId: string; deviceId: string; refreshToken: string }>();
    const retry = await redeem(await redeemBody(token, keys));
    expect(retry.status).toBe(201);
    const again = await retry.json<{ userId: string; deviceId: string; refreshToken: string; accessToken: string }>();
    expect(again.userId).toBe(first.userId);
    expect(again.deviceId).toBe(first.deviceId);
    expect(await count("users")).toBe(1);
    expect((await refresh({ refreshToken: again.refreshToken })).status).toBe(200);
  });

  it("retry with different keys -> 410", async () => {
    const token = await insertInvite();
    await redeem(await redeemBody(token));
    expect((await redeem(await redeemBody(token))).status).toBe(410);
  });

  it("retry after 10 min -> 410", async () => {
    const token = await insertInvite();
    const keys = await makeKeys();
    await redeem(await redeemBody(token, keys));
    await env.DB.prepare("UPDATE invites SET used_at = ?").bind(Date.now() - 11 * 60_000).run();
    expect((await redeem(await redeemBody(token, keys))).status).toBe(410);
  });

  it("missing TOKEN_SECRET -> 500 and invite not used", async () => {
    const token = await insertInvite();
    const req = new Request(`${BASE}/api/auth/invite/redeem`, jsonReq("POST", await redeemBody(token)));
    const res = await app.fetch(req, { ...env, TOKEN_SECRET: "" }, createExecutionContext());
    expect(res.status).toBe(500);
    expect(await count("users")).toBe(0);
    expect((await redeem(await redeemBody(token))).status).toBe(201);
  });
});

describe("bootstrap invites after first user", () => {
  const bootstrap = (name: string) =>
    SELF.fetch(`${BASE}/api/admin/bootstrap`, jsonReq("POST", { name }, { authorization: "Bearer test-bootstrap-secret" }));

  it("a second unused bootstrap invite is dead once any user exists", async () => {
    const a = await (await bootstrap("Michael")).json<{ inviteToken: string }>();
    const b = await (await bootstrap("Michael")).json<{ inviteToken: string }>();
    expect((await redeem(await redeemBody(b.inviteToken))).status).toBe(201);
    const late = await redeem(await redeemBody(a.inviteToken));
    expect(late.status).toBe(410);
    expect(await count("users")).toBe(1);
  });
});
