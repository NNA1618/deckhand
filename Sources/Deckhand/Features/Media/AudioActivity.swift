import CoreAudio
import Darwin
import Foundation

/// Which apps are sending sound to an output device right now, from CoreAudio's process objects.
/// Public API that needs no permission. It can't say what is playing, only that sound comes out,
/// which is exactly what tells a paused browser tab from a playing one.
///
/// `IsRunningOutput` has no working change notification, so it is polled; the per-process details
/// (PID, bundle identifier, owning app) are looked up once per process object and cached.
final class AudioActivity: @unchecked Sendable {
    static let shared = AudioActivity()

    private let queue = DispatchQueue(label: "deckhand.audio-activity", qos: .utility)
    /// Process object → the media app it belongs to, or nil for processes Deckhand ignores. Touched only on `queue`.
    private var owners: [AudioObjectID: MediaApp?] = [:]

    private init() {}

    /// The media apps that are outputting sound. Runs off the main thread; a full pass takes about a millisecond.
    func outputtingApps() async -> Set<MediaApp> {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.poll()) }
        }
    }

    private func poll() -> Set<MediaApp> {
        let objects = processObjects()
        let alive = Set(objects)
        owners = owners.filter { alive.contains($0.key) }
        var result = Set<MediaApp>()
        for object in objects {
            let owner: MediaApp?
            if let cached = owners[object] {
                owner = cached
            } else {
                owner = resolveOwner(object)
                owners[object] = owner
            }
            guard let owner, !result.contains(owner) else { continue }
            if uint32(object, kAudioProcessPropertyIsRunningOutput) == 1 { result.insert(owner) }
        }
        return result
    }

    private func processObjects() -> [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// Maps a process object to its app: by bundle identifier first, then by the `.app` that contains
    /// the executable, which catches helpers with unrelated identifiers (Electron apps).
    private func resolveOwner(_ object: AudioObjectID) -> MediaApp? {
        if let id = bundleID(object), let app = MediaApp.owner(ofBundleID: id) { return app }
        let pid = pid_t(bitPattern: uint32(object, kAudioProcessPropertyPID) ?? 0)
        guard pid > 0, let path = executablePath(pid), let appPath = MediaApp.outermostAppPath(in: path),
              let id = Bundle(path: appPath)?.bundleIdentifier else { return nil }
        return MediaApp.owner(ofBundleID: id)
    }

    private func bundleID(_ object: AudioObjectID) -> String? {
        var address = Self.address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let string = value?.takeRetainedValue() as String?, !string.isEmpty else { return nil }
        return string
    }

    private func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = Self.address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func executablePath(_ pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(length), as: UTF8.self)
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }
}
