import AppKit
import SwiftUI

/// The files under the browser's folder, for the fuzzy finder. Built off the main thread each
/// time the finder opens, so it is never stale.
final class FileQuickOpenIndex: ObservableObject {
    struct Entry {
        /// The path relative to the folder searched.
        let path: String

        /// The path lowercased, as UTF-8, so matching a keystroke against tens of thousands
        /// of paths stays fast.
        let bytes: [UInt8]

        /// Where the file name starts in `bytes`.
        let nameStart: Int
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var isIndexing = false

    /// Whether the folder had more files than are searched.
    @Published private(set) var isTruncated = false

    /// Bumped when the entries change.
    @Published private(set) var revision = 0

    static let maxFiles = 50_000

    /// Version control data and installed packages would drown out the user's own files.
    private static let skippedFolders: Set<String> = [".git", ".hg", ".svn", "node_modules"]

    private var cancellation: Cancellation?

    deinit {
        cancellation?.cancel()
    }

    func build(_ root: URL, showsHidden: Bool) {
        cancel()
        let cancellation = Cancellation()
        self.cancellation = cancellation
        isIndexing = true

        DispatchQueue.global(qos: .userInitiated).async {
            let (entries, truncated) = Self.list(root, showsHidden: showsHidden, cancellation: cancellation)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.cancellation === cancellation else { return }
                self.entries = entries
                self.isTruncated = truncated
                self.isIndexing = false
                self.revision += 1
            }
        }
    }

    func cancel() {
        cancellation?.cancel()
        cancellation = nil
        isIndexing = false
    }

    private static func list(
        _ root: URL,
        showsHidden: Bool,
        cancellation: Cancellation
    ) -> (entries: [Entry], truncated: Bool) {
        listRepository(root, showsHidden: showsHidden, cancellation: cancellation) ??
            walk(root, showsHidden: showsHidden, cancellation: cancellation)
    }

    /// The files of a git repository, from git: the ones it tracks and the ones it doesn't but
    /// wouldn't ignore. That takes a fraction of a walk of the folder, and leaves out what
    /// `.gitignore` says is not the user's own (build output, virtual environments, ...) so the
    /// limit isn't spent on it.
    ///
    /// Nil when the folder is not in a repository, git isn't there, or it lists nothing (a folder
    /// that is itself ignored), and then the folder is walked.
    private static func listRepository(
        _ root: URL,
        showsHidden: Bool,
        cancellation: Cancellation
    ) -> (entries: [Entry], truncated: Bool)? {
        guard let git = GitRunner.executable,
              let output = try? GitRunner.runBlocking(
                executable: git,
                arguments: ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                directory: root.path,
                maxBytes: 16 * 1024 * 1024,
                successCodes: [0])
        else { return nil }

        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var entries: [Entry] = []
        var previous = ""
        var truncated = output.truncated
        for (index, raw) in output.data.split(separator: 0, omittingEmptySubsequences: true).enumerated() {
            if index % 512 == 0 && cancellation.isCancelled { return ([], false) }

            // Files are listed once per merge stage while a merge is unresolved.
            let path = raw.lossyUTF8String
            if path == previous { continue }
            previous = path

            let components = path.split(separator: "/")
            if !showsHidden && components.contains(where: { $0.hasPrefix(".") }) { continue }
            if components.contains(where: { skippedFolders.contains(String($0)) }) { continue }

            // A tracked file can be missing from the disk, and a submodule is a folder.
            var info = stat()
            guard lstat(base + path, &info) == 0, info.st_mode & S_IFMT != S_IFDIR else { continue }

            entries.append(Self.entry(path))
            if entries.count >= maxFiles {
                truncated = true
                break
            }
        }
        return entries.isEmpty ? nil : (entries, truncated)
    }

    private static func entry(_ path: String) -> Entry {
        let bytes = Array(path.lowercased().utf8)
        let nameStart = (bytes.lastIndex(of: UInt8(ascii: "/")) ?? -1) + 1
        return Entry(path: path, bytes: bytes, nameStart: nameStart)
    }

    /// The files under a folder, found by walking it.
    private static func walk(
        _ root: URL,
        showsHidden: Bool,
        cancellation: Cancellation
    ) -> (entries: [Entry], truncated: Bool) {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !showsHidden { options.insert(.skipsHiddenFiles) }
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: options,
            errorHandler: { _, _ in true }
        ) else { return ([], false) }

        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var entries: [Entry] = []
        for case let url as URL in enumerator {
            if entries.count % 512 == 0 && cancellation.isCancelled { return ([], false) }

            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if skippedFolders.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            let path = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
            entries.append(Self.entry(path))
            if entries.count >= maxFiles { return (entries, true) }
        }
        return (entries, false)
    }

    /// The best matches for a query, best first.
    func matches(_ query: String, limit: Int = 200) -> [Entry] {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace }.utf8)
        guard !needle.isEmpty else { return Array(entries.prefix(limit)) }

        var scored: [(entry: Entry, score: Int)] = []
        for entry in entries {
            guard let score = FuzzyMatch.score(needle, entry) else { continue }
            scored.append((entry, score))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.entry.bytes.count < b.entry.bytes.count
        }
        return scored.prefix(limit).map { $0.entry }
    }

    private final class Cancellation {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
        }
    }
}

