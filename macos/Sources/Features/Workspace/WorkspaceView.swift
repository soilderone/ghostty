import AppKit
import SwiftUI

@MainActor
struct TerminalWorkspaceView<Content: View>: View {
    @ObservedObject var model: WorkspaceModel
    let connect: (WorkspaceSSHProfile, WorkspaceLocation?) -> Void
    @ViewBuilder let terminal: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    model.visible.toggle()
                    if model.visible { model.refresh() }
                } label: {
                    Label("Files", systemImage: "sidebar.left")
                }
                Button("SSH") {
                    model.visible = true
                    model.section = "SSH"
                }
                if !model.documents.isEmpty {
                    Button { model.editorVisible.toggle() } label: { Label("Editor", systemImage: "doc.text") }
                }
                Spacer()
                if model.busy {
                    if let progress = model.progress { ProgressView(value: progress).frame(width: 90) }
                    else { ProgressView().controlSize(.small) }
                    Button("Cancel", action: model.cancelOperation)
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            HSplitView {
                if model.visible {
                    VStack(spacing: 8) {
                        Picker("Sidebar", selection: $model.section) {
                            Text("Files").tag("Files")
                            Text("SSH").tag("SSH")
                        }.pickerStyle(.segmented).padding([.horizontal, .top], 8)
                        if model.section == "Files" {
                            WorkspaceFilesView(model: model, reconnect: {
                                if let profile = model.location.session?.profile { connect(profile, model.location) }
                            })
                        } else { WorkspaceConnectionsView(model: model, connect: { connect($0, nil) }) }
                    }
                    .frame(minWidth: 220, idealWidth: 270, maxWidth: 450)
                }
                VSplitView {
                    if model.editorVisible, let doc = model.activeDocument {
                        WorkspaceEditorView(model: model, document: doc)
                            .frame(minHeight: 120, idealHeight: 300)
                    }
                    terminal().frame(minWidth: 180, minHeight: 100)
                }
            }
        }
        .alert("Files", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}

@MainActor
private struct WorkspaceFilesView: View {
    @ObservedObject var model: WorkspaceModel
    let reconnect: () -> Void
    @State private var path = ""
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.location.label).font(.headline).padding(.horizontal, 8)
            HStack {
                Button { model.navigate((model.location.path as NSString).deletingLastPathComponent) } label: {
                    Image(systemName: "arrow.up")
                }.help("Parent folder")
                TextField("Directory", text: $path).onSubmit { model.navigate(path) }
                Button(action: model.refresh) { Image(systemName: "arrow.clockwise") }.help("Refresh")
            }.padding(.horizontal, 8)
            HStack {
                Menu {
                    Button("New File…") { create(directory: false) }
                    Button("New Folder…") { create(directory: true) }
                    Button("Upload File…", action: upload)
                } label: { Image(systemName: "plus") }
                Toggle("Hidden", isOn: $model.showHidden).toggleStyle(.checkbox)
            }.padding(.horizontal, 8)
            Toggle("Follow terminal directory", isOn: Binding(get: { model.following }, set: model.setFollowing))
                .toggleStyle(.checkbox).disabled(model.location.session != nil).padding(.horizontal, 8)
            if model.location.session != nil {
                Text("Remote directory following is not available yet.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            if model.loading { ProgressView().controlSize(.small).padding(.horizontal, 8) }
            List(selection: $selected) {
                ForEach(model.entries.filter { model.showHidden || !$0.name.hasPrefix(".") }) { entry in
                    Label(entry.name, systemImage: entry.directory ? "folder" : (entry.symbolicLink ? "link" : "doc"))
                        .tag(entry.path)
                        .onTapGesture(count: 2) { model.open(entry) }
                        .contextMenu {
                            Button("Open") { model.open(entry) }
                            Button("Rename…") { rename(entry) }
                            if !entry.directory { Button("Download…") { download(entry) } }
                            Button("Delete…") { remove(entry) }
                        }
                }
            }
            .onKeyPressIfAvailable { if let entry = model.entries.first(where: { $0.path == selected }) { model.open(entry) } }
            if !model.status.isEmpty {
                Text(model.status).font(.caption).textSelection(.enabled).padding(8)
                if model.location.session != nil { Button("Reconnect in New Tab", action: reconnect).padding(.horizontal, 8) }
            }
        }
        .onAppear { path = model.location.path }
        .onChange(of: model.location.path) { path = $0 }
        .onChange(of: model.location.id) { _ in
            path = model.location.path
            selected = nil
        }
    }

    private func create(directory: Bool) {
        guard let name = WorkspacePrompt.text(directory ? "New Folder" : "New File", value: "") else { return }
        let target = model.location
        let parent = target.path
        model.perform {
            let path = try WorkspacePath.child(name, in: parent)
            try await target.service.create(path, directory: directory)
            model.refresh()
        }
    }

    private func rename(_ entry: WorkspaceFile) {
        guard let name = WorkspacePrompt.text("Rename", value: entry.name) else { return }
        let target = model.location
        if model.documents.contains(where: { $0.location === target && ($0.path == entry.path || $0.path.hasPrefix(entry.path + "/")) }) {
            model.error = "Close files inside this item before renaming it."
            return
        }
        model.perform {
            let destination = try WorkspacePath.child(name, in: (entry.path as NSString).deletingLastPathComponent)
            try await target.service.rename(entry.path, to: destination)
            model.refresh()
        }
    }

    private func remove(_ entry: WorkspaceFile) {
        let target = model.location
        let alert = NSAlert()
        alert.messageText = "Delete \(entry.name)?"
        alert.informativeText = target.session == nil ? "The item will be moved to the Trash. Only empty folders are supported." :
            "Remote deletion is permanent. Only files and empty folders are supported."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        if model.documents.contains(where: { $0.location === target && ($0.path == entry.path || $0.path.hasPrefix(entry.path + "/")) }) {
            model.error = "Close files inside this item before deleting it."
            return
        }
        model.perform {
            try await target.service.remove(entry.path, directory: entry.directory)
            model.refresh()
        }
    }

    private func download(_ entry: WorkspaceFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let service = model.location.service
        // Transfers never overwrite an existing destination, even if the save panel
        // offered replacement; use an explicit new name to avoid partial replacement.
        model.perform {
            model.progress = 0
            try await service.download(entry.path, to: url) { value in
                Task { @MainActor in if model.busy { model.progress = value } }
            }
        }
    }

    private func upload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let target = model.location
        let parent = target.path
        model.perform {
            let path = try WorkspacePath.child(url.lastPathComponent, in: parent)
            model.progress = 0
            try await target.service.upload(url, to: path) { value in
                Task { @MainActor in if model.busy { model.progress = value } }
            }
            model.refresh()
        }
    }
}

