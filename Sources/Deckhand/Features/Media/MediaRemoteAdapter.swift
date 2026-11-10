import AppKit

/// The system's Now Playing, as the adapter in `Adapter/` reports it.
///
/// Since macOS 15.4 the private MediaRemote framework answers only to Apple-signed processes. The adapter
/// is a small library that Apple's own `/usr/bin/perl` loads (a platform binary MediaRemote trusts); it
/// writes one JSON object per line on stdout and takes commands on stdin. This file starts it, reads it,
/// restarts it with backoff if it dies, and gives up after a few tries so the monitor falls back to
/// asking apps directly.
struct SystemTrack: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var isPlaying: Bool
    /// Seconds; nil when the player doesn't say.
    var duration: Double?
    /// Seconds at `timestamp`.
    var elapsed: Double?
    var rate: Double?
    var timestamp: Date?
    /// The app that plays, or "" when MediaRemote didn't say.
    var bundleID: String

    /// Identifies the track, so its artwork is decoded once.
    var key: String { [title, artist, album, bundleID].joined(separator: "\u{1F}") }

    /// The source app among the ones Deckhand knows, else `.other`.
    var app: MediaApp { MediaApp.owner(ofBundleID: bundleID) ?? .other }

    /// What the Music tab and the badge show. Paused stays paused: the badge hides after the pause delay.
    func nowPlaying(appName: String?) -> NowPlaying {
        let positionDate = elapsed == nil ? nil : (timestamp ?? Date())
        return NowPlaying(title: title, artist: artist, album: album, isPlaying: isPlaying, app: app,
                          duration: duration.flatMap { $0 > 0 ? $0 : nil }, position: elapsed, positionDate: positionDate,
                          bundleID: bundleID.isEmpty ? nil : bundleID, appName: app == .other ? appName : nil)
    }
}

/// One line from the adapter.
enum AdapterLine: Equatable, Sendable {
    enum Artwork: Equatable, Sendable {
        /// Same artwork as the last line.
        case unchanged
        /// The track has none.
        case none
        case image(Data)
    }

    case hello(version: Int)
    /// Nothing is playing anywhere, or MediaRemote says nothing.
    case idle
    case track(SystemTrack, artwork: Artwork)
    /// The adapter couldn't load MediaRemote; it exits right after.
    case error(String)

    /// Parses one line; nil for anything that isn't a line the adapter writes.
    static func parse(_ line: Data) -> AdapterLine? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "hello":
            return .hello(version: (object["version"] as? NSNumber)?.intValue ?? 0)
        case "error":
            return .error((object["message"] as? String) ?? "")
        case "state":
            guard (object["active"] as? Bool) == true else { return .idle }
            func text(_ key: String) -> String { (object[key] as? String) ?? "" }
            func number(_ key: String) -> Double? {
                guard let n = object[key] as? NSNumber, n.doubleValue.isFinite else { return nil }
                return n.doubleValue
            }
            let title = text("title").trimmingCharacters(in: .whitespacesAndNewlines)
            // A session without a title has nothing to show
            guard !title.isEmpty else { return .idle }
            let track = SystemTrack(title: title, artist: text("artist"), album: text("album"),
                                    isPlaying: (object["playing"] as? Bool) ?? false,
                                    duration: number("duration"), elapsed: number("elapsed"), rate: number("rate"),
                                    timestamp: number("timestamp").map { Date(timeIntervalSince1970: $0) },
                                    bundleID: text("bundle"))
            let artwork: Artwork
            switch object["artwork"] {
            case let base64 as String where base64.isEmpty: artwork = .none
            case let base64 as String: artwork = Data(base64Encoded: base64).map(Artwork.image) ?? .none
            default: artwork = .unchanged
            }
            return .track(track, artwork: artwork)
        default:
            return nil
        }
    }
}

/// Splits a byte stream into lines. Pure, so the self-test covers it.
struct LineBuffer {
    private var pending = Data()
    /// A line longer than this is dropped (artwork is at most a few hundred kilobytes).
    var limit = 16 << 20

    mutating func append(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(pending[pending.startIndex..<newline])
            pending.removeSubrange(pending.startIndex...newline)
        }
        if pending.count > limit { pending.removeAll() }
        pending = Data(pending)  // keep indexes starting at zero
        return lines
    }
}

