import AppKit
import Combine
import SwiftUI

/// The frame drawn around each terminal with `macos-split-frame`: a rounded card with a
/// header, separated from its neighbors by a gap that shows the window canvas.
///
/// The terminal itself is never clipped. It sits inside the card with a margin on the sides
/// and bottom that is wide enough for the rounded corners, and the card draws its background
/// only in that margin. Clipping the Metal-backed terminal to a rounded shape can make the
/// compositor render it offscreen, which would cost memory for every terminal on screen.
enum SplitFrame {
    /// The space between two cards, and between a card and the window edge.
    static let gap: CGFloat = 5

    /// The space between the card's edge and the terminal on the sides and bottom.
    static let margin: CGFloat = 5

    static let headerHeight: CGFloat = 28
    static let cornerRadius: CGFloat = 10

    /// The space the frame takes around a single terminal in a window. `window-width` and
    /// `window-height` size the terminal, so this comes on top of them.
    static let windowChromeSize = NSSize(
        width: 2 * gap + 2 * margin,
        height: 2 * gap + headerHeight + margin)
}

/// The state of the split tree that a card's header reflects.
struct SplitFrameTree: Equatable {
    /// Whether the tree has more than one terminal, so zooming one means something.
    var isSplit: Bool = false

    /// Whether a terminal is zoomed.
    var isZoomed: Bool = false
}

private struct SplitFramesAllowedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ShowsSplitFramesKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SplitFrameTreeKey: EnvironmentKey {
    static let defaultValue = SplitFrameTree()
}

extension EnvironmentValues {
    /// Whether the terminals in this view may be framed. Only the windows that set this draw
    /// frames, and then only when `macos-split-frame` is on.
    var splitFramesAllowed: Bool {
        get { self[SplitFramesAllowedKey.self] }
        set { self[SplitFramesAllowedKey.self] = newValue }
    }

    /// Whether the terminals in this view are drawn as cards.
    var showsSplitFrames: Bool {
        get { self[ShowsSplitFramesKey.self] }
        set { self[ShowsSplitFramesKey.self] = newValue }
    }

    var splitFrameTree: SplitFrameTree {
        get { self[SplitFrameTreeKey.self] }
        set { self[SplitFrameTreeKey.self] = newValue }
    }
}

// MARK: Card

/// A terminal drawn as a card: its header, its border and the margin around it.
struct SplitCard<Content: View>: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let content: Content

    @Environment(\.ghosttyLastFocusedSurface) private var lastFocusedSurface
    @Environment(\.controlActiveState) private var controlActiveState
    @ObservedObject private var chromeAccent = ChromeAccent.shared
    @State private var isHovered = false

    init(surfaceView: Ghostty.SurfaceView, @ViewBuilder content: () -> Content) {
        self.surfaceView = surfaceView
        self.content = content()
    }

    /// The last focused terminal stays focused while focus is outside the split tree.
    private var isFocused: Bool {
        lastFocusedSurface?.value === surfaceView
    }

    /// The accent of the focus border and header. Gray while the window isn't key.
    private var accent: Color {
        chromeAccent.color(for: .terminal, inKeyWindow: controlActiveState == .key)
    }

    /// The terminal's background, which the card continues into its margin.
    private var terminalBackground: NSColor {
        let color = surfaceView.backgroundColor ?? surfaceView.derivedConfig.backgroundColor
        let alpha = surfaceView.derivedConfig.backgroundOpacity.clamped(to: 0.001...1)
        return NSColor(color).withAlphaComponent(alpha)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: SplitFrame.cornerRadius, style: .continuous)

        ZStack(alignment: .top) {
            SplitCardBackground(
                headerColor: Color(nsColor: ChromePalette.header(over: terminalBackground)),
                headerTint: isFocused ? accent.opacity(0.07) : .clear,
                marginColor: Color(nsColor: terminalBackground))
                .contentShape(shape)
                .onTapGesture { Ghostty.moveFocus(to: surfaceView) }

            content
                .padding(EdgeInsets(
                    top: SplitFrame.headerHeight,
                    leading: SplitFrame.margin,
                    bottom: SplitFrame.margin,
                    trailing: SplitFrame.margin))

            SplitHeader(
                surfaceView: surfaceView,
                isFocused: isFocused,
                accent: accent,
                showsControls: isHovered || isFocused)
                .frame(height: SplitFrame.headerHeight)

            border(shape)
                .allowsHitTesting(false)
        }
        .onHover { isHovered = $0 }
    }

    /// A hairline at rest; the focused card's border takes 60% of the accent, as in Wave.
    @ViewBuilder
    private func border(_ shape: RoundedRectangle) -> some View {
        if isFocused {
            ZStack {
                shape.strokeBorder(Color(nsColor: ChromePalette.separator), lineWidth: 1)
                shape.strokeBorder(accent.opacity(0.6), lineWidth: 1)
            }
        } else {
            shape.strokeBorder(Color(nsColor: ChromePalette.strongSeparator), lineWidth: 0.5)
        }
    }
}

