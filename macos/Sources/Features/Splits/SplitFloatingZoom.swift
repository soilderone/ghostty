import AppKit
import SwiftUI

/// How a zoomed terminal is shown with `macos-split-frame`: its card floats over the split tree
/// instead of replacing it, the way Wave shows a magnified block. The card takes most of the
/// area and is centered, the other terminals stay where they are behind a wash of the window
/// canvas, and a click on that wash restores the split.
extension SplitFrame {
    /// The share of the area the split tree is shown in that a zoomed terminal's card takes,
    /// as with Wave's `window:magnifiedblocksize`.
    static let zoomedScale: CGFloat = 0.95

    /// How much of the canvas color washes over the terminals behind a floating card. Wave
    /// blurs them instead, but blurring would make the compositor render the Metal-backed
    /// terminals offscreen.
    static let zoomedScrimOpacity: Double = 0.6

    /// The frame that the leaf of a floating terminal takes in an area of the given size: the
    /// centered card plus the half gap a leaf pads itself with. The margin around the card
    /// never gets narrower than two gaps, so small windows keep one too.
    static func zoomedLeafFrame(in size: CGSize) -> CGRect {
        let marginX = max(size.width * (1 - zoomedScale) / 2, 2 * gap)
        let marginY = max(size.height * (1 - zoomedScale) / 2, 2 * gap)
        let card = CGRect(
            x: marginX,
            y: marginY,
            width: max(size.width - 2 * marginX, 0),
            height: max(size.height - 2 * marginY, 0))
        return card.insetBy(dx: -gap / 2, dy: -gap / 2)
    }
}

// MARK: Floating card

/// The zoomed terminal's card over the rest of the split tree.
///
/// The other terminals are mounted at their usual places with the zoomed one left empty, so
/// its Metal-backed view only ever exists in the card. The card is laid out once, where it
/// ends up, and a transform plays the move from or to its place in the tree.
struct SplitFloatingZoom: View {
    /// How the card moves while a zoom plays.
    enum Motion {
        /// From its place in the split tree up over the others.
        case zoomingIn

        /// From over the others back to its place.
        case restoring
    }

    let root: SplitTree<Ghostty.SurfaceView>.Node
    let target: Ghostty.SurfaceView

    /// The move to play once, or nil when the card simply sits over the others.
    let motion: Motion?
    let action: (TerminalSplitOperation) -> Void

    @EnvironmentObject private var ghostty: Ghostty.App
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    /// How much of the move has played. It has all played when there is none.
    private var played: CGFloat {
        motion == nil || reduceMotion ? 1 : progress
    }

    /// 1 while the card is over the others, 0 once it is back in its place.
    private var floating: CGFloat {
        motion == .restoring ? 1 - played : played
    }

    var body: some View {
        GeometryReader { geo in
            let floatFrame = SplitFrame.zoomedLeafFrame(in: geo.size)
            let slotFrame = slot(in: geo.size) ?? floatFrame
            let layout = motion == .restoring ? slotFrame : floatFrame
            let origin = motion == .restoring ? floatFrame : slotFrame

            ZStack(alignment: .topLeading) {
                // The terminal being zoomed is a clear placeholder here.
                TerminalSplitSubtreeView(
                    node: root,
                    isRoot: true,
                    excludedSurfaceID: target.id,
                    action: action)
                    .id(root.structuralIdentity)
                    .padding(SplitFrame.gap / 2)
                    .environment(\.splitFrameTree, SplitFrameTree(isSplit: true, isZoomed: false))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                SplitZoomScrim(
                    info: target.cardInfo,
                    amount: floating,
                    // A tap while the card is on its way back must not zoom it again.
                    isInteractive: motion != .restoring,
                    onTap: restore)

                ZStack {
                    SplitZoomShadow()
                        .padding(SplitFrame.gap / 2)
                        .opacity(Double(floating))
                        .allowsHitTesting(false)

                    TerminalSplitLeaf(surfaceView: target, isSplit: true, action: action)
                }
                .frame(width: layout.width, height: layout.height)
                .modifier(SplitFloatGeometryEffect(origin: origin, layout: layout, progress: played))
                .offset(x: layout.minX, y: layout.minY)
                .environment(\.splitFrameTree, SplitFrameTree(isSplit: true, isZoomed: motion != .restoring))
            }
        }
        .environment(\.showsSplitFrames, true)
        .onAppear {
            guard motion != nil, !reduceMotion else { return }
            // Match the other zoom animations: 0.38 s response and 0.9 damping fraction.
            withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
                progress = 1
            }
        }
    }

    /// Where the target's leaf sits in the tree at rest, in an area of the given size.
    private func slot(in size: CGSize) -> CGRect? {
        guard let node = root.find(id: target.id),
              let bounds = root.spatial(within: CGSize(width: 1, height: 1))
                .slots.first(where: { $0.node == node })?.bounds else { return nil }

        // The tree pads itself by half a gap all around.
        let inset = SplitFrame.gap / 2
        let width = size.width - 2 * inset
        let height = size.height - 2 * inset
        guard width > 0, height > 0 else { return nil }

        return CGRect(
            x: inset + bounds.minX * width,
            y: inset + bounds.minY * height,
            width: bounds.width * width,
            height: bounds.height * height)
    }

    private func restore() {
        guard let surface = target.surface else { return }
        ghostty.splitToggleZoom(surface: surface)
    }
}

