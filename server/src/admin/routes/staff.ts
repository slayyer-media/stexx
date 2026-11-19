/**
 * Staff management (admin):
 *   GET  /staff                 list (audited as a read: staff_list)
 *   POST /staff/invite          invite or re-invite a handle; needs a recent step-up; shows the link once
 *   POST /staff/:id/disable     disable; needs a recent step-up, and for another admin a step-up bound to this
 *                               action and target (field `step_up`)
 * The rules (handle format, last admin, never yourself) live in lib/staff/accounts.ts, shared with the CLI.
 */
import { config } from "../../config.ts";
import { sql } from "../../db/sql.ts";
import { notFound } from "../../lib/errors.ts";
import { disableStaff, enrollmentUrl, findStaff, inviteStaff, listStaff, StaffError } from "../../lib/staff/accounts.ts";
import { staffAudit } from "../../lib/staff/audit.ts";
import { spendActionStepUp } from "../auth/stepup.ts";
import { stepUpRequired, type AdminRoutes } from "../guard.ts";
import { render } from "../render.ts";
import { InviteCreatedPage, StaffPage } from "../views/pages.tsx";
import type { Context } from "hono";
import type { AdminEnv } from "../env.ts";

const STAFF_ID_RE = /^st_[a-z2-7]{26}$/;

async function staffPage(c: Context<AdminEnv>, opts: { flash?: string | null; error?: string | null; status?: 200 | 400 } = {}) {
  const staff = c.get("staff")!;
  const session = c.get("session")!;
  const items = await sql.begin(async (tx) => {
    await staffAudit(tx, { kind: "read", action: "staff_list", channel: "console", staffId: staff.id, sessionId: session.id });
    return listStaff(tx);
  });
  return render(c, StaffPage({ staff, session, items, flash: opts.flash ?? null, error: opts.error ?? null }), opts.status ?? 200);
}

const formString = (v: unknown) => (typeof v === "string" ? v.trim() : "");

export function registerStaffRoutes(r: AdminRoutes): void {
  r.get("/staff", "staff_view", async (c) => {
    const flash = c.req.query("done") === "disabled" ? "Disabled, and signed out everywhere." : null;
    return staffPage(c, { flash });
  });

  r.post("/staff/invite", "staff_manage", async (c) => {
    const staff = c.get("staff")!;
    const session = c.get("session")!;
    const body = await c.req.parseBody();
    try {
      const res = await inviteStaff({
        handle: formString(body.handle),
        role: formString(body.role),
        actor: { staffId: staff.id, channel: "console", sessionId: session.id },
      });
      return render(
        c,
        InviteCreatedPage({
          staff,
          session,
          handle: res.staff.handle,
          role: res.staff.role,
          url: enrollmentUrl(config.admin.origin, res.token),
          expiresAt: res.expiresAt,
          reinvite: !res.created,
        }),
      );
    } catch (err) {
      if (err instanceof StaffError) return staffPage(c, { error: err.message, status: 400 });
      throw err;
    }
  });

  r.post("/staff/:id/disable", "staff_manage", async (c) => {
    const staff = c.get("staff")!;
    const session = c.get("session")!;
    const id = c.req.param("id") ?? "";
    if (!STAFF_ID_RE.test(id)) throw notFound();
    const target = await findStaff(id);
    if (!target || target.id !== id) throw notFound();
    if (target.id === staff.id) return staffPage(c, { error: "You can't disable yourself. Ask another admin.", status: 400 });
    const body = await c.req.parseBody();
    if (target.role === "admin") {
      const spent = await spendActionStepUp(sql, {
        sessionId: session.id,
        staffId: staff.id,
        action: "staff_disable",
        target: target.id,
        token: formString(body.step_up),
      });
      if (!spent) throw stepUpRequired();
    }
    try {
      await disableStaff({ handleOrId: target.id, actor: { staffId: staff.id, channel: "console", sessionId: session.id } });
    } catch (err) {
      if (err instanceof StaffError) return staffPage(c, { error: err.message, status: 400 });
      throw err;
    }
    return c.redirect("/staff?done=disabled", 303);
  });
}
