/**
 * Staff console process: `bun run admin` (src/admin/app.ts). Separate from the API: its own systemd unit, its own port
 * (ADMIN_HOST:ADMIN_PORT, default 127.0.0.1:8788), no background jobs, no websocket. Moderation actions it takes reach
 * the API process the same way the CLI's do (shared Postgres, pg_notify).
 */
import { config, isLoopbackHost } from "../config.ts";
import { sql } from "../db/sql.ts";
import { logInfo } from "../lib/logger.ts";
import { createAdminApp } from "./app.ts";

if (config.admin.error) {
  // config.ts keeps console-only mistakes from stopping the API and stexx-mod; the console itself refuses here.
  console.error(`Refusing to start the staff console: ${config.admin.error}`);
  process.exit(1);
}
if (!config.admin.configured) {
  console.error("Refusing to start the staff console: set ADMIN_ORIGIN (and ADMIN_RP_ID if it differs) first.");
  process.exit(1);
}
if (config.isProduction && !isLoopbackHost(config.admin.host)) {
  // config.ts already refuses this; checked again where it matters.
  console.error("Refusing to start the staff console: ADMIN_HOST must be loopback in production.");
  process.exit(1);
}

const { app } = await createAdminApp();
const server = Bun.serve({
  hostname: config.admin.host,
  port: config.admin.port,
  fetch: app.fetch,
  maxRequestBodySize: 128 * 1024,
});

logInfo("admin_listening", {
  host: config.admin.host,
  port: server.port ?? config.admin.port,
  env: config.env,
  rpId: config.admin.rpId,
  devAuth: config.admin.devAuth,
});

let stopping = false;
async function stop(signal: string) {
  if (stopping) return;
  stopping = true;
  logInfo("admin_stopping", { signal });
  const hard = setTimeout(() => process.exit(1), 10_000);
  hard.unref?.();
  await server.stop();
  await sql.end({ timeout: 5 }).catch(() => {});
  process.exit(0);
}
process.on("SIGINT", () => void stop("SIGINT"));
process.on("SIGTERM", () => void stop("SIGTERM"));
