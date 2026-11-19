import CryptoKit
import Foundation

/// Decrypted chat text (and the keys of encrypted photos) kept on this
/// device. A ratchet message decrypts only once and the server only ever has
/// ciphertext, so this is the only copy of the plaintext; the sender can't
/// decrypt its own envelopes either, so sent text is kept here too, by
/// client ID.
///
/// A photo's key (`Entry.attachment`) is kept only while the photo can still
/// exist on the server: an expiring message's entry goes at `expiresAt`, a key
/// whose expiry this device can't learn goes at `attachmentKeyUntil` (the
/// server's cap plus the timer, which the recipient learns from the
/// envelope), and a view-once photo's key goes as soon as it has been opened
/// here. `E2EEngine` prunes on load, on foreground and while revealing.
///
/// Stored as one AES-256-GCM sealed file per account in Application Support,
/// excluded from backups, with `completeUntilFirstUserAuthentication` file
/// protection. The 256-bit file key lives in the Keychain next to the Signal
/// keys (this device only), so a copied file or an old backup is unreadable
/// and deleting the account's keys makes the history unreadable too.
///
/// Also keeps the user's own sends of the last 24 hours (normalized text and
/// conversation) for the duplicate-message rule (`E2EContentRules`); nothing
/// about them goes to the server.
struct E2EHistory: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        var conversationID: Conversation.ID
        /// `nil` for content this version can't show.
        var text: String?
        var storedAt: Date
        /// The server deletes the message then; so does this store.
        var expiresAt: Date?
        /// The encrypted photo's pointer (key and digest) while it can still
        /// be shown.
        var attachment: E2EAttachmentPointer? = nil
        /// When this phone opened the view-once photo (its key is gone).
        var viewOnceOpenedAt: Date? = nil
        /// The key is dropped then, when the server will have deleted the
        /// photo but this device may never see the message's `expiresAt`
        /// (the recipient's read receipts are off, a view-once photo).
        var attachmentKeyUntil: Date? = nil
        /// The entry once had a photo key (now dropped): the photo is gone,
        /// not merely unavailable on this phone.
        var hadAttachment: Bool? = nil
        /// A received message's timer, from the envelope
        /// (`E2EPayload.expiresAfterSeconds`): `expiresAt` is stamped from
        /// it when the user reads the conversation (`E2EEngine.didMarkRead`).
        var expiresAfterSeconds: Int? = nil

        init(
            conversationID: Conversation.ID,
            text: String?,
            storedAt: Date,
            expiresAt: Date? = nil,
            attachment: E2EAttachmentPointer? = nil,
            attachmentKeyUntil: Date? = nil,
            expiresAfterSeconds: Int? = nil
        ) {
            self.conversationID = conversationID
            self.text = text
            self.storedAt = storedAt
            self.expiresAt = expiresAt
            self.attachment = attachment
            self.attachmentKeyUntil = attachment == nil ? nil : attachmentKeyUntil
            self.hadAttachment = attachment == nil ? nil : true
            self.expiresAfterSeconds = expiresAfterSeconds
        }

        /// Drops the photo key, keeping the text.
        mutating func dropAttachment(openedAt: Date? = nil) {
            attachment = nil
            attachmentKeyUntil = nil
            if let openedAt, viewOnceOpenedAt == nil { viewOnceOpenedAt = openedAt }
        }

        mutating func pruneAttachment(now: Date) {
            if attachment != nil, let until = attachmentKeyUntil, until <= now { dropAttachment() }
        }
    }

    struct Send: Codable, Sendable, Equatable {
        var conversationID: Conversation.ID
        var normalized: String
        var sentAt: Date
    }

    /// Received and sent messages, by server message ID.
    var messages: [Message.ID: Entry] = [:]
    /// Own sent text by client ID, from before the server assigned an ID.
    var sent: [String: Entry] = [:]
    var recentSends: [Send] = []

    static let maxEntries = 50_000

    /// How long the server keeps a photo whose expiry never started (unread
    /// expiring messages, unopened view-once photos).
    static let serverPhotoCap: TimeInterval = 14 * 24 * 3600
    /// Margin on top of the server's caps (its jobs run periodically, and a
    /// view-once photo stays for a grace window after it was opened).
    static let attachmentKeyMargin: TimeInterval = 24 * 3600

    /// Drops expired messages (photo keys included), photo keys past
    /// `attachmentKeyUntil`, sends older than a day, and the oldest entries
    /// beyond `maxEntries`.
    mutating func prune(now: Date) {
        messages = messages.filter { ($0.value.expiresAt ?? .distantFuture) > now }
        sent = sent.filter { ($0.value.expiresAt ?? .distantFuture) > now && $0.value.storedAt > now.addingTimeInterval(-30 * 24 * 3600) }
        for id in messages.keys where messages[id]?.attachmentKeyUntil != nil { messages[id]?.pruneAttachment(now: now) }
        for id in sent.keys where sent[id]?.attachmentKeyUntil != nil { sent[id]?.pruneAttachment(now: now) }
        recentSends.removeAll { $0.sentAt < now.addingTimeInterval(-24 * 3600) }
        if messages.count > Self.maxEntries {
            let keep = messages.sorted { $0.value.storedAt > $1.value.storedAt }.prefix(Self.maxEntries)
            messages = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }
}

