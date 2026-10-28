import AppKit
import UniformTypeIdentifiers

/// Recent images and videos from watched folders (Downloads by default) plus a prompt
/// helper powered by Claude. Handy for generations downloaded from Higgsfield and similar tools.
struct MediaFile: Identifiable, Hashable {
    let url: URL
    let modified: Date
    let isVideo: Bool
    var id: String { url.path }
}

@MainActor
final class RecentsViewModel: ObservableObject {
    @Published var recent: [MediaFile] = []
    @Published var prompt = ""
    @Published var improving = false
    @Published var error: String?

    func scan() {
        let folders = Settings.shared.watchedFolders.map { URL(fileURLWithPath: $0) }
        Task.detached(priority: .utility) {
            let files = Self.collect(folders)
            await MainActor.run { self.recent = files }
        }
    }

    nonisolated private static func collect(_ folders: [URL]) -> [MediaFile] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        var out: [MediaFile] = []
        for folder in folders {
            guard let walker = fm.enumerator(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey, .contentTypeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in walker {
                if walker.level > 6 { walker.skipDescendants(); continue }
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .contentTypeKey]),
                      let type = values.contentType,
                      let date = values.contentModificationDate,
                      date > cutoff else { continue }
                let video = type.conforms(to: .movie)
                guard video || type.conforms(to: .image) else { continue }
                out.append(MediaFile(url: url, modified: date, isVideo: video))
            }
        }
        return Array(out.sorted { $0.modified > $1.modified }.prefix(40))
    }

    func loadPromptFromClipboard() {
        if prompt.isEmpty, let s = NSPasteboard.general.string(forType: .string) {
            prompt = s
        }
    }

    func improve() {
        guard !prompt.isEmpty, let preset = Presets.byId("improve-prompt") else { return }
        improving = true
        error = nil
        let input = prompt
        Task { @MainActor in
            do {
                prompt = try await ClaudeAPI.shared.complete(
                    system: preset.system,
                    messages: [.init(role: .user, content: input)],
                    model: preset.preferredModel
                )
            } catch {
                self.error = error.localizedDescription
            }
            improving = false
        }
    }

    func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }
}
