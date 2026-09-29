import AppKit
import SwiftUI

/// The Git view (feature 9): a read-only look at the repository of the focused terminal's
/// directory, in the trailing sidebar. The Changes page lists the working tree's changes with
/// their diffs; the History page draws the commit graph with each commit's details and diffs.
///
/// Lists and diffs sit side by side when the sidebar is wide enough, and take turns otherwise.
struct GitView: View {
    @ObservedObject var model: GitViewModel
    let directory: URL?
    let connection: SSHConnection?
    let isCovered: Bool

    @Environment(\.controlActiveState) private var controlActiveState
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            if model.isRepository == true, let status = model.status {
                GitToolbar(model: model, status: status)
                GitSeparator()
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            hasAppeared = true
            model.setDirectory(directory, connection: connection)
            model.setWindowActive(controlActiveState == .key)
            model.setVisible(!isCovered)
        }
        .onDisappear {
            hasAppeared = false
            model.setVisible(false)
        }
        .onChange(of: directory) { model.setDirectory($0, connection: connection) }
        .onChange(of: connection) { model.setDirectory(directory, connection: $0) }
        .onChange(of: controlActiveState) { model.setWindowActive($0 == .key) }
        .onChange(of: isCovered) { if hasAppeared { model.setVisible(!$0) } }
    }

    @ViewBuilder
    private var content: some View {
        if let directory {
            if let error = model.error {
                GitMessage(symbol: "exclamationmark.triangle", title: "Git failed", detail: error, retry: model.refresh)
            } else if model.isRepository == false {
                GitMessage(symbol: "arrow.triangle.branch", title: "Not a git repository", detail: directory.path.abbreviatedPath)
            } else if model.status == nil {
                ProgressView()
                    .controlSize(.small)
            } else {
                GeometryReader { geo in
                    switch model.page {
                    case .changes:
                        GitChangesPage(model: model, wide: geo.size.width >= 640)
                    case .history:
                        GitHistoryPage(model: model, wide: geo.size.width >= 720)
                    }
                }
            }
        } else {
            GitMessage(
                symbol: "folder.badge.questionmark",
                title: "No directory",
                detail: "The focused terminal hasn't reported its directory. Shell integration reports it at each prompt.")
        }
    }
}

// MARK: Toolbar

private struct GitToolbar: View {
    @ObservedObject var model: GitViewModel
    let status: GitStatus

    private var branchTitle: String {
        if let branch = status.branch { return branch }
        if let head = status.head { return "HEAD at \(head.prefix(8))" }
        return "No commits yet"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
                Text(branchTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(nsColor: ChromePalette.text))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(status.upstream.map { "Tracking \($0)" } ?? branchTitle)

                if status.ahead > 0 {
                    GitCount(symbol: "arrow.up", count: status.ahead)
                        .help("\(status.ahead) commits ahead of the upstream")
                }
                if status.behind > 0 {
                    GitCount(symbol: "arrow.down", count: status.behind)
                        .help("\(status.behind) commits behind the upstream")
                }
                if let state = status.state {
                    Text(state.title.uppercased())
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(Color(nsColor: ChromePalette.warning))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: ChromePalette.warning).opacity(0.14)))
                }

                Spacer(minLength: 0)

                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }

            Picker("Page", selection: $model.page) {
                Text("Changes").tag(GitViewModel.Page.changes)
                Text("History").tag(GitViewModel.Page.history)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct GitCount: View {
    let symbol: String
    let count: Int

    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 11).monospacedDigit())
        }
        .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
    }
}

// MARK: Changes

private struct GitChangesPage: View {
    @ObservedObject var model: GitViewModel
    let wide: Bool

    var body: some View {
        if wide {
            HStack(spacing: 0) {
                GitChangeList(model: model)
                    .frame(width: 280)
                GitSeparator(vertical: true)
                if let change = model.selectedChange {
                    GitDiffPane(title: change.file.path, state: model.changeDiff)
                } else {
                    GitMessage(symbol: "doc.text.magnifyingglass", title: "Select a file to see its changes")
                }
            }
        } else if let change = model.selectedChange {
            GitDiffPane(title: change.file.path, state: model.changeDiff) {
                model.selectedChange = nil
            }
        } else {
            GitChangeList(model: model)
        }
    }
}

private struct GitChangeList: View {
    @ObservedObject var model: GitViewModel

