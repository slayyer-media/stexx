import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { MIGRATIONS_DIR } from "../src/db/migrate.ts";
import { lintMigrations, maskSql, nonAdditiveFindings, type LintInput } from "../scripts/lint-migrations.ts";

function input(files: Record<string, string>, base: Record<string, string> | null, extra: Partial<LintInput> = {}): LintInput {
  return {
    names: Object.keys(files),
    read: (n) => files[n]!,
    base: base && { names: Object.keys(base), read: (n) => base[n]! },
    ...extra,
  };
}
const messages = (fs: { file: string; message: string }[]) => fs.map((f) => `${f.file}: ${f.message}`);
const BASE = { "001_init.sql": "CREATE TABLE users (id text);", "107_x.sql": "SELECT 1;", "109_y.sql": "SELECT 1;" };

describe("lint-migrations: errors", () => {
  test("the repository's migrations pass", () => {
    const names = readdirSync(MIGRATIONS_DIR);
    const read = (n: string) => readFileSync(join(MIGRATIONS_DIR, n), "utf8");
    // Warnings on old files are allowed (they are advice for new ones), errors are not.
    expect(lintMigrations({ names, read, base: { names, read }, all: true }).errors).toEqual([]);
  });

  test("a name the runner would skip fails; dotfiles are ignored like the runner does", () => {
    const { errors } = lintMigrations(input({ ...BASE, "110_ok.sql": "", "12_short.sql": "", "113_x.SQL": "", "README.md": "", ".DS_Store": "" }, BASE));
    expect(errors.map((e) => e.file)).toEqual(["113_x.SQL", "12_short.sql", "README.md"]);
    expect(errors[0]!.message).toContain("the runner would silently skip it");
  });

  test("a directory fails", () => {
    const { errors } = lintMigrations(input({ ...BASE, "110_dir.sql": "" }, BASE, { directories: new Set(["110_dir.sql"]) }));
    expect(messages(errors)).toEqual([expect.stringContaining("110_dir.sql: a directory in migrations/")]);
  });

  test("duplicate numbers fail, naming both files", () => {
    const { errors } = lintMigrations(input({ ...BASE, "110_a.sql": "", "110_b.sql": "" }, BASE));
    expect(messages(errors)).toEqual([
      "110_a.sql: duplicate migration number 110: 110_a.sql, 110_b.sql",
      "110_b.sql: duplicate migration number 110: 110_a.sql, 110_b.sql",
    ]);
  });

  test("a new file numbered below (or at) the highest on the base fails; gaps are fine", () => {
    expect(lintMigrations(input({ ...BASE, "108_late.sql": "" }, BASE)).errors).toEqual([
      expect.objectContaining({ file: "108_late.sql", message: expect.stringContaining("not above the highest on the base (109_y.sql)") }),
    ]);
    // Branch behind main: main has 112, the branch adds its own 112 and lacks main's.
    const main = { ...BASE, "112_main.sql": "SELECT 1;" };
    const { errors, warnings } = lintMigrations(input({ ...BASE, "112_mine.sql": "" }, main));
    expect(messages(errors)).toEqual([expect.stringContaining("112_mine.sql: new migration number 112 is not above the highest on the base (112_main.sql)")]);
    expect(messages(warnings)).toEqual([expect.stringContaining("112_main.sql: exists on the base but not here")]);
    // 110 and 115 after 109: fine.
    expect(lintMigrations(input({ ...BASE, "110_a.sql": "", "115_b.sql": "" }, BASE)).errors).toEqual([]);
  });

  test("without a base only names and duplicates are checked", () => {
    expect(lintMigrations(input({ ...BASE, "002_old.sql": "DROP TABLE users;" }, null))).toEqual({ errors: [], warnings: [] });
  });
});

