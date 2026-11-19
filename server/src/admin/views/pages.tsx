/** The PR 1 screens: login, enrollment, dashboard, my sessions, staff list and invite, errors, dev login. */
import { minute, day, CsrfField, Layout } from "./layout.tsx";
import type { SessionContext, StaffContext } from "../env.ts";
import type { StaffAccount, StaffListItem } from "../../lib/staff/accounts.ts";
import { STAFF_ROLES, type StaffRole } from "../../lib/staff/permissions.ts";
import { hasRecentStepUp } from "../session.ts";

interface Signed {
  staff: StaffContext;
  session: SessionContext;
}

export function LoginPage(props: { flash?: string | null }) {
  return (
    <Layout title="Sign in" flash={props.flash ?? null}>
      <p>Sign in with your staff passkey. There is no password.</p>
      <p>
        <button type="button" id="passkey-login" class="primary">
          Sign in with a passkey
        </button>
      </p>
      <p id="passkey-error" class="error" role="alert" hidden></p>
      <noscript>
        <p class="error">Passkeys need JavaScript (one small script served by this console).</p>
      </noscript>
    </Layout>
  );
}

export function EnrollPage(props: { handle: string; role: string; token: string }) {
  return (
    <Layout title="Set up your passkey">
      <p>
        You were invited as <strong>{props.handle}</strong> ({props.role}). Create a passkey on this device to finish. The
        link works once and expires 30 minutes after it was made.
      </p>
      <p>
        <button type="button" id="passkey-enroll" class="primary" data-token={props.token}>
          Create passkey
        </button>
      </p>
      <p id="passkey-error" class="error" role="alert" hidden></p>
    </Layout>
  );
}

export function EnrollInvalidPage() {
  return (
    <Layout title="Link not valid">
      <p>This enrollment link has expired, was already used, or was replaced by a newer one. Ask an admin for a new link.</p>
    </Layout>
  );
}

export interface DashboardCounts {
  reportQueue: number;
  openPhotoFlags: number;
  spamLimited: number;
  staffActive?: number | undefined;
}

export function DashboardPage(props: Signed & { counts: DashboardCounts }) {
  const c = props.counts;
  return (
    <Layout title="Dashboard" staff={props.staff} session={props.session}>
      <table class="counts">
        <tbody>
          <tr>
            <th scope="row">Accounts in the report queue</th>
            <td>{c.reportQueue}</td>
          </tr>
          <tr>
            <th scope="row">Open photo flags</th>
            <td>{c.openPhotoFlags}</td>
          </tr>
          <tr>
            <th scope="row">Spam-limited accounts</th>
            <td>{c.spamLimited}</td>
          </tr>
          {c.staffActive !== undefined ? (
            <tr>
              <th scope="row">Active staff accounts</th>
              <td>{c.staffActive}</td>
            </tr>
          ) : null}
        </tbody>
      </table>
      <p class="muted">Counts only. Review pages come in a later release; the command line remains the way to act.</p>
    </Layout>
  );
}

export interface SessionRow {
  id: string;
  agentLabel: string | null;
  createdAt: Date;
  lastSeenAt: Date;
  current: boolean;
}

export interface PasskeyRow {
  createdAt: Date;
  lastUsedAt: Date | null;
}

