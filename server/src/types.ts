/** Hono env for every router: `new Hono<AppEnv>()`. `userId`/`sessionId` are set by requireAuth. */
export type AppEnv = {
  Variables: {
    userId: string;
    sessionId: string;
    /** Bearer token already resolved by the general rate limiter (requireAuth reuses it; no second lookup). */
    resolvedAuth: { token: string; auth: { userId: string; sessionId: string } | null } | undefined;
  };
};
