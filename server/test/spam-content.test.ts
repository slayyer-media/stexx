/**
 * Content signals for the spam heuristics (lib/abuse/handles.ts, minhash.ts, content.ts): the shared pattern table and
 * its vectors, the iOS copy being in sync, near-duplicate signatures, and the new-account handle rule.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { containsLink, encryptedContentPolicy, plaintextContentPolicy, plaintextFeatures } from "../src/lib/abuse/content.ts";
import { contentRulesTable, findHandles, normalizeForRules } from "../src/lib/abuse/handles.ts";
import { normalizeForSignature, signatureSimilarity, textSignature, MINHASH_SIZE } from "../src/lib/abuse/minhash.ts";
import { overrideTrustForTests } from "../src/lib/abuse/trust.ts";
import { as, createUser, expectError, expectJson, sql, uniq, type TestUser } from "./helpers.ts";

const restores: (() => void)[] = [];
afterEach(() => {
  while (restores.length) restores.pop()!();
});

const SERVER_TABLE = join(import.meta.dir, "..", "src", "lib", "abuse", "content-rules.json");
const IOS_TABLE = join(import.meta.dir, "..", "..", "ios", "Stexx", "E2E", "content-rules.json");

describe("shared content-rules table", () => {
  test("the iOS app bundles a byte-identical copy (edit the server file, then copy it)", () => {
    expect(readFileSync(IOS_TABLE, "utf8")).toBe(readFileSync(SERVER_TABLE, "utf8"));
  });

  test("every handle vector matches exactly the rules it names", () => {
    const { handles } = contentRulesTable.vectors;
    expect(handles.length).toBeGreaterThan(30);
    for (const v of handles) {
      expect({ text: v.text, matches: findHandles(v.text).map((h) => h.id).sort() }).toEqual({
        text: v.text,
        matches: [...v.matches].sort(),
      });
    }
  });

  test("every rule has a positive vector, ids are unique, kinds are known", () => {
    const ids = contentRulesTable.handleRules.map((r) => r.id);
    expect(new Set(ids).size).toBe(ids.length);
    const covered = new Set(contentRulesTable.vectors.handles.flatMap((v) => v.matches));
    for (const id of ids) expect(covered.has(id)).toBe(true);
    for (const r of contentRulesTable.handleRules) expect(["payment", "crypto", "redirect"]).toContain(r.kind);
  });

  test("patterns avoid syntax JavaScript and ICU read differently", () => {
    for (const r of contentRulesTable.handleRules) {
      // ICU treats "[:" as the start of a POSIX class; \b, \w and \d differ between the engines.
      expect(r.pattern).not.toMatch(/\[:|\\b|\\w|\\d/);
    }
  });

  test("link vectors (shared with the app) agree with containsLink", () => {
    for (const t of contentRulesTable.vectors.links.match) expect(containsLink(t)).toBe(true);
    for (const t of contentRulesTable.vectors.links.noMatch) expect(containsLink(t)).toBe(false);
  });

  test("normalization folds full-width letters and drops zero-width characters", () => {
    expect(normalizeForRules("ｖｅｎ​ｍｏ")).toBe("venmo");
  });
});

describe("near-duplicate signatures (keyed MinHash)", () => {
  const pitch = "Hey cutie, I'm new here. See my private pics on my page, you won't regret it";

  test("same text with different case, spacing, punctuation and emoji: identical signature", () => {
    const a = textSignature(pitch, 16)!;
    const b = textSignature("HEY cutie!!! i'm new here 😍 see my private pics on my page... you won't regret it", 16)!;
    expect(a).toHaveLength(MINHASH_SIZE);
    expect(signatureSimilarity(a, b)).toBe(1);
  });

  test("small edits (a different name, one word added) stay similar; different messages don't", () => {
    const a = textSignature(`Hey Jake, ${pitch}`, 16)!;
    const b = textSignature(`Hey Sam, ${pitch} xx`, 16)!;
    expect(signatureSimilarity(a, b)).toBeGreaterThanOrEqual(0.6);
    const other = textSignature("Are you around the park later? I'm walking the dog around six", 16)!;
    expect(signatureSimilarity(a, other)).toBeLessThan(0.3);
  });

  test("short greetings get no signature; values are 32-bit integers and the text can't be read back", () => {
    expect(textSignature("hey whats up", 16)).toBeNull();
    const sig = textSignature(pitch, 16)!;
    for (const v of sig) expect(Number.isInteger(v) && v >= -(2 ** 31) && v < 2 ** 31).toBe(true);
    expect(normalizeForSignature("Hi!!  THERE 😍 you")).toBe("hi there you");
  });

  test("features: plaintext only; the encrypted policy never inspects anything", () => {
    const f = plaintextFeatures("send it to my cashapp $JakeB99 or tg: jakebee, www.example.com")!;
    expect(f).toMatchObject({ hasLink: true, hasPayment: true, hasRedirect: true });
    expect(plaintextFeatures(null)).toBeNull();
    expect(plaintextContentPolicy.features).toBeDefined();
    expect(encryptedContentPolicy.features).toBeUndefined();
  });
});

describe("new accounts can't share handles (plaintext; the app runs the same table before encrypting)", () => {
  async function open(me: TestUser, other: TestUser): Promise<string> {
    return (await expectJson(await as(me).post("/v1/conversations", { json: { participantID: other.id } }))).id;
  }
  const send = (me: TestUser, conv: string, text: string) =>
    as(me).post(`/v1/conversations/${conv}/messages`, { json: { clientID: uniq(), text } });

  test("handles_not_allowed for a restricted account, fine once established", async () => {
    restores.push(overrideTrustForTests({ firstMessagesPerDay: 50 }));
    const newbie = await createUser();
    const other = await createUser();
    const conv = await open(newbie, other);
    for (const t of ["venmo me @jake-b", "btc: 1BoatSLRHtKNngkdXEeobR76b53LETtpyT", "check out my onlyfans"]) {
      const err = await expectError(await send(newbie, conv, t), 403, "handles_not_allowed");
      expect(err.message).toContain("New accounts");
    }
    await expectJson(await send(newbie, conv, "drinks are $5 at happy hour, want to come?"));
    const veteran = await createUser();
    await sql`UPDATE users SET created_at = now() - interval '30 days' WHERE id = ${veteran.id}`;
    await expectJson(await send(veteran, await open(veteran, other), "venmo me @jake-b for the tickets"));
  });

  test("GET /e2e/config tells a restricted app to refuse handles too", async () => {
    const newbie = await createUser();
    const cfg = await expectJson(await as(newbie).get("/v1/e2e/config"));
    expect(cfg.contentRules).toMatchObject({ restricted: true, noLinks: true, noHandles: true });
  });
});
