import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Encoding, naming and writing captured and edited images. Pure functions, safe off the main thread.
enum ImageExport {
    enum Failure: LocalizedError {
        case encode
        case folderMissing(String)

        var errorDescription: String? {
            switch self {
            case .encode: return String(localized: "The image could not be encoded.")
            case .folderMissing(let path): return String(localized: "The folder “\(path)” doesn’t exist.")
            }
        }
    }

    /// Encodes in the image's own color space (Display P3 stays P3) and records the pixel
    /// density, so a Retina capture opens at its real size.
    static func encode(_ image: CGImage, as format: CaptureFormat, pixelScale: CGFloat) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else { throw Failure.encode }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72 * pixelScale,
            kCGImagePropertyDPIHeight: 72 * pixelScale,
        ]
        if format != .png { props[kCGImageDestinationLossyCompressionQuality] = 0.9 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.encode }
        return data as Data
    }

    /// Re-encodes an image file's data, e.g. the PNG from `screencapture` as JPEG or HEIC.
    static func convert(_ data: Data, to format: CaptureFormat) throws -> Data {
        if format == .png { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.encode }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (props?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        return try encode(image, as: format, pixelScale: dpi / 72)
    }

    /// "Screenshot 2026-11-05 at 14.03.22", like macOS names its own screenshots.
    static func baseName(date: Date = Date()) -> String {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HH.mm.ss"
        return String(localized: "Screenshot \(day.string(from: date)) at \(time.string(from: date))")
    }

    /// A file URL in `folder` that doesn't exist yet: "Name.png", "Name 2.png", …
    static func uniqueURL(in folder: URL, baseName: String, fileExtension: String,
                          exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        var url = folder.appendingPathComponent(baseName).appendingPathExtension(fileExtension)
        var n = 2
        while exists(url) {
            url = folder.appendingPathComponent("\(baseName) \(n)").appendingPathExtension(fileExtension)
            n += 1
        }
        return url
    }

    /// Writes into `folder` under a fresh name and returns the file.
    static func save(_ data: Data, in folder: URL, format: CaptureFormat) throws -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
            throw Failure.folderMissing(folder.path)
        }
        let url = uniqueURL(in: folder, baseName: baseName(), fileExtension: format.fileExtension)
        try data.write(to: url, options: .withoutOverwriting)
        return url
    }

    /// PNG on the clipboard instead of an uncompressed TIFF (a 5K capture is ~59 MB as TIFF).
    @MainActor
    static func copyPNG(_ png: Data) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(png, forType: .png)
    }
}
