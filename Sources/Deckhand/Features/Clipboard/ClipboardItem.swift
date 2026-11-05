import Foundation

enum ClipboardKind: String, Codable, Sendable {
    case text, image, file, link
}

/// One row of the history as the list shows it. The full text is loaded only when it is needed
/// (copy, paste, preview), so the list stays light with thousands of long items.
struct ClipboardItem: Identifiable, Hashable, Sendable {
    let id: Int64
    let kind: ClipboardKind
    /// Short single-line text for the row: the start of the text, the link, the file names,
    /// or the pixel size of an image ("1920 × 1080").
    let preview: String
    /// Image file name inside the clipboard images folder.
    let imageName: String?
    let fileURLs: [URL]
    var pinned: Bool
    let isSecret: Bool
    let hasRichText: Bool
    let sourceApp: String?
    let sourceAppName: String?
    let createdAt: Date
    /// Last time it was copied or pasted; the list is sorted by it.
    var lastUsedAt: Date

    /// The row title.
    var title: String {
        if isSecret { return "••••••••" }
        switch kind {
        case .text, .link: return preview
        case .image: return String(localized: "Image")
        case .file: return ClipboardText.fileTitle(fileURLs)
        }
    }
}

/// The filter chips above the list.
enum ClipboardFilter: String, CaseIterable, Identifiable, Sendable {
    case all, text, images, files, links
    var id: String { rawValue }

    var kind: ClipboardKind? {
        switch self {
        case .all: return nil
        case .text: return .text
        case .images: return .image
        case .files: return .file
        case .links: return .link
        }
    }

    var symbol: String {
        switch self {
        case .all: return "tray.full"
        case .text: return "text.alignleft"
        case .images: return "photo"
        case .files: return "doc"
        case .links: return "link"
        }
    }

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .text: return String(localized: "Text")
        case .images: return String(localized: "Images")
        case .files: return String(localized: "Files")
        case .links: return String(localized: "Links")
        }
    }
}

/// Pure text helpers for the history: previews, search folding and link detection.
enum ClipboardText {
    /// Longest text kept in the history. Bigger copies still paste normally; they just aren't saved.
    static let maxTextBytes = 5 * 1024 * 1024
    /// Longest rich text (RTF or HTML) kept next to the plain text.
    static let maxRichBytes = 2 * 1024 * 1024
    /// How much of a long text the search covers.
    static let searchPrefix = 50_000

    /// The start of the text on one line, whitespace runs collapsed.
    static func preview(_ text: String, length: Int = 300) -> String {
        var out = ""
        var lastWasSpace = false
        for ch in text.prefix(length * 2) {
            if ch.isWhitespace || ch.isNewline {
                if !lastWasSpace && !out.isEmpty { out.append(" ") }
                lastWasSpace = true
            } else {
                out.append(ch)
                lastWasSpace = false
            }
            if out.count >= length { break }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Case- and accent-insensitive form used for searching, the same for every language
    /// (SQLite's own LIKE only folds ASCII, so "Москва" never matched "москва").
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// The folded text the search column holds: content, file names and the source app.
    static func searchText(text: String?, fileURLs: [URL], appName: String?) -> String {
        var parts: [String] = []
        if let text { parts.append(String(text.prefix(searchPrefix))) }
        for url in fileURLs { parts.append(url.lastPathComponent) }
        if let appName { parts.append(appName) }
        return fold(parts.joined(separator: "\n"))
    }

    /// LIKE patterns for a query: every word must appear somewhere. `%`, `_` and `\` match themselves.
    static func likePatterns(for query: String) -> [String] {
        fold(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map { "%" + escapeLike(String($0)) + "%" }
    }

    static func escapeLike(_ s: String) -> String {
        var out = ""
        for ch in s {
            if ch == "\\" || ch == "%" || ch == "_" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// A single web or mail address with nothing around it. Plain words, paths and
    /// multi-line text stay text.
    static func isLink(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 4096, !t.contains(where: { $0.isWhitespace }),
              let url = URL(string: t), let scheme = url.scheme?.lowercased() else { return false }
        switch scheme {
        case "http", "https", "ftp": return !(url.host ?? "").isEmpty
        case "mailto": return t.count > "mailto:".count
        default: return false
        }
    }

    /// "report.pdf", or "report.pdf + 3" for several files (no plural forms needed).
    static func fileTitle(_ urls: [URL]) -> String {
        guard let first = urls.first else { return String(localized: "File") }
        let name = first.lastPathComponent.isEmpty ? first.path : first.lastPathComponent
        return urls.count > 1 ? "\(name) + \(urls.count - 1)" : name
    }
}
