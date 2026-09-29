import AppKit
import SwiftUI

/// The capsule tab bar: a glass track holding a capsule per tab, with a raised pill under the
/// selected one, then a button for a new tab and empty space to drag the window by.
struct CapsuleTabBar: View {
    @ObservedObject var tabs: CapsuleTabs

    @ObservedObject private var chromeAccent = ChromeAccent.shared
    @Environment(\.controlActiveState) private var controlActiveState

    /// The tab being dragged to a new place.
    @State private var drag: TabDrag?

    private struct TabDrag {
        let id: ObjectIdentifier
        let from: Int
        var to: Int
        var offset: CGFloat
    }

    var body: some View {
        GeometryReader { geo in
            let layout = CapsuleTabs.layout(count: tabs.tabs.count, width: geo.size.width)
            HStack(spacing: CapsuleTabs.spacing) {
                track(layout)
                CapsuleNewTabButton { tabs.newTab() }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(CapsuleWindowDragArea())
    }

    // MARK: Track

    private func track(_ layout: CapsuleTabs.Layout) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: CapsuleTabs.barHeight / 2, style: .continuous)
                .fill(Color(nsColor: ChromePalette.glass))
                .overlay(
                    RoundedRectangle(cornerRadius: CapsuleTabs.barHeight / 2, style: .continuous)
                        .strokeBorder(Color(nsColor: ChromePalette.strongSeparator), lineWidth: 0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: CapsuleTabs.barHeight / 2, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color(nsColor: ChromePalette.rim), .clear],
                                startPoint: .top,
                                endPoint: .center),
                            lineWidth: 1)
                        .padding(0.5))

            if !tabs.tabs.isEmpty {
                pill(layout)
            }

            ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                tabItem(tab, index: index, layout: layout)
            }
        }
        .frame(width: layout.tracksWidth, height: CapsuleTabs.barHeight, alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: drag?.to)
    }

    /// The raised pill under the selected tab. It follows the tab while it is dragged, and
    /// otherwise slides with `CapsuleTabs.pillPosition`.
    private func pill(_ layout: CapsuleTabs.Layout) -> some View {
        let x = drag == nil
            ? tabs.pillPosition * layout.tabWidth
            : position(of: tabs.selectedIndex, layout: layout)
        let shape = RoundedRectangle(cornerRadius: CapsuleTabs.barHeight / 2 - 2, style: .continuous)
        return shape
            .fill(Color(nsColor: ChromePalette.thumb))
            .overlay(shape.strokeBorder(Color(nsColor: ChromePalette.strongSeparator), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.1), radius: 1.5, y: 1)
            .frame(width: layout.tabWidth - 4, height: CapsuleTabs.barHeight - 4)
            .offset(x: x + 2)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func tabItem(_ tab: CapsuleTabs.Tab, index: Int, layout: CapsuleTabs.Layout) -> some View {
        let isSelected = index == tabs.selectedIndex
        let view = CapsuleTabView(
            tab: tab,
            isSelected: isSelected,
            // A lone tab has no tab bar, so the titlebar shows its own reset zoom button.
            showsZoom: tab.isZoomed && tabs.tabs.count > 1,
            accent: chromeAccent.color(inKeyWindow: controlActiveState == .key),
            onClose: { tabs.close(index) },
            onResetZoom: { tabs.resetZoom(index) })
            .frame(width: layout.tabWidth, height: CapsuleTabs.barHeight)
            .offset(x: position(of: index, layout: layout))
            .zIndex(drag?.id == tab.id ? 1 : 0)
            .gesture(reorderGesture(tab, index: index, layout: layout))

        // Only the selected tab takes a double click, so selecting another tab isn't held up
        // waiting to see whether a second click follows.
        if isSelected {
            view.onTapGesture(count: 2) { tabs.rename(index) }
        } else {
            view.onTapGesture { tabs.select(index) }
        }
    }

    /// Where a tab is drawn: its own place, or while another tab is dragged, the place it
    /// makes room in.
    private func position(of index: Int, layout: CapsuleTabs.Layout) -> CGFloat {
        guard let drag else { return CGFloat(index) * layout.tabWidth }
        if index == drag.from {
            return CGFloat(index) * layout.tabWidth + drag.offset
        }

        var place = index
        if drag.from < drag.to && index > drag.from && index <= drag.to {
            place -= 1
        } else if drag.to < drag.from && index >= drag.to && index < drag.from {
            place += 1
        }
        return CGFloat(place) * layout.tabWidth
    }

    private func reorderGesture(_ tab: CapsuleTabs.Tab, index: Int, layout: CapsuleTabs.Layout) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                let count = tabs.tabs.count
                let proposed = (CGFloat(index) * layout.tabWidth + value.translation.width) / layout.tabWidth
                let to = min(max(Int(proposed.rounded()), 0), count - 1)
                drag = TabDrag(id: tab.id, from: index, to: to, offset: value.translation.width)
            }
            .onEnded { _ in
                guard let finished = drag else { return }
                drag = nil
                tabs.move(from: finished.from, to: finished.to)
            }
    }
}

