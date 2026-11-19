/**
 * The migration runner (src/db/migrate.ts) against scratch migration files, each test in its own scratch schema on
 * the shared test database (test/scratch-schema.ts), so nothing here touches the shared tables or their
 * schema_migrations. Most tests use a private advisory-lock key; one checks the real key with a short hold.
 */
import { afterEach, describe, expect, spyOn, test } from "bun:test";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import postgres from "postgres";
import { LOCK_KEY, MIGRATIONS_DIR, migrate, planMigrations } from "../src/db/migrate.ts";
import { createScratchSchema, type ScratchSchema } from "./scratch-schema.ts";

/** Not the runner's key, so these tests never wait on (or hold up) the shared database's migrators. */
const TEST_LOCK = 0x57e79;

const cleanups: (() => Promise<void>)[] = [];
afterEach(async () => {
  while (cleanups.length) await cleanups.pop()!();
});

async function scratch(): Promise<ScratchSchema> {
  const s = await createScratchSchema("migrate");
  cleanups.push(() => s.drop());
  return s;
}

async function migrationsDir(files: Record<string, string>): Promise<string> {
  const dir = await mkdtemp(join(tmpdir(), "stexx-migrate-test-"));
  cleanups.push(() => rm(dir, { recursive: true, force: true }));
  for (const [name, text] of Object.entries(files)) await writeFile(join(dir, name), text);
  return dir;
}

async function versions(s: ScratchSchema): Promise<string[]> {
  const rows = await s.db.unsafe(`SELECT version FROM ${s.name}.schema_migrations ORDER BY version`);
  return rows.map((r) => r.version as string);
}

async function tableExists(s: ScratchSchema, table: string): Promise<boolean> {
  const [row] = await s.db<{ ok: boolean }[]>`SELECT to_regclass(${`${s.name}.${table}`}) IS NOT NULL AS ok`;
  return row!.ok;
}

/** A connection of its own, for holding an advisory lock while migrate() runs on another. */
function lockHolder(url: string) {
  const db = postgres(url, { max: 1, onnotice: () => {} });
  cleanups.push(() => db.end({ timeout: 5 }));
  return db;
}

describe("planMigrations", () => {
  test("keeps NNN_name.sql files in numeric order and reports everything else (not dotfiles)", () => {
    const plan = planMigrations(["010_c.sql", ".DS_Store", "001_init.sql", "notes.md", "002_b-c.sql", "1_short.sql", "004_x.SQL", "005 space.sql", "006_x.sql.bak"]);
    expect(plan.files).toEqual(["001_init.sql", "002_b-c.sql", "010_c.sql"]);
    expect(plan.ignored).toEqual(["004_x.SQL", "005 space.sql", "006_x.sql.bak", "1_short.sql", "notes.md"]);
  });

  test("the real migrations/ directory has nothing the runner would skip", async () => {
    const { readdir } = await import("node:fs/promises");
    expect(planMigrations(await readdir(MIGRATIONS_DIR)).ignored).toEqual([]);
  });
});

