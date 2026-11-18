import type { Context } from "hono";
import { z } from "zod";
import { badRequest, notFound } from "./errors.ts";
import { isId, type IdKind } from "./ids.ts";

/**
 * Request parsing helpers. Always use strict schemas (`z.strictObject`) so unknown keys → 400.
 * Zod errors thrown from here (or anywhere) become 400 `validation_error` via onError.
 */

/** Parse a JSON body with a zod schema. Bad JSON → 400 invalid_json. */
export async function parseJson<S extends z.ZodType>(c: Context, schema: S): Promise<z.infer<S>> {
  let body: unknown;
  try {
    body = await c.req.json();
  } catch {
    throw badRequest("Request body must be valid JSON.", "invalid_json");
  }
  return schema.parse(body);
}

/**
 * Parse query params. Each key maps to string[] (repeatable params like `lookingFor`), so use
 * `qOne` / `qMany` / `qBool` / `qInt` building blocks in the schema.
 */
export function parseQuery<S extends z.ZodType>(c: Context, schema: S): z.infer<S> {
  return schema.parse(c.req.queries() ?? {});
}

/** Single optional query value (last wins). */
export const qOne = z
  .array(z.string())
  .optional()
  .transform((v) => (v && v.length ? v[v.length - 1] : undefined));
/** Repeatable query value (`?tag=a&tag=b`). */
export const qMany = z
  .array(z.string())
  .optional()
  .transform((v) => v ?? []);
/** `true`/`1` → true, `false`/`0`/absent → false. */
export const qBool = qOne.pipe(
  z
    .enum(["true", "false", "1", "0"])
    .optional()
    .transform((v) => v === "true" || v === "1"),
);
/** Optional integer within [min,max]. */
export const qInt = (min: number, max: number) =>
  qOne.pipe(
    z
      .string()
      .regex(/^-?\d+$/, "must be an integer")
      .transform(Number)
      .pipe(z.number().int().min(min).max(max))
      .optional(),
  );

/** Path param that must be a well-formed id of `kind`; otherwise 404 (don't leak via 400). */
export function idParam(c: Context, name: string, kind: IdKind): string {
  const v = c.req.param(name);
  if (!isId(kind, v)) throw notFound();
  return v;
}

// ---- Shared field schemas -------------------------------------------------

// Control chars and bidi overrides/isolates.
const FORBIDDEN_CHARS = /[\u0000-\u001f\u007f-\u009f‪-‮⁦-⁩]/;

/** Trimmed single-line text, 1..max chars, no control/bidi chars. */
export const cleanText = (max: number, min = 1) =>
  z
    .string()
    .trim()
    .min(min, min === 1 ? "must not be empty" : `must be at least ${min} characters`)
    .max(max, `must be at most ${max} characters`)
    .refine((s) => !FORBIDDEN_CHARS.test(s), "contains invalid characters");

/** Multi-line text (newlines/tabs allowed), other control chars rejected. */
export const multilineText = (max: number) =>
  z
    .string()
    .trim()
    .max(max, `must be at most ${max} characters`)
    .refine((s) => !/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f‪-‮⁦-⁩]/.test(s), "contains invalid characters");

export const displayNameSchema = cleanText(30);

export const positionSchema = z.enum(["top", "versTop", "versatile", "versBottom", "bottom", "side"]);
export const lookingForSchema = z.enum(["chat", "dates", "friends", "relationship", "networking", "rightNow"]);
export const tagsSchema = z.array(cleanText(24)).max(10, "at most 10 tags");
export const reportReasonSchema = z.enum([
  "underage",
  "harassment",
  "spam",
  "fakeProfile",
  "threatsOrViolence",
  "illegalContent",
  "other",
]);

/** `{ latitude, longitude, precisionMeters }` as sent by the client (FuzzedLocation). Re-snap server-side! */
export const locationSchema = z.strictObject({
  latitude: z.number().finite().min(-90).max(90),
  longitude: z.number().finite().min(-180).max(180),
  precisionMeters: z.number().finite().positive().max(100_000).optional(),
});

export const privacySchema = z.strictObject({
  hideDistance: z.boolean(),
  showOnlineStatus: z.boolean(),
  sendReadReceipts: z.boolean(),
  expiringPhotosByDefault: z.boolean(),
  blurExplicitPhotos: z.boolean(),
  incognito: z.boolean(),
});
