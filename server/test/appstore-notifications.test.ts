/**
 * App Store Server Notifications V2 (POST /v1/subscriptions/apple/notifications) and the status read-back.
 *
 * Notifications here are real JWS: signed with the TEST chain in fixtures/storekit/ (root → intermediate → leaf with
 * Apple's OIDs, made by generate.ts) and checked by the production verifier (`createAppleNotificationVerifier`, i.e.
 * SignedDataVerifier) pointed at the test root with online checks off. Only the root differs from production.
 */
import { createPrivateKey, randomUUID, sign } from "node:crypto";
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import {
  applyVerifiedTransaction,
  createAppleNotificationVerifier,
  NOTIFICATION_RETENTION_DAYS,
  setNotificationVerifierForTests,
  setTransactionVerifierForTests,
  type VerifiedTransaction,
} from "../src/routes/plus.ts";
import { DAY, HOUR, MINUTE } from "../src/lib/time.ts";
import fixtures from "./fixtures/storekit/fixtures.json";
import { as, createUser, expectError, expectJson, post, sql, uniq, type TestUser } from "./helpers.ts";

const PRODUCT = "gay.stexx.app.plus.monthly";
const BUNDLE = "gay.stexx.app";
const URL = "/v1/subscriptions/apple/notifications";

type Chain = (typeof fixtures)["trusted"];
const der = (b64: string) => Buffer.from(b64, "base64");
const b64url = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");

/** ES256 JWS with an x5c header, exactly like Apple's (leaf, intermediate, root). */
function signJws(payload: unknown, chain: Chain = fixtures.trusted): string {
  const input = `${b64url({ alg: "ES256", x5c: [chain.leaf, chain.intermediate, chain.root] })}.${b64url(payload)}`;
  const sig = sign("sha256", Buffer.from(input), { key: createPrivateKey(chain.leafKey), dsaEncoding: "ieee-p1363" });
  return `${input}.${sig.toString("base64url")}`;
}

interface TxFields {
  originalTransactionId: string;
  expiresDate?: number;
  purchaseDate?: number;
  revocationDate?: number;
  productId?: string;
  bundleId?: string;
  environment?: string;
  chain?: Chain;
}

function signedTransaction(t: TxFields): string {
  const now = Date.now();
  return signJws(
    {
      originalTransactionId: t.originalTransactionId,
      transactionId: `tx_${uniq()}`,
      bundleId: t.bundleId ?? BUNDLE,
      productId: t.productId ?? PRODUCT,
      purchaseDate: t.purchaseDate ?? now - MINUTE,
      originalPurchaseDate: now - 60 * DAY,
      expiresDate: t.expiresDate ?? now + 30 * DAY,
      type: "Auto-Renewable Subscription",
      inAppOwnershipType: "PURCHASED",
      environment: t.environment ?? "Sandbox",
      signedDate: now,
      ...(t.revocationDate !== undefined ? { revocationDate: t.revocationDate, revocationReason: 0 } : {}),
    },
    t.chain,
  );
}

interface RenewalFields {
  originalTransactionId: string;
  autoRenew?: boolean;
  gracePeriodExpiresDate?: number;
  environment?: string;
  chain?: Chain;
}

function signedRenewal(r: RenewalFields): string {
  return signJws(
    {
      originalTransactionId: r.originalTransactionId,
      autoRenewProductId: PRODUCT,
      productId: PRODUCT,
      autoRenewStatus: r.autoRenew === false ? 0 : 1,
      environment: r.environment ?? "Sandbox",
      signedDate: Date.now(),
      ...(r.gracePeriodExpiresDate !== undefined
        ? { gracePeriodExpiresDate: r.gracePeriodExpiresDate, isInBillingRetryPeriod: true }
        : {}),
    },
    r.chain,
  );
}

interface NotificationFields {
  type: string;
  subtype?: string;
  uuid?: string;
  signedDate?: number;
  tx?: TxFields;
  renewal?: Partial<RenewalFields> | false;
  bundleId?: string;
  environment?: string;
  chain?: Chain;
}