describe("migrate()", () => {
  test("applies files in numeric order, records them, and is idempotent", async () => {
    const s = await scratch();
    const dir = await migrationsDir({
      "010_third.sql": `INSERT INTO run_log (name) VALUES ('third');`,
      "001_first.sql": `CREATE TABLE run_log (seq int GENERATED ALWAYS AS IDENTITY, name text); INSERT INTO run_log (name) VALUES ('first');`,
      "002_second.sql": `INSERT INTO run_log (name) VALUES ('second');`,
    });
    expect(await migrate(s.url, { quiet: true, dir, lockKey: TEST_LOCK })).toEqual(["001_first", "002_second", "010_third"]);
    const log = await s.db.unsafe(`SELECT name FROM ${s.name}.run_log ORDER BY seq`);
    expect(log.map((r) => r.name)).toEqual(["first", "second", "third"]);
    expect(await versions(s)).toEqual(["001_first", "002_second", "010_third"]);

    // Again: nothing to do. Then a new file is applied alone.
    expect(await migrate(s.url, { quiet: true, dir, lockKey: TEST_LOCK })).toEqual([]);
    await writeFile(join(dir, "011_fourth.sql"), `INSERT INTO run_log (name) VALUES ('fourth');`);
    expect(await migrate(s.url, { quiet: true, dir, lockKey: TEST_LOCK })).toEqual(["011_fourth"]);
    expect((await s.db.unsafe(`SELECT count(*)::int AS n FROM ${s.name}.run_log`))[0]!.n).toBe(4);
  });

  test("a failing migration rolls back entirely, is not recorded, stops the run, and releases the lock", async () => {
    const s = await scratch();
    const dir = await migrationsDir({
      "001_ok.sql": `CREATE TABLE kept (x int);`,
      "002_broken.sql": `CREATE TABLE half_done (x int); INSERT INTO half_done VALUES (1); SELECT 1 / 0;`,
      "003_after.sql": `CREATE TABLE never_reached (x int);`,
    });
    await expect(migrate(s.url, { quiet: true, dir, lockKey: TEST_LOCK })).rejects.toThrow(/division by zero/);
    expect(await versions(s)).toEqual(["001_ok"]);
    expect(await tableExists(s, "kept")).toBe(true);
    expect(await tableExists(s, "half_done")).toBe(false);
    expect(await tableExists(s, "never_reached")).toBe(false);

    // The lock was released (a second session can take it), and a fixed file applies on the next run.
    const other = lockHolder(s.url);
    expect((await other`SELECT pg_try_advisory_lock(${TEST_LOCK}) AS ok`)[0]!.ok).toBe(true);
    await other`SELECT pg_advisory_unlock(${TEST_LOCK})`;
    await writeFile(join(dir, "002_broken.sql"), `CREATE TABLE half_done (x int);`);
    expect(await migrate(s.url, { quiet: true, dir, lockKey: TEST_LOCK })).toEqual(["002_broken", "003_after"]);
  });

  test("files that don't match NNN_name.sql are skipped with a warning naming each one", async () => {
    const s = await scratch();
    const dir = await migrationsDir({
      "001_ok.sql": `CREATE TABLE ok (x int);`,
      "2_missing_digits.sql": `CREATE TABLE skipped_a (x int);`,
      "003_upper.SQL": `CREATE TABLE skipped_b (x int);`,
      "README.md": `notes`,
      ".DS_Store": ``,
    });
    const warn = spyOn(console, "warn").mockImplementation(() => {});
    try {
      expect(await migrate(s.url, { quiet: true, dir, lockKey: TEST_LOCK })).toEqual(["001_ok"]);
      const messages = warn.mock.calls.map((c) => String(c[0]));
      expect(messages).toEqual([
        "[migrate] skipping 003_upper.SQL: not a migration name (NNN_name.sql)",
        "[migrate] skipping 2_missing_digits.sql: not a migration name (NNN_name.sql)",
        "[migrate] skipping README.md: not a migration name (NNN_name.sql)",
      ]);
    } finally {
      warn.mockRestore();
    }
    expect(await tableExists(s, "skipped_a")).toBe(false);
    expect(await tableExists(s, "skipped_b")).toBe(false);
  });

  test("concurrent runs serialize on the advisory lock: each file is applied exactly once", async () => {
    const s = await scratch();
    const dir = await migrationsDir({
      "001_slow.sql": `CREATE TABLE runs (n int); SELECT pg_sleep(0.3); INSERT INTO runs VALUES (1);`,
      "002_more.sql": `INSERT INTO runs VALUES (2);`,
    });
    const results = await Promise.all([1, 2, 3].map(() => migrate(s.url, { quiet: true, dir, lockKey: TEST_LOCK })));
    expect(results.flat().sort()).toEqual(["001_slow", "002_more"]);
    expect(results.filter((r) => r.length === 0)).toHaveLength(2);
    expect((await s.db.unsafe(`SELECT n FROM ${s.name}.runs ORDER BY n`)).map((r) => r.n)).toEqual([1, 2]);
  });

  test("migrate() waits while another session holds the lock", async () => {
    const s = await scratch();
    const dir = await migrationsDir({ "001_a.sql": `CREATE TABLE a (x int);` });
    const holder = lockHolder(s.url);
    await holder`SELECT pg_advisory_lock(${TEST_LOCK})`;
    let settled = false;
    const run = migrate(s.url, { quiet: true, dir, lockKey: TEST_LOCK }).finally(() => (settled = true));
    await Bun.sleep(400);
    expect(settled).toBe(false);
    expect(await tableExists(s, "schema_migrations")).toBe(false);
    await holder`SELECT pg_advisory_unlock(${TEST_LOCK})`;
    expect(await run).toEqual(["001_a"]);
  });

  test("by default it takes the shared LOCK_KEY (held here for a fraction of a second only)", async () => {
    const s = await scratch();
    const dir = await migrationsDir({});
    const holder = lockHolder(s.url);
    await holder`SELECT pg_advisory_lock(${LOCK_KEY})`;
    let settled = false;
    const run = migrate(s.url, { quiet: true, dir }).finally(() => (settled = true));
    try {
      await Bun.sleep(250);
      expect(settled).toBe(false);
    } finally {
      await holder`SELECT pg_advisory_unlock(${LOCK_KEY})`;
    }
    expect(await run).toEqual([]);
    expect(await tableExists(s, "schema_migrations")).toBe(true);
  });
});
