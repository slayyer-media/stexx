/**
 * Staff management (admin):
 *   GET  /staff                 list (audited as a read: staff_list)
 *   POST /staff/invite          invite a new handle; needs a recent step-up; shows the link once. For a handle that
 *                               already exists it changes nothing and shows a confirm page instead: re-inviting
 *                               removes that account's passkeys and hands this admin a link to enroll as it, so it
 *                               needs a step-up bound to the action and the account (field `step_up`), spent in the
 *                               same transaction as the re-invite. A reload of the result can't repeat it.
 *   POST /staff/:id/disable     disable; needs a recent step-up, and for another admin a step-up bound to this
 *                               action and target (field `step_up`), spent in the same transaction as the disable
 * The rules (handle format, last admin, never yourself) live in lib/staff/accounts.ts, shared with the CLI.
 */
import { config } from "../../config.ts";
import { sql } from "../../db/sql.ts";
import { notFound } from "../../lib/errors.ts";
import {
  checkStaffRole,
  disableStaff,
  enrollmentUrl,
  findStaff,
  inviteStaff,
  listStaff,
  StaffError,
  type StaffAccount,
} from "../../lib/staff/accounts.ts";
import { staffAudit } from "../../lib/staff/audit.ts";
import { spendActionStepUp } from "../auth/stepup.ts";
import { stepUpRequired, type AdminRoutes } from "../guard.ts";
import { render } from "../render.ts";
import { InviteCreatedPage, ReinviteConfirmPage, StaffPage } from "../views/pages.tsx";
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

/** A re-invite submitted without its bound step-up: show the confirm page (nothing was changed). */
class ReinviteNeedsConfirm extends Error {
  constructor(readonly target: StaffAccount) {
    super("re-invite needs confirmation");
  }
}

export function registerStaffRoutes(r: AdminRoutes): void {
  r.get("/staff", "staff_view", async (c) => {
    const flash = c.req.query("done") === "disabled" ? "Disabled, and signed out everywhere." : null;
    return staffPage(c, { flash });
  });

  r.post("/staff/invite", "staff_manage", async (c) => {
    const staff = c.get("staff")!;
    const session = c.get("session")!;
    const body = await c.req.parseBody();
    const handle = formString(body.handle);
    const role = formString(body.role);
    const proof = formString(body.step_up);
    try {
      const res = await inviteStaff({
        handle,
        role,
        actor: { staffId: staff.id, channel: "console", sessionId: session.id },
        authorizeReinvite: async (tx, target) => {
          if (!proof) throw new ReinviteNeedsConfirm(target);
          const spent = await spendActionStepUp(tx, {
            sessionId: session.id,
            staffId: staff.id,
            action: "staff_reinvite",
            target: target.id,
            token: proof,
          });
          if (!spent) throw stepUpRequired();
        },
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
      if (err instanceof ReinviteNeedsConfirm) {
        checkStaffRole(role); // already checked by inviteStaff; narrows the type
        const [item] = await listStaff(sql, { handle: err.target.handle });
        return render(c, ReinviteConfirmPage({ staff, session, target: err.target, role, passkeys: item?.passkeys ?? 0 }));
      }
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
    const proof = formString(body.step_up);
    try {
      await disableStaff({
        handleOrId: target.id,
        actor: { staffId: staff.id, channel: "console", sessionId: session.id },
        // Checked on the locked row, so a role raised to admin in the meantime still needs the bound proof; and spent
        // in the disable's transaction, so a refused or failed disable keeps it.
        authorize: async (tx, locked) => {
          if (locked.role !== "admin") return;
          const spent = await spendActionStepUp(tx, {
            sessionId: session.id,
            staffId: staff.id,
            action: "staff_disable",
            target: locked.id,
            token: proof,
          });
          if (!spent) throw stepUpRequired();
        },
      });
    } catch (err) {
      if (err instanceof StaffError) return staffPage(c, { error: err.message, status: 400 });
      throw err;
    }
    return c.redirect("/staff?done=disabled", 303);
  });
}
