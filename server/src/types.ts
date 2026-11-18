/** Hono env for every router: `new Hono<AppEnv>()`. `userId`/`sessionId` are set by requireAuth. */
/** The device proof attached by lib/abuse/attestation.ts `attest()` (kind "none" when attestation is off). */
export interface DeviceContext {
  kind: "app-attest" | "devicecheck" | "dev-bypass" | "none";
  /** devices.id for App Attest devices, else null. */
  deviceId: string | null;
  /** DeviceCheck token from this request (used for the per-device bits; never stored). */
  deviceCheckToken: string | null;
}

export type AppEnv = {
  Variables: {
    userId: string;
    sessionId: string;
    /** Bearer token already resolved by the general rate limiter (requireAuth reuses it; no second lookup). */
    device: DeviceContext;
    resolvedAuth: { token: string; auth: { userId: string; sessionId: string } | null } | undefined;
  };
};
