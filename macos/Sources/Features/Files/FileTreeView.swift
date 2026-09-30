import AppKit
import SwiftUI

/// The file browser's tree: an outline view of the folder shown, with a ".." row to go up.
///
/// AppKit's outline view brings multiple selection in screen order (Shift for a range, Command
/// to toggle one row), dragging a selection, and the keyboard for free.
struct FileTreeView: NSViewRepresentable {
    @ObservedObject var model: FileBrowserModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = FileOutlineView()
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 22
        outline.style = .plain
        outline.backgroundColor = .clear
        outline.allowsMultipleSelection = true
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.openClicked(_:))
        outline.coordinator = context.coordinator
        outline.registerForDraggedTypes([.fileURL])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.setAccessibilityLabel("Files")

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        context.coordinator.outline = outline
        context.coordinator.reload()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.model = model
        if context.coordinator.revision != model.revision {
            context.coordinator.reload()
        }
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var model: FileBrowserModel
        weak var outline: FileOutlineView?
        var revision = -1

        /// One node per path, so the outline keeps its expansion across reloads.
        private var nodes: [URL: FileNode] = [:]
        private var nodesRoot: URL?
        private var parentNode: FileNode?
        private var expandTimer: Timer?

        /// The outline asks for a folder's children one index at a time, so the list is built
        /// once per folder and kept until the model's revision changes.
        private var childCache: [URL: [Any]] = [:]
        private var childCacheRevision = -1

        init(model: FileBrowserModel) {
            self.model = model
        }

        // MARK: Reloading

        func reload() {
            guard let outline else { return }
            revision = model.revision
            childCache = [:]
            if nodesRoot != model.root {
                nodes = [:]
                parentNode = nil
                nodesRoot = model.root
            }
            let selected = model.selection
            outline.reloadData()
            restoreExpansion(of: rootChildren(), in: outline)

            // Reloading keeps nodes that still exist expanded; keep their selection too.
            let rows = selected.compactMap { url in nodes[url].map { outline.row(forItem: $0) } }.filter { $0 >= 0 }
            outline.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
            pruneNodes()
        }

        /// Forgets the nodes of folders that are no longer open. Only the folders that were
        /// listed for this reload have children on screen, and a folder that opens later makes
        /// its nodes when it is listed.
        private func pruneNodes() {
            var current = Set<URL>()
            for children in childCache.values {
                for case let node as FileNode in children where !node.isParentLink {
                    current.insert(node.entry.url)
                }
            }
            if current.count < nodes.count {
                nodes = nodes.filter { current.contains($0.key) }
            }
        }

        /// Expands the folders the model has open. A new outline, such as after the browser's
        /// layout changes, starts with everything collapsed.
        private func restoreExpansion(of items: [Any], in outline: NSOutlineView) {
            for case let node as FileNode in items where !node.isParentLink && node.entry.isDirectory {
                guard model.isExpanded(node.entry.url) else { continue }
                if !outline.isItemExpanded(node) {
                    outline.expandItem(node)
                }
                restoreExpansion(of: children(of: node), in: outline)
            }
        }

        private func node(for entry: FileEntry) -> FileNode {
            if let node = nodes[entry.url] {
                node.entry = entry
                return node
            }
            let node = FileNode(entry: entry)
            nodes[entry.url] = node
            return node
        }

        private func rootChildren() -> [Any] {
            guard let root = model.root else { return [] }
            return cachedChildren(of: root) {
                var children: [Any] = []
                if root.path != "/" {
                    if parentNode == nil { parentNode = FileNode(parentOf: root) }
                    if let parentNode { children.append(parentNode) }
                }
                children += model.children(of: root).map(node(for:))
                return children
            }
        }

        private func children(of item: Any?) -> [Any] {
            guard let node = item as? FileNode else { return rootChildren() }
            guard node.entry.isDirectory, !node.isParentLink else { return [] }
            let directory = node.entry.url
            return cachedChildren(of: directory) {
                model.children(of: directory).map(node(for:))
            }
        }

        private func cachedChildren(of directory: URL, build: () -> [Any]) -> [Any] {
            if childCacheRevision != model.revision {
                childCache = [:]
                childCacheRevision = model.revision
            }
            if let cached = childCache[directory] { return cached }
            let children = build()
            childCache[directory] = children
            return children
        }

        // MARK: Data Source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(of: item)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? FileNode else { return false }
            return node.entry.isDirectory && !node.isParentLink
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("FileCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? FileCellView ?? FileCellView()
            cell.identifier = identifier
            cell.configure(node)
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outline else { return }
            model.selection = outline.selectedRowIndexes.compactMap { row in
                guard let node = outline.item(atRow: row) as? FileNode, !node.isParentLink else { return nil }
                return node.entry.url
            }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
            model.setExpanded(node.entry.url, true)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileNode else { return }
            model.setExpanded(node.entry.url, false)
        }

        // MARK: Opening

        @objc func openClicked(_ sender: Any?) {
            guard let outline, outline.clickedRow >= 0 else { return }
            open(row: outline.clickedRow)
        }

        func openSelection() {
            guard let outline, let row = outline.selectedRowIndexes.first else { return }
            open(row: row)
        }

        private func open(row: Int) {
            guard let outline, let node = outline.item(atRow: row) as? FileNode else { return }
            if node.isParentLink {
                model.goUp()
            } else if node.entry.isDirectory {
                if outline.isItemExpanded(node) {
                    outline.collapseItem(node)
                } else {
                    outline.expandItem(node)
                }
            } else {
                model.open(node.entry.url)
            }
        }

        func quickLookSelection() {
            guard let url = model.selection.first else { return }
            model.quickLookURL = url
        }

        // MARK: Context Menu

        func menu(forRow row: Int) -> NSMenu {
            let menu = NSMenu()
            let node = row >= 0 ? outline?.item(atRow: row) as? FileNode : nil
            let targets = model.selection

            // New items go in the folder clicked, next to the file clicked, or in the root.
            let folder: URL?
            if let node, !node.isParentLink {
                folder = node.entry.isDirectory ? node.entry.url : node.entry.url.deletingLastPathComponent()
            } else {
                folder = model.root
            }

            if let folder {
                menu.addItem(item("New File…") { [weak self] in self?.promptNewItem(folder: false, in: folder) })
                menu.addItem(item("New Folder…") { [weak self] in self?.promptNewItem(folder: true, in: folder) })
            }

            if !targets.isEmpty {
                menu.addItem(.separator())
                if targets.count == 1, let url = targets.first {
                    menu.addItem(item("Open") { [weak self] in self?.openURL(url) })
                    menu.addItem(item("Open with Default App") { _ = NSWorkspace.shared.open(url) })
                    menu.addItem(item("Quick Look") { [weak self] in self?.model.quickLookURL = url })
                    menu.addItem(item("Rename…") { [weak self] in self?.promptRename(url) })
                }
                menu.addItem(item(targets.count == 1 ? "Copy Path" : "Copy \(targets.count) Paths") { [weak self] in
                    self?.model.copyPaths(targets)
                })
                menu.addItem(item("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(targets) })
            }

            if let folder {
                let terminalFolder = targets.count == 1 && (node?.entry.isDirectory ?? false) ? targets[0] : folder
                menu.addItem(.separator())
                menu.addItem(item("Open in Terminal") { [weak self] in self?.model.actions.openTerminal(terminalFolder) })
            }

            if !targets.isEmpty {
                menu.addItem(.separator())
                menu.addItem(item(targets.count == 1 ? "Move to Trash" : "Move \(targets.count) Items to Trash") { [weak self] in
                    self?.acceptTrash(targets)
                })
            }
            return menu
        }

        private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let item = ClosureMenuItem(title: title, action: action)
            return item
        }

        private func openURL(_ url: URL) {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                model.navigate(to: url)
            } else {
                model.open(url)
            }
        }

        // MARK: Prompts

        private func promptNewItem(folder isFolder: Bool, in directory: URL) {
            guard let name = prompt(
                title: isFolder ? "New Folder" : "New File",
                message: "In \(directory.path.abbreviatedPath)",
                defaultValue: isFolder ? "untitled folder" : "untitled",
                confirm: "Create") else { return }
            perform {
                if isFolder {
                    try model.createFolder(named: name, in: directory)
                } else {
                    try model.createFile(named: name, in: directory)
                }
            }
        }

        private func promptRename(_ url: URL) {
            guard let name = prompt(
                title: "Rename",
                message: url.lastPathComponent,
                defaultValue: url.lastPathComponent,
                confirm: "Rename") else { return }
            perform { try model.rename(url, to: name) }
        }

        func acceptMove(_ urls: [URL], into directory: URL) {
            perform {
                let conflicts = try model.move(urls, into: directory)
                guard !conflicts.isEmpty else { return }
                let alert = NSAlert()
                alert.messageText = "Some items weren't moved"
                alert.informativeText = "\(directory.lastPathComponent) already has items named: \(conflicts.joined(separator: ", ")). Nothing was overwritten; the other items moved."
                alert.runModal()
            }
        }

        private func prompt(title: String, message: String, defaultValue: String, confirm: String) -> String? {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: confirm)
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(string: defaultValue)
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("/") else { return nil }
            return name
        }

        private func perform(_ body: () throws -> Void) {
            do {
                try body()
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }

        // MARK: Drag and Drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? FileNode, !node.isParentLink else { return nil }
            return node.entry.url as NSURL
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            // Only moves within the tree; files dragged in from elsewhere aren't taken.
            guard (info.draggingSource as? NSOutlineView) === outlineView else { return [] }

            let target = dropTarget(for: item)
            outlineView.setDropItem(target.item, dropChildIndex: NSOutlineViewDropOnItemIndex)

            // Hovering over a collapsed folder opens it.
            expandTimer?.invalidate()
            if let node = target.item as? FileNode, !node.isParentLink, !outlineView.isItemExpanded(node) {
                expandTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak outlineView] _ in
                    outlineView?.expandItem(node)
                }
            }
            return target.directory == nil ? [] : .move
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            expandTimer?.invalidate()
            guard let directory = dropTarget(for: item).directory else { return false }
            let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
            guard !urls.isEmpty else { return false }
            acceptMove(urls, into: directory)
            return true
        }

        /// Where a drop lands: into a folder, into the parent for "..", and otherwise into the
        /// folder that holds the row, or the root for empty space.
        private func dropTarget(for item: Any?) -> (item: Any?, directory: URL?) {
            guard let node = item as? FileNode else { return (nil, model.root) }
            if node.isParentLink { return (node, node.entry.url) }
            if node.entry.isDirectory { return (node, node.entry.url) }
            let parent = node.entry.url.deletingLastPathComponent()
            if parent == model.root { return (nil, parent) }
            return (nodes[parent], parent)
        }
    }
}

