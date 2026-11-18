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
  };
  trustProxy: boolean;
  antiSpam: AntiSpamConfig;
  moderation: ModerationConfig;
  photoChecks: PhotoChecksConfig;
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
    devAuth: !isProduction && e.STEXX_DEV_AUTH,
    devDefaultLocation,
    devWelcome: !isProduction && e.STEXX_DEV_WELCOME,
    devBots: !isProduction && e.STEXX_DEV_BOTS,
  };
}

/** Process-wide config, parsed once at import. Fails fast. */
export const config: Config = loadConfig(process.env);
