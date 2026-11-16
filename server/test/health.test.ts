import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("health", () => {
  it("GET /api/health returns ok", async () => {
    const res = await SELF.fetch("https://famchat.dev/api/health");
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
  });

  it("unknown route returns not_found", async () => {
    const res = await SELF.fetch("https://famchat.dev/api/nope");
    expect(res.status).toBe(404);
    expect(await res.json()).toEqual({ error: "not_found" });
  });
});
