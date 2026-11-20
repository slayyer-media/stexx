/**
 * Schema guards for the account-deletion promise (README "Privacy guarantees": DELETE /me hard-deletes
 * everything). The DELETE /me test in me.test.ts lists the tables it knows about; these guards catch the ones a
 * future migration adds, by reading the catalog:
 *
 * 1. Every foreign key to users(id) is ON DELETE CASCADE, or is on SET_NULL_ALLOWLIST with a reason (and its column
 *    is nullable, or the delete would fail).
 * 2. The same for foreign keys into any table that a user's delete cascades into (photos, conversations, messages,
 *    ...): NO ACTION / RESTRICT there would make DELETE /me fail, and SET NULL keeps a row after its owner is gone.
 * 3. Text columns named like an id (`*_id`, `*_ids`) or like an account (`owner`, `subject`, `blocked_user`, ...; see
 *    ACCOUNT_COLUMN) that carry no foreign key are on UNLINKED_ID_ALLOWLIST with a reason, so a user id stored without a
 *    cascade gets a decision and a comment.
 *
 * Limits: the catalog only shows names and types. An account id stored under a name neither pattern matches (`muter`),
 * packed into a composite key (abuse_counters.key) or inside jsonb cannot be seen here; review those by hand.
 *
 * The checks run on a scratch schema migrated from this checkout's migrations/, not on the shared `public` schema
 * (other branches' migrations may have been applied to the shared test database).
 */
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import type postgres from "postgres";
import { readdirSync } from "node:fs";
import { join } from "node:path";
import { migrate } from "../src/db/migrate.ts";
import { createScratchSchema, type ScratchSchema } from "./scratch-schema.ts";

/**
 * `table.column` → why a deleted account (or a row deleted with it) leaves this row behind with NULL instead of
 * deleting it. Every entry must still exist as an ON DELETE SET NULL key on a nullable column.
 */
const SET_NULL_ALLOWLIST: Record<string, string> = {
  "reports.reporter_id": "a report outlives the reporter's account, anonymized (001_init)",
  "reports.reported_id": "a report about a deleted account stays for moderation history, anonymized (001_init)",
  "reports.conversation_id": "a report outlives the reported conversation; its shared evidence is in report_evidence (001_init)",
  "photo_flags.matched_owner_id": "a duplicate-photo flag belongs to the newer photo's owner; the other account may go (106)",
  "photo_flags.matched_photo_id": "same: the matched photo on the other account may be deleted first (106)",
  "moderation_actions.user_id": "the moderation audit trail survives account deletion, anonymized (107)",
  "photo_hash_blocklist.source_flag_id":
    "a moderator's blocklist entry outlives the flag (and account) it came from: that is what a blocklist is for; only the hash, a label and the moderator handle are kept (114)",
  "staff_audit.target_user_id":
    "the staff audit trail (who looked at or acted on an account) survives account deletion, anonymized like moderation_actions; the table is append-only apart from this (124)",
};

/**
 * `table.column` → why this text column looks like an id but has no foreign key. Every entry must still exist and
 * still have no foreign key. Entries that can hold an account id say how they go away.
 */
const UNLINKED_ID_ALLOWLIST: Record<string, string> = {
  "abuse_counters.key":
    "'<limit>:<subject>' where the subject may be an account id; no FK on purpose (limits must survive delete-and-recreate), rows expire and are purged by the jobs (105)",
  "auth_challenges.webauthn_user_id": "random WebAuthn handle for a registration that has no user yet; 5 min TTL (001_init)",
  "passkey_credentials.webauthn_user_id": "random WebAuthn handle, not a users.id; the row cascades through user_id (001_init)",
  "sessions.family_id": "refresh-token family id; the row cascades through user_id (001_init)",
  "messages.client_id": "client idempotency key; the row cascades through sender_id / conversation_id (001_init)",
  "report_evidence.message_id": "not a FK on purpose: the message may expire before the report is closed (107)",
  "subscriptions.original_transaction_id": "Apple transaction id; the row cascades through user_id (001_init)",
  "subscriptions.product_id": "App Store product id, not a row id (001_init)",
  "moderation_actions.report_ids": "ids of reports (which outlive accounts, anonymized), not account ids (107)",
  "moderation_actions.actor": "'system' or a moderator's handle, never an account id (107)",
  "reports.reporter_ip_hash": "keyed hash of the reporter's IP, not an account id; cleared with the evidence by the retention job (107)",
  "spam_message_features.conversation_id":
    "not a FK on purpose: the features outlive an expiring message for their short TTL; the row cascades through sender_id and expires after SPAM_HASH_TTL_HOURS (112)",
  "spam_flags.lifted_by": "'system' or a moderator's handle, never an account id; the row cascades through user_id (112)",
  "photo_hash_blocklist.added_by": "a moderator's handle, never an account id (114)",
  "spam_contacts.conversation_id":
    "not a FK on purpose: the ledger row outlives a cleared thread or an expired message for its short TTL; it cascades through sender_id and other_id and expires after SPAM_BLOCKED_DAYS / SPAM_WINDOW_HOURS (112)",
  "staff_audit.session_id": "a staff console session id (staff_sessions), never an account id; no FK because sessions are pruned and the append-only record stays (124)",
  "staff_audit.target_ref":
    "a report, photo flag, staff or session id; reports and flags may be deleted first and the append-only record stays; account ids go in target_user_id (124)",
  "staff_audit.target_kind": "the kind of target (a closed list: account, report, photo_flag, staff, session), not an id (124)",
  "staff_audit.ticket_ref": "an opaque external support ticket number, never an account id or an email (124)",
  "staff_challenges.bound_target":
    "the target id a per-action step-up is bound to (an account, report or staff id); the challenge expires after 5 minutes and is pruned (124)",
};

