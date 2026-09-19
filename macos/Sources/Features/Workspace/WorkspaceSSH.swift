import Foundation
import Combine

struct WorkspaceSSHProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var host = ""
    var user = ""
    var port = ""
    var identityFile = ""
    var directory = "."

    func validate() throws {
        guard !host.isEmpty, !host.hasPrefix("-"),
              !host.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" }),
              !user.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" }),
              !identityFile.contains("\0"), !directory.contains("\0") else {
            throw WorkspaceError.message("Enter a valid SSH host or config alias and username.")
        }
        if !port.isEmpty, UInt16(port).map({ $0 > 0 }) != true {
            throw WorkspaceError.message("The port must be between 1 and 65535, or empty to use SSH config.")
        }
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    func command(socket: String) throws -> String {
        try validate()
        var args = ["/usr/bin/ssh", "-M", "-S", socket, "-o", "ControlPersist=no",
                    "-o", "ControlMaster=yes", "-o", "StrictHostKeyChecking=ask",
                    "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]
        if !port.isEmpty { args += ["-p", port] }
        if !user.isEmpty { args += ["-l", user] }
        if !identityFile.isEmpty { args += ["-i", (identityFile as NSString).expandingTildeInPath] }
        args += ["--", host]
        // SurfaceConfiguration.command is already interpreted as a shell command
        // by apprt/embedded.zig; config-file prefixes such as "shell:" are not used.
        return "exec " + args.map(Self.quote).joined(separator: " ")
    }
}

@MainActor
final class WorkspaceSSHStore: ObservableObject {
    static let shared = WorkspaceSSHStore()
    @Published private(set) var profiles: [WorkspaceSSHProfile] = []
    @Published var error: String?
    private let url: URL

    private init() {
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mitchellh.ghostty/workspace/ssh.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                profiles = try JSONDecoder().decode([WorkspaceSSHProfile].self, from: Data(contentsOf: url))
            } catch {
                self.error = "Could not read SSH profiles: \(error.localizedDescription)"
            }
        }
    }

    func save(_ profile: WorkspaceSSHProfile) throws {
        try profile.validate()
        var next = profiles.filter { $0.id != profile.id }
        next.append(profile)
        try persist(next)
    }

    func remove(_ profile: WorkspaceSSHProfile) throws { try persist(profiles.filter { $0.id != profile.id }) }

    private func persist(_ next: [WorkspaceSSHProfile]) throws {
        // Do not silently overwrite a profile file that failed to decode.
        guard error == nil else { throw WorkspaceError.message(error ?? "Cannot read SSH profiles.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(next).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        profiles = next
    }
}

final class WorkspaceSSHSession: @unchecked Sendable {
    let directory: URL
    let socket: String
    let profile: WorkspaceSSHProfile
    let files: RemoteWorkspaceFiles

    init(_ profile: WorkspaceSSHProfile) throws {
        try profile.validate()
        self.profile = profile
        // Keep well within Darwin's sockaddr_un limit, even with a long TMPDIR.
        directory = URL(fileURLWithPath: "/tmp/gw-\(UUID().uuidString)")
        socket = directory.appendingPathComponent("ssh").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        files = RemoteWorkspaceFiles(socket: socket, destination: profile.host)
    }

    func waitForAuthentication() async throws {
        for _ in 0..<600 {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: socket) { return }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw WorkspaceError.message("SSH authentication did not finish. Complete login in the terminal, then reconnect.")
    }

    func stop() {
        let files = files
        let socket = socket
        let directory = directory
        let host = profile.host
        Task.detached {
            await files.disconnect()
            let control = Process()
            control.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            control.arguments = ["-F", "/dev/null", "-S", socket, "-O", "exit", "--", host]
            control.standardInput = FileHandle.nullDevice
            control.standardOutput = FileHandle.nullDevice
            control.standardError = FileHandle.nullDevice
            try? control.run()
            if control.isRunning { control.waitUntilExit() }
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
