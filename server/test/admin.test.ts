import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { sha256Hex } from "../src/lib/tokens";
import { BASE, jsonReq, makeKeys, redeemBody, insertUserWithDevice, resetDb } from "./helpers";
import { api } from "./chat-helpers";
import { promotionMessage } from "../src/lib/reset";
import { sign } from "./reset-helpers";

const DAY = 24 * 60 * 60 * 1000;
const bootstrap = (body: unknown, secret = "test-bootstrap-secret") =>
  SELF.fetch(`${BASE}/api/admin/bootstrap`, jsonReq("POST", body, { authorization: `Bearer ${secret}` }));

beforeEach(resetDb);

describe("POST /api/admin/bootstrap", () => {
  it("creates an admin invite", async () => {
    const before = Date.now();
    const res = await bootstrap({ name: "Michael" });
    expect(res.status).toBe(201);
    const body = await res.json<{ inviteToken: string; inviteUrl: string; expiresAt: number }>();
    expect(body.inviteUrl).toBe(`https://famchat.dev/join#${body.inviteToken}`);
    expect(Math.abs(body.expiresAt - (before + 7 * DAY))).toBeLessThan(60_000);
    const row = await env.DB.prepare("SELECT * FROM invites").first<Record<string, unknown>>();
    expect(row?.make_admin).toBe(1);
    expect(row?.name).toBe("Michael");
    expect(row?.token_hash).toBe(await sha256Hex(body.inviteToken));
  });

  it("wrong secret -> 401 and no invite", async () => {
    const res = await bootstrap({ name: "Michael" }, "nope");
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "unauthorized" });
    const n = await env.DB.prepare("SELECT COUNT(*) AS n FROM invites").first<number>("n");
    expect(n).toBe(0);
  });

  it("missing authorization -> 401", async () => {
    const res = await SELF.fetch(`${BASE}/api/admin/bootstrap`, jsonReq("POST", { name: "M" }));
    expect(res.status).toBe(401);
  });

  it("after a user exists -> 409 already_bootstrapped", async () => {
    await insertUserWithDevice();
    const res = await bootstrap({ name: "Michael" });
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: "already_bootstrapped" });
    const n = await env.DB.prepare("SELECT COUNT(*) AS n FROM invites").first<number>("n");
    expect(n).toBe(0);
  });

  it("redeeming the bootstrap invite makes the operator and owner of family #1", async () => {
    const { inviteToken } = await (await bootstrap({ name: "Michael" })).json<{ inviteToken: string }>();
    const res = await SELF.fetch(`${BASE}/api/auth/invite/redeem`, jsonReq("POST", await redeemBody(inviteToken, await makeKeys())));
    expect(res.status).toBe(201);
    const { userId } = await res.json<{ userId: string }>();
    expect(await env.DB.prepare("SELECT operator FROM users WHERE id = ?").bind(userId).first<number>("operator")).toBe(1);
    expect(await env.DB.prepare("SELECT role FROM family_members WHERE family_id = 1 AND user_id = ?").bind(userId).first<string>("role")).toBe("admin");
    expect(await env.DB.prepare("SELECT created_by FROM families WHERE id = 1").first<string>("created_by")).toBe(userId);
    expect(await env.DB.prepare("SELECT family_id FROM invites").first<number>("family_id")).toBe(1);
  });

  it("is refused while family #1 has a live member or an operator exists", async () => {
    await insertUserWithDevice({ operator: true, families: [] });
    const res = await bootstrap({ name: "Michael" });
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: "already_bootstrapped" });
  });

  it("blank or too-long name -> 400", async () => {
    expect((await bootstrap({ name: "  " })).status).toBe(400);
    expect((await bootstrap({ name: "x".repeat(41) })).status).toBe(400);
    expect((await bootstrap({})).status).toBe(400);
  });

  it("trims the name", async () => {
    await bootstrap({ name: "  Michael  " });
    const row = await env.DB.prepare("SELECT name FROM invites").first<string>("name");
    expect(row).toBe("Michael");
  });
});

describe("POST /api/admin/invites", () => {
  const invite = (body: unknown, token?: string) =>
    SELF.fetch(
      `${BASE}/api/admin/invites`,
      jsonReq("POST", body, token ? { authorization: `Bearer ${token}` } : {}),
    );

  it("admin creates a member invite", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const res = await invite({ name: "Mom" }, admin.accessToken);
    expect(res.status).toBe(201);
    const body = await res.json<{ inviteToken: string; inviteUrl: string }>();
    expect(body.inviteUrl).toBe(`https://famchat.dev/join#${body.inviteToken}`);
    const row = await env.DB.prepare("SELECT make_admin, created_by FROM invites").first<Record<string, unknown>>();
    expect(row).toEqual({ make_admin: 0, created_by: admin.userId });
  });

  it("no token -> 401", async () => {
    expect((await invite({ name: "Mom" })).status).toBe(401);
  });

  it("non-admin -> 403", async () => {
    const member = await insertUserWithDevice();
    const res = await invite({ name: "Mom" }, member.accessToken);
    expect(res.status).toBe(403);
    expect(await res.json()).toEqual({ error: "forbidden" });
  });

  it("garbage token -> 401", async () => {
    expect((await invite({ name: "Mom" }, "abc.def.ghi")).status).toBe(401);
  });
});

describe("promotion and family membership", () => {
  const promote = async (by: { accessToken: string; userId: string; keys: { identityPriv: CryptoKey } }, userId: string) =>
    api(by.accessToken, "POST", `/admin/users/${userId}/admin`, { sig: await sign(by.keys.identityPriv, promotionMessage(userId, by.userId)) });

  it("promotion writes the proof into family #1", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const dad = await insertUserWithDevice({ name: "Dad" });
    expect((await promote(admin, dad.userId)).status).toBe(204);
    const fm = await env.DB.prepare("SELECT role, admin_by, admin_signer_pub, admin_sig FROM family_members WHERE family_id = 1 AND user_id = ?")
      .bind(dad.userId).first<Record<string, unknown>>();
    const u = await env.DB.prepare("SELECT is_admin, admin_by, admin_signer_pub, admin_sig FROM users WHERE id = ?")
      .bind(dad.userId).first<Record<string, unknown>>();
    expect(fm?.role).toBe("admin");
    expect(fm?.admin_by).toBe(admin.userId);
    expect(fm?.admin_sig).toBeTruthy();
    expect(u).toEqual({ is_admin: 1, admin_by: fm?.admin_by, admin_signer_pub: fm?.admin_signer_pub, admin_sig: fm?.admin_sig });
  });

  it("promoting a user who is not in family #1 -> 404 and nothing written", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const outsider = await insertUserWithDevice({ families: [] });
    expect((await promote(admin, outsider.userId)).status).toBe(404);
    expect(await env.DB.prepare("SELECT is_admin FROM users WHERE id = ?").bind(outsider.userId).first<number>("is_admin")).toBe(0);
  });

  it("compat promote doesn't touch a user deleted between check and write", async () => {
    const admin = await insertUserWithDevice({ admin: true });
    const dad = await insertUserWithDevice({ name: "Dad" });
    await env.DB.prepare("UPDATE users SET deleted_at = 1 WHERE id = ?").bind(dad.userId).run();
    expect((await promote(admin, dad.userId)).status).toBe(404);
    expect(await env.DB.prepare("SELECT is_admin FROM users WHERE id = ?").bind(dad.userId).first<number>("is_admin")).toBe(0);
    expect(await env.DB.prepare("SELECT role FROM family_members WHERE family_id = 1 AND user_id = ?").bind(dad.userId).first<string>("role")).toBe("member");
  });
});