function signedPayload(n: NotificationFields): string {
  const data: Record<string, unknown> = {
    bundleId: n.bundleId ?? BUNDLE,
    bundleVersion: "1",
    environment: n.environment ?? "Sandbox",
  };
  if (n.tx) {
    data.signedTransactionInfo = signedTransaction(n.tx);
    if (n.renewal !== false) {
      data.signedRenewalInfo = signedRenewal({ originalTransactionId: n.tx.originalTransactionId, ...n.renewal });
    }
    data.status = 1;
  }
  return signJws(
    {
      notificationType: n.type,
      ...(n.subtype ? { subtype: n.subtype } : {}),
      notificationUUID: n.uuid ?? randomUUID(),
      data,
      version: "2.0",
      signedDate: n.signedDate ?? Date.now(),
    },
    n.chain,
  );
}

const send = (n: NotificationFields | string, ip?: string) =>
  post(URL, { json: { signedPayload: typeof n === "string" ? n : signedPayload(n) }, ip });

async function acked(n: NotificationFields) {
  const res = await send(n);
  expect(res.status).toBe(200);
}

const otid = () => `2000000${Math.floor(Math.random() * 1e9)}${uniq().slice(-6)}`;

/** A user holding `id` (as if the app had posted the transaction), expiring at `expiresDate`. */
async function subscriber(id: string, expiresDate = Date.now() + 10 * DAY, user?: TestUser): Promise<TestUser> {
  const u = user ?? (await createUser());
  const t: VerifiedTransaction = {
    originalTransactionId: id,
    productId: PRODUCT,
    expiresDate,
    revocationDate: null,
    purchaseDate: Date.now() - 20 * DAY,
    environment: "Sandbox",
  };
  await applyVerifiedTransaction(u.id, t);
  return u;
}

interface StatusJson {
  isActive: boolean;
  expiresAt: string | null;
  willRenew: boolean | null;
  boostEndsAt: string | null;
}
const status = async (u: TestUser) => expectJson<StatusJson>(await as(u).get("/v1/subscriptions/status"));

async function plusExpiresAt(u: TestUser): Promise<number | null> {
  const [row] = await sql<{ plus_expires_at: Date | null }[]>`SELECT plus_expires_at FROM users WHERE id = ${u.id}`;
  return row?.plus_expires_at?.getTime() ?? null;
}

async function subRow(id: string) {
  const [row] = await sql<{ expires_at: Date; revoked_at: Date | null; auto_renew: boolean | null; user_id: string }[]>`
    SELECT expires_at, revoked_at, auto_renew, user_id FROM subscriptions WHERE original_transaction_id = ${id}`;
  return row;
}

const near = (a: number | null, b: number) => expect(Math.abs((a ?? 0) - b)).toBeLessThan(1000);

const testVerifier = (environment: "Sandbox" | "Production" = "Sandbox") =>
  createAppleNotificationVerifier({
    roots: [der(fixtures.trusted.root)],
    bundleId: BUNDLE,
    environment,
    appAppleId: environment === "Production" ? 1234567890 : null,
    productId: PRODUCT,
    onlineChecks: false,
  });

beforeAll(() => {
  setNotificationVerifierForTests(testVerifier());
  // The client path isn't used for setup here (applyVerifiedTransaction is called directly); keep it unconfigured.
  setTransactionVerifierForTests(null);
});
afterAll(() => setNotificationVerifierForTests(null));

