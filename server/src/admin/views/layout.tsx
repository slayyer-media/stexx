/**
 * Page shell for every console screen. Server-rendered (hono/jsx), no inline script or style: one stylesheet and
 * one script (static/), both served by the console itself. Pages never contain storage keys, tokens (other than the
 * session's own CSRF token) or anything about an account beyond what the page is for.
 */
import type { Child } from "hono/jsx";
import { can } from "../../lib/staff/permissions.ts";
import type { SessionContext, StaffContext } from "../env.ts";

export interface LayoutProps {
  title: string;
  staff?: StaffContext | undefined;
  session?: SessionContext | undefined;
  flash?: string | null;
  error?: string | null;
  children?: Child;
}

export function CsrfField(props: { session: SessionContext | undefined }) {
  return props.session ? <input type="hidden" name="_csrf" value={props.session.csrfToken} /> : null;
}

export function Layout(props: LayoutProps) {
  const { staff, session } = props;
  return (
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex, nofollow" />
        {session ? <meta name="csrf-token" content={session.csrfToken} /> : null}
        <title>{`${props.title} · Stexx staff`}</title>
        <link rel="stylesheet" href="/static/console.css" />
        <script src="/static/passkey.js" defer></script>
      </head>
      <body>
        <header class="top">
          <span class="brand">Stexx staff</span>
          {staff ? (
            <nav>
              <a href="/">Dashboard</a>
              {can(staff.role, "staff_view") ? <a href="/staff">Staff</a> : null}
              <a href="/me/sessions">My sessions</a>
              <span class="who">
                {staff.handle} <span class="role">{staff.role}</span>
              </span>
              <form method="post" action="/logout" class="inline">
                <CsrfField session={session} />
                <button type="submit" class="link">
                  Sign out
                </button>
              </form>
            </nav>
          ) : null}
        </header>
        <main>
          <h1>{props.title}</h1>
          {props.flash ? (
            <p class="flash" role="status">
              {props.flash}
            </p>
          ) : null}
          {props.error ? (
            <p class="error" role="alert">
              {props.error}
            </p>
          ) : null}
          {props.children}
        </main>
      </body>
    </html>
  );
}

/** Day only, UTC (what the pages show for dates). */
export function day(d: Date | null | undefined): string {
  return d ? d.toISOString().slice(0, 10) : "-";
}

/** Day and minute, UTC. */
export function minute(d: Date | null | undefined): string {
  return d ? `${d.toISOString().slice(0, 16).replace("T", " ")} UTC` : "-";
}
