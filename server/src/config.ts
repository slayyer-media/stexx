import { readFileSync } from "node:fs";
import { z } from "zod";
import { parseBlocklist, type BlocklistEntry } from "./lib/photocheck/blocklist-format.ts";
import { DEFAULT_EXPLICIT_LABELS, NUDENET_LABELS } from "./lib/photocheck/labels.ts";

function readKeyFile(path: string): string {
  try {
    return readFileSync(path, "utf8");
  } catch {
    throw new ConfigError(`DEVICECHECK_PRIVATE_KEY_PATH: cannot read ${path}`);
  }
}

/** Placeholder pepper used only outside production. Production must set its own (and may not reuse this). */
export const DEV_EMAIL_PEPPER = "dev-only-email-pepper-do-not-use-in-production-0000";

const flag = z
  .enum(["0", "1", "true", "false", ""])
  .optional()
  .transform((v) => v === "1" || v === "true");

const latLon = z
  .string()
  .regex(/^-?\d+(\.\d+)?,\s*-?\d+(\.\d+)?$/, "expected 'lat,lon'")
  .transform((s) => {
    const [lat, lon] = s.split(",").map((p) => Number(p.trim())) as [number, number];
    return { latitude: lat, longitude: lon };
  })
  .refine((v) => Math.abs(v.latitude) <= 90 && Math.abs(v.longitude) <= 180, "lat/lon out of range");

