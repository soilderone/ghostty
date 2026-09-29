import Foundation

/// A file or folder in the file browser.
struct FileEntry: Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: Int64
    let modified: Date?

    /// POSIX permissions, only read when sorting by them.
    var permissions: Int?

    /// Dotfiles are dimmed, and hidden unless hidden files are shown.
    var isHidden: Bool { name.hasPrefix(".") }

    var pathExtension: String { (name as NSString).pathExtension.lowercased() }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isSymbolicLinkKey,
        .fileSizeKey,
        .contentModificationDateKey,
    ]

    init?(url: URL, readPermissions: Bool = false) {
        guard let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys)) else { return nil }
        self.url = url
        self.name = url.lastPathComponent
        self.isSymbolicLink = values.isSymbolicLink ?? false

        // A link to a folder behaves like the folder.
        if isSymbolicLink {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            self.isDirectory = isDirectory.boolValue
        } else {
            self.isDirectory = values.isDirectory ?? false
        }

        self.size = Int64(values.fileSize ?? 0)
        self.modified = values.contentModificationDate
        if readPermissions {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            self.permissions = (attributes?[.posixPermissions] as? NSNumber)?.intValue
        }
    }

    /// Metadata supplied by the remote file helper. This URL is a path identifier for the
    /// browser only; callers must not pass it to local FileManager or NSWorkspace operations.
    init(
        remoteURL: URL,
        isDirectory: Bool,
        isSymbolicLink: Bool,
        size: Int64,
        modified: Date?,
        permissions: Int
    ) {
        self.url = remoteURL
        self.name = remoteURL.lastPathComponent
        self.isDirectory = isDirectory
        self.isSymbolicLink = isSymbolicLink
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }

    /// Lists a folder, unsorted.
    static func list(_ directory: URL, readPermissions: Bool) throws -> [FileEntry] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: resourceKeys,
            options: [])
        return urls.compactMap { FileEntry(url: $0, readPermissions: readPermissions) }
    }
}

/// How the file browser orders a folder. Folders always come first.
enum FileSortKey: String, CaseIterable {
    case name
    case type
    case modified
    case size
    case permissions

    var title: String {
        switch self {
        case .name: return "Name"
        case .type: return "Type"
        case .modified: return "Date Modified"
        case .size: return "Size"
        case .permissions: return "Permissions"
        }
    }

    /// The newest and largest files are usually the interesting ones.
    var defaultAscending: Bool {
        switch self {
        case .modified, .size: return false
        default: return true
        }
    }

    func sorted(_ entries: [FileEntry], ascending: Bool) -> [FileEntry] {
        entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }

            // Names compare naturally ("file2" before "file10") and ignore case. That is the
            // slow part of a comparison, so it only runs when nothing else settles the order.
            func byName() -> ComparisonResult {
                a.name.localizedStandardCompare(b.name)
            }

            let order: ComparisonResult
            switch self {
            case .name:
                order = byName()
            case .type:
                // Files of the same type group together by extension.
                let byExtension = a.pathExtension.localizedStandardCompare(b.pathExtension)
                order = byExtension == .orderedSame ? byName() : byExtension
            case .modified:
                order = Self.compare(a.modified ?? .distantPast, b.modified ?? .distantPast, then: byName())
            case .size:
                order = Self.compare(a.size, b.size, then: byName())
            case .permissions:
                order = Self.compare(a.permissions ?? 0, b.permissions ?? 0, then: byName())
            }

            switch order {
            case .orderedAscending: return ascending
            case .orderedDescending: return !ascending
            case .orderedSame: return false
            }
        }
    }

    private static func compare<T: Comparable>(
        _ a: T,
        _ b: T,
        then tie: @autoclosure () -> ComparisonResult
    ) -> ComparisonResult {
        if a < b { return .orderedAscending }
        if a > b { return .orderedDescending }
        return tie()
    }
}

/// Watches folders and reports which one changed. Used to keep the file tree current.
///
/// A folder can change hundreds of times a second while a build or a checkout writes to it, so
/// the changes of one folder are reported at most once per `delay`. A change is never lost: one
/// that comes in after a report starts the next window.
final class DirectoryWatcher {
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var pending: Set<URL> = []
    private let delay: TimeInterval
    private let onChange: (URL) -> Void

    init(delay: TimeInterval = 0.2, onChange: @escaping (URL) -> Void) {
        self.delay = delay
        self.onChange = onChange
    }

    deinit {
        sources.values.forEach { $0.cancel() }
    }

    /// Watches exactly these folders.
    func watch(_ directories: Set<URL>) {
        for (url, source) in sources where !directories.contains(url) {
            source.cancel()
            sources[url] = nil
            pending.remove(url)
        }

        for url in directories where sources[url] == nil {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename],
                queue: .main)
            source.setEventHandler { [weak self] in self?.changed(url) }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources[url] = source
        }
    }

    private func changed(_ url: URL) {
        // A report is already on its way, and it will see this change too.
        guard pending.insert(url).inserted else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pending.remove(url) != nil, self.sources[url] != nil else { return }
            self.onChange(url)
        }
    }
}