/// Fuzzy matching as editors do it: the query's characters must appear in order, and matches
/// in the file name, at the start of a word and in runs rank higher.
enum FuzzyMatch {
    static func score(_ query: [UInt8], _ entry: FileQuickOpenIndex.Entry) -> Int? {
        // Any match within the file name beats one that needs the folders.
        if let score = match(query, entry.bytes, from: entry.nameStart) {
            return score + 1000
        }
        return match(query, entry.bytes, from: 0)
    }

    private static func match(_ query: [UInt8], _ text: [UInt8], from start: Int) -> Int? {
        var score = 0
        var matched = 0
        var last = -2
        var index = start
        while index < text.count && matched < query.count {
            if text[index] == query[matched] {
                score += 1
                if index == last + 1 { score += 8 }
                if index == start || isBoundary(text[index - 1]) { score += 10 }
                last = index
                matched += 1
            }
            index += 1
        }
        guard matched == query.count else { return nil }

        // Shorter paths are likelier to be what was meant.
        return score - (text.count - start) / 8
    }

    private static func isBoundary(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "/"), UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: " "):
            return true
        default:
            return false
        }
    }
}

/// The fuzzy finder (Command-O): type part of a file's name or path, pick with the arrows and
/// open with return.
struct FileQuickOpenView: View {
    @ObservedObject var model: FileBrowserModel

    @StateObject private var index = FileQuickOpenIndex()
    @State private var query = ""
    @State private var results: [FileQuickOpenIndex.Entry] = []
    @State private var highlighted = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
                CommandTextField(
                    text: $query,
                    placeholder: "Open a file in \(model.root?.lastPathComponent ?? "the folder")",
                    focusOnAppear: true,
                    onCommand: handle)
                    .frame(height: 22)
                if index.isIndexing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
                FileBarButton(symbol: "xmark", help: "Close") { close() }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 32)
            FileSeparator()

            if !index.isIndexing && results.isEmpty {
                FileMessage(
                    symbol: "doc.text.magnifyingglass",
                    title: index.entries.isEmpty ? "No files here" : "No matching files")
            } else {
                resultList
            }

            if index.isTruncated {
                Text("Only the first \(FileQuickOpenIndex.maxFiles.formatted()) files are searched.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: ChromePalette.panel))
        .onAppear {
            guard let root = model.root else { return }
            index.build(root, showsHidden: model.showsHidden)
        }
        .onDisappear { index.cancel() }
        .onChange(of: query) { _ in updateResults() }
        .onChange(of: index.revision) { _ in updateResults() }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.offset) { offset, entry in
                        FileQuickOpenRow(entry: entry, root: model.root, isHighlighted: offset == highlighted)
                            .id(offset)
                            .onTapGesture { open(entry) }
                    }
                }
                .padding(.vertical, 3)
            }
            .onChange(of: highlighted) { proxy.scrollTo($0) }
        }
    }

    private func updateResults() {
        results = index.matches(query)
        highlighted = 0
    }

    private func handle(_ command: TextFieldCommand) -> Bool {
        switch command {
        case .submit:
            guard results.indices.contains(highlighted) else { return true }
            open(results[highlighted])
        case .cancel:
            close()
        case .moveDown:
            highlighted = min(highlighted + 1, max(results.count - 1, 0))
        case .moveUp:
            highlighted = max(highlighted - 1, 0)
        case .complete:
            break
        }
        return true
    }

    private func open(_ entry: FileQuickOpenIndex.Entry) {
        guard let root = model.root else { return }
        let url = entry.path.hasPrefix("/")
            ? URL(fileURLWithPath: entry.path)
            : root.appendingPathComponent(entry.path)
        close()
        model.open(url.standardizedFileURL)
    }

    private func close() {
        model.isQuickOpenShown = false
    }
}

private struct FileQuickOpenRow: View {
    let entry: FileQuickOpenIndex.Entry
    let root: URL?
    let isHighlighted: Bool

    private var name: String {
        (entry.path as NSString).lastPathComponent
    }

    private var folder: String {
        (entry.path as NSString).deletingLastPathComponent
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: root?.appendingPathComponent(entry.path).path ?? entry.path))
                .resizable()
                .frame(width: 14, height: 14)
            Text(name)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: ChromePalette.text))
                .lineLimit(1)
            Text(folder)
                .font(.system(size: 11))
                .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(isHighlighted ? Color(nsColor: ChromePalette.selectionOverlay) : .clear)
        .contentShape(Rectangle())
    }
}
