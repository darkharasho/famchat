// Signed account resets (docs/protocol.md "Account resets"). Byte strings match the client's
// app/lib/crypto/reset.dart.
import { b64urlDecode } from "./encoding";
import { ApiError } from "./errors";
import { newId } from "./ids";

const enc = new TextEncoder();

/** Max distance between a statement's signed time and the server's clock. */
export const RESET_CLOCK_SKEW_MS = 10 * 60 * 1000;

class Writer {
  private parts: Uint8Array[] = [];
  constructor(domain: string) {
    this.parts.push(enc.encode(domain));
  }
  str(s: string): this {
    const b = enc.encode(s);
    if (b.length > 0xffff) throw new ApiError("invalid_request");
    this.parts.push(new Uint8Array([b.length >> 8, b.length & 0xff]), b);
    return this;
  }
  bytes(b: Uint8Array): this {
    this.parts.push(b);
    return this;
  }
  u64(v: number): this {
    const hi = Math.floor(v / 0x100000000);
    const lo = v % 0x100000000;
    const out = new Uint8Array(8);
    const dv = new DataView(out.buffer);
    dv.setUint32(0, hi);
    dv.setUint32(4, lo);
    this.parts.push(out);
    return this;
  }
  finish(): Uint8Array {
    const n = this.parts.reduce((a, p) => a + p.length, 0);
    const out = new Uint8Array(n);
    let o = 0;
    for (const p of this.parts) {
      out.set(p, o);
      o += p.length;
    }
    return out;
  }
}

export interface ResetStatement {
  resetId: string;
  userId: string;
  signerUserId: string;
  signerKind: "admin" | "recovery";
  oldIdentityPub: string;
  claimPub: string;
  createdAt: number;
}

export function resetMessage(s: ResetStatement): Uint8Array {
  return new Writer("famchat-reset-v1")
    .str(s.resetId)
    .str(s.userId)
    .str(s.signerUserId)
    .str(s.signerKind)
    .bytes(key32(s.oldIdentityPub))
    .bytes(key32(s.claimPub))
    .u64(s.createdAt)
    .finish();
}

export function claimMessage(claimPub: string, newIdentityPub: string): Uint8Array {
  return new Writer("famchat-reset-claim-v1").bytes(key32(claimPub)).bytes(key32(newIdentityPub)).finish();
}

export function recoveryKeyMessage(userId: string, recoveryPub: string): Uint8Array {
  return new Writer("famchat-recovery-key-v1").str(userId).bytes(key32(recoveryPub)).finish();
}

/** `"famchat-admin-v1" ‖ str(userId) ‖ str(byUserId)`: [byUserId] made [userId] an admin. */
export function promotionMessage(userId: string, byUserId: string): Uint8Array {
  return new Writer("famchat-admin-v1").str(userId).str(byUserId).finish();
}

/**
 * `"famchat-admin-v2" ‖ str(String(familyId)) ‖ str(userId) ‖ str(byUserId)`: [byUserId] made [userId]
 * an admin of family [familyId]. The family id is in the signed bytes so a proof can't be replayed
 * into another family.
 */
export function promotionMessageV2(familyId: number, userId: string, byUserId: string): Uint8Array {
  return new Writer("famchat-admin-v2").str(String(familyId)).str(userId).str(byUserId).finish();
}

function key32(b64: string): Uint8Array {
  const b = b64urlDecode(b64);
  if (b.length !== 32) throw new ApiError("invalid_request");
  return b;
}

/** Ed25519 verify; never throws. */
export async function verifyEd25519(pub: string, sig: string, msg: Uint8Array): Promise<boolean> {
  try {
    const p = b64urlDecode(pub);
    const s = b64urlDecode(sig);
    if (p.length !== 32 || s.length !== 64) return false;
    const key = await crypto.subtle.importKey("raw", p, { name: "Ed25519" }, false, ["verify"]);
    return await crypto.subtle.verify("Ed25519", key, s, msg);
  } catch {
    return false;
  }
}

/** A base64url 32-byte public key field, else invalid_request. */
export function pubKey(v: unknown): string {
  if (typeof v !== "string") throw new ApiError("invalid_request");
  key32(v);
  return v;
}

/** A base64url 64-byte signature field, else invalid_request. */
export function signature(v: unknown): string {
  if (typeof v !== "string" || b64urlDecode(v).length !== 64) throw new ApiError("invalid_request");
  return v;
}

/** A signed time within [RESET_CLOCK_SKEW_MS] of now, else invalid_request. */
export function freshTime(v: unknown, now: number): number {
  if (!Number.isSafeInteger(v) || Math.abs((v as number) - now) > RESET_CLOCK_SKEW_MS) {
    throw new ApiError("invalid_request");
  }
  return v as number;
}

/**
 * An audit-log insert, to put in a batch (or run on its own). With [guard] (an SQL condition and
 * its values), the row is only written if the condition holds when the statement runs.
 */
export function eventStmt(
  db: D1Database,
  e: { kind: string; userId?: string | null; actorId?: string | null; payload?: Record<string, unknown>; at?: number },
  guard: { sql: string; binds: unknown[] } = { sql: "1", binds: [] },
): D1PreparedStatement {
  return db.prepare(
    `INSERT INTO events (id, kind, user_id, actor_id, payload, created_at) SELECT ?, ?, ?, ?, ?, ? WHERE ${guard.sql}`,
  ).bind(newId(), e.kind, e.userId ?? null, e.actorId ?? null, JSON.stringify(e.payload ?? {}), e.at ?? Date.now(), ...guard.binds);
}

/** Best-effort audit row outside a transaction: a failed log never fails the request. */
export async function logEvent(db: D1Database, e: Parameters<typeof eventStmt>[1]): Promise<void> {
  try {
    await eventStmt(db, e).run();
  } catch (err) {
    console.error("event log failed", err);
  }
}

export interface ResetRow {
  id: string;
  user_id: string;
  signer_user_id: string;
  signer_kind: string;
  signer_pub: string;
  recovery_sig: string | null;
  old_identity_pub: string;
  claim_pub: string;
  created_at: number;
  sig: string;
  new_identity_pub: string | null;
  claim_sig: string | null;
  completed_at: number | null;
}

/** A reset as the directory shows it. */
export function resetOut(r: ResetRow) {
  return {
    id: r.id,
    signerUserId: r.signer_user_id,
    signerKind: r.signer_kind,
    signerPub: r.signer_pub,
    recoverySig: r.recovery_sig,
    oldIdentityPub: r.old_identity_pub,
    claimPub: r.claim_pub,
    createdAt: r.created_at,
    sig: r.sig,
    newIdentityPub: r.new_identity_pub,
    claimSig: r.claim_sig,
    completedAt: r.completed_at,
  };
}
