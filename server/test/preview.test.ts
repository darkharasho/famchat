import { beforeEach, describe, expect, it } from "vitest";
import { linkPreview } from "../src/lib/preview";
import { api } from "./chat-helpers";
import { insertUserWithDevice, resetDb } from "./helpers";

type Route = { status?: number; type?: string; body: string | Uint8Array };

/** A fetch that answers from [routes] by URL prefix and records what was asked. */
function fakeWeb(routes: Record<string, Route>) {
  const asked: string[] = [];
  const fetcher = (async (input: RequestInfo | URL) => {
    const url = typeof input === "string" ? input : input instanceof URL ? input.href : input.url;
    asked.push(url);
    const hit = Object.entries(routes).find(([k]) => url.startsWith(k));
    if (!hit) return new Response("nope", { status: 404 });
    const r = hit[1];
    return new Response(r.body, { status: r.status ?? 200, headers: { "content-type": r.type ?? "text/html; charset=utf-8" } });
  }) as typeof fetch;
  return { fetcher, asked };
}

const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 1, 2, 3]);

describe("linkPreview", () => {
  it("YouTube links (shorts too) use YouTube's oEmbed: title, channel and thumbnail", async () => {
    const web = fakeWeb({
      "https://www.youtube.com/oembed": {
        type: "application/json",
        body: JSON.stringify({ title: "Cat jumps", author_name: "Cats Inc", thumbnail_url: "https://i.ytimg.com/vi/x/hq.jpg" }),
      },
      "https://i.ytimg.com/": { type: "image/jpeg", body: jpeg },
    });
    const p = await linkPreview("https://youtube.com/shorts/DAAG0qf4d6I?is=h2lF", web.fetcher);
    expect(p).toMatchObject({ title: "Cat jumps", description: "Cats Inc", siteName: "YouTube", imageType: "image/jpeg" });
    expect(Uint8Array.from(atob(p!.image!), (ch) => ch.charCodeAt(0))).toEqual(jpeg);
    expect(web.asked[0]).toContain(encodeURIComponent("https://youtube.com/shorts/DAAG0qf4d6I"));
  });

  it("other pages: Open Graph tags, entities decoded, relative image made absolute", async () => {
    const web = fakeWeb({
      "https://shop.example/item": {
        body: `<html><head><title>Fallback</title>
          <meta property="og:title" content="Garden &amp; Hose" />
          <meta content="A very long hose" name="description">
          <meta property="og:site_name" content="Shop">
          <meta property="og:image" content="/img/hose.jpg"></head></html>`,
      },
      "https://shop.example/img/hose.jpg": { type: "image/jpeg", body: jpeg },
    });
    const p = await linkPreview("https://shop.example/item", web.fetcher);
    expect(p).toMatchObject({ title: "Garden & Hose", description: "A very long hose", siteName: "Shop" });
    expect(p!.image).toBeDefined();
  });

  it("Amazon pages without Open Graph: the title and the product image", async () => {
    const web = fakeWeb({
      "https://www.amazon.com/dp/B0": {
        body: `<html><head><title>Amazon.com: Kettle, 1.7L : Home</title></head><body>
          <img id="landingImage" data-old-hires="https://m.media-amazon.com/images/I/k.jpg" src="https://m.media-amazon.com/images/I/k._SX300_.jpg"></body></html>`,
      },
      "https://m.media-amazon.com/images/I/k.jpg": { type: "image/jpeg", body: jpeg },
    });
    const p = await linkPreview("https://www.amazon.com/dp/B0", web.fetcher);
    expect(p).toMatchObject({ title: "Amazon.com: Kettle, 1.7L : Home", siteName: "Amazon" });
    expect(p!.image).toBeDefined();
  });

  it("a page without an image still previews; an image that isn't one is dropped", async () => {
    const web = fakeWeb({
      "https://blog.example/": { body: `<title>Just text</title><meta property="og:image" content="https://blog.example/x">` },
      "https://blog.example/x": { type: "text/html", body: "<html>" },
    });
    const p = await linkPreview("https://blog.example/", web.fetcher);
    expect(p).toMatchObject({ title: "Just text" });
    expect(p!.image).toBeUndefined();
  });

  it("refuses non-web schemes, local addresses and pages with nothing to show", async () => {
    const web = fakeWeb({ "https://empty.example/": { body: "<html></html>" } });
    for (const u of ["ftp://x.io/", "javascript:alert(1)", "http://localhost/", "http://127.0.0.1/", "http://10.0.0.2/", "http://[::1]/", "https://empty.example/"]) {
      expect(await linkPreview(u, web.fetcher), u).toBeNull();
    }
  });
});

describe("GET /api/preview", () => {
  beforeEach(resetDb);
  it("needs auth and a url", async () => {
    const u = await insertUserWithDevice();
    expect((await api(u.accessToken, "GET", "/preview")).status).toBe(400);
    expect((await api("nope", "GET", "/preview?url=https%3A%2F%2Fx.io")).status).toBe(401);
  });
});
