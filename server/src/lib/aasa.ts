/**
 * apple-app-site-association (AASA): the file iOS fetches (through Apple's CDN) from
 * `https://<WEBAUTHN_RP_ID>/.well-known/apple-app-site-association` to decide that the Stexx app may use
 * passkeys for that domain (`webcredentials`) and open its links (`applinks`).
 *
 * The API serves it at that path on every host it answers (api.stexx.gay included); the relying-party domain
 * itself (stexx.gay) must serve the same bytes with no redirect. See server/deploy/README.md.
 */

export const AASA_PATH = "/.well-known/apple-app-site-association";

/** Email sign-in links are `${APP_LINK_BASE}/auth/email?token=...` (lib/mailer.ts). */
export const EMAIL_LINK_PATH = "/auth/email";

export interface AppSiteAssociation {
  webcredentials: { apps: string[] };
  applinks: { details: { appIDs: string[]; components: { "/": string; "?": Record<string, string>; comment: string }[] }[] };
}

/**
 * The AASA document for `appId` (`TEAMID.bundleId`), or null when it is unknown (APPLE_TEAM_ID unset): an
 * empty or made-up app ID would only make iOS cache a useless file, so the route answers 404 instead.
 */
export function appSiteAssociation(appId: string | null): AppSiteAssociation | null {
  if (!appId) return null;
  return {
    webcredentials: { apps: [appId] },
    applinks: {
      // Only the exact sign-in path, and only with a token (`?*` = at least one character). Everything else on the
      // domain stays in the browser.
      details: [
        { appIDs: [appId], components: [{ "/": EMAIL_LINK_PATH, "?": { token: "?*" }, comment: "Email sign-in links" }] },
      ],
    },
  };
}
