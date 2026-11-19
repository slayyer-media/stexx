import Foundation
import Testing
import UIKit
@testable import Stexx

/// Counts requests per stub host.
private actor RequestCounter {
    private(set) var count = 0
    func hit() { count += 1 }
}

/// Profile photos: no disk cache anywhere, memory-only copies, cleared with
/// the session.
@Suite("Profile photos: no disk cache")
struct ProfilePhotoLoaderTests {
    private let jpeg = MediaFixtures.jpeg

    private func stub(
        status: Int = 200,
        body: Data? = nil,
        counter: RequestCounter = RequestCounter(),
        gate: Gate? = nil
    ) -> (URL, RequestCounter) {
        let body = body ?? jpeg
        let base = StubURLProtocol.register { _ in
            await counter.hit()
            if let gate { await gate.wait() }
            // What media.stexx.gay sends: cacheable for a year.
            return (status, ["Content-Type": "image/jpeg", "Cache-Control": "private, max-age=31536000, immutable"], body)
        }
        return (base, counter)
    }

    @Test("Profile photos are fetched through the private session, which has no URL cache")
    func privateSession() {
        let loader = ProfilePhotoLoader.shared
        #expect(loader.session === PrivateMedia.session)
        #expect(loader.session.configuration.urlCache == nil)
        #expect(loader.session.configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("The memory cache is bounded by count and by decoded size")
    func bounded() throws {
        let loader = ProfilePhotoLoader.shared
        #expect(loader.countLimit > 0)
        #expect(loader.totalCostLimit > 0)
        #expect(loader.totalCostLimit <= 128 * 1024 * 1024)
        let image = try #require(UIImage(data: jpeg))
        #expect(ProfilePhotoLoader.cost(of: image) >= 12 * 9 * 4)
    }

    @Test("A loaded photo is kept in memory and not downloaded again")
    func cachesInMemory() async throws {
        let (base, counter) = stub()
        let loader = ProfilePhotoLoader(session: StubURLProtocol.session())
        let url = base.appending(path: "p.jpg")

        #expect(loader.cached(url) == nil)
        #expect(await loader.image(for: url) != nil)
        #expect(loader.cached(url) != nil)
        #expect(await loader.image(for: url) != nil)
        #expect(await counter.count == 1)
    }

    @Test("Concurrent requests for one photo share one download")
    func sharesDownload() async throws {
        let gate = Gate()
        let (base, counter) = stub(gate: gate)
        let loader = ProfilePhotoLoader(session: StubURLProtocol.session())
        let url = base.appending(path: "p.jpg")

        let loads = (0..<5).map { _ in Task { await loader.image(for: url) } }
        while await counter.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        await gate.open()
        for load in loads { #expect(await load.value != nil) }
        #expect(await counter.count == 1)
    }

    @Test("Errors and non-images give no photo and aren't cached")
    func failures() async throws {
        let loader = ProfilePhotoLoader(session: StubURLProtocol.session())
        let (missing, misses) = stub(status: 404)
        let (garbage, _) = stub(body: Data("not an image".utf8))
        let gone = missing.appending(path: "p.jpg")
        let broken = garbage.appending(path: "p.jpg")

        #expect(await loader.image(for: gone) == nil)
        #expect(await loader.image(for: broken) == nil)
        #expect(loader.cached(gone) == nil)
        #expect(loader.cached(broken) == nil)
        // A failure isn't remembered either: the next request tries again.
        _ = await loader.image(for: gone)
        #expect(await misses.count == 2)
    }

    @Test("clear() drops every photo, and a load running during it isn't cached")
    func clearDuringLoad() async throws {
        let (done, _) = stub()
        let gate = Gate()
        let (slow, counter) = stub(gate: gate)
        let loader = ProfilePhotoLoader(session: StubURLProtocol.session())
        let cachedURL = done.appending(path: "a.jpg")
        let slowURL = slow.appending(path: "b.jpg")

        _ = await loader.image(for: cachedURL)
        #expect(loader.cached(cachedURL) != nil)

        let load = Task { await loader.image(for: slowURL) }
        while await counter.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        loader.clear()
        await gate.open()

        #expect(await load.value != nil)
        #expect(loader.cached(cachedURL) == nil)
        #expect(loader.cached(slowURL) == nil)
    }

    @Test("evict(_:) drops one photo")
    func evict() async throws {
        let (base, _) = stub()
        let loader = ProfilePhotoLoader(session: StubURLProtocol.session())
        let a = base.appending(path: "a.jpg")
        let b = base.appending(path: "b.jpg")
        _ = await loader.image(for: a)
        _ = await loader.image(for: b)
        loader.evict(a)
        #expect(loader.cached(a) == nil)
        #expect(loader.cached(b) != nil)
    }
}

@Suite("Shared URL cache hygiene")
struct SharedURLCacheHygieneTests {
    @Test("At launch the shared URL cache was replaced by one that never writes to disk")
    func launchInstallsMemoryOnlyCache() {
        // The test host is the app, so `StexxApp.init` already ran.
        #expect(URLCache.shared.diskCapacity == 0)
        #expect(URLCache.shared.memoryCapacity <= SharedURLCacheHygiene.memoryCapacity)
    }

    @Test("purge deletes responses an earlier build stored on disk")
    func purgeDeletesStoredResponses() async throws {
        let directory = URL.temporaryDirectory.appending(path: "stexx-urlcache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = URLCache(memoryCapacity: 0, diskCapacity: 10 * 1024 * 1024, directory: directory)
        let url = URL(string: "https://media.example.test/\(UUID().uuidString).jpg")!
        let request = URLRequest(url: url)
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Cache-Control": "private, max-age=31536000, immutable", "Content-Type": "image/jpeg"]
        )!
        // Disk only (no memory capacity), like a response from a past launch.
        legacy.storeCachedResponse(CachedURLResponse(response: response, data: MediaFixtures.jpeg), for: request)
        #expect(try await eventually { legacy.cachedResponse(for: request) != nil })

        SharedURLCacheHygiene.purge(legacy)
        #expect(try await eventually { legacy.cachedResponse(for: request) == nil })
    }

    /// URLCache writes and deletes on its own queue.
    private func eventually(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test("No view loads images with AsyncImage (it writes to the shared URL cache)")
    func noAsyncImageInAppSources() throws {
        let sources = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Stexx")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var swiftFiles = 0
        var offenders: [String] = []
        for case let file as URL in files where file.pathExtension == "swift" {
            swiftFiles += 1
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") {
                let code = line.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                // `PrivateAsyncImage(` is the allowed drop-in; bare `AsyncImage(` is not.
                if code.replacingOccurrences(of: "PrivateAsyncImage(", with: "").contains("AsyncImage(") {
                    offenders.append(file.lastPathComponent)
                }
            }
        }
        #expect(swiftFiles > 20)
        #expect(offenders.isEmpty, "AsyncImage in: \(offenders)")
    }
}

@MainActor
@Suite("Profile photos: session teardown")
struct ProfilePhotoTeardownTests {
    @Test("Signing out drops every profile photo kept in memory")
    func signOutClears() async throws {
        let base = StubURLProtocol.register { _ in (200, [:], MediaFixtures.jpeg) }
        let loader = ProfilePhotoLoader(session: StubURLProtocol.session())
        let url = base.appending(path: "p.jpg")
        _ = await loader.image(for: url)
        #expect(loader.cached(url) != nil)

        let api = MockAPIClient(latency: .zero)
        let appState = AppState(
            defaults: UserDefaults(suiteName: "stexx.tests.\(UUID().uuidString)")!,
            sessionStore: InMemorySessionStore()
        )
        let services = AppServices(
            appState: appState,
            chatStore: ChatStore(api: api, defaults: UserDefaults(suiteName: "stexx.tests.\(UUID().uuidString)")!),
            purchases: PurchaseService(api: api, appState: appState),
            location: nil,
            realtime: nil,
            profilePhotos: loader
        )
        services.update(isSignedIn: true, isForeground: false)
        #expect(loader.cached(url) != nil)
        services.update(isSignedIn: false, isForeground: false)
        #expect(loader.cached(url) == nil)
    }

    @Test("Saving the editor without a photo drops that photo from memory")
    func deletedOwnPhotoEvicted() async throws {
        let api = MockAPIClient(latency: .zero)
        let a = try await api.uploadPhoto(jpegData: MediaFixtures.jpeg)
        let b = try await api.uploadPhoto(jpegData: MediaFixtures.jpeg)
        let loader = ProfilePhotoLoader()
        let urlA = try #require(a.url)
        let urlB = try #require(b.url)
        // The mock keeps uploads as files; the loader reads file URLs too.
        #expect(await loader.image(for: urlA) != nil)
        #expect(await loader.image(for: urlB) != nil)

        let sync = ProfilePhotoSync(photos: [a, b], loader: loader)
        _ = try await sync.apply([b], using: api)
        #expect(loader.cached(urlA) == nil)
        #expect(loader.cached(urlB) != nil)
    }
}
