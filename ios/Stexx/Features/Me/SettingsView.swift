import StoreKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiClient) private var api

    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var isShowingViewers = false
    @State private var isShowingTravel = false
    @State private var isTurningOffTravel = false
    @State private var boostEndsAt: Date?
    @State private var isExporting = false
    @State private var exportFile: DataExportFile?
    @State private var exportError: String?
    @State private var isManagingSubscription = false

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                Group {
                    Toggle("Hide my distance", isOn: appState.privacyBinding(\.hideDistance))
                    Toggle("Show when I'm online", isOn: appState.privacyBinding(\.showOnlineStatus))
                    Toggle("Send read receipts", isOn: appState.privacyBinding(\.sendReadReceipts))
                }
                .disabled(!appState.isPrivacyEditable)
                if appState.privacyStatus == .unavailable {
                    Button {
                        Task { await appState.loadMe(from: api) }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Couldn't load your settings")
                                Text("Tap to try again")
                                    .font(.stexxSub)
                                    .foregroundStyle(Theme.slate)
                            }
                        } icon: {
                            Image(systemName: "arrow.clockwise").foregroundStyle(Theme.steel)
                        }
                    }
                }
                LabeledContent("Location precision") {
                    Text("About \(StexxFormat.distance(LocationFuzzer.defaultCellMeters))")
                        .stexxLabelStyle()
                }
                Button {
                    Task { await downloadData() }
                } label: {
                    HStack {
                        Label {
                            Text("Download my data")
                        } icon: {
                            Image(systemName: "arrow.down.doc").foregroundStyle(Theme.steel)
                        }
                        Spacer()
                        if isExporting { ProgressView() }
                    }
                }
                .disabled(isExporting)
            } header: {
                HStack(spacing: Theme.Spacing.s) {
                    SectionLabel("Privacy")
                        .fixedSize()
                    if appState.privacyStatus == .loading {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Loading")
                            .stexxLabelStyle(.micro, color: Theme.slate)
                    }
                    Spacer(minLength: 0)
                }
            } footer: {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    if let exportError {
                        Text(exportError)
                            .font(.footnote)
                            .foregroundStyle(Theme.danger)
                    }
                    SettingsFooter("Your location is rounded on this device before it's sent. Others only ever see an approximate distance, never a pin on a map.")
                    SettingsFooter("Download my data saves what Stexx keeps about your account as a JSON file. Encrypted chat text isn't in it: only the phones in a chat can read it.")
                }
            }
            .settingsRows()

            Section {
                Group {
                    Toggle("Expiring photos by default", isOn: appState.privacyBinding(\.expiringPhotosByDefault))
                    Toggle("Blur explicit photos", isOn: appState.privacyBinding(\.blurExplicitPhotos))
                }
                .disabled(!appState.isPrivacyEditable)
                NavigationLink("Blocked members") {
                    BlockedProfilesView()
                }
                Link(destination: URL(string: "https://stexx.gay/safety")!) {
                    Label {
                        Text("Safety tips")
                    } icon: {
                        Image(systemName: "heart.text.square").foregroundStyle(Theme.steel)
                    }
                }
            } header: {
                SectionLabel("Safety")
            } footer: {
                SettingsFooter("Blocking, reporting, hiding your distance and expiring photos are free, forever.")
            }
            .settingsRows()

            Section {
                PlusToggle("Incognito", isOn: appState.privacyBinding(\.incognito))
                    .disabled(!appState.isPrivacyEditable)
                PlusRow("Travel mode", systemImage: "airplane", value: travelValue) { isShowingTravel = true }
                if appState.isTravelPaused {
                    Button {
                        Task { await turnOffTravel() }
                    } label: {
                        Label {
                            Text("Turn off travel mode")
                        } icon: {
                            Image(systemName: "airplane.arrival").foregroundStyle(Theme.steel)
                        }
                    }
                    .disabled(isTurningOffTravel)
                }
                PlusRow("Who viewed you", systemImage: "eyes") { isShowingViewers = true }
                PlusRow("Boosts", systemImage: "bolt.fill") { Task { await boost() } }
            } header: {
                HStack(spacing: Theme.Spacing.s) {
                    SectionLabel(verbatim: "Stexx+")
                        .fixedSize()
                    if appState.hasPlus {
                        Text("Active")
                            .stexxLabelStyle(.micro, color: Theme.ice)
                    }
                    Spacer(minLength: 0)
                }
            } footer: {
                if appState.isTravelPaused {
                    SettingsFooter("Travel mode is paused while you don't have Stexx+: others see you near your real location again. It resumes if you renew, or turn it off here.")
                }
            }
            .settingsRows()

            Section {
                Button("Sign out") { isConfirmingSignOut = true }
                Button("Delete account", role: .destructive) { isConfirmingDelete = true }
                    .disabled(isDeleting)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.stexxSub)
                        .foregroundStyle(Theme.danger)
                }
            } header: {
                SectionLabel("Account")
            }
            .settingsRows()

            Section {
                Link(destination: URL(string: "https://github.com/stexxapp/stexx")!) {
                    Label {
                        Text("Source code on GitHub")
                    } icon: {
                        Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(Theme.steel)
                    }
                }
                Link(destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!) {
                    LabeledContent("License", value: "AGPL-3.0")
                }
                LabeledContent("Version", value: version)
            } header: {
                SectionLabel("About")
            } footer: {
                VStack(spacing: Theme.Spacing.m) {
                    Wordmark(size: 26, glows: false)
                    Tagline()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Spacing.xxl)
            }
            .settingsRows()
        }
        .listSectionSpacing(Theme.Spacing.xl)
        .foregroundStyle(Theme.frost)
        .tint(Theme.ice)
        .stexxBackground(intensity: 0.5)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(verbatim: "settings")
                    .font(.stexxHeadline.weight(.heavy))
                    .tracking(Theme.Tracking.tight)
                    .foregroundStyle(Theme.frost)
                    .accessibilityAddTraits(.isHeader)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarVisibility(.hidden, for: .tabBar)
        .navigationDestination(isPresented: $isShowingViewers) { ViewersView() }
        .navigationDestination(isPresented: $isShowingTravel) { TravelModeView() }
        .alert("Boosted", isPresented: Binding(get: { boostEndsAt != nil }, set: { if !$0 { boostEndsAt = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You're shown first nearby until \((boostEndsAt ?? .now).formatted(date: .omitted, time: .shortened)).")
        }
        .alert(
            "Couldn't save",
            isPresented: Binding(get: { appState.privacyError != nil }, set: { if !$0 { appState.clearPrivacyError() } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.privacyError ?? "")
        }
        .sheet(item: $exportFile, onDismiss: { DataExportFile.removeAll() }) { file in
            ShareSheet(items: [file.url]) { exportFile = nil }
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .confirmationDialog("Sign out of Stexx?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { appState.signOut() }
        } message: {
            Text("Your encryption keys and decrypted messages are removed from this phone. When you sign back in, earlier encrypted messages show as not available here.")
        }
        .confirmationDialog("Delete your account?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { Task { await deleteAccount() } }
            if appState.hasPlus {
                Button("Manage Stexx+ subscription") { isManagingSubscription = true }
            }
        } message: {
            Text(Self.deleteAccountMessage)
        }
        .manageSubscriptionsSheet(isPresented: $isManagingSubscription)
        .task {
            if appState.privacyStatus != .loaded { await appState.loadMe(from: api) }
        }
        #if DEBUG
        .task { await runScreenshotAction() }
        #endif
    }

    #if DEBUG
    /// `-StexxScreenshotAction` (see `ScreenshotRoute`), once the settings
    /// have loaded.
    private func runScreenshotAction() async {
        guard ScreenshotRoute.current != nil, let action = ScreenshotRoute.action else { return }
        while appState.privacyStatus == .loading, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled else { return }
        switch action {
        case .hideDistance: appState.setPrivacy(\.hideDistance, to: !appState.privacy.hideDistance)
        case .export: await downloadData()
        case .signOut: isConfirmingSignOut = true
        case .delete: isConfirmingDelete = true
        }
    }
    #endif

    /// What account deletion does, accurately: no location history exists,
    /// encrypted backups keep data up to 28 days (`server/deploy/backup.sh`),
    /// and the App Store subscription is separate.
    static let deleteAccountMessage = String(localized: "Your profile, photos, chats and approximate location are deleted from our servers right away, and from our encrypted backups within 28 days. Reports and moderation records are kept without a link to you. Deleting doesn't cancel Stexx+: cancel it in your App Store subscriptions. This can't be undone.")

    /// Fetches the export and opens the share sheet with it as a file.
    private func downloadData() async {
        isExporting = true
        exportError = nil
        defer { isExporting = false }
        do {
            let data = try await api.exportData()
            exportFile = try DataExportFile.write(data)
        } catch let error as APIError {
            exportError = error.localizedDescription
        } catch is CocoaError {
            exportError = String(localized: "Couldn't prepare the file. Check there's space on your phone and try again.")
        } catch {
            exportError = String(localized: "Couldn't download your data. Check your connection and try again.")
        }
    }

    /// Trailing value of the travel row: where you browse from, when on.
    private var travelValue: Text? {
        guard appState.isTravelActive else { return nil }
        return Text(appState.travel?.name ?? String(localized: "On"))
    }

    /// Turning travel mode off is free, so a lapsed subscriber can do it.
    private func turnOffTravel() async {
        isTurningOffTravel = true
        defer { isTurningOffTravel = false }
        let model = TravelModeModel(appState: appState, api: api)
        if await !model.turnOff() { errorMessage = model.errorMessage }
    }

    private func boost() async {
        do {
            boostEndsAt = try await api.startBoost().endsAt
        } catch APIError.requiresPlus {
            appState.handleRequiresPlus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteAccount() async {
        isDeleting = true
        defer { isDeleting = false }
        do {
            try await api.deleteAccount()
            appState.signOut(wipeLocalData: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A Stexx+ feature row: opens the feature with Stexx+, the paywall without.
private struct PlusRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    /// Trailing mono-caps value (e.g. where travel mode is), Stexx+ only.
    var value: Text?
    /// Runs when the user has Stexx+ (otherwise the paywall opens).
    var action: (() -> Void)?
    @Environment(AppState.self) private var appState

    init(_ title: LocalizedStringKey, systemImage: String, value: Text? = nil, action: (() -> Void)? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.action = action
    }

    var body: some View {
        Button {
            if appState.requirePlus() { action?() }
        } label: {
            HStack {
                Label {
                    Text(title).foregroundStyle(Theme.frost)
                } icon: {
                    Image(systemName: systemImage).foregroundStyle(Theme.steel)
                }
                Spacer()
                if !appState.hasPlus {
                    PlusBadge()
                } else if let value {
                    value
                        .stexxLabelStyle(color: Theme.ice)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// Rows sit on the plain background, divided by 0.5pt hairlines (no cards).
private extension View {
    func settingsRows() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.line)
    }
}

/// Section footer copy in slate.
private struct SettingsFooter: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.slate)
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .previewEnvironment()
}
