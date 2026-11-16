import type { Context } from "hono";
import { ApiError } from "./errors";

export async function readJson(c: Context): Promise<Record<string, unknown>> {
  try {
    const body = await c.req.json();
    if (body && typeof body === "object" && !Array.isArray(body)) return body as Record<string, unknown>;
  } catch {
    /* fall through */
  }
  throw new ApiError("invalid_request");
}

/** Trimmed string between 1 and max characters, else invalid_request. */
export function name(v: unknown, max: number): string {
  if (typeof v !== "string") throw new ApiError("invalid_request");
  const t = v.trim();
  if (t.length < 1 || [...t].length > max) throw new ApiError("invalid_request");
  return t;
}

export function str(v: unknown): string {
  if (typeof v !== "string" || v.length === 0) throw new ApiError("invalid_request");
  return v;
}
