import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import sql from "../migrations/0013_families.sql?raw";
import { resetDb } from "./helpers";

/** Replays the data part of 0013 (the statements after `-- @data`) over legacy-shaped rows. */
async function runData(): Promise<void> {
  const data = sql.slice(sql.indexOf("-- @data") + "-- @data".length);
  const stmts = data
    .split(";\n")
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
  await env.DB.batch(stmts.map((s) => env.DB.prepare(s)));
}

async function clearFamilies(): Promise<void> {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM chat_leavers"),
    env.DB.prepare("DELETE FROM family_members"),
    env.DB.prepare("UPDATE chats SET family_id = NULL"),
    env.DB.prepare("UPDATE invites SET family_id = NULL"),
    env.DB.prepare("UPDATE families SET created_by = NULL, decided_by = NULL"),
    env.DB.prepare("DELETE FROM families"),
  ]);
}

function user(
  id: string,
  o: { admin?: boolean; reviewer?: boolean; deleted?: boolean; adminBy?: string | null; at: number },
) {
  return env.DB.prepare(
    `INSERT INTO users (id, name, is_admin, identity_pub, created_at, reviewer, deleted_at, admin_by, admin_signer_pub, admin_sig)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  ).bind(
    id,
    id,
    o.admin ? 1 : 0,
    `pub-${id}`,
    o.at,
    o.reviewer ? 1 : 0,
    o.deleted ? o.at + 1 : null,
    o.adminBy ?? null,
    o.admin ? `signer-${id}` : null,
    o.admin ? `sig-${id}` : null,
  );
}

function chat(id: string, kind: "direct" | "group", createdBy: string) {
  return env.DB.prepare(
    "INSERT INTO chats (id, kind, title, created_by, direct_key, created_at) VALUES (?, ?, ?, ?, ?, 1)",
  ).bind(id, kind, kind === "group" ? id : null, createdBy, kind === "direct" ? `key-${id}` : null);
}

function invite(hash: string, o: { reviewer?: boolean; userId?: string }) {
  return env.DB.prepare(
    "INSERT INTO invites (token_hash, name, created_at, expires_at, reviewer, user_id) VALUES (?, 'X', 1, 2, ?, ?)",
  ).bind(hash, o.reviewer ? 1 : 0, o.userId ?? null);
}

function message(chatId: string, seq: number, sender: string) {
  return env.DB.prepare(
    `INSERT INTO messages (chat_id, seq, id, sender_user_id, sender_device_id, envelope, created_at)
     VALUES (?, ?, ?, ?, 'dev', 'env', 1)`,
  ).bind(chatId, seq, `${chatId}-${seq}`, sender);
}

async function seedLegacy(): Promise<void> {
  await resetDb();
  await clearFamilies();
  await env.DB.batch([
    user("boot", { admin: true, at: 100 }),
    user("admin2", { admin: true, adminBy: "boot", at: 200 }),
    user("member", { at: 300 }),
    user("exadmin", { admin: true, deleted: true, adminBy: "boot", at: 150 }),
    user("rev", { reviewer: true, at: 400 }),
    user("revadmin", { reviewer: true, admin: true, at: 500 }),
    chat("g-fam", "group", "member"),
    chat("g-rev", "group", "rev"),
    chat("d-1", "direct", "member"),
    chat("g-left", "group", "member"),
    env.DB.prepare("INSERT INTO chat_members (chat_id, user_id, joined_at) VALUES ('g-left', 'member', 1)"),
    env.DB.prepare("INSERT INTO chat_members (chat_id, user_id, joined_at) VALUES ('g-left', 'boot', 1)"),
    invite("inv-fam", {}),
    invite("inv-rev", { reviewer: true }),
    invite("inv-reset", { userId: "member" }),
    message("g-left", 1, "member"),
    message("g-left", 2, "admin2"),
    message("g-left", 3, "admin2"),
  ]);
  await runData();
}

describe("migration 0013 data", () => {
  beforeEach(seedLegacy);

  it("today's family becomes family #1 with the same admins and proofs", async () => {
    const fam = await env.DB.prepare("SELECT name, status, hidden FROM families WHERE id = 1").first();
    expect(fam).toEqual({ name: "Family", status: "approved", hidden: 0 });
    const { results } = await env.DB.prepare(
      "SELECT user_id, role, admin_by, admin_signer_pub, admin_sig FROM family_members WHERE family_id = 1 ORDER BY user_id",
    ).all();
    expect(results.map((r) => r.user_id)).toEqual(["admin2", "boot", "exadmin", "member"]);
    const by = Object.fromEntries(results.map((r) => [r.user_id, r]));
    expect(by.admin2).toMatchObject({
      role: "admin",
      admin_by: "boot",
      admin_signer_pub: "signer-admin2",
      admin_sig: "sig-admin2",
    });
    expect(by.boot).toMatchObject({ role: "admin", admin_by: null, admin_sig: "sig-boot" });
    expect(by.member).toMatchObject({ role: "member", admin_by: null, admin_signer_pub: null, admin_sig: null });
    expect(by.exadmin).toMatchObject({ role: "member", admin_by: null, admin_signer_pub: null, admin_sig: null });
  });

  it("reviewers become the hidden family #2", async () => {
    const fam = await env.DB.prepare("SELECT hidden, status FROM families WHERE id = 2").first();
    expect(fam).toEqual({ hidden: 1, status: "approved" });
    const { results } = await env.DB.prepare(
      "SELECT user_id, role FROM family_members WHERE family_id = 2 ORDER BY user_id",
    ).all();
    expect(results).toEqual([
      { user_id: "rev", role: "member" },
      { user_id: "revadmin", role: "member" },
    ]);
    // The legacy is_admin mirror is cleared for reviewers: they are no family's admin.
    const rev = await env.DB.prepare("SELECT is_admin FROM users WHERE id = 'revadmin'").first();
    expect(rev).toEqual({ is_admin: 0 });
  });

  it("the bootstrapped admin becomes operator and owner", async () => {
    const { results } = await env.DB.prepare("SELECT id FROM users WHERE operator = 1").all();
    expect(results).toEqual([{ id: "boot" }]);
    const fam = await env.DB.prepare("SELECT created_by FROM families WHERE id = 1").first();
    expect(fam).toEqual({ created_by: "boot" });
  });

  it("groups and invites get their family", async () => {
    const { results: chats } = await env.DB.prepare("SELECT id, family_id FROM chats ORDER BY id").all();
    expect(Object.fromEntries(chats.map((c) => [c.id, c.family_id]))).toEqual({
      "d-1": null,
      "g-fam": 1,
      "g-left": 1,
      "g-rev": 2,
    });
    const { results: invs } = await env.DB.prepare("SELECT token_hash, family_id FROM invites").all();
    expect(Object.fromEntries(invs.map((i) => [i.token_hash, i.family_id]))).toEqual({
      "inv-fam": 1,
      "inv-rev": 2,
      "inv-reset": null,
    });
  });

  it("past group senders become leavers", async () => {
    const { results } = await env.DB.prepare("SELECT chat_id, user_id, left_at FROM chat_leavers").all();
    expect(results).toEqual([{ chat_id: "g-left", user_id: "admin2", left_at: null }]);
  });

  it("an empty database gets family #1 without an owner and the reviewer family", async () => {
    await resetDb();
    await clearFamilies();
    await runData();
    const { results } = await env.DB.prepare("SELECT id, created_by, hidden FROM families ORDER BY id").all();
    expect(results).toEqual([
      { id: 1, created_by: null, hidden: 0 },
      { id: 2, created_by: null, hidden: 1 },
    ]);
  });
});
