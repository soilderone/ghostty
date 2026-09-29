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

/// The state of one window's Git view. It is read-only: it runs git to look at the repository
/// of the focused terminal's directory and never changes anything.
///
/// Status is polled every few seconds, but only while the view is on screen and its window is
/// key, so a background window costs nothing.
///
/// Its methods are called on the main thread, and every git result comes back to it there.
final class GitViewModel: ObservableObject {
    enum Page: Hashable {
        case changes
        case history
    }

    private static let pollInterval: TimeInterval = 4
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
            if page == .history && commits.isEmpty && root != nil {
                loadLog(reset: true)
            }
        }
    }

    // MARK: Changes

    @Published var selectedChange: GitChange? {
        didSet {
            guard selectedChange != oldValue else { return }
            changeDiff = .none
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
    private var isVisible = false
    private var isWindowActive = false
    private var retryLogFromStart = false
    private var logRequestID = 0

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
            return
        }

        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func resetRepository() {
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

            var newStatus = GitStatus.parse(output)
            if connection == nil, let gitDirectory {
                newStatus.state = GitRepoState.detect(gitDirectory: gitDirectory)
            }
            error = nil
            applyStatus(newStatus)
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

    private func applyStatus(_ newStatus: GitStatus) {
        let previous = status
        guard newStatus != previous else {
            // Nothing changed, but a file's content can change without its status.
            reloadChangeDiff()
            return
        }
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
    private func reloadChangeDiff() {
        guard let change = selectedChange, let root else { return }
        let generation = self.generation
        let connection = self.connection
        let (arguments, successCodes) = Self.diffArguments(for: change)
        Task { @MainActor in
            let state: GitDiffState
            do {
                let output = try await GitRunner.run(
                    arguments, in: root, connection: connection, successCodes: successCodes)
                state = .loaded(GitDiff.parse(output))
            } catch {
                state = .failed(error.localizedDescription)
            }
            guard generation == self.generation, selectedChange == change, changeDiff != state else { return }
            changeDiff = state
        }
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
                guard generation == self.generation, requestID == self.logRequestID else { return }

                let loaded = GitCommit.parseLog(output.text)
                hasMoreCommits = loaded.count > Self.logPageSize
                let newCommits = Array(loaded.prefix(Self.logPageSize))
                commits = reset ? newCommits : commits + newCommits
                logError = nil
                retryLogFromStart = false
                isLoadingLog = false
                rebuildHistory()
            } catch {
                guard generation == self.generation, requestID == self.logRequestID else { return }
                logError = error.localizedDescription
                retryLogFromStart = reset
                isLoadingLog = false
            }
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
                state = .loaded(GitDiff.parse(output))
            } catch {
                state = .failed(error.localizedDescription)
            }
            guard generation == self.generation, selectedCommitFile == file else { return }
            commitFileDiff = state
        }
    }
}
