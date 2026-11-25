// Link previews (docs/protocol.md "Link previews"): a page's title, description and image, fetched
// for the sender when they type a link. The server sees the URL; never the message it's in.

export interface Preview {
  url: string;
  title: string;
  description?: string;
  siteName?: string;
  /**
   * The image, base64: at most MAX_IMAGE_BYTES, which the app re-encodes as an encrypted thumbnail,
   * or an animated GIF/WebP of at most MAX_ANIMATED_BYTES, which the app sends as it is.
   */
  image?: string;
  imageType?: string;
  /** The image is an animated GIF or WebP (a GIF link: Tenor, Giphy, a direct .gif). */
  animated?: boolean;
}

const MAX_HTML_BYTES = 1024 * 1024;
const MAX_IMAGE_BYTES = 2 * 1024 * 1024;
const MAX_ANIMATED_BYTES = 8 * 1024 * 1024;
const TIMEOUT_MS = 6000;
// Many sites (Amazon among them) answer chat-app preview bots with the page's tags and turn
// generic bots away. Signal sends a WhatsApp-style agent for the same reason.
const USER_AGENT = "WhatsApp/2.24 FamChat-LinkPreview (+https://famchat.dev)";

const YOUTUBE = /^(?:www\.|m\.|music\.)?youtube\.com$|^youtu\.be$/i;

/** Hosts a preview never fetches: loopback, private and link-local addresses, and bare names. */
function blockedHost(host: string): boolean {
  const h = host.replace(/^\[|\]$/g, "").toLowerCase();
  if (h === "localhost" || h.endsWith(".localhost") || h.endsWith(".local") || h.endsWith(".internal")) return true;
  if (!h.includes(".") && !h.includes(":")) return true;
  if (h.includes(":")) return true; // IPv6 literals: no previews
  const m = h.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (!m) return false;
  const [a, b] = [Number(m[1]), Number(m[2])];
  return a === 0 || a === 10 || a === 127 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127) || a >= 224;
}

function webUrl(raw: string): URL | null {
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return null;
  }
  if ((u.protocol !== "https:" && u.protocol !== "http:") || blockedHost(u.hostname)) return null;
  return u;
}

async function get(fetcher: typeof fetch, url: string, accept: string): Promise<Response | null> {
  try {
    const res = await fetcher(url, {
      headers: { "user-agent": USER_AGENT, accept, "accept-language": "en" },
      redirect: "follow",
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    return res.ok ? res : null;
  } catch {
    return null;
  }
}

/** At most [max] bytes of [res]'s body. */
async function readCapped(res: Response, max: number): Promise<Uint8Array | null> {
  const reader = res.body?.getReader();
  if (!reader) return null;
  const parts: Uint8Array[] = [];
  let n = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    n += value.length;
    if (n > max) {
      await reader.cancel().catch(() => {});
      return null;
    }
    parts.push(value);
  }
  const out = new Uint8Array(n);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

const ENTITIES: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };

function decode(s: string): string {
  return s
    .replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (all, e: string) => {
      if (e[0] === "#") {
        const code = e[1].toLowerCase() === "x" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
        return Number.isFinite(code) && code > 0 && code < 0x110000 ? String.fromCodePoint(code) : all;
      }
      return ENTITIES[e.toLowerCase()] ?? all;
    })
    .replace(/\s+/g, " ")
    .trim();
}

/** The content of the first <meta> whose property or name is one of [keys]. */
function meta(html: string, ...keys: string[]): string | undefined {
  for (const tag of html.match(/<meta\b[^>]*>/gi) ?? []) {
    const key = tag.match(/\b(?:property|name)\s*=\s*["']([^"']+)["']/i)?.[1]?.toLowerCase();
    if (!key || !keys.includes(key)) continue;
    const content = tag.match(/\bcontent\s*=\s*"([^"]*)"|\bcontent\s*=\s*'([^']*)'/i);
    const v = content?.[1] ?? content?.[2];
    if (v && decode(v)) return decode(v);
  }
  return undefined;
}

function clip(s: string | undefined, max: number): string | undefined {
  if (!s) return undefined;
  return [...s].length > max ? [...s].slice(0, max - 1).join("") + "…" : s;
}

/** Whether [bytes] (of content type [type]) is an animated GIF (2+ frames) or animated WebP. */
export function isAnimated(bytes: Uint8Array, type: string): boolean {
  const b = bytes;
  if (type === "image/gif") {
    if (b.length < 13 || b[0] !== 0x47 || b[1] !== 0x49 || b[2] !== 0x46) return false; // "GIF"
    // A looping animation's NETSCAPE2.0 block, or a second frame's graphic control extension.
    let controls = 0;
    for (let i = 13; i + 3 < b.length; i++) {
      if (b[i] !== 0x21) continue;
      if (b[i + 1] === 0xff && b[i + 2] === 0x0b && b[i + 3] === 0x4e) return true; // "N"ETSCAPE2.0
      if (b[i + 1] === 0xf9 && b[i + 2] === 0x04 && ++controls >= 2) return true;
    }
    return false;
  }
  if (type === "image/webp") {
    const ascii = (at: number, s: string) => [...s].every((ch, k) => b[at + k] === ch.charCodeAt(0));
    // RIFF....WEBPVP8X with the animation flag.
    return b.length >= 30 && ascii(0, "RIFF") && ascii(8, "WEBPVP8X") && (b[20] & 0x02) !== 0;
  }
  return false;
}