// MARK: Tab

/// One tab: a dot, the title and a close button. The dot takes the accent on the selected
/// tab, and a tab color tints the whole capsule. A badge (a command failed, the bell rang)
/// takes the dot's place until the tab is looked at.
private struct CapsuleTabView: View {
    let tab: CapsuleTabs.Tab
    let isSelected: Bool
    let showsZoom: Bool
    let accent: Color
    let onClose: () -> Void
    let onResetZoom: () -> Void

    @State private var isHovered = false

    private var title: String {
        tab.title.isEmpty ? "Terminal" : tab.title
    }

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: CapsuleTabs.barHeight / 2 - 2, style: .continuous)
                .fill(background)
                .padding(2)

            HStack(spacing: 0) {
                Group {
                    if let badge = tab.badge {
                        TerminalBadgeIcon(badge: badge, size: 11)
                    } else {
                        Circle()
                            .fill(isSelected ? accent : Color(nsColor: ChromePalette.tertiaryText).opacity(0.7))
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(width: 12, height: 12)
                .padding(.leading, 11)

                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(Color(nsColor: isSelected ? ChromePalette.text : ChromePalette.secondaryText))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 4)

                Spacer(minLength: 2)

                if showsZoom {
                    CapsuleTabButton(symbol: "arrow.down.right.and.arrow.up.left", help: "Reset Split Zoom", tint: accent, action: onResetZoom)
                }
                CapsuleTabButton(symbol: "xmark", help: "Close Tab", action: onClose)
                    .opacity(isSelected || isHovered ? 1 : 0)
                    .padding(.trailing, 7)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }

    private var background: Color {
        if let color = tab.color.displayColor {
            let amount = isSelected ? 0.38 : (isHovered ? 0.32 : 0.22)
            return Color(nsColor: color).opacity(amount)
        }
        if !isSelected && isHovered {
            return Color(nsColor: ChromePalette.hoverOverlay)
        }
        return .clear
    }
}

/// A small round button in a tab.
private struct CapsuleTabButton: View {
    let symbol: String
    let help: String
    var tint: Color?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundColor(tint ?? Color(nsColor: isHovered ? ChromePalette.text : ChromePalette.secondaryText))
                .frame(width: 18, height: 18)
                .background(Circle().fill(isHovered ? Color(nsColor: ChromePalette.selectionOverlay) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// The new tab button: a ghost button as tall as the track.
private struct CapsuleNewTabButton: View {
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color(nsColor: isHovered ? ChromePalette.text : ChromePalette.secondaryText))
                .frame(width: CapsuleTabs.newTabButtonWidth, height: CapsuleTabs.barHeight)
                .background(
                    RoundedRectangle(cornerRadius: CapsuleTabs.barHeight / 2, style: .continuous)
                        .fill(isHovered ? Color(nsColor: ChromePalette.hoverOverlay) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("New Tab")
    }
}

// MARK: Window Dragging

/// The bar's empty space. Dragging it moves the window and double-clicking it does what the
/// system setting for double-clicking a title bar says, as the titlebar itself does.
private struct CapsuleWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        DragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        // The drag is started from mouseDown instead, which the hosting view would otherwise
        // never pass on.
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            guard event.clickCount == 2 else {
                window.performDrag(with: event)
                return
            }

            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize":
                window.performMiniaturize(nil)
            case "None":
                break
            default:
                window.performZoom(nil)
            }
        }
    }
}
