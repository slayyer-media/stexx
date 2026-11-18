import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { Environment, SignedDataVerifier, VerificationException, VerificationStatus } from "@apple/app-store-server-library";
import { Hono } from "hono";
import { z } from "zod";
import { config } from "../config.ts";
import { sql, type Sql } from "../db/sql.ts";
import { currentUserId, requireAuth } from "../lib/auth.ts";
import { badRequest, requiresPlus, serviceUnavailable } from "../lib/errors.ts";
import { logError, logInfo } from "../lib/logger.ts";
import { plusStatus } from "../lib/plus.ts";
import { rateLimit } from "../lib/ratelimit.ts";
import { HOUR, isoDate } from "../lib/time.ts";
import { parseJson } from "../lib/validation.ts";
import type { AppEnv } from "../types.ts";

/**
 * plus routes, mounted at /v1. Paths are written in full relative to /v1 (e.g. "/me", not "/").
 * Owns: POST /subscriptions/apple, GET /subscriptions/status, POST /boosts. (PUT /me/travel lives in me.ts.)
 * See server/AGENTS-NOTES.md for helpers and conventions.
 *
 * Source of truth for entitlement is `users.plus_expires_at`, kept equal to the latest expiry over the user's
 * non-revoked rows in `subscriptions` (see `recomputePlus`).
 */
export const plusRoutes = new Hono<AppEnv>();

export const BOOST_DURATION_MS = 1 * HOUR;

// ---------------------------------------------------------------------------
// StoreKit 2 verification
// ---------------------------------------------------------------------------

/** The verified fields we use from a decoded JWSTransaction. */
export interface VerifiedTransaction {
  originalTransactionId: string;
  productId: string;
  /** ms since epoch. */
  expiresDate: number;
  /** ms since epoch, set when Apple refunded/revoked the purchase. */
  revocationDate: number | null;
  environment: "Production" | "Sandbox" | "Xcode" | "LocalTesting";
}

/** Verifies a StoreKit 2 signed transaction or throws (ApiError). Never returns unverified data. */
export type TransactionVerifier = (signedTransaction: string) => Promise<VerifiedTransaction>;

const ENVIRONMENTS: Record<string, VerifiedTransaction["environment"]> = {
  Production: "Production",
  Sandbox: "Sandbox",
  Xcode: "Xcode",
  LocalTesting: "LocalTesting",
};

const APPLE_ENV: Record<VerifiedTransaction["environment"], Environment> = {
  Production: Environment.PRODUCTION,
  Sandbox: Environment.SANDBOX,
  Xcode: Environment.XCODE,
  LocalTesting: Environment.LOCAL_TESTING,
};

/** DER root certificates (*.cer / *.der) from `dir`. Empty when the directory is missing or has none. */
export function loadRootCertificates(dir: string): Buffer[] {
  try {
    return readdirSync(dir)
      .filter((f) => /\.(cer|der)$/i.test(f))
      .sort()
      .map((f) => readFileSync(join(dir, f)));
  } catch {
    return [];
  }
}

/**
 * Build a verifier backed by SignedDataVerifier and the given Apple root certificates. The JWS signature, the
 * certificate chain (to the bundled Apple root), the bundle id and the environment are all checked by the library;
 * we additionally require our product id and an expiry date.
 */
export function createAppleVerifier(opts: {
  roots: Buffer[];
  bundleId: string;
  environment: VerifiedTransaction["environment"];
  appAppleId?: number | null;
  productId: string;
  /** Revocation (OCSP) checks call Apple; only enabled for the Production environment. */
  onlineChecks?: boolean;
}): TransactionVerifier {
  const verifier = new SignedDataVerifier(
    opts.roots,
    opts.onlineChecks ?? opts.environment === "Production",
    APPLE_ENV[opts.environment],
    opts.bundleId,
    opts.appAppleId ?? undefined,
  );
  return async (signedTransaction) => {
    let payload;
    try {
      payload = await verifier.verifyAndDecodeTransaction(signedTransaction);
    } catch (err) {
      const status = err instanceof VerificationException ? err.status : -1;
      logInfo("subscriptions.verify_failed", { status });
      if (status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE) {
        throw serviceUnavailable("subscriptions_unavailable", "Subscription verification is temporarily unavailable.");
      }
      throw badRequest("The transaction could not be verified.", "invalid_transaction");
    }
    const env = ENVIRONMENTS[String(payload.environment ?? "")];
    if (
      !payload.originalTransactionId ||
      payload.productId !== opts.productId ||
      payload.bundleId !== opts.bundleId ||
      !payload.expiresDate ||
      !env
    ) {
      throw badRequest("The transaction is not a Stexx+ subscription.", "invalid_transaction");
    }
    return {
      originalTransactionId: payload.originalTransactionId,
      productId: payload.productId,
      expiresDate: payload.expiresDate,
      revocationDate: payload.revocationDate ?? null,
      environment: env,
    };
  };
}

let cachedVerifier: TransactionVerifier | null | undefined;
let testVerifier: TransactionVerifier | null = null;

