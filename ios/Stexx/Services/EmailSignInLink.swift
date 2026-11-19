import Foundation

/// Email sign-in links: `<APP_LINK_BASE>/auth/email?token=…` (server
/// `lib/mailer.ts`). They reach the app as universal links through the
/// `applinks:` associated domain and the server's apple-app-site-association
/// file, which lists `/auth/email`.
enum EmailSignInLink {
    /// The app-link host (`STEXX_APP_LINK_HOST`, Info.plist
    /// `StexxAppLinkHost`); stexx.gay when the build doesn't say.
    static let configuredHost: String = {
        let value = (Bundle.main.object(forInfoDictionaryKey: "StexxAppLinkHost") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty || value.hasPrefix("$(") ? "stexx.gay" : value.lowercased()
    }()

    /// The one-time token in `url`, or nil when `url` isn't a sign-in link:
    /// `https` on the app-link host only, whatever else hands the app a URL.
    static func token(from url: URL, host: String = configuredHost) -> String? {
        guard url.scheme?.lowercased() == "https", url.host()?.lowercased() == host.lowercased() else { return nil }
        let path = url.path()
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard trimmed == "/auth/email",
              let token = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "token" })?.value,
              !token.isEmpty
        else { return nil }
        return token
    }
}