describe("lint-migrations: warnings", () => {
  test("editing a migration that exists on the base warns", () => {
    const { errors, warnings } = lintMigrations(input({ ...BASE, "107_x.sql": "SELECT 2;" }, BASE));
    expect(errors).toEqual([]);
    expect(messages(warnings)).toEqual([expect.stringContaining("107_x.sql: edits a migration that exists on the base")]);
  });

  test("non-additive statements in new files warn (with line numbers); old files are not rescanned", () => {
    const sql = [
      "-- DROP TABLE in a comment is fine",
      "CREATE TABLE fine (id text, note text DEFAULT 'drop table x');",
      "DROP TABLE IF EXISTS old_things;",
      "ALTER TABLE users DROP COLUMN headline, ADD COLUMN bio text NOT NULL;",
      "ALTER TABLE users RENAME COLUMN about TO bio_text;",
      "ALTER TABLE photos ALTER COLUMN position TYPE int;",
      "ALTER TABLE photos ALTER COLUMN caption SET NOT NULL;",
      "ALTER TYPE mood ADD VALUE 'happy';",
      "ALTER INDEX photos_idx RENAME TO photos_owner_idx;",
      "TRUNCATE abuse_counters;",
    ].join("\n");
    const { errors, warnings } = lintMigrations(input({ ...BASE, "001_init.sql": BASE["001_init.sql"], "110_new.sql": sql }, BASE));
    expect(errors).toEqual([]);
    expect(warnings.map((w) => [w.line, w.message.split(":")[0]])).toEqual([
      [3, "DROP TABLE old_things"],
      [4, "drops column users.headline"],
      [4, "adds users.bio NOT NULL without a default"],
      [5, "ALTER TABLE users RENAME COLUMN about TO bio_text"],
      [6, "changes the type of photos.position"],
      [7, "photos.caption SET NOT NULL without a default"],
      [8, "ALTER TYPE"],
      [9, "ALTER INDEX photos_idx ... RENAME"],
      [10, "TRUNCATE abuse_counters"],
    ]);
    expect(warnings.every((w) => w.file === "110_new.sql")).toBe(true);
  });

  test("additive changes don't warn", () => {
    const sql = `
      CREATE TABLE IF NOT EXISTS notes (id text PRIMARY KEY, user_id text NOT NULL REFERENCES users(id) ON DELETE CASCADE);
      ALTER TABLE users ADD COLUMN mood text, ADD COLUMN score int NOT NULL DEFAULT 0, ADD CONSTRAINT score_ok CHECK (score >= 0);
      ALTER TABLE users ADD COLUMN flag boolean;
      ALTER TABLE users ALTER COLUMN flag SET DEFAULT false;
      UPDATE users SET flag = false WHERE flag IS NULL;
      ALTER TABLE users ALTER COLUMN flag SET NOT NULL;
      ALTER TABLE users ALTER COLUMN mood DROP NOT NULL, DROP CONSTRAINT IF EXISTS old_check;
      ALTER TABLE users ADD COLUMN slug text GENERATED ALWAYS AS (lower(id)) STORED NOT NULL;
      DROP INDEX IF EXISTS users_old_idx;
      DROP TRIGGER IF EXISTS t ON users;
      CREATE INDEX users_mood_idx ON users (mood);`;
    expect(nonAdditiveFindings("110_ok.sql", sql)).toEqual([]);
  });

  test("maskSql blanks comments and strings but keeps line structure", () => {
    const sql = "a -- DROP TABLE x\n/* RENAME\n */ 'it''s DROP' b";
    const masked = maskSql(sql);
    expect(masked).toHaveLength(sql.length);
    expect(masked.split("\n")).toHaveLength(3);
    expect(masked).not.toMatch(/DROP|RENAME/);
    expect(masked.replace(/\s+/g, " ").trim()).toBe("a b");
  });
});

describe("lint-migrations CLI", () => {
  // Compared with HEAD so the result doesn't depend on where origin/main is.
  test("passes on this checkout and prints a summary", () => {
    const r = Bun.spawnSync([process.execPath, "scripts/lint-migrations.ts", "--base", "HEAD"], {
      cwd: join(import.meta.dir, ".."),
      stdout: "pipe",
      stderr: "pipe",
      env: { ...process.env, GITHUB_ACTIONS: "" },
    });
    expect(r.stderr.toString()).toBe("");
    expect(r.exitCode).toBe(0);
    expect(r.stdout.toString()).toMatch(/lint-migrations: \d+ migrations, compared with HEAD: 0 error\(s\), 0 warning\(s\)/);
  });

  test("an unknown base ref is a usage error, not a pass", () => {
    const r = Bun.spawnSync([process.execPath, "scripts/lint-migrations.ts", "--base", "no-such-ref-for-lint-test"], {
      cwd: join(import.meta.dir, ".."),
      stdout: "pipe",
      stderr: "pipe",
    });
    expect(r.exitCode).toBe(2);
    expect(r.stderr.toString()).toContain("base ref no-such-ref-for-lint-test not found");
  });
});