    var body: some View {
        if let status = model.status, status.files.isEmpty {
            GitMessage(symbol: "checkmark.circle", title: "No changes", detail: "The working tree is clean.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(GitChangeGroup.allCases, id: \.self) { group in
                        let changes = model.status?.changes(in: group) ?? []
                        if !changes.isEmpty {
                            Section {
                                ForEach(changes) { change in
                                    GitFileRow(
                                        letter: change.letter,
                                        path: change.file.path,
                                        originalPath: change.file.originalPath,
                                        isSelected: model.selectedChange == change)
                                    .onTapGesture { model.selectedChange = change }
                                }
                            } header: {
                                GitSectionHeader(title: group.title, count: changes.count)
                            }
                        }
                    }

                    if model.status?.truncated == true {
                        GitNote(text: "Only the first part of the list is shown; git listed more than 4 MB.")
                    }
                }
            }
        }
    }
}

private struct GitSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
            Text("\(count)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Color(nsColor: ChromePalette.panel))
    }
}

/// A file in a list: its status letter, its name, and the folder it is in.
private struct GitFileRow: View {
    let letter: Character
    let path: String
    var originalPath: String?
    let isSelected: Bool

    @State private var isHovered = false

    private var name: String { (path as NSString).lastPathComponent }
    private var folder: String { (path as NSString).deletingLastPathComponent }

    var body: some View {
        HStack(spacing: 8) {
            Text(String(letter))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(gitStatusColor(letter))
                .frame(width: 12)

            Text(name)
                .foregroundColor(Color(nsColor: ChromePalette.text))
                .lineLimit(1)
                .layoutPriority(1)

            if !folder.isEmpty {
                Text(folder)
                    .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(rowBackground(isSelected: isSelected, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(originalPath.map { "\($0) → \(path)" } ?? path)
    }
}

// MARK: History

private struct GitHistoryPage: View {
    @ObservedObject var model: GitViewModel
    let wide: Bool

    var body: some View {
        if wide {
            HStack(spacing: 0) {
                GitCommitList(model: model)
                GitSeparator(vertical: true)
                detail
                    .frame(width: 340)
            }
        } else if model.selectedCommit != nil {
            detail
        } else {
            GitCommitList(model: model)
        }
    }

    @ViewBuilder
    private var detail: some View {
        let back: (() -> Void)? = wide ? nil : { model.selectedCommit = nil }
        if let file = model.selectedCommitFile {
            GitDiffPane(title: file.path, state: model.commitFileDiff) {
                model.selectedCommitFile = nil
            }
        } else if let detail = model.commitDetail {
            GitCommitDetailView(detail: detail, onBack: back) { file in
                model.selectedCommitFile = file
            }
        } else if let error = model.commitDetailError {
            VStack(spacing: 0) {
                if let back {
                    GitBackBar(title: "Commit", onBack: back)
                    GitSeparator()
                }
                GitMessage(
                    symbol: "exclamationmark.triangle",
                    title: "Can't load the commit",
                    detail: error,
                    retry: model.retryCommitDetail)
            }
        } else if model.selectedCommit != nil {
            VStack(spacing: 0) {
                if let back {
                    GitBackBar(title: "Commit", onBack: back)
                    GitSeparator()
                }
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            GitMessage(symbol: "clock.arrow.circlepath", title: "Select a commit to see its changes")
        }
    }
}

private struct GitCommitList: View {
    @ObservedObject var model: GitViewModel

    var body: some View {
        if model.historyRows.isEmpty {
            if let error = model.logError {
                GitMessage(
                    symbol: "exclamationmark.triangle",
                    title: "Can't load the history",
                    detail: error,
                    retry: model.retryLog)
            } else if model.isLoadingLog {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GitMessage(symbol: "clock", title: "No commits yet")
            }
        } else {
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.historyRows.enumerated()), id: \.element.id) { index, row in
                            GitCommitRow(
                                row: row,
                                graph: index < model.graph.count ? model.graph[index] : nil,
                                lanes: graphLanes(near: index),
                                totalLanes: model.graphLanes,
                                availableWidth: geometry.size.width,
                                head: model.status?.head,
                                isSelected: model.selectedCommit == row.id)
                            .onTapGesture { select(row) }
                            .onAppear { model.rowAppeared(at: index) }
                        }

                        if let error = model.logError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle")
                                Text("History update failed: \(error)")
                                    .lineLimit(2)
                                Spacer(minLength: 4)
                                Button("Retry", action: model.retryLog)
                                    .buttonStyle(.borderless)
                            }
                            .font(.system(size: 11))
                            .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                            .padding(10)
                        }

                        if model.isLoadingLog {
                            ProgressView()
                                .controlSize(.small)
                                .padding(8)
                        }
                    }
                }
            }
        }
    }

    /// Include adjacent rows so labels shift only around a change in graph width.
    private func graphLanes(near index: Int) -> Int {
        guard index < model.graph.count else { return 1 }
        let first = max(0, index - 1)
        let last = min(model.graph.count - 1, index + 1)
        return model.graph[first...last].map(\.width).max() ?? 1
    }

    private func select(_ row: GitHistoryRow) {
        switch row {
        case .worktree:
            // The uncommitted changes live on the Changes page.
            model.page = .changes
        case .commit(let commit):
            model.selectedCommit = commit.hash
        }
    }
}

