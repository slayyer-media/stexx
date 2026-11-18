import type { z } from "zod";
import { badRequest } from "./errors.ts";

/** Opaque pagination cursor: base64url(JSON). Clients must not parse it. */
export function encodeCursor(value: unknown): string {
  return Buffer.from(JSON.stringify(value), "utf8").toString("base64url");
}

/**
 * Decode and validate a cursor. Returns null for null/undefined/"" input.
 * Throws 400 `invalid_cursor` on garbage or schema mismatch.
 */
export function decodeCursor<S extends z.ZodType>(raw: string | null | undefined, schema: S): z.infer<S> | null {
  if (raw === null || raw === undefined || raw === "") return null;
  if (raw.length > 512 || !/^[A-Za-z0-9_-]+$/.test(raw)) throw badRequest("Invalid cursor.", "invalid_cursor");
  let parsed: unknown;
  try {
    parsed = JSON.parse(Buffer.from(raw, "base64url").toString("utf8"));
  } catch {
    throw badRequest("Invalid cursor.", "invalid_cursor");
  }
  const result = schema.safeParse(parsed);
  if (!result.success) throw badRequest("Invalid cursor.", "invalid_cursor");
  return result.data;
}
