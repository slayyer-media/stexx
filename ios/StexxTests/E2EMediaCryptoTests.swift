import CryptoKit
import Foundation
import Testing
@testable import Stexx

/// Encrypted chat photos, format v1 (`docs/api.md`, "Encrypted photos"):
/// padding, the blob layout, the digest and the pointer.
@Suite("E2E media crypto")
struct E2EMediaCryptoTests {
    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private static func bytes(_ count: Int, seed: UInt8 = 1) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    @Test("Padded lengths follow Signal's buckets, with a 541-byte floor")
    func paddedLengths() {
        #expect(E2EMediaCrypto.paddedLength(18) == 541)
        #expect(E2EMediaCrypto.paddedLength(1000) == 1020)
        #expect(E2EMediaCrypto.paddedLength(123_456) == 127_826)
        #expect(E2EMediaCrypto.paddedLength(2_000_000) == 2_062_581)
        #expect(E2EMediaCrypto.paddedLength(1) == 541)
        #expect(E2EMediaCrypto.paddedLength(541) == 541)
        // Never shorter than the input.
        for n in [1, 540, 541, 542, 999, 1020, 1021, 65_536, 1_000_001] {
            #expect(E2EMediaCrypto.paddedLength(n) >= n)
        }
    }

    @Test("Round trip at several sizes: nonce ‖ padded ciphertext ‖ tag, digest of the blob", arguments: [1, 18, 540, 541, 542, 1000, 4096, 123_456])
    func roundTrip(size: Int) throws {
        let jpeg = Self.bytes(size, seed: UInt8(size % 251))
        let (blob, pointer) = try E2EMediaCrypto.encrypt(jpeg: jpeg, width: 30, height: 40)
        #expect(blob.count == 12 + E2EMediaCrypto.paddedLength(size) + 16)
        #expect(pointer.v == 1)
        #expect(pointer.kind == "photo")
        #expect(pointer.contentType == "image/jpeg")
        #expect(pointer.size == size)
        #expect(pointer.width == 30 && pointer.height == 40)
        #expect(Data(base64Encoded: pointer.key)?.count == 32)
        #expect(Data(base64Encoded: pointer.digest) == Data(SHA256.hash(data: blob)))
        #expect(try E2EMediaCrypto.decrypt(blob: blob, pointer: pointer) == jpeg)
    }

    @Test("Every photo gets a fresh key and nonce")
    func freshKeys() throws {
        let jpeg = Self.bytes(2000)
        let first = try E2EMediaCrypto.encrypt(jpeg: jpeg)
        let second = try E2EMediaCrypto.encrypt(jpeg: jpeg)
        #expect(first.pointer.key != second.pointer.key)
        #expect(first.blob.prefix(12) != second.blob.prefix(12))
        #expect(first.blob != second.blob)
    }

    @Test("The shared test vector (same as the server's) reproduces byte for byte")
    func sharedVector() throws {
        let key = SymmetricKey(data: Data(0x00...0x1f))
        let nonce = try AES.GCM.Nonce(data: Data(0xa0...0xab))
        let jpeg = Data("stexx test vector\n".utf8)
        #expect(jpeg.count == 18)
        let (blob, pointer) = try E2EMediaCrypto.encrypt(jpeg: jpeg, width: nil, height: nil, key: key, nonce: nonce)
        #expect(blob.count == 569)
        #expect(blob.prefix(12) == Data(0xa0...0xab))
        #expect(Self.hex(blob.suffix(16)) == "953d10b94b7a7edd4a31a942daabd37c")
        #expect(pointer.key == "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=")
        #expect(pointer.digest == "VBo3z+JaRs9V/mLtyUXXPSOqXDPvkgVK6bgBRBgxPx0=")
        #expect(pointer.size == 18)
        #expect(try E2EMediaCrypto.decrypt(blob: blob, pointer: pointer) == jpeg)
    }

    @Test("A changed blob fails the digest check before anything is decrypted")
    func tamperedBlob() throws {
        let (blob, pointer) = try E2EMediaCrypto.encrypt(jpeg: Self.bytes(3000))
        for index in [0, 20, blob.count / 2, blob.count - 1] {
            var tampered = blob
            tampered[index] ^= 0x01
            #expect(throws: E2EMediaCrypto.Failure.digestMismatch) { try E2EMediaCrypto.decrypt(blob: tampered, pointer: pointer) }
        }
        // Another valid blob (a server swapping photos between messages) fails too.
        let other = try E2EMediaCrypto.encrypt(jpeg: Self.bytes(3000)).blob
        #expect(throws: E2EMediaCrypto.Failure.digestMismatch) { try E2EMediaCrypto.decrypt(blob: other, pointer: pointer) }
    }

