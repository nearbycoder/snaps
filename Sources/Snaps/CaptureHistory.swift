import AppKit
import ImageIO

struct CaptureItem: Codable, Identifiable, Hashable {
    let id: UUID
    var url: URL
    let date: Date
    /// Image size in points, used to lay out thumbnails before they load.
    let width: Double
    let height: Double

    var aspectRatio: Double { height > 0 ? width / height : 1 }
}

/// Recent captures shown in the gallery, newest first. Persisted to Application Support.
@MainActor
final class CaptureHistory: ObservableObject {
    static let shared = CaptureHistory()

    @Published private(set) var items: [CaptureItem] = []

    private let limit = 60
    private let storeURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("dev.nearby.Snaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: storeURL),
           let decoded = try? JSONDecoder().decode([CaptureItem].self, from: data) {
            items = decoded
        }
        pruneMissing()
    }

    @discardableResult
    func add(url: URL, size: NSSize) -> CaptureItem {
        let item = CaptureItem(id: UUID(), url: url, date: Date(), width: size.width, height: size.height)
        items.insert(item, at: 0)
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
        save()
        return item
    }

    func contains(_ url: URL) -> Bool {
        items.contains { $0.url == url }
    }

    /// Keeps the history pointing at a capture after it's been saved somewhere else.
    func updateURL(from old: URL, to new: URL) {
        guard let index = items.firstIndex(where: { $0.url == old }) else { return }
        items[index].url = new
        save()
    }

    /// Removes an item; the file is deleted only if it was never saved out of the cache.
    func remove(_ item: CaptureItem) {
        items.removeAll { $0.id == item.id }
        if CaptureStorage.isInCache(item.url) {
            try? FileManager.default.removeItem(at: item.url)
        }
        Thumbnails.evict(item.url)
        save()
    }

    func clear() {
        for item in items { remove(item) }
    }

    func pruneMissing() {
        let existing = items.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        if existing.count != items.count {
            items = existing
            save()
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}

/// Small, cached thumbnails decoded off the main thread.
enum Thumbnails {
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 120
        return cache
    }()

    static func cached(_ url: URL) -> NSImage? {
        cache.object(forKey: url as NSURL)
    }

    static func evict(_ url: URL) {
        cache.removeObject(forKey: url as NSURL)
    }

    static func load(_ url: URL, maxPixelSize: Int = 520) async -> NSImage? {
        if let cached = cached(url) { return cached }
        let image = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
        }.value
        if let image { cache.setObject(image, forKey: url as NSURL) }
        return image
    }
}
