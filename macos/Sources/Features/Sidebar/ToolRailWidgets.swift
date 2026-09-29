import AppKit
import Combine

/// A button that the user adds to the tool rail, as Wave has custom widgets. Each entry of
/// `widgets.json` (in the folder of the Ghostty configuration) is one; clicking the button runs
/// its command in a new terminal.
///
///     [
///       {
///         "label": "Top",
///         "command": "top",
///         "icon": "gauge.medium",
///         "color": "#7DB3A0",
///         "open": "split",
///         "direction": "right",
///         "cwd": "focused",
///         "keep-open": false
///       }
///     ]
///
/// Only `label` and `command` are required. Entries that can't be read are skipped, so a typo
/// in one doesn't take the others with it.
struct ToolRailWidget: Codable, Equatable, Identifiable {
    /// Where the terminal opens.
    enum Placement: String, Codable {
        case split
        case tab
        case window
    }

    /// Which side of the focused terminal a split opens on.
    enum Direction: String, Codable {
        case right
        case left
        case up
        case down
    }

    /// What the button shows under its icon, and its tooltip when there is no `help`.
    var label: String

    /// The shell command to run. It runs the way Ghostty's `command` setting does.
    var command: String

    /// An SF Symbol name. Anything that isn't one (an emoji, a letter) is drawn as text.
    var icon: String?

    /// `#RRGGBB`, the color of the button while the pointer is over it. The accent by default.
    var color: String?

    /// A split by default.
    var open: Placement?

    /// Right by default.
    var direction: Direction?

    /// `focused` (the default) for the working directory of the focused terminal, `home`, or a
    /// path.
    var cwd: String?

    /// Whether the terminal stays open when the command ends, so its output can be read.
    var keepOpen: Bool?

    /// The tooltip.
    var help: String?

    var id: String { label + "\u{0}" + command }

    enum CodingKeys: String, CodingKey {
        case label
        case command
        case icon
        case color
        case open
        case direction
        case cwd
        case keepOpen = "keep-open"
        case help
    }

    var placement: Placement { open ?? .split }
    var splitDirection: Direction { direction ?? .right }

    var tint: NSColor? {
        color.flatMap { NSColor(hex: $0) }
    }

    /// The working directory for the terminal, given the one of the focused terminal. Nil leaves
    /// the choice to Ghostty.
    func workingDirectory(focused: String?) -> String? {
        switch cwd?.trimmingCharacters(in: .whitespaces) ?? "focused" {
        case "", "focused":
            guard let focused, !focused.isEmpty else { return nil }
            return focused
        case "home":
            return NSHomeDirectory()
        case let path:
            return (path as NSString).expandingTildeInPath
        }
    }
}

extension ToolRailWidget {
    /// Reads the widgets of a `widgets.json`, and how many entries were skipped. The file is an
    /// array of widgets, or an object that has one under `widgets`. Nil if it is neither.
    static func parse(_ data: Data) -> (widgets: [ToolRailWidget], skipped: Int)? {
        /// Decodes to nil instead of failing, so one bad entry doesn't fail the whole array.
        struct Lossy: Decodable {
            let widget: ToolRailWidget?

            init(from decoder: Decoder) throws {
                widget = try? ToolRailWidget(from: decoder)
            }
        }

        struct Wrapped: Decodable {
            let widgets: [Lossy]
        }

        let decoder = JSONDecoder()
        let entries: [Lossy]
        if let array = try? decoder.decode([Lossy].self, from: data) {
            entries = array
        } else if let wrapped = try? decoder.decode(Wrapped.self, from: data) {
            entries = wrapped.widgets
        } else {
            return nil
        }

        var seen = Set<String>()
        var widgets: [ToolRailWidget] = []
        var skipped = 0
        for entry in entries {
            guard var widget = entry.widget else {
                skipped += 1
                continue
            }
            widget.label = widget.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let command = widget.command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !widget.label.isEmpty, !command.isEmpty, seen.insert(widget.id).inserted else {
                skipped += 1
                continue
            }
            widgets.append(widget)
        }
        return (widgets, skipped)
    }

    /// What a new `widgets.json` starts with: a widget that works on any Mac.
    static let template = """
    [
      {
        "label": "Top",
        "command": "top",
        "icon": "gauge.medium"
      }
    ]

    """
}

/// The widgets on the tool rail, read from `widgets.json`. They reload when the file changes,
/// when the configuration reloads and when the app comes to the front.
final class ToolRailWidgetStore: ObservableObject {
    static let shared = ToolRailWidgetStore()

    static let fileName = "widgets.json"

    @Published private(set) var widgets: [ToolRailWidget] = []

    /// Set while the file can't be read in full, for the rail to say so.
    @Published private(set) var problem: String?

    private var watcher: DirectoryWatcher?
    private var observers: [NSObjectProtocol] = []

    private init() {
        reload()

        let center = NotificationCenter.default
        for name in [Notification.Name.ghosttyConfigDidChange, NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reload()
            })
        }

        // An editor that saves by replacing the file changes its folder.
        watcher = DirectoryWatcher { [weak self] _ in self?.reload() }
        watcher?.watch(Set(ConfigDirectory.candidates.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }))
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func reload() {
        guard let url = ConfigDirectory.existingFile(named: Self.fileName) else {
            set(widgets: [], problem: nil)
            return
        }

        guard let data = try? Data(contentsOf: url) else {
            set(widgets: [], problem: "Couldn't read \(Self.fileName)")
            return
        }

        guard let parsed = ToolRailWidget.parse(data) else {
            set(widgets: [], problem: "\(Self.fileName) isn't a list of widgets")
            return
        }

        let problem = parsed.skipped == 0
            ? nil
            : "\(parsed.skipped) \(parsed.skipped == 1 ? "entry" : "entries") in \(Self.fileName) skipped"
        set(widgets: parsed.widgets, problem: problem)
    }

    private func set(widgets: [ToolRailWidget], problem: String?) {
        if widgets != self.widgets { self.widgets = widgets }
        if problem != self.problem { self.problem = problem }
    }

    /// Opens `widgets.json` in a text editor, creating it with an example first if needed.
    func openFile() {
        ConfigDirectory.openForEditing(named: Self.fileName, template: ToolRailWidget.template)
    }
}
