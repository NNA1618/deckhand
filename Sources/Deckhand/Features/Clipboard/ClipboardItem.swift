import Foundation

enum ClipboardKind: String, Codable {
    case text, image, file
}

struct ClipboardItem: Identifiable, Hashable {
    let id: Int64
    let kind: ClipboardKind
    let text: String?
    let imagePath: String?
    let fileURL: String?
    let hash: String
    var pinned: Bool
    let sourceApp: String?
    let sourceAppName: String?
    let createdAt: Date
    var lastUsedAt: Date

    var preview: String {
        switch kind {
        case .text:
            let s = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return s.prefix(140).description
        case .image:
            return String(localized: "Image")
        case .file:
            if let f = fileURL, let url = URL(string: f) {
                return url.lastPathComponent
            }
            return String(localized: "File")
        }
    }

    var longPreview: String {
        text ?? preview
    }
}