describe("POST /subscriptions/apple/notifications: verification", () => {
  test("a TEST notification is answered 200 and changes nothing", async () => {
    await acked({ type: "TEST" });
  });

  test("garbage, a bad signature, another root, and missing or invalid bodies are 400 without details", async () => {
    const good = signedPayload({ type: "TEST" });
    const [h, p, s] = good.split(".") as [string, string, string];
    const flipped = Buffer.from(s, "base64url");
    flipped[10]! ^= 0xff;
    const tampered = `${h}.${b64url({ ...JSON.parse(Buffer.from(p, "base64url").toString()), notificationType: "REFUND" })}.${s}`;
    const messages = new Set<string>();
    for (const bad of [
      "garbage",
      "a.b.c",
      `${h}.${p}.${flipped.toString("base64url")}`,
      tampered,
      signedPayload({ type: "TEST", chain: fixtures.other }),
    ]) {
      messages.add((await expectError(await send(bad), 400, "invalid_notification")).message);
    }
    expect([...messages]).toEqual(["The notification could not be verified."]);
    await expectError(await post(URL, { json: {} }), 400, "validation_error");
    await expectError(await post(URL, { json: { signedPayload: "" } }), 400, "validation_error");
    await expectError(await post(URL, { body: "{", contentType: "application/json" }), 400, "invalid_json");
  });

  test("wrong bundle id or environment (outer payload, transaction or renewal) is the same 400, and nothing is applied", async () => {
    const id = otid();
    const u = await subscriber(id);
    const before = await plusExpiresAt(u);
    const refund = { originalTransactionId: id, revocationDate: Date.now() - MINUTE };
    const uuid = randomUUID();
    for (const n of [
      { type: "REFUND", uuid, tx: refund, bundleId: "com.example.other" },
      { type: "REFUND", uuid, tx: refund, environment: "Production" },
      { type: "REFUND", uuid, tx: { ...refund, bundleId: "com.example.other" } },
      { type: "REFUND", uuid, tx: { ...refund, environment: "Production" } },
      { type: "REFUND", uuid, tx: { ...refund, chain: fixtures.other } },
      { type: "REFUND", uuid, tx: refund, renewal: { environment: "Production" } },
      { type: "REFUND", uuid, tx: refund, renewal: { chain: fixtures.other } },
      { type: "REFUND", uuid, tx: refund, renewal: { originalTransactionId: otid() } },
    ] satisfies NotificationFields[]) {
      const e = await expectError(await send(n), 400, "invalid_notification");
      expect(e.message).toBe("The notification could not be verified.");
    }
    expect(await plusExpiresAt(u)).toBe(before);
    expect((await status(u)).isActive).toBe(true);
    // None of the rejected attempts recorded the UUID: the genuine notification with it still applies.
    await acked({ type: "REFUND", uuid, tx: refund });
    expect((await status(u)).isActive).toBe(false);
  });

  test("a Production server rejects Sandbox notifications (and vice versa)", async () => {
    setNotificationVerifierForTests(testVerifier("Production"));
    try {
      await expectError(await send({ type: "TEST" }), 400, "invalid_notification");
    } finally {
      setNotificationVerifierForTests(testVerifier());
    }
    await expectError(await send({ type: "TEST", environment: "Production" }), 400, "invalid_notification");
  });

  test("503 subscriptions_unavailable when StoreKit verification is not configured", async () => {
    setNotificationVerifierForTests(null);
    try {
      await expectError(await send({ type: "TEST" }), 503, "subscriptions_unavailable");
    } finally {
      setNotificationVerifierForTests(testVerifier());
    }
  });

  test("its own rate-limit bucket: 60 per minute per client, then 429 with Retry-After", async () => {
    const ip = `10.${Math.floor(Math.random() * 250)}.${Math.floor(Math.random() * 250)}.${Math.floor(Math.random() * 250)}`;
    for (let i = 0; i < 60; i++) {
      expect((await post(URL, { json: {}, ip })).status).toBe(400);
    }
    const res = await post(URL, { json: {}, ip });
    await expectError(res, 429);
    expect(Number(res.headers.get("Retry-After"))).toBeGreaterThan(0);
  });
});