const envSchema = z.object({
  NODE_ENV: z.enum(["development", "test", "production"]).default("development"),
  HOST: z.string().default("127.0.0.1"),
  PORT: z.coerce.number().int().min(1).max(65535).default(8787),
  DATABASE_URL: z.string().min(1, "DATABASE_URL is required"),
  DATABASE_POOL_MAX: z.coerce.number().int().min(1).max(100).default(10),

  MEDIA_DIR: z.string().default("./media"),
  MEDIA_BASE_URL: z.string().url().default("http://127.0.0.1:8787/media"),
  /** Uploads fail closed (503 storage_unavailable) below this share of free space on the media disk. Default 5 (0 in tests). */
  MEDIA_MIN_FREE_PERCENT: z.coerce.number().min(0).max(50).optional(),
  /** ... or below this many free megabytes. Default 500 (0 in tests). */
  MEDIA_MIN_FREE_MB: z.coerce.number().int().min(0).max(1_000_000).optional(),
  APP_LINK_BASE: z.string().url().default("https://stexx.gay"),

  EMAIL_PEPPER: z.string().optional(),
  SMTP_URL: z.string().optional(),
  MAIL_FROM: z.string().default("Stexx <no-reply@stexx.gay>"),

  WEBAUTHN_RP_ID: z.string().default("localhost"),
  WEBAUTHN_RP_NAME: z.string().default("Stexx"),
  WEBAUTHN_ORIGINS: z.string().default("http://localhost:8787"),

  APPLE_BUNDLE_ID: z.string().default("gay.stexx.app"),
  APPLE_APP_APPLE_ID: z.coerce.number().int().optional(),
  APPLE_ENVIRONMENT: z.enum(["Production", "Sandbox", "Xcode", "LocalTesting"]).default("Sandbox"),
  APPLE_ROOT_CA_DIR: z.string().optional(),
  APPLE_PLUS_PRODUCT_ID: z.string().default("gay.stexx.app.plus.monthly"),

  TRUST_PROXY: flag.default(true),

  // ---- Anti-spam (docs/security.md) ----
  /** off | dev | enforce. Default: dev outside production; in production enforce once APPLE_TEAM_ID is set. */
  ATTESTATION_MODE: z.enum(["off", "dev", "enforce"]).optional(),
  /** Apple Developer Team ID (10 chars). App Attest app ID = `${APPLE_TEAM_ID}.${APPLE_BUNDLE_ID}`. */
  APPLE_TEAM_ID: z
    .string()
    .regex(/^[A-Z0-9]{10}$/, "expected a 10-character Apple Team ID")
    .optional()
    .or(z.literal("").transform(() => undefined)),
  /** PEM of Apple's App Attestation Root CA (the repo ships it). */
  APP_ATTEST_ROOT_CA: z.string().optional(),
  /** Comma list of accepted App Attest environments. Default: production only in production, both elsewhere. */
  APP_ATTEST_ENVIRONMENTS: z.string().optional(),
  /** DeviceCheck server API key (Apple Developer > Keys, "DeviceCheck"). All three are needed to enable it. */
  DEVICECHECK_KEY_ID: z.string().optional(),
  DEVICECHECK_PRIVATE_KEY_PATH: z.string().optional(),
  DEVICECHECK_PRIVATE_KEY: z.string().optional(),
  DEVICECHECK_ENVIRONMENT: z.enum(["development", "production"]).optional(),
  MAX_ACCOUNTS_PER_DEVICE: z.coerce.number().int().min(1).max(20).default(1),
  TRUST_RAMP_ENABLED: flag.default(true),
  TRUST_RAMP_HOURS: z.coerce.number().min(0).max(24 * 30).default(24),
  TRUST_RAMP_FIRST_MESSAGES_PER_DAY: z.coerce.number().int().min(0).max(1000).default(10),
  TRUST_RAMP_DUPLICATE_RECIPIENTS: z.coerce.number().int().min(1).max(1000).default(3),
  TRUST_RAMP_GRADUATE_REPLIES: z.coerce.number().int().min(1).max(100).default(3),

  // Reports, auto-hide and moderation (src/lib/moderation.ts, docs/security.md).
  REPORT_AUTOHIDE_ENABLED: flag.default(true),
  REPORT_AUTOHIDE_THRESHOLD: z.coerce.number().int().min(1).max(100).default(3),
  REPORT_AUTOHIDE_WINDOW_DAYS: z.coerce.number().min(1).max(365).default(14),
  REPORT_UNDERAGE_TRUSTED_THRESHOLD: z.coerce.number().int().min(1).max(100).default(1),
  REPORT_UNDERAGE_ANY_THRESHOLD: z.coerce.number().int().min(1).max(100).default(2),
  /** Default: TRUST_RAMP_HOURS. */
  REPORT_REPORTER_MIN_AGE_HOURS: z.coerce.number().min(0).max(24 * 365).optional(),
  REPORT_EVIDENCE_RETENTION_DAYS: z.coerce.number().min(1).max(365).default(30),
  REPORT_EVIDENCE_MAX_DAYS: z.coerce.number().min(1).max(3650).default(180),
  /** Days a banned account is kept intact (appeal/review window) before the retention job purges it. Owner decision. */
  BANNED_RETENTION_DAYS: z.coerce.number().int().min(1).max(3650).default(30),

  // Spam heuristics on messages, shadow limits pending review (src/lib/abuse/spam.ts, docs/security.md section 8).
  SPAM_HEURISTICS_ENABLED: flag.default(true),
  /** Window for fan-out, first-contact rate, duplicates, links and handles. */
  SPAM_WINDOW_HOURS: z.coerce.number().min(1).max(24 * 7).default(24),
  SPAM_FANOUT_MIN: z.coerce.number().int().min(2).max(1000).default(20),
  SPAM_FANOUT_MAX_REPLY_RATE: z.coerce.number().min(0).max(1).default(0.1),
  SPAM_BURST_MINUTES: z.coerce.number().min(1).max(24 * 60).default(10),
  SPAM_BURST_FIRST_CONTACTS: z.coerce.number().int().min(2).max(1000).default(8),
  SPAM_FIRST_CONTACT_MIN: z.coerce.number().int().min(2).max(1000).default(10),
  SPAM_FIRST_CONTACT_RATIO: z.coerce.number().min(0.5).max(1).default(0.9),
  SPAM_BLOCKED_DAYS: z.coerce.number().min(1).max(90).default(7),
  SPAM_BLOCKED_HOURS: z.coerce.number().min(1).max(24 * 30).default(24),
  SPAM_BLOCKED_MIN: z.coerce.number().int().min(1).max(1000).default(3),
  SPAM_DUPLICATE_RECIPIENTS: z.coerce.number().int().min(2).max(1000).default(5),
  SPAM_DUPLICATE_SIMILARITY: z.coerce.number().min(0.3).max(1).default(0.6),
  SPAM_LINK_RECIPIENTS: z.coerce.number().int().min(1).max(1000).default(2),
  SPAM_HANDLE_RECIPIENTS: z.coerce.number().int().min(1).max(1000).default(1),
  SPAM_SCORE_NEW: z.coerce.number().int().min(1).max(100).default(3),
  SPAM_SCORE_ESTABLISHED: z.coerce.number().int().min(1).max(100).default(5),
  SPAM_ESTABLISHED_DAYS: z.coerce.number().min(0).max(365).default(14),
  SPAM_COOLDOWN_HOURS: z.coerce.number().min(1).max(24 * 90).default(72),
  SPAM_HELD_MAX_DAYS: z.coerce.number().min(1).max(365).default(30),
  SPAM_HASH_TTL_HOURS: z.coerce.number().min(1).max(24 * 30).default(48),
  SPAM_FLAG_RETENTION_DAYS: z.coerce.number().min(1).max(3650).default(180),
  // Moderator alerts (src/lib/moderator-alerts.ts, docs/security.md section 5). Off unless one channel is set.
  /** Address(es) for alert digests, comma-separated. Needs SMTP_URL. */
  MODERATOR_ALERT_EMAIL: z.string().optional(),
  /** Generic JSON POST target (e.g. a self-hosted ntfy topic or Matrix webhook bridge). */
  MODERATOR_ALERT_WEBHOOK_URL: z.string().optional(),
  /** At most one alert digest per channel per this many minutes. */
  MODERATOR_ALERT_INTERVAL_MINUTES: z.coerce.number().int().min(1).max(1440).default(15),
  /** Report reasons that are high priority (comma list). */
  MODERATOR_ALERT_REASONS: z.string().optional(),

  // ---- Photo checks (docs/security.md "Photo checks") ----
  /** auto: use the NSFW model if its file is present (default; "off" in tests) · off: never classify. */
  PHOTO_CLASSIFIER: z.enum(["auto", "off"]).optional(),
  /** NudeNet 320n ONNX file. Fetch it with scripts/fetch-photo-model.sh. */
  PHOTO_NSFW_MODEL: z.string().optional(),
  /** ONNX Runtime intra-op threads for one inference (inferences run one at a time). */
  PHOTO_NSFW_THREADS: z.coerce.number().int().min(1).max(16).default(1),
  /** A photo is explicit when any explicit label scores at least this. */
  PHOTO_NSFW_THRESHOLD: z.coerce.number().min(0.2).max(1).default(0.5),
  /** Comma list of NudeNet labels that count as explicit. */
  PHOTO_NSFW_LABELS: z.string().optional(),
  /** Hide photos the classifier hasn't checked yet from other people (fail closed). Default off (fail open). */
  PHOTO_HIDE_UNCHECKED: flag.default(false),
  /** Max pHash Hamming distance (of 64 bits) that counts as the same photo across accounts. -1 turns it off. */
  PHOTO_DUPLICATE_MAX_DISTANCE: z.coerce.number().int().min(-1).max(32).default(6),
  /** Optional file of known stock/scraped photo hashes: one 16-hex pHash per line, optional label after it. */
  PHOTO_HASH_BLOCKLIST: z.string().optional(),

  // End-to-end encrypted chat (src/lib/e2e/*, docs/security.md).
  /** off | optional | required. Default: off in production, optional elsewhere. */
  E2E_MODE: z.enum(["off", "optional", "required"]).optional(),
  /** Most one-time EC prekeys stored per device (and per upload). */
  E2E_MAX_PREKEYS: z.coerce.number().int().min(10).max(1000).default(100),
  /** Most one-time Kyber prekeys stored per device (and per upload). ~1.6 KB each, so kept small on one VPS. */
  E2E_MAX_PQ_PREKEYS: z.coerce.number().int().min(0).max(200).default(25),

  STEXX_DEV_AUTH: flag,
  STEXX_DEV_DEFAULT_LOCATION: z.string().optional(),
  STEXX_DEV_WELCOME: flag,
  STEXX_DEV_BOTS: flag,
});