/// Where `E2EHistory` is persisted.
protocol E2EHistoryPersistence: Sendable {
    /// `nil` when there's nothing to read (no file, or no key: a reinstall).
    /// Throws when a history exists but can't be read right now.
    func load(userID: Profile.ID) throws -> E2EHistory?
    func save(_ history: E2EHistory, userID: Profile.ID) throws
    func delete(userID: Profile.ID) throws
    /// Moves an unreadable history out of the way (kept, not deleted) so a
    /// new one can be written without destroying it.
    func setAside(userID: Profile.ID) throws
}

final class InMemoryHistoryPersistence: E2EHistoryPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var histories: [Profile.ID: E2EHistory] = [:]

    init() {}

    func load(userID: Profile.ID) throws -> E2EHistory? {
        try lock.withLock {
            if failLoads { throw CocoaError(.fileReadCorruptFile) }
            return histories[userID]
        }
    }
    func save(_ history: E2EHistory, userID: Profile.ID) throws { lock.withLock { histories[userID] = history } }
    func delete(userID: Profile.ID) throws { lock.withLock { histories[userID] = nil } }
    func setAside(userID: Profile.ID) throws { try delete(userID: userID) }
    /// Tests: make the next loads fail.
    var failLoads = false
}

/// The app's persistence: an encrypted file per account.
final class EncryptedFileHistoryPersistence: E2EHistoryPersistence, @unchecked Sendable {
    private let directory: URL
    private let secrets: any E2ESecretStorage

    init(secrets: any E2ESecretStorage, directory: URL? = nil) {
        self.secrets = secrets
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "E2E", directoryHint: .isDirectory)
    }

    /// The file name doesn't reveal the account id.
    private func fileURL(_ userID: Profile.ID) -> URL {
        let digest = SHA256.hash(data: Data("stexx-e2e-history|\(userID)".utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(name).history")
    }

    private func keyName(_ userID: Profile.ID) -> String { E2EProtocolStore.prefix(for: userID) + "history-key" }

    private func existingKey(_ userID: Profile.ID) throws -> SymmetricKey? {
        try secrets.read(keyName(userID)).map { SymmetricKey(data: $0) }
    }

    func load(userID: Profile.ID) throws -> E2EHistory? {
        let url = fileURL(userID)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        // No key (a reinstall that kept the file, or a wiped Keychain): the
        // file is unreadable by design. Start over.
        guard let key = try existingKey(userID) else { return nil }
        let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: url))
        let data = try AES.GCM.open(sealed, using: key)
        return try JSONDecoder().decode(E2EHistory.self, from: data)
    }

    func save(_ history: E2EHistory, userID: Profile.ID) throws {
        let key: SymmetricKey
        if let existing = try existingKey(userID) {
            key = existing
        } else {
            key = SymmetricKey(size: .bits256)
            try secrets.write(key.withUnsafeBytes { Data($0) }, for: keyName(userID))
        }
        let data = try JSONEncoder().encode(history)
        guard let sealed = try AES.GCM.seal(data, using: key).combined else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var dir = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        let url = fileURL(userID)
        try sealed.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func delete(userID: Profile.ID) throws {
        let url = fileURL(userID)
        for file in [url, url.appendingPathExtension("unreadable")]
        where FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: file)
        }
        try secrets.delete(keyName(userID))
    }

    func setAside(userID: Profile.ID) throws {
        let url = fileURL(userID)
        let aside = url.appendingPathExtension("unreadable")
        if FileManager.default.fileExists(atPath: aside.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: aside)
        }
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.moveItem(at: url, to: aside)
        }
    }
}
