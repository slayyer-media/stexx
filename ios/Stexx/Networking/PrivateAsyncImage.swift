import SwiftUI
import UIKit

/// Network access for private media (chat photos).
enum PrivateMedia {
    /// No disk cache, no memory cache: chat photos (expiring ones
    /// especially) must not outlive their deletion on the server as a copy
    /// in `Library/Caches`. `AsyncImage` uses `URLSession.shared`, whose
    /// default `URLCache` persists responses the media host marks cacheable.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()
}

/// A drop-in for `AsyncImage(url:content:placeholder:)` that loads through
/// `PrivateMedia.session`, so the image only ever lives in memory while the
/// view is on screen.
struct PrivateAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL
    private let session: URLSession
    private let content: (Image) -> Content
    private let placeholder: () -> Placeholder

    @State private var image: UIImage?

    init(
        url: URL,
        session: URLSession = PrivateMedia.session,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.session = session
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            image = nil
            guard let (data, response) = try? await session.data(from: url) else { return }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return }
            guard let decoded = UIImage(data: data) else { return }
            image = await decoded.byPreparingForDisplay() ?? decoded
        }
    }
}
