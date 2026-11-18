import { env, SELF } from "cloudflare:test";
import { b64urlEncode } from "../src/lib/encoding";
import { newId } from "../src/lib/ids";
import { BASE, insertUserWithDevice, makeKeys } from "./helpers";

export type ChatOut = {
  id: string;
  kind: "direct" | "group";
  title: string | null;
  createdBy: string;
  currentEpoch: number;
  epochReady: boolean;
  lastSeq: number;
  lastMessageAt: number | null;
  createdAt: number;
  familyId: number | null;
  mutedUntil: number | null;
  members: { userId: string; joinedSeq: number; lastReadSeq: number }[];
};

export type WrapJson = {
  chatId: string;
  epoch: number;
  recipientDeviceId: string;
  wrapperDeviceId: string;
  sealed: string;
  sig: string;
};

/** A wrap with the right shape; the server never opens it. */
export function fakeWrap(chatId: string, epoch: number, recipient: string, wrapper: string): WrapJson {
  return {
    chatId,
    epoch,
    recipientDeviceId: recipient,
    wrapperDeviceId: wrapper,
    sealed: b64urlEncode(crypto.getRandomValues(new Uint8Array(32 + 24 + 32 + 16))),
    sig: b64urlEncode(crypto.getRandomValues(new Uint8Array(64))),
  };
}

export function wrapsFor(chatId: string, epoch: number, wrapper: string, deviceIds: string[]): WrapJson[] {
  return deviceIds.map((d) => fakeWrap(chatId, epoch, d, wrapper));
}

export function api(token: string, method: string, path: string, body?: unknown): Promise<Response> {
  return SELF.fetch(`${BASE}/api${path}`, {
    method,
    headers: { authorization: `Bearer ${token}`, ...(body === undefined ? {} : { "content-type": "application/json" }) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

export type TestUser = Awaited<ReturnType<typeof insertUserWithDevice>>;

/** Adds another live device for a user; returns its id. */
export async function addDevice(userId: string): Promise<string> {
  const k = await makeKeys();
  const id = newId();
  await env.DB.prepare(
    `INSERT INTO devices (id, user_id, name, platform, enc_pub, sign_pub, cert_sig, created_at, last_seen)
     VALUES (?, ?, 'Laptop', 'linux', ?, ?, ?, 1, 1)`,
  ).bind(id, userId, k.encPub, k.signPub, k.certSig).run();
  return id;
}

/** Creates a group of [creator, ...others] with exact epoch-1 wraps. */
export async function createGroup(creator: TestUser, others: TestUser[], title = "Family", extraDevices: string[] = []) {
  const id = newId();
  const devs = [creator.deviceId, ...others.map((o) => o.deviceId), ...extraDevices];
  const res = await api(creator.accessToken, "POST", "/chats", {
    id,
    kind: "group",
    title,
    userIds: others.map((o) => o.userId),
    wraps: wrapsFor(id, 1, creator.deviceId, devs),
  });
  if (res.status !== 201) throw new Error(`create failed ${res.status} ${await res.text()}`);
  return (await res.json<{ chat: ChatOut }>()).chat;
}

export async function createDirect(a: TestUser, b: TestUser) {
  const id = newId();
  const res = await api(a.accessToken, "POST", "/chats", {
    id,
    kind: "direct",
    userId: b.userId,
    wraps: wrapsFor(id, 1, a.deviceId, [a.deviceId, b.deviceId]),
  });
  if (res.status !== 201 && res.status !== 200) throw new Error(`create failed ${res.status} ${await res.text()}`);
  return (await res.json<{ chat: ChatOut }>()).chat;
}

/** Inserts a message row directly (the hub does this in production). */
export async function insertMessage(chatId: string, sender: TestUser, epoch = 1, { silent = false } = {}) {
  const id = newId();
  const now = Date.now();
  const envelope = JSON.stringify({ v: 1, epoch, nonce: "AA", ct: "AA", sig: "AA" });
  await env.DB.batch([
    env.DB.prepare("UPDATE chats SET last_seq = last_seq + 1, last_message_at = ? WHERE id = ?").bind(now, chatId),
    env.DB.prepare(
      `INSERT INTO messages (chat_id, seq, id, sender_user_id, sender_device_id, envelope, created_at, silent)
       SELECT id, last_seq, ?, ?, ?, ?, ?, ? FROM chats WHERE id = ?`,
    ).bind(id, sender.userId, sender.deviceId, envelope, now, silent ? 1 : 0, chatId),
  ]);
  return id;
}