/// When to start the adapter again after it died. Pure, so the self-test covers it.
struct AdapterRestartPolicy: Sendable {
    /// Delays before the first, second and third restart; after that Deckhand gives up.
    var delays: [TimeInterval] = [1, 5, 20]
    /// A run this long counts as healthy: the next death starts the count over.
    var healthyRun: TimeInterval = 60

    /// The delay before the next start, or nil to give up. `failures` counts deaths in a row, this one included.
    func delay(afterFailures failures: Int) -> TimeInterval? {
        failures >= 1 && failures <= delays.count ? delays[failures - 1] : nil
    }
}

/// The child process, behind a protocol so the self-test can drive a fake one.
@MainActor
protocol AdapterProcess: AnyObject {
    /// Starts the process. `onLine` gets each parsed line, `onExit` fires once when it ends.
    func start(onLine: @escaping @MainActor (AdapterLine) -> Void, onExit: @escaping @MainActor () -> Void) throws
    func send(_ command: String)
    func terminate()
}

@MainActor
final class MediaRemoteAdapter {
    enum State: Equatable {
        /// Not started, or stopped because nothing needs it.
        case stopped
        /// Started, waiting for its first line.
        case launching
        case running
        /// Died; starts again after a delay.
        case waitingToRestart
        /// Died too often, or can't work on this Mac. Stays so until Deckhand restarts.
        case failed
    }

    enum Command: String { case toggle, next, previous }

    private(set) var state: State = .stopped { didSet { if state != oldValue { onStateChange?(state) } } }
    /// Each line from a running adapter.
    var onLine: ((AdapterLine) -> Void)?
    var onStateChange: ((State) -> Void)?

    private let makeProcess: () -> AdapterProcess?
    private let policy: AdapterRestartPolicy
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private let now: () -> Date
    private var process: AdapterProcess?
    private var generation = 0
    private var failures = 0
    private var startedAt: Date?
    /// Seconds to wait for the first line before the start counts as failed.
    private let launchTimeout: TimeInterval

    init(makeProcess: @escaping () -> AdapterProcess?, policy: AdapterRestartPolicy = AdapterRestartPolicy(),
         launchTimeout: TimeInterval = 5,
         schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = MediaRemoteAdapter.mainSchedule,
         now: @escaping () -> Date = Date.init) {
        self.makeProcess = makeProcess
        self.policy = policy
        self.launchTimeout = launchTimeout
        self.schedule = schedule
        self.now = now
    }

    /// The real adapter from the app bundle, or nil when the bundle has no adapter (a plain `swift run`).
    static func bundled() -> MediaRemoteAdapter? {
        guard let library = Bundle.main.url(forResource: "DeckhandNowPlaying", withExtension: "dylib"),
              let script = Bundle.main.url(forResource: "now-playing", withExtension: "pl"),
              FileManager.default.isExecutableFile(atPath: PerlAdapterProcess.perl) else { return nil }
        return MediaRemoteAdapter(makeProcess: { PerlAdapterProcess(script: script, library: library) })
    }

    nonisolated static func mainSchedule(_ delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            work()
        }
    }

    var isRunning: Bool { state == .running }

    /// Starts the adapter unless it runs already or gave up.
    func start() {
        guard state == .stopped else { return }
        launch()
    }

    /// Stops it on purpose: not a failure, no restart.
    func stop() {
        guard state != .failed else { return }
        generation += 1
        let old = process
        process = nil
        old?.terminate()
        state = .stopped
    }

    func send(_ command: Command) {
        guard state == .running else { return }
        process?.send(command.rawValue)
    }

    private func launch() {
        generation += 1
        let current = generation
        guard let process = makeProcess() else { state = .failed; return }
        self.process = process
        state = .launching
        startedAt = now()
        do {
            try process.start(onLine: { [weak self] line in self?.received(line, generation: current) },
                              onExit: { [weak self] in self?.exited(generation: current) })
        } catch {
            Log.info("now playing: adapter didn't start: \(error.localizedDescription)")
            exited(generation: current)
            return
        }
        schedule(launchTimeout) { [weak self] in
            guard let self, self.generation == current, self.state == .launching else { return }
            Log.info("now playing: adapter said nothing in \(Int(self.launchTimeout)) s")
            self.process?.terminate()
        }
    }

    private func received(_ line: AdapterLine, generation current: Int) {
        guard current == generation else { return }
        if case .error(let message) = line {
            // MediaRemote is missing or changed: trying again won't help
            Log.info("now playing: adapter error: \(message)")
            generation += 1
            process?.terminate()
            process = nil
            state = .failed
            return
        }
        if state == .launching { state = .running }
        onLine?(line)
    }

    private func exited(generation current: Int) {
        guard current == generation else { return }
        process = nil
        let ranFor = startedAt.map { now().timeIntervalSince($0) } ?? 0
        failures = ranFor >= policy.healthyRun ? 1 : failures + 1
        guard let delay = policy.delay(afterFailures: failures) else {
            Log.info("now playing: adapter died \(failures) times, using the fallback")
            state = .failed
            return
        }
        Log.info("now playing: adapter ended after \(Int(ranFor)) s, restart \(failures) in \(Int(delay)) s")
        state = .waitingToRestart
        let next = generation + 1
        generation = next
        schedule(delay) { [weak self] in
            guard let self, self.generation == next, self.state == .waitingToRestart else { return }
            self.launch()
        }
    }
}

