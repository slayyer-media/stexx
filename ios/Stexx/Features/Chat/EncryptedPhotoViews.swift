import SwiftUI
import UIKit

/// What an end-to-end encrypted photo bubble can show, decided from the
/// message alone (no network). `EncryptedPhotoTile` then loads `.load`.
enum EncryptedPhotoContent: Hashable {
    /// Fetch, verify, decrypt and show.
    case load(URL, E2EAttachmentPointer)
    /// A view-once photo: not fetched until the recipient opens it.
    case viewOnce(canOpen: Bool)
    /// A view-once photo this phone opened (its key is gone).
    case opened
    /// Expired or spent on the server.
    case gone
    /// No key on this phone (a reinstall, a new phone, an undecryptable envelope).
    case unavailable
    /// Held back by the sender's key change until the user accepts it.
    case awaitingKey
    /// From a newer version of the app.
    case unsupported

    static func of(_ message: Message, isMine: Bool) -> EncryptedPhotoContent {
        let attachment = message.attachment
        switch message.encryption {
        case .unsupported?: return .unsupported
        case .awaitingKeyConfirmation?: return .awaitingKey
        default: break
        }
        if attachment?.isViewOnce == true {
            // The sender can't know whether it was opened: always the plain tile.
            if isMine { return message.e2eAttachment == nil && message.e2eAttachmentRemoval == nil ? .unavailable : .viewOnce(canOpen: false) }
            if message.e2eAttachmentRemoval == .opened { return .opened }
        }
        if message.e2eAttachmentRemoval != nil { return .gone }
        guard let pointer = message.e2eAttachment else { return .unavailable }
        if attachment?.isViewOnce == true { return .viewOnce(canOpen: true) }
        guard let url = attachment?.url else { return .gone }
        return .load(url, pointer)
    }
}

/// An end-to-end encrypted photo in a chat bubble: loaded through
/// `ChatMediaLoader` (memory only), never a broken image. Incoming photos
/// go through the on-device check first (`ChatPhotoModeration`) and may be
/// blurred until tapped.
struct EncryptedPhotoTile: View {
    let message: Message
    let isMine: Bool
    /// The user tapped a blurred photo to see it (for this thread view).
    var isRevealed = false
    var onReveal: () -> Void = {}
    /// Opens a view-once photo in the full-screen viewer.
    var onOpenViewOnce: () -> Void = {}

    @Environment(AppState.self) private var appState

    private enum Phase: Equatable {
        case loading
        case done(ChatMediaLoader.Outcome)
    }

    @State private var phase: Phase = .loading
    @State private var attempt = 0

    private var content: EncryptedPhotoContent { .of(message, isMine: isMine) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.bubble, style: .continuous)
        ZStack {
            Theme.ink1
            tileContent
        }
        .frame(width: 180, height: 220)
        .clipShape(shape)
        .hairlineBorder(shape)
        .contentShape(shape)
        .onTapGesture(perform: tap)
        .accessibilityActions {
            if let action = actionName {
                Button(action, action: tap)
            }
        }
        .task(id: LoadKey(content: content, attempt: attempt)) { await load() }
    }

    private struct LoadKey: Hashable {
        let content: EncryptedPhotoContent
        let attempt: Int
    }

    @ViewBuilder
    private var tileContent: some View {
        switch content {
        case .load:
            switch phase {
            case .loading:
                ProgressView().tint(Theme.steel)
                    .accessibilityLabel("Loading photo")
            case .done(let outcome):
                loaded(outcome)
            }
        case .viewOnce(let canOpen):
            PhotoTileNotice(
                systemImage: "eye.slash",
                title: "View once",
                detail: canOpen ? "Tap to open" : nil
            )
            .accessibilityAddTraits(canOpen ? .isButton : [])
        case .opened:
            PhotoTileNotice(systemImage: "checkmark.circle", title: "Opened")
        case .gone:
            PhotoTileNotice(systemImage: "hourglass", detail: "Photo no longer available")
        case .unavailable:
            PhotoTileNotice(systemImage: "lock.slash", detail: "Encrypted photo. Not available on this phone.")
        case .awaitingKey:
            PhotoTileNotice(systemImage: "key", detail: "Encrypted photo")
        case .unsupported:
            PhotoTileNotice(systemImage: "lock.slash", detail: "This photo needs a newer version of Stexx.")
        }
    }

    @ViewBuilder
    private func loaded(_ outcome: ChatMediaLoader.Outcome) -> some View {
        switch outcome {
        case .image(let image, let verdict):
            let blurred = !isRevealed && presentation(for: verdict) == .blurUntilTap
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 180, height: 220)
                .blur(radius: blurred ? 28 : 0, opaque: true)
                .overlay {
                    if blurred { BlurredPhotoLabel() }
                }
                .accessibilityElement()
                .accessibilityLabel(blurred ? Text("Photo hidden, may be sensitive") : Text("Photo"))
                .accessibilityHint(blurred ? Text("Double-tap to view") : Text(verbatim: ""))
                .accessibilityAddTraits(blurred ? .isButton : .isImage)
        case .gone:
            PhotoTileNotice(systemImage: "hourglass", detail: "Photo no longer available")
        case .tampered:
            PhotoTileNotice(systemImage: "exclamationmark.triangle", detail: "Couldn't verify this photo")
        case .unreadable:
            PhotoTileNotice(systemImage: "exclamationmark.triangle", detail: "Couldn't show this photo")
        case .failed:
            PhotoTileNotice(systemImage: "arrow.clockwise", detail: "Couldn't load this photo. Tap to try again.")
                .accessibilityAddTraits(.isButton)
        }
    }

    private func presentation(for verdict: ChatPhotoVerdict) -> ChatPhotoModeration.Presentation {
        ChatPhotoModeration.presentation(
            verdict: verdict,
            blurExplicitPhotos: appState.privacy.blurExplicitPhotos,
            systemWarningsEnabled: ChatPhotoModeration.analyzer.systemWarningsEnabled,
            isOwnPhoto: isMine
        )
    }

    /// What a tap does right now, for VoiceOver.
    private var actionName: LocalizedStringKey? {
        switch (content, phase) {
        case (.viewOnce(canOpen: true), _): "Open view-once photo"
        case (.load, .done(.failed)): "Try again"
        case (.load, .done(.image(_, let verdict))) where !isRevealed && presentation(for: verdict) == .blurUntilTap: "View photo"
        default: nil
        }
    }

    private func tap() {
        switch (content, phase) {
        case (.viewOnce(canOpen: true), _):
            onOpenViewOnce()
        case (.load, .done(.failed)):
            phase = .loading
            attempt += 1
        case (.load, .done(.image(_, let verdict))) where !isRevealed && presentation(for: verdict) == .blurUntilTap:
            onReveal()
        default:
            break
        }
    }

    private func load() async {
        guard case .load(let url, let pointer) = content else { return }
        let loader = ChatMediaLoader.shared
        if let cached = await loader.cached(message.id) {
            phase = .done(cached)
            return
        }
        phase = .loading
        let outcome = await loader.photo(
            messageID: message.id,
            url: url,
            pointer: pointer,
            analyzer: isMine ? nil : ChatPhotoModeration.analyzer
        )
        guard !Task.isCancelled else { return }
        phase = .done(outcome)
    }
}

