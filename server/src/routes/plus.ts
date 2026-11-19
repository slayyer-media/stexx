import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  type JWSTransactionDecodedPayload,
  Environment,
  SignedDataVerifier,
  VerificationException,
  VerificationStatus,
} from "@apple/app-store-server-library";
import { Hono } from "hono";
import { z } from "zod";
import { config } from "../config.ts";
import { sql, type Sql } from "../db/sql.ts";
import { currentUserId, requireAuth } from "../lib/auth.ts";
import { ApiError, badRequest, requiresPlus, serviceUnavailable } from "../lib/errors.ts";
import { logError, logInfo } from "../lib/logger.ts";
import { type PlusStatus, plusStatus } from "../lib/plus.ts";
import { rateLimit } from "../lib/ratelimit.ts";
import { HOUR, isoDate } from "../lib/time.ts";
import { parseJson } from "../lib/validation.ts";
import type { AppEnv } from "../types.ts";

/**
 * plus routes, mounted at /v1. Paths are written in full relative to /v1 (e.g. "/me", not "/").
 * Owns: POST /subscriptions/apple, POST /subscriptions/apple/notifications (App Store Server Notifications V2, called
 * by Apple, unauthenticated), GET /subscriptions/status, POST /boosts. (PUT /me/travel lives in me.ts.)
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
  /**
   * ms since epoch: when this transaction (this billing period) was bought or renewed. A transaction bought after the
   * subscription was revoked is a new paid period and lifts the revocation. Absent = unknown (never lifts it).
   */
  purchaseDate?: number | null;
  environment: "Production" | "Sandbox" | "Xcode" | "LocalTesting";
}

/** Verifies a StoreKit 2 signed transaction or throws (ApiError). Never returns unverified data. */
export type TransactionVerifier = (signedTransaction: string) => Promise<VerifiedTransaction>;

/** The verified fields we use from a decoded JWSRenewalInfo. */
export interface VerifiedRenewal {
  originalTransactionId: string;
  /** autoRenewStatus: true = renews at expiry, false = turned off, null = absent. */
  autoRenew: boolean | null;
  /** ms since epoch: the end of the billing grace period while Apple retries a failed renewal. */
  gracePeriodExpiresDate: number | null;
}

/** A verified App Store Server Notification V2 (`responseBodyV2DecodedPayload`), reduced to what we use. */
export interface VerifiedNotification {
  notificationUUID: string;
  notificationType: string;
  subtype: string | null;
  /** ms since epoch: when Apple signed the notification. */
  signedDate: number;
  /**
   * The embedded transaction, verified like a client-posted one. null for TEST, for notifications without
   * transaction data, and for transactions of another product of the app.
   */
  transaction: VerifiedTransaction | null;
  /** The embedded renewal info (verified, same original transaction), or null. */
  renewal: VerifiedRenewal | null;
}

/** Verifies a `signedPayload` (and the JWS inside it) or throws (ApiError). Never returns unverified data. */
export type NotificationVerifier = (signedPayload: string) => Promise<VerifiedNotification>;

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

/** What both verifiers are built from: Apple's roots and this app's identity. */
export interface AppleVerifierOptions {
  roots: Buffer[];
  bundleId: string;
  environment: VerifiedTransaction["environment"];
  appAppleId?: number | null;
  productId: string;
  /** Revocation (OCSP) checks call Apple; only enabled for the Production environment. */
  onlineChecks?: boolean;
}

/**
 * The library verifier shared by the transaction and notification paths. It checks the JWS signature, the x5c chain up
 * to one of `roots` (with Apple's OIDs on the intermediate and leaf), the bundle id, the environment and, in
 * Production, the app's Apple ID.
 */
function signedDataVerifier(opts: AppleVerifierOptions): SignedDataVerifier {
  return new SignedDataVerifier(
    opts.roots,
    opts.onlineChecks ?? opts.environment === "Production",
    APPLE_ENV[opts.environment],
    opts.bundleId,
    opts.appAppleId ?? undefined,
  );
}

/**
 * Maps a library failure to our error: a retryable one (OCSP unreachable) is 503 so the caller (the app, or Apple's
 * retry schedule) tries again; anything else is a 400 that names no detail. Only the status number is logged.
 */
