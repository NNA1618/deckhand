import AppKit
import Combine
import CryptoKit
import Security

/// What a release publishes next to Deckhand.zip, as update.json.
struct UpdateManifest: Codable, Equatable {
    var version: String
    var build: Int
    var url: URL
    /// Ed25519 signature of the zip, base64, made with the key in scripts/setup-release-keys.sh.
    var signature: String
    var minimumSystem: String?
    var notes: [String: String]?
}

/// The public half of the update key. Only archives signed with the private half install.
enum UpdateKey {
    static let publicKey = "rTLCuMGIzWSnoALISA6hNWdTsYXcH07xS19ml0pagjg="
}

/// Checks GitHub for a newer Deckhand, downloads it, checks its signature and replaces the app in place.
///
/// Works without an Apple Developer ID: the trust comes from the Ed25519 signature, not from Gatekeeper,
/// and an archive downloaded by Deckhand itself isn't quarantined, so the new copy opens without a prompt.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    static let manifestURL = URL(string: "https://github.com/NNA1618/deckhand/releases/latest/download/update.json")!
    static let checkInterval: TimeInterval = 6 * 60 * 60

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateManifest)
        case installing(UpdateManifest)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?
    @Published var checksAutomatically: Bool { didSet { d.set(checksAutomatically, forKey: "updateChecksAutomatically") } }
    @Published var installsAutomatically: Bool { didSet { d.set(installsAutomatically, forKey: "updateInstallsAutomatically") } }

    private let d = UserDefaults.standard
    private var timer: Timer?
    private var announced: Int?
    private weak var notch: NotchController?

    private init() {
        d.register(defaults: ["updateChecksAutomatically": true, "updateInstallsAutomatically": true])
        checksAutomatically = d.bool(forKey: "updateChecksAutomatically")
        installsAutomatically = d.bool(forKey: "updateInstallsAutomatically")
        lastChecked = d.object(forKey: "updateLastChecked") as? Date
    }

    var available: UpdateManifest? {
        if case .available(let manifest) = state { return manifest }
        return nil
    }

    /// Starts the periodic check. Only the installed app does this, never check builds or snapshot runs.
    func start(notch: NotchController) {
        self.notch = notch
        guard AppPaths.bundleId == "com.nna1618.deckhand" else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { Updater.shared.tick() }
    }

    private func tick() {
        if let manifest = available {
            if installsAutomatically, Self.isIdle { install(manifest) }
            return
        }
        guard checksAutomatically else { return }
        if let lastChecked, Date().timeIntervalSince(lastChecked) < Self.checkInterval { return }
        check(userInitiated: false)
    }

    /// Nothing the user would lose by a relaunch: no open panel, timer, Keep Awake, capture or picker.
    static var isIdle: Bool {
        guard let notch = shared.notch else { return false }
        return !notch.viewModel.isOpen && !Countdown.shared.isActive && !KeepAwake.shared.isActive
            && !ScreenshotService.isRunning && !ScreenColorPicker.isRunning
            && NSApp.windows.allSatisfy { !($0.isVisible && $0.styleMask.contains(.titled)) }
    }

    func check(userInitiated: Bool) {
        if case .checking = state { return }
        if case .installing = state { return }
        state = .checking
        Task {
            do {
                var request = URLRequest(url: Self.manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                request.setValue("Deckhand/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.server }
                let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
                lastChecked = Date()
                d.set(lastChecked, forKey: "updateLastChecked")
                if Self.isNewer(manifest, than: Int(AppVersion.build) ?? 0, system: ProcessInfo.processInfo.operatingSystemVersion) {
                    state = .available(manifest)
                    Log.info("update: \(manifest.version) (\(manifest.build)) available")
                    if installsAutomatically && !userInitiated && Self.isIdle {
                        install(manifest)
                    } else if announced != manifest.build {
                        announced = manifest.build
                        notch?.showToast(symbol: "arrow.down.circle",
                                         text: String(localized: "Deckhand \(manifest.version) is available"))
                    }
                } else {
                    state = .upToDate
                }
            } catch {
                Log.info("update: check failed: \(error.localizedDescription)")
                state = userInitiated ? .failed(String(localized: "Couldn’t check for updates. Check your connection and try again."))
                                      : .idle
            }
        }
    }

    func install(_ manifest: UpdateManifest) {
        if case .installing = state { return }
        state = .installing(manifest)
        Task {
            do {
                let app = try await Self.download(manifest)
                try Self.replaceRunningApp(with: app)
                Log.info("update: installed \(manifest.version), relaunching")
                Self.relaunch()
            } catch {
                Log.info("update: install failed: \(error)")
                state = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
            }
        }
    }

    // MARK: - Steps

    enum UpdateError: Error, Equatable {
        case server, signature, archive, wrongApp, notWritable, translocated

        var message: String {
            switch self {
            case .server: String(localized: "Couldn’t download the update. Try again later.")
            case .signature: String(localized: "The update’s signature doesn’t match, so it wasn’t installed.")
            case .archive, .wrongApp: String(localized: "The downloaded update is damaged, so it wasn’t installed.")
            case .notWritable: String(localized: "Deckhand can’t replace itself in this folder. Move Deckhand to Applications and try again.")
            case .translocated: String(localized: "Move Deckhand to Applications, open it from there, and try again.")
            }
        }
    }

    nonisolated static func isNewer(_ manifest: UpdateManifest, than build: Int, system: OperatingSystemVersion) -> Bool {
        guard manifest.build > build else { return false }
        guard let minimum = manifest.minimumSystem else { return true }
        let parts = minimum.split(separator: ".").compactMap { Int($0) }
        let required = OperatingSystemVersion(majorVersion: parts.first ?? 0, minorVersion: parts.dropFirst().first ?? 0,
                                              patchVersion: parts.dropFirst(2).first ?? 0)
        return (system.majorVersion, system.minorVersion, system.patchVersion)
            >= (required.majorVersion, required.minorVersion, required.patchVersion)
    }

    nonisolated static func verify(_ data: Data, signature: String, publicKey: String = UpdateKey.publicKey) -> Bool {
        guard let sig = Data(base64Encoded: signature), let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    /// Downloads, verifies and unpacks the update next to the running app, and returns the new app.
    private static func download(_ manifest: UpdateManifest) async throws -> URL {
        let current = Bundle.main.bundleURL
        guard !current.path.contains("/AppTranslocation/") else { throw UpdateError.translocated }
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: current.path) else { throw UpdateError.notWritable }
        guard manifest.url.scheme == "https" else { throw UpdateError.server }

        var request = URLRequest(url: manifest.url, timeoutInterval: 120)
        request.setValue("Deckhand/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        let (file, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.server }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard verify(data, signature: manifest.signature) else { throw UpdateError.signature }

        // A folder on the app's own volume, so the swap below is a rename
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: current, create: true)
        let zip = work.appendingPathComponent("Deckhand.zip")
        try data.write(to: zip)
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        let app = work.appendingPathComponent("Deckhand.app")
        try check(app: app, manifest: manifest)
        return app
    }

    /// The unpacked app must be Deckhand, the promised build, intact, and signed the way this copy is.
    private static func check(app: URL, manifest: UpdateManifest) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              (info["CFBundleVersion"] as? String).flatMap(Int.init) == manifest.build else { throw UpdateError.wrongApp }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError.archive
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(staticCode, flags, nil) == errSecSuccess else { throw UpdateError.archive }

        // When this copy is signed with a certificate, the update must satisfy the same requirement,
        // which also keeps macOS permissions. An ad-hoc development build has nothing to compare.
        var me: SecCode?, requirement: SecRequirement?
        if SecCodeCopySelf([], &me) == errSecSuccess, let me,
           SecCodeCopyDesignatedRequirement(unsafeBitCast(me, to: SecStaticCode.self), [], &requirement) == errSecSuccess,
           let requirement {
            var text: CFString?
            SecRequirementCopyString(requirement, [], &text)
            if (text as String?)?.contains("certificate") == true,
               SecStaticCodeCheckValidity(staticCode, flags, requirement) != errSecSuccess {
                throw UpdateError.signature
            }
        }
    }

    private static func replaceRunningApp(with app: URL) throws {
        let current = Bundle.main.bundleURL
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: app)
        } catch {
            Log.info("update: replace failed: \(error.localizedDescription)")
            throw UpdateError.notWritable
        }
    }

    /// Opens the new copy once this one has exited.
    private static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                             "sh", pid, path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.terminationHandler = { p in
                if p.terminationStatus == 0 { continuation.resume() } else { continuation.resume(throwing: UpdateError.archive) }
            }
            do { try process.run() } catch { continuation.resume(throwing: UpdateError.archive) }
        }
    }
}
