/**
 * Production configuration: dev-only code must be unreachable, and the process must refuse to boot with
 * dev flags. Runs the app in a child process with NODE_ENV=production (config is parsed once per process).
 */
import { describe, expect, test } from "bun:test";
import { join } from "node:path";

const root = join(import.meta.dir, "..");

/** A valid production environment that never touches a real database. */
const prodEnv: Record<string, string> = {
  PATH: process.env.PATH ?? "",
  HOME: process.env.HOME ?? "",
  NODE_ENV: "production",
  DATABASE_URL: "postgres://stexx_app:not-a-real-password@127.0.0.1:1/stexx",
  EMAIL_PEPPER: "p".repeat(64),
  MEDIA_BASE_URL: "https://media.stexx.gay",
  APP_LINK_BASE: "https://stexx.gay",
  WEBAUTHN_RP_ID: "stexx.gay",
  WEBAUTHN_ORIGINS: "https://stexx.gay",
  MEDIA_DIR: "./media/test",
  PORT: "18799",
};

function run(args: string[], env: Record<string, string>) {
  // --no-env-file: keep the dev .env out of the child so only prodEnv applies.
  const proc = Bun.spawnSync([process.execPath, "--no-env-file", ...args], { cwd: root, env, stdout: "pipe", stderr: "pipe" });
  return { code: proc.exitCode, stdout: proc.stdout.toString(), stderr: proc.stderr.toString() };
}

describe("production config", () => {
  test("dev routes, dev media and the dev register shortcut are unreachable; src/dev is never loaded", () => {
    const r = run(["test/fixtures/prod-app.ts"], prodEnv);
    expect(r.code).toBe(0);
    const report = JSON.parse(r.stdout.trim().split("\n").pop()!);
    expect(report.isProduction).toBe(true);
    expect(report.devAuth).toBe(false);
    expect(report.devWelcome).toBe(false);
    expect(report.devBots).toBe(false);
    expect(report.devDefaultLocation).toBeNull();
    expect(report.devPlus.status).toBe(404);
    expect(report.devPlusGet.status).toBe(404);
    expect(report.media.status).toBe(404);
    expect(report.registerEmail).toEqual({ status: 400, json: { code: "use_email_link", message: expect.any(String) } });
    expect(report.registerPasskey).toEqual({ status: 400, json: { code: "use_passkey_flow", message: expect.any(String) } });
    expect(report.loadedDevModules).toEqual([]);
  });

  for (const flag of ["STEXX_DEV_AUTH", "STEXX_DEV_WELCOME", "STEXX_DEV_BOTS"]) {
    test(`boot fails with ${flag}=1 in production`, () => {
      const r = run(["src/index.ts"], { ...prodEnv, [flag]: "1" });
      expect(r.code).not.toBe(0);
      expect(r.stderr + r.stdout).toContain("Refusing to boot: dev flags set in production");
      expect(r.stdout).not.toContain('"listening"');
    });
  }

  test("boot fails with STEXX_DEV_DEFAULT_LOCATION in production", () => {
    const r = run(["src/index.ts"], { ...prodEnv, STEXX_DEV_DEFAULT_LOCATION: "37.7749,-122.4194" });
    expect(r.code).not.toBe(0);
    expect(r.stderr + r.stdout).toContain("Refusing to boot");
  });
});