describe("POST /subscriptions/apple/notifications: notification types", () => {
  test("SUBSCRIBED records the auto-renew flag; status reports willRenew", async () => {
    const id = otid();
    const u = await subscriber(id);
    expect((await status(u)).willRenew).toBeNull();
    await acked({ type: "SUBSCRIBED", subtype: "INITIAL_BUY", tx: { originalTransactionId: id } });
    const s = await status(u);
    expect(s.isActive).toBe(true);
    expect(s.willRenew).toBe(true);
    expect((await subRow(id))!.auto_renew).toBe(true);
  });

  test("DID_RENEW extends plus_expires_at to the new period", async () => {
    const id = otid();
    const u = await subscriber(id, Date.now() + HOUR);
    const next = Date.now() + 31 * DAY;
    await acked({ type: "DID_RENEW", tx: { originalTransactionId: id, expiresDate: next } });
    near(await plusExpiresAt(u), next);
    const s = await status(u);
    near(new Date(s.expiresAt!).getTime(), next);
    expect(s.willRenew).toBe(true);
  });

  test("an out-of-order (older) DID_RENEW never shortens the expiry", async () => {
    const id = otid();
    const later = Date.now() + 40 * DAY;
    const u = await subscriber(id, later);
    await acked({ type: "DID_RENEW", tx: { originalTransactionId: id, expiresDate: Date.now() + 10 * DAY } });
    near(await plusExpiresAt(u), later);
  });

  test("DID_CHANGE_RENEWAL_STATUS flips willRenew (renews on / ends on) without touching the expiry", async () => {
    const id = otid();
    const expires = Date.now() + 12 * DAY;
    const u = await subscriber(id, expires);
    await acked({
      type: "DID_CHANGE_RENEWAL_STATUS",
      subtype: "AUTO_RENEW_DISABLED",
      tx: { originalTransactionId: id, expiresDate: expires },
      renewal: { autoRenew: false },
    });
    let s = await status(u);
    expect(s).toMatchObject({ isActive: true, willRenew: false });
    near(await plusExpiresAt(u), expires);
    await acked({
      type: "DID_CHANGE_RENEWAL_STATUS",
      subtype: "AUTO_RENEW_ENABLED",
      tx: { originalTransactionId: id, expiresDate: expires },
      renewal: { autoRenew: true },
    });
    s = await status(u);
    expect(s.willRenew).toBe(true);
  });

  test("DID_FAIL_TO_RENEW with GRACE_PERIOD keeps Stexx+ until the grace period ends", async () => {
    const id = otid();
    const lapsed = Date.now() - HOUR;
    const u = await subscriber(id, lapsed);
    expect((await status(u)).isActive).toBe(false);
    const graceEnd = Date.now() + 6 * DAY;
    await acked({
      type: "DID_FAIL_TO_RENEW",
      subtype: "GRACE_PERIOD",
      tx: { originalTransactionId: id, expiresDate: lapsed },
      renewal: { gracePeriodExpiresDate: graceEnd },
    });
    near(await plusExpiresAt(u), graceEnd);
    expect((await status(u)).isActive).toBe(true);
  });

  test("DID_FAIL_TO_RENEW without a grace period leaves the lapsed expiry as is", async () => {
    const id = otid();
    const lapsed = Date.now() - HOUR;
    const u = await subscriber(id, lapsed);
    await acked({ type: "DID_FAIL_TO_RENEW", tx: { originalTransactionId: id, expiresDate: lapsed } });
    near(await plusExpiresAt(u), lapsed);
    expect((await status(u)).isActive).toBe(false);
  });

  test("EXPIRED: not active, expiry is Apple's, willRenew null; auto-renew stored as off", async () => {
    const id = otid();
    const ended = Date.now() - 2 * HOUR;
    const u = await subscriber(id, ended);
    await acked({
      type: "EXPIRED",
      subtype: "VOLUNTARY",
      tx: { originalTransactionId: id, expiresDate: ended },
      renewal: { autoRenew: false },
    });
    near(await plusExpiresAt(u), ended);
    expect(await status(u)).toMatchObject({ isActive: false, willRenew: null });
    expect((await subRow(id))!.auto_renew).toBe(false);
  });

  test("GRACE_PERIOD_EXPIRED after a grace period: Stexx+ ends at the grace end", async () => {
    const id = otid();
    const lapsed = Date.now() - 7 * DAY;
    const u = await subscriber(id, lapsed);
    const graceEnd = Date.now() - MINUTE;
    await acked({
      type: "GRACE_PERIOD_EXPIRED",
      tx: { originalTransactionId: id, expiresDate: lapsed },
      renewal: { gracePeriodExpiresDate: graceEnd },
    });
    near(await plusExpiresAt(u), graceEnd);
    expect((await status(u)).isActive).toBe(false);
  });

  test("REFUND of the current period removes Stexx+ immediately", async () => {
    const id = otid();
    const u = await subscriber(id, Date.now() + 20 * DAY);
    expect((await status(u)).isActive).toBe(true);
    await acked({
      type: "REFUND",
      tx: { originalTransactionId: id, expiresDate: Date.now() + 20 * DAY, revocationDate: Date.now() - MINUTE },
    });
    expect(await plusExpiresAt(u)).toBeNull();
    expect(await status(u)).toEqual({ isActive: false, expiresAt: null, willRenew: null, boostEndsAt: null });
    expect((await subRow(id))!.revoked_at).toBeInstanceOf(Date);
  });

  test("REFUND of one subscription while another one is active keeps Stexx+ from the other", async () => {
    const a = otid();
    const b = otid();
    const u = await subscriber(a, Date.now() + 25 * DAY);
    const otherEnd = Date.now() + 5 * DAY;
    await subscriber(b, otherEnd, u);
    await acked({
      type: "REFUND",
      tx: { originalTransactionId: a, expiresDate: Date.now() + 25 * DAY, revocationDate: Date.now() - MINUTE },
    });
    const s = await status(u);
    expect(s.isActive).toBe(true);
    near(new Date(s.expiresAt!).getTime(), otherEnd);
  });

  test("REFUND of an earlier, already ended month doesn't take away the current one", async () => {
    const id = otid();
    const current = Date.now() + 20 * DAY;
    const u = await subscriber(id, current);
    await acked({
      type: "REFUND",
      tx: {
        originalTransactionId: id,
        purchaseDate: Date.now() - 40 * DAY,
        expiresDate: Date.now() - 10 * DAY,
        revocationDate: Date.now() - DAY,
      },
    });
    expect((await status(u)).isActive).toBe(true);
    near(await plusExpiresAt(u), current);
    expect((await subRow(id))!.revoked_at).toBeNull();
  });

  test("REVOKE (Family Sharing) removes Stexx+ immediately", async () => {
    const id = otid();
    const u = await subscriber(id);
    await acked({ type: "REVOKE", tx: { originalTransactionId: id, revocationDate: Date.now() - MINUTE } });
    expect((await status(u)).isActive).toBe(false);
  });

  test("REFUND_REVERSED restores Stexx+; a reversal signed before the refund does not", async () => {
    const id = otid();
    const expires = Date.now() + 15 * DAY;
    const u = await subscriber(id, expires);
    const refundedAt = Date.now() - 10 * MINUTE;
    // The refunded transaction (the current month, bought before the refund) in all three notifications.
    const tx = { originalTransactionId: id, expiresDate: expires, purchaseDate: refundedAt - DAY };
    await acked({ type: "REFUND", tx: { ...tx, revocationDate: refundedAt } });
    expect((await status(u)).isActive).toBe(false);

    // A stale reversal (an earlier refund's, delivered late) doesn't undo a later refund.
    await acked({ type: "REFUND_REVERSED", signedDate: refundedAt - HOUR, tx });
    expect((await status(u)).isActive).toBe(false);

    await acked({ type: "REFUND_REVERSED", tx });
    const s = await status(u);
    expect(s.isActive).toBe(true);
    near(new Date(s.expiresAt!).getTime(), expires);
  });

  test("reversing an earlier month's refund doesn't undo a later month's refund", async () => {
    const id = otid();
    const now = Date.now();
    const m1 = { originalTransactionId: id, purchaseDate: now - 50 * DAY, expiresDate: now - 20 * DAY };
    const m2 = { originalTransactionId: id, purchaseDate: now - 20 * DAY, expiresDate: now + 10 * DAY };
    const u = await subscriber(id, m1.expiresDate);
    // (1) Month 1 refunded while it ran; (2) month 2 bought after that refund lifts it.
    await acked({ type: "REFUND", tx: { ...m1, revocationDate: now - 30 * DAY } });
    await acked({ type: "DID_RENEW", tx: m2 });
    expect((await status(u)).isActive).toBe(true);
    // (3) Month 2 refunded.
    await acked({ type: "REFUND", tx: { ...m2, revocationDate: now - 2 * DAY } });
    expect((await status(u)).isActive).toBe(false);
    // (4) Apple reverses month 1's refund, signed after month 2's: month 2 stays refunded.
    await acked({ type: "REFUND_REVERSED", tx: m1 });
    expect((await status(u)).isActive).toBe(false);
    expect((await subRow(id))!.revoked_at).toBeInstanceOf(Date);
    // Reversing month 2's refund does bring it back.
    await acked({ type: "REFUND_REVERSED", tx: m2 });
    const s = await status(u);
    expect(s.isActive).toBe(true);
    near(new Date(s.expiresAt!).getTime(), m2.expiresDate);
  });

  test("after a refund, a renewal bought later (new paid period) brings Stexx+ back; a stale one doesn't", async () => {
    const id = otid();
    const u = await subscriber(id);
    const refundedAt = Date.now() - HOUR;
    await acked({ type: "REFUND", tx: { originalTransactionId: id, revocationDate: refundedAt } });
    expect((await status(u)).isActive).toBe(false);
    await acked({ type: "DID_RENEW", tx: { originalTransactionId: id, purchaseDate: refundedAt - DAY } });
    expect((await status(u)).isActive).toBe(false);
    const next = Date.now() + 30 * DAY;
    await acked({ type: "SUBSCRIBED", subtype: "RESUBSCRIBE", tx: { originalTransactionId: id, purchaseDate: Date.now() - MINUTE, expiresDate: next } });
    const s = await status(u);
    expect(s.isActive).toBe(true);
    near(new Date(s.expiresAt!).getTime(), next);
  });

  test("a notification never moves the subscription to another account", async () => {
    const id = otid();
    const u = await subscriber(id);
    await acked({ type: "DID_RENEW", tx: { originalTransactionId: id, expiresDate: Date.now() + 40 * DAY } });
    expect((await subRow(id))!.user_id).toBe(u.id);
  });
});

