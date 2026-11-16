import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { sha256Hex } from "../src/lib/tokens";
import { BASE, insertUserWithDevice, jsonReq, resetDb } from "./helpers";

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
