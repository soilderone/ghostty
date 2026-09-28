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
/// The sidebars sit outside the split tree. They take no part in split focus, zoom or the
/// split tree's restoration, and opening one only makes the terminal area narrower.
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
    }

    static let minimumWidth: CGFloat = 160
    static let defaultWidth: CGFloat = 260

    @Published private(set) var leading: Side
    @Published private(set) var trailing: Side

    /// The directory of the window's focused terminal as its shell last reported it (OSC 7),
    /// or nil if it hasn't reported one. Panels open here.
    @Published private(set) var directory: URL?

    /// Whether the sidebars are drawn as cards, like the terminals with `macos-split-frame`.
    @Published var framed: Bool = false

    /// The Git view's state. It is kept while its sidebar is closed so reopening it is instant,
    /// and it only runs git while it is on screen.
    private(set) lazy var git = GitViewModel()

    /// The file browser's state, kept while its sidebar is closed so it reopens where it was.
    private(set) lazy var files = FileBrowserModel()

    init() {
        leading = Side(panel: nil, width: Self.savedWidth(for: .leading))
        trailing = Side(panel: nil, width: Self.savedWidth(for: .trailing))
    }

    var state: State {
        get { State(leading: leading, trailing: trailing) }
        set {
            leading = Side(panel: newValue.leading.panel, width: Self.clamp(newValue.leading.width))
            trailing = Side(panel: newValue.trailing.panel, width: Self.clamp(newValue.trailing.width))
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

    func isOpen(_ panel: SidebarPanel) -> Bool {
        side(panel.edge).panel == panel
    }

    /// Shows the panel in its sidebar, replacing whatever that sidebar showed, or closes the
    /// sidebar if it already shows the panel.
    func toggle(_ panel: SidebarPanel) {
        let newPanel: SidebarPanel? = isOpen(panel) ? nil : panel
        update(panel.edge) { $0.panel = newPanel }
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
