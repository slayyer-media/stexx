/**
 * Lints server/migrations/ (CI: .github/workflows/server.yml; locally: `bun scripts/lint-migrations.ts`).
 *
 *   bun scripts/lint-migrations.ts                 # compare with origin/main when it exists
 *   bun scripts/lint-migrations.ts --base <ref>    # compare with any git ref (CI passes the PR base)
 *   bun scripts/lint-migrations.ts --all           # also scan every existing file for non-additive statements
 *
 * Fails (exit 1) on:
 *   - a file the runner would skip (not NNN_name.sql, see MIGRATION_FILE_RE in src/db/migrate.ts),
 *   - two files with the same number,
 *   - a file new relative to the base whose number isn't above every number on the base. Gaps (108, 110) are fine.
 * Warns (exit 0) on, in new files only:
 *   - non-additive statements: DROP TABLE / VIEW / FUNCTION / TYPE / SCHEMA, dropping a column, RENAME, changing a
 *     column's type, ALTER TYPE, SET NOT NULL without a default, ADD COLUMN ... NOT NULL without a default.
 *     deploy.sh never reverts migrations on rollback, so the previous release must keep working on the new schema.
 *   - edits to, or deletion of, a migration that exists on the base (it has likely run already; edits never re-run).
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import { basename, join, relative } from "node:path";
import { MIGRATION_FILE_RE, MIGRATIONS_DIR } from "../src/db/migrate.ts";

export interface Finding {
  file: string;
  line?: number;
  message: string;
}

export interface LintInput {
  /** Entries of migrations/ in the working tree (dotfiles are ignored, like the runner does). */
  names: string[];
  read(name: string): string;
  /** The same directory on the base ref, or null when there is no base to compare with. */
  base: { names: string[]; read(name: string): string } | null;
  /** Scan every file for non-additive statements, not only new ones. */
  all?: boolean;
  /** Names that are directories, not files. */
  directories?: Set<string>;
}

const numberOf = (name: string) => Number(name.slice(0, 3));

export function lintMigrations(input: LintInput): { errors: Finding[]; warnings: Finding[] } {
  const errors: Finding[] = [];
  const warnings: Finding[] = [];
  const names = input.names.filter((n) => !n.startsWith(".")).sort();

  const valid: string[] = [];
  for (const name of names) {
    if (input.directories?.has(name)) errors.push({ file: name, message: "a directory in migrations/; the runner only reads NNN_name.sql files" });
    else if (!MIGRATION_FILE_RE.test(name)) errors.push({ file: name, message: "not NNN_name.sql (3 digits, underscore, letters/digits/_/-, lowercase .sql): the runner would silently skip it" });
    else valid.push(name);
  }

  const byNumber = new Map<number, string[]>();
  for (const name of valid) byNumber.set(numberOf(name), [...(byNumber.get(numberOf(name)) ?? []), name]);
  for (const [n, files] of byNumber) {
    if (files.length > 1) for (const f of files) errors.push({ file: f, message: `duplicate migration number ${String(n).padStart(3, "0")}: ${files.join(", ")}` });
  }

  const baseValid = (input.base?.names ?? []).filter((n) => MIGRATION_FILE_RE.test(n));
  const baseSet = new Set(baseValid);
  const baseMax = baseValid.length ? Math.max(...baseValid.map(numberOf)) : -1;
  const added = input.base ? valid.filter((n) => !baseSet.has(n)) : [];

  if (input.base) {
    for (const name of added) {
      if (numberOf(name) <= baseMax) {
        const top = baseValid.filter((n) => numberOf(n) === baseMax).join(", ");
        errors.push({
          file: name,
          message: `new migration number ${name.slice(0, 3)} is not above the highest on the base (${top}): databases that already ran ${top} would apply it out of order. Renumber it above ${String(baseMax).padStart(3, "0")}`,
        });
      }
    }
    const here = new Set(valid);
    for (const name of baseValid) {
      if (!here.has(name)) {
        warnings.push({ file: name, message: "exists on the base but not here: deleting a migration doesn't undo it on databases that ran it (rebase if the branch is just behind)" });
      } else if (input.base.read(name) !== input.read(name)) {
        warnings.push({ file: name, message: "edits a migration that exists on the base: databases that already ran it never see the edit. Add a new migration instead" });
      }
    }
  }

  for (const name of input.all ? valid : added) warnings.push(...nonAdditiveFindings(name, input.read(name)));
  return { errors, warnings };
}