    @Test("A changed digest in the pointer is a mismatch")
    func tamperedDigest() throws {
        let (blob, original) = try E2EMediaCrypto.encrypt(jpeg: Self.bytes(800))
        var pointer = original
        pointer.digest = Data(SHA256.hash(data: Data("something else".utf8))).base64EncodedString()
        #expect(throws: E2EMediaCrypto.Failure.digestMismatch) { try E2EMediaCrypto.decrypt(blob: blob, pointer: pointer) }
    }

    @Test("The wrong key with the right digest fails to decrypt")
    func wrongKey() throws {
        let (blob, original) = try E2EMediaCrypto.encrypt(jpeg: Self.bytes(800))
        var pointer = original
        pointer.key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64EncodedString()
        #expect(throws: E2EMediaCrypto.Failure.decryptFailed) { try E2EMediaCrypto.decrypt(blob: blob, pointer: pointer) }
    }

    @Test("Malformed pointers and blobs are refused")
    func malformed() throws {
        let (blob, pointer) = try E2EMediaCrypto.encrypt(jpeg: Self.bytes(800))
        var cases: [(E2EAttachmentPointer, Data)] = []
        var bad = pointer
        bad.key = "not base64!"
        cases.append((bad, blob))
        bad = pointer
        bad.key = Data(count: 16).base64EncodedString()
        cases.append((bad, blob))
        bad = pointer
        bad.digest = Data(count: 31).base64EncodedString()
        cases.append((bad, blob))
        bad = pointer
        bad.v = 2
        cases.append((bad, blob))
        bad = pointer
        bad.kind = "video"
        cases.append((bad, blob))
        bad = pointer
        bad.size = -1
        cases.append((bad, blob))
        // Longer than the padded plaintext.
        bad = pointer
        bad.size = E2EMediaCrypto.paddedLength(800) + 1
        cases.append((bad, blob))
        // Nonce and tag only (28 bytes): nothing in it.
        cases.append((pointer, blob.prefix(28)))
        for (candidate, data) in cases {
            #expect(throws: E2EMediaCrypto.Failure.malformed) { try E2EMediaCrypto.decrypt(blob: data, pointer: candidate) }
        }
        #expect(throws: E2EMediaCrypto.Failure.malformed) { try E2EMediaCrypto.encrypt(jpeg: Data()) }
    }

    @Test("Constant-time compare: equal only for identical bytes")
    func constantTimeEqual() {
        #expect(E2EMediaCrypto.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 3])))
        #expect(!E2EMediaCrypto.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 4])))
        #expect(!E2EMediaCrypto.constantTimeEqual(Data([1, 2, 3]), Data([1, 2])))
    }

    @Test("The pointer has the documented JSON shape inside the envelope payload")
    func pointerJSON() throws {
        let pointer = E2EAttachmentPointer(key: "a2V5", digest: "ZGlnZXN0", size: 123_456, width: 1536, height: 2048)
        let payload = E2EPayload(text: "caption", attachment: pointer)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        #expect(json["text"] as? String == "caption")
        let attachment = try #require(json["attachment"] as? [String: Any])
        #expect(Set(attachment.keys) == ["v", "kind", "contentType", "key", "digest", "size", "width", "height"])
        #expect(attachment["v"] as? Int == 1)
        #expect(attachment["kind"] as? String == "photo")
        #expect(attachment["contentType"] as? String == "image/jpeg")
        #expect(attachment["size"] as? Int == 123_456)

        // A text-only payload has no attachment key; an old payload decodes.
        let textOnly = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(E2EPayload(text: "hi"))) as? [String: Any])
        #expect(Set(textOnly.keys) == ["text"])
        #expect(try JSONDecoder().decode(E2EPayload.self, from: Data(#"{"text":"hi"}"#.utf8)) == E2EPayload(text: "hi"))
    }

    @Test("A pointer from a newer version decodes (unknown fields ignored) but is unsupported")
    func futurePointer() throws {
        let json = #"{"attachment":{"v":2,"kind":"photo","key":"a2V5","digest":"ZGlnZXN0","size":5,"thumbnail":"x"}}"#
        let payload = try JSONDecoder().decode(E2EPayload.self, from: Data(json.utf8))
        let pointer = try #require(payload.attachment)
        #expect(!pointer.isSupported)
        let video = try JSONDecoder().decode(E2EAttachmentPointer.self, from: Data(#"{"v":1,"kind":"video","key":"a","digest":"b","size":1}"#.utf8))
        #expect(!video.isSupported)
        let current = try JSONDecoder().decode(E2EAttachmentPointer.self, from: Data(#"{"v":1,"kind":"photo","key":"a","digest":"b","size":1,"extra":true}"#.utf8))
        #expect(current.isSupported)
        #expect(current.width == nil)
    }
}
