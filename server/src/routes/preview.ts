// GET /preview?url= → a link preview for the app (docs/protocol.md "Link previews").
import { Hono } from "hono";
import type { AppEnv } from "../env";
import { ApiError } from "../lib/errors";
import { linkPreview } from "../lib/preview";
import { requireAuth } from "../middleware/auth";

export const preview = new Hono<AppEnv>();
preview.use(requireAuth);

const CACHE_SECONDS = 24 * 60 * 60;

preview.get("/", async (c) => {
  const url = c.req.query("url");
  if (!url || url.length > 2048) throw new ApiError("invalid_request");
  // Cached per URL for a day (the same link is often shared to several chats).
  const cacheKey = new Request(`https://famchat-preview.invalid/?u=${encodeURIComponent(url)}`);
  const cache = (globalThis as { caches?: CacheStorage }).caches?.default as Cache | undefined;
  const hit = await cache?.match(cacheKey);
  if (hit) return new Response(hit.body, hit);
  const p = await linkPreview(url);
  if (!p) throw new ApiError("not_found");
  const res = new Response(JSON.stringify(p), {
    headers: { "content-type": "application/json", "cache-control": `private, max-age=${CACHE_SECONDS}` },
  });
  if (cache) {
    const stored = new Response(JSON.stringify(p), {
      headers: { "content-type": "application/json", "cache-control": `public, max-age=${CACHE_SECONDS}` },
    });
    c.executionCtx.waitUntil(cache.put(cacheKey, stored));
  }
  return res;
});