/** Blanks comments and single-quoted strings (keeping newlines and offsets), so keywords inside them don't match. */
export function maskSql(sql: string): string {
  let out = "";
  let i = 0;
  const blank = (s: string) => s.replace(/[^\n]/g, " ");
  while (i < sql.length) {
    const rest = sql.slice(i);
    let m: RegExpMatchArray | null;
    if ((m = rest.match(/^--[^\n]*/)) || (m = rest.match(/^\/\*[\s\S]*?(\*\/|$)/)) || (m = rest.match(/^[EeUu]?'(?:[^']|'')*('|$)/))) {
      out += blank(m[0]);
      i += m[0].length;
    } else {
      out += sql[i];
      i += 1;
    }
  }
  return out;
}

/** Splits on top-level commas (not inside parentheses). */
function splitTopLevel(s: string): string[] {
  const parts: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < s.length; i++) {
    if (s[i] === "(") depth++;
    else if (s[i] === ")") depth--;
    else if (s[i] === "," && depth === 0) {
      parts.push(s.slice(start, i));
      start = i + 1;
    }
  }
  parts.push(s.slice(start));
  return parts.map((p) => p.trim());
}

const IDENT = String.raw`("[^"]+"|[\w$]+)`;
const unquote = (s: string) => s.replace(/^"|"$/g, "").toLowerCase();

/** Warnings for statements that the previous release may not survive (deploy.sh rollback contract). */
export function nonAdditiveFindings(file: string, sql: string): Finding[] {
  const masked = maskSql(sql);
  const findings: Finding[] = [];
  const hasDefaultFor = (name: string) => {
    const column = name.replace(/[$]/g, "\\$");
    return (
      new RegExp(String.raw`\bALTER\s+(COLUMN\s+)?"?${column}"?\s+SET\s+DEFAULT\b`, "i").test(masked) ||
      new RegExp(String.raw`\bADD\s+(COLUMN\s+)?(IF\s+NOT\s+EXISTS\s+)?"?${column}"?\s[^,;]*\bDEFAULT\b`, "i").test(masked)
    );
  };

  let offset = 0;
  for (const raw of masked.split(";")) {
    const lead = raw.length - raw.trimStart().length;
    const line = masked.slice(0, offset + lead).split("\n").length;
    offset += raw.length + 1;
    const stmt = raw.trim().replace(/\s+/g, " ");
    if (!stmt) continue;
    const warn = (message: string) => findings.push({ file, line, message });

    let m: RegExpMatchArray | null;
    if ((m = stmt.match(new RegExp(String.raw`^DROP (TABLE|VIEW|MATERIALIZED VIEW|FUNCTION|TYPE|DOMAIN|SCHEMA|SEQUENCE) (IF EXISTS )?${IDENT}`, "i")))) {
      warn(`DROP ${m[1]!.toUpperCase()} ${unquote(m[3]!)}: the previous release may still use it. Drop it in a later release, once no deployed code reads it`);
      continue;
    }
    if ((m = stmt.match(/^TRUNCATE (TABLE )?(.*)$/i))) {
      warn(`TRUNCATE ${m[2]}: deletes data that a rollback can't bring back`);
      continue;
    }
    if (/^ALTER TYPE\b/i.test(stmt)) {
      warn(`ALTER TYPE: check that the previous release still reads and writes the type (ADD VALUE is safe; renames and drops are not)`);
      if (/\bRENAME\b/i.test(stmt)) warn(`RENAME: the previous release still uses the old name`);
      continue;
    }
    const alterTable = stmt.match(new RegExp(String.raw`^ALTER TABLE (IF EXISTS )?(ONLY )?${IDENT} (.*)$`, "i"));
    if (alterTable) {
      const table = unquote(alterTable[3]!);
      for (const action of splitTopLevel(alterTable[4]!)) {
        if (/^RENAME\b/i.test(action)) {
          warn(`ALTER TABLE ${table} ${action}: the previous release still uses the old name. Add the new shape alongside and switch over in a later release`);
        } else if ((m = action.match(new RegExp(String.raw`^DROP (COLUMN )?(IF EXISTS )?${IDENT}`, "i"))) && !/^DROP (CONSTRAINT|IDENTITY)\b/i.test(action)) {
          warn(`drops column ${table}.${unquote(m[3]!)}: the previous release may still read or write it. Stop using it first, drop it a release later`);
        } else if ((m = action.match(new RegExp(String.raw`^ALTER (COLUMN )?${IDENT} (SET DATA )?TYPE\b`, "i")))) {
          warn(`changes the type of ${table}.${unquote(m[2]!)}: the previous release may write values the new type rejects (and the rewrite locks the table)`);
        } else if ((m = action.match(new RegExp(String.raw`^ALTER (COLUMN )?${IDENT} SET NOT NULL\b`, "i")))) {
          const column = unquote(m[2]!);
          if (!hasDefaultFor(column)) warn(`${table}.${column} SET NOT NULL without a default: inserts from the previous release that omit it will fail`);
        } else if ((m = action.match(new RegExp(String.raw`^ADD (COLUMN )?(IF NOT EXISTS )?${IDENT} (.*)$`, "i"))) && !/^ADD (CONSTRAINT|PRIMARY|UNIQUE|CHECK|FOREIGN|EXCLUDE)\b/i.test(action)) {
          const rest = m[4]!;
          if (/\bNOT NULL\b/i.test(rest) && !/\bDEFAULT\b/i.test(rest) && !/\bGENERATED\b/i.test(rest)) {
            warn(`adds ${table}.${unquote(m[3]!)} NOT NULL without a default: inserts from the previous release will fail (and so does the migration on a non-empty table)`);
          }
        }
      }
      continue;
    }
    if (/^ALTER\b/i.test(stmt) && /\bRENAME\b/i.test(stmt)) {
      warn(`${stmt.split(" ").slice(0, 3).join(" ")} ... RENAME: the previous release still uses the old name`);
    }
  }
  return findings;
}

