import { createApp } from "./app.ts";
import { config } from "./config.ts";
import { sql } from "./db/sql.ts";
import { startJobs } from "./jobs/index.ts";
import { logInfo } from "./lib/logger.ts";
import { websocket } from "./routes/ws.ts";

const app = await createApp();

const server = Bun.serve({
  hostname: config.host,
  port: config.port,
  fetch: app.fetch,
  websocket,
  // Photos are ≤ 10 MB; leave headroom for headers. Per-route limits are enforced in app.ts.
  maxRequestBodySize: 11 * 1024 * 1024,
});

const stopJobs = startJobs();
logInfo("listening", { host: config.host, port: server.port ?? config.port, env: config.env, devAuth: config.devAuth });

async function shutdown() {
  stopJobs();
  await server.stop();
  await sql.end({ timeout: 5 });
  process.exit(0);
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
