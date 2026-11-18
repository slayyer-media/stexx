/**
 * bun test preload (bunfig.toml). Runs before any test file imports src/*:
 * points the app at the stexx_test database and applies migrations (advisory-locked, idempotent).
 * Tests share this database with other concurrently running suites: NEVER truncate or wipe tables;
 * always create unique data (see test/helpers.ts).
 */
import { migrate } from "../src/db/migrate.ts";

// Per-test timeout: bunfig.toml has no key for it and setDefaultTimeout() in a preload only reaches the
// first test file, so `bun run test` passes --timeout and the few heavy tests set their own.

const testUrl = process.env.TEST_DATABASE_URL ?? "postgres://stexx:stexx@127.0.0.1:55433/stexx_test";
if (!/stexx_test/.test(testUrl)) throw new Error("TEST_DATABASE_URL must point at a *_test database");

process.env.NODE_ENV = "test";
process.env.DATABASE_URL = testUrl;
process.env.MEDIA_DIR = process.env.TEST_MEDIA_DIR ?? "./media/test";
process.env.MEDIA_BASE_URL = "http://127.0.0.1:8787/media";
process.env.STEXX_DEV_AUTH = "1";
// Side-effecting dev features off in tests; no default location (it would pile every user into one cell).
process.env.STEXX_DEV_WELCOME = "0";
process.env.STEXX_DEV_BOTS = "0";
delete process.env.STEXX_DEV_DEFAULT_LOCATION;
// StoreKit verification is off in tests (plus.test.ts injects its own verifier), whatever the dev .env
// says: a local .env set up for Xcode StoreKit testing must not change test outcomes.
delete process.env.APPLE_ROOT_CA_DIR;
delete process.env.APPLE_APP_APPLE_ID;
process.env.APPLE_ENVIRONMENT = "Sandbox";
process.env.EMAIL_PEPPER ??= "test-pepper-test-pepper-test-pepper-0000";

await migrate(testUrl, { quiet: true });
