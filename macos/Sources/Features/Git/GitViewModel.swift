import Foundation
import Combine

/// A diff the Git view shows, as it loads.
enum GitDiffState: Equatable {
    case none
    case loading
    case loaded(GitDiff)
    case failed(String)
}

/// A row of the History page: a commit, or the uncommitted changes on top of HEAD.
enum GitHistoryRow: Identifiable, Equatable {
    case worktree(changes: Int)
    case commit(GitCommit)

    static let worktreeID = "__worktree__"

    var id: String {
        switch self {
        case .worktree: return Self.worktreeID
        case .commit(let commit): return commit.hash
        }
    }
}

extension Notification.Name {
    /// A command finished in a terminal (shell integration). The object is the terminal's
    /// surface view. Commands are what change a repository, so the Git view looks again.
    static let ghosttyCommandDidFinish = Notification.Name("com.mitchellh.ghostty.commandDidFinish")
}

/// The state of one window's Git view. It is read-only: it runs git to look at the repository
/// of the focused terminal's directory and never changes anything.
///
/// Status is polled, but only while the view is on screen and its window is key, so a
/// background window costs nothing. While nothing changes the polls space out, and a command
/// finishing in a terminal brings them back to the fast pace with an immediate look.
///
/// Its methods are called on the main thread, and every git result comes back to it there.
final class GitViewModel: ObservableObject {
    enum Page: Hashable {
        case changes
        case history
    }

    /// The wait between polls, doubled after each poll that finds nothing new, up to
    /// `maxBackoffs` times. Over SSH every poll is a round trip and a git run on the host.
    private static let localPollInterval: TimeInterval = 4
    private static let remotePollInterval: TimeInterval = 10
    private static let maxBackoffs = 2
    private static let logPageSize = 200

    /// The directory the view follows; the repository is the one that contains it.
    @Published private(set) var directory: URL?
    @Published private(set) var connection: SSHConnection?

    /// The repository's top-level directory, or nil while unknown or outside a repository.
    @Published private(set) var root: String?

    /// Whether the directory is inside a repository, nil until known.
    @Published private(set) var isRepository: Bool?

    @Published private(set) var status: GitStatus?
    @Published private(set) var error: String?

    @Published var page: Page = .changes {
        didSet {
            guard page != oldValue else { return }
            if page == .history {
                dropLogStreamWhenIdle = false
                if commits.isEmpty && root != nil { loadLog(reset: true) }
            } else {
                parkLogStream()
            }
        }
    }

    // MARK: Changes

    @Published var selectedChange: GitChange? {
        didSet {
            guard selectedChange != oldValue else { return }
            changeDiff = .none
            changeDiffOutput = nil
            changeDiffStamp = nil
            loadChangeDiff()
        }
    }

    @Published private(set) var changeDiff: GitDiffState = .none

    // MARK: History

    @Published private(set) var historyRows: [GitHistoryRow] = []
    @Published private(set) var graph: [GitGraph.Row] = []
    @Published private(set) var graphLanes: Int = 1
    @Published private(set) var hasMoreCommits = false
    @Published private(set) var isLoadingLog = false
    @Published private(set) var logError: String?

    @Published var selectedCommit: String? {
        didSet {
            guard selectedCommit != oldValue else { return }
            commitDetail = nil
            commitDetailError = nil
            selectedCommitFile = nil
            loadCommitDetail()
        }
    }

    @Published private(set) var commitDetail: GitCommitDetail?
    @Published private(set) var commitDetailError: String?

    @Published var selectedCommitFile: GitChangedFile? {
        didSet {
            guard selectedCommitFile != oldValue else { return }
            commitFileDiff = .none
            loadCommitFileDiff()
        }
    }

    @Published private(set) var commitFileDiff: GitDiffState = .none

    // MARK: State

    private var commits: [GitCommit] = []
    private var gitDirectory: String?

    /// Bumped whenever the repository changes, so results for the old one are dropped.
    private var generation = 0

    private var isRefreshing = false
    private var refreshAgain = false
    private var refreshRequestID = 0
    private var timer: Timer?
    private var isPolling = false
    private var isVisible = false
    private var isWindowActive = false
    private var retryLogFromStart = false
    private var logRequestID = 0

    /// The `git log` that the History page reads its pages from, and how many commits it has
    /// gone through, those it skipped included. Only local repositories have one.
    private var logStream: GitLogStream?
    private var logStreamPosition = 0
    private var dropLogStreamWhenIdle = false