describe("POST /subscriptions/apple/notifications: idempotency and ignoring", () => {
  test("a replayed notificationUUID is answered 200 without being applied again", async () => {
    const id = otid();
    const u = await subscriber(id);
    const uuid = randomUUID();
    const n: NotificationFields = {
      type: "DID_CHANGE_RENEWAL_STATUS",
      subtype: "AUTO_RENEW_DISABLED",
      uuid,
      tx: { originalTransactionId: id },
      renewal: { autoRenew: false },
    };
    const payload = signedPayload(n);
    expect((await send(payload)).status).toBe(200);
    expect((await status(u)).willRenew).toBe(false);
    // Change the row behind its back: a re-application would set it back to false.
    await sql`UPDATE subscriptions SET auto_renew = true WHERE original_transaction_id = ${id}`;
    expect((await send(payload)).status).toBe(200);
    expect((await send({ ...n, signedDate: Date.now() + 1000 })).status).toBe(200);
    expect((await status(u)).willRenew).toBe(true);
    const [{ n: rows }] = (await sql`SELECT count(*)::int AS n FROM apple_notifications WHERE notification_uuid = ${uuid}`) as [
      { n: number },
    ];
    expect(rows).toBe(1);
  });

  test("an unknown originalTransactionId is acknowledged and creates nothing", async () => {
    const id = otid();
    await acked({ type: "DID_RENEW", tx: { originalTransactionId: id } });
    await acked({ type: "REFUND", tx: { originalTransactionId: id, revocationDate: Date.now() } });
    expect(await subRow(id)).toBeUndefined();
  });

  test("unknown notification types and other products are acknowledged and ignored", async () => {
    const id = otid();
    const expires = Date.now() + 9 * DAY;
    const u = await subscriber(id, expires);
    await acked({ type: "PRICE_INCREASE", subtype: "PENDING", tx: { originalTransactionId: id, expiresDate: Date.now() + 90 * DAY } });
    await acked({ type: "CONSUMPTION_REQUEST", tx: { originalTransactionId: id, revocationDate: Date.now() } });
    await acked({
      type: "REFUND",
      tx: { originalTransactionId: id, productId: "gay.stexx.app.tip", revocationDate: Date.now() - MINUTE },
    });
    near(await plusExpiresAt(u), expires);
    expect(await status(u)).toMatchObject({ isActive: true, willRenew: null });
    expect((await subRow(id))!.revoked_at).toBeNull();
  });

  test("UUIDs older than 30 days are purged as notifications arrive; newer ones stay", async () => {
    const old = `old-${randomUUID()}`;
    const recent = `recent-${randomUUID()}`;
    await sql`
      INSERT INTO apple_notifications (notification_uuid, received_at)
      VALUES (${old}, now() - ${NOTIFICATION_RETENTION_DAYS + 1} * interval '1 day'),
             (${recent}, now() - ${NOTIFICATION_RETENTION_DAYS - 1} * interval '1 day')`;
    await acked({ type: "TEST" });
    const rows = await sql<{ notification_uuid: string }[]>`
      SELECT notification_uuid FROM apple_notifications WHERE notification_uuid IN (${old}, ${recent})`;
    expect(rows.map((r) => r.notification_uuid)).toEqual([recent]);
    await sql`DELETE FROM apple_notifications WHERE notification_uuid = ${recent}`;
  });

  test("only the UUID and arrival time are stored", async () => {
    const cols = await sql<{ column_name: string }[]>`
      SELECT column_name FROM information_schema.columns WHERE table_name = 'apple_notifications' ORDER BY column_name`;
    expect(cols.map((c) => c.column_name)).toEqual(["notification_uuid", "received_at"]);
  });
});

