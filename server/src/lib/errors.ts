export type ErrorCode =
  | "invalid_request"
  | "unauthorized"
  | "forbidden"
  | "not_found"
  | "already_bootstrapped"
  | "invite_invalid"
  | "wraps_mismatch"
  | "epoch_exists"
  | "stale_epoch"
  | "upgrade_required"
  | "rate_limited"
  | "pairing_invalid"
  | "too_large"
  | "media_expired"
  | "conflict"
  | "last_admin"
  | "no_shared_family"
  | "internal";

const STATUS: Record<ErrorCode, number> = {
  invalid_request: 400,
  unauthorized: 401,
  forbidden: 403,
  not_found: 404,
  already_bootstrapped: 409,
  invite_invalid: 410,
  wraps_mismatch: 409,
  epoch_exists: 409,
  stale_epoch: 409,
  upgrade_required: 426,
  rate_limited: 429,
  pairing_invalid: 410,
  too_large: 413,
  media_expired: 410,
  conflict: 409,
  last_admin: 409,
  no_shared_family: 403,
  internal: 500,
};

export class ApiError extends Error {
  readonly status: number;
  constructor(readonly code: ErrorCode, readonly extra?: Record<string, unknown>) {
    super(code);
    this.status = STATUS[code];
  }
}

export function errorResponse(code: ErrorCode, extra?: Record<string, unknown>): Response {
  return Response.json({ ...extra, error: code }, { status: STATUS[code] });
}
