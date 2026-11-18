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
/// and leaving without saving removes the photos uploaded during the edit.
@MainActor
final class ProfilePhotoSync {
    /// Photos on the server, in server order.
    private(set) var serverPhotos: [Photo]
    /// Uploaded during this edit and not saved yet.
    private(set) var unsavedUploads: [Photo.ID] = []

    init(photos: [Photo]) {
        serverPhotos = photos
    }

    /// A photo was uploaded (the server appends it to the gallery).
    func didUpload(_ photo: Photo) {
        serverPhotos.append(photo)
        unsavedUploads.append(photo.id)
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
        let uploads = unsavedUploads
        unsavedUploads = []
        for id in uploads {
            do {
                try await api.deletePhoto(id: id)
                serverPhotos.removeAll { $0.id == id }
            } catch APIError.notFound {
                serverPhotos.removeAll { $0.id == id }
            } catch {
                // Offline: the photo stays; the user can remove it next edit.
            }
        }
    }
}
