import { z } from "zod";

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
  /** Dev-only auth shortcuts (/auth/register returns a Session, /v1/dev/* mounted). Never true in production. */
  devAuth: boolean;
  /** Dev-only: new users get this cell so the grid isn't empty. null when unset or in production. */
  devDefaultLocation: { latitude: number; longitude: number } | null;
  devWelcome: boolean;
  devBots: boolean;
}

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
    devAuth: !isProduction && e.STEXX_DEV_AUTH,
    devDefaultLocation,
    devWelcome: !isProduction && e.STEXX_DEV_WELCOME,
    devBots: !isProduction && e.STEXX_DEV_BOTS,
  };
}

/** Process-wide config, parsed once at import. Fails fast. */
export const config: Config = loadConfig(process.env);
