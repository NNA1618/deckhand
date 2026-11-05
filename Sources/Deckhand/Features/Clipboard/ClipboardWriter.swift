import AppKit

/// Puts a history item back on a pasteboard.
///
/// The content is gathered and checked first; the pasteboard is cleared only when there is
/// something to write, so a missing image or a moved file never wipes what the user had copied.
@MainActor
enum ClipboardWriter {
    enum Failure: Error, Equatable {
        case missingImage, missingFiles, missingText

        var message: String {
            switch self {
            case .missingImage: return String(localized: "The image file is missing.")
            case .missingFiles: return String(localized: "The file no longer exists.")
            case .missingText: return String(localized: "This item can't be read.")
            }
        }
    }

    /// Writes the item; `plain` drops formatting. Returns the new change count on success.
    static func write(_ item: ClipboardItem, store: ClipboardStore, to pb: NSPasteboard,
                      plain: Bool = false) -> Result<Int, Failure> {
        let own = NSPasteboard.PasteboardType(ClipboardCapture.ownType)
        switch item.kind {
        case .text:
            guard let text = store.text(id: item.id) else { return .failure(.missingText) }
            let pbItem = NSPasteboardItem()
            pbItem.setString(text, forType: .string)
            if !plain, let rich = store.richText(id: item.id) {
                pbItem.setData(rich.data, forType: NSPasteboard.PasteboardType(rich.type))
            }
            pbItem.setString("", forType: own)
            pb.clearContents()
            pb.writeObjects([pbItem])

        case .link:
            guard let link = store.text(id: item.id) else { return .failure(.missingText) }
            // The plain-text flavor makes Terminal, Slack and code editors paste the address too
            let pbItem = NSPasteboardItem()
            pbItem.setString(link, forType: .string)
            if !plain { pbItem.setString(link, forType: .URL) }
            pbItem.setString("", forType: own)
            pb.clearContents()
            pb.writeObjects([pbItem])

        case .image:
            guard let url = store.imageURL(for: item), let png = try? Data(contentsOf: url) else {
                return .failure(.missingImage)
            }
            writeImage(png, to: pb)

        case .file:
            return writeFiles(existingFiles(item.fileURLs), to: pb)
        }
        return .success(pb.changeCount)
    }

    /// The same as `write`, with the file work (reading an image, checking that files still exist)
    /// done off the main thread, so a slow or stale drive can't freeze the panel. The pasteboard is
    /// written on the main thread once everything has been read.
    static func writeAsync(_ item: ClipboardItem, store: ClipboardStore, to pb: NSPasteboard,
                           plain: Bool = false) async -> Result<Int, Failure> {
        switch item.kind {
        case .text, .link:
            return write(item, store: store, to: pb, plain: plain)
        case .image:
            guard let url = store.imageURL(for: item),
                  let png = await Task.detached(priority: .userInitiated, operation: { try? Data(contentsOf: url) }).value
            else { return .failure(.missingImage) }
            writeImage(png, to: pb)
            return .success(pb.changeCount)
        case .file:
            let urls = item.fileURLs
            let existing = await Task.detached(priority: .userInitiated, operation: { existingFiles(urls) }).value
            return writeFiles(existing, to: pb)
        }
    }

    nonisolated private static func existingFiles(_ urls: [URL]) -> [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func writeImage(_ png: Data, to pb: NSPasteboard) {
        let pbItem = NSPasteboardItem()
        pbItem.setData(png, forType: .png)
        // TIFF for older apps, made only if someone asks for it
        let provider = TIFFProvider(png: png)
        pbItem.setDataProvider(provider, forTypes: [.tiff])
        TIFFProvider.current = provider
        pbItem.setString("", forType: NSPasteboard.PasteboardType(ClipboardCapture.ownType))
        pb.clearContents()
        pb.writeObjects([pbItem])
    }

    private static func writeFiles(_ existing: [URL], to pb: NSPasteboard) -> Result<Int, Failure> {
        guard !existing.isEmpty else { return .failure(.missingFiles) }
        let own = NSPasteboard.PasteboardType(ClipboardCapture.ownType)
        pb.clearContents()
        pb.writeObjects(existing as [NSURL])
        pb.addTypes([own], owner: nil)
        pb.setString("", forType: own)
        return .success(pb.changeCount)
    }

    /// Converts the PNG to TIFF lazily, on the first request for TIFF.
    private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
        /// The pasteboard doesn't retain its providers; keep the latest one alive.
        nonisolated(unsafe) static var current: TIFFProvider?
        let png: Data
        init(png: Data) { self.png = png }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            guard type == .tiff, let rep = NSBitmapImageRep(data: png), let tiff = rep.tiffRepresentation else { return }
            item.setData(tiff, forType: .tiff)
        }
    }
}
