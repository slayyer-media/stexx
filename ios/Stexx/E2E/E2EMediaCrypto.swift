import CryptoKit
import Foundation
import ImageIO

/// What the recipient needs to fetch and decrypt an end-to-end encrypted
/// photo. It only ever travels inside the Signal envelope (`E2EPayload`),
/// never in a field the server can read; the blob's URL comes from the
/// server's `message.attachment.url`.
///
/// Wire format v1 (`docs/api.md`, "Encrypted photos"): `key` and `digest` are
/// standard base64 with padding (32 bytes each), `size` is the unpadded JPEG
/// length, `width`/`height` are a layout hint only. Unknown fields are
/// ignored; a `v` or `kind` this version doesn't know makes the photo
/// unsupported (`isSupported`), not an error.
struct E2EAttachmentPointer: Codable, Hashable, Sendable {
    static let currentVersion = 1
    static let photoKind = "photo"

    var v: Int = Self.currentVersion
    var kind: String = Self.photoKind
    var contentType: String = "image/jpeg"
    /// AES-256 key, base64.
    var key: String
    /// SHA-256 of the whole blob, base64.
    var digest: String
    /// The JPEG's length before padding.
    var size: Int
    var width: Int?
    var height: Int?

    /// Whether this version can fetch and show it.
    var isSupported: Bool { v == Self.currentVersion && kind == Self.photoKind }

    init(key: String, digest: String, size: Int, width: Int? = nil, height: Int? = nil) {
        self.key = key
        self.digest = digest
        self.size = size
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey {
        case v, kind, contentType, key, digest, size, width, height
    }

    /// Lenient on purpose: a pointer from a newer version may lack fields this
    /// one expects. It still decodes (and shows as unsupported) instead of
    /// making the whole envelope unreadable.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        v = (try? container.decodeIfPresent(Int.self, forKey: .v)) ?? Self.currentVersion
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? Self.photoKind
        contentType = (try? container.decodeIfPresent(String.self, forKey: .contentType)) ?? "image/jpeg"
        key = (try? container.decodeIfPresent(String.self, forKey: .key)) ?? ""
        digest = (try? container.decodeIfPresent(String.self, forKey: .digest)) ?? ""
        size = (try? container.decodeIfPresent(Int.self, forKey: .size)) ?? -1
        width = try? container.decodeIfPresent(Int.self, forKey: .width)
        height = try? container.decodeIfPresent(Int.self, forKey: .height)
    }
}

/// Encrypts and decrypts chat photos for end-to-end encrypted chats.
///
/// Blob = `nonce(12) ‖ AES-256-GCM(padded JPEG) ‖ tag(16)` (CryptoKit's
/// `SealedBox.combined`), with a fresh random key per photo. The JPEG is
/// zero-padded to Signal's attachment size buckets (`paddedLength`) so the
/// server can't read the exact size. The pointer's SHA-256 `digest` pins
/// exactly one blob: GCM alone isn't key-committing, and the digest travels
/// inside the authenticated envelope, so the server can't swap blobs.
///
/// Never logs keys or plaintext.
enum E2EMediaCrypto {
    enum Failure: Error, Equatable {
        /// Bad sizes, base64 or version.
        case malformed
        /// The blob isn't the one the sender pointed to.
        case digestMismatch
        /// The digest matched but the blob didn't open with the key.
        case decryptFailed
    }

    static let keyLength = 32
    static let nonceLength = 12
    static let tagLength = 16
    /// The server's upload limit, plus the GCM overhead.
    static let maxBlobLength = 10 * 1024 * 1024 + 64

    /// Signal's attachment padding: `max(541, floor(1.05 ^ ceil(log(n) / log(1.05))))`.
    /// Only the sender computes it; the receiver strips by `size`.
    static func paddedLength(_ n: Int) -> Int {
        guard n > 0 else { return 541 }
        let bucket = floor(pow(1.05, ceil(log(Double(n)) / log(1.05))))
        return max(541, Int(bucket))
    }

    /// Encrypts a (sanitized) JPEG with a fresh key and nonce.
    static func encrypt(jpeg: Data, width: Int? = nil, height: Int? = nil) throws -> (blob: Data, pointer: E2EAttachmentPointer) {
        try encrypt(jpeg: jpeg, width: width, height: height, key: SymmetricKey(size: .bits256), nonce: AES.GCM.Nonce())
    }

    /// Tests: a fixed key and nonce (the shared test vector).
    static func encrypt(
        jpeg: Data,
        width: Int?,
        height: Int?,
        key: SymmetricKey,
        nonce: AES.GCM.Nonce
    ) throws -> (blob: Data, pointer: E2EAttachmentPointer) {
        guard !jpeg.isEmpty, key.bitCount == keyLength * 8 else { throw Failure.malformed }
        var padded = jpeg
        padded.append(Data(count: paddedLength(jpeg.count) - jpeg.count))
        guard let blob = try AES.GCM.seal(padded, using: key, nonce: nonce).combined,
              blob.count <= maxBlobLength
        else { throw Failure.malformed }
        let pointer = E2EAttachmentPointer(
            key: key.withUnsafeBytes { Data($0) }.base64EncodedString(),
            digest: Data(SHA256.hash(data: blob)).base64EncodedString(),
            size: jpeg.count,
            width: width,
            height: height
        )
        return (blob, pointer)
    }

    /// Checks the digest (before anything else touches the blob), opens it
    /// and strips the padding. Returns the JPEG bytes.
    static func decrypt(blob: Data, pointer: E2EAttachmentPointer) throws -> Data {
        guard pointer.isSupported,
              let key = Data(base64Encoded: pointer.key), key.count == keyLength,
              let digest = Data(base64Encoded: pointer.digest), digest.count == SHA256.byteCount,
              pointer.size >= 0,
              blob.count > nonceLength + tagLength, blob.count <= maxBlobLength
        else { throw Failure.malformed }
        guard constantTimeEqual(Data(SHA256.hash(data: blob)), digest) else { throw Failure.digestMismatch }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: SymmetricKey(data: key))
        } catch {
            throw Failure.decryptFailed
        }
        guard pointer.size <= plaintext.count else { throw Failure.malformed }
        return plaintext.prefix(pointer.size)
    }

    /// Compares every byte, whatever differs first.
    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
        return difference == 0
    }

    /// Pixel size of an image, read from its header (no decode).
    static func pixelSize(of image: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }
}
