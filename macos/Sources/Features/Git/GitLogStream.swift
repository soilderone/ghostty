import Foundation

/// A `git log` that keeps running between pages of the history, so a page is read from where
/// the last one stopped.
///
/// With `--topo-order`, git has to walk the whole history before it prints the first commit
/// unless the repository has a commit-graph file, which it often doesn't. Asking for each page
/// with its own `git log --skip` walks it again for every page, so a page costs as much as the
/// history is long. Here git is started once, and what it prints is read a page at a time.
/// It is not read ahead: while nothing reads, git waits with its output pipe full.
///
/// Read-only like all of the Git view. Reading happens off the main thread, one page at a time.
final class GitLogStream: @unchecked Sendable {
    struct Page {
        /// The records of the page: the text of `GitCommit.parseLog`.
        let text: String

        /// Whether there is at least one more commit after this page.
        let hasMore: Bool
    }

    /// The most output that is held while looking for the end of a page.
    private static let maxBufferBytes = 16 * 1024 * 1024
    private static let maxStderrBytes = 16 * 1024

    /// How long a page may take, which for the first one includes the walk of the history.
    private static let timeout: TimeInterval = 120

    private static let recordSeparator: UInt8 = 0x1e

    /// What git printed on stderr. It is read on its own thread, which must not keep the stream
    /// alive: the stream stops git when it goes away.
    private final class ErrorCapture {
        private let lock = NSLock()
        private let finished = DispatchGroup()
        private var data = Data()

        init() {
            finished.enter()
        }

        func read(from handle: FileHandle) {
            DispatchQueue.global().async {
                let text = handle.readDataToEndOfFile().prefix(GitLogStream.maxStderrBytes)
                self.lock.lock()
                self.data = Data(text)
                self.lock.unlock()
                self.finished.leave()
            }
        }

        var text: String {
            finished.wait()
            lock.lock()
            defer { lock.unlock() }
            return data.lossyUTF8String.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private let process = Process()
    private let reader: FileHandle
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.git-log", qos: .userInitiated)
    private let errors = ErrorCapture()

    private let lock = NSLock()
    private var isCancelled = false
    private var timedOut = false

    // Used on `queue` only.
    private var buffer = Data()
    private var recordEnds: [Int] = []
    private var reachedEnd = false

    /// Starts `git` with these arguments in a directory. They should print records that end
    /// with the ASCII record separator, such as `--format=...%x1e`.
    init(arguments: [String], in directory: String) throws {
        guard let executable = GitRunner.executable else { throw GitError.notFound }

        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.arguments = [
            "-c", "core.quotepath=off",
            "-c", "color.ui=false",
            "-c", "log.showsignature=false",
        ] + arguments

        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["PAGER"] = "cat"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        reader = stdout.fileHandleForReading

        do {
            try process.run()
        } catch {
            throw GitError(message: "Cannot run git: \(error.localizedDescription)")
        }

        // Read stderr alongside stdout, or a chatty stderr could fill its pipe and stall git.
        errors.read(from: stderr.fileHandleForReading)
    }

    deinit {
        cancel()
    }

    /// Stops git. A page that is being read fails with `CancellationError`.
    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    /// Reads the next `count` records.
    func nextPage(records count: Int) async throws -> Page {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.readPage(count) })
            }
        }
    }

    private func readPage(_ count: Int) throws -> Page {
        // A page is done once one record more than it holds is in, which is how it is known
        // whether there is another page. Or when the output ends.
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.timedOut = true
            self.lock.unlock()
            if self.process.isRunning { self.process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)
        defer { watchdog.cancel() }

        while recordEnds.count <= count && !reachedEnd {
            let chunk = reader.availableData
            if chunk.isEmpty {
                reachedEnd = true
                break
            }

            let base = buffer.count
            buffer.append(chunk)
            for (offset, byte) in chunk.enumerated() where byte == Self.recordSeparator {
                recordEnds.append(base + offset)
            }

            if buffer.count > Self.maxBufferBytes {
                cancel()
                throw GitError(message: "git log printed more than a page of history should hold.")
            }
        }

        lock.lock()
        let cancelled = isCancelled
        let didTimeOut = timedOut
        lock.unlock()
        if didTimeOut { throw GitError(message: "git log took too long.") }
        if cancelled { throw CancellationError() }

        if reachedEnd {
            // The output is over, so git is done or nearly: it failed, or the history is over.
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let message = errors.text
                if message.contains("not a git repository") { throw GitError.notARepository }
                throw GitError(message: message.isEmpty ? "git log failed." : message)
            }
            if recordEnds.isEmpty { return Page(text: "", hasMore: false) }
        }

        let taken = min(count, recordEnds.count)
        let cut = taken == 0 ? 0 : recordEnds[taken - 1] + 1
        let text = buffer.prefix(cut).lossyUTF8String
        let hasMore = recordEnds.count > taken

        // Keep what was read past the page for the next one.
        buffer = Data(buffer.suffix(from: buffer.startIndex + cut))
        recordEnds = recordEnds.dropFirst(taken).map { $0 - cut }
        return Page(text: text, hasMore: hasMore)
    }
}
