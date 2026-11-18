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

    init(profile: Profile) {
        _draft = State(initialValue: profile)
    }

    private var isValid: Bool {
        (2...30).contains(draft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).count)
    }

    var body: some View {
        Form {
            photosSection

            Section("Basics") {
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
            }

            Section {
                TextField("Headline", text: optionalText(\.headline))
                TextField("About you", text: optionalText(\.about), axis: .vertical)
                    .lineLimit(4...10)
            } header: {
                Text("About")
            } footer: {
                Text("Don't include your full name, workplace, or anything that could identify you if you don't want to.")
            }

            Section("Stats") {
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
            }

            Section("Looking for") {
                ForEach(LookingFor.allCases) { item in
                    Toggle(isOn: lookingForBinding(item)) {
                        Label {
                            Text(item.title)
                        } icon: {
                            Image(systemName: item.systemImage).foregroundStyle(Theme.violetBright)
                        }
                    }
                }
            }
            .tint(Theme.violet)

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
                Text("Tags")
            } footer: {
                Text("Up to \(maxTags). Nerd out.")
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(Theme.danger)
                }
            }
        }
        .stexxBackground(intensity: 0.5)
        .navigationTitle("Edit profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarVisibility(.hidden, for: .tabBar)
        .toolbar {
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
    }

    // MARK: Photos

    private var photosSection: some View {
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: Theme.Spacing.s) {
                    ForEach(Array(draft.photos.enumerated()), id: \.element.id) { index, photo in
                        ProfilePhotoView(profile: draft, photoIndex: index)
                            .frame(width: 96, height: 124)
                            .clipShape(.rect(cornerRadius: 14))
                            .overlay(alignment: .topTrailing) {
                                Button {
                                    draft.photos.removeAll { $0.id == photo.id }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.caption2.weight(.bold))
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.glass)
                                .buttonBorderShape(.circle)
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
                                        .font(.title2.weight(.semibold))
                                    Text("Add").font(.caption.weight(.semibold))
                                }
                            }
                            .foregroundStyle(Theme.violetBright)
                            .frame(width: 96, height: 124)
                            .background(Theme.surface, in: .rect(cornerRadius: 14))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(Theme.violet.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            )
                        }
                        .disabled(isUploading)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        } header: {
            Text("Photos")
        } footer: {
            Text("Location and camera data are stripped from photos on your phone before upload. Explicit photos belong in chat, not on your profile.")
        }
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
                draft.photos.append(photo)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
            // Photo order/removals are local-only in this mock-first version.
            updated.photos = draft.photos
            appState.me = updated
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
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
