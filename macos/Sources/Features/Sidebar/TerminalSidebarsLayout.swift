import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Places a terminal window's sidebars and tool rail beside its terminal view inside the
/// window's ``TerminalViewContainer``, from left to right: leading sidebar, terminal, trailing
/// sidebar, tool rail. Opening a sidebar narrows the terminal area; zooming a panel floats its
/// hosting view over the content area, leaving the terminal's layout and PTY size unchanged.
final class TerminalSidebarsLayout {
    /// The narrowest the terminal area gets before the sidebars start to shrink instead.
    static let minimumTerminalWidth: CGFloat = 160

    private let container: NSView
    private let terminalView: NSView
    private let sidebars: TerminalSidebars
    private let returnFocus: () -> Void
    private let leading: SidebarColumn
    private let trailing: SidebarColumn
    private let zoomOverlay: SidebarZoomOverlay
    private let toolRail: NSView
    private let toolRailWidth: NSLayoutConstraint
    private var zoomCancellable: AnyCancellable?
    private var desiredPanel: SidebarPanel?
    private var presentedPanel: SidebarPanel?
    private var zoomGeneration = 0

    /// The width of everything laid out beside the terminal.
    var widthBesideTerminal: CGFloat {
        leading.preferredWidth + trailing.preferredWidth + toolRailWidth.constant
    }

    /// Adds the sidebars and the tool rail to the container, which must already contain the
    /// terminal view with its top and bottom pinned and nothing pinning its leading or
    /// trailing edges.
    ///
    /// - Parameters:
    ///   - extendsIntoTitlebar: Whether the terminal extends into the titlebar area (the
    ///     hidden titlebar style). Otherwise the sidebars start below the titlebar.
    ///   - returnFocus: Called when a sidebar closes while it has keyboard focus.
    init(
        container: NSView,
        terminalView: NSView,
        sidebars: TerminalSidebars,
        toolRailActions: ToolRailActions,
        extendsIntoTitlebar: Bool,
        returnFocus: @escaping () -> Void
    ) {
        self.container = container
        self.terminalView = terminalView
        self.sidebars = sidebars
        self.returnFocus = returnFocus
        leading = SidebarColumn(edge: .leading, sidebars: sidebars, returnFocus: returnFocus)
        trailing = SidebarColumn(edge: .trailing, sidebars: sidebars, returnFocus: returnFocus)

        // Sized only by the constraints below, like the sidebars.
        let toolRailView = NSHostingView(rootView: ToolRailView(sidebars: sidebars, actions: toolRailActions))
        toolRailView.sizingOptions = []
        toolRailView.translatesAutoresizingMaskIntoConstraints = false
        toolRail = toolRailView
        toolRailWidth = toolRailView.widthAnchor.constraint(equalToConstant: ToolRailView.width)

        let overlay = SidebarZoomOverlay()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.isHidden = true
        zoomOverlay = overlay

        container.addSubview(leading)
        container.addSubview(trailing)
        container.addSubview(zoomOverlay)
        container.addSubview(toolRail)

        let top = extendsIntoTitlebar
            ? container.topAnchor
            : container.safeAreaLayoutGuide.topAnchor

        // The sidebar widths hold at a priority below this, so a window too narrow for
        // both sidebars and the terminal squeezes the sidebars first.
        let terminalMinimumWidth = terminalView.widthAnchor.constraint(
            greaterThanOrEqualToConstant: Self.minimumTerminalWidth)
        terminalMinimumWidth.priority = .init(900)

        NSLayoutConstraint.activate([
            leading.topAnchor.constraint(equalTo: top),
            leading.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            leading.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leading.trailingAnchor),

            trailing.topAnchor.constraint(equalTo: top),
            trailing.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            trailing.leadingAnchor.constraint(equalTo: terminalView.trailingAnchor),
            trailing.trailingAnchor.constraint(equalTo: toolRail.leadingAnchor),

            zoomOverlay.topAnchor.constraint(equalTo: top),
            zoomOverlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            zoomOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            zoomOverlay.trailingAnchor.constraint(equalTo: toolRail.leadingAnchor),

            toolRail.topAnchor.constraint(equalTo: top),
            toolRail.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            toolRail.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolRailWidth,

            terminalMinimumWidth,
        ])