/// The card's own fill: the header band at the top and the margin around the terminal. The
/// terminal's area is left empty since the terminal draws its own background there, which would
/// otherwise double up when `background-opacity` is below 1.
private struct SplitCardBackground: View {
    let headerColor: Color
    let headerTint: Color
    let marginColor: Color

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let shape = RoundedRectangle(cornerRadius: SplitFrame.cornerRadius, style: .continuous)

            // Each band is the whole card cut down to its part, so the rounded corners land in
            // the right band. Only these shapes are clipped, never the terminal.
            VStack(spacing: 0) {
                ZStack {
                    shape.fill(headerColor)
                    shape.fill(headerTint)
                }
                .frame(width: size.width, height: size.height)
                .frame(height: min(SplitFrame.headerHeight, size.height), alignment: .top)
                .clipped()

                SplitCardMargin()
                    .fill(marginColor, style: FillStyle(eoFill: true))
                    .frame(width: size.width, height: size.height)
                    .frame(height: max(size.height - SplitFrame.headerHeight, 0), alignment: .bottom)
                    .clipped()
            }
        }
    }
}

/// The card with a hole where the terminal is, filled even-odd.
private struct SplitCardMargin: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: SplitFrame.cornerRadius, style: .continuous)
        let terminal = CGRect(
            x: rect.minX + SplitFrame.margin,
            y: rect.minY + SplitFrame.headerHeight,
            width: rect.width - 2 * SplitFrame.margin,
            height: rect.height - SplitFrame.headerHeight - SplitFrame.margin)
        if terminal.width > 0 && terminal.height > 0 {
            path.addRect(terminal)
        }
        return path
    }
}

// MARK: Header

/// A card's header: the terminal icon, its directory (or title), and buttons to zoom and close
/// it. Dragging the header moves the terminal.
private struct SplitHeader: View {
    @ObservedObject var surfaceView: Ghostty.SurfaceView
    let isFocused: Bool
    let accent: Color
    let showsControls: Bool

    @EnvironmentObject private var ghostty: Ghostty.App
    @Environment(\.splitFrameTree) private var tree

    /// Whether terminal content has scrolled up under the header, which shows its separator.
    @State private var isScrolled = false
    @State private var isDragging = false
    @State private var isHoveringDragSource = false
    @State private var showsSSHConnectionPicker = false

    private var directory: String? {
        guard let pwd = surfaceView.pwd, !pwd.isEmpty else { return nil }
        return pwd
    }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                Image(systemName: surfaceView.sshConnection == nil ? "terminal" :
                      (surfaceView.childExitedMessage == nil ? "network" : "network.slash"))
                    .font(.system(size: 11))
                    .foregroundColor(isFocused ? accent : Color(nsColor: ChromePalette.tertiaryText))

