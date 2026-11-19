/**
 * The page behind an email sign-in link (`${APP_LINK_BASE}/auth/email?token=…`) when it does NOT open the app:
 * read on a computer or another phone, the app not installed, or universal links turned off for the domain (iOS
 * remembers "Open in Safari"). On an iPhone with Stexx, iOS hands the link to the app and this page never loads.
 *
 * Static on purpose: it never reads, echoes, stores or redeems the token (a mail scanner that fetches the link
 * can't use it up), loads nothing from anywhere, and sends no referrer.
 */

export const EMAIL_LINK_PAGE_CSP =
  "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

export const EMAIL_LINK_PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<meta name="referrer" content="no-referrer">
<meta name="color-scheme" content="dark">
<title>Open Stexx</title>
<style>
  :root { color-scheme: dark; }
  body { margin: 0; background: #050608; color: #E8EEF5; font: 17px/1.45 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
  main { max-width: 32rem; margin: 0 auto; padding: 56px 20px; }
  h1 { font-size: 28px; font-weight: 800; letter-spacing: -0.03em; margin: 0 0 12px; }
  h1 span { color: #A78BFF; }
  p, li { color: #8B96A5; }
  ol { padding-left: 1.2em; }
  li { margin: 0 0 12px; }
  strong { color: #E8EEF5; font-weight: 600; }
  .note { font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; text-transform: uppercase; letter-spacing: 0.16em; color: #545E6B; border-top: 0.5px solid rgba(255,255,255,0.08); padding-top: 16px; margin-top: 28px; }
</style>
</head>
<body>
<main>
<h1>open in ste<span>xx</span></h1>
<p>This sign-in link only works in the Stexx app on an iPhone. Nothing happened here, and your link is still good.</p>
<ol>
<li><strong>Reading this on your iPhone?</strong> Go back to the email, touch and hold the link, and choose <strong>Open in &ldquo;Stexx&rdquo;</strong>.</li>
<li><strong>On a computer or another device?</strong> Open Stexx on your iPhone and type the 8-digit code from the same email.</li>
</ol>
<p class="note">The link and the code work once, for 15 minutes. Didn&rsquo;t ask for one? Ignore the email.</p>
</main>
</body>
</html>
`;