@MainActor
private struct WorkspaceConnectionsView: View {
    @ObservedObject var model: WorkspaceModel
    @ObservedObject private var store = WorkspaceSSHStore.shared
    let connect: (WorkspaceSSHProfile) -> Void
    @State private var editing: WorkspaceSSHProfile?

    var body: some View {
        VStack {
            List(store.profiles) { profile in
                HStack {
                    VStack(alignment: .leading) {
                        Text(profile.name.isEmpty ? profile.host : profile.name)
                        Text(profile.host).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { connect(profile) } label: { Image(systemName: "arrow.right.circle") }.help("Connect")
                }
                .contextMenu {
                    Button("Edit…") { editing = profile }
                    Button("Remove") { do { try store.remove(profile) } catch { model.error = error.localizedDescription } }
                }
            }
            if let error = store.error { Text(error).font(.caption).padding(8) }
            Button("Add SSH Connection…") { editing = WorkspaceSSHProfile() }.padding(8)
        }
        .sheet(item: $editing) { profile in
            WorkspaceProfileForm(profile: profile) { value in
                do {
                    try store.save(value)
                    editing = nil
                } catch { model.error = error.localizedDescription }
            }
        }
    }
}

@MainActor
private struct WorkspaceProfileForm: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: WorkspaceSSHProfile
    let save: (WorkspaceSSHProfile) -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SSH Connection").font(.headline)
            Form {
                TextField("Name", text: $profile.name)
                TextField("Host or SSH config alias", text: $profile.host)
                TextField("User (optional)", text: $profile.user)
                TextField("Port (optional)", text: $profile.port)
                TextField("Identity file (optional)", text: $profile.identityFile)
                TextField("Initial remote directory", text: $profile.directory)
            }
            Text("Uses ~/.ssh/config and ssh-agent. Passwords and host verification are handled in the terminal; passwords are not saved.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        try profile.validate()
                        save(profile)
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 440)
    }
}

enum WorkspacePrompt {
    @MainActor static func text(_ title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let input = NSTextField(string: value)
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        return alert.runModal() == .alertFirstButtonReturn ? input.stringValue : nil
    }
}

private extension View {
    @ViewBuilder func onKeyPressIfAvailable(_ action: @escaping () -> Void) -> some View {
        if #available(macOS 14.0, *) {
            self.onKeyPress(.return) {
                action()
                return .handled
            }
        } else {
            self
        }
    }
}