describe("status read-back: willRenew and boostEndsAt", () => {
  test("a free user: everything null", async () => {
    const u = await createUser();
    expect(await status(u)).toEqual({ isActive: false, expiresAt: null, willRenew: null, boostEndsAt: null });
  });

  test("boostEndsAt is set while a boost runs and null once it has ended", async () => {
    const u = await createUser({ plusDays: 5 });
    expect((await status(u)).boostEndsAt).toBeNull();
    const boost = await expectJson<{ endsAt: string }>(await as(u).post("/v1/boosts"));
    expect((await status(u)).boostEndsAt).toBe(boost.endsAt);
    await sql`UPDATE users SET boost_ends_at = now() - interval '1 second' WHERE id = ${u.id}`;
    expect((await status(u)).boostEndsAt).toBeNull();
  });

  test("POST /subscriptions/apple answers with the same shape", async () => {
    setTransactionVerifierForTests(async (s) => JSON.parse(s) as VerifiedTransaction);
    try {
      const u = await createUser();
      const id = otid();
      const t: VerifiedTransaction = {
        originalTransactionId: id,
        productId: PRODUCT,
        expiresDate: Date.now() + 30 * DAY,
        revocationDate: null,
        environment: "Sandbox",
      };
      const body = await expectJson<StatusJson>(await as(u).post("/v1/subscriptions/apple", { json: { signedTransaction: JSON.stringify(t) } }));
      expect(body).toMatchObject({ isActive: true, willRenew: null, boostEndsAt: null });
      await acked({
        type: "DID_CHANGE_RENEWAL_STATUS",
        subtype: "AUTO_RENEW_DISABLED",
        tx: { originalTransactionId: id, expiresDate: t.expiresDate },
        renewal: { autoRenew: false },
      });
      // The client posting the same transaction again keeps what the notification said.
      const again = await expectJson<StatusJson>(await as(u).post("/v1/subscriptions/apple", { json: { signedTransaction: JSON.stringify(t) } }));
      expect(again.willRenew).toBe(false);
    } finally {
      setTransactionVerifierForTests(null);
    }
  });

  test("willRenew follows the subscription that grants the entitlement (the latest expiry)", async () => {
    const short = otid();
    const long = otid();
    const u = await subscriber(short, Date.now() + 2 * DAY);
    await subscriber(long, Date.now() + 20 * DAY, u);
    await acked({ type: "SUBSCRIBED", tx: { originalTransactionId: short, expiresDate: Date.now() + 2 * DAY }, renewal: { autoRenew: true } });
    await acked({
      type: "DID_CHANGE_RENEWAL_STATUS",
      tx: { originalTransactionId: long, expiresDate: Date.now() + 20 * DAY },
      renewal: { autoRenew: false },
    });
    expect((await status(u)).willRenew).toBe(false);
  });
});
