import Foundation
import Testing
@testable import Ghostty

struct WorkspaceTests {
    @Test func refusesUnsafeChildNames() throws {
        for name in ["", ".", "..", "a/b", "a\0b"] {
            #expect(throws: (any Error).self) { try WorkspacePath.child(name, in: "/tmp") }
        }
        #expect(try WorkspacePath.child("中文 ' $(echo nope).txt", in: "/") == "/中文 ' $(echo nope).txt")
    }

    @Test func rejectsBinaryAndOversizedText() throws {
        #expect(try WorkspacePath.text(Data("hello\r\n世界".utf8)) == "hello\r\n世界")
        #expect(throws: (any Error).self) { try WorkspacePath.text(Data([0xff])) }
        #expect(throws: (any Error).self) { try WorkspacePath.text(Data([0])) }
        #expect(throws: (any Error).self) { try WorkspacePath.text(Data(repeating: 65, count: WorkspacePath.textLimit + 1)) }
    }

    @Test @MainActor func preservesBOMAndCRLF() throws {
        let data = Data([0xef, 0xbb, 0xbf]) + Data("one\r\ntwo\r\n".utf8)
        let doc = try WorkspaceDocument(location: WorkspaceLocation(), path: "/test", data: data)
        #expect(!doc.dirty)
        doc.text += "three\n"
        #expect(doc.encodedText == data + Data("three\r\n".utf8))
        try doc.reload(Data("plain\n".utf8))
        #expect(doc.encodedText == Data("plain\n".utf8))
        #expect(!doc.dirty)
    }

    @Test func sshArgumentsCannotBecomeShellCommands() throws {
        var profile = WorkspaceSSHProfile()
        profile.host = "my-alias"
        profile.identityFile = "/tmp/a'$(touch injected)"
        let command = try profile.command(socket: "/tmp/socket")
        #expect(command.contains("'/tmp/a'\\''$(touch injected)'"))
        #expect(command.hasSuffix("'--' 'my-alias'"))
        profile.host = "-oProxyCommand=bad"
        #expect(throws: (any Error).self) { try profile.validate() }
        profile.host = "host"
        profile.port = "65536"
        #expect(throws: (any Error).self) { try profile.validate() }
    }

    @Test func malformedPacketsAreRejected() throws {
        var short = SFTPPacket(data: Data([0, 0, 0]))
        #expect(throws: (any Error).self) { try short.readUInt32() }
        var huge = SFTPPacket(data: Data([0xff, 0xff, 0xff, 0xff]))
        #expect(throws: (any Error).self) { try huge.readBytes() }
        var attrs = SFTPPacket(data: Data([0, 0, 0, 16]))
        #expect(throws: (any Error).self) { try SFTPAttributes(&attrs) }
    }

    @Test func localSaveDetectsConflictsAndFollowsSymlinks() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("file").path
        let link = root.appendingPathComponent("link").path
        let files = LocalWorkspaceFiles()
        let original = Data("original".utf8)
        try original.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        try await files.save(link, data: Data("edited".utf8), original: original, overwrite: false)
        #expect(try await files.read(path) == Data("edited".utf8))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == path)
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        do {
            try await files.save(path, data: original, original: original, overwrite: false)
            Issue.record("A stale edit overwrote the newer file")
        } catch WorkspaceError.conflict { }
        #expect(try await files.read(path) == Data("edited".utf8))
    }

    @Test func localTransferDoesNotOverwriteDestination() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try Data("source".utf8).write(to: source)
        try Data("keep".utf8).write(to: destination)
        do {
            try await LocalWorkspaceFiles().download(source.path, to: destination) { _ in }
            Issue.record("An existing transfer destination was overwritten")
        } catch { }
        #expect(try Data(contentsOf: destination) == Data("keep".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }

    @Test func sftpRoundTripAgainstOpenSSH() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = RemoteWorkspaceFiles(subsystemExecutable: URL(fileURLWithPath: "/usr/libexec/sftp-server"))
        do {
            try await exerciseRemote(files, root: root)
            await files.disconnect()
        } catch {
            await files.disconnect()
            throw error
        }
    }

    private func exerciseRemote(_ files: RemoteWorkspaceFiles, root: URL) async throws {
        let folder = root.appendingPathComponent("目录 ' spaces")
        try await files.create(folder.path, directory: true)
        let path = folder.appendingPathComponent("a\nb ' $(literal).txt").path
        let original = Data("original\r\n".utf8)
        try await files.save(path, data: original, original: nil, overwrite: false)
        #expect(try await files.read(path) == original)
        let listing = try await files.list(folder.path)
        #expect(listing.map(\.name) == ["a\nb ' $(literal).txt"])
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
        let link = folder.appendingPathComponent("link").path
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
        let edited = Data("changed".utf8)
        try await files.save(link, data: edited, original: original, overwrite: false)
        #expect(try await files.read(path) == edited)
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == path)
        do {
            try await files.save(path, data: original, original: original, overwrite: false)
            Issue.record("A stale remote edit overwrote the newer file")
        } catch WorkspaceError.conflict { }
        let upload = root.appendingPathComponent("upload")
        let bytes = Data((0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
        try bytes.write(to: upload)
        let remote = folder.appendingPathComponent("binary").path
        try await files.upload(upload, to: remote) { _ in }
        let download = root.appendingPathComponent("download")
        try await files.download(remote, to: download) { _ in }
        #expect(try Data(contentsOf: download) == bytes)
        let renamed = folder.appendingPathComponent("renamed").path
        try await files.rename(remote, to: renamed)
        try await files.remove(renamed, directory: false)
        do {
            try await files.remove(folder.path, directory: true)
            Issue.record("A nonempty remote folder was deleted")
        } catch { }
        #expect(try await files.read(path) == edited)
        let names = try await files.list(folder.path).map(\.name)
        #expect(!names.contains { $0.hasPrefix(".ghostty-") })
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ghostty-workspace-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}
