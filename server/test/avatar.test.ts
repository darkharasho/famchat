import { env, SELF } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { api, type TestUser } from "./chat-helpers";
import { BASE, insertUserWithDevice, resetDb } from "./helpers";
import { closeSockets, socket } from "./ws-helpers";

beforeEach(resetDb);
afterEach(closeSockets);

/** A tiny "JPEG": the SOI marker and some bytes. */
const jpeg = (n = 100, fill = 7) => {
  const b = new Uint8Array(n).fill(fill);
  b.set([0xff, 0xd8, 0xff]);
  return b;
};

const put = (u: TestUser, body: Uint8Array, type = "image/jpeg") =>
  SELF.fetch(`${BASE}/api/me/avatar`, {
    method: "PUT",
    headers: { authorization: `Bearer ${u.accessToken}`, "content-type": type },
    body,
  });

const get = (u: TestUser, userId: string, v?: string) =>
  SELF.fetch(`${BASE}/api/users/${userId}/avatar${v ? `?v=${v}` : ""}`, { headers: { authorization: `Bearer ${u.accessToken}` } });

type Dir = { users: { id: string; avatarKey: string | null }[] };
const avatarKeyOf = async (viewer: TestUser, userId: string) =>
  (await (await api(viewer.accessToken, "GET", "/users")).json<Dir>()).users.find((x) => x.id === userId)!.avatarKey;

describe("profile photos", () => {
  it("are set, listed in the directory, served to the family and replaced", async () => {
    const mom = await insertUserWithDevice({ name: "Mom" });
    const kid = await insertUserWithDevice({ name: "Kid" });
    expect(await avatarKeyOf(kid, mom.userId)).toBeNull();

    const res = await put(mom, jpeg(100));
    expect(res.status).toBe(200);
    const { avatarKey } = await res.json<{ avatarKey: string }>();
    expect(await avatarKeyOf(kid, mom.userId)).toBe(avatarKey);

    const img = await get(kid, mom.userId, avatarKey);
    expect(img.status).toBe(200);
    expect(img.headers.get("content-type")).toBe("image/jpeg");
    expect(img.headers.get("cache-control")).toContain("immutable");
    expect(new Uint8Array(await img.arrayBuffer())).toEqual(jpeg(100));

    // A new photo gets a new key; the old one is gone.
    const second = (await (await put(mom, jpeg(50, 9))).json<{ avatarKey: string }>()).avatarKey;
    expect(second).not.toBe(avatarKey);
    expect((await get(kid, mom.userId, avatarKey)).status).toBe(404);
    expect(new Uint8Array(await (await get(kid, mom.userId, second)).arrayBuffer())).toEqual(jpeg(50, 9));
    expect((await get(kid, mom.userId)).status).toBe(200); // without v: the current one
    expect(await env.MEDIA.get(`avatars/${mom.userId}/${avatarKey}`)).toBeNull();
  });

  it("can be removed", async () => {
    const mom = await insertUserWithDevice();
    const { avatarKey } = await (await put(mom, jpeg())).json<{ avatarKey: string }>();
    expect((await api(mom.accessToken, "DELETE", "/me/avatar")).status).toBe(204);
    expect(await avatarKeyOf(mom, mom.userId)).toBeNull();
    expect((await get(mom, mom.userId)).status).toBe(404);
    expect(await env.MEDIA.get(`avatars/${mom.userId}/${avatarKey}`)).toBeNull();
  });

  it("must be a JPEG of at most 256 KiB", async () => {
    const mom = await insertUserWithDevice();
    expect((await put(mom, new Uint8Array([1, 2, 3, 4]))).status).toBe(400);
    expect((await put(mom, jpeg(), "image/png")).status).toBe(400);
    expect((await put(mom, jpeg(256 * 1024 + 1))).status).toBe(413);
    expect((await put(mom, new Uint8Array(0))).status).toBe(400);
  });

  it("tell everyone on the same side to refresh the directory", async () => {
    const mom = await insertUserWithDevice();
    const kid = await insertUserWithDevice(); // shares no chat with mom yet
    const reviewer = await insertUserWithDevice({ reviewer: true });
    const sk = await socket(kid);
    const sr = await socket(reviewer);
    await put(mom, jpeg());
    expect(await sk.next("profile")).toMatchObject({ userId: mom.userId });
    await sr.none("profile");
  });

  it("aren't visible across the reviewer line", async () => {
    const mom = await insertUserWithDevice();
    const reviewer = await insertUserWithDevice({ reviewer: true });
    await put(mom, jpeg());
    expect((await get(reviewer, mom.userId)).status).toBe(404);
  });

  it("go with a deleted account", async () => {
    const mom = await insertUserWithDevice();
    const kid = await insertUserWithDevice();
    const { avatarKey } = await (await put(kid, jpeg())).json<{ avatarKey: string }>();
    expect((await api(kid.accessToken, "DELETE", "/me", { confirm: "delete" })).status).toBe(204);
    expect(await env.MEDIA.get(`avatars/${kid.userId}/${avatarKey}`)).toBeNull();
    expect(await avatarKeyOf(mom, kid.userId)).toBeNull();
  });
});
