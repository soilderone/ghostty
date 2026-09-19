import AppKit
import Combine

@MainActor
final class WorkspaceLocation: Identifiable {
    let id = UUID()
    var path: String
    var follow = false
    var session: WorkspaceSSHSession?
    var service: any WorkspaceFileService
    var label: String { session.map { $0.profile.name.isEmpty ? $0.profile.host : $0.profile.name } ?? "Local" }

    init(path: String = FileManager.default.homeDirectoryForCurrentUser.path, session: WorkspaceSSHSession? = nil) {
        self.path = path
        self.session = session
        if let session { self.service = session.files } else { self.service = LocalWorkspaceFiles() }
    }
}

@MainActor
final class WorkspaceDocument: ObservableObject, Identifiable {
    let id = UUID()
    let location: WorkspaceLocation
    var path: String
    var original: Data
    @Published var text: String
    @Published var saving = false
    private var hasBOM = false
    private var usesCRLF = false
    var encodedText: Data {
        let normalized = usesCRLF ? text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n") : text
        return (hasBOM ? Data([0xef, 0xbb, 0xbf]) : Data()) + Data(normalized.utf8)
    }
    var dirty: Bool { encodedText != original }
    var title: String { (path as NSString).lastPathComponent }

    init(location: WorkspaceLocation, path: String, data: Data) throws {
        self.location = location
        self.path = path
        self.original = data
        self.text = ""
        try reload(data)
    }

    func reload(_ data: Data) throws {
        let decoded = try WorkspacePath.text(data)
        hasBOM = data.starts(with: [0xef, 0xbb, 0xbf])
        usesCRLF = decoded.contains("\r\n") && !decoded.replacingOccurrences(of: "\r\n", with: "").contains("\n")
        text = decoded.hasPrefix("\u{feff}") ? String(decoded.dropFirst()) : decoded
        original = data
    }
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var visible = false
    @Published var section = "Files"
    @Published var editorVisible = true
    @Published var showHidden = false
    @Published var location = WorkspaceLocation()
    @Published var entries: [WorkspaceFile] = []
    @Published var documents: [WorkspaceDocument] = []
    @Published var selectedDocument: UUID?
    @Published var error: String?
    @Published var status = ""
    @Published var loading = false
    @Published var connecting = false
    @Published var progress: Double?
    @Published var following = false
    @Published var busy = false
    private var locations: [UUID: WorkspaceLocation] = [:]
    private var listing: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var authentication: Task<Void, Never>?
    private var generation = UUID()
    private var activeSurface: UUID?
    private var lastPwd: String?
    private var subscriptions: [UUID: AnyCancellable] = [:]
    private var closing = false

    var activeDocument: WorkspaceDocument? { documents.first { $0.id == selectedDocument } }
    var hasUnsavedChanges: Bool { documents.contains { $0.dirty || $0.saving } }

    func focus(_ surface: Ghostty.SurfaceView?) {
        guard let surface else { return }
        activeSurface = surface.id
        lastPwd = surface.pwd
        if locations[surface.id] == nil {
            locations[surface.id] = WorkspaceLocation(path: surface.pwd ?? FileManager.default.homeDirectoryForCurrentUser.path)
        }
        guard let next = locations[surface.id], next !== location else { return }
        location = next
        following = next.follow
        if visible { refresh() }
    }

    func pwdChanged(_ path: String?) {
        lastPwd = path
        guard following, location.session == nil, let path else { return }
        navigate(path)
    }

    func setFollowing(_ value: Bool) {
        following = value && location.session == nil
        location.follow = following
        if following { pwdChanged(lastPwd) }
    }

    func attach(_ session: WorkspaceSSHSession, surface: Ghostty.SurfaceView, restoring: WorkspaceLocation? = nil) {
        let target = restoring ?? WorkspaceLocation(path: session.profile.directory, session: session)
        if let restoring { restoring.session?.stop() }
        target.session = session
        target.service = session.files
        target.follow = false
        locations[surface.id] = target
        location = target
        activeSurface = surface.id
        visible = true
        section = "Files"
        following = false
        listing?.cancel()
        generation = UUID()
        entries = []
        connecting = true
        status = "Complete SSH login in the terminal…"
        authentication?.cancel()
        authentication = Task { [weak self] in
            do {
                try await session.waitForAuthentication()
                guard let self, !Task.isCancelled else { return }
                self.connecting = false
                self.status = ""
                self.refresh()
            } catch {
                guard !Task.isCancelled else { return }
                self?.connecting = false
                self?.status = error.localizedDescription
            }
        }
    }

    func adopt(_ docs: [WorkspaceDocument]) {
        for doc in docs {
            documents.append(doc)
            observe(doc)
        }
        selectedDocument = documents.first?.id
    }