function verificationFailure(err: unknown, event: string, invalid: () => ApiError): ApiError {
  const status = err instanceof VerificationException ? err.status : -1;
  logInfo(event, { status });
  if (status === VerificationStatus.RETRYABLE_VERIFICATION_FAILURE) {
    return serviceUnavailable("subscriptions_unavailable", "Subscription verification is temporarily unavailable.");
  }
  return invalid();
}

/**
 * The fields we keep from a library-verified transaction, or null when it is not a Stexx+ subscription (another
 * product, wrong bundle, no expiry, unknown environment).
 */
function plusTransaction(payload: JWSTransactionDecodedPayload, opts: AppleVerifierOptions): VerifiedTransaction | null {
  const env = ENVIRONMENTS[String(payload.environment ?? "")];
  if (
    !payload.originalTransactionId ||
    payload.productId !== opts.productId ||
    payload.bundleId !== opts.bundleId ||
    !payload.expiresDate ||
    !env
  ) {
    return null;
  }
  return {
    originalTransactionId: payload.originalTransactionId,
    productId: payload.productId,
    expiresDate: payload.expiresDate,
    revocationDate: payload.revocationDate ?? null,
    purchaseDate: payload.purchaseDate ?? null,
    environment: env,
  };
}

/**
 * Build a verifier backed by SignedDataVerifier and the given Apple root certificates. The JWS signature, the
 * certificate chain (to the bundled Apple root), the bundle id and the environment are all checked by the library;
 * we additionally require our product id and an expiry date.
 */
export function createAppleVerifier(opts: AppleVerifierOptions): TransactionVerifier {
  const verifier = signedDataVerifier(opts);
  const invalid = () => badRequest("The transaction could not be verified.", "invalid_transaction");
  return async (signedTransaction) => {
    let payload;
    try {
      payload = await verifier.verifyAndDecodeTransaction(signedTransaction);
    } catch (err) {
      throw verificationFailure(err, "subscriptions.verify_failed", invalid);
    }
    const t = plusTransaction(payload, opts);
    if (!t) throw badRequest("The transaction is not a Stexx+ subscription.", "invalid_transaction");
    return t;
  };
}

/**
 * Build a verifier for App Store Server Notifications V2 with the same roots and library as `createAppleVerifier`.
 * The outer `signedPayload` must be for our bundle id (and app Apple ID in Production) and environment; the embedded
 * `signedTransactionInfo` and `signedRenewalInfo` are verified on their own (signature, chain, bundle id,
 * environment) and must belong to the same original transaction. Every failure is the same 400
 * `invalid_notification`, so a caller learns nothing about which check failed.
 */
export function createAppleNotificationVerifier(opts: AppleVerifierOptions): NotificationVerifier {
  const verifier = signedDataVerifier(opts);
  const invalid = () => badRequest("The notification could not be verified.", "invalid_notification");
  return async (signedPayload) => {
    try {
      const payload = await verifier.verifyAndDecodeNotification(signedPayload);
      const { notificationUUID, notificationType, signedDate } = payload;
      if (!notificationUUID || !notificationType || typeof signedDate !== "number") throw invalid();
      const data = payload.data;

      let transaction: VerifiedTransaction | null = null;
      if (data?.signedTransactionInfo) {
        const decoded = await verifier.verifyAndDecodeTransaction(data.signedTransactionInfo);
        transaction = plusTransaction(decoded, opts);
        // Another product of this app (none today) is not ours to apply, but a Stexx+ transaction without an
        // expiry or original transaction id is malformed.
        if (!transaction && decoded.productId === opts.productId) throw invalid();
      }

      let renewal: VerifiedRenewal | null = null;
      if (transaction && data?.signedRenewalInfo) {
        const decoded = await verifier.verifyAndDecodeRenewalInfo(data.signedRenewalInfo);
        if (decoded.originalTransactionId !== transaction.originalTransactionId) throw invalid();
        renewal = {
          originalTransactionId: decoded.originalTransactionId,
          autoRenew: decoded.autoRenewStatus === 1 ? true : decoded.autoRenewStatus === 0 ? false : null,
          gracePeriodExpiresDate: decoded.gracePeriodExpiresDate ?? null,
        };
      }

      return {
        notificationUUID,
        notificationType: String(notificationType),
        subtype: payload.subtype ? String(payload.subtype) : null,
        signedDate,
        transaction,
        renewal,
      };
    } catch (err) {
      if (err instanceof ApiError) throw err;
      throw verificationFailure(err, "subscriptions.notification_verify_failed", invalid);
    }
  };
}