// MARK: Outline View

/// An outline item. One exists per path for the life of the tree.
final class FileNode: NSObject {
    var entry: FileEntry

    /// The ".." row, whose entry is the folder above the root.
    let isParentLink: Bool

    init(entry: FileEntry) {
        self.entry = entry
        self.isParentLink = false
    }

    init?(parentOf root: URL) {
        guard let entry = FileEntry(url: root.deletingLastPathComponent()) else { return nil }
        self.entry = entry
        self.isParentLink = true
    }
}

/// The outline view, with the file browser's keys and context menu.
final class FileOutlineView: NSOutlineView {
    weak var coordinator: FileTreeView.Coordinator?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: // space
            coordinator?.quickLookSelection()
        case 36, 76: // return, enter
            coordinator?.openSelection()
        case 51 where event.modifierFlags.contains(.command): // command-delete
            if let urls = coordinator?.model.selection, !urls.isEmpty {
                coordinator?.acceptTrash(urls)
            }
        case 31 where event.modifierFlags.contains(.command): // command-O
            coordinator?.model.isQuickOpenShown = true
        default:
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))

        // Right-clicking outside the selection acts on the clicked row alone, like the Finder.
        if row >= 0 && !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return coordinator?.menu(forRow: row)
    }
}

extension FileTreeView.Coordinator {
    /// Deleting asks once, however many files are selected.
    func acceptTrash(_ urls: [URL]) {
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? "Move \u{201C}\(urls[0].lastPathComponent)\u{201D} to the Trash?"
            : "Move \(urls.count) items to the Trash?"
        alert.informativeText = "You can put them back from the Trash in the Finder."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try model.trash(urls)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// A row with an outline icon in the panel's palette. Dotfiles are dimmed.
final class FileCellView: NSTableCellView {
    private let icon = NSImageView()
    private let aliasIcon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        aliasIcon.translatesAutoresizingMaskIntoConstraints = false
        aliasIcon.image = NSImage(systemSymbolName: "arrow.turn.up.right", accessibilityDescription: nil)
        aliasIcon.contentTintColor = ChromePalette.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.font = .systemFont(ofSize: 12)
        addSubview(icon)
        addSubview(aliasIcon)
        addSubview(label)
        imageView = icon
        textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            aliasIcon.trailingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 2),
            aliasIcon.bottomAnchor.constraint(equalTo: icon.bottomAnchor),
            aliasIcon.widthAnchor.constraint(equalToConstant: 8),
            aliasIcon.heightAnchor.constraint(equalToConstant: 8),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ node: FileNode) {
        aliasIcon.isHidden = node.isParentLink || !node.entry.isSymbolicLink
        if node.isParentLink {
            icon.image = NSImage(systemSymbolName: "arrow.turn.left.up", accessibilityDescription: "Up")
            icon.contentTintColor = ChromePalette.secondaryText
            label.stringValue = ".."
            label.textColor = ChromePalette.secondaryText
            toolTip = node.entry.url.path
            return
        }

        let style = FileIconStyle(name: node.entry.name, isDirectory: node.entry.isDirectory)
        icon.image = style.image
        icon.contentTintColor = node.entry.isHidden ? style.color.withAlphaComponent(0.55) : style.color
        label.stringValue = node.entry.name
        label.textColor = node.entry.isHidden ? ChromePalette.tertiaryText : ChromePalette.text
        toolTip = node.entry.url.path
    }
}
