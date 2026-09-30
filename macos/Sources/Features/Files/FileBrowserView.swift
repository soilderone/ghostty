import AppKit
import QuickLook
import SwiftUI

/// The file browser (feature 10), in the leading sidebar: a tree of the focused terminal's
/// directory, and a preview with a tab per opened file.
///
/// The tree and the preview sit side by side when the sidebar is wide enough, with a divider
/// that can be dragged or collapsed, and take turns otherwise.
struct FileBrowserView: View {
    @ObservedObject var model: FileBrowserModel
    let directory: URL?

    @State private var pathEditing = FilePathEditing()
    @State private var showsFilter = false
    @State private var treeWidth: CGFloat = 240
    @State private var treeCollapsed = false

    /// The narrowest sidebar that shows the tree and the preview side by side.
    private static let sideBySideWidth: CGFloat = 560
    private static let minimumTreeWidth: CGFloat = 150
    private static let minimumPreviewWidth: CGFloat = 240

    var body: some View {
        VStack(spacing: 0) {
            FileBrowserToolbar(model: model, pathEditing: $pathEditing, showsFilter: $showsFilter)
            if pathEditing.isEditing && !pathEditing.completions.isEmpty {
                FileSeparator()
                FileCompletionList(
                    completions: pathEditing.completions,
                    highlighted: pathEditing.highlighted
                ) { completion in
                    pathEditing.go(to: completion, model)
                }
            }
            if showsFilter {
                FileFilterBar(model: model, isShown: $showsFilter)
            }
            FileSeparator()

            GeometryReader { geo in
                content(width: geo.size.width)
            }
        }
        .quickLookPreview($model.quickLookURL)
        .onAppear { model.terminalDirectoryDidChange(directory) }
        .onChange(of: directory) { model.terminalDirectoryDidChange($0) }
        .onChange(of: model.root) { _ in pathEditing.stop() }
    }

    private enum Layout {
        case tree
        case preview
        case split
        case quickOpen
    }

    private func currentLayout(width: CGFloat) -> Layout {
        if model.isQuickOpenShown { return .quickOpen }
        if model.tabs.isEmpty || model.activeTab == nil { return .tree }
        if width >= Self.sideBySideWidth { return .split }
        return model.showsPreview ? .preview : .tree
    }

    /// The tree stays in the view in every layout, at zero width when hidden, so it keeps its
    /// scroll position and selection.
    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        let layout = currentLayout(width: width)
        HStack(spacing: 0) {
            FileTreeView(model: model)
                .frame(width: treeFrameWidth(layout, total: width))
                .frame(maxWidth: layout == .tree ? CGFloat.infinity : nil)
                .opacity(treeFrameWidth(layout, total: width) == 0 ? 0 : 1)

            switch layout {
            case .tree:
                EmptyView()
            case .split:
                FileSplitDivider(
                    width: $treeWidth,
                    collapsed: $treeCollapsed,
                    range: Self.minimumTreeWidth...max(Self.minimumTreeWidth, width - Self.minimumPreviewWidth))
                FilePreviewArea(model: model, narrow: false, treeCollapsed: $treeCollapsed)
            case .preview:
                FilePreviewArea(model: model, narrow: true, treeCollapsed: $treeCollapsed)
            case .quickOpen:
                FileQuickOpenView(model: model)
            }
        }
    }

    /// Nil lets the tree fill the sidebar.
    private func treeFrameWidth(_ layout: Layout, total: CGFloat) -> CGFloat? {
        switch layout {
        case .tree:
            return nil
        case .split:
            if treeCollapsed { return 0 }
            let maximum = max(Self.minimumTreeWidth, total - Self.minimumPreviewWidth)
            return min(max(treeWidth, Self.minimumTreeWidth), maximum)
        case .preview, .quickOpen:
            return 0
        }
    }
}

// MARK: Toolbar

private struct FileBrowserToolbar: View {
    @ObservedObject var model: FileBrowserModel
    @Binding var pathEditing: FilePathEditing
    @Binding var showsFilter: Bool

    var body: some View {
        HStack(spacing: 2) {
            FileBarButton(symbol: "chevron.up", help: "Enclosing Folder") { model.goUp() }
                .disabled(model.root == nil || model.root?.path == "/")

            FilePathBar(model: model, editing: $pathEditing)

            if model.isAwayFromTerminal {
                FileBarButton(symbol: "location", help: "Show the Terminal's Directory") {
                    model.showTerminalDirectory()
                }
            }
            FileBarButton(symbol: "magnifyingglass", help: "Open File by Name (⌘O in the tree)") {
                model.isQuickOpenShown.toggle()
            }
            FileBarButton(
                symbol: "line.3.horizontal.decrease",
                help: "Filter",
                isOn: showsFilter || !model.filter.isEmpty
            ) {
                showsFilter.toggle()
                if !showsFilter { model.filter = "" }
            }
            FileViewMenu(model: model)
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
    }
}

/// Sorting and hidden files.
private struct FileViewMenu: View {
    @ObservedObject var model: FileBrowserModel

