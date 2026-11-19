import SwiftUI
import UIKit

/// Covers the whole app with a brand screen whenever it leaves the
/// foreground, so the app switcher (its live card while you swipe, and the
/// snapshot iOS saves to disk) shows no grid, chats or photos.
///
/// It's a separate `UIWindow` above everything, shown synchronously from the
/// scene's own notifications, so it's in place before iOS takes the snapshot
/// (a SwiftUI overlay driven by `scenePhase` can land a frame too late).
///
/// Trade-off: iOS can't tell an app why it went inactive. The app switcher,
/// Notification Center, Control Center, Siri and system alerts (permission
/// prompts, the App Store purchase sheet) all look the same, so the cover
/// shows for all of them. Flows that the app itself starts and that bring up
/// a system prompt call `expectSystemPrompt()` first: the next deactivation
/// within a few seconds doesn't cover (the prompt sits over the app anyway),
/// but going to the background always does. The exemption is single-use (the
/// first deactivation spends it, covered or not) and the flow ends it when its
/// call returns (`endSystemPrompt()`), so a prompt that never appeared can't
/// leave the next real trip to the app switcher uncovered. The cost: while an
/// app-started prompt is up, the app is already inactive, so swiping into the
/// app switcher from there shows the live card uncovered (iOS sends no new
/// event); the saved snapshot is still covered when the app reaches the
/// background. The photo picker and share sheets run inside the app and never
/// deactivate it, so they never flash.
///
/// On by default; Settings › Privacy can turn it off (stored on this phone
/// only, `enabledKey`).
@MainActor
final class PrivacyCover {
    static let shared = PrivacyCover()

    /// `UserDefaults` key of the Settings toggle. Missing = on.
    static let enabledKey = "stexx.privacyCover"
    /// How long after `expectSystemPrompt()` a deactivation counts as that prompt.
    static let systemPromptWindow: TimeInterval = 10

    private let defaults: UserDefaults
    private var window: UIWindow?
    private var observers: [NSObjectProtocol] = []
    private var systemPromptUntil: Date?
    /// Debug screenshots only: the cover stays up (`-StexxShowPrivacyCover YES`).
    private var isPinned = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Whether the cover is up right now.
    var isShowing: Bool { window.map { !$0.isHidden } ?? false }

    /// Starts following the app's scenes. Call once at launch.
    func install() {
        guard observers.isEmpty else { return }
        #if DEBUG
        isPinned = UserDefaults.standard.bool(forKey: "StexxShowPrivacyCover")
        #endif
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { note in
                let scene = note.object as? UIWindowScene
                MainActor.assumeIsolated { PrivacyCover.shared.sceneWillDeactivate(scene) }
            },
            center.addObserver(forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main) { note in
                let scene = note.object as? UIWindowScene
                MainActor.assumeIsolated { PrivacyCover.shared.sceneDidEnterBackground(scene) }
            },
            center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { note in
                let scene = note.object as? UIWindowScene
                MainActor.assumeIsolated { PrivacyCover.shared.sceneDidActivate(scene) }
            },
        ]
    }

    /// The app is about to show a system prompt over itself (a permission
    /// request, a purchase sheet): don't cover for it.
    func expectSystemPrompt(now: Date = .now) {
        systemPromptUntil = now.addingTimeInterval(Self.systemPromptWindow)
    }

    /// The flow that called `expectSystemPrompt()` is done (its call
    /// returned): drop the exemption if no deactivation used it.
    func endSystemPrompt() {
        systemPromptUntil = nil
    }

    // MARK: Scene phases

    enum Transition {
        case willDeactivate, didEnterBackground, didActivate
    }

    /// Whether the cover should be up after `transition`.
    func wantsCover(after transition: Transition, now: Date = .now) -> Bool {
        switch transition {
        case .willDeactivate:
            guard isEnabled else { return false }
            if let until = systemPromptUntil, now < until { return false }
            return true
        case .didEnterBackground:
            // Always, even for an expected prompt: this is when iOS snapshots the app.
            return isEnabled
        case .didActivate:
            return isPinned
        }
    }

    /// Applies `transition`: spends the system-prompt exemption on the first
    /// deactivation and on reactivation, and returns whether to cover.
    func handle(_ transition: Transition, now: Date = .now) -> Bool {
        let cover = wantsCover(after: transition, now: now)
        if transition != .didEnterBackground { systemPromptUntil = nil }
        return cover
    }

    func sceneWillDeactivate(_ scene: UIWindowScene?) {
        if handle(.willDeactivate) { show(in: scene) }
    }

    func sceneDidEnterBackground(_ scene: UIWindowScene?) {
        if handle(.didEnterBackground) { show(in: scene) }
    }

    func sceneDidActivate(_ scene: UIWindowScene?) {
        if handle(.didActivate) { show(in: scene) } else { hide() }
    }

    // MARK: Window

    private func show(in scene: UIWindowScene?) {
        guard let scene = scene ?? Self.foregroundScene else { return }
        let window: UIWindow
        if let existing = self.window, existing.windowScene === scene {
            window = existing
        } else {
            window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            let host = UIHostingController(rootView: PrivacyCoverView())
            host.view.backgroundColor = UIColor(Theme.ink)
            window.rootViewController = host
            window.accessibilityViewIsModal = true
            self.window = window
        }
        // No animation: it has to be fully there for the snapshot.
        window.layer.removeAllAnimations()
        window.alpha = 1
        window.isHidden = false
    }

    private func hide() {
        guard let window, !window.isHidden else { return }
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        guard !reduceMotion else {
            window.isHidden = true
            return
        }
        UIView.animate(withDuration: 0.15, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            window.alpha = 0
        } completion: { finished in
            // Not if it was shown again meanwhile.
            if finished, window.alpha == 0 { window.isHidden = true }
        }
    }

    private static var foregroundScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

/// What the app switcher shows instead of the app: the backdrop and the
/// logo, nothing else.
struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            GlowBackground(intensity: 0.8)
            VStack(spacing: Theme.Spacing.l) {
                StexxLogoTile(size: 104)
                Wordmark(size: 26)
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Stexx"))
    }
}
