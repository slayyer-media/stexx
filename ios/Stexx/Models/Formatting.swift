import Foundation

enum StexxFormat {
    /// Coarse, locale-aware distance like "300 m", "1.2 km" or "0.7 mi".
    /// Values are rounded to 100 m so the UI never implies more precision
    /// than the server provides.
    static func distance(_ meters: Double) -> String {
        let rounded = max(100, (meters / 100).rounded() * 100)
        return Measurement(value: rounded, unit: UnitLength.meters).formatted(
            .measurement(
                width: .abbreviated,
                usage: .road,
                numberFormatStyle: FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...1))
            )
        )
    }

    static func height(cm: Int) -> String {
        Measurement(value: Double(cm), unit: UnitLength.centimeters).formatted(
            .measurement(width: .abbreviated, usage: .personHeight)
        )
    }

    /// "Online", "5 min. ago", "Yesterday"...
    static func lastSeen(_ date: Date?, isOnline: Bool) -> String {
        if isOnline { return String(localized: "Online now") }
        guard let date else { return String(localized: "Offline") }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    /// Time for today, weekday within a week, short date otherwise.
    static func chatTimestamp(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
