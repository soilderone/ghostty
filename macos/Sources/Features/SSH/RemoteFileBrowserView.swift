import AppKit
import SwiftUI

/// A remote folder browser backed only by SSH commands. It never hands its path identifiers to
/// Finder, Quick Look or the local file browser, whose URLs have local filesystem semantics.
struct RemoteFileBrowserView: View {
    let connection: SSHConnection
    @ObservedObject var sidebars: TerminalSidebars
    @ObservedObject private var model: RemoteFileBrowserModel
    @State private var pathText = ""

    init(connection: SSHConnection, sidebars: TerminalSidebars) {
        self.connection = connection
        self.sidebars = sidebars
        self.model = sidebars.remoteFiles(for: connection)
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            FileSeparator()

            if let error = model.error {
                errorBar(error) { model.reload() }
            }

            if let error = sidebars.remoteError, sidebars.remoteDirectory == nil {
                errorBar(error) { sidebars.refreshRemoteDirectory() }
            }

            if sidebars.remoteDirectory == nil {
                FileMessage(
                    symbol: "network",
                    title: "Waiting for SSH",
                    detail: "Finish connecting in the terminal, then retry the remote directory.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let split = geometry.size.width >= 600 && !model.tabs.isEmpty
                    HStack(spacing: 0) {
                        if split || !model.showsPreview || model.tabs.isEmpty {
                            fileList
                                .frame(width: split ? max(220, geometry.size.width * 0.4) : nil)
                        }
                        if split {
                            Rectangle()
                                .fill(Color(nsColor: ChromePalette.separator))
                                .frame(width: 1)
                        }
                        if split || model.showsPreview && !model.tabs.isEmpty {
                            previewPane
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
        }
        .onAppear {
            if let path = sidebars.remoteDirectory {
                pathText = path
                model.load(path)
            } else if sidebars.remoteError == nil && !sidebars.isResolvingRemoteDirectory {
                sidebars.refreshRemoteDirectory()
            }
        }
        .onChange(of: sidebars.remoteDirectory) { path in
            guard let path else { return }
            pathText = path
            model.load(path)
        }
    }

    private var toolbar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                FileBarButton(symbol: "chevron.up", help: "Parent folder") {
                    guard let path = sidebars.remoteDirectory, path != "/" else { return }
                    sidebars.navigateRemote(to: URL(fileURLWithPath: path).deletingLastPathComponent().path)
                    model.showsPreview = false
                }
                .disabled(sidebars.remoteDirectory == nil || sidebars.remoteDirectory == "/")

                TextField("Remote path", text: $pathText)
                    .font(.system(size: 11, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(navigateTypedPath)

                FileBarButton(symbol: "arrow.right", help: "Go to remote path", action: navigateTypedPath)
                FileBarButton(symbol: "arrow.clockwise", help: "Reload remote folder") { model.reload() }
            }

            HStack(spacing: 6) {
                TextField("Filter this folder", text: $model.filter)
                    .font(.system(size: 11))
                    .textFieldStyle(.roundedBorder)

                Menu {
                    ForEach(FileSortKey.allCases, id: \.self) { key in
                        Button(key.title) { model.sortKey = key }
                    }
                    Divider()
                    Button(model.sortAscending ? "Descending" : "Ascending") {
                        model.sortAscending.toggle()
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 28)
                .help("Sort remote files")

                FileBarButton(
                    symbol: model.showsHidden ? "eye" : "eye.slash",
                    help: model.showsHidden ? "Hide dotfiles" : "Show dotfiles") {
                    model.showsHidden.toggle()
                }
                FileBarButton(symbol: "doc.badge.plus", help: "New remote file") {
                    if let name = prompt("New Remote File") { model.createFile(named: name) }
                }
                FileBarButton(symbol: "folder.badge.plus", help: "New remote folder") {
                    if let name = prompt("New Remote Folder") { model.createFolder(named: name) }
                }
            }
        }
        .padding(6)
        .disabled(model.isWorking)
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(12)
                }

                if sidebars.remoteDirectory != "/" {
                    Button {
                        guard let path = sidebars.remoteDirectory else { return }
                        sidebars.navigateRemote(to: URL(fileURLWithPath: path).deletingLastPathComponent().path)
                    } label: {
                        fileRow(symbol: "arrow.turn.up.left", name: "..", subtitle: nil, selected: false)
                    }
                    .buttonStyle(.plain)
                }

                ForEach(model.visibleEntries, id: \.url) { entry in
                    Button {
                        if entry.isDirectory {
                            sidebars.navigateRemote(to: entry.url.path)
                            model.showsPreview = false
                        } else {
                            model.open(entry.url.path)
                        }
                    } label: {
                        fileRow(
                            symbol: entry.isDirectory ? "folder" : "doc",
                            name: entry.name,
                            subtitle: entry.isDirectory ? nil : ByteCountFormatter.string(
                                fromByteCount: entry.size, countStyle: .file),
                            selected: model.activeTab == entry.url.path)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { contextMenu(for: entry) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileRow(symbol: String, name: String, subtitle: String?, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: ChromePalette.filesAccent))
                .frame(width: 18)
            Text(name)
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: ChromePalette.text))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(selected ? Color(nsColor: ChromePalette.selectionOverlay) : .clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func contextMenu(for entry: FileEntry) -> some View {
        Button("Copy Remote Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("\(connection.displayName):\(entry.url.path)", forType: .string)
        }
        if entry.isDirectory {
            Button("Go to Folder in SSH Terminal") {
                sidebars.files.actions.typeInTerminal(
                    "cd \(SSHConnection.shellQuote(entry.url.path))")
            }
        } else {
            Button("Edit in SSH Terminal") {
                sidebars.files.actions.typeInTerminal(
                    "${EDITOR:-vi} \(SSHConnection.shellQuote(entry.url.path))")
            }
        }
        Divider()
        Button("Rename…") {
            if let name = prompt("Rename Remote Item", initial: entry.name) {
                model.rename(entry.url.path, to: name)
            }
        }
        Button("Move…") {
            if let folder = prompt("Move to Remote Folder", initial: sidebars.remoteDirectory ?? "") {
                guard let destination = resolve(folder) else { return }
                Task { @MainActor in
                    do {
                        guard try await model.isDirectory(destination) else {
                            throw SSHCommandError(message: "The destination is not a folder.")
                        }
                        model.move(entry.url.path, into: destination)
                    } catch {
                        model.error = error.localizedDescription
                    }
                }
            }
        }
        Divider()
        Button("Move to Remote Trash…") {
            let alert = NSAlert()
            alert.messageText = "Move \(entry.name) to the remote Trash?"
            alert.informativeText = "The item will be moved to the Trash on \(connection.displayName)."
            alert.addButton(withTitle: "Move to Trash")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                model.trash(entry.url.path)
            }
        }
    }

    private var previewPane: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(model.tabs, id: \.self) { path in
                        HStack(spacing: 2) {
                            Button(URL(fileURLWithPath: path).lastPathComponent) {
                                model.activeTab = path
                                model.showsPreview = true
                            }
                            .buttonStyle(.plain)
                            .lineLimit(1)
                            Button { model.close(path) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 7)
                        .frame(height: 26)
                        .background(model.activeTab == path
                                    ? Color(nsColor: ChromePalette.selectionOverlay) : .clear)
                    }
                }
            }
            FileSeparator()

            if let path = model.activeTab {
                HStack(spacing: 6) {
                    if model.showsPreview {
                        FileBarButton(symbol: "chevron.left", help: "Back to remote files") {
                            model.showsPreview = false
                        }
                    }
                    Text(path.abbreviatedPath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                    FileBarButton(symbol: "arrow.clockwise", help: "Reload preview") { model.reload() }
                    FileBarButton(symbol: "terminal", help: "Edit in SSH terminal") {
                        sidebars.files.actions.typeInTerminal(
                            "${EDITOR:-vi} \(SSHConnection.shellQuote(path))")
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: 28)
                FileSeparator()
            }

            previewContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var previewContent: some View {
        switch model.preview {
        case nil:
            ProgressView().controlSize(.small)
        case .document(let document):
            if FilePreviewWebView.pageURL != nil {
                FilePreviewWebView(document: document, allowLocalFiles: false) { link in
                    guard link.scheme == "ssh" else { return }
                    Task { @MainActor in await openRemotePath(link.path) }
                }
            } else {
                FileMessage(symbol: "exclamationmark.triangle", title: "The preview page is missing")
            }
        case .image(let image):
            VStack(spacing: 8) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                    .font(.system(size: 11).monospacedDigit())
            }
            .padding(16)
        case .media:
            // The system's PDF and media viewers need a local file. Remote PDFs show as images
            // and the model never produces this.
            FileMessage(symbol: "doc", title: "Can't be previewed over SSH")
        case .directory:
            FileMessage(symbol: "folder", title: "This is a folder")
        case .tooLarge(let size):
            FileMessage(symbol: "doc", title: "Too large to preview",
                        detail: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        case .binary:
            FileMessage(symbol: "doc", title: "Binary file")
        case .missing:
            FileMessage(symbol: "questionmark.folder", title: "The remote file no longer exists")
        case .unreadable(let message):
            FileMessage(symbol: "exclamationmark.triangle", title: "Couldn't read the remote file", detail: message)
        }
    }

    private func errorBar(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Retry", action: retry)
        }
        .font(.system(size: 11))
        .foregroundColor(Color(nsColor: ChromePalette.error))
        .padding(8)
    }

    private func navigateTypedPath() {
        guard let path = resolve(pathText) else { return }
        Task { @MainActor in await openRemotePath(path) }
    }

    private func openRemotePath(_ path: String) async {
        do {
            if try await model.isDirectory(path) {
                sidebars.navigateRemote(to: path)
                model.showsPreview = false
            } else {
                sidebars.navigateRemote(to: URL(fileURLWithPath: path).deletingLastPathComponent().path)
                model.open(path)
            }
        } catch {
            model.error = error.localizedDescription
        }
    }

    private func resolve(_ typed: String) -> String? {
        SSHRemotePath.resolve(typed, current: sidebars.remoteDirectory, home: sidebars.remoteHome)
    }

    private func prompt(_ title: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