// ---------------------------------------------------------------------------------------------------------------
// CLI

function git(args: string[], cwd: string): { ok: boolean; out: string } {
  const r = Bun.spawnSync(["git", ...args], { cwd, stdout: "pipe", stderr: "pipe" });
  return { ok: r.exitCode === 0, out: r.stdout.toString() };
}

function print(kind: "error" | "warning", f: Finding, dirInRepo: string) {
  const path = `${dirInRepo}/${f.file}`;
  if (process.env.GITHUB_ACTIONS === "true") {
    const loc = f.line ? `,line=${f.line}` : "";
    const msg = f.message.replace(/%/g, "%25").replace(/\r/g, "%0D").replace(/\n/g, "%0A");
    console.log(`::${kind} file=${path}${loc},title=migration lint::${msg}`);
  } else {
    console.log(`${kind}: ${path}${f.line ? `:${f.line}` : ""}: ${f.message}`);
  }
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const all = args.includes("--all");
  const baseIdx = args.indexOf("--base");
  const explicitBase = baseIdx >= 0 ? args[baseIdx + 1] : undefined;
  if (baseIdx >= 0 && !explicitBase) {
    console.error("usage: bun scripts/lint-migrations.ts [--base <git ref>] [--all]");
    process.exit(2);
  }

  const dir = MIGRATIONS_DIR;
  const top = git(["rev-parse", "--show-toplevel"], dir);
  const dirInRepo = top.ok ? relative(top.out.trim(), dir) : "server/migrations";
  const entries = readdirSync(dir);
  const directories = new Set(entries.filter((n) => statSync(join(dir, n)).isDirectory()));

  let baseRef = explicitBase;
  if (!baseRef && git(["rev-parse", "--verify", "--quiet", "origin/main^{commit}"], dir).ok) baseRef = "origin/main";
  let base: LintInput["base"] = null;
  if (baseRef) {
    if (!git(["rev-parse", "--verify", "--quiet", `${baseRef}^{commit}`], dir).ok) {
      console.error(`lint-migrations: base ref ${baseRef} not found (fetch it first)`);
      process.exit(2);
    }
    const listing = git(["ls-tree", "--name-only", baseRef, `${dirInRepo}/`], top.out.trim());
    base = {
      names: listing.out.split("\n").filter(Boolean).map((p) => basename(p)),
      read: (name) => git(["show", `${baseRef}:${dirInRepo}/${name}`], top.out.trim()).out,
    };
  }

  const { errors, warnings } = lintMigrations({
    names: entries,
    read: (name) => readFileSync(join(dir, name), "utf8"),
    base,
    all,
    directories,
  });
  for (const f of errors) print("error", f, dirInRepo);
  for (const f of warnings) print("warning", f, dirInRepo);
  const valid = entries.filter((n) => MIGRATION_FILE_RE.test(n)).length;
  console.log(
    `lint-migrations: ${valid} migrations, ${base ? `compared with ${baseRef}` : "no base ref (new-file checks skipped)"}: ` +
      `${errors.length} error(s), ${warnings.length} warning(s)`,
  );
  process.exit(errors.length ? 1 : 0);
}