/**
 * Allowlist reasons end with the migration that adds the column, e.g. "(112)". Several branches add migrations in
 * parallel, so an entry may land before its migration does: an entry whose migration number is above the highest
 * migration in this checkout is not reported as stale (it can't exist yet). Every other stale entry still fails.
 */
const HIGHEST_MIGRATION = Math.max(
  ...readdirSync(join(import.meta.dir, "..", "migrations"))
    .map((f) => /^(\d{3})_/.exec(f)?.[1])
    .filter((n): n is string => n !== undefined)
    .map(Number),
);
export function migrationNotYetHere(reason: string, highest = HIGHEST_MIGRATION): boolean {
  const m = /\((\d{3})\)\s*$/.exec(reason);
  return m !== null && Number(m[1]) > highest;
}

/**
 * Column names that look like they hold an account id: `*_id` / `*_ids`, or a role word for a person anywhere in the
 * name. Matched against lower-case Postgres column names. Widen it when a migration invents a new word for a person.
 */
const ACCOUNT_COLUMN =
  "_ids?$|user|owner|author|member|subject|peer|target|blocker|blocked|muter|muted|reporter|reported|sender|recipient|viewer|actor|account|_by$";

const ACTIONS: Record<string, string> = { a: "NO ACTION", r: "RESTRICT", c: "CASCADE", n: "SET NULL", d: "SET DEFAULT" };

interface ForeignKey {
  table: string;
  columns: string[];
  ref_table: string;
  on_delete: string;
  nullable: boolean;
}

async function foreignKeys(db: postgres.Sql | postgres.TransactionSql, schema: string): Promise<ForeignKey[]> {
  return db<ForeignKey[]>`
    SELECT rel.relname AS table,
           array_agg(a.attname::text ORDER BY k.ord) AS columns,
           ref.relname AS ref_table,
           c.confdeltype AS on_delete,
           bool_and(NOT a.attnotnull) AS nullable
    FROM pg_constraint c
    JOIN pg_class rel ON rel.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = rel.relnamespace
    JOIN pg_class ref ON ref.oid = c.confrelid
    CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord)
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.contype = 'f' AND c.conparentid = 0 AND n.nspname = ${schema}
    GROUP BY c.oid, rel.relname, ref.relname, c.confdeltype
    ORDER BY 1, 2`;
}

/** Tables whose rows a user's delete removes: users, plus everything that cascades from them, transitively. */
function deletionClosure(fks: ForeignKey[]): Set<string> {
  const closure = new Set(["users"]);
  for (let grew = true; grew; ) {
    grew = false;
    for (const fk of fks) {
      if (fk.on_delete === "c" && closure.has(fk.ref_table) && !closure.has(fk.table)) {
        closure.add(fk.table);
        grew = true;
      }
    }
  }
  return closure;
}

