import Foundation
import UIKit

/// Profile photos (the Nearby grid, avatars, profiles, the user's own photos
/// including ones the server labelled explicit).
///
/// - Downloads go through `PrivateMedia.session` (ephemeral, no URL cache), so
///   no profile photo lands in `Library/Caches`. The media host marks photos
///   cacheable for a year, and `AsyncImage` (`URLSession.shared`) would keep
///   them on disk past sign-out, account deletion and the photo's deletion.
/// - Decoded images live in memory only, in a cache capped by count and by
///   decoded size, so scrolling the grid doesn't download the same photo
///   again. Cleared on sign-out (`clear()`); a load still running then
///   doesn't cache its result.
/// - Concurrent requests for the same URL share one download.
/// - Never logs URLs or image data.
final class ProfilePhotoLoader: @unchecked Sendable {
    static let shared = ProfilePhotoLoader()

    /// The largest body accepted (profile photos are re-encoded server-side
    /// and far smaller); anything bigger is dropped, not decoded.
    static let maxBytes = 16 * 1024 * 1024

    let session: URLSession
    private let cache = NSCache<NSURL, UIImage>()
    private let lock = NSLock()
    /// Bumped by `clear()`: a load that started before returns its image but
    /// doesn't cache it.
    private var generation = 0
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    init(session: URLSession = PrivateMedia.session, countLimit: Int = 300, totalCostLimit: Int = 80 * 1024 * 1024) {
        self.session = session
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    var countLimit: Int { cache.countLimit }
    var totalCostLimit: Int { cache.totalCostLimit }

    /// A photo already loaded in this session, if it's still cached.
    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Loads (or reuses) the photo at `url`. `nil` on a network error, a
    /// non-2xx answer or a body that isn't an image.
    func image(for url: URL) async -> UIImage? {
        if let cached = cached(url) { return cached }
        let task: Task<UIImage?, Never> = lock.withLock {
            if let running = inFlight[url] { return running }
            let started = generation
            let task = Task { [session] in
                let image = await Self.download(url, session: session)
                self.finish(url, image: image, generation: started)
                return image
            }
            inFlight[url] = task
            return task
        }
        return await task.value
    }

    /// Drops one photo (e.g. the owner removed it).
    func evict(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    /// Signed out or account deleted: drop every photo (and don't cache any
    /// still loading).
    func clear() {
        lock.withLock {
            generation += 1
            inFlight.removeAll()
            cache.removeAllObjects()
        }
    }

    private func finish(_ url: URL, image: UIImage?, generation started: Int) {
        lock.withLock {
            guard started == generation else { return }
            inFlight[url] = nil
            if let image { cache.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image)) }
        }
    }

    private static func download(_ url: URL, session: URLSession) async -> UIImage? {
        guard let (data, response) = try? await session.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        guard data.count <= maxBytes, let decoded = UIImage(data: data) else { return nil }
        return await decoded.byPreparingForDisplay() ?? decoded
    }

    /// Decoded size in bytes, for the cache's cost limit.
    static func cost(of image: UIImage) -> Int {
        if let cgImage = image.cgImage { return cgImage.bytesPerRow * cgImage.height }
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        return Int(pixels) * 4
    }
}

/// The process-wide `URLCache` that `URLSession.shared` (and `AsyncImage`)
/// use. Nothing in the app should load media through it any more; this makes
/// sure that stays true on disk, even for code that slips through.
enum SharedURLCacheHygiene {
    /// Memory budget of the replacement cache (no disk).
    static let memoryCapacity = 4 * 1024 * 1024

    /// At launch, before anything loads: delete every response earlier
    /// builds wrote to disk (profile photos loaded through `AsyncImage`), and
    /// swap in a cache that never writes to disk.
    @discardableResult
    static func installAtLaunch() -> URLCache {
        purge(URLCache.shared)
        let memoryOnly = URLCache(memoryCapacity: memoryCapacity, diskCapacity: 0, directory: nil)
        URLCache.shared = memoryOnly
        return memoryOnly
    }

    /// Deletes every stored response, from memory and disk. (Both calls:
    /// `removeAllCachedResponses()` alone has been unreliable for the disk
    /// store on some iOS versions.)
    static func purge(_ cache: URLCache = .shared) {
        cache.removeAllCachedResponses()
        cache.removeCachedResponses(since: .distantPast)
    }
}
