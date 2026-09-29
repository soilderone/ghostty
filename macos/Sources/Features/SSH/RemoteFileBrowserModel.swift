import AppKit
import Combine

/// The remote browser keeps its own async cache. Local FileManager operations never receive a
/// remote path, even though FileEntry uses file URLs as convenient path identifiers.
final class RemoteFileBrowserModel: ObservableObject {
    let connection: SSHConnection

    @Published private(set) var directory: String?
    @Published private(set) var entries: [FileEntry] = []
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

    init(connection: SSHConnection) {
        self.connection = connection
    }

    var visibleEntries: [FileEntry] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = entries.filter { entry in
            (showsHidden || !entry.isHidden) &&
                (needle.isEmpty || entry.name.localizedCaseInsensitiveContains(needle))
        }
        return sortKey.sorted(filtered, ascending: sortAscending)
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
                let entry = try await SSHRemoteFiles.stat(path, on: connection)
                if entry.isDirectory {
                    content = .directory
                } else if entry.size > 10 * 1024 * 1024 {
                    content = .tooLarge(entry.size)
                } else if FilePreviewDocument.imageExtensions.contains(entry.url.pathExtension.lowercased()) {
                    let data = try await SSHRemoteFiles.read(path, on: connection, maxBytes: 10 * 1024 * 1024)
                    content = NSImage(data: data).map(FilePreviewContent.image) ?? .binary
                } else if entry.size > FilePreviewLoader.maxTextBytes {
                    content = .tooLarge(entry.size)
                } else {
                    let data = try await SSHRemoteFiles.read(
                        path, on: connection, maxBytes: FilePreviewLoader.maxTextBytes)
                    if data.prefix(8192).contains(0) {
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
                            base: base))
                    }
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