export interface Config {
  env: "development" | "test" | "production";
  isProduction: boolean;
  isTest: boolean;
  host: string;
  port: number;
  databaseUrl: string;
  databasePoolMax: number;
  mediaDir: string;
  /** Free-space floor for media writes (lib/media.ts). Either one being crossed refuses the write. */
  mediaMinFree: { percent: number; mb: number };
  /** No trailing slash. Photo URLs are `${mediaBaseUrl}/${storageKey}`. */
  mediaBaseUrl: string;
  /** No trailing slash. Email link = `${appLinkBase}/auth/email?token=...`. */
  appLinkBase: string;
  emailPepper: string;
  smtpUrl: string | null;
  mailFrom: string;
  webauthn: { rpId: string; rpName: string; origins: string[] };
  apple: {
    bundleId: string;
    appAppleId: number | null;
    environment: "Production" | "Sandbox" | "Xcode" | "LocalTesting";
    rootCaDir: string | null;
    plusProductId: string;
    /** True when StoreKit verification can run; otherwise POST /subscriptions/apple → 503. */
    enabled: boolean;
    /**
     * `${APPLE_TEAM_ID}.${APPLE_BUNDLE_ID}`, or null when APPLE_TEAM_ID is unset. Names the app in the
     * apple-app-site-association file (passkeys); also the App Attest app ID.
     */
    appId: string | null;
  };
  trustProxy: boolean;
  antiSpam: AntiSpamConfig;
  moderation: ModerationConfig;
  spam: SpamConfig;
  photoChecks: PhotoChecksConfig;
  moderatorAlerts: ModeratorAlertsConfig;
  e2e: E2eConfig;
  /** Dev-only auth shortcuts (/auth/register returns a Session, /v1/dev/* mounted). Never true in production. */
  devAuth: boolean;
  /** Dev-only: new users get this cell so the grid isn't empty. null when unset or in production. */
  devDefaultLocation: { latitude: number; longitude: number } | null;
  devWelcome: boolean;
  devBots: boolean;
}

