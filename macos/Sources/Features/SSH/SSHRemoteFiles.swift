import Foundation

/// File operations are sent as arguments to a short Python helper over OpenSSH. No agent or
/// files are installed on the remote host. All paths are quoted before the remote shell sees
/// them, and every mutation checks that its destination does not already exist.
enum SSHRemoteFiles {
    private static let marker = Data([0x1e] + Array("GHOSTTY_FILES".utf8) + [0x1f])

    private struct Entry: Decodable {
        let name: String
        let directory: Bool
        let symlink: Bool
        let size: Int64
        let modified: TimeInterval
        let permissions: Int

        func fileEntry(in folder: String) -> FileEntry {
            FileEntry(
                remoteURL: URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent(name),
                isDirectory: directory,
                isSymbolicLink: symlink,
                size: size,
                modified: Date(timeIntervalSince1970: modified),
                permissions: permissions)
        }
    }

    private static let script = #"""
import datetime
import json
import os
import shutil
import stat
import sys
import urllib.parse
import uuid

operation = sys.argv[1]
args = sys.argv[2:]
sys.stdout.buffer.write(b"\x1eGHOSTTY_FILES\x1f")
sys.stdout.buffer.flush()

def entry(path):
    original = os.lstat(path)
    try:
        details = os.stat(path)
    except OSError:
        details = original
    return {
        "name": os.path.basename(path.rstrip("/")),
        "directory": stat.S_ISDIR(details.st_mode),
        "symlink": os.path.islink(path),
        "size": details.st_size,
        "modified": details.st_mtime,
        "permissions": stat.S_IMODE(details.st_mode),
    }

try:
    if operation == "list":
        path = args[0]
        print(json.dumps([entry(item.path) for item in os.scandir(path)], ensure_ascii=True))
    elif operation == "stat":
        print(json.dumps(entry(args[0]), ensure_ascii=True))
    elif operation == "read":
        with open(args[0], "rb") as source:
            sys.stdout.buffer.write(source.read(int(args[1]) + 1))
    elif operation == "create":
        with open(args[0], "xb"):
            pass
    elif operation == "mkdir":
        os.mkdir(args[0])
    elif operation == "move":
        source, destination = args
        if os.path.lexists(destination):
            raise FileExistsError(destination)
        if os.path.isdir(source) and os.path.commonpath((os.path.realpath(source), os.path.realpath(destination))) == os.path.realpath(source):
            raise ValueError("A folder cannot be moved into itself")
        os.rename(source, destination)
    elif operation == "trash":
        source = args[0]
        home = os.path.expanduser("~")
        if sys.platform == "darwin":
            files = os.path.join(home, ".Trash")
            info = None
        else:
            base = os.path.join(home, ".local", "share", "Trash")
            files = os.path.join(base, "files")
            info = os.path.join(base, "info")
            os.makedirs(info, mode=0o700, exist_ok=True)
        os.makedirs(files, mode=0o700, exist_ok=True)
        name = os.path.basename(source.rstrip("/")) + "-" + uuid.uuid4().hex[:8]
        destination = os.path.join(files, name)
        while os.path.lexists(destination):
            name = os.path.basename(source.rstrip("/")) + "-" + uuid.uuid4().hex[:8]
            destination = os.path.join(files, name)
        shutil.move(source, destination)
        if info is not None:
            with open(os.path.join(info, name + ".trashinfo"), "x", encoding="utf-8") as record:
                record.write("[Trash Info]\nPath=" + urllib.parse.quote(os.path.abspath(source)) + "\nDeletionDate=" + datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S") + "\n")
    else:
        raise ValueError("Unknown remote file operation")
except Exception as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
"""#

    private static func run(
        _ operation: String,
        _ arguments: [String],
        on connection: SSHConnection,
        maxBytes: Int = SSHRunner.maxOutputBytes
    ) async throws -> SSHOutput {
        let command = (["python3", "-c", script, operation] + arguments)
            .map(SSHConnection.shellQuote)
            .joined(separator: " ")
        do {
            let output = try await SSHRunner.run(command, on: connection, maxBytes: maxBytes + 4096)
            guard let range = output.data.range(of: marker) else {
                throw SSHCommandError(message: "The remote file helper returned unexpected output.")
            }
            let data = Data(output.data[range.upperBound...].prefix(maxBytes))
            return SSHOutput(data: data, truncated: output.truncated ||
                             output.data.count - range.upperBound > maxBytes)
        } catch let error as SSHCommandError where error.message.contains("python3:") &&
            (error.message.contains("not found") || error.message.contains("command not found")) {
            throw SSHCommandError(message: "Remote Files requires Python 3 on \(connection.displayName).")
        }
    }

    static func list(_ directory: String, on connection: SSHConnection) async throws -> [FileEntry] {
        let output = try await run("list", [directory], on: connection)
        guard !output.truncated else {
            throw SSHCommandError(message: "The remote folder contains too many files to list.")
        }
        let entries = try JSONDecoder().decode([Entry].self, from: output.data)
        return entries.map { $0.fileEntry(in: directory) }
    }

    static func stat(_ path: String, on connection: SSHConnection) async throws -> FileEntry {
        let output = try await run("stat", [path], on: connection, maxBytes: 4096)
        guard !output.truncated else { throw SSHCommandError(message: "Remote file metadata is too large.") }
        let entry = try JSONDecoder().decode(Entry.self, from: output.data)
        return entry.fileEntry(in: (path as NSString).deletingLastPathComponent)
    }

    static func read(_ path: String, on connection: SSHConnection, maxBytes: Int) async throws -> Data {
        let output = try await run("read", [path, String(maxBytes)], on: connection, maxBytes: maxBytes + 1)
        guard !output.truncated, output.data.count <= maxBytes else {
            throw SSHCommandError(message: "The remote file is too large to preview.")
        }
        return output.data
    }

    static func createFile(_ path: String, on connection: SSHConnection) async throws {
        _ = try await run("create", [path], on: connection, maxBytes: 1024)
    }

    static func createFolder(_ path: String, on connection: SSHConnection) async throws {
        _ = try await run("mkdir", [path], on: connection, maxBytes: 1024)
    }

    static func move(_ source: String, to destination: String, on connection: SSHConnection) async throws {
        _ = try await run("move", [source, destination], on: connection, maxBytes: 1024)
    }

    static func trash(_ path: String, on connection: SSHConnection) async throws {
        _ = try await run("trash", [path], on: connection, maxBytes: 1024)
    }
}
