import type { MiddlewareHandler } from "hono";
import { routePath } from "hono/route";
import { config } from "../config.ts";

/**
 * Privacy-preserving logging. Request lines carry ONLY: method, matched route PATTERN
 * (e.g. /v1/profiles/:id), status, duration. Never bodies, query strings, tokens, IPs, user agents,
 * emails, coordinates or message text. Do not add fields here without updating the privacy review.
 */

let silent = config.isTest && process.env.STEXX_TEST_LOGS !== "1";
let sink: ((line: string) => void) | null = null;

/** Tests silence logs by default; set STEXX_TEST_LOGS=1 to see them. */
export function setLogSilent(value: boolean) {
  silent = value;
}

/** Tests: receive every log line (JSON text) instead of stdout, even while silent. `null` restores stdout. */
export function setLogSinkForTests(fn: ((line: string) => void) | null) {
  sink = fn;
}

function write(line: Record<string, unknown>) {
  if (sink) {
    sink(JSON.stringify({ t: new Date().toISOString(), ...line }));
    return;
  }
  if (silent) return;
  console.log(JSON.stringify({ t: new Date().toISOString(), ...line }));
}

/** Free-form operational event. `fields` must not contain user data (ids are OK only if unavoidable). */
export function logInfo(event: string, fields: Record<string, string | number | boolean> = {}) {
  write({ level: "info", event, ...fields });
}

/** Longest error message kept in a log line (after redaction). */
export const MAX_LOGGED_MESSAGE = 200;

const QUOTES = ['"', "'", "`", "\u201c", "\u2018"] as const;
const CLOSING: Record<string, string> = { "\u201c": "\u201d", "\u2018": "\u2019" };
const EMAIL_RE = /[^\s"'`<>()[\]{},;:]*@[^\s"'`<>()[\]{},;]+/g;
/** Base64/base64url/hex-ish runs: tokens, keys, storage names, hashes. */
const TOKEN_RE = /[A-Za-z0-9+/=_-]{20,}/g;
/** Decimals with 3+ fractional digits (coordinates), then any run of 7+ digits (phone numbers, ids, amounts). */
const DECIMAL_RE = /\d+[.,]\d{3,}/g;
const LONG_NUMBER_RE = /\d{7,}/g;

/**
 * Strip quoted spans. A quoted span runs from the first opening quote to the LAST matching closing quote, so a
 * value that itself contains the quote character can't leak its tail; an unmatched opening quote redacts to the
 * end. An apostrophe between two letters ("couldn't") is not an opening quote.
 */
function stripQuoted(text: string): string {
  let s = text;
  for (const open of QUOTES) {
    const close = CLOSING[open] ?? open;
    let start = -1;
    for (let i = 0; i < s.length; i++) {
      if (s[i] !== open) continue;
      if (open === "'" && /\p{L}/u.test(s[i - 1] ?? "") && /\p{L}/u.test(s[i + 1] ?? "")) continue;
      start = i;
      break;
    }
    if (start < 0) continue;
    const end = s.lastIndexOf(close);
    s = end > start ? `${s.slice(0, start)}${open}?${close}${s.slice(end + 1)}` : `${s.slice(0, start)}${open}?`;
  }
  return s;
}

/**
 * An error message that is safe to log: Postgres and system errors can echo user input
 * (`invalid input syntax for type uuid: "<value>"`, a file path, an address). Removes quoted literals, emails,
 * long tokens, coordinates and numbers longer than 6 digits, collapses whitespace and truncates to
 * MAX_LOGGED_MESSAGE characters. The error class and the Postgres `code`/`routine` are logged as separate fields by
 * logError (they never contain input).
 */
export function redactMessage(err: unknown): string {
  const raw = err instanceof Error ? err.message : typeof err === "string" ? err : String(err);
  let s = stripQuoted(raw);
  s = s.replace(EMAIL_RE, "<email>");
  s = s.replace(TOKEN_RE, (m) => (/\d/.test(m) || m.length >= 32 ? "<token>" : m));
  s = s.replace(DECIMAL_RE, "#").replace(LONG_NUMBER_RE, "#");
  s = s.replace(/\s+/g, " ").trim();
  return s.length > MAX_LOGGED_MESSAGE ? `${s.slice(0, MAX_LOGGED_MESSAGE - 1)}\u2026` : s;
}

/** The stack without its first line(s) (which repeat the raw message): only the `at ...` frames. */
function framesOnly(stack: string | undefined): string | undefined {
  if (!stack) return undefined;
  const frames = stack.split("\n").filter((l) => /^\s+at /.test(l));
  return frames.length ? frames.join("\n") : undefined;
}

/**
 * Errors: class, redacted message (redactMessage), Postgres `code`/`routine`, and outside production the stack
 * frames. Never request data, SQL parameters or the Postgres `detail`/`where` fields.
 */
export function logError(event: string, err: unknown) {
  const e = err instanceof Error ? err : new Error(String(err));
  const code = (e as { code?: unknown }).code;
  const routine = (e as { routine?: unknown }).routine;
  const stack = config.isProduction ? undefined : framesOnly(e.stack);
  write({
    level: "error",
    event,
    error: e.name,
    message: redactMessage(e),
    ...(typeof code === "string" ? { code } : {}),
    ...(typeof routine === "string" ? { routine } : {}),
    ...(stack ? { stack } : {}),
  });
}

/** Request logger middleware. */
export const requestLogger: MiddlewareHandler = async (c, next) => {
  const start = performance.now();
  await next();
  let route = "unmatched";
  try {
    const p = routePath(c);
    if (p && p !== "*" && !p.endsWith("/*")) route = p;
  } catch {
    // no match info
  }
  write({
    level: "info",
    method: c.req.method,
    route,
    status: c.res.status,
    ms: Math.round(performance.now() - start),
  });
};
