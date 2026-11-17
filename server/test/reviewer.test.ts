// Reviewer invites and accounts (docs/protocol.md "Reviewer accounts"): a reusable, revocable invite
// for app-store reviewers, whose accounts are walled off from the family in both directions.
import { env, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { newId } from "../src/lib/ids";
import { promotionMessage } from "../src/lib/reset";
import { api, type ChatOut, createDirect, createGroup, type TestUser, wrapsFor } from "./chat-helpers";
import { BASE, insertInvite, insertUserWithDevice, jsonReq, makeKeys, redeemBody, resetDb, type TestKeys } from "./helpers";
import { REVIEWER_MEDIA_CAP } from "../src/lib/media";
import { insertMedia, upload } from "./media-helpers";
import { signedReset, postReset, sign } from "./reset-helpers";
import { closeSockets, socket } from "./ws-helpers";

beforeEach(resetDb);
afterEach(closeSockets);

type ReviewerInvite = { inviteToken: string; inviteUrl: string; createdAt: number };
type ReviewersOut = {
  invite: { inviteUrl: string; createdAt: number } | null;
  users: { id: string; name: string; createdAt: number; devices: number }[];
};
type DirUser = { id: string; name: string; devices: { id: string }[] };

const createInvite = (admin: TestUser) => api(admin.accessToken, "POST", "/admin/reviewer-invite");
const revokeInvite = (admin: TestUser) => api(admin.accessToken, "DELETE", "/admin/reviewer-invite");
const reviewers = async (admin: TestUser) => {
  const res = await api(admin.accessToken, "GET", "/admin/reviewers");
  expect(res.status).toBe(200);
  return res.json<ReviewersOut>();
};
const directory = async (u: TestUser) => (await (await api(u.accessToken, "GET", "/users")).json<{ users: DirUser[] }>()).users;

async function newInvite(admin: TestUser): Promise<ReviewerInvite> {
  const res = await createInvite(admin);
  expect(res.status).toBe(201);
  return res.json<ReviewerInvite>();
}

function redeem(token: string, name: string | undefined, keys: TestKeys) {
  return redeemBody(token, keys).then((b) =>
    SELF.fetch(`${BASE}/api/auth/invite/redeem`, jsonReq("POST", name === undefined ? b : { ...b, name })),
  );
}

/** Redeems [token] as a new reviewer named [name]; returns a TestUser for them. */
async function joinAsReviewer(token: string, name = "Reviewer"): Promise<TestUser> {
  const keys = await makeKeys();
  const res = await redeem(token, name, keys);
  expect(res.status).toBe(201);
  const out = await res.json<{ userId: string; deviceId: string; accessToken: string; reviewer: boolean; isAdmin: boolean }>();
  expect(out.reviewer).toBe(true);
  expect(out.isAdmin).toBe(false);
  return { userId: out.userId, deviceId: out.deviceId, accessToken: out.accessToken, keys };
}

/** Admin Alice and member Bob (with a family group), and two reviewers who joined through the invite. */
async function setup() {
  const alice = await insertUserWithDevice({ admin: true, operator: true, name: "Alice" });
  const bob = await insertUserWithDevice({ name: "Bob" });
  const familyGroup = await createGroup(alice, [bob], "Secret family plans");
  const invite = await newInvite(alice);
  const r1 = await joinAsReviewer(invite.inviteToken, "Play Reviewer");
  const r2 = await joinAsReviewer(invite.inviteToken, "Second Reviewer");
  return { alice, bob, familyGroup, invite, r1, r2 };
}

const directBody = (from: TestUser, to: TestUser, id = newId()) => ({
  id,
  kind: "direct",
  userId: to.userId,
  wraps: wrapsFor(id, 1, from.deviceId, [from.deviceId, to.deviceId]),
});
const groupBody = (from: TestUser, others: TestUser[], id = newId()) => ({
  id,
  kind: "group",
  title: "G",
  userIds: others.map((o) => o.userId),
  wraps: wrapsFor(id, 1, from.deviceId, [from.deviceId, ...others.map((o) => o.deviceId)]),
});

describe("the reviewer invite", () => {
  it("only admins can create, view or revoke it", async () => {
    const bob = await insertUserWithDevice({ name: "Bob" });
    expect((await createInvite(bob)).status).toBe(403);
    expect((await api(bob.accessToken, "GET", "/admin/reviewers")).status).toBe(403);
    expect((await revokeInvite(bob)).status).toBe(403);
    expect((await SELF.fetch(`${BASE}/api/admin/reviewer-invite`, { method: "POST" })).status).toBe(401);
  });

  it("reviewer endpoints are operator-only", async () => {
    const dave = await insertUserWithDevice({ admin: true, name: "Dave" });
    expect((await createInvite(dave)).status).toBe(403);
    expect((await api(dave.accessToken, "GET", "/admin/reviewers")).status).toBe(403);
    expect((await revokeInvite(dave)).status).toBe(403);
  });

  it("is a marked link that the admin can see again later", async () => {
    const alice = await insertUserWithDevice({ admin: true, operator: true, name: "Alice" });
    expect((await reviewers(alice)).invite).toBeNull();
    const inv = await newInvite(alice);
    expect(inv.inviteUrl).toBe(`${env.APP_ORIGIN}/join#review.${inv.inviteToken}`);
    expect((await reviewers(alice)).invite).toEqual({ inviteUrl: inv.inviteUrl, createdAt: inv.createdAt });
  });

  it("a reviewer redeem joins the hidden family", async () => {
    const { r1, invite } = await setup();
    expect(await env.DB.prepare("SELECT role FROM family_members WHERE family_id = 2 AND user_id = ?").bind(r1.userId).first<string>("role")).toBe("member");
    expect(await env.DB.prepare("SELECT COUNT(*) AS n FROM family_members WHERE family_id = 1 AND user_id = ?").bind(r1.userId).first<number>("n")).toBe(0);
    expect(await env.DB.prepare("SELECT family_id FROM invites WHERE reviewer = 1").first<number>("family_id")).toBe(2);
    expect(invite.inviteToken).toBeTruthy();
  });

  it("is reusable and never expires", async () => {
    const { alice, invite, r1, r2 } = await setup();
    const r3 = await joinAsReviewer(invite.inviteToken, "Third");
    expect(new Set([r1.userId, r2.userId, r3.userId]).size).toBe(3);
    const row = await env.DB.prepare("SELECT expires_at, used_by FROM invites WHERE reviewer = 1").first<{ expires_at: number; used_by: string | null }>();
    expect(row!.expires_at).toBeGreaterThan(Date.UTC(9000, 0));
    expect(row!.used_by).toBeNull();
    const out = await reviewers(alice);
    expect(out.users.map((u) => u.name).sort()).toEqual(["Play Reviewer", "Second Reviewer", "Third"]);
    expect(out.users.every((u) => u.devices === 1)).toBe(true);
    const users = await env.DB.prepare("SELECT reviewer, is_admin FROM users WHERE id IN (?, ?, ?)")
      .bind(r1.userId, r2.userId, r3.userId).all<{ reviewer: number; is_admin: number }>();
    expect(users.results.every((u) => u.reviewer === 1 && u.is_admin === 0)).toBe(true);
  });

  it("needs a display name from the reviewer", async () => {
    const alice = await insertUserWithDevice({ admin: true, operator: true });
    const inv = await newInvite(alice);
    for (const name of [undefined, "", "   ", "x".repeat(41)]) {
      expect((await redeem(inv.inviteToken, name, await makeKeys())).status).toBe(400);
    }
    expect((await reviewers(alice)).users).toEqual([]);
  });

  it("a lost response can be retried with the same keys without making a second account", async () => {
    const alice = await insertUserWithDevice({ admin: true, operator: true });
    const inv = await newInvite(alice);
    const keys = await makeKeys();
    const a = await (await redeem(inv.inviteToken, "Rev", keys)).json<{ userId: string; deviceId: string }>();
    const res = await redeem(inv.inviteToken, "Rev", keys);
    expect(res.status).toBe(201);
    const b = await res.json<{ userId: string; deviceId: string; reviewer: boolean }>();
    expect(b).toMatchObject({ userId: a.userId, deviceId: a.deviceId, reviewer: true });
    expect((await reviewers(alice)).users).toHaveLength(1);
  });

  it("stops working when revoked, and the reviewers keep their accounts", async () => {
    const { alice, invite, r1 } = await setup();
    expect((await revokeInvite(alice)).status).toBe(204);
    expect((await redeem(invite.inviteToken, "Late", await makeKeys())).status).toBe(410);
    const out = await reviewers(alice);
    expect(out.invite).toBeNull();
    expect(out.users).toHaveLength(2);
    expect((await api(r1.accessToken, "GET", "/me")).status).toBe(200);
    // Revoking again is fine.
    expect((await revokeInvite(alice)).status).toBe(204);
  });

  it("a new one replaces the old one (at most one is active)", async () => {
    const alice = await insertUserWithDevice({ admin: true, operator: true });
    const first = await newInvite(alice);
    const second = await newInvite(alice);
    expect(second.inviteToken).not.toBe(first.inviteToken);
    expect((await redeem(first.inviteToken, "Old", await makeKeys())).status).toBe(410);
    expect((await redeem(second.inviteToken, "New", await makeKeys())).status).toBe(201);
    expect((await reviewers(alice)).invite?.inviteUrl).toBe(second.inviteUrl);
  });

  it("stops working when the admin who made it is deleted", async () => {
    const alice = await insertUserWithDevice({ admin: true, operator: true, name: "Alice" });
    await insertUserWithDevice({ admin: true, name: "Carol" });
    const inv = await newInvite(alice);
    expect((await api(alice.accessToken, "DELETE", "/me", { confirm: "delete" })).status).toBe(204);
    expect((await redeem(inv.inviteToken, "Rev", await makeKeys())).status).toBe(410);
  });

  it("normal invites don't make reviewers and ignore a name", async () => {
    await insertUserWithDevice({ admin: true });
    const token = await insertInvite({ name: "Mom" });
    const res = await redeem(token, "Somebody else", await makeKeys());
    expect(res.status).toBe(201);
    const out = await res.json<{ userId: string; reviewer: boolean }>();
    expect(out.reviewer).toBe(false);
    const row = await env.DB.prepare("SELECT name, reviewer FROM users WHERE id = ?").bind(out.userId).first();
    expect(row).toEqual({ name: "Mom", reviewer: 0 });
  });

  it("GET /me says whether you are a reviewer", async () => {
    const { bob, r1 } = await setup();
    expect((await (await api(r1.accessToken, "GET", "/me")).json<{ reviewer: boolean }>()).reviewer).toBe(true);
    expect((await (await api(bob.accessToken, "GET", "/me")).json<{ reviewer: boolean }>()).reviewer).toBe(false);
  });
});

describe("directory isolation", () => {
  it("the family never sees reviewers", async () => {
    const { alice, bob, r1, r2 } = await setup();
    for (const u of [alice, bob]) {
      const ids = (await directory(u)).map((x) => x.id);
      expect(ids.sort()).toEqual([alice.userId, bob.userId].sort());
      expect(ids).not.toContain(r1.userId);
      expect(ids).not.toContain(r2.userId);
    }
  });

  it("reviewers see only reviewers (themselves included)", async () => {
    const { r1, r2 } = await setup();
    const users = await directory(r1);
    expect(users.map((x) => x.id).sort()).toEqual([r1.userId, r2.userId].sort());
    expect(users.flatMap((u) => u.devices.map((d) => d.id)).sort()).toEqual([r1.deviceId, r2.deviceId].sort());
  });
});

describe("chat isolation", () => {
  it("family members can't start chats with reviewers", async () => {
    const { alice, bob, r1 } = await setup();
    const d = await api(alice.accessToken, "POST", "/chats", directBody(alice, r1));
    expect(d.status).toBe(403);
    expect(await d.json()).toEqual({ error: "no_shared_family" });
    expect((await api(alice.accessToken, "POST", "/chats", groupBody(alice, [bob, r1]))).status).toBe(400);
  });

  it("reviewers can't start chats with family members", async () => {
    const { alice, bob, r1, r2 } = await setup();
    const d = await api(r1.accessToken, "POST", "/chats", directBody(r1, alice));
    expect(d.status).toBe(403);
    expect(await d.json()).toEqual({ error: "no_shared_family" });
    expect((await api(r1.accessToken, "POST", "/chats", groupBody(r1, [r2, bob]))).status).toBe(400);
  });

  it("nobody can add someone from the other side to a group", async () => {
    const { alice, familyGroup, r1, r2 } = await setup();
    const famAdd = await api(alice.accessToken, "POST", `/chats/${familyGroup.id}/members`, {
      userIds: [r1.userId],
      wraps: wrapsFor(familyGroup.id, 1, alice.deviceId, [r1.deviceId]),
    });
    expect(famAdd.status).toBe(400);
    const g = await createGroup(r1, [r2], "Reviewers");
    const revAdd = await api(r1.accessToken, "POST", `/chats/${g.id}/members`, {
      userIds: [alice.userId],
      wraps: wrapsFor(g.id, 1, r1.deviceId, [alice.deviceId]),
    });
    expect(revAdd.status).toBe(400);
  });

  it("reviewers can chat with each other, and can't see family chats", async () => {
    const { familyGroup, r1, r2 } = await setup();
    const d = await createDirect(r1, r2);
    expect(d.members.map((m) => m.userId).sort()).toEqual([r1.userId, r2.userId].sort());
    expect((await api(r1.accessToken, "GET", `/chats/${familyGroup.id}`)).status).toBe(404);
    expect((await api(r1.accessToken, "GET", `/chats/${familyGroup.id}/messages`)).status).toBe(404);
    const list = await (await api(r1.accessToken, "GET", "/chats")).json<{ chats: ChatOut[] }>();
    expect(list.chats.map((c) => c.id)).toEqual([d.id]);
  });
});

describe("a lone reviewer", () => {
  it("can make a chat with only themselves and use it: text, photo, voice", async () => {
    const alice = await insertUserWithDevice({ admin: true, operator: true });
    const r = await joinAsReviewer((await newInvite(alice)).inviteToken);
    const id = newId();
    const res = await api(r.accessToken, "POST", "/chats", {
      id, kind: "group", title: "Note to self", userIds: [], wraps: wrapsFor(id, 1, r.deviceId, [r.deviceId]),
    });
    expect(res.status).toBe(201);
    const chat = (await res.json<{ chat: ChatOut }>()).chat;
    expect(chat).toMatchObject({ kind: "group", title: "Note to self", currentEpoch: 1, epochReady: true });
    expect(chat.members.map((m) => m.userId)).toEqual([r.userId]);

    // Photo and voice blobs.
    for (const kind of ["photo", "thumb", "voice"]) {
      const up = await upload(r, { chatId: id, kind, messageId: newId() }, new Uint8Array(100));
      expect(up.status).toBe(201);
    }
    // Text (or a media message) over the hub.
    const ws = await socket(r);
    await ws.next("hello");
    const msgId = newId();
    ws.send({ type: "send", id: msgId, chatId: id, envelope: { v: 1, epoch: 1, nonce: "AAAA", ct: "AAAA", sig: "AAAA" } });
    expect(await ws.next("ack")).toMatchObject({ id: msgId, seq: 1 });
    const msgs = await (await api(r.accessToken, "GET", `/chats/${id}/messages`)).json<{ messages: { id: string }[] }>();
    expect(msgs.messages.map((m) => m.id)).toEqual([msgId]);
  });

  it("a one-member group still moves epochs when its member revokes a device", async () => {
    const alice = await insertUserWithDevice({ admin: true, operator: true });
    const r = await joinAsReviewer((await newInvite(alice)).inviteToken);
    const id = newId();
    await api(r.accessToken, "POST", "/chats", {
      id, kind: "group", title: "Note to self", userIds: [], wraps: wrapsFor(id, 1, r.deviceId, [r.deviceId]),
    });
    // The epoch-2 key covers exactly the member's live devices: just this one.
    await env.DB.prepare("UPDATE chats SET current_epoch = 2 WHERE id = ?").bind(id).run();
    const res = await api(r.accessToken, "POST", `/chats/${id}/epochs`, { epoch: 2, wraps: wrapsFor(id, 2, r.deviceId, [r.deviceId]) });
    expect(res.status).toBe(201);
  });
});

describe("reviewer media budget", () => {
  it("reviewers share a small budget; the family's uploads don't count against it", async () => {
    const { alice, bob, familyGroup, r1, r2 } = await setup();
    const g = await createGroup(r1, [r2], "Reviewers");
    await insertMedia({ chatId: g.id, uploader: r2, bytes: REVIEWER_MEDIA_CAP - 50, createdAt: Date.now() });
    await insertMedia({ chatId: familyGroup.id, uploader: bob, bytes: 10 * REVIEWER_MEDIA_CAP, createdAt: Date.now() });
    expect((await upload(r1, { chatId: g.id }, new Uint8Array(40))).status).toBe(201);
    expect((await upload(r1, { chatId: g.id }, new Uint8Array(40))).status).toBe(413);
    expect((await upload(alice, { chatId: familyGroup.id }, new Uint8Array(40))).status).toBe(201);
  });
});

describe("admin routes reject reviewers", () => {
  it("even a reviewer row marked admin can't use them", async () => {
    const { bob, r1 } = await setup();
    await env.DB.prepare("UPDATE users SET is_admin = 1 WHERE id = ?").bind(r1.userId).run();
    const calls: [string, string, unknown?][] = [
      ["POST", "/admin/invites", { name: "Eve" }],
      ["POST", "/admin/reviewer-invite"],
      ["DELETE", "/admin/reviewer-invite"],
      ["GET", "/admin/reviewers"],
      ["GET", "/admin/usage"],
      ["DELETE", `/admin/users/${bob.userId}`],
      ["POST", `/admin/users/${bob.userId}/admin`, { sig: "A".repeat(86) }],
      ["POST", `/admin/users/${bob.userId}/reset`, {}],
      ["POST", "/admin/recovery-key", {}],
    ];
    for (const [method, path, body] of calls) {
      expect((await api(r1.accessToken, method, path, body)).status, `${method} ${path}`).toBe(403);
    }
    expect((await api(bob.accessToken, "GET", "/me")).status).toBe(200);
  });

  it("admins can't make a reviewer an admin or reset them", async () => {
    const { alice, r1 } = await setup();
    const sig = await sign(alice.keys.identityPriv, promotionMessage(r1.userId, alice.userId));
    expect((await api(alice.accessToken, "POST", `/admin/users/${r1.userId}/admin`, { sig })).status).toBe(404);
    const reset = await signedReset(alice, { userId: r1.userId, identityPub: r1.keys.identityPub });
    expect((await postReset(alice, r1.userId, reset.body)).status).toBe(404);
    const row = await env.DB.prepare("SELECT is_admin FROM users WHERE id = ?").bind(r1.userId).first<number>("is_admin");
    expect(row).toBe(0);
  });

  it("admins remove reviewers with DELETE /admin/users/:id", async () => {
    const { alice, r1, r2 } = await setup();
    expect((await api(alice.accessToken, "DELETE", `/admin/users/${r1.userId}`)).status).toBe(204);
    expect((await reviewers(alice)).users.map((u) => u.id)).toEqual([r2.userId]);
    expect((await api(r1.accessToken, "GET", "/me")).status).toBe(401);
  });

  it("reviewers don't count as family for the last-admin rule", async () => {
    const { alice, bob } = await setup();
    expect((await api(alice.accessToken, "DELETE", `/admin/users/${bob.userId}`)).status).toBe(204);
    // Only reviewers are left besides Alice: she may delete her account.
    expect((await api(alice.accessToken, "DELETE", "/me", { confirm: "delete" })).status).toBe(204);
  });
});

describe("events don't cross over", () => {
  it("account_deleted reaches only the deleted user's side", async () => {
    const alice = await insertUserWithDevice({ admin: true, operator: true, name: "Alice" });
    const bob = await insertUserWithDevice({ name: "Bob" });
    const carol = await insertUserWithDevice({ name: "Carol" });
    const r1 = await joinAsReviewer((await newInvite(alice)).inviteToken, "R1");
    const r2 = await joinAsReviewer((await newInvite(alice)).inviteToken, "R2");
    const [bobWs, r1Ws] = [await socket(bob), await socket(r1)];

    expect((await api(alice.accessToken, "DELETE", `/admin/users/${carol.userId}`)).status).toBe(204);
    expect(await bobWs.next("account_deleted")).toEqual({ type: "account_deleted", userId: carol.userId });
    await r1Ws.none("account_deleted");

    expect((await api(alice.accessToken, "DELETE", `/admin/users/${r2.userId}`)).status).toBe(204);
    expect(await r1Ws.next("account_deleted")).toEqual({ type: "account_deleted", userId: r2.userId });
    await bobWs.none("account_deleted");
  });

  it("resets of family members aren't sent to reviewers", async () => {
    const { alice, bob, r1 } = await setup();
    const [bobWs, r1Ws] = [await socket(bob), await socket(r1)];
    const reset = await signedReset(alice, { userId: bob.userId, identityPub: bob.keys.identityPub });
    expect((await postReset(alice, bob.userId, reset.body)).status).toBe(201);
    await r1Ws.none("reset");
    void bobWs;
  });

  it("presence and the hello list stay on each side", async () => {
    const { alice, r1, r2 } = await setup();
    const aliceWs = await socket(alice);
    expect((await aliceWs.next("hello")).online).toEqual([alice.userId]);
    const r1Ws = await socket(r1);
    expect((await r1Ws.next("hello")).online).toEqual([r1.userId]);
    await aliceWs.none("presence");
    const r2Ws = await socket(r2);
    expect(((await r2Ws.next("hello")).online as string[]).sort()).toEqual([r1.userId, r2.userId].sort());
    expect(await r1Ws.next("presence")).toEqual({ type: "presence", userId: r2.userId, online: true });
    await aliceWs.none("presence");
  });

  it("bootstrap counts only the family", async () => {
    const alice = await insertUserWithDevice({ admin: true, operator: true });
    await joinAsReviewer((await newInvite(alice)).inviteToken);
    const boot = () =>
      SELF.fetch(`${BASE}/api/admin/bootstrap`, jsonReq("POST", { name: "Alice" }, { authorization: "Bearer test-bootstrap-secret" }));
    expect((await boot()).status).toBe(409);
    expect((await api(alice.accessToken, "DELETE", "/me", { confirm: "delete" })).status).toBe(204);
    const res = await boot();
    expect(res.status).toBe(201);
    const { inviteToken } = await res.json<{ inviteToken: string }>();
    const again = await redeem(inviteToken, undefined, await makeKeys());
    expect(again.status).toBe(201);
    expect((await again.json<{ isAdmin: boolean }>()).isAdmin).toBe(true);
  });
});
