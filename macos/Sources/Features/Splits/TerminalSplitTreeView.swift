import SwiftUI

/// A single operation within the split tree.
///
/// Rather than binding the split tree (which is immutable), any mutable operations are
/// exposed via this enum to the embedder to handle.
enum TerminalSplitOperation {
    case resize(Resize)
    case drop(Drop)

    struct Resize {
        let node: SplitTree<Ghostty.SurfaceView>.Node
        let ratio: Double
    }

    struct Drop {
        /// The surface being dragged.
        let payload: Ghostty.SurfaceView

        /// The surface it was dragged onto
        let destination: Ghostty.SurfaceView

        /// The zone it was dropped to determine how to split the destination.
        let zone: TerminalSplitDropZone
    }
}

/// One explicit zoom action. The ID gives its incoming view fresh animation
/// state; retaining only the surface ID does not keep a closed surface alive.
struct SplitZoomTransition {
    let id = UUID()
    let targetID: UUID
    let zoomingIn: Bool
}

struct TerminalSplitTreeView: View {
    let tree: SplitTree<Ghostty.SurfaceView>
    let zoomTransition: SplitZoomTransition?
    let action: (TerminalSplitOperation) -> Void

    @EnvironmentObject private var ghostty: Ghostty.App
    @Environment(\.splitFramesAllowed) private var splitFramesAllowed

    private var showsFrames: Bool {
        splitFramesAllowed && ghostty.config.macosSplitFrame
    }

    var body: some View {
        if let node = tree.zoomed ?? tree.root {
            let subtree = TerminalSplitSubtreeView(
                node: node,
                isRoot: node == tree.root,
                excludedSurfaceID: nil,
                action: action)
            // This is necessary because we can't rely on SwiftUI's implicit
            // structural identity to detect changes to this view. Due to
            // the tree structure of splits it could result in bad behaviors.
            // See: https://github.com/ghostty-org/ghostty/issues/7546
            .id(node.structuralIdentity)
            // Each leaf pads itself by the other half, so cards are a gap apart
            // from each other and from the window edge.
            .padding(showsFrames ? SplitFrame.gap / 2 : 0)
            .environment(\.showsSplitFrames, showsFrames)
            .environment(\.splitFrameTree, SplitFrameTree(isSplit: tree.isSplit, isZoomed: tree.zoomed != nil))

            if let zoomTransition, let root = tree.root,
               root.find(id: zoomTransition.targetID) != nil {
                SplitZoomAnimatedView(
                    root: root,
                    transition: zoomTransition,
                    inset: showsFrames ? SplitFrame.gap / 2 : 0,
                    showsFrames: showsFrames,
                    action: action,
                    content: subtree)
                    .id(zoomTransition.id)
            } else {
                subtree
            }
        }
    }
}

/// Move the incoming tree from the selected pane's old bounds to its final
/// bounds. The fading background omits the target pane, so its Metal-backed
/// NSView is only mounted once during the transition.
private struct SplitZoomAnimatedView<Content: View>: View {
    let root: SplitTree<Ghostty.SurfaceView>.Node
    let transition: SplitZoomTransition
    let inset: CGFloat
    let showsFrames: Bool
    let action: (TerminalSplitOperation) -> Void
    let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    @State private var showsOutgoingSplits = true

    private var sourceBounds: CGRect? {
        guard let target = root.find(id: transition.targetID) else { return nil }
        return root.spatial(within: CGSize(width: 1, height: 1))
            .slots.first(where: { $0.node == target })?.bounds
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Keep the other panes at their original size while they fade out.
            // The target is a clear placeholder here, so its NSView only exists
            // in the animated foreground.
            if transition.zoomingIn && !reduceMotion && showsOutgoingSplits {
                TerminalSplitSubtreeView(
                    node: root,
                    isRoot: true,
                    excludedSurfaceID: transition.targetID,
                    action: action)
                    .id(root.structuralIdentity)
                    .padding(inset)
                    .environment(\.showsSplitFrames, showsFrames)
                    .environment(\.splitFrameTree, SplitFrameTree(isSplit: true, isZoomed: false))
                    .opacity(min(max(1 - progress, 0), 1))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            content
                .modifier(SplitZoomGeometryEffect(
                    sourceBounds: sourceBounds,
                    zoomingIn: transition.zoomingIn,
                    inset: inset,
                    progress: reduceMotion ? 1 : progress))
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
                progress = 1
            }
        }
        .task(id: transition.id) {
            guard transition.zoomingIn && !reduceMotion else { return }
            do {
                try await Task.sleep(for: .milliseconds(700))
            } catch {
                return
            }
            showsOutgoingSplits = false
        }
    }
}

