import Foundation

/// Keeps the profile editor's photo list in step with the server.
///
/// Photos are uploaded as soon as they're picked, so the server's gallery
/// can hold photos the draft no longer shows (removed again before saving).
/// This tracks what is actually on the server, so that saving:
///
/// - deletes every server photo missing from the draft, including ones
///   uploaded during this edit, so the reorder call always gets an exact
///   permutation of the server's photos;
/// - is safe to retry after a partial failure: a photo whose delete already
///   went through is not deleted again (and a 404 counts as deleted);
///
/// and leaving without saving removes the photos uploaded during the edit,
/// including any upload still in flight when the editor closed: once the
/// edit is abandoned, a photo that finishes uploading is deleted straight
/// away instead of joining the gallery.
@MainActor
final class ProfilePhotoSync {
    /// Photos on the server, in server order.
    private(set) var serverPhotos: [Photo]
    /// Uploaded during this edit and not saved yet.
    private(set) var unsavedUploads: [Photo.ID] = []
    /// The editor closed without saving. Uploads that land after this are
    /// deleted again, and the upload loop stops picking up more photos.
    private(set) var isAbandoned = false

    /// Photos that were on the server before this edit and still are (the
    /// gallery as people see it if this edit's uploads are discarded).
    var committedPhotos: [Photo] {
        serverPhotos.filter { !unsavedUploads.contains($0.id) }
    }

    /// Deleted photos are dropped from here too, so a removed photo isn't
    /// kept in memory for the rest of the session.
    private let loader: ProfilePhotoLoader

    init(photos: [Photo], loader: ProfilePhotoLoader = .shared) {
        serverPhotos = photos
        self.loader = loader
    }

    /// A photo was uploaded (the server appends it to the gallery).
    func didUpload(_ photo: Photo) {
        serverPhotos.append(photo)
        unsavedUploads.append(photo.id)
    }

    /// Records a finished upload, unless the edit was abandoned while it was
    /// uploading: then the photo is deleted again (best effort) so it never
    /// stays on the public profile, and this returns `false`.
    func didUpload(_ photo: Photo, using api: any APIClient) async -> Bool {
        guard isAbandoned else {
            didUpload(photo)
            return true
        }
        do {
            try await api.deletePhoto(id: photo.id)
        } catch {
            // Offline: it stays; the user can remove it next edit.
        }
        return false
    }

    /// Makes the server's gallery exactly `wanted`, in that order, and
    /// returns it.
    func apply(_ wanted: [Photo], using api: any APIClient) async throws -> [Photo] {
        let keep = Set(wanted.map(\.id))
        for photo in serverPhotos where !keep.contains(photo.id) {
            do {
                try await api.deletePhoto(id: photo.id)
            } catch APIError.notFound {
                // Already gone (an earlier attempt got through).
            }
            if let url = photo.url { loader.evict(url) }
            serverPhotos.removeAll { $0.id == photo.id }
            unsavedUploads.removeAll { $0 == photo.id }
        }
        let wantedIDs = wanted.map(\.id)
        if !wantedIDs.isEmpty, wantedIDs != serverPhotos.map(\.id) {
            serverPhotos = try await api.reorderPhotos(wantedIDs)
        }
        unsavedUploads = []
        return serverPhotos
    }

    /// The edit was abandoned: delete what it uploaded. Best effort.
    func discardUnsavedUploads(using api: any APIClient) async {
        isAbandoned = true
        let uploads = unsavedUploads
        unsavedUploads = []
        for id in uploads {
            do {
                try await api.deletePhoto(id: id)
                forget(id)
            } catch APIError.notFound {
                forget(id)
            } catch {
                // Offline: the photo stays; the user can remove it next edit.
            }
        }
    }

    private func forget(_ id: Photo.ID) {
        for photo in serverPhotos where photo.id == id { if let url = photo.url { loader.evict(url) } }
        serverPhotos.removeAll { $0.id == id }
    }
}
