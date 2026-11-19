/**
 * Development only (ADMIN_DEV_AUTH=1, never in production, loopback host only; config.ts refuses otherwise):
 * sign in as an active staff handle without a passkey, to work on the pages. Imported dynamically by app.ts only when
 * config.admin.devAuth is on. The dev seed (`bun run db:seed`) creates dev-support, dev-mod and dev-admin.
 */
import { config } from "../config.ts";
import { sql } from "../db/sql.ts";
import { notFound } from "../lib/errors.ts";
import { staffAudit } from "../lib/staff/audit.ts";
import type { AdminRoutes } from "./guard.ts";
import { render } from "./render.ts";
import { createStaffSession, sessionCookie } from "./session.ts";
import { DevLoginPage } from "./views/pages.tsx";

export function registerDevRoutes(r: AdminRoutes): void {
  if (!config.admin.devAuth || config.isProduction) throw new Error("dev login is development only");

  r.get("/dev/login", "public", async (c) => {
    const handles = await sql<{ handle: string; role: string }[]>`
      SELECT handle, role FROM staff_accounts WHERE disabled_at IS NULL ORDER BY handle LIMIT 50`;
    return render(c, DevLoginPage({ handles }));
  });

  r.post("/dev/login", "public", async (c) => {
    if (!config.admin.devAuth || config.isProduction) throw notFound();
    const body = await c.req.parseBody();
    const handle = typeof body.handle === "string" ? body.handle : "";
    const session = await sql.begin(async (tx) => {
      const [staff] = await tx<{ id: string }[]>`
        SELECT id FROM staff_accounts WHERE handle = ${handle} AND disabled_at IS NULL`;
      if (!staff) return null;
      const s = await createStaffSession(tx, staff.id, c.req.header("User-Agent"));
      await staffAudit(tx, { kind: "event", action: "dev_login", channel: "console", staffId: staff.id, sessionId: s.id });
      return s;
    });
    if (!session) throw notFound();
    c.header("Set-Cookie", sessionCookie(session.token));
    return c.redirect("/", 303);
  });
}