/** Problems with foreign keys into the deletion closure, one message per key, naming table and column. */
async function deletionViolations(db: postgres.Sql | postgres.TransactionSql, schema: string): Promise<string[]> {
  const fks = await foreignKeys(db, schema);
  const closure = deletionClosure(fks);
  const problems: string[] = [];
  const setNullSeen = new Set<string>();
  for (const fk of fks) {
    if (!closure.has(fk.ref_table)) continue;
    const name = `${fk.table}.${fk.columns.join(",")}`;
    const target = fk.ref_table === "users" ? "users(id)" : `${fk.ref_table} (deleted with its account)`;
    const action = ACTIONS[fk.on_delete] ?? fk.on_delete;
    if (fk.on_delete === "c") continue;
    if (fk.on_delete === "n") {
      setNullSeen.add(name);
      if (!(name in SET_NULL_ALLOWLIST)) {
        problems.push(
          `${name} references ${target} ON DELETE SET NULL, so the row outlives the account. ` +
            `Use ON DELETE CASCADE, or add "${name}" to SET_NULL_ALLOWLIST in test/schema-guards.test.ts with a reason.`,
        );
      } else if (!fk.nullable) {
        problems.push(`${name} references ${target} ON DELETE SET NULL but is NOT NULL, so deleting an account fails.`);
      }
      continue;
    }
    const effect = fk.on_delete === "d" ? "the row outlives the account" : "DELETE /me fails while such a row exists";
    problems.push(`${name} references ${target} ON DELETE ${action}: ${effect}. Use ON DELETE CASCADE.`);
  }
  for (const [name, reason] of Object.entries(SET_NULL_ALLOWLIST)) {
    if (!setNullSeen.has(name) && !migrationNotYetHere(reason)) {
      problems.push(`SET_NULL_ALLOWLIST has "${name}", which is no longer an ON DELETE SET NULL key into the deletion closure: remove it.`);
    }
  }
  return problems;
}

/** Text id- or account-like columns (ACCOUNT_COLUMN) without a foreign key that are not on UNLINKED_ID_ALLOWLIST (and stale allowlist entries). */
async function unlinkedIdViolations(db: postgres.Sql | postgres.TransactionSql, schema: string): Promise<string[]> {
  const rows = await db<{ name: string; looks_like_id: boolean; has_fk: boolean }[]>`
    SELECT c.relname || '.' || a.attname AS name,
           (a.attname ~ ${ACCOUNT_COLUMN}) AS looks_like_id,
           EXISTS (SELECT 1 FROM pg_constraint f
                   WHERE f.conrelid = c.oid AND f.contype = 'f' AND a.attnum = ANY (f.conkey)) AS has_fk
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid
    JOIN pg_type t ON t.oid = a.atttypid
    LEFT JOIN pg_type et ON et.oid = t.typelem AND t.typcategory = 'A'
    WHERE n.nspname = ${schema} AND c.relkind IN ('r', 'p') AND a.attnum > 0 AND NOT a.attisdropped
      AND coalesce(et.typcategory, t.typcategory) = 'S'
    ORDER BY 1`;
  const problems: string[] = [];
  const byName = new Map(rows.map((r) => [r.name, r]));
  for (const r of rows) {
    if (r.looks_like_id && !r.has_fk && !(r.name in UNLINKED_ID_ALLOWLIST)) {
      problems.push(
        `${r.name} is a text column named like an id or account, with no foreign key. If it can hold an account id, reference users(id) ON DELETE CASCADE; ` +
          `otherwise add "${r.name}" to UNLINKED_ID_ALLOWLIST in test/schema-guards.test.ts with the reason.`,
      );
    }
  }
  for (const [name, reason] of Object.entries(UNLINKED_ID_ALLOWLIST)) {
    const r = byName.get(name);
    if (!r && migrationNotYetHere(reason)) continue;
    if (!r) problems.push(`UNLINKED_ID_ALLOWLIST has "${name}", which is not a text column any more: remove it.`);
    else if (r.has_fk) problems.push(`UNLINKED_ID_ALLOWLIST has "${name}", which now has a foreign key: remove it.`);
  }
  return problems;
}

let scratch: ScratchSchema;
beforeAll(async () => {
  scratch = await createScratchSchema("guards");
  // A private lock key: this scratch migration must not hold up the shared database's migrators.
  await migrate(scratch.url, { quiet: true, lockKey: 0x57e78 });
});
afterAll(async () => {
  await scratch?.drop();
});

/** Runs `fn` in a transaction that is always rolled back, so probe tables never outlive the test. */
async function probe(ddl: string, fn: (tx: postgres.TransactionSql) => Promise<void>) {
  const rollback = new Error("rollback");
  await scratch.db
    .begin(async (tx) => {
      await tx.unsafe(`SET LOCAL search_path TO ${scratch.name}`);
      await tx.unsafe(ddl);
      await fn(tx);
      throw rollback;
    })
    .catch((e) => {
      if (e !== rollback) throw e;
    });
}

