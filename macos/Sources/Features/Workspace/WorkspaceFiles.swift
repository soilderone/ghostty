import Foundation

struct WorkspaceFile: Identifiable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let directory: Bool
    let symbolicLink: Bool
    let size: UInt64
}

enum WorkspaceError: LocalizedError {
    case message(String)
    case conflict

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .conflict: return "The file changed since it was opened. Reload it, save a copy, or explicitly overwrite it."
        }
    }
}

/// Implementations serialize filesystem work away from the main actor.
protocol WorkspaceFileService: Sendable {
    func resolve(_ path: String) async throws -> String
    func list(_ path: String) async throws -> [WorkspaceFile]
    func read(_ path: String) async throws -> Data
    func save(_ path: String, data: Data, original: Data?, overwrite: Bool) async throws
    func create(_ path: String, directory: Bool) async throws
    func rename(_ path: String, to destination: String) async throws
    func remove(_ path: String, directory: Bool) async throws
    func download(_ path: String, to url: URL, progress: @Sendable @escaping (Double) -> Void) async throws
    func upload(_ url: URL, to path: String, progress: @Sendable @escaping (Double) -> Void) async throws
}

enum WorkspacePath {
    static let textLimit = 5 * 1024 * 1024

    static func child(_ name: String, in directory: String) throws -> String {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw WorkspaceError.message("Enter a single file or folder name without a slash.")
        }
        return (directory == "/" ? "" : directory) + "/" + name
    }

    static func text(_ data: Data) throws -> String {
        guard data.count <= textLimit, !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceError.message("The editor supports UTF-8 text up to 5 MiB. Use Download for other files.")
        }
        return text
    }
}

actor LocalWorkspaceFiles: WorkspaceFileService {
    private let manager = FileManager.default

    func resolve(_ path: String) throws -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardized.path
    }

    func list(_ path: String) throws -> [WorkspaceFile] {
        try manager.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [
            .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
        ]).map { url in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            return WorkspaceFile(path: url.path, name: url.lastPathComponent,
                                 directory: (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, symbolicLink: values.isSymbolicLink == true,
                                 size: UInt64(max(0, values.fileSize ?? 0)))
        }
    }

    func read(_ path: String) throws -> Data {
        guard try manager.attributesOfItem(atPath: resolve(path))[.type] as? FileAttributeType == .typeRegular else {
            throw WorkspaceError.message("Only regular files can be opened in the editor.")
        }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let data = try handle.read(upToCount: WorkspacePath.textLimit + 1) ?? Data()
        _ = try WorkspacePath.text(data)
        return data
    }

    func save(_ path: String, data: Data, original: Data?, overwrite: Bool) throws {
        let target = try resolve(path)
        if !overwrite {
            if let original {
                guard try read(target) == original else { throw WorkspaceError.conflict }
            } else if manager.fileExists(atPath: target) {
                throw WorkspaceError.conflict
            }
        }
        let attributes = try? manager.attributesOfItem(atPath: target)
        try data.write(to: URL(fileURLWithPath: target), options: .atomic)
        if let permissions = attributes?[.posixPermissions] {
            try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target)
        }
    }

    func create(_ path: String, directory: Bool) throws {
        if directory {
            try manager.createDirectory(atPath: path, withIntermediateDirectories: false)
        } else {
            try Data().write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
        }
    }

    func rename(_ path: String, to destination: String) throws {
        try manager.moveItem(atPath: path, toPath: destination)
    }

    func remove(_ path: String, directory: Bool) throws {
        if directory, !(try manager.contentsOfDirectory(atPath: path)).isEmpty {
            throw WorkspaceError.message("Only empty folders can be deleted in this version.")
        }
        try manager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    func download(_ path: String, to url: URL, progress: @Sendable @escaping (Double) -> Void) throws {
        try copy(URL(fileURLWithPath: path), to: url, progress: progress)
    }

    func upload(_ url: URL, to path: String, progress: @Sendable @escaping (Double) -> Void) throws {
        try copy(url, to: URL(fileURLWithPath: path), progress: progress)
    }

    private func copy(_ source: URL, to destination: URL, progress: @Sendable (Double) -> Void) throws {
        let values = try source.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw WorkspaceError.message("Only regular files can be transferred.") }
        let size = values.fileSize ?? 0
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".ghostty-\(UUID().uuidString)")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw WorkspaceError.message("Cannot create transfer file.")
        }
        defer { try? manager.removeItem(at: temporary) }
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: temporary)
        defer {
            try? input.close()
            try? output.close()
        }
        var count = 0
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            try output.write(contentsOf: chunk)
            count += chunk.count
            progress(Double(count) / Double(max(1, size)))
        }
        try Task.checkCancellation()
        try manager.moveItem(at: temporary, to: destination)
        progress(1)
    }
}