    func detachDocuments(for target: WorkspaceLocation) -> [WorkspaceDocument] {
        let result = documents.filter { $0.location === target }
        let previous = WorkspaceLocation(path: target.path, session: target.session)
        for key in locations.keys where locations[key] === target { locations[key] = previous }
        if location === target { location = previous }
        documents.removeAll { $0.location === target }
        for doc in result { subscriptions.removeValue(forKey: doc.id) }
        selectedDocument = documents.first?.id
        return result
    }

    func navigate(_ path: String) {
        location.path = path
        refresh()
    }

    func refresh() {
        guard !connecting else { return }
        listing?.cancel()
        let token = UUID()
        generation = token
        let target = location
        let path = target.path
        let service = target.service
        loading = true
        entries = []
        listing = Task { [weak self] in
            do {
                let canonical = try await service.resolve(path)
                let result = try await service.list(canonical)
                guard let self, !Task.isCancelled, self.generation == token else { return }
                target.path = canonical
                self.entries = result.sorted {
                    if $0.directory != $1.directory { return $0.directory }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                self.status = ""
                self.loading = false
            } catch {
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.status = error.localizedDescription
                self.loading = false
            }
        }
    }

    private func observe(_ doc: WorkspaceDocument) {
        subscriptions[doc.id] = doc.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func open(_ entry: WorkspaceFile) {
        if entry.directory {
            navigate(entry.path)
            return
        }
        let target = location
        perform {
            let path = try await target.service.resolve(entry.path)
            if let doc = self.documents.first(where: { $0.location === target && $0.path == path }) {
                self.selectedDocument = doc.id
            } else {
                let data = try await target.service.read(path)
                try Task.checkCancellation()
                let doc = try WorkspaceDocument(location: target, path: path, data: data)
                self.documents.append(doc)
                self.observe(doc)
                self.selectedDocument = doc.id
            }
            self.editorVisible = true
        }
    }

    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else {
            error = "Wait for the current file operation, or cancel it first."
            return
        }
        busy = true
        operation = Task { [weak self] in
            defer {
                self?.operation = nil
                self?.progress = nil
                self?.busy = false
            }
            do { try await action() } catch is CancellationError {
                self?.status = "Operation cancelled."
            } catch { if self?.closing != true { self?.error = error.localizedDescription } }
        }
    }

    func cancelOperation() { operation?.cancel() }

    func save(_ doc: WorkspaceDocument, overwrite: Bool = false, copyPath: String? = nil) {
        guard !doc.saving else { return }
        let snapshot = doc.encodedText
        guard snapshot.count <= WorkspacePath.textLimit else {
            error = "Text exceeds the 5 MiB editor limit."
            return
        }
        perform {
            doc.saving = true
            defer { doc.saving = false }
            do {
                try await doc.location.service.save(copyPath ?? doc.path, data: snapshot,
                                                    original: copyPath == nil ? doc.original : nil, overwrite: overwrite)
                if let copyPath { doc.path = copyPath }
                doc.original = snapshot
                doc.objectWillChange.send()
                self.refresh()
            } catch WorkspaceError.conflict {
                let alert = NSAlert()
                alert.messageText = "File changed on disk"
                alert.informativeText = "Your edits are still here. Reload discards them; overwrite replaces the current file."
                alert.addButton(withTitle: "Keep Editing")
                alert.addButton(withTitle: "Reload")
                alert.addButton(withTitle: "Overwrite")
                let choice = alert.runModal()
                if choice == .alertSecondButtonReturn {
                    let data = try await doc.location.service.read(doc.path)
                    try doc.reload(data)
                } else if choice == .alertThirdButtonReturn {
                    try await doc.location.service.save(doc.path, data: snapshot, original: nil, overwrite: true)
                    doc.original = snapshot
                    doc.objectWillChange.send()
                }
            }
        }
    }

    func closeDocument(_ doc: WorkspaceDocument) {
        guard !doc.saving else {
            error = "Wait for this file to finish saving."
            return
        }
        if doc.dirty, !Self.confirmDiscard("Close \(doc.title)?") { return }
        documents.removeAll { $0.id == doc.id }
        subscriptions.removeValue(forKey: doc.id)
        if selectedDocument == doc.id { selectedDocument = documents.last?.id }
    }

    func confirmClose() -> Bool {
        if documents.contains(where: { $0.saving }) {
            error = "Wait for files to finish saving before closing this workspace."
            return false
        }
        return !hasUnsavedChanges || Self.confirmDiscard("Discard unsaved file changes?")
    }

    static func confirmDiscard(_ title: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Choose Cancel to return to the editor and save your changes."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func shutdown() {
        guard !closing else { return }
        closing = true
        listing?.cancel()
        operation?.cancel()
        authentication?.cancel()
        var stopped = Set<UUID>()
        for target in Array(locations.values) + documents.map(\.location) {
            if stopped.insert(target.id).inserted { target.session?.stop() }
        }
    }
}
