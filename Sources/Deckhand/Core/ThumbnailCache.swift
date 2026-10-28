import AppKit
import ImageIO

/// Small downscaled previews for clipboard rows, decoded once and kept in memory.
enum ThumbnailCache {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {   // NSCache is thread-safe
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300
        return c
    }()

    static func image(at path: String, maxPixels: Int = 160) -> NSImage? {
        let key = "\(path)#\(maxPixels)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        cache.setObject(image, forKey: key)
        return image
    }
}
