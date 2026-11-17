import { env } from "cloudflare:test";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { api } from "./chat-helpers";
import { insertUserWithDevice, resetDb } from "./helpers";
import { closeSockets, socket } from "./ws-helpers";

beforeEach(resetDb);
afterEach(closeSockets);

describe("PUT /api/me/name", () => {
  it("renames the caller, shown in /me and the directory, and tells their side", async () => {
    const mom = await insertUserWithDevice({ name: "Mom" });
    const kid = await insertUserWithDevice({ name: "Kid" });
    const reviewer = await insertUserWithDevice({ reviewer: true });
    const sk = await socket(kid);
    const sr = await socket(reviewer);
    expect((await api(mom.accessToken, "PUT", "/me/name", { name: "  Grandma Rose  " })).status).toBe(204);
    expect((await (await api(mom.accessToken, "GET", "/me")).json<{ name: string }>()).name).toBe("Grandma Rose");
    const dir = await (await api(kid.accessToken, "GET", "/users")).json<{ users: { id: string; name: string }[] }>();
    expect(dir.users.find((u) => u.id === mom.userId)!.name).toBe("Grandma Rose");
    expect(await sk.next("profile")).toMatchObject({ userId: mom.userId });
    await sr.none("profile");
  });

  it("refuses an empty or overlong name, or one with control characters", async () => {
    const mom = await insertUserWithDevice({ name: "Mom" });
    for (const name of ["", "   ", "x".repeat(41), "a\nb", 5]) {
      expect((await api(mom.accessToken, "PUT", "/me/name", { name })).status, String(name)).toBe(400);
    }
    expect(await env.DB.prepare("SELECT name FROM users WHERE id = ?").bind(mom.userId).first("name")).toBe("Mom");
  });
});
