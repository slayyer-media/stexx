import type { Context } from "hono";
import { HTTPException } from "hono/http-exception";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import { ZodError } from "zod";
import { config } from "../config.ts";
import { logError } from "./logger.ts";

/** Every non-2xx response body: `{ code, message }`. `message` may be shown to the user. */
export interface ErrorBody {
  code: string;
  message: string;
}

/** Throw from anywhere in a request; the app's onError turns it into `{code,message}` with `status`. */
export class ApiError extends Error {
  override name = "ApiError";
  constructor(
    readonly status: ContentfulStatusCode,
    readonly code: string,
    message: string,
    /** Extra response headers, e.g. Retry-After. */
    readonly headers: Record<string, string> = {},
  ) {
    super(message);
  }
}

export const badRequest = (message: string, code = "validation_error") => new ApiError(400, code, message);
export const unauthorized = (message = "Sign in again.", code = "unauthorized") => new ApiError(401, code, message);
export const requiresPlus = (message = "This feature is part of Stexx+.") => new ApiError(402, "requires_plus", message);
export const forbidden = (message = "Not allowed.", code = "forbidden") => new ApiError(403, code, message);
/** Also used for anything hidden by a block. Never reveal whether the thing exists. */
export const notFound = (message = "Not found.") => new ApiError(404, "not_found", message);
export const conflict = (message: string, code = "conflict") => new ApiError(409, code, message);
export const tooManyRequests = (retryAfterSeconds: number) =>
  new ApiError(429, "rate_limited", "Slow down a little and try again in a moment.", {
    "Retry-After": String(Math.max(1, Math.ceil(retryAfterSeconds))),
  });
export const serviceUnavailable = (code: string, message: string) => new ApiError(503, code, message);

export function errorResponse(c: Context, status: ContentfulStatusCode, code: string, message: string) {
  return c.json<ErrorBody>({ code, message }, status);
}

function zodMessage(err: ZodError): string {
  const issue = err.issues[0];
  if (!issue) return "Invalid request.";
  const path = issue.path.join(".");
  return path ? `${path}: ${issue.message}` : issue.message;
}

/** app.onError handler. Never leaks stacks/SQL/request data to the client. */
export function onError(err: Error, c: Context) {
  if (err instanceof ApiError) {
    for (const [k, v] of Object.entries(err.headers)) c.header(k, v);
    return errorResponse(c, err.status, err.code, err.message);
  }
  if (err instanceof ZodError) {
    return errorResponse(c, 400, "validation_error", zodMessage(err));
  }
  if (err instanceof HTTPException) {
    const status = err.status as ContentfulStatusCode;
    if (status === 413) return errorResponse(c, 413, "payload_too_large", "That upload is too large.");
    if (status === 401) return errorResponse(c, 401, "unauthorized", "Sign in again.");
    return errorResponse(c, status, "http_error", status >= 500 ? "Something went wrong on our side." : "Bad request.");
  }
  // Postgres rejected a character in client input (NUL in text, or not representable in UTF-8). That is a bad
  // request, not a server error: don't log it as one (cheap log/alert flooding otherwise).
  const pgCode = (err as { code?: unknown }).code;
  if (pgCode === "22021" || pgCode === "22P05") {
    return errorResponse(c, 400, "validation_error", "The request contains invalid characters.");
  }
  logError("unhandled", err);
  const message = config.isProduction ? "Something went wrong on our side." : `Internal error: ${err.message}`;
  return errorResponse(c, 500, "internal_error", message);
}

/** app.notFound handler. */
export function onNotFound(c: Context) {
  return errorResponse(c, 404, "not_found", "Not found.");
}
