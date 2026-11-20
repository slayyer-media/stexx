/**
 *   GET  /                          dashboard: counts only (no account appears on it)
 *   GET  /me/sessions               the staff member's own sessions and passkeys (dates and a browser label)
 *   POST /me/sessions/:id/revoke    sign out one of them (the current one signs you out here)
 */
import { sql } from "../../db/sql.ts";
import { notFound } from "../../lib/errors.ts";
import { staffAudit } from "../../lib/staff/audit.ts";
import { can } from "../../lib/staff/permissions.ts";
import type { AdminRoutes } from "../guard.ts";
import { render } from "../render.ts";
import { clearedSessionCookie, lockStaffAccountFirst, revokeStaffSession } from "../session.ts";
import { DashboardPage, SessionsPage, type DashboardCounts } from "../views/pages.tsx";

const SESSION_ID_RE = /^ss_[a-z2-7]{26}$/;

export function registerHomeRoutes(r: AdminRoutes): void {
  r.get("/", "dashboard", async (c) => {
    const staff = c.get("staff")!;
    const [row] = await sql<{ report_queue: number; open_photo_flags: number; spam_limited: number; staff_active: number }[]>`
      SELECT (SELECT count(DISTINCT reported_id)::int FROM reports WHERE status = 'open' AND reported_id IS NOT NULL) AS report_queue,
             (SELECT count(*)::int FROM photo_flags WHERE status = 'open') AS open_photo_flags,
             (SELECT count(*)::int FROM users WHERE spam_limited_at IS NOT NULL) AS spam_limited,
             (SELECT count(*)::int FROM staff_accounts WHERE disabled_at IS NULL) AS staff_active`;
    const counts: DashboardCounts = {
      reportQueue: row!.report_queue,
      openPhotoFlags: row!.open_photo_flags,
      spamLimited: row!.spam_limited,
      staffActive: can(staff.role, "staff_view") ? row!.staff_active : undefined,
    };
    return render(c, DashboardPage({ staff, session: c.get("session")!, counts }));
  });

  r.get("/me/sessions", "own_sessions", async (c) => {
    const staff = c.get("staff")!;
    const session = c.get("session")!;
    const sessions = await sql<{ id: string; agent_label: string | null; created_at: Date; last_seen_at: Date }[]>`
      SELECT id, agent_label, created_at, last_seen_at FROM staff_sessions
       WHERE staff_id = ${staff.id} AND revoked_at IS NULL AND idle_expires_at > now() AND absolute_expires_at > now()
       ORDER BY created_at DESC LIMIT 100`;
    const passkeys = await sql<{ created_at: Date; last_used_at: Date | null }[]>`
      SELECT created_at, last_used_at FROM staff_passkeys WHERE staff_id = ${staff.id} ORDER BY created_at`;
    const flash = c.req.query("done") === "revoked" ? "Session signed out." : null;
    return render(
      c,
      SessionsPage({
        staff,
        session,
        flash,
        sessions: sessions.map((s) => ({ id: s.id, agentLabel: s.agent_label, createdAt: s.created_at, lastSeenAt: s.last_seen_at, current: s.id === session.id })),
        passkeys: passkeys.map((p) => ({ createdAt: p.created_at, lastUsedAt: p.last_used_at })),
      }),
    );
  });

  r.post("/me/sessions/:id/revoke", "own_sessions", async (c) => {
    const staff = c.get("staff")!;
    const session = c.get("session")!;
    const id = c.req.param("id") ?? "";
    if (!SESSION_ID_RE.test(id)) throw notFound();
    const revoked = await sql.begin(async (tx) => {
      await lockStaffAccountFirst(tx, staff.id);
      if (!(await revokeStaffSession(tx, staff.id, id))) return false;
      await staffAudit(tx, {
        kind: "event",
        action: "session_revoke",
        channel: "console",
        staffId: staff.id,
        sessionId: session.id,
        targetKind: "session",
        targetRef: id,
      });
      return true;
    });
    if (!revoked) throw notFound();
    if (id === session.id) {
      c.header("Set-Cookie", clearedSessionCookie());
      return c.redirect("/login?done=signed_out", 303);
    }
    return c.redirect("/me/sessions?done=revoked", 303);
  });
}
