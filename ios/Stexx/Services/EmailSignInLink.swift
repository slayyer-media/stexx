import Foundation

/// Email sign-in links: `<APP_LINK_BASE>/auth/email?token=…` (server
/// `lib/mailer.ts`). They reach the app as universal links through the
/// `applinks:` associated domain and the server's apple-app-site-association
/// file, which lists `/auth/email`.
enum EmailSignInLink {
    /// The one-time token in `url`, or nil when `url` isn't a sign-in link.
    static func token(from url: URL) -> String? {
        let path = url.path()
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard trimmed.hasSuffix("/auth/email"),
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty
        else { return nil }
        return token
    }
}
