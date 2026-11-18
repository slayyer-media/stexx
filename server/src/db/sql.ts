import postgres from "postgres";
import { config } from "../config.ts";

/**
 * Shared postgres.js client. Rows come back with snake_case column names as in the schema.
 * timestamptz → Date, bigint → string, text[] → string[], bytea → Buffer.
 * Use `sql.begin(async (tx) => { ... })` for transactions; helpers that accept `db?: Sql`
 * can be passed `tx`.
 */
export const sql = postgres(config.databaseUrl, {
  max: config.databasePoolMax,
  idle_timeout: 20,
  connect_timeout: 10,
  onnotice: () => {},
  transform: { undefined: null },
  connection: { application_name: "stexx-api" },
});

export type Sql = postgres.Sql | postgres.TransactionSql;
export type Fragment = postgres.PendingQuery<postgres.Row[]>;