let cachedVerifiers: { transaction: TransactionVerifier; notification: NotificationVerifier | null } | null | undefined;
let testVerifier: TransactionVerifier | null = null;
let testNotificationVerifier: NotificationVerifier | null = null;

/** Both verifiers for this process (built once from config), or null when StoreKit verification is not configured. */
function appleVerifiers() {
  if (cachedVerifiers !== undefined) return cachedVerifiers;
  cachedVerifiers = null;
  if (config.isProduction && config.apple.environment !== "Production") {
    // Unreachable (loadConfig refuses to boot like this): Xcode/LocalTesting skip signature verification.
    logError("subscriptions.bad_environment", new Error("non-Production Apple environment in production"));
    return cachedVerifiers;
  }
  if (config.apple.enabled && config.apple.rootCaDir) {
    const roots = loadRootCertificates(config.apple.rootCaDir);
    if (roots.length === 0) {
      logError("subscriptions.no_root_certs", new Error("APPLE_ROOT_CA_DIR contains no .cer/.der files"));
    } else {
      const opts: AppleVerifierOptions = {
        roots,
        bundleId: config.apple.bundleId,
        environment: config.apple.environment,
        appAppleId: config.apple.appAppleId,
        productId: config.apple.plusProductId,
      };
      cachedVerifiers = {
        transaction: createAppleVerifier(opts),
        // Apple sends notifications only from Production and Sandbox. In Xcode/LocalTesting the library skips
        // signature checks, which an unauthenticated endpoint must never do, so notifications stay off there.
        notification:
          opts.environment === "Production" || opts.environment === "Sandbox" ? createAppleNotificationVerifier(opts) : null,
      };
    }
  }
  return cachedVerifiers;
}

/** The transaction verifier for this process, or null when StoreKit verification is not configured. */
export function getTransactionVerifier(): TransactionVerifier | null {
  return testVerifier ?? appleVerifiers()?.transaction ?? null;
}

/** The notification verifier for this process, or null when not configured (or in Xcode/LocalTesting). */
export function getNotificationVerifier(): NotificationVerifier | null {
  return testNotificationVerifier ?? appleVerifiers()?.notification ?? null;
}

/** Tests only: replace the verifier (null restores the real one). Throws outside NODE_ENV=test. */
export function setTransactionVerifierForTests(v: TransactionVerifier | null) {
  if (!config.isTest) throw new Error("setTransactionVerifierForTests is test-only");
  testVerifier = v;
}

