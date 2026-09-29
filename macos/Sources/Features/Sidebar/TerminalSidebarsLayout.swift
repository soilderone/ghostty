import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Places a terminal window's sidebars and tool rail beside its terminal view inside the
/// window's ``TerminalViewContainer``, from left to right: leading sidebar, terminal, trailing
/// sidebar, tool rail. Opening a sidebar narrows the terminal area; zooming a panel moves its
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
    private let zoomLeading: NSLayoutConstraint
    private let zoomTrailing: NSLayoutConstraint
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
        zoomLeading = overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor)
        zoomTrailing = overlay.trailingAnchor.constraint(equalTo: toolRailView.leadingAnchor)

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
            zoomLeading,
            zoomTrailing,

            toolRail.topAnchor.constraint(equalTo: top),
            toolRail.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            toolRail.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolRailWidth,

            terminalMinimumWidth,
        ])

        zoomCancellable = sidebars.zoomPublisher()
            .sink { [weak self] in self?.applyZoom($0) }
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
        return column.convert(column.bounds, to: container)
    }

    private func setOverlayFrame(_ frame: NSRect) {
        zoomLeading.constant = frame.minX
        zoomTrailing.constant = frame.maxX - toolRail.frame.minX
    }

    private var shouldAnimateZoom: Bool {
        container.window?.isVisible == true &&
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion &&
            container.bounds.width > 0
    }

    private func animateOverlay(to frame: NSRect, completion: (() -> Void)? = nil) {
        guard shouldAnimateZoom else {
            setOverlayFrame(frame)
            container.layoutSubtreeIfNeeded()
            completion?()
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.36
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            setOverlayFrame(frame)
            container.animator().layoutSubtreeIfNeeded()
        }, completionHandler: completion)
    }

    private func applyZoom(_ panel: SidebarPanel?) {
        guard desiredPanel != panel else { return }
        desiredPanel = panel
        zoomGeneration += 1
        let generation = zoomGeneration
        let presentedFrame = zoomOverlay.layer?.presentation()?.frame
        zoomOverlay.layer?.removeAllAnimations()
        if let presentedFrame, presentedPanel != nil {
            setOverlayFrame(presentedFrame)
            container.layoutSubtreeIfNeeded()
        }

        if let presentedPanel, let panel, presentedPanel != panel {
            column(for: presentedPanel).restoreContent()
            self.presentedPanel = nil
        }

        guard let panel else {
            guard let presentedPanel else { return }
            let source = sourceFrame(for: presentedPanel)
            let wasClosed = !sidebars.isOpen(presentedPanel)
            if wasClosed {
                setOverlayFrame(source)
                container.layoutSubtreeIfNeeded()
                finishRestore(presentedPanel, generation: generation)
            } else {
                animateOverlay(to: source) { [weak self] in
                    self?.finishRestore(presentedPanel, generation: generation)
                }
            }
            return
        }

        let column = column(for: panel)
        if presentedPanel == nil {
            let source = sourceFrame(for: panel)
            setOverlayFrame(source)
            container.layoutSubtreeIfNeeded()
            column.moveContent(to: zoomOverlay)
            zoomOverlay.isHidden = false
            presentedPanel = panel
            container.layoutSubtreeIfNeeded()
        }

        if let window = container.window {
            if let responder = window.firstResponder as? NSView {
                if !column.containsContent(responder) {
                    window.makeFirstResponder(zoomOverlay)
                }
            } else {
                window.makeFirstResponder(zoomOverlay)
            }
        }
        animateOverlay(to: NSRect(x: 0, y: 0, width: toolRail.frame.minX, height: zoomOverlay.frame.height))
    }

    private func finishRestore(_ panel: SidebarPanel, generation: Int) {
        guard zoomGeneration == generation, desiredPanel == nil, presentedPanel == panel else { return }
        let shouldReturnFocus = container.window?.firstResponder === zoomOverlay || !sidebars.isOpen(panel)
        column(for: panel).restoreContent()
        presentedPanel = nil
        zoomOverlay.isHidden = true
        container.layoutSubtreeIfNeeded()
        if shouldReturnFocus { returnFocus() }
    }
}

/// Opaque canvas behind the expanded panel. Its content is the panel's original hosting view.
private final class SidebarZoomOverlay: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        ChromePalette.canvas.setFill()
        NSBezierPath(rect: dirtyRect).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
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