/// "Tap to view" over a blurred photo.
private struct BlurredPhotoLabel: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.title3.weight(.medium))
            Text("Tap to view")
                .stexxLabelStyle(.micro, color: Theme.frost)
        }
        .foregroundStyle(Theme.frost)
        .padding(Theme.Spacing.m)
        .background(Theme.ink.opacity(0.45), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A quiet icon and line or two in place of a photo.
struct PhotoTileNotice: View {
    let systemImage: String
    var title: LocalizedStringKey?
    var detail: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title2.weight(.light))
                .accessibilityHidden(true)
            if let title {
                Text(title)
                    .stexxLabelStyle(.micro, color: Theme.steel)
            }
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.steel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(Theme.steel)
        .padding(Theme.Spacing.m)
        .accessibilityElement(children: .combine)
    }
}

/// Full-screen viewer for an end-to-end encrypted view-once photo. Downloads
/// and decrypts on open, keeps nothing (no cache); closing it ends the photo
/// on this phone (`onClose`).
struct ViewOnceViewer: View {
    let message: Message
    /// Called once when the viewer goes away, with what it ended up showing.
    let onClose: (ChatMediaLoader.Outcome?) -> Void

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var outcome: ChatMediaLoader.Outcome?
    @State private var isRevealed = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch outcome {
            case nil:
                ProgressView().tint(Theme.frost)
                    .accessibilityLabel("Loading photo")
            case .image(let image, let verdict)?:
                let blurred = !isRevealed && ChatPhotoModeration.presentation(
                    verdict: verdict,
                    blurExplicitPhotos: appState.privacy.blurExplicitPhotos,
                    systemWarningsEnabled: ChatPhotoModeration.analyzer.systemWarningsEnabled,
                    isOwnPhoto: false
                ) == .blurUntilTap
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .blur(radius: blurred ? 40 : 0, opaque: true)
                    .overlay {
                        if blurred { BlurredPhotoLabel() }
                    }
                    .onTapGesture { if blurred { isRevealed = true } }
                    .accessibilityElement()
                    .accessibilityLabel(blurred ? Text("Photo hidden, may be sensitive") : Text("View-once photo"))
                    .accessibilityAddTraits(blurred ? .isButton : .isImage)
                    .accessibilityAction { if blurred { isRevealed = true } }
            case .gone?:
                PhotoTileNotice(systemImage: "hourglass", detail: "Photo no longer available")
            case .tampered?:
                PhotoTileNotice(systemImage: "exclamationmark.triangle", detail: "Couldn't verify this photo")
            case .unreadable?:
                PhotoTileNotice(systemImage: "exclamationmark.triangle", detail: "Couldn't show this photo")
            case .failed?:
                PhotoTileNotice(systemImage: "wifi.exclamationmark", detail: "Couldn't load this photo. Close and try again.")
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.frost)
                    .frame(width: 44, height: 44)
                    .background(Theme.ink1.opacity(0.8), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(Theme.Spacing.m)
            .accessibilityLabel("Close")
        }
        .overlay(alignment: .bottom) {
            if case .image? = outcome {
                Text("This photo disappears when you close it.")
                    .stexxLabelStyle(.micro, color: Theme.steel)
                    .padding(.bottom, Theme.Spacing.l)
            }
        }
        .task { await load() }
        .onDisappear { onClose(outcome) }
    }

    private func load() async {
        guard let url = message.attachment?.url, let pointer = message.e2eAttachment else {
            outcome = .gone
            return
        }
        outcome = await ChatMediaLoader.shared.photo(
            messageID: message.id,
            url: url,
            pointer: pointer,
            analyzer: ChatPhotoModeration.analyzer,
            caches: false
        )
    }
}
