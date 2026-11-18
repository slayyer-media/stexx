import Foundation

enum StexxFormat {
    /// Coarse, locale-aware distance like "300 m", "1.2 km" or "0.7 mi".
    /// Never implies more precision than the server's buckets: metric rounds
    /// to 100 m (then 0.1 km), imperial uses miles to one decimal. (Formatting
    /// with `usage: .road` turned a 500 m bucket into "1,640.4 ft".)
    static func distance(_ meters: Double, locale: Locale = .current) -> String {
        let number = FloatingPointFormatStyle<Double>.number.locale(locale)
        let style: (Int) -> Measurement<UnitLength>.FormatStyle = { digits in
            .measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: number.precision(.fractionLength(0...digits)))
                .locale(locale)
        }
        if locale.measurementSystem == .metric {
            let rounded = max(100, (meters / 100).rounded() * 100)
            if rounded < 1000 {
                return Measurement(value: rounded, unit: UnitLength.meters).formatted(style(0))
            }
            return Measurement(value: rounded / 1000, unit: UnitLength.kilometers).formatted(style(1))
        }
        let exact = meters / 1609.344
        let miles = exact < 10 ? max(0.1, (exact * 10).rounded() / 10) : exact.rounded()
        return Measurement(value: miles, unit: UnitLength.miles).formatted(style(miles < 10 ? 1 : 0))
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
