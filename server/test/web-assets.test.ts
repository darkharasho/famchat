import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import wranglerConfig from "../wrangler.jsonc?raw";

// The Worker also serves the Flutter web build (wrangler.jsonc `assets`). SELF.fetch calls the
// Worker directly and skips Cloudflare's asset router, so the routing itself is pinned through the
// config here; scripts/deploy.sh checks the deployed routes.

// wrangler.jsonc only uses whole-line comments.
const config = JSON.parse(wranglerConfig.replace(/^\s*\/\/.*$/gm, "")) as {
  assets?: { directory?: string; not_found_handling?: string; run_worker_first?: unknown };
};

describe("web app hosting", () => {
  it("serves the web build with an SPA fallback, so app routes like /join get index.html", () => {
    expect(config.assets?.directory).toBe("./public");
    expect(config.assets?.not_found_handling).toBe("single-page-application");
  });

  it("runs the Worker first for /api and the app link files, so the SPA fallback never answers them", () => {
    expect(config.assets?.run_worker_first).toEqual(["/api/*", "/.well-known/*"]);
  });

  it("keeps unknown /api routes a JSON 404, even for a browser navigation", async () => {
    for (const init of [undefined, { headers: { "Sec-Fetch-Mode": "navigate", Accept: "text/html" } }]) {
      const res = await SELF.fetch("https://famchat.dev/api/unknown", init);
      expect(res.status).toBe(404);
      expect(res.headers.get("content-type")).toContain("application/json");
      expect(await res.json()).toEqual({ error: "not_found" });
    }
  });
});