/// A geometry effect leaves SwiftUI's layout size alone while the incoming
/// terminal grows or the full split tree settles back around it.
private struct SplitZoomGeometryEffect: GeometryEffect {
    let sourceBounds: CGRect?
    let zoomingIn: Bool
    let inset: CGFloat
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        guard let sourceBounds else { return ProjectionTransform(.identity) }

        let innerWidth = size.width - 2 * inset
        let innerHeight = size.height - 2 * inset
        guard innerWidth > 0, innerHeight > 0 else { return ProjectionTransform(.identity) }

        let source = CGRect(
            x: inset + sourceBounds.minX * innerWidth,
            y: inset + sourceBounds.minY * innerHeight,
            width: sourceBounds.width * innerWidth,
            height: sourceBounds.height * innerHeight)
        guard source.width > 0, source.height > 0 else { return ProjectionTransform(.identity) }

        let initialScaleX = zoomingIn ? source.width / size.width : size.width / source.width
        let initialScaleY = zoomingIn ? source.height / size.height : size.height / source.height
        let initialX = zoomingIn ? source.minX : -source.minX * initialScaleX
        let initialY = zoomingIn ? source.minY : -source.minY * initialScaleY
        let remaining = 1 - progress

        return ProjectionTransform(CGAffineTransform(
            a: 1 + (initialScaleX - 1) * remaining,
            b: 0,
            c: 0,
            d: 1 + (initialScaleY - 1) * remaining,
            tx: initialX * remaining,
            ty: initialY * remaining))
    }
}

private struct TerminalSplitSubtreeView: View {
    @EnvironmentObject var ghostty: Ghostty.App

    @Environment(\.showsSplitFrames) private var showsFrames

    let node: SplitTree<Ghostty.SurfaceView>.Node
    var isRoot: Bool = false
    let excludedSurfaceID: UUID?
    let action: (TerminalSplitOperation) -> Void

    var body: some View {
        switch node {
        case .leaf(let leafView):
            if leafView.id == excludedSurfaceID {
                Color.clear
            } else {
                TerminalSplitLeaf(surfaceView: leafView, isSplit: !isRoot, action: action)
            }

        case .split(let split):
            let splitViewDirection: SplitViewDirection = switch split.direction {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }

            SplitView(
                splitViewDirection,
                .init(get: {
                    CGFloat(split.ratio)
                }, set: {
                    action(.resize(.init(node: node, ratio: $0)))
                }),
                // Between cards the gap is the divider; it still resizes.
                dividerColor: showsFrames ? .clear : ghostty.config.splitDividerColor,
                resizeIncrements: .init(width: 1, height: 1),
                left: {
                    TerminalSplitSubtreeView(node: split.left, excludedSurfaceID: excludedSurfaceID, action: action)
                },
                right: {
                    TerminalSplitSubtreeView(node: split.right, excludedSurfaceID: excludedSurfaceID, action: action)
                },
                onEqualize: {
                    guard let surface = node.leftmostLeaf().surface else { return }
                    ghostty.splitEqualize(surface: surface)
                }
            )
        }
    }
}

private struct TerminalSplitLeaf: View {
    let surfaceView: Ghostty.SurfaceView
    let isSplit: Bool
    let action: (TerminalSplitOperation) -> Void

    @Environment(\.showsSplitFrames) private var showsFrames

    @State private var dropState: DropState = .idle
    @State private var isSelfDragging: Bool = false

