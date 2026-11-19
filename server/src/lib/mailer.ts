import nodemailer from "nodemailer";
import type { Transporter } from "nodemailer";
import { config } from "../config.ts";
import { serviceUnavailable } from "./errors.ts";

/**
 * Sign-in link delivery: one email with the link and the same sign-in's one-time code.
 * - SMTP_URL set → send via nodemailer. Body contains only the link and the code (no profile content).
 * - Otherwise, outside production → print the LINK and CODE (never the address) to stdout and push to devOutbox.
 * - Otherwise (production without SMTP) → 503 `email_unavailable`.
 */

export interface DevMail {
  /** Normalized recipient, kept in memory only (dev/test) so tests can find their link. */
  to: string;
  url: string;
  token: string;
  /** The 8-digit code that works instead of the link (POST /auth/email/code). */
  code: string;
  at: Date;
}

/** Dev/test-only in-memory outbox (last 100). Always empty in production. */
export const devOutbox: DevMail[] = [];

let transporter: Transporter | null = null;
function smtp(): Transporter {
  transporter ??= nodemailer.createTransport(config.smtpUrl!);
  return transporter;
}

export function signInLinkUrl(token: string): string {
  return `${config.appLinkBase}/auth/email?token=${encodeURIComponent(token)}`;
}

/** Plain-text body. Exported for tests. The code is on a line of its own so iOS can offer it as AutoFill. */
export function signInMailText(url: string, code: string): string {
  return [
    "Tap to sign in to Stexx on your iPhone:",
    "",
    url,
    "",
    `Or enter this code in the Stexx app: ${code}`,
    "",
    "The link and the code work once, for 15 minutes. If you didn't ask for this, ignore this email.",
  ].join("\n");
}

export async function sendSignInLink(to: string, token: string, code: string): Promise<void> {
  const url = signInLinkUrl(token);
  if (config.smtpUrl) {
    await smtp().sendMail({
      from: config.mailFrom,
      to,
      // Not the code: subjects show on the lock screen and in notification previews.
      subject: "Your Stexx sign-in link",
      text: signInMailText(url, code),
    });
    return;
  }
  if (config.isProduction) throw serviceUnavailable("email_unavailable", "Email sign-in is temporarily unavailable.");
  devOutbox.push({ to: to.trim().toLowerCase(), url, token, code, at: new Date() });
  if (devOutbox.length > 100) devOutbox.shift();
  if (!config.isTest) console.log(`[dev-mail] sign-in link: ${url}  code: ${code}`);
}

/**
 * Plain-text mail through the same SMTP transport (moderator alerts). Throws when SMTP isn't configured; the caller
 * decides what that means. Never pass user content in `text`.
 */
export async function sendPlainMail(to: string[], subject: string, text: string): Promise<void> {
  if (!config.smtpUrl) throw serviceUnavailable("email_unavailable", "SMTP is not configured.");
  await smtp().sendMail({ from: config.mailFrom, to, subject, text });
}

/** Latest dev link sent to `email` (tests). */
export function lastDevLinkFor(email: string): DevMail | undefined {
  const norm = email.trim().toLowerCase();
  for (let i = devOutbox.length - 1; i >= 0; i--) if (devOutbox[i]!.to === norm) return devOutbox[i];
  return undefined;
}