    var body: some View {
        Menu {
            Picker("Sort By", selection: $model.sortKey) {
                ForEach(FileSortKey.allCases, id: \.self) { key in
                    Text(key.title).tag(key)
                }
            }
            .pickerStyle(.inline)

            Picker("Order", selection: $model.sortAscending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            .pickerStyle(.inline)

            Divider()
            Toggle("Show Hidden Files", isOn: $model.showsHidden)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 24, height: 22)
        .help("Sort and View Options")
    }
}

// MARK: Path Bar

/// The path bar's editing state. The field takes `~`, absolute paths and paths relative to
/// the folder shown; the completions under it list what the typed path could complete to.
struct FilePathEditing {
    var isEditing = false
    var text = ""
    var completions: [String] = []
    var highlighted: Int?

    mutating func start(_ model: FileBrowserModel) {
        guard let root = model.root else { return }
        let path = root.path.abbreviatedPath
        text = path.hasSuffix("/") ? path : path + "/"
        completions = model.completions(for: text)
        highlighted = nil
        isEditing = true
    }

    mutating func stop() {
        isEditing = false
        completions = []
        highlighted = nil
    }

    mutating func textDidChange(_ model: FileBrowserModel) {
        guard isEditing else { return }
        completions = model.completions(for: text)
        highlighted = nil
    }

    /// Handles a key from the field, and returns whether it did.
    mutating func handle(_ command: TextFieldCommand, _ model: FileBrowserModel) -> Bool {
        switch command {
        case .submit:
            go(to: highlighted.map { completions[$0] } ?? text, model)
        case .cancel:
            if highlighted != nil {
                highlighted = nil
            } else {
                stop()
            }
        case .complete:
            complete()
        case .moveDown:
            guard !completions.isEmpty else { return false }
            highlighted = highlighted.map { min($0 + 1, completions.count - 1) } ?? 0
        case .moveUp:
            guard let current = highlighted else { return false }
            highlighted = current == 0 ? nil : current - 1
        }
        return true
    }

    /// Tab takes the highlighted completion, or the only one, or as much as all of them
    /// share, as a shell does.
    private mutating func complete() {
        if let highlighted {
            text = completions[highlighted]
            return
        }
        guard let first = completions.first else { return }
        if completions.count == 1 {
            text = first
            return
        }
        let shared = completions.dropFirst().reduce(first) { prefix, completion in
            String(zip(prefix, completion).prefix { $0.0 == $0.1 }.map { $0.0 })
        }
        if shared.count > text.count {
            text = shared
        }
    }

    /// Shows a folder, or a file's folder with the file open. A path that doesn't exist is
    /// refused and the field stays up.
    mutating func go(to typed: String, _ model: FileBrowserModel) {
        guard let url = model.resolve(typed) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            NSSound.beep()
            return
        }
        stop()
        if isDirectory.boolValue {
            model.navigate(to: url)
        } else {
            model.navigate(to: url.deletingLastPathComponent())
            model.open(url)
        }
    }
}

/// The folder shown, which turns into a field on click.
private struct FilePathBar: View {
    @ObservedObject var model: FileBrowserModel
    @Binding var editing: FilePathEditing

    var body: some View {
        Group {
            if editing.isEditing {
                CommandTextField(
                    text: $editing.text,
                    placeholder: "Path",
                    font: .monospacedSystemFont(ofSize: 11.5, weight: .regular),
                    focusOnAppear: true,
                    onCommand: { editing.handle($0, model) },
                    onEndEditing: {
                        // Deferred so the field isn't torn down while AppKit is still
                        // ending its editing session.
                        DispatchQueue.main.async { editing.stop() }
                    })
                    .frame(height: 22)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(nsColor: ChromePalette.raised)))
            } else {
                Button {
                    editing.start(model)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: ChromePalette.filesAccent))
                        Text(model.root?.path.abbreviatedPath ?? "")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(Color(nsColor: ChromePalette.text))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.root.map { "\($0.path) (click to type a path)" } ?? "")
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: editing.text) { _ in editing.textDidChange(model) }
    }
}

/// The completions under the path bar while it is edited.
private struct FileCompletionList: View {
    let completions: [String]
    let highlighted: Int?
    let onChoose: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(completions.enumerated()), id: \.offset) { index, completion in
                Button {
                    onChoose(completion)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: completion.hasSuffix("/") ? "folder" : "doc")
                            .font(.system(size: 10))
                            .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
                            .frame(width: 14)
                        Text(completion)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(Color(nsColor: ChromePalette.text))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                    .background(index == highlighted ? Color(nsColor: ChromePalette.selectionOverlay) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
        .background(Color(nsColor: ChromePalette.panelHeader))
    }
}

// MARK: Filter

