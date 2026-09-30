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
    let onDismiss: () -> Void

    @State private var input = ""
    @State private var error: String?
    @State private var configuredHosts: [String] = []
    @State private var recentHosts: [String] = []
    @State private var selectedIndex = 0
    @State private var keyboardScrollRequest = 0
    @FocusState private var inputFocused: Bool

    private var query: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var recentMatches: [String] {
        recentHosts.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }

    private var configuredMatches: [String] {
        let recent = Set(recentHosts.map { $0.lowercased() })
        return configuredHosts.filter {
            !recent.contains($0.lowercased()) &&
                (query.isEmpty || $0.localizedCaseInsensitiveContains(query))
        }
    }

    private var directDestination: String? {
        guard !query.isEmpty,
              !recentHosts.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }),
              !configuredHosts.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }),
              (try? SSHConnection.parse(query)) != nil else { return nil }
        return query
    }

    private var rows: [String] {
        recentMatches + configuredMatches + (directDestination.map { [$0] } ?? [])
    }

    private var selectedName: String? {
        let choices = rows
        guard !choices.isEmpty else { return nil }
        return choices[min(selectedIndex, choices.count - 1)]
    }

    private var listHeight: CGFloat {
        let sections = [!recentMatches.isEmpty, !configuredMatches.isEmpty, directDestination != nil]
            .filter { $0 }.count
        let contentHeight = rows.isEmpty ? 78 : rows.count * 30 + sections * 22 + 12
        return CGFloat(min(contentHeight, 250))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
                TextField("Search or enter user@host:port", text: $input)
                    .textFieldStyle(.plain)
                    .focused($inputFocused)
                    .onChange(of: input) { _ in
                        selectedIndex = 0
                        error = nil
                    }
                    .onMoveCommand { direction in
                        switch direction {
                        case .up: moveSelection(-1)
                        case .down: moveSelection(1)
                        default: break
                        }
                    }
                    .onExitCommand(perform: onDismiss)
                    .onSubmit(connectSelected)
                if !input.isEmpty {
                    Button {
                        input = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color(nsColor: ChromePalette.raised))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(8)

            Rectangle()
                .fill(Color(nsColor: ChromePalette.separator))
                .frame(height: 1)

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ChromePalette.error))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        if !recentMatches.isEmpty {
                            sectionTitle("RECENT")
                            ForEach(recentMatches, id: \.self) { name in
                                connectionRow(name, symbol: "clock.arrow.circlepath", label: name)
                            }
                        }
                        if !configuredMatches.isEmpty {
                            sectionTitle("SSH CONFIG")
                            ForEach(configuredMatches, id: \.self) { name in
                                connectionRow(name, symbol: "network", label: name)
                            }
                        }
                        if let directDestination {
                            sectionTitle("NEW CONNECTION")
                            connectionRow(
                                directDestination,
                                symbol: "plus",
                                label: "Connect to \(directDestination)")
                        }
                        if rows.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(query.isEmpty ? "No saved SSH hosts" : "No matching hosts")
                                    .foregroundColor(Color(nsColor: ChromePalette.text))
                                Text(query.isEmpty
                                     ? "Enter a host above or add one to ~/.ssh/config."
                                     : "Enter a valid host or user@host:port to connect.")
                                    .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                            }
                            .font(.system(size: 11))
                            .padding(10)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
                .frame(height: listHeight)
                // Hovering a row must not scroll it back under the pointer while the user
                // scrolls the list. Only keyboard navigation asks to reveal a selection.
                .onChange(of: keyboardScrollRequest) { _ in
                    if let selectedName { proxy.scrollTo(selectedName, anchor: .center) }
                }
                .onChange(of: input) { _ in
                    if let first = rows.first { proxy.scrollTo(first, anchor: .top) }
                }
            }

            Rectangle()
                .fill(Color(nsColor: ChromePalette.separator))
                .frame(height: 1)

            HStack {
                Text("↑↓ Select    ↵ Connect    Esc Close")
                Spacer()
                Text("SSH")
            }
            .font(.system(size: 10))
            .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
            .padding(.horizontal, 12)
            .frame(height: 28)
        }
        .frame(width: 340)
        .background(Color(nsColor: ChromePalette.popover))
        .background {
            Group {
                Button { moveSelection(-1) } label: { Color.clear }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button { moveSelection(1) } label: { Color.clear }
                    .keyboardShortcut(.downArrow, modifiers: [])
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onAppear {
            configuredHosts = SSHHostDiscovery.configuredHosts()
            recentHosts = SSHRecentConnections.list().map(\.displayName)
            DispatchQueue.main.async { inputFocused = true }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
            .padding(.horizontal, 9)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func connectionRow(_ name: String, symbol: String, label: String) -> some View {
        Button {
            connect(name)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 16)
                    .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if selectedName == name {
                    Image(systemName: "return")
                        .font(.system(size: 10))
                        .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
                }
            }
            .font(.system(size: 11))
            .foregroundColor(Color(nsColor: ChromePalette.text))
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selectedName == name ? Color(nsColor: ChromePalette.selectionOverlay) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering, let index = rows.firstIndex(of: name) { selectedIndex = index }
        }
        .id(name)
    }

    private func moveSelection(_ step: Int) {
        guard !rows.isEmpty else { return }
        selectedIndex = max(0, min(selectedIndex + step, rows.count - 1))
        keyboardScrollRequest += 1
    }

    private func connectSelected() {
        connect(selectedName ?? query)
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
