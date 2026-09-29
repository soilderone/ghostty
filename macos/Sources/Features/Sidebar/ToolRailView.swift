import AppKit
import SwiftUI

/// What the tool rail's buttons do. The window's controller provides these.
struct ToolRailActions {
    let newSplit: () -> Void
    let connectSSH: (SSHConnection) -> Void
    let toggleSidebar: (SidebarPanel) -> Void
    let openConfig: () -> Void
}

/// The tool rail (`macos-tool-rail`): a narrow bar along the right edge of a terminal window
/// with buttons for a new split, the sidebars and the configuration file.
///
/// The rail has no background of its own. It sits on the window background, so with
/// `macos-window-vibrancy` the material shows through it like it does through the titlebar.
struct ToolRailView: View {
    static let width: CGFloat = 48

    @ObservedObject var sidebars: TerminalSidebars
    let actions: ToolRailActions
    @State private var showsSSHConnectionPicker = false

    var body: some View {
        HStack(spacing: 0) {
            // Cards have their own borders and a gap to the rail.
            if !sidebars.framed {
                Rectangle()
                    .fill(Color(nsColor: ChromePalette.separator))
                    .frame(width: 1)
            }

            // Drop the labels when the window is too short for all of them.
            ViewThatFits(in: .vertical) {
                buttons(showsLabels: true)
                buttons(showsLabels: false)
            }
        }
        .popover(isPresented: $showsSSHConnectionPicker) {
            SSHConnectionPicker(onConnect: { connection in
                showsSSHConnectionPicker = false
                actions.connectSSH(connection)
            }, onDismiss: {
                showsSSHConnectionPicker = false
            })
        }
    }

    private func buttons(showsLabels: Bool) -> some View {
        VStack(spacing: 2) {
            ToolRailButton(
                title: "Terminal",
                symbol: "terminal",
                tint: .kind(.terminal),
                isActive: false,
                showsLabel: showsLabels,
                help: "New Split Right",
                action: actions.newSplit)

            ToolRailButton(
                title: "SSH",
                symbol: "network",
                tint: .kind(.terminal),
                isActive: false,
                showsLabel: showsLabels,
                help: "Connect SSH",
                action: { showsSSHConnectionPicker = true })

            sidebarButton(.files, showsLabel: showsLabels)
            sidebarButton(.git, showsLabel: showsLabels)

            Spacer(minLength: 0)

            ToolRailButton(
                title: "Settings",
                symbol: "gearshape",
                tint: .neutral,
                isActive: false,
                showsLabel: showsLabels,
                help: "Open Configuration",
                action: actions.openConfig)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }

    private func sidebarButton(_ panel: SidebarPanel, showsLabel: Bool) -> some View {
        let isOpen = sidebars.isOpen(panel)
        return ToolRailButton(
            title: panel.title,
            symbol: panel.symbol,
            tint: .kind(panel.viewKind),
            isActive: isOpen,
            showsLabel: showsLabel,
            help: isOpen ? "Hide \(panel.title) Sidebar" : "Show \(panel.title) Sidebar",
            action: { actions.toggleSidebar(panel) })
    }
}

/// A button on the tool rail. It is gray at rest and takes the color of its view kind under
/// the pointer and while its sidebar is open, so the rail stays quiet next to the terminals.
private struct ToolRailButton: View {
    enum Tint {
        /// The color of a view kind: the chrome accent for terminals.
        case kind(ChromePalette.ViewKind)

        /// Plain text color, for buttons that don't open a view.
        case neutral
    }

    let title: String
    let symbol: String
    let tint: Tint
    let isActive: Bool
    let showsLabel: Bool
    let help: String
    let action: () -> Void

    @ObservedObject private var chromeAccent = ChromeAccent.shared
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundColor(iconColor)
                    .frame(height: 18)

                if showsLabel {
                    Text(title)
                        .font(.system(size: 9.5))
                        .lineLimit(1)
                        .foregroundColor(labelColor)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundColor))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The terminal keeps keyboard focus when a rail button is clicked.
        .focusable(false)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var isHighlighted: Bool {
        isHovered || isActive
    }

    /// The tint of the button while it is highlighted. Gray while the window isn't key.
    private var highlightColor: Color {
        switch tint {
        case .kind(let kind):
            return chromeAccent.color(for: kind, inKeyWindow: controlActiveState == .key)
        case .neutral:
            return Color(nsColor: ChromePalette.text)
        }
    }

    private var iconColor: Color {
        isHighlighted ? highlightColor : Color(nsColor: ChromePalette.secondaryText)
    }

    private var labelColor: Color {
        Color(nsColor: isHighlighted ? ChromePalette.text : ChromePalette.secondaryText)
    }

    private var backgroundColor: Color {
        guard isHighlighted else { return .clear }
        switch tint {
        case .kind:
            return highlightColor.opacity(0.13)
        case .neutral:
            return Color(nsColor: ChromePalette.hoverOverlay)
        }
    }
}
