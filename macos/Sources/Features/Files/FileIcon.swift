import AppKit
import SwiftUI

/// Lightweight outline symbols shared by the tree, preview tabs, Quick Open and SSH files.
/// Icons depend only on the name and metadata, so drawing a row never queries Finder.
struct FileIconStyle {
    let symbol: String
    let color: NSColor
    let isSymbolicLink: Bool

    init(name: String, isDirectory: Bool = false, isSymbolicLink: Bool = false) {
        self.isSymbolicLink = isSymbolicLink
        let extensionName = (name as NSString).pathExtension.lowercased()

        if isDirectory {
            symbol = "folder"
            color = ChromePalette.filesAccent
        } else if Self.sourceExtensions.contains(extensionName) {
            symbol = "chevron.left.forwardslash.chevron.right"
            color = ChromePalette.sageAccent
        } else if Self.configExtensions.contains(extensionName) ||
                    [".gitignore", ".gitattributes", ".editorconfig", ".env"].contains(name.lowercased()) {
            symbol = "slider.horizontal.3"
            color = ChromePalette.aiAccent
        } else {
            switch extensionName {
            case "sh", "bash", "zsh", "fish", "nu":
                symbol = "terminal"
                color = ChromePalette.sageAccent
            case "md", "markdown", "mdx", "rst":
                symbol = "doc.richtext"
                color = ChromePalette.filesAccent
            case "png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "tif", "tiff", "bmp", "ico":
                symbol = "photo"
                color = ChromePalette.fileMediaAccent
            case "mp4", "m4v", "mov", "webm", "mkv", "avi":
                symbol = "film"
                color = ChromePalette.fileMediaAccent
            case "mp3", "m4a", "aac", "wav", "aiff", "caf", "flac", "ogg":
                symbol = "waveform"
                color = ChromePalette.aiAccent
            case "zip", "tar", "gz", "bz2", "xz", "zst", "7z", "rar", "dmg":
                symbol = "archivebox"
                color = ChromePalette.filesAccent
            case "pdf":
                symbol = "doc.richtext"
                color = ChromePalette.gitAccent
            case "csv", "tsv", "xls", "xlsx", "numbers":
                symbol = "tablecells"
                color = ChromePalette.sageAccent
            case "app":
                symbol = "app"
                color = ChromePalette.fileMediaAccent
            default:
                symbol = ["makefile", "justfile", "dockerfile"].contains(name.lowercased()) ? "terminal" : "doc.text"
                color = ChromePalette.secondaryText
            }
        }
    }

    var image: NSImage? {
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
    }

    private static let sourceExtensions: Set<String> = [
        "zig", "swift", "c", "h", "cpp", "hpp", "cc", "m", "mm", "rs", "go", "py", "rb",
        "js", "jsx", "ts", "tsx", "java", "kt", "kts", "lua", "php", "cs", "html", "css", "scss",
    ]
    private static let configExtensions: Set<String> = [
        "json", "jsonc", "yaml", "yml", "toml", "ini", "conf", "config", "xml", "plist", "env",
    ]
}

struct FileIcon: View {
    let style: FileIconStyle

    init(name: String, isDirectory: Bool = false, isSymbolicLink: Bool = false) {
        style = FileIconStyle(name: name, isDirectory: isDirectory, isSymbolicLink: isSymbolicLink)
    }

    var body: some View {
        Image(systemName: style.symbol)
            .font(.system(size: 12, weight: .regular))
            .foregroundColor(Color(nsColor: style.color))
            .frame(width: 16, height: 16)
            .overlay(alignment: .bottomTrailing) {
                if style.isSymbolicLink {
                    Image(systemName: "arrow.turn.up.right")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                        .background(Color(nsColor: ChromePalette.panel))
                }
            }
            .accessibilityHidden(true)
    }
}