export interface PhotoChecksConfig {
  classifier: "auto" | "off";
  modelPath: string;
  threads: number;
  threshold: number;
  explicitLabels: string[];
  hideUnchecked: boolean;
  /** -1 = duplicate detection off. */
  duplicateMaxDistance: number;
  blocklistPath: string | null;
  /** Parsed at load, so a malformed file fails the boot (and deploy's boot check). */
  blocklist: BlocklistEntry[];
}

/** Report reasons (same list as validation.ts reportReasonSchema; a test keeps them in sync). */
export const REPORT_REASONS = [
  "underage",
  "harassment",
  "spam",
  "fakeProfile",
  "threatsOrViolence",
  "illegalContent",
  "other",
] as const;
export const DEFAULT_ALERT_REASONS = ["underage", "threatsOrViolence", "illegalContent"] as const;

export interface ModeratorAlertsConfig {
  /** Recipients of the email digest (empty = email channel off). */
  emails: string[];
  /** JSON POST target, or null (webhook channel off). Never logged: it may carry a secret. */
  webhookUrl: string | null;
  intervalMinutes: number;
  /** Open reports with one of these reasons are alerted. */
  reasons: string[];
}

export type AttestationMode = "off" | "dev" | "enforce";

export interface AntiSpamConfig {
  attestation: {
    mode: AttestationMode;
    /** `${teamId}.${bundleId}`, or null when APPLE_TEAM_ID is unset (real attestations are then refused). */
    appId: string | null;
    rootCaPath: string;
    environments: ("development" | "production")[];
  };
  /** null unless DEVICECHECK_KEY_ID, APPLE_TEAM_ID and a private key are all set. */
  deviceCheck: {
    keyId: string;
    teamId: string;
    privateKeyPem: string;
    environment: "development" | "production";
  } | null;
  maxAccountsPerDevice: number;
  /** Raw RATE_LIMIT_* env values (parsed by lib/abuse/limits.ts). */
  rateLimitOverrides: Record<string, string>;
  trustRamp: {
    enabled: boolean;
    hours: number;
    firstMessagesPerDay: number;
    duplicateRecipients: number;
    graduateReplies: number;
  };
}

/** Spam heuristics on messages (lib/abuse/spam.ts). Every rule and threshold is documented in docs/security.md. */
export interface SpamConfig {
  enabled: boolean;
  windowHours: number;
  fanOutMin: number;
  fanOutMaxReplyRate: number;
  burstMinutes: number;
  burstFirstContacts: number;
  firstContactMin: number;
  firstContactRatio: number;
  blockedDays: number;
  blockedHours: number;
  blockedMin: number;
  duplicateRecipients: number;
  duplicateSimilarity: number;
  linkRecipients: number;
  handleRecipients: number;
  scoreNew: number;
  scoreEstablished: number;
  establishedDays: number;
  cooldownHours: number;
  heldMaxDays: number;
  hashTtlHours: number;
  flagRetentionDays: number;
}