function base64(bytes: Uint8Array): string {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

const ANIMATED_TYPES = new Set(["image/gif", "image/webp"]);

async function image(
  fetcher: typeof fetch,
  src: string | undefined,
  base: URL,
): Promise<Pick<Preview, "image" | "imageType" | "animated">> {
  if (!src) return {};
  let u: URL | null;
  try {
    u = webUrl(new URL(src, base).href);
  } catch {
    u = null;
  }
  if (!u) return {};
  const res = await get(fetcher, u.href, "image/*");
  const type = res?.headers.get("content-type")?.split(";")[0].trim().toLowerCase();
  if (!res || !type?.startsWith("image/") || type === "image/svg+xml") return {};
  // GIFs (and animated WebP) may be larger: they're sent as they are, not as a thumbnail.
  const bytes = await readCapped(res, ANIMATED_TYPES.has(type) ? MAX_ANIMATED_BYTES : MAX_IMAGE_BYTES);
  if (!bytes || bytes.length === 0) return {};
  const animated = isAnimated(bytes, type);
  if (!animated && bytes.length > MAX_IMAGE_BYTES) return {};
  return { image: base64(bytes), imageType: type, ...(animated ? { animated } : {}) };
}

/** A link straight to an animated GIF or WebP: the image itself, named after its file. */
async function directGif(res: Response, url: URL, type: string): Promise<Preview | null> {
  const bytes = await readCapped(res, MAX_ANIMATED_BYTES);
  if (!bytes || !isAnimated(bytes, type)) return null;
  let file = url.pathname.split("/").filter(Boolean).pop() ?? "";
  try {
    file = decodeURIComponent(file);
  } catch {
    // keep it encoded
  }
  return {
    url: url.href,
    title: clip(file || url.hostname, 200)!,
    siteName: clip(url.hostname.replace(/^www\./, ""), 80),
    image: base64(bytes),
    imageType: type,
    animated: true,
  };
}

/** A preview of [raw], or null when it isn't a public web page with at least a title. */
export async function linkPreview(raw: string, fetcher: typeof fetch = fetch): Promise<Preview | null> {
  const url = webUrl(raw);
  if (!url) return null;

  if (YOUTUBE.test(url.hostname)) {
    const res = await get(fetcher, `https://www.youtube.com/oembed?format=json&url=${encodeURIComponent(url.href)}`, "application/json");
    const j = res ? await res.json<Record<string, unknown>>().catch(() => null) : null;
    if (!j || typeof j.title !== "string") return null;
    return {
      url: url.href,
      title: clip(decode(j.title), 200)!,
      description: typeof j.author_name === "string" ? clip(j.author_name, 300) : undefined,
      siteName: "YouTube",
      ...(await image(fetcher, typeof j.thumbnail_url === "string" ? j.thumbnail_url : undefined, url)),
    };
  }

  const res = await get(fetcher, url.href, "text/html,application/xhtml+xml,image/gif;q=0.9,image/webp;q=0.9");
  if (!res) return null;
  const type = (res.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
  if (ANIMATED_TYPES.has(type)) return directGif(res, url, type);
  if (!type.includes("html")) return null;
  const bytes = await readCapped(res, MAX_HTML_BYTES);
  if (!bytes) return null;
  const html = new TextDecoder().decode(bytes);
  const finalUrl = webUrl(res.url || url.href) ?? url;
  const title = meta(html, "og:title", "twitter:title") ??
    (html.match(/<title[^>]*>([^<]*)<\/title>/i)?.[1] ? decode(html.match(/<title[^>]*>([^<]*)<\/title>/i)![1]) : undefined);
  if (!title) return null;
  const amazon = /(^|\.)amazon\.[a-z.]+$/i.test(finalUrl.hostname);
  const imageSrc = meta(html, "og:image", "og:image:url", "og:image:secure_url", "twitter:image", "twitter:image:src") ??
    (amazon ? html.match(/data-old-hires\s*=\s*"(https:[^"]+)"/i)?.[1] ??
      html.match(/id\s*=\s*"landingImage"[^>]*\bsrc\s*=\s*"(https:[^"]+)"/i)?.[1] : undefined);
  return {
    url: finalUrl.href,
    title: clip(title, 200)!,
    description: clip(meta(html, "og:description", "twitter:description", "description"), 300),
    siteName: clip(meta(html, "og:site_name") ?? (amazon ? "Amazon" : undefined), 80),
    ...(await image(fetcher, imageSrc ? decode(imageSrc) : undefined, finalUrl)),
  };
}
