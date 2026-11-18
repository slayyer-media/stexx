import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { Glob } from "bun";
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import {
  createAppleVerifier,
  loadRootCertificates,
  setTransactionVerifierForTests,
  type VerifiedTransaction,
} from "../src/routes/plus.ts";
import { DAY, HOUR } from "../src/lib/time.ts";
import { as, createUser, expectError, expectJson, post, sql, uniq } from "./helpers.ts";

const PRODUCT = "gay.stexx.app.plus.monthly";

/** The fake verifier "decodes" a JSON string; the real one is exercised separately below. */
function jws(t: Partial<VerifiedTransaction> & { originalTransactionId: string }): string {
  const full: VerifiedTransaction = {
    productId: PRODUCT,
    expiresDate: Date.now() + 30 * DAY,
    revocationDate: null,
    environment: "Sandbox",
    ...t,
  };
  return JSON.stringify(full);
}
const otid = () => `otid_${uniq()}`;

beforeAll(() => setTransactionVerifierForTests(async (s) => JSON.parse(s) as VerifiedTransaction));
afterAll(() => setTransactionVerifierForTests(null));

describe("POST /subscriptions/apple", () => {
  test("requires auth", async () => {
    await expectError(await post("/v1/subscriptions/apple", { json: { signedTransaction: "x" } }), 401);
  });

  test("503 subscriptions_unavailable when StoreKit verification is not configured, and nothing is granted", async () => {
    setTransactionVerifierForTests(null);
    try {
      const u = await createUser();
      const res = await as(u).post("/v1/subscriptions/apple", { json: { signedTransaction: jws({ originalTransactionId: otid() }) } });
      await expectError(res, 503, "subscriptions_unavailable");
      const status = await expectJson<{ isActive: boolean }>(await as(u).get("/v1/subscriptions/status"));
      expect(status.isActive).toBe(false);
    } finally {
      setTransactionVerifierForTests(async (s) => JSON.parse(s) as VerifiedTransaction);
    }
  });

  test("grants Plus for a verified transaction; status agrees; dates have no fractional seconds", async () => {
    const u = await createUser();
    const expires = Date.now() + 30 * DAY;
    const body = await expectJson<{ isActive: boolean; expiresAt: string }>(
      await as(u).post("/v1/subscriptions/apple", {
        json: { signedTransaction: jws({ originalTransactionId: otid(), expiresDate: expires }) },
      }),
    );
    expect(body.isActive).toBe(true);
    expect(Math.abs(new Date(body.expiresAt).getTime() - expires)).toBeLessThan(1000);
    const status = await expectJson<{ isActive: boolean; expiresAt: string }>(await as(u).get("/v1/subscriptions/status"));
    expect(status).toEqual(body);
    const [row] = await sql`SELECT plus_expires_at FROM users WHERE id = ${u.id}`;
    expect(row!.plus_expires_at).toBeInstanceOf(Date);
  });

  test("status for a user who never subscribed", async () => {
    const u = await createUser();
    expect(await expectJson(await as(u).get("/v1/subscriptions/status"))).toEqual({ isActive: false, expiresAt: null });
  });

  test("an already expired transaction is recorded but not active", async () => {
    const u = await createUser();
    const body = await expectJson<{ isActive: boolean; expiresAt: string }>(
      await as(u).post("/v1/subscriptions/apple", {
        json: { signedTransaction: jws({ originalTransactionId: otid(), expiresDate: Date.now() - DAY }) },
      }),
    );
    expect(body.isActive).toBe(false);
    expect(body.expiresAt).toBeTruthy();
  });

  test("an older renewal never shortens a newer expiry", async () => {
    const u = await createUser();
    const id = otid();
    const long = Date.now() + 60 * DAY;
    await as(u).post("/v1/subscriptions/apple", { json: { signedTransaction: jws({ originalTransactionId: id, expiresDate: long }) } });
    const body = await expectJson<{ expiresAt: string }>(
      await as(u).post("/v1/subscriptions/apple", {
        json: { signedTransaction: jws({ originalTransactionId: id, expiresDate: Date.now() + 5 * DAY }) },
      }),
    );
    expect(Math.abs(new Date(body.expiresAt).getTime() - long)).toBeLessThan(1000);
  });

  test("a revoked (refunded) transaction is not active and stays revoked when a stale copy is replayed", async () => {
    const u = await createUser();
    const id = otid();
    const body = await expectJson<{ isActive: boolean }>(
      await as(u).post("/v1/subscriptions/apple", {
        json: { signedTransaction: jws({ originalTransactionId: id, revocationDate: Date.now() - HOUR }) },
      }),
    );
    expect(body.isActive).toBe(false);
    const replay = await expectJson<{ isActive: boolean }>(
      await as(u).post("/v1/subscriptions/apple", { json: { signedTransaction: jws({ originalTransactionId: id }) } }),
    );
    expect(replay.isActive).toBe(false);
  });

  test("the subscription follows the latest claimant; the previous holder loses Plus", async () => {
    const a = await createUser();
    const b = await createUser();
    const id = otid();
    const tx = jws({ originalTransactionId: id });
    expect((await expectJson<{ isActive: boolean }>(await as(a).post("/v1/subscriptions/apple", { json: { signedTransaction: tx } }))).isActive).toBe(true);
    expect((await expectJson<{ isActive: boolean }>(await as(b).post("/v1/subscriptions/apple", { json: { signedTransaction: tx } }))).isActive).toBe(true);
    expect((await expectJson<{ isActive: boolean }>(await as(a).get("/v1/subscriptions/status"))).isActive).toBe(false);
  });

  test("validation: missing, empty and unknown fields are 400", async () => {
    const u = await createUser();
    await expectError(await as(u).post("/v1/subscriptions/apple", { json: {} }), 400, "validation_error");
    await expectError(await as(u).post("/v1/subscriptions/apple", { json: { signedTransaction: "" } }), 400, "validation_error");
    await expectError(
      await as(u).post("/v1/subscriptions/apple", { json: { signedTransaction: "x", userId: "p_x" } }),
      400,
      "validation_error",
    );
  });
});

