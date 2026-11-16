export type ErrorCode =
  | "invalid_request"
  | "unauthorized"
  | "forbidden"
  | "not_found"
  | "already_bootstrapped"
  | "invite_invalid"
  | "internal";

const STATUS: Record<ErrorCode, number> = {
  invalid_request: 400,
  unauthorized: 401,
  forbidden: 403,
  not_found: 404,
  already_bootstrapped: 409,
  invite_invalid: 410,
  internal: 500,
};

export class ApiError extends Error {
  readonly status: number;
  constructor(readonly code: ErrorCode) {
    super(code);
    this.status = STATUS[code];
  }
}

export function errorResponse(code: ErrorCode): Response {
  return Response.json({ error: code }, { status: STATUS[code] });
}
