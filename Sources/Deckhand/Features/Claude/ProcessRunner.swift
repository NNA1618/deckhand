import Darwin
import Foundation

/// Runs a command line tool with a timeout, without ever blocking the main thread and
/// without letting a tool that exits early kill Deckhand with SIGPIPE.
enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
        /// Ended by a timeout or by cancelling.
        var stopped = false
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// A child stays alive this long after SIGTERM before it gets SIGKILL.
    private static let killDelay: TimeInterval = 2

    /// Writing to a pipe whose reader is gone raises SIGPIPE, which ends the process by default.
    /// Ignored once for the whole app; the failed write then just reports an error.
    private static let ignoreSigpipe: Void = { signal(SIGPIPE, SIG_IGN) }()

    /// The environment for child processes: the user's own, without the variables of a
    /// Claude Code session that may have launched Deckhand, plus `extra`.
    static func environment(_ extra: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.hasPrefix("CLAUDE_CODE_") || key == "CLAUDECODE" {
            env[key] = nil
        }
        env.merge(extra) { $1 }
        return env
    }

    /// After the process exits, its output is read for at most this long. A background child it
    /// left behind may hold the pipes open for much longer; what arrived by then is the answer.
    static let drainGrace: TimeInterval = 0.5

    /// Runs and waits. Blocks the calling thread, so call it off the main thread
    /// (or in the self-test with short timeouts).
    static func runSync(_ executable: String, _ arguments: [String], input: String? = nil, timeout: TimeInterval,
                        cwd: URL? = nil, env: [String: String] = [:]) throws -> Output {
        let job = try Job(executable, arguments, input: input, cwd: cwd, env: env)
        if job.done.wait(timeout: .now() + timeout) != .success {
            job.stop()
            // A stopped tool usually exits at once; take what it printed on the way out
            _ = job.done.wait(timeout: .now() + drainGrace + 0.2)
        }
        return job.output()
    }

    /// Runs without blocking a thread. Cancelling the task stops the process (SIGTERM, then SIGKILL).
    static func run(_ executable: String, _ arguments: [String], input: String? = nil, timeout: TimeInterval,
                    cwd: URL? = nil, env: [String: String] = [:]) async throws -> Output {
        let job = try Job(executable, arguments, input: input, cwd: cwd, env: env)
        let timer = Task.detached {
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { job.stop() }
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                job.done.notify(queue: .global()) { continuation.resume() }
            }
        } onCancel: {
            job.stop()
        }
        try Task.checkCancellation()
        return job.output()
    }

    /// One running process with its pipes being drained in the background.
    ///
    /// `done` fires once the process has exited and both pipes reached their end, or `drainGrace`
    /// after the exit, whichever comes first: a child the tool left running in the background
    /// keeps the pipes open but must not keep the caller waiting.
    private final class Job: @unchecked Sendable {
        let process = Process()
        let done = DispatchGroup()
        private let lock = NSLock()
        private var out = Data(), err = Data()
        private var stopped = false
        private var finished = false
        /// Both pipes reached their end.
        private let pipes = DispatchGroup()
        private let outPipe = Pipe(), errPipe = Pipe()

        init(_ executable: String, _ arguments: [String], input: String?, cwd: URL?, env: [String: String]) throws {
            _ = ProcessRunner.ignoreSigpipe
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let cwd { process.currentDirectoryURL = cwd }
            process.environment = ProcessRunner.environment(env)
            let inPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = inPipe
            done.enter()
            read(outPipe) { [self] data in out.append(data) }
            read(errPipe) { [self] data in err.append(data) }
            process.terminationHandler = { [self] _ in
                DispatchQueue.global().async { [self] in
                    _ = pipes.wait(timeout: .now() + ProcessRunner.drainGrace)
                    finish()
                }
            }
            do {
                try process.run()
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                throw Failure(message: error.localizedDescription)
            }
            let writer = inPipe.fileHandleForWriting
            DispatchQueue.global().async {
                // Fails quietly when the tool exits without reading its input
                if let input { try? writer.write(contentsOf: Data(input.utf8)) }
                try? writer.close()
            }
        }

        /// Appends what arrives on a pipe until its end, then leaves `pipes` once.
        private func read(_ pipe: Pipe, append: @escaping @Sendable (Data) -> Void) {
            pipes.enter()
            let ended = NSLock()
            nonisolated(unsafe) var left = false
            pipe.fileHandleForReading.readabilityHandler = { [self, pipes] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    let first = ended.withLock { () -> Bool in
                        defer { left = true }
                        return !left
                    }
                    if first { pipes.leave() }
                } else {
                    lock.withLock { if !finished { append(data) } }
                }
            }
        }

        /// Stops reading and reports the job done; the output read so far is the answer.
        private func finish() {
            let first = lock.withLock { () -> Bool in
                defer { finished = true }
                return !finished
            }
            guard first else { return }
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            done.leave()
        }

        /// Ends the process and anything it started in the background: Foundation puts the child
        /// in a process group of its own, so the group is signalled even after the child exited.
        /// Counts as stopped only when something was still running.
        func stop() {
            let pid = process.processIdentifier
            guard pid > 0 else { return }
            let running = process.isRunning
            let group = kill(-pid, 0) == 0
            guard running || group else { return }
            lock.withLock { stopped = true }
            if group { kill(-pid, SIGTERM) }
            if running { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + ProcessRunner.killDelay) { [process] in
                if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) }
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }

        func output() -> Output {
            let running = process.isRunning
            return lock.withLock {
                Output(status: running ? -1 : process.terminationStatus,
                       stdout: String(decoding: out, as: UTF8.self),
                       stderr: String(decoding: err, as: UTF8.self),
                       stopped: stopped)
            }
        }
    }

    // MARK: - Other processes

    /// Name, start time and terminal of a running process, read with sysctl (no child process).
    struct ProcessDetails {
        let name: String
        let started: TimeInterval
        let parent: Int32
        /// The terminal device, e.g. "/dev/ttys003", when it has one.
        let tty: String?
    }

    static func details(pid: Int32) -> ProcessDetails? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let start = info.kp_proc.p_un.__p_starttime
        let started = TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
        var tty: String?
        let dev = info.kp_eproc.e_tdev
        if dev != -1, let cName = devname(dev, S_IFCHR) {
            let n = String(cString: cName)
            if n != "??" { tty = "/dev/" + n }
        }
        return ProcessDetails(name: name, started: started, parent: info.kp_eproc.e_ppid, tty: tty)
    }
}