                // Truncate the head so the current directory stays visible.
                Text(surfaceView.sshConnection.map {
                    "SSH \($0.displayName)" + (surfaceView.childExitedMessage == nil ? "" : " · Disconnected")
                } ??
                     (directory?.abbreviatedPath ?? surfaceView.title))
                    .font(directory == nil ? Font.system(size: 12) : Font.system(size: 11.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .foregroundColor(Color(nsColor: ChromePalette.text).opacity(0.75))
            }
            // Clicks go through to the drag source behind.
            .allowsHitTesting(false)

            Spacer(minLength: 0)

            controls
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // This replaces the drag handle at the top of the terminal. A click without a
            // drag focuses the terminal.
            Ghostty.SurfaceDragSource(
                surfaceView: surfaceView,
                isDragging: $isDragging,
                isHovering: $isHoveringDragSource)
        }
        .overlay(alignment: .bottom) {
            if isScrolled {
                Rectangle()
                    .fill(Color(nsColor: ChromePalette.strongSeparator))
                    .frame(height: 0.5)
                    .allowsHitTesting(false)
            }
        }
        .help(directory ?? surfaceView.title)
        .onAppear {
            isScrolled = (surfaceView.scrollbar?.offset ?? 0) > 0
        }
        .onReceive(scrollbarOffsets) { offset in
            let scrolled = offset > 0
            guard scrolled != isScrolled else { return }
            isScrolled = scrolled
        }
    }

    private var scrollbarOffsets: AnyPublisher<UInt64, Never> {
        NotificationCenter.default
            .publisher(for: .ghosttyDidUpdateScrollbar, object: surfaceView)
            .compactMap { $0.userInfo?[Notification.Name.ScrollbarKey] as? Ghostty.Action.Scrollbar }
            .map(\.offset)
            .eraseToAnyPublisher()
    }

    private var controls: some View {
        HStack(spacing: 2) {
            if surfaceView.sshConnection != nil && surfaceView.childExitedMessage != nil {
                SplitHeaderButton(symbol: "arrow.clockwise", help: "Reconnect SSH") {
                    (surfaceView.window?.windowController as? TerminalController)?
                        .reconnectSSH(on: surfaceView)
                }
            }

            SplitHeaderButton(symbol: "network", help: "Connect SSH") {
                showsSSHConnectionPicker = true
            }
            .popover(isPresented: $showsSSHConnectionPicker) {
                SSHConnectionPicker { connection in
                    showsSSHConnectionPicker = false
                    (surfaceView.window?.windowController as? TerminalController)?
                        .connectSSH(connection, from: surfaceView)
                }
            }

            SplitHeaderButton(
                symbol: tree.isZoomed ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                help: tree.isZoomed ? "Restore Split" : "Zoom Split",
                isEnabled: tree.isSplit
            ) {
                guard let surface = surfaceView.surface else { return }
                ghostty.splitToggleZoom(surface: surface)
            }

            SplitHeaderButton(symbol: "xmark", help: "Close Terminal", isDestructive: true) {
                guard let surface = surfaceView.surface else { return }
                ghostty.requestClose(surface: surface)
            }
        }
        .opacity(showsControls ? 1 : 0.45)
    }
}

/// A small icon button at the end of a card's header.
private struct SplitHeaderButton: View {
    let symbol: String
    let help: String
    var isEnabled: Bool = true
    var isDestructive: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(foregroundColor)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The terminal keeps keyboard focus when a header button is clicked.
        .focusable(false)
        .disabled(!isEnabled)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    private var foregroundColor: Color {
        guard isEnabled else { return Color(nsColor: ChromePalette.tertiaryText).opacity(0.5) }
        if isHovered && isDestructive { return Color(nsColor: ChromePalette.error) }
        return Color(nsColor: ChromePalette.text)
    }

    private var backgroundColor: Color {
        guard isEnabled && isHovered else { return .clear }
        return isDestructive
            ? Color(nsColor: ChromePalette.error).opacity(0.14)
            : Color(nsColor: ChromePalette.hoverOverlay)
    }
}
