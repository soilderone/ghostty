import AppKit
import Combine

/// A panel that a terminal window can show in one of its sidebars.
enum SidebarPanel: String, Codable {
    case files
    case git

    /// The sidebar that shows this panel: files on the left, repository views on the right.
    var edge: SidebarEdge {
        switch self {
        case .files: return .leading
        case .git: return .trailing
        }
    }

    var title: String {
        switch self {
        case .files: return "Files"
        case .git: return "Git"
        }
    }

    /// The SF Symbol for the panel, shared by its sidebar header and its tool rail button.
    var symbol: String {
        switch self {
        case .files: return "folder"
        case .git: return "arrow.triangle.branch"
        }
    }

    var viewKind: ChromePalette.ViewKind {
        switch self {
        case .files: return .files
        case .git: return .git
        }
    }
}

enum SidebarEdge: String, Codable {
    case leading
    case trailing
}

/// The sidebars of one terminal window. Every tab is its own window, so each tab opens and
/// closes its sidebars on its own.
///
/// The sidebars sit outside the split tree. A zoomed panel covers the content area without
/// changing the split tree or resizing the terminals underneath it.
final class TerminalSidebars: ObservableObject {
    /// What one sidebar shows and how wide it is. The width is kept while the sidebar is
    /// closed so that it reopens at the same size.
    struct Side: Codable, Equatable {
        var panel: SidebarPanel?
        var width: CGFloat
    }

    /// The state saved with the window for restoration and for undoing a closed tab.
    struct State: Codable, Equatable {
        var leading: Side
        var trailing: Side
        /// Optional so states saved before panel zoom existed still decode.
        var zoomed: SidebarPanel?
    }

    static let minimumWidth: CGFloat = 160
    static let defaultWidth: CGFloat = 260

    @Published private(set) var leading: Side
    @Published private(set) var trailing: Side
    @Published private(set) var zoomed: SidebarPanel?

    /// The directory of the window's focused terminal as its shell last reported it (OSC 7),
    /// or nil if it hasn't reported one. Panels open here.
    @Published private(set) var directory: URL?

    /// The connection of the last focused terminal. Its remote browsing directory starts at
    /// that account's home and then moves only when the user navigates the remote Files panel.
    @Published private(set) var remoteConnection: SSHConnection?
    @Published private(set) var remoteHome: String?
    @Published private(set) var remoteDirectory: String?
    @Published private(set) var remoteError: String?
    @Published private(set) var isResolvingRemoteDirectory = false
    private var remoteDirectories: [SSHConnection: String] = [:]
    private var remoteHomes: [SSHConnection: String] = [:]
    private var remoteGeneration = 0

    /// Whether the sidebars are drawn as cards, like the terminals with `macos-split-frame`.
    @Published var framed: Bool = false

    /// The Git view's state. It is kept while its sidebar is closed so reopening it is instant,
    /// and it only runs git while it is on screen.
    private(set) lazy var git = GitViewModel()

    /// The file browser's state, kept while its sidebar is closed so it reopens where it was.
    private(set) lazy var files = FileBrowserModel()

    /// Remote preview tabs are kept per host when Files is closed or focus moves to a local split.
    private var remoteFileModels: [SSHConnection: RemoteFileBrowserModel] = [:]

    func remoteFiles(for connection: SSHConnection) -> RemoteFileBrowserModel {
        if let model = remoteFileModels[connection] { return model }
        let model = RemoteFileBrowserModel(connection: connection)
        remoteFileModels[connection] = model
        return model
    }

    init() {
        leading = Side(panel: nil, width: Self.savedWidth(for: .leading))
        trailing = Side(panel: nil, width: Self.savedWidth(for: .trailing))
    }

    var state: State {
        get { State(leading: leading, trailing: trailing, zoomed: zoomed) }
        set {
            leading = Side(panel: newValue.leading.panel, width: Self.clamp(newValue.leading.width))
            trailing = Side(panel: newValue.trailing.panel, width: Self.clamp(newValue.trailing.width))
            if let panel = newValue.zoomed, isOpen(panel) {
                if zoomed != panel { zoomed = panel }
            } else if zoomed != nil {
                zoomed = nil
            }
        }
    }

    func side(_ edge: SidebarEdge) -> Side {
        switch edge {
        case .leading: return leading
        case .trailing: return trailing
        }
    }

    func sidePublisher(_ edge: SidebarEdge) -> AnyPublisher<Side, Never> {
        switch edge {
        case .leading: return $leading.eraseToAnyPublisher()
        case .trailing: return $trailing.eraseToAnyPublisher()
        }
    }

