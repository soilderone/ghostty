import AppKit
import SwiftUI

/// What the preview shows for a file.
enum FilePreviewContent: Equatable {
    case document(FilePreviewDocument)
    case image(NSImage)
    case directory
    case tooLarge(Int64)
    case binary
    case missing
    case unreadable(String)
}

/// Reads files for the preview off the main thread.
final class FilePreviewLoader: ObservableObject {
    /// Nil until the first file has loaded. While another file loads, the last one stays up so
    /// the preview page isn't torn down in between.
    @Published private(set) var content: FilePreviewContent?

    /// Text past this isn't previewed; it would make the page slow for little benefit.
    static let maxTextBytes = 2 * 1024 * 1024

    private var generation = 0

    func load(_ url: URL) {
        generation += 1
        let current = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let content = Self.read(url)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current else { return }
                self.content = content
            }
        }
    }

    private static func read(_ url: URL) -> FilePreviewContent {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else {
            return .missing
        }
        if values.isDirectory == true { return .directory }

        if FilePreviewDocument.imageExtensions.contains(url.pathExtension.lowercased()),
           let image = NSImage(contentsOf: url) {
            return .image(image)
        }

        let size = Int64(values.fileSize ?? 0)
        guard size <= maxTextBytes else { return .tooLarge(size) }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable(error.localizedDescription)
        }

        // A NUL byte early on is the usual sign of a binary file.
        if data.prefix(8192).contains(0) { return .binary }
        return .document(FilePreviewDocument(url: url, text: data.lossyUTF8String))
    }
}

extension FilePreviewDocument {
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "icns", "svg", "pdf",
    ]

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx"]

    /// Files shown as plain text, where guessing a language would only add noise.
    private static let plainExtensions: Set<String> = ["", "txt", "text", "log", "csv", "tsv", "lock"]

    /// Names and extensions that highlight.js doesn't know by those names. Any other
    /// extension is passed on as the language, since highlight.js knows most of them as
    /// aliases ("rs", "py", "yml", "toml", ...), and the page guesses when it doesn't.
    private static let languageOverrides: [String: String] = [
        "m": "objectivec",
        "zsh": "bash",
        "fish": "bash",
        "command": "bash",
        "plist": "xml",
        "xib": "xml",
        "storyboard": "xml",
        "entitlements": "xml",
        "conf": "ini",
        "cfg": "ini",
        "jsonc": "json",
        "json5": "json",
    ]

    private static let nameLanguages: [String: String] = [
        "makefile": "makefile",
        "gnumakefile": "makefile",
        ".bashrc": "bash",
        ".bash_profile": "bash",
        ".zshrc": "bash",
        ".zprofile": "bash",
        ".zshenv": "bash",
        ".profile": "bash",
        ".gitconfig": "ini",
        ".editorconfig": "ini",
    ]

    init(url: URL, text: String) {
        let name = url.lastPathComponent.lowercased()
        let pathExtension = url.pathExtension.lowercased()

        if let language = Self.nameLanguages[name] {
            self.init(kind: .code, text: text, language: language, base: url.deletingLastPathComponent())
        } else if Self.markdownExtensions.contains(pathExtension) {
            self.init(kind: .markdown, text: text, language: nil, base: url.deletingLastPathComponent())
        } else if Self.plainExtensions.contains(pathExtension) {
            self.init(kind: .text, text: text, language: nil, base: url.deletingLastPathComponent())
        } else {
            self.init(
                kind: .code,
                text: text,
                language: Self.languageOverrides[pathExtension] ?? pathExtension,
                base: url.deletingLastPathComponent())
        }
    }
}

/// One file in the preview: a bar with what can be done with it, and its content. Files are
/// read-only here; editing happens in the user's own editor.
struct FilePreviewPane: View {
    let url: URL
    @ObservedObject var model: FileBrowserModel

    @StateObject private var loader = FilePreviewLoader()

    var body: some View {
        VStack(spacing: 0) {
            FilePreviewActions(url: url, model: model) { loader.load(url) }
            FileSeparator()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { loader.load(url) }
        .onChange(of: url) { loader.load($0) }
    }

    @ViewBuilder
    private var content: some View {
        switch loader.content {
        case nil:
            ProgressView()
                .controlSize(.small)
        case .document(let document):
            if FilePreviewWebView.pageURL != nil {
                FilePreviewWebView(document: document) { link in
                    openLink(link)
                }
            } else {
                FileMessage(symbol: "exclamationmark.triangle", title: "The preview page is missing from the app")
            }
        case .image(let image):
            FileImagePreview(image: image)
        case .directory:
            FileMessage(symbol: "folder", title: "This is a folder")
        case .tooLarge(let size):
            FileMessage(
                symbol: "doc",
                title: "Too large to preview",
                detail: "\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)). Open it with its app or in Quick Look.")
        case .binary:
            FileMessage(symbol: "doc", title: "Binary file", detail: "Open it with its app or in Quick Look.")
        case .missing:
            FileMessage(symbol: "questionmark.folder", title: "The file no longer exists", detail: url.path.abbreviatedPath)
        case .unreadable(let message):
            FileMessage(symbol: "exclamationmark.triangle", title: "Couldn't read the file", detail: message)
        }
    }

    /// A link in a markdown file: folders show in the tree, files open in a tab.
    private func openLink(_ link: URL) {
        guard link.isFileURL else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: link.path, isDirectory: &isDirectory) else {
            NSSound.beep()
            return
        }
        if isDirectory.boolValue {
            model.navigate(to: link)
        } else {
            model.open(link.standardizedFileURL)
        }
    }
}

/// The bar over a preview: the file's path, and buttons for its own app, the terminal's editor,
/// Quick Look and the Finder.
private struct FilePreviewActions: View {
    let url: URL
    @ObservedObject var model: FileBrowserModel
    let onReload: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text(url.path.abbreviatedPath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                .help(url.path)
            Spacer(minLength: 4)

            FileBarButton(symbol: "arrow.clockwise", help: "Reload", action: onReload)
            FileBarButton(symbol: "eye", help: "Quick Look") { model.quickLookURL = url }
            FileBarButton(symbol: "terminal", help: "Edit in Terminal: types the editor command into the focused terminal without running it") {
                model.actions.typeInTerminal(Self.editCommand(for: url))
            }
            FileBarButton(symbol: "arrow.up.forward.app", help: "Open with Default App") {
                _ = NSWorkspace.shared.open(url)
            }
            FileBarButton(symbol: "folder", help: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 28)
    }

    /// The shell command that opens the file in the user's editor. It is only typed, so the
    /// user sees it and runs it with return.
    static func editCommand(for url: URL) -> String {
        let quoted = "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "${EDITOR:-vi} \(quoted)"
    }
}

/// An image, scaled down to fit but never up, with its size under it.
private struct FileImagePreview: View {
    let image: NSImage

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(maxWidth: image.size.width, maxHeight: image.size.height)
            Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
