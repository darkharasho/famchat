import { env, SELF } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { api, addDevice } from "./chat-helpers";
import { BASE, insertUserWithDevice, resetDb } from "./helpers";

beforeEach(resetDb);

type UserOut = {
  id: string;
  name: string;
  isAdmin: boolean;
  identityPub: string;
  devices: { id: string; name: string; platform: string; encPub: string; signPub: string; certSig: string; revoked: boolean }[];
};

describe("GET /api/users", () => {
  it("lists every user with devices", async () => {
    const a = await insertUserWithDevice({ name: "Mom", admin: true });
    const b = await insertUserWithDevice({ name: "Kid" });
    const old = await addDevice(b.userId);
    await env.DB.prepare("UPDATE devices SET revoked_at = 5 WHERE id = ?").bind(old).run();
    const res = await api(a.accessToken, "GET", "/users");
    expect(res.status).toBe(200);
    const { users } = await res.json<{ users: UserOut[] }>();
    expect(users.map((u) => u.name).sort()).toEqual(["Kid", "Mom"]);
    const kid = users.find((u) => u.id === b.userId)!;
    expect(kid.isAdmin).toBe(false);
    expect(kid.identityPub).toBe(b.keys.identityPub);
    const live = kid.devices.find((d) => d.id === b.deviceId)!;
    expect(live).toEqual({
      id: b.deviceId, name: "Phone", platform: "android",
      encPub: b.keys.encPub, signPub: b.keys.signPub, certSig: b.keys.certSig, revoked: false,
    });
    expect(kid.devices.find((d) => d.id === old)!.revoked).toBe(true);
    expect(users.find((u) => u.id === a.userId)!.isAdmin).toBe(true);
  });

  it("requires auth", async () => {
    expect((await SELF.fetch(`${BASE}/api/users`)).status).toBe(401);
  });
});