    func zoomPublisher() -> AnyPublisher<SidebarPanel?, Never> {
        $zoomed.eraseToAnyPublisher()
    }

    func isOpen(_ panel: SidebarPanel) -> Bool {
        side(panel.edge).panel == panel
    }

    /// Shows the panel in its sidebar, replacing whatever that sidebar showed, or closes the
    /// sidebar if it already shows the panel.
    func toggle(_ panel: SidebarPanel) {
        if isOpen(panel) {
            update(panel.edge) { $0.panel = nil }
            if zoomed == panel { zoomed = nil }
        } else {
            update(panel.edge) { $0.panel = panel }
            if zoomed != nil { zoomed = nil }
        }
    }

    func toggleZoom(_ panel: SidebarPanel) {
        guard isOpen(panel) else { return }
        zoomed = zoomed == panel ? nil : panel
    }

    func restoreZoom() {
        guard zoomed != nil else { return }
        zoomed = nil
    }

    func setWidth(_ width: CGFloat, for edge: SidebarEdge) {
        let width = Self.clamp(width)
        guard side(edge).width != width else { return }
        update(edge) { $0.width = width }
    }

    /// Makes the sidebar's current width the one that new windows start with.
    func saveWidth(for edge: SidebarEdge) {
        UserDefaults.ghostty.set(Double(side(edge).width), forKey: Self.widthKey(for: edge))
    }

    /// Called with the pwd of the window's focused terminal whenever it changes.
    func directoryDidChange(to pwd: String?) {
        // An empty pwd is how a shell says it no longer knows its directory.
        let url: URL? = if let pwd, !pwd.isEmpty {
            URL(fileURLWithPath: pwd, isDirectory: true)
        } else {
            nil
        }
        guard url != directory else { return }
        directory = url
    }

    var contentDirectory: URL? {
        if remoteConnection != nil {
            return remoteDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        return directory
    }

    func focusedSSHDidChange(to connection: SSHConnection?) {
        guard remoteConnection != connection else { return }
        remoteGeneration += 1
        remoteConnection = connection
        remoteHome = connection.flatMap { remoteHomes[$0] }
        remoteDirectory = connection.flatMap { remoteDirectories[$0] }
        remoteError = nil
        isResolvingRemoteDirectory = false
        if connection != nil && remoteDirectory == nil { refreshRemoteDirectory() }
    }

    func navigateRemote(to path: String) {
        guard let connection = remoteConnection, path.hasPrefix("/") else { return }
        let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        remoteDirectories[connection] = standardized
        remoteDirectory = standardized
    }

    func refreshRemoteDirectory() {
        guard let connection = remoteConnection else { return }
        remoteGeneration += 1
        let generation = remoteGeneration
        remoteError = nil
        isResolvingRemoteDirectory = true
        Task { @MainActor in
            for attempt in 0..<12 {
                guard generation == remoteGeneration, remoteConnection == connection else { return }
                do {
                    let output = try await SSHRunner.run(
                        "pwd", on: connection, maxBytes: 4096, timeout: 5)
                    let path = output.text.split(whereSeparator: \.isNewline)
                        .map(String.init).first(where: { $0.hasPrefix("/") })
                    guard !output.truncated, let path else {
                        throw SSHCommandError(message: "The remote home directory could not be read.")
                    }
                    guard generation == remoteGeneration, remoteConnection == connection else { return }
                    remoteHomes[connection] = path
                    remoteHome = path
                    if remoteDirectory == nil { navigateRemote(to: path) }
                    isResolvingRemoteDirectory = false
                    SSHRecentConnections.remember(connection)
                    return
                } catch {
                    guard generation == remoteGeneration, remoteConnection == connection else { return }
                    let message = error.localizedDescription
                    let authenticationPending = message.contains("Permission denied") ||
                        message.contains("Host key verification failed")
                    guard authenticationPending && attempt < 11 else {
                        isResolvingRemoteDirectory = false
                        remoteError = message
                        return
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    private func update(_ edge: SidebarEdge, _ body: (inout Side) -> Void) {
        switch edge {
        case .leading: body(&leading)
        case .trailing: body(&trailing)
        }
    }

    private static func clamp(_ width: CGFloat) -> CGFloat {
        max(minimumWidth, width)
    }

    private static func widthKey(for edge: SidebarEdge) -> String {
        switch edge {
        case .leading: return "TerminalSidebarLeadingWidth"
        case .trailing: return "TerminalSidebarTrailingWidth"
        }
    }

    private static func savedWidth(for edge: SidebarEdge) -> CGFloat {
        let saved = UserDefaults.ghostty.double(forKey: widthKey(for: edge))
        return saved > 0 ? clamp(CGFloat(saved)) : defaultWidth
    }
}
