import Foundation
import Darwin

/// An OpenSSH destination. OpenSSH still resolves aliases, keys, jump hosts and host keys from
/// the user's SSH configuration; this value only supplies a destination and optional port.
struct SSHConnection: Codable, Hashable {
    let host: String
    let user: String?
    let port: Int?

    private init(host: String, user: String?, port: Int?) {
        self.host = host
        self.user = user
        self.port = port
    }

    init(from decoder: Decoder) throws {
        let encoded = try decoder.singleValueContainer().decode(String.self)
        self = try Self.parse(encoded)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(displayName)
    }

    var destination: String {
        user.map { "\($0)@\(host)" } ?? host
    }

    var displayName: String {
        let displayedHost = host.contains(":") ? "[\(host)]" : host
        let displayedDestination = user.map { "\($0)@\(displayedHost)" } ?? displayedHost
        return displayedDestination + (port.map { ":\($0)" } ?? "")
    }

    static func parse(_ input: String) throws -> SSHConnection {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 512 else { throw SSHConnectionError.invalidDestination }

        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { throw SSHConnectionError.invalidDestination }
        let user = parts.count == 2 ? String(parts[0]) : nil
        let hostAndPort = String(parts.last ?? "")

        let host: String
        let portText: String?
        if hostAndPort.hasPrefix("[") {
            guard let closing = hostAndPort.firstIndex(of: "]") else {
                throw SSHConnectionError.invalidDestination
            }
            host = String(hostAndPort[hostAndPort.index(after: hostAndPort.startIndex)..<closing])
            let suffix = hostAndPort[hostAndPort.index(after: closing)...]
            guard suffix.isEmpty || suffix.hasPrefix(":") else {
                throw SSHConnectionError.invalidDestination
            }
            portText = suffix.isEmpty ? nil : String(suffix.dropFirst())
        } else if let colon = hostAndPort.lastIndex(of: ":") {
            host = String(hostAndPort[..<colon])
            portText = String(hostAndPort[hostAndPort.index(after: colon)...])
            guard !host.contains(":") else { throw SSHConnectionError.invalidDestination }
        } else {
            host = hostAndPort
            portText = nil
        }

        guard validPart(host), !host.hasPrefix("-"), !host.contains("@"),
              user.map({ validPart($0) && !$0.contains(":") && !$0.contains("@") }) ?? true else {
            throw SSHConnectionError.invalidDestination
        }

        let port: Int?
        if let portText {
            guard !portText.isEmpty, portText.allSatisfy(\.isNumber),
                  let number = Int(portText), (1...65535).contains(number) else {
                throw SSHConnectionError.invalidPort
            }
            port = number
        } else {
            port = nil
        }
        return SSHConnection(host: host, user: user, port: port)
    }

    private static func validPart(_ part: String) -> Bool {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        return !part.isEmpty && !part.unicodeScalars.contains(where: forbidden.contains) &&
            !part.contains("/") && !part.contains("\\")
    }

    var sshArguments: [String] {
        (port.map { ["-p", String($0)] } ?? []) + [destination]
    }

    /// The surface command goes through a shell. Quote every argument before it gets there.
    func terminalCommand(controlPath: String?) -> String {
        let executable = Bundle.main.executableURL?.path ?? "/usr/bin/ssh"
        var arguments = [executable]
        if Bundle.main.executableURL != nil {
            arguments += ["+ssh", "--"]
        }
        arguments += Self.controlOptions(path: controlPath)
        arguments += sshArguments
        return "exec " + arguments.map(Self.shellQuote).joined(separator: " ")
    }

    static func controlOptions(path: String?) -> [String] {
        guard let path else { return [] }
        return [
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=600",
            "-o", "ControlPath=\(path)",
        ]
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum SSHConnectionError: LocalizedError {
    case invalidDestination
    case invalidPort

    var errorDescription: String? {
        switch self {
        case .invalidDestination: "Enter a host, user@host, or user@host:port."
        case .invalidPort: "The SSH port must be between 1 and 65535."
        }
    }
}

enum SSHRemotePath {
    /// Resolves a path typed in a remote panel without expanding it against the local home.
    static func resolve(_ input: String, current: String?, home: String?) -> String? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text == "~" { return home }
        if text.hasPrefix("~/"), let home {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(String(text.dropFirst(2))).standardizedFileURL.path
        }
        if text.hasPrefix("/") { return URL(fileURLWithPath: text).standardizedFileURL.path }
        guard let current else { return nil }
        return URL(fileURLWithPath: current, isDirectory: true)
            .appendingPathComponent(text).standardizedFileURL.path
    }
}

/// One private control socket per destination lets Files and Git reuse an authenticated terminal
/// connection without storing credentials or starting an interactive prompt behind the UI.
final class SSHControlPaths: @unchecked Sendable {
    static let shared = SSHControlPaths()

    private let lock = NSLock()
    private let directory: String?
    private var paths: [SSHConnection: String] = [:]

    private init() {
        var template = Array((NSTemporaryDirectory() + "gssh.XXXXXX").utf8CString)
        directory = template.withUnsafeMutableBufferPointer { buffer in
            guard let result = mkdtemp(buffer.baseAddress) else { return nil }
            return String(cString: result)
        }
    }

    func path(for connection: SSHConnection) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let directory else { return nil }
        if let path = paths[connection] { return path }
        let path = directory + "/s" + UUID().uuidString.prefix(16)
        paths[connection] = path
        return path
    }
}
