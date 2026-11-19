import SwiftUI
import UIKit

/// "Download my data" (Settings › Privacy): the server's data export
/// (`GET /me/export`) as a JSON file handed to the share sheet.
///
/// The file only exists while the share sheet is open: it's written to its
/// own folder under the app's temporary directory (never backed up), with
/// complete file protection (unreadable while the phone is locked), and the
/// whole export folder is deleted when the sheet closes. Anything left behind
/// by a crash goes on the next launch or the next export.
struct DataExportFile: Identifiable, Equatable, Sendable {
    let url: URL
    var id: URL { url }

    static let defaultDirectory = URL.temporaryDirectory.appending(path: "DataExport", directoryHint: .isDirectory)

    /// Writes `data` (pretty-printed when it's JSON) as
    /// `stexx-data-YYYY-MM-DD.json`, replacing any earlier export.
    static func write(_ data: Data, in directory: URL = defaultDirectory, now: Date = .now) throws -> DataExportFile {
        removeAll(in: directory)
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        let url = folder.appending(path: fileName(now: now))
        try readable(data).write(to: url, options: [.atomic, .completeFileProtection])
        return DataExportFile(url: url)
    }

    /// Deletes every export (the share sheet closed, or a launch after a crash).
    static func removeAll(in directory: URL = defaultDirectory) {
        try? FileManager.default.removeItem(at: directory)
    }

    static func fileName(now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let day = calendar.dateComponents([.year, .month, .day], from: now)
        return String(format: "stexx-data-%04d-%02d-%02d.json", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }

    /// Indented JSON, easier to read in a text editor. Anything that isn't
    /// JSON is kept as it came.
    private static func readable(_ data: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
        else { return data }
        return pretty
    }
}

/// The system share sheet for a file (Save to Files, AirDrop, …).
/// `onComplete` runs when it finishes or is cancelled.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    var onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
