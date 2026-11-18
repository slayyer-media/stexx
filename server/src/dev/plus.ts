import { Hono } from "hono";
import { z } from "zod";
import { config } from "../config.ts";
import { sql } from "../db/sql.ts";
import { currentUserId, requireAuth } from "../lib/auth.ts";
import { randomId128 } from "../lib/ids.ts";
import { plusStatus } from "../lib/plus.ts";
import { DAY, isoDate } from "../lib/time.ts";
import { parseJson } from "../lib/validation.ts";
import { recomputePlus } from "../routes/plus.ts";
import type { AppEnv } from "../types.ts";

/**
 * Dev only: POST /v1/dev/plus grants Stexx+ without StoreKit. Loaded only through src/dev/routes.ts, which app.ts
 * imports dynamically when config.devAuth is true. The guard below is belt and braces.
 */
export const devPlusRoutes = new Hono<AppEnv>();

const body = z.strictObject({ days: z.number().int().min(1).max(365).optional() });

devPlusRoutes.post("/dev/plus", requireAuth, async (c) => {
  if (!config.devAuth) throw new Error("dev routes are disabled");
  const userId = currentUserId(c);
  const raw = (await c.req.text()).trim();
  const { days = 30 } = raw === "" ? {} : await parseJson(c, body);
  await sql.begin(async (tx) => {
    await tx`
      INSERT INTO subscriptions (original_transaction_id, user_id, product_id, expires_at, environment)
      VALUES (${`dev_${randomId128()}`}, ${userId}, ${config.apple.plusProductId},
              ${new Date(Date.now() + days * DAY)}, 'Dev')`;
    await recomputePlus(userId, tx);
  });
  const s = await plusStatus(userId);
  return c.json({ isActive: s.isActive, expiresAt: isoDate(s.expiresAt) });
});
