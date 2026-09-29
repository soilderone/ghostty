import AppKit
import Combine

/// The remote browser keeps its own async cache. Local FileManager operations never receive a
/// remote path, even though FileEntry uses file URLs as convenient path identifiers.
final class RemoteFileBrowserModel: ObservableObject {
    let connection: SSHConnection

    @Published private(set) var directory: String?
    @Published private(set) var entries: [FileEntry] = [] {
        didSet { entriesRevision += 1 }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published var error: String?

    @Published var sortKey: FileSortKey = .name {
        didSet { if sortKey != oldValue { sortAscending = sortKey.defaultAscending } }
    }
    @Published var sortAscending = true
    @Published var showsHidden = false
    @Published var filter = ""

    @Published private(set) var tabs: [String] = []
    @Published var activeTab: String? {
        didSet { if activeTab != oldValue { loadPreview() } }
    }
    @Published var showsPreview = false
    @Published private(set) var preview: FilePreviewContent?

    private var listGeneration = 0
    private var previewGeneration = 0

    /// Bumped when the listing changes, so the sorted and filtered lists know to be redone.
    private var entriesRevision = 0
    private var sortedCache: (key: SortInput, entries: [FileEntry])?
    private var visibleCache: (key: VisibleKey, entries: [FileEntry])?

    /// Bigger than this isn't previewed, whatever it is.
    private static let maxImageBytes = 10 * 1024 * 1024

    private struct SortInput: Equatable {
        let revision: Int
        let key: FileSortKey
        let ascending: Bool
    }

    private struct VisibleKey: Equatable {
        let sort: SortInput
        let showsHidden: Bool
        let filter: String
    }

    init(connection: SSHConnection) {
        self.connection = connection
    }

    /// The listing as the view shows it, sorted and filtered. The view asks for this on every
    /// update, so it is only worked out again when something it depends on changes, and typing
    /// in the filter doesn't sort again.
    var visibleEntries: [FileEntry] {
        let sortInput = SortInput(revision: entriesRevision, key: sortKey, ascending: sortAscending)
        let key = VisibleKey(sort: sortInput, showsHidden: showsHidden, filter: filter)
        if let visibleCache, visibleCache.key == key { return visibleCache.entries }

        let sorted: [FileEntry]
        if let sortedCache, sortedCache.key == sortInput {
            sorted = sortedCache.entries
        } else {
            sorted = sortKey.sorted(entries, ascending: sortAscending)
            sortedCache = (sortInput, sorted)
        }

        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = sorted.filter { entry in
            (showsHidden || !entry.isHidden) &&
                (needle.isEmpty || entry.name.localizedCaseInsensitiveContains(needle))
        }
        visibleCache = (key, visible)
        return visible
    }

    func load(_ path: String) {
        directory = path
        listGeneration += 1
        let generation = listGeneration
        isLoading = true
        error = nil
        Task { @MainActor in
            do {
                let result = try await SSHRemoteFiles.list(path, on: connection)
                guard generation == listGeneration else { return }
                entries = result
                isLoading = false
            } catch {
                guard generation == listGeneration else { return }
                entries = []
                isLoading = false
                self.error = error.localizedDescription
            }
        }
    }

    func reload() {
        if let directory { load(directory) }
        if activeTab != nil { loadPreview() }
    }

    func isDirectory(_ path: String) async throws -> Bool {
        try await SSHRemoteFiles.stat(path, on: connection).isDirectory
    }

    func open(_ path: String) {
        if !tabs.contains(path) { tabs.append(path) }
        activeTab = path
        showsPreview = true
    }

    func close(_ path: String) {
        guard let index = tabs.firstIndex(of: path) else { return }
        tabs.remove(at: index)
        if activeTab == path {
            activeTab = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)]
        }
        if tabs.isEmpty { showsPreview = false }
    }

    private func loadPreview() {
        previewGeneration += 1
        let generation = previewGeneration
        preview = nil
        guard let path = activeTab else { return }
        Task { @MainActor in
            let content: FilePreviewContent
            do {
                let isImage = FilePreviewDocument.imageExtensions.contains((path as NSString).pathExtension.lowercased())
                let limit = isImage ? Self.maxImageBytes : FilePreviewLoader.maxTextBytes
                let preview = try await SSHRemoteFiles.preview(path, maxBytes: limit, on: connection)
                let entry = preview.entry
                if entry.isDirectory {
                    content = .directory
                } else if entry.size > limit {
                    content = .tooLarge(entry.size)
                } else if let data = preview.data {
                    if isImage {
                        content = FilePreviewImage.load(data: data).map(FilePreviewContent.image) ?? .binary
                    } else if data.prefix(8192).contains(0) {
                        content = .binary
                    } else {
                        let localURL = URL(fileURLWithPath: path)
                        let document = FilePreviewDocument(url: localURL, text: data.lossyUTF8String)
                        var components = URLComponents()
                        components.scheme = "ssh"
                        components.host = "ghostty-remote"
                        components.path = localURL.deletingLastPathComponent().path + "/"
                        let base = components.url ?? URL(string: "ssh://ghostty-remote/")!
                        content = .document(FilePreviewDocument(
                            kind: document.kind,
                            text: document.text,
                            language: document.language,
                            delimiter: document.delimiter,
                            base: base))
                    }
                } else {
                    content = .unreadable("It isn't a regular file.")
                }
            } catch {
                content = .unreadable(error.localizedDescription)
            }
            guard generation == previewGeneration else { return }
            preview = content
        }
    }

    private func mutate(_ action: @escaping () async throws -> Void, after: @escaping () -> Void = {}) {
        isWorking = true
        error = nil
        Task { @MainActor in
            do {
                try await action()
                after()
                if let directory { load(directory) }
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }

    func createFile(named name: String) {
        guard let path = pathForNewItem(name) else { return }
        mutate { try await SSHRemoteFiles.createFile(path, on: self.connection) }
    }

    func createFolder(named name: String) {
        guard let path = pathForNewItem(name) else { return }
        mutate { try await SSHRemoteFiles.createFolder(path, on: self.connection) }
    }

    func rename(_ path: String, to name: String) {
        guard validName(name) else { return }
        let destination = URL(fileURLWithPath: path).deletingLastPathComponent()
            .appendingPathComponent(name).path
        guard destination != path else { return }
        mutate({ try await SSHRemoteFiles.move(path, to: destination, on: self.connection) }, after: {
            self.retarget(from: path, to: destination)
        })
    }

    func move(_ path: String, into directory: String) {
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path
        guard destination != path else { return }
        mutate({ try await SSHRemoteFiles.move(path, to: destination, on: self.connection) }, after: {
            self.retarget(from: path, to: destination)
        })
    }

    func trash(_ path: String) {
        mutate({ try await SSHRemoteFiles.trash(path, on: self.connection) }, after: {
            for tab in self.tabs where tab == path || tab.hasPrefix(path + "/") {
                self.close(tab)
            }
        })
    }

    private func pathForNewItem(_ name: String) -> String? {
        guard validName(name), let directory else { return nil }
        return URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(name).path
    }

    private func validName(_ name: String) -> Bool {
        let valid = !name.isEmpty && name != "." && name != ".." &&
            !name.contains("/") && !name.contains("\\") && !name.contains("\0")
        if !valid { error = "Enter a single file or folder name." }
        return valid
    }

    private func retarget(from source: String, to destination: String) {
        tabs = tabs.map { path in
            if path == source { return destination }
            if path.hasPrefix(source + "/") { return destination + path.dropFirst(source.count) }
            return path
        }
        if let activeTab {
            if activeTab == source {
                self.activeTab = destination
            } else if activeTab.hasPrefix(source + "/") {
                self.activeTab = destination + activeTab.dropFirst(source.count)
            }
        }
    }
}
