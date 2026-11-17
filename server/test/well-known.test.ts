import { createExecutionContext, env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import worker from "../src/index";
import { BASE } from "./helpers";

const get = (path: string, vars: Record<string, string>) =>
  worker.fetch(new Request(`${BASE}${path}`), { ...env, ...vars } as typeof env, createExecutionContext());

const vars = { APPLE_APP_ID: "T.dev.famchat.app", ANDROID_CERT_SHA256: "AA:BB, CC:DD" };

describe("app link association files", () => {
  it("iOS: FamChat handles /join links on famchat.dev", async () => {
    const res = await get("/.well-known/apple-app-site-association", vars);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    const j = await res.json<{ applinks: { details: { appIDs: string[]; components: object[] }[] } }>();
    expect(j.applinks.details[0].appIDs).toEqual(["T.dev.famchat.app"]);
    expect(j.applinks.details[0].components).toEqual([{ "/": "/join" }]);
  });

  it("Android: the app's signing certificates", async () => {
    const res = await get("/.well-known/assetlinks.json", vars);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    expect(await res.json()).toEqual([{
      relation: ["delegate_permission/common.handle_all_urls"],
      target: { namespace: "android_app", package_name: "dev.famchat.app", sha256_cert_fingerprints: ["AA:BB", "CC:DD"] },
    }]);
  });

  it("without configuration there's nothing to serve", async () => {
    expect((await get("/.well-known/apple-app-site-association", { APPLE_APP_ID: "" })).status).toBe(404);
    expect((await get("/.well-known/assetlinks.json", { ANDROID_CERT_SHA256: "" })).status).toBe(404);
  });
});