/** The verifier for this process, or null when StoreKit verification is not configured. */
export function getTransactionVerifier(): TransactionVerifier | null {
  if (testVerifier) return testVerifier;
  if (cachedVerifier !== undefined) return cachedVerifier;
  cachedVerifier = null;
  if (config.isProduction && config.apple.environment !== "Production") {
    // Unreachable (loadConfig refuses to boot like this): Xcode/LocalTesting skip signature verification.
    logError("subscriptions.bad_environment", new Error("non-Production Apple environment in production"));
    return cachedVerifier;
  }
  if (config.apple.enabled && config.apple.rootCaDir) {
    const roots = loadRootCertificates(config.apple.rootCaDir);
    if (roots.length === 0) {
      logError("subscriptions.no_root_certs", new Error("APPLE_ROOT_CA_DIR contains no .cer/.der files"));
    } else {
      cachedVerifier = createAppleVerifier({
        roots,
        bundleId: config.apple.bundleId,
        environment: config.apple.environment,
        appAppleId: config.apple.appAppleId,
        productId: config.apple.plusProductId,
      });
    }
  }
  return cachedVerifier;
}

/** Tests only: replace the verifier (null restores the real one). Throws outside NODE_ENV=test. */
export function setTransactionVerifierForTests(v: TransactionVerifier | null) {
  if (!config.isTest) throw new Error("setTransactionVerifierForTests is test-only");
  testVerifier = v;
}

// ---------------------------------------------------------------------------
// Entitlement bookkeeping
// ---------------------------------------------------------------------------

/** Set users.plus_expires_at to the latest expiry over the user's non-revoked subscriptions (NULL if none). */
export async function recomputePlus(userId: string, db: Sql = sql): Promise<void> {
  await db`
    UPDATE users SET plus_expires_at =
      (SELECT max(expires_at) FROM subscriptions WHERE user_id = ${userId} AND revoked_at IS NULL)
    WHERE id = ${userId}`;
}

/**
 * Record a verified transaction for `userId`. The subscription follows the claimant: if the same original
 * transaction was held by another account (e.g. the user re-installed with a new account), it moves and the
 * previous holder's entitlement is recomputed. A revoked transaction stays revoked, and an older renewal never
 * shortens a newer expiry.
 */
export async function applyVerifiedTransaction(userId: string, t: VerifiedTransaction): Promise<void> {
  const expires = new Date(t.expiresDate);
  const revokedAt = t.revocationDate !== null ? new Date(t.revocationDate) : null;
  await sql.begin(async (tx) => {
    const [existing] = await tx<{ user_id: string; expires_at: Date; revoked_at: Date | null }[]>`
      SELECT user_id, expires_at, revoked_at FROM subscriptions
       WHERE original_transaction_id = ${t.originalTransactionId} FOR UPDATE`;
    if (!existing) {
      await tx`
        INSERT INTO subscriptions (original_transaction_id, user_id, product_id, expires_at, environment, revoked_at)
        VALUES (${t.originalTransactionId}, ${userId}, ${t.productId}, ${expires}, ${t.environment}, ${revokedAt})`;
    } else {
      const revoked = existing.revoked_at ?? revokedAt;
      const newExpires = existing.expires_at.getTime() > expires.getTime() ? existing.expires_at : expires;
      await tx`
        UPDATE subscriptions
           SET user_id = ${userId}, product_id = ${t.productId}, expires_at = ${newExpires},
               environment = ${t.environment}, revoked_at = ${revoked}, updated_at = now()
         WHERE original_transaction_id = ${t.originalTransactionId}`;
    }
    await recomputePlus(userId, tx);
    if (existing && existing.user_id !== userId) await recomputePlus(existing.user_id, tx);
  });
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

const appleBody = z.strictObject({ signedTransaction: z.string().min(1).max(16_384) });

function statusJson(s: { isActive: boolean; expiresAt: Date | null }) {
  return { isActive: s.isActive, expiresAt: isoDate(s.expiresAt) };
}

// Cost 10 of the general bucket (300/min) => 30 verification attempts per minute per user.
plusRoutes.post("/subscriptions/apple", requireAuth, rateLimit("general", { cost: 10 }), async (c) => {
  const userId = currentUserId(c);
  const { signedTransaction } = await parseJson(c, appleBody);
  const verify = getTransactionVerifier();
  if (!verify) {
    throw serviceUnavailable("subscriptions_unavailable", "Subscriptions are not available right now.");
  }
  const verified = await verify(signedTransaction);
  await applyVerifiedTransaction(userId, verified);
  return c.json(statusJson(await plusStatus(userId)));
});

plusRoutes.get("/subscriptions/status", requireAuth, async (c) => {
  return c.json(statusJson(await plusStatus(currentUserId(c))));
});

/** One-hour visibility boost. Not stackable: while a boost is running the current end time is returned. */
plusRoutes.post("/boosts", requireAuth, async (c) => {
  const userId = currentUserId(c);
  const [started] = await sql<{ boost_ends_at: Date }[]>`
    UPDATE users
       SET boost_ends_at = now() + ${BOOST_DURATION_MS / 1000} * interval '1 second'
     WHERE id = ${userId}
       AND plus_expires_at > now()
       AND (boost_ends_at IS NULL OR boost_ends_at <= now())
    RETURNING boost_ends_at`;
  if (started) return c.json({ endsAt: isoDate(started.boost_ends_at) });

  const [row] = await sql<{ boost_ends_at: Date | null; plus_active: boolean }[]>`
    SELECT boost_ends_at, coalesce(plus_expires_at > now(), false) AS plus_active FROM users WHERE id = ${userId}`;
  if (!row?.plus_active) throw requiresPlus();
  return c.json({ endsAt: isoDate(row.boost_ends_at!) });
});