/** Tests only: replace the notification verifier (null restores the real one). Throws outside NODE_ENV=test. */
export function setNotificationVerifierForTests(v: NotificationVerifier | null) {
  if (!config.isTest) throw new Error("setNotificationVerifierForTests is test-only");
  testNotificationVerifier = v;
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

/** What a server notification adds to a transaction (the client path has none of these). */
export interface TransactionContext {
  /** From the signed renewal info; undefined or null (unknown) leaves `subscriptions.auto_renew` unchanged. */
  autoRenew?: boolean | null;
  /** End of a billing grace period (ms): the subscriber keeps Stexx+ until then while Apple retries the charge. */
  graceUntil?: number | null;
  /**
   * REFUND_REVERSED: Apple undid a refund at this time (the notification's signedDate, ms). Lifts a revocation that
   * happened before it.
   */
  reinstatedAt?: number | null;
}

/**
 * Record a verified transaction for `userId` inside `tx`. The subscription follows the claimant: if the same original
 * transaction was held by another account (e.g. the user re-installed with a new account), it moves and the previous
 * holder's entitlement is recomputed.
 *
 * - Expiry only grows: an older renewal (or an out-of-order notification) never shortens a newer expiry. A grace
 *   period extends it to the grace end.
 * - A revocation (refund, Family Sharing revoke) sticks, so a stale copy of the transaction can't bring Stexx+ back.
 *   It is lifted only by Apple: a refund reversal signed after it for the revoked period (not an earlier one), or a
 *   transaction purchased after it (a new paid period).
 * - Refunding a period that had already ended before the refund (an earlier month) doesn't revoke a later one.
 */
export async function applyTransactionInTx(
  tx: Sql,
  userId: string,
  t: VerifiedTransaction,
  ctx: TransactionContext = {},
): Promise<void> {
  const [existing] = await tx<{ user_id: string; expires_at: Date; revoked_at: Date | null }[]>`
    SELECT user_id, expires_at, revoked_at FROM subscriptions
     WHERE original_transaction_id = ${t.originalTransactionId} FOR UPDATE`;

  let expiresMs = Math.max(t.expiresDate, ctx.graceUntil ?? 0);
  if (existing) expiresMs = Math.max(expiresMs, existing.expires_at.getTime());

  let revoked: Date | null = existing?.revoked_at ?? null;
  if (t.revocationDate !== null) {
    const refundsEarlierPeriod =
      !!existing && t.expiresDate <= t.revocationDate && existing.expires_at.getTime() > t.expiresDate;
    if (!refundsEarlierPeriod) revoked ??= new Date(t.revocationDate);
  } else if (revoked) {
    // A reversal lifts the revocation only if it is for the revoked period: the reversed transaction was running when
    // the revocation happened, or it is the latest period. Reversing an earlier month's refund must not undo a later
    // month's refund (one revoked_at per subscription, so the period is told apart by its dates).
    const revokedMs = revoked.getTime();
    const sameRevokedPeriod =
      ((t.purchaseDate ?? Number.NEGATIVE_INFINITY) <= revokedMs && revokedMs < t.expiresDate) ||
      (!!existing && t.expiresDate >= existing.expires_at.getTime());
    const reinstated = ctx.reinstatedAt != null && ctx.reinstatedAt > revokedMs && sameRevokedPeriod;
    const newPeriod = t.purchaseDate != null && t.purchaseDate > revoked.getTime();
    if (reinstated || newPeriod) revoked = null;
  }

  const expires = new Date(expiresMs);
  if (!existing) {
    await tx`
      INSERT INTO subscriptions (original_transaction_id, user_id, product_id, expires_at, environment, revoked_at, auto_renew)
      VALUES (${t.originalTransactionId}, ${userId}, ${t.productId}, ${expires}, ${t.environment}, ${revoked},
              ${ctx.autoRenew ?? null})`;
  } else {
    await tx`
      UPDATE subscriptions
         SET user_id = ${userId}, product_id = ${t.productId}, expires_at = ${expires},
             environment = ${t.environment}, revoked_at = ${revoked},
             auto_renew = coalesce(${ctx.autoRenew ?? null}::boolean, auto_renew),
             updated_at = now()
       WHERE original_transaction_id = ${t.originalTransactionId}`;
  }
  await recomputePlus(userId, tx);
  if (existing && existing.user_id !== userId) await recomputePlus(existing.user_id, tx);
}

/** `applyTransactionInTx` in its own transaction (the client path: POST /subscriptions/apple). */
export async function applyVerifiedTransaction(userId: string, t: VerifiedTransaction, ctx: TransactionContext = {}): Promise<void> {
  await sql.begin((tx) => applyTransactionInTx(tx, userId, t, ctx));
}

// ---------------------------------------------------------------------------
// App Store Server Notifications V2
// ---------------------------------------------------------------------------

/** Notification types that change a subscription we know. Everything else is acknowledged and ignored. */
export const HANDLED_NOTIFICATION_TYPES: ReadonlySet<string> = new Set([
  "SUBSCRIBED",
  "DID_RENEW",
  "DID_CHANGE_RENEWAL_STATUS",
  "DID_FAIL_TO_RENEW",
  "EXPIRED",
  "GRACE_PERIOD_EXPIRED",
  "REFUND",
  "REVOKE",
  "REFUND_REVERSED",
]);

/** Notification UUIDs are kept this long for idempotency (Apple retries for about three days). */
export const NOTIFICATION_RETENTION_DAYS = 30;
const NOTIFICATION_PURGE_BATCH = 500;

export type NotificationOutcome =
  | "applied"
  | "replay"
  | "test"
  | "ignored_type"
  | "ignored_product"
  | "unknown_transaction";

/**
 * Apply one verified notification. Recording its UUID and changing the subscription happen in one transaction, so a
 * replay (same UUID) changes nothing, and a failure leaves no trace for Apple's retry. The subscription is looked up
 * by original transaction id; the notification never moves it to another account.
 */
export async function applyNotification(n: VerifiedNotification): Promise<NotificationOutcome> {
  return sql.begin(async (tx): Promise<NotificationOutcome> => {
    const [fresh] = await tx`
      INSERT INTO apple_notifications (notification_uuid) VALUES (${n.notificationUUID})
      ON CONFLICT (notification_uuid) DO NOTHING RETURNING 1 AS fresh`;
    if (!fresh) return "replay";
    if (n.notificationType === "TEST") return "test";
    if (!HANDLED_NOTIFICATION_TYPES.has(n.notificationType)) return "ignored_type";
    const t = n.transaction;
    if (!t) return "ignored_product";

    const [sub] = await tx<{ user_id: string }[]>`
      SELECT user_id FROM subscriptions WHERE original_transaction_id = ${t.originalTransactionId} FOR UPDATE`;
    if (!sub) return "unknown_transaction";

    const reversal = n.notificationType === "REFUND_REVERSED";
    await applyTransactionInTx(tx, sub.user_id, reversal ? { ...t, revocationDate: null } : t, {
      autoRenew: n.renewal ? n.renewal.autoRenew : undefined,
      graceUntil: n.renewal?.gracePeriodExpiresDate ?? null,
      reinstatedAt: reversal ? n.signedDate : null,
    });
    return "applied";
  });
}

/** Opportunistic cleanup of old idempotency rows (no job needed). Never fails the request. */
export async function purgeOldNotifications(): Promise<number> {
  try {
    const rows = await sql`
      DELETE FROM apple_notifications WHERE notification_uuid IN (
        SELECT notification_uuid FROM apple_notifications
         WHERE received_at < now() - ${NOTIFICATION_RETENTION_DAYS} * interval '1 day'
         ORDER BY received_at LIMIT ${NOTIFICATION_PURGE_BATCH})`;
    return rows.count;
  } catch (err) {
    logError("subscriptions.notification_purge_failed", err);
    return 0;
  }
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

const appleBody = z.strictObject({ signedTransaction: z.string().min(1).max(16_384) });
/**
 * Apple's body is `{ "signedPayload": "<JWS>" }`. Not strict: an extra field Apple might add later must not turn
 * every notification into a 400 that Apple keeps retrying. The JSON body limit (64 KB) caps the size.
 */
const notificationBody = z.object({ signedPayload: z.string().min(1).max(65_536) });

/** `SubscriptionStatus` on the wire (serialize.ts is left alone on purpose; this is the only builder). */
function statusJson(s: PlusStatus) {
  return {
    isActive: s.isActive,
    expiresAt: isoDate(s.expiresAt),
    willRenew: s.willRenew,
    boostEndsAt: isoDate(s.boostEndsAt),
  };
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

/**
 * App Store Server Notifications V2. Unauthenticated (Apple calls it); trust comes only from the verified signature.
 * 200 = acknowledged (applied, replayed, TEST, or ignored); 400 = not verifiable (Apple retries, then gives up);
 * 503 = not configured / verification temporarily unavailable (Apple retries). Logs ids and types only.
 */
plusRoutes.post("/subscriptions/apple/notifications", rateLimit("appleNotifications"), async (c) => {
  const { signedPayload } = await parseJson(c, notificationBody);
  const verify = getNotificationVerifier();
  if (!verify) {
    throw serviceUnavailable("subscriptions_unavailable", "Subscriptions are not available right now.");
  }
  const n = await verify(signedPayload);
  const outcome = await applyNotification(n);
  logInfo("subscriptions.notification", {
    notificationUUID: n.notificationUUID,
    type: n.notificationType,
    ...(n.subtype ? { subtype: n.subtype } : {}),
    ...(n.transaction ? { originalTransactionId: n.transaction.originalTransactionId } : {}),
    outcome,
  });
  await purgeOldNotifications();
  return c.body(null, 200);
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
