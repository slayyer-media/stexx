import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiClient) private var api

    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var isShowingViewers = false
    @State private var boostEndsAt: Date?

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        @Bindable var bindable = appState

        Form {
            Section {
                Toggle("Hide my distance", isOn: $bindable.privacy.hideDistance)
                Toggle("Show when I'm online", isOn: $bindable.privacy.showOnlineStatus)
                Toggle("Send read receipts", isOn: $bindable.privacy.sendReadReceipts)
                LabeledContent("Location precision") {
                    Text("About \(StexxFormat.distance(LocationFuzzer.defaultCellMeters))")
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Your location is rounded on this device before it's sent. Others only ever see an approximate distance, never a pin on a map.")
            }

            Section {
                Toggle("Expiring photos by default", isOn: $bindable.privacy.expiringPhotosByDefault)
                Toggle("Blur explicit photos", isOn: $bindable.privacy.blurExplicitPhotos)
                NavigationLink("Blocked members") {
                    BlockedProfilesView()
                }
                Link(destination: URL(string: "https://stexx.gay/safety")!) {
                    Label("Safety tips", systemImage: "heart.text.square")
                }
            } header: {
                Text("Safety")
            } footer: {
                Text("Blocking, reporting, hiding your distance and expiring photos are free, forever.")
            }

            Section {
                PlusToggle("Incognito", isOn: $bindable.privacy.incognito)
                PlusRow("Travel mode", systemImage: "airplane")
                PlusRow("Who viewed you", systemImage: "eyes") { isShowingViewers = true }
                PlusRow("Boosts", systemImage: "bolt.fill") { Task { await boost() } }
            } header: {
                Text(verbatim: "Stexx+")
            }

            Section("Account") {
                Button("Sign out") { isConfirmingSignOut = true }
                Button("Delete account", role: .destructive) { isConfirmingDelete = true }
                    .disabled(isDeleting)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(Theme.danger)
                }
            }

            Section {
                Link(destination: URL(string: "https://github.com/stexxapp/stexx")!) {
                    Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://www.gnu.org/licenses/agpl-3.0.html")!) {
                    LabeledContent("License", value: "AGPL-3.0")
                }
                LabeledContent("Version", value: version)
            } header: {
                Text("About")
            } footer: {
                VStack(spacing: Theme.Spacing.s) {
                    Wordmark(size: 22)
                    Text("No ads. Just stexx.")
                }
                .frame(maxWidth: .infinity)
                .padding(.top, Theme.Spacing.xl)
            }
        }
        .tint(Theme.violet)
        .stexxBackground(intensity: 0.5)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .navigationDestination(isPresented: $isShowingViewers) { ViewersView() }
        .alert("Boosted", isPresented: Binding(get: { boostEndsAt != nil }, set: { if !$0 { boostEndsAt = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You're shown first nearby until \((boostEndsAt ?? .now).formatted(date: .omitted, time: .shortened)).")
        }
        .confirmationDialog("Sign out of Stexx?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { appState.signOut() }
        }
        .confirmationDialog("Delete your account?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { Task { await deleteAccount() } }
        } message: {
            Text("Your profile, photos, messages and location history are permanently deleted from our servers. This can't be undone.")
        }
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

/// A Stexx+ feature row that opens the paywall (or the feature, later).
private struct PlusRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    /// Runs when the user has Stexx+ (otherwise the paywall opens).
    var action: (() -> Void)?
    @Environment(AppState.self) private var appState

    init(_ title: LocalizedStringKey, systemImage: String, action: (() -> Void)? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button {
            if appState.requirePlus() { action?() }
            // TODO: Travel mode UI (API: `setTravelLocation`).
        } label: {
            HStack {
                Label {
                    Text(title).foregroundStyle(Theme.textPrimary)
                } icon: {
                    Image(systemName: systemImage).foregroundStyle(Theme.violetBright)
                }
                Spacer()
                if !appState.hasPlus { PlusBadge() }
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .previewEnvironment()
}
