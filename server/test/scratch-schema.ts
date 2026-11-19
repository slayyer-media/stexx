/**
 * A private Postgres schema on the shared test database, for tests that must run DDL (migrate.test.ts,
 * schema-guards.test.ts). Unqualified names resolve to it alone (search_path), so nothing touches the shared
 * tables in `public`. drop() removes only this schema.
 */
import postgres from "postgres";
import { randomBytes } from "node:crypto";

export interface ScratchSchema {
  name: string;
  /** TEST database URL whose connections use only this schema (search_path startup parameter). */
  url: string;
  /** Admin connection (default search_path); qualify names with `name`. */
  db: postgres.Sql;
  drop(): Promise<void>;
}

export async function createScratchSchema(purpose: string): Promise<ScratchSchema> {
  const base = process.env.DATABASE_URL;
  if (!base || !/stexx_test/.test(base)) throw new Error("scratch schemas live only in the *_test database");
  const name = `scratch_${purpose.replace(/[^a-z0-9]/g, "")}_${randomBytes(5).toString("hex")}`;
  const db = postgres(base, { max: 2, onnotice: () => {} });
  await db.unsafe(`CREATE SCHEMA ${name}`);
  const u = new URL(base);
  u.searchParams.set("search_path", name);
  return {
    name,
    url: u.toString(),
    db,
    async drop() {
      try {
        await db.unsafe(`DROP SCHEMA IF EXISTS ${name} CASCADE`);
      } finally {
        await db.end({ timeout: 5 });
      }
    },
  };
}
