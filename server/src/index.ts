import { createApp } from "./app.ts";
import { config } from "./config.ts";
import { sql } from "./db/sql.ts";
import { startJobs } from "./jobs/index.ts";
import { logInfo } from "./lib/logger.ts";
import { closeAllConnections } from "./lib/realtime.ts";
import { createShutdown } from "./lib/shutdown.ts";
import { verifierName } from "./lib/e2e/crypto.ts";
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
  e2e: config.e2e.mode,
  // libsignal, or the built-in fallback if the native module can't load on this host (docs/security.md).
  e2eVerifier: config.e2e.mode === "off" ? "unused" : await verifierName(),
});
// Load the NSFW model now (logs photo_checks.model_loaded or .model_missing) instead of on the first upload.
void photoClassifier();
if (config.isProduction && config.antiSpam.attestation.mode === "off") {
  // Expected only until the Apple keys are set up (docs/security.md): sign-ups are not device-checked.
  logInfo("attestation_disabled", { reason: "APPLE_TEAM_ID unset or ATTESTATION_MODE=off" });
}

// Graceful stop (lib/shutdown.ts): stop listening, close websockets with 1012, await the jobs, close lingering
// requests after a short grace, close the pool, and exit before systemd's TimeoutStopSec=20 SIGKILL.
const shutdown = createShutdown({
  server,
  stopJobs,
  closeSockets: () => closeAllConnections(1012, "restarting"),
  endDb: () => sql.end({ timeout: 5 }),
  exit: (code) => process.exit(code),
});
process.on("SIGINT", () => void shutdown("SIGINT"));
process.on("SIGTERM", () => void shutdown("SIGTERM"));
