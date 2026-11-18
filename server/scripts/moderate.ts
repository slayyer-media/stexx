/**
 * Moderator CLI. Usage: `bun scripts/moderate.ts help` (or `bun run moderate -- help`).
 * Runs against DATABASE_URL with the normal server config; in production see docs/security.md for the exact
 * command (service user + /etc/stexx/stexx.env). Implementation: src/moderation/cli.ts.
 */
import { sql } from "../src/db/sql.ts";
import { runModerationCli } from "../src/moderation/cli.ts";

let code = 1;
try {
  code = await runModerationCli(process.argv.slice(2));
} finally {
  await sql.end({ timeout: 5 });
}
process.exit(code);
