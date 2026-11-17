// App link association files (docs/superpowers/specs/2026-11-17-app-links-design.md): they let
// iOS and Android open famchat.dev/join links in the installed app. Served by the Worker, so the
// Apple app id and the Android certificate fingerprints come from configuration.
import { Hono } from "hono";
import type { Env } from "../env";

export const wellKnown = new Hono<{ Bindings: Env }>();

const json = (body: unknown) =>
  new Response(JSON.stringify(body), { headers: { "content-type": "application/json", "cache-control": "public, max-age=3600" } });

wellKnown.get("/.well-known/apple-app-site-association", (c) => {
  const appId = c.env.APPLE_APP_ID?.trim();
  if (!appId) return c.notFound();
  return json({ applinks: { details: [{ appIDs: [appId], components: [{ "/": "/join" }] }] } });
});

wellKnown.get("/.well-known/assetlinks.json", (c) => {
  const prints = (c.env.ANDROID_CERT_SHA256 ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (prints.length === 0) return c.notFound();
  return json([{
    relation: ["delegate_permission/common.handle_all_urls"],
    target: { namespace: "android_app", package_name: "dev.famchat.app", sha256_cert_fingerprints: prints },
  }]);
});
