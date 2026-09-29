import AppKit
import GhosttyKit

/// Where Ghostty keeps its configuration, for the files the macOS app reads next to it
/// (`widgets.json`).
enum ConfigDirectory {
    /// The folders Ghostty reads its configuration from, in the order it prefers them: the
    /// Application Support folder before the XDG one.
    static var candidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let appSupport = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        var bundleIdentifiers = ["com.mitchellh.ghostty"]
        if let identifier = Bundle.main.bundleIdentifier, !bundleIdentifiers.contains(identifier) {
            bundleIdentifiers.insert(identifier, at: 0)
        }

        let xdgHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".config", isDirectory: true)

        return bundleIdentifiers.map { appSupport.appendingPathComponent($0, isDirectory: true) } +
            [xdgHome.appendingPathComponent("ghostty", isDirectory: true)]
    }

    /// The first of the folders that holds a file of this name, if any.
    static func existingFile(named name: String) -> URL? {
        candidates
            .map { $0.appendingPathComponent(name, isDirectory: false) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The folder of the configuration file that the app edits. Asking for it creates that
    /// file if it doesn't exist yet, the same as opening the configuration does.
    static var editableDirectory: URL? {
        let path = Ghostty.AllocatedString(ghostty_config_open_path()).string
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }

    /// Opens a file of this name in the folder of the configuration, writing `template` into it
    /// first if there is no such file yet. Returns false if it couldn't.
    @discardableResult
    static func openForEditing(named name: String, template: String) -> Bool {
        let url: URL
        if let existing = existingFile(named: name) {
            url = existing
        } else if let directory = editableDirectory {
            url = directory.appendingPathComponent(name, isDirectory: false)
            do {
                try template.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Ghostty.logger.warning("couldn't create \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return false
            }
        } else {
            return false
        }

        // A text editor rather than whatever the system opens JSON with, which can be a browser.
        if let editor = NSWorkspace.shared.defaultTextEditor {
            NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
            return true
        }
        return NSWorkspace.shared.open(url)
    }
}
