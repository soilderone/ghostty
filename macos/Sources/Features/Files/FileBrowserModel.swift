import AppKit
import Combine

/// What the file browser asks the window to do on its behalf.
struct FileBrowserActions {
    /// Opens a new tab with a terminal in the folder.
    var openTerminal: (URL) -> Void = { _ in }

    /// Types text into the focused terminal without pressing return.
    var typeInTerminal: (String) -> Void = { _ in }
}

/// The state of one window's file browser (feature 10): the folder it shows, how the tree is
/// sorted and filtered, the selection, and the files open in the preview.
///
/// Its methods are called on the main thread.
final class FileBrowserModel: ObservableObject {
    /// The folder the tree shows.
    @Published private(set) var root: URL?

    @Published var sortKey: FileSortKey = .name {
        didSet {
            guard sortKey != oldValue else { return }
            sortAscending = sortKey.defaultAscending
            reloadAll()
        }
    }

    @Published var sortAscending = true {
        didSet {
            guard sortAscending != oldValue else { return }
            reloadAll()
        }
    }

    @Published var filter = "" {
        didSet {
            guard filter != oldValue else { return }
            revision += 1
        }
    }

    @Published var showsHidden = false {
        didSet {
            guard showsHidden != oldValue else { return }
            revision += 1
        }
    }

    /// Bumped whenever the tree has to reload.
    @Published private(set) var revision = 0

    /// Files open in the preview, in tab order.
    @Published private(set) var tabs: [URL] = []
    @Published var activeTab: URL?

    /// In a narrow sidebar the preview replaces the tree while this is set.
    @Published var showsPreview = false

    /// The file shown in Quick Look, if any.
    @Published var quickLookURL: URL?

    /// Whether the fuzzy file finder (Command-O) is up.
    @Published var isQuickOpenShown = false

    /// The focused terminal's directory, or nil when it hasn't reported one.
    @Published private(set) var terminalDirectory: URL?

    /// The selected files, in the tree's order.
    var selection: [URL] = []

    var actions = FileBrowserActions()

    private var listings: [URL: [FileEntry]] = [:]
    private var expanded: Set<URL> = []

    /// Whether the tree still shows the terminal's directory, so it follows the terminal
    /// until the user browses somewhere else.
    private var followsTerminal = true

    private lazy var watcher = DirectoryWatcher { [weak self] url in
        self?.directoryDidChange(url)
    }

    // MARK: Location

    /// Follows the focused terminal's directory while the tree shows it. Until a terminal
    /// reports one, the tree shows the home folder.
    func terminalDirectoryDidChange(_ url: URL?) {
        let previous = terminalDirectory
        terminalDirectory = url?.standardizedFileURL
        guard let url = terminalDirectory else {
            if root == nil {
                show(FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL)
            }
            return
        }
        if root == nil || (followsTerminal && (previous == nil || root == previous)) {
            show(url)
            followsTerminal = true
        }
    }

    /// Whether the tree shows somewhere other than the terminal's directory.
    var isAwayFromTerminal: Bool {
        guard let terminalDirectory else { return false }
        return root != terminalDirectory
    }

    /// Shows a folder in the tree.
    func navigate(to url: URL) {
        show(url.standardizedFileURL)
        followsTerminal = url.standardizedFileURL == terminalDirectory
    }

    func goUp() {
        guard let root, root.path != "/" else { return }
        navigate(to: root.deletingLastPathComponent())
    }

    /// Returns to the focused terminal's directory.
    func showTerminalDirectory() {
        guard let terminalDirectory else { return }
        navigate(to: terminalDirectory)
    }

    private func show(_ url: URL) {
        guard url != root else { return }
        root = url
        listings = [:]
        expanded = []
        selection = []
        updateWatcher()
        revision += 1
    }

    // MARK: Listing

    /// The entries of a folder as the tree shows them: sorted, filtered, and without dotfiles
    /// unless hidden files are shown.
    func children(of directory: URL) -> [FileEntry] {
        let entries = listing(of: directory)
        let needle = filter.trimmingCharacters(in: .whitespaces)
        return entries.filter { entry in
            (showsHidden || !entry.isHidden) &&
                (needle.isEmpty || entry.name.localizedCaseInsensitiveContains(needle))
        }
    }

    private func listing(of directory: URL) -> [FileEntry] {
        if let cached = listings[directory] { return cached }
        let entries = (try? FileEntry.list(directory, readPermissions: sortKey == .permissions)) ?? []
        let sorted = sortKey.sorted(entries, ascending: sortAscending)
        listings[directory] = sorted
        return sorted
    }

    func isExpanded(_ directory: URL) -> Bool {
        expanded.contains(directory)
    }

    func setExpanded(_ directory: URL, _ isExpanded: Bool) {
        // Reloading the tree reports every folder that stays open again.
        let changed = isExpanded ? expanded.insert(directory).inserted : expanded.remove(directory) != nil
        if changed { updateWatcher() }
    }

    /// Reads every folder again, such as after the sort changes.
    func reloadAll() {
        listings = [:]
        revision += 1
    }

    private func directoryDidChange(_ url: URL) {
        listings[url] = nil
        revision += 1
    }

    private func updateWatcher() {
        var directories = expanded
        if let root { directories.insert(root) }
        watcher.watch(directories)
    }

    // MARK: Preview

    func open(_ url: URL) {
        if !tabs.contains(url) {
            tabs.append(url)
        }
        activeTab = url
        showsPreview = true
    }

