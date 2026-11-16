import { env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { newId } from "../src/lib/ids";
import { MEDIA_CAP, MEDIA_TARGET } from "../src/lib/media";
import { api, createGroup, type TestUser } from "./chat-helpers";
import { insertUserWithDevice, resetDb } from "./helpers";
import { download, GiB, insertMedia, listen, MiB, randomBytes, upload, usage } from "./media-helpers";

let alice: TestUser, bob: TestUser, eve: TestUser;
let chatId: string;

beforeEach(async () => {
  await resetDb();
  alice = await insertUserWithDevice({ name: "Alice", admin: true });
  bob = await insertUserWithDevice({ name: "Bob" });
  eve = await insertUserWithDevice({ name: "Eve" });
  chatId = (await createGroup(alice, [bob])).id;
});

describe("upload and download", () => {
  it("uploads and downloads the same bytes", async () => {
    const bytes = randomBytes(5000);
    const key = newId();
    const messageId = newId();
    const res = await upload(alice, { chatId, key, messageId }, bytes);
    expect(res.status).toBe(201);
    expect(await res.json()).toEqual({ key, bytes: 5000 });
    const row = await env.DB.prepare("SELECT * FROM media WHERE key = ?").bind(key).first<Record<string, unknown>>();
    expect(row).toMatchObject({
      uploader_id: alice.userId, uploader_device_id: alice.deviceId, chat_id: chatId, message_id: messageId,
      kind: "photo", bytes: 5000, expired_at: null,
    });
    expect(await usage()).toBe(5000);

    const got = await download(bob, key);
    expect(got.status).toBe(200);
    expect(got.headers.get("content-type")).toBe("application/octet-stream");
    expect(got.headers.get("cache-control")).toBe("private, no-store");
    expect(new Uint8Array(await got.arrayBuffer())).toEqual(bytes);
  });

  it("re-upload of the same key is idempotent", async () => {
    const key = newId();
    expect((await upload(alice, { chatId, key }, randomBytes(100))).status).toBe(201);
    const again = await upload(alice, { chatId, key }, randomBytes(100));
    expect(again.status).toBe(200);
    expect(await again.json()).toEqual({ key, bytes: 100 });
    expect(await usage()).toBe(100);
  });

  it("same key from another device → conflict", async () => {
    const key = newId();
    await upload(alice, { chatId, key }, randomBytes(100));
    const res = await upload(bob, { chatId, key }, randomBytes(100));
    expect(res.status).toBe(409);
    expect(await res.json()).toEqual({ error: "conflict" });
  });

  it("upload to a chat I'm not in → 404", async () => {
    const res = await upload(eve, { chatId }, randomBytes(10));
    expect(res.status).toBe(404);
    expect(await usage()).toBe(0);
    expect((await env.MEDIA.list()).objects).toHaveLength(0);
  });

  it("non-member cannot download", async () => {
    const key = newId();
    await upload(alice, { chatId, key }, randomBytes(10));
    expect((await download(eve, key)).status).toBe(404);
  });

  it("unknown key → 404", async () => {
    expect((await download(alice, newId())).status).toBe(404);
  });

  it("requires auth", async () => {
    expect((await upload({ ...alice, accessToken: "nope" }, { chatId }, randomBytes(10))).status).toBe(401);
  });

  it("bad kind, key or chatId → 400", async () => {
    for (const q of [{ chatId, kind: "video" }, { chatId, key: "nope" }, { chatId: "nope" }, { chatId, messageId: "x" }]) {
      const res = await upload(alice, q, randomBytes(10));
      expect(res.status, JSON.stringify(q)).toBe(400);
    }
  });

  it("empty body → invalid_request", async () => {
    expect((await upload(alice, { chatId }, new Uint8Array(0))).status).toBe(400);
  });

  it("missing content-length → invalid_request", async () => {
    const stream = new ReadableStream({
      start(c) {
        c.enqueue(new Uint8Array([1, 2, 3]));
        c.close();
      },
    });
    const res = await upload(alice, { chatId }, stream);
    expect(res.status).toBe(400);
    expect(await usage()).toBe(0);
  });

  it("photo over 15 MiB → too_large", async () => {
    const res = await upload(alice, { chatId }, randomBytes(15 * MiB + 1));
    expect(res.status).toBe(413);
    expect(await res.json()).toEqual({ error: "too_large" });
    expect(await usage()).toBe(0);
    expect((await env.MEDIA.list()).objects).toHaveLength(0);
  });

  it("thumb over 1 MiB → too_large", async () => {
    expect((await upload(alice, { chatId, kind: "thumb" }, randomBytes(MiB + 1))).status).toBe(413);
    expect((await upload(alice, { chatId, kind: "thumb" }, randomBytes(MiB))).status).toBe(201);
  });

  it("voice up to 8 MiB accepted", async () => {
    expect((await upload(alice, { chatId, kind: "voice" }, randomBytes(8 * MiB))).status).toBe(201);
    expect((await upload(alice, { chatId, kind: "voice" }, randomBytes(8 * MiB + 1))).status).toBe(413);
  });
});

describe("quota", () => {
  it("cap is 8 GiB, evicting to below 7.5 GiB", () => {
    expect(MEDIA_CAP).toBe(8589934592);
    expect(MEDIA_TARGET).toBe(8053063680);
  });

  it("passing 8 GiB evicts oldest to below 7.5 GiB", async () => {
    const t0 = Date.now() - 100_000;
    const keys: string[] = [];
    const shared = newId();
    for (let i = 0; i < 10; i++) {
      // Rows 1 and 2 are one message (photo + thumb): a cut after row 1 must take row 2 too.
      keys.push(await insertMedia({
        chatId, uploader: alice, bytes: 900 * MiB, createdAt: t0 + i * 1000,
        messageId: i === 1 || i === 2 ? shared : undefined, kind: i === 2 ? "thumb" : "photo",
      }));
    }
    expect(await usage()).toBe(9000 * MiB);
    const res = await upload(alice, { chatId }, randomBytes(10));
    expect(res.status).toBe(201);
    // 9000 MiB > 8192 MiB → oldest first until < 7680 MiB: rows 0, 1 (7200 MiB), plus row 1's sibling 2.
    const rows = (await env.DB.prepare("SELECT key, expired_at FROM media ORDER BY created_at").all<{ key: string; expired_at: number | null }>()).results;
    const expired = rows.filter((r) => r.expired_at !== null).map((r) => r.key);
    expect(expired).toEqual([keys[0], keys[1], keys[2]]);
    expect(await usage()).toBe(6300 * MiB + 10);
    expect(await usage()).toBeLessThan(MEDIA_TARGET);
    for (const k of keys.slice(0, 3)) expect(await env.MEDIA.head(k)).toBeNull();
    expect(await env.MEDIA.head(keys[3])).not.toBeNull();
  });

  it("eviction without message groups stops as soon as usage is below target", async () => {
    const t0 = Date.now() - 100_000;
    for (let i = 0; i < 10; i++) await insertMedia({ chatId, uploader: alice, bytes: 900 * MiB, createdAt: t0 + i });
    await upload(alice, { chatId }, randomBytes(10));
    // 9000 MiB: dropping two 900 MiB rows leaves 7200 MiB + 10 B < 7680 MiB.
    const n = await env.DB.prepare("SELECT COUNT(*) AS n FROM media WHERE expired_at IS NOT NULL").first<{ n: number }>();
    expect(n!.n).toBe(2);
  });

  it("under the cap nothing is evicted", async () => {
    await insertMedia({ chatId, uploader: alice, bytes: 7 * GiB, createdAt: 1 });
    await upload(alice, { chatId }, randomBytes(10));
    const n = await env.DB.prepare("SELECT COUNT(*) AS n FROM media WHERE expired_at IS NOT NULL").first<{ n: number }>();
    expect(n!.n).toBe(0);
  });

  it("expired media → 410 media_expired", async () => {
    const old = await insertMedia({ chatId, uploader: alice, bytes: 8 * GiB, createdAt: 1 });
    await upload(alice, { chatId }, randomBytes(10));
    const res = await download(bob, old);
    expect(res.status).toBe(410);
    expect(await res.json()).toEqual({ error: "media_expired" });
  });

  it("an object missing from R2 → 410", async () => {
    const key = newId();
    await upload(alice, { chatId, key }, randomBytes(10));
    await env.MEDIA.delete(key);
    expect((await download(bob, key)).status).toBe(410);
  });

  it("eviction notifies chat members over the hub", async () => {
    const old = await insertMedia({ chatId, uploader: alice, bytes: 8 * GiB, createdAt: 1 });
    const b = await listen(bob);
    const e = await listen(eve);
    try {
      await b.next("hello");
      await upload(alice, { chatId }, randomBytes(10));
      expect(await b.next("media_expired")).toEqual({ type: "media_expired", chatId, keys: [old] });
      await new Promise((r) => setTimeout(r, 100));
      expect(e.frames.filter((f) => f.type === "media_expired")).toEqual([]);
    } finally {
      b.close();
      e.close();
    }
  });

  it("usage total matches the sum of live rows", async () => {
    for (let i = 0; i < 5; i++) await upload(alice, { chatId }, randomBytes(100 + i));
    await insertMedia({ chatId, uploader: alice, bytes: 8 * GiB, createdAt: 1 });
    await upload(bob, { chatId }, randomBytes(7));
    const sum = await env.DB.prepare("SELECT COALESCE(SUM(bytes), 0) AS s FROM media WHERE expired_at IS NULL").first<{ s: number }>();
    expect(await usage()).toBe(sum!.s);
  });
});

describe("admin usage", () => {
  it("usage for admins", async () => {
    await upload(alice, { chatId }, randomBytes(300));
    await insertMedia({ chatId, uploader: alice, bytes: 8 * GiB, createdAt: 1 });
    await upload(alice, { chatId }, randomBytes(200));
    const res = await api(alice.accessToken, "GET", "/admin/usage");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      usedBytes: 500, capBytes: 8589934592, evictToBytes: 8053063680, files: 2, expiredFiles: 1,
    });
  });

  it("usage forbidden for members", async () => {
    expect((await api(bob.accessToken, "GET", "/admin/usage")).status).toBe(403);
  });
});