        overlay.onRestore = { [weak sidebars] in sidebars?.restoreZoom() }
        zoomCancellable = sidebars.zoomPublisher()
            .sink { [weak self] panel in
                // @Published sends before storing the new value. Layout and snapshot the
                // panel only after SwiftUI can read its new zoom state.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.sidebars.zoomed == panel else { return }
                    self.applyZoom(panel)
                }
            }
    }

    /// Shows or hides the tool rail (`macos-tool-rail`).
    func setToolRailVisible(_ visible: Bool) {
        toolRailWidth.constant = visible ? ToolRailView.width : 0
        toolRail.isHidden = !visible
    }

    /// Window activation and restoration can focus a terminal behind the expanded panel.
    func focusZoomedPanelIfNeeded() {
        guard let presentedPanel, let window = container.window else { return }
        guard let responder = window.firstResponder as? NSView else {
            window.makeFirstResponder(zoomOverlay)
            return
        }
        let coveredColumn = presentedPanel == .files ? trailing : leading
        if responder === terminalView || responder.isDescendant(of: terminalView) ||
            coveredColumn.containsContent(responder) {
            window.makeFirstResponder(zoomOverlay)
        }
    }

    private func column(for panel: SidebarPanel) -> SidebarColumn {
        panel.edge == .leading ? leading : trailing
    }

    private func sourceFrame(for panel: SidebarPanel) -> NSRect {
        container.layoutSubtreeIfNeeded()
        let column = column(for: panel)
        return column.convert(column.bounds, to: zoomOverlay)
    }

    private var shouldAnimateZoom: Bool {
        container.window?.isVisible == true &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion &&
            container.bounds.width > 0
    }

    private func applyZoom(_ panel: SidebarPanel?) {
        guard desiredPanel != panel else { return }
        desiredPanel = panel
        zoomGeneration += 1
        let generation = zoomGeneration
        let currentFrame = zoomOverlay.stopAnimation()
        leading.setContentVisible(true)
        trailing.setContentVisible(true)

        if let presentedPanel, let panel, presentedPanel != panel {
            column(for: presentedPanel).restoreContent()
            self.presentedPanel = nil
        }

        guard let panel else {
            guard let presentedPanel else { return }
            let column = column(for: presentedPanel)
            let start = currentFrame ?? zoomOverlay.contentView.frame
            let image = shouldAnimateZoom && sidebars.isOpen(presentedPanel) ? zoomOverlay.snapshot() : nil
            let destination = sourceFrame(for: presentedPanel)

            // Reparent and lay out the real content at sidebar width before animating.
            // Only a disposable snapshot is scaled; AppKit and SwiftUI never inherit a
            // transformed ancestor when the hosting view is moved back into its column.
            column.restoreContent()
            container.layoutSubtreeIfNeeded()
            if sidebars.isOpen(presentedPanel), let image {
                column.setContentVisible(false)
                zoomOverlay.animateSnapshot(image, from: start, to: destination) { [weak self] in
                    self?.finishRestore(presentedPanel, generation: generation)
                }
            } else {
                finishRestore(presentedPanel, generation: generation)
            }
            return
        }

        let column = column(for: panel)
        let start = currentFrame ?? sourceFrame(for: panel)
        column.moveContent(to: zoomOverlay.contentView)
        zoomOverlay.isHidden = false
        presentedPanel = panel
        container.layoutSubtreeIfNeeded()
        zoomOverlay.layoutSubtreeIfNeeded()

        if let window = container.window {
            if let responder = window.firstResponder as? NSView {
                if !column.containsContent(responder) {
                    window.makeFirstResponder(zoomOverlay)
                }
            } else {
                window.makeFirstResponder(zoomOverlay)
            }
        }

        if shouldAnimateZoom, let image = zoomOverlay.snapshot() {
            zoomOverlay.contentView.isHidden = true
            zoomOverlay.animateSnapshot(image, from: start, to: zoomOverlay.contentView.frame) { [weak self] in
                guard let self, self.zoomGeneration == generation, self.desiredPanel == panel else { return }
                self.zoomOverlay.stopAnimation()
            }
        }
    }

    private func finishRestore(_ panel: SidebarPanel, generation: Int) {
        guard zoomGeneration == generation, desiredPanel == nil, presentedPanel == panel else { return }
        let shouldReturnFocus = container.window?.firstResponder === zoomOverlay || !sidebars.isOpen(panel)
        let column = column(for: panel)
        column.restoreContent()
        column.setContentVisible(true)
        presentedPanel = nil
        zoomOverlay.stopAnimation()
        zoomOverlay.isHidden = true
        container.layoutSubtreeIfNeeded()
        if shouldReturnFocus { returnFocus() }
    }
}

