import AppKit
import Darwin
import SwiftUI

/// Host aliases are suggestions only. OpenSSH remains the authority for Include, Match,
/// ProxyJump, keys and all other connection settings when a destination is opened.
enum SSHHostDiscovery {
    static func configuredHosts() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var visited = Set<String>()
        var hosts = Set<String>()
        scan(home + "/.ssh/config", depth: 0, visited: &visited, hosts: &hosts)
        scan("/etc/ssh/ssh_config", depth: 0, visited: &visited, hosts: &hosts)
        return hosts.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func scan(
        _ path: String,
        depth: Int,
        visited: inout Set<String>,
        hosts: inout Set<String>
    ) {
        guard depth < 8 else { return }
        let path = (path as NSString).standardizingPath
        guard visited.insert(path).inserted,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber, size.intValue <= 1024 * 1024,
              let config = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        for rawLine in config.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).split(separator: "#", maxSplits: 1).first.map(String.init) ?? ""
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let directive = fields.first?.lowercased() else { continue }
            switch directive {
            case "host":
                for pattern in fields.dropFirst() where !pattern.contains("*") &&
                    !pattern.contains("?") && !pattern.hasPrefix("!") {
                    hosts.insert(pattern)
                }
            case "include":
                for pattern in fields.dropFirst() {
                    let expanded = (pattern as NSString).expandingTildeInPath
                    let resolved = expanded.hasPrefix("/")
                        ? expanded
                        : ((path as NSString).deletingLastPathComponent as NSString)
                            .appendingPathComponent(expanded)
                    for included in matchingPaths(resolved) {
                        scan(included, depth: depth + 1, visited: &visited, hosts: &hosts)
                    }
                }
            default:
                break
            }
        }
    }

    private static func matchingPaths(_ pattern: String) -> [String] {
        var matches = glob_t()
        defer { globfree(&matches) }
        guard pattern.withCString({ glob($0, 0, nil, &matches) }) == 0 else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { index in
            matches.gl_pathv[index].map { String(cString: $0) }
        }
    }
}

enum SSHRecentConnections {
    private static let key = "SSHRecentConnections"

    static func list() -> [SSHConnection] {
        (UserDefaults.ghostty.stringArray(forKey: key) ?? []).compactMap { try? SSHConnection.parse($0) }
    }

    static func remember(_ connection: SSHConnection) {
        let names = [connection.displayName] + list().map(\.displayName).filter { $0 != connection.displayName }
        UserDefaults.ghostty.set(Array(names.prefix(20)), forKey: key)
    }
}

/// The picker is shared by the terminal card and the tool rail. Selecting a host opens a new
/// split; the existing local shell is left in place for another connection or local work.
struct SSHConnectionPicker: View {
    let onConnect: (SSHConnection) -> Void

    @State private var input = ""
    @State private var error: String?
    @State private var configuredHosts: [String] = []
    @FocusState private var inputFocused: Bool

    private var suggestions: [String] {
        let names = SSHRecentConnections.list().map(\.displayName) + configuredHosts
        var seen = Set<String>()
        return names.filter { name in
            seen.insert(name).inserted &&
                (input.isEmpty || name.localizedCaseInsensitiveContains(input))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SSH Connection")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 8) {
                TextField("host, user@host, or user@host:port", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit(connectInput)
                Button("Connect", action: connectInput)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ChromePalette.error))
            }

            if suggestions.isEmpty {
                Text("Type an SSH destination to connect.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(suggestions, id: \.self) { name in
                    Button {
                        connect(name)
                    } label: {
                        Label(name, systemImage: "network")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 380, height: 310)
        .onAppear {
            configuredHosts = SSHHostDiscovery.configuredHosts()
            inputFocused = true
        }
    }

    private func connectInput() {
        connect(input)
    }

    private func connect(_ text: String) {
        do {
            let connection = try SSHConnection.parse(text)
            error = nil
            onConnect(connection)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
