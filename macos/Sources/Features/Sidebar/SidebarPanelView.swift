import AppKit
import SwiftUI

/// The content of one sidebar: its panel, with a separator along the edge it shares with the
/// terminal, or as a card like the terminals when they are framed. Sidebars are opaque, like
/// the terminals beside them.
struct SidebarColumnView: View {
    let edge: SidebarEdge
    @ObservedObject var sidebars: TerminalSidebars

    var body: some View {
        if sidebars.framed {
            card
        } else {
            flat
        }
    }

    /// The panel as a card on the window canvas. The terminal side has no gap of its own
    /// because the terminal cards already keep one from their edge.
    @ViewBuilder
    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: SplitFrame.cornerRadius, style: .continuous)

        Group {
            if let panel = sidebars.side(edge).panel {
                // Sidebars hold no Metal content, so clipping them costs nothing extra.
                SidebarPanelView(panel: panel, sidebars: sidebars)
                    .background(Color(nsColor: ChromePalette.panel))
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color(nsColor: ChromePalette.strongSeparator), lineWidth: 0.5))
            } else {
                Color.clear
            }
        }
        .padding(.vertical, SplitFrame.gap)
        .padding(edge == .leading ? Edge.Set.leading : Edge.Set.trailing, SplitFrame.gap)
    }

    private var flat: some View {
        HStack(spacing: 0) {
            if edge == .trailing {
                separator
            }

            if let panel = sidebars.side(edge).panel {
                SidebarPanelView(panel: panel, sidebars: sidebars)
            } else {
                Spacer(minLength: 0)
            }

            if edge == .leading {
                separator
            }
        }
        .background(Color(nsColor: ChromePalette.panel))
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(nsColor: ChromePalette.separator))
            .frame(width: 1)
    }
}

/// A panel in a sidebar, under its header.
struct SidebarPanelView: View {
    let panel: SidebarPanel
    @ObservedObject var sidebars: TerminalSidebars

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(panel: panel, directory: sidebars.directory)

            switch panel {
            case .git:
                GitView(model: sidebars.git, directory: sidebars.directory)
            case .files:
                FileBrowserView(model: sidebars.files, directory: sidebars.directory)
            }
        }
    }
}

/// The header band of a sidebar panel: its icon and the directory it shows.
struct SidebarHeader: View {
    let panel: SidebarPanel
    let directory: URL?

    @ObservedObject private var chromeAccent = ChromeAccent.shared
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: panel.symbol)
                    .foregroundColor(chromeAccent.color(for: panel.viewKind, inKeyWindow: controlActiveState == .key))
                    .accessibilityLabel(panel.title)

                // Truncate the head so the current directory stays visible.
                Text(directory?.path.abbreviatedPath ?? "No directory")
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundColor(Color(nsColor: directory == nil ? ChromePalette.tertiaryText : ChromePalette.text))
                    .help(directory?.path ?? "")

                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .frame(height: SplitFrame.headerHeight)
            .background(Color(nsColor: ChromePalette.panelHeader))

            Rectangle()
                .fill(Color(nsColor: ChromePalette.separator))
                .frame(height: 1)
        }
    }
}
