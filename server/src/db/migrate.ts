import { readdir } from "node:fs/promises";
import { join } from "node:path";
import postgres from "postgres";

export const MIGRATIONS_DIR = join(import.meta.dir, "..", "..", "migrations");
/** Arbitrary constant; serializes concurrent migrators (parallel test runs, multiple boots). */
export const LOCK_KEY = 0x57e77;
/** A migration file name. Anything else in migrations/ is skipped, with a warning (scripts/lint-migrations.ts fails CI on it). */
export const MIGRATION_FILE_RE = /^\d{3}_[\w-]+\.sql$/;

/** Splits a migrations/ listing into the files the runner applies, in order, and the ones it skips (dotfiles aside). */
export function planMigrations(names: string[]): { files: string[]; ignored: string[] } {
  const files = names.filter((f) => MIGRATION_FILE_RE.test(f)).sort();
  const ignored = names.filter((f) => !MIGRATION_FILE_RE.test(f) && !f.startsWith(".")).sort();
  return { files, ignored };
}

/**
 * Applies migrations/NNN_name.sql in order, each in its own transaction, tracked in schema_migrations.
 * Safe to call concurrently (advisory lock) and repeatedly (idempotent). Returns applied versions.
 * `dir` and `lockKey` exist for test/migrate.test.ts (scratch migrations and a private lock); callers leave them unset.
 */
export async function migrate(
  databaseUrl: string,
  opts: { quiet?: boolean; dir?: string; lockKey?: number } = {},
): Promise<string[]> {
  const dir = opts.dir ?? MIGRATIONS_DIR;
  const lockKey = opts.lockKey ?? LOCK_KEY;
  const db = postgres(databaseUrl, { max: 1, onnotice: () => {} });
  const applied: string[] = [];
  try {
    await db`SELECT pg_advisory_lock(${lockKey})`;
    try {
      await db`CREATE TABLE IF NOT EXISTS schema_migrations (
        version text PRIMARY KEY,
        applied_at timestamptz NOT NULL DEFAULT now()
      )`;
      const done = new Set((await db<{ version: string }[]>`SELECT version FROM schema_migrations`).map((r) => r.version));
      const { files, ignored } = planMigrations(await readdir(dir));
      for (const f of ignored) console.warn(`[migrate] skipping ${f}: not a migration name (NNN_name.sql)`);
      for (const file of files) {
        const version = file.replace(/\.sql$/, "");
        if (done.has(version)) continue;
        const text = await Bun.file(join(dir, file)).text();
        await db.begin(async (tx) => {
          await tx.unsafe(text);
          await tx`INSERT INTO schema_migrations (version) VALUES (${version})`;
        });
        applied.push(version);
        if (!opts.quiet) console.log(`[migrate] applied ${version}`);
      }
    } finally {
      await db`SELECT pg_advisory_unlock(${lockKey})`;
    }
  } finally {
    await db.end({ timeout: 5 });
  }
  return applied;
}

if (import.meta.main) {
  const useTest = process.argv.includes("--test");
  const url = useTest ? process.env.TEST_DATABASE_URL : process.env.DATABASE_URL;
  if (!url) {
    console.error(`[migrate] ${useTest ? "TEST_DATABASE_URL" : "DATABASE_URL"} is not set`);
    process.exit(1);
  }
  const applied = await migrate(url);
  console.log(`[migrate] ${useTest ? "test " : ""}database up to date (${applied.length} applied)`);
}
