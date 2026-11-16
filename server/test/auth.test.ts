import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { sha256Hex, verifyAccessToken } from "../src/lib/tokens";
import { BASE, insertInvite, jsonReq, makeKeys, redeemBody, resetDb } from "./helpers";

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
