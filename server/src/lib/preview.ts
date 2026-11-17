// Link previews (docs/protocol.md "Link previews"): a page's title, description and image, fetched
// for the sender when they type a link. The server sees the URL; never the message it's in.

export interface Preview {
  url: string;
  title: string;
  description?: string;
  siteName?: string;
  /** The image, base64, at most MAX_IMAGE_BYTES; the app re-encodes it as an encrypted thumbnail. */
  image?: string;
  imageType?: string;
}

const MAX_HTML_BYTES = 1024 * 1024;
const MAX_IMAGE_BYTES = 2 * 1024 * 1024;
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

async function image(fetcher: typeof fetch, src: string | undefined, base: URL): Promise<Pick<Preview, "image" | "imageType">> {
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
  const bytes = await readCapped(res, MAX_IMAGE_BYTES);
  if (!bytes || bytes.length === 0) return {};
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return { image: btoa(bin), imageType: type };
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

  const res = await get(fetcher, url.href, "text/html,application/xhtml+xml");
  if (!res || !(res.headers.get("content-type") ?? "").includes("html")) return null;
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