private struct FileFilterBar: View {
    @ObservedObject var model: FileBrowserModel
    @Binding var isShown: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 10))
                .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
            CommandTextField(
                text: $model.filter,
                placeholder: "Filter by name",
                focusOnAppear: true,
                onCommand: { command in
                    guard command == .cancel else { return false }
                    model.filter = ""
                    isShown = false
                    return true
                })
                .frame(height: 20)
            FileBarButton(
                symbol: model.showsHidden ? "eye" : "eye.slash",
                help: model.showsHidden ? "Hide Hidden Files" : "Show Hidden Files",
                isOn: model.showsHidden
            ) {
                model.showsHidden.toggle()
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
    }
}

// MARK: Preview

/// The preview side: a tab per opened file over the active file's preview.
private struct FilePreviewArea: View {
    @ObservedObject var model: FileBrowserModel
    let narrow: Bool
    @Binding var treeCollapsed: Bool

    var body: some View {
        VStack(spacing: 0) {
            FileTabStrip(model: model, narrow: narrow, treeCollapsed: $treeCollapsed)
            FileSeparator()
            if let url = model.activeTab {
                FilePreviewPane(url: url, model: model)
            }
        }
        .background(Color(nsColor: ChromePalette.panel))
    }
}

private struct FileTabStrip: View {
    @ObservedObject var model: FileBrowserModel
    let narrow: Bool
    @Binding var treeCollapsed: Bool

    var body: some View {
        HStack(spacing: 0) {
            if narrow {
                FileBarButton(symbol: "chevron.left", help: "Back to the Files") { model.showsPreview = false }
                    .padding(.horizontal, 4)
            } else {
                FileBarButton(
                    symbol: "sidebar.left",
                    help: treeCollapsed ? "Show the Files" : "Hide the Files",
                    isOn: !treeCollapsed
                ) {
                    treeCollapsed.toggle()
                }
                .padding(.horizontal, 4)
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(model.tabs, id: \.self) { url in
                            FileTab(url: url, model: model, isActive: url == model.activeTab)
                                .id(url)
                        }
                    }
                }
                .onChange(of: model.activeTab) { active in
                    guard let active else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(active) }
                }
            }
        }
        .frame(height: 30)
        .background(Color(nsColor: ChromePalette.panelHeader))
    }
}

/// A tab in the preview, drawn like an editor's: the active one takes the page's color and an
/// accent line along its top.
private struct FileTab: View {
    let url: URL
    @ObservedObject var model: FileBrowserModel
    let isActive: Bool

    @State private var isHovered = false
    @ObservedObject private var chromeAccent = ChromeAccent.shared
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        HStack(spacing: 5) {
            FileIcon(name: url.lastPathComponent)
            Text(url.lastPathComponent)
                .font(.system(size: 11.5, weight: isActive ? .medium : .regular))
                .foregroundColor(Color(nsColor: isActive ? ChromePalette.text : ChromePalette.secondaryText))
                .lineLimit(1)

            Button {
                model.closeTab(url)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(isActive || isHovered ? 1 : 0)
            .help("Close")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(maxHeight: .infinity)
        .background(background)
        .overlay(alignment: .top) {
            if isActive {
                Rectangle()
                    .fill(chromeAccent.color(for: .files, inKeyWindow: controlActiveState == .key))
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: ChromePalette.separator))
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.activeTab = url }
        .onHover { isHovered = $0 }
        .help(url.path.abbreviatedPath)
        .contextMenu {
            Button("Close") { model.closeTab(url) }
            Button("Close Other Tabs") { model.closeOtherTabs(url) }
                .disabled(model.tabs.count < 2)
            Divider()
            Button("Copy Path") { model.copyPaths([url]) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private var background: Color {
        if isActive { return Color(nsColor: ChromePalette.panel) }
        if isHovered { return Color(nsColor: ChromePalette.hoverOverlay) }
        return .clear
    }
}

/// The line between the tree and the preview. Dragging it resizes the tree, dragging it far
/// enough left collapses the tree, and double-clicking it collapses or restores the tree.
private struct FileSplitDivider: View {
    @Binding var width: CGFloat
    @Binding var collapsed: Bool
    let range: ClosedRange<CGFloat>

    @State private var dragStart: CGFloat?
    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: isHovered || dragStart != nil ? ChromePalette.strongSeparator : ChromePalette.separator))
            .frame(width: 1)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onTapGesture(count: 2) { collapsed.toggle() }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? (collapsed ? 0 : width)
                        dragStart = start
                        let proposed = start + value.translation.width
                        if proposed < range.lowerBound / 2 {
                            collapsed = true
                        } else {
                            collapsed = false
                            width = min(max(proposed, range.lowerBound), range.upperBound)
                        }
                    }
                    .onEnded { _ in dragStart = nil })
    }
}

// MARK: Pieces

/// A small icon button for the browser's bars.
struct FileBarButton: View {
    let symbol: String
    let help: String
    var isOn = false
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(nsColor: isOn ? ChromePalette.filesAccent : ChromePalette.secondaryText))
                .frame(width: 24, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovered && isEnabled ? Color(nsColor: ChromePalette.hoverOverlay) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

struct FileMessage: View {
    let symbol: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
                    .textSelection(.enabled)
            }
        }
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct FileSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: ChromePalette.separator))
            .frame(height: 1)
    }
}
