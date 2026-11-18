/**
 * Encrypted message envelopes: an opaque libsignal ciphertext the server stores and relays but never parses.
 *
 * Wire form (MessageDraft.envelope and Message.envelope): { "type": "prekey" | "signal", "body": "<base64>" }
 *   - prekey: libsignal PreKeySignalMessage (CiphertextMessageType.PreKey = 3), the first messages of a session;
 *   - signal: libsignal SignalMessage (CiphertextMessageType.Whisper = 2), every message after the recipient replied.
 * body is the serialized message, standard base64 (padded), at most ENVELOPE_MAX_BYTES decoded.
 */
import { z } from "zod";
import { ApiError } from "../errors.ts";
import { decodeBase64, encodeBase64 } from "./crypto.ts";

/**
 * 32 KiB. A 4000-character message is at most 16 KB of UTF-8; libsignal adds padding, a MAC and, for a prekey
 * message, the Kyber ciphertext (1568 B) and session header: well under 20 KB. Base64 of 32 KiB fits the 64 KB
 * JSON body limit. (The DB CHECK allows 64 KiB, so this can be raised without a migration.)
 */
export const ENVELOPE_MAX_BYTES = 32 * 1024;
export const ENVELOPE_TYPES = ["prekey", "signal"] as const;
export type EnvelopeType = (typeof ENVELOPE_TYPES)[number];

export interface EnvelopeJson {
  type: EnvelopeType;
  body: string;
}

export const envelopeSchema = z.strictObject({
  type: z.enum(ENVELOPE_TYPES),
  body: z.string().min(1).max(Math.ceil(ENVELOPE_MAX_BYTES / 3) * 4),
});

/** Decoded body; 400 `invalid_envelope` if it isn't canonical base64 within the size limit. */
export function decodeEnvelope(env: z.infer<typeof envelopeSchema>): { type: EnvelopeType; body: Buffer } {
  try {
    return { type: env.type, body: decodeBase64(env.body, "envelope.body", ENVELOPE_MAX_BYTES) };
  } catch {
    throw new ApiError(400, "invalid_envelope", "envelope.body must be standard base64 of at most 32 KiB.");
  }
}

export function envelopeJson(type: string | null, body: Buffer | null): EnvelopeJson | null {
  if (!type || !body) return null;
  return { type: type as EnvelopeType, body: encodeBase64(body) };
}
