import nodemailer from "nodemailer";
import type { Transporter } from "nodemailer";
import { config } from "../config.ts";
import { serviceUnavailable } from "./errors.ts";

/**
 * Sign-in link delivery.
 * - SMTP_URL set → send via nodemailer. Body contains only the link (no profile content).
 * - Otherwise, outside production → print the LINK (never the address) to stdout and push to devOutbox.
 * - Otherwise (production without SMTP) → 503 `email_unavailable`.
 */

export interface DevMail {
  /** Normalized recipient, kept in memory only (dev/test) so tests can find their link. */
  to: string;
  url: string;
  token: string;
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

export async function sendSignInLink(to: string, token: string): Promise<void> {
  const url = signInLinkUrl(token);
  if (config.smtpUrl) {
    await smtp().sendMail({
      from: config.mailFrom,
      to,
      subject: "Your Stexx sign-in link",
      text: `Tap to sign in to Stexx:\n\n${url}\n\nThis link expires in 15 minutes and works once. If you didn't ask for it, ignore this email.`,
    });
    return;
  }
  if (config.isProduction) throw serviceUnavailable("email_unavailable", "Email sign-in is temporarily unavailable.");
  devOutbox.push({ to: to.trim().toLowerCase(), url, token, at: new Date() });
  if (devOutbox.length > 100) devOutbox.shift();
  if (!config.isTest) console.log(`[dev-mail] sign-in link: ${url}`);
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