/// A centered panel over a translucent scrim. The live hosting view is never transformed;
/// zoom animations resize a separate snapshot layer that is discarded when they finish.
private final class SidebarZoomOverlay: NSView {
    let contentView = NSView()
    var onRestore: (() -> Void)?
    private let snapshotLayer = CALayer()
    private var animationGeneration = 0
    private var animationCompletion: (() -> Void)?
    private var animationSize: NSSize?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        contentView.wantsLayer = true
        addSubview(contentView)
        contentView.layer?.shadowColor = NSColor.black.cgColor
        contentView.layer?.shadowOpacity = 0.35
        contentView.layer?.shadowRadius = 16
        contentView.layer?.shadowOffset = CGSize(width: 0, height: -6)
        snapshotLayer.zPosition = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func layout() {
        super.layout()
        contentView.frame = SplitFrame.zoomedLeafFrame(in: bounds.size)
        contentView.layer?.shadowPath = CGPath(
            roundedRect: contentView.bounds.insetBy(dx: SplitFrame.gap, dy: SplitFrame.gap),
            cornerWidth: SplitFrame.cornerRadius,
            cornerHeight: SplitFrame.cornerRadius,
            transform: nil)

        // A window resize invalidates the snapshot's destination. Show the correctly
        // resized live view (or finish restoring it) instead of stretching a stale image.
        if let animationSize, animationSize != bounds.size {
            let completion = animationCompletion
            stopAnimation()
            // Restoring reparents content and lays out the container. Do that after this
            // layout pass to avoid recursively entering AppKit's layout engine.
            DispatchQueue.main.async { completion?() }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        ChromePalette.canvas.withAlphaComponent(SplitFrame.zoomedScrimOpacity).setFill()
        NSBezierPath(rect: dirtyRect).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onRestore?()
    }

    override func cancelOperation(_ sender: Any?) {
        onRestore?()
    }

    func snapshot() -> CGImage? {
        contentView.layoutSubtreeIfNeeded()
        guard contentView.bounds.width > 0, contentView.bounds.height > 0,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else { return nil }
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        return bitmap.cgImage
    }

    @discardableResult
    func stopAnimation() -> NSRect? {
        let current = snapshotLayer.superlayer == nil ? nil :
            (snapshotLayer.presentation()?.frame ?? snapshotLayer.frame)
        animationGeneration += 1
        animationCompletion = nil
        animationSize = nil
        snapshotLayer.removeAllAnimations()
        snapshotLayer.removeFromSuperlayer()
        snapshotLayer.contents = nil
        contentView.isHidden = false
        return current
    }

    func animateSnapshot(_ image: CGImage, from start: NSRect, to end: NSRect, completion: @escaping () -> Void) {
        guard let layer, start.width > 0, start.height > 0, end.width > 0, end.height > 0 else {
            completion()
            return
        }
        animationGeneration += 1
        let generation = animationGeneration
        animationCompletion = completion
        animationSize = bounds.size

        let size = spring(keyPath: "bounds")
        size.fromValue = NSValue(rect: NSRect(origin: .zero, size: start.size))
        size.toValue = NSValue(rect: NSRect(origin: .zero, size: end.size))
        let position = spring(keyPath: "position")
        position.fromValue = NSValue(point: NSPoint(x: start.midX, y: start.midY))
        position.toValue = NSValue(point: NSPoint(x: end.midX, y: end.midY))
        let animation = CAAnimationGroup()
        animation.animations = [size, position]
        animation.duration = max(size.duration, position.duration)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.animationGeneration == generation else { return }
            completion()
        }
        snapshotLayer.contents = image
        snapshotLayer.contentsScale = window?.backingScaleFactor ?? 1
        snapshotLayer.frame = end
        layer.addSublayer(snapshotLayer)
        snapshotLayer.add(animation, forKey: "sidebarZoom")
        CATransaction.commit()
    }

    private func spring(keyPath: String) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        let angularFrequency = 2 * CGFloat.pi / 0.38
        spring.mass = 1
        spring.stiffness = angularFrequency * angularFrequency
        spring.damping = 2 * 0.9 * angularFrequency
        spring.duration = spring.settlingDuration
        return spring
    }
}

// MARK: Sidebar Column

/// One sidebar: the SwiftUI panel content and the strip along its inner edge that resizes it.
private final class SidebarColumn: NSView {
    let edge: SidebarEdge
    private let sidebars: TerminalSidebars
    private let returnFocus: () -> Void
    private let hostingView: NSHostingView<SidebarColumnView>
    private let handle = SidebarResizeHandle()
    private var contentConstraints: [NSLayoutConstraint] = []

    /// The sidebar's width while it is open. It holds below the required priority so a
    /// narrow window can shrink it.
    private var widthConstraint: NSLayoutConstraint!

    /// Collapses the sidebar while it is closed.
    private var closedConstraint: NSLayoutConstraint!

    /// The width when the resize drag began.
    private var dragStartWidth: CGFloat = 0

    private var cancellables: Set<AnyCancellable> = []