/// Keeps the card over the others until a restore has finished, then hands the terminal back
/// to the plain split tree.
struct SplitFloatingRestore<Content: View>: View {
    let root: SplitTree<Ghostty.SurfaceView>.Node
    let target: Ghostty.SurfaceView
    let transition: SplitZoomTransition
    let action: (TerminalSplitOperation) -> Void
    let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSettled = false

    var body: some View {
        if isSettled || reduceMotion {
            content
        } else {
            SplitFloatingZoom(root: root, target: target, motion: .restoring, action: action)
                .task(id: transition.id) { await settle() }
        }
    }

    private func settle() async {
        // A little longer than the spring takes to come to rest.
        do {
            try await Task.sleep(for: .milliseconds(600))
        } catch {
            return
        }

        // Mounting the terminal in the tree moves its view, which drops its keyboard focus.
        let hadFocus = target.window?.firstResponder === target
        isSettled = true
        if hadFocus {
            // Wait for SwiftUI to finish moving the view before taking focus back.
            Ghostty.moveFocus(to: target, delay: 0.05)
        }
    }
}

// MARK: Scrim

/// The wash over the terminals behind a floating card, in the color of the window canvas. A
/// click on it restores the split.
private struct SplitZoomScrim: View {
    @ObservedObject var info: SplitCardInfo
    let amount: CGFloat
    let isInteractive: Bool
    let onTap: () -> Void

    /// The canvas the window shows around the cards, without any transparency of its own.
    private var canvas: Color {
        Color(nsColor: ChromePalette.canvas(behind: NSColor(info.value.background)).withAlphaComponent(1))
    }

    var body: some View {
        canvas
            .opacity(Double(amount) * SplitFrame.zoomedScrimOpacity)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .allowsHitTesting(isInteractive)
            .accessibilityLabel("Restore Split")
            .accessibilityAddTraits(.isButton)
    }
}

// MARK: Shadow

/// The soft shadow around a floating card.
///
/// This is a shape of its own instead of a `.shadow` on the card, since a shadow on the card
/// would make the compositor render the terminal's Metal view offscreen. It is cut out under
/// the card too, so a terminal with `background-opacity` below 1 has nothing behind it.
private struct SplitZoomShadow: View {
    var body: some View {
        RoundedRectangle(cornerRadius: SplitFrame.cornerRadius, style: .continuous)
            .fill(Color.black)
            .shadow(color: Color.black.opacity(0.35), radius: 16, x: 0, y: 6)
            .mask(SplitZoomShadowMask().fill(Color.black, style: FillStyle(eoFill: true)))
    }
}

/// Everything around the card, filled even-odd. It reaches out far enough to keep the shadow.
private struct SplitZoomShadowMask: Shape {
    static let reach: CGFloat = 60

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -Self.reach, dy: -Self.reach))
        path.addPath(Path(roundedRect: rect, cornerRadius: SplitFrame.cornerRadius, style: .continuous))
        return path
    }
}

// MARK: Motion

/// Moves the card between its place in the split tree and its place over the others. Being a
/// geometry effect, it leaves the layout alone: the card is laid out at `layout` and drawn from
/// `origin` towards it, so the terminal is only resized once.
private struct SplitFloatGeometryEffect: GeometryEffect {
    /// Where the card is drawn at the start, and `layout` is where it ends up, both in the
    /// coordinates of the area the split tree is shown in.
    let origin: CGRect
    let layout: CGRect
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard layout.width > 0, layout.height > 0 else { return ProjectionTransform(.identity) }

        let remaining = 1 - progress
        let scaleX = origin.width / layout.width
        let scaleY = origin.height / layout.height

        return ProjectionTransform(CGAffineTransform(
            a: 1 + (scaleX - 1) * remaining,
            b: 0,
            c: 0,
            d: 1 + (scaleY - 1) * remaining,
            tx: (origin.minX - layout.minX) * remaining,
            ty: (origin.minY - layout.minY) * remaining))
    }
}
