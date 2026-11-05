import Foundation
import CoreServices
import UniformTypeIdentifiers

/// Which files Recents shows.
enum RecentsKinds: String, CaseIterable, Identifiable, Sendable {
    case all, images, videos
    var id: String { rawValue }
}

struct MediaFile: Identifiable, Hashable, Sendable {
    let url: URL
    /// When the file landed in its folder (date added, else created, else modified).
    let date: Date
    let isVideo: Bool
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

/// A watched folder Recents can't use.
struct FolderProblem: Hashable, Sendable {
    enum Kind: Sendable { case noAccess, missing }
    let path: String
    let kind: Kind
}

/// What to look for.
struct RecentsQuery: Equatable, Sendable {
    var folders: [URL]
    var days: Int
    var kinds: RecentsKinds
    var includeSubfolders: Bool
    var limit: Int
}

struct RecentsScan: Sendable {
    var files: [MediaFile]
    var problems: [FolderProblem]
}

/// Finds recent images and videos. Runs off the main thread and stops early when cancelled.
enum RecentsScanner {
    /// Deep or huge folders (a project checkout in Downloads) stop the walk here.
    static let maxDepth = 6
    static let maxEntries = 30_000

    private static let keys: [URLResourceKey] = [
        .addedToDirectoryDateKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey, .isRegularFileKey,
    ]

    static func scan(_ query: RecentsQuery, now: Date = Date()) -> RecentsScan {
        let cutoff = now.addingTimeInterval(-Double(query.days) * 24 * 3600)
        var files: [MediaFile] = []
        var problems: [FolderProblem] = []
        let fm = FileManager.default
        for folder in query.folders {
            if Task.isCancelled { break }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
                problems.append(FolderProblem(path: folder.path, kind: .missing))
                continue
            }
            // Reading the top level tells "no access" apart from "nothing new"
            let top: [URL]
            do {
                top = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            } catch {
                problems.append(FolderProblem(path: folder.path, kind: isPermissionError(error) ? .noAccess : .missing))
                continue
            }
            if query.includeSubfolders {
                guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: keys,
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                var seen = 0
                for case let url as URL in walker {
                    seen += 1
                    if seen > maxEntries || Task.isCancelled { break }
                    if walker.level > maxDepth || url.lastPathComponent == "node_modules" {
                        walker.skipDescendants()
                        continue
                    }
                    if let file = media(at: url, query: query, cutoff: cutoff) { files.append(file) }
                }
            } else {
                files += top.compactMap { media(at: $0, query: query, cutoff: cutoff) }
            }
        }
        let sorted = files.sorted { $0.date == $1.date ? $0.url.path < $1.url.path : $0.date > $1.date }
        return RecentsScan(files: Array(sorted.prefix(query.limit)), problems: problems)
    }

    private static func media(at url: URL, query: RecentsQuery, cutoff: Date) -> MediaFile? {
        guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
              let type = v.contentType else { return nil }
        let video = type.conforms(to: .movie)
        let image = type.conforms(to: .image)
        switch query.kinds {
        case .all: guard video || image else { return nil }
        case .images: guard image else { return nil }
        case .videos: guard video else { return nil }
        }
        guard let date = v.addedToDirectoryDate ?? v.creationDate ?? v.contentModificationDate, date >= cutoff else { return nil }
        return MediaFile(url: url, date: date, isVideo: video)
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return underlying.code == Int(EPERM) || underlying.code == Int(EACCES)
        }
        return false
    }
}

/// Tells Recents when something changes in the watched folders (FSEvents), so the tab
/// rescans only when needed instead of walking Downloads on every open.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "deckhand.recents.watcher")
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    /// Watches `paths` (and everything below them), replacing what was watched before.
    func watch(_ paths: [String]) {
        stop()
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                               FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}
