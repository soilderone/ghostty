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
                SidebarPanelView(panel: panel, directory: sidebars.directory)
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
                SidebarPanelView(panel: panel, directory: sidebars.directory)
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

/// A panel in a sidebar. The files and git panels aren't built yet (features 10 and 9), so this
/// shows the header they'll have and where they will open.
struct SidebarPanelView: View {
    let panel: SidebarPanel
    let directory: URL?

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader(panel: panel, directory: directory)

            VStack(spacing: 6) {
                Image(systemName: panel.symbol)
                    .font(.system(size: 22))
                    .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
                Text(placeholderTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                Text(placeholderDetail)
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: ChromePalette.tertiaryText))
            }
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var placeholderTitle: String {
        switch panel {
        case .files: return "The file browser isn't built yet."
        case .git: return "The Git view isn't built yet."
        }
    }

    private var placeholderDetail: String {
        guard directory != nil else {
            return "The focused terminal hasn't reported its directory. Shell integration reports it at each prompt."
        }

        switch panel {
        case .files: return "It will open at the focused terminal's directory."
        case .git: return "It will open the repository of the focused terminal's directory."
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
