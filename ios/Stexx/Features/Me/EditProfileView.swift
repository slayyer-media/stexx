import PhotosUI
import SwiftUI
import UIKit

/// Edit your public profile. Everything except the nickname is optional.
struct EditProfileView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.apiClient) private var api
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Profile
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var isUploading = false
    @State private var isSaving = false
    @State private var newTag = ""
    @State private var errorMessage: String?

    private let maxPhotos = 6
    private let maxTags = 10
    /// What's actually on the server (uploads happen on pick).
    @State private var photoSync: ProfilePhotoSync

    init(profile: Profile) {
        _draft = State(initialValue: profile)
        _photoSync = State(initialValue: ProfilePhotoSync(photos: profile.photos))
    }

    private var isValid: Bool {
        (2...30).contains(draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }

    var body: some View {
        Form {
            photosSection

            Section {
                TextField("Nickname", text: $draft.displayName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Picker("Age", selection: $draft.age) {
                    Text("Not shown").tag(Int?.none)
                    ForEach(18...99, id: \.self) { age in
                        Text(age, format: .number).tag(Int?.some(age))
                    }
                }
                TextField("Pronouns", text: optionalText(\.pronouns))
                    .textInputAutocapitalization(.never)
            } header: {
                SectionLabel("Basics")
            }
            .editRows()

            Section {
                TextField("Headline", text: optionalText(\.headline))
                TextField("About you", text: optionalText(\.about), axis: .vertical)
                    .lineLimit(4...10)
            } header: {
                SectionLabel("About")
            } footer: {
                EditFooter("Don't include your full name, workplace, or anything that could identify you if you don't want to.")
            }
            .editRows()

            Section {
                Picker("Height", selection: $draft.heightCm) {
                    Text("Not shown").tag(Int?.none)
                    ForEach(140...220, id: \.self) { cm in
                        Text(StexxFormat.height(cm: cm)).tag(Int?.some(cm))
                    }
                }
                Picker("Position", selection: $draft.position) {
                    Text("Not shown").tag(Position?.none)
                    ForEach(Position.allCases) { position in
                        Text(position.title).tag(Position?.some(position))
                    }
                }
            } header: {
                SectionLabel("Stats")
            }
            .editRows()

            Section {
                ForEach(LookingFor.allCases) { item in
                    Toggle(isOn: lookingForBinding(item)) {
                        Label {
                            Text(item.title)
                        } icon: {
                            Image(systemName: item.systemImage).foregroundStyle(Theme.steel)
                        }
                    }
                }
            } header: {
                SectionLabel("Looking for")
            }
            .editRows()

            Section {
                if !draft.tags.isEmpty {
                    FlowLayout {
                        ForEach(draft.tags, id: \.self) { tag in
                            Button {
                                draft.tags.removeAll { $0 == tag }
                            } label: {
                                TagChip(text: tag, systemImage: "xmark")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(tag)")
                        }
                    }
                    .padding(.vertical, 4)
                }
                if draft.tags.count < maxTags {
                    TextField("Add a tag (Rust, climbing, D&D…)", text: $newTag)
                        .onSubmit(addTag)
                        .submitLabel(.done)
                }
            } header: {
                SectionLabel("Tags")
            } footer: {
                EditFooter("Up to \(maxTags). Nerd out.")
            }
            .editRows()

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.stexxSub)
                        .foregroundStyle(Theme.danger)
                }
                .editRows()
            }
        }
        .listSectionSpacing(Theme.Spacing.xl)
        .foregroundStyle(Theme.frost)
        .tint(Theme.ice)
        .stexxBackground(intensity: 0.5)
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(verbatim: "edit profile")
                    .font(.stexxHeadline.weight(.heavy))
                    .tracking(Theme.Tracking.tight)
                    .foregroundStyle(Theme.frost)
                    .accessibilityAddTraits(.isHeader)
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Save", role: .confirm) { Task { await save() } }
                        .disabled(!isValid)
                }
            }
        }
        .onChange(of: photoSelection) { _, items in
            guard !items.isEmpty else { return }
            Task { await upload(items) }
        }
        .onDisappear {
            // Left without saving: remove photos uploaded during this edit.
            let photoSync = photoSync, api = api
            Task { await photoSync.discardUnsavedUploads(using: api) }
        }
    }

    // MARK: Photos

    private var photosSection: some View {
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Spacing.s) {
                    ForEach(Array(draft.photos.enumerated()), id: \.element.id) { index, photo in
                        ProfilePhotoView(profile: draft, photoIndex: index)
                            .frame(width: 96, height: 124)
                            .clipShape(photoTileShape)
                            .hairlineBorder(photoTileShape)
                            .overlay {
                                if index == 0 {
                                    // The main photo is the screen's one rim-lit surface.
                                    Color.clear.rimLight(photoTileShape)
                                }
                            }
                            .overlay(alignment: .bottomLeading) {
                                if index == 0 {
                                    Text("Main")
                                        .stexxLabelStyle(.micro, color: Theme.frost)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .blackGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
                                        .padding(6)
                                }
                            }
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    draft.photos.removeAll { $0.id == photo.id }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(Theme.frost)
                                        .frame(width: 22, height: 22)
                                        .blackGlass(in: RoundedRectangle(cornerRadius: Theme.Radius.xs, style: .continuous))
                                        .contentShape(.rect)
                                }
                                .buttonStyle(.pressable)
                                .padding(4)
                                .accessibilityLabel("Remove photo")
                            }
                    }
                    if draft.photos.count < maxPhotos {
                        PhotosPicker(
                            selection: $photoSelection,
                            maxSelectionCount: maxPhotos - draft.photos.count,
                            matching: .images
                        ) {
                            VStack(spacing: 6) {
                                if isUploading {
                                    ProgressView()
                                } else {
                                    Image(systemName: "plus")
                                        .font(.title3.weight(.regular))
                                        .foregroundStyle(Theme.steel)
                                    Text("Add")
                                        .font(.stexxMicro)
                                        .textCase(.uppercase)
                                        .tracking(Theme.Tracking.micro)
                                        .foregroundStyle(Theme.steel)
                                }
                            }
                            .tint(Theme.steel)
                            .frame(width: 96, height: 124)
                            .background(Theme.ink1, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                    .strokeBorder(Theme.lineStrong, style: StrokeStyle(lineWidth: 0.5, dash: [4, 4]))
                            )
                        }
                        .disabled(isUploading)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
        } header: {
            SectionLabel("Photos")
        } footer: {
            EditFooter("Location and camera data are stripped from photos on your phone before upload. Explicit photos belong in chat, not on your profile.")
        }
        .editRows()
    }

    private var photoTileShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
    }

    private func upload(_ items: [PhotosPickerItem]) async {
        isUploading = true
        defer {
            isUploading = false
            photoSelection = []
        }
        for item in items {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let jpeg = ImageSanitizer.strippedJPEG(from: data)
                else { continue }
                let photo = try await api.uploadPhoto(jpegData: jpeg)
                photoSync.didUpload(photo)
                draft.photos.append(photo)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Applies photo removals and reordering on the server (uploads already
    /// happened when they were picked). Safe to retry. Returns the server's
    /// photo order.
    private func syncPhotos() async throws -> [Photo] {
        try await photoSync.apply(draft.photos, using: api)
    }

    // MARK: Helpers

    /// Binds an optional String property to a TextField, storing `nil` when empty.
    private func optionalText(_ keyPath: WritableKeyPath<Profile, String?> & Sendable) -> Binding<String> {
        Binding(
            get: { draft[keyPath: keyPath] ?? "" },
            set: { draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }

    private func lookingForBinding(_ item: LookingFor) -> Binding<Bool> {
        Binding(
            get: { draft.lookingFor.contains(item) },
            set: { isOn in
                if isOn {
                    if !draft.lookingFor.contains(item) { draft.lookingFor.append(item) }
                } else {
                    draft.lookingFor.removeAll { $0 == item }
                }
            }
        )
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, tag.count <= 24, draft.tags.count < maxTags,
              !draft.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame })
        else { return }
        draft.tags.append(tag)
        newTag = ""
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        draft.displayName = draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            var updated = try await api.updateMe(ProfileUpdate(draft))
            updated.photos = try await syncPhotos()
            appState.me = updated
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Rows sit on the plain background, divided by 0.5pt hairlines (no cards).
private extension View {
    func editRows() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.line)
    }
}

/// Section footer copy in slate.
private struct EditFooter: View {
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

/// Re-encodes images so EXIF/GPS metadata never leaves the device.
enum ImageSanitizer {
    /// Returns a JPEG without metadata, downscaled to at most `maxDimension`.
    static func strippedJPEG(from data: Data, maxDimension: CGFloat = 2048, quality: CGFloat = 0.85) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        let scale = longest > maxDimension ? maxDimension / longest : 1
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        // Drawing into a fresh context bakes in orientation and drops all metadata.
        let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return rendered.jpegData(compressionQuality: quality)
    }
}

#Preview {
    NavigationStack {
        EditProfileView(profile: MockData.profiles[0])
    }
    .previewEnvironment()
}
