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

    /// The panel as a card on the window canvas. A zoomed panel has gaps on both sides;
    /// at normal width the terminal cards provide the gap on its inner edge.
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
        .padding(sidebars.zoomed?.edge == edge ? Edge.Set.horizontal :
                    (edge == .leading ? .leading : .trailing), SplitFrame.gap)
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
            SidebarHeader(
                panel: panel,
                directory: sidebars.contentDirectory,
                connection: sidebars.remoteConnection,
                remoteHome: sidebars.remoteHome,
                isZoomed: sidebars.zoomed == panel,
                onNavigateRemote: { sidebars.navigateRemote(to: $0) },
                onToggleZoom: { sidebars.toggleZoom(panel) })

            switch panel {
            case .git:
                if sidebars.remoteConnection != nil && sidebars.remoteDirectory == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "network")
                        Text("Waiting for SSH")
                            .font(.system(size: 12, weight: .medium))
                        Text(sidebars.remoteError ?? "Finish connecting in the terminal, then retry.")
                            .font(.system(size: 11))
                            .multilineTextAlignment(.center)
                        Button("Retry") { sidebars.refreshRemoteDirectory() }
                            .disabled(sidebars.isResolvingRemoteDirectory)
                    }
                    .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GitView(
                        model: sidebars.git,
                        directory: sidebars.contentDirectory,
                        connection: sidebars.remoteConnection,
                        isCovered: sidebars.zoomed != nil && sidebars.zoomed != .git)
                }
            case .files:
                if let connection = sidebars.remoteConnection {
                    RemoteFileBrowserView(connection: connection, sidebars: sidebars)
                        .id(connection)
                } else {
                    FileBrowserView(model: sidebars.files, directory: sidebars.directory)
                }
            }
        }
    }
}

/// The header band of a sidebar panel: its icon and the directory it shows.
struct SidebarHeader: View {
    let panel: SidebarPanel
    let directory: URL?
    let connection: SSHConnection?
    let remoteHome: String?
    let isZoomed: Bool
    let onNavigateRemote: (String) -> Void
    let onToggleZoom: () -> Void

    @ObservedObject private var chromeAccent = ChromeAccent.shared
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var showsRemotePathPicker = false
    @State private var remotePathInput = ""
    @State private var remotePathError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: panel.symbol)
                    .foregroundColor(chromeAccent.color(for: panel.viewKind, inKeyWindow: controlActiveState == .key))
                    .accessibilityLabel(panel.title)

                // Truncate the head so the current directory stays visible.
                Text(connection.map { "\($0.displayName) · \(directory?.path ?? "Remote home")" } ??
                     (directory?.path.abbreviatedPath ?? "No directory"))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundColor(Color(nsColor: directory == nil ? ChromePalette.tertiaryText : ChromePalette.text))
                    .help(directory?.path ?? "")

                Spacer(minLength: 0)

                if connection != nil {
                    Button {
                        remotePathInput = directory?.path ?? remoteHome ?? ""
                        remotePathError = nil
                        showsRemotePathPicker = true
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help("Change remote directory")
                    .popover(isPresented: $showsRemotePathPicker) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Remote Directory")
                                .font(.system(size: 12, weight: .semibold))
                            TextField("/path/on/host", text: $remotePathInput)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(navigateRemote)
                            if let remotePathError {
                                Text(remotePathError)
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(nsColor: ChromePalette.error))
                            }
                            HStack {
                                Spacer()
                                Button("Go", action: navigateRemote)
                            }
                        }
                        .padding(12)
                        .frame(width: 330)
                    }
                }

                Button(action: onToggleZoom) {
                    Image(systemName: isZoomed
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(nsColor: ChromePalette.secondaryText))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(isZoomed ? "Restore \(panel.title)" : "Zoom \(panel.title)")
                .accessibilityLabel(isZoomed ? "Restore \(panel.title)" : "Zoom \(panel.title)")
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

    private func navigateRemote() {
        guard let connection,
              let path = SSHRemotePath.resolve(
                remotePathInput, current: directory?.path, home: remoteHome) else { return }
        Task { @MainActor in
            do {
                _ = try await SSHRunner.run(
                    "test -d \(SSHConnection.shellQuote(path)) || " +
                    "{ printf 'The remote path is not a folder.\\n' >&2; exit 1; }",
                    on: connection, maxBytes: 1024)
                onNavigateRemote(path)
                showsRemotePathPicker = false
            } catch {
                remotePathError = error.localizedDescription
            }
        }
    }
}