private struct GitCommitRow: View {
    static let height: CGFloat = 26

    let row: GitHistoryRow
    let graph: GitGraph.Row?
    let lanes: Int
    let totalLanes: Int
    let availableWidth: CGFloat
    let head: String?
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if let graph {
                GitGraphCell(
                    row: graph,
                    lanes: lanes,
                    totalLanes: totalLanes,
                    isHead: commit?.hash == head,
                    isWorktree: commit == nil)
            }

            switch row {
            case .worktree(let changes):
                Text("Uncommitted changes")
                    .italic()
                    .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                Spacer(minLength: 4)
                Text("\(changes)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))

            case .commit(let commit):
                if availableWidth >= 420 {
                    ForEach(commit.refs.prefix(2), id: \.self) { ref in
                        GitRefChip(ref: ref)
                    }
                    if commit.refs.count > 2 {
                        Text("+\(commit.refs.count - 2)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                            .help(commit.refs.dropFirst(2).map(\.name).joined(separator: ", "))
                    }
                }
                Text(commit.subject)
                    .foregroundColor(Color(nsColor: ChromePalette.text))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if availableWidth >= 600 {
                    Text(gitRelativeDate(commit.date))
                        .font(.system(size: 11))
                        .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
                        .lineLimit(1)
                        .fixedSize()
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(commit.hash, forType: .string)
                } label: {
                    Text(commit.shortHash)
                        .font(.system(size: 10.5, design: .monospaced))
                }
                .buttonStyle(.plain)
                .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
                .fixedSize()
                .help("Copy full commit ID")
                .accessibilityLabel("Copy full commit ID \(commit.shortHash)")
            }
        }
        .font(.system(size: 12))
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .frame(height: Self.height)
        .background(rowBackground(isSelected: isSelected, isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(helpText)
    }

    private var commit: GitCommit? {
        if case .commit(let commit) = row { return commit }
        return nil
    }

    private var helpText: String {
        guard let commit else { return "Uncommitted changes" }
        let summary = "\(commit.shortHash) · \(commit.author) · \(gitRelativeDate(commit.date)) · \(commit.subject)"
        guard !commit.refs.isEmpty else { return summary }
        return summary + "\n" + commit.refs.map(\.name).joined(separator: ", ")
    }
}

private struct GitRefChip: View {
    let ref: GitRef

    private var color: NSColor {
        switch ref.kind {
        case .head: return ChromePalette.sageAccent
        case .branch: return ref.isHead ? ChromePalette.sageAccent : ChromePalette.success
        case .remote: return ChromePalette.graphLanes[1]
        case .tag: return ChromePalette.warning
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            if ref.kind == .tag {
                Image(systemName: "tag")
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(ref.name)
                .font(.system(size: 10.5, weight: ref.isHead ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .leading)
        }
        .foregroundColor(Color(nsColor: color))
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: color).opacity(0.16)))
    }
}

private struct GitCommitDetailView: View {
    let detail: GitCommitDetail
    let onBack: (() -> Void)?
    let onSelectFile: (GitChangedFile) -> Void

    private var subject: String {
        detail.message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }

    private var bodyText: String {
        let parts = detail.message.split(separator: "\n", maxSplits: 1)
        guard parts.count > 1 else { return "" }
        return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let onBack {
                GitBackBar(title: String(detail.hash.prefix(8)), onBack: onBack)
                GitSeparator()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(subject)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(nsColor: ChromePalette.text))
                        .textSelection(.enabled)

                    if !bodyText.isEmpty {
                        Text(bodyText)
                            .font(.system(size: 12))
                            .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                            .textSelection(.enabled)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(String(detail.hash.prefix(12)))
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(detail.hash, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 10))
                            }
                            .buttonStyle(.plain)
                            .help("Copy the full hash")
                        }
                        Text("\(detail.author) <\(detail.authorEmail)>")
                            .textSelection(.enabled)
                        Text(detail.authorDate.formatted(date: .abbreviated, time: .shortened))
                    }
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))

                    GitSeparator()

                    Text(detail.files.count == 1 ? "1 file changed" : "\(detail.files.count) files changed")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)

                LazyVStack(spacing: 0) {
                    ForEach(detail.files) { file in
                        GitFileRow(letter: file.status, path: file.path, originalPath: file.originalPath, isSelected: false)
                            .onTapGesture { onSelectFile(file) }
                    }
                    if detail.filesTruncated {
                        GitNote(text: "Only the first part of the list is shown; git listed more than 4 MB.")
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }
}