export type E2eMode = "off" | "optional" | "required";

export interface E2eConfig {
  /**
   * off: key routes 404 `e2e_disabled`, envelopes refused, plaintext chat as before.
   * optional: key routes live; a message may carry plaintext `text` or an encrypted `envelope` (migration period).
   * required: text must travel in an envelope (plaintext `text` → 400 `encryption_required`).
   */
  mode: E2eMode;
  maxPreKeys: number;
  maxPqPreKeys: number;
}

export interface ModerationConfig {
  autoHide: {
    enabled: boolean;
    /** Independent trusted reporters (any reason) within the window that hide an account. */
    threshold: number;
    windowDays: number;
    /** Independent trusted reporters of `underage` that hide an account. */
    underageTrusted: number;
    /** Distinct reporters of `underage` (not hidden/banned, different device and connection; any account age). */
    underageAny: number;
    /** A reporter counts as trusted from this account age (and when the trust ramp doesn't restrict them). */
    reporterMinAgeHours: number;
  };
  /** Evidence (and report details, IP hash) is deleted this many days after the report is closed. */
  evidenceRetentionDays: number;
  /** Hard cap for evidence on reports that stay open. */
  evidenceMaxDays: number;
  /** A banned account is kept intact this many days after the ban (appeal window), then purged like DELETE /me. */
  bannedRetentionDays: number;
}

export const DEFAULT_APP_ATTEST_ROOT_CA = new URL("../certs/app-attest/Apple_App_Attestation_Root_CA.pem", import.meta.url)
  .pathname;

/** Default model location: server/models/ (git-ignored). Production points PHOTO_NSFW_MODEL at /srv/stexx/models. */
export const DEFAULT_NSFW_MODEL_PATH = new URL("../models/nudenet-320n.onnx", import.meta.url).pathname;

export class ConfigError extends Error {
  override name = "ConfigError";
}

