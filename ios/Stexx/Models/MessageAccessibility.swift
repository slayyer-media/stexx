import Foundation

/// What VoiceOver reads for a chat bubble: who sent it, what it is (text,
/// or the kind of photo and its timer), when, and for my own messages the
/// delivery status. One element per bubble, so swiping through a thread
/// reads one message at a time.
enum MessageAccessibility {
    /// What a photo bubble shows, as far as the bubble knows.
    enum PhotoState: Hashable, Sendable {
        case visible
        /// Incoming photo blurred until tapped.
        case hidden
        case viewOnceClosed
        case viewOnceOpened
        case gone
        /// An encrypted photo this phone can't show (no key, or failed).
        case unavailable
    }

    static func label(
        for message: Message,
        isMine: Bool,
        senderName: String,
        photo: PhotoState? = nil,
        placeholder: String? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> String {
        var parts: [String] = [isMine ? String(localized: "You") : senderName]
        if message.attachment != nil {
            parts.append(photoDescription(message, state: photo ?? .visible))
            if let expiresAt = message.expiresAt, expiresAt > now {
                let relative = expiresAt.formatted(.relative(presentation: .named, unitsStyle: .wide))
                parts.append(String(localized: "disappears \(relative)"))
            }
        }
        if let text = message.text, !text.isEmpty {
            parts.append(text)
        } else if let placeholder {
            parts.append(placeholder)
        }
        parts.append(time(message.sentAt, now: now, calendar: calendar))
        if isMine { parts.append(status(message.status)) }
        return parts.joined(separator: ", ")
    }

    static func photoDescription(_ message: Message, state: PhotoState) -> String {
        let isViewOnce = message.attachment?.isViewOnce == true
        switch state {
        case .viewOnceOpened:
            return String(localized: "View-once photo, opened")
        case .viewOnceClosed:
            return String(localized: "View-once photo, not opened")
        case .gone:
            return isViewOnce
                ? String(localized: "View-once photo, no longer available")
                : String(localized: "Photo, no longer available")
        case .unavailable:
            return String(localized: "Encrypted photo, not available on this phone")
        case .hidden:
            return String(localized: "Photo, hidden until you tap it")
        case .visible:
            return isViewOnce ? String(localized: "View-once photo") : String(localized: "Photo")
        }
    }

    /// "14:32" today, "Monday 14:32" this week, "3 Nov, 14:32" before that.
    static func time(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide).hour().minute())
        }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    static func status(_ status: Message.Status) -> String {
        switch status {
        case .sending: String(localized: "Sending")
        case .sent: String(localized: "Sent")
        case .delivered: String(localized: "Delivered")
        case .read: String(localized: "Read")
        case .failed: String(localized: "Send failed")
        }
    }
}
