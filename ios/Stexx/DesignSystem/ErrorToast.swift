import SwiftUI

// MARK: - Friendly error text

/// Turns an error from the API (or the network) into one short sentence for
/// people. Screens show it with `.errorToast($message)` or in an alert.
///
/// - 429: says how long to wait, from `Retry-After`.
/// - 402 / `requires_plus`: "This is part of Stexx+."
/// - 403 (`account_under_review`, anti-spam limits): the server's own
///   message, which is written for people.
/// - Offline or unreachable: asks to check the connection.
/// - 404: a neutral "no longer exists" (screens that know what's gone, like
///   a profile, word it themselves).
/// - Anything else: a generic "Try again".
///
/// Returns `nil` for cancellations (a screen closed mid-request), which
/// should never surface as an error.
enum UserFacingError {
    /// - Parameter failedAction: what didn't happen, e.g. "Couldn't send the
    ///   tap.", used to lead the offline and generic messages. Messages that
    ///   already explain themselves (429, 402, 403) don't repeat it.
    static func message(for error: any Error, failedAction: String? = nil) -> String? {
        if isCancellation(error) { return nil }
        if let apiError = error as? APIError {
            switch apiError {
            case .rateLimited(let retryAfter):
                return rateLimitedMessage(retryAfter: retryAfter)
            case .requiresPlus, .server(status: 402, message: _, code: _):
                return String(localized: "This is part of Stexx+.")
            case .server(status: 403, message: let message?, code: _) where !message.isEmpty:
                return message
            case .server(status: 403, message: _, code: _):
                return String(localized: "You can't do that right now.")
            case .unauthorized:
                return String(localized: "Your session expired. Please sign in again.")
            case .notFound:
                // Neutral on purpose: a 404 can come from any call. Profile
                // screens say "This profile is no longer available" themselves.
                return lead(failedAction, String(localized: "That no longer exists."),
                            tail: String(localized: "It no longer exists."))
            case .server, .e2e, .invalidResponse:
                return generic(failedAction)
            }
        }
        if isOffline(error) {
            return lead(failedAction, String(localized: "Couldn't connect. Check your connection and try again."),
                        tail: String(localized: "Check your connection and try again."))
        }
        return generic(failedAction)
    }

    /// "Try again in N min", rounded up; hours past an hour.
    static func rateLimitedMessage(retryAfter: TimeInterval?) -> String {
        guard let retryAfter, retryAfter > 0 else {
            return String(localized: "You're doing that too often. Try again in a moment.")
        }
        let minutes = max(1, Int((retryAfter / 60).rounded(.up)))
        if minutes < 60 {
            return String(localized: "You're doing that too often. Try again in \(minutes) min.")
        }
        let hours = Int((retryAfter / 3600).rounded(.up))
        return String(localized: "You're doing that too often. Try again in \(hours) h.")
    }

    static func isOffline(_ error: any Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
             .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func generic(_ failedAction: String?) -> String {
        lead(failedAction, String(localized: "Something went wrong. Try again."),
             tail: String(localized: "Try again."))
    }

    private static func lead(_ failedAction: String?, _ standalone: String, tail: String) -> String {
        guard let failedAction, !failedAction.isEmpty else { return standalone }
        return "\(failedAction) \(tail)"
    }
}

// MARK: - Toast

extension View {
    /// Shows `message` as a small black-glass banner at the top of the view.
    /// VoiceOver announces it; it has a Dismiss button (and the escape
    /// gesture), and goes away by itself after a few seconds unless
    /// VoiceOver is running. Setting `message` to `nil` hides it.
    func errorToast(_ message: Binding<String?>) -> some View {
        modifier(ErrorToastModifier(message: message))
    }
}

private struct ErrorToastModifier: ViewModifier {
    @Binding var message: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled

    /// Long enough to read two lines.
    private let visibleFor: Duration = .seconds(6)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    ErrorToastView(text: message) { self.message = nil }
                        .padding(.horizontal, Theme.Spacing.l)
                        .padding(.top, Theme.Spacing.s)
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                        .task(id: message) {
                            AccessibilityNotification.Announcement(message).post()
                            guard !voiceOverEnabled else { return }
                            try? await Task.sleep(for: visibleFor)
                            if !Task.isCancelled, self.message == message { self.message = nil }
                        }
                }
            }
            .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: message)
    }
}

/// Warning glyph, the message in frost, and an × to dismiss.
struct ErrorToastView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            Text(text)
                .font(.stexxSub)
                .foregroundStyle(Theme.frost)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.steel)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, Theme.Spacing.m)
        .padding(.trailing, Theme.Spacing.xs)
        .padding(.vertical, Theme.Spacing.s)
        .blackGlass(in: shape)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, dismiss)
        .accessibilityAddTraits(.isStaticText)
    }
}

#Preview {
    @Previewable @State var message: String? = UserFacingError.message(for: APIError.rateLimited(retryAfter: 600))
    Color.clear
        .stexxBackground()
        .errorToast($message)
        .preferredColorScheme(.dark)
}
