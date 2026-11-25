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

  // GIF89a, 2x1, then a NETSCAPE2.0 loop block and two frames (graphic control extensions).
  const gif = (bytes = 0) => {
    const head = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 2, 0, 1, 0, 0, 0, 0];
    const loop = [0x21, 0xff, 0x0b, ...[..."NETSCAPE2.0"].map((ch) => ch.charCodeAt(0)), 3, 1, 0, 0, 0];
    const frame = [0x21, 0xf9, 0x04, 0, 10, 0, 0, 0, 0x2c, 0, 0, 0, 0, 2, 0, 1, 0, 0, 2, 2, 0x4c, 0x01, 0];
    return new Uint8Array([...head, ...loop, ...frame, ...frame, ...new Array(bytes).fill(0), 0x3b]);
  };
  const stillGif = new Uint8Array([0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 2, 0, 1, 0, 0, 0, 0,
    0x21, 0xf9, 0x04, 0, 0, 0, 0, 0, 0x2c, 0, 0, 0, 0, 2, 0, 1, 0, 0, 2, 2, 0x4c, 0x01, 0, 0x3b]);

  it("a link straight to a GIF: the animated image itself, over the still-image cap", async () => {
    const big = gif(3 * 1024 * 1024);
    const web = fakeWeb({ "https://media.example/cats/dance%20party.gif": { type: "image/gif", body: big } });
    const p = await linkPreview("https://media.example/cats/dance%20party.gif", web.fetcher);
    expect(p).toMatchObject({
      url: "https://media.example/cats/dance%20party.gif",
      title: "dance party.gif",
      siteName: "media.example",
      imageType: "image/gif",
      animated: true,
    });
    expect(Uint8Array.from(atob(p!.image!), (ch) => ch.charCodeAt(0))).toEqual(big);
  });

  it("a GIF page (Tenor, Giphy): its animated og:image, marked animated; still images aren't", async () => {
    const web = fakeWeb({
      "https://tenor.com/view/cat-dance-gif-1": {
        body: `<meta property="og:title" content="Cat Dance GIF"><meta property="og:site_name" content="Tenor">
          <meta property="og:image" content="https://media1.tenor.com/m/x/cat-dance.gif">`,
      },
      "https://media1.tenor.com/m/x/cat-dance.gif": { type: "image/gif", body: gif(2 * 1024 * 1024) },
      "https://still.example/s.gif": { type: "image/gif", body: stillGif },
      "https://still.example/": { body: `<title>Still</title><meta property="og:image" content="https://still.example/s.gif">` },
    });
    const p = await linkPreview("https://tenor.com/view/cat-dance-gif-1", web.fetcher);
    expect(p).toMatchObject({ title: "Cat Dance GIF", siteName: "Tenor", imageType: "image/gif", animated: true });
    const still = await linkPreview("https://still.example/", web.fetcher);
    expect(still!.image).toBeDefined();
    expect(still!.animated).toBeUndefined();
  });

  it("GIFs over 8 MiB, still images over 2 MiB and direct still images get no image", async () => {
    const web = fakeWeb({
      "https://media.example/huge.gif": { type: "image/gif", body: gif(8 * 1024 * 1024) },
      "https://media.example/still.gif": { type: "image/gif", body: stillGif },
      "https://shop.example/big.jpg": { type: "image/jpeg", body: new Uint8Array(2 * 1024 * 1024 + 1) },
      "https://shop.example/": { body: `<title>Shop</title><meta property="og:image" content="https://shop.example/big.jpg">` },
    });
    expect(await linkPreview("https://media.example/huge.gif", web.fetcher)).toBeNull();
    expect(await linkPreview("https://media.example/still.gif", web.fetcher)).toBeNull();
    expect((await linkPreview("https://shop.example/", web.fetcher))!.image).toBeUndefined();
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
