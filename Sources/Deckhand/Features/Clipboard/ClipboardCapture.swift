import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// What the watcher copied off the pasteboard, ready to be processed away from the main thread.
struct PasteboardSnapshot: Sendable {
    var types: Set<String> = []
    var string: String?
    var fileURLs: [URL] = []
    /// `public.url` without a plain-text flavor, e.g. a link dragged from some browsers.
    var urlString: String?
    var richType: String?
    var richData: Data?
    var imageData: Data?
    var imageType: String?
    var sourceApp: String?
    var sourceAppName: String?
    var isSecret = false
}

/// A processed copy, ready to be inserted into the store.
struct ClipboardEntry: Sendable {
    var kind: ClipboardKind
    var text: String?
    var preview: String
    var searchText: String
    var richType: String?
    var richData: Data?
    /// The PNG already written into the images folder.
    var imageName: String?
    var fileURLs: [URL] = []
    var hash: String
    var isSecret = false
    var sourceApp: String?
    var sourceAppName: String?
}

/// Decides what a copy is and turns it into a history entry.
enum ClipboardCapture {
    /// Image flavors worth keeping, in order of preference. PDF alone is the last resort.
    static let imageTypes: [String] = [
        NSPasteboard.PasteboardType.png.rawValue,
        NSPasteboard.PasteboardType.tiff.rawValue,
        UTType.jpeg.identifier,
        UTType.heic.identifier,
        "NeXT TIFF v4.0 pasteboard type",
    ]
    static let pdfType = NSPasteboard.PasteboardType.pdf.rawValue
    static let rtfType = NSPasteboard.PasteboardType.rtf.rawValue
    static let htmlType = NSPasteboard.PasteboardType.html.rawValue
    /// Marks Deckhand's own writes so they are credited to Deckhand, not to the app in front.
    static let ownType = "com.nna1618.deckhand.clipboard"

    /// What kind of item a copy becomes, or nil when there is nothing worth saving.
    ///
    /// - Files win: Finder copies carry the file URLs, never their contents.
    /// - Text beats an image when both exist: Excel, Numbers and Keynote put a picture of the cells
    ///   next to the text, and the text is what people mean.
    /// - The exception is an image with only a link as text, as Safari's "Copy Image" writes.
    static func classify(types: Set<String>, string: String?, fileURLs: [URL], urlString: String?) -> ClipboardKind? {
        if !fileURLs.isEmpty { return .file }
        let hasBitmap = imageTypes.contains(where: types.contains)
        let hasImage = hasBitmap || types.contains(pdfType)
        let text = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            if ClipboardText.isLink(text) { return hasBitmap ? .image : .link }
            return .text
        }
        if hasImage { return .image }
        if let urlString, ClipboardText.isLink(urlString) { return .link }
        return nil
    }

    /// Hashing, previews, image encoding and the image file write: everything slow happens here,
    /// off the main thread.
    static func prepare(_ snap: PasteboardSnapshot, imagesDir: URL, maxImageBytes: Int) -> ClipboardEntry? {
        guard let kind = classify(types: snap.types, string: snap.string, fileURLs: snap.fileURLs, urlString: snap.urlString)
        else { return nil }
        switch kind {
        case .file:
            let urls = snap.fileURLs
            return ClipboardEntry(
                kind: .file, text: nil, preview: ClipboardText.fileTitle(urls),
                searchText: ClipboardText.searchText(text: urls.map(\.path).joined(separator: "\n"), fileURLs: urls,
                                                     appName: snap.sourceAppName),
                fileURLs: urls, hash: hash(kind, urls.map(\.absoluteString).joined(separator: "\n")),
                sourceApp: snap.sourceApp, sourceAppName: snap.sourceAppName)
        case .link, .text:
            let raw = snap.string ?? snap.urlString ?? ""
            let text = kind == .link ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : raw
            guard text.utf8.count <= ClipboardText.maxTextBytes else { return nil }
            let rich = kind == .text && (snap.richData?.count ?? .max) <= ClipboardText.maxRichBytes
            return ClipboardEntry(
                kind: kind, text: text, preview: ClipboardText.preview(text),
                searchText: snap.isSecret ? "" : ClipboardText.searchText(text: text, fileURLs: [], appName: snap.sourceAppName),
                richType: rich ? snap.richType : nil, richData: rich ? snap.richData : nil,
                hash: hash(kind, text), isSecret: snap.isSecret,
                sourceApp: snap.sourceApp, sourceAppName: snap.sourceAppName)
        case .image:
            guard let data = snap.imageData, let png = pngData(data, type: snap.imageType ?? ""),
                  maxImageBytes <= 0 || png.data.count <= maxImageBytes else { return nil }
            let digest = hash(.image, png.data)
            let name = "img-\(digest.prefix(32)).png"
            let url = imagesDir.appendingPathComponent(name)
            // Same content, same name: a repeated copy finds its file already there
            if !FileManager.default.fileExists(atPath: url.path) {
                do { try png.data.write(to: url, options: .atomic) } catch {
                    Log.info("clipboard: cannot save image: \(error)")
                    return nil
                }
            }
            return ClipboardEntry(
                kind: .image, text: nil, preview: "\(png.width) × \(png.height)",
                searchText: ClipboardText.searchText(text: nil, fileURLs: [], appName: snap.sourceAppName),
                imageName: name, hash: digest,
                sourceApp: snap.sourceApp, sourceAppName: snap.sourceAppName)
        }
    }

    /// PNG bytes and pixel size. PNG input is kept as it is; anything else is re-encoded once.
    static func pngData(_ data: Data, type: String) -> (data: Data, width: Int, height: Int)? {
        if type == pdfType { return renderPDF(data) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        if type == NSPasteboard.PasteboardType.png.rawValue { return (data, width, height) }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return encodePNG(image).map { ($0, image.width, image.height) }
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// The first page of a PDF-only copy, at 2× scale.
    private static func renderPDF(_ data: Data) -> (data: Data, width: Int, height: Int)? {
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider),
              let page = pdf.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        let scale: CGFloat = 2
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard width > 0, height > 0, width * height < 100_000_000,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage(), let png = encodePNG(image) else { return nil }
        return (png, width, height)
    }

    static func hash(_ kind: ClipboardKind, _ text: String) -> String {
        hash(kind, Data(text.utf8))
    }

    static func hash(_ kind: ClipboardKind, _ data: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