describe("real StoreKit verifier (Apple root CA bundled in certs/)", () => {
  const roots = loadRootCertificates("./certs");

  test("the bundled root is Apple Root CA - G3 (pinned fingerprint)", () => {
    expect(roots.length).toBeGreaterThanOrEqual(1);
    const fp = createHash("sha256").update(readFileSync("./certs/AppleRootCA-G3.cer")).digest("hex");
    expect(fp).toBe("63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179");
  });

  test("unsigned, forged and garbage transactions are rejected (400 invalid_transaction) and grant nothing", async () => {
    const real = createAppleVerifier({
      roots,
      bundleId: "gay.stexx.app",
      environment: "Sandbox",
      productId: PRODUCT,
      onlineChecks: false,
    });
    setTransactionVerifierForTests(real);
    try {
      const u = await createUser();
      const b64 = (o: unknown) => Buffer.from(JSON.stringify(o)).toString("base64url");
      const forged = `${b64({ alg: "ES256", x5c: [roots[0]!.toString("base64")] })}.${b64({
        originalTransactionId: otid(),
        productId: PRODUCT,
        bundleId: "gay.stexx.app",
        environment: "Sandbox",
        expiresDate: Date.now() + DAY,
      })}.${Buffer.from("not a signature").toString("base64url")}`;
      for (const bad of ["garbage", "a.b.c", forged]) {
        await expectError(await as(u).post("/v1/subscriptions/apple", { json: { signedTransaction: bad } }), 400, "invalid_transaction");
      }
      const status = await expectJson<{ isActive: boolean }>(await as(u).get("/v1/subscriptions/status"));
      expect(status.isActive).toBe(false);
    } finally {
      setTransactionVerifierForTests(async (s) => JSON.parse(s) as VerifiedTransaction);
    }
  });
});

describe("POST /boosts", () => {
  test("402 requires_plus without Stexx+ (also when Plus has expired)", async () => {
    const free = await createUser();
    await expectError(await as(free).post("/v1/boosts"), 402, "requires_plus");
    const lapsed = await createUser({ plusDays: -1 });
    await expectError(await as(lapsed).post("/v1/boosts"), 402, "requires_plus");
  });

  test("starts a one hour boost; a second call returns the same end time (no stacking)", async () => {
    const u = await createUser({ plusDays: 5 });
    const before = Date.now();
    const first = await expectJson<{ endsAt: string }>(await as(u).post("/v1/boosts"));
    const ends = new Date(first.endsAt).getTime();
    expect(ends).toBeGreaterThan(before + HOUR - 5000);
    expect(ends).toBeLessThan(Date.now() + HOUR + 1000);
    const second = await expectJson<{ endsAt: string }>(await as(u).post("/v1/boosts"));
    expect(second.endsAt).toBe(first.endsAt);
    const [row] = await sql`SELECT boost_ends_at FROM users WHERE id = ${u.id}`;
    expect(row!.boost_ends_at).toBeInstanceOf(Date);
  });

  test("a finished boost can be restarted", async () => {
    const u = await createUser({ plusDays: 5 });
    await sql`UPDATE users SET boost_ends_at = now() - interval '1 minute' WHERE id = ${u.id}`;
    const res = await expectJson<{ endsAt: string }>(await as(u).post("/v1/boosts"));
    expect(new Date(res.endsAt).getTime()).toBeGreaterThan(Date.now() + HOUR - 5000);
  });
});

describe("POST /v1/dev/plus (dev only)", () => {
  test("grants 30 days by default, or the requested number of days", async () => {
    const u = await createUser();
    const res = await expectJson<{ isActive: boolean; expiresAt: string }>(await as(u).post("/v1/dev/plus"));
    expect(res.isActive).toBe(true);
    expect(new Date(res.expiresAt).getTime()).toBeGreaterThan(Date.now() + 29 * DAY);
    expect(new Date(res.expiresAt).getTime()).toBeLessThan(Date.now() + 31 * DAY);
    const longer = await expectJson<{ expiresAt: string }>(await as(u).post("/v1/dev/plus", { json: { days: 90 } }));
    expect(new Date(longer.expiresAt).getTime()).toBeGreaterThan(Date.now() + 89 * DAY);
    const [{ n }] = (await sql`SELECT count(*)::int AS n FROM subscriptions WHERE user_id = ${u.id} AND environment = 'Dev'`) as [{ n: number }];
    expect(n).toBe(2);
  });

  test("requires auth and a valid body", async () => {
    await expectError(await post("/v1/dev/plus"), 401);
    const u = await createUser();
    await expectError(await as(u).post("/v1/dev/plus", { json: { days: 0 } }), 400, "validation_error");
    await expectError(await as(u).post("/v1/dev/plus", { json: { days: 5, plus: true } }), 400, "validation_error");
  });

  test("production code never imports the dev module (it is only reachable via the dynamic dev import)", async () => {
    const offenders: string[] = [];
    for await (const f of new Glob("src/**/*.ts").scan(".")) {
      if (f.startsWith("src/dev/")) continue;
      if (/from\s+["'][^"']*dev\/(plus|routes)(\.ts)?["']/.test(readFileSync(f, "utf8"))) offenders.push(f);
    }
    // app.ts uses a dynamic import() guarded by config.devAuth; that is the only allowed reference.
    expect(offenders).toEqual([]);
  });
});