    /// How many polls in a row found nothing new, and whether one has since.
    private var quietPolls = 0
    private var sawChange = false

    /// What git printed last time, so an unchanged repository isn't parsed and compared again.
    private var statusOutput: GitOutput?
    private var changeDiffOutput: GitOutput?

    /// What the selected change's diff depends on when it was loaded. While that is the same,
    /// the diff is the same and git isn't asked again.
    private var changeDiffStamp: DiffStamp?
    private var changeDiffRequestID = 0

    private var commandObserver: NSObjectProtocol?

    init() {
        commandObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyCommandDidFinish,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.commandDidFinish()
        }
    }

    deinit {
        if let commandObserver {
            NotificationCenter.default.removeObserver(commandObserver)
        }
        timer?.invalidate()
        logStream?.cancel()
    }

    // MARK: Inputs

    /// Follows the focused terminal's directory. Moving within the same repository keeps the
    /// view's state.
    func setDirectory(_ url: URL?, connection: SSHConnection? = nil) {
        guard url != directory || connection != self.connection else { return }
        let connectionChanged = connection != self.connection
        self.connection = connection
        directory = url

        if !connectionChanged, let url, let root,
           url.path == root || url.path.hasPrefix(root + "/") {
            return
        }

        resetRepository()
        sawChange = true
        refresh()
    }

    func setVisible(_ visible: Bool) {
        isVisible = visible
        updatePolling()
    }

    func setWindowActive(_ active: Bool) {
        isWindowActive = active
        updatePolling()
    }

    private func updatePolling() {
        guard isVisible && isWindowActive else {
            timer?.invalidate()
            timer = nil
            isPolling = false
            parkLogStream()
            return
        }

        dropLogStreamWhenIdle = false
        guard !isPolling else { return }
        isPolling = true
        quietPolls = 0

        // One that is already running (the view sets its directory just before it starts
        // polling) will schedule the next poll when it is done.
        if !isRefreshing { refresh() }
    }

    /// Waits for the next poll once a refresh is done. The wait doubles for each poll in a row
    /// that found nothing new.
    private func scheduleNextPoll() {
        timer?.invalidate()
        timer = nil
        guard isPolling else { return }

        if sawChange {
            sawChange = false
            quietPolls = 0
        } else {
            quietPolls = min(quietPolls + 1, Self.maxBackoffs)
        }

        let base = connection == nil ? Self.localPollInterval : Self.remotePollInterval
        let interval = base * Double(1 << quietPolls)
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Lets the system line the poll up with other work instead of waking up for it alone.
        timer.tolerance = interval / 4
        self.timer = timer
    }

    private func commandDidFinish() {
        guard isPolling else { return }
        sawChange = true
        refresh()
    }

    private func resetRepository() {
        dropLogStream()
        statusOutput = nil
        changeDiffOutput = nil
        changeDiffStamp = nil
        generation += 1
        logRequestID += 1
        refreshRequestID += 1
        isRefreshing = false
        refreshAgain = false
        root = nil
        gitDirectory = nil
        isRepository = nil
        status = nil
        error = nil
        commits = []
        historyRows = []
        graph = []
        graphLanes = 1
        hasMoreCommits = false
        isLoadingLog = false
        logError = nil
        retryLogFromStart = false
        selectedChange = nil
        selectedCommit = nil
        commitDetailError = nil
    }

    // MARK: Status

    /// Reloads the status, and the selected change's diff with it.
    func refresh() {
        guard let directory else { return }
        guard !isRefreshing else {
            refreshAgain = true
            return
        }

        isRefreshing = true
        refreshRequestID += 1
        let requestID = refreshRequestID
        let generation = self.generation
        let connection = self.connection
        Task { @MainActor in
            await refreshStatus(directory: directory, connection: connection, generation: generation)
            guard requestID == refreshRequestID else { return }
            isRefreshing = false
            if refreshAgain {
                refreshAgain = false
                refresh()
            } else {
                scheduleNextPoll()
            }
        }
    }

    @MainActor
    private func refreshStatus(directory: URL, connection: SSHConnection?, generation: Int) async {
        do {
            if root == nil {
                let output = try await GitRunner.run(
                    ["rev-parse", "--show-toplevel", "--absolute-git-dir"],
                    in: directory.path, connection: connection)
                guard generation == self.generation else { return }
                let lines = output.text.split(whereSeparator: \.isNewline).map(String.init)
                guard lines.count >= 2 else { throw GitError(message: "Unexpected output from git rev-parse.") }
                root = lines[0]
                gitDirectory = lines[1]
                isRepository = true
            }

            guard let root else { return }
            let output = try await GitRunner.run(
                ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"],
                in: root, connection: connection)
            guard generation == self.generation else { return }

            // Parsing and comparing a big status takes a while, so it happens off the main
            // thread, and not at all when git printed the same as last time.
            let previous = status
            let previousOutput = statusOutput
            let localGitDirectory = connection == nil ? self.gitDirectory : nil
            let (newStatus, changed) = await Task.detached(priority: .userInitiated) { () -> (GitStatus, Bool) in
                var parsed: GitStatus
                if let previous, let previousOutput, previousOutput.isSame(as: output) {
                    parsed = previous
                } else {
                    parsed = GitStatus.parse(output)
                }
                if let localGitDirectory {
                    parsed.state = GitRepoState.detect(gitDirectory: localGitDirectory)
                }
                return (parsed, parsed != previous)
            }.value
            guard generation == self.generation else { return }

            statusOutput = output
            error = nil
            applyStatus(newStatus, changed: changed)
        } catch {
            guard generation == self.generation else { return }
            if let gitError = error as? GitError, gitError == .notARepository {
                isRepository = false
                self.error = nil
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    private func applyStatus(_ newStatus: GitStatus, changed: Bool) {
        let previous = status
        guard changed else {
            // Nothing changed, but a file's content can change without its status.
            reloadChangeDiff()
            return
        }
        sawChange = true
        status = newStatus

        // Keep the selection while its file is still listed in the same group.
        if let selected = selectedChange,
           !newStatus.changes(in: selected.group).contains(where: { $0.file.path == selected.file.path }) {
            selectedChange = nil
        } else if let selected = selectedChange,
                  let updated = newStatus.changes(in: selected.group).first(where: { $0.file.path == selected.file.path }),
                  updated != selected {
            selectedChange = updated
        } else {
            reloadChangeDiff()
        }

        let headMoved = previous != nil && (previous?.head != newStatus.head || previous?.branch != newStatus.branch)
        if page == .history && (headMoved || (commits.isEmpty && !isLoadingLog && logError == nil)) {
            loadLog(reset: true)
        } else if headMoved {
            // The History page reloads the log when it is next shown.
            dropLogStream()
            logRequestID += 1
            commits = []
            hasMoreCommits = false
            isLoadingLog = false
            logError = nil
            rebuildHistory()
        } else {
            rebuildHistory()
        }
    }

    // MARK: Diffs

    private func loadChangeDiff() {
        guard selectedChange != nil else { return }
        changeDiff = .loading
        reloadChangeDiff()
    }

    /// Loads the selected change's diff again. The result only replaces the diff on screen
    /// when it differs, so an unchanged diff keeps its scroll position.
    ///
    /// Git isn't run at all when the files the diff comes from are as they were when it was
    /// loaded. That can't be told over SSH, so a remote diff is loaded again every time.
    private func reloadChangeDiff() {
        guard let change = selectedChange, let root else { return }
        let generation = self.generation
        let connection = self.connection

        let stamp = connection == nil ? diffStamp(for: change, root: root) : nil
        if let stamp, stamp == changeDiffStamp {
            switch changeDiff {
            case .loaded, .loading: return
            default: break
            }
        }

        // From here the stamp describes what is on screen or on its way there.
        changeDiffStamp = stamp
        changeDiffRequestID += 1
        let requestID = changeDiffRequestID
        let (arguments, successCodes) = Self.diffArguments(for: change)
        let previousOutput = changeDiffOutput
        Task { @MainActor in
            let state: GitDiffState
            var newOutput: GitOutput?
            do {
                let output = try await GitRunner.run(
                    arguments, in: root, connection: connection, successCodes: successCodes)
                newOutput = output
                if let previousOutput, previousOutput.isSame(as: output), case .loaded = changeDiff {
                    // The same text as on screen.
                    state = changeDiff
                } else {
                    state = .loaded(await Self.parse(output))
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
            guard generation == self.generation, selectedChange == change,
                  requestID == changeDiffRequestID else { return }

            if case .loaded = state {
                changeDiffOutput = newOutput
            } else {
                // Look again at the next poll.
                changeDiffOutput = nil
                changeDiffStamp = nil
            }
            guard changeDiff != state else { return }
            changeDiff = state
            sawChange = true
        }
    }

    /// Parses a diff off the main thread; a big one takes long enough to be felt.
    private static func parse(_ output: GitOutput) async -> GitDiff {
        await Task.detached(priority: .userInitiated) { GitDiff.parse(output) }.value
    }

    /// What a diff depends on: the file it compares, and the index and HEAD it is compared
    /// through. Only the modification time and size of the file and the index are looked at,
    /// not their contents.
    private struct DiffStamp: Equatable {
        struct File: Equatable {
            let seconds: Int
            let nanoseconds: Int
            let size: Int64
        }

        let file: File?
        let index: File?
        let head: String?

        static func stamp(ofItemAtPath path: String) -> File? {
            // A link's own time, since the diff of a link is about where it points.
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            return File(
                seconds: info.st_mtimespec.tv_sec,
                nanoseconds: info.st_mtimespec.tv_nsec,
                size: Int64(info.st_size))
        }
    }

    /// Nil when there is nothing to tell whether the diff still holds.
    private func diffStamp(for change: GitChange, root: String) -> DiffStamp? {
        // A staged diff is the index against HEAD, and an untracked file's is the file alone.
        let file = change.group == .staged ? nil : DiffStamp.stamp(ofItemAtPath: root + "/" + change.file.path)
        let index = change.group == .untracked
            ? nil
            : gitDirectory.flatMap { DiffStamp.stamp(ofItemAtPath: $0 + "/index") }
        guard file != nil || index != nil else { return nil }
        return DiffStamp(file: file, index: index, head: status?.head)
    }

    private static func diffArguments(for change: GitChange) -> ([String], Set<Int32>) {
        let file = change.file
        switch change.group {
        case .conflicts:
            return (["diff", "--no-ext-diff", "--", file.path], [0])
        case .staged:
            let paths = [file.originalPath, file.path].compactMap { $0 }
            return (["diff", "--no-ext-diff", "--cached", "-M", "--"] + paths, [0])
        case .unstaged:
            return (["diff", "--no-ext-diff", "--", file.path], [0])
        case .untracked:
            // git diff exits with 1 when the files differ, which they always do here.
            return (["diff", "--no-ext-diff", "--no-index", "--", "/dev/null", file.path], [0, 1])
        }
    }

    // MARK: History

    /// Loads the first page of the log, or the next one.
    func loadLog(reset: Bool) {
        guard let root, !isLoadingLog || reset else { return }
        guard status?.head != nil else {
            // No commits yet.
            dropLogStream()
            logRequestID += 1
            commits = []
            hasMoreCommits = false
            isLoadingLog = false
            logError = nil
            rebuildHistory()
            return
        }

        logError = nil
        isLoadingLog = true
        logRequestID += 1
        let requestID = logRequestID
        let generation = self.generation
        let connection = self.connection
        let skip = reset ? 0 : commits.count
        Task { @MainActor in
            do {
                let page: (commits: [GitCommit], hasMore: Bool)
                if connection == nil {
                    page = try await streamedPage(in: root, skip: skip, reset: reset)
                } else {
                    let output = try await GitRunner.run([
                        "log",
                        "--topo-order",
                        "--decorate=full",
                        "--format=\(GitCommit.logFormat)",
                        "--skip=\(skip)",
                        "-n", "\(Self.logPageSize + 1)",
                        "HEAD",
                        "--",
                    ], in: root, connection: connection)
                    let loaded = GitCommit.parseLog(output.text)
                    page = (Array(loaded.prefix(Self.logPageSize)), loaded.count > Self.logPageSize)
                }
                guard generation == self.generation, requestID == self.logRequestID else { return }

                hasMoreCommits = page.hasMore
                commits = reset ? page.commits : commits + page.commits
                logError = nil
                retryLogFromStart = false
                isLoadingLog = false
                rebuildHistory()
                if dropLogStreamWhenIdle { dropLogStream() }
            } catch {
                guard generation == self.generation, requestID == self.logRequestID else { return }
                // The next attempt starts a log of its own.
                dropLogStream()
                logError = error.localizedDescription
                retryLogFromStart = reset
                isLoadingLog = false
            }
        }
    }

    /// A page of the log from the running `git log`, or from a new one when none is running or
    /// the running one is not where this page starts.
    private func streamedPage(
        in root: String,
        skip: Int,
        reset: Bool
    ) async throws -> (commits: [GitCommit], hasMore: Bool) {
        let stream: GitLogStream
        if !reset, let logStream, logStreamPosition == skip {
            stream = logStream
        } else {
            dropLogStream()
            stream = try GitLogStream(arguments: [
                "log",
                "--topo-order",
                "--decorate=full",
                "--format=\(GitCommit.logFormat)",
                "--skip=\(skip)",
                "HEAD",
                "--",
            ], in: root)
            logStream = stream
            logStreamPosition = skip
        }

        let page = try await stream.nextPage(records: Self.logPageSize)
        let commits = GitCommit.parseLog(page.text)
        if logStream === stream { logStreamPosition = skip + commits.count }
        return (commits, page.hasMore)
    }

    private func dropLogStream() {
        logStream?.cancel()
        logStream = nil
        dropLogStreamWhenIdle = false
    }

    /// Lets go of the running git while the History page isn't in use, since it can hold a lot
    /// of memory in a big repository. A page that is being read finishes first. The next page
    /// starts a new git where this one left off.
    private func parkLogStream() {
        if isLoadingLog {
            dropLogStreamWhenIdle = logStream != nil
        } else {
            dropLogStream()
        }
    }

    /// Loads the next page once the list gets near its end.
    func rowAppeared(at index: Int) {
        guard hasMoreCommits, !isLoadingLog, logError == nil,
              index >= historyRows.count - 30 else { return }
        loadLog(reset: false)
    }

    func retryLog() {
        loadLog(reset: retryLogFromStart || historyRows.isEmpty)
    }

    private func rebuildHistory() {
        var rows: [GitHistoryRow] = []
        var lanes: [(hash: String, parents: [String])] = []

        // Uncommitted changes hang off HEAD as a pseudo-commit.
        if let status, let head = status.head, !status.files.isEmpty, commits.first?.hash == head {
            rows.append(.worktree(changes: status.files.count))
            lanes.append((hash: GitHistoryRow.worktreeID, parents: [head]))
        }

        rows += commits.map { GitHistoryRow.commit($0) }
        lanes += commits.map { (hash: $0.hash, parents: $0.parents) }

        guard rows != historyRows else { return }
        historyRows = rows
        graph = GitGraph.layout(lanes)
        graphLanes = graph.map(\.width).max() ?? 1
    }

    private func loadCommitDetail() {
        guard let hash = selectedCommit, hash != GitHistoryRow.worktreeID, let root else { return }
        let generation = self.generation
        let connection = self.connection
        Task { @MainActor in
            do {
                let output = try await GitRunner.run(
                    ["show", "-s", "--format=\(GitCommitDetail.format)", hash],
                    in: root, connection: connection)
                guard var detail = GitCommitDetail.parse(output.text) else {
                    throw GitError(message: "Unexpected output from git show.")
                }

                // A merge is compared with its first parent, like `git log -p --first-parent`.
                var arguments = ["diff-tree", "-r", "-z", "-M", "--name-status", "--no-commit-id"]
                if let parent = detail.parents.first {
                    arguments += [parent, hash]
                } else {
                    arguments += ["--root", hash]
                }
                let files = try await GitRunner.run(arguments, in: root, connection: connection)
                detail.files = GitChangedFile.parse(files)
                detail.filesTruncated = files.truncated

                guard generation == self.generation, selectedCommit == hash else { return }
                commitDetailError = nil
                commitDetail = detail
            } catch {
                guard generation == self.generation, selectedCommit == hash else { return }
                commitDetailError = error.localizedDescription
            }
        }
    }

    func retryCommitDetail() {
        guard selectedCommit != nil else { return }
        commitDetailError = nil
        loadCommitDetail()
    }

    private func loadCommitFileDiff() {
        guard let file = selectedCommitFile, let detail = commitDetail, let root else { return }
        commitFileDiff = .loading
        let generation = self.generation
        let connection = self.connection
        let paths = [file.originalPath, file.path].compactMap { $0 }
        let arguments: [String]
        if let parent = detail.parents.first {
            arguments = ["diff", "--no-ext-diff", "-M", parent, detail.hash, "--"] + paths
        } else {
            arguments = ["show", "--no-ext-diff", "--format=", detail.hash, "--", file.path]
        }

        Task { @MainActor in
            let state: GitDiffState
            do {
                let output = try await GitRunner.run(arguments, in: root, connection: connection)
                state = .loaded(await Self.parse(output))
            } catch {
                state = .failed(error.localizedDescription)
            }
            guard generation == self.generation, selectedCommitFile == file else { return }
            commitFileDiff = state
        }
    }
}
