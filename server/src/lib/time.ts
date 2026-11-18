/**
 * The ONLY way to put a date on the wire. ISO 8601 UTC with NO fractional seconds
 * (`2026-11-17T20:30:00Z`); Swift's `.iso8601` decoder rejects `.000Z`.
 * Truncates (floors) sub-second precision.
 */
export function isoDate(d: Date | string | number): string;
export function isoDate(d: Date | string | number | null | undefined): string | null;
export function isoDate(d: Date | string | number | null | undefined): string | null {
  if (d === null || d === undefined) return null;
  const date = d instanceof Date ? d : new Date(d);
  if (Number.isNaN(date.getTime())) throw new TypeError("isoDate: invalid date");
  return date.toISOString().replace(/\.\d+Z$/, "Z");
}

export const SECOND = 1000;
export const MINUTE = 60 * SECOND;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;

/** Date `ms` milliseconds from now (or from `from`). */
export function inMs(ms: number, from: Date = new Date()): Date {
  return new Date(from.getTime() + ms);
}

/** Matches an ISO timestamp with fractional seconds anywhere in a JSON string. Used by tests. */
export const FRACTIONAL_SECONDS_RE = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+/;
