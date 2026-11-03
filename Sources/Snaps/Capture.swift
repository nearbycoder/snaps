import AppKit

/// What to capture, as picked on the overlay or implied by the mode.
enum CaptureTarget {
    /// A region in AppKit global coordinates (bottom-left origin), in points.
    case area(CGRect)
    /// One window on its own: transparent outside its shape, with or without its shadow.
    case window(CGWindowID)
}

/// Wraps the system `screencapture` tool. Snaps draws its own picker; this only takes the shot.
@MainActor
enum ScreenCapturer {
    static func capture(_ target: CaptureTarget, settings: AppSettings) async -> URL? {
        let url = CaptureStorage.newCaptureURL()

        var arguments: [String] = []
        if !settings.playSound { arguments.append("-x") }

        switch target {
        case .area(let rect):
            arguments += ["-R", quartzRect(rect)]
        case .window(let id):
            if !settings.includeWindowShadow { arguments.append("-o") }
            arguments += ["-l", String(id)]
        }
        arguments.append(url.path)

        await run("/usr/sbin/screencapture", arguments)

        // No file means the capture failed (e.g. the window closed meanwhile).
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// `rect` in the top-left-origin global coordinates `screencapture -R` expects.
    private static func quartzRect(_ rect: CGRect) -> String {
        let rect = rect.integral
        let top = (NSScreen.screens.first?.frame.maxY ?? rect.maxY) - rect.maxY
        return "\(Int(rect.minX)),\(Int(top)),\(Int(rect.width)),\(Int(rect.height))"
    }

    private static func run(_ path: String, _ arguments: [String]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                NSLog("Snaps: failed to launch screencapture: \(error)")
                continuation.resume()
            }
        }
    }
}

enum CaptureStorage {
    /// Captures live here until saved; the preview drags this file.
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("dev.nearby.Snaps/Captures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The full-quality videos GIF recordings are made from, kept so a GIF can be trimmed and remade later.
    static var recordingSourcesDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("dev.nearby.Snaps/Recording Sources", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func newCaptureURL(_ kind: CaptureKind = .image) -> URL {
        let prefix = kind == .image ? "Snap" : "Snap Recording"
        return uniqueURL(in: cacheDirectory, baseName: fileBaseName(for: Date(), prefix: prefix), pathExtension: kind.pathExtension)
    }

    static func newRecordingSourceURL() -> URL {
        recordingSourcesDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
    }

    /// A scratch file for writing a result before it replaces `target`, on the same volume so the swap works.
    static func temporaryURL(pathExtension: String, replacing target: URL? = nil) -> URL {
        let directory = target.flatMap {
            try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: $0, create: true)
        } ?? cacheDirectory
        return directory.appendingPathComponent(".\(UUID().uuidString)").appendingPathExtension(pathExtension)
    }

    static func isInCache(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(cacheDirectory.standardizedFileURL.path)
    }

    /// Copies a capture into `folder`, returning the new location.
    static func save(_ url: URL, into folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let baseName = url.deletingPathExtension().lastPathComponent
        let destination = uniqueURL(in: folder, baseName: baseName, pathExtension: url.pathExtension)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// Removes cached (unsaved) captures and GIF sources older than a week.
    static func pruneCache(olderThan age: TimeInterval = 7 * 24 * 60 * 60) {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-age)
        for directory in [cacheDirectory, recordingSourcesDirectory] {
            guard let files = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey]
            ) else { continue }
            for file in files {
                let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                if created < cutoff { try? fm.removeItem(at: file) }
            }
        }
    }

    private static func fileBaseName(for date: Date, prefix: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: date))"
    }

    private static func uniqueURL(in folder: URL, baseName: String, pathExtension: String) -> URL {
        var candidate = folder.appendingPathComponent(baseName).appendingPathExtension(pathExtension)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(baseName) (\(index))").appendingPathExtension(pathExtension)
            index += 1
        }
        return candidate
    }
}

enum Clipboard {
    /// Copies whatever kind of capture lives at `url`. Returns false if it couldn't be read.
    @discardableResult
    static func copy(contentsOf url: URL) -> Bool {
        switch CaptureKind(url) {
        case .image:
            guard let image = NSImage(contentsOf: url) else { return false }
            copy(image: image, pngURL: url)
        case .video, .gif:
            guard FileManager.default.fileExists(atPath: url.path) else { return false }
            copy(fileAt: url)
        }
        return true
    }

    /// Puts a recording on the pasteboard as a file, so it pastes into Finder, Slack, Mail and so on.
    /// GIFs also carry their data, so apps that take images paste them inline and animated.
    static func copy(fileAt url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        if CaptureKind(url) == .gif, let data = try? Data(contentsOf: url) {
            item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
        }
        pasteboard.writeObjects([item])
    }

    /// Puts the image on the general pasteboard as PNG, with TIFF provided lazily for older apps.
    static func copy(image: NSImage, pngURL: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        if let png = try? Data(contentsOf: pngURL) {
            item.setData(png, forType: .png)
        }
        item.setDataProvider(TIFFProvider.shared.retaining(image), forTypes: [.tiff])
        pasteboard.writeObjects([item])
    }

    private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
        static let shared = TIFFProvider()
        private var image: NSImage?

        func retaining(_ image: NSImage) -> TIFFProvider {
            self.image = image
            return self
        }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            if let tiff = image?.tiffRepresentation {
                item.setData(tiff, forType: type)
            }
        }

        func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
            image = nil
        }
    }
}

extension NSScreen {
    static var underMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }
}