// MARK: Diff

/// A diff with a title bar, and a back button when it replaces a list.
private struct GitDiffPane: View {
    let title: String
    let state: GitDiffState
    var onBack: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            if let onBack {
                GitBackBar(title: title, onBack: onBack)
            } else {
                HStack {
                    Text(title)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
            }
            GitSeparator()

            switch state {
            case .none:
                Color.clear
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                GitMessage(symbol: "exclamationmark.triangle", title: "Can't load the diff", detail: message)
            case .loaded(let diff):
                if diff.isBinary {
                    GitMessage(symbol: "doc", title: "Binary file", detail: "Diffs of binary files aren't shown.")
                } else if diff.isEmpty {
                    GitMessage(symbol: "equal", title: "No differences")
                } else {
                    GitDiffLines(diff: diff)
                }
            }
        }
    }
}

/// The lines of a unified diff with old and new line numbers.
private struct GitDiffLines: View {
    let diff: GitDiff

    private var numberWidth: CGFloat {
        let largest = diff.lines.reduce(0) { max($0, $1.oldNumber ?? 0, $1.newNumber ?? 0) }
        return CGFloat(max(String(largest).count, 3)) * 7 + 10
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.lines) { line in
                        GitDiffLineView(line: line, numberWidth: numberWidth)
                            .frame(minWidth: geo.size.width, alignment: .leading)
                    }
                    if diff.truncated {
                        GitNote(text: "The diff is longer than 4 MB; the rest isn't shown.")
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
    }
}

private struct GitDiffLineView: View {
    let line: GitDiff.Line
    let numberWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(marker)
                .foregroundColor(textColor)
                .frame(width: 16)
            Text(line.text.isEmpty ? " " : line.text)
                .foregroundColor(textColor)
                .italic(line.kind == .note)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.trailing, 12)
        .frame(minHeight: 17)
        .background(background)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
            .frame(width: numberWidth, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var marker: String {
        switch line.kind {
        case .added: return "+"
        case .removed: return "-"
        default: return ""
        }
    }

    private var textColor: Color {
        switch line.kind {
        case .hunk, .note: return Color(nsColor: ChromePalette.tertiaryText)
        default: return Color(nsColor: ChromePalette.text)
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: return Color(nsColor: ChromePalette.success).opacity(0.14)
        case .removed: return Color(nsColor: ChromePalette.error).opacity(0.14)
        case .hunk: return Color(nsColor: ChromePalette.hoverOverlay)
        default: return .clear
        }
    }
}

// MARK: Pieces

private struct GitBackBar: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back")

            Text(title)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .foregroundColor(Color(nsColor: ChromePalette.text))
        .padding(.horizontal, 6)
        .frame(height: 28)
    }
}

private struct GitMessage: View {
    let symbol: String
    let title: String
    var detail: String?
    var retry: (() -> Void)? = nil

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
            if let retry {
                Button("Retry", action: retry)
                    .buttonStyle(.bordered)
            }
        }
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct GitNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GitSeparator: View {
    var vertical: Bool = false

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: ChromePalette.separator))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

private func rowBackground(isSelected: Bool, isHovered: Bool) -> Color {
    if isSelected { return Color(nsColor: ChromePalette.selectionOverlay) }
    if isHovered { return Color(nsColor: ChromePalette.hoverOverlay) }
    return .clear
}

private func gitStatusColor(_ letter: Character) -> Color {
    switch letter {
    case "A": return Color(nsColor: ChromePalette.success)
    case "D", "U": return Color(nsColor: ChromePalette.error)
    case "R", "C": return Color(nsColor: ChromePalette.graphLanes[1])
    case "?": return Color(nsColor: ChromePalette.tertiaryText)
    default: return Color(nsColor: ChromePalette.warning)
    }
}

private let relativeDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
}()

private func gitRelativeDate(_ date: Date) -> String {
    relativeDateFormatter.localizedString(for: date, relativeTo: Date())
}