    func closeTab(_ url: URL) {
        guard let index = tabs.firstIndex(of: url) else { return }
        tabs.remove(at: index)
        if activeTab == url {
            activeTab = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]
        }
        if tabs.isEmpty {
            showsPreview = false
        }
    }

    func closeOtherTabs(_ url: URL) {
        tabs = tabs.filter { $0 == url }
        activeTab = tabs.first
    }

    /// Keeps open tabs on files that moved or were renamed.
    private func retarget(from old: URL, to new: URL) {
        let oldPath = old.standardizedFileURL.path
        tabs = tabs.map { tab in
            let path = tab.standardizedFileURL.path
            if path == oldPath { return new }
            if path.hasPrefix(oldPath + "/") {
                return URL(fileURLWithPath: new.path + path.dropFirst(oldPath.count))
            }
            return tab
        }
        if let active = activeTab {
            let path = active.standardizedFileURL.path
            if path == oldPath {
                activeTab = new
            } else if path.hasPrefix(oldPath + "/") {
                activeTab = URL(fileURLWithPath: new.path + path.dropFirst(oldPath.count))
            }
        }
    }

    // MARK: Changes

    func createFile(named name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw FileBrowserError.exists(name)
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw FileBrowserError.failed("Couldn't create \(name).")
        }
        directoryDidChange(directory)
    }

    func createFolder(named name: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw FileBrowserError.exists(name)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        directoryDidChange(directory)
    }

    func rename(_ url: URL, to name: String) throws {
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        guard destination != url else { return }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw FileBrowserError.exists(name)
        }
        try FileManager.default.moveItem(at: url, to: destination)
        retarget(from: url, to: destination)
        directoryDidChange(url.deletingLastPathComponent())
    }

    /// Moves files to the Trash, so a mistake can be undone from the Finder.
    func trash(_ urls: [URL]) throws {
        var failures: [String] = []
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                closeTabs(under: url)
            } catch {
                failures.append(url.lastPathComponent)
            }
            listings[url.deletingLastPathComponent()] = nil
        }
        revision += 1
        if !failures.isEmpty {
            throw FileBrowserError.failed("Couldn't move to the Trash: \(failures.joined(separator: ", "))")
        }
    }

    /// Moves files into a folder. Nothing is ever overwritten: a file whose name is taken
    /// there stays put and is reported, and the rest move.
    ///
    /// - Returns: The names that were already taken.
    @discardableResult
    func move(_ urls: [URL], into directory: URL) throws -> [String] {
        var conflicts: [String] = []
        var failures: [String] = []
        let target = directory.standardizedFileURL

        for url in urls {
            let source = url.standardizedFileURL

            // A folder can't move into itself, and moving to where it is does nothing.
            if source.deletingLastPathComponent() == target { continue }
            if target.path == source.path || target.path.hasPrefix(source.path + "/") { continue }

            let destination = target.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                conflicts.append(source.lastPathComponent)
                continue
            }

            do {
                try FileManager.default.moveItem(at: source, to: destination)
                retarget(from: source, to: destination)
                listings[source.deletingLastPathComponent()] = nil
            } catch {
                failures.append(source.lastPathComponent)
            }
        }

        listings[target] = nil
        revision += 1
        if !failures.isEmpty {
            throw FileBrowserError.failed("Couldn't move: \(failures.joined(separator: ", "))")
        }
        return conflicts
    }

    func copyPaths(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    }

    private func closeTabs(under url: URL) {
        let path = url.standardizedFileURL.path
        for tab in tabs where tab.standardizedFileURL.path == path || tab.standardizedFileURL.path.hasPrefix(path + "/") {
            closeTab(tab)
        }
    }

    // MARK: Paths

    /// Resolves what the user typed in the path bar: `~`, an absolute path, or a path
    /// relative to the folder shown.
    func resolve(_ typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let expanded = (text as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return root?.appendingPathComponent(expanded).standardizedFileURL
    }

    /// Completions for a partly typed path: the folder's entries that start with the last
    /// component, folders first and with a trailing slash.
    func completions(for typed: String, limit: Int = 12) -> [String] {
        let text = typed.trimmingCharacters(in: .whitespaces)
        let slash = text.lastIndex(of: "/")
        let folderPart = slash.map { String(text[...$0]) } ?? ""
        let prefix = slash.map { String(text[text.index(after: $0)...]) } ?? text

        let folder: URL?
        if folderPart.isEmpty {
            folder = root
        } else {
            folder = resolve(folderPart)
        }
        guard let folder else { return [] }

        // This runs on every keystroke, so a folder of tens of thousands of files can't be read
        // in full each time: the tree's listing is reused when it has one, and otherwise only
        // the names are read, and only the ones that match are looked at any closer.
        let lowercasedPrefix = prefix.lowercased()
        let listsHidden = showsHidden || prefix.hasPrefix(".")
        let matches: [FileEntry]
        if let cached = listings[folder] {
            matches = cached.filter { entry in
                (listsHidden || !entry.isHidden) && entry.name.lowercased().hasPrefix(lowercasedPrefix)
            }
        } else {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            matches = names.compactMap { name in
                guard listsHidden || !name.hasPrefix("."),
                      name.lowercased().hasPrefix(lowercasedPrefix) else { return nil }
                return FileEntry(url: folder.appendingPathComponent(name))
            }
        }
        return FileSortKey.name.sorted(matches, ascending: true)
            .prefix(limit)
            .map { folderPart + $0.name + ($0.isDirectory ? "/" : "") }
    }
}

enum FileBrowserError: LocalizedError {
    case exists(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .exists(let name): return "\u{201C}\(name)\u{201D} already exists here."
        case .failed(let message): return message
        }
    }
}
