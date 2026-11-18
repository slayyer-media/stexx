import { readdir } from "node:fs/promises";
import { join } from "node:path";
import postgres from "postgres";

const MIGRATIONS_DIR = join(import.meta.dir, "..", "..", "migrations");
/** Arbitrary constant; serializes concurrent migrators (parallel test runs, multiple boots). */
const LOCK_KEY = 0x57e77;

/**
 * Applies migrations/NNN_name.sql in order, each in its own transaction, tracked in schema_migrations.
 * Safe to call concurrently (advisory lock) and repeatedly (idempotent). Returns applied versions.
 */
export async function migrate(databaseUrl: string, opts: { quiet?: boolean } = {}): Promise<string[]> {
  const db = postgres(databaseUrl, { max: 1, onnotice: () => {} });
  const applied: string[] = [];
  try {
    await db`SELECT pg_advisory_lock(${LOCK_KEY})`;
    try {
      await db`CREATE TABLE IF NOT EXISTS schema_migrations (
        version text PRIMARY KEY,
        applied_at timestamptz NOT NULL DEFAULT now()
      )`;
      const done = new Set((await db<{ version: string }[]>`SELECT version FROM schema_migrations`).map((r) => r.version));
      const files = (await readdir(MIGRATIONS_DIR)).filter((f) => /^\d{3}_[\w-]+\.sql$/.test(f)).sort();
      for (const file of files) {
        const version = file.replace(/\.sql$/, "");
        if (done.has(version)) continue;
        const text = await Bun.file(join(MIGRATIONS_DIR, file)).text();
        await db.begin(async (tx) => {
          await tx.unsafe(text);
          await tx`INSERT INTO schema_migrations (version) VALUES (${version})`;
        });
        applied.push(version);
        if (!opts.quiet) console.log(`[migrate] applied ${version}`);
      }
    } finally {
      await db`SELECT pg_advisory_unlock(${LOCK_KEY})`;
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
