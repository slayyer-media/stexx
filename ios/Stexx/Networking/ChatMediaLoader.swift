import UIKit

/// Downloads, verifies and decrypts end-to-end encrypted chat photos
/// (`E2EMediaCrypto`). Plaintext photos keep using `PrivateAsyncImage`,
/// except view-once ones (`plaintextPhoto`).
///
/// - Downloads go through `PrivateMedia.session` (ephemeral, no disk cache):
///   the blob is opaque anyway, but nothing from a chat lands in
///   `Library/Caches`.
/// - Decrypted images live in memory only, in a small cache keyed by message
///   ID, so scrolling doesn't download and decrypt again. Cleared on sign-out
///   (`clear()`) and when a key is forgotten (`evict(_:)`, from `E2EEngine`);
///   a load still running then doesn't cache its result.
/// - A download longer than any blob is cut off, not buffered.
/// - Never logs keys, URLs or image data.
actor ChatMediaLoader {
    static let shared = ChatMediaLoader()

    /// What loading a photo came to.
    enum Outcome: Equatable, Sendable {
        /// Decrypted and decoded, with the on-device check's verdict
        /// (`.unknown` when it wasn't asked for or couldn't run).
        case image(UIImage, ChatPhotoVerdict)
        /// The server no longer has it (404 / 410): expired or spent.
        case gone
        /// Not the blob the sender pointed to, or it didn't decrypt.
        case tampered
        /// Decrypted, but not an image this phone can show.
        case unreadable
        /// A network or server error; trying again may work.
        case failed
    }

    enum LoadError: Error, Equatable {
        case gone
        case failed
    }

    private final class Entry {
        let image: UIImage
        let verdict: ChatPhotoVerdict
        init(image: UIImage, verdict: ChatPhotoVerdict) {
            self.image = image
            self.verdict = verdict
        }
    }

    private let session: URLSession
    private let cache = NSCache<NSString, Entry>()
    /// Bumped by `clear()`: a load that started before returns its image
    /// but doesn't cache it.
    private var generation = 0
    /// Loads running, by message ID, and those evicted meanwhile (not cached).
    private var loading: [Message.ID: Int] = [:]
    private var evictedWhileLoading: Set<Message.ID> = []

    init(session: URLSession = PrivateMedia.session, countLimit: Int = 40, totalCostLimit: Int = 96 * 1024 * 1024) {
        self.session = session
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    /// A photo already decrypted in this session, if it's still cached.
    func cached(_ messageID: Message.ID) -> Outcome? {
        cache.object(forKey: messageID as NSString).map { .image($0.image, $0.verdict) }
    }

    /// Downloads, verifies, decrypts and decodes the photo of `messageID`.
    ///
    /// - Parameters:
    ///   - analyzer: Checks the decrypted image on device (incoming photos);
    ///     `nil` skips it (own photos).
    ///   - caches: `false` for view-once photos, which must not outlive the viewer.
    func photo(
        messageID: Message.ID,
        url: URL,
        pointer: E2EAttachmentPointer,
        analyzer: (any ChatPhotoAnalyzer)? = nil,
        caches: Bool = true
    ) async -> Outcome {
        if caches, let cached = cached(messageID) { return cached }
        let generation = self.generation
        loading[messageID, default: 0] += 1
        defer { finishLoading(messageID) }
        let jpeg: Data
        do {
            jpeg = try await decrypted(url: url, pointer: pointer)
        } catch LoadError.gone {
            return .gone
        } catch is E2EMediaCrypto.Failure {
            return .tampered
        } catch {
            return .failed
        }
        guard let decoded = UIImage(data: jpeg) else { return .unreadable }
        let image = await decoded.byPreparingForDisplay() ?? decoded
        var verdict = ChatPhotoVerdict.unknown
        if let analyzer, let cgImage = decoded.cgImage {
            verdict = await analyzer.assess(cgImage)
        }
        // Not after a sign-out or a forgotten key meanwhile, nor for a viewer that went away.
        if caches, generation == self.generation, !evictedWhileLoading.contains(messageID), !Task.isCancelled {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(Entry(image: image, verdict: verdict), forKey: messageID as NSString, cost: cost)
        }
        return .image(image, verdict)
    }

    /// A plaintext view-once photo (not end-to-end encrypted): downloaded
    /// through the same private session, decoded and checked on device like
    /// an encrypted one, and never cached.
    func plaintextPhoto(url: URL, analyzer: (any ChatPhotoAnalyzer)? = nil) async -> Outcome {
        let data: Data
        do {
            data = try await download(url)
        } catch LoadError.gone {
            return .gone
        } catch is E2EMediaCrypto.Failure {
            return .unreadable
        } catch {
            return .failed
        }
        guard let decoded = UIImage(data: data) else { return .unreadable }
        let image = await decoded.byPreparingForDisplay() ?? decoded
        var verdict = ChatPhotoVerdict.unknown
        if let analyzer, let cgImage = decoded.cgImage {
            verdict = await analyzer.assess(cgImage)
        }
        return .image(image, verdict)
    }

    /// The decrypted JPEG bytes (for report evidence). Throws `LoadError`
    /// or `E2EMediaCrypto.Failure`.
    func decrypted(url: URL, pointer: E2EAttachmentPointer) async throws -> Data {
        try E2EMediaCrypto.decrypt(blob: try await download(url), pointer: pointer)
    }

    /// The blob, read as it streams in: a body longer than any blob can be
    /// (`E2EMediaCrypto.maxBlobLength`) is refused as soon as that's clear
    /// (`Failure.malformed`), never buffered whole.
    private nonisolated func download(_ url: URL) async throws -> Data {
        let limit = E2EMediaCrypto.maxBlobLength
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(from: url)
        } catch {
            throw LoadError.failed
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 || http.statusCode == 410 {
                bytes.task.cancel()
                throw LoadError.gone
            }
            guard (200..<300).contains(http.statusCode) else {
                bytes.task.cancel()
                throw LoadError.failed
            }
        }
        guard response.expectedContentLength <= limit else {
            bytes.task.cancel()
            throw E2EMediaCrypto.Failure.malformed
        }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit {
                    bytes.task.cancel()
                    throw E2EMediaCrypto.Failure.malformed
                }
            }
        } catch let failure as E2EMediaCrypto.Failure {
            throw failure
        } catch {
            throw LoadError.failed
        }
        return data
    }

    private func finishLoading(_ messageID: Message.ID) {
        let remaining = (loading[messageID] ?? 1) - 1
        loading[messageID] = remaining > 0 ? remaining : nil
        if remaining <= 0 { evictedWhileLoading.remove(messageID) }
    }

    /// The key for this photo was forgotten: drop the decrypted copy too
    /// (and don't cache one that's still loading).
    func evict(_ messageID: Message.ID) {
        cache.removeObject(forKey: messageID as NSString)
        if loading[messageID] != nil { evictedWhileLoading.insert(messageID) }
    }

    /// Signed out: drop every decrypted photo (and any still loading).
    func clear() {
        cache.removeAllObjects()
        generation += 1
    }
}
