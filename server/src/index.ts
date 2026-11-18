import { createApp } from "./app.ts";
import { config } from "./config.ts";
import { sql } from "./db/sql.ts";
import { startJobs } from "./jobs/index.ts";
import { logInfo } from "./lib/logger.ts";
import { photoClassifier } from "./lib/photocheck/classifier.ts";
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
logInfo("listening", {
  host: config.host,
  port: server.port ?? config.port,
  env: config.env,
  devAuth: config.devAuth,
  attestation: config.antiSpam.attestation.mode,
  deviceCheck: config.antiSpam.deviceCheck !== null,
  photoClassifier: config.photoChecks.classifier,
  photoBlocklist: config.photoChecks.blocklist.length,
});
// Load the NSFW model now (logs photo_checks.model_loaded or .model_missing) instead of on the first upload.
void photoClassifier();
if (config.isProduction && config.antiSpam.attestation.mode === "off") {
  // Expected only until the Apple keys are set up (docs/security.md): sign-ups are not device-checked.
  logInfo("attestation_disabled", { reason: "APPLE_TEAM_ID unset or ATTESTATION_MODE=off" });
}

async function shutdown() {
  stopJobs();
  await server.stop();
  await sql.end({ timeout: 5 });
  process.exit(0);
}
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
