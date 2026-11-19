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
  connection: {
    application_name: "stexx-api",
    // No JIT: this is a request/response API. Postgres JIT-compiles any statement whose estimated cost passes
    // jit_above_cost, and for the nearby search (an OR'd per-row EXISTS inflates the estimate) compiling cost
    // 30+ ms on top of a 20 ms query. Short queries never win it back.
    jit: "off",
  },
});

export type Sql = postgres.Sql | postgres.TransactionSql;
export type Fragment = postgres.PendingQuery<postgres.Row[]>;
