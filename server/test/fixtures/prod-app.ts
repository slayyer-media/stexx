/**
 * Spawned by test/production.test.ts with NODE_ENV=production. Builds the real app with the production
 * config and prints a JSON report of how dev-only surfaces respond. No database is contacted.
 */
import { createApp } from "../../src/app.ts";
import { config } from "../../src/config.ts";

const app = await createApp();
const call = async (method: string, path: string, body?: unknown) => {
  const res = await app.fetch(
    new Request(`http://127.0.0.1${path}`, {
      method,
      headers: body === undefined ? {} : { "Content-Type": "application/json" },
      body: body === undefined ? undefined : JSON.stringify(body),
    }),
  );
  const text = await res.text();
  let json: unknown = null;
  try {
    json = JSON.parse(text);
  } catch {}
  return { status: res.status, json };
};

const report = {
  isProduction: config.isProduction,
  devAuth: config.devAuth,
  devWelcome: config.devWelcome,
  devBots: config.devBots,
  devDefaultLocation: config.devDefaultLocation,
  devPlus: await call("POST", "/v1/dev/plus", { days: 30 }),
  devPlusGet: await call("GET", "/v1/dev/plus"),
  media: await call("GET", "/media/0123456789abcdef0123456789abcdef.jpg"),
  registerEmail: await call("POST", "/v1/auth/register", {
    displayName: "Prod Test",
    method: "email",
    email: "x@example.com",
    confirmedAdult: true,
  }),
  registerPasskey: await call("POST", "/v1/auth/register", { displayName: "Prod Test", method: "passkey", confirmedAdult: true }),
  // Which source modules were evaluated? (Bun exposes ESM modules in require.cache.)
  loadedDevModules: Object.keys(require.cache).filter((k) => /[\\/]src[\\/]dev[\\/]/.test(k)),
};
console.log(JSON.stringify(report));
process.exit(0);