/** Parse and validate an environment. Throws ConfigError (never boots half-configured). */
export function loadConfig(env: Record<string, string | undefined>): Config {
  const parsed = envSchema.safeParse(env);
  if (!parsed.success) {
    const issues = parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ");
    throw new ConfigError(`Invalid environment: ${issues}`);
  }
  const e = parsed.data;
  const isProduction = e.NODE_ENV === "production";

  if (isProduction) {
    const devFlags = ["STEXX_DEV_AUTH", "STEXX_DEV_WELCOME", "STEXX_DEV_BOTS", "STEXX_DEV_DEFAULT_LOCATION"].filter(
      (k) => {
        const v = env[k];
        return v !== undefined && v !== "" && v !== "0" && v !== "false";
      },
    );
    if (devFlags.length > 0) {
      throw new ConfigError(`Refusing to boot: dev flags set in production (${devFlags.join(", ")})`);
    }
    if (!e.EMAIL_PEPPER || e.EMAIL_PEPPER.length < 32 || e.EMAIL_PEPPER === DEV_EMAIL_PEPPER) {
      throw new ConfigError("EMAIL_PEPPER must be set to a unique secret of at least 32 chars in production");
    }
    if (!e.MEDIA_BASE_URL.startsWith("https://")) {
      throw new ConfigError("MEDIA_BASE_URL must be https in production");
    }
    if (!e.APP_LINK_BASE.startsWith("https://")) {
      throw new ConfigError("APP_LINK_BASE must be https in production");
    }
    if (e.WEBAUTHN_RP_ID === "localhost") {
      throw new ConfigError("WEBAUTHN_RP_ID must be the production domain in production");
    }
    if (/stexx:stexx@/.test(e.DATABASE_URL)) {
      throw new ConfigError("DATABASE_URL uses the dev password in production");
    }
    // Xcode/LocalTesting make the Apple library skip JWS signature + chain verification entirely (anyone could
    // forge Stexx+), and Sandbox would accept free TestFlight/sandbox purchases while rejecting real ones.
    if (e.APPLE_ROOT_CA_DIR) {
      if (env.APPLE_ENVIRONMENT !== "Production") {
        throw new ConfigError("APPLE_ENVIRONMENT must be set to Production in production when APPLE_ROOT_CA_DIR is set");
      }
      if (e.APPLE_APP_APPLE_ID === undefined) {
        throw new ConfigError("APPLE_APP_APPLE_ID is required in production when APPLE_ROOT_CA_DIR is set");
      }
    }
  }

  // ---- Anti-spam ----
  const appId = e.APPLE_TEAM_ID ? `${e.APPLE_TEAM_ID}.${e.APPLE_BUNDLE_ID}` : null;
  const mode: AttestationMode = e.ATTESTATION_MODE ?? (isProduction ? (appId ? "enforce" : "off") : e.NODE_ENV === "test" ? "off" : "dev");
  if (isProduction && mode === "dev") {
    throw new ConfigError("ATTESTATION_MODE=dev is not allowed in production (it accepts the simulator bypass)");
  }
  if (mode === "enforce" && !appId) {
    throw new ConfigError("ATTESTATION_MODE=enforce needs APPLE_TEAM_ID (the App Attest app ID is TEAMID.bundleId)");
  }
  const environments = (e.APP_ATTEST_ENVIRONMENTS ?? (isProduction ? "production" : "development,production"))
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  for (const env of environments) {
    if (env !== "development" && env !== "production") throw new ConfigError(`APP_ATTEST_ENVIRONMENTS: unknown ${env}`);
  }
  let deviceCheck: AntiSpamConfig["deviceCheck"] = null;
  const dcKey =
    e.DEVICECHECK_PRIVATE_KEY?.replace(/\\n/g, "\n") ||
    (e.DEVICECHECK_PRIVATE_KEY_PATH ? readKeyFile(e.DEVICECHECK_PRIVATE_KEY_PATH) : undefined);
  if (e.DEVICECHECK_KEY_ID && e.APPLE_TEAM_ID && dcKey) {
    deviceCheck = {
      keyId: e.DEVICECHECK_KEY_ID,
      teamId: e.APPLE_TEAM_ID,
      privateKeyPem: dcKey,
      environment: e.DEVICECHECK_ENVIRONMENT ?? (isProduction ? "production" : "development"),
    };
  }
  const rateLimitOverrides: Record<string, string> = {};
  for (const [k, v] of Object.entries(env)) {
    if (k.startsWith("RATE_LIMIT_") && v) rateLimitOverrides[k] = v;
  }

  // ---- Photo checks ----
  const explicitLabels = (e.PHOTO_NSFW_LABELS ?? DEFAULT_EXPLICIT_LABELS.join(","))
    .split(",")
    .map((s) => s.trim().toUpperCase())
    .filter(Boolean);
  for (const label of explicitLabels) {
    if (!(NUDENET_LABELS as readonly string[]).includes(label)) {
      throw new ConfigError(`PHOTO_NSFW_LABELS: unknown label ${label}`);
    }
  }
  if (explicitLabels.length === 0) throw new ConfigError("PHOTO_NSFW_LABELS: list at least one label");
  let blocklist: BlocklistEntry[] = [];
  if (e.PHOTO_HASH_BLOCKLIST) {
    let text: string;
    try {
      text = readFileSync(e.PHOTO_HASH_BLOCKLIST, "utf8");
    } catch {
      throw new ConfigError(`PHOTO_HASH_BLOCKLIST: cannot read ${e.PHOTO_HASH_BLOCKLIST}`);
    }
    try {
      blocklist = parseBlocklist(text);
    } catch (err) {
      throw new ConfigError(`PHOTO_HASH_BLOCKLIST: ${(err as Error).message}`);
    }
  }

  // ---- Moderator alerts ----
  const alertEmails = (e.MODERATOR_ALERT_EMAIL ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  for (const addr of alertEmails) {
    if (!/^[^\s@,<>]+@[^\s@,<>]+\.[^\s@,<>]+$/.test(addr)) throw new ConfigError("MODERATOR_ALERT_EMAIL: not an email address");
  }
  if (alertEmails.length > 5) throw new ConfigError("MODERATOR_ALERT_EMAIL: at most 5 addresses");
  if (alertEmails.length > 0 && !e.SMTP_URL) throw new ConfigError("MODERATOR_ALERT_EMAIL needs SMTP_URL");
  let webhookUrl: string | null = null;
  if (e.MODERATOR_ALERT_WEBHOOK_URL) {
    let u: URL;
    try {
      u = new URL(e.MODERATOR_ALERT_WEBHOOK_URL);
    } catch {
      throw new ConfigError("MODERATOR_ALERT_WEBHOOK_URL: not a URL");
    }
    if (u.protocol !== "https:" && u.protocol !== "http:") throw new ConfigError("MODERATOR_ALERT_WEBHOOK_URL: http(s) only");
    const loopback = ["127.0.0.1", "localhost", "[::1]"].includes(u.hostname);
    if (isProduction && u.protocol !== "https:" && !loopback) {
      throw new ConfigError("MODERATOR_ALERT_WEBHOOK_URL must be https in production (or a loopback address)");
    }
    webhookUrl = u.toString();
  }
  const alertReasons = (e.MODERATOR_ALERT_REASONS ?? DEFAULT_ALERT_REASONS.join(","))
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  for (const r of alertReasons) {
    if (!(REPORT_REASONS as readonly string[]).includes(r)) throw new ConfigError(`MODERATOR_ALERT_REASONS: unknown reason ${r}`);
  }

  let devDefaultLocation: Config["devDefaultLocation"] = null;
  if (!isProduction && e.STEXX_DEV_DEFAULT_LOCATION) {
    const loc = latLon.safeParse(e.STEXX_DEV_DEFAULT_LOCATION);
    if (!loc.success) throw new ConfigError(`STEXX_DEV_DEFAULT_LOCATION: ${loc.error.issues[0]?.message}`);
    devDefaultLocation = loc.data;
  }

  const appleEnabled =
    !!e.APPLE_ROOT_CA_DIR && (e.APPLE_ENVIRONMENT !== "Production" || e.APPLE_APP_APPLE_ID !== undefined);

  return {
    env: e.NODE_ENV,
    isProduction,
    isTest: e.NODE_ENV === "test",
    host: e.HOST,
    port: e.PORT,
    databaseUrl: e.DATABASE_URL,
    databasePoolMax: e.DATABASE_POOL_MAX,
    mediaDir: e.MEDIA_DIR,
    mediaMinFree: {
      percent: e.MEDIA_MIN_FREE_PERCENT ?? (e.NODE_ENV === "test" ? 0 : 5),
      mb: e.MEDIA_MIN_FREE_MB ?? (e.NODE_ENV === "test" ? 0 : 500),
    },
    mediaBaseUrl: e.MEDIA_BASE_URL.replace(/\/+$/, ""),
    appLinkBase: e.APP_LINK_BASE.replace(/\/+$/, ""),
    emailPepper: e.EMAIL_PEPPER || DEV_EMAIL_PEPPER,
    smtpUrl: e.SMTP_URL || null,
    mailFrom: e.MAIL_FROM,
    webauthn: {
      rpId: e.WEBAUTHN_RP_ID,
      rpName: e.WEBAUTHN_RP_NAME,
      origins: e.WEBAUTHN_ORIGINS.split(",").map((s) => s.trim()).filter(Boolean),
    },
    apple: {
      bundleId: e.APPLE_BUNDLE_ID,
      appAppleId: e.APPLE_APP_APPLE_ID ?? null,
      environment: e.APPLE_ENVIRONMENT,
      rootCaDir: e.APPLE_ROOT_CA_DIR ?? null,
      plusProductId: e.APPLE_PLUS_PRODUCT_ID,
      enabled: appleEnabled,
      appId,
    },
    trustProxy: e.TRUST_PROXY,
    antiSpam: {
      attestation: {
        mode,
        appId,
        rootCaPath: e.APP_ATTEST_ROOT_CA ?? DEFAULT_APP_ATTEST_ROOT_CA,
        environments: environments as ("development" | "production")[],
      },
      deviceCheck,
      maxAccountsPerDevice: e.MAX_ACCOUNTS_PER_DEVICE,
      rateLimitOverrides,
      trustRamp: {
        enabled: e.TRUST_RAMP_ENABLED,
        hours: e.TRUST_RAMP_HOURS,
        firstMessagesPerDay: e.TRUST_RAMP_FIRST_MESSAGES_PER_DAY,
        duplicateRecipients: e.TRUST_RAMP_DUPLICATE_RECIPIENTS,
        graduateReplies: e.TRUST_RAMP_GRADUATE_REPLIES,
      },
    },
    moderation: {
      autoHide: {
        enabled: e.REPORT_AUTOHIDE_ENABLED,
        threshold: e.REPORT_AUTOHIDE_THRESHOLD,
        windowDays: e.REPORT_AUTOHIDE_WINDOW_DAYS,
        underageTrusted: e.REPORT_UNDERAGE_TRUSTED_THRESHOLD,
        underageAny: e.REPORT_UNDERAGE_ANY_THRESHOLD,
        reporterMinAgeHours: e.REPORT_REPORTER_MIN_AGE_HOURS ?? e.TRUST_RAMP_HOURS,
      },
      evidenceRetentionDays: e.REPORT_EVIDENCE_RETENTION_DAYS,
      evidenceMaxDays: e.REPORT_EVIDENCE_MAX_DAYS,
      bannedRetentionDays: e.BANNED_RETENTION_DAYS,
    },
    spam: {
      enabled: e.SPAM_HEURISTICS_ENABLED,
      windowHours: e.SPAM_WINDOW_HOURS,
      fanOutMin: e.SPAM_FANOUT_MIN,
      fanOutMaxReplyRate: e.SPAM_FANOUT_MAX_REPLY_RATE,
      burstMinutes: e.SPAM_BURST_MINUTES,
      burstFirstContacts: e.SPAM_BURST_FIRST_CONTACTS,
      firstContactMin: e.SPAM_FIRST_CONTACT_MIN,
      firstContactRatio: e.SPAM_FIRST_CONTACT_RATIO,
      blockedDays: e.SPAM_BLOCKED_DAYS,
      blockedHours: e.SPAM_BLOCKED_HOURS,
      blockedMin: e.SPAM_BLOCKED_MIN,
      duplicateRecipients: e.SPAM_DUPLICATE_RECIPIENTS,
      duplicateSimilarity: e.SPAM_DUPLICATE_SIMILARITY,
      linkRecipients: e.SPAM_LINK_RECIPIENTS,
      handleRecipients: e.SPAM_HANDLE_RECIPIENTS,
      scoreNew: e.SPAM_SCORE_NEW,
      scoreEstablished: e.SPAM_SCORE_ESTABLISHED,
      establishedDays: e.SPAM_ESTABLISHED_DAYS,
      cooldownHours: e.SPAM_COOLDOWN_HOURS,
      heldMaxDays: e.SPAM_HELD_MAX_DAYS,
      hashTtlHours: e.SPAM_HASH_TTL_HOURS,
      flagRetentionDays: e.SPAM_FLAG_RETENTION_DAYS,
    },
    photoChecks: {
      classifier: e.PHOTO_CLASSIFIER ?? (e.NODE_ENV === "test" ? "off" : "auto"),
      modelPath: e.PHOTO_NSFW_MODEL || DEFAULT_NSFW_MODEL_PATH,
      threads: e.PHOTO_NSFW_THREADS,
      threshold: e.PHOTO_NSFW_THRESHOLD,
      explicitLabels,
      hideUnchecked: e.PHOTO_HIDE_UNCHECKED,
      duplicateMaxDistance: e.PHOTO_DUPLICATE_MAX_DISTANCE,
      blocklistPath: e.PHOTO_HASH_BLOCKLIST || null,
      blocklist,
    },
    moderatorAlerts: {
      emails: alertEmails,
      webhookUrl,
      intervalMinutes: e.MODERATOR_ALERT_INTERVAL_MINUTES,
      reasons: alertReasons,
    },
    e2e: {
      mode: e.E2E_MODE ?? (isProduction ? "off" : "optional"),
      maxPreKeys: e.E2E_MAX_PREKEYS,
      maxPqPreKeys: e.E2E_MAX_PQ_PREKEYS,
    },
    devAuth: !isProduction && e.STEXX_DEV_AUTH,
    devDefaultLocation,
    devWelcome: !isProduction && e.STEXX_DEV_WELCOME,
    devBots: !isProduction && e.STEXX_DEV_BOTS,
  };
}

/** Process-wide config, parsed once at import. Fails fast. */
export const config: Config = loadConfig(process.env);