    var body: some View {
        GeometryReader { geometry in
            leafContent
            .background {
                // If we're dragging ourself, we hide the entire drop zone. This makes
                // it so that a released drop animates back to its source properly
                // so it is a proper invalid drop zone.
                if !isSelfDragging {
                    Color.clear
                        .onDrop(of: [.ghosttySurfaceId], delegate: SplitDropDelegate(
                            dropState: $dropState,
                            viewSize: geometry.size,
                            destinationSurface: surfaceView,
                            action: action
                        ))
                }
            }
            .overlay {
                if !isSelfDragging, case .dropping(let zone) = dropState {
                    zone.overlay(in: geometry)
                        .clipShape(RoundedRectangle(
                            cornerRadius: showsFrames ? SplitFrame.cornerRadius : 0,
                            style: .continuous))
                        .allowsHitTesting(false)
                }
            }
            .onPreferenceChange(Ghostty.DraggingSurfaceKey.self) { value in
                isSelfDragging = value == surfaceView.id
                if isSelfDragging {
                    dropState = .idle
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Terminal pane")
        }
        .padding(showsFrames ? SplitFrame.gap / 2 : 0)
    }

    @ViewBuilder
    private var leafContent: some View {
        let surface = Ghostty.InspectableSurface(surfaceView: surfaceView, isSplit: isSplit)
        if showsFrames {
            SplitCard(surfaceView: surfaceView) { surface }
        } else {
            surface
        }
    }

    private enum DropState: Equatable {
        case idle
        case dropping(TerminalSplitDropZone)
    }

    private struct SplitDropDelegate: DropDelegate {
        @Binding var dropState: DropState
        let viewSize: CGSize
        let destinationSurface: Ghostty.SurfaceView
        let action: (TerminalSplitOperation) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            info.hasItemsConforming(to: [.ghosttySurfaceId])
        }

        func dropEntered(info: DropInfo) {
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            // For some reason dropUpdated is sent after performDrop is called
            // and we don't want to reset our drop zone to show it so we have
            // to guard on the state here.
            guard case .dropping = dropState else { return DropProposal(operation: .forbidden) }
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            dropState = .idle
        }

        func performDrop(info: DropInfo) -> Bool {
            let zone = TerminalSplitDropZone.calculate(at: info.location, in: viewSize)
            dropState = .idle

            // Load the dropped surface asynchronously using Transferable
            let providers = info.itemProviders(for: [.ghosttySurfaceId])
            guard let provider = providers.first else { return false }

            // Capture action before the async closure
            _ = provider.loadTransferable(type: Ghostty.SurfaceView.self) { [weak destinationSurface] result in
                switch result {
                case .success(let sourceSurface):
                    DispatchQueue.main.async {
                        // Don't allow dropping on self
                        guard let destinationSurface else { return }
                        guard sourceSurface !== destinationSurface else { return }
                        action(.drop(.init(payload: sourceSurface, destination: destinationSurface, zone: zone)))
                    }

                case .failure:
                    break
                }
            }

            return true
        }
    }
}

enum TerminalSplitDropZone: String, Equatable {
    case top
    case bottom
    case left
    case right

    /// Determines which drop zone the cursor is in based on proximity to edges.
    ///
    /// Divides the view into four triangular regions by drawing diagonals from
    /// corner to corner. The drop zone is determined by which edge the cursor
    /// is closest to, creating natural triangular hit regions for each side.
    static func calculate(at point: CGPoint, in size: CGSize) -> TerminalSplitDropZone {
        let relX = point.x / size.width
        let relY = point.y / size.height

        let distToLeft = relX
        let distToRight = 1 - relX
        let distToTop = relY
        let distToBottom = 1 - relY

        let minDist = min(distToLeft, distToRight, distToTop, distToBottom)

        if minDist == distToLeft { return .left }
        if minDist == distToRight { return .right }
        if minDist == distToTop { return .top }
        return .bottom
    }

    @ViewBuilder
    func overlay(in geometry: GeometryProxy) -> some View {
        // Only shown during a drag, which happens in the key window.
        let overlayColor = ChromeAccent.shared.color(inKeyWindow: true).opacity(0.3)

        switch self {
        case .top:
            VStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
                Spacer()
            }
        case .bottom:
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
            }
        case .left:
            HStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
                Spacer()
            }
        case .right:
            HStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
            }
        }
    }
}
