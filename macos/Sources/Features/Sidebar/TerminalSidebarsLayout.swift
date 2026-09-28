import AppKit
import Combine
import SwiftUI

/// Places a terminal window's sidebars beside its terminal view inside the window's
/// ``TerminalViewContainer``. Only the terminal view's frame changes; the split tree inside
/// it is untouched, so opening a sidebar works like making the window narrower.
final class TerminalSidebarsLayout {
    /// The narrowest the terminal area gets before the sidebars start to shrink instead.
    static let minimumTerminalWidth: CGFloat = 160

    private let leading: SidebarColumn
    private let trailing: SidebarColumn

    /// The width of everything laid out beside the terminal.
    var widthBesideTerminal: CGFloat {
        leading.preferredWidth + trailing.preferredWidth
    }

    /// Adds the sidebars to the container, which must already contain the terminal view with
    /// its top and bottom pinned and nothing pinning its leading or trailing edges.
    ///
    /// - Parameters:
    ///   - extendsIntoTitlebar: Whether the terminal extends into the titlebar area (the
    ///     hidden titlebar style). Otherwise the sidebars start below the titlebar.
    ///   - returnFocus: Called when a sidebar closes while it has keyboard focus.
    init(
        container: NSView,
        terminalView: NSView,
        sidebars: TerminalSidebars,
        extendsIntoTitlebar: Bool,
        returnFocus: @escaping () -> Void
    ) {
        leading = SidebarColumn(edge: .leading, sidebars: sidebars, returnFocus: returnFocus)
        trailing = SidebarColumn(edge: .trailing, sidebars: sidebars, returnFocus: returnFocus)

        container.addSubview(leading)
        container.addSubview(trailing)

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
            trailing.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            terminalMinimumWidth,
        ])
    }
}

// MARK: Sidebar Column

/// One sidebar: the SwiftUI panel content and the strip along its inner edge that resizes it.
private final class SidebarColumn: NSView {
    let edge: SidebarEdge
    private let sidebars: TerminalSidebars
    private let returnFocus: () -> Void
    private let handle = SidebarResizeHandle()

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
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        // The panel is sized only by these constraints, never by its SwiftUI content,
        // which would otherwise fight the closed sidebar's zero width.
        let hostingView = NSHostingView(rootView: SidebarColumnView(edge: edge, sidebars: sidebars))
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

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),

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