/// `/usr/bin/perl now-playing.pl DeckhandNowPlaying.dylib`, with stdout parsed off the main thread.
/// Lines and the exit reach the main queue in order: the exit comes after the last line was read.
@MainActor
final class PerlAdapterProcess: AdapterProcess {
    static let perl = "/usr/bin/perl"
    private let script: URL
    private let library: URL
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var quitObserver: NSObjectProtocol?
    private var readAll = false
    private var terminated = false
    private var exitHandler: (@MainActor () -> Void)?

    init(script: URL, library: URL) {
        self.script = script
        self.library = library
    }

    func start(onLine: @escaping @MainActor (AdapterLine) -> Void, onExit: @escaping @MainActor () -> Void) throws {
        exitHandler = onExit
        process.executableURL = URL(fileURLWithPath: Self.perl)
        process.arguments = [script.path, library.path]
        // No inherited PERL5LIB or PERL5OPT: the launcher uses only Perl's own DynaLoader
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // A command written just as the adapter dies must not end Deckhand with SIGPIPE
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let reader = LineReader()
        let deliver = Delivery(line: onLine) { [weak self] in self?.finished(readAll: true) }
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                deliver.end()
                return
            }
            for line in reader.append(chunk) {
                if let parsed = AdapterLine.parse(line) { deliver.send(parsed) }
            }
        }
        process.terminationHandler = { _ in deliver.terminated() }
        deliver.onTerminated = { [weak self] in self?.finished(readAll: false) }
        try process.run()
        // Closing stdin also ends the adapter, but quitting Deckhand shouldn't rely on that alone
        let child = process
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                              object: nil, queue: .main) { _ in
            if child.isRunning { child.terminate() }
        }
    }

    func send(_ command: String) {
        guard process.isRunning, let data = (command + "\n").data(using: .utf8) else { return }
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    func terminate() {
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        quitObserver = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    /// The exit counts once both the process ended and its output was read to the end.
    private func finished(readAll eof: Bool) {
        if eof { readAll = true } else { terminated = true }
        guard readAll, terminated, let handler = exitHandler else { return }
        exitHandler = nil
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        quitObserver = nil
        try? input.fileHandleForWriting.close()
        handler()
    }

    /// The line buffer, used only from the pipe's reading queue.
    private final class LineReader: @unchecked Sendable {
        private var buffer = LineBuffer()
        func append(_ chunk: Data) -> [Data] { buffer.append(chunk) }
    }

    /// Hands lines, end of output and termination to the main queue, in the order they happened.
    private final class Delivery: @unchecked Sendable {
        private let line: @MainActor (AdapterLine) -> Void
        private let eof: @MainActor () -> Void
        @MainActor var onTerminated: (@MainActor () -> Void)?

        init(line: @escaping @MainActor (AdapterLine) -> Void, eof: @escaping @MainActor () -> Void) {
            self.line = line
            self.eof = eof
        }

        func send(_ value: AdapterLine) {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.line(value) } }
        }

        func end() {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.eof() } }
        }

        func terminated() {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.onTerminated?() } }
        }
    }
}