    /// The width the sidebar asks for, zero while it is closed.
    var preferredWidth: CGFloat {
        let side = sidebars.side(edge)
        return side.panel == nil ? 0 : side.width
    }

    init(edge: SidebarEdge, sidebars: TerminalSidebars, returnFocus: @escaping () -> Void) {
        self.edge = edge
        self.sidebars = sidebars
        self.returnFocus = returnFocus
        self.hostingView = NSHostingView(rootView: SidebarColumnView(edge: edge, sidebars: sidebars))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.masksToBounds = true

        // The panel is sized only by these constraints, never by its SwiftUI content,
        // which would otherwise fight the closed sidebar's zero width.
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)

        handle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(handle)

        widthConstraint = widthAnchor.constraint(equalToConstant: sidebars.side(edge).width)
        widthConstraint.priority = .init(800)
        closedConstraint = widthAnchor.constraint(equalToConstant: 0)

        let handleEdge = edge == .leading
            ? handle.trailingAnchor.constraint(equalTo: trailingAnchor)
            : handle.leadingAnchor.constraint(equalTo: leadingAnchor)

        contentConstraints = constraintsForContent(in: self)
        NSLayoutConstraint.activate(contentConstraints + [
            handle.topAnchor.constraint(equalTo: topAnchor),
            handle.bottomAnchor.constraint(equalTo: bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: 5),
            handleEdge,

            widthConstraint,
        ])

        handle.onDragBegan = { [weak self] in
            guard let self else { return }
            self.dragStartWidth = self.frame.width
        }
        handle.onDragChanged = { [weak self] distance in
            self?.resize(byDragging: distance)
        }
        handle.onDragEnded = { [weak self] in
            guard let self else { return }
            self.sidebars.saveWidth(for: self.edge)
        }
        handle.onDoubleClick = { [weak self] in
            guard let self else { return }
            self.sidebars.setWidth(TerminalSidebars.defaultWidth, for: self.edge)
            self.sidebars.saveWidth(for: self.edge)
        }

        sidebars.sidePublisher(edge)
            .sink { [weak self] in self?.apply($0) }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func constraintsForContent(in parent: NSView) -> [NSLayoutConstraint] {
        [
            hostingView.topAnchor.constraint(equalTo: parent.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
        ]
    }

    private func moveContent(into parent: NSView) {
        NSLayoutConstraint.deactivate(contentConstraints)
        hostingView.removeFromSuperview()
        parent.addSubview(hostingView)
        contentConstraints = constraintsForContent(in: parent)
        NSLayoutConstraint.activate(contentConstraints)
    }

    func moveContent(to overlay: NSView) {
        moveContent(into: overlay)
        handle.isHidden = true
    }

    func restoreContent() {
        guard hostingView.superview !== self else { return }
        moveContent(into: self)
        handle.isHidden = false
    }

    func setContentVisible(_ visible: Bool) {
        hostingView.isHidden = !visible
    }

    func containsContent(_ responder: NSView) -> Bool {
        responder === hostingView || responder.isDescendant(of: hostingView)
    }

    private func apply(_ side: TerminalSidebars.Side) {
        let isOpen = side.panel != nil

        // A hidden sidebar can't keep keyboard focus, so hand it back to the terminal.
        if !isOpen,
           !isHidden,
           let responder = window?.firstResponder as? NSView,
           responder.isDescendant(of: self) {
            DispatchQueue.main.async { [returnFocus] in returnFocus() }
        }

        widthConstraint.constant = side.width
        closedConstraint.isActive = !isOpen
        isHidden = !isOpen
    }

    private func resize(byDragging distance: CGFloat) {
        // Dragging toward the terminal widens the sidebar.
        let proposed = edge == .leading
            ? dragStartWidth + distance
            : dragStartWidth - distance

        // Leave the terminal its minimum width; past that the window is simply too narrow.
        let available = (superview?.bounds.width ?? proposed) - TerminalSidebarsLayout.minimumTerminalWidth
        sidebars.setWidth(min(proposed, max(available, TerminalSidebars.minimumWidth)), for: edge)
    }
}

// MARK: Resize Handle

/// The strip along a sidebar's inner edge that resizes it. It sits inside the sidebar so the
/// terminal keeps every point of its own area for mouse input.
private final class SidebarResizeHandle: NSView {
    var onDragBegan: (() -> Void)?
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private var dragStartX: CGFloat?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityLabel("Sidebar divider")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            dragStartX = nil
            onDoubleClick?()
            return
        }

        dragStartX = event.locationInWindow.x
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartX else { return }
        onDragChanged?(event.locationInWindow.x - dragStartX)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartX != nil else { return }
        dragStartX = nil
        onDragEnded?()
    }
}