export function SessionsPage(props: Signed & { sessions: SessionRow[]; passkeys: PasskeyRow[]; flash?: string | null }) {
  return (
    <Layout title="My sessions" staff={props.staff} session={props.session} flash={props.flash ?? null}>
      <p>Signed-in browsers for {props.staff.handle}. Sign out any you don't recognise.</p>
      <table>
        <thead>
          <tr>
            <th>Browser</th>
            <th>Signed in</th>
            <th>Last seen</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {props.sessions.map((s) => (
            <tr>
              <td>
                {s.agentLabel ?? "Unknown browser"}
                {s.current ? <span class="tag">this one</span> : null}
              </td>
              <td>{minute(s.createdAt)}</td>
              <td>{minute(s.lastSeenAt)}</td>
              <td>
                <form method="post" action={`/me/sessions/${s.id}/revoke`} class="inline">
                  <CsrfField session={props.session} />
                  <button type="submit">{s.current ? "Sign out" : "Revoke"}</button>
                </form>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      <h2>Passkeys</h2>
      <p>
        {props.passkeys.length} passkey{props.passkeys.length === 1 ? "" : "s"}.
      </p>
      <ul>
        {props.passkeys.map((p) => (
          <li>
            added {day(p.createdAt)}, last used {day(p.lastUsedAt)}
          </li>
        ))}
      </ul>
    </Layout>
  );
}

function staffStatus(s: StaffListItem): string {
  if (s.disabledAt) return `disabled ${day(s.disabledAt)}`;
  if (s.passkeys === 0) return s.invitePending ? "invited" : "no passkey (invite expired)";
  return "active";
}

export function StaffPage(props: Signed & { items: StaffListItem[]; flash?: string | null; error?: string | null }) {
  const fresh = hasRecentStepUp(props.session.stepUpAt);
  return (
    <Layout title="Staff" staff={props.staff} session={props.session} flash={props.flash ?? null} error={props.error ?? null}>
      <table>
        <thead>
          <tr>
            <th>Handle</th>
            <th>Role</th>
            <th>Status</th>
            <th>Passkeys</th>
            <th>Last sign-in</th>
            <th>Invited by</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {props.items.map((s) => (
            <tr>
              <td>{s.handle}</td>
              <td>{s.role}</td>
              <td>{staffStatus(s)}</td>
              <td>{s.passkeys}</td>
              <td>{day(s.lastLoginAt)}</td>
              <td>{s.createdByHandle ?? "command line"}</td>
              <td>
                {!s.disabledAt && s.id !== props.staff.id ? (
                  <form
                    method="post"
                    action={`/staff/${s.id}/disable`}
                    class="inline"
                    data-step-up={s.role === "admin" ? "action" : "recent"}
                    data-step-up-fresh={s.role !== "admin" && fresh ? "1" : undefined}
                    data-step-up-action="staff_disable"
                    data-step-up-target={s.id}
                    data-confirm={`Disable ${s.handle}? They are signed out everywhere and can't sign in again.`}
                  >
                    <CsrfField session={props.session} />
                    <input type="hidden" name="step_up" value="" />
                    <button type="submit" class="danger">
                      Disable
                    </button>
                  </form>
                ) : null}
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      <h2>Invite</h2>
      <p>
        Creates a single-use link, valid for 30 minutes, to pass on out of band. For an existing handle you are asked to
        confirm first: re-inviting removes its passkeys and signs it out everywhere. Use a handle, never a real name.
      </p>
      <form method="post" action="/staff/invite" data-step-up="recent" data-step-up-fresh={fresh ? "1" : undefined}>
        <CsrfField session={props.session} />
        <label>
          Handle <input name="handle" required maxlength={64} pattern="[A-Za-z0-9._\-]{1,64}" autocomplete="off" />
        </label>
        <label>
          Role{" "}
          <select name="role">
            {STAFF_ROLES.map((r) => (
              <option value={r}>{r}</option>
            ))}
          </select>
        </label>
        <button type="submit" class="primary">
          Create invite link
        </button>
      </form>
      <p id="passkey-error" class="error" role="alert" hidden></p>
    </Layout>
  );
}

/** Shown instead of re-inviting when the handle already exists: the consequence, then a step-up bound to the account. */
export function ReinviteConfirmPage(props: Signed & { target: StaffAccount; role: StaffRole; passkeys: number }) {
  const t = props.target;
  const roleChange = t.role !== props.role;
  return (
    <Layout title="Re-invite?" staff={props.staff} session={props.session}>
      <p>
        <strong>{t.handle}</strong> ({t.role}, {t.id}) already exists. Re-inviting removes{" "}
        {props.passkeys === 1 ? "its passkey" : `its ${props.passkeys} passkeys`}, signs it out everywhere and voids any
        earlier link{roleChange ? `, and changes its role from ${t.role} to ${props.role}` : ""}. Whoever opens the new link
        signs in as {t.handle}, so only do this for a person who lost their passkey, and pass the link to them alone.
      </p>
      <form
        method="post"
        action="/staff/invite"
        data-step-up="action"
        data-step-up-action="staff_reinvite"
        data-step-up-target={t.id}
      >
        <CsrfField session={props.session} />
        <input type="hidden" name="handle" value={t.handle} />
        <input type="hidden" name="role" value={props.role} />
        <input type="hidden" name="step_up" value="" />
        <button type="submit" class="danger">
          Re-invite {t.handle}
        </button>{" "}
        <a href="/staff">Cancel</a>
      </form>
      <p id="passkey-error" class="error" role="alert" hidden></p>
    </Layout>
  );
}

export function InviteCreatedPage(props: Signed & { handle: string; role: string; url: string; expiresAt: Date; reinvite: boolean }) {
  return (
    <Layout title="Invite link" staff={props.staff} session={props.session}>
      <p>
        {props.reinvite ? "Re-invited" : "Invited"} <strong>{props.handle}</strong> as {props.role}.
        {props.reinvite ? " Their old passkeys were removed and their sessions signed out." : ""}
      </p>
      <p>Pass this link on out of band. It works once, until {minute(props.expiresAt)}, and is not shown again.</p>
      <p>
        <code class="link-out">{props.url}</code>
      </p>
      <p>
        <a href="/staff">Back to staff</a>
      </p>
    </Layout>
  );
}

export function ErrorPage(props: { status: number; message: string; staff?: StaffContext | undefined; session?: SessionContext | undefined }) {
  const title = props.status === 404 ? "Not found" : props.status === 403 ? "Not allowed" : props.status === 401 ? "Signed out" : "Something went wrong";
  return (
    <Layout title={title} staff={props.staff} session={props.session}>
      <p>{props.message}</p>
      {props.status === 401 ? (
        <p>
          <a href="/login">Sign in</a>
        </p>
      ) : (
        <p>
          <a href="/">Back to the dashboard</a>
        </p>
      )}
    </Layout>
  );
}

export function DevLoginPage(props: { handles: { handle: string; role: string }[] }) {
  return (
    <Layout title="Dev sign-in">
      <p class="notice">Development only (ADMIN_DEV_AUTH). Signs in without a passkey.</p>
      {props.handles.length === 0 ? <p>No active staff accounts. Run the dev seed.</p> : null}
      {props.handles.map((h) => (
        <form method="post" action="/dev/login" class="inline">
          <input type="hidden" name="handle" value={h.handle} />
          <button type="submit">
            {h.handle} ({h.role})
          </button>
        </form>
      ))}
    </Layout>
  );
}