describe("schema guards: account deletion", () => {
  test("every foreign key to users(id), directly or through a cascade, is CASCADE or an allowlisted SET NULL", async () => {
    expect(await deletionViolations(scratch.db, scratch.name)).toEqual([]);
  });

  test("the deletion closure covers the user-owned tables (sanity check of the walk)", async () => {
    const closure = deletionClosure(await foreignKeys(scratch.db, scratch.name));
    for (const t of ["photos", "sessions", "conversations", "messages", "conversation_members", "e2e_one_time_prekeys", "device_accounts"]) {
      expect(closure.has(t)).toBe(true);
    }
    // These keep rows after an account is deleted, on purpose.
    for (const t of ["reports", "moderation_actions", "devices", "abuse_counters"]) expect(closure.has(t)).toBe(false);
  });

  test("text id columns without a foreign key are all allowlisted with a reason", async () => {
    expect(await unlinkedIdViolations(scratch.db, scratch.name)).toEqual([]);
  });

  test("a new user-keyed table without ON DELETE CASCADE fails, naming the table and column", async () => {
    await probe(`CREATE TABLE probe_notes (id text PRIMARY KEY, author_user_id text REFERENCES users(id), body text)`, async (tx) => {
      const problems = await deletionViolations(tx, scratch.name);
      expect(problems).toHaveLength(1);
      expect(problems[0]).toContain("probe_notes.author_user_id references users(id) ON DELETE NO ACTION");
    });
    await probe(`CREATE TABLE probe_likes (user_id text REFERENCES users(id) ON DELETE RESTRICT)`, async (tx) => {
      expect(await deletionViolations(tx, scratch.name)).toEqual([expect.stringContaining("probe_likes.user_id references users(id) ON DELETE RESTRICT")]);
    });
  });

  test("an unlisted SET NULL key to users(id) fails; so does one on a NOT NULL column", async () => {
    await probe(`CREATE TABLE probe_audit (target_id text REFERENCES users(id) ON DELETE SET NULL)`, async (tx) => {
      expect(await deletionViolations(tx, scratch.name)).toEqual([
        expect.stringContaining('probe_audit.target_id references users(id) ON DELETE SET NULL, so the row outlives the account. Use ON DELETE CASCADE, or add "probe_audit.target_id"'),
      ]);
    });
    await probe(`ALTER TABLE moderation_actions ALTER COLUMN user_id SET NOT NULL`, async (tx) => {
      expect(await deletionViolations(tx, scratch.name)).toEqual([expect.stringContaining("moderation_actions.user_id references users(id) ON DELETE SET NULL but is NOT NULL")]);
    });
  });

  test("a key into a table deleted with the account (photos) must cascade too", async () => {
    await probe(`CREATE TABLE probe_photo_notes (photo_id text NOT NULL REFERENCES photos(id), note text)`, async (tx) => {
      expect(await deletionViolations(tx, scratch.name)).toEqual([
        expect.stringContaining("probe_photo_notes.photo_id references photos (deleted with its account) ON DELETE NO ACTION"),
      ]);
    });
    // A cascading one is fine, and joins the closure.
    await probe(`CREATE TABLE probe_photo_tags (photo_id text NOT NULL REFERENCES photos(id) ON DELETE CASCADE)`, async (tx) => {
      expect(await deletionViolations(tx, scratch.name)).toEqual([]);
    });
  });

  test("a new text id column without a foreign key fails until it is allowlisted", async () => {
    await probe(`CREATE TABLE probe_counters (subject_user_id text, peer_ids text[], amount int)`, async (tx) => {
      const problems = await unlinkedIdViolations(tx, scratch.name);
      expect(problems).toEqual([
        expect.stringContaining("probe_counters.peer_ids is a text column named like an id or account, with no foreign key"),
        expect.stringContaining("probe_counters.subject_user_id is a text column named like an id or account, with no foreign key"),
      ]);
    });
  });

  test("account ids in columns not named *_id are caught too", async () => {
    await probe(
      `CREATE TABLE probe_mutes (owner text, subject text, blocked_user text, muter text, muted text[], reason text, until timestamptz)`,
      async (tx) => {
        const problems = await unlinkedIdViolations(tx, scratch.name);
        const named = problems.map((p) => p.split(" ")[0]);
        expect(named).toEqual(["probe_mutes.blocked_user", "probe_mutes.muted", "probe_mutes.muter", "probe_mutes.owner", "probe_mutes.subject"]);
      },
    );
  });

  test("entries for a migration that isn't in this checkout yet are not stale; all others are", () => {
    expect(migrationNotYetHere("a reason (112)", 111)).toBe(true);
    expect(migrationNotYetHere("a reason (112)", 112)).toBe(false);
    expect(migrationNotYetHere("a reason without a migration", 111)).toBe(false);
    expect(migrationNotYetHere("(112) only at the end counts: (107)", 111)).toBe(false);
  });

  test("stale allowlist entries fail", async () => {
    await probe(`ALTER TABLE photo_flags DROP COLUMN matched_owner_id; ALTER TABLE report_evidence DROP COLUMN message_id`, async (tx) => {
      expect(await deletionViolations(tx, scratch.name)).toEqual([expect.stringContaining('SET_NULL_ALLOWLIST has "photo_flags.matched_owner_id"')]);
      expect(await unlinkedIdViolations(tx, scratch.name)).toEqual([expect.stringContaining('UNLINKED_ID_ALLOWLIST has "report_evidence.message_id"')]);
    });
  });
});
